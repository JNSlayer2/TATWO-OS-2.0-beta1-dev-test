import XCTest

@testable import TatwoUltraworkCore

/// B2: the dispatch registry persists each real sub-dispatch so the dashboard can show real
/// (and last-known) running subs. Mirrors GoalRunStoreTests' temp-dir pattern.
final class DispatchRegistryTests: XCTestCase {
  private func makeRegistry() -> (TatwoDispatchRegistry, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (TatwoDispatchRegistry(directoryURL: root), root)
  }

  private let contractID = "contract-xl-coding-abc123def456"

  @discardableResult
  private func begin(
    _ reg: TatwoDispatchRegistry,
    binding: String,
    goalID: String? = nil,
    at ms: Double
  ) throws
    -> TatwoDispatchRecord
  {
    try reg.begin(
      contractID: contractID, goalID: goalID,
      bindingID: binding, sourceSlotID: "slot-\(binding)",
      identity: .sub, modelID: "gpt-5.5", subtask: "review \(binding)",
      now: Date(timeIntervalSince1970: ms))
  }

  func testBeginWritesQueuedRecordUnderDispatchesDirectory() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    let record = try begin(reg, binding: "b1", at: 1000)
    XCTAssertEqual(record.status, .queued)
    XCTAssertEqual(record.modelID, "gpt-5.5")

    let run = try reg.run(forContractID: contractID)
    XCTAssertEqual(run?.records.count, 1)
    let url = try reg.fileURL(forContractID: contractID)
    XCTAssertTrue(url.path.contains("/dispatches/"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testUpdateTransitionsStatusAndPreservesOtherFields() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    let record = try begin(reg, binding: "b1", at: 1000)
    let running = try reg.update(contractID: contractID, dispatchID: record.id, status: .running)
    XCTAssertEqual(running.status, .running)
    XCTAssertEqual(running.subtask, record.subtask)  // unchanged
    XCTAssertEqual(running.startedAt, record.startedAt)  // unchanged

    let done = try reg.update(
      contractID: contractID, dispatchID: record.id, status: .completed,
      receiptID: "gateway-dispatch-gpt-5.5-1", outputRef: "sha256:abcd")
    XCTAssertEqual(done.status, .completed)
    XCTAssertEqual(done.receiptID, "gateway-dispatch-gpt-5.5-1")
    XCTAssertEqual(done.outputRef, "sha256:abcd")
  }

  func testUpdateUnknownDispatchThrows() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try begin(reg, binding: "b1", at: 1000)
    XCTAssertThrowsError(
      try reg.update(contractID: contractID, dispatchID: "no-such-dispatch", status: .completed)
    ) { error in
      guard case TatwoDispatchRegistryError.unknownDispatch = error else {
        return XCTFail("expected unknownDispatch, got \(error)")
      }
    }
  }

  func testLatestRecordsByBindingReturnsMostRecentPerBindingEvenAfterCompletion() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    // Two dispatches for b1 (retry), one for b2.
    let first = try begin(reg, binding: "b1", at: 1000)
    _ = try reg.update(
      contractID: contractID, dispatchID: first.id, status: .failed,
      now: Date(timeIntervalSince1970: 1100))
    let second = try begin(reg, binding: "b1", at: 2000)
    _ = try begin(reg, binding: "b2", at: 1500)

