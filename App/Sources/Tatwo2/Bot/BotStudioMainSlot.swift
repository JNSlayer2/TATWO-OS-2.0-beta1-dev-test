import SwiftUI

// Gen-5 bot 分頁主槽：工作室畫面／bot 對話／綁工作環境／建 bot 六步／身份組設定。
// 純 UI：所有內容都是展示資料，按鈕不接任何執行器。

struct BotStudioMainSlot: View {
    @ObservedObject var state: BotStudioState

    var body: some View {
        VStack(spacing: 0) {
            switch state.mode {
            case .studio: studioPane
            case .team:
                teamPane
                    .frame(maxWidth: 900, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .spaceSettings:
                BotStudioSpaceSettingsPane(state: state)
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .thread:
                threadPane
                    .frame(maxWidth: 860, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .bind:
                BotStudioBindPane(state: state)
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .wizard:
                BotStudioWizardPane(state: state)
                    .frame(maxWidth: 860, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            case .role:
                BotStudioRolePane(state: state)
                    .frame(maxWidth: 980, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 36)
        .padding(.leading, 18)
        .padding(.trailing, 34)   // 留給窗外工作室書籤咬住的邊
        .padding(.bottom, 16)
    }

    // MARK: - 工作室畫面

    @ViewBuilder
    private var studioPane: some View {
        if let studio = state.studio {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Text(studio.emoji).font(.system(size: 15))
                    Text(studio.name).font(.system(size: 14, weight: .bold))
                    Text(studio.target)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.primary.opacity(0.14), lineWidth: 1))
                    Spacer(minLength: 0)
                    BotStudioKindChip(kind: studio.kind)
                }

                if let notice = studio.notice {
                    BotStudioNotice(text: notice)
                }

                BotStudioFakeWeb(title: studio.canvasTitle, cells: studio.canvasCells)

                if let say = studio.say {
                    BotStudioSayRow(say: say)
                }
            }
        } else {
            BotStudioEmpty(
                symbol: "square.dashed",
                title: "這個 bot space 還沒接東西進來",
                detail: "用 app 右緣的工作室書籤 ＋，講一句你要接什麼，bot 會先給你 plan。") {
                    state.startBind()
                }
        }
    }

    // MARK: - 小組＝一組人一起講話的地方

    @ViewBuilder
    private var teamPane: some View {
        if let id = state.selectedTeamID, let folder = state.folder(id) {
            let members = state.teamBots(id)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Text(folder.name).font(.system(size: 17, weight: .semibold))
                        Spacer(minLength: 0)
                        Button("身份組") { state.openRoleSettings(folderID: id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    BotStudioMemberRow(bots: members) { state.selectBot($0) }
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 11) {
                        if !folder.charter.isEmpty {
                            BotStudioCharterCard(charter: folder.charter, members: [])
                        }
                        ForEach(Array(BotStudioFixture.thread(for: folder.name).enumerated()), id: \.offset) { _, say in
                            BotStudioSayRow(say: say)
                        }
                        ForEach(Array(state.extraSays(for: id).enumerated()), id: \.offset) { _, say in
                            BotStudioSayRow(say: say)
                        }
                    }
                }
                BotStudioComposer(
                    text: $state.threadDraft,
                    placeholder: members.isEmpty ? "這個小組還沒有人" : "跟「\(folder.name)」裡的大家講話…",
                    modelLabel: "\(members.count) 隻在裡面",
                    modelTier: "一起",
                    scopeLabel: "全員",
                    onSubmit: { state.sendThreadDraft() })
            }
        } else {
            BotStudioEmpty(symbol: "person.3.fill", title: "選一個小組", detail: nil, action: nil)
        }
    }

    // MARK: - 單獨一隻 bot 的對話

    @ViewBuilder
    private var threadPane: some View {
        if let unit = state.bot(state.selectedBotID) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    BotAvatar(emoji: unit.emoji, size: 22, selected: true)
                    Text(unit.name).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(Array(BotStudioFixture.thread(for: unit.name).enumerated()), id: \.offset) { _, say in
                            BotStudioSayRow(say: say)
                        }
                        ForEach(Array(state.extraSays(for: unit.id).enumerated()), id: \.offset) { _, say in
                            BotStudioSayRow(say: say)
                        }
                    }
                }
                BotStudioComposer(
                    text: $state.threadDraft,
                    placeholder: "跟「\(unit.name)」講話…",
                    modelLabel: unit.engine,
                    scopeLabel: "自己做",
                    onSubmit: { state.sendThreadDraft() })
            }
        } else {
            BotStudioEmpty(symbol: "bubble.left", title: "選一隻 bot", detail: nil, action: nil)
        }
    }
}

