// 2.0 新畫面（不是照搬）：右側資訊卡的 issue 清單重設計（使用者 2026-09-05：「又小又不直觀」）。
// 1.0 語意保留：入列不執行；/issue 與＋快速記；@ 全域可搜；封存＝雙擊＋確認；來源討論不會被刪改。
import SwiftUI

struct IssueQueueCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var bodyDrafts: [String: String] = [:]
    @State private var expanded: Set<String> = []
    @State private var hovering: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let focused = model.issueListEntries.first(where: { $0.id == model.focusedIssueEntryID }) {
                pinned(focused)
            }
            if model.visibleIssueListEntries.isEmpty {
                Text(model.issueListShowsGlobal ? "全域佇列是空的；輸入框打 /issue <文字> 或按右上角＋捕捉。" : "本串沒有 issue；輸入框打 /issue <文字>，或 @ 叫出全域。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.visibleIssueListEntries) { entry in
                        row(entry)
                    }
                }
            }
        }
        .onAppear { model.reloadIssueList() }
    }

    // MARK: 標題列：本串／全域、數量、＋捕捉

    private var header: some View {
        HStack(spacing: 8) {
            Text("Issue List")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text("\(model.visibleIssueListEntries.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            Spacer(minLength: 0)
            Picker("", selection: Binding(get: { model.issueListShowsGlobal }, set: { model.issueListShowsGlobal = $0 })) {
                Text("本串").tag(false)
                Text("全域").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 96)
            .labelsHidden()
            Button {
                model.captureCurrentDiscussionIntoIssueList()
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("把這條討論串目前的問題與結論記成一筆（只記，不會開始做）")
        }
    }

    // MARK: 一筆

    private func row(_ entry: TatwoIssueListEntryV1) -> some View {
        let isOpen = expanded.contains(entry.id)
        let isHover = hovering == entry.id
        let isOtherThread = entry.threadReference != model.selectedThreadID?.uuidString
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(isOpen ? nil : 2)
                    if !isOpen, !entry.body.isEmpty {
                        Text(entry.body)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(entry.sourceType == .plan ? "來自計畫" : "來自對話")
                        if isOtherThread, model.issueListShowsGlobal { Text("・其他討論串") }
                        Text("・\(Self.stamp(entry.createdAt))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if isHover || isOpen {
                    HStack(spacing: 4) {
                        actionButton("arrow.down.to.line", "放進輸入框") { model.packIssueIntoComposer(entry) }
                        if isOtherThread, let ref = entry.threadReference, let id = UUID(uuidString: ref) {
                            actionButton("bubble.left.and.text.bubble.right", "開啟來源討論串") { model.selectedThreadID = id }
                        }
                        actionButton("archivebox", "封存（會再問一次確認）") { model.archiveIssueListEntry(entry.id) }
                    }
                }
            }
            if isOpen {
                // 1.0 邏輯：展開即可改內文，改了才出現「儲存」
                TextEditor(text: Binding(
                    get: { bodyDrafts[entry.id] ?? entry.body },
                    set: { bodyDrafts[entry.id] = $0 }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
                .padding(.leading, 17)
                if let draft = bodyDrafts[entry.id], draft != entry.body {
                    HStack {
                        Spacer(minLength: 0)
                        Button("儲存") { model.updateIssueListEntryBody(entry.id, body: draft); bodyDrafts[entry.id] = nil }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                    }
                    .padding(.leading, 17)
                }
                if !model.issueImageURLs(for: entry).isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.issueImageURLs(for: entry), id: \.path) { url in
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                    .padding(.leading, 17)
                }
                HStack(spacing: 8) {
                    Button("附加圖片…") { model.addImageNotes(to: entry) }
                        .buttonStyle(.borderless).controlSize(.mini)
                    Spacer()
                }
                .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            (isOpen ? LiquidGlassTokens.brandAccent.opacity(0.07) : Color.secondary.opacity(isHover ? 0.08 : 0.045)),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        }
        .onHover { hovering = $0 ? entry.id : (hovering == entry.id ? nil : hovering) }
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: @ 釘選

    private func pinned(_ focused: TatwoIssueListEntryV1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text(focused.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Button { model.focusedIssueEntryID = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("解除釘選")
            }
            if !focused.body.isEmpty {
                Text(focused.body).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button("放進輸入框") { model.packIssueIntoComposer(focused) }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(8)
        .background(LiquidGlassTokens.brandAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static func stamp(_ date: Date) -> String {
        let now = ChatPageModel.exportChatScene != nil || ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            ? Date(timeIntervalSinceReferenceDate: 800_000_000) : Date()
        let s = Int(now.timeIntervalSince(date))
        if s < 3_600 { return "\(max(1, s / 60)) 分鐘前" }
        if s < 86_400 { return "\(s / 3_600) 小時前" }
        let f = DateFormatter(); f.dateFormat = "MM-dd"; return f.string(from: date)
    }
}