    let latest = try reg.latestRecordsByBinding(forContractID: contractID)
    XCTAssertEqual(latest.count, 2)  // one per binding
    let b1 = latest.first { $0.bindingID == "b1" }
    XCTAssertEqual(b1?.id, second.id)  // the newer b1 dispatch, not the failed one
  }

  func testRecordManifestSetsEntryIDs() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = TatwoExecutionManifestV1(
      contractID: contractID, goalID: "goal-xl-coding-abc123def456",
      generatedAt: Date(timeIntervalSince1970: 1000),
      entries: [
        TatwoExecutionManifestEntry(
          id: "dispatch-plan-b1", bindingID: "b1", sourceSlotID: "s1", identity: .sub,
          modelID: "gpt-5.5", subtask: "x", status: .planned)
      ])
    let run = try reg.recordManifest(manifest)
    XCTAssertEqual(run.schema, "TatwoStoredDispatchRunV2")
    XCTAssertEqual(run.manifestEntryIDs, ["dispatch-plan-b1"])
    XCTAssertEqual(run.executionManifest, manifest)
    XCTAssertEqual(
      run.executionManifestSHA256,
      try manifest.canonicalSHA256())
    XCTAssertEqual(
      try reg.requireExecutionManifest(
        contractID: contractID),
      manifest)
  }

  func testExecutablePublicationClassifierTreatsAbsentRunAsUnpublished() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertFalse(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1"]))
  }

  func testExecutablePublicationClassifierAllowsExactManifestOnlyRun() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try reg.recordManifest(
      TatwoExecutionManifestV1(
        contractID: contractID,
        goalID: "goal-xl-coding-abc123def456",
        generatedAt: Date(timeIntervalSince1970: 1_000),
        entries: [
          TatwoExecutionManifestEntry(
            id: "dispatch-plan-b2",
            bindingID: "b2",
            sourceSlotID: "s2",
            identity: .sub,
            modelID: "gpt-5.5",
            subtask: "second",
            status: .planned),
          TatwoExecutionManifestEntry(
            id: "dispatch-plan-b1",
            bindingID: "b1",
            sourceSlotID: "s1",
            identity: .sub,
            modelID: "gpt-5.5",
            subtask: "first",
            status: .planned),
        ]))

    XCTAssertFalse(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1", "b2"]))
  }

  func testExecutablePublicationClassifierRejectsManifestMismatchAndDuplicates() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalidManifests = [
      ["dispatch-plan-b1"],
      ["dispatch-plan-b1", "dispatch-plan-b2", "dispatch-plan-extra"],
      ["dispatch-plan-b1", "dispatch-plan-b1"],
    ]

    for manifestEntryIDs in invalidManifests {
      try persistDispatchRun(
        TatwoStoredDispatchRun(
          contractID: contractID,
          manifestEntryIDs: manifestEntryIDs),
        as: contractID,
        in: reg)
      XCTAssertTrue(
        reg.hasExecutablePublicationEvidence(
          forContractID: contractID,
          issuedBindingIDs: ["b1", "b2"]),
        "expected fail-closed publication for \(manifestEntryIDs)")
    }
  }

  func testExecutablePublicationClassifierRejectsAnyDispatchRecord() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try begin(reg, binding: "b1", at: 1_000)

    XCTAssertTrue(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1"]))
  }

  func testExecutablePublicationClassifierRejectsSealsAndAdvancedEpoch() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let seal = TatwoDispatchCycleSealV1(
      epoch: 1,
      sealID: "seal-1",
      sealedAt: Date(timeIntervalSince1970: 1_000),
      recordIDs: ["dispatch-1"],
      goalID: "goal-1")
    let invalidRuns = [
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        sealID: "seal-1"),
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        sealedAt: Date(timeIntervalSince1970: 1_000)),
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        sealedRecordIDs: []),
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        sealedGoalID: "goal-1"),
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        cycleSeals: [seal]),
      TatwoStoredDispatchRun(
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"],
        activeCycleEpoch: 2),
    ]

    for run in invalidRuns {
      try persistDispatchRun(run, as: contractID, in: reg)
      XCTAssertTrue(
        reg.hasExecutablePublicationEvidence(
          forContractID: contractID,
          issuedBindingIDs: ["b1"]))
    }
  }

  func testExecutablePublicationClassifierRejectsSchemaContractAndMalformedRun() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    try persistDispatchRun(
      TatwoStoredDispatchRun(
        schema: "TatwoStoredDispatchRunV2",
        contractID: contractID,
        manifestEntryIDs: ["dispatch-plan-b1"]),
      as: contractID,
      in: reg)
    XCTAssertTrue(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1"]))

    try persistDispatchRun(
      TatwoStoredDispatchRun(
        contractID: "contract-xl-coding-other123",
        manifestEntryIDs: ["dispatch-plan-b1"]),
      as: contractID,
      in: reg)
    XCTAssertTrue(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1"]))

    let url = try reg.fileURL(forContractID: contractID)
    try Data("{not-json".utf8).write(to: url)
    XCTAssertTrue(
      reg.hasExecutablePublicationEvidence(
        forContractID: contractID,
        issuedBindingIDs: ["b1"]))
  }

  func testRemoteOutboxEvidenceFailsClosedForParentAndContractSymlinks() throws {
    let (_, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-outbox-outside-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(
      at: outside, withIntermediateDirectories: true)
    let parent = root.appendingPathComponent(
      "remote-outbox-intents", isDirectory: true)

    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: parent, withDestinationURL: outside)
    XCTAssertTrue(
      TatwoRemoteOutboxEvidence.hasPublishedEvidence(
        stateDirectoryURL: root,
        contractID: contractID))

    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true)
    let contractDirectory = parent.appendingPathComponent(
      TatwoLoopPathComponent.sanitize(contractID), isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: contractDirectory, withDestinationURL: outside)
    XCTAssertTrue(
      TatwoRemoteOutboxEvidence.hasPublishedEvidence(
        stateDirectoryURL: root,
        contractID: contractID))
  }

  func testHelperCapRejectsBeyondCap() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try reg.begin(
      contractID: contractID, bindingID: "b1", sourceSlotID: "s", identity: .sub,
      modelID: "gpt-5.5", subtask: "x", helperCap: 2)
    _ = try reg.begin(
      contractID: contractID, bindingID: "b2", sourceSlotID: "s", identity: .sub,
      modelID: "gpt-5.5", subtask: "x", helperCap: 2)
    XCTAssertThrowsError(
      try reg.begin(
        contractID: contractID, bindingID: "b3", sourceSlotID: "s", identity: .sub,
        modelID: "gpt-5.5", subtask: "x", helperCap: 2)
    ) { error in
      guard case TatwoDispatchRegistryError.helperCapReached = error else {
        return XCTFail("expected helperCapReached, got \(error)")
      }
    }
  }

  func testHelperCapZeroRejectsAllDispatches() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    // S mode = cap 0 → no helper dispatch allowed.
    XCTAssertThrowsError(
      try reg.begin(
        contractID: contractID, bindingID: "b", sourceSlotID: "s", identity: .sub,
        modelID: "gpt-5.5", subtask: "x", helperCap: 0))
  }

  func testCompletedDispatchesFreeTheirCapSlot() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    // Fill the cap with 2 dispatches, then complete them. The cap counts only active
    // (queued/running) helpers, so a 3rd is allowed once the first two finish — an exam that
    // grades one model after another is never blocked by its own completed history.
    let d1 = try reg.begin(
      contractID: contractID, bindingID: "b1", sourceSlotID: "s", identity: .sub,
      modelID: "m", subtask: "x", helperCap: 2)
    let d2 = try reg.begin(
      contractID: contractID, bindingID: "b2", sourceSlotID: "s", identity: .sub,
      modelID: "m", subtask: "x", helperCap: 2)
    _ = try reg.update(contractID: contractID, dispatchID: d1.id, status: .completed)
    _ = try reg.update(contractID: contractID, dispatchID: d2.id, status: .completed)
    XCTAssertNoThrow(
      try reg.begin(
        contractID: contractID, bindingID: "b3", sourceSlotID: "s", identity: .sub,
        modelID: "m", subtask: "x", helperCap: 2))
  }

  func testSealCompletedSetIsIdempotentAndBlocksFurtherMutation() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try begin(reg, binding: "b1", at: 1000)
    _ = try reg.update(
      contractID: contractID,
      dispatchID: record.id,
      status: .completed)

    let firstSeal = try reg.sealCompletedSet(
      contractID: contractID,
      now: Date(timeIntervalSince1970: 2000))
    let retriedSeal = try reg.sealCompletedSet(
      contractID: contractID,
      now: Date(timeIntervalSince1970: 3000))

    XCTAssertNotNil(firstSeal.sealID)
    XCTAssertEqual(firstSeal.sealID, retriedSeal.sealID)
    XCTAssertEqual(firstSeal.sealedRecordIDs, [record.id])
    XCTAssertEqual(retriedSeal.sealedAt, firstSeal.sealedAt)
    XCTAssertThrowsError(
      try begin(reg, binding: "b2", at: 4000)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .runSealed(firstSeal.sealID ?? ""))
    }
    XCTAssertThrowsError(
      try reg.update(
        contractID: contractID,
        dispatchID: record.id,
        status: .failed)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .runSealed(firstSeal.sealID ?? ""))
    }
  }

  func testAdvanceCyclePreservesPriorSealAndBindsNewRecordsToNextEpoch() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try begin(reg, binding: "b1", goalID: "goal-1", at: 1000)
    _ = try reg.update(
      contractID: contractID,
      dispatchID: first.id,
      status: .completed)
    let sealed1 = try reg.sealCompletedSet(
      contractID: contractID,
      goalID: "goal-1",
      now: Date(timeIntervalSince1970: 2000))
    let seal1 = try XCTUnwrap(sealed1.sealID)

    let advanced = try reg.advanceCycle(
      contractID: contractID,
      goalID: "goal-1",
      expectedSealID: seal1,
      now: Date(timeIntervalSince1970: 3000))
    XCTAssertEqual(advanced.activeCycleEpoch, 2)
    XCTAssertEqual(advanced.cycleSeals?.map(\.sealID), [seal1])
    XCTAssertEqual(
      try reg.advanceCycle(
        contractID: contractID,
        goalID: "goal-1",
        expectedSealID: seal1,
        now: Date(timeIntervalSince1970: 4000)),
      advanced)

    let second = try begin(reg, binding: "b2", goalID: "goal-1", at: 5000)
    XCTAssertEqual(second.cycleEpoch, 2)
    _ = try reg.update(
      contractID: contractID,
      dispatchID: second.id,
      status: .completed)
    let sealed2 = try reg.sealCompletedSet(
      contractID: contractID,
      goalID: "goal-1",
      now: Date(timeIntervalSince1970: 6000))

    XCTAssertEqual(sealed2.cycleSeals?.map(\.epoch), [1, 2])
    XCTAssertEqual(sealed2.cycleSeals?.first?.recordIDs, [first.id])
    XCTAssertEqual(sealed2.cycleSeals?.last?.recordIDs, [second.id])
    XCTAssertNotEqual(sealed2.sealID, seal1)
  }

  func testSealRejectsEmptyAndIncompleteSets() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try reg.sealCompletedSet(contractID: contractID)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .cannotSealEmpty(contractID))
    }

    let record = try begin(reg, binding: "b1", at: 1000)
    XCTAssertThrowsError(
      try reg.sealCompletedSet(contractID: contractID)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .cannotSealIncomplete([record.id]))
    }
  }

  func testSealUsesCompletedLogicalHeadsAndIgnoresSupersededFailure() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let goalID = "goal-xl-coding-abc123def456"
    let first = try reg.begin(
      contractID: contractID,
      goalID: goalID,
      bindingID: "sol-review",
      sourceSlotID: "slot-sol",
      identity: .supervisor,
      modelID: "gpt-5.6-sol",
      subtask: "refute first",
      logicalDispatchID: "logical-sol-review",
      now: Date(timeIntervalSince1970: 1_000))
    _ = try reg.update(
      contractID: contractID,
      dispatchID: first.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      rawErrorDigest: "sha256:" + String(repeating: "a", count: 64),
      errorMessage: "server_error: retry allowed",
      now: Date(timeIntervalSince1970: 1_100))
    let retry = try reg.begin(
      contractID: contractID,
      goalID: goalID,
      bindingID: "sol-review",
      sourceSlotID: "slot-sol",
      identity: .supervisor,
      modelID: "gpt-5.6-sol",
      subtask: "refute first retry",
      logicalDispatchID: "logical-sol-review",
      supersedes: first.id,
      now: Date(timeIntervalSince1970: 2_000))
    _ = try reg.update(
      contractID: contractID,
      dispatchID: retry.id,
      status: .completed,
      now: Date(timeIntervalSince1970: 2_100))

    let sealed = try reg.sealCompletedSet(
      contractID: contractID,
      goalID: goalID,
      now: Date(timeIntervalSince1970: 3_000))

    XCTAssertEqual(retry.attempt, 2)
    XCTAssertEqual(retry.supersedes, first.id)
    XCTAssertEqual(sealed.sealedGoalID, goalID)
    XCTAssertEqual(sealed.sealedRecordIDs, [retry.id])
  }

  func testSealScopesToRequestedGoalRunInsteadOfContractHistory() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = try reg.begin(
      contractID: contractID,
      goalID: "goal-xl-coding-old000000000",
      bindingID: "old-fable",
      sourceSlotID: "slot-old",
      identity: .lead,
      modelID: "fable-5",
      subtask: "historical failure",
      logicalDispatchID: "logical-old",
      now: Date(timeIntervalSince1970: 1_000))
    _ = try reg.update(
      contractID: contractID,
      dispatchID: stale.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "session_limit",
      errorMessage: "session_limit",
      now: Date(timeIntervalSince1970: 1_100))
    let currentGoalID = "goal-xl-coding-new000000000"
    let current = try reg.begin(
      contractID: contractID,
      goalID: currentGoalID,
      bindingID: "current-fable",
      sourceSlotID: "slot-current",
      identity: .lead,
      modelID: "fable-5",
      subtask: "current adjudication",
      logicalDispatchID: "logical-current",
      now: Date(timeIntervalSince1970: 2_000))
    _ = try reg.update(
      contractID: contractID,
      dispatchID: current.id,
      status: .completed,
      now: Date(timeIntervalSince1970: 2_100))

    let sealed = try reg.sealCompletedSet(
      contractID: contractID,
      goalID: currentGoalID)

    XCTAssertEqual(sealed.sealedGoalID, currentGoalID)
    XCTAssertEqual(sealed.sealedRecordIDs, [current.id])
  }

  func testFailureReceiptSanitizesRawBackendPayloadAndStoresDigest() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try begin(reg, binding: "b1", at: 1_000)
    let raw = """
      {"type":"response.failed","response":{"id":"resp_test","error":{"code":"server_error","message":"retry with request ID req_test"},"output":[{"encrypted_content":"TOP_SECRET_CIPHERTEXT"}]}}
      """

    let failed = try reg.update(
      contractID: contractID,
      dispatchID: record.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      backendRequestID: "req_test",
      backendResponseID: "resp_test",
      errorMessage: raw)
    let encoded = try JSONEncoder().encode(failed)
    let text = String(decoding: encoded, as: UTF8.self)

    XCTAssertLessThanOrEqual(failed.errorMessage?.count ?? .max, 512)
    XCTAssertEqual(failed.failureReceipt?.failureClass, .retryable)
    XCTAssertEqual(failed.failureReceipt?.errorCode, "server_error")
    XCTAssertEqual(failed.failureReceipt?.backendRequestID, "req_test")
    XCTAssertEqual(failed.failureReceipt?.backendResponseID, "resp_test")
    XCTAssertTrue(failed.failureReceipt?.rawErrorDigest?.hasPrefix("sha256:") == true)
    XCTAssertFalse(text.contains("encrypted_content"))
    XCTAssertFalse(text.contains("TOP_SECRET_CIPHERTEXT"))
  }

  func testTerminalDispatchRecordCannotBeRewrittenInPlace() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = try begin(reg, binding: "immutable", at: 1_000)
    _ = try reg.update(
      contractID: contractID,
      dispatchID: record.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "first failure",
      now: Date(timeIntervalSince1970: 1_100))
    let url = try reg.fileURL(forContractID: contractID)
    let before = try Data(contentsOf: url)

    XCTAssertThrowsError(
      try reg.update(
        contractID: contractID,
        dispatchID: record.id,
        status: .completed,
        receiptID: "rewrite",
        now: Date(timeIntervalSince1970: 1_200)))
    XCTAssertThrowsError(
      try reg.update(
        contractID: contractID,
        dispatchID: record.id,
        status: .failed,
        failureClass: .terminal,
        errorCode: "policy_violation",
        errorMessage: "rewrite failure",
        now: Date(timeIntervalSince1970: 1_300)))
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  func testRetryCannotCrossGoalRunOrSupersedeTerminalFailure() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let goalA = "goal-xl-coding-aaaaaaaaaaaa"
    let goalB = "goal-xl-coding-bbbbbbbbbbbb"
    let retryable = try reg.begin(
      contractID: contractID,
      goalID: goalA,
      bindingID: "sol",
      sourceSlotID: "slot-sol",
      identity: .supervisor,
      modelID: "gpt-5.6-sol",
      subtask: "attempt one",
      logicalDispatchID: "logical-sol",
      now: Date(timeIntervalSince1970: 1_000))
    _ = try reg.update(
      contractID: contractID,
      dispatchID: retryable.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "retryable")

    XCTAssertThrowsError(
      try reg.begin(
        contractID: contractID,
        goalID: goalB,
        bindingID: "sol",
        sourceSlotID: "slot-sol",
        identity: .supervisor,
        modelID: "gpt-5.6-sol",
        subtask: "cross-goal retry",
        logicalDispatchID: "logical-sol",
        supersedes: retryable.id))

    let terminal = try reg.begin(
      contractID: contractID,
      goalID: goalA,
      bindingID: "terra",
      sourceSlotID: "slot-terra",
      identity: .verifier,
      modelID: "gpt-5.6-terra",
      subtask: "terminal attempt",
      logicalDispatchID: "logical-terra")
    _ = try reg.update(
      contractID: contractID,
      dispatchID: terminal.id,
      status: .failed,
      failureClass: .terminal,
      errorCode: "policy_violation",
      errorMessage: "terminal")

    XCTAssertThrowsError(
      try reg.begin(
        contractID: contractID,
        goalID: goalA,
        bindingID: "terra",
        sourceSlotID: "slot-terra",
        identity: .verifier,
        modelID: "gpt-5.6-terra",
        subtask: "terminal retry",
        logicalDispatchID: "logical-terra",
        supersedes: terminal.id))
  }

  func testRequestedGoalSealNeverAdoptsLegacyNilGoalRecords() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try begin(reg, binding: "legacy", at: 1_000)
    _ = try reg.update(
      contractID: contractID,
      dispatchID: legacy.id,
      status: .completed)

    XCTAssertThrowsError(
      try reg.sealCompletedSet(
        contractID: contractID,
        goalID: "goal-xl-coding-explicit00000")
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .cannotSealEmpty(contractID))
    }
  }

  func testConcurrentBeginsNeverExceedHelperCap() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    let cap = 5
    let localContractID = contractID
    // 20 simultaneous begins with cap 5 → the cross-process lock must serialize them so exactly
    // `cap` records land, never more. Without the lock the read-modify-write would race.
    DispatchQueue.concurrentPerform(iterations: 20) { i in
      _ = try? reg.begin(
        contractID: localContractID, bindingID: "b\(i)", sourceSlotID: "s", identity: .sub,
        modelID: "gpt-5.5", subtask: "x", helperCap: cap)
    }
    let run = try reg.run(forContractID: localContractID)
    XCTAssertEqual(run?.records.count, cap)
  }

  func testFileURLRejectsTraversalStyleContractID() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try reg.fileURL(forContractID: "../../etc/passwd"))
    XCTAssertThrowsError(try reg.fileURL(forContractID: ""))
  }

  func testAllRunsUpdatedSinceFiltersStaleDispatchRecords() throws {
    let (reg, root) = makeRegistry()
    defer { try? FileManager.default.removeItem(at: root) }

    let stale = try begin(reg, binding: "old", at: 1_000)
    _ = try reg.update(
      contractID: contractID, dispatchID: stale.id, status: .completed,
      now: Date(timeIntervalSince1970: 1_100))
    let fresh = try begin(reg, binding: "new", at: 2_000)
    _ = try reg.update(
      contractID: contractID, dispatchID: fresh.id, status: .running,
      now: Date(timeIntervalSince1970: 2_000))

    let runs = reg.allRuns(updatedSince: Date(timeIntervalSince1970: 1_500))
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.records.map(\.bindingID), ["new"])
  }

  private func persistDispatchRun(
    _ run: TatwoStoredDispatchRun,
    as contractID: String,
    in registry: TatwoDispatchRegistry
  ) throws {
    let url = try registry.fileURL(forContractID: contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(run).write(to: url, options: [.atomic])
  }
}
