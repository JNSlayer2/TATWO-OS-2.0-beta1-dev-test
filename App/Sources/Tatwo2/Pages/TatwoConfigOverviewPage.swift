// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoConfigOverviewPage.swift；改動 116 行（原因：B2 依裁決拆除模式／情境區塊，只保留特質卡）
import SwiftUI

/// 各模型的性格與強項；誰主導、誰當 sub、誰審，在輸入框旁的 ultrawork 膠囊選。
struct TatwoConfigOverviewPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let modes: [WorkMode]
    let selectedMode: WorkModeID
    let profiles: [ScenarioProfile]
    /// AppShell 擁有的情境綁定（原 Modes/Scenarios 共用綁定合約的合併版）。
    @Binding var previewScenarioProfileID: String
    let issuedContract: TatwoWorkOSContractV1?
    let issuedIntegrityState: ModesIssuedIntegrityState
    let modelTraits: [ModelTrait]
    let onSelectScenarioProfile: (ScenarioProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                traitSection
            }
            .padding(18)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 特質

    private var traitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("特質", subtitle: "各模型的性格與強項；誰主導、誰當 sub、誰審，在輸入框旁的 ultrawork 膠囊選")
            ForEach(modelTraits) { trait in
                traitRow(trait)
            }
        }
        .padding(14)
        .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    private func traitRow(_ trait: ModelTrait) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(trait.displayName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 86, alignment: .leading)
            Text(trait.plainSummary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 6)
            traitScoreDots(trait.scores)
        }
        .padding(.vertical, 4)
    }

    /// 分數點陣（設計語言：強度用點不用數字）——取三個最有決策價值的維度。
    private func traitScoreDots(_ scores: ModelTraitScores) -> some View {
        HStack(spacing: 8) {
            scoreDot("推理", scores.reasoning)
            scoreDot("寫碼", scores.coding)
            scoreDot("審查", scores.reviewStrictness)
        }
    }

    private func scoreDot(_ label: String, _ score: Int) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(
                            index < score
                                ? LiquidGlassTokens.brandAccent.opacity(0.85)
                                : Color.secondary.opacity(0.18))
                        .frame(width: 4, height: 4)
                }
            }
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .rounded))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
