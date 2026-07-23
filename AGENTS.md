# OmniScribe — Agent / LLM Handoff Guide

> Read this fully before changing anything. It captures **what the app is, how it
> works, why each key decision was made, and the traps that already cost days.**
> Written for another AI agent (or developer) picking up the project cold.

Repo: `https://github.com/g4me2011-lang/omniScribe`

---

## 1. What OmniScribe is

A **menu-bar-only macOS app** for voice dictation with AI post-processing. The user
presses a global hotkey (**⌥Space / Option+Space**), speaks, and cleaned-up text is
**pasted into whatever app currently has focus** (TextEdit, Mail, Slack, browser,
this chat box — anything).

The unique value: it doesn't just transcribe — it **reshapes** the text with an LLM
according to a selected *mode* (grammar cleanup, professional email, code snippet,
casual message, translation) before inserting it.

**Design principles:** invisible (no Dock icon, no window — only a menu-bar icon and
a small floating HUD while recording), universal (works in 100% of apps via
Accessibility + synthetic ⌘V), secure (API keys in Keychain), low-latency.

---

## 2. Runtime pipeline (the core loop)

Everything hangs off one cycle in `AppDelegate.finishDictation()`:

```
⌥Space (HotkeyManager, CGEventTap)
  → AudioSessionManager.start()           capture mic, convert to 16 kHz mono Float32
  → VoiceActivityDetector                 auto-stop after ~2 s of silence …
      OR ⌥Space again                     … or manual stop
  → AudioSessionManager.stop() → [Float]  the captured samples
  → CloudWhisperService.transcribe()      OpenAI Whisper API → Lithuanian text
  → AILayerCoordinator.process(text,mode) Claude (Anthropic) reshapes per mode
  → TextInjector.inject(processed)         save clipboard → set text → ⌘V → restore clipboard
  → back to idle, HUD hidden
```

States are shown via the menu-bar icon (`MenuBarManager`: idle / listening /
processing) and a floating panel (`WindowManager` + `HUDPanel` + `RecordingHUDView`).

All errors in the async pipeline are `catch`-ed and `print`-ed with an ❌ prefix; they
are **not** surfaced in the UI yet. To debug, run from Terminal and watch stdout
(see §7).

---

## 3. File / module map (21 Swift files)

**AppCore / lifecycle**
- `OmniScribeApp.swift` — `@main`, `Settings { EmptyView() }`, no `WindowGroup`.
- `AppDelegate.swift` — owns all services; orchestrates the dictation cycle. **Start here.**
- `MenuBarManager.swift` — `NSStatusItem`, 3-state icon, menu (Settings / Quit).
- `PermissionManager.swift` — requests Microphone + Accessibility, shows NSAlerts.
- `AppPreferences.swift` — `ObservableObject`, persists `selectedMode` + `selectedProvider` (UserDefaults; **not** secrets).

**Hotkey / OS interop**
- `HotkeyManager.swift` — global **CGEventTap** for ⌥Space; **requires Accessibility**; guards with `AXIsProcessTrusted()`. Takes an `onTrigger` closure.
- `TextInjector.swift` — `@MainActor`; clipboard-save → set string → synthesize ⌘V via `CGEvent` (`.cghidEventTap`) → `Task.sleep(120 ms)` → clipboard-restore. Requires Accessibility.
- `ClipboardState.swift` — deep-copies `NSPasteboardItem`s so text/image/file clipboard survives.

**Audio**
- `AudioSessionManager.swift` — `AVAudioEngine`, taps input, converts to 16 kHz mono Float32, feeds VAD; handles device changes; removes tap **before** stopping engine.
- `VoiceActivityDetector.swift` — RMS-based; only counts silence **after** it has first detected speech above threshold (0.012). Fires `onSilenceTimeout` once after ~2 s silence.
- `STTResult.swift` — provider-agnostic result `{ text, language, audioDuration, source }`.

