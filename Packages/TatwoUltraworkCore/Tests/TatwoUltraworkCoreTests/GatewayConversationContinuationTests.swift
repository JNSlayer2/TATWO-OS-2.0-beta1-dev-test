import XCTest

@testable import TatwoUltraworkCore

final class GatewayConversationContinuationTests: XCTestCase {
  func testClassifierRecognizesHandleUnknownClassErrors() {
    let positives = [
      "continuation_handle_unknown_or_expired",
      "Error: continuation_handle_unknown",
      "gateway rejected continuation_handle_expired",
      "previous_response_handle_unknown",
      "previous_response_id_expired",
      "handle_unknown_or_expired",
      "continuation handle is unknown after restart",
      "previous response id expired",
    ]
    for message in positives {
      XCTAssertTrue(
        TatwoGatewayContinuationHandleErrorClassifierV1
          .isUnknownOrExpiredHandleError(message),
        message)
    }
  }

  func testClassifierRejectsUnrelatedFailures() {
    let negatives = [
      "",
      "quota exhausted",
      "gateway_model_attestation_mismatch",
      "unknown model",
      "expired lease",
      "continuation receipt missing",
      "handle this request",
    ]
    for message in negatives {
      XCTAssertFalse(
        TatwoGatewayContinuationHandleErrorClassifierV1
          .isUnknownOrExpiredHandleError(message),
        message)
    }
  }

  func testHandlelessFallbackDropsStalePointerAndMatchesFreshSend() {
    let request = makeResumeRequest()
    let rebuilt = request.handlelessFallbackRequest(
      rebuiltContextSHA256: Self.replayContextSHA256)

    XCTAssertTrue(request.isValid)
    XCTAssertEqual(rebuilt.mode, .none)
    XCTAssertNil(rebuilt.previousResponseHandle)
    XCTAssertNil(rebuilt.previousGatewayInstanceID)
    XCTAssertEqual(rebuilt.threadID, request.threadID)
    XCTAssertEqual(rebuilt.discussionID, request.discussionID)
    XCTAssertEqual(rebuilt.canonicalModelID, request.canonicalModelID)
    XCTAssertEqual(rebuilt.contextSHA256, Self.replayContextSHA256)
    XCTAssertTrue(rebuilt.isValid)
  }

  func testStaleHandleAutoFallbackSucceedsWithoutUserVisibleFailure() {
    let request = makeResumeRequest()
    let first = TatwoGatewayContinuationStaleHandleFallbackV1.decide(
      errorMessage: "continuation_handle_unknown_or_expired",
      request: request,
      fallbackAlreadyAttempted: false)
    XCTAssertEqual(first, .retryWithoutHandle)
    XCTAssertTrue(
      TatwoGatewayContinuationStaleHandleFallbackV1.shouldClearStoredHandle(
        errorMessage: "continuation_handle_unknown_or_expired",
        request: request))

    let successPresentation = "completed assistant answer"
    XCTAssertFalse(
      TatwoGatewayContinuationHandleErrorClassifierV1
        .isUnknownOrExpiredHandleError(successPresentation))
    XCTAssertNotEqual(first, .surfaceFailure)
  }

  func testFallbackAlsoFailsSurfacesSingleRetryError() {
    let request = makeResumeRequest()
    XCTAssertEqual(
      TatwoGatewayContinuationStaleHandleFallbackV1.decide(
        errorMessage: "continuation_handle_unknown_or_expired",
        request: request,
        fallbackAlreadyAttempted: true),
      .surfaceFailure)
    XCTAssertEqual(
      TatwoGatewayContinuationStaleHandleFallbackV1.decide(
        errorMessage: "quota exhausted",
        request: request,
        fallbackAlreadyAttempted: true),
      .notApplicable)
  }

  func testStoredHandleIsClearedAfterStaleFallback() {
    var document = makeDocumentWithHandle()
    let request = makeResumeRequest()
    XCTAssertNotNil(
      TatwoNativeSessionTree.gatewayConversationHandle(
        threadID: request.threadID,
        discussionID: nil,
        adapterID: request.runtimeAdapterID,
        modelID: request.canonicalModelID,
        handles: document.threads[0].gatewayConversationHandles))

    XCTAssertTrue(
      TatwoNativeSessionTree.clearGatewayConversationHandle(
        matching: request,
        in: &document))
    XCTAssertNil(
      TatwoNativeSessionTree.gatewayConversationHandle(
        threadID: request.threadID,
        discussionID: nil,
        adapterID: request.runtimeAdapterID,
        modelID: request.canonicalModelID,
        handles: document.threads[0].gatewayConversationHandles))
    XCTAssertTrue(
      TatwoGatewayContinuationStaleHandleFallbackV1.shouldClearStoredHandle(
        errorMessage: "continuation_handle_unknown_or_expired",
        request: request))
  }

  func testClearHandleIsCompareAndSwapAndLeavesNewerPointer() {
    var document = makeDocumentWithHandle(
      opaqueHandle: "newer-gateway-handle-22")
    let stale = makeResumeRequest()
    XCTAssertFalse(
      TatwoNativeSessionTree.clearGatewayConversationHandle(
        matching: stale,
        in: &document))
    XCTAssertEqual(
      document.threads[0].gatewayConversationHandles.first?
        .opaqueResponseHandle,
      "newer-gateway-handle-22")
  }

  func testJournalRecapPathIsUsedWhenHandleIsGone() {
    let messages = [
      TatwoNativeChatStoredMessage(
        role: "user",
        text: "第一輪使用者問題"),
      TatwoNativeChatStoredMessage(
        role: "assistant",
        text: "第一輪 Grok 回覆",
        modelID: "sonnet5",
        runtimeAdapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue),
    ]
    let resumed = TatwoChatThreadContextComposer.compose(
      currentTurn: "第二輪",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: true)
    let replayed = TatwoChatThreadContextComposer.compose(
      currentTurn: "第二輪",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false)

    XCTAssertFalse(resumed.contains("第一輪使用者問題"))
    XCTAssertTrue(replayed.contains("第一輪使用者問題"))
    XCTAssertTrue(replayed.contains("第一輪 Grok 回覆"))
    XCTAssertTrue(replayed.hasSuffix("第二輪"))
  }

  private func makeResumeRequest() -> TatwoGatewayContinuationRequestV1 {
    TatwoGatewayContinuationRequestV1(
      mode: .providerResume,
      threadID: Self.threadID.uuidString.lowercased(),
      runtimeAdapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
      canonicalModelID: "grok-4.6",
      previousResponseHandle: "stale-gateway-handle-01",
      previousGatewayInstanceID: "gateway-instance-01",
      contextSHA256: Self.resumeContextSHA256)
  }

  private func makeDocumentWithHandle(
    opaqueHandle: String = "stale-gateway-handle-01"
  ) -> TatwoNativeChatStoreDocument {
    let handle = TatwoGatewayConversationHandleV1(
      opaqueResponseHandle: opaqueHandle,
      threadID: Self.threadID.uuidString.lowercased(),
      runtimeAdapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
      canonicalModelID: "grok-4.6",
      gatewayInstanceID: "gateway-instance-01")
    XCTAssertTrue(handle.isValid)
    let thread = TatwoNativeChatThread(
      id: Self.threadID,
      title: "Grok thread",
      gatewayConversationHandles: [handle])
    return TatwoNativeChatStoreDocument(threads: [thread])
  }

  private static let threadID = UUID(
    uuidString: "019f0000-0000-7000-8000-0000000000aa")!
  private static let resumeContextSHA256 =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  private static let replayContextSHA256 =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
