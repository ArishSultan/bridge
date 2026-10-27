import AppKit
import Carbon
import GhosttyKit

// Keyboard, IME and mouse handling here follows Ghostty's own macOS app (MIT license,
// vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift), which is the
// reference for how libghostty expects AppKit input.

/// One terminal: a libghostty surface hosted in an AppKit view.
///
/// libghostty attaches its own Metal layer to this view and renders into it from a dedicated
/// renderer thread, synced to the display. This view only forwards size, focus and input.
@MainActor
public final class TerminalSurfaceView: NSView {
    /// What a new terminal starts with.
    public struct Options: Sendable {
        public var workingDirectory: String?
        public var command: String?
        /// Points; nil uses the configured size.
        public var fontSize: Float?

        public init(workingDirectory: String? = nil, command: String? = nil, fontSize: Float? = nil) {
            self.workingDirectory = workingDirectory
            self.command = command
            self.fontSize = fontSize
        }
    }

    public enum Context: Sendable {
        case window, tab, split

        var ghostty: ghostty_surface_context_e {
            switch self {
            case .window: GHOSTTY_SURFACE_CONTEXT_WINDOW
            case .tab: GHOSTTY_SURFACE_CONTEXT_TAB
            case .split: GHOSTTY_SURFACE_CONTEXT_SPLIT
            }
        }
    }

    public private(set) weak var app: TerminalApp?
    private(set) var surface: ghostty_surface_t?

    /// The title the program set (OSC 0/2), or empty.
    public private(set) var title = ""
    /// The shell's working directory, when shell integration or OSC 7 reports it.
    public private(set) var workingDirectory: String?
    /// True after the bell rang while this terminal wasn't focused; cleared on focus.
    public private(set) var bell = false
    public private(set) var focused = false
    /// The URL under the pointer while ⌘ is held, if any.
    public private(set) var hoveredLink: String?

    /// Called when `title`, `workingDirectory`, `bell` or `hoveredLink` change.
    public var onChange: (() -> Void)?
    /// Called when this terminal gains keyboard focus.
    public var onFocus: (() -> Void)?

    private var cursor: NSCursor = .iBeam
    private var cellSize: CGSize = .zero
    private var markedText = NSMutableAttributedString()
    /// Non-nil while handling a keyDown: text the input method committed during it.
    private var keyTextAccumulator: [String]?
    /// See performKeyEquivalent.
    private var lastPerformKeyEvent: TimeInterval?

