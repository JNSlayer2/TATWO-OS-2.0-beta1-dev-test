import AppKit
import SwiftUI
import TatwoUltraworkCore

// Whole-row collapsible headers (輪次進度 / 完整規劃與配置 / 規劃筆記 / 已封存) need to
// react to a click anywhere on the row, not only the chevron glyph SwiftUI renders for
// DisclosureGroup. Each header label wraps in a plain Button that toggles the same
// disclosure binding; this modifier just adds the pointing-hand hover feedback that
// signals "this whole row is clickable" at near-zero cost.
extension View {
    fileprivate func tatwoPointerCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// Loops is a user-facing Work OS console. The default surface answers four
// questions only: what is real now, what is the Goal, who is running, and what
// happens next. Plan text, model configuration, cycles, and planning discussion
// stay behind explicit disclosure controls.
struct TatwoLoopsLiveRow: Identifiable, Equatable {
    let id: String
    let identity: String
    let modelID: String
    let statusLabel: String
    let detail: String
    let phase: TatwoDispatchRuntimePhase
    /// 2026-08-21 使用者回饋「看不到 sub 實際的運作情況」：帶上啟動時刻
    /// 讓實況列能顯示已跑多久。舊呼叫點不帶＝不顯示耗時。
    var startedAt: Date? = nil
}

enum LoopsSessionAgentTone: Equatable {
    case muted
    case active
    case warning
    case verified
    case destructive
}

enum LoopsSessionPresentationPolicy {
    // Kept as a source contract for fail-closed presentation:
    // 規劃預覽 · 尚未派發 · 無 runtime receipt
    static let planningConversationTitle = "規劃筆記"

    static func statusLabel(for truth: TatwoLoopsRuntimeTruthSummary) -> String {
        switch truth.state {
        case .planningPreview: return "規劃預覽"
        case .notDispatched: return "尚未送交"
        case .dispatched: return "已送交"
        case .running: return "執行中"
        case .receiptGated: return "等待驗收"
        case .blocked: return "執行受阻"
        }
    }

    static func statusSummary(for truth: TatwoLoopsRuntimeTruthSummary) -> String {
        switch truth.state {
        case .planningPreview, .notDispatched:
            return "目前只有規劃，尚未啟動任何 runtime agent。"
        case .dispatched:
            return truth.dispatchLabel
        case .running:
            return "\(truth.activeAgentCount) 個 runtime agent 正在執行。"
        case .receiptGated:
            return truth.runtimeReceiptCount > 0
                ? "正式執行已停止；請依收據完成驗收或 Goal Judge。"
                : "正式執行已停止，但仍缺可驗證的 runtime receipt。"
        case .blocked:
            return "執行受阻；不可把規劃或 artifact 計數當成完成。"
        }
    }

    static func workerSummary(
        session: TatwoLoopsSession,
        truth: TatwoLoopsRuntimeTruthSummary
    ) -> String {
        switch truth.state {
        case .dispatched:
            return "已送交 Work OS，等待 runner"
        case .running:
            return "\(truth.activeAgentCount) 個 runtime agent"
        case .receiptGated:
            return "目前沒有執行中 agent"
        case .blocked:
            return "正式工作受阻，查看 dispatch ledger"
        case .planningPreview, .notDispatched:
            return session.subAgents.isEmpty
                ? "尚無 runtime agent"
                : "預計 \(truth.plannedAgentCount) 個角色（未派發）"
        }
    }

    static func compactOwnerLabel(session: TatwoLoopsSession) -> String {
        let supervisorID = session.supervisorModelID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !supervisorID.isEmpty else {
            return "監工 未指定"
        }
        return "監工 \(TatwoChatRouteProfile.resolve(supervisorID).displayName)"
    }

    static func compactProgressLabel(
        session: TatwoLoopsSession,
        truth: TatwoLoopsRuntimeTruthSummary
    ) -> String {
        switch truth.state {
        case .planningPreview, .notDispatched:
            if truth.plannedAgentCount > 0 {
                return "預計 \(truth.plannedAgentCount) 個角色"
            }
            if !session.cycles.isEmpty {
                return "已有 \(session.cycles.count) 輪規劃，尚未送交"
            }
            return "尚未送交"
        case .dispatched:
            return "已送交，等待開始"
        case .running:
            return truth.activeAgentCount > 0
                ? "\(truth.activeAgentCount) 個執行中"
                : "已開始執行"
        case .receiptGated:
            if truth.producedArtifactCount > 0,
               truth.verifiedArtifactCount > 0 {
                return "已驗證 \(truth.verifiedArtifactCount)/\(truth.producedArtifactCount)"
            }
            if truth.runtimeReceiptCount > 0 {
                return "\(truth.runtimeReceiptCount) 份成果待驗收"
            }
            return "等待驗收"
        case .blocked:
            return truth.blockedArtifactCount > 0
                ? "\(truth.blockedArtifactCount) 項卡關"
                : "執行受阻"
        }
    }