// MARK: - 接一個新東西進來：對話，不是表單
// 2026-09-09 使用者定案：不預設工作室形式（那會把可擴展性框死）。
// 你講一句話，可以找現有的 bot 談、也可以當場開一隻新的；那隻 bot 一律
// 先做 plan 把你的部署想像問清楚，才談要接成什麼。

struct BotStudioBindPane: View {
    @ObservedObject var state: BotStudioState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if state.bindPhase == .plan {
                planBody
            } else if state.bindTranscript.isEmpty {
                intro
            } else {
                transcript
            }
            Spacer(minLength: 0)
            if state.bindPhase == .compose {
                composer
            } else {
                planActions
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("接一個新東西進來").font(.system(size: 14, weight: .bold))
            Text(state.bindPhase == .plan ? "bot 的 plan" : "先講給 bot 聽")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("取消") { state.mode = .studio }
                .buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("這裡不先問你要接哪一種。")
                .font(.system(size: 13, weight: .semibold))
            Text("你就照平常講話講：要接的是什麼、你想拿它做什麼。找一隻現有的 bot 談，或當場開一隻新的都行——它會先把你的部署想像問清楚，給你一份 plan，你點頭它才動手。")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("例如：「幼兒園的校長雲我用了很多年，它不會 AI，我想要有人幫我把報名表填進去」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(0.04)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(state.bindTranscript.enumerated()), id: \.offset) { _, say in
                BotStudioSayRow(say: say)
            }
        }
    }

    private var planBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                transcript
                BotStudioPlanCard(
                    title: "它想先問清楚的",
                    caption: "問完才知道要接成什麼形式",
                    rows: state.bindQuestions,
                    numbered: false)
                BotStudioPlanCard(
                    title: "初步 plan",
                    caption: "一律從只讀開始，權限逐項打開",
                    rows: state.bindPlan,
                    numbered: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("要留下來的話，先給它一個名字")
                        .font(.system(size: 12.5, weight: .bold))
                    BotStudioField(label: "這間叫什麼", text: $state.bindName, placeholder: "校長雲")
                    BotStudioField(label: "位置（還沒有就留空）", text: $state.bindTarget,
                                   placeholder: "127.0.0.1:5173　或　cloud.jretc.com.tw　或　~/tattoo-cms",
                                   mono: true)
                    Text("位置寫法自己看得出是哪一種，不用你先選。留空就先當還沒成形的專案收著。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.background.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 1))

                Text("到這一步為止沒有連上任何東西，也沒有給出任何權限。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var planActions: some View {
        HStack(spacing: 9) {
            BotStudioButton(title: "再談談", prominent: false) { state.resumeBindTalk() }
            Spacer(minLength: 0)
            BotStudioButton(title: "照這個 plan 開始", prominent: true) { state.finishBind() }
        }
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            partnerRow
            BotStudioComposer(
                text: $state.bindPrompt,
                placeholder: "要接什麼進來？講給它聽…",
                modelLabel: state.bindPartner?.engine ?? "Claude Opus 5",
                scopeLabel: "先給 plan",
                statusText: "它會先問清楚再給 plan，不會直接動手",
                onSubmit: { state.submitBind() })
        }
    }

    /// 跟誰談：現有 bot 或當場開一隻新的。
    private var partnerRow: some View {
        FlowRow(spacing: 7) {
            Text("跟誰談").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .frame(height: 24)
            BotStudioPartnerChip(
                emoji: "＋", title: "開一隻新的",
                selected: state.bindPartnerID == nil) { state.bindPartnerID = nil }
            ForEach(state.allBots) { unit in
                BotStudioPartnerChip(
                    emoji: unit.emoji, title: unit.name,
                    selected: state.bindPartnerID == unit.id) { state.bindPartnerID = unit.id }
            }
        }
    }
}

