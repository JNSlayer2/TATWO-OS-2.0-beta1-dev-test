import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeSessionTree {
  public static func transcriptSHA256(_ messages: [TatwoNativeChatStoredMessage]) -> String {
    let material = messages.map {
      [
        $0.id,
        $0.role,
        $0.text,
        $0.status ?? "",
        $0.modelID ?? "",
        $0.eventKind.rawValue,
        String($0.createdAt.timeIntervalSinceReferenceDate),
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
    return TatwoArtifactReviewHasher.sha256(material)
  }

  public static func forkDiscussion(
    from thread: TatwoNativeChatThread,
    title: String = "新討論"
  ) -> TatwoNativeDiscussion {
    let parent = TatwoNativeChatSessionReference(kind: .thread, id: thread.id)
    let parentMessages = thread.messages ?? []
    let checkpoint = TatwoNativeSessionForkCheckpoint(
      parentSession: parent,
      parentMessageCount: parentMessages.count,
      parentTranscriptSHA256: transcriptSHA256(parentMessages),
      parentMessages: parentMessages)
    return TatwoNativeDiscussion(
      title: title,
      inheritedSnapshot: thread.lastPreview,
      parentSession: parent,
      forkCheckpoint: checkpoint)
  }

  public static func migratedDiscussion(
    _ discussion: TatwoNativeDiscussion,
    parentThreadID: UUID,
    parentMessages: [TatwoNativeChatStoredMessage]
  ) -> TatwoNativeDiscussion {
    var migrated = discussion
    let parent = TatwoNativeChatSessionReference(kind: .thread, id: parentThreadID)
    if migrated.parentSession == nil {
      migrated.parentSession = parent
    }
    if migrated.forkCheckpoint == nil {
      migrated.forkCheckpoint = TatwoNativeSessionForkCheckpoint(
        parentSession: parent,
        parentMessageCount: parentMessages.count,
        parentTranscriptSHA256: transcriptSHA256(parentMessages),
        parentMessages: parentMessages)
    }
    return migrated
  }

  public static func validates(
    _ checkpoint: TatwoNativeSessionForkCheckpoint
  ) -> Bool {
    checkpoint.parentMessageCount == checkpoint.parentMessages.count
      && checkpoint.parentTranscriptSHA256 == transcriptSHA256(checkpoint.parentMessages)
  }

  public static func checkpoint(
    for discussion: TatwoNativeDiscussion
  ) -> TatwoNativeDiscussionCheckpointReceipt {
    let messages = discussion.messages
    let digest = transcriptSHA256(messages)
    let latest = messages.last(where: {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "無可見訊息"
    let summary = "checkpoint \(digest.prefix(12)) · \(messages.count) messages · \(String(latest.prefix(160)))"
    return TatwoNativeDiscussionCheckpointReceipt(
      discussionID: discussion.id,
      transcriptSHA256: digest,
      messageCount: messages.count,
      snapshotMessages: messages,
      summary: summary)
  }

  public static func validates(
    _ receipt: TatwoNativeDiscussionCheckpointReceipt
  ) -> Bool {
    receipt.messageCount == receipt.snapshotMessages.count
      && receipt.transcriptSHA256 == transcriptSHA256(receipt.snapshotMessages)
  }

  public static func mergeReceipt(
    for discussion: TatwoNativeDiscussion,
    checkpoint: TatwoNativeDiscussionCheckpointReceipt,
    targetThreadID: UUID
  ) -> TatwoNativeDiscussionMergeReceipt? {
    let target = TatwoNativeChatSessionReference(
      kind: .thread,
      id: targetThreadID)
    guard
      let fork = discussion.forkCheckpoint,
      discussion.parentSession == target,
      fork.parentSession == target,
      validates(fork),
      validates(checkpoint),
      checkpoint.discussionID == discussion.id
    else {
      return nil
    }
    return TatwoNativeDiscussionMergeReceipt(
      sourceSession: TatwoNativeChatSessionReference(kind: .discussion, id: discussion.id),
      targetSession: target,
      forkCheckpointID: fork.id,
      sourceCheckpointID: checkpoint.id,
      sourceTranscriptSHA256: checkpoint.transcriptSHA256,
      summary: checkpoint.summary)
  }

  public static func upserting(
    _ handle: TatwoNativeAdapterSessionHandle,
    into handles: [TatwoNativeAdapterSessionHandle]
  ) -> [TatwoNativeAdapterSessionHandle] {
    var result = handles
    if let index = result.firstIndex(where: {
      $0.adapterID == handle.adapterID
        && compatibleSessionModelID($0.modelID) == compatibleSessionModelID(handle.modelID)
    }) {
      result[index] = handle
    } else {
      result.append(handle)
    }
    return result
  }

  public static func providerSessionID(
    adapterID: String,
    modelID: String,
    handles: [TatwoNativeAdapterSessionHandle]
  ) -> String? {
    let exact = handles.last {
      $0.adapterID == adapterID
        && compatibleSessionModelID($0.modelID) == compatibleSessionModelID(modelID)
        && !$0.providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let exact { return exact.providerSessionID }
    return handles.last {
      $0.adapterID == adapterID
        && $0.modelID == nil
        && !$0.providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.providerSessionID
  }

  public static func upsertingGatewayConversationHandle(
    _ handle: TatwoGatewayConversationHandleV1,
    into handles: [TatwoGatewayConversationHandleV1]
  ) -> [TatwoGatewayConversationHandleV1] {
    guard handle.isValid else { return handles }
    var result = handles.filter(\.isValid)
    if let index = result.firstIndex(where: {
      $0.threadID == handle.threadID
        && $0.discussionID == handle.discussionID
        && $0.runtimeAdapterID == handle.runtimeAdapterID
        && compatibleSessionModelID($0.canonicalModelID)
          == compatibleSessionModelID(handle.canonicalModelID)
    }) {
      result[index] = handle
    } else {
      result.append(handle)
    }
    return result
  }

  public static func gatewayConversationHandle(
    threadID: String,
    discussionID: String?,
    adapterID: String,
    modelID: String,
    handles: [TatwoGatewayConversationHandleV1]
  ) -> TatwoGatewayConversationHandleV1? {
    handles.last {
      $0.isValid
        && $0.threadID == threadID
        && $0.discussionID == discussionID
        && $0.runtimeAdapterID == adapterID
        && compatibleSessionModelID($0.canonicalModelID)
          == compatibleSessionModelID(modelID)
    }
  }

  /// Applies one continuation receipt to its immutable Chat scope.
  ///
  /// This deliberately does not consult the currently selected UI row. The
  /// receipt and request carry the exact thread/discussion/model scope, and
  /// the previous opaque handle is used as a compare-and-swap precondition so
  /// a late terminal event cannot overwrite a newer conversation pointer.
  @discardableResult
  public static func promoteGatewayConversationHandle(
    request: TatwoGatewayContinuationRequestV1,
    receipt: TatwoGatewayContinuationReceiptV1,
    in document: inout TatwoNativeChatStoreDocument,
    now: Date = Date()
  ) -> Bool {
    guard
      let promoted = receipt.promotableHandle(matching: request),
      let threadUUID = UUID(uuidString: request.threadID)
    else {
      return false
    }
    let discussionUUID: UUID?
    if let discussionID = request.discussionID {
      guard let parsed = UUID(uuidString: discussionID) else {
        return false
      }
      discussionUUID = parsed
    } else {
      discussionUUID = nil
    }

    func apply(to thread: inout TatwoNativeChatThread) -> Bool {
      guard thread.id == threadUUID else { return false }
      if let discussionUUID {
        guard
          let index = thread.discussions.firstIndex(where: {
            $0.id == discussionUUID
          })
        else {
          return false
        }
        let current = gatewayConversationHandle(
          threadID: request.threadID,
          discussionID: request.discussionID,
          adapterID: request.runtimeAdapterID,
          modelID: request.canonicalModelID,
          handles: thread.discussions[index].gatewayConversationHandles)
        guard continuationPreconditionMatches(
          current: current,
          request: request)
        else {
          return false
        }
        thread.discussions[index].gatewayConversationHandles =
          upsertingGatewayConversationHandle(
            promoted,
            into: thread.discussions[index].gatewayConversationHandles)
      } else {
        let current = gatewayConversationHandle(
          threadID: request.threadID,
          discussionID: nil,
          adapterID: request.runtimeAdapterID,
          modelID: request.canonicalModelID,
          handles: thread.gatewayConversationHandles)
        guard continuationPreconditionMatches(
          current: current,
          request: request)
        else {
          return false
        }
        thread.gatewayConversationHandles =
          upsertingGatewayConversationHandle(
            promoted,
            into: thread.gatewayConversationHandles)
      }
      thread.updatedAt = now
      return true
    }

    if let index = document.threads.firstIndex(where: {
      $0.id == threadUUID
    }) {
      return apply(to: &document.threads[index])
    }
    for projectIndex in document.projects.indices {
      guard
        let threadIndex = document.projects[projectIndex].threads
          .firstIndex(where: { $0.id == threadUUID })
      else {
        continue
      }
      return apply(
        to: &document.projects[projectIndex].threads[threadIndex])
    }
    return false
  }

  /// Drops a stale resume pointer after the gateway rejects it. Compare-and-swap
  /// on the opaque handle so a newer receipt cannot be erased by a late failure.
  @discardableResult
  public static func clearGatewayConversationHandle(
    matching request: TatwoGatewayContinuationRequestV1,
    in document: inout TatwoNativeChatStoreDocument,
    now: Date = Date()
  ) -> Bool {
    guard request.previousResponseHandle != nil,
      let threadUUID = UUID(uuidString: request.threadID)
    else {
      return false
    }
    let discussionUUID: UUID?
    if let discussionID = request.discussionID {
      guard let parsed = UUID(uuidString: discussionID) else {
        return false
      }
      discussionUUID = parsed
    } else {
      discussionUUID = nil
    }

    func removeMatchingHandle(
      from handles: inout [TatwoGatewayConversationHandleV1]
    ) -> Bool {
      let current = gatewayConversationHandle(
        threadID: request.threadID,
        discussionID: request.discussionID,
        adapterID: request.runtimeAdapterID,
        modelID: request.canonicalModelID,
        handles: handles)
      guard continuationPreconditionMatches(
        current: current,
        request: request)
      else {
        return false
      }
      let before = handles.count
      handles.removeAll { handle in
        handle.threadID == request.threadID
          && handle.discussionID == request.discussionID
          && handle.runtimeAdapterID == request.runtimeAdapterID
          && compatibleSessionModelID(handle.canonicalModelID)
            == compatibleSessionModelID(request.canonicalModelID)
          && handle.opaqueResponseHandle == request.previousResponseHandle
      }
      return handles.count < before
    }

    func apply(to thread: inout TatwoNativeChatThread) -> Bool {
      guard thread.id == threadUUID else { return false }
      let cleared: Bool
      if let discussionUUID {
        guard
          let index = thread.discussions.firstIndex(where: {
            $0.id == discussionUUID
          })
        else {
          return false
        }
        cleared = removeMatchingHandle(
          from: &thread.discussions[index].gatewayConversationHandles)
      } else {
        cleared = removeMatchingHandle(
          from: &thread.gatewayConversationHandles)
      }
      if cleared {
        thread.updatedAt = now
      }
      return cleared
    }

    if let index = document.threads.firstIndex(where: {
      $0.id == threadUUID
    }) {
      return apply(to: &document.threads[index])
    }
    for projectIndex in document.projects.indices {
      guard
        let threadIndex = document.projects[projectIndex].threads
          .firstIndex(where: { $0.id == threadUUID })
      else {
        continue
      }
      return apply(
        to: &document.projects[projectIndex].threads[threadIndex])
    }
    return false
  }

  private static func continuationPreconditionMatches(
    current: TatwoGatewayConversationHandleV1?,
    request: TatwoGatewayContinuationRequestV1
  ) -> Bool {
    switch request.mode {
    case .none, .contextReplay:
      return current == nil
    case .providerResume:
      guard let current else { return false }
      return current.opaqueResponseHandle
          == request.previousResponseHandle
        && current.gatewayInstanceID
          == request.previousGatewayInstanceID
    }
  }

  private static func compatibleSessionModelID(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    let profile = TatwoChatRouteProfile.resolve(trimmed)
    return profile.runtimeAdapter == .unavailable ? trimmed : profile.id
  }

  public static func legacyAdapterHandles(
    codexCLISessionID: String?,
    codexSessionID: String?,
    claudeSessionID: String?
  ) -> [TatwoNativeAdapterSessionHandle] {
    var handles: [TatwoNativeAdapterSessionHandle] = []
    if let codex = nonEmpty(codexCLISessionID) ?? nonEmpty(codexSessionID) {
      handles.append(TatwoNativeAdapterSessionHandle(
        adapterID: TatwoChatRuntimeAdapter.codexExec.rawValue,
        providerSessionID: codex))
    }
    if let claude = nonEmpty(claudeSessionID) {
      handles.append(TatwoNativeAdapterSessionHandle(
        adapterID: TatwoChatRuntimeAdapter.claudeCLI.rawValue,
        providerSessionID: claude))
    }
    return handles
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
