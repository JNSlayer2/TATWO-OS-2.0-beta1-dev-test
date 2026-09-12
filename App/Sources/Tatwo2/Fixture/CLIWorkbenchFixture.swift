import SwiftUI

/// In-memory UI rehearsal only. Never constructs a PTY, model, store or runtime.
struct CLIWorkbenchFixtureState {
    enum Scene: String, CaseIterable {
        case empty, single, horizontal, vertical, four, maximized, narrow, close
    }

    var tabs: [CLIWorkbenchTab]
    var panes: [CLIWorkbenchPane]
    var selectedTabID: UUID?
    var editingOptions = CLIWorkbenchEditingOptions()
    var pendingCloseIDs: [UUID] = []
    var pendingCloseTitle: String?
    var feedback = "純 UI 預覽 · 無程序、無正式資料"
    var searchQuery = ""

    static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 4100 + index))!
    }

    init(scene: Scene) {
        panes = [
            CLIWorkbenchPane(id: Self.id(1), title: "Claude · 規劃", engine: "claude",
                             project: "tatwo2", state: .waiting),
            CLIWorkbenchPane(id: Self.id(2), title: "Codex · 實作", engine: "codex",
                             project: "tatwo2", state: .running),
            CLIWorkbenchPane(id: Self.id(3), title: "Grok · 檢視", engine: "grok",
                             project: "tatwo2", state: .unknown),
            CLIWorkbenchPane(id: Self.id(4), title: "Shell · 工具", engine: "generic",
                             project: "tatwo2", state: .waiting),
            CLIWorkbenchPane(id: Self.id(5), title: "文件索引", engine: "generic",
                             project: "tatwo2", state: .running, isBackground: true),
            CLIWorkbenchPane(id: Self.id(6), title: "上一個 Shell", engine: "generic",
                             project: "tatwo2", state: .exited, isBackground: true, exitCode: 0),
        ]
        var layout = CLIWorkbenchLayout.pane(Self.id(1))
        if scene != .single && scene != .empty {
            layout = layout.splitting(Self.id(1), newPane: Self.id(2),
                                     axis: scene == .vertical ? .vertical : .horizontal,
                                     splitID: Self.id(20))
        }
        if [.four, .maximized, .narrow, .close].contains(scene) {
            layout = layout.splitting(Self.id(1), newPane: Self.id(3), axis: .vertical, splitID: Self.id(21))
            layout = layout.splitting(Self.id(2), newPane: Self.id(4), axis: .vertical, splitID: Self.id(22))
        }
        let visibleIDs = scene == .empty ? [] : layout.paneIDs
        panes.removeAll { !$0.isBackground && !visibleIDs.contains($0.id) }
        tabs = scene == .empty ? [] : [
            CLIWorkbenchTab(id: Self.id(10), title: "CLI 工作台", layout: layout,
                            focusedPaneID: Self.id(1),
                            maximizedPaneID: scene == .maximized ? Self.id(1) : nil),
        ]
        selectedTabID = tabs.first?.id
        if scene == .close {
            pendingCloseIDs = [Self.id(2)]
            pendingCloseTitle = "Codex · 實作"
        }
    }

    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }
    var focusedID: UUID? { selectedIndex.flatMap { tabs[$0].focusedPaneID } }

    mutating func send(_ action: CLIWorkbenchAction) {
        switch action {
        case .createTab(let engine):
            let pane = CLIWorkbenchPane(id: UUID(), title: "\(engine == "generic" ? "Shell" : engine.capitalized) · 示範",
                                        engine: engine, project: "tatwo2", state: .unknown)
            panes.append(pane)
            let tab = CLIWorkbenchTab(id: UUID(), title: "新工作台", layout: .pane(pane.id), focusedPaneID: pane.id)
            tabs.append(tab)
            selectedTabID = tab.id
        case .selectTab(let id):
            if tabs.contains(where: { $0.id == id }) { selectedTabID = id }
        case .selectPane(let id):
            guard let index = tabs.firstIndex(where: { $0.layout?.paneIDs.contains(id) == true }) else { return }
            selectedTabID = tabs[index].id
            tabs[index].focusedPaneID = id
            if tabs[index].maximizedPaneID != nil { tabs[index].maximizedPaneID = id }
        case .split(let id, let axis):
            guard let index = selectedIndex, let layout = tabs[index].layout,
                  layout.paneIDs.contains(id) else { return }
            let pane = CLIWorkbenchPane(id: UUID(), title: "Shell · 新窗格", engine: "generic",
                                        project: "tatwo2", state: .unknown)
            panes.append(pane)
            tabs[index].layout = layout.splitting(id, newPane: pane.id, axis: axis)
            tabs[index].focusedPaneID = pane.id
            tabs[index].maximizedPaneID = nil
        case .setRatio(let id, let ratio):
            guard let index = selectedIndex else { return }
            tabs[index].layout = tabs[index].layout?.settingRatio(splitID: id, ratio: ratio)
        case .focusNext(let backwards):
            guard let index = selectedIndex, let ids = tabs[index].layout?.paneIDs, !ids.isEmpty else { return }
            let old = ids.firstIndex(of: tabs[index].focusedPaneID ?? ids[0]) ?? 0
            let next = ids[(old + (backwards ? ids.count - 1 : 1)) % ids.count]
            send(.selectPane(next))
        case .toggleMaximize(let id):
            guard let index = selectedIndex, tabs[index].layout?.paneIDs.contains(id) == true else { return }
            tabs[index].focusedPaneID = id
            tabs[index].maximizedPaneID = tabs[index].maximizedPaneID == id ? nil : id
        case .requestClosePane(let id):
            guard let pane = panes.first(where: { $0.id == id }) else { return }
            pendingCloseIDs = [id]
            pendingCloseTitle = pane.title
        case .requestCloseTab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return }
            pendingCloseIDs = tab.layout?.paneIDs ?? []
            pendingCloseTitle = "\(tab.title) · \(pendingCloseIDs.count) 個窗格"
        case .resolveClose(let choice):
            if choice != .cancel {
                for id in pendingCloseIDs {
                    if let index = panes.firstIndex(where: { $0.id == id }) {
                        panes[index].isBackground = true
                        if choice == .terminate { panes[index].state = .exited; panes[index].exitCode = 0 }
                    }
                    for index in tabs.indices {
                        tabs[index].layout = tabs[index].layout?.removing(id)
                        if tabs[index].focusedPaneID == id { tabs[index].focusedPaneID = tabs[index].layout?.paneIDs.first }
                        if tabs[index].maximizedPaneID == id { tabs[index].maximizedPaneID = nil }
                    }
                }
                tabs.removeAll { $0.layout == nil }
                if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
            }
            pendingCloseIDs = []
            pendingCloseTitle = nil
        case .reattach(let id):
            guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
            if panes[index].state == .exited {
                feedback = "示範：僅檢視退出快照，不重跑舊命令"
            } else {
                panes[index].isBackground = false
                let tab = CLIWorkbenchTab(id: UUID(), title: panes[index].title,
                                          layout: .pane(id), focusedPaneID: id)
                tabs.append(tab)
                selectedTabID = tab.id
            }
        case .sendSelectionToDraft:
            feedback = "示範：選取輸出 → Chat 草稿；沒有傳送或執行"
        case .find(_, let query, _):
            searchQuery = query
            feedback = "示範搜尋：\(query)；真終端搜尋待 B 階段"
        case .setEditingOptions(let options):
            editingOptions = options
            feedback = "設定 UI 已變更；IME／控制字元接線待 B 階段"
        }
    }

    static func lines(for engine: String) -> [String] {
        switch engine {
        case "claude":
            return ["Claude Code", "/workspace/tatwo2", "", "❯ 整理 CLI 工作台的修改範圍", "",
                    "  工作台呈現  ·  尺寸 / 分割 / 焦點",
                    "  終端執行    ·  SwiftTerm / PTY / tmux",
                    "  OS 2 接線   ·  專案 / Chat / Bot", "",
                    "先確認介面，再接真實程序。", "", "❯ █"]
        case "codex":
            return ["Codex", "/workspace/tatwo2", "", "› 替換固定高度的 CLI 卡片", "",
                    "  CLIWorkbenchSurface.swift", "  CLIWorkbenchLayout.swift", "",
                    "分割與最大化只調整畫面；", "不重新執行原有命令。", "", "› █"]
        case "grok":
            return ["Grok", "/workspace/tatwo2", "", "❯ 檢視狀態是否表達準確", "",
                    "  程序存活 ≠ 任務成功", "  歷史快照 ≠ 接回原 session", "",
                    "沒有可信事件時，顯示「未知」。", "", "❯ █"]
        default:
            return ["Shell", "/workspace/tatwo2", "", "% printf 'hello · 你好 👋\\n'",
                    "hello · 你好 👋", "", "% █"]
        }
    }
}

