import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ClaudeImageLaunchctlLiveProbeTests: XCTestCase {
  func testClaudeImageReadCompletesAcrossRealLaunchctlBoundary() throws {
    let environment = ProcessInfo.processInfo.environment
    let configURL = URL(
      fileURLWithPath:
        environment["TATWO_LIVE_CLAUDE_IMAGE_LAUNCHCTL_CONFIG"]
          ?? "/tmp/tatwo-claude-image-launchctl-live-probe.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      throw XCTSkip(
        "Create the live-probe sentinel config to run the real subscription probe.")
    }
    let config = try JSONDecoder().decode(
      LiveProbeConfig.self,
      from: Data(contentsOf: configURL))
    guard config.enabled else {
      throw XCTSkip("Live-probe sentinel config is disabled.")
    }
    let imagePath = config.imagePath
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: imagePath),
      "Live probe image does not exist.")

    let claudePath = config.claudePath ?? "/opt/homebrew/bin/claude"
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: claudePath),
      "Claude CLI is not executable.")

    let runID = UUID().uuidString.lowercased()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-claude-image-launchctl-live-\(runID)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    let stdoutURL = root.appendingPathComponent("stdout.jsonl")
    let stderrURL = root.appendingPathComponent("stderr.log")
    let statusURL = root.appendingPathComponent("status.txt")
    for url in [stdoutURL, stderrURL, statusURL] {
      try Data().write(to: url, options: .atomic)
    }

    let imageDirectory = URL(fileURLWithPath: imagePath)
      .deletingLastPathComponent()
      .standardizedFileURL.path
    let prompt = """
      Inspect this image with the Read tool:
      \(imagePath)

      After Read returns a tool_result, respond with exactly IMAGE_OK.
      Do not use any other tool.
      """
    let claudeArguments = [
      "-p",
      "--output-format", "stream-json",
      "--verbose",
      "--no-session-persistence",
      "--permission-mode", "acceptEdits",
      "--effort", "high",
      "--model", "opus",
      "--tools", "Read",
      "--allowedTools", "Read",
      "--add-dir", imageDirectory,
      "--",
      prompt,
    ]
    let environmentArguments = launchEnvironmentArguments(
      environment: environment,
      executable: claudePath,
      arguments: claudeArguments)
    let label = "com.tatwo.ultrawork.live.claude-image.\(runID.prefix(24))"
    let launch = TatwoChatCommandPlanner.launchctlSubmitBoundaryLaunch(
      label: label,
      stdoutPath: stdoutURL.path,
      stderrPath: stderrURL.path,
      statusPath: statusURL.path,
      uid: "\(getuid())",
      workingDirectoryPath: URL(fileURLWithPath: imageDirectory).path,
      executable: "/usr/bin/env",
      arguments: environmentArguments,
      pollTimeoutSeconds: 90)

    let wrapper = Process()
    wrapper.executableURL = URL(fileURLWithPath: launch.executable)
    wrapper.arguments = launch.arguments
    wrapper.currentDirectoryURL = FileManager.default.temporaryDirectory
    wrapper.environment = [
      "HOME": environment["HOME"] ?? NSHomeDirectory(),
      "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": environment["TMPDIR"] ?? NSTemporaryDirectory(),
    ]
    try wrapper.run()
    wrapper.waitUntilExit()

    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    let status = (try? String(contentsOf: statusURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    XCTAssertEqual(
      wrapper.terminationStatus,
      0,
      "launchctl wrapper failed; status=\(status ?? "missing") stderr=\(stderr)")
    XCTAssertEqual(status, "0")
    XCTAssertTrue(stdout.contains(#""model":"claude-opus-5""#))
    XCTAssertTrue(stdout.contains(#""name":"Read""#))
    XCTAssertTrue(stdout.contains(#""type":"tool_result""#))
    XCTAssertTrue(stdout.contains("IMAGE_OK"))
    XCTAssertFalse(stdout.contains(#""type":"fallback""#))
  }

  private struct LiveProbeConfig: Decodable {
    let enabled: Bool
    let imagePath: String
    let claudePath: String?
  }

  private func launchEnvironmentArguments(
    environment: [String: String],
    executable: String,
    arguments: [String]
  ) -> [String] {
    let allowedKeys = [
      "HOME",
      "USER",
      "LOGNAME",
      "SHELL",
      "PATH",
      "TMPDIR",
      "TMP",
      "TEMP",
      "LANG",
      "LC_CTYPE",
      "SSH_AUTH_SOCK",
    ]
    let pairs = allowedKeys.compactMap { key -> String? in
      guard let value = environment[key], !value.isEmpty else { return nil }
      return "\(key)=\(value)"
    }
    return [
      "-u", "ANTHROPIC_API_KEY",
      "-u", "ANTHROPIC_AUTH_TOKEN",
      "-u", "ANTHROPIC_BASE_URL",
    ] + pairs + [executable] + arguments
  }
}
