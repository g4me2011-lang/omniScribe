import AppKit
import ApplicationServices

/// Installs a global `CGEventTap` that intercepts **Option + Space** system-wide.
///
/// Design decisions:
/// - Uses `CGEventTap` (not `NSEvent.addGlobalMonitorForEvents`) so the event
///   can be *consumed* (return `nil`) and never reaches the focused application.
/// - The tap callback is a bare C function pointer; `self` is threaded through
///   via `userInfo` using `Unmanaged` to avoid a retain cycle.
/// - Weak references to `MenuBarManager` prevent a retain cycle if the manager
///   is ever deallocated.
/// - If the system disables the tap after a timeout, it is automatically re-enabled.
final class HotkeyManager {

    /// Invoked on the main queue every time ⌥Space is pressed. The coordinator
    /// decides what to do (start vs. stop dictation) so this class stays a pure
    /// input source with no knowledge of the audio pipeline.
    private let onTrigger: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: – Init / Deinit

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        install()
    }

    deinit {
        uninstall()
    }

    // MARK: – Install

    private func install() {
        guard AXIsProcessTrusted() else {
            print("[HotkeyManager] ⚠️  Accessibility not granted – event tap NOT installed. " +
                  "Grant access in System Settings and relaunch.")
            return
        }

        // Listen only to keyDown events to keep the tap as lightweight as possible.
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        // The callback must be a C-compatible function pointer (no Swift captures).
        // We pass `self` via `userInfo` instead.
        let callback: CGEventTapCallBack = { _, type, event, userInfo -> Unmanaged<CGEvent>? in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,        // Session-level: fires for every app.
            place: .headInsertEventTap,     // First to see the event.
            options: .defaultTap,           // Can modify/consume events.
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            print("[HotkeyManager] ❌ CGEvent tap creation failed. " +
                  "Accessibility permission is required.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[HotkeyManager] ✅ Global hotkey ⌥Space registered.")
    }

    // MARK: – Uninstall

    private func uninstall() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        print("[HotkeyManager] Global hotkey ⌥Space unregistered.")
    }

    // MARK: – Event Handling

    /// Decides whether to consume or pass through each keyboard event.
    /// Returns `nil` to consume (swallow) the event, or the original event to let it through.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that take too long. Re-enable and bail.
        if type == .tapDisabledByTimeout {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags

        // kVK_Space = 0x31 = 49
        let isSpace = keyCode == 49

        // Option pressed, but NOT Command / Control / Shift (avoids conflicts with
        // system shortcuts that use ⌥Space as a component, e.g. Input Source switching).
        let isOptionOnly = flags.contains(.maskAlternate)
                        && !flags.contains(.maskCommand)
                        && !flags.contains(.maskControl)
                        && !flags.contains(.maskShift)

        guard isSpace && isOptionOnly else {
            return Unmanaged.passRetained(event)  // Not our shortcut – pass through.
        }

        // Dispatch UI work to main. The callback may arrive on a background thread.
        DispatchQueue.main.async { [weak self] in
            self?.didTriggerHotkey()
        }

        return nil  // Consume the event so the focused app never sees it.
    }

    // MARK: – Hotkey Action

    private func didTriggerHotkey() {
        print("[HotkeyManager] 🎤 ⌥Space triggered")
        onTrigger()
    }
}