**STT (speech → text)**
- `CloudWhisperService.swift` — **THE ACTIVE TRANSCRIBER.** Uploads a 16 kHz mono WAV to the **OpenAI Whisper API** (`/v1/audio/transcriptions`, `language=lt`). Needs the **OpenAI** Keychain key.
- `LocalTranscriptionService.swift` — Apple `SFSpeechRecognizer` path. **Currently NOT wired into AppDelegate** (leftover). Apple Speech does **not** support `lt-LT`, so it can't do Lithuanian. Keep for reference / future non-Lithuanian on-device use, or delete.

**AI reshaping (text → text)**
- `AIProviderProtocol.swift` — `AIProviderProtocol { process(text:mode:) }`, `AIProviderID { claude, gemini, openai }`, `AIError`.
- `ProcessingMode.swift` — enum `{ ltTyping, email, code, messenger, translation }`, each carries a system prompt. `.ltTyping` = grammar cleanup keeping original language.
- `ClaudeService.swift` — Anthropic Messages API via raw `URLSession` (no Swift SDK). Model `claude-opus-4-8`. **No** temperature/top_p (rejected on Opus 4.7/4.8). 10 s timeout. Needs the **Claude** Keychain key.
- `AILayerCoordinator.swift` — factory routing to the selected provider. **Only `ClaudeService` is registered**; Gemini/OpenAI-as-reshaper are not implemented.

**Security**
- `KeychainManager.swift` — generic-password CRUD keyed by provider `rawValue` under service `com.omniscribe.app.apikeys`. Keys **never** touch UserDefaults. **Per-machine** (keys do not travel with the app).

**UI**
- `SettingsView.swift` — native `TabView` (General + API Keys) + `Form` + `Picker`. No iOS `NavigationView`. General tab: mode + AI-provider pickers. API Keys tab: one `SecureField` per provider (Save/Remove), backed by Keychain.
- `RecordingHUDView.swift` — SwiftUI HUD content (listening/processing).
- `HUDPanel.swift` — non-activating `NSPanel`, `.floating` level, `ignoresMouseEvents`, `canBecomeKey = false` (must never steal focus).
- `WindowManager.swift` — presents the Settings window and the HUD panel safely for an `LSUIElement` app.

---

## 4. Hard-won decisions & WHY (do not "fix" these blindly)

1. **STT provider history — this is the most important lesson.**
   - Original plan: **WhisperKit** (on-device CoreML). **It crashes (SIGSEGV) on Intel Macs** — WhisperKit needs Apple-Silicon Neural Engine. The target user is on an **Intel** Mac → removed WhisperKit entirely (0 references now).
   - Tried **Apple `SFSpeechRecognizer`** — clean, no download, but **does not support Lithuanian (`lt-LT`)**. Returns empty for Lithuanian speech.
   - **Current: OpenAI Whisper API (cloud).** Supports Lithuanian, fast for short clips (~1–3 s), cheap, and — counter-intuitively — **faster than local Whisper on an Intel Mac** because the compute is off-device. This is why cloud beats "buy a local Whisper app" here.
   - ⚠️ If asked to "make transcription local/offline again": on Intel that means `whisper.cpp`, not WhisperKit, and it will be slow. Confirm the user's hardware first.

2. **Claude does NOT transcribe.** Anthropic has no audio modality. Claude only does step 2 (text→text reshaping). Never route audio to Claude. STT must be Whisper/Apple/whisper.cpp.

3. **Menu-bar only (`LSUIElement`).** No Dock icon, **no main window** — users repeatedly think it "didn't open"; it only shows a menu-bar icon. Floating HUD only during recording. Never add a `WindowGroup` as the primary UI.

4. **Hotkey via CGEventTap, not NSEvent monitor** — so ⌥Space can be *consumed* (not passed to the focused app). Requires **Accessibility**.

5. **Text injection via clipboard + synthetic ⌘V** (not Accessibility AXValue setting) — works reliably across all apps including sandboxed ones. Must restore the old clipboard **asynchronously** (sync restore pastes the old content).

6. **API keys in Keychain, per-machine.** They do **not** transfer when you copy the `.app` to another Mac — each machine must re-enter them in Settings.

