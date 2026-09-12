import CryptoKit
import Darwin
import Foundation
import TatwoUltraworkCore

/// M4a build-time rollback switch. Production defaults to the governed vendor
/// CLI development session; the legacy 11-tool runner remains available below
/// the same `ChatNativeAgentRunning` seam.
enum TatwoNativeAgentRunnerBuildConfiguration {
    static let useGovernedDevSessionRunner = true
}

struct GovernedDevProcessInvocation: Sendable, Equatable {
    enum OutputStream: Sendable {
        case stdout
        case stderr
    }

    let executableURL: URL
    let arguments: [String]
    let standardInput: Data?
    let environment: [String: String]
    let currentDirectoryURL: URL
}

struct GovernedDevProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol GovernedDevProcessRunning: Sendable {
    func run(
        invocation: GovernedDevProcessInvocation,
        onOutput: @escaping @Sendable (
            GovernedDevProcessInvocation.OutputStream,
            Data
        ) -> Void
    ) async throws -> GovernedDevProcessResult
    func stop()
}

private final class GovernedDevLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { storage.append(data) }
    }

    var data: Data { lock.withLock { storage } }
}

final class GovernedDevProcessRunner:
    GovernedDevProcessRunning,
    @unchecked Sendable
{
    private struct ActiveProcess {
        let process: Process
        let processGroupID: pid_t?
    }

    private let lock = NSLock()
    private var activeProcess: ActiveProcess?
    private var stopRequested = false

    func run(
        invocation: GovernedDevProcessInvocation,
        onOutput: @escaping @Sendable (
            GovernedDevProcessInvocation.OutputStream,
            Data
        ) -> Void
    ) async throws -> GovernedDevProcessResult {
        guard FileManager.default.isExecutableFile(
            atPath: invocation.executableURL.path)
        else {
            throw GovernedDevSessionFailure.runtimeUnavailable
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = GovernedDevLockedDataBuffer()
        let errorBuffer = GovernedDevLockedDataBuffer()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputBuffer.append(data)
            onOutput(.stdout, data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorBuffer.append(data)
            onOutput(.stderr, data)
        }

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<GovernedDevProcessResult, Error>) in
                process.terminationHandler = { [weak self] terminated in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    let finalOutput = outputPipe.fileHandleForReading.availableData
                    let finalError = errorPipe.fileHandleForReading.availableData
                    outputBuffer.append(finalOutput)
                    errorBuffer.append(finalError)
                    if !finalOutput.isEmpty { onOutput(.stdout, finalOutput) }
                    if !finalError.isEmpty { onOutput(.stderr, finalError) }
                    self?.lock.withLock {
                        if self?.activeProcess?.process === terminated {
                            self?.activeProcess = nil
                        }
                    }
                    continuation.resume(returning: GovernedDevProcessResult(
                        exitCode: terminated.terminationStatus,
                        stdout: outputBuffer.data,
                        stderr: errorBuffer.data))
                }
                do {
                    try process.run()
                    let pid = process.processIdentifier
                    let groupID: pid_t?
                    if Darwin.setpgid(pid, pid) == 0 || Darwin.getpgid(pid) == pid {
                        groupID = pid
                    } else {
                        groupID = nil
                    }
                    lock.withLock {
                        activeProcess = ActiveProcess(
                            process: process,
                            processGroupID: groupID)
                    }
                    if lock.withLock({ stopRequested }) {
                        stopActiveProcess(ActiveProcess(
                            process: process,
                            processGroupID: groupID))
                    }
                    if let standardInput = invocation.standardInput {
                        try inputPipe.fileHandleForWriting.write(
                            contentsOf: standardInput)
                    }
                    try inputPipe.fileHandleForWriting.close()
                } catch {
                    lock.withLock {
                        if activeProcess?.process === process {
                            activeProcess = nil
                        }
                    }
                    process.terminationHandler = nil
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    try? inputPipe.fileHandleForWriting.close()
                    continuation.resume(
                        throwing: GovernedDevSessionFailure.runtimeUnavailable)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            return result
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        let active = lock.withLock {
            stopRequested = true
            return activeProcess
        }
        guard let active, active.process.isRunning else { return }
        stopActiveProcess(active)
    }

    private func stopActiveProcess(_ active: ActiveProcess) {
        if let processGroupID = active.processGroupID {
            _ = Darwin.kill(-processGroupID, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 1.5
            ) { [weak process = active.process] in
                guard process?.isRunning == true else { return }
                _ = Darwin.kill(-processGroupID, SIGKILL)
            }
        } else {
            active.process.terminate()
        }
    }
}

enum GovernedDevSessionFailure: Error, Sendable, Equatable {
    case runtimeUnavailable
    case unsupportedModel
    case grokAttestationUnverified
    case workspaceNotGitRepository
    case worktreeCollision
    case worktreeCreationFailed
    case cliExited(Int32)
    case claudeAttestationMismatch
    case codexAttestationMismatch
    case processFailure(String)

    var code: String {
        switch self {
        case .runtimeUnavailable: "governed_dev_runtime_unavailable"
        case .unsupportedModel: "governed_dev_unsupported_model"
        case .grokAttestationUnverified: "grok_dev_attestation_unverified"
        case .workspaceNotGitRepository: "governed_dev_workspace_not_git"
        case .worktreeCollision: "governed_dev_worktree_collision"
        case .worktreeCreationFailed: "governed_dev_worktree_create_failed"
        case .cliExited(let status): "governed_dev_cli_exit_\(status)"
        case .claudeAttestationMismatch: "governed_dev_claude_attestation_mismatch"
        case .codexAttestationMismatch: "governed_dev_codex_attestation_mismatch"
        case .processFailure(let code): code
        }
    }
}

struct GovernedDevGitDigestV1: Codable, Sendable, Equatable {
    let headCommit: String
    let statusPorcelainSHA256: String
}

struct GovernedDevSessionArtifactV1: Codable, Sendable, Equatable {
    let schema: String
    let runID: String
    let dispatchID: String?
    let contractID: String
    let modelID: String
    let effort: String
    let readOnly: Bool
    let repositoryRoot: String
    let worktreePath: String
    let worktreeBranch: String
    let baseCommit: String
    let outputRefDescription: String
    let preRunDigest: GovernedDevGitDigestV1
    let postRunDigest: GovernedDevGitDigestV1
    let diffStat: String
    let changedFiles: [String]
    let cliJSONEventCount: Int
    let commandEventCount: Int
    let toolEventCount: Int
    let stdoutSHA256: String
    let stderrSHA256: String
    let terminalReceiptID: String
    let completedAt: Date
}

struct GovernedDevPersistedRunV1: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case running
        case completed
        case cancelled
        case timedOut
        case failed
        case interrupted
    }

    let schema: String
    let runID: String
    var state: State
    let dispatchID: String?
    let contractID: String
    let modelID: String
    let effort: String
    let readOnly: Bool
    var repositoryRoot: String?
    var worktreePath: String?
    var worktreeBranch: String?
    var baseCommit: String?
    var preRunDigest: GovernedDevGitDigestV1?
    var postRunDigest: GovernedDevGitDigestV1?
    var diffStat: String?
    var changedFiles: [String]?
    var cliJSONEventCount: Int?
    var commandEventCount: Int?
    var toolEventCount: Int?
    var stdoutSHA256: String?
    var stderrSHA256: String?
    var artifactPath: String?
    var terminalReceiptID: String?
    var failureCode: String?
    var updatedAt: Date

    init(
        schema: String = "GovernedDevPersistedRunV1",
        runID: String,
        state: State,
        dispatchID: String?,
        contractID: String,
        modelID: String,
        effort: String,
        readOnly: Bool,
        repositoryRoot: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        baseCommit: String? = nil,
        preRunDigest: GovernedDevGitDigestV1? = nil,
        postRunDigest: GovernedDevGitDigestV1? = nil,
        diffStat: String? = nil,
        changedFiles: [String]? = nil,
        cliJSONEventCount: Int? = nil,
        commandEventCount: Int? = nil,
        toolEventCount: Int? = nil,
        stdoutSHA256: String? = nil,
        stderrSHA256: String? = nil,
        artifactPath: String? = nil,
        terminalReceiptID: String? = nil,
        failureCode: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.schema = schema
        self.runID = runID
        self.state = state
        self.dispatchID = dispatchID
        self.contractID = contractID
        self.modelID = modelID
        self.effort = effort
        self.readOnly = readOnly
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.baseCommit = baseCommit
        self.preRunDigest = preRunDigest
        self.postRunDigest = postRunDigest
        self.diffStat = diffStat
        self.changedFiles = changedFiles
        self.cliJSONEventCount = cliJSONEventCount
        self.commandEventCount = commandEventCount
        self.toolEventCount = toolEventCount
        self.stdoutSHA256 = stdoutSHA256
        self.stderrSHA256 = stderrSHA256
        self.artifactPath = artifactPath
        self.terminalReceiptID = terminalReceiptID
        self.failureCode = failureCode
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schema, runID, state, dispatchID, contractID, modelID, effort
        case readOnly, repositoryRoot, worktreePath, worktreeBranch
        case baseCommit, preRunDigest, postRunDigest, diffStat, changedFiles
        case cliJSONEventCount, commandEventCount, toolEventCount
        case stdoutSHA256, stderrSHA256
        case artifactPath, terminalReceiptID, failureCode, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(String.self, forKey: .schema)
            ?? "GovernedDevPersistedRunV1"
        runID = try values.decode(String.self, forKey: .runID)
        state = try values.decode(State.self, forKey: .state)
        dispatchID = try values.decodeIfPresent(String.self, forKey: .dispatchID)
        contractID = try values.decodeIfPresent(String.self, forKey: .contractID) ?? ""
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? ""
        readOnly = try values.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        repositoryRoot = try values.decodeIfPresent(String.self, forKey: .repositoryRoot)
        worktreePath = try values.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeBranch = try values.decodeIfPresent(String.self, forKey: .worktreeBranch)
        baseCommit = try values.decodeIfPresent(String.self, forKey: .baseCommit)
        preRunDigest = try values.decodeIfPresent(
            GovernedDevGitDigestV1.self,
            forKey: .preRunDigest)
        postRunDigest = try values.decodeIfPresent(
            GovernedDevGitDigestV1.self,
            forKey: .postRunDigest)
        diffStat = try values.decodeIfPresent(String.self, forKey: .diffStat)
        changedFiles = try values.decodeIfPresent(
            [String].self,
            forKey: .changedFiles)
        cliJSONEventCount = try values.decodeIfPresent(
            Int.self,
            forKey: .cliJSONEventCount)
        commandEventCount = try values.decodeIfPresent(
            Int.self,
            forKey: .commandEventCount)
        toolEventCount = try values.decodeIfPresent(
            Int.self,
            forKey: .toolEventCount)
        stdoutSHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .stdoutSHA256)
        stderrSHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .stderrSHA256)
        artifactPath = try values.decodeIfPresent(String.self, forKey: .artifactPath)
        terminalReceiptID = try values.decodeIfPresent(String.self, forKey: .terminalReceiptID)
        failureCode = try values.decodeIfPresent(String.self, forKey: .failureCode)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

