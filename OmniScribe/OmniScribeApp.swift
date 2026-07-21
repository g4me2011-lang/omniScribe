import SwiftUI
import AppKit

/// Application entry point.
///
/// OmniScribe is a *Menu Bar only* app – no Dock icon, no windows.
/// All lifecycle logic lives in `AppDelegate`; this struct satisfies
/// the SwiftUI `App` protocol requirement and wires up the delegate.
@main
struct OmniScribeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // A hidden Settings scene prevents the "no scene" runtime warning
        // while keeping the window count at zero. The real UI is the status
        // item menu built in MenuBarManager.
        Settings {
            EmptyView()
        }
    }
}
