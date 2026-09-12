import Testing
@testable import TatwoUltraworkCore

@Suite("SessionProtocolV1 MCP boundary")
struct SessionProtocolV1MCPBoundaryTests {
  @Test(arguments: ["tatwo.thread.create", "tatwo.goal.create"])
  func toolsCallCannotMintSessionAuthority(tool: String) {
    #expect(TatwoMCPRegistry.tools.contains(where: { $0.name == tool }) == false)

    let result = TatwoMCPRegistry.call(
      tool: tool,
      arguments: [
        "threadID": .string("thread-forbidden"),
        "goalID": .string("goal-forbidden"),
      ])

    #expect(result.ok == false)
    #expect(result.failureKind == .notFound)
    #expect(result.error == "unknown_tool:\(tool)")
    #expect(result.payload == nil)
    #expect(result.hostMutationAllowed == false)
  }
}