7. **macOS 12.0 minimum, single universal build.** One build runs on 12 → 15 → newer (macOS is backward-compatible). Do **not** split into per-OS versions; use `if #available(...)` for newer-only APIs. WhisperKit removal is what allowed dropping the target from 14 to 12.

8. **App Sandbox is DISABLED** (`OmniScribe.entitlements`). CGEventTap + Accessibility + global paste can't work under the sandbox. Consequence: distribution is **Developer ID + notarization**, not the Mac App Store.

---

## 5. Build & distribution (no local Xcode — CI does it)

The user has **no full Xcode locally** (only Command Line Tools) and a modest Intel
Mac. All compiling happens on **GitHub Actions macOS runners**. Never assume a local
`xcodebuild`.

- Workflow: `.github/workflows/build.yml`. Trigger: push to `main` or manual dispatch.
- Runner `macos-15` + `maxim-lobanov/setup-xcode@v1 latest-stable` (a modern Xcode is required or SwiftPM resolution fails).
- Build command uses **`-scheme OmniScribe`** (a shared scheme exists at
  `OmniScribe.xcodeproj/xcshareddata/xcschemes/OmniScribe.xcscheme`). ⚠️ `-derivedDataPath`
  **requires** `-scheme`, not `-target` — this cost a failed build.
- `MACOSX_DEPLOYMENT_TARGET=14.0` was passed in CI while WhisperKit existed; the
  project target is now **12.0**. Keep CI override ≥ project target.
- Build is **unsigned** (`CODE_SIGNING_ALLOWED=NO`) then **ad-hoc signed**
  (`codesign --force --deep --sign -`) so it launches.
- Output: `OmniScribe.zip` uploaded as artifact **`OmniScribe-app`**. After WhisperKit
  removal the app is tiny (~0.3 MB) — models are not bundled; STT is cloud.

**To ship the built app to a user's Mac:** download the artifact (requires being
logged into GitHub), unzip twice → `OmniScribe.app`, then on the Mac:
`xattr -dr com.apple.quarantine /Applications/OmniScribe.app` (ad-hoc apps are
quarantine-blocked), then grant permissions.

**Verifying a CI run from a headless/agent context** (no `gh` auth): use the public
REST API, e.g.
`curl -s https://api.github.com/repos/g4me2011-lang/omniScribe/actions/runs`
and `.../runs/{id}/jobs` for step results. Logs need auth (403 unauthenticated).

---

## 6. Permissions the app needs (and the #1 gotcha)

| Permission | Why | Where |
|---|---|---|
| **Microphone** | capture audio | Privacy → Microphone |
| **Accessibility** | CGEventTap hotkey **and** synthetic ⌘V paste | Privacy → Accessibility |
| **Speech Recognition** | only if using the Apple `LocalTranscriptionService` path (not the active OpenAI path) | Privacy → Speech Recognition |

**Gotcha — running from Terminal attributes permissions to Terminal, not OmniScribe.**
When you launch `…/OmniScribe.app/Contents/MacOS/OmniScribe` from a terminal to see
logs, macOS attributes Microphone/Accessibility to the **terminal app**. If the
terminal lacks Microphone permission, macOS feeds **silent (zero) buffers with no
error** → Whisper returns `"🎵🎵🎵"` (its silence hallucination) → VAD never detects
speech → auto-stop never fires. Fix: grant the terminal Microphone+Accessibility, **or**
just launch the `.app` normally from Finder for real use.

**Gotcha — ad-hoc signature changes every build.** Each new CI build has a different
ad-hoc signature, so macOS treats it as a new app and **Accessibility must be
re-granted** (remove the stale entry with "−", add the new `.app` with "+", relaunch).
This only disappears with a real Developer ID signature.

---

## 7. Debugging / testing

- Run from Terminal to see logs: `/Applications/OmniScribe.app/Contents/MacOS/OmniScribe`
  (mind the permission gotcha above — grant the terminal Mic+Accessibility).
