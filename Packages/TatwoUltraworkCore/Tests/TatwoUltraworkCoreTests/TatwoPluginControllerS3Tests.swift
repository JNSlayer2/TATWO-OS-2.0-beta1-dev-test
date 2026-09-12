import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPluginControllerS3Tests: XCTestCase {
  private var tempRoot: URL!

  override func setUpWithError() throws {
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-plugin-s3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot {
      try? FileManager.default.removeItem(at: tempRoot)
    }
  }

  // MARK: 1 — conflict whole-batch reject

  func testConflictRejectsWholeBatchNoPartialApply() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "# original\n".write(to: target, atomically: true, encoding: .utf8)
    let original = try String(contentsOf: target, encoding: .utf8)

    let plan = makePlan(
      revision: "s3-conflict",
      items: [
        makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a")),
        makeItem(
          id: "delta",
          action: .conflict,
          body: codexBody(id: "delta", command: "d"),
          observed: "serverID=delta\ntransport=stdio\ncommand=hand\nargs=[]\n",
          desired: "serverID=delta\ntransport=stdio\ncommand=d\nargs=[]\n"),
      ])
    let token = try authToken(for: plan, target: target)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: target.path,
        humanGateToken: token)
    ) { error in
      guard case TatwoPluginApplyErrorV1.planContainsConflict(let ids) = error else {
        return XCTFail("expected planContainsConflict, got \(error)")
      }
      XCTAssertEqual(ids, ["delta"])
    }

    // No partial apply: original untouched, no backup created
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
    let backups = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
      .filter { $0.contains("tatwo-backup-") }
    XCTAssertTrue(backups.isEmpty)
  }

  // MARK: 2 — backup reservation is unique and never overwrites

  func testBackupsAreUniqueWithinSameTimestampAndNeverOverwrite() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "model = \"keep\"\n".write(to: target, atomically: true, encoding: .utf8)

    let fixedNow = ISO8601DateFormatter().date(from: "2026-07-30T12:00:00Z")!
    let plan = makePlan(
      revision: "s3-backup",
      items: [
        makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "alpha"))
      ])
    let first = try TatwoPluginApplyEngineV1.apply(
      plan: plan,
      targetPath: target.path,
      humanGateToken: try authToken(for: plan, target: target),
      now: fixedNow)
    let secondPlan = makePlan(
      revision: "s3-backup-second",
      items: [
        makeItem(id: "alpha", action: .update, body: codexBody(id: "alpha", command: "alpha-2"))
      ])
    let second = try TatwoPluginApplyEngineV1.apply(
      plan: secondPlan,
      targetPath: target.path,
      humanGateToken: try authToken(for: secondPlan, target: target),
      now: fixedNow)

    XCTAssertNotEqual(first.backupPath, second.backupPath)
    XCTAssertEqual(try String(contentsOfFile: first.backupPath!, encoding: .utf8), "model = \"keep\"\n")
    XCTAssertTrue(try String(contentsOfFile: second.backupPath!, encoding: .utf8).contains("mcp_servers.alpha"))
  }

  // MARK: 3 — atomic write (temp + rename → complete final content)

  func testAtomicWriteProducesCompleteTarget() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "model = \"x\"\n".write(to: target, atomically: true, encoding: .utf8)

    let body = codexBody(id: "alpha", command: "alpha-cmd")
    let plan = makePlan(
      revision: "s3-atomic",
      items: [makeItem(id: "alpha", action: .create, body: body)])
    let token = try authToken(for: plan, target: target)

    let receipt = try TatwoPluginApplyEngineV1.apply(
      plan: plan,
      targetPath: target.path,
      humanGateToken: token)

    XCTAssertEqual(receipt.status, .applied)
    let text = try String(contentsOf: target, encoding: .utf8)
    XCTAssertTrue(text.contains("model = \"x\""))
    XCTAssertTrue(text.contains("[mcp_servers.alpha]"))
    XCTAssertTrue(text.contains("command = \"alpha-cmd\""))
    XCTAssertNotNil(receipt.backupPath)
    XCTAssertEqual(receipt.ownershipRecords.count, 1)
    XCTAssertEqual(receipt.ownershipRecords[0].serverID, "alpha")
    XCTAssertEqual(receipt.ownershipRecords[0].appliedAtRevision, "s3-atomic")
    XCTAssertFalse(receipt.ownershipRecords[0].appliedFragmentSHA256.isEmpty)
  }

  // MARK: 4 — readback mismatch auto-rollback

  func testReadbackMismatchAutoRollback() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    let original = "model = \"orig\"\n"
    try original.write(to: target, atomically: true, encoding: .utf8)

    let body = codexBody(id: "alpha", command: "alpha")
    let plan = makePlan(
      revision: "s3-mismatch",
      items: [makeItem(id: "alpha", action: .create, body: body)])
    let token = try authToken(for: plan, target: target)

    let corruptIO = CorruptingApplyFileIO(inner: TatwoPluginDefaultApplyFileIO())
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: target.path,
        humanGateToken: token,
        fileIO: corruptIO)
    ) { error in
      guard case TatwoPluginApplyErrorV1.readbackMismatch = error else {
        return XCTFail("expected readbackMismatch, got \(error)")
      }
    }

    // Target restored from backup
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
  }

  // MARK: 5 — rollback receipt

  func testRollbackReceiptRestoresBackup() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    let original = "model = \"before\"\n"
    try original.write(to: target, atomically: true, encoding: .utf8)

    let body = codexBody(id: "alpha", command: "alpha")
    let plan = makePlan(
      revision: "s3-rollback",
      items: [makeItem(id: "alpha", action: .create, body: body)])
    let token = try authToken(for: plan, target: target)

    let receipt = try TatwoPluginApplyEngineV1.apply(
      plan: plan,
      targetPath: target.path,
      humanGateToken: token)
    XCTAssertEqual(receipt.status, .applied)
    XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("mcp_servers.alpha"))

    let rb = try TatwoPluginApplyEngineV1.rollback(receipt: receipt)
    XCTAssertEqual(rb.status, .rollbackPassed)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), original)
    XCTAssertNotNil(rb.restoredSHA256)
    XCTAssertEqual(rb.originalApplyPlanDigest, receipt.planDigest)
  }

  // MARK: 6 — token planDigest mismatch reject

  func testAuthorizationPlanDigestMismatchRejects() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "# empty\n".write(to: target, atomically: true, encoding: .utf8)

    let plan = makePlan(
      revision: "s3-digest",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let badToken = TatwoPluginApplyAuthorizationV1(
      approvedPlanDigest: String(repeating: "ab", count: 32),
      approvedTargetPath: target.path,
      approvedBrand: .codex,
      approver: "human@test",
      approvedAt: "2026-07-30T12:00:00Z")

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: target.path,
        humanGateToken: badToken)
    ) { error in
      guard case TatwoPluginApplyErrorV1.authorizationDigestMismatch = error else {
        return XCTFail("expected authorizationDigestMismatch, got \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# empty\n")
  }

  func testAuthorizationBindingRejectsTargetAndBrandReuse() throws {
    let targetA = tempRoot.appendingPathComponent("a.toml")
    let targetB = tempRoot.appendingPathComponent("b.toml")
    try "# a\n".write(to: targetA, atomically: true, encoding: .utf8)
    try "# b\n".write(to: targetB, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-auth-binding",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let token = try authToken(for: plan, target: targetA)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: targetB.path,
        humanGateToken: token)
    ) { error in
      guard case TatwoPluginApplyErrorV1.authorizationTargetMismatch = error else {
        return XCTFail("expected authorizationTargetMismatch, got \(error)")
      }
    }

    let brandPlan = TatwoPluginStagedPlanDocumentV1(
      registryRevision: "s3-auth-brand",
      brands: [.claude],
      items: [
        TatwoPluginStagedPlanItemV1(
          entryID: "alpha",
          entryType: .portableMcp,
          brand: .claude,
          action: .create,
          logicalPath: "~/.claude/.mcp.json#mcpServers.alpha",
          templateID: "claude.mcp-server.v1",
          projectedBody: #"{"command":"alpha","type":"stdio"}"#,
          unifiedDiff: "diff")
      ])
    let brandToken = TatwoPluginApplyAuthorizationV1(
      approvedPlanDigest: TatwoPluginApplyEngineV1.planDigest(brandPlan),
      approvedTargetPath: targetA.path,
      approvedBrand: .codex,
      approver: "human@test",
      approvedAt: "2026-07-30T12:00:00Z")
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: brandPlan,
        targetPath: targetA.path,
        humanGateToken: brandToken)
    ) { error in
      guard case TatwoPluginApplyErrorV1.authorizationBrandMismatch = error else {
        return XCTFail("expected authorizationBrandMismatch, got \(error)")
      }
    }
  }

  func testLoadedAuthorizationCanonicalizesTargetPath() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    let alias = tempRoot.appendingPathComponent("config-alias.toml")
    try "# fixture\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)

    let plan = makePlan(
      revision: "s3-auth-decode",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let payload: [String: Any] = [
      "schema": TatwoPluginApplyAuthorizationV1.schemaName,
      "approvedPlanDigest": TatwoPluginApplyEngineV1.planDigest(plan),
      "approvedTargetPath": alias.path,
      "approvedBrand": "codex",
      "approver": "human@test",
      "approvedAt": "2026-07-30T12:00:00Z",
    ]
    let authURL = tempRoot.appendingPathComponent("authorization.json")
    try JSONSerialization.data(withJSONObject: payload).write(to: authURL)

    XCTAssertEqual(
      TatwoPluginApplyEngineV1.canonicalTargetPath(alias.path),
      TatwoPluginApplyEngineV1.canonicalTargetPath(target.path))
    let loaded = try TatwoPluginApplyEngineV1.loadAuthorization(from: authURL)
    XCTAssertEqual(
      loaded.approvedTargetPath,
      TatwoPluginApplyEngineV1.canonicalTargetPath(target.path))
    XCTAssertEqual(loaded.approvedBrand, .codex)
  }

  // MARK: 7 — missing backup fail-closed

  func testRollbackMissingBackupFailClosed() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "model = \"x\"\n".write(to: target, atomically: true, encoding: .utf8)

    let fake = TatwoPluginApplyReceiptV1(
      status: .applied,
      registryRevision: "s3-missing-backup",
      planDigest: String(repeating: "cd", count: 32),
      targetPath: target.path,
      backupPath: tempRoot.appendingPathComponent("does-not-exist.tatwo-backup-X").path,
      ownershipRecords: [],
      appliedEntryIDs: ["alpha"],
      skippedEntryIDs: [],
      approver: "human@test",
      approvedAt: "2026-07-30T12:00:00Z",
      recordedAt: "2026-07-30T12:00:01Z")

    let rb = try TatwoPluginApplyEngineV1.rollback(receipt: fake)
    XCTAssertEqual(rb.status, .rollbackFailed)
    XCTAssertTrue((rb.error ?? "").contains("backup missing") || (rb.error ?? "").contains("fail-closed") || (rb.error ?? "").lowercased().contains("missing"))
    // Target not guessed/cleared
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "model = \"x\"\n")
  }

  // MARK: Extra — user home config requires ack flag

  func testUserHomeConfigRequiresAckFlag() throws {
    let homeCodex = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
    let plan = makePlan(
      revision: "s3-home",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let token = try authToken(for: plan, target: URL(fileURLWithPath: homeCodex))

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: homeCodex,
        humanGateToken: token,
        acknowledgeUserConfigTarget: false)
    ) { error in
      guard case TatwoPluginApplyErrorV1.userHomeConfigRequiresAck = error else {
        return XCTFail("expected userHomeConfigRequiresAck, got \(error)")
      }
    }
  }

  func testSymlinkParentToHomeConfigRequiresAckForMissingLeaf() throws {
    let alias = tempRoot.appendingPathComponent("codex-alias", isDirectory: true)
    let homeCodex = URL(fileURLWithPath: (NSHomeDirectory() as NSString)
      .appendingPathComponent(".codex"))
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: homeCodex)
    let missingLeaf = alias.appendingPathComponent("missing-config.toml")
    XCTAssertTrue(TatwoPluginApplyEngineV1.isUserHomeAgentConfigPath(missingLeaf.path))
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.assertTargetPathAllowed(
        missingLeaf.path,
        acknowledgeUserConfigTarget: false)
    ) { error in
      guard case TatwoPluginApplyErrorV1.userHomeConfigRequiresAck = error else {
        return XCTFail("expected userHomeConfigRequiresAck, got \(error)")
      }
    }
  }

  /// F20: apply path (not only auth load) must realpath a leaf symlink that
  /// points at home config and still demand the user-config ack flag.
  /// Does not read or write the real home file — only identity / gate checks.
  func testApplySymlinkTargetToHomeConfigRequiresAckFlag() throws {
    let homeCodex = URL(fileURLWithPath: (NSHomeDirectory() as NSString)
      .appendingPathComponent(".codex/config.toml"))
    let alias = tempRoot.appendingPathComponent("home-config-alias.toml")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: homeCodex)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path),
      homeCodex.path)

    let canonicalAlias = TatwoPluginApplyEngineV1.canonicalTargetPath(alias.path)
    let canonicalHome = TatwoPluginApplyEngineV1.canonicalTargetPath(homeCodex.path)
    XCTAssertEqual(canonicalAlias, canonicalHome)
    XCTAssertTrue(TatwoPluginApplyEngineV1.isUserHomeAgentConfigPath(alias.path))

    let plan = makePlan(
      revision: "s3-symlink-home-apply",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    // Token is bound to the symlink path string; init must canonicalize to home.
    let token = try authToken(for: plan, target: alias)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPath: alias.path,
        humanGateToken: token,
        acknowledgeUserConfigTarget: false)
    ) { error in
      guard case TatwoPluginApplyErrorV1.userHomeConfigRequiresAck = error else {
        return XCTFail("expected userHomeConfigRequiresAck, got \(error)")
      }
    }
  }

  func testMultiTargetApplyHappyPath() throws {
    let targetA = tempRoot.appendingPathComponent("a.toml")
    let targetB = tempRoot.appendingPathComponent("b.toml")
    try "# a\n".write(to: targetA, atomically: true, encoding: .utf8)
    try "# b\n".write(to: targetB, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-multi-target",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let receipt = try TatwoPluginApplyEngineV1.apply(
      plan: plan,
      targetPaths: [targetA.path, targetB.path],
      humanGateToken: try authToken(for: plan, targets: [targetA, targetB]))
    XCTAssertEqual(receipt.status, .applied)
    XCTAssertEqual(receipt.targetPaths, [
      TatwoPluginApplyEngineV1.canonicalTargetPath(targetA.path),
      TatwoPluginApplyEngineV1.canonicalTargetPath(targetB.path),
    ])
    XCTAssertTrue(try String(contentsOf: targetA, encoding: .utf8).contains("mcp_servers.alpha"))
    XCTAssertTrue(try String(contentsOf: targetB, encoding: .utf8).contains("mcp_servers.alpha"))
    XCTAssertEqual(receipt.backupPaths.count, 2)
  }

  func testMultiTargetPrepareFailureLeavesTargetsUntouched() throws {
    let targetA = tempRoot.appendingPathComponent("prepare-a.toml")
    let targetB = tempRoot.appendingPathComponent("prepare-b.toml")
    try "# a\n".write(to: targetA, atomically: true, encoding: .utf8)
    try "# b\n".write(to: targetB, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-prepare-failure",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let io = FaultInjectingApplyFileIO(failTempWrite: true)
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPaths: [targetA.path, targetB.path],
        humanGateToken: try authToken(for: plan, targets: [targetA, targetB]),
        fileIO: io)
    ) { error in
      guard case TatwoPluginApplyErrorV1.prepareFailed = error else {
        return XCTFail("expected prepareFailed, got \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: targetA, encoding: .utf8), "# a\n")
    XCTAssertEqual(try String(contentsOf: targetB, encoding: .utf8), "# b\n")
    let tempFiles = try FileManager.default.contentsOfDirectory(
      at: tempRoot,
      includingPropertiesForKeys: nil)
    XCTAssertFalse(tempFiles.contains {
      $0.lastPathComponent.contains(".tatwo-apply-") && $0.pathExtension == "tmp"
    })
  }

  func testMultiTargetCommitFailureRollsBackAllCommittedTargets() throws {
    let targetA = tempRoot.appendingPathComponent("commit-a.toml")
    let targetB = tempRoot.appendingPathComponent("commit-b.toml")
    try "# a\n".write(to: targetA, atomically: true, encoding: .utf8)
    try "# b\n".write(to: targetB, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-commit-failure",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let io = FaultInjectingApplyFileIO(failRenameAt: 1)
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPaths: [targetA.path, targetB.path],
        humanGateToken: try authToken(for: plan, targets: [targetA, targetB]),
        fileIO: io)
    ) { error in
      guard case TatwoPluginApplyErrorV1.partialCommitRolledBack(let restored, _) = error else {
        return XCTFail("expected partialCommitRolledBack, got \(error)")
      }
      XCTAssertEqual(restored, [
        TatwoPluginApplyEngineV1.canonicalTargetPath(targetA.path),
      ])
    }
    XCTAssertEqual(try String(contentsOf: targetA, encoding: .utf8), "# a\n")
    XCTAssertEqual(try String(contentsOf: targetB, encoding: .utf8), "# b\n")
  }

  func testCrashJournalRecoveryRestoresRenamedTargetAndCleansTemp() throws {
    let target = tempRoot.appendingPathComponent("crash.toml")
    let backup = tempRoot.appendingPathComponent("crash.toml.tatwo-backup-crash")
    let temp = tempRoot.appendingPathComponent(".crash.toml.tatwo-apply-crash-tx-0.tmp")
    let journal = tempRoot.appendingPathComponent("crash.journal.jsonl")
    try "# before\n".write(to: backup, atomically: true, encoding: .utf8)
    try "[mcp_servers.alpha]\ncommand = \"after\"\n".write(to: target, atomically: true, encoding: .utf8)
    try "stale temp\n".write(to: temp, atomically: true, encoding: .utf8)
    let expected = try Data(contentsOf: target)
    let authDigest = String(repeating: "a", count: 64)
    let line1 = try journalFixtureLine(
      transactionID: "crash-tx",
      phase: "prepare",
      targetPath: target.path,
      tempPath: temp.path,
      backupPath: backup.path,
      existed: true,
      beforeSHA256: TatwoPluginApplyEngineV1.sha256Hex(try Data(contentsOf: backup)),
      expectedSHA256: TatwoPluginApplyEngineV1.sha256Hex(expected),
      chainDigest: authDigest,
      transactionAuthorizationDigest: authDigest,
      authorizationTargetPaths: [target.path])
    let line1Digest = TatwoPluginApplyEngineV1.sha256Hex(line1)
    let line2 = try journalFixtureLine(
      transactionID: "crash-tx",
      phase: "commitStarted",
      chainDigest: line1Digest,
      transactionAuthorizationDigest: authDigest,
      authorizationTargetPaths: [target.path])
    let journalData = line1 + Data([0x0a]) + line2 + Data([0x0a])
    try journalData.write(to: journal)

    let recovery = try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    XCTAssertEqual(recovery.status, .recovered)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# before\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    XCTAssertEqual(recovery.restoredTargets, [TatwoPluginApplyEngineV1.canonicalTargetPath(target.path)])
  }

  func testMalformedJournalFailsBeforeRecoveryMutation() throws {
    let target = tempRoot.appendingPathComponent("malformed.toml")
    try "sentinel\n".write(to: target, atomically: true, encoding: .utf8)
    let journal = tempRoot.appendingPathComponent("malformed.journal.jsonl")
    try Data("{not-json}\n".utf8).write(to: journal)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    ) { error in
      guard case TatwoPluginApplyErrorV1.recoveryFailed(let detail) = error else {
        return XCTFail("expected recoveryFailed, got \(error)")
      }
      XCTAssertTrue(detail.contains("invalid journal"))
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel\n")
  }

  func testBrokenJournalChainFailsBeforeRecoveryMutation() throws {
    let target = tempRoot.appendingPathComponent("broken-chain.toml")
    let backup = tempRoot.appendingPathComponent("broken-chain.toml.tatwo-backup-chain")
    let temp = tempRoot.appendingPathComponent(
      ".broken-chain.toml.tatwo-apply-broken-chain-0.tmp")
    let journal = tempRoot.appendingPathComponent("broken-chain.journal.jsonl")
    try "before\n".write(to: backup, atomically: true, encoding: .utf8)
    try "after\n".write(to: target, atomically: true, encoding: .utf8)
    try "temp\n".write(to: temp, atomically: true, encoding: .utf8)
    let authDigest = String(repeating: "b", count: 64)
    let line = try journalFixtureLine(
      transactionID: "broken-chain",
      phase: "prepare",
      targetPath: target.path,
      tempPath: temp.path,
      backupPath: backup.path,
      existed: true,
      beforeSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("before\n".utf8)),
      expectedSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("after\n".utf8)),
      chainDigest: String(repeating: "c", count: 64),
      transactionAuthorizationDigest: authDigest,
      authorizationTargetPaths: [target.path])
    try (line + Data([0x0a])).write(to: journal)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    ) { error in
      XCTAssertEqual(error as? TatwoPluginApplyErrorV1, .recoveryFailed("journal integrity"))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after\n")
  }

  func testAuthorizationDigestMismatchFailsBeforeRecoveryMutation() throws {
    let target = tempRoot.appendingPathComponent("auth-mismatch.toml")
    let journal = tempRoot.appendingPathComponent("auth-mismatch.journal.jsonl")
    let authA = String(repeating: "d", count: 64)
    let authB = String(repeating: "e", count: 64)
    let line1 = try journalFixtureLine(
      transactionID: "auth-mismatch",
      phase: "commitStarted",
      chainDigest: authA,
      transactionAuthorizationDigest: authA,
      authorizationTargetPaths: [target.path])
    let line2 = try journalFixtureLine(
      transactionID: "auth-mismatch",
      phase: "complete",
      chainDigest: TatwoPluginApplyEngineV1.sha256Hex(line1),
      transactionAuthorizationDigest: authB,
      authorizationTargetPaths: [target.path])
    try (line1 + Data([0x0a]) + line2 + Data([0x0a])).write(to: journal)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    ) { error in
      XCTAssertEqual(error as? TatwoPluginApplyErrorV1, .recoveryFailed("journal integrity"))
    }
  }

  func testJournalOutsideAuthorizedTargetSetFailsBeforeRecoveryMutation() throws {
    let authorized = tempRoot.appendingPathComponent("authorized.toml")
    let outside = tempRoot.appendingPathComponent("outside.toml")
    let backup = tempRoot.appendingPathComponent("outside.toml.tatwo-backup-outside")
    let temp = tempRoot.appendingPathComponent(
      ".outside.toml.tatwo-apply-outside-target-0.tmp")
    let journal = tempRoot.appendingPathComponent("outside.journal.jsonl")
    try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
    try "backup\n".write(to: backup, atomically: true, encoding: .utf8)
    try "temp\n".write(to: temp, atomically: true, encoding: .utf8)
    let authDigest = String(repeating: "f", count: 64)
    let line = try journalFixtureLine(
      transactionID: "outside-target",
      phase: "prepare",
      targetPath: outside.path,
      tempPath: temp.path,
      backupPath: backup.path,
      existed: true,
      beforeSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("backup\n".utf8)),
      expectedSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("outside\n".utf8)),
      chainDigest: authDigest,
      transactionAuthorizationDigest: authDigest,
      authorizationTargetPaths: [authorized.path])
    try (line + Data([0x0a])).write(to: journal)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    ) { error in
      XCTAssertEqual(error as? TatwoPluginApplyErrorV1, .recoveryFailed("journal integrity"))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
  }

  func testJournalCompanionOutsideAuthorizedTargetDirectoryFailsBeforeRecoveryMutation() throws {
    let target = tempRoot.appendingPathComponent("authorized-companion.toml")
    let backup = tempRoot.appendingPathComponent(
      "authorized-companion.toml.tatwo-backup-companion")
    let outsideDir = tempRoot.appendingPathComponent("unauthorized-companion-dir")
    let temp = outsideDir.appendingPathComponent(
      ".authorized-companion.toml.tatwo-apply-companion-outside-0.tmp")
    let journal = tempRoot.appendingPathComponent("companion-outside.journal.jsonl")
    try FileManager.default.createDirectory(
      at: outsideDir,
      withIntermediateDirectories: true)
    try "after\n".write(to: target, atomically: true, encoding: .utf8)
    try "before\n".write(to: backup, atomically: true, encoding: .utf8)
    try "temp\n".write(to: temp, atomically: true, encoding: .utf8)
    let authDigest = String(repeating: "1", count: 64)
    let line = try journalFixtureLine(
      transactionID: "companion-outside",
      phase: "prepare",
      targetPath: target.path,
      tempPath: temp.path,
      backupPath: backup.path,
      existed: true,
      beforeSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("before\n".utf8)),
      expectedSHA256: TatwoPluginApplyEngineV1.sha256Hex(Data("after\n".utf8)),
      chainDigest: authDigest,
      transactionAuthorizationDigest: authDigest,
      authorizationTargetPaths: [target.path])
    try (line + Data([0x0a])).write(to: journal)

    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.recoverIfNeeded(journalPath: journal.path)
    ) { error in
      XCTAssertEqual(error as? TatwoPluginApplyErrorV1, .recoveryFailed("journal integrity"))
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after\n")
    XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
  }

  func testMultiTargetReadbackMismatchRollsBackWholeBatch() throws {
    let targetA = tempRoot.appendingPathComponent("readback-a.toml")
    let targetB = tempRoot.appendingPathComponent("readback-b.toml")
    try "# a\n".write(to: targetA, atomically: true, encoding: .utf8)
    try "# b\n".write(to: targetB, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-readback-failure",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "a"))])
    let io = CorruptingTargetReadbackFileIO(
      inner: TatwoPluginDefaultApplyFileIO(),
      targetPath: targetB.path)
    XCTAssertThrowsError(
      try TatwoPluginApplyEngineV1.apply(
        plan: plan,
        targetPaths: [targetA.path, targetB.path],
        humanGateToken: try authToken(for: plan, targets: [targetA, targetB]),
        fileIO: io)
    ) { error in
      guard case TatwoPluginApplyErrorV1.readbackMismatch = error else {
        return XCTFail("expected readbackMismatch, got \(error)")
      }
    }
    XCTAssertEqual(try String(contentsOf: targetA, encoding: .utf8), "# a\n")
    XCTAssertEqual(try String(contentsOf: targetB, encoding: .utf8), "# b\n")
  }

  func testRollbackMarksOwnershipRolledBackAndReplanIsNotUnchanged() throws {
    let target = tempRoot.appendingPathComponent("config.toml")
    try "model = \"before\"\n".write(to: target, atomically: true, encoding: .utf8)
    let plan = makePlan(
      revision: "s3-provenance",
      items: [makeItem(id: "alpha", action: .create, body: codexBody(id: "alpha", command: "alpha"))])
    let receipt = try TatwoPluginApplyEngineV1.apply(
      plan: plan,
      targetPath: target.path,
      humanGateToken: try authToken(for: plan, target: target))
    let rollback = try TatwoPluginApplyEngineV1.rollback(receipt: receipt)
    XCTAssertEqual(rollback.status, .rollbackPassed)
    XCTAssertEqual(rollback.ownershipRecordsBefore, receipt.ownershipRecords)
    XCTAssertTrue(rollback.ownershipRecordsAfter.allSatisfy { $0.state == .rolledBack })

    let registry = TatwoPluginControllerRegistryDocumentV1(
      registryRevision: "s3-provenance",
      entries: [],
      source: "os_registry")
    // A direct plan item fixture proves the planner's rolledBack precedence
    // without touching a real home config or registry.
    let observed = TatwoPluginObservedMcpServerV1(
      serverID: "alpha",
      source: .codexToml,
      transport: "stdio",
      command: "alpha",
      args: [],
      url: nil)
    let _ = registry
    let rebuilt = try TatwoPluginStagedPlanV1.build(
      registry: TatwoPluginControllerRegistryDocumentV1(
        registryRevision: "s3-provenance",
        entries: [
          TatwoPluginRegistryEntryV1(
            id: "alpha",
            type: .portableMcp,
            desiredState: .enabled,
            canonicalDefinition: TatwoPluginCanonicalMcpDefinitionV1(
              protocolName: "mcp",
              transport: .stdio,
              command: "alpha",
              args: []),
            projectionTemplates: [
              "codex": TatwoPluginProjectionTemplateRefV1(templateID: "codex.mcp-server.v1")
            ])
        ],
        source: "os_registry"),
      brands: [.codex],
      codexServers: [observed],
      ownershipRecords: rollback.ownershipRecordsAfter)
    XCTAssertNotEqual(rebuilt.items.first?.action, .unchanged)

    // A stale active record must not mask a later rollback tombstone merely
    // because the active record appears first in persisted storage.
    let rebuiltWithActiveFirst = try TatwoPluginStagedPlanV1.build(
      registry: TatwoPluginControllerRegistryDocumentV1(
        registryRevision: "s3-provenance",
        entries: [
          TatwoPluginRegistryEntryV1(
            id: "alpha",
            type: .portableMcp,
            desiredState: .enabled,
            canonicalDefinition: TatwoPluginCanonicalMcpDefinitionV1(
              protocolName: "mcp",
              transport: .stdio,
              command: "alpha",
              args: []),
            projectionTemplates: [
              "codex": TatwoPluginProjectionTemplateRefV1(templateID: "codex.mcp-server.v1")
            ])
        ],
        source: "os_registry"),
      brands: [.codex],
      codexServers: [observed],
      ownershipRecords: receipt.ownershipRecords + rollback.ownershipRecordsAfter)
    XCTAssertEqual(rebuiltWithActiveFirst.items.first?.action, .conflict)
  }

  // MARK: Helpers

  private func authToken(
    for plan: TatwoPluginStagedPlanDocumentV1,
    target: URL
  ) throws -> TatwoPluginApplyAuthorizationV1 {
    let digest = TatwoPluginApplyEngineV1.planDigest(plan)
    return TatwoPluginApplyAuthorizationV1(
      approvedPlanDigest: digest,
      approvedTargetPath: target.path,
      approvedBrand: .codex,
      approver: "human@test",
      approvedAt: "2026-07-30T12:00:00Z")
  }

  private func authToken(
    for plan: TatwoPluginStagedPlanDocumentV1,
    targets: [URL]
  ) throws -> TatwoPluginApplyAuthorizationV1 {
    TatwoPluginApplyAuthorizationV1(
      approvedTargetPaths: targets.map(\.path),
      approvedPlanDigest: TatwoPluginApplyEngineV1.planDigest(plan),
      approvedBrand: .codex,
      approver: "human@test",
      approvedAt: "2026-07-30T12:00:00Z")
  }

  private func makePlan(
    revision: String,
    items: [TatwoPluginStagedPlanItemV1]
  ) -> TatwoPluginStagedPlanDocumentV1 {
    TatwoPluginStagedPlanDocumentV1(
      registryRevision: revision,
      brands: [.codex],
      items: items)
  }

  private func makeItem(
    id: String,
    action: TatwoPluginStagedPlanActionV1,
    body: String,
    observed: String? = nil,
    desired: String? = nil
  ) -> TatwoPluginStagedPlanItemV1 {
    TatwoPluginStagedPlanItemV1(
      entryID: id,
      entryType: .portableMcp,
      brand: .codex,
      action: action,
      logicalPath: "~/.codex/config.toml#mcp_servers.\(id)",
      templateID: "codex.mcp-server.v1",
      projectedBody: body,
      observedManagedText: observed,
      desiredManagedText: desired
        ?? "serverID=\(id)\ntransport=stdio\ncommand=\(id)\nargs=[]\n",
      unifiedDiff: action == .unchanged ? "" : "diff",
      requiresHumanGate: true,
      reason: action.rawValue)
  }

  private func codexBody(id: String, command: String) -> String {
    """
    [mcp_servers.\(id)]
    command = "\(command)"
    transport = "stdio"
    """
  }

  private func journalFixtureLine(
    transactionID: String,
    phase: String,
    targetPath: String? = nil,
    tempPath: String? = nil,
    backupPath: String? = nil,
    existed: Bool? = nil,
    beforeSHA256: String? = nil,
    expectedSHA256: String? = nil,
    occurredAt: String = "2026-07-30T12:00:00Z",
    chainDigest: String,
    transactionAuthorizationDigest: String,
    authorizationTargetPaths: [String]
  ) throws -> Data {
    let value = JournalFixtureRecord(
      schema: "TatwoPluginApplyJournalV1",
      transactionID: transactionID,
      phase: phase,
      targetPath: targetPath.map(TatwoPluginApplyEngineV1.canonicalTargetPath),
      tempPath: tempPath.map(TatwoPluginApplyEngineV1.canonicalTargetPath),
      backupPath: backupPath.map(TatwoPluginApplyEngineV1.canonicalTargetPath),
      existed: existed,
      beforeSHA256: beforeSHA256,
      expectedSHA256: expectedSHA256,
      occurredAt: occurredAt,
      chainDigest: chainDigest,
      transactionAuthorizationDigest: transactionAuthorizationDigest,
      authorizationTargetPaths: authorizationTargetPaths.map(TatwoPluginApplyEngineV1.canonicalTargetPath))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}

private struct JournalFixtureRecord: Codable {
  let schema: String
  let transactionID: String
  let phase: String
  let targetPath: String?
  let tempPath: String?
  let backupPath: String?
  let existed: Bool?
  let beforeSHA256: String?
  let expectedSHA256: String?
  let occurredAt: String
  let chainDigest: String
  let transactionAuthorizationDigest: String
  let authorizationTargetPaths: [String]
}

// MARK: - Corrupting IO (write succeeds but corrupts target content)

private final class CorruptingApplyFileIO: TatwoPluginApplyFileIO, @unchecked Sendable {
  private let inner: TatwoPluginDefaultApplyFileIO
  /// Skip corrupting the first write (backup copy path uses copyItem).
  private var writeCount = 0

  init(inner: TatwoPluginDefaultApplyFileIO) {
    self.inner = inner
  }

  func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
  func readData(from url: URL) throws -> Data { try inner.readData(from: url) }
  func copyItem(at source: URL, to destination: URL) throws {
    try inner.copyItem(at: source, to: destination)
  }
  func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
  func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }

  func writeAtomically(_ data: Data, to url: URL) throws {
    writeCount += 1
    // First writeAtomically in apply is the target write after backup.
    // Corrupt so read-back hash fails; later restore writes must be clean.
    if writeCount == 1 {
      let garbage = Data("# corrupted by test IO\nnot-a-valid-mcp-table\n".utf8)
      try inner.writeAtomically(garbage, to: url)
    } else {
      try inner.writeAtomically(data, to: url)
    }
  }
}

