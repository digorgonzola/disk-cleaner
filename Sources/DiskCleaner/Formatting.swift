import DiskCleanerCore
import Foundation
import SwiftUI

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        return days < 1 ? "today" : "\(days)d ago"
    }

    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension Risk {
    var label: String { self == .safe ? "Safe" : "Caution" }
    var color: Color { self == .safe ? .green : .orange }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.18), in: Capsule())
            .foregroundStyle(risk.color)
            .help(risk == .safe ? "Pure cache; tools rebuild it on demand." : "Needs a reinstall, rebuild or re-download, or may hold data you want.")
    }
}

struct Checkbox: View {
    let state: AppModel.SelectionState
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Checkbox.symbols[state] ?? "square")
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(state == .all ? "Selected" : "Not selected")
    }

    private static let symbols: [AppModel.SelectionState: String] = [
        .none: "square", .some: "minus.square.fill", .all: "checkmark.square.fill",
    ]
}

/// Horizontal bar scaled against the largest value in a list.
struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient).frame(width: max(4, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}
