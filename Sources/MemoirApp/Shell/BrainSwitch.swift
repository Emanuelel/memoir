import SwiftUI
import MemoirKit

/// The conversation's brain toggle: Apple on-device, the user's own network model,
/// or the API. Anything unconfigured is greyed out rather than hidden, so the
/// option teaches where Settings would light it up.
@MainActor
final class BrainSwitchModel: ObservableObject {

    struct Option: Identifiable, Equatable {
        let kind: BrainKind
        let label: String
        /// False when Settings has not been filled in for this brain. Shown greyed,
        /// never hidden: a control that vanishes teaches nothing.
        let enabled: Bool
        /// Why it is greyed, for the tooltip.
        let hint: String?

        var id: String { kind.rawValue }
    }

    @Published private(set) var selection: BrainKind
    @Published private(set) var options: [Option] = []

    /// Applies a selection: persists the preference and points the router at it.
    var onSelect: (@MainActor (BrainKind) -> Void)?

    init(selection: BrainKind) {
        self.selection = selection
    }

    /// Rebuilds the option row from the live config. Called at launch and whenever
    /// Settings changes, so the grey states never go stale.
    func refresh(config: AppConfig, apiKeySaved: Bool) {
        selection = config.preferredBrain
        let qwenConfigured = config.brain.localNetworkEndpoint != nil
        let apiConfigured = config.brain.allowCloud && apiKeySaved
        options = [
            Option(kind: .appleOnDevice, label: "Apple", enabled: true, hint: nil),
            Option(kind: .localNetwork, label: "Qwen",
                   enabled: qwenConfigured,
                   hint: qwenConfigured ? nil : "Add your model host in Settings > Brain"),
            Option(kind: .anthropicAPI, label: "API",
                   enabled: apiConfigured,
                   hint: apiConfigured ? nil : "Turn on cloud and add an API key in Settings > Brain"),
        ]
        // A selection that got un-configured out from under us falls back to Apple:
        // silently answering with a brain the toggle says is off would be a lie.
        if let current = options.first(where: { $0.kind == selection }), !current.enabled {
            selection = .appleOnDevice
            onSelect?(.appleOnDevice)
        }
    }

    func select(_ kind: BrainKind) {
        guard kind != selection,
              options.first(where: { $0.kind == kind })?.enabled == true else { return }
        selection = kind
        onSelect?(kind)
    }
}

/// Three mini pills riding above the composer. Selected is white-on-black; a cloud
/// choice carries the warn dot so "this one leaves the Mac" is visible before the
/// first message, not after it.
struct BrainPickerRow: View {
    @ObservedObject var model: BrainSwitchModel

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(model.options) { option in
                Button { model.select(option.kind) } label: {
                    HStack(spacing: 4) {
                        if option.kind.isCloud {
                            Circle()
                                .fill(model.selection == option.kind ? Theme.warn : Theme.faint)
                                .frame(width: 4, height: 4)
                        }
                        Text(option.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(pillForeground(option))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // Unselected pills sit on the stronger hairline grey: on pure
                    // black the tile fill vanished and the toggle read as one lone pill.
                    .background(Capsule().fill(model.selection == option.kind ? Theme.ink : Theme.line2))
                    .opacity(option.enabled ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
                .help(option.hint ?? Self.helpLine(for: option.kind))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answering brain")
    }

    private func pillForeground(_ option: BrainSwitchModel.Option) -> Color {
        model.selection == option.kind ? Theme.bg : Theme.dim
    }

    private static func helpLine(for kind: BrainKind) -> String {
        switch kind {
        case .appleOnDevice: return "Apple's on-device model: stays on this Mac"
        case .localNetwork: return "Your own model host: stays on your network"
        case .anthropicAPI: return "Anthropic API: sends the question off this Mac"
        case .claudeCode, .rulesOnly: return kind.displayName
        }
    }
}