struct GovernedDevSessionRunJournal: Sendable {
    let directoryURL: URL

    init(rootDirectoryURL: URL) {
        self.directoryURL = rootDirectoryURL
            .appendingPathComponent("governed-dev-runs", isDirectory: true)
            .standardizedFileURL
    }

    func save(_ run: GovernedDevPersistedRunV1) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: url(for: run.runID), options: [.atomic])
    }

    func load(runID: String) throws -> GovernedDevPersistedRunV1? {
        let fileURL = url(for: runID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            GovernedDevPersistedRunV1.self,
            from: Data(contentsOf: fileURL))
    }

    @discardableResult
    func reconcileInterruptedRuns(now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return 0
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var count = 0
        for fileURL in try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) where fileURL.pathExtension == "json"
        {
            guard var run = try? decoder.decode(
                GovernedDevPersistedRunV1.self,
                from: Data(contentsOf: fileURL)),
                  run.state == .running
            else { continue }
            run.state = .interrupted
            run.updatedAt = now
            try save(run)
            count += 1
        }
        return count
    }

    private func url(for runID: String) -> URL {
        directoryURL.appendingPathComponent(
            GovernedDevSessionRunner.safeIdentifier(runID) + ".json")
    }
}

private struct GovernedDevWorktree: Sendable, Equatable {
    let repositoryRoot: URL
    let url: URL
    let branch: String
    let baseCommit: String
}

