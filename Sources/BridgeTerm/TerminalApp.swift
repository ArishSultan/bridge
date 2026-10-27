import AppKit
import GhosttyKit
import os
import UniformTypeIdentifiers

let logger = Logger(subsystem: "dev.arish.bridge", category: "terminal")

/// Owns the libghostty app: the shared configuration and the runtime callbacks every terminal
/// surface reports through. Create one per process, on the main thread.
///
/// Each `TerminalSurfaceView` made from it runs its own pty, I/O thread and Metal renderer, so a
/// busy terminal never holds up the others or the UI.
@MainActor
public final class TerminalApp {
    /// Receives the actions libghostty asks the host app to perform (split, close, set title…).
    public weak var delegate: TerminalAppDelegate?

    let app: ghostty_app_t
    private var config: TerminalConfiguration

    private static var initialized = false

    /// Start libghostty with a configuration in Ghostty's `key = value` file syntax.
    public init(configuration text: String) throws {
        if !Self.initialized {
            Self.useBundledResources()
            guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
                throw TerminalError.initFailed
            }
            Self.initialized = true
        }

        config = try TerminalConfiguration(text)

        // The callbacks find this object again through the userdata pointer, which is retained
        // for the life of the process.
        let box = WeakBox()
        var runtime = Self.runtimeConfig(userdata: Unmanaged.passRetained(box).toOpaque())
        guard let app = ghostty_app_new(&runtime, config.config) else {
            throw TerminalError.initFailed
        }
        self.app = app
        box.app = self
        ghostty_app_set_focus(app, NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { ghostty_app_set_focus($0.app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { ghostty_app_set_focus($0.app, false) } }
        }
        // libghostty reloads its keyboard layout mapping when the input source changes.
        center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self.map { ghostty_app_keyboard_changed($0.app) } }
        }
    }

    /// Apply a new configuration to the app and every open terminal.
    public func update(configuration text: String) {
        do {
            let new = try TerminalConfiguration(text)
            ghostty_app_update_config(app, new.config)
            config = new
        } catch {
            logger.error("invalid terminal configuration: \(String(describing: error), privacy: .public)")
        }
    }

    /// Tell libghostty whether the system is in light or dark mode.
    public func setColorScheme(dark: Bool) {
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// True when quitting would kill a running program, so the user should confirm.
    public var needsConfirmQuit: Bool {
        ghostty_app_needs_confirm_quit(app)
    }

    func tick() {
        ghostty_app_tick(app)
    }

    /// Ghostty's resources folder (themes, terminfo, shell integration): in the app bundle, or
    /// vendor/share when running from a build folder.
    public static var resourcesDirectory: URL? {
        useBundledResources()
        if let bundled = Bundle.main.url(forResource: "ghostty", withExtension: nil) { return bundled }
        return getenv("GHOSTTY_RESOURCES_DIR").map { URL(fileURLWithPath: String(cString: $0)) }
    }

    /// libghostty finds terminfo and its shell integration scripts in its resources folder.
    /// In the app bundle that's Contents/Resources/ghostty, which it finds itself; when running
    /// from a build folder, point it at vendor/share.
    private static func useBundledResources() {
        if Bundle.main.url(forResource: "ghostty", withExtension: nil) != nil { return }
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while dir.path != "/" {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("vendor/share/ghostty")
            if FileManager.default.fileExists(atPath: candidate.path) {
                setenv("GHOSTTY_RESOURCES_DIR", candidate.path, 1)
                return
            }
        }
    }

    // MARK: - Callbacks

    /// The callbacks hold this instead of the app, which may not exist yet when the first one
    /// arrives.
    private final class WeakBox {
        weak var app: TerminalApp?
    }

    /// The callbacks libghostty calls. They're made here, outside the main actor, because some
    /// arrive on libghostty's own threads (the renderer's, the pty reader's): closures written in
    /// a main-actor context would trap there.
    private nonisolated static func runtimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in TerminalApp.wakeup(userdata) },
            action_cb: { app, target, action in TerminalApp.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state in
                TerminalApp.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, text, state, request in
                TerminalApp.confirmReadClipboard(userdata, text: text, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, count, confirm in
                TerminalApp.writeClipboard(userdata, location: location, content: content, count: count, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                TerminalApp.closeSurface(userdata, processAlive: processAlive)
            })
    }

    private nonisolated static func appFrom(_ userdata: UnsafeMutableRawPointer?) -> WeakBox? {
        guard let userdata else { return nil }
        return Unmanaged<WeakBox>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Run `body` on the main thread: right away if already there, otherwise later.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        // Called from any thread when libghostty has work for the main thread.
        nonisolated(unsafe) let pointer = userdata
        DispatchQueue.main.async {
            appFrom(pointer)?.app?.tick()
        }
    }

    private nonisolated static func action(
        _ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s
    ) -> Bool {
        guard let app, let userdata = ghostty_app_userdata(app) else { return false }
        // Copy what the action points to now: the pointers are only valid during this call.
        guard let converted = TerminalAction(action) else { return false }

        var surfacePointer: UnsafeMutableRawPointer?
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            surfacePointer = ghostty_surface_userdata(surface)
        }
        nonisolated(unsafe) let surfaceUserdata = surfacePointer
        nonisolated(unsafe) let appUserdata = userdata

        // Actions arrive on the main thread (from a tick or a key press), where the result can
        // be returned. Anything else is delivered asynchronously and reported as handled.
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                guard let terminalApp = appFrom(appUserdata)?.app else { return }
                let surface = surfaceUserdata.map(TerminalSurfaceView.from)
                _ = terminalApp.perform(converted, surface: surface)
            }
            return true
        }
        return MainActor.assumeIsolated {
            guard let terminalApp = appFrom(appUserdata)?.app else { return false }
            let surface = surfaceUserdata.map(TerminalSurfaceView.from)
            return terminalApp.perform(converted, surface: surface)
        }
    }

    private func perform(_ action: TerminalAction, surface: TerminalSurfaceView?) -> Bool {
        // Some actions only concern the surface view itself.
        if let surface, surface.handle(action) {
            return true
        }
        return delegate?.terminalApp(self, perform: action, surface: surface) ?? false
    }

    private nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?
    ) -> Bool {
        // Reads come from a paste binding or a program request, both handled on the main thread.
        guard let userdata, Thread.isMainThread else { return false }
        nonisolated(unsafe) let pointer = userdata
        nonisolated(unsafe) let state = state
        return MainActor.assumeIsolated {
            let view = TerminalSurfaceView.from(pointer)
            guard let surface = view.surface,
                  let text = NSPasteboard.terminal(location)?.terminalString
            else { return false }
            text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
    }

    private nonisolated static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        text: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let text else { return }
        let string = String(cString: text)
        nonisolated(unsafe) let pointer = userdata
        nonisolated(unsafe) let state = state
        // Asked later, never inside this call: a modal prompt runs the main loop, which would
        // call into libghostty while it is still in the middle of this request.
        onMain {
            // Held until the prompt is answered, so the surface outlives the request.
            let view = TerminalSurfaceView.from(pointer)
            DispatchQueue.main.async {
                let confirmed = ClipboardPrompt.confirm(
                    request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? .paste : .programRead,
                    text: string, window: view.window)
                guard let surface = view.surface else { return }
                // Completing with confirmed = true sends the text; an empty string sends nothing.
                (confirmed ? string : "").withCString {
                    ghostty_surface_complete_clipboard_request(surface, $0, state, true)
                }
            }
        }
    }

    /// The most a program may put on the clipboard (OSC 52).
    static let maxProgramClipboard = 1 << 20

    private nonisolated static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let userdata, let content, count > 0 else { return }
        var items: [(mime: String, data: String)] = []
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime, let data = item.data else { continue }
            items.append((String(cString: mime), String(cString: data)))
        }
        guard !items.isEmpty else { return }
        nonisolated(unsafe) let pointer = userdata
        onMain {
            guard let pasteboard = NSPasteboard.terminal(location) else { return }
            if confirm {
                // A program asked to set the clipboard (OSC 52; the config asks Bridge every
                // time, so a copy by the user never comes here). Allowed per terminal: a
                // sandboxed one can't, unless its sandbox allows the clipboard.
                let view = TerminalSurfaceView.from(pointer)
                guard view.allowsProgramClipboardWrite,
                      let text = items.first(where: { $0.mime == "text/plain" })?.data,
                      text.utf8.count <= maxProgramClipboard
                else { return }
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(text, forType: .string)
                return
            }
            let types = items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }
            pasteboard.declareTypes(types, owner: nil)
            for item in items {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setString(item.data, forType: type)
            }
        }
    }

    private nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata else { return }
        nonisolated(unsafe) let pointer = userdata
        onMain {
            let view = TerminalSurfaceView.from(pointer)
            guard let app = view.app else { return }
            app.delegate?.terminalApp(app, closeSurface: view, processAlive: processAlive)
        }
    }
}

