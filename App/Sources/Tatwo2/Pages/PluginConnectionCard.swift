import SwiftUI

struct PluginLivenessStatusPill: View {
    let state: PluginLivenessResult

    private var color: Color {
        switch state.state.pillColor {
        case "green": .green
        case "yellow": .yellow
        case "red": .red
        default: .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.state.pillText).font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

/// Only the MCP tab uses this card. Skillet keeps its original row/presentation.
struct PluginConnectionCard: View {
    let entry: PluginRegistryEntry
    let requestRemoval: () -> Void

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: entry.kind == .builtin ? "shippingbox" : "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .tatwoAdaptiveMaterial(cornerRadius: 14)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(entry.name).font(.headline)
                        Badge(entry.kind == .builtin ? "內建" : "MCP")
                        Badge(entry.safetyLevel.rawValue)
                    }
                    Text(entry.purpose).foregroundStyle(.secondary)
                    Text("誰能用：\(entry.availableTo.isEmpty ? "—" : entry.availableTo.joined(separator: "・"))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("工具數：\(entry.toolCount.map(String.init) ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("最近呼叫：\(entry.lastCalledAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let detail = entry.liveness.detail {
                        Text(detail).font(.caption)
                            .foregroundStyle(entry.liveness.state == .unreachable ? Color.red : Color.secondary)
                    }
                    Text("安裝：\(installationLabel)・\(entry.publicInstallHint)")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Label(entry.trigger, systemImage: "bolt.horizontal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 8) {
                    PluginLivenessStatusPill(state: entry.liveness)
                    if entry.kind == .mcp && entry.liveness.state == .unreachable {
                        Button("移除登記", role: .destructive, action: requestRemoval)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var installationLabel: String {
        switch entry.installState {
        case .installed: "已登記"
        case .missing: "缺少"
        case .skipped: "略過"
        case .unknown: "未確認"
        }
    }
}
