import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
import LocalAuthentication
#endif

@testable import TatwoUltraworkCore

final class TatwoPLGEventChainTests: XCTestCase {
  func testFormalLocalInternalBundleUsesIsolatedAnchorIdentity() {
    let configuration = TatwoPLGChainStore.helperRuntimeConfiguration(
      bundleIdentifier: "com.tatwo.ultrawork",
      infoDictionary: [
        "TatwoBuildClass": "local-internal",
        "TatwoDistributionReady": false,
      ],
      environment: [:])

    XCTAssertEqual(
      configuration.service,
      "ai.tatwo.ultrawork.plg-chain-anchor.local-internal.v1")
    XCTAssertEqual(configuration.account, "stable-helper-v1")
    XCTAssertEqual(
      configuration.chainDirectoryName,
      "plg-event-chains-local-internal-v1")
  }

  func testDistributionReadyFormalBundleKeepsProductionAnchorIdentity() {
    let configuration = TatwoPLGChainStore.helperRuntimeConfiguration(
      bundleIdentifier: "com.tatwo.ultrawork",
      infoDictionary: [
        "TatwoBuildClass": "production-intent",
        "TatwoDistributionReady": true,
      ],
      environment: [:])

    XCTAssertEqual(
      configuration.service,
      "ai.tatwo.ultrawork.plg-chain-anchor.production.v3")
    XCTAssertEqual(configuration.account, "stable-helper-v1")
    XCTAssertEqual(configuration.chainDirectoryName, "plg-event-chains-v3")
  }

  func testKeychainAnchorConfigurationCanBeIsolatedByEnvironment() {
    let configuration = TatwoPLGKeychainAnchorAuthority.configuration(
      environment: [
        "TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE":
          "ai.tatwo.ultrawork.plg-chain-anchor.staging",
        "TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT": "staging-host-v1",
      ])

    XCTAssertEqual(
      configuration.service,
      "ai.tatwo.ultrawork.plg-chain-anchor.staging")
    XCTAssertEqual(configuration.account, "staging-host-v1")
  }

  #if canImport(Security)
  func testKeychainAnchorReadQueryNeverWaitsForAuthenticationUI() {
    let query = TatwoPLGKeychainAnchorAuthority.readQuery(
      service: "ai.tatwo.test-anchor",
      account: "test-host")

    let context = try? XCTUnwrap(
      query[kSecUseAuthenticationContext as String] as? LAContext)
    XCTAssertEqual(context?.interactionNotAllowed, true)
  }