    static func nextStep(for truth: TatwoLoopsRuntimeTruthSummary) -> String {
        switch truth.state {
        case .planningPreview, .notDispatched:
            return "需要執行時，按「送交 Work OS」建立正式工作；這不代表模型已啟動。"
        case .dispatched:
            return truth.nextAction
        case .running:
            return "等待執行完成，再核對 terminal output 與正式收據。"
        case .receiptGated:
            return "補齊正式收據並交由 verifier 驗收。"
        case .blocked:
            return "先處理阻塞原因，再由 Work OS 重派。"
        }
    }

    static func shouldShowCycles(for session: TatwoLoopsSession) -> Bool {
        !session.cycles.isEmpty
    }

    static func submissionLabel(isDispatching: Bool) -> String {
        isDispatching ? "送交中…" : "送交 Work OS"
    }

    static func agentTone(
        status: TatwoLoopsStatus,
        truth: TatwoLoopsRuntimeTruthSummary
    ) -> LoopsSessionAgentTone {
        guard truth.countsAsRuntimeProgress else {
            return .muted
        }

        switch status {
        case .planned: return .muted
        case .running: return .active
        case .blocked: return .warning
        case .passed:
            return truth.runtimeReceiptCount > 0 ? .verified : .warning
        case .rollbackRequired: return .destructive
        }
    }
}

enum LoopsSessionRailDensityPolicy {
    // The rail stays scannable whether it contains 5 or 20 Loops. Detail is
    // selection-driven; row count must never make every row permanently taller.
    static let collapsedRowHeight: CGFloat = 48

    static func isExpanded(rowID: UUID, selectedID: UUID?) -> Bool {
        rowID == selectedID
    }
}

struct LoopsSessionDisclosureState: Equatable {
    var cycleHistoryExpanded = false
    var configurationExpanded = false
    var planningConversationExpanded = false

    mutating func rowExpansionChanged(to isExpanded: Bool) {
        guard !isExpanded else { return }
        cycleHistoryExpanded = false
        configurationExpanded = false
        planningConversationExpanded = false
    }
}

struct LoopsSessionRailAccordionState: Equatable {
    var currentWorkExpanded = false
    var liveDetailsExpanded = false
    var archivedExpanded = false

    mutating func sessionSelected() {
        currentWorkExpanded = false
        liveDetailsExpanded = false
        archivedExpanded = false
    }

    mutating func toggleCurrentWork() -> Bool {
        let willExpand = !currentWorkExpanded
        currentWorkExpanded = willExpand
        liveDetailsExpanded = false
        archivedExpanded = false
        return willExpand
    }

    mutating func toggleLiveDetails() -> Bool {
        let willExpand = !liveDetailsExpanded
        liveDetailsExpanded = willExpand
        currentWorkExpanded = false
        archivedExpanded = false
        return willExpand
    }

    mutating func setArchivedExpanded(_ expanded: Bool) -> Bool {
        archivedExpanded = expanded
        if expanded {
            currentWorkExpanded = false
            liveDetailsExpanded = false
        }
        return expanded
    }
}

private struct LoopsAccordionRowLabel: View {
    let title: String
    let summary: String
    let status: String
    let statusColor: Color
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Text(status)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(statusColor)
                .background(statusColor.opacity(0.14), in: Capsule())
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: LoopsSessionRailDensityPolicy.collapsedRowHeight,
            maxHeight: LoopsSessionRailDensityPolicy.collapsedRowHeight,
            alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct LoopsSessionRail: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let sessions: [TatwoLoopsSession]
    var archivedSessions: [TatwoLoopsSession] = []
    let supervisorModelID: String
    let selectedID: UUID?
    var liveRows: [TatwoLoopsLiveRow] = []
    let onCreate: () -> Void
    let onSelect: (UUID) -> Void
    let onArchive: (UUID) -> Void
    var onRestore: (UUID) -> Void = { _ in }
    let onSendMessage: (UUID, String) -> Void
    let onDispatchSub: (UUID) -> Void
    let onAdvanceRound: (UUID) -> Void
    var dispatchingID: UUID? = nil
    // #16 /plg 執行流卡（有 run 時釘在最上）；宣告在末尾以配合呼叫端傳參順序。
    var plgRun: TatwoPLGRun? = nil
    var plgDispatchRecords: [TatwoDispatchRecord] = []
    var canonicalGoalRecord: TatwoStoredGoalRun? = nil
    var plgBlockerMessage: String? = nil
    var plgPaused: Bool = false
    var isFocusedWorkspace: Bool = false
    var onToggleFocus: () -> Void = {}
    var onPLGAuthorize: () -> Void = {}
    var onPLGMainline: (Bool) -> Void = { _ in }
    var onPLGRollback: () -> Void = {}
    var onPLGConfirmPlan: () -> Void = {}
    var onPLGEndGoal: () -> Void = {}
    var onPLGTogglePause: () -> Void = {}
    var plgCanAdvanceCycle: Bool = false
    var onPLGAdvanceCycle: () -> Void = {}
    @State private var accordionState = LoopsSessionRailAccordionState()

