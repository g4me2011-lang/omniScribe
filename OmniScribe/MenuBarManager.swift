import AppKit

// MARK: – AppState

/// Represents the three visual states of the Menu Bar icon.
enum AppState: String {
    case idle       = "Idle"
    case listening  = "Listening"
    case processing = "Processing"

    /// SF Symbol name for each state.
    var symbolName: String {
        switch self {
        case .idle:       return "mic"
        case .listening:  return "mic.fill"
        case .processing: return "waveform"
        }
    }

    var tooltip: String { "OmniScribe – \(rawValue)" }
}

// MARK: – MenuBarManager

/// Owns the `NSStatusItem` and keeps its icon/menu in sync with `AppState`.
///
/// All public methods are safe to call from any thread – they dispatch to
/// the main queue internally.
final class MenuBarManager {

    // MARK: Private state

    private let statusItem: NSStatusItem
    private let statusMenuItem = NSMenuItem()   // Shows "OmniScribe – <state>" as info row.

    private(set) var currentState: AppState = .idle {
        didSet { refreshButton() }
    }

    // MARK: Init

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        configureMenu()
    }

    // MARK: – Public API

    /// Updates the icon and status label. Thread-safe.
    func updateState(_ state: AppState) {
        DispatchQueue.main.async { [weak self] in
            self?.currentState = state
        }
    }

    // MARK: – Private – Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = makeIcon(for: .idle)
        button.toolTip = AppState.idle.tooltip
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.image = makeIcon(for: currentState)
        button.toolTip = currentState.tooltip
        statusMenuItem.title = "OmniScribe – \(currentState.rawValue)"
    }

    private func makeIcon(for state: AppState) -> NSImage? {
        let img = NSImage(systemSymbolName: state.symbolName,
                          accessibilityDescription: state.tooltip)
        img?.isTemplate = true  // Automatically adapts to dark/light Menu Bar.
        return img
    }

    // MARK: – Private – Menu

    private func configureMenu() {
        let menu = NSMenu()

        // --- Info row (disabled, shows current state) ---
        statusMenuItem.title = "OmniScribe – Idle"
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // --- Hotkey hint ---
        let hintItem = NSMenuItem(title: "Activate: \u{2325}Space", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(.separator())

        // --- Settings ---
        let settingsItem = NSMenuItem(title: "Settings\u{2026}",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit OmniScribe",
                                  action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: – Actions

    @objc private func openSettings() {
        WindowManager.shared.showSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