  func testKeychainAnchorAddQueryNeverWaitsForAuthenticationUI() {
    let query = TatwoPLGKeychainAnchorAuthority.addQuery(
      service: "ai.tatwo.test-anchor",
      account: "test-host",
      key: Data(repeating: 0x5a, count: 32))

    let context = try? XCTUnwrap(
      query[kSecUseAuthenticationContext as String] as? LAContext)
    XCTAssertEqual(context?.interactionNotAllowed, true)
    XCTAssertEqual(
      query[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }

  func testKeychainOperationReturnsTimeoutInsteadOfWaitingForever() {
    let startedAt = Date()

    XCTAssertThrowsError(
      try TatwoPLGKeychainAnchorAuthority.performWithTimeout(
        seconds: 0.02
      ) {
        Thread.sleep(forTimeInterval: 0.25)
        return OSStatus(errSecSuccess)
      }
    ) { error in
      XCTAssertEqual(error as? TatwoPLGAnchorError, .timeout)
    }

    XCTAssertLessThan(
      Date().timeIntervalSince(startedAt),
      0.22,
      "timeout must still return before the injected 0.25 second operation finishes")
  }

  func testLegacyKeychainReadTimeoutRemainsShortAndFailClosed() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/TatwoUltraworkCore/TatwoPLGEventChain.swift"),
      encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        "private static let readTimeoutSeconds: TimeInterval = 1"))
    XCTAssertTrue(
      source.contains(
        "private static let writeTimeoutSeconds: TimeInterval = 1"))
    XCTAssertTrue(
      source.contains(
        "seconds: Self.writeTimeoutSeconds"))
  }

  func testStableHelperAnchorSignsAndVerifiesWithoutExposingKeyMaterial() throws {
    let helper = try executableScript(
      """
      #!/bin/sh
      input="$(cat)"
      printf 'tatwo-helper|%s' "$input" | shasum -a 256 | awk '{print $1}'
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      // Match the production helper budget. Under a full --jobs 2 gate this
      // fixture launches /bin/sh + cat + shasum + awk three times; a one-second
      // test-only override can expire from scheduler pressure even though the
      // production three-second fail-closed deadline remains healthy.
      timeoutSeconds: 3)

    let signature = try authority.sign("plan|loops|goal")

    XCTAssertEqual(signature.count, 64)
    XCTAssertTrue(try authority.verify(signature, material: "plan|loops|goal"))
    XCTAssertFalse(try authority.verify(signature, material: "different"))
  }

  func testStableHelperAnchorUsesPOSIXUserHomeWhenAppHomeIsIsolated() throws {
    #if canImport(Darwin)
    let password = try XCTUnwrap(getpwuid(getuid()))
    let posixHome = String(cString: password.pointee.pw_dir)
    let originalHome = getenv("HOME").map { String(cString: $0) }
    let isolatedHome = temporaryDirectory().appendingPathComponent("isolated-home")
    try FileManager.default.createDirectory(
      at: isolatedHome,
      withIntermediateDirectories: true)
    XCTAssertEqual(setenv("HOME", isolatedHome.path, 1), 0)
    defer {
      if let originalHome {
        _ = setenv("HOME", originalHome, 1)
      } else {
        unsetenv("HOME")
      }
    }

    let helper = try executableScript(
      """
      #!/bin/sh
      test "$HOME" = \(shellQuoted(posixHome)) || exit 42
      input="$(cat)"
      printf 'tatwo-helper|%s' "$input" | shasum -a 256 | awk '{print $1}'
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      timeoutSeconds: 3)

    XCTAssertEqual(try authority.sign("isolated-app-home").count, 64)
    #else
    throw XCTSkip("POSIX user-home lookup requires Darwin")
    #endif
  }

  func testStableHelperAnchorAppliesScopedIdentityOverrides() throws {
    let helper = try executableScript(
      """
      #!/bin/sh
      test "$TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE" = \
        "ai.tatwo.ultrawork.plg-chain-anchor.local-internal.v1" || exit 43
      test "$TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT" = \
        "stable-helper-v1" || exit 44
      input="$(cat)"
      printf 'tatwo-helper|%s' "$input" | shasum -a 256 | awk '{print $1}'
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      timeoutSeconds: 3,
      environmentOverrides: [
        "TATWO_ULTRAWORK_PLG_ANCHOR_SERVICE":
          "ai.tatwo.ultrawork.plg-chain-anchor.local-internal.v1",
        "TATWO_ULTRAWORK_PLG_ANCHOR_ACCOUNT": "stable-helper-v1",
      ])

    XCTAssertEqual(try authority.sign("local-internal").count, 64)
  }

  func testStableHelperAnchorTerminatesAndFailsClosedOnTimeout() throws {
    let helper = try executableScript(
      """
      #!/bin/sh
      sleep 5
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      timeoutSeconds: 0.05)
    let startedAt = Date()

    XCTAssertThrowsError(try authority.sign("blocked")) { error in
      XCTAssertEqual(error as? TatwoPLGAnchorError, .timeout)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
  }

  func testStableHelperAnchorTimeoutAlsoBoundsAHelperThatNeverReadsLargeInput() throws {
    let helper = try executableScript(
      """
      #!/bin/sh
      sleep 5
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      timeoutSeconds: 0.05)
    let material = String(repeating: "x", count: 64 * 1024)
    let startedAt = Date()

    XCTAssertThrowsError(try authority.sign(material)) { error in
      XCTAssertEqual(error as? TatwoPLGAnchorError, .timeout)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
  }

  func testStableHelperAnchorDisablesSIGPIPEBeforeWritingToTheHelper() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/TatwoUltraworkCore/TatwoPLGEventChain.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("F_SETNOSIGPIPE"))
    XCTAssertTrue(source.contains("inputSucceeded.load() == true"))
  }

  func testStableHelperAnchorRejectsAHelperThatDoesNotMatchTheRuntimePin() throws {
    let helper = try executableScript(
      """
      #!/bin/sh
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      """)
    let authority = TatwoPLGHelperAnchorAuthority(
      helperURL: helper,
      timeoutSeconds: 1,
      expectedExecutableSHA256: String(repeating: "0", count: 64))

    XCTAssertThrowsError(try authority.sign("material")) { error in
      XCTAssertEqual(error as? TatwoPLGAnchorError, .unavailable)
    }
  }
  #endif

  func testConcurrentStoreInstancesSerializeOneCanonicalSuccessor() throws {
    let directory = temporaryDirectory()
    let authority = CoordinatedTestAnchorAuthority()
    let firstStore = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: authority)
    let secondStore = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: authority)
    let run = executingRun()
    try firstStore.begin(run: run)

    let firstTransition = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .blocked,
      reason: "first concurrent successor",
      nowISO: "2026-07-15T14:20:00Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    let secondTransition = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .blocked,
      reason: "second concurrent successor",
      nowISO: "2026-07-15T14:20:01Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let results = ChainRaceResults()

    for (store, transition) in [
      (firstStore, firstTransition),
      (secondStore, secondTransition)
    ] {
      group.enter()
      DispatchQueue.global().async {
        ready.signal()
        start.wait()
        do {
          _ = try store.append(transition: transition, from: run)
          results.recordSuccess()
        } catch {
          results.record(error)
        }
        group.leave()
      }
    }

    ready.wait()
    ready.wait()
    start.signal()
    start.signal()
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

    let outcomes = results.snapshot()
    XCTAssertEqual(outcomes.filter { $0 == "success" }.count, 1)
    XCTAssertEqual(
      outcomes.filter {
        $0 == "error=\(TatwoPLGChainStoreError.expectedRunMismatch)"
      }.count,
      1)

    do {
      let replay = try firstStore.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id)
      XCTAssertEqual(replay.run.revision, run.revision + 1)
      XCTAssertEqual(replay.appliedEventIDs.count, 1)
    } catch {
      XCTFail("Concurrent append left a non-replayable chain: \(error)")
    }
  }

  func testReplayRejectsInteriorBlankPhysicalLineAtExactLine() throws {
    let directory = temporaryDirectory()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: TestAnchorAuthority())
    let run = executingRun()
    try store.begin(run: run)
    let transition = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .blocked,
      reason: "blank-line test",
      nowISO: "2026-07-15T14:25:00Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    _ = try store.append(transition: transition, from: run)

    let url = store.storageURL(
      contractID: run.contractID,
      goalID: run.goalID,
      runID: run.id)
    var contents = try String(contentsOf: url, encoding: .utf8)
    let firstNewline = try XCTUnwrap(contents.firstIndex(of: "\n"))
    contents.insert("\n", at: contents.index(after: firstNewline))
    try contents.write(to: url, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try store.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPLGChainStoreError,
        .malformedLine(2))
    }
  }

  func testKeychainVerificationLoadsWithoutCreatingMissingKey() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/TatwoUltraworkCore/TatwoPLGEventChain.swift"),
      encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "public func verify(_ signature: String, material: String) throws -> Bool {"))
    let end = try XCTUnwrap(
      source.range(
        of: "  private func constantTimeEqual",
        range: start.upperBound..<source.endIndex))
    let verifySource = String(source[start.lowerBound..<end.lowerBound])

    XCTAssertTrue(verifySource.contains("keyData(createIfMissing: false)"))
    XCTAssertFalse(verifySource.contains("try sign(material)"))
  }

  func testReplayUniqueDiscoversChainWhenCachedRunIDIsMissingOrStale() throws {
    let directory = temporaryDirectory()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: TestAnchorAuthority())
    let run = executingRun()
    try store.begin(run: run)

    let replay = try store.replayUnique(
      contractID: run.contractID,
      goalID: run.goalID,
      preferredRunID: UUID())

    XCTAssertEqual(replay.run.id, run.id)
    XCTAssertEqual(replay.run.revision, run.revision)
    XCTAssertTrue(replay.run.hasTrustedAuthority)
  }

  func testReplayUniqueFailsClosedWhenGoalHasMultipleChains() throws {
    let directory = temporaryDirectory()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: TestAnchorAuthority())
    let first = executingRun()
    var second = first
    second.id = UUID()
    try store.begin(run: first)
    try store.begin(run: second)

    XCTAssertThrowsError(
      try store.replayUnique(
        contractID: first.contractID,
        goalID: first.goalID,
        preferredRunID: first.id)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPLGChainStoreError,
        .ambiguousChain)
    }
  }

  func testGenuinePassSurvivesAnchoredReplayWhileDecodedProjectionDoesNot() throws {
    let directory = temporaryDirectory()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: TestAnchorAuthority())
    let run = executingRun()
    try store.begin(run: run)

    let transition = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: run.branchGoals[0]),
      nowISO: "2026-07-15T14:30:00Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    let appended = try store.append(
      transition: transition,
      from: run)

    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: appended.run.branchGoals[0],
        in: appended.run),
      .pass)
    XCTAssertEqual(appended.appliedEventIDs, [transition.event.eventID])

    let decodedProjection = try JSONDecoder().decode(
      TatwoPLGRun.self,
      from: JSONEncoder().encode(appended.run))
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: decodedProjection.branchGoals[0],
        in: decodedProjection),
      .blocked)

    let replayed = try store.replay(
      contractID: run.contractID,
      goalID: run.goalID,
      runID: run.id)
    XCTAssertEqual(replayed.run, appended.run)
    XCTAssertEqual(replayed.appliedEventIDs, [transition.event.eventID])
    XCTAssertEqual(
      TatwoPLGOrchestrator.receiptPresentation(
        for: replayed.run.branchGoals[0],
        in: replayed.run),
      .pass)
  }

  func testChainTamperAndMissingAnchorFailClosed() throws {
    let directory = temporaryDirectory()
    let authority = TestAnchorAuthority()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: authority)
    let run = executingRun()
    try store.begin(run: run)
    let transition = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .passed,
      reason: nil,
      domainReceipt: validDomainReceipt(for: run.branchGoals[0]),
      nowISO: "2026-07-15T14:31:00Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    _ = try store.append(transition: transition, from: run)

    let url = store.storageURL(
      contractID: run.contractID,
      goalID: run.goalID,
      runID: run.id)
    let original = try String(contentsOf: url, encoding: .utf8)

    let tampered = original.replacingOccurrences(
      of: transition.event.eventID.uuidString,
      with: UUID().uuidString)
    XCTAssertNotEqual(tampered, original)
    try tampered.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(
      try store.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id))

    try original
      .replacingOccurrences(of: "\"anchorMAC\":\"", with: "\"anchorMAC\":\"missing-")
      .write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(
      try store.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id))
  }

  func testDuplicateEventIDAndReorderedRevisionFailClosed() throws {
    let directory = temporaryDirectory()
    let store = TatwoPLGChainStore(
      directory: directory,
      anchorAuthority: TestAnchorAuthority())
    let run = executingRun()
    try store.begin(run: run)
    let first = try TatwoPLGOrchestrator.reportBranch(
      id: run.branchGoals[0].id,
      status: .blocked,
      reason: "first",
      nowISO: "2026-07-15T14:32:00Z",
      in: run,
      expectedRevision: run.revision,
      eventID: UUID())
    let firstReplay = try store.append(transition: first, from: run)
    let second = try TatwoPLGOrchestrator.replanBranch(
      id: firstReplay.run.branchGoals[0].id,
      reason: "second",
      deadlineISO: nil,
      nowISO: "2026-07-15T14:33:00Z",
      in: firstReplay.run,
      expectedRevision: firstReplay.run.revision,
      eventID: UUID())
    _ = try store.append(transition: second, from: firstReplay.run)

    let url = store.storageURL(
      contractID: run.contractID,
      goalID: run.goalID,
      runID: run.id)
    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    XCTAssertEqual(lines.count, 3)

    try ([lines[0], lines[2], lines[1]].joined(separator: "\n") + "\n")
      .write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(
      try store.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id))

    try ([lines[0], lines[1], lines[1]].joined(separator: "\n") + "\n")
      .write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(
      try store.replay(
        contractID: run.contractID,
        goalID: run.goalID,
        runID: run.id))
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-plg-chain-\(UUID().uuidString)")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func executableScript(_ contents: String) throws -> URL {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("helper.sh")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path)
    return url
  }

  private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func executingRun() -> TatwoPLGRun {
    let sourceLoopID = "source-loop-chain"
    let domainLoopID = TatwoPLGOrchestrator.makeDomainLoopID(
      contractID: "contract-chain",
      domain: .code,
      sourceLoopID: sourceLoopID)
    return TatwoPLGRun(
      goalID: "goal-chain",
      contractID: "contract-chain",
      revision: 0,
      phase: .executingLoops,
      leadBindings: [binding(id: "lead", identity: .lead)],
      subBindings: [binding(id: "sub", identity: .sub)],
      planSummary: "Anchored PLG replay",
      adversarialConclusion: "reviewed",
      humanAuth: TatwoPLGHumanAuthReceipt(
        receiptID: "human-chain",
        actor: "human",
        issuedISO: "2026-07-15T14:00:00Z",
        expiresISO: "2026-07-15T16:00:00Z",
        scope: "execute",
        contractID: "contract-chain"),
      branchGoals: [
        TatwoPLGBranchGoal(
          objective: "Chain branch",
          subLabel: "sub",
          subBindingID: "sub",
          status: .planned,
          reason: nil,
          attempt: 0,
          deadlineISO: nil,
          reportedToMainline: false,
          domainLoopID: domainLoopID,
          domain: .code,
          sourceLoopID: sourceLoopID,
          ownerIdentity: .sub,
          planSlice: "[code] anchored replay",
          domainReceipt: nil)
      ],
      mainlineGoalMet: nil)
  }

  private func validDomainReceipt(
    for branch: TatwoPLGBranchGoal
  ) -> TatwoPLGDomainReceipt {
    let tests = ["swift test --filter TatwoPLGEventChainTests"]
    return TatwoPLGDomainReceipt(
      domainLoopID: branch.domainLoopID ?? "",
      objectiveHash: TatwoObjectiveIdentity.make(branch.objective).objectiveHash,
      inputsDigest: TatwoArtifactReviewHasher.sha256(branch.planSlice ?? ""),
      artifactsDigest: TatwoPLGOrchestrator.makeArtifactsDigest(testsRun: tests),
      verdict: .pass,
      testsRun: tests)
  }

  private func binding(
    id: String,
    identity: IdentityKind
  ) -> WorkOSIdentityBinding {
    WorkOSIdentityBinding(
      id: id,
      identity: identity,
      label: id,
      engineID: nil,
      modelID: "model-\(id)",
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "slot-\(id)",
      bindingRule: "test")
  }
}

private struct TestAnchorAuthority: TatwoPLGAnchorAuthority {
  func sign(_ material: String) throws -> String {
    TatwoArtifactReviewHasher.sha256("test-anchor|\(material)")
  }

  func verify(_ signature: String, material: String) throws -> Bool {
    signature == (try sign(material))
  }
}

private final class CoordinatedTestAnchorAuthority:
  TatwoPLGAnchorAuthority,
  @unchecked Sendable
{
  private let condition = NSCondition()
  private var eventSigners = 0

  func sign(_ material: String) throws -> String {
    if material.contains("|event|") {
      condition.lock()
      eventSigners += 1
      if eventSigners < 2 {
        _ = condition.wait(until: Date().addingTimeInterval(0.25))
      } else {
        condition.broadcast()
      }
      condition.unlock()
    }
    return signature(for: material)
  }

  func verify(_ signature: String, material: String) throws -> Bool {
    signature == self.signature(for: material)
  }

  private func signature(for material: String) -> String {
    TatwoArtifactReviewHasher.sha256("coordinated-anchor|\(material)")
  }
}

private final class ChainRaceResults: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [String] = []

  func recordSuccess() {
    record("success")
  }

  func record(_ error: Error) {
    record("error=\(error)")
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return outcomes
  }

  private func record(_ outcome: String) {
    lock.lock()
    outcomes.append(outcome)
    lock.unlock()
  }
}