/// 跟 bot／群講話的輸入框＝chat 分頁原版 composer 搬用（使用者 2026-09-09 指定
/// 的那一個）：ChatComposerTextView 本體＋工具列（＋／代我核准／模型／派工方式／
/// 送出）＋底下梯形狀態列。差異只有送出是展示 no-op。
struct BotStudioComposer: View {
    @Binding var text: String
    var placeholder: String
    var modelLabel: String
    var modelTier: String = "fast"
    var scopeLabel: String
    var statusText: String = "Gen-5 展示・未接入"
    var onSubmit: () -> Void

    @State private var height: CGFloat = 0
    @State private var focused = false

    private var ready: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let minH = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
        let maxH = TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight
        let effective = min(maxH, max(minH, height))
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(
                    text: $text,
                    contentHeight: $height,
                    isFocused: focused,
                    placeholder: placeholder,
                    isMonospaced: false,
                    minimumHeight: minH,
                    maximumHeight: maxH,
                    onSubmit: { onSubmit() },
                    onFocusChange: { focused = $0 })
                    .frame(height: effective)
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 8)
                toolbar
                    .padding(.horizontal, 11)
                    .padding(.bottom, 8)
            }
            .frame(minHeight: TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)

            statusBar
                .zIndex(-1)
                .padding(.top, -13)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Menu {
                Button { } label: { Label("貼上剪貼簿圖片（展示）", systemImage: "doc.on.clipboard") }
                    .disabled(true)
                Button { } label: { Label("附加檔案…（展示）", systemImage: "paperclip") }
                    .disabled(true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("加入內容（展示）")

            Button { } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 11, weight: .bold))
                    Text("代我核准").font(.caption2.weight(.black)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .black)).opacity(0.82)
                }
                .foregroundStyle(Color.orange.opacity(0.86))
                .padding(.horizontal, 7)
                .frame(height: 24)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .help("展示模式・權限未生效")

            Spacer(minLength: 14)

            // 這隻用哪個模型跑（chat 分頁模型選單同語言）。
            Button { } label: {
                HStack(spacing: 6) {
                    Text(modelLabel).font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                    Text(modelTier).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .black)).opacity(0.8)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .chatGlassChip()
            .help("這隻用哪個模型跑（展示・切換未生效）")

            // 自己做還是找群一起（對應 chat 的 ultrawork 選單位置）。
            Button { } label: {
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle").font(.system(size: 10, weight: .bold)).opacity(0.75)
                    Text(scopeLabel).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .black)).opacity(0.8)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .chatGlassChip()
            .help("自己做，還是找群一起（展示・切換未生效）")

            Button { onSubmit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(ready ? Color.primary.opacity(0.8) : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .background { Circle().fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity)) }
            .overlay { Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity)) }
            .help("送出（展示・不會真的派工）")
        }
        .frame(height: 28)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.secondary.opacity(0.72)).frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background {
            BotStudioInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                .fill(Color.primary.opacity(0.075))
        }
        .overlay {
            BotStudioInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .padding(.horizontal, 14)
    }
}

