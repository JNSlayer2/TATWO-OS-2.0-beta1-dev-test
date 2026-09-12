import SwiftUI

/// 回合收尾：這一回合產出了哪些檔／報告。不列工具次數；每列標三種狀態：
/// 引擎說有但檔不在（橘）、檔真的在（灰）、主導驗過（綠）。點檔名用系統開啟；「查看」開右側 diff。
struct ChatArtifactsCard: View {
    let index: TurnArtifactIndex
    let onView: () -> Void
    let onOpen: (String) -> Void

    @State private var isExpanded = false

    private var shown: [TurnArtifact] { Array(index.artifacts.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("本回合產出 \(index.artifacts.count) 項")
                            .font(.system(size: 12, weight: .semibold))
                        Text(summaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-artifacts-disclosure")
                .accessibilityValue(isExpanded ? "已展開" : "已收合")
                .help((isExpanded ? "收合產出檔案" : "展開產出檔案") + " · " + summaryLine)
                Button("查看") { onView() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("chat-artifacts-view")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if isExpanded {
                Divider().opacity(0.72)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.path) { item in
                        Button {
                            if item.exists && !item.outside { onOpen(item.path) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(item))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(item.outside ? "（工作樹外的檔案，不顯示路徑）" : item.path)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.primary.opacity(item.exists ? 0.82 : 0.55))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.outside ? "工作樹外的檔案，不顯示路徑" : item.path)
                                Spacer(minLength: 12)
                                if let size = item.sizeBytes, item.exists {
                                    Text(Self.sizeText(size))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                statusPill(item)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .opacity(item.exists && !item.outside ? 1 : 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!(item.exists && !item.outside))
                        .accessibilityLabel("\(item.outside ? "工作樹外的檔案" : item.path)，\(statusText(item))")
                    }
                    if index.artifacts.count > shown.count || index.truncated {
                        Button("另有 \(max(0, index.artifacts.count - shown.count)) 項，查看全部") { onView() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本回合產出 \(index.artifacts.count) 項")
    }

    private var summaryLine: String {
        let claimedMissing = index.artifacts.filter { $0.claimed && !$0.exists }.count
        let otherMissing = index.artifacts.filter { !$0.claimed && !$0.exists }.count
        let verified = index.artifacts.filter { $0.verifiedBy != nil }.count
        var parts: [String] = []
        if claimedMissing > 0 { parts.append("\(claimedMissing) 項引擎說有但找不到") }
        if otherMissing > 0 { parts.append("\(otherMissing) 項已不在") }
        if verified > 0 { parts.append("\(verified) 項已驗") }
        if parts.isEmpty { parts.append(verified == index.artifacts.count ? "全部已驗" : "檔案都在，尚未驗收") }
        return parts.joined(separator: "，")
    }

    private func icon(_ item: TurnArtifact) -> String {
        switch item.kind {
        case "report": return "doc.text"
        case "log": return "terminal"
        default: return "doc"
        }
    }

    private func statusText(_ item: TurnArtifact) -> String {
        if item.verifiedBy != nil { return "已驗" }
        if !item.exists { return item.claimed ? "引擎說有，找不到" : "找不到" }
        return item.claimed ? "檔在" : "git 變更"
    }

    @ViewBuilder private func statusPill(_ item: TurnArtifact) -> some View {
        let color: Color = item.verifiedBy != nil ? .green : (!item.exists ? .orange : .secondary)
        Text(statusText(item))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(color.opacity(0.12), in: Capsule())
    }

    static func sizeText(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
