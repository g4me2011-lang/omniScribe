import SwiftUI

/// The root Settings window content: a native macOS tabbed interface.
///
/// Uses `TabView` + `Form` + native `Picker`s — no iOS-style `NavigationView`
/// or back buttons. The window itself (title bar, close button, size) is managed
/// by `WindowManager`; this view only supplies content and a fixed size.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }
        }
        .frame(width: 460, height: 340)
    }
}

// MARK: – General (mode + provider)

private struct GeneralSettingsView: View {
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Processing Mode", selection: $prefs.selectedMode) {
                    ForEach(ProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("AI Provider", selection: $prefs.selectedProvider) {
                    ForEach(AIProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } footer: {
                Text("The processing mode is applied to every dictation until you change it. Activate dictation with \u{2325}Space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: – API Keys (Keychain-backed)

private struct APIKeysSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(AIProviderID.allCases, id: \.self) { provider in
                    APIKeyRow(provider: provider)
                }
            } footer: {
                Text("Keys are stored in the macOS Keychain, never in plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider's key field with Save / Remove, backed directly by `KeychainManager`.
private struct APIKeyRow: View {
    let provider: AIProviderID

    @State private var key: String = ""
    @State private var isStored: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                if isStored {
                    Label("Stored", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            SecureField("API Key", text: $key)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove", role: .destructive) { remove() }
                    .disabled(!isStored)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .onAppear(perform: load)
    }

    private func load() {
        // Flatten String?? from `try?` down to a plain String for the field.
        key = ((try? KeychainManager.shared.apiKey(for: provider)) ?? nil) ?? ""
        isStored = KeychainManager.shared.hasAPIKey(for: provider)
    }

    private func save() {
        try? KeychainManager.shared.setAPIKey(key.trimmingCharacters(in: .whitespaces), for: provider)
        isStored = KeychainManager.shared.hasAPIKey(for: provider)
    }

    private func remove() {
        try? KeychainManager.shared.deleteAPIKey(for: provider)
        key = ""
        isStored = false
    }
}
