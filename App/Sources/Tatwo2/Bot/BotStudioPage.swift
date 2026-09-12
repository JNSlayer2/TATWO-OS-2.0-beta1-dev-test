import SwiftUI
import AppKit

// Gen-5 bot 分頁「工作室」純 UI（2026-09-09 使用者收斂）。
// 左列風格照現況不動（Chat／CLI／Bot 膠囊、已釘選、資料夾、臨時工區、
// create bot、底部 TATWO OS＋space 圓點）；新增的只有：
//   ① 子資料夾可再深一層、群可展開看成員
//   ② 側欄右緣把手 → 工作室抽屜（一個 space 可有多間工作室）
//   ③ add space 三段流 → 綁一個工作環境（三種來源講白能力）
//   ④ create bot ＝生臨時工；轉常駐才走六步
//   ⑤ 資料夾設定＝身份組，拆「權限×視野」兩軸（認知隔離）
// 歷史遺留的左列右上收合鈕：使用者 2026-09-09 指示移除，這版沒有。
// 防偷渡：零 send、零 runner、零通道、零落盤。

struct BotStudioRootView: View {
    @StateObject private var state: BotStudioState
    var onSwitchMode: ((ChatRunMode) -> Void)?

    /// 快照捕捉時是否改抓 Gen-5（預設 0＝仍抓 Gen-4 12 場景的凍結金樣）。
    /// 驗收用：TATWO_ULTRAWORK_BOT_GEN5=1，另可用 …_BOT_GEN5_MODE 指定主槽模式。
    static let exportGen5: Bool = {
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_BOT_GEN5"] == "1"
    }()

    static var exportGen5Mode: BotStudioMode {
        switch ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_BOT_GEN5_MODE"] {
        case "bind": .bind
        case "wizard": .wizard
        case "role": .role
        case "thread": .thread
        case "team": .team
        case "space": .spaceSettings
        default: .studio
        }
    }

    init(spaceIndex: Int = 0,
         mode: BotStudioMode = .studio,
         onSwitchMode: ((ChatRunMode) -> Void)? = nil) {
        _state = StateObject(wrappedValue: BotStudioState(spaceIndex: spaceIndex, mode: mode))
        self.onSwitchMode = onSwitchMode
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            BotStudioMainSlot(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 工作室入口＝既有的窗外書側標籤（2026-08-22 使用者做好的資產）：
        // 互動時掛 child window 在主窗右緣外側；快照 export 抓不到子視窗，退回窗內貼緣版。
        .overlay(alignment: .trailing) {
            if BotPageRootView.snapshotExportMode {
                BotStudioEdgeTabsInsetRail(state: state).zIndex(30)
            }
        }
        .background {
            if !BotPageRootView.snapshotExportMode {
                BotStudioEdgeTabsMounter(state: state)
            }
        }
        // bot 私訊：右下浮鈕＋小視窗（沿用 Gen-4 的資產）。
        .overlay(alignment: .bottomTrailing) {
            BotStudioMessagesFAB(state: state)
        }
    }

    // MARK: - 側欄

    private var sidebar: some View {
        WorkspaceSidebarShell {
            VStack(alignment: .leading, spacing: 0) {
                // 膠囊、寬度、頂距一律走 chat/cli/bot 共用度量，不在這裡另寫。
                WorkspaceSidebarModePicker(
                    modes: ChatRunMode.visibleChatTabs,
                    selection: .bot) { mode in
                        if mode != .bot { onSwitchMode?(mode) }
                    }
                    .padding(.top, WorkspaceSidebarMetrics.headerTopInset)
                spaceHeader
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                    .padding(.vertical, WorkspaceSidebarMetrics.sectionSpacing)
                treeScroll
                Spacer(minLength: 8)
                bottomBar
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 3)
        .zIndex(10)
    }

    /// 膠囊下方＝這個 space 的名字；點名字進全 space 設定。
    private var spaceHeader: some View {
        Button { state.openSpaceSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(state.space.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("這個 space 的設定")
    }

    private var treeScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.space.folders.enumerated()), id: \.element.id) { index, root in
                    if index > 0 {
                        Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                    }
                    BotStudioFolderBranch(state: state, folder: root, depth: 0)
                }

                BotStudioRow(icon: "＋", title: "新的部門", avatar: false,
                             selected: false, health: nil, subdued: true) {
                    state.addDepartment()
                }
                .padding(.top, 4)
                .help("開一個新部門：水平線隔開的最大一塊，權限和用途各自獨立")

                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                    .padding(.horizontal, 6).padding(.vertical, 8)

                Text("臨時工區")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                ForEach(state.space.temps) { temp in
                    BotStudioTempRow(state: state, temp: temp)
                }
                BotStudioRow(icon: "＋", title: "create bot", avatar: false,
                             selected: false, health: nil, subdued: true) {
                    state.createTempBot()
                }
                .help("生一隻臨時工：不留記憶、只能動自己的暫存區。要它常駐再走六步。要直接加常駐 bot 用部門／小組上的 ＋。")
            }
        }
        .scrollClipDisabled()
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(state.spaces.enumerated()), id: \.element.id) { index, space in
                    Button { state.selectSpace(index) } label: {
                        Circle()
                            .fill(index == state.spaceIndex
                                  ? Color.primary.opacity(0.75) : Color.primary.opacity(0.22))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                }
                Button { state.addSpace() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新增一個 space")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            TatwoOSMark(size: 13)
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

}

// MARK: - 側欄：資料夾分支（root → 子資料夾 → 群／bot；最多三層）

struct BotStudioFolderBranch: View {
    @ObservedObject var state: BotStudioState
    let folder: BotFolder
    let depth: Int

    private var isEmptyBranch: Bool {
        folder.folders.isEmpty && folder.bots.isEmpty
            && !state.promoted.contains { state.promotedFolderID[$0.id] == folder.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BotStudioFolderRow(
                name: folder.name,
                isTopLevel: depth == 0,
                expanded: state.expandedFolderIDs.contains(folder.id),
                indent: CGFloat(depth) * 14,
                addMenu: {
                    Text(depth == 0 ? "在部門「\(folder.name)」裡加" : "在小組「\(folder.name)」裡加")
                    if depth == 0 {
                        Button("小組　—　一組人一起講話的地方") { state.addTeam(in: folder.id) }
                    }
                    Button("bot　—　單獨一隻，走六步") { state.startWizardForNewBot(in: folder.id) }
                }) {
                    withAnimation(.easeOut(duration: 0.14)) { state.toggleFolder(folder.id) }
                }
                .contextMenu { BotStudioFolderMenu(state: state, folder: folder, isDepartment: depth == 0) }

            if state.expandedFolderIDs.contains(folder.id) {
                ForEach(folder.folders) { sub in
                    BotStudioTeamRow(state: state, folder: sub, indent: CGFloat(depth + 1) * 14)
                }
                ForEach(folder.bots) { unit in
                    botRow(unit, indent: CGFloat(depth + 1) * 14 + 8)
                }
                ForEach(state.promoted.filter { state.promotedFolderID[$0.id] == folder.id }) { unit in
                    botRow(unit, indent: CGFloat(depth + 1) * 14 + 8)
                }
                if isEmptyBranch {
                    Text("空的　·　用右邊的 ＋ 加")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6 + CGFloat(depth + 1) * 14 + 8)
                        .frame(height: 26)
                }
            }
        }
    }

    private func botRow(_ unit: BotUnit, indent: CGFloat) -> some View {
        BotStudioRow(icon: unit.emoji, title: unit.name, avatar: true,
                     selected: state.selectedBotID == unit.id, health: unit.health,
                     indent: indent) {
            state.selectBot(unit.id)
        }
        .contextMenu { BotStudioBotMenu(state: state, unit: unit, folder: folder) }
    }
}

