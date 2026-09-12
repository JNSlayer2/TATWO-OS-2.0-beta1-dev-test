import CryptoKit
import Foundation

public enum TatwoNativeDevelopmentToolCatalog {
  public static let definitions: [TatwoNativeToolDefinition] = [
    definition(
      "list_files",
      "List regular files below a workspace-relative path or an absolute path inside the workspace.",
      properties: #"{"path":{"type":"string"},"maximum_depth":{"type":"integer"}}"#),
    definition(
      "read_file",
      "Read a UTF-8 file by workspace-relative path or absolute path inside the workspace.",
      properties: #"{"path":{"type":"string"}}"#, required: ["path"]),
    definition(
      "search",
      "Search text below a workspace-relative path or absolute path inside the workspace.",
      properties:
        #"{"path":{"type":"string"},"query":{"type":"string"},"maximum_matches":{"type":"integer"}}"#,
      required: ["query"]),
    definition(
      "write_file",
      "Write a complete UTF-8 file inside the workspace with backup and rollback receipt.",
      properties: #"{"path":{"type":"string"},"content":{"type":"string"}}"#,
      required: ["path", "content"]),
    definition(
      "edit_file",
      "Replace exact text in a UTF-8 file inside the workspace with backup and rollback receipt.",
      properties:
        #"{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"},"replace_all":{"type":"boolean"}}"#,
      required: ["path", "old_text", "new_text"]),
    definition(
      "run_command", "Run an allowlisted executable with an argv array; shell strings are forbidden.",
      properties:
        #"{"executable":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"timeout_seconds":{"type":"number"}}"#,
      required: ["executable", "arguments"]),
    definition(
      "git_status", "Run git status in the workspace.",
      properties: #"{}"#),
    definition(
      "git_diff", "Run git diff for one or more safe workspace-relative file paths.",
      properties: #"{"arguments":{"type":"array","items":{"type":"string"}}}"#),
    definition(
      "build", "Run an allowlisted build command using executable plus argv.",
      properties:
        #"{"executable":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"timeout_seconds":{"type":"number"}}"#,
      required: ["executable", "arguments"]),
    definition(
      "test", "Run an allowlisted test command using executable plus argv.",
      properties:
        #"{"executable":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"timeout_seconds":{"type":"number"}}"#,
      required: ["executable", "arguments"]),
    definition(
      "rollback", "Rollback a write or edit by its host receipt ID.",
      properties: #"{"receipt_id":{"type":"string"}}"#, required: ["receipt_id"]),
  ]

  public static func definitions(
    readOnly: Bool
  ) -> [TatwoNativeToolDefinition] {
    guard readOnly else { return definitions }
    let nonMutating = Set([
      "list_files", "read_file", "search", "run_command", "git_status",
      "git_diff",
    ])
    return definitions.filter { nonMutating.contains($0.name) }
  }

  private static func definition(
    _ name: String,
    _ description: String,
    properties: String,
    required: [String] = []
  ) -> TatwoNativeToolDefinition {
    let requiredJSON =
      required.isEmpty
      ? ""
      : #","required":["# + required.map { #""\#($0)""# }.joined(separator: ",") + "]"
    return TatwoNativeToolDefinition(
      name: name,
      description: description,
      inputSchemaJSON:
        #"{"type":"object","additionalProperties":false,"properties":"#
        + properties + requiredJSON + "}")
  }
}

public struct TatwoNativeHostAuthorizationRequest: Sendable, Equatable {
  public let action: TatwoHostActionKind
  public let argumentDigest: String
  public let isMutation: Bool

  public init(
    action: TatwoHostActionKind,
    argumentDigest: String,
    isMutation: Bool = false
  ) {
    self.action = action
    self.argumentDigest = argumentDigest
    self.isMutation = isMutation
  }
}

public protocol TatwoNativeHostAuthorizationProviding: Sendable {
  func leaseID(for request: TatwoNativeHostAuthorizationRequest) throws -> String
}

public struct TatwoNativeStaticHostAuthorizationProvider:
  TatwoNativeHostAuthorizationProviding
{
  public let leaseID: String

  public init(leaseID: String) {
    self.leaseID = leaseID
  }

  public func leaseID(for request: TatwoNativeHostAuthorizationRequest) throws -> String {
    leaseID
  }
}

/// Resolves only already-issued, exact Host Executor leases. It cannot mint
/// authority and never accepts a lease identifier from model arguments.
public struct TatwoNativePersistedHostAuthorizationProvider:
  TatwoNativeHostAuthorizationProviding
{
  public let directoryURL: URL
  public let contractID: String
  public let workspaceRoot: String
  public let now: @Sendable () -> Date

  public init(
    directoryURL: URL,
    contractID: String,
    workspaceRoot: String,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directoryURL = directoryURL
    self.contractID = contractID
    self.workspaceRoot = URL(fileURLWithPath: workspaceRoot)
      .standardizedFileURL.resolvingSymlinksInPath().path
    self.now = now
  }

  public func leaseID(
    for request: TatwoNativeHostAuthorizationRequest
  ) throws -> String {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .prefix(512)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let matches = urls.compactMap { url -> TatwoHostApprovalLeaseV1? in
      guard let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey]),
        values.isRegularFile == true,
        let data = try? Data(contentsOf: url),
        let lease = try? decoder.decode(
          TatwoHostApprovalLeaseV1.self, from: data)
      else { return nil }
      let canonicalWorkspace = URL(fileURLWithPath: lease.workspaceRoot)
        .standardizedFileURL.resolvingSymlinksInPath().path
      guard lease.contractID == contractID,
        canonicalWorkspace == workspaceRoot,
        lease.allowedActions.contains(request.action),
        lease.argumentDigest == request.argumentDigest,
        lease.issuedAt <= now(),
        lease.expiresAt > now()
      else { return nil }
      return lease
    }
    guard matches.count == 1, let lease = matches.first else {
      throw TatwoHostExecutorError.approvalRequired
    }
    return lease.id
  }
}

/// Resolves or mints only exact, host-side leases after tool arguments have
/// been decoded and hashed. Lease identifiers never enter model arguments.
/// Pre-revision goals may use short-lived approve-for-me leases. Revision-bound
/// goals fail closed unless the App has already issued one exact signed
/// HostOperationAuthorization, which this provider consumes through the normal
/// Host Executor path.
public struct TatwoNativeExactHostAuthorizationProvider:
  TatwoNativeHostAuthorizationProviding
{
  public typealias RevisionBoundAuthorizationIssuer =
    @Sendable (TatwoNativeHostAuthorizationRequest) throws -> String

  public let approvalStore: TatwoHostApprovalStore
  public let contractID: String
  public let workspaceRoot: String
  public let allowsMutation: Bool
  private let revisionBoundAuthorizationIssuer:
    RevisionBoundAuthorizationIssuer?
  public let now: @Sendable () -> Date

  public init(
    approvalStore: TatwoHostApprovalStore,
    contractID: String,
    workspaceRoot: String,
    allowsMutation: Bool,
    revisionBoundAuthorizationIssuer:
      RevisionBoundAuthorizationIssuer? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.approvalStore = approvalStore
    self.contractID = contractID
    self.workspaceRoot = URL(fileURLWithPath: workspaceRoot)
      .standardizedFileURL.resolvingSymlinksInPath().path
    self.allowsMutation = allowsMutation
    self.revisionBoundAuthorizationIssuer =
      revisionBoundAuthorizationIssuer
    self.now = now
  }

  public func leaseID(
    for request: TatwoNativeHostAuthorizationRequest
  ) throws -> String {
    if request.isMutation, !allowsMutation {
      throw TatwoHostExecutorError.approvalRequired
    }
    let goal = try approvalStore.goalRunStore.requireIssuedContract(contractID)
    if goal.supersession != nil
      || goal.predecessorContractID != nil
      || goal.successorContractID != nil
    {
      if let existing = try? TatwoNativePersistedHostAuthorizationProvider(
        directoryURL: approvalStore.directoryURL,
        contractID: contractID,
        workspaceRoot: workspaceRoot,
        now: now
      ).leaseID(for: request) {
        return existing
      }
      let authorizationID: String
      if let revisionBoundAuthorizationIssuer {
        authorizationID = try revisionBoundAuthorizationIssuer(request)
      } else {
        authorizationID = try exactAppAuthorizationID(for: request)
      }
      return try approvalStore.issueHostOperationBound(
        authorizationID: authorizationID,
        sessionStore: TatwoSessionStore(
          directoryURL: approvalStore.goalRunStore.directoryURL),
        now: now()).id
    }
    return try approvalStore.issueNativeOperationBound(
      contractID: contractID,
      workspaceRoot: workspaceRoot,
      action: request.action,
      argumentDigest: request.argumentDigest,
      isMutation: request.isMutation,
      ttl: 60,
      now: now()).id
  }

  private func exactAppAuthorizationID(
    for request: TatwoNativeHostAuthorizationRequest
  ) throws -> String {
    let directory =
      approvalStore.hostOperationAuthorizationStore.directoryURL
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    else { throw TatwoHostExecutorError.approvalRequired }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let current = now()
    let matches = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url -> TatwoHostOperationAuthorizationV1? in
        guard url.pathExtension == "json",
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
          values.isRegularFile == true,
          let data = try? Data(contentsOf: url),
          let authorization = try? decoder.decode(
            TatwoHostOperationAuthorizationV1.self, from: data),
          authorization.contractID == contractID,
          authorization.canonicalWorkspacePath == workspaceRoot,
          authorization.action == request.action,
          authorization.argumentDigest == request.argumentDigest,
          authorization.issuedAt <= current,
          authorization.expiresAt > current
        else { return nil }
        return authorization
      }
    guard matches.count == 1, let match = matches.first else {
      throw TatwoHostExecutorError.approvalRequired
    }
    return match.id
  }
}

public struct TatwoNativeDevelopmentToolOutput: Codable, Sendable, Equatable {
  public let ok: Bool
  public let tool: String
  public let content: String?
  public let receiptID: String?
  public let backupPath: String?
  public let diff: String?
  public let outcome: String?
  public let exitCode: Int32?
  public let hostMutationPerformed: Bool
  public let errorCode: String?

  public init(
    ok: Bool,
    tool: String,
    content: String? = nil,
    receiptID: String? = nil,
    backupPath: String? = nil,
    diff: String? = nil,
    outcome: String? = nil,
    exitCode: Int32? = nil,
    hostMutationPerformed: Bool = false,
    errorCode: String? = nil
  ) {
    self.ok = ok
    self.tool = tool
    self.content = content
    self.receiptID = receiptID
    self.backupPath = backupPath
    self.diff = diff
    self.outcome = outcome
    self.exitCode = exitCode
    self.hostMutationPerformed = hostMutationPerformed
    self.errorCode = errorCode
  }

  private enum CodingKeys: String, CodingKey {
    case ok, tool, content, diff, outcome
    case receiptID = "receipt_id"
    case backupPath = "backup_path"
    case exitCode = "exit_code"
    case hostMutationPerformed = "host_mutation_performed"
    case errorCode = "error_code"
  }

  public static func decode(_ json: String) -> Self {
    (try? JSONDecoder().decode(Self.self, from: Data(json.utf8)))
      ?? Self(ok: false, tool: "decode", errorCode: "invalid_output")
  }

  fileprivate var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else {
      return #"{"error_code":"encoding_failed","host_mutation_performed":false,"ok":false,"tool":"unknown"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}

public actor TatwoNativeDevelopmentToolExecutor: TatwoNativeToolExecuting {
  public let hostExecutor: TatwoHostExecutor
  public let authorizationProvider: any TatwoNativeHostAuthorizationProviding
  public let contractID: String
  public let workspaceRoot: String
  public let readOnly: Bool

  private var writeReceipts: [String: TatwoHostExecutionReceiptV1] = [:]

  public init(
    hostExecutor: TatwoHostExecutor,
    authorizationProvider: any TatwoNativeHostAuthorizationProviding,
    contractID: String,
    workspaceRoot: String,
    readOnly: Bool
  ) {
    self.hostExecutor = hostExecutor
    self.authorizationProvider = authorizationProvider
    self.contractID = contractID
    self.workspaceRoot = workspaceRoot
    self.readOnly = readOnly
  }

  public func execute(_ call: TatwoNativeToolCall) async throws -> TatwoNativeToolResult {
    if Task.isCancelled { throw CancellationError() }
    do {
      let output = try executeAuthorized(call)
      return TatwoNativeToolResult(callID: call.id, output: output.json, isError: !output.ok)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let code =
        (error as? TatwoHostExecutorError)?.errorDescription
        ?? (error as? TatwoNativeDevelopmentToolError)?.rawValue
        ?? "tool_failed"
      let output = TatwoNativeDevelopmentToolOutput(
        ok: false,
        tool: call.name,
        hostMutationPerformed: false,
        errorCode: code)
      return TatwoNativeToolResult(callID: call.id, output: output.json, isError: true)
    }
  }

  private func executeAuthorized(
    _ call: TatwoNativeToolCall
  ) throws -> TatwoNativeDevelopmentToolOutput {
    switch call.name {
    case "list_files":
      let arguments = try decode(ListArguments.self, call)
      let path = try workspaceRelativePath(arguments.path ?? ".")
      let maximumDepth = arguments.maximumDepth ?? 8
      let leaseID = try lease(
        action: .readFile,
        components: ["list", path, String(max(0, min(maximumDepth, 32)))],
        isMutation: false)
      let receipt = try hostExecutor.listFiles(
        contractID: contractID,
        leaseID: leaseID,
        workspaceRoot: workspaceRoot,
        relativePath: path,
        maximumDepth: maximumDepth)
      return output(call.name, receipt)

    case "read_file":
      let arguments = try decode(PathArguments.self, call)
      let receipt = try read(
        path: workspaceRelativePath(arguments.path))
      return output(call.name, receipt)

    case "search":
      let arguments = try decode(SearchArguments.self, call)
      let path = try workspaceRelativePath(arguments.path ?? ".")
      let maximumMatches = arguments.maximumMatches ?? 200
      let leaseID = try lease(
        action: .readFile,
        components: [
          "search", path, arguments.query,
          String(max(1, min(maximumMatches, 2_000))),
        ],
        isMutation: false)
      let receipt = try hostExecutor.searchFiles(
        contractID: contractID,
        leaseID: leaseID,
        workspaceRoot: workspaceRoot,
        relativePath: path,
        query: arguments.query,
        maximumMatches: maximumMatches)
      return output(call.name, receipt)

    case "write_file":
      try requireWritable()
      let arguments = try decode(WriteArguments.self, call)
      let path = try workspaceRelativePath(arguments.path)
      let oldContent = try existingContentIfReadable(path: path)
      let receipt = try write(path: path, content: arguments.content)
      writeReceipts[receipt.receiptID] = receipt
      return output(
        call.name,
        receipt,
        diff: Self.diff(path: path, old: oldContent ?? "", new: arguments.content))

    case "edit_file":
      try requireWritable()
      let arguments = try decode(EditArguments.self, call)
      let path = try workspaceRelativePath(arguments.path)
      guard !arguments.oldText.isEmpty else {
        throw TatwoNativeDevelopmentToolError.invalidArguments
      }
      let readReceipt = try read(path: path)
      guard Self.sha256(Data(readReceipt.result.utf8)) == readReceipt.contentSHA256 else {
        throw TatwoNativeDevelopmentToolError.fileTooLargeForEdit
      }
      let occurrences = readReceipt.result.components(separatedBy: arguments.oldText).count - 1
      guard occurrences > 0 else {
        throw TatwoNativeDevelopmentToolError.editTextNotFound
      }
      guard arguments.replaceAll == true || occurrences == 1 else {
        throw TatwoNativeDevelopmentToolError.editTextNotUnique
      }
      let newContent =
        arguments.replaceAll == true
        ? readReceipt.result.replacingOccurrences(
          of: arguments.oldText, with: arguments.newText)
        : readReceipt.result.replacingFirstOccurrence(
          of: arguments.oldText, with: arguments.newText)
      let receipt = try write(path: path, content: newContent)
      writeReceipts[receipt.receiptID] = receipt
      return output(
        call.name,
        receipt,
        diff: Self.diff(path: path, old: readReceipt.result, new: newContent))

    case "run_command":
      let arguments = try decode(CommandArguments.self, call)
      if readOnly {
        guard Self.isReadOnlySafeCommand(
          arguments,
          workspaceRoot: workspaceRoot)
        else {
          throw TatwoNativeDevelopmentToolError.readOnly
        }
        return try command(
          call.name,
          executable: arguments.executable,
          arguments: arguments.arguments,
          timeout: arguments.timeoutSeconds ?? 120,
          isMutation: false)
      }
      return try command(call.name, arguments: arguments)

    case "git_status":
      let arguments = try decode(OptionalArguments.self, call)
      guard arguments.arguments == nil else {
        throw TatwoHostExecutorError.commandDenied
      }
      return try command(
        call.name,
        executable: "/usr/bin/git",
        arguments: ["status", "--porcelain"],
        timeout: 120,
        isMutation: false)

    case "git_diff":
      let arguments = try decode(OptionalArguments.self, call)
      let pathspecs = try Self.safeGitDiffPathspecs(
        arguments.arguments,
        workspaceRoot: workspaceRoot)
      return try command(
        call.name,
        executable: "/usr/bin/git",
        arguments: ["diff", "--no-ext-diff", "--"] + pathspecs,
        timeout: 120,
        isMutation: false)

    case "build":
      try requireWritable()
      let arguments = try decode(CommandArguments.self, call)
      guard Self.isBuildCommand(arguments) else {
        throw TatwoNativeDevelopmentToolError.commandIntentMismatch
      }
      return try command(call.name, arguments: arguments)

    case "test":
      try requireWritable()
      let arguments = try decode(CommandArguments.self, call)
      guard Self.isTestCommand(arguments) else {
        throw TatwoNativeDevelopmentToolError.commandIntentMismatch
      }
      return try command(call.name, arguments: arguments)

    case "rollback":
      try requireWritable()
      let arguments = try decode(RollbackArguments.self, call)
      guard let writeReceipt = writeReceipts[arguments.receiptID] else {
        throw TatwoNativeDevelopmentToolError.rollbackReceiptMissing
      }
      let components = [
        writeReceipt.receiptID,
        writeReceipt.contentSHA256 ?? "missing",
      ]
      let leaseID = try lease(
        action: .rollback, components: components, isMutation: true)
      let receipt = try hostExecutor.rollback(
        contractID: contractID,
        leaseID: leaseID,
        workspaceRoot: workspaceRoot,
        writeReceipt: writeReceipt)
      return output(call.name, receipt)

    default:
      throw TatwoNativeDevelopmentToolError.unknownTool
    }
  }

  private func read(path: String) throws -> TatwoHostExecutionReceiptV1 {
    let leaseID = try lease(
      action: .readFile, components: [path], isMutation: false)
    return try hostExecutor.readFile(
      contractID: contractID,
      leaseID: leaseID,
      workspaceRoot: workspaceRoot,
      relativePath: path)
  }

  private func write(path: String, content: String) throws -> TatwoHostExecutionReceiptV1 {
    let digest = Self.sha256(Data(content.utf8))
    let leaseID = try lease(
      action: .writeFile,
      components: [path, digest],
      isMutation: true)
    return try hostExecutor.writeFile(
      contractID: contractID,
      leaseID: leaseID,
      workspaceRoot: workspaceRoot,
      relativePath: path,
      content: content)
  }

  private func command(
    _ tool: String,
    arguments: CommandArguments
  ) throws -> TatwoNativeDevelopmentToolOutput {
    try command(
      tool,
      executable: arguments.executable,
      arguments: arguments.arguments,
      timeout: arguments.timeoutSeconds ?? 120,
      isMutation: true)
  }

  private func command(
    _ tool: String,
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    isMutation: Bool = true
  ) throws -> TatwoNativeDevelopmentToolOutput {
    #if os(macOS)
    let leaseID = try lease(
      action: .runCommand,
      components: [executable] + arguments,
      isMutation: isMutation)
    let receipt = try hostExecutor.runCommand(
      contractID: contractID,
      leaseID: leaseID,
      workspaceRoot: workspaceRoot,
      executable: executable,
      arguments: arguments,
      timeout: timeout,
      cancellationRequested: { Task.isCancelled })
    return output(tool, receipt)
    #else
    throw TatwoHostExecutorError.unsupportedPlatform
    #endif
  }

  private func existingContentIfReadable(path: String) throws -> String? {
    do {
      return try read(path: path).result
    } catch {
      let target = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        .appendingPathComponent(path)
      if !FileManager.default.fileExists(atPath: target.path) {
        return nil
      }
      throw error
    }
  }

  private func workspaceRelativePath(_ path: String) throws -> String {
    guard (path as NSString).isAbsolutePath else { return path }
    let workspace = URL(
      fileURLWithPath: workspaceRoot,
      isDirectory: true
    ).standardizedFileURL.resolvingSymlinksInPath()
    let candidate = URL(fileURLWithPath: path)
      .standardizedFileURL.resolvingSymlinksInPath()
    let workspacePath = workspace.path
    let candidatePath = candidate.path
    if candidatePath == workspacePath { return "." }
    let prefix = workspacePath.hasSuffix("/")
      ? workspacePath
      : workspacePath + "/"
    guard candidatePath.hasPrefix(prefix) else {
      throw TatwoHostExecutorError.invalidRelativePath
    }
    let relative = String(candidatePath.dropFirst(prefix.count))
    guard !relative.isEmpty else {
      throw TatwoHostExecutorError.invalidRelativePath
    }
    return relative
  }

  private func lease(
    action: TatwoHostActionKind,
    components: [String],
    isMutation: Bool
  ) throws -> String {
    try authorizationProvider.leaseID(for: TatwoNativeHostAuthorizationRequest(
      action: action,
      argumentDigest: TatwoHostOperationAuthorizationV1.argumentDigest(
        action: action, components: components),
      isMutation: isMutation))
  }

  private func output(
    _ tool: String,
    _ receipt: TatwoHostExecutionReceiptV1,
    diff: String? = nil
  ) -> TatwoNativeDevelopmentToolOutput {
    TatwoNativeDevelopmentToolOutput(
      ok: receipt.ok,
      tool: tool,
      content: Self.boundedToolText(receipt.result),
      receiptID: receipt.receiptID,
      backupPath: receipt.backupPath,
      diff: diff.map(Self.boundedToolText),
      outcome: receipt.outcome.rawValue,
      exitCode: receipt.exitCode,
      hostMutationPerformed: receipt.hostMutationPerformed,
      errorCode: receipt.ok ? nil : receipt.outcome.rawValue)
  }

  private func requireWritable() throws {
    if readOnly {
      throw TatwoNativeDevelopmentToolError.readOnly
    }
  }

  private func decode<T: Decodable>(
    _ type: T.Type,
    _ call: TatwoNativeToolCall
  ) throws -> T {
    guard let data = call.argumentsJSON.data(using: .utf8) else {
      throw TatwoNativeDevelopmentToolError.invalidArguments
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw TatwoNativeDevelopmentToolError.invalidArguments
    }
  }

  private static func isBuildCommand(_ command: CommandArguments) -> Bool {
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    guard let first = command.arguments.first else { return false }
    switch executable {
    case "swift": return first == "build"
    case "npm", "pnpm": return first == "run" && command.arguments.dropFirst().first == "build"
    case "xcodebuild": return !command.arguments.contains("test")
    default: return false
    }
  }

  private static func isReadOnlySafeCommand(
    _ command: CommandArguments,
    workspaceRoot: String
  ) -> Bool {
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    switch executable {
    case "pwd":
      return command.arguments.isEmpty
    case "git":
      guard let subcommand = command.arguments.first else { return false }
      let arguments = Array(command.arguments.dropFirst())
      switch subcommand {
      case "status":
        return arguments == ["--porcelain"] || arguments == ["--short"]
      case "diff":
        var remaining = arguments
        if remaining.first == "--no-ext-diff" {
          remaining.removeFirst()
        }
        guard remaining.first == "--" else { return false }
        return (try? safeGitDiffPathspecs(
          Array(remaining.dropFirst()),
          workspaceRoot: workspaceRoot)) != nil
      default:
        return false
      }
    default:
      return false
    }
  }

  private static func isTestCommand(_ command: CommandArguments) -> Bool {
    let executable = URL(fileURLWithPath: command.executable).lastPathComponent
    guard let first = command.arguments.first else { return false }
    switch executable {
    case "swift": return first == "test"
    case "npm", "pnpm":
      return first == "test"
        || (first == "run" && command.arguments.dropFirst().first == "test")
    case "xcodebuild": return command.arguments.contains("test")
    default: return false
    }
  }

  private static func diff(path: String, old: String, new: String) -> String {
    guard old != new else { return "" }
    let removed = old.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "-\($0)" }
    let added = new.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "+\($0)" }
    return (["--- \(path)", "+++ \(path)"] + removed + added)
      .joined(separator: "\n")
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func safeGitDiffPathspecs(
    _ arguments: [String]?,
    workspaceRoot: String
  ) throws -> [String] {
    guard let arguments, !arguments.isEmpty else {
      throw TatwoHostExecutorError.commandDenied
    }
    let paths =
      arguments.first == "--"
      ? Array(arguments.dropFirst())
      : arguments
    guard !paths.isEmpty else {
      throw TatwoHostExecutorError.commandDenied
    }
    guard paths.allSatisfy({
      !$0.isEmpty
        && !$0.hasPrefix("-")
        && !$0.hasPrefix(":(")
        && $0.rangeOfCharacter(
          from: CharacterSet(charactersIn: "*?[")) == nil
        && TatwoHostExecutor.isSafeGitDiffPathspec(
          $0,
          workspaceRoot: workspaceRoot)
    }) else {
      throw TatwoHostExecutorError.commandDenied
    }
    return paths
  }

  private static func boundedToolText(_ text: String) -> String {
    let data = Data(text.utf8)
    let maximumBytes = 64 * 1024
    guard data.count > maximumBytes else { return text }
    return String(decoding: data.prefix(maximumBytes), as: UTF8.self)
      + "\n<tatwo-truncated original_bytes=\(data.count)>"
  }

  private struct ListArguments: Decodable {
    let path: String?
    let maximumDepth: Int?

    private enum CodingKeys: String, CodingKey {
      case path
      case maximumDepth = "maximum_depth"
    }
  }

  private struct PathArguments: Decodable {
    let path: String
  }

  private struct SearchArguments: Decodable {
    let path: String?
    let query: String
    let maximumMatches: Int?

    private enum CodingKeys: String, CodingKey {
      case path, query
      case maximumMatches = "maximum_matches"
    }
  }

  private struct WriteArguments: Decodable {
    let path: String
    let content: String
  }

  private struct EditArguments: Decodable {
    let path: String
    let oldText: String
    let newText: String
    let replaceAll: Bool?

    private enum CodingKeys: String, CodingKey {
      case path
      case oldText = "old_text"
      case newText = "new_text"
      case replaceAll = "replace_all"
    }
  }

  private struct CommandArguments: Decodable {
    let executable: String
    let arguments: [String]
    let timeoutSeconds: TimeInterval?

    private enum CodingKeys: String, CodingKey {
      case executable, arguments
      case timeoutSeconds = "timeout_seconds"
    }
  }

  private struct OptionalArguments: Decodable {
    let arguments: [String]?
  }

  private struct RollbackArguments: Decodable {
    let receiptID: String

    private enum CodingKeys: String, CodingKey {
      case receiptID = "receipt_id"
    }
  }
}

public enum TatwoNativeDevelopmentToolError: String, Error, Sendable {
  case unknownTool = "unknown_tool"
  case invalidArguments = "invalid_arguments"
  case readOnly = "read_only"
  case fileTooLargeForEdit = "file_too_large_for_edit"
  case editTextNotFound = "edit_text_not_found"
  case editTextNotUnique = "edit_text_not_unique"
  case commandIntentMismatch = "command_intent_mismatch"
  case rollbackReceiptMissing = "rollback_receipt_missing"
}

private extension String {
  func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
    guard let range = range(of: target) else { return self }
    var copy = self
    copy.replaceSubrange(range, with: replacement)
    return copy
  }
}