private struct GovernedDevCLIPlan: Sendable {
    enum Vendor: Sendable {
        case claude(expectedVendorModelID: String)
        case codex
    }

    let vendor: Vendor
    let invocation: GovernedDevProcessInvocation
}

private struct GovernedDevCLIObservation: Sendable {
    let jsonEventCount: Int
    let commandEventCount: Int
    let toolEventCount: Int
    let assistantText: String?
    let claudeAttested: Bool
    let codexAttested: Bool
}

final class GovernedDevCLIEventAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let modelID: String
    private let claudeVendorModelID: String?
    private let onEvent: @Sendable (ChatCLIEvent) -> Void
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var jsonEventCount = 0
    private var commandEventCount = 0
    private var toolEventCount = 0
    private var assistantFragments: [String] = []
    private var finalAssistantText: String?
    private var claudeResultAttested = false
    private var claudeFallbackDetected = false
    private var codexModelEchoes: Set<String> = []

    init(
        modelID: String,
        claudeVendorModelID: String?,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        self.modelID = modelID
        self.claudeVendorModelID = claudeVendorModelID
        self.onEvent = onEvent
    }

    func consume(
        stream: GovernedDevProcessInvocation.OutputStream,
        data: Data
    ) {
        guard !data.isEmpty else { return }
        switch stream {
        case .stdout:
            let lines = lock.withLock { () -> [Data] in
                stdoutBuffer.append(data)
                return Self.extractLines(from: &stdoutBuffer)
            }
            lines.forEach(consumeJSONLine)
        case .stderr:
            let lines = lock.withLock { () -> [Data] in
                stderrBuffer.append(data)
                return Self.extractLines(from: &stderrBuffer)
            }
            for line in lines {
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onEvent(.diagnostic(text)) }
            }
        }
    }

    fileprivate func finish() -> GovernedDevCLIObservation {
        let stdoutTail = lock.withLock { () -> Data in
            defer { stdoutBuffer.removeAll() }
            return stdoutBuffer
        }
        if !stdoutTail.isEmpty { consumeJSONLine(stdoutTail) }
        let stderrTail = lock.withLock { () -> Data in
            defer { stderrBuffer.removeAll() }
            return stderrBuffer
        }
        let diagnostic = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !diagnostic.isEmpty { onEvent(.diagnostic(diagnostic)) }
        return lock.withLock {
            GovernedDevCLIObservation(
                jsonEventCount: jsonEventCount,
                commandEventCount: commandEventCount,
                toolEventCount: toolEventCount,
                assistantText: finalAssistantText
                    ?? (assistantFragments.isEmpty
                        ? nil : assistantFragments.joined(separator: "\n")),
                claudeAttested: claudeResultAttested && !claudeFallbackDetected,
                codexAttested:
                    codexModelEchoes == Set([modelID]))
        }
    }

    static func validateClaudeStream(
        _ data: Data,
        expectedVendorModelID: String
    ) -> Bool {
        let accumulator = GovernedDevCLIEventAccumulator(
            modelID: expectedVendorModelID,
            claudeVendorModelID: expectedVendorModelID,
            onEvent: { _ in })
        accumulator.consume(stream: .stdout, data: data)
        return accumulator.finish().claudeAttested
    }

    private func consumeJSONLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any]
        else {
            let raw = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { onEvent(.raw(raw)) }
            return
        }
        let type = (object["type"] as? String ?? "").lowercased()
        var emittedText: String?
        lock.withLock {
            jsonEventCount += 1
            if Self.isCommandEvent(type: type, object: object) {
                commandEventCount += 1
            } else if Self.isToolEvent(type: type, object: object) {
                toolEventCount += 1
            }
            if let expected = claudeVendorModelID {
                if type == "fallback" {
                    claudeFallbackDetected = true
                }
                if type == "system" {
                    let subtype = (object["subtype"] as? String ?? "")
                        .lowercased()
                    if subtype == "fallback"
                        || subtype == "model_refusal_fallback"
                    {
                        claudeFallbackDetected = true
                    }
                }
                if type == "result" {
                    claudeResultAttested = Self.isValidClaudeResult(
                        object,
                        expectedVendorModelID: expected)
                    if let result = object["result"] as? String,
                       !result.isEmpty
                    {
                        finalAssistantText = result
                        emittedText = result
                    }
                } else if type == "assistant" {
                    emittedText = Self.claudeAssistantText(object)
                }
            } else {
                if Self.isCodexAttestationEvent(type) {
                    codexModelEchoes.formUnion(Self.modelEchoes(in: object))
                }
                emittedText = Self.codexAssistantText(object)
            }
            if let emittedText, !emittedText.isEmpty {
                assistantFragments.append(emittedText)
            }
        }
        if Self.isCommandEvent(type: type, object: object) {
            onEvent(.toolUse(ChatCLIActivity(
                text: Self.toolName(in: object) ?? "command",
                rawType: type)))
        } else if Self.isToolEvent(type: type, object: object) {
            onEvent(.toolUse(ChatCLIActivity(
                text: Self.toolName(in: object) ?? "tool",
                rawType: type)))
        }
        if let emittedText, !emittedText.isEmpty {
            onEvent(.output(emittedText))
        }
    }

    private static func extractLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    private static func isValidClaudeResult(
        _ object: [String: Any],
        expectedVendorModelID: String
    ) -> Bool {
        guard object["subtype"] as? String == "success",
              object["is_error"] as? Bool == false,
              let usage = object["modelUsage"] as? [String: Any]
        else { return false }
        var foundExpected = false
        for value in usage.values {
            guard let entry = value as? [String: Any],
                  let canonical = entry["canonicalModel"] as? String,
                  entry["provider"] as? String == "firstParty",
                  ((entry["outputTokens"] as? NSNumber)?.intValue ?? 0) > 0
            else { return false }
            if canonical == expectedVendorModelID {
                foundExpected = true
            } else if !canonical.hasPrefix("claude-haiku-") {
                return false
            }
        }
        return foundExpected
    }

    private static func claudeAssistantText(
        _ object: [String: Any]
    ) -> String? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        let text = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func codexAssistantText(
        _ object: [String: Any]
    ) -> String? {
        let type = (object["type"] as? String ?? "").lowercased()
        if type == "item.completed",
           let item = object["item"] as? [String: Any],
           ["agent_message", "agentmessage"].contains(
                (item["type"] as? String ?? "").lowercased()),
           let text = item["text"] as? String
        {
            return text
        }
        if let text = object["output_text"] as? String { return text }
        if let response = object["response"] as? [String: Any],
           let text = response["output_text"] as? String
        {
            return text
        }
        return nil
    }

    private static func isCodexAttestationEvent(_ type: String) -> Bool {
        type == "thread.started"
            || type == "turn.started"
            || type == "turn.completed"
            || type == "response.started"
            || type == "response.completed"
    }

    private static func modelEchoes(in object: [String: Any]) -> Set<String> {
        var result: Set<String> = []
        func visit(_ value: Any, key: String?) {
            if let object = value as? [String: Any] {
                for (childKey, child) in object {
                    visit(child, key: childKey)
                }
            } else if let values = value as? [Any] {
                values.forEach { visit($0, key: key) }
            } else if let string = value as? String,
                      ["model", "model_id", "modelid", "canonical_model"]
                        .contains(key?.lowercased() ?? "")
            {
                result.insert(string.lowercased())
            }
        }
        visit(object, key: nil)
        return result
    }

    private static func isCommandEvent(
        type: String,
        object: [String: Any]
    ) -> Bool {
        if type.contains("exec_command") || type.contains("command_execution") {
            return true
        }
        let name = toolName(in: object)?.lowercased() ?? ""
        return name == "bash"
            || name.contains("exec_command")
            || name.contains("command_execution")
    }

    private static func isToolEvent(
        type: String,
        object: [String: Any]
    ) -> Bool {
        if type.contains("tool") || type.contains("patch") {
            return true
        }
        guard let name = toolName(in: object)?.lowercased() else { return false }
        return ["read", "write", "edit", "grep", "glob", "webfetch", "websearch"]
            .contains(name)
    }

    private static func toolName(in object: [String: Any]) -> String? {
        if let name = object["name"] as? String { return name }
        if let item = object["item"] as? [String: Any] {
            return item["name"] as? String ?? item["type"] as? String
        }
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           let tool = content.first(where: {
               $0["type"] as? String == "tool_use"
           })
        {
            return tool["name"] as? String
        }
        return nil
    }
}

