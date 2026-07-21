import AppKit

/// An in-memory snapshot of the general pasteboard, taken before OmniScribe
/// overwrites it with generated text and restored immediately after pasting.
///
/// Each `NSPasteboardItem` is deep-copied (every representation type + its data)
/// rather than retained by reference: items read from the live pasteboard cannot
/// be reliably re-added, so we rebuild fresh items that `writeObjects` accepts.
/// This preserves text, images, and file references alike.
struct ClipboardState {

    private let items: [NSPasteboardItem]

    /// Captures the current contents of `pasteboard`.
    static func capture(from pasteboard: NSPasteboard) -> ClipboardState {
        let copies: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return ClipboardState(items: copies)
    }

    /// Restores the captured contents back onto `pasteboard`, replacing whatever
    /// OmniScribe temporarily wrote there.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        // Nothing was on the clipboard originally – leaving it cleared is correct.
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
