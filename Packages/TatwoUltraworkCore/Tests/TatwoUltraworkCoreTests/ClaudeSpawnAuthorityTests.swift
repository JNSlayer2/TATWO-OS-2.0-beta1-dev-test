import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class ClaudeSpawnAuthorityTests: XCTestCase {
  func testEveryPurposePinsProfileTokenVendorModelAndExplicitTools() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "profile-token\n".write(
      to: root.appendingPathComponent(ClaudeSpawnAuthority.oauthTokenFilename),
      atomically: true,
      encoding: .utf8)
    let authority = ClaudeSpawnAuthority(
      executableURL: URL(fileURLWithPath: "/tmp/claude"),
      profileHomeURL: root,
      environment: [
        "PATH": "/usr/bin",
        "HOME": "/Users/real-user",
        "CLAUDE_CONFIG_DIR": "/Users/real-user/.claude",
        "ANTHROPIC_API_KEY": "must-be-scrubbed",
      ])

    for purpose in ClaudeSpawnPurpose.allCases {
      let plan = try authority.plan(ClaudeSpawnRequest(
        purpose: purpose,
        canonicalModelSlug: "fable-5",
        effort: "high",
        toolPolicy: ClaudeSpawnToolPolicy(
          tools: ["Read", "Bash"],
          allowedTools: ["Read"]),
        networkPolicy: .allowed,
        workingDirectory: root))
      XCTAssertEqual(plan.profileHomeURL, root.standardizedFileURL)
      XCTAssertEqual(plan.environment["HOME"], root.path)
      XCTAssertEqual(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"], "profile-token")
      XCTAssertNil(plan.environment["CLAUDE_CONFIG_DIR"])
      XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
      XCTAssertEqual(plan.environment["TATWO_CLAUDE_SPAWN_PURPOSE"], purpose.rawValue)
      XCTAssertEqual(plan.vendorModelID, "claude-fable-5")
      XCTAssertTrue(plan.arguments.contains("--tools"))
      XCTAssertTrue(plan.arguments.contains("--allowedTools"))
    }
  }

  func testCanonicalVendorMappingIsSingleTruth() {
    XCTAssertEqual(ClaudeSpawnAuthority.vendorModelID(for: "fable-5"), "claude-fable-5")
    XCTAssertEqual(ClaudeSpawnAuthority.vendorModelID(for: "opus-5"), "claude-opus-5")
    XCTAssertEqual(ClaudeSpawnAuthority.vendorModelID(for: "sonnet-5"), "sonnet")
    XCTAssertEqual(ClaudeSpawnAuthority.vendorModelID(for: "haiku-4-5"), "haiku")
    XCTAssertNil(ClaudeSpawnAuthority.vendorModelID(for: "unknown"))
  }
}
