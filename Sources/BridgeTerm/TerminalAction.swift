import GhosttyKit

/// An action libghostty asks the host to perform, copied out of the C structure so it can be
/// handled after the callback returns. Only the actions Bridge handles are represented.
public enum TerminalAction: Sendable {
    case quit
    case newWindow
    case newTab
    case closeTab(CloseTabMode)
    case closeWindow
    case closeAllWindows
    case newSplit(SplitSide)
    case gotoSplit(SplitFocus)
    case resizeSplit(SplitSide, amount: UInt16)
    case equalizeSplits
    case toggleSplitZoom
    /// A tab index from 0, or one of the `TabTarget` cases.
    case gotoTab(TabTarget)
    case moveTab(Int)
    case toggleFullscreen
    case setTitle(String)
    case pwd(String)
    case ringBell
    case mouseShape(MouseShape)
    case mouseVisible(Bool)
    case mouseOverLink(String?)
    case openURL(String)
    case openConfig
    case desktopNotification(title: String, body: String)
    case childExited(exitCode: UInt32)
    case commandFinished(exitCode: Int?, seconds: Double)
    case cellSize(width: UInt32, height: UInt32)
    case rendererHealthy(Bool)
    case secureInput(SecureInput)
    /// Scrollback search opened (with what to look for), closed, and its results.
    case startSearch(needle: String)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)

    public enum SplitSide: Sendable {
        case right, down, left, up
    }

    public enum SplitFocus: Sendable {
        case previous, next, up, down, left, right
    }

    public enum TabTarget: Sendable, Equatable {
        case previous, next, last
        case index(Int)
    }

    public enum CloseTabMode: Sendable {
        case this, others, right
    }

    public enum SecureInput: Sendable {
        case on, off, toggle
    }

    /// The pointer shape a program asked for (only the ones AppKit has cursors for).
    public enum MouseShape: Sendable {
        case `default`, text, pointer, crosshair, notAllowed, grab, grabbing
        case resizeLeftRight, resizeUpDown
        case verticalText, contextMenu, copy, alias
    }

    init?(_ action: ghostty_action_s) {
        let value = action.action
        switch action.tag {
        case GHOSTTY_ACTION_QUIT: self = .quit
        case GHOSTTY_ACTION_NEW_WINDOW: self = .newWindow
        case GHOSTTY_ACTION_NEW_TAB: self = .newTab
        case GHOSTTY_ACTION_CLOSE_TAB:
            switch value.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: self = .closeTab(.others)
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: self = .closeTab(.right)
            default: self = .closeTab(.this)
            }
        case GHOSTTY_ACTION_CLOSE_WINDOW: self = .closeWindow
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: self = .closeAllWindows
        case GHOSTTY_ACTION_NEW_SPLIT:
            switch value.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .newSplit(.down)
            case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .newSplit(.left)
            case GHOSTTY_SPLIT_DIRECTION_UP: self = .newSplit(.up)
            default: self = .newSplit(.right)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            switch value.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: self = .gotoSplit(.previous)
            case GHOSTTY_GOTO_SPLIT_NEXT: self = .gotoSplit(.next)
            case GHOSTTY_GOTO_SPLIT_UP: self = .gotoSplit(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: self = .gotoSplit(.down)
            case GHOSTTY_GOTO_SPLIT_LEFT: self = .gotoSplit(.left)
            case GHOSTTY_GOTO_SPLIT_RIGHT: self = .gotoSplit(.right)
            default: return nil
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = value.resize_split
            let side: SplitSide = switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: .left
            default: .right
            }
            self = .resizeSplit(side, amount: resize.amount)
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: self = .equalizeSplits
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: self = .toggleSplitZoom
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = value.goto_tab.rawValue
            switch raw {
            case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: self = .gotoTab(.previous)
            case GHOSTTY_GOTO_TAB_NEXT.rawValue: self = .gotoTab(.next)
            case GHOSTTY_GOTO_TAB_LAST.rawValue: self = .gotoTab(.last)
            default: self = .gotoTab(.index(Int(raw)))
            }
        case GHOSTTY_ACTION_MOVE_TAB: self = .moveTab(Int(value.move_tab.amount))
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: self = .toggleFullscreen
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = value.set_title.title else { return nil }
            self = .setTitle(String(cString: title))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = value.pwd.pwd else { return nil }
            self = .pwd(String(cString: pwd))
        case GHOSTTY_ACTION_RING_BELL: self = .ringBell
        case GHOSTTY_ACTION_MOUSE_SHAPE: self = .mouseShape(MouseShape(value.mouse_shape))
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            self = .mouseVisible(value.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = value.mouse_over_link
            if let url = link.url, link.len > 0 {
                let bytes = UnsafeRawBufferPointer(start: url, count: Int(link.len))
                self = .mouseOverLink(String(decoding: bytes, as: UTF8.self))
            } else {
                self = .mouseOverLink(nil)
            }
        case GHOSTTY_ACTION_OPEN_URL:
            let open = value.open_url
            guard let url = open.url else { return nil }
            let bytes = UnsafeRawBufferPointer(start: url, count: Int(open.len))
            self = .openURL(String(decoding: bytes, as: UTF8.self))
        case GHOSTTY_ACTION_OPEN_CONFIG: self = .openConfig
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = value.desktop_notification
            self = .desktopNotification(
                title: note.title.map { String(cString: $0) } ?? "",
                body: note.body.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            self = .childExited(exitCode: value.child_exited.exit_code)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = value.command_finished
            self = .commandFinished(
                exitCode: finished.exit_code < 0 ? nil : Int(finished.exit_code),
                seconds: Double(finished.duration) / 1_000_000_000)
        case GHOSTTY_ACTION_CELL_SIZE:
            self = .cellSize(width: value.cell_size.width, height: value.cell_size.height)
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            self = .rendererHealthy(value.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
        case GHOSTTY_ACTION_SECURE_INPUT:
            switch value.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: self = .secureInput(.on)
            case GHOSTTY_SECURE_INPUT_OFF: self = .secureInput(.off)
            default: self = .secureInput(.toggle)
            }
        case GHOSTTY_ACTION_START_SEARCH:
            self = .startSearch(needle: value.start_search.needle.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_END_SEARCH:
            self = .endSearch
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            self = .searchTotal(value.search_total.total < 0 ? nil : Int(value.search_total.total))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            self = .searchSelected(value.search_selected.selected < 0 ? nil : Int(value.search_selected.selected))
        default:
            return nil
        }
    }
}

extension TerminalAction.MouseShape {
    init(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: self = .text
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: self = .verticalText
        case GHOSTTY_MOUSE_SHAPE_POINTER: self = .pointer
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: self = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: self = .notAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: self = .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING: self = .grabbing
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE: self = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: self = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: self = .contextMenu
        case GHOSTTY_MOUSE_SHAPE_COPY: self = .copy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: self = .alias
        default: self = .default
        }
    }
}