private final class FaultInjectingApplyFileIO: TatwoPluginApplyFileIO, @unchecked Sendable {
  private let inner: TatwoPluginDefaultApplyFileIO
  private let failTempWrite: Bool
  private let failRenameAt: Int?
  private var renameCount = 0

  init(
    inner: TatwoPluginDefaultApplyFileIO = TatwoPluginDefaultApplyFileIO(),
    failTempWrite: Bool = false,
    failRenameAt: Int? = nil
  ) {
    self.inner = inner
    self.failTempWrite = failTempWrite
    self.failRenameAt = failRenameAt
  }

  func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
  func readData(from url: URL) throws -> Data { try inner.readData(from: url) }
  func copyItem(at source: URL, to destination: URL) throws {
    try inner.copyItem(at: source, to: destination)
  }
  func copyItemExclusively(at source: URL, to destination: URL) throws {
    try inner.copyItemExclusively(at: source, to: destination)
  }
  func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
  func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }

  func writeAtomically(_ data: Data, to url: URL) throws {
    if failTempWrite, url.lastPathComponent.contains(".tatwo-apply-") {
      throw NSError(domain: "FaultInjectingApplyFileIO", code: 1)
    }
    try inner.writeAtomically(data, to: url)
  }

  func renameItem(at source: URL, to destination: URL) throws {
    defer { renameCount += 1 }
    if let failRenameAt, renameCount == failRenameAt {
      throw NSError(domain: "FaultInjectingApplyFileIO", code: 2)
    }
    try inner.renameItem(at: source, to: destination)
  }
}