    public init(app: TerminalApp, options: Options = Options(), context: Context = .window) throws {
        self.app = app
        // Non-zero so the renderer has something to draw into before the first layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = options.fontSize ?? 0
        config.context = context.ghostty

        // The C strings only need to live for the duration of ghostty_surface_new.
        let surface = options.workingDirectory.withOptionalCString { directory in
            options.command.withOptionalCString { command in
                config.working_directory = directory
                config.command = command
                return ghostty_surface_new(app.app, &config)
            }
        }
        guard let surface else { throw TerminalError.surfaceFailed }
        self.surface = surface

        updateTrackingAreas()
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    static func from(_ userdata: UnsafeMutableRawPointer) -> TerminalSurfaceView {
        Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// The options a new terminal opened from this one should start with: its directory and
    /// font size.
    public func inheritedOptions(for context: Context) -> Options {
        guard let surface else { return Options() }
        let config = ghostty_surface_inherited_config(surface, context.ghostty)
        return Options(
            workingDirectory: config.working_directory.map { String(cString: $0) },
            fontSize: config.font_size == 0 ? nil : config.font_size)
    }

    /// True when closing would kill a running program, so the user should confirm.
    public var needsConfirmQuit: Bool {
        surface.map(ghostty_surface_needs_confirm_quit) ?? false
    }

    /// Ask libghostty to close this terminal; it answers through the delegate's closeSurface.
    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    /// Run a Ghostty key binding action by name, like `copy_to_clipboard` or `increase_font_size:1`.
    @discardableResult
    public func perform(binding action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Handle the actions that only concern this view. Returns true if handled.
    func handle(_ action: TerminalAction) -> Bool {
        switch action {
        case .setTitle(let title):
            self.title = title
            onChange?()
        case .pwd(let directory):
            workingDirectory = directory
            onChange?()
        case .ringBell:
            if !focused || !(window?.isKeyWindow ?? false) {
                bell = true
                onChange?()
            }
            return false // The host may also want to show it.
        case .mouseShape(let shape):
            cursor = NSCursor(shape)
            window?.invalidateCursorRects(for: self)
        case .mouseVisible(let visible):
            NSCursor.setHiddenUntilMouseMoves(!visible)
        case .mouseOverLink(let url):
            hoveredLink = url
            onChange?()
        case .cellSize(let width, let height):
            cellSize = CGSize(width: Double(width) / backingScale, height: Double(height) / backingScale)
        case .rendererHealthy(let healthy):
            if !healthy { logger.warning("terminal renderer reported unhealthy") }
        default:
            return false
        }
        return true
    }

    private var backingScale: Double {
        Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - Size, screen and visibility

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { false }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let size = convertToBacking(bounds.size)
        guard size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // The renderer draws at the right scale itself; stop Core Animation rescaling it.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface else { return }
        let backing = convertToBacking(bounds)
        if bounds.width > 0, bounds.height > 0 {
            ghostty_surface_set_content_scale(surface, backing.width / bounds.width, backing.height / bounds.height)
        }
        updateSurfaceSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(windowDidChangeScreen), name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(
            self, selector: #selector(windowDidChangeOcclusion), name: NSWindow.didChangeOcclusionStateNotification,
            object: window)
        windowDidChangeScreen()
        windowDidChangeOcclusion()
        viewDidChangeBackingProperties()
    }

    /// The renderer syncs frames to the display the window is on.
    @objc private func windowDidChangeScreen() {
        guard let surface,
              let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    /// A hidden window's terminals stop rendering until it's visible again.
    @objc private func windowDidChangeOcclusion() {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    // MARK: - Focus

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ focused: Bool) {
        guard self.focused != focused else { return }
        self.focused = focused
        if let surface { ghostty_surface_set_focus(surface, focused) }
        if focused {
            if bell {
                bell = false
                onChange?()
            }
            onFocus?()
        }
    }

    // MARK: - Mouse

    public override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    public override func mouseDown(with event: NSEvent) {
        if !focused { window?.makeFirstResponder(self) }
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    public override func mouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseDown(with: event)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseUp(with: event)
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber), event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber), event)
    }

    @discardableResult
    private func sendButton(
        _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private static func button(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_EIGHT
        case 8: GHOSTTY_MOUSE_NINE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        // While dragging, the drag events keep reporting the position.
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        // A negative position tells libghostty the pointer left.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // libghostty's origin is the top left.
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }

    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Trackpad deltas feel slow 1:1; Ghostty doubles them too.
            x *= 2
            y *= 2
        }
        // Packed scroll mods: bit 0 is "precise", bits 1-3 the momentum phase.
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Settings like option-as-alt change which modifiers take part in producing text.
        let translationGhostty = Self.flags(
            ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // The original event must be reused when nothing changed: some input methods (Korean)
        // depend on its identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // interpretKeyEvents runs the input method, which may commit text through insertText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // The key switched the keyboard layout (an input source shortcut): not for the terminal.
        if !markedTextBefore && layoutBefore != Self.keyboardLayoutID {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            // Composing if there's preedit now, or there was and this key ended it (then the key
            // only cancels the composition and mustn't reach the program).
            let composing = markedText.length > 0 || markedTextBefore
            sendKey(action, event: event, translationEvent: translationEvent,
                    text: translationEvent.terminalCharacters, composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Pressed, unless it's the other side's key going up while this side stays down.
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        sendKey(action, event: event)
    }

    /// AppKit offers ⌘ and ⌃ key combinations here before keyDown. Ghostty key bindings (⌘D,
    /// ⌘T, ⌘C…) are handled now; other ⌃ combinations go on to keyDown so the program gets them.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        var flags = ghostty_binding_flags_e(0)
        var keyEvent = event.terminalKeyEvent(GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // ⌃Return goes to the program rather than AppKit's default button.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ⌃/ makes macOS beep; send it as ⌃_ like other terminals.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            // AppKit sometimes synthesizes events with no timestamp; leave those alone.
            if event.timestamp == 0 { return false }
            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }
            // Give the menu a chance first. If nothing handles it, AppKit offers it again (see
            // doCommand), and then it goes to the program.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode)
        else { return false }
        keyDown(with: finalEvent)
        return true
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = event.terminalKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        guard let text, !text.isEmpty else {
            return ghostty_surface_key(surface, keyEvent)
        }
        return text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    nonisolated static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    nonisolated static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
        return flags
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) { perform(binding: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(binding: "paste_from_clipboard") }
    @objc func pasteAsPlainText(_ sender: Any?) { perform(binding: "paste_from_clipboard") }
    public override func selectAll(_ sender: Any?) { perform(binding: "select_all") }

    // MARK: - Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface, let text = sender.draggingPasteboard.terminalString, !text.isEmpty else { return false }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        return true
    }
}

// MARK: - Text input (IME)

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // Outside a keyDown (say the layout changed mid-composition), show it now.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    public func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// Where the input method should show its candidate window: at the cursor.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0
        var width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += Double(cellSize.width) * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, Double(cellSize.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }

        unmarkText()

        // During keyDown the text goes out with the key event.
        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
            return
        }

        // Otherwise (dictation, the character viewer) send it as typed text.
        guard let surface, !text.isEmpty else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { pointer in
            keyEvent.text = pointer
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Keeps AppKit from beeping for commands we don't implement, and sends back ⌘ keys that
    /// performKeyEquivalent passed on but nothing handled.
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}

// MARK: - Helpers

extension NSEvent {
    /// A libghostty key event for this event, without text (the caller adds that).
    func terminalKeyEvent(
        _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = TerminalSurfaceView.mods(modifierFlags)
        // ⌃ and ⌘ never take part in producing text; assume everything else did.
        keyEvent.consumed_mods = TerminalSurfaceView.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let characters = characters(byApplyingModifiers: []),
           let scalar = characters.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    /// The text to send with a key: control characters without ⌃ (libghostty encodes those
    /// itself), and nothing for function keys, which macOS reports in the private-use area.
    var terminalCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

extension NSCursor {
    convenience init(_ shape: TerminalAction.MouseShape) {
        let cursor: NSCursor = switch shape {
        case .default: .arrow
        case .text: .iBeam
        case .verticalText: .iBeamCursorForVerticalLayout
        case .pointer: .pointingHand
        case .crosshair: .crosshair
        case .notAllowed: .operationNotAllowed
        case .grab: .openHand
        case .grabbing: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .contextMenu: .contextualMenu
        case .copy: .dragCopy
        case .alias: .dragLink
        }
        self.init(image: cursor.image, hotSpot: cursor.hotSpot)
    }
}

extension Optional where Wrapped == String {
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        switch self {
        case .some(let string): string.withCString(body)
        case .none: body(nil)
        }
    }
}
