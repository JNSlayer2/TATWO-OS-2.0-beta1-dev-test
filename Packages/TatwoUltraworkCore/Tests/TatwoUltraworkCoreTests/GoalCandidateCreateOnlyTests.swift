import CryptoKit
import XCTest

@testable import TatwoUltraworkCore

final class GoalCandidateCreateOnlyTests: XCTestCase {
  private func makeFixture() throws -> (root: URL, store: TatwoGoalRunStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-candidate-create-only-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, TatwoGoalRunStore(directoryURL: root))
  }

  private func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }

  private struct AuthorizationRequest {
    let sha256: String
    let json: String
    let contract: TatwoWorkOSContractV1
    let scenarioEvidence: TatwoScenarioConfigReadOnlyEvidenceV1
    let preflight: TatwoGoalCandidateStorePreflightV1
  }

  private func canonicalJSONSHA256<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return sha256(try encoder.encode(value))
  }

  private func makeAuthorizationRequest(
    store: TatwoGoalRunStore,
    mode: WorkModeID = .xxl,
    scenario: String = "coding",
    objective: String,
    book: TatwoScenarioConfigBookV1 =
      TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults(),
    operationNonce: String? = nil,
    mutateArtifact: ((inout [String: Any]) -> Void)? = nil
  ) throws -> AuthorizationRequest {
    let scenarioEvidence =
      try TatwoScenarioConfigReadOnlyEvidenceV1.projectedOverride(book)
    let contract = try WorkOSFactory.preview(
      mode: mode,
      scenarioProfileID: scenario,
      objective: objective,
      scenarioBook: scenarioEvidence.book)
    let issuedIdentityBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    let preflight = try store.preflightCandidateCreate(
      contractID: contract.contractID)
    let artifact = TatwoGoalCandidateCreateAuthorizationBindingV1(
      operationNonce: operationNonce ?? "operation-\(UUID().uuidString)",
      mode: contract.mode.rawValue,
      scenario: contract.scenario,
      objectiveSHA256: sha256(Data(contract.objective.utf8)),
      scenarioConfigStableHash: scenarioEvidence.book.stableHash,
      scenarioConfigSourceKind: scenarioEvidence.sourceKind,
      scenarioConfigRawSHA256: scenarioEvidence.scenarioConfigRawSHA256,
      contractID: contract.contractID,
      goalID: contract.goalID,
      issuedIdentityBindingsDigest:
        TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: issuedIdentityBindings),
      projectedContractCanonicalJSONSHA256:
        try canonicalJSONSHA256(contract),
      issuedIdentityBindingsCanonicalJSONSHA256:
        try canonicalJSONSHA256(issuedIdentityBindings),
      goalStorePreflightCanonicalManifestSHA256:
        preflight.canonicalManifestSHA256,
      targetJSONPath: preflight.targetJSONPath,
      targetLockPath: preflight.targetLockPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var artifactObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(artifact))
        as? [String: Any])
    mutateArtifact?(&artifactObject)
    let artifactBytes = try JSONSerialization.data(
      withJSONObject: artifactObject,
      options: [.sortedKeys])
    return AuthorizationRequest(
      sha256: sha256(artifactBytes),
      json: try XCTUnwrap(String(data: artifactBytes, encoding: .utf8)),
      contract: contract,
      scenarioEvidence: scenarioEvidence,
      preflight: preflight)
  }

  private func createCandidate(
    store: TatwoGoalRunStore,
    objective: String,
    request: AuthorizationRequest? = nil
  ) throws -> TatwoGoalCandidateCreateOnlyResultV1 {
    let request = try request ?? makeAuthorizationRequest(
      store: store,
      objective: objective)
    return try WorkOSFactory.createGoalCandidateOnly(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: objective,
      authorizationBindingArtifactSHA256: request.sha256,
      authorizationBindingArtifactJSON: request.json,
      scenarioConfigSourceKind: request.scenarioEvidence.sourceKind,
      scenarioConfigRawSHA256:
        request.scenarioEvidence.scenarioConfigRawSHA256,
      scenarioBook: request.scenarioEvidence.book,
      store: store)
  }

  private func assertZeroDeltaFailure(
    root: URL,
    store: TatwoGoalRunStore,
    objective: String,
    request: AuthorizationRequest,
    expectedErrorFragment: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let before = try directoryManifest(root)
    XCTAssertThrowsError(
      try createCandidate(
        store: store,
        objective: objective,
        request: request),
      file: file,
      line: line
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(expectedErrorFragment),
        "\(error)",
        file: file,
        line: line)
    }
    XCTAssertEqual(
      try directoryManifest(root),
      before,
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: request.preflight.targetLockPath),
      file: file,
      line: line)
  }

  private func encodedScenarioBook(_ book: TatwoScenarioConfigBookV1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(book)
  }

  private func fileMetadata(_ url: URL) throws -> [String: String] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return [
      "size": (attributes[.size] as? NSNumber)?.stringValue ?? "missing",
      "modificationDate":
        (attributes[.modificationDate] as? Date)
        .map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "missing",
      "permissions": (attributes[.posixPermissions] as? NSNumber)?.stringValue ?? "missing",
      "inode": (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "missing",
    ]
  }

  private func directoryManifest(_ root: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { _, _ in false })
    else { return [] }
    var entries: [String] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      let relativePath = String(url.path.dropFirst(root.path.count + 1))
      if values.isDirectory == true {
        entries.append("D|\(relativePath)")
      } else {
        entries.append(
          "F|\(relativePath)|\(values.fileSize ?? -1)|\(sha256(try Data(contentsOf: url)))")
      }
    }
    return entries.sorted()
  }

  func testStrictReadOnlyScenarioConfigLoadPreservesCurrentSchemaBytesAndMetadata() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configURL = fixture.root.appendingPathComponent("scenario-config.json")
    let frozenBook = TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults()
    try encodedScenarioBook(frozenBook).write(to: configURL, options: [.withoutOverwriting])
    let store = TatwoScenarioConfigStore(fileURL: configURL)
    let beforeBytes = try Data(contentsOf: configURL)
    let beforeMetadata = try fileMetadata(configURL)
    let beforeManifest = try directoryManifest(fixture.root)

    let loaded = try store.loadStrictReadOnly()

    XCTAssertEqual(loaded.stableHash, frozenBook.stableHash)
    XCTAssertEqual(try Data(contentsOf: configURL), beforeBytes)
    XCTAssertEqual(try fileMetadata(configURL), beforeMetadata)
    XCTAssertEqual(try directoryManifest(fixture.root), beforeManifest)
  }

  func testStrictReadOnlyScenarioConfigAbsentReturnsDefaultsWithoutCreatingParent() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let missingParent = fixture.root.appendingPathComponent("missing-parent", isDirectory: true)
    let configURL = missingParent.appendingPathComponent("scenario-config.json")
    let beforeManifest = try directoryManifest(fixture.root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))

    let loaded = try TatwoScenarioConfigStore(fileURL: configURL).loadStrictReadOnly()

    XCTAssertEqual(
      loaded.stableHash,
      TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults().stableHash)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: configURL.appendingPathExtension("bak").path))
    XCTAssertEqual(try directoryManifest(fixture.root), beforeManifest)
  }

  func testStrictReadOnlyScenarioConfigDecodeFailureIsTypedAndZeroWrite() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configURL = fixture.root.appendingPathComponent("scenario-config.json")
    let corruptBytes = Data("{not-a-scenario-config".utf8)
    try corruptBytes.write(to: configURL, options: [.withoutOverwriting])
    let beforeMetadata = try fileMetadata(configURL)
    let beforeManifest = try directoryManifest(fixture.root)

    XCTAssertThrowsError(
      try TatwoScenarioConfigStore(fileURL: configURL).loadStrictReadOnly()
    ) { error in
      XCTAssertEqual(
        error as? TatwoScenarioConfigReadOnlyLoadError,
        .decodeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: configURL), corruptBytes)
    XCTAssertEqual(try fileMetadata(configURL), beforeMetadata)
    XCTAssertEqual(try directoryManifest(fixture.root), beforeManifest)
  }

  func testStrictReadOnlyScenarioConfigReadFailureIsTypedAndZeroWrite() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configURL = fixture.root.appendingPathComponent(
      "scenario-config.json",
      isDirectory: true)
    try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
    let sentinel = configURL.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel, options: [.withoutOverwriting])
    let beforeManifest = try directoryManifest(fixture.root)

    XCTAssertThrowsError(
      try TatwoScenarioConfigStore(fileURL: configURL).loadStrictReadOnly()
    ) { error in
      XCTAssertEqual(
        error as? TatwoScenarioConfigReadOnlyLoadError,
        .readFailed)
    }

    XCTAssertEqual(try directoryManifest(fixture.root), beforeManifest)
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
  }

  func testStrictReadOnlyScenarioConfigMigrationRequiredLeavesDirectoryUntouched() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configURL = fixture.root.appendingPathComponent("scenario-config.json")
    let migrationRequiredBook = TatwoScenarioConfigBookV1(scenarios: [])
    try encodedScenarioBook(migrationRequiredBook).write(
      to: configURL,
      options: [.withoutOverwriting])
    let store = TatwoScenarioConfigStore(fileURL: configURL)
    let beforeBytes = try Data(contentsOf: configURL)
    let beforeMetadata = try fileMetadata(configURL)
    let beforeManifest = try directoryManifest(fixture.root)

    XCTAssertThrowsError(try store.loadStrictReadOnly()) { error in
      XCTAssertEqual(
        error as? TatwoScenarioConfigReadOnlyLoadError,
        .migrationRequired)
    }

    XCTAssertEqual(try Data(contentsOf: configURL), beforeBytes)
    XCTAssertEqual(try fileMetadata(configURL), beforeMetadata)
    XCTAssertEqual(try directoryManifest(fixture.root), beforeManifest)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: configURL.appendingPathExtension("bak").path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .contains { $0.contains(".tmp") || $0.contains(".bak") })
    XCTAssertEqual(
      TatwoMCPRegistry.failureKind(
        for: TatwoScenarioConfigReadOnlyLoadError.migrationRequired),
      .contract)
    XCTAssertEqual(
      TatwoScenarioConfigReadOnlyLoadError.migrationRequired.localizedDescription,
      "scenario_config_migration_required")
  }

  func testMissingOrTamperedExactArtifactBytesFailBeforeGoalLock() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let objective = "artifact byte fence"
    let valid = try makeAuthorizationRequest(
      store: fixture.store,
      objective: objective)

    for (sha, json, errorFragment) in [
      ("", valid.json, "missing_authorization_binding_artifact_sha256"),
      (valid.sha256, "", "missing_authorization_binding_artifact_json"),
      (
        "sha256:\(String(repeating: "0", count: 64))",
        valid.json,
        "authorization_binding_artifact_hash_mismatch"
      ),
    ] {
      try assertZeroDeltaFailure(
        root: fixture.root,
        store: fixture.store,
        objective: objective,
        request: AuthorizationRequest(
          sha256: sha,
          json: json,
          contract: valid.contract,
          scenarioEvidence: valid.scenarioEvidence,
          preflight: valid.preflight),
        expectedErrorFragment: errorFragment)
    }
  }

  func testArtifactSchemaRouteAndSingleInvocationFenceAreZeroWrite() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let objective = "static authorization fence"
    let cases: [(String, Any, String)] = [
      (
        "schema",
        "TatwoGoalCandidateCreateAuthorizationBindingV0",
        "authorization_binding_artifact_schema_mismatch"
      ),
      (
        "route",
        "tatwo.os.begin",
        "authorization_binding_artifact_route_mismatch"
      ),
      (
        "maxInvocations",
        2,
        "authorization_binding_artifact_max_invocations_mismatch"
      ),
      (
        "unexpectedAuthority",
        "not-allowed",
        "authorization_binding_artifact_closed_world_mismatch"
      ),
    ]
    for (key, value, errorFragment) in cases {
      let request = try makeAuthorizationRequest(
        store: fixture.store,
        objective: objective
      ) { artifact in
        artifact[key] = value
      }
      try assertZeroDeltaFailure(
        root: fixture.root,
        store: fixture.store,
        objective: objective,
        request: request,
        expectedErrorFragment: errorFragment)
    }
  }

  func testOperationNonceMustBeNonEmptyAndIsBoundByExactArtifactHash() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let objective = "operation nonce fence"

    let emptyNonce = try makeAuthorizationRequest(
      store: fixture.store,
      objective: objective,
      operationNonce: " \n\t")
    try assertZeroDeltaFailure(
      root: fixture.root,
      store: fixture.store,
      objective: objective,
      request: emptyNonce,
      expectedErrorFragment:
        "authorization_binding_artifact_operation_nonce_empty")

    let nonceA = try makeAuthorizationRequest(
      store: fixture.store,
      objective: objective,
      operationNonce: "operation-nonce-a")
    let nonceB = try makeAuthorizationRequest(
      store: fixture.store,
      objective: objective,
      operationNonce: "operation-nonce-b")
    XCTAssertNotEqual(nonceA.sha256, nonceB.sha256)

    var tamperedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(nonceA.json.utf8))
        as? [String: Any])
    tamperedObject["operationNonce"] = "operation-nonce-tampered"
    let tamperedBytes = try JSONSerialization.data(
      withJSONObject: tamperedObject,
      options: [.sortedKeys])
    let tampered = AuthorizationRequest(
      sha256: nonceA.sha256,
      json: try XCTUnwrap(String(data: tamperedBytes, encoding: .utf8)),
      contract: nonceA.contract,
      scenarioEvidence: nonceA.scenarioEvidence,
      preflight: nonceA.preflight)
    try assertZeroDeltaFailure(
      root: fixture.root,
      store: fixture.store,
      objective: objective,
      request: tampered,
      expectedErrorFragment:
        "authorization_binding_artifact_hash_mismatch")
  }

  func testEveryLiveComponentMismatchIsZeroWriteAndZeroLock() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let objective = "component authorization fence"
    let cases: [(String, Any, String)] = [
      ("mode", "XL", "authorization_binding_artifact_mode_mismatch"),
      ("scenario", "ui-ux", "authorization_binding_artifact_scenario_mismatch"),
      (
        "objectiveSHA256",
        "sha256:\(String(repeating: "1", count: 64))",
        "authorization_binding_artifact_objective_mismatch"
      ),
      (
        "scenarioConfigStableHash",
        "sha256:\(String(repeating: "2", count: 64))",
        "authorization_binding_artifact_scenario_config_mismatch"
      ),
      (
        "scenarioConfigSourceKind",
        "persisted_exact_bytes",
        "authorization_binding_artifact_scenario_config_source_mismatch"
      ),
      (
        "scenarioConfigRawSHA256",
        "sha256:\(String(repeating: "3", count: 64))",
        "authorization_binding_artifact_scenario_config_raw_mismatch"
      ),
      (
        "contractID",
        "contract-xxl-coding-tampered",
        "authorization_binding_artifact_contract_mismatch"
      ),
      (
        "goalID",
        "goal-xxl-coding-tampered",
        "authorization_binding_artifact_goal_mismatch"
      ),
      (
        "issuedIdentityBindingsDigest",
        "sha256:\(String(repeating: "4", count: 64))",
        "authorization_binding_artifact_identity_bindings_mismatch"
      ),
      (
        "projectedContractCanonicalJSONSHA256",
        "sha256:\(String(repeating: "5", count: 64))",
        "authorization_binding_artifact_projected_contract_canonical_json_mismatch"
      ),
      (
        "issuedIdentityBindingsCanonicalJSONSHA256",
        "sha256:\(String(repeating: "6", count: 64))",
        "authorization_binding_artifact_identity_bindings_canonical_json_mismatch"
      ),
      (
        "storeSchema",
        "TatwoGoalRunStoreV0",
        "authorization_binding_artifact_store_schema_mismatch"
      ),
      (
        "goalStorePreflightCanonicalManifestSHA256",
        "sha256:\(String(repeating: "7", count: 64))",
        "authorization_binding_artifact_store_manifest_mismatch"
      ),
      (
        "targetJSONPath",
        "/tmp/not-authorized.json",
        "authorization_binding_artifact_target_json_path_mismatch"
      ),
      (
        "targetLockPath",
        "/tmp/not-authorized.json.lock",
        "authorization_binding_artifact_target_lock_path_mismatch"
      ),
      (
        "targetJSONMustBeAbsent",
        false,
        "authorization_binding_artifact_target_json_must_be_absent"
      ),
      (
        "targetLockMustBeAbsent",
        false,
        "authorization_binding_artifact_target_lock_must_be_absent"
      ),
      (
        "targetMustBeAbsent",
        false,
        "authorization_binding_artifact_target_must_be_absent"
      ),
    ]
    for (key, value, errorFragment) in cases {
      let request = try makeAuthorizationRequest(
        store: fixture.store,
        objective: objective
      ) { artifact in
        artifact[key] = value
      }
      try assertZeroDeltaFailure(
        root: fixture.root,
        store: fixture.store,
        objective: objective,
        request: request,
        expectedErrorFragment: errorFragment)
    }
  }

  func testGoalStoreDriftAfterArtifactPreflightFailsWithoutGoalOrLockDelta() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let objective = "store manifest drift"
    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: objective)
    let unrelated = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent("contract-unrelated.json")
    try FileManager.default.createDirectory(
      at: unrelated.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("{\"unrelated\":true}".utf8).write(
      to: unrelated,
      options: [.withoutOverwriting])

    try assertZeroDeltaFailure(
      root: fixture.root,
      store: fixture.store,
      objective: objective,
      request: request,
      expectedErrorFragment:
        "authorization_binding_artifact_store_manifest_mismatch")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: request.preflight.targetJSONPath))
  }

  func testPostPreflightRaceIsCaughtInsideTargetLockBeforeGoalJSONWrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-candidate-locked-race-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goals = root.appendingPathComponent("goals", isDirectory: true)
    try FileManager.default.createDirectory(
      at: goals,
      withIntermediateDirectories: true)
    let existingURL = goals.appendingPathComponent("contract-existing.json")
    let existingBytes = Data("{\"existing\":true}".utf8)
    try existingBytes.write(to: existingURL, options: [.withoutOverwriting])
    let driftURL = goals.appendingPathComponent("contract-race-drift.json")
    let driftBytes = Data("{\"drift\":\"after-preflight\"}".utf8)
    let store = TatwoGoalRunStore(
      directoryURL: root,
      candidateLockedPreflightHook: {
        try driftBytes.write(to: driftURL, options: [.withoutOverwriting])
      })
    let objective = "locked preflight race"
    let request = try makeAuthorizationRequest(
      store: store,
      objective: objective)

    XCTAssertThrowsError(
      try createCandidate(
        store: store,
        objective: objective,
        request: request)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .goalCandidateStorePreflightStale(request.contract.contractID))
    }

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: request.preflight.targetJSONPath))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: request.preflight.targetLockPath))
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: request.preflight.targetLockPath)),
      Data())
    XCTAssertEqual(try Data(contentsOf: existingURL), existingBytes)
    XCTAssertEqual(try Data(contentsOf: driftURL), driftBytes)
    let entries = try Set(
      FileManager.default.contentsOfDirectory(atPath: goals.path))
    XCTAssertEqual(
      entries,
      [
        existingURL.lastPathComponent,
        driftURL.lastPathComponent,
        URL(fileURLWithPath: request.preflight.targetLockPath).lastPathComponent,
      ])
  }

  func testGoalStoreManifestEnumerationFailureIsTypedAndCreatesNoTargetLock() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let goals = fixture.root.appendingPathComponent("goals", isDirectory: true)
    let blocked = goals.appendingPathComponent("blocked", isDirectory: true)
    try FileManager.default.createDirectory(
      at: blocked,
      withIntermediateDirectories: true)
    try Data("unreadable".utf8).write(
      to: blocked.appendingPathComponent("sentinel"),
      options: [.withoutOverwriting])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: blocked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: blocked.path)
    }
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "manifest enumeration failure")
    let targetURL = try fixture.store.fileURL(
      forContractID: contract.contractID)

    XCTAssertThrowsError(
      try fixture.store.preflightCandidateCreate(
        contractID: contract.contractID)
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(
          "goal_candidate_store_preflight_read_failed"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: targetURL.appendingPathExtension("lock").path))
  }

  func testFirstCreatePersistsOnlyFreshPlannedGoalTrackerCandidate() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: "fresh strict candidate")
    let result = try createCandidate(
      store: fixture.store,
      objective: "fresh strict candidate",
      request: request)

    XCTAssertEqual(result.storeDisposition.disposition, .created)
    XCTAssertEqual(result.storeDisposition.record.contractID, result.contract.contractID)
    XCTAssertEqual(result.storeDisposition.record.goalID, result.contract.goalID)
    XCTAssertEqual(result.storeDisposition.record.status, .planned)
    XCTAssertEqual(result.storeDisposition.record.receipts.map(\.receiptID), ["goal-tracker"])
    XCTAssertEqual(result.storeDisposition.record.receipts.map(\.kind), ["goal_tracker"])
    XCTAssertEqual(
      result.storeDisposition.record.receipts.first?
        .authorizationBindingArtifactSHA256,
      request.sha256)
    XCTAssertNil(result.storeDisposition.record.revision)
    XCTAssertEqual(result.candidateResolvedRevision, 1)
    XCTAssertEqual(
      try fixture.store.record(forContractID: result.contract.contractID),
      result.storeDisposition.record)
    let recordURL = try fixture.store.fileURL(forContractID: result.contract.contractID)
    XCTAssertEqual(
      result.storeDisposition.persistedBytesSHA256,
      sha256(try Data(contentsOf: recordURL)))
    XCTAssertEqual(
      result.route,
      TatwoGoalCandidateCreateAuthorizationBindingV1.createRoute)
    XCTAssertEqual(
      result.authorizationFenceSchema,
      TatwoGoalCandidateCreateAuthorizationBindingV1.currentSchema)
    XCTAssertEqual(
      result.handlerFenceVersion,
      "TatwoGoalCandidateCreateHandlerFenceV1")
    XCTAssertEqual(result.authorizationBindingArtifactSHA256, request.sha256)
    XCTAssertEqual(
      result.storePreflight.canonicalManifestSHA256,
      request.preflight.canonicalManifestSHA256)
  }

  func testSameDeterministicIDCollisionFailsWithoutChangingDurableBytes() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: "collision must not refresh")
    let first = try createCandidate(
      store: fixture.store,
      objective: "collision must not refresh",
      request: request)
    let recordURL = try fixture.store.fileURL(forContractID: first.contract.contractID)
    let beforeRecord = try Data(contentsOf: recordURL)
    let beforeLock = try Data(contentsOf: recordURL.appendingPathExtension("lock"))

    XCTAssertThrowsError(
      try createCandidate(
        store: fixture.store,
        objective: "collision must not refresh",
        request: request)
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(
          "authorization_binding_artifact_store_manifest_mismatch")
          || error.localizedDescription.contains(
            "authorization_binding_artifact_target_store_mismatch"))
    }

    XCTAssertEqual(try Data(contentsOf: recordURL), beforeRecord)
    XCTAssertEqual(try Data(contentsOf: recordURL.appendingPathExtension("lock")), beforeLock)
  }

  func testPreexistingZeroByteOccupantFailsWithoutOverwriteOrLockCreation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "zero byte occupant")
    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: "zero byte occupant")
    let recordURL = try fixture.store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: recordURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data().write(to: recordURL, options: [.withoutOverwriting])
    let before = try Data(contentsOf: recordURL)
    let lockURL = recordURL.appendingPathExtension("lock")
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))

    XCTAssertThrowsError(
      try createCandidate(
        store: fixture.store,
        objective: "zero byte occupant",
        request: request)
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(
          "authorization_binding_artifact_store_manifest_mismatch")
          || error.localizedDescription.contains(
            "authorization_binding_artifact_target_store_mismatch"))
    }

    XCTAssertEqual(try Data(contentsOf: recordURL), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
  }

  func testPreexistingCorruptOccupantFailsWithoutOverwriteOrLockCreation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "corrupt occupant")
    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: "corrupt occupant")
    let recordURL = try fixture.store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: recordURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let corruptBytes = Data("{definitely-not-json".utf8)
    try corruptBytes.write(to: recordURL, options: [.withoutOverwriting])
    let before = try Data(contentsOf: recordURL)
    let lockURL = recordURL.appendingPathExtension("lock")
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))

    XCTAssertThrowsError(
      try createCandidate(
        store: fixture.store,
        objective: "corrupt occupant",
        request: request)
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(
          "authorization_binding_artifact_store_manifest_mismatch")
          || error.localizedDescription.contains(
            "authorization_binding_artifact_target_store_mismatch"))
    }

    XCTAssertEqual(try Data(contentsOf: recordURL), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
  }

  func testCreateOnlyDoesNotPublishSessionOrDispatchState() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    _ = try createCandidate(
      store: fixture.store,
      objective: "store only boundary")

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("current-session.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("dispatch", isDirectory: true).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("threads", isDirectory: true).path))
    let rootEntries = try Set(FileManager.default.contentsOfDirectory(atPath: fixture.root.path))
    XCTAssertEqual(rootEntries, ["goals"])
  }

  func testCandidateRemainsRevisionNilResolvedOneUntilLaterPromotion() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try createCandidate(
      store: fixture.store,
      objective: "revision semantics")

    XCTAssertNil(result.storeDisposition.record.revision)
    XCTAssertEqual(result.storeDisposition.record.resolvedRevision, 1)
    XCTAssertEqual(result.candidateResolvedRevision, 1)
  }

  func testMCPToolIsExposedAndDispatchesOnlyIntoTemporaryStateRoot() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let frozenBook = TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults()
    let request = try makeAuthorizationRequest(
      store: fixture.store,
      objective: "mcp strict candidate",
      book: frozenBook)
    let beforeManifest = try directoryManifest(fixture.root)
    XCTAssertEqual(beforeManifest, [])

    let definition = try XCTUnwrap(
      TatwoMCPRegistry.tools.first { $0.name == "tatwo.os.goal.candidate.create" })
    XCTAssertEqual(definition.returnsSchema, "TatwoGoalCandidateCreateOnlyResultV1")
    XCTAssertFalse(definition.hostMutationAllowed)
    XCTAssertEqual(
      definition.requiredArguments,
      [
        "mode",
        "scenario",
        "objective",
        "authorizationBindingArtifactSHA256",
        "authorizationBindingArtifactJSON",
      ])

    let call = TatwoMCPRegistry.call(
      tool: "tatwo.os.goal.candidate.create",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string("coding"),
        "objective": .string("mcp strict candidate"),
        "authorizationBindingArtifactSHA256": .string(request.sha256),
        "authorizationBindingArtifactJSON": .string(request.json),
      ],
      goalCandidateStoreOverride: fixture.store,
      goalCandidateScenarioBookOverride: frozenBook)
    XCTAssertTrue(call.ok, call.error ?? "")

    guard case .object(let payload) = call.payload,
      case .object(let contract)? = payload["contract"],
      case .string(let contractID)? = contract["contractID"],
      case .object(let storeDisposition)? = payload["storeDisposition"],
      case .string(let persistedBytesSHA256)? = storeDisposition["persistedBytesSHA256"]
    else {
      return XCTFail("expected typed create-only MCP payload")
    }
    XCTAssertNotNil(try fixture.store.record(forContractID: contractID))
    let recordURL = try fixture.store.fileURL(forContractID: contractID)
    XCTAssertEqual(
      persistedBytesSHA256,
      sha256(try Data(contentsOf: recordURL)))
    let recordBytes = try Data(contentsOf: recordURL)
    let lockURL = recordURL.appendingPathExtension("lock")
    let lockBytes = try Data(contentsOf: lockURL)
    let afterCreateManifest = try directoryManifest(fixture.root)
    XCTAssertFalse(afterCreateManifest.contains { $0.contains("scenario-config") })
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("current-session.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("dispatch", isDirectory: true).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("threads", isDirectory: true).path))

    let collision = TatwoMCPRegistry.call(
      tool: "tatwo.os.goal.candidate.create",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string("coding"),
        "objective": .string("mcp strict candidate"),
        "authorizationBindingArtifactSHA256": .string(request.sha256),
        "authorizationBindingArtifactJSON": .string(request.json),
      ],
      goalCandidateStoreOverride: fixture.store,
      goalCandidateScenarioBookOverride: frozenBook)
    XCTAssertFalse(collision.ok)
    XCTAssertEqual(
      collision.error?.contains(
        "authorization_binding_artifact_store_manifest_mismatch"),
      true)
    XCTAssertEqual(try Data(contentsOf: recordURL), recordBytes)
    XCTAssertEqual(try Data(contentsOf: lockURL), lockBytes)
    XCTAssertEqual(try directoryManifest(fixture.root), afterCreateManifest)
  }
}
