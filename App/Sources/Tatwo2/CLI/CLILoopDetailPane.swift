// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/CLILoopDetailPane.swift；改動 2 行（原因：加入來源標記；移除舊 Core import，改由 Facade 同名假資料型別供應）
import SwiftUI

/// CLI 主區：loop 唯讀詳情（非終端、不可輸入）。
/// 停止按鈕一律走 `TatwoInterruptConfirmationPresenter`／`LoopsInterruptGate`。
struct CLILoopDetailPane: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let snapshot: CLILoopDetailSnapshot?
    let onStop: () -> Void
    let onClearSelection: () -> Void

    var body: some View {
        GlassCard {
            if let snapshot {
                detailBody(snapshot)
            } else {
                missingBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailBody(_ snapshot: CLILoopDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(snapshot)
            metaRow(snapshot.row)
            timelineCard(snapshot.timeline)
            outputCard(snapshot.outputText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ snapshot: CLILoopDetailSnapshot) -> some View {
        HStack(spacing: 8) {
            Label(snapshot.row.displayName, systemImage: "bolt.horizontal.circle")
                .font(.headline.weight(.black))
                .lineLimit(1)
            Badge(snapshot.row.identity)
            Badge(snapshot.row.statusLabel)
            Badge(snapshot.row.deviceLabel)
            Spacer(minLength: 0)
            if snapshot.canStop {
                Button {
                    // 停止一律二次確認；確認後由呼叫端執行既有 stop 路徑。
                    guard TatwoInterruptConfirmationPresenter.confirm(kind: .composerStop)
                    else { return }
                    onStop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .chatGlassChip(isSelected: true)
                .help("停止此 loop（需二次確認）")
            }
            Button(action: onClearSelection) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回終端")
        }
    }

    private func metaRow(_ row: CLILoopTreeRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.modelID.isEmpty ? row.bindingID : row.modelID)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                Text(row.startedAt, style: .relative)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let source = row.sourceThreadLabel, !source.isEmpty {
                HStack(spacing: 6) {
                    Badge("來源 thread")
                    Text(source)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !row.subtask.isEmpty {
                Text(row.subtask)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("contract \(row.contractID)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidGlassTokens.brandAccent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: .continuous))
    }

    private func timelineCard(_ events: [CLILoopTimelineEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("狀態時間線")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text("尚無狀態轉換紀錄")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(timelineDot(event.status))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.status.label)
                                    .font(.caption2.weight(.black))
                                Text(event.at, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: .continuous))
    }

    private func outputCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("輸出／收據（唯讀）")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
    }

    private var missingBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("找不到此 loop 紀錄")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("返回終端", action: onClearSelection)
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timelineDot(_ status: CLILoopTreeStatus) -> Color {
        switch status {
        case .queued: return .gray
        case .running: return .blue
        case .completed: return .green
        case .verified: return .mint
        case .failed: return .red
        }
    }
}
