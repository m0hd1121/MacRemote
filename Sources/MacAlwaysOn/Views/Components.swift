#if os(macOS)
import SwiftUI
import AlwaysOnCore

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Label(title, systemImage: symbol).font(.headline)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    init(_ label: String, _ value: String, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

extension HealthLevel {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .degraded: return .orange
        case .unhealthy: return .red
        }
    }
}

extension ServiceState {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .restarting, .waitingForNetwork: return .orange
        case .crashed, .failed: return .red
        case .stopped, .suspended: return .secondary
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .crashed: return "Crashed"
        case .restarting: return "Restarting"
        case .failed: return "Failed"
        case .suspended: return "Suspended"
        case .waitingForNetwork: return "Waiting for network"
        }
    }
}

extension DiagnosticOutcome {
    var color: Color {
        switch self {
        case .pass: return .green
        case .info: return .blue
        case .warning: return .orange
        case .fail: return .red
        }
    }

    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
}

func yesNo(_ value: Bool?) -> String {
    switch value {
    case true?: return "Yes"
    case false?: return "No"
    case nil: return "Unknown"
    }
}

func dateText(_ date: Date?) -> String {
    date.map { Formatting.time($0) } ?? "—"
}
#endif
