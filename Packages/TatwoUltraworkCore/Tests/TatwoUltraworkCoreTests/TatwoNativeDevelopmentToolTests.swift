import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoNativeDevelopmentToolTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let workspace: URL
    let contract: TatwoWorkOSContractV1
    let lease: TatwoHostApprovalLeaseV1
    let host: TatwoHostExecutor
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-native-tools-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = TatwoGoalRunStore(
      directoryURL: root.appendingPathComponent("goals", isDirectory: true))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "native development tool tests",
      store: store)
    let approvalStore = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent("approvals", isDirectory: true),
      goalRunStore: store)
    let lease = try approvalStore.issue(
      contractID: contract.contractID,
      workspaceRoot: workspace.path,
      allowedActions: [.readFile, .writeFile, .runCommand, .rollback],
      ttl: 600)
    return Fixture(
      root: root,
      workspace: workspace,
      contract: contract,
      lease: lease,
      host: TatwoHostExecutor(
        approvalStore: approvalStore,
        backupRoot: root.appendingPathComponent("backups", isDirectory: true),
        goalRunStore: store))
  }

  private func executor(
    _ fixture: Fixture,
    readOnly: Bool = false,
    leaseID: String? = nil
  ) -> TatwoNativeDevelopmentToolExecutor {
    TatwoNativeDevelopmentToolExecutor(
      hostExecutor: fixture.host,
      authorizationProvider: TatwoNativeStaticHostAuthorizationProvider(
        leaseID: leaseID ?? fixture.lease.id),
      contractID: fixture.contract.contractID,
      workspaceRoot: fixture.workspace.path,
      readOnly: readOnly)
  }

  func testCatalogDeclaresCompleteNativeDevelopmentSurface() {
    XCTAssertEqual(
      Set(TatwoNativeDevelopmentToolCatalog.definitions.map(\.name)),
      Set([
        "list_files", "read_file", "search", "write_file", "edit_file",
        "run_command", "git_status", "git_diff", "build", "test", "rollback",
      ]))
  }

  func testReadOnlyCatalogExposesOnlyNonMutatingTools() {
    XCTAssertEqual(
      Set(TatwoNativeDevelopmentToolCatalog.definitions(
        readOnly: true).map(\.name)),
      Set([
        "list_files", "read_file", "search", "run_command", "git_status",
        "git_diff",
      ]))
  }

  func testListReadAndSearchUseWorkspaceBoundHostAuthorization() async throws {
    let f = try fixture()
    let source = f.workspace.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("struct App { // NEEDLE\\n}\\n".utf8).write(to: source)
    let toolExecutor = executor(f)

    let listed = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "list",
      name: "list_files",
      argumentsJSON: #"{"path":"Sources"}"#))
    let read = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "read",
      name: "read_file",
      argumentsJSON: #"{"path":"Sources/App.swift"}"#))
    let searched = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "search",
      name: "search",
      argumentsJSON: #"{"path":"Sources","query":"NEEDLE"}"#))

    XCTAssertFalse(listed.isError)
    XCTAssertTrue(listed.output.contains("Sources/App.swift"))
    XCTAssertFalse(read.isError)
    XCTAssertTrue(read.output.contains("struct App"))
    XCTAssertFalse(searched.isError)
    XCTAssertTrue(searched.output.contains("Sources/App.swift:1"))
  }

  func testFileToolsAcceptAbsolutePathsOnlyWhenTheyStayInsideWorkspace()
    async throws
  {
    let f = try fixture()
    let source = f.workspace.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("struct App { // NEEDLE\n}\n".utf8).write(to: source)
    let toolExecutor = executor(f)

    let listed = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-list",
      name: "list_files",
      argumentsJSON:
        #"{"path":"\#(source.deletingLastPathComponent().path)"}"#))
    let read = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-read",
      name: "read_file",
      argumentsJSON: #"{"path":"\#(source.path)"}"#))
    let searched = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-search",
      name: "search",
      argumentsJSON:
        #"{"path":"\#(source.deletingLastPathComponent().path)","query":"NEEDLE"}"#))
    let writtenURL = f.workspace.appendingPathComponent("absolute-write.txt")
    let written = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-write",
      name: "write_file",
      argumentsJSON:
        #"{"path":"\#(writtenURL.path)","content":"absolute"}"#))
    let edited = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-edit",
      name: "edit_file",
      argumentsJSON:
        #"{"path":"\#(source.path)","old_text":"NEEDLE","new_text":"FOUND"}"#))

    XCTAssertFalse(listed.isError)
    XCTAssertTrue(listed.output.contains("Sources/App.swift"))
    XCTAssertFalse(read.isError)
    XCTAssertTrue(read.output.contains("struct App"))
    XCTAssertFalse(searched.isError)
    XCTAssertTrue(searched.output.contains("Sources/App.swift:1"))
    XCTAssertFalse(written.isError)
    XCTAssertEqual(
      try String(contentsOf: writtenURL, encoding: .utf8),
      "absolute")
    XCTAssertFalse(edited.isError)
    XCTAssertEqual(
      try String(contentsOf: source, encoding: .utf8),
      "struct App { // FOUND\n}\n")
  }

  func testReadRejectsAbsolutePathOutsideWorkspace() async throws {
    let f = try fixture()
    let outside = f.root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    let toolExecutor = executor(f)

    let read = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "absolute-outside",
      name: "read_file",
      argumentsJSON: #"{"path":"\#(outside.path)"}"#))

    XCTAssertTrue(read.isError)
    XCTAssertTrue(read.output.contains("invalid_relative_path"))
    XCTAssertFalse(read.output.contains("outside"))
  }

  func testWriteEditDiffAndRollbackProduceReceiptsAndRestoreContent() async throws {
    let f = try fixture()
    let target = f.workspace.appendingPathComponent("value.txt")
    try Data("old value\\n".utf8).write(to: target)
    let toolExecutor = executor(f)

    let edit = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "edit",
      name: "edit_file",
      argumentsJSON:
        #"{"path":"value.txt","old_text":"old value","new_text":"new value"}"#))
    XCTAssertFalse(edit.isError)
    XCTAssertTrue(edit.output.contains("\"backup_path\""))
    XCTAssertTrue(edit.output.contains("-old value"))
    XCTAssertTrue(edit.output.contains("+new value"))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new value\\n")

    let receiptID = try XCTUnwrap(
      TatwoNativeDevelopmentToolOutput.decode(edit.output).receiptID)
    let rollback = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "rollback",
      name: "rollback",
      argumentsJSON: #"{"receipt_id":"\#(receiptID)"}"#))

    XCTAssertFalse(rollback.isError)
    XCTAssertTrue(rollback.output.contains("\"outcome\":\"rolled_back\""))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old value\\n")
  }

  func testReadOnlyModeRejectsEveryMutatingToolBeforeHostMutation() async throws {
    let f = try fixture()
    let toolExecutor = executor(f, readOnly: true)

    for (name, arguments) in [
      ("write_file", #"{"path":"blocked.txt","content":"x"}"#),
      ("edit_file", #"{"path":"blocked.txt","old_text":"a","new_text":"b"}"#),
      ("run_command", #"{"executable":"/usr/bin/swift","arguments":["build"]}"#),
      ("build", #"{"executable":"/usr/bin/swift","arguments":["build"]}"#),
      ("test", #"{"executable":"/usr/bin/swift","arguments":["test"]}"#),
      ("rollback", #"{"receipt_id":"missing"}"#),
    ] {
      let result = try await toolExecutor.execute(
        TatwoNativeToolCall(id: name, name: name, argumentsJSON: arguments))
      XCTAssertTrue(result.isError, name)
      XCTAssertTrue(result.output.contains("read_only"), name)
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.workspace.appendingPathComponent("blocked.txt").path))
  }

  func testApproveForMeProviderMintsExactShortLivedLeaseAfterArgumentsExist()
    async throws
  {
    let f = try fixture()
    _ = try f.host.goalRunStore.updateStatus(
      contractID: f.contract.contractID,
      status: .dispatching)
    let provider = TatwoNativeExactHostAuthorizationProvider(
      approvalStore: f.host.approvalStore,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      allowsMutation: true)
    let toolExecutor = TatwoNativeDevelopmentToolExecutor(
      hostExecutor: f.host,
      authorizationProvider: provider,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      readOnly: false)

    let result = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "write",
      name: "write_file",
      argumentsJSON: #"{"path":"exact.txt","content":"native"}"#))

    XCTAssertFalse(result.isError)
    let leases = try FileManager.default.contentsOfDirectory(
      at: f.host.approvalStore.directoryURL,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let exactLeases = try leases.map {
      try decoder.decode(
        TatwoHostApprovalLeaseV1.self, from: Data(contentsOf: $0))
    }.filter { $0.argumentDigest != nil && $0.allowedActions == [.writeFile] }
    XCTAssertEqual(exactLeases.count, 1)
    let exactLease = try XCTUnwrap(exactLeases.first)
    XCTAssertLessThanOrEqual(
      exactLease.expiresAt.timeIntervalSince(exactLease.issuedAt), 60)
    XCTAssertEqual(
      try String(
        contentsOf: f.workspace.appendingPathComponent("exact.txt"),
        encoding: .utf8),
      "native")
  }

  func testReadOnlyExactProviderDoesNotMintMutationLease() async throws {
    let f = try fixture()
    let provider = TatwoNativeExactHostAuthorizationProvider(
      approvalStore: f.host.approvalStore,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      allowsMutation: false)
    let toolExecutor = TatwoNativeDevelopmentToolExecutor(
      hostExecutor: f.host,
      authorizationProvider: provider,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      readOnly: true)

    let result = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "write",
      name: "write_file",
      argumentsJSON: #"{"path":"blocked.txt","content":"x"}"#))

    XCTAssertTrue(result.isError)
    XCTAssertTrue(result.output.contains("read_only"))
    let leaseURLs = (try? FileManager.default.contentsOfDirectory(
      at: f.host.approvalStore.directoryURL,
      includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let mintedMutationLease = leaseURLs.contains { url in
      guard let data = try? Data(contentsOf: url),
        let lease = try? decoder.decode(TatwoHostApprovalLeaseV1.self, from: data)
      else { return false }
      return lease.argumentDigest != nil
        && lease.allowedActions.contains(.writeFile)
    }
    XCTAssertFalse(mintedMutationLease)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.workspace.appendingPathComponent("blocked.txt").path))
  }

  func testSuccessorMarkedContractUsesRevisionBoundAuthorizationBranch()
    throws
  {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/TatwoUltraworkCore/TatwoNativeDevelopmentTools.swift"),
      encoding: .utf8)
    let branch = try XCTUnwrap(source.range(
      of: "if goal.supersession != nil"))
    let nativeIssuer = try XCTUnwrap(source.range(
      of: "return try approvalStore.issueNativeOperationBound(",
      range: branch.upperBound..<source.endIndex))
    let revisionBranch = String(
      source[branch.lowerBound..<nativeIssuer.lowerBound])

    XCTAssertTrue(revisionBranch.contains("goal.predecessorContractID != nil"))
    XCTAssertTrue(revisionBranch.contains("goal.successorContractID != nil"))
    XCTAssertTrue(revisionBranch.contains("exactAppAuthorizationID"))
  }

  func testRawShellPathEscapeSymlinkAndWrongLeaseFailClosed() async throws {
    let f = try fixture()
    let outside = f.root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: f.workspace.appendingPathComponent("link.txt"),
      withDestinationURL: outside)

    let valid = executor(f)
    let shell = try await valid.execute(TatwoNativeToolCall(
      id: "shell",
      name: "run_command",
      argumentsJSON: #"{"executable":"/bin/zsh","arguments":["-c","echo unsafe"]}"#))
    let escape = try await valid.execute(TatwoNativeToolCall(
      id: "escape",
      name: "write_file",
      argumentsJSON: #"{"path":"../escape.txt","content":"x"}"#))
    let symlink = try await valid.execute(TatwoNativeToolCall(
      id: "symlink",
      name: "write_file",
      argumentsJSON: #"{"path":"link.txt","content":"x"}"#))
    let wrongLease = try await executor(f, leaseID: "missing").execute(
      TatwoNativeToolCall(
        id: "lease",
        name: "read_file",
        argumentsJSON: #"{"path":"link.txt"}"#))

    XCTAssertTrue(shell.isError)
    XCTAssertTrue(escape.isError)
    XCTAssertTrue(symlink.isError)
    XCTAssertTrue(wrongLease.isError)
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
  }

  #if os(macOS)
  func testGitStatusAndArgvOnlyCommandReturnStructuredResults() async throws {
    let f = try fixture()
    let gitInit = Process()
    gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    gitInit.arguments = ["init", "-q"]
    gitInit.currentDirectoryURL = f.workspace
    try gitInit.run()
    gitInit.waitUntilExit()
    XCTAssertEqual(gitInit.terminationStatus, 0)
    try Data("x".utf8).write(to: f.workspace.appendingPathComponent("new.txt"))
    let toolExecutor = executor(f)

    let status = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "status",
      name: "git_status",
      argumentsJSON: #"{}"#))
    let command = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "command",
      name: "run_command",
      argumentsJSON: #"{"executable":"/usr/bin/swift","arguments":["--version"]}"#))

    XCTAssertFalse(status.isError)
    XCTAssertTrue(status.output.contains("new.txt"))
    XCTAssertFalse(command.isError)
    XCTAssertTrue(command.output.lowercased().contains("swift"))
  }

  func testRunCommandAcceptsBarePwdWithoutShellLookup() async throws {
    let f = try fixture()
    let toolExecutor = executor(f)

    let result = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "bare-pwd",
      name: "run_command",
      argumentsJSON:
        #"{"executable":"pwd","arguments":[],"timeout_seconds":30}"#))

    XCTAssertFalse(result.isError)
    let output = TatwoNativeDevelopmentToolOutput.decode(result.output)
    let actualPath = output.content?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/private/var/", with: "/var/")
    let expectedPath = f.workspace.path
      .replacingOccurrences(of: "/private/var/", with: "/var/")
    XCTAssertEqual(
      actualPath,
      expectedPath)
    XCTAssertEqual(output.exitCode, 0)
    XCTAssertFalse(output.hostMutationPerformed)
  }

  func testReadOnlyRunCommandAllowsPwdWithoutHostMutation() async throws {
    let f = try fixture()
    let toolExecutor = executor(f, readOnly: true)

    let result = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "read-only-pwd",
      name: "run_command",
      argumentsJSON:
        #"{"executable":"/bin/pwd","arguments":[],"timeout_seconds":30}"#))

    XCTAssertFalse(result.isError)
    let output = TatwoNativeDevelopmentToolOutput.decode(result.output)
    let actualPath = output.content?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/private/var/", with: "/var/")
    let expectedPath = f.workspace.path
      .replacingOccurrences(of: "/private/var/", with: "/var/")
    XCTAssertEqual(actualPath, expectedPath)
    XCTAssertEqual(output.exitCode, 0)
    XCTAssertFalse(output.hostMutationPerformed)
  }

  func testRunCommandAcceptsBareGitStatusShortWithoutShellLookup() async throws {
    let f = try fixture()
    try runFixtureGit(["init", "-q"], in: f.workspace)
    try Data("x".utf8).write(to: f.workspace.appendingPathComponent("new.txt"))
    let toolExecutor = executor(f)

    let result = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "bare-git-status",
      name: "run_command",
      argumentsJSON:
        #"{"executable":"git","arguments":["status","--short"],"timeout_seconds":30}"#))

    XCTAssertFalse(result.isError)
    let output = TatwoNativeDevelopmentToolOutput.decode(result.output)
    XCTAssertTrue(output.content?.contains("new.txt") == true)
    XCTAssertEqual(output.exitCode, 0)
    XCTAssertFalse(output.hostMutationPerformed)
  }

  func testCancellationInterruptsRunningCommandWithinShortBound() async throws {
    let f = try fixture()
    let toolExecutor = executor(f)
    let task = Task {
      try await toolExecutor.execute(TatwoNativeToolCall(
        id: "cancel-sleep",
        name: "run_command",
        argumentsJSON:
          #"{"executable":"/bin/sleep","arguments":["30"],"timeout_seconds":3}"#))
    }
    try await Task.sleep(for: .milliseconds(100))

    let started = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancelled command returned a tool result")
    } catch is CancellationError {
      // Expected: cancellation terminates the process group and propagates.
    }
    let elapsed = started.duration(to: .now)
    XCTAssertLessThan(elapsed, .seconds(2))
  }

  func testGitToolsRejectEscapeOptionsOutsideAndProtectedPathsWithoutOutput()
    async throws
  {
    let f = try fixture()
    let outside = f.workspace.deletingLastPathComponent()
      .appendingPathComponent("outside-secret.txt")
    try Data("EXFILTRATION_MARKER".utf8).write(to: outside)
    try FileManager.default.createDirectory(
      at: f.workspace.appendingPathComponent(".codex"),
      withIntermediateDirectories: true)
    try Data("PROTECTED_MARKER".utf8).write(
      to: f.workspace.appendingPathComponent(".codex/auth.json"))
    let toolExecutor = executor(f)
    let calls: [(String, String)] = [
      (
        "git_diff",
        #"{"arguments":["--no-index","\#(outside.path)","/dev/null"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["--git-dir=\#(outside.path)","HEAD"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["--work-tree","\#(outside.path)","HEAD"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["-c","core.pager=cat","HEAD"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["--","\#(outside.path)"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["--",".codex/auth.json"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["HEAD~1:.ssh/id_rsa","HEAD:.ssh/id_rsa"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["--","*.env"]}"#
      ),
      (
        "git_diff",
        #"{"arguments":["HEAD~1"]}"#
      ),
      (
        "git_status",
        #"{"arguments":["--short","--","\#(outside.path)"]}"#
      ),
      (
        "git_status",
        #"{"arguments":["--short","--",".codex/auth.json"]}"#
      ),
    ]

    for (index, call) in calls.enumerated() {
      let result = try await toolExecutor.execute(TatwoNativeToolCall(
        id: "git-\(index)",
        name: call.0,
        argumentsJSON: call.1))
      XCTAssertTrue(result.isError, call.1)
      XCTAssertTrue(result.output.contains("command_denied"), call.1)
      XCTAssertFalse(result.output.contains("EXFILTRATION_MARKER"), call.1)
      XCTAssertFalse(result.output.contains("PROTECTED_MARKER"), call.1)
    }
  }

  func testNativeGitDiffRejectsBroadDirectoriesContainingProtectedFilesAndAllowsOrdinaryFile()
    async throws
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
        "commit", "-qm", "native protected pathspec fixture",
      ],
      in: f.workspace)
    for path in files.keys {
      try Data("\(files[path]!)changed\n".utf8).write(
        to: f.workspace.appendingPathComponent(path))
    }
    let toolExecutor = executor(f)

    for (index, broadPathspec) in [".", "Sources", "Config", "secrets"].enumerated() {
      let result = try await toolExecutor.execute(TatwoNativeToolCall(
        id: "broad-\(index)",
        name: "git_diff",
        argumentsJSON: #"{"arguments":["--","\#(broadPathspec)"]}"#))
      XCTAssertTrue(result.isError, broadPathspec)
      XCTAssertTrue(result.output.contains("command_denied"), broadPathspec)
      XCTAssertFalse(result.output.contains("AUTH_SECRET"), broadPathspec)
      XCTAssertFalse(result.output.contains("ENV_SECRET"), broadPathspec)
      XCTAssertFalse(result.output.contains("CREDENTIAL_SECRET"), broadPathspec)
      XCTAssertFalse(result.output.contains("GENERIC_SECRET"), broadPathspec)
    }

    let safe = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "safe-file",
      name: "git_diff",
      argumentsJSON: #"{"arguments":["--","Sources/App.swift"]}"#))
    XCTAssertFalse(safe.isError)
    XCTAssertTrue(safe.output.contains("Sources/App.swift"))
    XCTAssertFalse(safe.output.contains("AUTH_SECRET"))
    XCTAssertFalse(safe.output.contains("ENV_SECRET"))
    XCTAssertFalse(safe.output.contains("CREDENTIAL_SECRET"))
    XCTAssertFalse(safe.output.contains("GENERIC_SECRET"))
  }

  func testNativeGitDiffAcceptsSafeFilePathWithoutInternalGitSeparator()
    async throws
  {
    let f = try fixture()
    let source = f.workspace.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("let value = 1\n".utf8).write(to: source)
    try runFixtureGit(["init", "-q"], in: f.workspace)
    try runFixtureGit(["add", "."], in: f.workspace)
    try runFixtureGit(
      [
        "-c", "user.name=TATWO Test",
        "-c", "user.email=tatwo@example.invalid",
        "commit", "-qm", "native model-friendly pathspec fixture",
      ],
      in: f.workspace)
    try Data("let value = 2\n".utf8).write(to: source)

    let result = try await executor(f).execute(TatwoNativeToolCall(
      id: "safe-file-without-separator",
      name: "git_diff",
      argumentsJSON: #"{"arguments":["Sources/App.swift"]}"#))

    XCTAssertFalse(result.isError)
    XCTAssertTrue(result.output.contains("Sources/App.swift"))
    XCTAssertTrue(result.output.contains("let value = 2"))
  }

  func testBlockedReadOnlyExactProviderRunsSafeGitDiffAndPwdWithoutApprovalRequired()
    async throws
  {
    let f = try fixture()
    let source = f.workspace.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("let value = 1\n".utf8).write(to: source)
    try runFixtureGit(["init", "-q"], in: f.workspace)
    try runFixtureGit(["add", "."], in: f.workspace)
    try runFixtureGit(
      [
        "-c", "user.name=TATWO Test",
        "-c", "user.email=tatwo@example.invalid",
        "commit", "-qm", "read-only exact git diff fixture",
      ],
      in: f.workspace)
    try Data("let value = 2\n".utf8).write(to: source)
    _ = try f.host.goalRunStore.updateStatus(
      contractID: f.contract.contractID,
      status: .dispatching)
    _ = try f.host.goalRunStore.updateStatus(
      contractID: f.contract.contractID,
      status: .blocked,
      authority: .ledgerBeginAck,
      evidence: .ledger(dispatchID: "blocked-read-only-smoke"))
    let provider = TatwoNativeExactHostAuthorizationProvider(
      approvalStore: f.host.approvalStore,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      allowsMutation: false)
    let toolExecutor = TatwoNativeDevelopmentToolExecutor(
      hostExecutor: f.host,
      authorizationProvider: provider,
      contractID: f.contract.contractID,
      workspaceRoot: f.workspace.path,
      readOnly: true)

    let diff = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "read-only-exact-git-diff",
      name: "git_diff",
      argumentsJSON: #"{"arguments":["Sources/App.swift"]}"#))
    let pwd = try await toolExecutor.execute(TatwoNativeToolCall(
      id: "read-only-exact-pwd",
      name: "run_command",
      argumentsJSON:
        #"{"executable":"/bin/pwd","arguments":[],"timeout_seconds":30}"#))

    XCTAssertFalse(diff.isError)
    let diffOutput = TatwoNativeDevelopmentToolOutput.decode(diff.output)
    XCTAssertEqual(diffOutput.exitCode, 0)
    XCTAssertFalse(diffOutput.hostMutationPerformed)
    XCTAssertNotNil(diffOutput.receiptID)
    XCTAssertTrue(diffOutput.content?.contains("let value = 2") == true)
    XCTAssertNotEqual(diffOutput.errorCode, "approval_required")

    XCTAssertFalse(pwd.isError)
    let pwdOutput = TatwoNativeDevelopmentToolOutput.decode(pwd.output)
    XCTAssertEqual(pwdOutput.exitCode, 0)
    XCTAssertFalse(pwdOutput.hostMutationPerformed)
    XCTAssertNotNil(pwdOutput.receiptID)
    XCTAssertNotEqual(pwdOutput.errorCode, "approval_required")
  }
  #endif

  #if os(macOS)
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
  #endif
}
