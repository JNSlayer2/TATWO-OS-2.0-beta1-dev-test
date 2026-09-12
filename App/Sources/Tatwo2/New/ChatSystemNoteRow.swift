import SwiftUI

/// OS 自己講的話（權限已允許、監工提醒、支線摘要…）不用氣泡：一行小字、前面一個小圖示。
/// 只接 status 是 `done|…` 或 `info|…` 的系統訊息；錯誤走 ChatErrorCard，其餘照舊。
struct ChatSystemNotePresentation: Equatable {
    let symbol: String
    let tag: String
    let text: String

    static func resolve(_ message: ChatMessage) -> ChatSystemNotePresentation? {
        guard message.role == .system,
              let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = status.split(separator: "|", maxSplits: 1).map(String.init)
        guard let kind = parts.first?.lowercased(), kind == "done" || kind == "info" else { return nil }
        let tag = parts.count > 1 ? parts[1] : ""
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let symbol: String
        switch tag {
        case "權限": symbol = text.hasPrefix("拒絕") ? "hand.raised" : "checkmark.shield"
        case "監工": symbol = "eye"
        case "支線摘要": symbol = "arrow.triangle.branch"
        default: symbol = kind == "done" ? "checkmark.circle" : "info.circle"
        }
        return ChatSystemNotePresentation(symbol: symbol, tag: tag, text: text)
    }
}

struct ChatSystemNoteRow: View {
    let presentation: ChatSystemNotePresentation
    let rowWidth: CGFloat?
    @State private var expanded = false

    private var isLong: Bool { presentation.text.count > 120 || presentation.text.contains("\n") }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if !presentation.tag.isEmpty {
                Text(presentation.tag)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Text(presentation.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(expanded ? "收起" : "展開") {
                    withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(width: rowWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.tag) \(presentation.text)")
    }
}
