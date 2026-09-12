import SwiftUI
import TatwoUltraworkCore

/// 配置總覽（2026-08-20 使用者裁決：模式／情境／特質三分頁已雞肋，
/// 收成一頁、不留深潛層）。設計語言優先：每節一眼看完——
/// 模式＝檔位膠囊列＋一句話；情境＝精簡選擇列；特質＝強項 chips。
/// 深度內容（完整 stop rules、identity slots、calibration notes）不再
/// 提供查閱入口——需要時屬於 Ultrawork 閉環紀錄與 os.md，不屬於這頁。
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

    private var selectedScenarioProfileID: String? {
        previewScenarioProfileID.isEmpty ? nil : previewScenarioProfileID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modeSection
                scenarioSection
                traitSection
            }
            .padding(18)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 模式（S–XXL 檔位）

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("模式", subtitle: "工作規模 S～XXL")
            HStack(spacing: 6) {
                ForEach(modes) { mode in
                    modePill(mode)
                }
            }
            if let current = modes.first(where: { $0.mode == selectedMode }) {
                Text("\(current.chineseName)：\(current.plainDescription)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("幫手上限 \(current.maxHelpers) · 回合上限 \(current.maxRounds)"
                    + (current.requiresHumanApproval ? " · 人工核准" : "")
                    + (current.requiresIndependentVerification ? " · 獨立驗證" : ""))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text("模式變更走 /plg 目標修訂（人門），此處僅總覽。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            // 已簽發 session 唯讀檢視（沿承原 ModesPage 的治理可視性）。
            if let issuedContract {
                Text("已簽發：\(issuedContract.scenario) · \(issuedContract.mode.rawValue.uppercased()) · 完整性 \(String(describing: issuedIntegrityState))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    /// 模式檔位唯讀展示：變更屬憲法級目標修訂流程（TatwoGoalRevisionSelection
    /// 綁 scenarioBook＋loopPreset），總覽頁不旁路人門。
    private func modePill(_ mode: WorkMode) -> some View {
        let isSelected = mode.mode == selectedMode
        return Text(mode.englishName)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .frame(minWidth: 40, minHeight: 26)
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.45))
            .background {
                if isSelected {
                    Capsule().fill(LiquidGlassTokens.ultraworkGradient)
                }
            }
            .help(mode.plainDescription)
    }

    // MARK: 情境

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("情境", subtitle: "身份組隊形")
            ForEach(profiles) { profile in
                scenarioRow(profile)
            }
        }
        .padding(14)
        .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    private func scenarioRow(_ profile: ScenarioProfile) -> some View {
        let isSelected = profile.id == selectedScenarioProfileID
        return Button {
            onSelectScenarioProfile(profile)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary.opacity(0.28))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(.primary)
                    Text(profile.plainPurpose)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(profile.defaultMode.rawValue.uppercased())
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? LiquidGlassTokens.brandAccent.opacity(0.10) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 特質

    private var traitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("特質", subtitle: "各模型一眼互補")
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
