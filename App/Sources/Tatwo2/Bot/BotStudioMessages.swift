import SwiftUI
import AppKit

// bot 私訊（沿用 Gen-4 的資產：右下浮鈕展開的 X 平台 Messages 式小視窗）。
// 清單列出這個 space 的群與 bot；點一列進窗內 DM 頁，不切主畫面。
// 純 UI：輸入列只是示意，沒有接任何東西。

struct BotStudioMessagesFAB: View {
    @ObservedObject var state: BotStudioState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if state.dmOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { state.closeDM() }
            }
            VStack(alignment: .trailing, spacing: 10) {
                if state.dmOpen {
                    BotStudioMessagesPanel(state: state)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Button { withAnimation(.easeOut(duration: 0.16)) { state.toggleDM() } } label: {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .overlay(Circle().stroke(.primary.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help("bot 私訊（展示）")
            }
            .padding(.trailing, 12)
            .padding(.bottom, 8)
        }
    }
}

struct BotStudioMessagesPanel: View {
    @ObservedObject var state: BotStudioState

    var body: some View {
        Group {
            if let target = state.dmTargetID {
                dmView(target)
            } else {
                listView
            }
        }
        .frame(width: 320, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: 清單

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("bot").font(.system(size: 16, weight: .bold))
                Text(state.space.name).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button { state.closeDM() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.allBots) { unit in
                        row(emoji: unit.emoji, title: unit.name,
                            detail: unit.duty, health: unit.health) { state.openDM(unit.id) }
                    }
                    if state.allBots.isEmpty {
                        Text("這個 space 還沒有 bot")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 28)
                    }
                }
                .padding(8)
            }
            Text("私訊（展示・未接入）")
                .font(.system(size: 10)).foregroundStyle(.quaternary)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func row(emoji: String, title: String, detail: String,
                     health: BotHealth?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                BotAvatar(emoji: emoji, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let health {
                    Circle().fill(health.tint).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 窗內 DM 頁

    private func dmView(_ id: String) -> some View {
        let unit = state.bot(id)
        let title = unit?.name ?? "bot"
        let emoji = unit?.emoji ?? "🤖"
        let says = BotStudioFixture.thread(for: title)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { state.dmTargetID = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回清單")
                BotAvatar(emoji: emoji, size: 24)
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(says.enumerated()), id: \.offset) { _, say in
                        HStack(alignment: .top, spacing: 8) {
                            BotAvatar(emoji: say.emoji, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(say.who).font(.system(size: 11, weight: .semibold))
                                Text(say.text).font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
            }

            HStack(spacing: 8) {
                Text("私訊（展示・未接入）")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "paperplane")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
    }
}
