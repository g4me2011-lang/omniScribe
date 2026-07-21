import AppKit

/// A borderless, non-activating floating panel that hosts the recording HUD.
///
/// The critical contract: it must **never** become key or main, so it cannot
/// steal keyboard focus from the app the user is dictating into. `canBecomeKey`
/// is hard-`false`; the panel is shown with `orderFrontRegardless()` (not
/// `makeKeyAndOrderFront`) and ignores mouse events entirely.
final class HUDPanel: NSPanel {

    init(contentView: NSView) {
        super.init(
            contentRect: contentView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Transparent chrome so only the SwiftUI capsule shows.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // The SwiftUI view draws its own shadow.

        // Never interfere with the workspace.
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        worksWhenModal = false

        self.contentView = contentView
    }

    // Hard guarantees against focus theft.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
