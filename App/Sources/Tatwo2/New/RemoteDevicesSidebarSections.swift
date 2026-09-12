// 2.0 新畫面（不是照搬）：左列「本機專案」底下，每台已配對設備各一段，列它的專案與討論串；點了就在那台跑。
// 使用者 2026-09-05：遠端跟本地並行，不做遙控模式開關。
import SwiftUI

struct RemoteDevicesSidebarSections: View {
    @ObservedObject var model: ChatPageModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        ForEach(model.remoteSidebarSections) { section in
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed(section) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(section.deviceName)
                            .font(ChatTypography.sidebarProject)
                            .lineLimit(1)
                        Circle()
                            .fill(section.isOnline ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Spacer()
                        if !section.isOnline {
                            Text("離線・\(Self.seen(section.lastSeenAt))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !isCollapsed(section), section.isOnline {
                    if section.projects.isEmpty {
                        Text("這台還沒有專案")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 20)
                    }
                    ForEach(section.projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.leading, 20)
                            ForEach(project.threads) { thread in
                                RemoteThreadRowView(model: model, deviceID: section.deviceID, thread: thread)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func isCollapsed(_ section: RemoteSidebarSection) -> Bool { collapsed.contains(section.id) }

    private static func seen(_ date: Date) -> String {
        let now = ChatPageModel.exportChatScene != nil ? Date(timeIntervalSinceReferenceDate: 800_000_000) : Date()
        let s = Int(now.timeIntervalSince(date))
        if s < 3_600 { return "\(max(1, s / 60)) 分鐘前" }
        if s < 86_400 { return "\(s / 3_600) 小時前" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
    }
}

private struct RemoteThreadRowView: View {
    @ObservedObject var model: ChatPageModel
    let deviceID: String
    let thread: RemoteThreadRow

    private var isSelected: Bool {
        guard let sel = model.selectedRemote else { return false }
        return sel.deviceID == deviceID && sel.threadID == thread.id
    }

    var body: some View {
        Button {
            _ = model.selectRemote(deviceID: deviceID, threadID: thread.id)
        } label: {
            label
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .contextMenu {
            Button("拉到這台（複製一份到本機）") { _ = model.pullThreadFromDevice(deviceID, thread.id) }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(ChatTypography.sidebarThreadTitle)
                    .lineLimit(1)
                if !thread.statusLine.isEmpty {
                    Text(thread.statusLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if thread.isRunning {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        isSelected ? LiquidGlassTokens.brandAccent.opacity(0.14) : Color.clear
    }
}