final class GovernedDevSessionRunner:
    ChatNativeAgentRunning,
    @unchecked Sendable
{
    static let productionMaximumRunDuration =
        ChatNativeAgentRunner.productionMaximumRunDuration

    private struct TerminalReceipt: Codable, Sendable {
        let schema: String
        let receiptID: String
        let runID: String
        let dispatchID: String?
        let modelID: String
        let effort: String
        let contractID: String
        let eventCount: Int
        let assistantTextSHA256: String?
        let completedAt: Date
        let outputRef: String
    }

    private enum ExecutionOutcome: Sendable {
        case process(GovernedDevProcessResult)
        case timedOut
        case cancelled
        case failed(String)
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var activeProcessRunner: (any GovernedDevProcessRunning)?
    private var activeRunToken: UUID?
    private let journalDirectoryURL: URL
    private let runtimeGovernor: TatwoRuntimeGovernor
    private let maximumRunDuration: TimeInterval
    private let environment: [String: String]
    private let bundleURL: URL
    private let isExecutableFile: @Sendable (String) -> Bool
    private let processRunnerFactory:
        @Sendable () -> any GovernedDevProcessRunning
    private let now: @Sendable () -> Date

    init(
        journalDirectoryURL: URL,
        runtimeGovernor: TatwoRuntimeGovernor = .shared,
        maximumRunDuration: TimeInterval =
            GovernedDevSessionRunner.productionMaximumRunDuration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        processRunnerFactory:
            @escaping @Sendable () -> any GovernedDevProcessRunning = {
                GovernedDevProcessRunner()
            },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.journalDirectoryURL = journalDirectoryURL.standardizedFileURL
        self.runtimeGovernor = runtimeGovernor
        self.maximumRunDuration = max(0.01, maximumRunDuration)
        self.environment = environment
        self.bundleURL = bundleURL.standardizedFileURL
        self.isExecutableFile = isExecutableFile
        self.processRunnerFactory = processRunnerFactory
        self.now = now
    }

    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        terminate()
        let identity = ChatRunnerAttemptIdentity(
            runID: request.runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        let runToken = UUID()
        let processRunner = processRunnerFactory()
        lock.withLock {
            activeProcessRunner = processRunner
            activeRunToken = runToken
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let lease = runtimeGovernor.registerExternalRuntime(
                kind: .xxlGoalSpawn,
                gentleTermination: { processRunner.stop() })
            defer {
                runtimeGovernor.release(lease)
                lock.withLock {
                    guard activeRunToken == runToken else { return }
                    activeProcessRunner = nil
                    activeRunToken = nil
                    self.task = nil
                }
            }
            await run(
                request: request,
                processRunner: processRunner,
                onEvent: onEvent)
        }
        lock.withLock {
            if activeRunToken == runToken {
                self.task = task
            }
        }
        return identity
    }

    func terminate() {
        let current = lock.withLock { () -> (Task<Void, Never>?, (any GovernedDevProcessRunning)?) in
            let value = (task, activeProcessRunner)
            task = nil
            activeProcessRunner = nil
            activeRunToken = nil
            return value
        }
        current.1?.stop()
        current.0?.cancel()
    }

    private func run(
        request: ChatNativeAgentRunRequest,
        processRunner: any GovernedDevProcessRunning,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) async {
        let journal = GovernedDevSessionRunJournal(
            rootDirectoryURL: journalDirectoryURL)
        _ = try? journal.reconcileInterruptedRuns(now: now())
        var persisted = GovernedDevPersistedRunV1(
            runID: request.runID,
            state: .running,
            dispatchID: request.dispatchID,
            contractID: request.contractID,
            modelID: request.modelID,
            effort: request.effort,
            readOnly: request.readOnly,
            updatedAt: now())
        do {
            // M4a Grok goal-dispatch remains locked. If enabled, it must not
            // inherit --always-approve; narrow it with --deny rules or keep it locked.
            if request.modelID == "grok-build" {
                throw GovernedDevSessionFailure.grokAttestationUnverified
            }
            let prior = try journal.load(runID: request.runID)
            let worktree = try prepareWorktree(
                request: request,
                resumableRun: prior)
            persisted.repositoryRoot = worktree.repositoryRoot.path
            persisted.worktreePath = worktree.url.path
            persisted.worktreeBranch = worktree.branch
            persisted.baseCommit = worktree.baseCommit
            persisted.updatedAt = now()
            try journal.save(persisted)

            let preRunDigest = try gitDigest(at: worktree.url)
            persisted.preRunDigest = preRunDigest
            persisted.updatedAt = now()
            try journal.save(persisted)
            let plan = try cliPlan(request: request, worktree: worktree)
            let expectedClaudeModel: String?
            switch plan.vendor {
            case .claude(let expected): expectedClaudeModel = expected
            case .codex: expectedClaudeModel = nil
            }
            let accumulator = GovernedDevCLIEventAccumulator(
                modelID: request.modelID,
                claudeVendorModelID: expectedClaudeModel,
                onEvent: onEvent)
            let outcome = await execute(
                plan.invocation,
                processRunner: processRunner,
                onOutput: { stream, data in
                    accumulator.consume(stream: stream, data: data)
                })
            let observation = accumulator.finish()
            switch outcome {
            case .timedOut:
                persisted.state = .timedOut
                persisted.failureCode = "governed_dev_timeout"
                persisted.updatedAt = now()
                try? journal.save(persisted)
                onEvent(.runtimeFailure(
                    "Governed development session timed out after \(Int(maximumRunDuration)) seconds"))
                onEvent(.exit(1))
                return
            case .cancelled:
                persisted.state = .cancelled
                persisted.updatedAt = now()
                try? journal.save(persisted)
                onEvent(.exit(130))
                return
            case .failed(let code):
                throw GovernedDevSessionFailure.processFailure(code)
            case .process(let result):
                guard result.exitCode == 0 else {
                    throw GovernedDevSessionFailure.cliExited(result.exitCode)
                }
                switch plan.vendor {
                case .claude:
                    guard observation.claudeAttested else {
                        throw GovernedDevSessionFailure.claudeAttestationMismatch
                    }
                case .codex:
                    guard observation.codexAttested else {
                        throw GovernedDevSessionFailure.codexAttestationMismatch
                    }
                }
                let completedAt = now()
                let postRunDigest = try gitDigest(at: worktree.url)
                let diffStat = try gitText(
                    ["diff", "--stat", "--no-ext-diff", "HEAD"],
                    at: worktree.url)
                let changedFiles = try changedFiles(at: worktree.url)
                let stdoutSHA256 = Self.sha256(result.stdout)
                let stderrSHA256 = Self.sha256(result.stderr)
                let assistantDigest = observation.assistantText.map {
                    Self.sha256(Data($0.utf8))
                }
                let receiptID = terminalReceiptID(
                    request: request,
                    eventCount: observation.jsonEventCount,
                    assistantTextSHA256: assistantDigest,
                    completedAt: completedAt)
                let artifactURL = journalDirectoryURL
                    .appendingPathComponent(
                        "governed-dev-artifacts",
                        isDirectory: true)
                    .appendingPathComponent(
                        Self.safeIdentifier(request.runID) + ".json")
                let artifact = GovernedDevSessionArtifactV1(
                    schema: "GovernedDevSessionArtifactV1",
                    runID: request.runID,
                    dispatchID: request.dispatchID,
                    contractID: request.contractID,
                    modelID: request.modelID,
                    effort: request.effort,
                    readOnly: request.readOnly,
                    repositoryRoot: worktree.repositoryRoot.path,
                    worktreePath: worktree.url.path,
                    worktreeBranch: worktree.branch,
                    baseCommit: worktree.baseCommit,
                    outputRefDescription:
                        "baseCommit=\(worktree.baseCommit);worktree=\(worktree.url.path)",
                    preRunDigest: preRunDigest,
                    postRunDigest: postRunDigest,
                    diffStat: diffStat,
                    changedFiles: changedFiles,
                    cliJSONEventCount: observation.jsonEventCount,
                    commandEventCount: observation.commandEventCount,
                    toolEventCount: observation.toolEventCount,
                    stdoutSHA256: stdoutSHA256,
                    stderrSHA256: stderrSHA256,
                    terminalReceiptID: receiptID,
                    completedAt: completedAt)
                try persist(artifact, at: artifactURL)
                let terminal = TerminalReceipt(
                    schema: "TatwoNativeTerminalReceiptV1",
                    receiptID: receiptID,
                    runID: request.runID,
                    dispatchID: request.dispatchID,
                    modelID: request.modelID,
                    effort: request.effort,
                    contractID: request.contractID,
                    eventCount: observation.jsonEventCount,
                    assistantTextSHA256: assistantDigest,
                    completedAt: completedAt,
                    outputRef: artifactURL.path)
                let terminalURL = journalDirectoryURL
                    .appendingPathComponent(
                        "native-terminal-receipts",
                        isDirectory: true)
                    .appendingPathComponent(
                        Self.safeIdentifier(request.runID) + ".json")
                try persist(terminal, at: terminalURL)
                persisted.state = .completed
                persisted.postRunDigest = postRunDigest
                persisted.diffStat = diffStat
                persisted.changedFiles = changedFiles
                persisted.cliJSONEventCount = observation.jsonEventCount
                persisted.commandEventCount = observation.commandEventCount
                persisted.toolEventCount = observation.toolEventCount
                persisted.stdoutSHA256 = stdoutSHA256
                persisted.stderrSHA256 = stderrSHA256
                persisted.artifactPath = artifactURL.path
                persisted.terminalReceiptID = receiptID
                persisted.failureCode = nil
                persisted.updatedAt = completedAt
                try journal.save(persisted)
                onEvent(.nativeTerminalReceipt(
                    receiptID: receiptID,
                    outputRef: artifactURL.path))
                onEvent(.exit(0))
            }
        } catch is CancellationError {
            persisted.state = .cancelled
            persisted.updatedAt = now()
            try? journal.save(persisted)
            onEvent(.exit(130))
        } catch let failure as GovernedDevSessionFailure {
            persisted.state = .failed
            persisted.failureCode = failure.code
            persisted.updatedAt = now()
            try? journal.save(persisted)
            onEvent(.runtimeFailure(
                "Governed development session failed: \(failure.code)"))
            onEvent(.exit(1))
        } catch {
            persisted.state = .failed
            persisted.failureCode = "governed_dev_runtime_error"
            persisted.updatedAt = now()
            try? journal.save(persisted)
            onEvent(.runtimeFailure(
                "Governed development session failed: governed_dev_runtime_error"))
            onEvent(.exit(1))
        }
    }

    private func execute(
        _ invocation: GovernedDevProcessInvocation,
        processRunner: any GovernedDevProcessRunning,
        onOutput: @escaping @Sendable (
            GovernedDevProcessInvocation.OutputStream,
            Data
        ) -> Void
    ) async -> ExecutionOutcome {
        await withTaskGroup(of: ExecutionOutcome?.self) { group in
            group.addTask {
                do {
                    let result = try await processRunner.run(
                        invocation: invocation,
                        onOutput: onOutput)
                    return .process(result)
                } catch is CancellationError {
                    return .cancelled
                } catch let failure as GovernedDevSessionFailure {
                    return .failed(failure.code)
                } catch {
                    return .failed("governed_dev_process_error")
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            self.maximumRunDuration * 1_000_000_000))
                } catch {
                    return nil
                }
                guard !Task.isCancelled else { return nil }
                processRunner.stop()
                return .timedOut
            }
            while let next = await group.next() {
                guard let next else { continue }
                group.cancelAll()
                if case .process = next {
                    return next
                }
                processRunner.stop()
                return next
            }
            return .cancelled
        }
    }

    private func prepareWorktree(
        request: ChatNativeAgentRunRequest,
        resumableRun: GovernedDevPersistedRunV1?
    ) throws -> GovernedDevWorktree {
        let workspace = URL(
            fileURLWithPath: request.workspaceRoot,
            isDirectory: true).standardizedFileURL
        let repositoryPath: String
        do {
            repositoryPath = try gitText(
                ["rev-parse", "--show-toplevel"],
                at: workspace)
        } catch {
            throw GovernedDevSessionFailure.workspaceNotGitRepository
        }
        let repositoryRoot = URL(
            fileURLWithPath: repositoryPath,
            isDirectory: true).standardizedFileURL
        let baseCommit = try gitText(["rev-parse", "HEAD"], at: workspace)
        let dispatchSource = request.dispatchID ?? request.runID
        // 2026-08-21 WTFIX：真實 dispatch id 形如
        // "dispatch-binding-<slot>-<ts>-<seq>"，唯一性在尾端；prefix(8)
        // 會把每個派工都切成同名 "dispatch"，第二個派工起全體
        // governed_dev_worktree_collision。改用全 id 雜湊前 8 碼。
        let shortID = Self.worktreeShortID(for: dispatchSource)
        guard !shortID.isEmpty else {
            throw GovernedDevSessionFailure.worktreeCreationFailed
        }
        let worktreeURL = repositoryRoot
            .appendingPathComponent(".worktrees", isDirectory: true)
            .appendingPathComponent("dispatch-\(shortID)", isDirectory: true)
            .standardizedFileURL
        let branch = "tatwo-dispatch-\(shortID)"
        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            guard resumableRun?.state == .interrupted,
                  resumableRun?.worktreePath == worktreeURL.path,
                  resumableRun?.baseCommit == baseCommit,
                  (try? gitText(["rev-parse", "HEAD"], at: worktreeURL)) != nil
            else {
                throw GovernedDevSessionFailure.worktreeCollision
            }
            return GovernedDevWorktree(
                repositoryRoot: repositoryRoot,
                url: worktreeURL,
                branch: resumableRun?.worktreeBranch ?? branch,
                baseCommit: baseCommit)
        }
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            _ = try gitData(
                [
                    "worktree", "add", "-b", branch,
                    worktreeURL.path, baseCommit,
                ],
                at: repositoryRoot)
        } catch {
            throw GovernedDevSessionFailure.worktreeCreationFailed
        }
        return GovernedDevWorktree(
            repositoryRoot: repositoryRoot,
            url: worktreeURL,
            branch: branch,
            baseCommit: baseCommit)
    }

    private func cliPlan(
        request: ChatNativeAgentRunRequest,
        worktree: GovernedDevWorktree
    ) throws -> GovernedDevCLIPlan {
        let executableName: String
        let helperName: String
        let vendor: GovernedDevCLIPlan.Vendor
        var arguments: [String]
        let standardInput: Data?
        var launchEnvironment: [String: String]
        switch request.modelID {
        case "fable-5", "opus-5":
            executableName = "claude"
            helperName = ChatNativeClaudeSubscriptionRuntimeLocator.helperName
            guard let vendorModel = ClaudeSpawnAuthority.vendorModelID(
                for: request.modelID)
            else {
                throw GovernedDevSessionFailure.unsupportedModel
            }
            vendor = .claude(expectedVendorModelID: vendorModel)
            launchEnvironment = [:]
            let permissionArguments = request.readOnly
                ? ["--permission-mode", "default"]
                : ["--permission-mode", "acceptEdits"]
            arguments = [
                "-p",
                "--output-format", "stream-json",
                "--verbose",
            ] + permissionArguments + [request.prompt]
            standardInput = nil
        case "gpt-5.6-sol":
            executableName = "codex"
            helperName = ChatNativeSubscriptionRuntimeLocator.helperName
            vendor = .codex
            let home = ChatNativeSubscriptionHomeLocator(
                environment: self.environment).resolve()
            launchEnvironment = ChatNativeSubscriptionEnvironment
                .isolatedProcessEnvironment(
                    inheriting: self.environment,
                    homeURL: home)
            arguments = [
                "exec",
                "--json",
                "-C", worktree.url.path,
                "-s", request.readOnly ? "read-only" : "workspace-write",
                "-m", request.modelID,
                "-c", "model_reasoning_effort=\"\(request.effort)\"",
                "-",
            ]
            standardInput = Data(request.prompt.utf8)
        case "grok-build":
            throw GovernedDevSessionFailure.grokAttestationUnverified
        default:
            throw GovernedDevSessionFailure.unsupportedModel
        }
        guard let executable = resolveExecutable(
            executableName: executableName,
            bundledHelperName: helperName)
        else {
            throw GovernedDevSessionFailure.runtimeUnavailable
        }
        if case .claude = vendor {
            let home = ChatNativeClaudeSubscriptionHomeLocator(
                environment: self.environment).resolve()
            let toolPolicy = request.readOnly
                ? ClaudeSpawnToolPolicy(
                    tools: ["Read", "Grep", "Glob"],
                    allowedTools: ["Read", "Grep", "Glob"])
                : ClaudeSpawnToolPolicy(
                    tools: ["Read", "Grep", "Glob", "Edit", "Write", "Bash"],
                    allowedTools: ["Read", "Grep", "Glob", "Edit", "Write", "Bash"])
            let authorityPlan = try ClaudeSpawnAuthority(
                executableURL: executable,
                profileHomeURL: home,
                environment: self.environment
            ).plan(ClaudeSpawnRequest(
                purpose: .devRunner,
                canonicalModelSlug: request.modelID,
                effort: request.effort,
                toolPolicy: toolPolicy,
                networkPolicy: .allowed,
                workingDirectory: worktree.url,
                additionalArguments: arguments))
            arguments = authorityPlan.arguments
            launchEnvironment = authorityPlan.environment
        }
        let forbidden = ["bypassPermissions", "danger-full-access"]
        guard !arguments.contains(where: forbidden.contains) else {
            throw GovernedDevSessionFailure.runtimeUnavailable
        }
        return GovernedDevCLIPlan(
            vendor: vendor,
            invocation: GovernedDevProcessInvocation(
                executableURL: executable,
                arguments: arguments,
                standardInput: standardInput,
                environment: launchEnvironment,
                currentDirectoryURL: worktree.url))
    }

    private func resolveExecutable(
        executableName: String,
        bundledHelperName: String
    ) -> URL? {
        let helpers = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .standardizedFileURL
        let bundled = helpers
            .appendingPathComponent(bundledHelperName)
            .standardizedFileURL
        if bundled.path.hasPrefix(helpers.path + "/"),
           isExecutableFile(bundled.path)
        {
            return bundled
        }
        for segment in (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
        {
            let candidate = URL(
                fileURLWithPath: String(segment),
                isDirectory: true)
                .appendingPathComponent(executableName)
                .standardizedFileURL
            if isExecutableFile(candidate.path) { return candidate }
        }
        return nil
    }

    private func gitDigest(at directory: URL) throws -> GovernedDevGitDigestV1 {
        GovernedDevGitDigestV1(
            headCommit: try gitText(["rev-parse", "HEAD"], at: directory),
            statusPorcelainSHA256: Self.sha256(
                try gitData(
                    ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                    at: directory)))
    }

    private func changedFiles(at directory: URL) throws -> [String] {
        let status = String(
            decoding: try gitData(
                ["status", "--porcelain=v1", "--untracked-files=all"],
                at: directory),
            as: UTF8.self)
        return status.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.count >= 4 else { return nil }
            let path = String(line.dropFirst(3))
            if let range = path.range(of: " -> ") {
                return String(path[range.upperBound...])
            }
            return path
        }.sorted()
    }

    private func terminalReceiptID(
        request: ChatNativeAgentRunRequest,
        eventCount: Int,
        assistantTextSHA256: String?,
        completedAt: Date
    ) -> String {
        let canonical = [
            "TatwoNativeTerminalReceiptV1",
            request.runID,
            request.dispatchID ?? "",
            request.modelID,
            request.effort,
            request.contractID,
            String(eventCount),
            assistantTextSHA256 ?? "",
            String(Int64(completedAt.timeIntervalSince1970)),
        ].joined(separator: "\n")
        return "native-terminal:\(Self.sha256(Data(canonical.utf8)))"
    }

    private func persist<Value: Encodable>(
        _ value: Value,
        at fileURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: [.atomic])
    }

    private func gitText(_ arguments: [String], at directory: URL) throws -> String {
        String(decoding: try gitData(arguments, at: directory), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitData(_ arguments: [String], at directory: URL) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw GovernedDevSessionFailure.workspaceNotGitRepository
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GovernedDevSessionFailure.workspaceNotGitRepository
        }
        return data
    }

    /// Collision-proof per-dispatch worktree name; unique across dispatch ids
    /// whose distinguishing part is anywhere in the string.
    static func worktreeShortID(for dispatchSource: String) -> String {
        let safe = safeIdentifier(dispatchSource)
        guard !safe.isEmpty else { return "" }
        return String(sha256(Data(safe.utf8)).prefix(8))
    }

    static func safeIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                ? Character(String($0)) : "_"
        })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