    private var supervisorName: String {
        TatwoChatRouteProfile.resolve(supervisorModelID).displayName
    }

    private var canonicalGoalLane: TatwoGoalRunLaneV1? {
        guard let canonicalGoalRecord else { return nil }
        let run = TatwoStoredDispatchRun(
            contractID: canonicalGoalRecord.contractID,
            records: plgDispatchRecords,
            updatedAt:
                plgDispatchRecords.map(\.updatedAt).max()
                ?? canonicalGoalRecord.updatedAt)
        return TatwoGoalRunLaneAggregator.aggregate(
            goalRecords: [canonicalGoalRecord],
            dispatchRuns: [run],
            observedAt: Date()
        ).lanes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let plgRun {
                        sectionLabel(
                            title: "目前工作",
                            detail: "點擊一列展開")
                        currentWorkSection(plgRun)
                    }

                    // 2026-08-21 使用者回饋「看不到 sub 實際的運作情況」，
                    // 推翻舊裁定（PLG 卡只給總數就不再畫列）。PLG 卡管流程
                    // 相位，這裡管「每個 sub 是誰、在做什麼、跑多久」——
                    // 同一 ledger 的兩個互補視角，PLG 進行中也要看得到。
                    if !liveRows.isEmpty {
                        sectionLabel(
                            title: plgRun == nil ? "目前執行" : "Sub 實況",
                            detail: "\(liveRows.count) 位")
                        liveCard
                    }

                    if !sessions.isEmpty {
                        planningSessionsSection
                    }

                    if !archivedSessions.isEmpty {
                        archivedSessionsSection
                    }

                    if plgRun == nil,
                       sessions.isEmpty,
                       archivedSessions.isEmpty,
                       liveRows.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidGlassSurface(cornerRadius: 0)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loops 工作區")
        .accessibilityValue("監工 \(supervisorName)")
        .onChange(of: selectedID) { _, newSelection in
            if newSelection != nil {
                accordionState.sessionSelected()
            }
        }
        .onChange(of: plgRun?.id, initial: true) { _, runID in
            if runID != nil {
                accordionState.currentWorkExpanded = true
                accordionState.liveDetailsExpanded = false
                accordionState.archivedExpanded = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
            Text("Loops 工作區")
                .font(.system(size: 13, weight: .black, design: .rounded))
            Spacer(minLength: 4)
            Button(action: onToggleFocus) {
                Image(
                    systemName: isFocusedWorkspace
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .background(
                        LiquidGlassTokens.brandAccent.opacity(
                            isFocusedWorkspace ? 0.16 : 0.07),
                        in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isFocusedWorkspace
                    ? "縮回並排顯示"
                    : "放大為全寬 Loops 工作區")
            .accessibilityLabel(
                isFocusedWorkspace
                    ? "縮回 Loops 工作區"
                    : "放大 Loops 工作區")

            if plgRun == nil {
                Button(action: onCreate) {
                    Label("新規劃", systemImage: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 44)
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .background(
                            LiquidGlassTokens.brandAccent.opacity(0.12),
                            in: Capsule())
                }
                .buttonStyle(.plain)
                .help("建立 Loops 規劃草稿；不會直接啟動模型")
                .accessibilityLabel("建立新的 Loops 規劃")
            }
        }
    }

    @ViewBuilder
    private var planningSessionsSection: some View {
        sectionLabel(
            title: plgRun == nil ? "Loops" : "規劃草稿",
            detail: "\(sessions.count) 條 · 點擊一列展開")
        sessionRows
    }

    private var sessionRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(sessions) { session in
                LoopsSessionRow(
                    session: session,
                    isExpanded: LoopsSessionRailDensityPolicy.isExpanded(
                        rowID: session.id,
                        selectedID: selectedID),
                    isDispatching: dispatchingID == session.id,
                    isDispatchDisabled: dispatchingID != nil,
                    onSelect: { selectSession(session.id) },
                    onArchive: { onArchive(session.id) },
                    onSendMessage: { onSendMessage(session.id, $0) },
                    onDispatchSub: { onDispatchSub(session.id) },
                    onAdvanceRound: { onAdvanceRound(session.id) })
            }
        }
    }

    private var archivedSessionsSection: some View {
        DisclosureGroup(isExpanded: archivedExpansionBinding) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(archivedSessions) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(session.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("還原") {
                            onRestore(session.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("還原 \(session.title)")
                    }
                    .padding(.horizontal, 10)
                    .background(
                        Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.top, 6)
        } label: {
            Button {
                setArchivedExpanded(!accordionState.archivedExpanded)
            } label: {
                disclosureSectionLabel(
                    title: "已封存",
                    detail: "\(archivedSessions.count) 條")
            }
            .buttonStyle(.plain)
            .tatwoPointerCursor()
        }
        .tint(LiquidGlassTokens.brandAccent)
        .help("封存只收起規劃，不會刪除資料；可隨時還原")
    }

    private var archivedExpansionBinding: Binding<Bool> {
        Binding(
            get: { accordionState.archivedExpanded },
            set: { setArchivedExpanded($0) })
    }

    private func sectionLabel(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureSectionLabel(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    // One compact runtime overview; individual dispatch rows are opt-in.
    private var liveCard: some View {
        let ledger = TatwoDispatchRuntimeReducer.reduce(records: plgDispatchRecords)
        let color = runtimeColor(ledger.phase)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                toggleLiveDetails()
            } label: {
                LoopsAccordionRowLabel(
                    title: ledger.hasRuntimeEvidence
                        ? "Work OS runtime"
                        : "Work OS 執行樣本",
                    summary: ledger.hasRuntimeEvidence
                        ? ledger.progressLabel
                        : "\(liveRows.count) 筆樣本",
                    status: ledger.headline,
                    statusColor: color,
                    isExpanded: accordionState.liveDetailsExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                accordionState.liveDetailsExpanded
                    ? "收合 Work OS runtime"
                    : "展開 Work OS runtime")

            // 2026-08-21：PLG 進行中 sub 實況直接攤開（使用者要「一眼看到
            // sub 在幹嘛」，不該還要多點一下）；非 PLG 情境保留手風琴。
            if accordionState.liveDetailsExpanded || plgRun != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text(ledger.runtimeReceiptLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(liveRows) { row in
                        subLiveRow(row)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LiquidGlassTokens.brandAccent.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.30), lineWidth: 1.5))
    }

    private func currentWorkSection(_ run: TatwoPLGRun) -> some View {
        let truth = TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: plgDispatchRecords)
        let canonicalStatus = canonicalGoalLane.map {
            LoopsCanonicalGoalPresentationPolicy.status($0)
        }
        let color =
            canonicalStatus?.color ?? currentWorkColor(truth.state)
        let summary = run.planSummary.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                toggleCurrentWork()
            } label: {
                LoopsAccordionRowLabel(
                    title: "正式 Work OS",
                    summary: summary.isEmpty ? "尚未建立 Plan 摘要" : summary,
                    status: plgPaused
                        ? "已暫停"
                        : canonicalStatus?.label
                            ?? currentWorkStatus(truth.state),
                    statusColor: plgPaused ? LiquidGlassTokens.loopsCaution : color,
                    isExpanded: accordionState.currentWorkExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                accordionState.currentWorkExpanded
                    ? "收合目前 Work OS 工作"
                    : "展開目前 Work OS 工作")
            .accessibilityValue(
                plgPaused
                    ? "已暫停"
                    : canonicalStatus?.label
                        ?? currentWorkStatus(truth.state))

            if accordionState.currentWorkExpanded {
                if canonicalGoalLane?.state == .superseded {
                    Text("此 predecessor 已 canonical superseded；歷史 dispatch 只保留為證據，不再投影成目前 blocker。")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 10)
                } else {
                    PLGFlowCard(
                        run: run,
                        onAuthorize: onPLGAuthorize,
                        onEvaluateMainline: onPLGMainline,
                        onRollback: onPLGRollback,
                        dispatchRecords: plgDispatchRecords,
                        blockerMessage: plgBlockerMessage,
                        onConfirmPlan: onPLGConfirmPlan,
                        onEndGoal: onPLGEndGoal,
                        onTogglePause: onPLGTogglePause,
                        paused: plgPaused,
                        canAdvanceCycle: plgCanAdvanceCycle,
                        onAdvanceCycle: onPLGAdvanceCycle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LiquidGlassTokens.brandAccent.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    LiquidGlassTokens.brandAccent.opacity(0.16),
                    lineWidth: 1))
    }

    private func currentWorkStatus(
        _ state: TatwoPLGExecutionTruthState
    ) -> String {
        switch state {
        case .planningPreview: return "規劃中"
        case .notDispatched: return "尚未送交"
        case .dispatched: return "已送交"
        case .running: return "執行中"
        case .receiptGated: return "等待驗收"
        case .blocked: return "執行受阻"
        }
    }

    private func currentWorkColor(
        _ state: TatwoPLGExecutionTruthState
    ) -> Color {
        switch state {
        case .planningPreview, .notDispatched: return .secondary
        case .dispatched: return LiquidGlassTokens.loopsCaution
        case .running: return LiquidGlassTokens.brandAccent
        case .receiptGated: return LiquidGlassTokens.loopsCaution
        case .blocked: return LiquidGlassTokens.loopsCritical
        }
    }

    private func selectSession(_ id: UUID) {
        accordionState.sessionSelected()
        onSelect(id)
    }

    private func toggleCurrentWork() {
        let willExpand = accordionState.toggleCurrentWork()
        if willExpand, let selectedID {
            onSelect(selectedID)
        }
    }

    private func toggleLiveDetails() {
        let willExpand = accordionState.toggleLiveDetails()
        if willExpand, let selectedID {
            onSelect(selectedID)
        }
    }

    private func setArchivedExpanded(_ expanded: Bool) {
        let willExpand = accordionState.setArchivedExpanded(expanded)
        if willExpand, let selectedID {
            onSelect(selectedID)
        }
    }

    /// Sub 實況單列：狀態點｜身份＋模型名（人話）｜狀態｜已跑多久，下行是
    /// 「目前在做什麼」。全部走語意 token，無原生雜色。
    private func subLiveRow(_ row: TatwoLoopsLiveRow) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(runtimeColor(row.phase))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.identity)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                    Text(TatwoChatRouteProfile.resolve(row.modelID).displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(row.statusLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(runtimeColor(row.phase))
                    if row.phase == .running || row.phase == .started,
                       let startedAt = row.startedAt {
                        Text(Self.elapsedLabel(since: startedAt))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func elapsedLabel(since startedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        if seconds >= 3_600 { return "已跑 \(seconds / 3_600) 小時 \((seconds % 3_600) / 60) 分" }
        if seconds >= 60 { return "已跑 \(seconds / 60) 分" }
        return "已跑 \(seconds) 秒"
    }

    private func runtimeColor(_ phase: TatwoDispatchRuntimePhase) -> Color {
        switch phase {
        case .none, .queued: return .secondary
        case .delivered, .started: return LiquidGlassTokens.brandAccent
        case .running: return LiquidGlassTokens.brandAccent
        case .completed: return LiquidGlassTokens.loopsPositive
        case .verified: return LiquidGlassTokens.loopsPositive
        case .failed: return LiquidGlassTokens.loopsCritical
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("尚無 loops session")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("點「新規劃」建立一條 Loops 工作。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

enum LoopsCanonicalGoalPresentationPolicy {
    struct Status: Equatable {
        let label: String
        let color: Color

        static func == (lhs: Status, rhs: Status) -> Bool {
            lhs.label == rhs.label
        }
    }

    static func status(_ lane: TatwoGoalRunLaneV1) -> Status {
        switch lane.state {
        case .planned: return Status(label: "已規劃", color: .secondary)
        case .waitingDependency:
            return Status(label: "等待依賴", color: LiquidGlassTokens.loopsCaution)
        case .ready: return Status(label: "可送交", color: LiquidGlassTokens.loopsCaution)
        case .running:
            return Status(
                label: lane.blockers.isEmpty ? "執行中" : "執行受阻",
                color: lane.blockers.isEmpty
                    ? LiquidGlassTokens.brandAccent : LiquidGlassTokens.loopsCritical)
        case .humanGate: return Status(label: "等待驗收", color: LiquidGlassTokens.loopsCaution)
        case .blocked: return Status(label: "執行受阻", color: LiquidGlassTokens.loopsCritical)
        case .superseded:
            return Status(label: "已由新版取代", color: .secondary)
        case .passed: return Status(label: "已通過", color: LiquidGlassTokens.loopsPositive)
        case .rollbackRequired:
            return Status(label: "需要回滾", color: LiquidGlassTokens.loopsCritical)
        }
    }
}

struct LoopsSessionRow: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let session: TatwoLoopsSession
    let isExpanded: Bool
    let isDispatching: Bool
    let isDispatchDisabled: Bool
    let onSelect: () -> Void
    let onArchive: () -> Void
    let onSendMessage: (String) -> Void
    let onDispatchSub: () -> Void
    let onAdvanceRound: () -> Void

    @State private var composeText: String = ""
    @State private var disclosureState = LoopsSessionDisclosureState()
    @State private var showArchiveConfirmation = false

    private var runtimeTruth: TatwoLoopsRuntimeTruthSummary {
        TatwoLoopsDispatchPlanner.runtimeTruth(session: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onSelect) {
                LoopsAccordionRowLabel(
                    title: session.title,
                    summary:
                        "\(LoopsSessionPresentationPolicy.compactOwnerLabel(session: session))"
                        + " · "
                        + LoopsSessionPresentationPolicy.compactProgressLabel(
                            session: session,
                            truth: runtimeTruth),
                    status: statusLabel,
                    statusColor: statusColor,
                    isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isExpanded
                    ? "收合 \(session.title)"
                    : "展開 \(session.title)")
            .accessibilityValue("真實狀態 \(statusLabel)")

            if isExpanded { detail }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LiquidGlassTokens.brandAccent.opacity(isExpanded ? 0.07 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(LiquidGlassTokens.brandAccent.opacity(isExpanded ? 0.28 : 0.10), lineWidth: 1))
        .onChange(of: isExpanded) { _, expanded in
            disclosureState.rowExpansionChanged(to: expanded)
            if !expanded {
                showArchiveConfirmation = false
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            overviewCard
            if LoopsSessionPresentationPolicy.shouldShowCycles(for: session) {
                cycleHistoryDisclosure
            }
            configurationDisclosure
            planningConversationDisclosure
            actionBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作概況")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            overviewRow(
                icon: "waveform.path.ecg",
                label: "狀態",
                value: LoopsSessionPresentationPolicy.statusSummary(for: runtimeTruth),
                tint: statusColor)
            Divider().opacity(0.45)
            overviewRow(
                icon: "scope",
                label: "Goal",
                value: goalSummary,
                tint: LiquidGlassTokens.brandAccent,
                lineLimit: 3)
            Divider().opacity(0.45)
            overviewRow(
                icon: "person.2",
                label: "執行者",
                value: LoopsSessionPresentationPolicy.workerSummary(
                    session: session,
                    truth: runtimeTruth),
                tint: LiquidGlassTokens.brandAccent)
            Divider().opacity(0.45)
            overviewRow(
                icon: "arrow.right.circle",
                label: "下一步",
                value: LoopsSessionPresentationPolicy.nextStep(for: runtimeTruth),
                tint: LiquidGlassTokens.loopsCaution,
                lineLimit: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loops 工作概況")
    }

    private func overviewRow(
        icon: String,
        label: String,
        value: String,
        tint: Color,
        lineLimit: Int? = 2
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 15, height: 18, alignment: .center)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var configurationDisclosure: some View {
        DisclosureGroup(isExpanded: $disclosureState.configurationExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                plgBlock("完整 Goal", session.plg.goal)
                plgBlock("Plan", session.plg.plan)
                plgBlock("Loops 範圍", session.plg.loops)
                modelConfiguration
            }
            .padding(.top, 5)
        } label: {
            Button {
                disclosureState.configurationExpanded.toggle()
            } label: {
                disclosureLabel(
                    title: "完整規劃與配置",
                    detail: "Plan · Goal · 模型")
            }
            .buttonStyle(.plain)
            .tatwoPointerCursor()
        }
        .tint(LiquidGlassTokens.brandAccent)
        .help("展開完整 Plan、Goal 與模型配置")
        .accessibilityLabel("完整規劃與配置")
        .accessibilityValue(
            disclosureState.configurationExpanded ? "已展開" : "已收合")
    }

    private var cycleHistoryDisclosure: some View {
        DisclosureGroup(isExpanded: $disclosureState.cycleHistoryExpanded) {
            cyclesViz
                .padding(.top, 5)
        } label: {
            Button {
                disclosureState.cycleHistoryExpanded.toggle()
            } label: {
                disclosureLabel(
                    title: "輪次進度",
                    detail: compactCycleSummary)
            }
            .buttonStyle(.plain)
            .tatwoPointerCursor()
        }
        .tint(LiquidGlassTokens.brandAccent)
        .help("展開才顯示各輪次；預設只保留最新輪次摘要")
        .accessibilityLabel("輪次進度")
        .accessibilityValue(
            disclosureState.cycleHistoryExpanded ? "已展開" : "已收合")
    }

    private var compactCycleSummary: String {
        guard let latest = session.cycles.last else {
            return "尚無輪次"
        }
        let totalRounds = max(latest.totalRounds, session.cycles.count)
        return "\(session.cycles.count) 輪 · 最新 R\(latest.round)/\(totalRounds)"
    }

    private var planningConversationDisclosure: some View {
        DisclosureGroup(isExpanded: $disclosureState.planningConversationExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                messageThread
                composeBar
            }
            .padding(.top, 5)
        } label: {
            Button {
                disclosureState.planningConversationExpanded.toggle()
            } label: {
                disclosureLabel(
                    title: LoopsSessionPresentationPolicy.planningConversationTitle,
                    detail: session.messages.isEmpty
                        ? "尚無訊息"
                        : "\(session.messages.count) 則")
            }
            .buttonStyle(.plain)
            .tatwoPointerCursor()
        }
        .tint(LiquidGlassTokens.brandAccent)
        .help("展開規劃對話；預設收合以避免長文佔滿工作概況")
        .accessibilityLabel(LoopsSessionPresentationPolicy.planningConversationTitle)
        .accessibilityValue(
            disclosureState.planningConversationExpanded ? "已展開" : "已收合")
    }

    private func disclosureLabel(title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var modelConfiguration: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型配置")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(LiquidGlassTokens.brandAccent.opacity(0.85))
            configurationRow(
                label: "監工",
                value: "\(modelDisplayName(session.supervisorModelID)) · 由主串繼承")
            if let reviewerModelID = session.reviewerModelID,
               !reviewerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configurationRow(
                    label: "副審",
                    value: modelDisplayName(reviewerModelID))
            }
            if session.subAgents.isEmpty {
                configurationRow(label: "執行角色", value: "尚未規劃")
            } else {
                ForEach(session.subAgents) { sub in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(subColor(sub.status))
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                        Text(sub.label)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(minWidth: 68, alignment: .leading)
                        Text(modelDisplayName(sub.modelID))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(subStatusLabel(sub.status))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(subColor(sub.status))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configurationRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // Empty cycles are intentionally absent. Existing rounds require their own
    // explicit disclosure and never masquerade as runtime receipts.
    private var cyclesViz: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                runtimeTruth.countsAsRuntimeProgress
                    ? "輪次記錄"
                    : "規劃輪次（不代表已執行）")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(LiquidGlassTokens.brandAccent.opacity(0.85))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.cycles) { cycle in
                        VStack(spacing: 3) {
                            cycleBar(cycle)
                            Text("R\(cycle.round)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func cycleBar(_ cycle: TatwoLoopsCycleProgress) -> some View {
        let total = max(cycle.producedCount, 1)
        let vf = CGFloat(cycle.verifiedCount) / CGFloat(total)
        let bl = CGFloat(cycle.blockedCount) / CGFloat(total)
        return GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        runtimeTruth.runtimeReceiptCount > 0
                            ? LiquidGlassTokens.loopsPositive.opacity(0.7)
                            : LiquidGlassTokens.loopsCaution.opacity(0.62))
                    .frame(height: h * min(vf, 1))
                Rectangle().fill(LiquidGlassTokens.loopsCaution.opacity(0.7)).frame(height: h * min(bl, 1 - min(vf, 1)))
                Rectangle().fill(Color.secondary.opacity(0.18))
            }
        }
        .frame(width: 32, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help(
            "Round \(cycle.round)：artifact 產出 \(cycle.producedCount)／"
            + "驗證 \(cycle.verifiedCount)／卡關 \(cycle.blockedCount)；"
            + runtimeTruth.runtimeReceiptLabel)
    }

    // The whole conversation is already opt-in via planningConversationDisclosure.
    private var messageThread: some View {
        VStack(alignment: .leading, spacing: 5) {
            if session.messages.isEmpty {
                Text("尚無規劃對話。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                if session.messages.count > 20 {
                    Text("僅顯示最近 20 / 共 \(session.messages.count) 則")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(session.messages.suffix(20)) { msg in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(roleLabel(msg.role))
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(roleColor(msg.role))
                            if let m = msg.authorModelID, !m.isEmpty {
                                Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Text(msg.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(roleColor(msg.role).opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var composeBar: some View {
        HStack(spacing: 6) {
            TextField("新增規劃筆記…", text: $composeText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...3)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(minHeight: 44)
                .background(LiquidGlassTokens.brandAccent.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onSubmit(send)
                .accessibilityLabel("規劃筆記輸入")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : LiquidGlassTokens.brandAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("儲存規劃筆記")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: onDispatchSub) {
                HStack(spacing: 4) {
                    if isDispatching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                    }
                    Text(
                        LoopsSessionPresentationPolicy.submissionLabel(
                            isDispatching: isDispatching))
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(.white)
                .background(LiquidGlassTokens.brandAccent.opacity(isDispatching ? 0.6 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDispatchDisabled)
            .help("送交 Work OS 建立正式 dispatch；成功後 runner 會進入 running")
            .accessibilityLabel(
                LoopsSessionPresentationPolicy.submissionLabel(
                    isDispatching: isDispatching))

            Button(action: onAdvanceRound) {
                Label("新增規劃輪次", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("只新增規劃輪次；不代表已派發或執行")
            .accessibilityLabel("新增規劃輪次")

            Spacer(minLength: 0)

            Button {
                showArchiveConfirmation = true
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("封存規劃；資料保留，可在 Loops 工作區還原")
            .accessibilityLabel("封存這條 Loops")
        }
        .padding(.top, 2)
        .confirmationDialog(
            "封存這條 Loops 規劃？",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("封存規劃") {
                onArchive()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會把規劃收進「已封存」；不會刪除資料，也不會停止 Work OS 的正式工作。")
        }
    }

    private func send() {
        let t = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSendMessage(t)
        composeText = ""
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "supervisor": return "監工"
        case "reviewer": return "副審"
        case "sub": return "SUB"
        case "human": return "你"
        default: return role.uppercased()
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "supervisor": return LiquidGlassTokens.brandAccent
        case "reviewer": return LiquidGlassTokens.accentBlue
        case "sub": return LiquidGlassTokens.accentViolet
        case "human": return .secondary
        default: return .secondary
        }
    }

    private func subStatusLabel(_ s: TatwoLoopsStatus) -> String {
        if !runtimeTruth.countsAsRuntimeProgress {
            switch s {
            case .blocked: return "卡住"
            case .rollbackRequired: return "需回滾"
            default: return "尚未派發"
            }
        }
        switch s {
        case .planned: return "規劃預覽"
        case .running: return "執行中"
        case .blocked: return "卡住"
        case .passed:
            return runtimeTruth.runtimeReceiptCount > 0 ? "完成" : "產出待收據"
        case .rollbackRequired: return "需回滾"
        }
    }

    private func subColor(_ s: TatwoLoopsStatus) -> Color {
        switch LoopsSessionPresentationPolicy.agentTone(
            status: s,
            truth: runtimeTruth
        ) {
        case .muted: return .secondary
        case .active: return LiquidGlassTokens.brandAccent
        case .warning: return LiquidGlassTokens.loopsCaution
        case .verified: return LiquidGlassTokens.loopsPositive
        case .destructive: return LiquidGlassTokens.loopsCritical
        }
    }

    private func plgBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(LiquidGlassTokens.brandAccent.opacity(0.85))
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var goalSummary: String {
        let trimmed = session.plg.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "尚未定義 Goal" : trimmed
    }

    private func modelDisplayName(_ modelID: String) -> String {
        let resolved = TatwoChatRouteProfile.resolve(modelID).displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? modelID : resolved
    }

    private var statusLabel: String {
        LoopsSessionPresentationPolicy.statusLabel(for: runtimeTruth)
    }

    private var statusColor: Color {
        switch runtimeTruth.state {
        case .planningPreview, .notDispatched: return .secondary
        case .dispatched: return LiquidGlassTokens.loopsCaution
        case .running: return LiquidGlassTokens.brandAccent
        case .receiptGated: return LiquidGlassTokens.loopsCaution
        case .blocked: return LiquidGlassTokens.loopsCritical
        }
    }
}
