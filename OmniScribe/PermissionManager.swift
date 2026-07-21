import AppKit
import AVFoundation

/// Checks and requests Microphone and Accessibility permissions.
///
/// - Marked `@MainActor` because every permission callback and `NSAlert`
///   must run on the main thread.
/// - Does NOT poll; each check is a single async call or a one-shot query.
@MainActor
final class PermissionManager {

    // MARK: – Public entry point

    /// Requests Microphone access, then surfaces the Accessibility prompt if needed.
    /// Returns after both flows complete (regardless of outcome).
    func requestAllPermissions() async {
        await requestMicrophonePermission()
        checkAccessibilityPermission()
    }

    // MARK: – Microphone

    func requestMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return  // Already granted – nothing to do.

        case .notDetermined:
            // Single async call; macOS shows its own system dialog.
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { showAlert(for: .microphoneDenied) }

        case .denied, .restricted:
            showAlert(for: .microphoneDenied)

        @unknown default:
            break
        }
    }

    // MARK: – Accessibility

    /// Returns whether the process currently has Accessibility trust.
    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    func checkAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }

        // Trigger the macOS "Add to Accessibility" system sheet.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // Show our own informative alert in addition to the system one.
        showAlert(for: .accessibilityDenied)
    }

    // MARK: – Alert helpers

    private enum PermissionKind {
        case microphoneDenied
        case accessibilityDenied

        var title: String {
            switch self {
            case .microphoneDenied:    return "Microphone Access Required"
            case .accessibilityDenied: return "Accessibility Access Required"
            }
        }

        var message: String {
            switch self {
            case .microphoneDenied:
                return """
                OmniScribe needs microphone access to record your voice.

                Please enable it in System Settings \u{2192} Privacy & Security \u{2192} Microphone.
                """
            case .accessibilityDenied:
                return """
                OmniScribe needs Accessibility access to inject transcribed text \
                into other apps.

                Please enable it in System Settings \u{2192} Privacy & Security \u{2192} \
                Accessibility, then relaunch OmniScribe.
                """
            }
        }

        var settingsKey: String {
            switch self {
            case .microphoneDenied:    return "Privacy_Microphone"
            case .accessibilityDenied: return "Privacy_Accessibility"
            }
        }
    }

    private func showAlert(for kind: PermissionKind) {
        let alert = NSAlert()
        alert.messageText     = kind.title
        alert.informativeText = kind.message
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings(key: kind.settingsKey)
        }
    }

    private func openSystemSettings(key: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(key)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
