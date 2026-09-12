import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentKernelContextEngineTests: XCTestCase {
  func testTypedContextItemCarriesSelectionMetadata() {
    let item = AgentContextItem(
      id: "goal-1",
      kind: .goal,
      payload: "Ship K2",
      provenance: .human(turnID: "turn-1"),
      freshness: 42,
      priority: 100,
      tokenCount: 3,
      required: true,
      pinned: true)

    XCTAssertEqual(item.provenance, .human(turnID: "turn-1"))
    XCTAssertEqual(item.freshness, 42)
    XCTAssertEqual(item.priority, 100)
    XCTAssertTrue(item.required)
    XCTAssertTrue(item.pinned)
  }

  func testPinnedRetentionSetCannotBeEvictedAndOverflowFailsClosed() throws {
    let pinnedKinds: [AgentContextItemKind] = [
      .goal, .prohibition, .approval, .pendingSideEffect,
    ]
    var pinned = pinnedKinds.enumerated().map {
      item(id: "p-\($0.offset)", kind: $0.element, tokens: 2)
    }
    pinned.append(item(
      id: "correction-old",
      kind: .humanCorrection,
      freshness: 1,
      priority: 999,
      tokens: 2))
    pinned.append(item(
      id: "correction-new", kind: .humanCorrection, freshness: 2, tokens: 2))

    let selected = try AgentContextSelector().select(
      AgentContextSelectionInput(
        recentWindow: [],
        checkpoint: [],
        pinned: pinned,
        tokenBudget: 10))

    XCTAssertEqual(
      Set(selected.items.map(\.id)),
      Set(["p-0", "p-1", "p-2", "p-3", "correction-new"]))
    XCTAssertFalse(selected.items.contains { $0.id == "correction-old" })

    XCTAssertThrowsError(
      try AgentContextSelector().select(
        AgentContextSelectionInput(
          recentWindow: [],
          checkpoint: [],
          pinned: pinned,
          tokenBudget: 9))
    ) { error in
      XCTAssertEqual(
        error as? AgentContextSelectionError,
        .stopped(reason: .tokenBudgetExceeded))
    }
  }

  func testRequiredRecentWindowOverflowFailsClosedInsteadOfSilentlyDroppingIt() {
    let overflow = """
    PINNED_GOAL=G2C-BUDGET-GOAL-KEEP
    PINNED_FORBIDDEN=do-not-drop-this-retain-set-item
    OVERFLOW_BODY=\(String(repeating: "x", count: 4_000))
    G2C-RAW-TURN01-UNIQUE-9KQ2
    """
    let input = AgentContextSelectionInput(
      recentWindow: [
        AgentContextItem(
          id: "overflow",
          kind: .recentTurn,
          payload: overflow,
          provenance: .human(turnID: "overflow"),
          freshness: 1,
          priority: 1,
          tokenCount: AgentKernelTokenCounter.count(overflow),
          required: true,
          pinned: false),
      ],
      checkpoint: [],
      pinned: [
        item(id: "goal", kind: .goal, tokens: 5),
        item(id: "prohibition", kind: .prohibition, tokens: 9),
      ],
      tokenBudget: 256)

    XCTAssertGreaterThan(AgentKernelTokenCounter.count(overflow), 256)
    XCTAssertThrowsError(try AgentContextSelector().select(input)) { error in
      XCTAssertEqual(
        error as? AgentContextSelectionError,
        .stopped(reason: .tokenBudgetExceeded))
    }
  }

  func testSelectionIsDeterministicAndReceiptExplainsBudgetAndDigest() throws {
    let input = AgentContextSelectionInput(
      recentWindow: [
        item(id: "window-low", kind: .recentTurn, freshness: 9, priority: 1, tokens: 4),
        item(id: "window-high", kind: .recentTurn, freshness: 8, priority: 5, tokens: 4),
      ],
      checkpoint: [
        item(id: "fact", kind: .fact, freshness: 4, priority: 3, tokens: 3),
      ],
      pinned: [
        item(id: "goal", kind: .goal, tokens: 2),
      ],
      tokenBudget: 9)

    let first = try AgentContextSelector().select(input)
    let second = try AgentContextSelector().select(input)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.items.map(\.id), ["goal", "window-high", "fact"])
    XCTAssertEqual(first.receipt.candidateIDs, [
      "fact", "goal", "window-high", "window-low",
    ])
    XCTAssertEqual(first.receipt.decisions["goal"], .selected(reason: .pinned))
    XCTAssertEqual(
      first.receipt.decisions["window-low"],
      .evicted(reason: .budgetExceeded))
    XCTAssertEqual(first.receipt.tokenBudget, 9)
    XCTAssertEqual(first.receipt.assembledInputTokens, 9)
    XCTAssertEqual(first.receipt.remainingTokens, 0)
    XCTAssertEqual(first.payloadDigest.count, 64)
    XCTAssertEqual(first.payloadDigest, second.payloadDigest)
    XCTAssertEqual(first.bytes, second.bytes)
  }

  func testPromptManifestUsesFrozenScorerInterfaceAndWritesAtomically() throws {
    let root = temporaryDirectory()
    let manifest = AgentPromptManifestV1(
      windowTurnIDs: ["turn-31", "turn-32"],
      checkpointHash: "checkpoint-hash",
      assembledInputTokens: 17,
      bytes: 123,
      payloadDigest: String(repeating: "a", count: 64))

    let url = try AgentPromptManifestWriter.write(
      manifest,
      turnID: "turn-32",
      runDirectory: root)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url))
        as? [String: Any])

    XCTAssertEqual(Set(object.keys), Set([
      "windowTurnIDs", "checkpointHash", "assembled_input_tokens",
      "bytes", "payloadDigest",
    ]))
    XCTAssertEqual(url.lastPathComponent, "prompt_manifest.json")
    XCTAssertTrue(url.path.contains("turn-32"))
    XCTAssertEqual(
      try JSONDecoder().decode(AgentPromptManifestV1.self, from: Data(contentsOf: url)),
      manifest)
  }

  func testFixedThirtySixTurnCorpusCompactionReducesTokensWithoutRequiredMissing() throws {
    let turns = (1...36).map { turn in
      item(
        id: "turn-\(turn)",
        kind: .recentTurn,
        freshness: turn,
        priority: 1,
        tokens: 20,
        required: turn == 7)
    }
    let checkpoint = [
      item(
        id: "checkpoint-required-turn-7",
        kind: .fact,
        freshness: 36,
        priority: 90,
        tokens: 5,
        required: true),
    ]
    let pinned = [
      item(id: "goal", kind: .goal, tokens: 5),
      item(id: "prohibition", kind: .prohibition, tokens: 5),
      item(
        id: "latest-correction",
        kind: .humanCorrection,
        freshness: 36,
        tokens: 5),
    ]
    let selector = AgentContextSelector()
    let uncompacted = try selector.select(
      AgentContextSelectionInput(
        recentWindow: turns,
        checkpoint: [],
        pinned: pinned,
        tokenBudget: 1_000))
    let compacted = try selector.select(
      AgentContextSelectionInput(
        recentWindow: Array(turns.suffix(4)),
        checkpoint: checkpoint,
        pinned: pinned,
        tokenBudget: 100))

    XCTAssertLessThan(
      compacted.assembledInputTokens,
      uncompacted.assembledInputTokens / 3)
    XCTAssertEqual(
      compacted.items.filter(\.required).map(\.id),
      ["checkpoint-required-turn-7"])
    XCTAssertFalse(
      compacted.items.contains {
        $0.kind == .recentTurn && !["turn-33", "turn-34", "turn-35", "turn-36"].contains($0.id)
      })
  }

  private func item(
    id: String,
    kind: AgentContextItemKind,
    freshness: Int = 0,
    priority: Int = 0,
    tokens: Int,
    required: Bool = false,
    pinned: Bool = false
  ) -> AgentContextItem {
    AgentContextItem(
      id: id,
      kind: kind,
      payload: id,
      provenance: .human(turnID: id),
      freshness: freshness,
      priority: priority,
      tokenCount: tokens,
      required: required,
      pinned: pinned)
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
