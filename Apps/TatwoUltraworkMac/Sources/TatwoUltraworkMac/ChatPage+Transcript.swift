import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPage {
    var cliTerminalPane: some View {
        Group {
            if model.isCLIRuntimeEnabled {
                ScrollView {
                    VStack(alignment: .trailing, spacing: 12) {
                        if model.cliTabs.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("開一個 CLI 分頁開始（可同時多工）")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                cliNewShellButton(prominentLabel: "＋ 新終端")
                            }
                            .frame(maxWidth: 700, minHeight: 300)
                        }

                        ForEach(model.cliTabs) { tab in
                            cliTerminalCard(tab)
                                .frame(maxWidth: 700)
                                .frame(height: expandedCLITabIDs.contains(tab.id) ? 600 : 300)
                                .onTapGesture { model.selectCLITab(tab.id) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, isPanel ? 0 : 18)
                    .padding(.top, surface == .window ? WindowChromeMetrics.bandHeight : 0)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    model.loadPersistedCLISessionBook()
                    model.prepareCLITabs()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("CLI").font(.headline.weight(.black))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    func cliTerminalCard(_ tab: TatwoNativeCLISessionBook.Session) -> some View {
        let active = model.activeCLITabID == tab.id
        let status = model.cliTabStatuses[tab.id] ?? "idle"
        let expanded = expandedCLITabIDs.contains(tab.id)
        return CLISolidCard(highlighted: active) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(tab.title, systemImage: "terminal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: 10, weight: .bold).monospaced())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        if expanded { expandedCLITabIDs.remove(tab.id) }
                        else { expandedCLITabIDs.insert(tab.id) }
                    } label: {
                        Image(systemName: expanded
                              ? "arrow.down.forward.and.arrow.up.backward"
                              : "arrow.up.backward.and.arrow.down.forward")
                    }
                    .help(expanded ? "縮回 300pt" : "展開到 600pt")
                    Button {
                        CLITerminalWindowManager.shared.focus(tabID: tab.id, title: tab.title, model: model)
                    } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("專注")
                    Button {
                        CLITerminalWindowManager.shared.detach(tabID: tab.id, title: tab.title, model: model)
                    } label: { Image(systemName: "uiwindow.split.2x1") }
                    .help("分離小視窗")
                    Button {
                        expandedCLITabIDs.remove(tab.id)
                        model.closeCLITab(tab.id)
                    } label: { Image(systemName: "xmark") }
                    .help("關閉終端")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Group {
                    if let ptySession = model.cliTabPTYSession(for: tab.id) {
                        NativeTerminalPTYView(
                            session: ptySession,
                            lines: model.cliTabLines(for: tab.id),
                            fontSize: ChatTypography.terminalPointSize,
                            contentInset: ChatTypography.terminalContentInset,
                            palette: .lightGlass)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(model.cliTabLines(for: tab.id)) { line in
                                    TerminalLineView(line: line)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(ChatTypography.terminalContentInset)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // CLI 多工分頁條：開啟中的分頁 tabs（active 高亮＋× 關閉）。新終端入口在左列。
    var cliTabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.cliTabs) { tab in
                        cliTabChip(tab)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
        }
    }

    func cliNewShellButton(prominentLabel: String) -> some View {
        Button {
            model.openCLITab(engine: .generic)
        } label: {
            Text(prominentLabel)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 30)
                .chatGlassChip(isSelected: true)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("開新終端")
    }

    func cliTabChip(_ tab: TatwoNativeCLISessionBook.Session) -> some View {
        let active = model.activeCLITabID == tab.id
        return HStack(spacing: 6) {
            Button { model.selectCLITab(tab.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: cliEngineIcon(tab.engine)).font(.system(size: 10, weight: .bold))
                    Text(tab.title).font(.caption.weight(active ? .bold : .regular)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            // X 不用 Button：橫向 ScrollView 會吃掉小 Button 的 click；overlay 也不可擋 hit。
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .help("關閉分頁")
                .highPriorityGesture(TapGesture().onEnded {
                    model.closeCLITab(tab.id)
                })
        }
        .foregroundStyle(active ? LiquidGlassTokens.brandAccent : Color.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .fill(active ? LiquidGlassTokens.brandAccent.opacity(0.12) : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                .strokeBorder(active ? LiquidGlassTokens.brandAccent.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    func cliEngineIcon(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .grok: return "bolt.fill"
        case .generic: return "terminal"
        }
    }

    @ViewBuilder
    func messageArea(contentMaxWidth: CGFloat?) -> some View {
        if model.isLoadingStore {
            ProgressView("載入對話")
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedThreadID == nil {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcript(contentMaxWidth: contentMaxWidth)
        }
    }

    func transcript(contentMaxWidth: CGFloat?) -> some View {
        let rowWidth = contentMaxWidth ?? composerMaxWidth ?? ChatUILayout.chatColumnMaxWidth
        return TranscriptScrollView(
            messages: model.transcriptMessages,
            selectedSessionReference: model.selectedSessionReference,
            assistantRoute: model.routeChoice,
            rowWidth: rowWidth,
            gitChangedFiles: model.gitChangedFiles,
            gitChangedFileCount: model.gitChangedFileCount,
            gitChangedLineAdditions: model.gitChangedLineAdditions,
            gitChangedLineDeletions: model.gitChangedLineDeletions,
            isRunning: model.isRunning,
            assistantTranscriptCache: model.assistantTranscriptCache,
            planArtifact: model.activePlanArtifact,
            isPlanWriting: model.isActivePlanTurnWriting,
            activePlanTurnAssistantMessageID:
                model.activePlanTurnAssistantMessageID,
            planInspectorPresented: $planInspectorPresented,
            onOpenChangedFiles: {
                rightPanelContent = .diff
                rightPanelPreference = true
                isRightPanelOpen = true
            },
            isPanel: isPanel)
            .id(model.selectedSessionReference)
    }

    private struct TranscriptBottomYPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    private struct TranscriptContentHeightPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct TranscriptScrollView: View {
        let messages: [ChatMessage]
        let selectedSessionReference: TatwoNativeChatSessionReference?
        let assistantRoute: ChatRouteChoice
        let rowWidth: CGFloat
        let gitChangedFiles: [ChatGitChangedFileSummary]
        let gitChangedFileCount: Int
        let gitChangedLineAdditions: Int
        let gitChangedLineDeletions: Int
        let isRunning: Bool
        let assistantTranscriptCache: TatwoAssistantTranscriptCache
        let planArtifact: TatwoPlanArtifactV1?
        let isPlanWriting: Bool
        let activePlanTurnAssistantMessageID: String?
        @Binding var planInspectorPresented: Bool
        let onOpenChangedFiles: () -> Void
        let isPanel: Bool

        @State private var followState = ChatTranscriptScrollFollowState()
        @State private var cachedDisplayItems: [ChatTranscriptDisplayItem] = []
        @State private var cachedDisplayFingerprint = ChatTranscriptDisplayFingerprint()
        @State private var transcriptContentHeight: CGFloat = 0
        @State private var initialFocusClaimedPlanQuestionMessageIDs:
            Set<String> = []

        /// The projection cache stamps the tail with a model-owned revision.
        /// Constructing this key is therefore O(1), even for long transcripts.
        private var displayFingerprint: ChatTranscriptDisplayFingerprint {
            ChatTranscriptDisplayFingerprint(
                messages,
                planArtifactSourceMessageID:
                    planArtifact?.sourceAssistantMessageID,
                activePlanTurnAssistantMessageID:
                    activePlanTurnAssistantMessageID,
                isPlanWriting: isPlanWriting)
        }

        private var displayItems: [ChatTranscriptDisplayItem] {
            let fingerprint = displayFingerprint
            if fingerprint == cachedDisplayFingerprint {
                return cachedDisplayItems
            }
            return ChatTranscriptDisplayBuilder.build(
                planThoughtPresentationMessages)
        }

        private var latestAssistantMessageID: String? {
            displayFingerprint.latestAssistantMessageID
        }

        private var gitChangedSummaryFingerprint: String {
            [
                String(gitChangedFileCount),
                String(gitChangedLineAdditions),
                String(gitChangedLineDeletions),
                gitChangedFiles.map {
                    "\($0.path):\($0.additions):\($0.deletions)"
                }.joined(separator: "|"),
            ].joined(separator: "#")
        }

        private var planArtifactMessageID: String? {
            planArtifact?.sourceAssistantMessageID
        }

        private var planArtifactPlacement:
            ChatPlanArtifactTranscriptProjection.Placement
        {
            ChatPlanArtifactTranscriptProjection.placement(
                hasArtifact: planArtifact != nil,
                sourceAssistantMessageID:
                    planArtifactMessageID,
                isPlanWriting: isPlanWriting)
        }

        private var standalonePlanArtifact: TatwoPlanArtifactV1? {
            guard planArtifactPlacement.completedArtifact == .standalone
            else {
                return nil
            }
            return planArtifact
        }

        private var shouldRenderPlanWritingSummary: Bool {
            planArtifactPlacement.includesWritingRow
        }

        private var planThoughtPresentationMessages: [ChatMessage] {
            ChatPlanThoughtPresentation.projectedMessages(
                messages,
                planArtifactSourceMessageID:
                    planArtifactMessageID,
                activePlanTurnAssistantMessageID:
                    activePlanTurnAssistantMessageID)
        }

        private var latestAssistantHasPlanQuestions: Bool {
            displayFingerprint.latestAssistantHasPlanQuestions
        }

        private func scrollDestination(
            viewportHeight: CGFloat
        ) -> ChatTranscriptScrollDestination {
            ChatTranscriptScrollDestination.resolve(
                latestAssistantMessageID: latestAssistantMessageID,
                hasPlanArtifact: planArtifact != nil,
                isPlanWriting: isPlanWriting,
                latestAssistantHasPlanQuestions:
                    latestAssistantHasPlanQuestions,
                contentHeight: transcriptContentHeight,
                viewportHeight: viewportHeight)
        }

        private static let bottomAnchorID = "tatwo-chat-transcript-bottom"
        private static let coordinateSpaceName = "tatwo-chat-transcript-scroll"

        var body: some View {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            LazyVStack(
                                alignment: .leading,
                                spacing: TatwoChatTranscriptVisualMetrics.messageSpacing
                            ) {
                                ForEach(displayItems) { item in
                                    switch item {
                                    case .message(let message):
                                        messageRow(message)
                                            .frame(
                                                width: rowWidth,
                                                alignment: message.role == .user ? .trailing : .leading)
                                    case .workTimeline(let timeline):
                                        ChatInlineWorkTimelineView(
                                            timeline: timeline,
                                            assistantRoute: assistantRoute,
                                            rowWidth: rowWidth)
                                    }
                                }
                                if shouldRenderPlanWritingSummary {
                                    PlanTranscriptSummaryView(
                                        artifact: nil,
                                        isWriting: true,
                                        isSidePanelPresented:
                                            $planInspectorPresented)
                                        .frame(
                                            width: rowWidth,
                                            alignment: .leading)
                                        .id("tatwo-plan-writing-summary")
                                        .accessibilityIdentifier(
                                            "plan-transcript-summary")
                                }
                                if let standalonePlanArtifact {
                                    PlanTranscriptSummaryView(
                                        artifact: standalonePlanArtifact,
                                        isWriting: false,
                                        isSidePanelPresented:
                                            $planInspectorPresented)
                                        .frame(
                                            width: rowWidth,
                                            alignment: .leading)
                                        .id("tatwo-plan-standalone-summary")
                                        .accessibilityIdentifier(
                                            "plan-transcript-summary")
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchorID)
                                    .background {
                                        GeometryReader { bottom in
                                            Color.clear.preference(
                                                key: TranscriptBottomYPreferenceKey.self,
                                                value: bottom.frame(
                                                    in: .named(Self.coordinateSpaceName)).maxY)
                                        }
                                    }
                            }
                            .frame(width: rowWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, isPanel ? 0 : 18)
                            // #1(回滾貼底)+#4:Codex 式頂部 inset——首句從上方起，
                            // 但留出交通燈 band(34)+間隔，與紅黃綠水平清楚區隔；不再貼底也不貼交通燈。
                            .padding(.top, isPanel ? 8 : 50)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key:
                                            TranscriptContentHeightPreferenceKey
                                                .self,
                                        value: content.size.height)
                                }
                            }
                        }
                        .coordinateSpace(name: Self.coordinateSpaceName)
                        .scrollIndicators(.hidden)
                        // #1 頂部淡出 mask 已移除：在 live 大視窗會把 ScrollView 內文遮成透明(內文消失 bug)。
                        // 區隔改由頂部 inset 50px 提供；不用遮罩。
                        .onPreferenceChange(TranscriptBottomYPreferenceKey.self) { bottomY in
                            followState.update(
                                bottomY: bottomY,
                                viewportHeight: viewport.size.height)
                        }
                        .onPreferenceChange(
                            TranscriptContentHeightPreferenceKey.self
                        ) { height in
                            let isInitialMeasurement =
                                transcriptContentHeight <= 0 && height > 0
                            let didChange =
                                abs(transcriptContentHeight - height) > 0.5
                            transcriptContentHeight = height
                            guard isInitialMeasurement
                                    || (didChange
                                        && followState
                                            .shouldAutoScrollOnContentChange)
                            else {
                                return
                            }
                            if isInitialMeasurement {
                                followState.jumpToLatest()
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onAppear {
                            followState.jumpToLatest()
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: selectedSessionReference) { _, _ in
                            followState.jumpToLatest()
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: displayFingerprint, initial: true) { _, fingerprint in
                            cachedDisplayFingerprint = fingerprint
                            cachedDisplayItems = ChatTranscriptDisplayBuilder.build(
                                planThoughtPresentationMessages)
                        }
                        .onChange(of: displayFingerprint) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: planArtifact?.markdownExport()) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        .onChange(of: gitChangedSummaryFingerprint) { _, _ in
                            guard followState.shouldAutoScrollOnContentChange else {
                                return
                            }
                            scrollToLatest(
                                using: proxy,
                                viewportHeight: viewport.size.height)
                        }
                        // Codex 式歷史 minimap（使用者 #62 逐格 parity：找歷史指令）；左側刻度條、hover預覽、點擊跳轉。
                        .overlay(alignment: .leading) {
                            if !isPanel {
                                ChatHistoryMinimap(
                                    messages: planThoughtPresentationMessages
                                ) { id in
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                }
                            }
                        }

                        if followState.showsJumpToLatest {
                            Button {
                                followState.jumpToLatest()
                                scrollToLatest(
                                    using: proxy,
                                    viewportHeight: viewport.size.height)
                            } label: {
                                Label("跳至最新", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .tatwoAdaptiveCapsule(material: .regularMaterial)
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(
                                                Color.white.opacity(0.14),
                                                lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .shadow(
                                color: .black.opacity(0.12),
                                radius: 8,
                                x: 0,
                                y: 4)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityLabel("跳至最新訊息")
                        }
                    }
                }
                .animation(
                    .easeInOut(duration: 0.16),
                    value: followState.showsJumpToLatest)
            }
        }

        @ViewBuilder
        private func messageRow(_ message: ChatMessage) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                ChatBubble(
                    message: message,
                    assistantRoute: assistantRoute,
                    rowWidth: rowWidth,
                    assistantTranscriptCache: assistantTranscriptCache,
                    planArtifact:
                        message.id == planArtifactMessageID
                            ? planArtifact
                            : nil,
                    isLatestAssistantMessage:
                        message.id == latestAssistantMessageID,
                    initialPlanQuestionFocusClaimed:
                        initialFocusClaimedPlanQuestionMessageIDs
                            .contains(message.id),
                    onInitialPlanQuestionFocusClaimed: {
                        initialFocusClaimedPlanQuestionMessageIDs
                            .insert(message.id)
                    },
                    planInspectorPresented: $planInspectorPresented)

                if shouldRenderChangedFiles(after: message) {
                    ChatChangedFilesSummaryView(
                        files: gitChangedFiles,
                        totalFileCount: gitChangedFileCount,
                        totalAdditions: gitChangedLineAdditions,
                        totalDeletions: gitChangedLineDeletions,
                        onView: onOpenChangedFiles)
                        .id("tatwo-chat-changed-files-summary")
                }
            }
        }

        private func shouldRenderChangedFiles(
            after message: ChatMessage
        ) -> Bool {
            message.role == .assistant
                && message.eventKind == .message
                && message.id == latestAssistantMessageID
                && !isRunning
                && gitChangedFileCount > 0
        }

        private func scrollToLatest(
            using proxy: ScrollViewProxy,
            viewportHeight: CGFloat
        ) {
            // LazyVStack may still be committing a streamed delta or a shorter
            // final answer. Defer one runloop so the stable sentinel reflects
            // the latest layout before scrolling.
            DispatchQueue.main.async {
                switch scrollDestination(viewportHeight: viewportHeight) {
                case .none:
                    break
                case .bottom:
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                case .itemTop(let id):
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    func activeGoalInlineCard(contentMaxWidth: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: activeGoalDetailsExpanded ? 7 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    activeGoalDetailsExpanded.toggle()
                }
            } label: {
                Group {
                    if activeGoalDetailsExpanded {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(activeGoalCodexTint.opacity(0.12))
                                    .frame(width: 24, height: 24)
                                Image(systemName: "target")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(activeGoalCodexTint.opacity(0.82))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(activeGoalCodexStatusText)
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    activeGoalFlatMeta(model.activeGoalElapsedLabel, systemImage: "clock")
                                        .id(model.activeGoalClock)
                                }
                                Text(model.activeGoalObjectiveLabel)
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)
                            activeGoalFlatMeta(model.activeGoalHeaderProgressLabel, systemImage: "checkmark.seal")
                            activeGoalStatusPill(model.activeGoalPaused ? "paused" : model.selectedWorkOSGoalStatusLabel)
                            if model.selectedThreadHasWorkOSGoal {
                                activeGoalControlButton(
                                    icon: model.activeGoalPaused ? "play.fill" : "pause.fill",
                                    tint: .orange,
                                    help: model.activeGoalPaused ? "續跑目標" : "暫停目標") {
                                        model.toggleActiveGoalPause()
                                    }
                                    .disabled(model.activeGoalPaused && !model.canResumeActiveGoal)
                                    .opacity(model.activeGoalPaused && !model.canResumeActiveGoal ? 0.45 : 1)
                                activeGoalControlButton(
                                    icon: model.canJudgeAndCompleteActiveGoal
                                        ? "checkmark"
                                        : "stop.fill",
                                    tint: model.canJudgeAndCompleteActiveGoal
                                        ? .green
                                        : .red,
                                    help: model.canJudgeAndCompleteActiveGoal
                                        ? "驗收並完成 Goal"
                                        : "結束目標") {
                                    model.endActiveGoal()
                                }
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .frame(minHeight: 34)
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "target")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(activeGoalCodexTint.opacity(0.78))
                            Text(activeGoalCodexStatusText)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(activeGoalCodexTint.opacity(0.82))
                                .lineLimit(1)
                            Text("# \(model.activeGoalObjectiveLabel)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(model.activeGoalElapsedLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .id(model.activeGoalClock)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .frame(height: 32)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if activeGoalDetailsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.28)
                    if !model.selectedRouteCooldownStatusText.isEmpty {
                        Label(
                            model.selectedRouteCooldownStatusText,
                            systemImage: "exclamationmark.octagon.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("模型路線暫停")
                    }
                    activeGoalProgressCluster
                    HStack(spacing: 7) {
                        chip(systemImage: "bolt.horizontal", text: model.activeWorkOSModeLabel)
                        chip(systemImage: "person.crop.circle.badge.checkmark", text: "Plan \(model.activeWorkOSLeadLabel)")
                        chip(systemImage: "arrow.triangle.2.circlepath", text: "Loops \(model.activeWorkOSLoopsLabel)")
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        activeGoalInfoColumn("Receipts", model.activeGoalHeaderProgressLabel)
                        activeGoalInfoColumn("Changed", "\(model.gitChangedFileCount) files")
                        activeGoalInfoColumn("Next", model.activeGoalNextActionLabel, lineLimit: 2)
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, activeGoalDetailsExpanded ? 13 : 12)
        .padding(.vertical, activeGoalDetailsExpanded ? 9 : 0)
        .frame(maxWidth: contentMaxWidth ?? composerMaxWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                // fable5 深度改造：base 用不透明暖紙(去玻璃/blur)；aurora 維持 ultraThinMaterial。
                .fill(TatwoActivePalette.current.usesGlass
                    ? AnyShapeStyle(.ultraThinMaterial)
                    : AnyShapeStyle(TatwoActivePalette.current.surfaceFill))
                .overlay {
                    RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(activeGoalDetailsExpanded ? 0.150 : 0.115),
                                    activeGoalCodexTint.opacity(activeGoalDetailsExpanded ? 0.058 : 0.034),
                                    Color.white.opacity(0.082)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: ChatUILayout.panelRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(activeGoalDetailsExpanded ? 0.30 : 0.22),
                                activeGoalCodexTint.opacity(activeGoalDetailsExpanded ? 0.20 : 0.115),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1)
                if activeGoalDetailsExpanded {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        activeGoalCodexTint,
                                        LiquidGlassTokens.accentViolet
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(LiquidGlassTokens.tintOpacity)
                            .frame(width: max(18, geometry.size.width * CGFloat(activeGoalProgressFraction)), height: 2)
                            .padding(.horizontal, 12)
                            .padding(.top, 1)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .leading) {
            if activeGoalDetailsExpanded {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                activeGoalCodexTint,
                                LiquidGlassTokens.accentViolet
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(LiquidGlassTokens.tintOpacity)
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .padding(.leading, 2)
            }
        }
        .shadow(color: .black.opacity(activeGoalDetailsExpanded ? 0.050 : 0.026), radius: activeGoalDetailsExpanded ? 14 : 8, x: 0, y: activeGoalDetailsExpanded ? 8 : 4)
        .frame(maxWidth: .infinity, alignment: .center)
        .onAppear {
            model.startActiveGoalTimerIfNeeded()
        }
        .onDisappear {
            model.stopActiveGoalTimer()
        }
        .help("由目前 thread 的 Work OS contract、goal receipts 與 git status 產生；點開才顯示細節。")
    }

    var activeGoalProgressFraction: Double {
        let progress = model.activeGoalStepProgress
        return Double(progress.current) / Double(max(progress.total, 1))
    }

    var activeGoalCodexStatusText: String {
        if !model.selectedRouteCooldownStatusText.isEmpty {
            return "模型路線暫停"
        }
        return model.activeGoalPaused
            ? "目標已暫停"
            : model.activeGoalStatusPresentationLabel
    }

    var activeGoalCodexTint: Color {
        if !model.selectedRouteCooldownStatusText.isEmpty {
            return .red
        }
        switch model.selectedWorkOSGoalStatusLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "human_gate", "paused", "blocked", "failed", "cancelled", "rollback_required":
            return .red
        case "dispatching", "running":
            return .orange
        default:
            return LiquidGlassTokens.brandAccent
        }
    }

    // 目標狀態列的暫停/結束小圓鈕（巢狀在展開 header 內；.plain 讓各自吃點擊）。
    func activeGoalControlButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint.opacity(0.9))
                .frame(width: 20, height: 18)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var activeGoalProgressCluster: some View {
        let progress = model.activeGoalStepProgress
        let names = ["Goal", "Plan", "Loops", "Receipts", "Close"]
        func align(_ index: Int) -> Alignment {
            index == 0 ? .leading : (index == progress.total - 1 ? .trailing : .center)
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer(minLength: 0)
                Label(model.activeGoalStepProgressLabel, systemImage: "checkmark.seal")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            // 圓點列與標籤列用「同一套全寬對齊」→ 每個點正對它的標籤，不再錯位看起來相反。
            HStack(spacing: 0) {
                ForEach(0..<progress.total, id: \.self) { index in
                    goalSpineDot(isDone: index + 1 < progress.current, isCurrent: index + 1 == progress.current)
                        .frame(maxWidth: .infinity, alignment: align(index))
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<progress.total, id: \.self) { index in
                    Text(names.indices.contains(index) ? names[index] : "\(index + 1)")
                        .font(.system(size: 8, weight: index + 1 == progress.current ? .black : .semibold, design: .rounded))
                        .foregroundStyle(
                            index + 1 <= progress.current
                                ? LiquidGlassTokens.brandAccent
                                : Color.secondary.opacity(
                                    LiquidGlassTokens.nodeCardTintOpacity
                                )
                        )
                        .frame(maxWidth: .infinity, alignment: align(index))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
                    LiquidGlassTokens.accentViolet.opacity(LiquidGlassTokens.subtleFillOpacity),
                    LiquidGlassTokens.tint.opacity(LiquidGlassTokens.subtleFillOpacity)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
    }

    // 單一進度圓點（給全寬對齊的進度列用）。
    func goalSpineDot(isDone: Bool, isCurrent: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    (isDone || isCurrent ? LiquidGlassTokens.brandAccent : LiquidGlassTokens.tint)
                        .opacity(isCurrent ? LiquidGlassTokens.tintOpacity : LiquidGlassTokens.chipFillOpacity)
                )
                .frame(width: isCurrent ? 16 : 13, height: isCurrent ? 16 : 13)
            Circle()
                .fill(
                    (isDone || isCurrent)
                        ? LiquidGlassTokens.brandAccent
                        : Color.secondary.opacity(LiquidGlassTokens.strokeOpacity)
                )
                .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
        }
    }

    func activeGoalFlatMeta(_ text: String, systemImage: String) -> some View {
        Label(text.isEmpty ? "—" : text, systemImage: systemImage)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }

    func activeGoalStatusPill(_ text: String) -> some View {
        Text(text.isEmpty ? "planned" : text)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(LiquidGlassTokens.brandAccent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .chatGlassChip(isSelected: true)
    }

    func activeGoalInfoColumn(_ title: String, _ value: String, lineLimit: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value.isEmpty ? "—" : value)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .truncationMode(title == "Contract" ? .middle : .tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.070), lineWidth: 1))
    }

}
