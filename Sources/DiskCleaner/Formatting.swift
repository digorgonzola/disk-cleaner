import DiskCleanerCore
import Foundation
import SwiftUI

enum Format {
    /// The size cleaning frees, or why there is none: "Asking…" while a tool answers,
    /// "Unknown" when it cannot tell.
    static func cleanableSize(of items: [ScanItem]) -> (text: String, isKnown: Bool) {
        let bytes = items.reduce(0) { $0 + $1.bytes }
        if bytes > 0 { return (Self.bytes(bytes), true) }
        if items.contains(where: { $0.reclaimable == .pending }) { return ("Asking…", false) }
        if items.contains(where: { if case .unknown = $0.reclaimable { true } else { false } }) { return ("Unknown", false) }
        return (Self.bytes(0), true)
    }

    static func bytes(_ value: Int64) -> String {
        value == 0 ? "—" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Short form for the menu bar: "27 GB", "8.4 GB", "1.2 TB".
    static func compactBytes(_ value: Int64) -> String {
        let gigabytes = Double(value) / 1_000_000_000
        if gigabytes >= 1_000 { return String(format: "%.1f TB", gigabytes / 1_000) }
        return gigabytes >= 10 ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
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

extension RuleCategory {
    var tint: Color { RuleCategory.tints[self] ?? .secondary }

    private static let tints: [RuleCategory: Color] = [
        .worktrees: .purple,
        .projectArtifacts: .orange,
        .packageManagers: .blue,
        .infrastructure: .teal,
        .containers: .indigo,
        .testing: .pink,
        .editors: .mint,
        .browsers: .cyan,
        .system: .gray,
        .reviewOnly: .secondary,
    ]
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

/// Horizontal bar scaled against the largest value in a list. `selectedFraction` draws the
/// selected share solid over a faint bar for the whole.
struct SizeBar: View {
    let fraction: Double
    var selectedFraction: Double?
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let selectedFraction {
                    Capsule().fill(color.opacity(0.35)).frame(width: max(4, width * min(1, fraction)))
                    if selectedFraction > 0 {
                        Capsule().fill(color.gradient).frame(width: max(4, width * min(1, selectedFraction)))
                    }
                } else {
                    Capsule().fill(color.gradient).frame(width: max(4, width * min(1, fraction)))
                }
            }
        }
        .frame(height: height)
    }
}

/// Small label for the rule that found an item, shown where rows from many rules mix.
struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
