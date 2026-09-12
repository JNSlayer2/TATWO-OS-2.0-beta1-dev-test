import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class LoopsLedgerAndIdentityResolverTests: XCTestCase {
  func testMakeEntryMapsDispatchStatusesToLedgerStatuses() {
    let cases: [(TatwoDispatchStatus, TatwoDispatchLedgerStatus)] = [
      (.queued, .dispatched),
      (.running, .running),
      (.completed, .done),
      (.verified, .verified),
      (.failed, .failed),
    ]

    for (dispatchStatus, ledgerStatus) in cases {
      let entry = makeEntry(status: dispatchStatus)
      XCTAssertEqual(entry.status, ledgerStatus)
    }
  }

  func testMakeEntryMapsSubtaskAndModelToExistingLedgerFields() {
    let entry = makeEntry(modelID: "model-alpha", subtask: "inspect data flow")

    XCTAssertEqual(entry.label, "inspect data flow")
    XCTAssertEqual(entry.model, "model-alpha")
  }

  func testMakeEntryPreservesIdentityAndRoundInCompatibilityMetadata() {
    let entry = makeEntry(identity: .verifier, roundIndex: 7)

    XCTAssertTrue(entry.note?.contains("identity=verifier") == true)
    XCTAssertTrue(entry.note?.contains("roundIndex=7") == true)
  }

  func testMakeEntryPreservesContractAndGoalInCompatibilityMetadata() {
    let entry = makeEntry(contractID: "contract-16", goalID: "goal-phase-1")

    XCTAssertTrue(entry.note?.contains("contractID=contract-16") == true)
    XCTAssertTrue(entry.note?.contains("goalID=goal-phase-1") == true)
  }

  func testEncodeJSONLProducesExactlyOneReaderCompatibleLine() throws {
    let entry = makeEntry(status: .running)
    let line = TatwoLoopsLedgerWriter.encodeJSONL(entry)

    XCTAssertFalse(line.isEmpty)
    XCTAssertFalse(line.contains("\n"))

    let ledgerURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("loops-ledger-writer-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: ledgerURL) }
    try (line + "\n").write(to: ledgerURL, atomically: true, encoding: .utf8)

    XCTAssertEqual(TatwoDispatchLedgerReader(ledgerURL: ledgerURL).readEntries(), [entry])
  }

  func testEntryCodableRoundTripPreservesCompatibilityMetadata() throws {
    let entry = makeEntry(identity: .supervisor, status: .completed, roundIndex: 3)
    let line = TatwoLoopsLedgerWriter.encodeJSONL(entry)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(TatwoDispatchLedgerEntry.self, from: Data(line.utf8))

    XCTAssertEqual(decoded, entry)
  }

  func testResolveReturnsBindingForRequestedIdentity() {
    let verifier = binding(id: "verify", identity: .verifier, modelID: "model-verify")

    XCTAssertEqual(
      TatwoLoopsIdentityResolver.resolve(identity: .verifier, bindings: [verifier]),
      verifier)
  }

  func testResolveReturnsNilWhenIdentityIsMissing() {
    let lead = binding(id: "lead", identity: .lead, modelID: "model-lead")

    XCTAssertNil(TatwoLoopsIdentityResolver.resolve(identity: .sub, bindings: [lead]))
  }

  func testResolveSelectsRequestedIdentityFromMultipleBindings() {
    let lead = binding(id: "lead", identity: .lead, modelID: "model-lead")
    let sub = binding(id: "sub", identity: .sub, modelID: "model-sub")
    let verifier = binding(id: "verify", identity: .verifier, modelID: "model-verify")

    XCTAssertEqual(
      TatwoLoopsIdentityResolver.resolve(identity: .sub, bindings: [lead, sub, verifier]),
      sub)
  }

  func testResolveModelIDReturnsBoundModelInsteadOfFallback() {
    let sub = binding(id: "sub", identity: .sub, modelID: "model-bound")

    XCTAssertEqual(
      TatwoLoopsIdentityResolver.resolveModelID(
        identity: .sub,
        bindings: [sub],
        fallback: "model-fallback"),
      "model-bound")
  }

  func testResolveModelIDUsesFallbackWhenBindingOrModelIsMissing() {
    let unbound = binding(id: "sub", identity: .sub, modelID: nil)

    XCTAssertEqual(
      TatwoLoopsIdentityResolver.resolveModelID(
        identity: .sub,
        bindings: [unbound],
        fallback: "model-fallback"),
      "model-fallback")
    XCTAssertNil(
      TatwoLoopsIdentityResolver.resolveModelID(
        identity: .verifier,
        bindings: [unbound],
        fallback: nil))
  }

  private func makeEntry(
    contractID: String = "contract-16",
    goalID: String = "goal-phase-1",
    identity: IdentityKind = .sub,
    modelID: String = "model-alpha",
    subtask: String = "phase-one",
    status: TatwoDispatchStatus = .queued,
    roundIndex: Int = 1
  ) -> TatwoDispatchLedgerEntry {
    TatwoLoopsLedgerWriter.makeEntry(
      contractID: contractID,
      goalID: goalID,
      identity: identity,
      modelID: modelID,
      subtask: subtask,
      status: status,
      roundIndex: roundIndex)
  }

  private func binding(
    id: String,
    identity: IdentityKind,
    modelID: String?
  ) -> WorkOSIdentityBinding {
    WorkOSIdentityBinding(
      id: id,
      identity: identity,
      label: id,
      engineID: nil,
      modelID: modelID,
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "slot-\(id)",
      bindingRule: "test")
  }
}
