import SwiftUI
import TatwoUltraworkCore

/// CLI 左列 session 樹：頂部三段（終端 / Loops / 遠端），下列只顯示作用中段。
///
/// 視覺只重用既有 token／側欄字級（`LiquidGlassTokens`、`ChatTypography`、`Badge`），
/// 不發明新色或 magic number 間距語彙。

struct CLISessionTreeProject: Identifiable, Equatable {
    let id: UUID
    let name: String
    let sessions: [CLISessionTreeTerminalSession]
}

struct CLISessionTreeTerminalSession: Identifiable, Equatable {
    let id: UUID
    let name: String
    let engineLabel: String
    let cwd: String
}

struct CLISessionTreeOpenSession: Identifiable, Equatable {
    let id: UUID
    let title: String
    let engine: TatwoNativeCLISessionBook.Engine
    let isRunning: Bool
}

private enum CLISessionTreeSegment: String, CaseIterable, Identifiable {
    case terminal
    case loops
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "終端"
        case .loops: return "Loops"
        case .remote: return "遠端"
        }
    }
}

struct CLISessionTree: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let projects: [CLISessionTreeProject]
    let openSessions: [CLISessionTreeOpenSession]
    let loopRows: [CLILoopTreeRow]
    var showsLoopSegments = true
    let selectedTerminalSessionID: String?
    let selectedOpenSessionID: UUID?
    let selectedLoopID: String?
    let onSelectTerminal: (UUID, UUID) -> Void
    let onSelectOpenSession: (UUID) -> Void
    let onSelectLoop: (String) -> Void
    let onCreateSession: (UUID, TatwoNativeCLIEngine) -> Void
    let onCloseOpenSession: (UUID) -> Void
    let onHandoffTerminalToChat: (UUID, UUID) -> Void

    @State private var selectedSegment: CLISessionTreeSegment = .terminal
    @State private var hoveredOpenSessionID: UUID?

    private var activeLoopCount: Int {
        loopRows.filter(\.isActive).count
    }

    /// 跨裝置算力：inbound 鏡像列，或 origin/target 分屬不同裝置的派工。
    private var remoteLoopRows: [CLILoopTreeRow] {
        loopRows.filter(\.isRemoteCompute)
    }

    private var localLoopRows: [CLILoopTreeRow] {
        loopRows.filter { !$0.isRemoteCompute }
    }

    private var activeRemoteLoopCount: Int {
        remoteLoopRows.filter(\.isActive).count
    }

    private var activeLocalLoopCount: Int {
        localLoopRows.filter(\.isActive).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLoopSegments {
                segmentControl
            }
            ScrollView {
                Group {
                    switch selectedSegment {
                    case .terminal:
                        terminalSection
                    case .loops:
                        loopsSection
                    case .remote:
                        remoteComputeSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var segmentControl: some View {
        HStack(spacing: 4) {
            ForEach(
                showsLoopSegments ? CLISessionTreeSegment.allCases : [.terminal]
            ) { segment in
                let isActive = selectedSegment == segment
                Button {
                    selectedSegment = segment
                } label: {
                    HStack(spacing: 3) {
                        Text(segment.title)
                        if let badge = segmentBadge(segment) {
                            Text(badge)
                                .font(.caption2.monospacedDigit().weight(.black))
                                .foregroundStyle(isActive ? LiquidGlassTokens.brandAccent : Color.secondary)
                        }
                    }
                    .font(.caption.weight(.black))
                    .foregroundStyle(isActive ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .contentShape(Rectangle())
                    .chatGlassChip(isSelected: isActive)
                }
                .buttonStyle(.plain)
                .help(segmentHelp(segment))
            }
        }
        .padding(3)
        .chatGlassChip()
        .padding(.horizontal, 9)
    }

    private func segmentHelp(_ segment: CLISessionTreeSegment) -> String {
        switch segment {
        case .terminal: return "CLI 專案與 session"
        case .loops: return "本機進行中與近 1 小時的 loops"
        case .remote: return "跨裝置算力 loops"
        }
    }

    private func segmentBadge(_ segment: CLISessionTreeSegment) -> String? {
        switch segment {
        case .terminal:
            return nil
        case .loops:
            return activeLocalLoopCount > 0 ? "\(activeLocalLoopCount)" : nil
        case .remote:
            return activeRemoteLoopCount > 0 ? "\(activeRemoteLoopCount)" : nil
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .allowsHitTesting(false)
    }

    // MARK: - 段一：終端 Sessions

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if openSessions.isEmpty && projects.isEmpty {
                emptyState("尚無 CLI 專案。點 + 新增資料夾或匯入 chat 專案。")
            } else {
                if !openSessions.isEmpty {
                    ForEach(openSessions) { session in
                        openSessionRow(session)
                    }
                }
                ForEach(projects) { project in
                    projectBlock(project)
                }
            }
        }
    }

    private func openSessionRow(_ session: CLISessionTreeOpenSession) -> some View {
        let isSelected = selectedOpenSessionID == session.id
        let isHovered = hoveredOpenSessionID == session.id
        return HStack(spacing: 6) {
            Button {
                onSelectOpenSession(session.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: engineIcon(session.engine))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary)
                        .frame(width: 14, height: 18)
                    Text(session.title)
                        .font(ChatTypography.sidebarThreadTitle.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : .primary)
                    if session.isRunning {
                        Circle()
                            .fill(LiquidGlassTokens.brandAccent)
                            .frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .help("關閉分頁")
                .highPriorityGesture(TapGesture().onEnded {
                    onCloseOpenSession(session.id)
                })
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredOpenSessionID = hovering ? session.id : nil
        }
        .chatMenuRowHover(isSelected: isSelected)
    }

    private func engineIcon(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .grok: return "bolt.fill"
        case .generic: return "terminal"
        }
    }

    private func projectBlock(_ project: CLISessionTreeProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(TatwoNativeCLIEngine.allCases, id: \.self) { engine in
                    Button(engine.displayName) {
                        onCreateSession(project.id, engine)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(ChatTypography.systemUI(11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .padding(.horizontal, 9)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("在此專案新增 CLI session")

            if project.sessions.isEmpty {
                emptyState("此專案尚無 CLI session")
            } else {
                ForEach(project.sessions) { session in
                    terminalRow(projectID: project.id, session: session)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func terminalRow(projectID: UUID, session: CLISessionTreeTerminalSession) -> some View {
        let isSelected = selectedTerminalSessionID == session.id.uuidString
            && selectedLoopID == nil
        return Button {
            onSelectTerminal(projectID, session.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .frame(width: 14, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(ChatTypography.sidebarThreadTitle.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : .primary)
                    Text("\(session.engineLabel) · \(session.cwd)")
                        .font(ChatTypography.sidebarThreadPreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover(isSelected: isSelected)
        .contextMenu {
            Button {
                onHandoffTerminalToChat(projectID, session.id)
            } label: {
                Label("送回 Chat（建對話串）", systemImage: "bubble.left")
            }
        }
    }

    // MARK: - 段二：Loops

    private var loopsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if localLoopRows.isEmpty {
                emptyState("尚無進行中或近 1 小時的 loops。chat／Ultrawork 派工後會自動出現。")
            } else {
                ForEach(localLoopRows) { row in
                    CLISessionTreeLoopRowView(
                        row: row,
                        isSelected: selectedLoopID == row.id,
                        onSelect: { onSelectLoop(row.id) })
                }
            }
        }
    }

    // MARK: - 段三：遠端算力 Loops

    private var remoteComputeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if remoteLoopRows.isEmpty {
                emptyState("尚無跨裝置 loops。另一台裝置派工過來、或本機派工到遠端後會出現。")
            } else {
                ForEach(remoteLoopRows) { row in
                    CLISessionTreeLoopRowView(
                        row: row,
                        isSelected: selectedLoopID == row.id,
                        onSelect: { onSelectLoop(row.id) })
                }
            }
        }
    }
}

/// 單列 loop：身份、模型、狀態、經過時間、裝置。
struct CLISessionTreeLoopRowView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let row: CLILoopTreeRow
    let isSelected: Bool
    let onSelect: () -> Void

    private var dotColor: Color {
        switch row.status {
        case .queued: return .gray
        case .running: return .blue
        case .completed: return .green
        case .verified: return .mint
        case .failed: return .red
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.displayName)
                            .font(.caption2.weight(.black))
                            .lineLimit(1)
                        Text(row.identity)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(row.startedAt, style: .relative)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(row.statusLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Badge(row.deviceLabel)
                        if let source = row.sourceThreadLabel, !source.isEmpty {
                            Badge("來源 \(source)")
                        }
                    }

                    if !row.subtask.isEmpty {
                        Text(row.subtask)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover(isSelected: isSelected)
        .help(
            "\(row.statusLabel)｜\(row.displayName)｜\(row.deviceLabel)｜\(row.subtask.isEmpty ? row.contractID : row.subtask)"
        )
    }
}