- Log prefixes to grep: `[HotkeyManager]`, `[AppDelegate]`, `[CloudWhisperService]`.
  Key lines: `✅ Global hotkey ⌥Space registered`, `⏹️ Recording stopped – N samples`,
  `📝 Transcription (...)`, `✨ Processed (...)`, `⌨️ Inserted`, `❌ Pipeline failed: …`.
- `"🎵🎵🎵"` transcription = **silence/no speech reached Whisper** (mic not capturing;
  see permission gotcha, wrong input device, or background music).
- No auto-stop after silence = VAD never saw speech = same root cause (silent audio),
  or genuine mic level below the 0.012 RMS threshold.
- Multiple menu-bar mic icons = multiple instances (each Terminal launch spawns one);
  `killall OmniScribe`. NOTE: an isolated agent shell may not see the user's GUI
  processes — have the **user** run `killall`.
- Crash reports: `~/Library/Logs/DiagnosticReports/OmniScribe*.ips` (JSON; parse the
  `faultingThread` frames — that's how the WhisperKit SIGSEGV was pinpointed).

---

## 8. Known issues / TODO

- **Cosmetic mislabel:** `STTResult.Source` enum still reads `"Apple Speech (server)"`
  / `"Apple Speech (on-device)"`, but the active transcriber is **OpenAI Whisper**. Logs
  therefore say "Apple Speech (server)" when it's really OpenAI. Rename the enum values.
- **No user-facing error UI** — pipeline errors only `print`. Consider surfacing them in
  the HUD or a notification.
- **`LocalTranscriptionService` is dead code** in the current wiring (Apple has no
  Lithuanian). Either delete or keep behind a language/provider setting.
- **AI provider** — only Claude is implemented; `AILayerCoordinator` has stubs for
  Gemini/OpenAI-as-reshaper.
- **No "raw" dictation mode** — every mode runs the text through Claude, which edits it.
  `.ltTyping` cleans grammar (can slightly change wording). A pass-through mode that
  inserts the raw transcription (no LLM) would be a useful addition.
- **VAD sensitivity** is a fixed 0.012 RMS / 2 s. A quiet mic may never trip "speech
  detected". Consider a Settings slider.
- **Distribution friction:** ad-hoc signing → users need `xattr`/"Open Anyway" and
  re-grant Accessibility each build. Real fix = Apple Developer ID ($99/yr) +
  notarization + a `.dmg`/GitHub Release. Not done yet.
- **Two API keys required, per machine:** OpenAI (for STT) **and** Anthropic/Claude
  (for reshaping), entered in Settings → API Keys. Don't confuse the fields
  (`sk-...`/`sk-proj-...` = OpenAI; `sk-ant-...` = Claude). Swapping them → 401 on both.

---

## 9. Environment facts (this project's user)

- Two Macs: **Intel** MacBook Pro (macOS **15.7** Sequoia) and another on **macOS 12.7.6
  Monterey**. Both **Intel** → no WhisperKit, no Apple-Silicon assumptions.
- No local full Xcode. Builds run on GitHub Actions; the user downloads the artifact.
- Non-expert with the toolchain — give click-by-click steps (Finder/System Settings
  paths differ between Monterey "System Preferences" and Sequoia "System Settings").
- Primary dictation language: **Lithuanian** (`lt`). This is why OpenAI Whisper is
  mandatory (Apple lacks it).

---

## 10. If you extend it — where to look

- Add a language picker → `CloudWhisperService` (`language` param) + Settings General tab.
- Add a raw/no-LLM mode → new `ProcessingMode` case + short-circuit in
  `AppDelegate.finishDictation` (skip `aiCoordinator.process`).
- Add another AI provider → implement `AIProviderProtocol`, register it in
  `AILayerCoordinator.init(providers:)`.
- Notarized distribution → extend `.github/workflows/build.yml` with Developer ID
  signing + `notarytool` + a Release/`.dmg` step (needs the user's Apple credentials —
  the agent cannot supply them).
- Always: change code → commit → **user** does `git push` → CI builds → user downloads
  the new artifact and re-grants Accessibility.
```