struct CLIWorkbenchFixtureView: View {
    static let sidebarWidth: CGFloat = WorkspaceSidebarMetrics.width
    @State var state: CLIWorkbenchFixtureState
    let appearance: CLIWorkbenchAppearance

    var body: some View {
        HStack(spacing: CLIWorkbenchMetrics.hairline) {
            sidebar.frame(width: Self.sidebarWidth)
            VStack(spacing: 0) {
                HStack(spacing: CLIWorkbenchMetrics.inset) {
                    Label("tatwo2", systemImage: "folder")
                    Text("/  CLI").foregroundStyle(appearance.secondaryInk)
                    Spacer()
                    Text(state.feedback).font(.system(size: CLIWorkbenchMetrics.labelFont))
                        .foregroundStyle(appearance.secondaryInk).lineLimit(1)
                }
                .padding(.horizontal, CLIWorkbenchMetrics.inset * 2)
                .frame(height: CLIWorkbenchMetrics.tabHeight)
                CLIWorkbenchSurface(tabs: state.tabs, selectedTabID: state.selectedTabID,
                    panes: state.panes, appearance: appearance, editingOptions: state.editingOptions,
                    pendingCloseTitle: state.pendingCloseTitle, send: { state.send($0) }) { pane in
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(CLIWorkbenchFixtureState.lines(for: pane.engine).enumerated()), id: \.offset) { _, line in
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: CLIWorkbenchMetrics.terminalFont, design: .monospaced))
                                        .foregroundStyle(line.hasPrefix("❯") || line.hasPrefix("›")
                                                         ? appearance.accent : appearance.ink)
                                        .frame(height: CLIWorkbenchMetrics.terminalLine, alignment: .leading)
                                }
                            }
                            .padding(CLIWorkbenchMetrics.inset)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.send(.selectPane(pane.id)) }
                    }
            }
        }
        .foregroundStyle(appearance.ink)
        .background(appearance.canvas)
        .environment(\.colorScheme, .light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: CLIWorkbenchMetrics.inset) {
            HStack(spacing: CLIWorkbenchMetrics.inset) {
                ForEach([Color.gray, Color.gray, Color.gray].indices, id: \.self) { _ in
                    Circle().fill(appearance.border).frame(width: 11, height: 11)
                }
                Spacer()
                Image(systemName: "sidebar.left")
            }
            .frame(height: CLIWorkbenchMetrics.tabHeight)
            HStack(spacing: CLIWorkbenchMetrics.smallGap) {
                ForEach(["Chat", "CLI", "Bot"], id: \.self) { title in
                    Text(title).font(.system(size: CLIWorkbenchMetrics.labelFont, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: CLIWorkbenchMetrics.paneHeader)
                        .foregroundStyle(title == "CLI" ? appearance.accent : appearance.secondaryInk)
                        .background(title == "CLI" ? appearance.canvas : appearance.surface)
                        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
                }
            }
            HStack {
                Label("tatwo2", systemImage: "folder")
                Spacer()
                Image(systemName: "chevron.down")
            }
            .font(.system(size: CLIWorkbenchMetrics.labelFont, weight: .semibold))
            .foregroundStyle(appearance.secondaryInk)
            .padding(.horizontal, CLIWorkbenchMetrics.inset)
            .padding(.vertical, CLIWorkbenchMetrics.inset)
            ScrollView {
                CLIWorkbenchSessionRows(tabs: state.tabs, selectedTabID: state.selectedTabID, panes: state.panes,
                    appearance: appearance, send: { state.send($0) })
            }
            Spacer(minLength: 0)
            Text("TATWO OS").font(.system(size: CLIWorkbenchMetrics.labelFont, weight: .semibold))
                .foregroundStyle(appearance.secondaryInk).padding(.vertical, CLIWorkbenchMetrics.inset)
        }
        .padding(.horizontal, CLIWorkbenchMetrics.inset * 2)
        .background(appearance.surface)
    }
}
