import SwiftUI
import AppKit
import Foundation
import QuickLook
import TatwoUltraworkCore

enum ChatRemoteJobInlineLabel {
    static func title(
        for payload: ChatRemoteJobInlinePresentation.Payload,
        narrative: String
    ) -> String {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return payload.terminalOutcome?.rawValue
            ?? payload.state?.rawValue
            ?? "遠端工作"
    }
}

enum ChatRemoteJobInlineActivityPolicy {
    static func isActive(
        _ payload: ChatRemoteJobInlinePresentation.Payload
    ) -> Bool {
        guard payload.runtimeTruth == .observedThisProcess,
              payload.terminalOutcome == nil
        else {
            return false
        }
        return payload.state == .delivered
            || payload.state == .started
            || payload.state == .running
    }
}

enum ChatInlineWorkState: String, Equatable {
    case queued
    case running
    case tool
    case reconnecting
    case completed
    case failed
    case cancelled
}

struct ChatInlineWorkPresentation: Equatable {
    let state: ChatInlineWorkState
    let text: String
    let isActive: Bool

    static func resolve(_ message: ChatMessage) -> ChatInlineWorkPresentation? {
        guard message.role == .assistant,
              ChatRemoteJobInlinePresentation.payload(from: message.status) == nil
        else { return nil }
        let raw = message.status?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = raw.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        let base = parts.first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? ""
        let detail = parts.dropFirst().first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let spacedReconnectAttempt: String? = {
            guard base.hasPrefix("reconnecting ") else { return nil }
            return String(base.dropFirst("reconnecting ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let normalizedBase = base.hasPrefix("reconnecting ")
            ? "reconnecting"
            : base
        let hasTerminalNarrative =
            !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (message.eventKind == .message || message.eventKind == .failure)
        let isTerminalBase =
            ["completed", "done", "failed", "failure", "error", "blocked",
             "route-blocked", "stopped", "cancelled", "canceled"]
            .contains(normalizedBase)
            || normalizedBase.hasPrefix("failed")
            || normalizedBase.hasPrefix("error")
        if hasTerminalNarrative && isTerminalBase {
            // Final assistant prose remains a normal transcript row. The
            // timeline still derives its terminal summary from the other work
            // events and from turnMessages.
            return nil
        }

        if ["queued", "pending", "waiting"].contains(normalizedBase) {
            return .init(
                state: .queued,
                text: detail.map { "已排入，準備開始 · \($0)" }
                    ?? "已排入，準備開始",
                isActive: true)
        }
        if normalizedBase == "reconnecting" {
            let reconnectDetail = detail
                ?? spacedReconnectAttempt.map { "連線中斷，正在續接 \($0)" }
                ?? "連線中斷，正在續接…"
            return .init(
                state: .reconnecting,
                text: reconnectDetail,
                isActive: true)
        }
        if ["completed", "done"].contains(normalizedBase) {
            return .init(
                state: .completed,
                text: detail.map { "已完成 · \($0)" } ?? "已完成工作",
                isActive: false)
        }
        if ["failed", "failure", "error", "blocked", "route-blocked"].contains(normalizedBase)
            || normalizedBase.hasPrefix("failed")
            || normalizedBase.hasPrefix("error")
        {
            return .init(
                state: .failed,
                text: detail.map { "工作中斷 · \($0)" } ?? "工作中斷",
                isActive: false)
        }
        if ["stopped", "cancelled", "canceled"].contains(normalizedBase) {
            return .init(
                state: .cancelled,
                text: detail.map { "已取消 · \($0)" }
                    ?? "已取消，未採用後續結果",
                isActive: false)
        }

        let suffix = detail.map { " \($0)" } ?? ""
        let text: String
        switch normalizedBase {
        case "building":
            text = "正在建置\(suffix)"
        case "testing":
            text = "正在測試\(suffix)"
        case "checking":
            text = "正在檢查\(suffix)"
        case "searching":
            text = "正在搜尋\(suffix)"
        case "editing":
            text = "正在編輯\(suffix)"
        case "viewing":
            text = "正在檢視\(suffix.isEmpty ? "附件" : suffix)"
        case "browsing":
            text = "正在瀏覽\(suffix)"
        case "running-command":
            text = suffix.isEmpty ? "正在執行命令" : "正在執行\(suffix)"
        case "calling-tool":
            text = suffix.isEmpty ? "正在呼叫工具" : "正在呼叫\(suffix)"
        case "using-computer":
            text = suffix.isEmpty ? "正在操作畫面" : "正在操作\(suffix)"
        case "collaborating":
            text = suffix.isEmpty ? "正在協作" : "正在協作\(suffix)"
        case "waiting-collab":
            text = suffix.isEmpty ? "正在等待協作" : "正在等待\(suffix)"
        case "compacting-context":
            text = "正在壓縮上下文\(suffix)"
        case "inspecting":
            text = "正在檢視\(suffix)"
        case "planning":
            text = "正在規劃\(suffix)"
        case "debugging":
            text = "正在除錯\(suffix)"
        case "working":
            text = "正在執行\(suffix)"
        case "thinking", "streaming", "stream", "":
            guard message.eventKind == .thinking
                    || message.eventKind == .toolUse
                    || message.text.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            text = message.eventKind == .toolUse
                ? (suffix.isEmpty ? "正在執行工具" : "正在執行\(suffix)")
                : (suffix.isEmpty ? "正在思考" : "正在思考 ·\(suffix)")
        default:
            guard message.eventKind == .thinking || message.eventKind == .toolUse
            else { return nil }
            text = message.eventKind == .toolUse
                ? (suffix.isEmpty ? "正在執行工具" : "正在執行\(suffix)")
                : "正在思考"
        }
        return .init(
            state: message.eventKind == .toolUse ? .tool : .running,
            text: text,
            isActive: true)
    }
}

struct ChatInlineWorkTimeline: Identifiable, Equatable {
    let turnID: String
    let messages: [ChatMessage]
    let presentation: ChatInlineWorkPresentation
    let modelID: String?

    private static func resolvedModelID(
        from messages: [ChatMessage]
    ) -> String? {
        let values = Set(messages.compactMap {
            $0.modelID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }.filter { !$0.isEmpty })
        return values.count == 1 ? values.first : nil
    }

    var id: String {
        let base = "chat-inline-work-timeline:\(turnID)"
        return modelID.map { "\(base):\($0)" } ?? base
    }

    static func make(
        turnID: String,
        workMessages: [ChatMessage],
        turnMessages: [ChatMessage]
    ) -> ChatInlineWorkTimeline? {
        let resolved = coalescedWorkMessages(workMessages).compactMap { message in
            ChatInlineWorkPresentation.resolve(message).map {
                (message: message, presentation: $0)
            }
        }
        guard let first = resolved.first else { return nil }
        // Terminal events fence delayed running/tool callbacks. An explicit
        // queued/reconnecting event opens a new retry epoch, after which newer
        // active events are allowed to advance the same assistant turn.
        // Cancellation is authoritative for its epoch: delayed active, tool,
        // or completed callbacks are excluded from the rendered projection.
        var latest = first.presentation
        var acceptedMessages: [ChatMessage] = []
        acceptedMessages.reserveCapacity(workMessages.count)
        var terminalFenceIsClosed = false
        for resolvedItem in resolved {
            let item = resolvedItem.presentation
            if item.state == .queued || item.state == .reconnecting {
                acceptedMessages.append(resolvedItem.message)
                latest = item
                terminalFenceIsClosed = false
            } else if terminalFenceIsClosed {
                guard latest.state != .cancelled, !item.isActive else {
                    continue
                }
                acceptedMessages.append(resolvedItem.message)
                latest = item
            } else {
                acceptedMessages.append(resolvedItem.message)
                latest = item
                terminalFenceIsClosed = !item.isActive
            }
        }
        let finalMessages = turnMessages.filter {
            $0.role == .assistant
                && ChatInlineWorkPresentation.resolve($0) == nil
                && ChatRemoteJobInlinePresentation.payload(from: $0.status) == nil
        }
        let finalStatus = finalMessages.last?.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalStatusParts = finalStatus?.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false) ?? []
        let finalStatusBase = finalStatusParts.first.map {
            String($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } ?? ""
        let finalFailed = finalMessages.last?.eventKind == .failure
            || finalStatusBase.contains("fail")
            || finalStatusBase.contains("error")
            || finalStatusBase.contains("block")
        let finalCancelled = ["stopped", "cancelled", "canceled"]
            .contains(finalStatusBase)
        let hasStableFinal = finalMessages.contains {
            let statusBase = $0.status?
                .split(
                    separator: "|",
                    maxSplits: 1,
                    omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return !$0.text.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                && !["stream", "streaming"].contains(statusBase)
        }
        let terminalState: ChatInlineWorkState?
        if finalFailed {
            terminalState = .failed
        } else if finalCancelled {
            terminalState = .cancelled
        } else if hasStableFinal
            && latest.state != .queued
            && latest.state != .reconnecting
        {
            terminalState = .completed
        } else if !latest.isActive {
            terminalState = latest.state
        } else {
            terminalState = nil
        }
        // Keep details in their original rows; the collapsed timeline is a
        // status summary, not a second copy of tool output or final prose.
        let terminalPresentation = terminalState.map { state in
            let label: String
            switch state {
            case .failed: label = "工作中斷"
            case .cancelled: label = "已取消，未採用後續結果"
            default: label = "已完成工作"
            }
            return ChatInlineWorkPresentation(
                state: state,
                text: "\(label) · \(acceptedMessages.count) 個步驟",
                isActive: false)
        }
        return ChatInlineWorkTimeline(
            turnID: turnID,
            messages: acceptedMessages,
            presentation: terminalPresentation ?? latest,
            modelID: resolvedModelID(from: acceptedMessages))
    }

    /// Providers may emit a start and terminal update with the same stable
    /// item ID. The transcript timeline represents that as one logical step,
    /// preserving its first position while rendering the newest state.
    private static func coalescedWorkMessages(
        _ messages: [ChatMessage]
    ) -> [ChatMessage] {
        var orderedIDs: [String] = []
        var latestByID: [String: ChatMessage] = [:]
        orderedIDs.reserveCapacity(messages.count)
        latestByID.reserveCapacity(messages.count)
        for message in messages {
            if latestByID[message.id] == nil {
                orderedIDs.append(message.id)
            }
            latestByID[message.id] = message
        }
        return orderedIDs.compactMap { latestByID[$0] }
    }
}

enum ChatTranscriptDisplayItem: Identifiable, Equatable {
    case message(ChatMessage)
    case workTimeline(ChatInlineWorkTimeline)

    var id: String {
        switch self {
        case .message(let message):
            "message:\(message.id)"
        case .workTimeline(let timeline):
            timeline.id
        }
    }
}

enum ChatTranscriptDisplayBuilder {
    private struct WorkScope: Hashable {
        let turnID: String
        let modelID: String?
    }

    static func build(_ messages: [ChatMessage]) -> [ChatTranscriptDisplayItem] {
        let localWorkMessages = messages.filter(isLocalInlineWorkMessage)
        let knownModelsByTurn = Dictionary(grouping: localWorkMessages) {
            $0.turnID ?? $0.id
        }.mapValues { turnMessages in
            Set(turnMessages.compactMap(normalizedModelID))
        }
        func scope(for message: ChatMessage) -> WorkScope {
            let turnID = message.turnID ?? message.id
            let explicitModelID = normalizedModelID(message)
            let knownModels = knownModelsByTurn[turnID] ?? []
            return WorkScope(
                turnID: turnID,
                modelID: explicitModelID
                    ?? (knownModels.count == 1 ? knownModels.first : nil))
        }
        let grouped = Dictionary(grouping: localWorkMessages) {
            scope(for: $0)
        }
        let allTurnMessages = Dictionary(grouping: messages) {
            $0.turnID ?? $0.id
        }
        var emittedScopes = Set<WorkScope>()
        var result: [ChatTranscriptDisplayItem] = []
        result.reserveCapacity(messages.count)
        for message in messages {
            guard isLocalInlineWorkMessage(message) else {
                result.append(.message(message))
                continue
            }
            let workScope = scope(for: message)
            guard emittedScopes.insert(workScope).inserted else { continue }
            let turnMessages = (allTurnMessages[workScope.turnID] ?? [message])
                .filter { candidate in
                    guard candidate.role == .assistant else { return true }
                    let candidateModelID = normalizedModelID(candidate)
                    return candidateModelID == workScope.modelID
                        || (candidateModelID == nil
                            && (knownModelsByTurn[workScope.turnID]?.count ?? 0) <= 1)
                }
            guard let timeline = ChatInlineWorkTimeline.make(
                turnID: workScope.turnID,
                workMessages: grouped[workScope] ?? [message],
                turnMessages: turnMessages)
            else {
                result.append(.message(message))
                continue
            }
            result.append(.workTimeline(timeline))
        }
        return result
    }

    private static func isLocalInlineWorkMessage(_ message: ChatMessage) -> Bool {
        message.planQuestions.isEmpty
            && ChatRemoteJobInlinePresentation.payload(from: message.status) == nil
            && ChatInlineWorkPresentation.resolve(message) != nil
    }

    private static func normalizedModelID(_ message: ChatMessage) -> String? {
        let value = message.modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value?.isEmpty == false ? value : nil
    }
}

struct ChatInlineWorkTimelineSummary: Equatable {
    /// Accessibility identity of the capsule (stable across states).
    static let containerLabel = "思考中"
    /// Structural placeholders that carry no information for the reader.
    static let genericPresentationTexts: Set<String> = ["思考中", "已完成工作", "分析進度", "分析完成"]

    let status: String
    let stepCount: Int
    let isActive: Bool
    let state: ChatInlineWorkState

    /// Visible leading label: "思考中" only while work is in flight; a finished
    /// turn reads 已完成／發生錯誤／已取消 (Codex App: "Worked for …").
    var label: String {
        switch state {
        case .completed: "已完成"
        case .failed: "發生錯誤"
        case .cancelled: "已取消"
        case .queued, .running, .tool, .reconnecting: Self.containerLabel
        }
    }

    var compactText: String {
        [status == label ? "" : status, "\(stepCount) 個步驟"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func resolve(
        _ timeline: ChatInlineWorkTimeline
    ) -> ChatInlineWorkTimelineSummary {
        .init(
            status: statusText(for: timeline.presentation.state),
            stepCount: timeline.messages.count,
            isActive: timeline.presentation.isActive,
            state: timeline.presentation.state)
    }

    private static func statusText(
        for state: ChatInlineWorkState
    ) -> String {
        switch state {
        case .queued:
            "等待中"
        case .running:
            "進行中"
        case .tool:
            "使用工具"
        case .reconnecting:
            "重新連線"
        case .completed:
            "已完成"
        case .failed:
            "發生錯誤"
        case .cancelled:
            "已取消"
        }
    }
}

struct ChatInlineWorkDetail: Identifiable, Equatable {
    let id: String
    let stepNumber: Int
    let label: String
    let state: ChatInlineWorkState
}

enum ChatInlineWorkTimelineDetailProjection {
    /// Collapsed timelines take the constant-time path and never construct
    /// per-step rows. This also keeps hidden model reasoning out of the default
    /// accessibility tree.
    static func rows(
        for timeline: ChatInlineWorkTimeline,
        isExpanded: Bool
    ) -> [ChatInlineWorkDetail] {
        guard isExpanded else { return [] }
        return timeline.messages.enumerated().compactMap { index, message in
            guard let item = ChatInlineWorkPresentation.resolve(message) else {
                return nil
            }
            return ChatInlineWorkDetail(
                id: "\(message.id):\(index)",
                stepNumber: index + 1,
                label: detailLabel(for: message, presentation: item),
                state: item.state)
        }
    }

    private static func detailLabel(
        for message: ChatMessage,
        presentation: ChatInlineWorkPresentation
    ) -> String {
        // Never project hidden/full reasoning into the UI. Expansion is for a
        // concise progress ledger, not chain-of-thought disclosure.
        let base = message.status?
            .split(
                separator: "|",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if message.eventKind == .thinking
            && ["", "thinking", "stream", "streaming"].contains(base)
        {
            return presentation.isActive ? "分析進度" : "分析完成"
        }
        // A finished thinking step whose only detail is the structural
        // placeholder ("已完成 · 思考中") reads as nonsense; name the step.
        if presentation.state == .completed,
           ChatInlineWorkTimelineSummary.genericPresentationTexts.contains(
               presentation.text.replacingOccurrences(of: "已完成 · ", with: ""))
        {
            return "分析完成"
        }
        return compact(presentation.text)
    }

    private static func compact(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let limit = 120
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }
}

/// Timeline detail is deliberately concise. Raw thinking text is never passed
/// into this row, even after the user expands the container.
struct ChatInlineWorkDetailRow: View {
    let detail: ChatInlineWorkDetail
    let symbolName: String
    let symbolTint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(symbolTint)
                .frame(width: 9)
            Text(detail.label)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "步驟 \(detail.stepNumber) · \(detail.label)")
        .accessibilityIdentifier("chat-inline-work-detail")
    }
}

enum ChatInlineWorkTimelineExpansionPolicy {
    static func defaultIsExpanded(
        for _: ChatInlineWorkPresentation
    ) -> Bool {
        false
    }
}

struct ChatInlineWorkTimelineView: View {
    let timeline: ChatInlineWorkTimeline
    let assistantRoute: ChatRouteChoice
    let rowWidth: CGFloat

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        timeline: ChatInlineWorkTimeline,
        assistantRoute: ChatRouteChoice,
        rowWidth: CGFloat
    ) {
        self.timeline = timeline
        self.assistantRoute = assistantRoute
        self.rowWidth = rowWidth
        _isExpanded = State(
            initialValue: ChatInlineWorkTimelineExpansionPolicy.defaultIsExpanded(
                for: timeline.presentation))
    }

    var body: some View {
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        VStack(alignment: .center, spacing: 4) {
            Button {
                withAnimation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15)
                ) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    ChatInlineWorkProgressDisc(
                        state: timeline.presentation.state,
                        isActive: summary.isActive,
                        tint: tint(for: timeline.presentation.state))
                    Text(summary.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                    if !summary.compactText.isEmpty {
                        Text(summary.compactText)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    Image(systemName: isExpanded
                        ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Color.primary.opacity(0.035),
                    in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收合工作進度" : "展開工作進度")
            .accessibilityLabel(summary.label)
            .accessibilityValue(
                "\(summary.compactText) · \(isExpanded ? "已展開" : "已收合")")
            .accessibilityIdentifier("chat-inline-work-timeline-summary")

            if isExpanded {
                let details = ChatInlineWorkTimelineDetailProjection.rows(
                    for: timeline,
                    isExpanded: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(details) { detail in
                        ChatInlineWorkDetailRow(
                            detail: detail,
                            symbolName: symbol(for: detail.state),
                            symbolTint: tint(for: detail.state))
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.horizontal, 10)
            }
        }
        .frame(width: max(rowWidth, 320), alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatInlineWorkTimelineSummary.containerLabel)
        .accessibilityValue(
            "\(summary.compactText) · \(isExpanded ? "已展開" : "已收合")")
        .accessibilityIdentifier("chat-inline-work-timeline")
    }

    private var resolvedRoute: ChatRouteChoice {
        timeline.modelID
            .map(ChatRouteChoice.resolve)
            ?? assistantRoute
    }

    private func symbol(for state: ChatInlineWorkState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "circle.dotted"
        case .tool: "wrench.and.screwdriver"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        }
    }

    private func tint(for state: ChatInlineWorkState) -> Color {
        switch state {
        case .queued, .running, .tool:
            Color(red: 0.54, green: 0.42, blue: 0.48)
        case .reconnecting:
            .orange
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}

private struct ChatInlineWorkProgressDisc: View {
    let state: ChatInlineWorkState
    let isActive: Bool
    let tint: Color

    var body: some View {
        Group {
            if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .progressViewStyle(.circular)
                    .tint(tint)
            } else {
                Image(systemName: terminalSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
        .accessibilityIdentifier("chat-inline-work-progress-disc")
    }

    private var terminalSymbol: String {
        switch state {
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        case .cancelled:
            "stop.circle.fill"
        case .queued:
            "clock"
        case .running, .tool:
            "circle.dotted"
        case .reconnecting:
            "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct ChatGitChangedFileSummary: Identifiable, Equatable, Sendable {
    let path: String
    let additions: Int
    let deletions: Int

    var id: String { path }

    var displayName: String {
        let trimmed = path.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }
}

struct ChatChangedFilesSummaryView: View {
    let files: [ChatGitChangedFileSummary]
    let totalFileCount: Int
    let totalAdditions: Int
    let totalDeletions: Int
    let onView: () -> Void
    var onUndo: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("已編輯 \(totalFileCount) 個檔案")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Text("+\(totalAdditions)")
                            .foregroundStyle(Color.green)
                        Text("-\(totalDeletions)")
                            .foregroundStyle(Color.red.opacity(0.86))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                Spacer(minLength: 12)
                Button {
                    onUndo?()
                } label: {
                    HStack(spacing: 5) {
                        Text("復原")
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                .disabled(onUndo == nil)
                .opacity(onUndo == nil ? 0.48 : 1)
                .help(
                    onUndo == nil
                        ? "尚未建立本回合安全復原基線；不會覆蓋工作區原有變更"
                        : "復原本回合的檔案變更")
                .accessibilityIdentifier("chat-changed-files-undo")

                Button("查看") {
                    onView()
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("chat-changed-files-view")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .opacity(0.72)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(files.prefix(8))) { file in
                    HStack(spacing: 14) {
                        Text(file.path)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                        Spacer(minLength: 12)
                        HStack(spacing: 5) {
                            Text("+\(file.additions)")
                                .foregroundStyle(Color.green)
                            Text("-\(file.deletions)")
                                .foregroundStyle(Color.red.opacity(0.86))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(file.path)，新增 \(file.additions) 行，刪除 \(file.deletions) 行")
                }
                if totalFileCount > min(files.count, 8) {
                    Button("另有 \(totalFileCount - min(files.count, 8)) 個檔案，查看全部") {
                        onView()
                    }
                    .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已編輯 \(totalFileCount) 個檔案")
        .accessibilityValue(
            "新增 \(totalAdditions) 行，刪除 \(totalDeletions) 行")
        .accessibilityIdentifier("chat-changed-files-summary")
    }
}
