import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("SessionProtocolV1 clients")
struct SessionProtocolV1ClientTests {
  @Test("client and execution-location vocabulary is closed")
  func vocabulary() {
    #expect(SessionProtocolV1.ClientKind.allCases == [
      .localChat, .cli, .futureBot, .channelAdapter, .cloudRunner,
    ])
    #expect(SessionProtocolV1.ExecutionLocation.allCases == [
      .local, .remoteDevice, .cloudWorker, .privateComputeCapability,
    ])
  }

  @Test("cloud runner is bounded and owns no durable run")
  func boundedCloudRunner() throws {
    let client = try SessionProtocolV1.Client(
      kind: .cloudRunner,
      executionLocation: .cloudWorker,
      budget: .init(maxTokens: 4_000),
      ttlSeconds: 120)
    #expect(client.authorityLease == .never)
    #expect(client.budget?.maxTokens == 4_000)
    #expect(client.ttlSeconds == 120)
    #expect(client.ownsDurableRun == false)
  }

  @Test(arguments: [
    (SessionProtocolV1.Budget?.none, Optional(120)),
    (Optional(SessionProtocolV1.Budget(maxTokens: 4_000)), Int?.none),
  ])
  func cloudRunnerRejectsMissingBounds(
    budget: SessionProtocolV1.Budget?,
    ttl: Int?
  ) {
    #expect(throws: SessionProtocolV1.ClientError.self) {
      try SessionProtocolV1.Client(
        kind: .cloudRunner,
        executionLocation: .cloudWorker,
        budget: budget,
        ttlSeconds: ttl)
    }
  }

  @Test("decoded cloud runner cannot smuggle authority or ownership")
  func decodedCloudRunnerCannotSmuggleAuthority() {
    let json = Data("""
      {"kind":"cloudRunner","executionLocation":"cloudWorker",
       "authorityLease":"processBound","budget":{"maxTokens":100},
       "ttlSeconds":30,"ownsDurableRun":true}
      """.utf8)
    #expect(throws: SessionProtocolV1.ClientError.self) {
      try JSONDecoder().decode(SessionProtocolV1.Client.self, from: json)
    }
  }
}
