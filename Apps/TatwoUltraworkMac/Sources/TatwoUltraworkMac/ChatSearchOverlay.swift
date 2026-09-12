import SwiftUI
import TatwoUltraworkCore

// ② 全文搜尋 overlay（Codex parity + OS 化）：跨 thread（含獨立對話）全文搜尋，
// 結果顯示來源徽章＋標題＋片段＋時間，點擊跳到該對話。CLI 歷史後端已備，v1 先搜對話。
// 視窗內 overlay（非 NSPopover），headless 可渲染；fable5 走 liquidGlassSurface 自動分材質。
struct TatwoChatSearchOverlay: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    /// 開啟當下建一次索引（避免每次擊鍵重建）；回傳 nil 代表尚未備妥。
    let indexProvider: () -> TatwoChatSearchIndex
    let onJump: (TatwoChatSearchDocument) -> Void
    let onClose: () -> Void

    @State private var query: String =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_SEARCH_QUERY"] ?? ""
    @State private var index: TatwoChatSearchIndex?
    @FocusState private var fieldFocused: Bool

    private var results: [TatwoChatSearchResult] {
        guard let index else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        return index.search(TatwoChatSearchQuery(rawText: trimmed, scope: .all, resultLimit: 60))
    }

    var body: some View {
        ZStack {
            // 點暗幕關閉
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            panel
                .frame(maxWidth: 580)
                .padding(.horizontal, 40)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            index = indexProvider()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
        .frame(maxHeight: 540)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
        .shadow(color: .black.opacity(0.22), radius: 26, x: 0, y: 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
            TextField("搜尋對話內容…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($fieldFocused)
                .onSubmit { if let first = results.first { onJump(first.source) } }
            if !query.isEmpty {
                Text("\(results.count) 筆")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("關閉（Esc）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            emptyState(icon: "text.magnifyingglass", text: "輸入關鍵字，搜尋所有對話內文與標題")
        } else if results.isEmpty {
            emptyState(icon: "tray", text: "找不到符合「\(trimmed)」的結果")
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(results) { result in
                        Button { onJump(result.source) } label: { row(result) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .padding(.horizontal, 24)
    }

    private func row(_ result: TatwoChatSearchResult) -> some View {
        let doc = result.source
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon(for: doc.sourceKind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .frame(width: 20, height: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(doc.title.isEmpty ? kindLabel(doc.sourceKind) : doc.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let ts = doc.timestamp {
                        Text(Self.dateFormatter.string(from: ts))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(result.snippet)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LiquidGlassTokens.brandAccent.opacity(0.001))
        )
    }

    private func icon(for kind: TatwoChatSearchSourceKind) -> String {
        switch kind {
        case .project: return "folder"
        case .thread: return "bubble.left.and.bubble.right"
        case .message: return "text.bubble"
        case .attachment: return "paperclip"
        case .cliCommand: return "terminal"
        }
    }

    private func kindLabel(_ kind: TatwoChatSearchSourceKind) -> String {
        switch kind {
        case .project: return "專案"
        case .thread: return "對話"
        case .message: return "訊息"
        case .attachment: return "附件"
        case .cliCommand: return "CLI 指令"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
}
