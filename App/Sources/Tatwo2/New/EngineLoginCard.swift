// 2.0 新畫面（不是照搬）：設定頁「模型登入」— 三家引擎各自登入／登出、額度條、禁用 API。
// 使用者 2026-09-05：標題改「模型登入」、GPT 改 OpenAI、少註解、額度條、列向左拖拽出「禁用 API」、登出鈕重設計並上下置中。
import SwiftUI

struct EngineLoginCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var loginInput = ""
    @State private var confirmResetCredit = false

    private let kinds: [ClaudeSidecar.Kind] = [.codex, .claude, .grok]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("模型登入")
                    .font(.title3.bold())
                Spacer()
                Button("重新檢查") { model.refreshEngineLogins(); model.refreshEngineQuotas() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            VStack(spacing: 0) {
                ForEach(kinds, id: \.rawValue) { kind in
                    SwipeRevealRow(revealWidth: 112, isRevealedInitially: false) {
                        row(kind)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                    } reveal: {
                        VStack(spacing: 4) {
                            Button {
                                model.toggleEngineDisabled(kind)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: model.isEngineDisabled(kind) ? "checkmark.circle" : "nosign")
                                    Text(model.isEngineDisabled(kind) ? "解除禁用" : "禁用 API")
                                }
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                                .foregroundStyle(.white)
                                .background(model.isEngineDisabled(kind) ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)   // 以後的開關往下塞
                        }
                        .padding(6)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.secondary.opacity(0.06))
                    }
                    Divider().opacity(0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.engineLoginInProgress != nil {
                loginProgress
            }

            Text("往左拖一列可以「禁用 API」：禁用後這家一句都不會送出，額度用完也不會亂燒。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refreshEngineLogins(); model.refreshEngineQuotas() }
    }

    // MARK: 一列

    @ViewBuilder
    private func row(_ kind: ClaudeSidecar.Kind) -> some View {
        let status = model.engineLogins.first(where: { $0.kind == kind })
        let loggedIn = status?.isLoggedIn ?? false
        let disabled = model.isEngineDisabled(kind)
        let detail = model.engineQuotaDetails[kind.rawValue]
        let account = detail?.accountLabel ?? status?.account
        HStack(alignment: .center, spacing: 12) {
            // 各家 logo 取代小圓點（使用者 2026-09-05）；未登入變淡、禁用加紅圈
            ZStack {
                if let logo = ProviderSVGIconLoader.image(for: Self.logoID(kind)) {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)      // SVG 是單色，淺色主題要跟著文字色，不然看不見
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                } else {
                    Text(String(Self.title(kind).prefix(1)))
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                }
            }
            .opacity(loggedIn ? 1 : 0.35)
            .overlay(
                Circle().stroke(Color.red.opacity(disabled ? 0.8 : 0), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            )

            VStack(alignment: .leading, spacing: 6) {
                // 第一行：名字・等級（純文字）・到期
                HStack(spacing: 10) {
                    Text(Self.title(kind))
                        .font(.subheadline.weight(.semibold))
                    Text(detail?.tierLabel ?? Self.plan(kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let expires = detail?.expiresAt {
                        Text("到期 \(Self.day(expires))").font(.caption).foregroundStyle(.tertiary)
                    } else if let since = detail?.subscribedAt {
                        Text("訂閱起 \(Self.day(since))").font(.caption).foregroundStyle(.tertiary)
                    }
                    if disabled {
                        Text("已禁用 API")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                // 第二行：帳號，靠左
                Text(loggedIn ? (account ?? "已登入") : "未登入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail, !detail.windows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.windows) { w in windowBar(w) }
                    }
                    .padding(.top, 2)
                    if let credits = detail.creditsBalance {
                        Text("點數 \(credits)").font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .codex {
                        HStack(spacing: 6) {
                            Text("重置券：OpenAI 沒給查詢接口；OS 絕不會自動用。")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Button("使用一張重置券…") { confirmResetCredit = true }
                                .buttonStyle(.link).font(.caption2)
                        }
                    }
                } else if loggedIn {
                    Text(detail?.note.isEmpty == false ? detail!.note : "額度讀取中…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if model.engineLoginInProgress == kind {
                    ProgressView().controlSize(.small)
                } else if loggedIn {
                    Button {
                        model.logoutEngine(kind)
                    } label: {
                        Text("登出")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("登入") { model.loginEngine(kind) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.engineLoginInProgress != nil)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .opacity(disabled ? 0.6 : 1)
        .alert("確定要用掉一張重置券？", isPresented: $confirmResetCredit) {
            Button("取消", role: .cancel) {}
            Button("用掉", role: .destructive) { model.consumeOpenAIResetCredit() }
        } message: {
            Text("這是 OpenAI 給的「額度重置券」，用掉就沒了。你說過要留給 GPT-6，確定現在用？")
        }
    }

    private func windowBar(_ w: EngineQuotaDetail.Window) -> some View {
        let remaining = max(0, min(100, 100 - w.usedPercent))
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView(value: remaining, total: 100)
                    .progressViewStyle(.linear)
                    .tint(remaining < 15 ? .red : (remaining < 40 ? .orange : .accentColor))
                    .frame(width: 120)
                Text("剩 \(Int(remaining.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            Text(w.resetsAt.map { "重置 \(Self.countdown($0))" } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(w.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .trailing)
        }
    }

    // MARK: 登入進度

    private var loginProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("登入中… 瀏覽器會自己打開；沒開的話把下面的網址貼到瀏覽器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.engineLoginLog.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField("輸入驗證碼", text: $loginInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("送出") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(loginInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func submit() {
        model.submitEngineLoginInput(loginInput)
        loginInput = ""
    }

    private static func title(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .grok: "Grok"
        }
    }

    private static func plan(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "ChatGPT 訂閱"
        case .claude: "Claude 訂閱"
        case .grok: "SuperGrok 訂閱"
        }
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    private static func countdown(_ date: Date) -> String {
        let now = ChatPageModel.exportChatScene != nil || ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            ? Date(timeIntervalSinceReferenceDate: 800_000_000) : Date()
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "現在" }
        if s < 3_600 { return "\(s / 60) 分後" }
        if s < 86_400 { return "\(s / 3_600) 小時 \((s % 3_600) / 60) 分後" }
        return "\(s / 86_400) 天 \((s % 86_400) / 3_600) 小時後"
    }

    private static func logoID(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "codex-gpt"
        case .claude: "claude"
        case .grok: "grok"
        }
    }

    private static func quotaID(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: "codex-gpt"
        case .claude: "claude"
        case .grok: "grok"
        }
    }
}

/// 一列往左拖，底下露出動作鈕（macOS 的 List.swipeActions 在這種卡片裡畫不出來，所以自己做）。
struct SwipeRevealRow<Content: View, Reveal: View>: View {
    let revealWidth: CGFloat
    let isRevealedInitially: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let reveal: () -> Reveal

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat = 0

    init(revealWidth: CGFloat, isRevealedInitially: Bool,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder reveal: @escaping () -> Reveal) {
        self.revealWidth = revealWidth
        self.isRevealedInitially = isRevealedInitially
        self.content = content
        self.reveal = reveal
        _offset = State(initialValue: isRevealedInitially ? -revealWidth : 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            reveal()
                .frame(width: revealWidth)
                .opacity(offset < -8 ? 1 : 0)
            content()
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let proposed = dragStart + value.translation.width
                            offset = max(-revealWidth, min(0, proposed))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                offset = offset < -revealWidth * 0.45 ? -revealWidth : 0
                            }
                            dragStart = offset
                        }
                )
                .onTapGesture {
                    if offset != 0 {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { offset = 0 }
                        dragStart = 0
                    }
                }
        }
        .clipped()
    }
}
