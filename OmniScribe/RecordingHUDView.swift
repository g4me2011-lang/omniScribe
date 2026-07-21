import SwiftUI

/// The visual phase the floating HUD reflects.
enum HUDPhase {
    case listening
    case processing

    var label: String {
        switch self {
        case .listening:  return "Listening\u{2026}"
        case .processing: return "Processing\u{2026}"
        }
    }

    var symbol: String {
        switch self {
        case .listening:  return "mic.fill"
        case .processing: return "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .listening:  return .red
        case .processing: return .accentColor
        }
    }
}

/// Observable state driving the HUD. Owned by `WindowManager`; mutated on the
/// main thread as the dictation phase changes.
final class RecordingHUDState: ObservableObject {
    @Published var phase: HUDPhase = .listening
}

/// A small, non-interactive recording indicator. Purely visual — the hosting
/// `HUDPanel` handles the "never steal focus" behaviour.
struct RecordingHUDView: View {
    @ObservedObject var state: RecordingHUDState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.phase.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.phase.tint)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Text(state.phase.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .fixedSize()
        .onAppear { pulse = true }
    }
}