@MainActor
public protocol TerminalAppDelegate: AnyObject {
    /// Perform an action libghostty requested, for a surface or (when nil) the whole app.
    /// Return false when it doesn't apply, so a key binding can fall through to the program.
    func terminalApp(_ app: TerminalApp, perform action: TerminalAction, surface: TerminalSurfaceView?) -> Bool

    /// A surface wants to close (its program exited, or the user asked). When `processAlive` is
    /// true a program is still running and the user should confirm.
    func terminalApp(_ app: TerminalApp, closeSurface surface: TerminalSurfaceView, processAlive: Bool)
}

public enum TerminalError: Error {
    case initFailed
    case surfaceFailed
}

/// A finalized libghostty configuration.
final class TerminalConfiguration {
    let config: ghostty_config_t

    init(_ text: String) throws {
        guard let config = ghostty_config_new() else { throw TerminalError.initFailed }
        self.config = config

        // libghostty loads configuration from files, so write the text to a private one.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-terminal-\(UUID().uuidString).conf")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        ghostty_config_load_file(config, url.path)
        ghostty_config_finalize(config)

        for index in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            if let message = diagnostic.message {
                logger.warning("terminal config: \(String(cString: message), privacy: .public)")
            }
        }
    }

    deinit {
        ghostty_config_free(config)
    }
}

extension NSPasteboard {
    /// The pasteboard for a libghostty clipboard. The selection clipboard (filled on select, read
    /// by middle-click) is a private named pasteboard, as macOS has none of its own.
    static func terminal(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: .general
        case GHOSTTY_CLIPBOARD_SELECTION: NSPasteboard(name: .init("dev.arish.bridge.selection"))
        default: nil
        }
    }

    /// Text to paste: file URLs become their (shell-escaped) paths, otherwise the plain string.
    var terminalString: String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        return string(forType: .string)
    }
}

/// Escape a path for a POSIX shell by backslash-escaping its special characters.
func shellEscape(_ text: String) -> String {
    let special = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")
    return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
}

extension NSPasteboard.PasteboardType {
    /// The pasteboard type for a MIME type libghostty uses when writing the clipboard.
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain": self = .string
        case "text/html": self = .html
        default:
            guard let type = UTType(mimeType: mimeType) else { return nil }
            self.init(type.identifier)
        }
    }
}
