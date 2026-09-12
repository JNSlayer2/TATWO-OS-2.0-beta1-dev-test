import SwiftUI
import AppKit

/// Pure presentation. The injected terminal content can be a fixture or a runtime wrapper.
/// The OS shell owns its ONE sidebar; this view never inserts another sidebar.
struct CLIWorkbenchSurface<TerminalContent: View>: View {
    let tabs: [CLIWorkbenchTab]
    let selectedTabID: UUID?
    let panes: [CLIWorkbenchPane]
    let appearance: CLIWorkbenchAppearance
    let editingOptions: CLIWorkbenchEditingOptions
    var pendingCloseTitle: String?
    let send: (CLIWorkbenchAction) -> Void
    @ViewBuilder let terminal: (CLIWorkbenchPane) -> TerminalContent

    @State private var searchPresented = false
    @State private var searchText = ""
    @State private var settingsPresented = false
    @FocusState private var searchFocused: Bool

    private var currentTab: CLIWorkbenchTab? { tabs.first { $0.id == selectedTabID } }
    private var focusedID: UUID? { currentTab?.focusedPaneID ?? currentTab?.layout?.paneIDs.first }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if searchPresented { searchBar }
            if let layout = currentTab?.layout {
                canvas(layout)
            } else {
                emptyState
            }
            footer
        }
        .disabled(pendingCloseTitle != nil)
        .foregroundStyle(appearance.ink)
        .background(appearance.surface)
        .overlay {
            if let pendingCloseTitle { closePrompt(pendingCloseTitle) }
        }
        .popover(isPresented: $settingsPresented) { editingSettings }
        .onChange(of: selectedTabID) { _, _ in searchText = "" }
        .accessibilityIdentifier("cli-workbench")
    }

    private var tabStrip: some View {
        HStack(spacing: CLIWorkbenchMetrics.smallGap) {
            ScrollView(.horizontal) {
                HStack(spacing: CLIWorkbenchMetrics.smallGap) {
                    ForEach(tabs) { tab in
                        HStack(spacing: CLIWorkbenchMetrics.smallGap) {
                            Button { send(.selectTab(tab.id)) } label: {
                                HStack(spacing: CLIWorkbenchMetrics.smallGap) {
                                    Text(tab.title).lineLimit(1)
                                    Text("\(tab.layout?.paneIDs.count ?? 0)")
                                        .foregroundStyle(appearance.secondaryInk).monospacedDigit()
                                }
                                .frame(minWidth: CLIWorkbenchMetrics.tabMin,
                                       maxWidth: CLIWorkbenchMetrics.tabMax, alignment: .leading)
                            }
                            iconButton("關閉工作台 \(tab.title)", "xmark") {
                                send(.requestCloseTab(tab.id))
                            }
                        }
                        .padding(.leading, CLIWorkbenchMetrics.inset)
                        .background(selectedTabID == tab.id ? appearance.canvas : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
                        .overlay(alignment: .bottom) {
                            if selectedTabID == tab.id {
                                appearance.accent.frame(height: CLIWorkbenchMetrics.hairline)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            newMenu
            Rectangle().fill(appearance.border)
                .frame(width: CLIWorkbenchMetrics.hairline, height: CLIWorkbenchMetrics.icon)
            iconButton("向右分割 ⌘D", "rectangle.split.2x1") {
                if let focusedID { send(.split(focusedID, .horizontal)) }
            }.keyboardShortcut("d", modifiers: .command).disabled(focusedID == nil)
            iconButton("向下分割 ⇧⌘D", "rectangle.split.1x2") {
                if let focusedID { send(.split(focusedID, .vertical)) }
            }.keyboardShortcut("d", modifiers: [.shift, .command]).disabled(focusedID == nil)
            iconButton("搜尋目前窗格 ⌘F", "magnifyingglass") {
                searchPresented.toggle()
                searchFocused = searchPresented
            }.keyboardShortcut("f", modifiers: .command).disabled(focusedID == nil)
            iconButton("終端快捷鍵設定", "slider.horizontal.3") { settingsPresented = true }
        }
        .buttonStyle(.plain)
        .font(.system(size: CLIWorkbenchMetrics.labelFont))
        .padding(.horizontal, CLIWorkbenchMetrics.inset)
        .frame(height: CLIWorkbenchMetrics.tabHeight)
        .overlay(alignment: .bottom) { appearance.border.frame(height: CLIWorkbenchMetrics.hairline) }
    }

    private var newMenu: some View {
        Menu {
            Button("Shell") { send(.createTab(engine: "generic")) }
            Button("Claude") { send(.createTab(engine: "claude")) }
            Button("Codex") { send(.createTab(engine: "codex")) }
            Button("Grok") { send(.createTab(engine: "grok")) }
        } label: {
            Image(systemName: "plus")
                .frame(width: CLIWorkbenchMetrics.control, height: CLIWorkbenchMetrics.control)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新增工作台")
        .accessibilityLabel("新增 CLI 工作台，選擇引擎")
    }

    private var emptyState: some View {
        VStack(spacing: CLIWorkbenchMetrics.inset) {
            Image(systemName: "terminal")
                .font(.system(size: CLIWorkbenchMetrics.paneHeader))
                .foregroundStyle(appearance.accent)
            Text("開啟終端工作台").font(.headline)
            HStack(spacing: CLIWorkbenchMetrics.inset) {
                ForEach(["Shell", "Claude", "Codex", "Grok"], id: \.self) { title in
                    Button(title) {
                        send(.createTab(engine: title == "Shell" ? "generic" : title.lowercased()))
                    }
                }
            }
            Text("使用目前專案與原生引擎權限")
                .font(.caption).foregroundStyle(appearance.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvas(_ layout: CLIWorkbenchLayout) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let projection = layout.projection(in: geometry.size, focused: focusedID,
                                                   maximized: currentTab?.maximizedPaneID)
                ZStack(alignment: .topLeading) {
                    ForEach(projection.panes) { placement in
                        if let pane = panes.first(where: { $0.id == placement.id }) {
                            paneSurface(pane)
                                .frame(width: placement.frame.width, height: placement.frame.height)
                                .offset(x: placement.frame.minX, y: placement.frame.minY)
                                .opacity(placement.isVisible ? 1 : 0)
                                .allowsHitTesting(placement.isVisible)
                                .accessibilityHidden(!placement.isVisible)
                        }
                    }
                    ForEach(projection.dividers) { divider in
                        CLIWorkbenchDividerHandle(divider: divider, color: appearance.border, send: send)
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .offset(x: divider.frame.minX, y: divider.frame.minY)
                    }
                }
                // offset does not contribute to a ZStack's layout bounds.
                // Without the explicit canvas frame, right/bottom panes get clipped.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .coordinateSpace(name: "cli-workbench-canvas")
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if projection.isCompact {
                        Label("窄視窗 · 分割已保留", systemImage: "rectangle.compress.vertical")
                            .font(.system(size: CLIWorkbenchMetrics.labelFont))
                            .padding(CLIWorkbenchMetrics.smallGap)
                            .background(appearance.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
                            .padding(CLIWorkbenchMetrics.smallGap)
                            .allowsHitTesting(false)
                    }
                }
            }
            if layout.paneIDs.count > 1 { focusStrip(layout) }
        }
        .padding(CLIWorkbenchMetrics.inset)
        .background(appearance.canvas)
    }

    private func paneSurface(_ pane: CLIWorkbenchPane) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: CLIWorkbenchMetrics.smallGap) {
                Image(systemName: pane.symbol).foregroundStyle(appearance.accent)
                Text(pane.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: CLIWorkbenchMetrics.smallGap)
                Text(pane.state.label)
                    .foregroundStyle(appearance.secondaryInk).lineLimit(1)
                    .help(pane.state.explanation)
                iconButton(currentTab?.maximizedPaneID == pane.id ? "還原分割" : "最大化窗格",
                    currentTab?.maximizedPaneID == pane.id
                        ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    send(.toggleMaximize(pane.id))
                }
                Menu {
                    Button("向右分割") { send(.split(pane.id, .horizontal)) }
                    Button("向下分割") { send(.split(pane.id, .vertical)) }
                    Divider()
                    Button("選取輸出送回 Chat 草稿") { send(.sendSelectionToDraft(pane.id)) }
                    Button("關閉窗格…") { send(.requestClosePane(pane.id)) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: CLIWorkbenchMetrics.control, height: CLIWorkbenchMetrics.control)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(pane.title) 的窗格操作")
                iconButton("關閉窗格 \(pane.title)", "xmark") { send(.requestClosePane(pane.id)) }
            }
            .font(.system(size: CLIWorkbenchMetrics.labelFont))
            .padding(.horizontal, CLIWorkbenchMetrics.inset)
            .frame(height: CLIWorkbenchMetrics.paneHeader)
            .background(focusedID == pane.id ? appearance.canvas : appearance.surface)
            .contentShape(Rectangle())
            .onTapGesture { send(.selectPane(pane.id)) }
            terminal(pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .background(appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: appearance.cornerRadius)
                .strokeBorder(focusedID == pane.id ? appearance.accent : appearance.border,
                              lineWidth: CLIWorkbenchMetrics.hairline)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("cli-pane-\(pane.id)")
    }

    private func focusStrip(_ layout: CLIWorkbenchLayout) -> some View {
        HStack(spacing: CLIWorkbenchMetrics.smallGap) {
            iconButton("上一個窗格 ⌥⌘[", "chevron.left") { send(.focusNext(backwards: true)) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            ScrollView(.horizontal) {
                HStack(spacing: CLIWorkbenchMetrics.inset) {
                    ForEach(layout.paneIDs, id: \.self) { id in
                        if let pane = panes.first(where: { $0.id == id }) {
                            Button {
                                send(.selectPane(id))
                            } label: {
                                Label(pane.title, systemImage: pane.symbol).lineLimit(1)
                                    .foregroundStyle(focusedID == id ? appearance.accent : appearance.secondaryInk)
                            }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
            iconButton("下一個窗格 ⌥⌘]", "chevron.right") { send(.focusNext(backwards: false)) }
                .keyboardShortcut("]", modifiers: [.command, .option])
        }
        .buttonStyle(.plain)
        .font(.system(size: CLIWorkbenchMetrics.labelFont))
        .frame(height: CLIWorkbenchMetrics.paneHeader)
    }

    private var searchBar: some View {
        HStack(spacing: CLIWorkbenchMetrics.inset) {
            Image(systemName: "magnifyingglass")
            TextField("搜尋目前終端", text: $searchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { find(backwards: false) }
            iconButton("上一個結果", "chevron.up") { find(backwards: true) }
            iconButton("下一個結果", "chevron.down") { find(backwards: false) }
            iconButton("關閉搜尋", "xmark") { searchPresented = false }
        }
        .font(.system(size: CLIWorkbenchMetrics.labelFont))
        .padding(.horizontal, CLIWorkbenchMetrics.inset)
        .frame(height: CLIWorkbenchMetrics.tabHeight)
        .background(appearance.canvas)
    }

    private func find(backwards: Bool) {
        guard let focusedID, !searchText.isEmpty else { return }
        send(.find(focusedID, searchText, backwards: backwards))
    }

    private var footer: some View {
        HStack(spacing: CLIWorkbenchMetrics.inset) {
            if let pane = panes.first(where: { $0.id == focusedID }) {
                Label(pane.project, systemImage: "folder")
                Text(pane.engine == "generic" ? "Shell" : pane.engine.capitalized)
                Text(pane.statusLabel).help(pane.state.explanation)
            }
            Spacer(minLength: 0)
            Text("送回 Chat 僅填草稿")
        }
        .font(.system(size: CLIWorkbenchMetrics.labelFont))
        .foregroundStyle(appearance.secondaryInk)
        .lineLimit(1)
        .padding(.horizontal, CLIWorkbenchMetrics.inset)
        .frame(height: CLIWorkbenchMetrics.footer)
    }

    private var editingSettings: some View {
        VStack(alignment: .leading, spacing: CLIWorkbenchMetrics.inset) {
            Text("終端編輯快捷鍵").font(.headline)
            Toggle("⌘⌫ 刪至行首", isOn: Binding(
                get: { editingOptions.deleteToLineStart },
                set: { value in
                    var options = editingOptions
                    options.deleteToLineStart = value
                    send(.setEditingOptions(options))
                }))
            Toggle("⌥⌫ 刪除前一字", isOn: Binding(
                get: { editingOptions.deletePreviousWord },
                set: { value in
                    var options = editingOptions
                    options.deletePreviousWord = value
                    send(.setEditingOptions(options))
                }))
            Text("預設關閉；變更套用至所有開啟窗格。\n組字期間保留輸入法原生操作。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(CLIWorkbenchMetrics.inset * 2)
        .fixedSize()
    }

    private func closePrompt(_ title: String) -> some View {
        ZStack {
            appearance.canvas.opacity(0.95)
            VStack(spacing: CLIWorkbenchMetrics.inset * 2) {
                Image(systemName: "terminal").font(.title)
                Text("關閉「\(title)」？").font(.headline)
                Text("保留背景：移出工作台，程序繼續跑。\n結束程序：終止工作，不會自動重跑。")
                    .font(.callout).multilineTextAlignment(.center)
                HStack(spacing: CLIWorkbenchMetrics.inset) {
                    Button("取消") { send(.resolveClose(.cancel)) }
                        .keyboardShortcut(.cancelAction)
                    Button("結束程序", role: .destructive) { send(.resolveClose(.terminate)) }
                    Button("保留背景") { send(.resolveClose(.background)) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(CLIWorkbenchMetrics.inset * 3)
            .background(appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
        }
        .accessibilityIdentifier("cli-close-choice")
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CLIWorkbenchMetrics.icon))
                .frame(width: CLIWorkbenchMetrics.control, height: CLIWorkbenchMetrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

private struct CLIWorkbenchDividerHandle: View {
    let divider: CLIWorkbenchDivider
    let color: Color
    let send: (CLIWorkbenchAction) -> Void
    @State private var startingRatio: Double?
    @State private var cursorPushed = false

    var body: some View {
        let horizontal = divider.axis == .horizontal
        ZStack {
            Color.clear
            color.frame(width: horizontal ? CLIWorkbenchMetrics.hairline : nil,
                        height: horizontal ? nil : CLIWorkbenchMetrics.hairline)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering && !cursorPushed {
                (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                cursorPushed = true
            } else if !hovering && cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cli-workbench-canvas"))
            .onChanged { value in
                if startingRatio == nil { startingRatio = divider.ratio }
                let delta = horizontal ? value.translation.width : value.translation.height
                guard divider.availableLength > 0 else { return }
                send(.setRatio(divider.id, (startingRatio ?? divider.ratio) + delta / divider.availableLength))
            }
            .onEnded { _ in startingRatio = nil })
        .accessibilityLabel(horizontal ? "左右分割比例" : "上下分割比例")
        .accessibilityValue("\(Int(divider.ratio * 100))%")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            send(.setRatio(divider.id, divider.ratio + delta))
        }
    }
}

/// Replaces the CLI rows inside the existing OS rail, not a new sidebar container.
struct CLIWorkbenchSessionRows: View {
    let tabs: [CLIWorkbenchTab]
    let selectedTabID: UUID?
    let panes: [CLIWorkbenchPane]
    let appearance: CLIWorkbenchAppearance
    let send: (CLIWorkbenchAction) -> Void
    @State private var historyExpanded = false

    private var backgroundPanes: [CLIWorkbenchPane] { panes.filter(\.isBackground) }

    var body: some View {
        VStack(alignment: .leading, spacing: CLIWorkbenchMetrics.smallGap) {
            ForEach(tabs) { tab in
                Button { send(.selectTab(tab.id)) } label: {
                    HStack(spacing: CLIWorkbenchMetrics.inset) {
                        Image(systemName: "terminal.fill").frame(width: CLIWorkbenchMetrics.icon)
                        Text(tab.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: CLIWorkbenchMetrics.labelFont))
                        Text("\(tab.layout?.paneIDs.count ?? 0)").monospacedDigit()
                    }
                    .padding(.horizontal, CLIWorkbenchMetrics.inset)
                    .frame(height: CLIWorkbenchMetrics.sidebarRow)
                    .background(selectedTabID == tab.id ? appearance.canvas : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
                    .contentShape(Rectangle())
                }
                .fontWeight(selectedTabID == tab.id ? .semibold : .regular)
                .foregroundStyle(appearance.ink)
                .accessibilityLabel("\(tab.title)，\(tab.layout?.paneIDs.count ?? 0) 個窗格")
                .accessibilityAddTraits(selectedTabID == tab.id ? .isSelected : [])
                .contextMenu {
                    Button("關閉工作台…") { send(.requestCloseTab(tab.id)) }
                }
            }
            Menu {
                Button("Shell") { send(.createTab(engine: "generic")) }
                Button("Claude") { send(.createTab(engine: "claude")) }
                Button("Codex") { send(.createTab(engine: "codex")) }
                Button("Grok") { send(.createTab(engine: "grok")) }
            } label: {
                Label("新增分頁", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CLIWorkbenchMetrics.inset)
                    .frame(height: CLIWorkbenchMetrics.sidebarRow)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .foregroundStyle(appearance.secondaryInk)
            .accessibilityLabel("新增 CLI 工作台，選擇引擎")

            if !backgroundPanes.isEmpty {
                Button { historyExpanded.toggle() } label: {
                    HStack(spacing: CLIWorkbenchMetrics.inset) {
                        Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: CLIWorkbenchMetrics.icon)
                        Text("背景與歷史")
                        Spacer(minLength: 0)
                        Text("\(backgroundPanes.count)").monospacedDigit()
                    }
                    .padding(.horizontal, CLIWorkbenchMetrics.inset)
                    .frame(height: CLIWorkbenchMetrics.sidebarRow)
                }
                .font(.system(size: CLIWorkbenchMetrics.labelFont))
                .foregroundStyle(appearance.secondaryInk)
                .padding(.top, CLIWorkbenchMetrics.inset)
                .accessibilityValue(historyExpanded ? "已展開" : "已收合")
                if historyExpanded {
                    ForEach(backgroundPanes) { pane in
                        Button { send(.reattach(pane.id)) } label: {
                            HStack(spacing: CLIWorkbenchMetrics.inset) {
                                Image(systemName: pane.state == .exited ? "clock" : "terminal")
                                    .frame(width: CLIWorkbenchMetrics.icon)
                                Text(pane.title).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: pane.state == .exited ? "doc.text" : "arrow.up.forward")
                            }
                            .padding(.horizontal, CLIWorkbenchMetrics.inset)
                            .frame(height: CLIWorkbenchMetrics.sidebarRow)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(appearance.secondaryInk)
                        .help("\(pane.statusLabel)；\(pane.state.explanation)")
                        .accessibilityLabel("\(pane.title)，\(pane.statusLabel)")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: CLIWorkbenchMetrics.terminalFont))
        .accessibilityIdentifier("cli-workbench-session-rows")
    }
}
