import AppKit

/// Central application lifecycle manager and dictation coordinator.
///
/// Responsibilities:
/// - Force `.accessory` activation policy so the app never appears in the Dock.
/// - Instantiate and own all top-level services in the correct order.
/// - Preload the Whisper model at launch so the first hotkey press is instant.
/// - Orchestrate one dictation cycle: hotkey → record → (VAD silence or hotkey) →
///   stop → transcribe → deliver text.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references – these must live for the entire app lifetime.
    private var menuBarManager: MenuBarManager?
    private var permissionManager: PermissionManager?
    private var hotkeyManager: HotkeyManager?
    private var audioManager: AudioSessionManager?

    // Cloud STT (OpenAI Whisper) — supports Lithuanian and runs well on Intel
    // Macs, where Apple's Speech framework lacks Lithuanian and WhisperKit crashes.
    private let transcriptionService = CloudWhisperService()
    private let aiCoordinator = AILayerCoordinator.shared

    /// Guards against re-entrancy: the VAD timeout and a manual ⌥Space can both
    /// try to end the same recording.
    private var isDictating = false

    // MARK: – NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: LSUIElement in Info.plist hides the Dock icon
        // at launch, but setting .accessory here guarantees it programmatically.
        NSApp.setActivationPolicy(.accessory)

        // 1. Status item must exist before anything else updates its icon.
        let mbm = MenuBarManager()
        menuBarManager = mbm

        // 2. Audio pipeline. Wire its callbacks to the dictation coordinator.
        let audio = AudioSessionManager()
        audio.onSilenceDetected = { [weak self] in self?.finishDictation() }
        audio.onError = { [weak self] error in self?.handleAudioError(error) }
        audioManager = audio

        // 3. Preload the Whisper model now – NOT on the hotkey press – so the
        //    first dictation has zero model-load latency.
        Task { await transcriptionService.preloadModel() }

        // 4. Permissions – checked asynchronously so we never block the main thread.
        let pm = PermissionManager()
        permissionManager = pm

        Task { [weak self] in
            guard let self else { return }
            await pm.requestAllPermissions()

            // 5. Install global hotkey only after permission flow completes.
            //    HotkeyManager guards internally with AXIsProcessTrusted().
            self.hotkeyManager = HotkeyManager { [weak self] in
                self?.toggleDictation()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Never quit when (the non-existent) last window closes.
        return false
    }

    // MARK: – Dictation coordination

    private func toggleDictation() {
        if isDictating {
            finishDictation()
        } else {
            startDictation()
        }
    }

    private func startDictation() {
        guard !isDictating, let audioManager else { return }

        do {
            try audioManager.start()
            isDictating = true
            menuBarManager?.updateState(.listening)
            WindowManager.shared.showRecordingHUD(phase: .listening)
            print("[AppDelegate] 🎙️ Recording started.")
        } catch {
            print("[AppDelegate] ❌ Could not start recording: \(error.localizedDescription)")
            menuBarManager?.updateState(.idle)
        }
    }

    private func finishDictation() {
        guard isDictating, let audioManager else { return }
        isDictating = false

        let samples = audioManager.stop()
        menuBarManager?.updateState(.processing)
        WindowManager.shared.updateHUD(phase: .processing)
        print("[AppDelegate] ⏹️ Recording stopped – \(samples.count) samples captured.")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.transcriptionService.transcribe(samples: samples)
                print("[AppDelegate] 📝 Transcription (\(result.source.rawValue)): \"\(result.text)\"")

                // Phase 3: reshape the transcription with the selected AI provider.
                // Phase 4: inject the result into the focused app, preserving the
                // user's clipboard. A missing API key surfaces as a handled error.
                if !result.text.isEmpty {
                    let mode = AppPreferences.shared.selectedMode
                    let processed = try await self.aiCoordinator.process(text: result.text, mode: mode)
                    print("[AppDelegate] ✨ Processed (\(mode.displayName)): \"\(processed)\"")
                    try await TextInjector.shared.inject(processed)
                    print("[AppDelegate] ⌨️ Inserted into the focused app.")
                }
            } catch {
                print("[AppDelegate] ❌ Pipeline failed: \(error.localizedDescription)")
            }
            self.menuBarManager?.updateState(.idle)
            WindowManager.shared.hideRecordingHUD()
        }
    }

    private func handleAudioError(_ error: AudioEngineError) {
        print("[AppDelegate] ⚠️ Audio error: \(error.localizedDescription)")
        isDictating = false
        menuBarManager?.updateState(.idle)
        WindowManager.shared.hideRecordingHUD()
    }
}
