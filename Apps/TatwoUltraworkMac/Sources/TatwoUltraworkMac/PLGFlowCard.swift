import SwiftUI
import TatwoUltraworkCore

struct PLGBranchAccordionState: Equatable {
    private(set) var expandedBranchID: UUID?

    init(expandedBranchID: UUID? = nil) {
        self.expandedBranchID = expandedBranchID
    }

    func isExpanded(_ branchID: UUID) -> Bool {
        expandedBranchID == branchID
    }

    mutating func toggle(_ branchID: UUID) {
        expandedBranchID = expandedBranchID == branchID ? nil : branchID
    }

    mutating func reconcile(validIDs: [UUID]) {
        guard let expandedBranchID,
              !validIDs.contains(expandedBranchID)
        else { return }
        self.expandedBranchID = nil
    }
}

// #16 /plg 執行流可視化：把 TatwoPLGRun 畫成 canonical 藍圖形，一眼看
// 「Plan(主導) → Loops(副審+Sub) → Goal(主導) → 完工提交人類」現在走到哪、還在跑嗎、要不要授權。
struct PLGFlowCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private struct PresentedBranch: Identifiable {
        let branch: TatwoPLGBranchGoal
        let presentation: TatwoPLGBranchPresentation

        var id: UUID { branch.id }
    }

    @State private var branchAccordionState = PLGBranchAccordionState()

    let run: TatwoPLGRun
    let onAuthorize: () -> Void
    let onEvaluateMainline: (Bool) -> Void
    let onRollback: () -> Void
    var dispatchRecords: [TatwoDispatchRecord] = []
    var blockerMessage: String? = nil
    var onConfirmPlan: () -> Void = {}
    var onEndGoal: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var paused: Bool = false
    var canAdvanceCycle: Bool = false
    var onAdvanceCycle: () -> Void = {}

    private var leadNames: String {
        run.leadBindings.map { TatwoChatRouteProfile.resolve($0.modelID ?? "").displayName }.joined(separator: " + ")
    }
    private var subNames: String {
        run.subBindings.map { TatwoChatRouteProfile.resolve($0.modelID ?? "").displayName }.joined(separator: " + ")
    }
    private var executionTruth: TatwoPLGExecutionTruthSummary {
        TatwoPLGGovernance.executionTruth(
            run: run,
            dispatchRecords: dispatchRecords)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            identityRow
            executionTruthCard
            spine
            phaseDetail
            if canAdvanceCycle {
                advanceCycleSection
            }
            if let blockerMessage,
               !blockerMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockerCard(blockerMessage)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiquidGlassTokens.brandAccent.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.34), lineWidth: 1.5))
    }

    /// M4b cycle seal 之後的人門：開新 cycle 是人的決定。只在 goal 停在
    /// humanGate／awaitingNextCycle（本輪 dispatch 已封存）時出現。
    private var advanceCycleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本輪 dispatch 已封存；goal 仍開放，可開啟下一輪或交 Goal 裁決。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAdvanceCycle) {
                Label("開啟下一輪 cycle", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .foregroundStyle(.white)
                    .background(LiquidGlassTokens.brandAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .accessibilityIdentifier("plg-advance-cycle")
            .accessibilityHint("封存後開啟新一輪 dispatch cycle")
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
            Text("PLG 流程")
                .font(.system(size: 13, weight: .black, design: .rounded))
            Spacer(minLength: 4)
            if isLive {
                Button(action: onTogglePause) {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(paused ? "續跑目標" : "暫停目標")
                .accessibilityLabel(paused ? "繼續 PLG 目標" : "暫停 PLG 目標")
                .accessibilityHint("不會關閉 Work OS goal")
                Button(action: onEndGoal) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LiquidGlassTokens.loopsCritical.opacity(0.85))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("關閉本機流程卡（不關閉 Work OS goal）")
                .accessibilityLabel("關閉本機 PLG 流程卡")
                .accessibilityHint("只關閉視覺投影，不關閉 Work OS goal")
            }
            Text(paused ? "已暫停" : executionStatusLabel)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(paused ? LiquidGlassTokens.loopsCaution : phaseColor)
                .background((paused ? LiquidGlassTokens.loopsCaution : phaseColor).opacity(0.15), in: Capsule())
        }
    }

    // 目標仍在跑（非完成/回滾）→ 顯示暫停/結束控制。
    private var isLive: Bool {
        run.phase != .passed && run.phase != .rollbackRequired
    }

    private var identityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !executionTruth.countsAsRuntimeProgress {
                Text("規劃預覽 · planned identities 不代表已派發")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(run.isMultiLead ? "主導群" : "主導")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(leadNames)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !subNames.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Loops Sub")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(subNames)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiquidGlassTokens.brandAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var executionTruthCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(executionTruth.headline)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(executionTruthColor)
            Text(executionTruth.dispatchLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(executionTruth.runtimeReceiptLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    executionTruth.runtimeReceiptCount > 0 ? LiquidGlassTokens.loopsPositive : Color.secondary)
            Text(executionTruth.nextAction)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            executionTruthColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // canonical 形：Plan主導 → Loops(副審+Sub) → Goal主導 → 人類；current phase 高亮。
    private var spine: some View {
        ViewThatFits(in: .horizontal) {
            spineHorizontal
            spineVertical
        }
    }

    private var spineHorizontal: some View {
        HStack(spacing: 3) {
            spineNode("Plan", "主導", stage: 0)
            spineArrow(after: 0, vertical: false)
            spineNode("Loops", "副審+Sub", stage: 1)
            spineArrow(after: 1, vertical: false)
            spineNode("Goal", "主導", stage: 2)
            spineArrow(after: 2, vertical: false)
            spineNode("提交", "人類", stage: 3)
        }
    }

    private var spineVertical: some View {
        VStack(alignment: .leading, spacing: 3) {
            spineNode("Plan", "主導", stage: 0)
            spineArrow(after: 0, vertical: true)
            spineNode("Loops", "副審+Sub", stage: 1)
            spineArrow(after: 1, vertical: true)
            spineNode("Goal", "主導", stage: 2)
            spineArrow(after: 2, vertical: true)
            spineNode("提交", "人類", stage: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spineNode(_ title: String, _ role: String, stage: Int) -> some View {
        let active = currentStage == stage
        let done = currentStage > stage
        let tint = done ? LiquidGlassTokens.loopsPositive : (active ? LiquidGlassTokens.brandAccent : Color.secondary)
        return VStack(spacing: 1) {
            Text(title).font(.system(size: 11, weight: active ? .black : .semibold, design: .rounded))
                .foregroundStyle(active || done ? tint : .secondary)
            Text(role).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(active ? 0.16 : (done ? 0.08 : 0.03)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(active ? tint : .clear, lineWidth: 1.5))
    }

    private func spineArrow(after stage: Int, vertical: Bool) -> some View {
        Image(systemName: vertical ? "arrow.down" : "arrow.right")
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(currentStage > stage ? LiquidGlassTokens.loopsPositive : .secondary.opacity(0.5))
            .frame(
                maxWidth: vertical ? .infinity : nil,
                alignment: vertical ? .leading : .center)
            .padding(.leading, vertical ? 12 : 0)
    }

    @ViewBuilder
    private var phaseDetail: some View {
        switch run.phase {
        case .planning:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(LiquidGlassTokens.brandAccent)
                    Text("Plan 討論中").font(.system(size: 11, weight: .black)).foregroundStyle(LiquidGlassTokens.brandAccent)
                }
                detailText(run.planSummary.isEmpty ? "與主導在對話框來回釐清目標…" : run.planSummary)
                Text("在下方對話框與主導討論；確認後才分工，Enter 不會直接派工。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onConfirmPlan) {
                    Label("確認計畫，進入分工", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(LiquidGlassTokens.brandAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .accessibilityIdentifier("plg-confirm-plan")
                .accessibilityHint("確認後才會開始 Loops 分工")
            }
        case .leadAdversarial:
            detailText("主導群對抗驗證中：" + (run.adversarialConclusion ?? "各自分析 + refute-first…"))
        case .awaitingHumanAuth:
            VStack(alignment: .leading, spacing: 7) {
                if let c = run.adversarialConclusion { detailText("結論：\(c)") }
                Text("等你授權後才進入執行（human gate）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(action: onAuthorize) {
                    Label("授權執行", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(LiquidGlassTokens.brandAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("授權後才會啟動已綁定的 Loops 分支")
            }
        case .executingLoops, .branchesReporting:
            branchList
        case .mainlineGoalCheck:
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    executionTruth.runtimeReceiptCount > 0
                        ? "已有 runtime receipt；App 只能標 READY，goal 仍由 OS 關閉。"
                        : "分支／phase 已前進，但無 runtime receipt；不可算已回報或已驗收。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { onEvaluateMainline(true) } label: {
                        Label("收據 READY", systemImage: "checkmark.seal").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(LiquidGlassTokens.brandAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(executionTruth.runtimeReceiptCount == 0)
                    .help("等待 Work OS close/gate；App 無 promotion 權限")
                    Button { onEvaluateMainline(false) } label: {
                        Label("未達·回滾", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LiquidGlassTokens.brandAccent).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(LiquidGlassTokens.brandAccent.opacity(0.14), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Text("等待 Work OS close/gate")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
            }
        case .passed:
            detailText(
                executionTruth.runtimeReceiptCount > 0
                    ? "✅ Work OS 已確認結果；App 僅顯示已存證狀態。"
                    : "phase 標記 passed，但無 runtime receipt；App 不把它顯示成已驗收。")
        case .rollbackRequired:
            detailText("↩︎ 需回滾：主線未達標或分支阻斷。")
        }
    }

    private var branchList: some View {
        VStack(alignment: .leading, spacing: 5) {
            let branches = run.branchGoals.map {
                PresentedBranch(
                    branch: $0,
                    presentation: branchPresentation(for: $0))
            }
            let total = branches.count
            let passed = branches.filter {
                $0.presentation.isVerifiedPass
            }.count
            let pct = total == 0 ? 0 : Int((Double(passed) / Double(total) * 100).rounded())
            HStack(spacing: 6) {
                Text("目標項目（\(passed)/\(total) 已完成）")
                    .font(.system(size: 11, weight: .black)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(pct)%").font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(pct == 100 ? LiquidGlassTokens.loopsPositive : LiquidGlassTokens.brandAccent)
            }
            if total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(pct == 100 ? LiquidGlassTokens.loopsPositive : LiquidGlassTokens.brandAccent)
                            .frame(width: geo.size.width * CGFloat(pct) / 100)
                    }
                }.frame(height: 4)
            }
            if run.branchGoals.isEmpty {
                Text("主導拆解項目中…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(branches) { item in
                branchRow(item)
            }
        }
        .onChange(of: run.branchGoals.map(\.id)) { _, validIDs in
            branchAccordionState.reconcile(validIDs: validIDs)
        }
    }

    private func branchRow(_ item: PresentedBranch) -> some View {
        let branch = item.branch
        let presentation = item.presentation
        let isExpanded = branchAccordionState.isExpanded(branch.id)
        let status = branchStatusLabel(presentation.visualStatus)
        let tint = branchColor(presentation.visualStatus)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                branchAccordionState.toggle(branch.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(branch.subLabel)
                                .font(.system(size: 11, weight: .bold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let domain = branch.domain {
                                Text(domain.rawValue.uppercased())
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                                    .lineLimit(1)
                            }
                        }
                        Text(branch.objective)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 5)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(status)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if branch.escalated {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                            }
                            if branch.attempt > 1 {
                                Text("\(branch.attempt)/\(branch.maxAttempts)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .contentShape(Rectangle())
                .frame(
                    minHeight: 48,
                    maxHeight: 48,
                    alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(isExpanded ? "收合" : "展開") \(branch.subLabel)")
            .accessibilityValue("\(status) · \(branch.objective)")

            if isExpanded {
                branchDetail(
                    branch,
                    presentation: presentation)
                    .padding(.leading, 25)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 7)
        .background(
            tint.opacity(isExpanded ? 0.07 : 0.035),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func branchDetail(
        _ branch: TatwoPLGBranchGoal,
        presentation: TatwoPLGBranchPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(branch.objective)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let planSlice = branch.planSlice,
               !planSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Plan slice · \(planSlice)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            receiptPresentation(
                presentation.receipt,
                hasReceipt: branch.domainReceipt != nil)
            if let reason = branch.reason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("阻擋：\(reason)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func branchPresentation(
        for branch: TatwoPLGBranchGoal
    ) -> TatwoPLGBranchPresentation {
        TatwoPLGOrchestrator.branchPresentation(
            for: branch,
            in: run)
    }

    @ViewBuilder
    private func receiptPresentation(
        _ presentation: TatwoPLGReceiptPresentation,
        hasReceipt: Bool
    ) -> some View {
        switch presentation {
        case .pass:
            receiptBadge(
                icon: "checkmark.seal.fill",
                text: "Validated receipt · PASS",
                color: LiquidGlassTokens.loopsPositive)
        case .fail:
            receiptBadge(
                icon: "xmark.seal.fill",
                text: "Domain receipt · FAIL",
                color: LiquidGlassTokens.loopsCritical)
        case .blocked:
            receiptBadge(
                icon: "doc.badge.clock",
                text: hasReceipt ? "Domain receipt · BLOCKED" : "等待 Domain receipt",
                color: LiquidGlassTokens.loopsCaution)
        }
    }

    private func receiptBadge(
        icon: String,
        text: String,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(color)
    }

    private func detailText(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockerCard(_ blockerMessage: String) -> some View {
        let descriptor = TatwoOperationalBlockerDescriptor.parse(blockerMessage)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
                Text("PLG 已阻擋")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LiquidGlassTokens.loopsCaution)
            }
            if let descriptor {
                blockerMetric("類型", descriptor.blockerClass)
                blockerMetric("重置時間", descriptor.resetDisplay)
                blockerMetric("重試策略", descriptor.retryDisplay)
            }
            Text(blockerMessage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiquidGlassTokens.loopsCaution)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiquidGlassTokens.loopsCaution.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PLG blocker：\(blockerMessage)")
    }

    private func blockerMetric(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Runtime truth → spine stage；run.phase 不能單獨把規劃投影畫成已執行。
    private var currentStage: Int {
        switch executionTruth.state {
        case .planningPreview, .notDispatched:
            return 0
        case .dispatched, .running, .blocked:
            return 1
        case .receiptGated:
            return run.phase == .passed && executionTruth.runtimeReceiptCount > 0 ? 3 : 2
        }
    }
    private var executionStatusLabel: String {
        switch executionTruth.state {
        case .planningPreview: return "規劃預覽"
        case .notDispatched: return "尚未派發"
        case .dispatched: return "已派發"
        case .running: return "執行中"
        case .receiptGated: return "等待 receipt"
        case .blocked: return "執行受阻"
        }
    }
    private var phaseColor: Color {
        executionTruthColor
    }
    private var executionTruthColor: Color {
        switch executionTruth.state {
        case .planningPreview, .notDispatched: return .secondary
        case .dispatched: return LiquidGlassTokens.loopsCaution
        case .running: return LiquidGlassTokens.brandAccent
        case .receiptGated: return LiquidGlassTokens.loopsCaution
        case .blocked: return LiquidGlassTokens.loopsCritical
        }
    }
    private func branchColor(_ s: TatwoLoopsStatus) -> Color {
        switch s { case .passed: return LiquidGlassTokens.loopsPositive; case .blocked: return LiquidGlassTokens.loopsCaution
        case .rollbackRequired: return LiquidGlassTokens.loopsCritical; case .running: return LiquidGlassTokens.brandAccent; case .planned: return .secondary }
    }
    private func branchStatusLabel(_ s: TatwoLoopsStatus) -> String {
        if !executionTruth.countsAsRuntimeProgress {
            switch s {
            case .blocked: return "[卡住]"
            case .rollbackRequired: return "[需回滾]"
            default: return "[尚未派發]"
            }
        }
        switch s {
        case .planned: return "[規劃預覽]"
        case .running: return "[進行中]"
        case .blocked: return "[卡住]"
        case .passed: return "[已完成]"
        case .rollbackRequired: return "[需回滾]"
        }
    }
}
