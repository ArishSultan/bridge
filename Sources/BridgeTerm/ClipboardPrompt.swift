import AppKit

/// Asks the user before a risky clipboard operation: pasting text that could run commands, or a
/// program reading or setting the clipboard (OSC 52).
@MainActor
enum ClipboardPrompt {
    enum Kind {
        case paste, programRead, programWrite
    }

    static func confirm(_ kind: Kind, text: String, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        switch kind {
        case .paste:
            alert.messageText = "Paste this text?"
            alert.informativeText = "It contains line breaks or control characters, so it may run commands as soon as it's pasted."
            alert.addButton(withTitle: "Paste")
        case .programRead:
            alert.messageText = "Let the program read the clipboard?"
            alert.informativeText = "A program in this terminal asked for the clipboard's contents."
            alert.addButton(withTitle: "Allow")
        case .programWrite:
            alert.messageText = "Let the program set the clipboard?"
            alert.informativeText = "A program in this terminal wants to copy this text to the clipboard."
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")

        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        preview.string = text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
        preview.isEditable = false
        preview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let scroll = NSScrollView(frame: preview.frame)
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll

        return alert.runModal() == .alertFirstButtonReturn
    }
}