/// 小組：不展開，點進去在主畫面看名稱與成員頭像。
struct BotStudioTeamRow: View {
    @ObservedObject var state: BotStudioState
    let folder: BotFolder
    var indent: CGFloat = 0

    var body: some View {
        let selected = state.mode == .team && state.selectedTeamID == folder.id
        return Button { state.selectTeam(folder.id) } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(selected ? LiquidGlassTokens.brandAccent : Color.clear)
                    .frame(width: 3, height: selected ? 16 : 0)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(folder.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3 + indent)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(selected ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { BotStudioFolderMenu(state: state, folder: folder, isDepartment: false) }
    }
}

// MARK: - 側欄元件

struct BotStudioRow: View {
    let icon: String
    let title: String
    var avatar: Bool = true
    var selected: Bool = false
    var health: BotHealth?
    var indent: CGFloat = 0
    var subdued: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Discord 式 active 指示條（選中那列左緣）。
                Capsule()
                    .fill(selected ? LiquidGlassTokens.brandAccent : Color.clear)
                    .frame(width: 3, height: selected ? 16 : 0)
                if avatar {
                    BotAvatar(emoji: icon, size: 18, selected: selected)
                } else {
                    Text(icon).font(.system(size: 12)).frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: subdued ? 12.5 : 13))
                    .foregroundStyle(subdued ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3 + indent)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(selected ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(selected ? 0.20 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BotStudioFolderRow<AddMenu: View>: View {
    let name: String
    var isTopLevel: Bool = false
    let expanded: Bool
    var indent: CGFloat = 0
    @ViewBuilder var addMenu: () -> AddMenu
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: isTopLevel ? 9 : 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    Text(name)
                        .font(.system(size: isTopLevel ? 15 : 13,
                                      weight: isTopLevel ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 每一層自己的 ＋：部門能加小組／群／bot，小組能加群／bot。
            Menu {
                addMenu()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: isTopLevel ? 11 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .help(isTopLevel ? "在這個部門裡加東西" : "在這個小組裡加東西")
        }
        .padding(.leading, 6 + indent)
        .padding(.trailing, 6)
        .frame(height: isTopLevel ? 32 : 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct BotStudioTempRow: View {
    @ObservedObject var state: BotStudioState
    let temp: BotTemp
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            BotAvatar(emoji: temp.emoji, size: 18)
            Text(temp.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Button { state.startWizard(tempID: temp.id) } label: {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("轉常駐：這一刻才要填六步")
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("轉常駐 bot…") { state.startWizard(tempID: temp.id) }
        }
    }
}


// MARK: - 右鍵選單（先把位置佔好；灰掉的是還沒接的）

struct BotStudioBotMenu: View {
    @ObservedObject var state: BotStudioState
    let unit: BotUnit
    let folder: BotFolder?

    var body: some View {
        Button("私訊") { state.dmOpen = true; state.openDM(unit.id) }
        if let folder {
            Button("這一層的身份組…") { state.openRoleSettings(folderID: folder.id) }
        }
    }
}

struct BotStudioFolderMenu: View {
    @ObservedObject var state: BotStudioState
    let folder: BotFolder
    var isDepartment: Bool = false

    var body: some View {
        Button("身份組（權限與視野）…") { state.openRoleSettings(folderID: folder.id) }
        Divider()
        if isDepartment {
            Button("加一個小組") { state.addTeam(in: folder.id) }
        }
        Button("加一隻 bot…") { state.startWizardForNewBot(in: folder.id) }
    }
}
