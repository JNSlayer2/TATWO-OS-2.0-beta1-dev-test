import SwiftUI

/// Bot 接續便條：打開一隻 bot 先看「上次做到哪、下一步、還沒解決的、等你確認的記憶」。
/// 資料來自 BotMemory.resumeNote；找不到對應的 bot 時誠實顯示「還沒有紀錄」。
struct BotResumeNoteCard: View {
    let botID: String?
    let botName: String?
    @State private var note: BotResumeNote?
    @State private var resolvedID: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("接續便條")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let note, note.pendingCount > 0 {
                    Text("\(note.pendingCount) 條記憶等你確認")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
            }
            if !libraryAvailable {
                Text("這隻 bot 還沒有工作紀錄；開始對話後會自動記。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let note {
                row("上次做到", note.currentTask ?? "還沒記錄")
                if !note.nextSteps.isEmpty { row("下一步", note.nextSteps.prefix(3).joined(separator: "；")) }
                if !note.openQuestions.isEmpty { row("還沒解決", note.openQuestions.prefix(3).joined(separator: "；")) }
                if let at = note.lastSessionAt {
                    Text("上次 \(Self.relative(at))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(loaded ? "這隻 bot 還沒有工作紀錄；開始對話後會自動記。" : "讀取中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(ChatUILayout.quietFillOpacity), in: RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .task(id: selectionKey) { if libraryAvailable { await load() } }
        .accessibilityElement(children: .combine)
    }

    /// 金樣／非 live 沒有 Bot 資料層：直接顯示最終字，不走非同步（截圖才穩定）。
    private var libraryAvailable: Bool { BotUIWire.isLive && CLISessionsTermination.model?.botLibraryForBridge != nil }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(.caption2)
                .lineLimit(2)
        }
    }

    private var selectionKey: String { (botID ?? "") + "|" + (botName ?? "") }

    private func load() async {
        // 切換 bot 先清掉舊便條，避免短暫顯示另一隻的內容
        note = nil; resolvedID = nil; loaded = false
        let key = selectionKey
        guard let library = await MainActor.run(body: { CLISessionsTermination.model?.botLibraryForBridge }) else { loaded = true; return }
        let id = botID
        await library.ready()   // 隔離 UI 驗收 2026-09-06 抓到：資料層還在背景載入時 snapshot 是空的，卡會誤判「還沒有紀錄」
        let result: (String, BotResumeNote)? = await Task.detached(priority: .utility) {
            let bots = library.snapshot.bots
            guard let bot = bots.first(where: { $0.id == id }) else { return nil }
            return (bot.id, BotMemory(library: library).resumeNote(botID: bot.id))
        }.value
        guard key == selectionKey else { return }   // 回來時使用者已切到別的 bot：丟棄，不套用
        resolvedID = result?.0
        note = result?.1
        loaded = true
    }

    static func relative(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: iso) }()
        guard let date else { return iso }
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .short
        return r.localizedString(for: date, relativeTo: Date())
    }
}
