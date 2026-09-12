import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoAgentEngineBindingTests: XCTestCase {
  private let contractID = "contract-agent-engine"
  private let goalID = "goal-agent-engine"

  private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-agent-engine-\(UUID().uuidString)",
      isDirectory: true)
  }

  /// Install a fake agent CLI under `home/.local/bin/<name>` (executable script).
  @discardableResult
  private func installFakeAgent(
    home: URL,
    name: String,
    script: String
  ) throws -> URL {
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let path = bin.appendingPathComponent(name)
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: path.path)
    return path
  }

  private func task(
    description: String,
    agent: TatwoRemoteAgentKindV1? = .grok,
    exactModelRouteID: String? = nil,
    includeExactModelRoute: Bool = true,
    activeSkillBinding: TatwoActiveSkillLaunchBindingV1? = nil
  ) -> TatwoLoopEngineTaskV1 {
    let defaultRoute: String?
    switch agent {
    case .grok: defaultRoute = "grok-build"
    case .codex: defaultRoute = "gpt-5.6-sol"
    case .claude: defaultRoute = "fable-5"
    case nil: defaultRoute = nil
    }
    return TatwoLoopEngineTaskV1(
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      mode: .s,
      taskDescription: description,
      agent: agent,
      exactModelRouteID: includeExactModelRoute
        ? (exactModelRouteID ?? defaultRoute)
        : nil,
      activeSkillBinding: activeSkillBinding)
  }

  private func activeSkillBinding(
    root: URL,
    repository: String = "review-skill"
  ) throws -> TatwoActiveSkillLaunchBindingV1 {
    let runtime = root.appendingPathComponent("skills-runtime", isDirectory: true)
    let skill = runtime.appendingPathComponent(repository, isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try "# Review Skill\n".write(
      to: skill.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8)
    let readback = try TatwoSkilletBundleTransport.readRuntimeRepository(
      runtimeRoot: runtime,
      repositoryID: repository)
    let revision = TatwoActiveSkillRevisionV1(
      repository: repository,
      revision: "rev-\(String(repeating: "a", count: 64))",
      contentDigest: try XCTUnwrap(readback.contentDigest))
    return TatwoActiveSkillLaunchBindingV1(
      expectedActiveSkillSetDigest:
        try TatwoActiveSkillSetDigestV1.canonicalDigest([revision]),
      activeSkillRevisions: [revision],
      runtimeRootURL: runtime)
  }

  func testWhitelistExecutableRunsAndWritesPromptFile() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // Fake grok: echo prompt-file path + contents; must use /dev/fd/N only.
    try installFakeAgent(
      home: home,
      name: "grok",
      script: """
        #!/bin/sh
        # argv: --prompt-file /dev/fd/N  (no absolute host pathname, no --cwd)
        prompt=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prompt-file) prompt="$2"; shift 2 ;;
            --cwd|-C) echo "PATHNAME_CWD_FORBIDDEN" >&2; exit 9 ;;
            *) shift ;;
          esac
        done
        echo "PROMPT_PATH=$prompt"
        case "$prompt" in
          /dev/fd/*)
            echo "PROMPT_BODY=$(cat "$prompt")"
            ;;
          *)
            echo "PATHNAME_PROMPT_FORBIDDEN:$prompt" >&2
            exit 8
            ;;
        esac
        exit 0
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "hello from origin; rm -rf /"),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 8_192),
      shouldCancel: { false })

    XCTAssertNil(result.failureCode, result.message ?? "")
    XCTAssertEqual(result.exitCode, 0)
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    let promptURL = work.appendingPathComponent(TatwoAgentEngineBinding.promptFileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: promptURL.path))
    XCTAssertEqual(
      try String(contentsOf: promptURL, encoding: .utf8),
      "hello from origin; rm -rf /")
    // Transport is /dev/fd/N — never the absolute host prompt pathname.
    XCTAssertTrue(
      output.range(of: #"PROMPT_PATH=/dev/fd/\d+"#, options: .regularExpression) != nil,
      output)
    XCTAssertFalse(output.contains("PROMPT_PATH=\(promptURL.path)"))
    XCTAssertTrue(output.contains("PROMPT_BODY=hello from origin; rm -rf /"))
  }

  func testOutsideWhitelistRejectedAndJournaled() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // Place an executable outside ~/.local/bin — must never be selected.
    let evil = root.appendingPathComponent("evil-bin")
    try """
      #!/bin/sh
      echo PWNED
      """.write(to: evil, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: evil.path)

    // No whitelist entry for grok under home → fail closed.
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "should not run"),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_executable_not_allowed")
    XCTAssertEqual(result.exitCode, -1)
    let journal = work.appendingPathComponent(TatwoAgentEngineBinding.auditJournalFileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    let journalText = try String(contentsOf: journal, encoding: .utf8)
    XCTAssertTrue(journalText.contains("agent_executable_not_allowed"))
    // Evil binary must not have been executed.
    XCTAssertFalse(String(data: result.outputData, encoding: .utf8)?.contains("PWNED") ?? false)
  }

  func testTimeoutKillsAgentProcess() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    try installFakeAgent(
      home: home,
      name: "codex",
      script: """
        #!/bin/sh
        sleep 30
        echo should-not-appear
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let started = Date()
    let result = try engine.run(
      task: task(description: "long job", agent: .codex),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 0.2, maxOutputBytes: 1_024),
      shouldCancel: { false })
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(result.failureCode, "timeout")
    XCTAssertTrue(result.timedOut)
    XCTAssertLessThan(elapsed, 5)
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertFalse(output.contains("should-not-appear"))
  }

  func testOutputCapTruncates() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        # Claude print mode: task prompt arrives on inherited stdin (not argv pathname).
        cat >/dev/null
        dd if=/dev/zero bs=1024 count=64 2>/dev/null
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "flood", agent: .claude),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 128),
      shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "output_cap")
    XCTAssertTrue(result.outputTruncated)
    XCTAssertLessThanOrEqual(result.outputData.count, 128)
  }

  func testClaudePrintModeReadsPromptFromStdinNotMetaPrompt() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        # Reflect argv + stdin body inside Claude stream-json.
        body=$(cat)
        case "$*" in
          */dev/fd/*|*/Users/*|*/tmp/*)
            echo "PATHNAME_OR_FD_META_FORBIDDEN" >&2
            exit 7
            ;;
        esac
        printf '%s\\n' \
          '{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"ok"}]}}'
        printf '{"type":"result","result":"ARGV=%s\\\\nSTDIN_BODY=%s","modelUsage":{"claude-fable-5":{}}}\\n' \
          "$*" "$body"
        exit 0
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "claude stdin only", agent: .claude),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 4_096),
      shouldCancel: { false })

    XCTAssertNil(result.failureCode, result.message ?? "")
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("STDIN_BODY=claude stdin only"), output)
    XCTAssertTrue(output.contains("--model claude-fable-5"), output)
    XCTAssertTrue(output.contains("--output-format stream-json"), output)
    XCTAssertFalse(output.contains("--fallback-model"), output)
    XCTAssertFalse(output.contains("/dev/fd/"), output)
    XCTAssertFalse(output.contains(TatwoAgentEngineBinding.promptFileName), output)
  }

  func testPromptShellInjectionDoesNotExecute() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let pwned = root.appendingPathComponent("PWNED-agent-inject")
    try? FileManager.default.removeItem(at: pwned)

    // Fake grok only reads --prompt-file path as discrete argv; never eval's content.
    try installFakeAgent(
      home: home,
      name: "grok",
      script: """
        #!/bin/sh
        prompt=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prompt-file) prompt="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        # Reflect path + body only — no eval.
        printf 'path=%s\\n' "$prompt"
        cat "$prompt"
        exit 0
        """)

    let evilPrompt =
      "\"; touch \(pwned.path); echo \"$(rm -rf /) && curl evil.example"
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: evilPrompt),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 4_096),
      shouldCancel: { false })

    XCTAssertNil(result.failureCode, result.message ?? "")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: pwned.path),
      "shell metacharacters in taskDescription must not execute")
    let promptBody = try String(
      contentsOf: work.appendingPathComponent(TatwoAgentEngineBinding.promptFileName),
      encoding: .utf8)
    XCTAssertEqual(promptBody, evilPrompt)
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains(evilPrompt))
  }

  func testMissingAgentFailsClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "grok",
      script: "#!/bin/sh\necho ok\n")

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "no agent field", agent: nil),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 256),
      shouldCancel: { false })
    XCTAssertEqual(result.failureCode, "agent_unspecified")
  }

  func testMissingExactModelRouteFailsBeforeAgentLaunch() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: "#!/bin/sh\necho SHOULD_NOT_RUN\n")

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(
        description: "plain claude is forbidden",
        agent: .claude,
        includeExactModelRoute: false),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 256),
      shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_model_route_required")
    XCTAssertFalse(
      String(data: result.outputData, encoding: .utf8)?.contains("SHOULD_NOT_RUN") ?? false)
  }

  func testClaudeFableRouteCannotLaunchAsOpus() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        body=$(cat)
        case "$*" in
          *"--model claude-fable-5"*)
            printf '%s\\n' \
              '{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"ok"}]}}'
            printf '{"type":"result","result":"ARGV=%s","modelUsage":{"claude-fable-5":{}}}\\n' "$*"
            exit 0
            ;;
          *) echo "WRONG_MODEL_ROUTE" >&2; exit 9 ;;
        esac
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "must stay on fable", agent: .claude),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 1_024),
      shouldCancel: { false })

    XCTAssertNil(result.failureCode, result.message ?? "")
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("--model claude-fable-5"), output)
    XCTAssertFalse(output.contains("claude-opus-5"), output)
    XCTAssertEqual(
      result.modelExecutionAttestation?.outcome,
      .verifiedExact)
    XCTAssertEqual(
      result.modelExecutionAttestation?.observedAssistantModelIDs,
      ["claude-fable-5"])
  }

  func testClaudeFableFailsClosedWhenAssistantStreamSwitchesToOpus() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' \
          '{"type":"assistant","message":{"model":"claude-fable-5","content":[{"type":"text","text":"start"}]}}'
        printf '%s\\n' \
          '{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"fallback"}]}}'
        printf '%s\\n' \
          '{"type":"result","result":"MUST_NOT_COUNT","modelUsage":{"claude-fable-5":{},"claude-opus-5[1m]":{}}}'
        exit 0
        """)

    let result = try TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
      .run(
        task: task(description: "fable only", agent: .claude),
        workPath: work,
        caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 4_096),
        shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_model_route_mismatch")
    XCTAssertEqual(result.exitCode, -1)
    XCTAssertTrue(result.outputData.isEmpty)
    XCTAssertEqual(
      result.modelExecutionAttestation?.outcome,
      .failClosedMismatch)
    XCTAssertEqual(
      result.modelExecutionAttestation?.observedAssistantModelIDs,
      ["claude-fable-5", "claude-opus-5"])
    XCTAssertEqual(
      result.modelExecutionAttestation?.modelUsageKeys,
      ["claude-fable-5", "claude-opus-5"])
  }

  func testClaudeFableFailsClosedWhenProviderOmitsModelAttestation() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        cat >/dev/null
        echo "plain unverified output"
        exit 0
        """)

    let result = try TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
      .run(
        task: task(description: "must attest", agent: .claude),
        workPath: work,
        caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 4_096),
        shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_model_attestation_missing")
    XCTAssertEqual(
      result.modelExecutionAttestation?.outcome,
      .attestationMissing)
  }

  func testResolveExecutableRejectsNonAllowlistedPathEquality() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let allowed = Set(engine.allowedExecutablePaths())
    // Classic prefix confusion: home/.local/bin/grok-evil is not grok.
    XCTAssertFalse(allowed.contains(home.appendingPathComponent(".local/bin/grok-evil").path))
    XCTAssertNil(engine.resolveExecutablePath(for: .grok))
    XCTAssertNil(engine.resolveExecutablePath(for: .codex))
    XCTAssertNil(engine.resolveExecutablePath(for: .claude))
  }

  /// R5: Claude capability requires bounded stdin `-p` transport probe, not executable alone.
  func testClaudeCapabilityRequiresTransportProbe() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // Executable exists but ignores `-p`/stdin and hangs — must not declare capability.
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        sleep 30
        exit 0
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    XCTAssertNotNil(engine.resolveExecutablePath(for: .claude))
    XCTAssertFalse(
      engine.detectCapableAgents().contains(.claude),
      "hanging claude must not declare .claude capability")
    XCTAssertThrowsError(try engine.probeTransport(for: .claude)) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("agent_transport_unsupported") || text.contains("probe"),
        text)
    }
    let result = try engine.run(
      task: task(description: "should fail transport", agent: .claude),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 1024),
      shouldCancel: { false })
    XCTAssertEqual(result.failureCode, "agent_transport_unsupported")
  }

  func testClaudeTransportProbePassesForStdinPrintMode() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        # Accept -p and drain stdin quickly.
        cat >/dev/null
        exit 0
        """)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    try engine.probeTransport(for: .claude)
    XCTAssertTrue(engine.detectCapableAgents().contains(.claude))
  }

  /// R5: quick non-zero "unknown option" is NOT capability (false-positive closed).
  func testClaudeProbeRejectsUnknownOptionNonZero() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        echo "unknown option: -p" >&2
        exit 2
        """)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    XCTAssertFalse(engine.detectCapableAgents().contains(.claude))
    XCTAssertThrowsError(try engine.probeTransport(for: .claude)) { error in
      let text = String(describing: error)
      XCTAssertTrue(
        text.contains("agent_transport_unsupported") || text.contains("rejects"),
        text)
    }
  }

  /// R5: auth-class non-zero after accepting transport still proves capability path.
  func testClaudeProbeAcceptsAuthClassNonZeroAsTransportProof() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        cat >/dev/null
        echo "Error: unauthorized — login required" >&2
        exit 1
        """)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    try engine.probeTransport(for: .claude)
    XCTAssertTrue(engine.detectCapableAgents().contains(.claude))
  }

  /// R5: ambiguous non-zero without markers must not claim capability.
  func testClaudeProbeRejectsAmbiguousNonZero() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try installFakeAgent(
      home: home,
      name: "claude",
      script: """
        #!/bin/sh
        exit 1
        """)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    XCTAssertFalse(engine.detectCapableAgents().contains(.claude))
    XCTAssertThrowsError(try engine.probeTransport(for: .claude))
  }

  func testCodexUsesStdinFromPromptFileNotShell() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    try installFakeAgent(
      home: home,
      name: "codex",
      script: """
        #!/bin/sh
        # Expect: exec -C <work> -
        echo "args=$*"
        echo "stdin=$(cat)"
        exit 0
        """)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let result = try engine.run(
      task: task(description: "codex-via-stdin", agent: .codex),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 4_096),
      shouldCancel: { false })
    XCTAssertNil(result.failureCode, result.message ?? "")
    let output = String(data: result.outputData, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("exec"))
    XCTAssertTrue(output.contains("stdin=codex-via-stdin"))
  }

  func testRunnerWithAgentEngineExecutesTatwoLoopWhenSandboxUnlocked() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let originDeviceID = "origin-agent"
    let targetDeviceID = "runner-agent"
    let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
    let originStore = MemoryDevicePrivateKeyStore()
    let runnerStore = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: originDeviceID,
      privateKeyStore: originStore,
      environment: testEnv)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: targetDeviceID,
      privateKeyStore: runnerStore,
      environment: testEnv)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let channelRoot = root.appendingPathComponent("channel")
    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: originTrust, environment: testEnv)
    let runnerChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: runnerTrust, environment: testEnv)

    let home = root.appendingPathComponent("home", isDirectory: true)
    let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
    let work = sandboxRoot.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try installFakeAgent(
      home: home,
      name: "grok",
      script: """
        #!/bin/sh
        prompt=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prompt-file) prompt="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "done:$(cat "$prompt")"
        exit 0
        """)

    let job = TatwoLoopJobV1(
      jobID: "job-agent-live",
      logicalJobID: "logical-job-agent-live",
      dispatchNonce: "nonce-agent-live",
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originDeviceID,
      targetDeviceID: targetDeviceID,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contractID,
          goalID: goalID,
          identity: .sub,
          mode: .s,
          taskDescription: "remote agent work",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 5, maxOutputBytes: 4_096),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: Date())
    _ = try originChannel.enqueue(job)

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated")
    let runner = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: targetDeviceID,
      pollIntervalSec: 0.01,
      environment: [
        TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
        TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
      ],
      sandboxRootURL: sandboxRoot,
      engine: engine,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-state", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("journal")))
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].status, .completed, receipts[0].message ?? "")
    XCTAssertNil(receipts[0].failureCode)
    let prompt = try String(
      contentsOf: work.appendingPathComponent(TatwoAgentEngineBinding.promptFileName),
      encoding: .utf8)
    XCTAssertEqual(prompt, "remote agent work")
  }

  func testDefaultEngineBindingIsSandboxProbeNotAgent() {
    // Production start default remains ProcessEngineBinding.sandboxProbe.
    XCTAssertEqual(ProcessEngineBinding.sandboxProbe.executablePath, "/bin/ls")
    // Agent engine is a distinct type enabled only via explicit CLI flag.
    let agent = TatwoAgentEngineBinding.production
    XCTAssertNil(agent.defaultAgent)
  }

  func testExactActiveSkillsProjectionReturnsAgentLoadedDigest() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let binding = try activeSkillBinding(root: root)
    try installFakeAgent(
      home: home,
      name: "grok",
      script: """
        #!/bin/sh
        test -f "$TATWO_ACTIVE_SKILLS_ROOT/review-skill/SKILL.md" || exit 7
        exit 0
        """)
    let isolatedHomes = root.appendingPathComponent("isolated", isDirectory: true)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated",
      isolatedHomesRootURL: isolatedHomes)

    let result = try engine.run(
      task: task(
        description: "load exact skills",
        activeSkillBinding: binding),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 1_024),
      shouldCancel: { false })

    XCTAssertNil(result.failureCode, result.message ?? "")
    XCTAssertEqual(
      result.expectedActiveSkillSetDigest,
      binding.expectedActiveSkillSetDigest)
    XCTAssertEqual(
      result.actualLoadedSkillSetDigest,
      binding.expectedActiveSkillSetDigest)
    let nativeSkills = isolatedHomes
      .appendingPathComponent("grok/.grok/skills", isDirectory: false)
    let projection = URL(
      fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(
        atPath: nativeSkills.path),
      isDirectory: true)
    XCTAssertTrue(
      projection.lastPathComponent.hasPrefix(
        "\(binding.expectedActiveSkillSetDigest)-"))
    let projectedRepository = projection.appendingPathComponent(
      "review-skill",
      isDirectory: true)
    let projectedRepositoryValues = try projectedRepository.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    XCTAssertEqual(projectedRepositoryValues.isDirectory, true)
    XCTAssertNotEqual(projectedRepositoryValues.isSymbolicLink, true)
    let projectedManifest = projectedRepository.appendingPathComponent(
      "SKILL.md",
      isDirectory: false)
    let projectedManifestValues = try projectedManifest.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    XCTAssertEqual(projectedManifestValues.isRegularFile, true)
    XCTAssertNotEqual(projectedManifestValues.isSymbolicLink, true)
  }

  func testAgentSkillProjectionMutationFailsClosed() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let binding = try activeSkillBinding(root: root)
    try installFakeAgent(
      home: home,
      name: "grok",
      script: """
        #!/bin/sh
        printf '%s\n' "tampered by agent" \
          > "$TATWO_ACTIVE_SKILLS_ROOT/review-skill/SKILL.md"
        exit 0
        """)
    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated",
      isolatedHomesRootURL: root.appendingPathComponent("isolated"))

    let result = try engine.run(
      task: task(
        description: "reject drift",
        activeSkillBinding: binding),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 1_024),
      shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_skill_projection_mismatch")
    XCTAssertEqual(
      result.expectedActiveSkillSetDigest,
      binding.expectedActiveSkillSetDigest)
    XCTAssertNotEqual(
      result.actualLoadedSkillSetDigest,
      binding.expectedActiveSkillSetDigest)
  }

  func testActiveSkillProjectionRejectsSourceSymlinkBeforeAgentLaunch() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let binding = try activeSkillBinding(root: root)
    let repository = binding.runtimeRootURL.appendingPathComponent(
      "review-skill",
      isDirectory: true)
    let manifest = repository.appendingPathComponent("SKILL.md", isDirectory: false)
    try FileManager.default.removeItem(at: manifest)
    let outside = root.appendingPathComponent("outside.md")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
    try installFakeAgent(
      home: home,
      name: "grok",
      script: "#!/bin/sh\necho SHOULD_NOT_RUN\n")

    let engine = TatwoAgentEngineBinding(
      homeDirectoryURL: home,
      realUserName: "test-user-no-isolated",
      isolatedHomesRootURL: root.appendingPathComponent("isolated"))

    let result = try engine.run(
      task: task(
        description: "reject source symlink",
        activeSkillBinding: binding),
      workPath: work,
      caps: TatwoLoopResourceCapsV1(maxDurationSec: 3, maxOutputBytes: 1_024),
      shouldCancel: { false })

    XCTAssertEqual(result.failureCode, "agent_skill_projection_failed")
    XCTAssertFalse(
      String(data: result.outputData, encoding: .utf8)?.contains("SHOULD_NOT_RUN") ?? false)
  }
}

/// In-memory private key store for unit tests only (no Keychain, no disk).
private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(
    deviceID: String,
    generation: UInt64
  ) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID):\(generation)"]
  }

  func storePrivateKey(
    _ key: Data,
    deviceID: String,
    generation: UInt64
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let slot = "\(deviceID):\(generation)"
    if let existing = keys[slot], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[slot] = key
  }
}
