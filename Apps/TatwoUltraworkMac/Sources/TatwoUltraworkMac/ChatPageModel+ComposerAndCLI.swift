import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    /// App-wide Ultrawork role memory (`UltraworkRoleConfiguration`) is a
    /// *display default for a row that declares no topology of its own*. It is
    /// never authority over an existing row.
    ///
    /// 2026-08-27 runtime-63 live regression (thread `4858FD76…`, goal
    /// `goal-xxl-general-xxl-sol-opus5-luna-grok-exact-24bf426f5d5e`): `/plg`
    /// bound the native-development XXL scenario, which flipped
    /// `collaborationLevel` from `.off`, which fired the view's
    /// "apply stored roles" hook, which wrote the app-wide defaults
    /// (`gpt-5.5` / `sonnet-5`) into the row's `loopsConfig` **after** the XXL
    /// contract had already been issued for the same turn. That mutation was
    /// recorded as `bindingInvalidation reason=loopsConfigChanged` and the
    /// just-issued goal went `cancelled`/`superseded_before_dispatch` in the
    /// same second, so the turn could never establish a dispatch attempt:
    /// `啟動失敗：runner authority 無法建立實體 attempt。
    /// [goal_terminal_before_dispatch status=cancelled
    /// reason=superseded_before_dispatch]`.
    ///
    /// So this seeding is fail-closed. It refuses when the row already carries
    /// its own roles, when its scenario declares a topology (a nil override
    /// means "use the scenario's full declared topology" — see
    /// `loopsConfig(for:mode:)`), when a Work OS contract/goal is bound, and
    /// when a binding invalidation is still open. Explicit picks from the role
    /// picker keep going through `setPrimaryModel`/`setSecondaryModel`.
    @discardableResult
    func applyStoredUltraworkRoleDefaults(
        primaryModelID: String,
        secondaryModelID: String?
    ) -> Bool {
        guard var config = activeLoopsConfig,
              Self.normalizedNonEmpty(config.primaryModelID) == nil,
              Self.normalizedNonEmpty(config.secondaryModelID) == nil,
              activeLoopsModelCandidates.isEmpty,
              let thread = selectedThread,
              Self.normalizedNonEmpty(thread.workOSContractID) == nil,
              Self.normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.bindingInvalidation == nil,
              let primary = Self.normalizedNonEmpty(primaryModelID)
        else { return false }
        config.primaryModelID = primary
        if let secondary = Self.normalizedNonEmpty(secondaryModelID),
           secondary != primary
        {
            config.secondaryModelID = secondary
        }
        updateSelectedThreadLoopsConfig(config, syncSingleModelFromLead: false)
        return true
    }

    func setSecondaryModel(_ modelID: String) {
        guard var config = activeLoopsConfig else { return }
        let previousPrimary = activePrimaryModelID
        let previousSecondary = activeSecondaryModelID
        config.secondaryModelID = modelID
        if modelID == previousPrimary {
            config.primaryModelID = previousSecondary
        } else if config.primaryModelID == nil || config.primaryModelID == modelID {
            config.primaryModelID = activeLoopsModelCandidates.first(where: { $0 != modelID }) ?? previousPrimary
        }
        updateSelectedThreadLoopsConfig(config)
    }

    private func syncCollaborationLeadFromSingleRoute(_ choice: ChatRouteChoice) {
        guard var config = activeLoopsConfig else { return }
        let osModelID = Self.osModelID(forRoute: choice)
        guard config.primaryModelID != osModelID else { return }
        let previousPrimary = config.primaryModelID ?? activePrimaryModelID
        config.primaryModelID = osModelID
        if config.secondaryModelID == osModelID {
            config.secondaryModelID = previousPrimary == osModelID ? activeSecondaryModelID : previousPrimary
        }
        updateSelectedThreadLoopsConfig(config, syncSingleModelFromLead: false)
    }

    func syncSingleModelFromCollaborationLead(_ config: TatwoNativeThreadLoopsConfig) {
        guard let primary = config.primaryModelID,
              let choice = Self.routeChoice(forModelID: primary),
              choice.id != selectedModel
        else { return }
        setSingleModel(choice.id, syncCollaborationLead: false)
    }

    @discardableResult
    func appendDroppedPath(_ path: String) -> Bool {
        let attachmentRoute = currentTurnDispatchRoute()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            flashComposerHint("附件路徑是空的。")
            return false
        }
        let sourceURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            flashComposerHint("附件不存在，未加入。")
            return false
        }

        let storedPath: String
        let displayName: String
        if !isDirectory.boolValue,
           TatwoImageAssetStore.isImageCandidatePath(sourceURL.path) {
            guard attachmentRoute.profile.supportsImageInput else {
                flashComposerHint(
                    "\(attachmentRoute.title) 目前是純文字 route；圖片不會被傳送，請改用支援圖片的 route。")
                return false
            }
            do {
                let asset = try imageAssetStore.ingest(fileURL: sourceURL)
                storedPath = asset.url.path
                displayName = asset.displayName
            } catch {
                flashComposerHint(error.localizedDescription)
                return false
            }
        } else {
            guard isDirectory.boolValue || FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                flashComposerHint("附件無法讀取，未加入。")
                return false
            }
            storedPath = sourceURL.path
            displayName = sourceURL.lastPathComponent.isEmpty ? "附件" : sourceURL.lastPathComponent
        }

        guard attachmentRoute.profile.acceptsAttachmentPath(storedPath) else {
            flashComposerHint(
                "\(attachmentRoute.title) 目前是純文字 route；圖片不會被傳送，請改用支援圖片的 route。")
            return false
        }
        guard !droppedPaths.contains(storedPath) else { return true }
        droppedPaths.append(storedPath)
        droppedPathDisplayNames[storedPath] = displayName
        return true
    }

    @discardableResult
    func appendDroppedImageData(_ data: Data, suggestedName: String = "貼上的圖片.png") -> Bool {
        let attachmentRoute = currentTurnDispatchRoute()
        guard attachmentRoute.profile.supportsImageInput else {
            flashComposerHint(
                "\(attachmentRoute.title) 目前是純文字 route；圖片不會被傳送，請改用支援圖片的 route。")
            return false
        }
        do {
            let asset = try imageAssetStore.ingest(data: data, suggestedName: suggestedName)
            if !droppedPaths.contains(asset.url.path) {
                droppedPaths.append(asset.url.path)
            }
            droppedPathDisplayNames[asset.url.path] = asset.displayName
            return true
        } catch {
            flashComposerHint(error.localizedDescription)
            return false
        }
    }

    func flashComposerHint(_ message: String) {
        // A confirmed Plan can fail inside the Computer Host pre-dispatch
        // gate, then unwind through generic "runner did not start" wrappers in
        // the same MainActor turn. The structured blocker is the actionable,
        // already-redacted authority result; do not let a less-specific
        // follow-up erase it before the user or accessibility surface can read
        // it. Ownership is generation-scoped so an old timer or a later
        // unrelated turn cannot retain or clear the wrong hint.
        let incomingBlockerClass =
            Self.safeStructuredComputerHostBlockerClass(message)
        let incomingIsStructuredBlocker = incomingBlockerClass != nil
        if planConfirmInFlight, incomingIsStructuredBlocker {
            pendingConfirmedPlanComputerHostBlockerHint = message
        }
        if planConfirmInFlight,
           confirmedPlanComputerHostBlockerHintGeneration
                == composerHintClearGeneration,
           Self.isSafeStructuredComputerHostBlocker(composerHint),
           !incomingIsStructuredBlocker
        {
            return
        }
        composerHint = message
        composerHintClearGeneration += 1
        let generation = composerHintClearGeneration
        confirmedPlanComputerHostBlockerHintGeneration =
            planConfirmInFlight && incomingIsStructuredBlocker
                ? generation
                : nil
        if !planConfirmInFlight {
            pendingConfirmedPlanComputerHostBlockerHint = nil
        }
        if incomingIsStructuredBlocker,
           confirmedPlanComputerHostBlockerHintGeneration == generation
        {
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .structuredPublish)
            // The exact allowlisted Computer Host blocker is an actionable
            // authority result, not a transient toast. Keep it visible until
            // the ownership lifecycle clears or replaces it; the legacy
            // seven-second timer made the canonical transcript durable while
            // silently erasing the only actionable composer surface.
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .timerAutoClearSuppressed)
            return
        }
        // 2026-08-21：失敗／阻斷類提示 2.4 秒根本讀不完（使用者需要知道
        // 原因才能行動）——依語意延長；一般資訊提示維持短暫不擾人。
        let duration = Self.composerHintDisplayDuration(for: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.composerHintClearGeneration == generation else { return }
            self.traceConfirmedPlanComputerHostBlockerHintState(
                event: .timerClear)
            if self.confirmedPlanComputerHostBlockerHintGeneration == generation {
                self.confirmedPlanComputerHostBlockerHintGeneration = nil
                if !self.planConfirmInFlight {
                    self.pendingConfirmedPlanComputerHostBlockerHint = nil
                }
            }
            self.composerHint = nil
        }
    }

    func resetConfirmedPlanComputerHostBlockerHint() {
        pendingConfirmedPlanComputerHostBlockerHint = nil
        confirmedPlanDeferredStartBoundaryHandle = nil
        activeConfirmedPlanConfirmationGeneration = nil
        let staleOwnerGeneration =
            confirmedPlanComputerHostBlockerHintGeneration
        confirmedPlanComputerHostBlockerHintGeneration = nil
        guard staleOwnerGeneration == composerHintClearGeneration else {
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .ownershipReset)
            return
        }
        // Invalidate the old timer before the next confirmation publishes its
        // initial status. Otherwise the previous generation can both suppress
        // that status and later clear a hint owned by the retry.
        composerHintClearGeneration += 1
        if Self.isSafeStructuredComputerHostBlocker(composerHint) {
            composerHint = nil
        }
        traceConfirmedPlanComputerHostBlockerHintState(
            event: .ownershipReset)
    }

    func beginConfirmedPlanConfirmationBoundary() {
        resetConfirmedPlanComputerHostBlockerHint()
        confirmedPlanConfirmationGeneration &+= 1
        activeConfirmedPlanConfirmationGeneration =
            confirmedPlanConfirmationGeneration
        planConfirmInFlight = true
    }

    func finishConfirmedPlanConfirmationBoundary() {
        confirmedPlanDeferredStartBoundaryHandle = nil
        activeConfirmedPlanConfirmationGeneration = nil
    }

    func republishConfirmedPlanComputerHostBlockerAtConfirmationBoundaryIfNeeded() {
        guard planConfirmInFlight,
              let blocker = pendingConfirmedPlanComputerHostBlockerHint,
              Self.isSafeStructuredComputerHostBlocker(blocker)
        else { return }
        // Re-arm the visible generation before planConfirmInFlight is released.
        // This makes the final composer surface deterministic while preserving
        // the existing "ordinary hint after confirmation" and next-turn clears.
        flashComposerHint(blocker)
        traceConfirmedPlanComputerHostBlockerHintState(
            event: .boundaryRepublish)
    }

    func awaitConfirmedPlanDeferredStartBoundaryIfNeeded() async {
        guard planConfirmInFlight,
              let confirmationGeneration =
                activeConfirmedPlanConfirmationGeneration,
              let handle =
                confirmedPlanDeferredStartBoundaryHandle,
              handle.confirmationGeneration == confirmationGeneration
        else { return }
        // Take the acceptance-bound handle before suspension. The global
        // pendingRemoteTurnTask may already have been replaced by a queued
        // continuation by the time this await resumes.
        confirmedPlanDeferredStartBoundaryHandle = nil
        await handle.task.value
        let wasCancelled =
            handle.task.isCancelled
            || handle.cancellationFence.isCancelled
        guard planConfirmInFlight,
              activeConfirmedPlanConfirmationGeneration
                == handle.confirmationGeneration
        else {
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .deferredStartBoundaryDiscarded,
                deferredBoundaryHandle: handle,
                deferredBoundaryCancelled: wasCancelled)
            return
        }
        traceConfirmedPlanComputerHostBlockerHintState(
            event: wasCancelled
                ? .deferredStartBoundaryCancelled
                : .deferredStartBoundaryAwaited,
            deferredBoundaryHandle: handle,
            deferredBoundaryCancelled: wasCancelled)
    }

    func clearConfirmedPlanComputerHostBlockerBeforeUnrelatedTurnIfNeeded() {
        guard !planConfirmInFlight,
              let ownerGeneration =
                confirmedPlanComputerHostBlockerHintGeneration
        else { return }
        pendingConfirmedPlanComputerHostBlockerHint = nil
        confirmedPlanComputerHostBlockerHintGeneration = nil
        guard ownerGeneration == composerHintClearGeneration else { return }
        composerHintClearGeneration += 1
        guard Self.isSafeStructuredComputerHostBlocker(composerHint) else {
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .unrelatedTurnClear)
            return
        }
        composerHint = nil
        traceConfirmedPlanComputerHostBlockerHintState(
            event: .unrelatedTurnClear)
    }

    func clearConfirmedPlanComputerHostBlockerAtSessionBoundaryIfNeeded() {
        pendingConfirmedPlanComputerHostBlockerHint = nil
        guard let ownerGeneration =
                confirmedPlanComputerHostBlockerHintGeneration
        else { return }
        confirmedPlanComputerHostBlockerHintGeneration = nil
        guard ownerGeneration == composerHintClearGeneration else {
            traceConfirmedPlanComputerHostBlockerHintState(
                event: .sessionBoundaryClear)
            return
        }
        // Session selection is an ownership boundary. Invalidate the previous
        // generation before the new session can publish a hint, so no callback
        // associated with the old surface can clear the new one.
        composerHintClearGeneration += 1
        if Self.isSafeStructuredComputerHostBlocker(composerHint) {
            composerHint = nil
        }
        traceConfirmedPlanComputerHostBlockerHintState(
            event: .sessionBoundaryClear)
    }

    func traceConfirmedPlanComputerHostBlockerHintState(
        event: ConfirmedPlanComputerHostBlockerHintTraceEntry.Event,
        deferredBoundaryHandle:
            ConfirmedPlanDeferredStartBoundaryHandle? = nil,
        deferredBoundaryCancelled: Bool? = nil
    ) {
        confirmedPlanComputerHostBlockerHintTrace.append(
            ConfirmedPlanComputerHostBlockerHintTraceEntry(
                event: event,
                planConfirmInFlight: planConfirmInFlight,
                pendingBlockerClass:
                    Self.safeStructuredComputerHostBlockerClass(
                        pendingConfirmedPlanComputerHostBlockerHint),
                visibleBlockerClass:
                    Self.safeStructuredComputerHostBlockerClass(composerHint),
                ownerGeneration:
                    confirmedPlanComputerHostBlockerHintGeneration,
                clearGeneration: composerHintClearGeneration,
                confirmationGeneration:
                    activeConfirmedPlanConfirmationGeneration,
                deferredBoundaryIdentity:
                    deferredBoundaryHandle?.identity,
                deferredRemoteTurnGeneration:
                    deferredBoundaryHandle?.remoteTurnGeneration,
                deferredBoundaryCancelled:
                    deferredBoundaryCancelled))
        let maximumTraceCount = 32
        if confirmedPlanComputerHostBlockerHintTrace.count > maximumTraceCount {
            confirmedPlanComputerHostBlockerHintTrace.removeFirst(
                confirmedPlanComputerHostBlockerHintTrace.count
                    - maximumTraceCount)
        }
    }

    private static func isSafeStructuredComputerHostBlocker(
        _ message: String?
    ) -> Bool {
        safeStructuredComputerHostBlockerClass(message) != nil
    }

    private static func safeStructuredComputerHostBlockerClass(
        _ message: String?
    ) -> ConfirmedPlanComputerHostBlockerHintTraceEntry.BlockerClass? {
        guard let message else { return nil }
        if message == confirmedPlanComputerHostBindingBlocker {
            return .bindingFailed
        }
        if message == confirmedPlanComputerHostApprovalBlocker {
            return .approvalFailed
        }
        return nil
    }

    static func composerHintDisplayDuration(for message: String) -> TimeInterval {
        let failureMarkers = [
            "失敗", "未啟動", "未建立", "未送出", "受阻", "隔離",
            "無法", "不一致", "blocked", "已停止", "未能",
        ]
        return failureMarkers.contains(where: message.contains) ? 7.0 : 2.4
    }

    /// ② 建全文搜尋索引：涵蓋所有專案對話 + 獨立對話（包成合成專案），CLI 歷史 v1 先留空。
    func makeChatSearchIndex() -> TatwoChatSearchIndex {
        var projects = document.projects
        let standalone = document.threads
        if !standalone.isEmpty {
            projects.append(
                TatwoNativeChatProject(name: "（獨立對話）", workdir: "", threads: standalone))
        }
        return TatwoChatSearchIndexBuilder.build(
            projects: projects, history: TatwoCLICommandHistoryBook())
    }

    /// ② 搜尋結果跳轉：專案對話走 select(projectID:threadID:)；合成/獨立對話走 selectStandaloneThread。
    func jumpToSearchResult(_ doc: TatwoChatSearchDocument) {
        guard let threadID = doc.threadID else {
            if let pid = doc.projectID, document.projects.contains(where: { $0.id == pid }) {
                selectedProjectID = pid
            }
            return
        }
        if let pid = doc.projectID, document.projects.contains(where: { $0.id == pid }) {
            select(projectID: pid, threadID: threadID)
        } else {
            selectStandaloneThread(threadID)
        }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "加入附件"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        if TatwoModalPanelGate.run({ panel.runModal() }) == .OK {
            for url in panel.urls { appendDroppedPath(url.path) }
        }
    }

    /// #7 ⑤ 剪貼簿/拖入圖片：所有來源都進 App 自有的持久圖片附件庫。
    /// 回傳是否已消費剪貼簿內容；圖片即使被 route 拒絕也要回 true，
    /// 才不會被 NSTextView 降級插成 Finder 絕對路徑。
    @discardableResult
    func pasteClipboardImage(from pasteboard: NSPasteboard = .general) -> Bool {
        // 1. 檔案 URL（從 Finder / 照片 / 影片複製）→ 直接掛路徑（照片與影片都進得來）。
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = urls.filter { $0.isFileURL }
            if !files.isEmpty {
                let includesImage = files.contains {
                    TatwoImageAssetStore.isImageCandidatePath($0.path)
                }
                let added = files.map { appendDroppedPath($0.path) }.contains(true)
                return added || includesImage
            }
        }
        // 2. 原始影像資料（截圖 / 照片 app 直接複製）→ copy-on-ingest。
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            _ = appendDroppedImageData(png, suggestedName: "貼上的圖片.png")
            return true
        }
        return false
    }

    func removeDroppedPath(_ path: String) {
        droppedPaths.removeAll { $0 == path }
        droppedPathDisplayNames.removeValue(forKey: path)
    }

    func exportHandoffPack() {
        if selectedThreadID == nil { newChat() }
        preserveCurrentMessages()
        let envelope = makeHandoffEnvelope()
        let directory = handoffDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            let url = directory.appendingPathComponent(Self.handoffFileName(for: envelope))
            try data.write(to: url, options: [.atomic])
            handoffStatus = "已匯出：\(url.lastPathComponent)"
            appendMessage(ChatMessage(role: .system, text: "交接包已匯出：\(Self.redactedPath(url.path))", status: "handoff export", eventKind: .message))
        } catch {
            handoffStatus = "匯出失敗：\(error.localizedDescription)"
            appendMessage(ChatMessage(role: .system, text: handoffStatus, status: "handoff error", eventKind: .failure))
        }
    }

    func importHandoffPack() {
        if selectedThreadID == nil { newChat() }
        let panel = NSOpenPanel()
        panel.title = "匯入交接包"
        panel.prompt = "匯入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.json]
        let handoffDirectory = handoffDirectoryURL()
        if FileManager.default.fileExists(atPath: handoffDirectory.path) {
            panel.directoryURL = handoffDirectory
        }
        guard TatwoModalPanelGate.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(ChatHandoffEnvelope.self, from: data)
            guard let threadID = selectedThreadID else { return }
            pendingHandoffByThreadID[threadID] = envelope
            handoffStatus = "已載入待併入：\(envelope.summaryLine)"
            appendMessage(ChatMessage(role: .system, text: "交接包已匯入為 pendingHandoff；下次送出會併入隱藏 context 後清除。\n\(envelope.summaryLine)", status: "handoff import", eventKind: .message))
        } catch {
            handoffStatus = "匯入失敗：\(error.localizedDescription)"
            appendMessage(ChatMessage(role: .system, text: handoffStatus, status: "handoff error", eventKind: .failure))
        }
    }

    func clearPendingHandoff() {
        guard let selectedThreadID else { return }
        pendingHandoffByThreadID.removeValue(forKey: selectedThreadID)
        handoffStatus = "交接包已清除"
    }

    private func makeHandoffEnvelope() -> ChatHandoffEnvelope {
        let recentMessages = Array(messages.suffix(20))
        return ChatHandoffEnvelope(
            schemaVersion: 1,
            exportedAt: Date(),
            source: "TatwoUltraworkMac.ChatPage",
            projectName: selectedProjectName,
            threadID: selectedThreadID,
            threadTitle: selectedThread?.title ?? "未命名 thread",
            messageCount: recentMessages.count,
            messages: recentMessages.map { message in
                ChatHandoffMessage(
                    role: message.role.label,
                    text: message.text,
                    status: message.status,
                    modelID: message.modelID,
                    eventKind: message.eventKind)
            },
            loopsConfig: activeLoopsConfig)
    }

    private func handoffDirectoryURL() -> URL {
        currentConversationWorkspaceURL().appendingPathComponent("handoff", isDirectory: true)
    }

    func clearPendingHandoffAfterComposingTurn() {
        guard let selectedThreadID, pendingHandoffByThreadID[selectedThreadID] != nil else { return }
        pendingHandoffByThreadID.removeValue(forKey: selectedThreadID)
        handoffStatus = "pendingHandoff 已併入下一輪隱藏 context 並清除"
    }

    private static func handoffFileName(for envelope: ChatHandoffEnvelope) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let datePart = formatter.string(from: envelope.exportedAt)
        let titlePart = sanitizedHandoffFileComponent(envelope.threadTitle)
        let idPart = envelope.threadID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "no-thread"
        return "tatwo-handoff-\(datePart)-\(idPart)-\(titlePart).json"
    }

    private static func sanitizedHandoffFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "thread" : trimmed).prefix(36))
    }

    func refreshGitBranch() {
        let selectedThreadIDSnapshot = selectedThreadID
        if mode == .chat, isSelectedThreadStandalone {
            gitBranch = "—"
            gitChangedFileCount = 0
            gitChangedFilePreview = []
            gitChangedFiles = []
            gitChangedLineAdditions = 0
            gitChangedLineDeletions = 0
            return
        }
        let workdir = selectedThreadProject?.workdir ?? workspacePath
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let branch = Self.readGitBranch(workdir: workdir)
                let changedFiles = Self.readGitChangedFiles(workdir: workdir)
                let summaries = Self.readGitChangedFileSummary(
                    workdir: workdir,
                    changedPaths: changedFiles)
                let changedFilePreview = changedFiles.prefix(5).map(Self.compactChangedPath)
                return (
                    branch: branch,
                    count: changedFiles.count,
                    preview: changedFilePreview,
                    summaries: summaries,
                    additions: summaries.reduce(0) { $0 + $1.additions },
                    deletions: summaries.reduce(0) { $0 + $1.deletions })
            }.value
            await MainActor.run {
                guard let self, self.selectedThreadID == selectedThreadIDSnapshot else { return }
                if self.mode == .chat, self.isSelectedThreadStandalone {
                    self.gitBranch = "—"
                    self.gitChangedFileCount = 0
                    self.gitChangedFilePreview = []
                    self.gitChangedFiles = []
                    self.gitChangedLineAdditions = 0
                    self.gitChangedLineDeletions = 0
                    return
                }
                self.gitBranch = snapshot.branch
                self.gitChangedFileCount = snapshot.count
                self.gitChangedFilePreview = snapshot.preview
                self.gitChangedFiles = snapshot.summaries
                self.gitChangedLineAdditions = snapshot.additions
                self.gitChangedLineDeletions = snapshot.deletions
            }
        }
    }

    func reloadCLISessions() {
        guard cliRuntimeEnabled else {
            cliSessions = []
            selectedCLISessionID = nil
            return
        }
        let workspacePathSnapshot = workspacePath
        cliSessionReloadTask?.cancel()
        cliSessionReloadTask = Task { [weak self] in
            let snapshots = await Task.detached(priority: .utility) {
                Self.loadCLISessionSnapshots(workspacePath: workspacePathSnapshot)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.cliSessions = snapshots
            if let selectedID = self.selectedCLISessionID, snapshots.contains(where: { $0.id == selectedID }) {
                return
            }
            self.selectedCLISessionID = snapshots.first?.id
        }
    }

    func selectCLISession(_ id: String) {
        selectedCLISessionID = id
        if mode == .cli, cliRuntimeEnabled {
            ensureNativeTerminal(reset: true)
        }
    }

    func selectCLISession(projectID: UUID, sessionID: UUID) {
        // 2026-08-23 修「點 chat 匯入專案/session 後切分頁失效」：舊 single-terminal
        // 殭屍路徑退役——不再覆寫 selectedProjectID/workspacePath（chat 選取狀態被
        // CLI 點擊污染的來源）、不再 ensureNativeTerminal 憑空 spawn 隱形 shell。
        // 點 session＝開/選對應終端分頁卡（與其他入口同一條路）。
        selectedCLISessionID = sessionID.uuidString
        openCLITabForDocumentSession(projectID: projectID, sessionID: sessionID)
    }

    /// 文件 session → 終端分頁：已有同名同 cwd 分頁就選取，否則開新分頁。
    func openCLITabForDocumentSession(projectID: UUID, sessionID: UUID) {
        guard cliRuntimeEnabled,
              let project = document.projects.first(where: { $0.id == projectID }),
              let session = project.sessions.first(where: { $0.id == sessionID }) else { return }
        let workdir = session.cwd.isEmpty ? project.workdir : session.cwd
        if let existing = cliSessionBook.sessions.first(where: {
            $0.title == session.name && $0.workdir == workdir
        }) {
            selectCLITab(existing.id)
            return
        }
        let engine = TatwoNativeCLISessionBook.Engine(rawValue: session.engine.rawValue) ?? .generic
        let id = cliSessionBook.open(engine: engine, title: session.name, workdir: workdir)
        if let bookSession = cliSessionBook.sessions.first(where: { $0.id == id }) {
            spawnCLITerminal(for: bookSession)
        }
    }

    func createCLISession(in projectID: UUID, engine: TatwoNativeCLIEngine) {
        guard allowColdStartDocumentMutation() else { return }
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = document.projects[projectIndex]
        let sameEngineCount = project.sessions.filter { $0.engine == engine }.count
        let sequenceSuffix = sameEngineCount == 0 ? "" : " \(sameEngineCount + 1)"
        let session = TatwoNativeCLISession(
            name: "新 \(engine.displayName) session\(sequenceSuffix)",
            engine: engine,
            cwd: project.workdir)
        document.projects[projectIndex].sessions.insert(session, at: 0)
        document.projects[projectIndex].isExpanded = true
        publishDocumentChangeAndPersist()
        selectCLISession(projectID: projectID, sessionID: session.id)
    }

    /// 跨面接力：把一條 chat thread 接到同專案的 CLI session（在專案工作目錄開真終端續作）。
    /// 承載的 context = thread 標題（session 命名）+ 同 cwd；深層 context handoff 走既有 handoff pack。
    func handoffThreadToCLISession(project: TatwoNativeChatProject?, thread: TatwoNativeChatThread, engine: TatwoNativeCLIEngine = .codex) {
        guard allowColdStartDocumentMutation() else { return }
        guard let project,
              let projectIndex = document.projects.firstIndex(where: { $0.id == project.id })
        else { return }
        let seed = "從對話：\(thread.title)"
        // 攜帶真 context：來源 thread 關聯 + 摘要(標題+近況)，供終端 seed 顯示與續作。
        let preview = thread.lastPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextSummary = preview.isEmpty
            ? "來源對話串：\(thread.title)"
            : "來源對話串：\(thread.title)\n近況：\(preview)"
        let session = TatwoNativeCLISession(
            name: String(seed.prefix(48)),
            engine: engine,
            cwd: document.projects[projectIndex].workdir,
            sourceThreadID: thread.id,
            seededContext: contextSummary)
        document.projects[projectIndex].sessions.insert(session, at: 0)
        document.projects[projectIndex].isExpanded = true
        publishDocumentChangeAndPersist()
        mode = .cli
        selectCLISession(projectID: project.id, sessionID: session.id)
    }

    /// 反向接力：把一條 CLI session 送回 Chat（在同專案建一條 thread 帶入 session 摘要），回到 Chat 分頁閱讀/續作。
    func handoffCLISessionToThread(project: TatwoNativeChatProject, session: TatwoNativeCLISession) {
        guard allowColdStartDocumentMutation() else { return }
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == project.id }) else { return }
        let thread = TatwoNativeChatThread(
            title: String("從 CLI：\(session.name)".prefix(48)),
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            lastPreview: "引擎 \(session.engine.displayName) · \(session.cwd)")
        document.projects[projectIndex].threads.insert(thread, at: 0)
        document.projects[projectIndex].isExpanded = true
        publishDocumentChangeAndPersist()
        mode = .chat
        select(projectID: project.id, threadID: thread.id)
    }

    func ensureNativeTerminal(reset: Bool = false) {
        guard cliRuntimeEnabled else {
            nativeTerminalStatus = "paused"
            terminalLines = []
            return
        }
        let selection = selectedCLISession
        let selectionID = selection?.id ?? "empty-cli-state"
        guard reset || nativeTerminal == nil || nativeTerminalSelectionID != selectionID else { return }

        nativeTerminal?.terminate()
        nativeTerminalSelectionID = selectionID
        let selectedSessionWorkdir = selectedNativeCLISession?.cwd
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = URL(
            fileURLWithPath:
                selectedSessionWorkdir?.isEmpty == false
                ? selectedSessionWorkdir!
                : currentConversationWorkspaceURL().path)
        // engine 控制 runtime：帶 engine env + engine 專屬 prompt；引擎 CLI 由 seed 指引使用者啟動
        // （不自動 spawn 需認證/互動的 codex/claude/grok，避免掛住或誤觸費用）。
        let engineTag = selectedNativeCLISession?.engine.rawValue ?? "sandbox"
        let launch = TatwoNativeTerminalLaunch(
            executable: "/bin/zsh",
            arguments: ["-l", "-i"],
            workingDirectory: cwd,
            environment: [
                "TERM": "xterm-256color",
                "CLICOLOR": "1",
                "TATWO_CLI_ENGINE": engineTag,
                "PS1": "%F{cyan}tatwo:\(engineTag)%f %1~ %# "
            ])
        let seed = Self.terminalSeed(selection: selection, workdir: cwd.path, engine: selectedNativeCLISession?.engine)
        nativeTerminalStatus = "starting"
        terminalLines = TatwoTerminalANSIParser.parse(seed).lines
        let session = TatwoNativeTerminalSession(
            launch: launch,
            maxLineCount: 1_500,
            throttleInterval: 0.06,
            onUpdate: { [weak self] lines in
                Task { @MainActor [weak self] in
                    self?.terminalLines = lines
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.nativeTerminalStatus = status.displayText
                }
            })
        nativeTerminal = session
        session.start(seedText: seed)
    }

    func sendNativeTerminalInput() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        prompt = ""
        ensureNativeTerminal()
        nativeTerminal?.sendLine(input, echo: true)
        lastCommand = "stdin → native terminal: \(Self.redactedPath(input))"
    }

    // MARK: - CLI 多工分頁（每分頁一個並存 PTY）

    var cliTabs: [TatwoNativeCLISessionBook.Session] { cliSessionBook.sessions }
    var activeCLITabID: UUID? { cliSessionBook.activeSessionID }
    var activeCLITabLines: [TatwoTerminalLine] {
        guard let id = cliSessionBook.activeSessionID else { return [] }
        return cliTabBuffers[id] ?? []
    }
    var activeCLITabStatus: String {
        guard let id = cliSessionBook.activeSessionID else { return "idle" }
        return cliTabStatuses[id] ?? "idle"
    }
    /// active 分頁的 PTY session；PTY 後端才有值，pipe fallback 下為 nil。
    /// 有值時窗格改用 `NativeTerminalPTYView`（按鍵級輸入 + resize→TIOCSWINSZ），
    /// nil 時退回原本的唯讀 ScrollView。
    var activeCLITabPTYSession: TatwoNativePTYTerminalSession? {
        guard let id = cliSessionBook.activeSessionID else { return nil }
        return cliTerminals[id]?.ptySession
    }

    // 2026-08-23 CLI 分離小視窗/專注模式：任意分頁的 buffer 與 PTY 取用。
    func cliTabLines(for id: UUID) -> [TatwoTerminalLine] {
        cliTabBuffers[id] ?? []
    }

    func cliTabPTYSession(for id: UUID) -> TatwoNativePTYTerminalSession? {
        cliTerminals[id]?.ptySession
    }

    /// 開新分頁：book.open + spawn 一個並存終端（不殺其他分頁）。可指定 workdir（chat→cli 閉環用）。
    func openCLITab(engine: TatwoNativeCLISessionBook.Engine, workdir: String? = nil) {
        guard cliRuntimeEnabled else { return }
        let n = cliSessionBook.sessions.filter { $0.engine == engine }.count + 1
        let title = "\(Self.cliEngineLabel(engine)) \(n)"
        let cwd = workdir ?? currentConversationWorkspaceURL().path
        let id = cliSessionBook.open(engine: engine, title: title, workdir: cwd)
        if let session = cliSessionBook.sessions.first(where: { $0.id == id }) {
            spawnCLITerminal(for: session)
        }
    }

    /// chat→cli 閉環：把當前討論串的專案工作目錄，在 CLI 開一個新 Shell 分頁並切到 CLI 分頁。
    var canOpenThreadInCLI: Bool { cliRuntimeEnabled && selectedThreadID != nil }
    func openThreadProjectInCLI() {
        openCLITab(
            engine: .generic,
            workdir: currentConversationWorkspaceURL().path)
        mode = .cli
    }

    /// 顯式收掉所有 CLI 分頁的終端。回傳收掉的數量。
    ///
    /// 只給「容器要收了」的路徑用（見 `shutdownForContainerClose`），
    /// 不掛在 `stop()` 上——composer 停止鍵按的是「停這輪回應」，
    /// 不該連使用者開著的 shell 一起殺掉。
    @discardableResult
    func terminateAllCLITerminals() -> Int {
        let count = TatwoCLITerminalTeardown.terminateAll(Array(cliTerminals.values))
        cliTerminals.removeAll()
        cliTerminalEngines.removeAll()
        return count
    }

    /// 視窗容器關閉時的收尾（使用者已在 LoopsInterruptGate 確認過，這裡不再問一次）。
    ///
    /// `stop()` 只收 chat runner；CLI 分頁的 PTY／pipe shell 要在這裡顯式收，
    /// 否則就退化成靠 dealloc 收屍＝靜默遺失。
    /// `terminateAllCLITerminals` 收完即清空字典，重複呼叫是 no-op（不雙重執行）。
    func shutdownForContainerClose() {
        flushCurrentComposerDraft()
        stop()
        cancelAllRunnerStateReconcilers()
        terminateAllCLITerminals()
    }

    /// 關分頁：PTY／process 若還在跑，先走既有 terminate API 收掉，再從 book 移除。不詢問。
    /// 必須整本 assign 回 @Published，mutating close 走 wrapper 時 didSet／畫面不一定會跟。
    func closeCLITab(_ id: UUID) {
        terminateCLITerminal(id)
        var book = cliSessionBook
        guard book.close(id) else { return }
        cliSessionBook = book
    }

    func selectCLITab(_ id: UUID) { cliSessionBook.select(id) }

    /// 是否可一鍵啟動引擎 CLI（codex/claude/grok 可；generic shell 無）。
    var activeCLITabCanLaunch: Bool {
        guard let e = cliSessionBook.activeSession?.engine else { return false }
        return e != .generic
    }
    /// 一鍵送引擎啟動命令到 active 分頁（不用手打）。
    func launchEngineInActiveTab() {
        guard let session = cliSessionBook.activeSession, let id = cliSessionBook.activeSessionID else { return }
        let cmd: String
        switch session.engine {
        case .codex: cmd = "codex"
        case .claude: cmd = "claude"
        case .grok: cmd = "grok"
        case .generic: return
        }
        cliTerminals[id]?.sendLine(cmd)
        lastCommand = "launch → cli tab: \(cmd)"
    }

    /// 送輸入到「當前 active 分頁」的終端（不影響其他並存分頁）。
    func sendActiveCLITabInput() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let id = cliSessionBook.activeSessionID else { return }
        prompt = ""
        cliTerminals[id]?.sendLine(input)
        lastCommand = "stdin → cli tab: \(Self.redactedPath(input))"
    }

    /// 進 CLI 分頁時準備：有持久化分頁→對帳補齊終端。全空不自動再開——空畫面與左列 ＋ 是入口。
    func prepareCLITabs() {
        guard cliRuntimeEnabled else { return }
        guard !cliSessionBook.sessions.isEmpty || !cliTerminals.isEmpty else { return }
        reconcileCLITerminals()
    }

    /// 用 sol 的純邏輯對帳器把 live 終端對齊 book（重開後 book 有分頁但無終端→補 spawn；engine 變→respawn；多餘→terminate）。
    func reconcileCLITerminals() {
        let live = cliTerminals.keys.map { id in
            TatwoNativeTerminalPoolReconciler.LiveTerminal(
                id: id, engine: cliTerminalEngines[id] ?? .generic)
        }
        let plan = TatwoNativeTerminalPoolReconciler.reconcile(book: cliSessionBook, liveTerminals: live)
        for id in plan.toTerminate { terminateCLITerminal(id) }
        for req in plan.toRespawn {
            terminateCLITerminal(req.id)
            if let s = cliSessionBook.sessions.first(where: { $0.id == req.id }) { spawnCLITerminal(for: s) }
        }
        for req in plan.toSpawn {
            if let s = cliSessionBook.sessions.first(where: { $0.id == req.id }) { spawnCLITerminal(for: s) }
        }
    }

    private func terminateCLITerminal(_ id: UUID) {
        cliTerminals[id]?.terminate()
        cliTerminals[id] = nil
        cliTerminalEngines[id] = nil
        cliTabBuffers[id] = nil
        cliTabStatuses[id] = nil
    }

    func persistCLISessionBook() {
        guard let data = try? JSONEncoder().encode(cliSessionBook) else { return }
        UserDefaults.standard.set(data, forKey: Self.cliSessionBookDefaultsKey)
    }

    func loadPersistedCLISessionBook() {
        guard cliSessionBook.sessions.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.cliSessionBookDefaultsKey),
              let book = try? JSONDecoder().decode(TatwoNativeCLISessionBook.self, from: data),
              !book.sessions.isEmpty
        else { return }
        cliSessionBook = book
    }

    private func spawnCLITerminal(for session: TatwoNativeCLISessionBook.Session) {
        let path = (session.workdir?.isEmpty == false)
            ? session.workdir!
            : currentConversationWorkspaceURL().path
        let cwd = URL(fileURLWithPath: path)
        let engineTag = session.engine.rawValue
        let launch = TatwoNativeTerminalLaunch(
            executable: "/bin/zsh",
            arguments: ["-l", "-i"],
            workingDirectory: cwd,
            environment: [
                "TERM": "xterm-256color",
                "CLICOLOR": "1",
                "TATWO_CLI_ENGINE": engineTag,
                "PS1": "%F{cyan}tatwo:\(engineTag)%f %1~ %# "
            ])
        let id = session.id
        let seed = Self.cliTabSeed(engine: session.engine, workdir: cwd.path)
        cliTabBuffers[id] = TatwoTerminalANSIParser.parse(seed).lines
        cliTabStatuses[id] = "starting"
        cliTerminalEngines[id] = session.engine

        // 匯出 fixture：分頁看得見（標題列＋浮動光可入鏡），但不 forkpty。
        // 快照匯出必須是 hermetic 的，不該在使用者機器上留下 zsh 子程序。
        if exportCLITabFixtureEnabled {
            cliTabBuffers[id] = TatwoTerminalANSIParser.parse(
                seed + Self.exportCLITabFixtureTranscript).lines
            cliTabStatuses[id] = "running"
            return
        }
        let term = TatwoCLITerminalHandle.make(
            launch: launch,
            maxLineCount: 1_500,
            throttleInterval: 0.06,
            onUpdate: { [weak self] lines in
                Task { @MainActor [weak self] in self?.cliTabBuffers[id] = lines }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in self?.cliTabStatuses[id] = status.displayText }
            })
        cliTerminals[id] = term
        term.start(seedText: seed)
    }

    static func cliEngineLabel(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .generic: return "Shell"
        }
    }
}
