import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class AgentTransportContractTests: XCTestCase {
  func testCanonicalToolProposalNormalizesArgsAndHashesLifecycle() throws {
    let proposal = try AgentToolProposalDecoder.decode(
      Data(#"{"callID":"call-1","name":"write","args":{"text":"hello","path":"a.txt"}}"#.utf8),
      allowlistedTools: ["write"])
    XCTAssertEqual(proposal.callID, "call-1")
    XCTAssertEqual(proposal.name, "write")
    XCTAssertEqual(String(decoding: proposal.canonicalArgs, as: UTF8.self), #"{"path":"a.txt","text":"hello"}"#)
    XCTAssertEqual(proposal.argsHash, AgentKernelDigest.sha256Hex(proposal.canonicalArgs))
    XCTAssertEqual(proposal.lifecycle, .proposed)

    let completed = proposal.completed(result: Data("wrote a.txt".utf8))
    XCTAssertEqual(completed.lifecycle, .completed)
    XCTAssertEqual(completed.resultDigest, AgentKernelDigest.sha256Hex(Data("wrote a.txt".utf8)))
  }

  func testUnknownToolAndClaimedExecutionAreRejected() {
    XCTAssertThrowsError(
      try AgentToolProposalDecoder.decode(
        Data(#"{"callID":"call-1","name":"shell","args":{}}"#.utf8),
        allowlistedTools: ["write"])) { error in
          XCTAssertEqual(error as? AgentToolContractError, .unknownTool("shell"))
        }
    XCTAssertThrowsError(
      try AgentToolProposalDecoder.decode(
        Data(#"{"callID":"call-2","name":"write","args":{},"lifecycle":"completed","resultDigest":"fake"}"#.utf8),
        allowlistedTools: ["write"])) { error in
          XCTAssertEqual(error as? AgentToolContractError, .modelClaimedExecution)
        }
  }

  func testDuplicateCallIDIsRejected() throws {
    let ledger = AgentToolCallLedger()
    let proposal = try AgentToolProposalDecoder.decode(
      Data(#"{"callID":"same","name":"write","args":{"path":"a","text":"x"}}"#.utf8),
      allowlistedTools: ["write"])
    try ledger.accept(proposal)
    XCTAssertThrowsError(try ledger.accept(proposal)) { error in
      XCTAssertEqual(error as? AgentToolContractError, .duplicateCallID("same"))
    }
  }
}
