import AppKit
import ApplicationServices

/// Errors from the OS text-injection path.
enum TextInjectionError: LocalizedError {
    case emptyText
    case accessibilityNotTrusted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "There is no text to insert."
        case .accessibilityNotTrusted:
            return "Accessibility access is required to paste into other apps. Enable it in System Settings and relaunch."
        case .eventCreationFailed:
            return "Could not synthesize the paste keystroke."
        }
    }
}

/// Injects finished text into whatever app currently has keyboard focus, without
/// permanently disturbing the user's clipboard.
///
/// Strategy (more reliable than pure Accessibility, which varies per app):
///   1. Snapshot the general pasteboard.
///   2. Write our text to it.
///   3. Synthesize ⌘V via `CGEvent` and post it to the HID event tap.
///   4. Wait briefly for the target app to consume the paste.
///   5. Restore the original pasteboard contents.
///
/// Marked `@MainActor`: `NSPasteboard` and event posting must run on the main thread.
@MainActor
final class TextInjector {

    static let shared = TextInjector()
    private init() {}

    private let pasteboard = NSPasteboard.general

    /// How long to wait after posting ⌘V before restoring the clipboard.
    /// Restoring synchronously would race the target app and paste the *old*
    /// contents — the delay must be asynchronous. 120 ms is a safe default that
    /// also covers slower apps.
    private let pasteSettleNanoseconds: UInt64 = 120_000_000

    // Virtual key codes (Carbon `kVK_*`).
    private let keyV: CGKeyCode = 0x09      // kVK_ANSI_V
    private let keyCommand: CGKeyCode = 0x37 // kVK_Command

    /// Inserts `text` at the current cursor location, then restores the clipboard.
    func inject(_ text: String) async throws {
        guard !text.isEmpty else { throw TextInjectionError.emptyText }

        // CGEvent posting silently no-ops without Accessibility trust – fail loudly.
        guard AXIsProcessTrusted() else { throw TextInjectionError.accessibilityNotTrusted }

        let saved = ClipboardState.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        do {
            try synthesizePaste()
        } catch {
            // Roll back the clipboard even if the keystroke failed.
            saved.restore(to: pasteboard)
            throw error
        }

        // Give the frontmost app time to process ⌘V before we put the old data back.
        try? await Task.sleep(nanoseconds: pasteSettleNanoseconds)

        saved.restore(to: pasteboard)
    }

    // MARK: – Keystroke synthesis

    /// Posts Command↓, V↓, V↑, Command↑ to the system HID event tap.
    private func synthesizePaste() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInjectionError.eventCreationFailed
        }

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCommand, keyDown: true),
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCommand, keyDown: false)
        else {
            throw TextInjectionError.eventCreationFailed
        }

        // V events must carry the Command modifier so the target sees ⌘V, not "v".
        vDown.flags = .maskCommand
        vUp.flags   = .maskCommand

        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
    }
}
