import SwiftUI
import AppKit
import Foundation
import QuickLook
import TatwoUltraworkCore

struct MatrixChip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let binding: TatwoNativePaneBindingMatrix
    let isSelected: Bool

    var body: some View {
        Text("\(binding.skin.shortTitle)×\(binding.engine.rawValue)")
            .font(.caption2.weight(.black))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : .secondary)
            .chatGlassChip(isSelected: isSelected)
    }
}

struct FeatureMappingPill: View {
    let mapping: TatwoNativeCLIFeatureMapping

    private var tint: Color {
        switch mapping.status {
        case .mapped: .green
        case .uiOnly: .blue
        case .unmapped: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(mapping.feature.rawValue)
                    .font(.caption2.weight(.black))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(mapping.flag ?? "灰態：\(mapping.note)")
                .font(.caption2.monospaced())
                .foregroundStyle(mapping.status == .unmapped ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(mapping.status == .unmapped ? 0.06 : 0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(mapping.status == .unmapped ? 0.16 : 0.28), lineWidth: 1))
        .opacity(mapping.status == .unmapped ? 0.62 : 1)
        .help(mapping.note)
    }
}

struct ComputerUseEvaluationCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @ObservedObject private var browserSecurity =
        TatwoBrowserSecurityProjection.shared

    private var pendingSensitiveActions: [TatwoBrowserTypedActionV1] {
        browserSecurity.pendingActions.filter {
            !$0.sensitiveKinds.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Computer Use 評估卡", systemImage: "cursorarrow.click.2")
                    .font(.headline.weight(.black))
                Spacer()
                Text(browserSecurity.planState.rawValue)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            infoRow("是什麼", "讓代理透過螢幕座標、視覺觀察與點擊鍵入操作本機 App；不是聊天模型本身。")
            infoRow("風險", "可能誤點、讀到私密畫面、觸發不可回滾操作；不能用來繞過 Work OS 收據或人類 gate。")
            infoRow("前置需求", "需明確 contract、可操作範圍、截圖/錄影收據、停止條件、敏感視窗遮蔽與人工批准。")
            infoRow(
                "Perception",
                browserSecurity.perceptionMode == .textSafe
                    ? "textSafe（sanitizer envelope only）"
                    : "visualReadOnly（獨立無 mutation grant）")
            infoRow("Origin", browserSecurity.origin)
            if !browserSecurity.planHash.isEmpty {
                infoRow(
                    "Plan hash",
                    String(browserSecurity.planHash.prefix(16)))
            }
            if !pendingSensitiveActions.isEmpty {
                infoRow(
                    "待確認敏感動作",
                    pendingSensitiveActions.map { action in
                        let kinds = action.sensitiveKinds
                            .map(\.rawValue)
                            .sorted()
                            .joined(separator: ",")
                        return "\(action.action.rawValue):\(kinds)"
                    }.joined(separator: " · "))
            }
            if browserSecurity.awaitingHumanApproval {
                Button {
                    browserSecurity.approveCurrentPlan()
                } label: {
                    Label("確認下一個 typed action", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            if browserSecurity.protectionDegraded {
                Text(
                    "瀏覽器保護降級：\(browserSecurity.visibleError ?? "snapshot_unavailable")；人類可手動瀏覽，agent read 已 fail-closed。")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("網頁內容只進 tool-result/data channel；不會成為 system、developer、contract 或使用者指令。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    private func infoRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(.primary)
            Text(body)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
