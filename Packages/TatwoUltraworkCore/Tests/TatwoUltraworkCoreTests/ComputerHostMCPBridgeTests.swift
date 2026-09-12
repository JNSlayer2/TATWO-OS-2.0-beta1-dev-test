import Foundation
import XCTest

final class ComputerHostMCPBridgeTests: XCTestCase {
  func testDedicatedComputerMCPExposesOnlyNativeHostAndScopedBrowserTools() throws {
    let scriptURL = repositoryRoot
      .appendingPathComponent("scripts/tatwo-computer-mcp.mjs")
    XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", scriptURL.path]
    process.environment = [
      "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
      "TATWO_COMPUTER_APP_URL": "http://127.0.0.1:9",
      "TATWO_COMPUTER_CONTRACT_ID": "contract-test",
      "TATWO_COMPUTER_LEASE_ID": "lease-test",
      "TATWO_COMPUTER_RUN_ID": "run-test",
      "TATWO_COMPUTER_WORKSPACE_ROOT": "/tmp/tatwo-computer-test",
    ]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()
    let requests = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
    ].joined(separator: "\n") + "\n"
    try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0)
    let lines = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).split(separator: "\n")
    let responses = try lines.map { line in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let listResponse = try XCTUnwrap(
      responses.first { ($0["id"] as? Int) == 2 })
    let result = try XCTUnwrap(listResponse["result"] as? [String: Any])
    let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
    let names = tools.compactMap { $0["name"] as? String }
    let expected = [
      "tatwo_computer",
      "tatwo.browser.read_sanitized",
      "tatwo.browser.plan_actions",
      "tatwo.browser.execute_approved_plan",
    ]
    XCTAssertEqual(names.count, expected.count)
    XCTAssertEqual(Set(names), Set(expected))
    XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: tools), encoding: .utf8)!.contains("codex"))
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
