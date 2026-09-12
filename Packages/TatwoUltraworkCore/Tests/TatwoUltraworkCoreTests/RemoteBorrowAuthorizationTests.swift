import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("Remote borrow authorization")
struct RemoteBorrowAuthorizationTests {
  @Test("Device auto-borrow is denied by default and persists explicitly")
  func devicePolicyDefaultsDeniedAndPersists() throws {
    let root = temporaryRoot()
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: root)

    let initial = try store.devicePolicy(targetDeviceID: "mac-mini")
    #expect(initial.autoBorrowEnabled == false)

    let changed = try store.setAutoBorrow(
      targetDeviceID: "mac-mini",
      enabled: true,
      now: Date(timeIntervalSince1970: 100))
    #expect(changed.autoBorrowEnabled)

    let relaunched = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    let loaded = try relaunched.devicePolicy(targetDeviceID: "mac-mini")
    #expect(loaded == changed)
  }

  @Test("Session grant survives relaunch and is bound to the Work OS contract")
  func grantRoundTripAndContractBinding() throws {
    let root = temporaryRoot()
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    let issued = try store.issueSessionGrant(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a",
      now: Date(timeIntervalSince1970: 200))

    let relaunched = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    #expect(
      try relaunched.sessionGrant(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        now: Date(timeIntervalSince1970: 201)) == issued)
    #expect(
      try relaunched.sessionGrant(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-b",
        now: Date(timeIntervalSince1970: 201)) == nil)
  }

  @Test("High-risk work cannot receive a standing session grant")
  func highRiskStandingGrantIsForbidden() throws {
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: temporaryRoot())
    #expect(throws: TatwoRemoteBorrowAuthorizationError.standingHighRiskGrantForbidden) {
      try store.issueSessionGrant(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        risk: .highRisk)
    }
  }

  @Test("Session and target revocation retain durable revoked receipts")
  func revocationIsDurableWithoutDeletingRecords() throws {
    let root = temporaryRoot()
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    _ = try store.issueSessionGrant(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a")
    _ = try store.issueSessionGrant(
      sessionID: "thread-2",
      targetDeviceID: "mac-mini",
      contractID: "contract-b")

    let sessionRevoked = try store.revokeSession(
      sessionID: "thread-1",
      now: Date(timeIntervalSince1970: 300))
    #expect(sessionRevoked.count == 1)
    #expect(sessionRevoked[0].revokedAt == Date(timeIntervalSince1970: 300))

    let targetRevoked = try store.revokeTarget(
      targetDeviceID: "mac-mini",
      now: Date(timeIntervalSince1970: 400))
    #expect(targetRevoked.count == 1)

    let files = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("session-grants", isDirectory: true),
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    #expect(files.count == 2)
  }

  @Test("Grant expiry fails closed without deleting issuance evidence")
  func expiryFailsClosed() throws {
    let root = temporaryRoot()
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    let issued = try store.issueSessionGrant(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a",
      ttl: 300,
      now: Date(timeIntervalSince1970: 1_000))

    #expect(
      try store.sessionGrant(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        now: Date(timeIntervalSince1970: 1_299))?.id == issued.id)
    #expect(
      try store.sessionGrant(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        now: Date(timeIntervalSince1970: 1_301)) == nil)
    #expect(
      try store.grantHistory(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a").count == 1)
  }

  @Test("Reissue preserves the revoked grant and links replacement history")
  func revokeThenReissueIsAppendOnly() throws {
    let root = temporaryRoot()
    let store = TatwoRemoteBorrowAuthorizationStore(rootURL: root)
    let first = try store.issueSessionGrant(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a",
      now: Date(timeIntervalSince1970: 1_000))
    _ = try store.revokeSession(
      sessionID: "thread-1",
      now: Date(timeIntervalSince1970: 1_100))
    let replacement = try store.issueSessionGrant(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a",
      now: Date(timeIntervalSince1970: 1_200))

    let history = try store.grantHistory(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a")
    #expect(history.count == 2)
    #expect(history[0].id == first.id)
    #expect(history[0].revokedAt == Date(timeIntervalSince1970: 1_100))
    #expect(replacement.previousGrantID == first.id)
    #expect(history[1].id == replacement.id)

    let revocationFiles = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent(
        "session-grant-revocations",
        isDirectory: true),
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    #expect(revocationFiles.count == 1)
  }

  @Test("Production store derives from the sealed state root")
  func productionRootIsCanonical() {
    let stateRoot = temporaryRoot().appendingPathComponent("state", isDirectory: true)
    let store = TatwoRemoteBorrowAuthorizationStore.production(stateRoot: stateRoot)
    #expect(
      store.rootURL == stateRoot.standardizedFileURL.appendingPathComponent(
        "remote-execution-authorization",
        isDirectory: true))
  }

  @Test("Automatic borrow needs device policy, trust, and the exact session grant")
  func automaticBorrowEvaluatorFailsClosed() {
    let disabled = TatwoRemoteDeviceExecutionPolicyV1(
      targetDeviceID: "mac-mini",
      autoBorrowEnabled: false)
    let enabled = TatwoRemoteDeviceExecutionPolicyV1(
      targetDeviceID: "mac-mini",
      autoBorrowEnabled: true)
    let grant = TatwoRemoteSessionGrantV1(
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a")

    #expect(
      TatwoRemoteBorrowAuthorizationEvaluator.decide(
        mode: .automatic,
        risk: .lowRisk,
        policy: disabled,
        grant: grant,
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        targetIsTrusted: true
      ).blocker == .automaticBorrowDisabled)

    #expect(
      TatwoRemoteBorrowAuthorizationEvaluator.decide(
        mode: .automatic,
        risk: .lowRisk,
        policy: enabled,
        grant: nil,
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        targetIsTrusted: true
      ).blocker == .sessionApprovalRequired)

    #expect(
      TatwoRemoteBorrowAuthorizationEvaluator.decide(
        mode: .automatic,
        risk: .lowRisk,
        policy: enabled,
        grant: grant,
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        targetIsTrusted: false
      ).blocker == .targetNotTrusted)

    #expect(
      TatwoRemoteBorrowAuthorizationEvaluator.decide(
        mode: .automatic,
        risk: .lowRisk,
        policy: enabled,
        grant: grant,
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a",
        targetIsTrusted: true
      ).allowed)
  }

  @Test("High-risk evaluation always requires one-time confirmation")
  func highRiskEvaluatorIgnoresStandingGrant() {
    let decision = TatwoRemoteBorrowAuthorizationEvaluator.decide(
      mode: .manual,
      risk: .highRisk,
      policy: TatwoRemoteDeviceExecutionPolicyV1(
        targetDeviceID: "mac-mini",
        autoBorrowEnabled: true),
      grant: TatwoRemoteSessionGrantV1(
        sessionID: "thread-1",
        targetDeviceID: "mac-mini",
        contractID: "contract-a"),
      sessionID: "thread-1",
      targetDeviceID: "mac-mini",
      contractID: "contract-a",
      targetIsTrusted: true)

    #expect(decision.allowed == false)
    #expect(decision.blocker == .perInvocationApprovalRequired)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-remote-borrow-\(UUID().uuidString)", isDirectory: true)
  }
}
