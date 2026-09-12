import CryptoKit
import XCTest
@testable import TatwoUltraworkCore

final class HostExecutorTests: XCTestCase {
  private func fixture() throws -> (
    executor: TatwoHostExecutor, workspace: URL, store: TatwoGoalRunStore,
    contract: TatwoWorkOSContractV1, lease: TatwoHostApprovalLeaseV1
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-host-executor-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = TatwoGoalRunStore(directoryURL: root.appendingPathComponent("goals", isDirectory: true))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "debug", objective: "host executor tests", store: store)
    let approvalStore = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent("approvals", isDirectory: true),
      goalRunStore: store)
    let lease = try approvalStore.issue(
      contractID: contract.contractID,
      workspaceRoot: workspace.path,
      allowedActions: [.readFile, .writeFile, .runCommand, .rollback],
      ttl: 600)
    return (
      TatwoHostExecutor(
        approvalStore: approvalStore,
        backupRoot: root.appendingPathComponent("backups", isDirectory: true)),
      workspace, store, contract, lease)
  }

  func testWriteRequiresMatchingLeaseAndCreatesBackup() throws {
    let f = try fixture()
    let target = f.workspace.appendingPathComponent("Sources/value.txt")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: target)

    let receipt = try f.executor.writeFile(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      relativePath: "Sources/value.txt",
      content: "new")

    XCTAssertTrue(receipt.ok)
    XCTAssertTrue(receipt.hostMutationPerformed)
    XCTAssertNotNil(receipt.backupPath)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")

    let rollback = try f.executor.rollback(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      writeReceipt: receipt)
    XCTAssertTrue(rollback.ok)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
  }

  func testRollbackRemovesNewlyCreatedFile() throws {
    let f = try fixture()
    let target = f.workspace.appendingPathComponent("Sources/new.txt")
    let receipt = try f.executor.writeFile(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      relativePath: "Sources/new.txt",
      content: "new")

    XCTAssertFalse(receipt.originalExisted)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    _ = try f.executor.rollback(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      writeReceipt: receipt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  func testPathEscapeAndProtectedTargetsFailClosed() throws {
    let f = try fixture()
    XCTAssertThrowsError(try f.executor.writeFile(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, relativePath: "../escape", content: "x"))
    XCTAssertThrowsError(try f.executor.writeFile(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, relativePath: ".git/config", content: "x"))
  }

  func testProtectedCanonicalWorkspaceRootFailsClosed() throws {
    let f = try fixture()
    for component in [
      ".ssh", ".codex", "api-token", "cookie-store", "auth", "secrets",
    ] {
      let protectedRoot = f.workspace.deletingLastPathComponent()
        .appendingPathComponent(component, isDirectory: true)
      try FileManager.default.createDirectory(
        at: protectedRoot, withIntermediateDirectories: true)
      let lease = try f.executor.approvalStore.issue(
        contractID: f.contract.contractID,
        workspaceRoot: protectedRoot.path,
        allowedActions: [.readFile],
        ttl: 600)

      XCTAssertThrowsError(try f.executor.listFiles(
        contractID: f.contract.contractID,
        leaseID: lease.id,
        workspaceRoot: protectedRoot.path,
        relativePath: "."
      )) { error in
        XCTAssertEqual(
          error as? TatwoHostExecutorError,
          .protectedTarget,
          component)
      }
    }
  }

  func testProtectedPolicyAllowsOrdinaryTokenNamedProjectsAndFiles() throws {
    let f = try fixture()
    let ordinaryRoot = f.workspace.deletingLastPathComponent()
      .appendingPathComponent("token-service", isDirectory: true)
    try FileManager.default.createDirectory(
      at: ordinaryRoot.appendingPathComponent("cookie-jar"),
      withIntermediateDirectories: true)
    try Data("struct Tokenizer {}".utf8).write(
      to: ordinaryRoot.appendingPathComponent("Tokenizer.swift"))
    try Data("{}".utf8).write(
      to: ordinaryRoot.appendingPathComponent("design-tokens.json"))
    try Data("safe".utf8).write(
      to: ordinaryRoot.appendingPathComponent("cookie-jar/README.md"))
    for name in [
      "api-token.txt", "session-cookie.txt", "auth.json", "token.json",
      "tokens.json", "cookies.sqlite", "credentials.yaml", "token.pem",
      "auth.key", "api-token.log", "session-cookie.env", "credentials.ini",
      ".netrc", "id_rsa", "id_rsa.bak", ".netrc.bak", "auth.json.bak",
      "credentials.yaml.old", "token.pem.old",
    ] {
      try Data("secret".utf8).write(
        to: ordinaryRoot.appendingPathComponent(name))
    }
    let lease = try f.executor.approvalStore.issue(
      contractID: f.contract.contractID,
      workspaceRoot: ordinaryRoot.path,
      allowedActions: [.readFile],
      ttl: 600)

    let listed = try f.executor.listFiles(
      contractID: f.contract.contractID,
      leaseID: lease.id,
      workspaceRoot: ordinaryRoot.path)
    XCTAssertTrue(listed.result.contains("Tokenizer.swift"))
    XCTAssertTrue(listed.result.contains("design-tokens.json"))
    XCTAssertTrue(listed.result.contains("cookie-jar/README.md"))
    XCTAssertFalse(listed.result.contains("api-token.txt"))
    XCTAssertFalse(listed.result.contains("session-cookie.txt"))
    XCTAssertFalse(listed.result.contains("auth.json"))

    for path in ["Tokenizer.swift", "design-tokens.json", "cookie-jar/README.md"] {
      XCTAssertNoThrow(try f.executor.readFile(
        contractID: f.contract.contractID,
        leaseID: lease.id,
        workspaceRoot: ordinaryRoot.path,
        relativePath: path))
    }
    for path in [
      "api-token.txt", "session-cookie.txt", "auth.json", "token.json",
      "tokens.json", "cookies.sqlite", "credentials.yaml", "token.pem",
      "auth.key", "api-token.log", "session-cookie.env", "credentials.ini",
      ".netrc", "id_rsa", "id_rsa.bak", ".netrc.bak", "auth.json.bak",
      "credentials.yaml.old", "token.pem.old",
    ] {
      XCTAssertThrowsError(try f.executor.readFile(
        contractID: f.contract.contractID,
        leaseID: lease.id,
        workspaceRoot: ordinaryRoot.path,
        relativePath: path
      )) { error in
        XCTAssertEqual(error as? TatwoHostExecutorError, .protectedTarget, path)
      }
    }
  }

  func testNativeOperationLeaseBlocksPlannedMutationButAllowsReadAndActiveMutation() throws {
    let f = try fixture()
    let approvalStore = f.executor.approvalStore

    XCTAssertNoThrow(try approvalStore.issueNativeOperationBound(
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .readFile,
      argumentDigest: "read-digest"))

    XCTAssertThrowsError(try approvalStore.issueNativeOperationBound(
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .writeFile,
      argumentDigest: "planned-write-digest"
    )) { error in
      XCTAssertEqual(error as? TatwoHostExecutorError, .approvalRequired)
    }

    _ = try f.store.updateStatus(
      contractID: f.contract.contractID,
      status: .dispatching)
    XCTAssertNoThrow(try approvalStore.issueNativeOperationBound(
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .writeFile,
      argumentDigest: "active-write-digest"))
  }

  func testExactMutationLeaseCannotBeConsumedAfterGoalLeavesActiveExecution() throws {
    let f = try fixture()
    let approvalStore = f.executor.approvalStore
    let digest = "active-write-digest"
    _ = try f.store.updateStatus(
      contractID: f.contract.contractID,
      status: .dispatching)
    let lease = try approvalStore.issueNativeOperationBound(
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .writeFile,
      argumentDigest: digest)

    XCTAssertNoThrow(try approvalStore.require(
      id: lease.id,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .writeFile,
      argumentDigest: digest))

    _ = try f.store.updateStatus(
      contractID: f.contract.contractID,
      status: .blocked,
      authority: .ledgerBeginAck,
      evidence: .reconciliation(stage: "test"))

    XCTAssertThrowsError(try approvalStore.require(
      id: lease.id,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      action: .writeFile,
      argumentDigest: digest
    )) { error in
      XCTAssertEqual(error as? TatwoHostExecutorError, .approvalRequired)
    }
  }

  func testListAndSearchCapVisibleTextButHashCompleteResults() throws {
    let f = try fixture()
    let names = (0..<1_200).map {
      String(format: "Sources/file-%04d-%040d.swift", $0, $0)
    }
    try FileManager.default.createDirectory(
      at: f.workspace.appendingPathComponent("Sources"),
      withIntermediateDirectories: true)
    for name in names {
      try Data("safe".utf8).write(
        to: f.workspace.appendingPathComponent(name))
    }
    let listed = try f.executor.listFiles(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path)
    let completeList = names.sorted().joined(separator: "\n")
    XCTAssertTrue(listed.result.contains("<tatwo-truncated original_bytes="))
    XCTAssertLessThan(listed.result.utf8.count, 66 * 1024)
    XCTAssertEqual(
      listed.contentSHA256,
      SHA256.hash(data: Data(completeList.utf8)).map {
        String(format: "%02x", $0)
      }.joined())

    let lines = (1...1_000).map {
      "HIT \(String(repeating: "x", count: 90)) \($0)"
    }
    try Data(lines.joined(separator: "\n").utf8).write(
      to: f.workspace.appendingPathComponent("large-search.txt"))
    let searched = try f.executor.searchFiles(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      query: "HIT",
      maximumMatches: 2_000)
    let completeSearch = lines.enumerated().map {
      "large-search.txt:\($0.offset + 1):\($0.element)"
    }.joined(separator: "\n")
    XCTAssertTrue(searched.result.contains("<tatwo-truncated original_bytes="))
    XCTAssertLessThan(searched.result.utf8.count, 66 * 1024)
    XCTAssertEqual(
      searched.contentSHA256,
      SHA256.hash(data: Data(completeSearch.utf8)).map {
        String(format: "%02x", $0)
      }.joined())
  }

  func testListAndSearchNeverExposeProtectedOrSymlinkDescendants() throws {
    let f = try fixture()
    try Data("SAFE_NEEDLE".utf8).write(
      to: f.workspace.appendingPathComponent("safe.txt"))
    try FileManager.default.createDirectory(
      at: f.workspace.appendingPathComponent("secrets"),
      withIntermediateDirectories: true)
    try Data("SECRET_NEEDLE".utf8).write(
      to: f.workspace.appendingPathComponent("secrets/auth.json"))
    try Data("TOKEN_NEEDLE".utf8).write(
      to: f.workspace.appendingPathComponent("secrets/api-token.txt"))
    let outside = f.workspace.deletingLastPathComponent()
      .appendingPathComponent("outside-cookie.txt")
    try Data("COOKIE_NEEDLE".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: f.workspace.appendingPathComponent("linked-secret.txt"),
      withDestinationURL: outside)

    let listed = try f.executor.listFiles(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path)
    let searched = try f.executor.searchFiles(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      query: "NEEDLE")

    XCTAssertTrue(listed.result.contains("safe.txt"))
    XCTAssertFalse(listed.result.contains("auth.json"))
    XCTAssertFalse(listed.result.contains("token"))
    XCTAssertFalse(listed.result.contains("linked-secret"))
    XCTAssertTrue(searched.result.contains("safe.txt:1:SAFE_NEEDLE"))
    XCTAssertFalse(searched.result.contains("SECRET_NEEDLE"))
    XCTAssertFalse(searched.result.contains("TOKEN_NEEDLE"))
    XCTAssertFalse(searched.result.contains("COOKIE_NEEDLE"))
  }

  func testUnknownLeaseFailsClosed() throws {
    let f = try fixture()
    XCTAssertThrowsError(try f.executor.writeFile(
      contractID: f.contract.contractID, leaseID: "lease-missing",
      workspaceRoot: f.workspace.path, relativePath: "safe.txt", content: "x"))
  }

  func testLeaseCanBeRevokedAndExpiredLeasesCanBeCleaned() throws {
    let f = try fixture()
    try f.executor.approvalStore.revoke(id: f.lease.id)
    XCTAssertThrowsError(try f.executor.writeFile(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, relativePath: "safe.txt", content: "x"))

    let expired = try f.executor.approvalStore.issue(
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      allowedActions: [.readFile],
      ttl: 60,
      now: Date(timeIntervalSince1970: 1))
    let removed = try f.executor.approvalStore.cleanupExpired(now: Date())
    XCTAssertTrue(removed.contains(expired.id))
  }

  func testSymlinkTargetFailsClosed() throws {
    let f = try fixture()
    let outside = f.workspace.deletingLastPathComponent().appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    let link = f.workspace.appendingPathComponent("linked.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try f.executor.writeFile(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, relativePath: "linked.txt", content: "escape"))
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
  }

  func testMCPManifestExposesExecutorWithoutApprovalIssuerTool() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.host.plan"))
    XCTAssertTrue(names.contains("tatwo.host.authorize_revision"))
    XCTAssertTrue(names.contains("tatwo.host.read_file"))
    XCTAssertTrue(names.contains("tatwo.host.write_file"))
    XCTAssertTrue(names.contains("tatwo.host.run_command"))
    XCTAssertTrue(names.contains("tatwo.host.rollback"))
    XCTAssertFalse(names.contains("tatwo.host.authorize"))

    let result = TatwoMCPRegistry.call(tool: "tatwo.host.plan")
    XCTAssertTrue(result.ok)
    XCTAssertFalse(result.hostMutationAllowed)
  }

  func testMCPManifestKeepsInternalLeaseTerminologyOutOfUserFacingPurposes() {
    let userFacingTools = TatwoMCPRegistry.tools.filter {
      $0.name.hasPrefix("tatwo.host.") || $0.name.hasPrefix("tatwo.computer.")
    }

    XCTAssertFalse(userFacingTools.isEmpty)
    for tool in userFacingTools {
      XCTAssertFalse(tool.plainPurpose.localizedCaseInsensitiveContains("human lease"), tool.name)
      XCTAssertFalse(tool.plainPurpose.localizedCaseInsensitiveContains("approval lease"), tool.name)
      XCTAssertFalse(tool.plainPurpose.localizedCaseInsensitiveContains("人工 lease"), tool.name)
    }
  }

  #if os(macOS)
  func testCommandAllowlistRejectsShellAndAllowsSwiftVersion() throws {
    let f = try fixture()
    XCTAssertThrowsError(try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/bin/zsh",
      arguments: ["-c", "echo unsafe"]))
    let receipt = try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/usr/bin/swift",
      arguments: ["--version"], timeout: 30)
    XCTAssertTrue(receipt.ok)
    XCTAssertTrue(receipt.result.lowercased().contains("swift"))
    XCTAssertFalse(receipt.hostMutationPerformed)
  }

  func testCommandAllowlistRejectsArbitraryNodeAndPackageManagerExecution() throws {
    let f = try fixture()
    XCTAssertThrowsError(try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/usr/bin/node",
      arguments: ["script.js"]))
    XCTAssertThrowsError(try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/opt/homebrew/bin/pnpm",
      arguments: ["exec", "sh"]))
    XCTAssertThrowsError(try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/usr/bin/swift",
      arguments: ["test", "--package-path", "/tmp/other"]))
  }

  func testEveryAllowedCommandFailsClosedForProtectedCanonicalWorkspaceRoot()
    throws
  {
    let f = try fixture()
    let protectedRoot = f.workspace.deletingLastPathComponent()
      .appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(
      at: protectedRoot, withIntermediateDirectories: true)
    let lease = try f.executor.approvalStore.issue(
      contractID: f.contract.contractID,
      workspaceRoot: protectedRoot.path,
      allowedActions: [.runCommand],
      ttl: 600)
    let commands: [(String, [String])] = [
      ("/opt/homebrew/bin/node", ["--version"]),
      ("/opt/homebrew/bin/npm", ["--version"]),
      ("/opt/homebrew/bin/npm", ["test"]),
      ("/opt/homebrew/bin/npm", ["run", "lint"]),
      ("/opt/homebrew/bin/pnpm", ["--version"]),
      ("/opt/homebrew/bin/pnpm", ["test"]),
      ("/opt/homebrew/bin/pnpm", ["run", "lint"]),
      ("/usr/bin/xcodebuild", ["-version"]),
      ("/bin/sleep", ["0"]),
    ]

    for (executable, arguments) in commands {
      XCTAssertThrowsError(try f.executor.runCommand(
        contractID: f.contract.contractID,
        leaseID: lease.id,
        workspaceRoot: protectedRoot.path,
        executable: executable,
        arguments: arguments
      )) { error in
        XCTAssertEqual(
          error as? TatwoHostExecutorError,
          .protectedTarget,
          "\(executable) \(arguments.joined(separator: " "))")
      }
    }
  }

  func testGitCommandsRejectRepositoryEscapeAndProtectedPathArguments() throws {
    let f = try fixture()
    let outside = f.workspace.deletingLastPathComponent()
      .appendingPathComponent("outside-secret.txt")
    try Data("EXFILTRATION_MARKER".utf8).write(to: outside)
    try FileManager.default.createDirectory(
      at: f.workspace.appendingPathComponent(".ssh"),
      withIntermediateDirectories: true)
    try Data("PROTECTED_MARKER".utf8).write(
      to: f.workspace.appendingPathComponent(".ssh/key"))

    for arguments in [
      ["diff", "--no-index", outside.path, "/dev/null"],
      ["diff", "--git-dir=\(outside.path)", "HEAD"],
      ["diff", "--work-tree", outside.path, "HEAD"],
      ["diff", "-c", "core.pager=cat", "HEAD"],
      ["diff", "--", outside.path],
      ["diff", "--", ".ssh/key"],
      ["status", "--short", "--", outside.path],
      ["status", "--short", "--", ".ssh/key"],
      ["diff", "--output=/tmp/tatwo-git-output"],
      ["diff", "--output", "/tmp/tatwo-git-output"],
      ["diff", "--unknown-output=/tmp/tatwo-git-output"],
    ] {
      XCTAssertThrowsError(try f.executor.runCommand(
        contractID: f.contract.contractID,
        leaseID: f.lease.id,
        workspaceRoot: f.workspace.path,
        executable: "/usr/bin/git",
        arguments: arguments
      )) { error in
        XCTAssertEqual(
          error as? TatwoHostExecutorError,
          .commandDenied,
          arguments.joined(separator: " "))
      }
    }
  }

  func testGitShowLogRevisionPathsAndAttachedPathOptionsFailClosed() throws {
    let f = try fixture()
    for arguments in [
      ["show", "HEAD:.ssh/id_rsa"],
      ["log", "HEAD:.ssh/id_rsa"],
      ["diff", "HEAD~1:.ssh/id_rsa", "HEAD:.ssh/id_rsa"],
      ["log", "-L1,2:.ssh/id_rsa"],
      ["log", "-p", "--", "*id_rsa"],
      ["diff", "--", "*.env"],
      ["show", "HEAD"],
      ["diff", "HEAD~1"],
      ["diff", "-O/tmp/tatwo-order-file"],
    ] {
      XCTAssertThrowsError(try f.executor.runCommand(
        contractID: f.contract.contractID,
        leaseID: f.lease.id,
        workspaceRoot: f.workspace.path,
        executable: "/usr/bin/git",
        arguments: arguments
      )) { error in
        XCTAssertEqual(
          error as? TatwoHostExecutorError,
          .commandDenied,
          arguments.joined(separator: " "))
      }
    }

    XCTAssertNoThrow(try f.executor.runCommand(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      executable: "/usr/bin/git",
      arguments: ["status", "--porcelain"]))
  }

  func testGitDiffRejectsBroadDirectoriesContainingProtectedFilesButAllowsOrdinaryFile()
    throws
  {
    let f = try fixture()
    let files = [
      ".codex/auth.json": "AUTH_SECRET",
      "Sources/.env": "ENV_SECRET",
      "Config/credentials.yaml": "CREDENTIAL_SECRET",
      "secrets/value.txt": "GENERIC_SECRET",
      "Sources/App.swift": "let value = 1\n",
    ]
    for (path, content) in files {
      let url = f.workspace.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    try runFixtureGit(["init", "-q"], in: f.workspace)
    try runFixtureGit(["add", "."], in: f.workspace)
    try runFixtureGit(
      [
        "-c", "user.name=TATWO Test",
        "-c", "user.email=tatwo@example.invalid",
        "commit", "-qm", "protected pathspec fixture",
      ],
      in: f.workspace)
    for path in files.keys {
      try Data("\(files[path]!)changed\n".utf8).write(
        to: f.workspace.appendingPathComponent(path))
    }

    for broadPathspec in [".", "Sources", "Config", "secrets"] {
      XCTAssertThrowsError(try f.executor.runCommand(
        contractID: f.contract.contractID,
        leaseID: f.lease.id,
        workspaceRoot: f.workspace.path,
        executable: "/usr/bin/git",
        arguments: ["diff", "--no-ext-diff", "--", broadPathspec]
      )) { error in
        XCTAssertEqual(
          error as? TatwoHostExecutorError,
          .commandDenied,
          broadPathspec)
      }
    }

    let safe = try f.executor.runCommand(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      executable: "/usr/bin/git",
      arguments: ["diff", "--no-ext-diff", "--", "Sources/App.swift"])
    XCTAssertTrue(safe.ok)
    XCTAssertTrue(safe.result.contains("Sources/App.swift"))
    XCTAssertFalse(safe.result.contains("AUTH_SECRET"))
    XCTAssertFalse(safe.result.contains("ENV_SECRET"))
    XCTAssertFalse(safe.result.contains("CREDENTIAL_SECRET"))
    XCTAssertFalse(safe.result.contains("GENERIC_SECRET"))
  }

  func testRunCommandDrainsLargeOutputWithoutPipeDeadlock() throws {
    let f = try fixture()
    let large = Data(repeating: 65, count: 512 * 1024)
    try large.write(to: f.workspace.appendingPathComponent("large.txt"))
    try runFixtureGit(["init", "-q"], in: f.workspace)
    try runFixtureGit(["add", "large.txt"], in: f.workspace)
    try runFixtureGit(
      [
        "-c", "user.name=TATWO Test",
        "-c", "user.email=tatwo@example.invalid",
        "commit", "-qm", "large output fixture",
      ],
      in: f.workspace)
    let changed = Data(repeating: 66, count: 512 * 1024)
    try changed.write(to: f.workspace.appendingPathComponent("large.txt"))
    let expectedOutput = try fixtureGitOutput(
      ["diff", "--no-ext-diff", "--", "large.txt"],
      in: f.workspace)

    let receipt = try f.executor.runCommand(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      executable: "/usr/bin/git",
      arguments: ["diff", "--no-ext-diff", "--", "large.txt"],
      timeout: 2)

    XCTAssertTrue(receipt.ok)
    XCTAssertEqual(receipt.exitCode, 0)
    XCTAssertEqual(receipt.result.utf8.count, 8 * 1024)
    XCTAssertEqual(
      receipt.contentSHA256,
      SHA256.hash(data: expectedOutput).map {
        String(format: "%02x", $0)
      }.joined())
    XCTAssertNotEqual(receipt.outcome, .timeout)
  }

  func testRunCommandFailsClosedWhenDescendantKeepsOutputPipeOpen() throws {
    let npm = "/opt/homebrew/bin/npm"
    guard FileManager.default.isExecutableFile(atPath: npm) else {
      throw XCTSkip("npm is required for the inherited-output-pipe regression")
    }
    let f = try fixture()
    try Data(
      #"{"scripts":{"test":"printf EARLY_OUTPUT; (sleep 3) &"}}"#.utf8
    ).write(to: f.workspace.appendingPathComponent("package.json"))

    let receipt = try f.executor.runCommand(
      contractID: f.contract.contractID,
      leaseID: f.lease.id,
      workspaceRoot: f.workspace.path,
      executable: npm,
      arguments: ["test"],
      timeout: 10)

    XCTAssertFalse(receipt.ok)
    XCTAssertEqual(receipt.exitCode, 0)
    XCTAssertEqual(receipt.outcome.rawValue, "output_incomplete")
    XCTAssertTrue(receipt.result.contains("EARLY_OUTPUT"))
    XCTAssertNil(receipt.contentSHA256)
  }

  func testCommandTimeoutReturnsExplicitReceipt() throws {
    let f = try fixture()
    let receipt = try f.executor.runCommand(
      contractID: f.contract.contractID, leaseID: f.lease.id,
      workspaceRoot: f.workspace.path, executable: "/bin/sleep",
      arguments: ["2"], timeout: 0.05)
    XCTAssertFalse(receipt.ok)
    XCTAssertEqual(receipt.result, "timeout")
    XCTAssertEqual(receipt.outcome, .timeout)
  }

  private func runFixtureGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
  }

  private func fixtureGitOutput(
    _ arguments: [String],
    in directory: URL
  ) throws -> Data {
    let outputURL = directory.appendingPathComponent(
      ".git-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: outputURL)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: outputURL)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    try handle.synchronize()
    return try Data(contentsOf: outputURL)
  }
  #endif
}