struct BotStudioPartnerChip: View {
    let emoji: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(emoji).font(.system(size: 11))
                Text(title).font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.opacity(selected ? 0.95 : 0.3)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(selected ? 0.24 : 0.10), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BotStudioPlanCard: View {
    let title: String
    let caption: String
    let rows: [String]
    var numbered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .bold))
                Text(caption).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 9) {
                    if numbered {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.primary.opacity(0.06)))
                    } else {
                        Text("？").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    Text(row).font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - 建 bot 六步（臨時工轉常駐才走）

struct BotStudioWizardPane: View {
    @ObservedObject var state: BotStudioState

    private let titles = ["名字與頭像", "用哪個模型跑", "一句話職責", "放進哪個小組", "給哪些工具", "看得懂再建立"]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("轉常駐").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.leading, 8).padding(.bottom, 6)
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Button { state.wizardGo(index) } label: {
                        HStack(spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .frame(width: 19, height: 19)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == state.wizardStep
                                          ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.06)))
                                .foregroundStyle(index == state.wizardStep ? Color.white : Color.secondary)
                            Text(title).font(.system(size: 12.5))
                                .foregroundStyle(index == state.wizardStep ? Color.primary : Color.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(index == state.wizardStep
                                    ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 176)

            VStack(alignment: .leading, spacing: 12) {
                Text(titles[state.wizardStep]).font(.system(size: 14, weight: .bold))
                stepBody
                Spacer(minLength: 0)
                HStack(spacing: 9) {
                    BotStudioButton(title: "取消", prominent: false) { state.cancelWizard() }
                    Spacer(minLength: 0)
                    if state.wizardStep > 0 {
                        BotStudioButton(title: "上一步", prominent: false) { state.wizardGo(state.wizardStep - 1) }
                    }
                    if state.wizardStep < 5 {
                        BotStudioButton(title: "下一步", prominent: true) { state.wizardGo(state.wizardStep + 1) }
                    } else {
                        BotStudioButton(title: "建立這隻 bot", prominent: true) { state.finishWizard() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch state.wizardStep {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                BotStudioField(label: "名字", text: $state.wizardName, placeholder: "生圖 bot")
                VStack(alignment: .leading, spacing: 6) {
                    Text("頭像").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ForEach(BotStudioFixture.avatarChoices, id: \.self) { emoji in
                            Button { state.wizardEmoji = emoji } label: {
                                BotAvatar(emoji: emoji, size: 26, selected: state.wizardEmoji == emoji)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("臨時工帶過來的名字和一句話任務會先填好，改不改都行。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                BotStudioChipRow(options: BotStudioFixture.engines,
                                 isOn: { $0 == state.wizardEngine },
                                 tap: { state.wizardEngine = $0 })
                Text("跟 chat 分頁同一套模型清單。重複性高的工作不用給最貴的。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                BotStudioField(label: "這隻負責什麼", text: $state.wizardDuty,
                               placeholder: "照素材規格出圖，出完丟進待發布區，不自己發布。")
                Text("這句話會直接變成它的行事準則，寫得越具體它越不會亂跑。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case 3:
            VStack(alignment: .leading, spacing: 10) {
                BotStudioChipRow(options: state.allFolders.map(\.id),
                                 label: { state.folderPath($0) },
                                 isOn: { $0 == state.wizardFolderID },
                                 tap: { state.wizardFolderID = $0 })
                if let role = state.role(forFolder: state.wizardFolderID) {
                    BotStudioConfirmCard(lines: [
                        (true, "拿到身份組「\(role.name)」的權限與視野"),
                        (false, "看不到其他部門的東西"),
                    ])
                }
                Text("一隻 bot 只能放一個部門／小組——權限來源只能有一個，不然算不出來。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case 4:
            VStack(alignment: .leading, spacing: 10) {
                BotStudioChipRow(options: BotStudioFixture.skills,
                                 isOn: { state.wizardSkills.contains($0) },
                                 tap: { state.toggleWizardSkill($0) })
                Text("從 skillet 主根登記，不是複製一份。主根更新了它就跟著更新。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                BotStudioConfirmCard(lines: confirmLines)
                Text("看得懂再按。這裡不給設定表——那是 Discord 的 bot 要跑在別人家才需要的東西。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var confirmLines: [(Bool, String)] {
        let folder = state.folderPath(state.wizardFolderID ?? "")
        let role = state.role(forFolder: state.wizardFolderID)
        var lines: [(Bool, String)] = [
            (true, "\(state.wizardName.isEmpty ? "這隻 bot" : state.wizardName) 放在「\(folder)」，用 \(state.wizardEngine) 跑"),
        ]
        if let role {
            for grant in role.permissions where state.grantState(role: role, grant: grant) != .off {
                lines.append((true, "能\(grant.label)"))
            }
            for grant in role.permissions where state.grantState(role: role, grant: grant) == .off {
                lines.append((false, "不能\(grant.label)"))
            }
            for grant in role.vision where state.grantState(role: role, grant: grant) == .off {
                lines.append((false, "看不到\(grant.label)"))
            }
        }
        if !state.wizardSkills.isEmpty {
            lines.append((true, "會用：\(state.wizardSkills.sorted().joined(separator: "、"))"))
        }
        return lines
    }
}

// MARK: - 資料夾設定＝身份組（權限 × 視野）

struct BotStudioRolePane: View {
    @ObservedObject var state: BotStudioState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("部門／小組設定").font(.system(size: 14, weight: .bold))
                if let fid = state.roleFolderID {
                    Text(state.folderPath(fid)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu("從別間工作室套一份") {
                    ForEach(state.spaces) { space in
                        ForEach(space.roles) { role in
                            Button("\(space.name)・\(role.name)") { }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 11))
                .frame(width: 150)
                .help("套過來當起點，之後各改各的、不連動")
                Button("完成") { state.mode = .studio }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            BotStudioChipRow(options: state.allFolders.map(\.id),
                             label: { state.folderPath($0) },
                             isOn: { $0 == state.roleFolderID },
                             tap: { state.roleFolderID = $0 })

            if let role = state.role(forFolder: state.roleFolderID) {
                HStack(alignment: .top, spacing: 12) {
                    axisCard(title: "權限", subtitle: "能動什麼", role: role, grants: role.permissions)
                    axisCard(title: "視野", subtitle: "知道什麼", role: role, grants: role.vision)
                }
                if let fid = state.roleFolderID, let parent = state.parentFolder(of: fid) {
                    Text("橘色那條是從部門「\(parent.name)」繼承來的，小組只能關掉，不能打開。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("關掉的視野那條，bot 連「有這份東西存在」都不知道。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                BotStudioEmpty(symbol: "folder", title: "這個 bot space 還沒有部門", detail: nil, action: nil)
            }
            Spacer(minLength: 0)
        }
    }

    private func axisCard(title: String, subtitle: String, role: BotRole, grants: [BotGrant]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(grants) { grant in
                let value = state.grantState(role: role, grant: grant)
                Button { state.toggleGrant(role: role, grant: grant) } label: {
                    HStack(spacing: 10) {
                        Text(grant.label).font(.system(size: 12.5))
                            .foregroundStyle(value == .off ? Color.secondary : Color.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        BotStudioSwitch(value: value)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - 成員頭像（進小組的第一眼）

struct BotStudioMemberRow: View {
    let bots: [BotUnit]
    let onBot: (String) -> Void

    var body: some View {
        if bots.isEmpty {
            Text("這個小組還沒有人。用側欄那一層的 ＋ 加一隻。")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 14) {
                ForEach(bots) { unit in
                    Button { onBot(unit.id) } label: {
                        VStack(spacing: 5) {
                            BotAvatar(emoji: unit.emoji, size: 36)
                            Text(unit.name).font(.system(size: 11)).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("單獨跟「\(unit.name)」講話")
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 這個 bot space 的設定

struct BotStudioSpaceSettingsPane: View {
    @ObservedObject var state: BotStudioState
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("bot space 設定").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                Button("完成") { state.mode = .studio }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            BotStudioField(label: "名字", text: $draftName, placeholder: state.space.name)
            BotStudioButton(title: "改名字", prominent: false) { state.renameSpace(draftName) }

            VStack(alignment: .leading, spacing: 8) {
                Text("這個 bot space 的工作室").font(.system(size: 12.5, weight: .bold))
                if state.studios.isEmpty {
                    Text("還沒綁。用 app 右緣的工作室書籤 ＋ 接一個進來。")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    ForEach(state.studios) { studio in
                        HStack(spacing: 9) {
                            Text(studio.emoji)
                            Text(studio.name).font(.system(size: 12.5))
                            Text(studio.target).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Circle().fill(studio.health.tint).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("部門").font(.system(size: 12.5, weight: .bold))
                ForEach(state.space.folders) { dept in
                    HStack(spacing: 9) {
                        Text(dept.name).font(.system(size: 12.5))
                        Text(state.space.role(dept.roleID)?.name ?? "—")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button("身份組") { state.openRoleSettings(folderID: dept.id) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if state.space.folders.isEmpty {
                    Text("還沒有部門。").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.primary.opacity(0.10), lineWidth: 1))

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 共用小元件

struct BotStudioKindChip: View {
    let kind: BotStudioKind
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol).font(.system(size: 9))
            Text(kind.label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 999, style: .continuous)
            .stroke(.primary.opacity(0.14), lineWidth: 1))
    }
}

struct BotStudioNotice: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(BotHealth.warn.tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(BotHealth.warn.tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(BotHealth.warn.tint.opacity(0.55), lineWidth: 1))
    }
}

struct BotStudioFakeWeb: View {
    let title: String
    let cells: [String]

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            if cells.isEmpty {
                Text("還沒接上任何東西。位置和權限給了之後，這裡就會是那個系統的畫面。")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(cells, id: \.self) { cell in
                    Text(cell)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 108)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.primary.opacity(0.08), lineWidth: 1))
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }
}

struct BotStudioSayRow: View {
    let say: BotStudioSay
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            BotAvatar(emoji: say.emoji, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(say.who).font(.system(size: 11.5, weight: .semibold))
                Text(say.text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(.primary.opacity(0.09), lineWidth: 1))
    }
}

struct BotStudioCharterCard: View {
    let charter: String
    let members: [BotUnit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("小組規範").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: -6) {
                    ForEach(members) { m in BotAvatar(emoji: m.emoji, size: 20) }
                }
            }
            .foregroundStyle(.secondary)
            Text(charter).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }
}

struct BotStudioBrief: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
    }
}

struct BotStudioConfirmCard: View {
    let lines: [(Bool, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: line.0 ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(line.0 ? BotHealth.run.tint : Color.secondary)
                        .frame(width: 14)
                    Text(line.1).font(.system(size: 12.5))
                        .foregroundStyle(line.0 ? Color.primary.opacity(0.9) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.background.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(.primary.opacity(0.10), lineWidth: 1))
    }
}

struct BotStudioField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.primary.opacity(0.14), lineWidth: 1))
        }
    }
}

struct BotStudioChipRow: View {
    let options: [String]
    var label: (String) -> String = { $0 }
    let isOn: (String) -> Bool
    let tap: (String) -> Void

    var body: some View {
        FlowRow(spacing: 7) {
            ForEach(options, id: \.self) { option in
                Button { tap(option) } label: {
                    Text(label(option))
                        .font(.system(size: 12.5))
                        .foregroundStyle(isOn(option) ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.background.opacity(isOn(option) ? 0.95 : 0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.primary.opacity(isOn(option) ? 0.26 : 0.12), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 會自動換行的橫排（chip 用；避免固定欄數把長標籤擠掉）。
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct BotStudioSwitch: View {
    let value: BotGrantState

    private var fill: Color {
        switch value {
        case .on: BotHealth.run.tint
        case .inherited: Color(red: 0.867, green: 0.565, blue: 0.478)   // 珊瑚橘＝繼承
        case .off: Color.primary.opacity(0.16)
        }
    }

    var body: some View {
        Capsule()
            .fill(fill)
            .frame(width: 33, height: 19)
            .overlay(alignment: value == .off ? .leading : .trailing) {
                Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .help(value == .inherited ? "從父資料夾繼承，只能關掉" : (value == .on ? "開" : "關"))
    }
}

struct BotStudioButton: View {
    let title: String
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Color.secondary)
                .padding(.horizontal, 15).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1))
                .opacity(disabled ? 0.45 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct BotStudioEmpty: View {
    let symbol: String
    let title: String
    var detail: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            if let action {
                BotStudioButton(title: "接一個新東西進來", prominent: true, action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// composer 底下那條狀態列的形狀：跟 chat 分頁同款倒梯形。
/// （BotPage.swift 那份是 private，這裡自帶一份，幾何完全一致。）
struct BotStudioInvertedTrapezoid: Shape {
    var sideSlope: CGFloat = 14
    var cornerRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let pts = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX - sideSlope, y: rect.maxY),
            CGPoint(x: rect.minX + sideSlope, y: rect.maxY),
        ]
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = Swift.max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: dx / len, y: dy / len)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var path = Path()
        let n = pts.count
        for i in 0..<n {
            let curr = pts[i]
            let prev = pts[(i - 1 + n) % n]
            let next = pts[(i + 1) % n]
            let r = (i <= 1) ? 0 : Swift.min(cornerRadius, dist(prev, curr) / 2, dist(next, curr) / 2)
            let toPrev = unit(curr, prev), toNext = unit(curr, next)
            let p1 = CGPoint(x: curr.x + toPrev.x * r, y: curr.y + toPrev.y * r)
            let p2 = CGPoint(x: curr.x + toNext.x * r, y: curr.y + toNext.y * r)
            if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
            if r > 0 { path.addQuadCurve(to: p2, control: curr) }
        }
        path.closeSubpath()
        return path
    }
}