private final class CorruptingTargetReadbackFileIO: TatwoPluginApplyFileIO, @unchecked Sendable {
  private let inner: TatwoPluginDefaultApplyFileIO
  private let targetPath: String
  private var corrupted = false
  private var committed = false

  init(inner: TatwoPluginDefaultApplyFileIO, targetPath: String) {
    self.inner = inner
    self.targetPath = TatwoPluginApplyEngineV1.canonicalTargetPath(targetPath)
  }

  func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
  func copyItem(at source: URL, to destination: URL) throws {
    try inner.copyItem(at: source, to: destination)
  }
  func copyItemExclusively(at source: URL, to destination: URL) throws {
    try inner.copyItemExclusively(at: source, to: destination)
  }
  func writeAtomically(_ data: Data, to url: URL) throws {
    try inner.writeAtomically(data, to: url)
  }
  func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
  func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
  func renameItem(at source: URL, to destination: URL) throws {
    try inner.renameItem(at: source, to: destination)
    if TatwoPluginApplyEngineV1.canonicalTargetPath(destination.path) == targetPath {
      committed = true
    }
  }

  func readData(from url: URL) throws -> Data {
    let data = try inner.readData(from: url)
    guard committed, !corrupted,
      TatwoPluginApplyEngineV1.canonicalTargetPath(url.path) == targetPath else {
      return data
    }
    corrupted = true
    return data + Data("corrupt".utf8)
  }
}
