import SwiftUI
import AppKit
import Foundation
import QuickLook
import TatwoUltraworkCore

private struct ChatAttachmentStrip: View {
    let attachments: [ChatInlineAttachment]
    let maxWidth: CGFloat
    private let visibleLimit = 6
    @State private var isExpanded = false

    var body: some View {
        if !attachments.isEmpty {
            let visibleAttachments = isExpanded
                ? attachments
                : Array(attachments.prefix(visibleLimit))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(visibleAttachments) { attachment in
                    ChatAttachmentTile(attachment: attachment)
                }
                if attachments.count > visibleLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isExpanded
                                ? "收合附件"
                                : "+\(attachments.count - visibleLimit) 個附件",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }
}

private struct ChatAttachmentTile: View {
    let attachment: ChatInlineAttachment
    @State private var previewURL: URL?

    var body: some View {
        Button {
            guard !attachment.isMissing else { return }
            previewURL = attachment.url
        } label: {
            Group {
                if attachment.isMissing {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.displayName)
                                .font(ChatTypography.transcriptMeta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("附件遺失")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 112)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(attachment.displayName)
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: attachment.isVideo ? "play.rectangle" : "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(attachment.displayName)
                            .font(ChatTypography.transcriptMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .help(attachment.isMissing ? "附件遺失：\(attachment.displayName)" : "點擊預覽 \(attachment.displayName)")
        .quickLookPreview($previewURL)
    }
}

private struct ChatAssistantTranscriptParseTaskID: Hashable {
    let renderIdentity: ChatTranscriptRenderIdentity
    let cacheResetGeneration: UInt64
}

enum ChatAssistantTranscriptParseCoalescing {
    /// Short enough to remain visually immediate, long enough to collapse the
    /// common 20-40 token/second stream into one structured reparse.
    static let incrementalAppendDelay: Duration = .milliseconds(48)

    static func delay(
        utf8Count: Int,
        isIncrementalAppend: Bool
    ) -> Duration? {
        if let existing = TatwoAssistantTranscriptThrottle.delay(
            utf8Count: utf8Count)
        {
            return existing
        }
        return isIncrementalAppend ? incrementalAppendDelay : nil
    }
}

private struct ChatAssistantTranscriptCachedText: View {
    let messageID: String
    let markdown: String
    let textFingerprint: ChatStableContentFingerprint
    let textRevision: UUID
    let displayAppendBaseRevision: UUID?
    let displayAppendSuffix: String?
    let cache: TatwoAssistantTranscriptCache

    @State private var document: TatwoAssistantTranscriptDocument?
    @State private var documentRenderIdentity: ChatTranscriptRenderIdentity?
    @State private var cacheResetGeneration: UInt64 = 0

    private var renderIdentity: ChatTranscriptRenderIdentity {
        ChatTranscriptRenderIdentity(
            messageID: messageID,
            sourceText: markdown,
            textFingerprint: textFingerprint)
    }

    var body: some View {
        ChatStreamingPlainTextFlowText(
            text: markdown,
            sourceFingerprint: textFingerprint,
            sourceRevision: textRevision,
            displayAppendBaseRevision:
                displayAppendBaseRevision,
            displayAppendSuffix: displayAppendSuffix,
            presentationIdentity: ChatTranscriptPresentationIdentity(
                messageID: messageID,
                parserVersion: cache.parserVersion,
                sessionBoundaryGeneration:
                    ChatTranscriptPerformanceCacheCoordinator
                        .currentSessionBoundaryGeneration),
            structuredPayload: structuredPayload,
            copyAllText: markdown)
        .task(id: ChatAssistantTranscriptParseTaskID(
            renderIdentity: renderIdentity,
            cacheResetGeneration: cacheResetGeneration)
        ) {
            let requestedIdentity = renderIdentity
            let requestedMarkdown = markdown
            let requestedKey = TatwoAssistantTranscriptCacheKey(
                messageID: messageID,
                markdown: requestedMarkdown,
                utf8Count: textFingerprint.utf8Count,
                fingerprint: textFingerprint.primary,
                parserVersion: cache.parserVersion)
            let request = cache.beginRequest(for: requestedKey)
            defer {
                cache.finishRequest(
                    request,
                    forMessageID: requestedKey.messageID)
            }
            if let cached = cache.cachedDocument(for: requestedKey) {
                document = cached
                documentRenderIdentity = requestedIdentity
                return
            }

            // Miss: drop any previously parsed document so the new markdown
            // renders as plaintext instead of a stale structured parse.
            if document != nil {
                document = nil
            }
            documentRenderIdentity = nil

            if let delay = ChatAssistantTranscriptParseCoalescing.delay(
                utf8Count: textFingerprint.utf8Count,
                isIncrementalAppend: displayAppendBaseRevision != nil)
            {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard requestedIdentity == renderIdentity else { return }
            guard cache.isCurrent(request, for: requestedKey) else {
                return
            }

            let parsed = await cache.parseDocumentWithMetadata(
                markdown: requestedMarkdown)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard requestedIdentity == renderIdentity else { return }
                guard cache.isCurrent(request, for: requestedKey) else {
                    return
                }
                guard let parsed else { return }
                guard cache.storeIfCurrent(
                    parsed.document,
                    documentResidentBytes: parsed.estimatedResidentBytes,
                    for: requestedKey,
                    request: request)
                else { return }
                document = parsed.document
                documentRenderIdentity = requestedIdentity
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ChatTranscriptPerformanceCacheCoordinator
                    .resetNotification)
        ) { _ in
            document = nil
            documentRenderIdentity = nil
            cacheResetGeneration &+= 1
        }
    }

    private var structuredPayload:
        ChatTranscriptFlowComposer.Payload?
    {
        guard let document,
              documentRenderIdentity == renderIdentity
        else { return nil }
        return ChatTranscriptFlowComposer.cachedDocumentPayload(
            document: document,
            renderIdentity: renderIdentity)
    }
}

struct ChatBubble: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let message: ChatMessage
    let assistantRoute: ChatRouteChoice
    let rowWidth: CGFloat?
    let assistantTranscriptCache: TatwoAssistantTranscriptCache
    let planArtifact: TatwoPlanArtifactV1?
    let isLatestAssistantMessage: Bool
    let initialPlanQuestionFocusClaimed: Bool
    let onInitialPlanQuestionFocusClaimed: () -> Void
    @Binding var planInspectorPresented: Bool

    private var resolvedAssistantRoute: ChatRouteChoice {
        if let modelID = message.modelID { return ChatRouteChoice.resolve(modelID) }
        return assistantRoute
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                ZStack(alignment: .trailing) {
                    Color.clear
                    userMessageBubble
                }
                // Give the row a concrete width before alignment. A flexible
                // frame on the outer Group can leave a Spacer without a real
                // proposal inside LazyVStack. A ZStack is deterministic here:
                // the row owns the readable column width, and the user's
                // compact bubble is pinned to that row's right edge.
                .frame(width: resolvedRowWidth, height: nil, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                HStack(alignment: .top, spacing: 10) {
                    ChatModelAvatar(route: resolvedAssistantRoute)
                        .padding(.top, usesPlainTranscript ? 0 : 1)
                    messageContainer
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                HStack(alignment: .top, spacing: 10) {
                    roleMarker
                        .padding(.top, usesPlainTranscript ? 2 : 1)
                    messageContainer
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        // 空白處拖選/右鍵轉發（見 ChatRowSelectionCatcherView 註解）。
        .background { ChatRowSelectionCatcher() }
        // 2026-08-23 使用者要求「對話要能複製」：右鍵整則複製是保底路徑。
        // （hover 複製鈕做過一版，使用者裁決「不要做這個」，已移除。）
        .contextMenu {
            Button("複製訊息") { copyMessageToPasteboard() }
        }
    }

    static func approvalToolName(in text: String) -> String? {
        TatwoChatMCPApprovalRequest(diagnosticText: text)?.toolName
    }

    static func approvalToolDisplayName(_ tool: String) -> String {
        // mcp__tatwo-app__tatwo_app_switch_tab → switch_tab；內建名原樣。
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.components(separatedBy: "__").last ?? tool
    }

    private var approvalActionTool: String? {
        guard message.role != .user else { return nil }
        guard message.status == "tool approval required"
            || message.text.range(
                of: #"(?i)requested permissions"#,
                options: .regularExpression) != nil
        else { return nil }
        return Self.approvalToolName(in: message.text)
    }

    private var copyableMessageText: String {
        message.transcriptDisplayText.isEmpty
            ? message.text
            : message.transcriptDisplayText
    }

    private func copyMessageToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyableMessageText, forType: .string)
    }

    private var resolvedRowWidth: CGFloat {
        max(rowWidth ?? 560, 320)
    }

    private var userBubbleMaxWidth: CGFloat {
        TatwoChatTranscriptVisualMetrics.userBubbleMaximumWidth(
            rowWidth: resolvedRowWidth)
    }

    private var userBubbleWidth: CGFloat {
        let displayText = message.transcriptDisplayText
        let attachments = message.inlineAttachments
        let lines = displayText.split(separator: "\n", omittingEmptySubsequences: false)
        let longestLine = lines.map(\.count).max() ?? displayText.count
        let estimatedCharacterWidth = displayText.contains(where: { !$0.isASCII })
            ? TatwoChatTranscriptVisualMetrics.estimatedCJKCharacterWidth
            : TatwoChatTranscriptVisualMetrics.estimatedLatinCharacterWidth
        let horizontalInsets = TatwoChatTranscriptVisualMetrics.userBubbleHorizontalPadding * 2
        let estimatedOuterWidth = CGFloat(max(longestLine, 1)) * estimatedCharacterWidth + horizontalInsets
        let attachmentOuterFloor: CGFloat = attachments.isEmpty
            ? TatwoChatTranscriptVisualMetrics.userBubbleMinimumWidth
            : min(userBubbleMaxWidth, 286 + horizontalInsets)
        let outerWidth = min(
            userBubbleMaxWidth,
            max(attachmentOuterFloor, estimatedOuterWidth))
        return max(1, outerWidth - horizontalInsets)
    }

    private var userMessageBubble: some View {
        let displayText = message.transcriptDisplayText
        let attachments = message.inlineAttachments
        return VStack(alignment: .leading, spacing: 8) {
            if !displayText.isEmpty {
                Text(displayText)
                    .font(ChatTypography.transcriptUser)
                    .foregroundStyle(.primary)
                    .lineSpacing(ChatUILayout.transcriptLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !attachments.isEmpty {
                ChatAttachmentStrip(attachments: attachments, maxWidth: userBubbleWidth)
            }
            if displayText.isEmpty && attachments.isEmpty {
                Text("…")
                    .font(ChatTypography.transcriptUser)
                    .foregroundStyle(.secondary)
            }
        }
            .frame(width: userBubbleWidth, alignment: .leading)
            .padding(
                .horizontal,
                TatwoChatTranscriptVisualMetrics.userBubbleHorizontalPadding)
            .padding(
                .vertical,
                TatwoChatTranscriptVisualMetrics.userBubbleVerticalPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: TatwoChatTranscriptVisualMetrics.userBubbleCornerRadius,
                    style: .continuous)
                    .fill(rowBackground)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: TatwoChatTranscriptVisualMetrics.userBubbleCornerRadius,
                    style: .continuous)
                    .strokeBorder(rowStroke, lineWidth: 1)
            }
    }

    private var messageContainer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if shouldShowHeader {
                messageHeader
            }
            messageBody
            if let planArtifact, message.role == .assistant {
                PlanTranscriptSummaryView(
                    artifact: planArtifact,
                    isWriting: false,
                    isSidePanelPresented: $planInspectorPresented)
            }
            // 2026-08-23 工程 B 收尾：權限請求訊息附一鍵放行鈕（寫入
            // per-thread allowlist，下一輪生效；spec「不靜默掛死＋一鍵放行」）。
            // 補完：權限請求常以助理結語轉述（"Claude requested permissions
            // to write to …"），不只 .raw 診斷——依內文比對，不只看 status。
            if let tool = approvalActionTool {
                Button {
                    NotificationCenter.default.post(
                        name: .tatwoChatAllowMCPTool, object: tool)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("允許 \(ChatBubble.approvalToolDisplayName(tool)) 並自動重試")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5.5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .background(
                    LiquidGlassTokens.brandAccent.opacity(0.10),
                    in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        LiquidGlassTokens.brandAccent.opacity(0.32),
                        lineWidth: 1)
                }
                .padding(.top, 2)
                .accessibilityIdentifier("chat-mcp-approve-button")
            }
            if !message.planQuestions.isEmpty {
                PlanClarificationRequestCard(
                    questions: message.planQuestions,
                    isLatestAssistantMessage: isLatestAssistantMessage,
                    initialFocusAlreadyClaimed:
                        initialPlanQuestionFocusClaimed,
                    onInitialFocusClaimed:
                        onInitialPlanQuestionFocusClaimed)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, usesPlainTranscript ? 0 : 10)
        .padding(.vertical, usesPlainTranscript ? 2 : 8)
        .background {
            if usesSurface {
                RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .overlay {
            if usesSurface {
                RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous)
                    .strokeBorder(rowStroke, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var roleMarker: some View {
        if usesPlainTranscript {
            EmptyView()
        } else {
            ZStack {
                Circle()
                    .fill(rowTint.opacity(message.role == .user ? 0.12 : 0.080))
                    .frame(width: 22, height: 22)
                Image(systemName: roleSymbol)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(rowTint)
            }
        }
    }

    private var messageHeader: some View {
        HStack(spacing: 6) {
            if shouldShowRoleLabel {
                Text(roleTitle)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(rowTint)
            }
            if shouldShowStatus, let status = message.status {
                Text(cleanStatus(status))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(rowTint.opacity(0.095), in: Capsule())
                    .foregroundStyle(rowTint)
            }
            if message.eventKind != .message {
                Label(eventLabel, systemImage: eventSymbol)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(eventTint)
            }
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.isCoworkCard {
            CoworkCardBody(message: message)
        } else if let remoteJob = remoteJobPayload {
            remoteJobInlineRow(remoteJob)
        } else if isCompletedActivityOnly {
            compactActivityRow
        } else if usesCompactActivityRow {
            compactActivityRow
        } else if message.eventKind == .thinking {
            compactActivityRow
        } else if message.eventKind == .toolUse {
            compactActivityRow
        } else {
            transcriptTextAndAttachmentsBody
        }
    }

    private func remoteJobInlineRow(
        _ payload: ChatRemoteJobInlinePresentation.Payload
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                CodexActivityInlineText(
                    text: ChatRemoteJobInlineLabel.title(
                        for: payload,
                        narrative: message.text),
                    tint: remoteJobTint(payload),
                    isActive: ChatRemoteJobInlineActivityPolicy.isActive(payload))
                Spacer(minLength: 0)
            }
            if !payload.details.isEmpty {
                DisclosureGroup("詳細資料") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(payload.details.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top, spacing: 6) {
                                Text(key)
                                    .foregroundStyle(.secondary)
                                Text(payload.details[key] ?? "")
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("chat-remote-job-inline-item")
    }

    private var remoteJobPayload: ChatRemoteJobInlinePresentation.Payload? {
        ChatRemoteJobInlinePresentation.payload(from: message.status)
    }

    private func remoteJobTint(
        _ payload: ChatRemoteJobInlinePresentation.Payload
    ) -> Color {
        switch payload.terminalOutcome {
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case nil:
            break
        }
        if payload.runtimeTruth == .unknownAfterRelaunch {
            return .secondary
        }
        switch payload.state {
        case .delivered, .started:
            return LiquidGlassTokens.brandAccent
        case .running:
            return .orange
        case .completed:
            return .green
        case .verified:
            return .mint
        case nil:
            return payload.blocker == nil ? .secondary : .orange
        }
    }

    private var transcriptTextAndAttachmentsBody: some View {
        let snapshot = message.derivedSnapshot(
            using: ChatMessageDerivedValueCache.shared)
        let displayText = snapshot.transcriptDisplayText
        let attachments = snapshot.inlineAttachments
        return VStack(alignment: .leading, spacing: 9) {
            if !displayText.isEmpty {
                transcriptText(displayText, snapshot: snapshot)
                    .font(message.role == .user ? ChatTypography.transcriptUser : ChatTypography.transcriptAssistant)
                    .foregroundStyle(.primary)
                    .lineSpacing(ChatUILayout.transcriptLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: plainTextMaxWidth, alignment: .leading)
            }
            if !attachments.isEmpty {
                ChatAttachmentStrip(attachments: attachments, maxWidth: min(resolvedRowWidth - 52, 640))
            }
        }
    }

    @ViewBuilder
    private func transcriptText(
        _ displayText: String,
        snapshot: ChatMessageDerivedSnapshot
    ) -> some View {
        if message.role == .assistant, message.eventKind == .message {
            ChatAssistantTranscriptCachedText(
                messageID: message.id,
                markdown: displayText,
                textFingerprint:
                    snapshot.transcriptDisplayFingerprint,
                textRevision: message.derivedTextRevision,
                displayAppendBaseRevision:
                    snapshot.displayAppendBaseRevision,
                displayAppendSuffix:
                    snapshot.displayAppendSuffix,
                cache: assistantTranscriptCache)
        } else if message.role == .system {
            // 2026-08-23 系統訊息（權限請求等）也要能反白複製：SwiftUI Text
            // 選取在此結構失效，改走同一條 selectable NSTextView。
            let payload = ChatTranscriptFlowComposer.cachedPlainPayload(
                displayText,
                renderIdentity: ChatTranscriptRenderIdentity(
                    messageID: message.id,
                    sourceText: displayText,
                    textFingerprint:
                        snapshot.transcriptDisplayFingerprint))
            ChatSelectableFlowText(
                attributed: payload.attributed,
                contentFingerprint: payload.fingerprint,
                layoutSemanticIdentity: payload.layoutSemanticIdentity,
                copyAllText: displayText)
        } else {
            // The Text value itself is memoized with the derived snapshot. A
            // SwiftUI body pass therefore reuses the same semantic text payload
            // rather than rebuilding a new Text storage wrapper every time.
            message.transcriptTextView
        }
    }

    private var compactActivityRow: some View {
        HStack(spacing: 0) {
            CodexActivityInlineText(
                text: compactActivityPresentation?.text ?? "正在執行",
                tint: compactActivityTint,
                isActive: compactActivityPresentation?.isActive ?? false)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .animation(
            .easeInOut(duration: 0.18),
            value: compactActivityPresentation?.text)
        .accessibilityIdentifier(
            "chat-inline-work-item-\(compactActivityPresentation?.state.rawValue ?? "unknown")")
        .accessibilityLabel(compactActivityPresentation?.text ?? "正在執行")
    }

    private var plainTextMaxWidth: CGFloat? {
        switch message.role {
        case .user:
            // Codex App style: user turns sit on the right and hug their
            // content instead of stretching into a full-width pale bar. The
            // outer user row still caps the bubble width, so long prompts wrap
            // while short prompts stay compact.
            return nil
        case .system, .assistant:
            return .infinity
        }
    }

    private var usesPlainTranscript: Bool {
        message.role == .assistant
            && message.eventKind == .message
            && !message.isCoworkCard
            && !isFailureStatus
            && !usesCompactActivityRow
            && message.inlineAttachments.isEmpty
    }

    private var usesSurface: Bool {
        if usesCompactActivityRow { return false }
        if message.eventKind == .toolUse { return false }
        return !usesPlainTranscript
    }

    private var shouldShowHeader: Bool {
        if remoteJobPayload != nil { return false }
        if isCompletedActivityOnly { return false }
        if usesCompactActivityRow { return false }
        return shouldShowRoleLabel || shouldShowStatus || message.eventKind != .message
    }

    private var shouldShowStatus: Bool {
        guard let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !status.isEmpty
        else { return false }
        if message.role == .user && ["ticket", "queued"].contains(status) {
            return false
        }
        if message.eventKind == .toolUse && ["tool", "tool-use", "tool use"].contains(status) {
            return false
        }
        return !usesPlainTranscript || ["streaming", "stream", "failed", "failure", "tool-use", "tool"].contains(status)
    }

    private var shouldShowRoleLabel: Bool {
        if message.role == .user { return false }
        return !usesPlainTranscript && (message.eventKind == .message || message.isCoworkCard || isFailureStatus)
    }

    private var roleTitle: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return resolvedAssistantRoute.title
        case .system:
            return "OS"
        }
    }

    private func cleanStatus(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "cli" { return "route" }
        if trimmed.lowercased() == "shell" { return "route" }
        return trimmed
    }

    private var isFailureStatus: Bool {
        if remoteJobPayload != nil { return false }
        guard let status = message.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return status.contains("fail")
            || status.contains("error")
            || status.contains("block")
    }

    private var usesCompactActivityRow: Bool {
        if !message.planQuestions.isEmpty { return false }
        return TatwoChatTranscriptPresentation.usesCompactActivity(
            role: message.role.transcriptPresentationRole,
            eventKind: message.eventKind,
            text: message.text,
            status: message.status)
    }

    private var compactActivityPresentation: ChatInlineWorkPresentation? {
        ChatInlineWorkPresentation.resolve(message)
    }

    private var compactActivityTint: Color {
        let status = parsedActivityStatus.base
        if status == "building" || status == "testing" || status == "checking" || status == "working" || status == "editing" || status == "running-command" || status == "calling-tool" || status == "using-computer" || status.contains("tool") {
            return Color(red: 0.54, green: 0.42, blue: 0.48)
        }
        return Color(red: 0.50, green: 0.46, blue: 0.56)
    }

    private var parsedActivityStatus: (base: String, detail: String?) {
        let raw = message.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let base = parts.first.map { String($0).lowercased() } ?? ""
        let detail = parts.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (base, detail?.isEmpty == false ? detail : nil)
    }

    private var isCompletedActivityOnly: Bool {
        guard message.role == .assistant else { return false }
        guard message.eventKind == .thinking || message.eventKind == .toolUse else { return false }
        let status = parsedActivityStatus.base
        return status == "completed" || status == "done"
    }

    private var roleSymbol: String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .system: "point.3.connected.trianglepath.dotted"
        }
    }

    private var rowTint: Color {
        if message.eventKind != .message { return eventTint }
        return message.role.color
    }

    private var eventSymbol: String {
        switch message.eventKind {
        case .toolUse: "wrench.and.screwdriver"
        case .thinking: "brain.head.profile"
        case .raw: "terminal"
        case .failure: "exclamationmark.triangle"
        case .session: "link"
        case .continuation: "arrow.triangle.2.circlepath"
        case .exit: "checkmark.circle"
        case .message: "text.bubble"
        }
    }

    private var eventLabel: String {
        switch message.eventKind {
        case .toolUse: "tool"
        case .thinking: "thinking"
        case .raw: "raw"
        case .failure: "issue"
        case .session: "session"
        case .continuation: "continuation"
        case .exit: "exit"
        case .message: "message"
        }
    }

    private var eventTint: Color {
        switch message.eventKind {
        case .toolUse: .blue
        case .thinking: Color(red: 0.54, green: 0.55, blue: 0.60)
        case .failure: .red
        case .raw, .session, .continuation, .exit, .message:
            message.role.color
        }
    }

    private var rowBackground: some ShapeStyle {
        let firstOpacity: Double = {
            if message.eventKind == .toolUse { return 0.018 }
            switch message.role {
            case .user: return TatwoChatTranscriptVisualMetrics.userBubbleTintOpacity
            case .system: return 0.022
            case .assistant: return 0.014
            }
        }()
        let secondOpacity: Double = {
            if message.eventKind == .toolUse { return 0.006 }
            if message.role == .user {
                return TatwoChatTranscriptVisualMetrics.userBubbleHighlightOpacity
            }
            return 0.010
        }()
        return LinearGradient(
            colors: [
                rowTint.opacity(firstOpacity),
                Color.white.opacity(secondOpacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var rowStroke: Color {
        if message.eventKind == .toolUse { return rowTint.opacity(0.070) }
        return rowTint.opacity(
            message.role == .user
                ? TatwoChatTranscriptVisualMetrics.userBubbleStrokeOpacity
                : 0.058)
    }
}

private struct CodexActivityInlineText: View {
    let text: String
    let tint: Color
    let isActive: Bool
    var accessibilityIdentifier: String? = nil
    var accessibilityValue: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedOpacity = 0.58

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            content
                .accessibilityLabel(text)
                .accessibilityValue(accessibilityValue ?? "")
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }

    private var content: some View {
        Text(text)
            .font(ChatTypography.transcriptMeta)
            .foregroundStyle(tint.opacity(animatedOpacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .onAppear {
                updateAnimation()
            }
            .onChange(of: isActive) { _, _ in
                updateAnimation()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateAnimation()
            }
    }

    private func updateAnimation() {
        guard isActive, !reduceMotion, !Self.isSnapshotExport else {
            withAnimation(.none) {
                animatedOpacity = 0.58
            }
            return
        }

        animatedOpacity = 0.58
        withAnimation(
            .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: true)
        ) {
            animatedOpacity = 0.76
        }
    }

    private static var isSnapshotExport: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || environment["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
    }
}
