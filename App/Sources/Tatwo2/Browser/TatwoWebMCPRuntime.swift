import Foundation
import CoreFoundation
import Darwin

struct WebMCPFailure: Error, LocalizedError, Equatable {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { code }
}

struct WebMCPTool: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchemaJSON: String
    let effect: EmbeddedBrowserSiteToolEffect
    // Retain renderer identity for replacement/invalidation checks, never expose it to the model.
    let contextID: String?

    static func classify(name: String, description: String, schema: [String: Any]) -> EmbeddedBrowserSiteToolEffect {
        let annotations = schema["annotations"] as? [String: Any] ?? [:]
        func hint(_ key: String) -> Bool {
            let value = annotations[key] ?? schema[key]
            let boolean = (value as? NSNumber).map {
                CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
            } ?? false
            return boolean || description.range(
                of: #"\b"# + key + #"["']?\s*:\s*true\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        }
        // Split camelCase and separators, not substrings such as "display" or "ready".
        func words(_ text: String) -> [String] {
            text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        if hint("destructiveHint") || words(name + " " + description).contains(where: {
            ["delete", "pay", "send"].contains($0)
        }) { return .highRisk }
        if hint("readOnlyHint") || words(name).first.map({ ["get", "list", "search", "read"].contains($0) }) == true {
            return .readOnly
        }
        return .sideEffect
    }
}

struct WebMCPPageTools: Equatable, Sendable {
    let origin: String
    let navigationGeneration: UInt64
    let tools: [WebMCPTool]

    // Match the renderer's UTF-8 limits; bound the aggregate registry as well.
    static let maximumNameBytes = 128
    static let maximumDescriptionBytes = 8_192
    static let maximumSchemaBytes = 65_536
    static let maximumPayloadBytes = 1_048_576
    static let maximumTools = 128
    static let maximumJSONDepth = 16

    static func origin(of url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.scheme == "http" && parts.port == 80 || parts.scheme == "https" && parts.port == 443 { parts.port = nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }

    static func boundedJSON(_ text: String, maximumBytes: Int, objectOnly: Bool = true) throws -> Any {
        guard text.utf8.count <= maximumBytes else { throw WebMCPFailure("payload_too_large") }
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              !objectOnly || value is [String: Any] else { throw WebMCPFailure("invalid_json") }
        func bounded(_ value: Any, depth: Int) -> Bool {
            guard depth <= maximumJSONDepth else { return false }
            if let array = value as? [Any] {
                return array.count <= 4096 && array.allSatisfy { bounded($0, depth: depth + 1) }
            }
            if let object = value as? [String: Any] {
                return object.count <= 4096 && object.values.allSatisfy { bounded($0, depth: depth + 1) }
            }
            return true
        }
        guard bounded(value, depth: 0) else { throw WebMCPFailure("json_limit_exceeded") }
        return value
    }

    static func parse(_ text: String) throws -> Self {
        let value = try boundedJSON(text, maximumBytes: maximumPayloadBytes)
        guard let snapshot = value as? [String: Any],
              snapshot["schema"] as? String == "TatwoCEFWebMCPToolsSnapshotV1",
              let rawOrigin = snapshot["origin"] as? String, rawOrigin.utf8.count <= 8192,
              let url = URL(string: rawOrigin), let origin = origin(of: url),
              rawOrigin == origin || rawOrigin == origin + "/",
              let generation = generation(snapshot["navigationGeneration"]),
              let records = snapshot["tools"] as? [[String: Any]] else { throw WebMCPFailure("invalid_snapshot") }
        guard records.count <= maximumTools else { throw WebMCPFailure("too_many_tools") }
        var names = Set<String>()
        let tools = try records.map { record -> WebMCPTool in
            guard let name = record["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let description = record["description"] as? String,
                  let schemaJSON = record["inputSchemaJSON"] as? String,
                  names.insert(name).inserted else { throw WebMCPFailure("invalid_tool") }
            guard name.utf8.count <= maximumNameBytes,
                  description.utf8.count <= maximumDescriptionBytes else { throw WebMCPFailure("tool_too_large") }
            guard record["origin"] as? String == rawOrigin,
                  Self.generation(record["navigationGeneration"]) == generation else { throw WebMCPFailure("stale_page") }
            let schema = try boundedJSON(schemaJSON, maximumBytes: maximumSchemaBytes) as! [String: Any]
            let contextID = record["contextID"] as? String
            guard contextID == nil || contextID!.utf8.count <= 128 else { throw WebMCPFailure("invalid_tool") }
            return WebMCPTool(name: name, description: description, inputSchemaJSON: schemaJSON,
                effect: WebMCPTool.classify(name: name, description: description, schema: schema), contextID: contextID)
        }
        return Self(origin: origin, navigationGeneration: generation, tools: tools)
    }

    private static func generation(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let generation = UInt64(number.stringValue), generation > 0 else { return nil }
        return generation
    }
}

enum WebMCPInvocationPolicy {
    enum Decision: String { case allow, confirm, reject }
    static func decision(effect: EmbeddedBrowserSiteToolEffect, preset: TatwoPermissionPreset?,
                         readOnlyCaller: Bool) -> Decision {
        if readOnlyCaller { return effect == .readOnly ? .allow : .reject }
        switch TatwoAgentConsentPolicy.resolve(user: preset, bot: nil, readOnly: false) {
        case .autoAllow(clearOnHumanInput: false): return .allow
        case .autoAllow(clearOnHumanInput: true): return effect == .readOnly ? .allow : .confirm
        case .askOncePerSession: return .confirm
        }
    }
}

/// Only the App constructs this context; no policy/caller overrides in the MCP schema.
struct WebMCPCaller: Equatable {
    let id: String
    let session: String
    let preset: TatwoPermissionPreset?
    let readOnly: Bool
}

@MainActor
final class TatwoWebMCPRuntime {
    typealias MainActorInvoker = @MainActor (
        _ pageToolName: String, _ argumentsJSON: String, _ navigationGeneration: UInt64,
        _ completion: @escaping (String?, String?) -> Void
    ) -> Void
    typealias Confirm = @MainActor (_ title: String, _ detail: String) async -> Bool
    static let shared = TatwoWebMCPRuntime()
    static let auditURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/webmcp-audit.log")

    private(set) var activeTabID: String?
    private var pages: [String: WebMCPPageTools] = [:]
    private var invokers: [String: MainActorInvoker] = [:]
    private var revisions: [String: UUID] = [:]
    private struct ConsentKey: Hashable {
        let caller: String
        let session: String
        let tabID: String
        let origin: String
    }
    private var readConsent = Set<ConsentKey>()
    private let confirm: Confirm
    private let audit: (String) -> Void
    private let log: (String) -> Void
    private let invocationTimeout: TimeInterval

    init(confirm: Confirm? = nil, audit: ((String) -> Void)? = nil,
         log: @escaping (String) -> Void = { NSLog("WebMCP: %@", $0) }, invocationTimeout: TimeInterval = 30) {
        self.confirm = confirm ?? { title, detail in
            await IslandNotice.shared.confirm(title: title, detail: detail, confirmLabel: "允許", timeout: 20)
        }
        self.audit = audit ?? { line in
            do { try Self.appendAudit(line, to: Self.auditURL) }
            catch { log("audit_write_failed") }
        }
        self.log = log
        self.invocationTimeout = invocationTimeout
    }

    func pageTools(tabID: String) -> WebMCPPageTools? { pages[tabID] }
    func isAttached(tabID: String) -> Bool { invokers[tabID] != nil }
    func activate(tabID: String) { activeTabID = tabID }
    func attach(tabID: String, invoker: @escaping MainActorInvoker) {
        // A replacement mount cannot inherit an old renderer's tools or consent.
        if invokers[tabID] != nil { detach(tabID: tabID) }
        invokers[tabID] = invoker
    }
    func detach(tabID: String) {
        invokers.removeValue(forKey: tabID)
        pages.removeValue(forKey: tabID)
        revisions.removeValue(forKey: tabID)
        readConsent = readConsent.filter { $0.tabID != tabID }
        if activeTabID == tabID { activeTabID = nil }
    }
    func update(tabID: String, snapshotJSONString: String) {
        do {
            let page = try WebMCPPageTools.parse(snapshotJSONString)
            if let old = pages[tabID], page.navigationGeneration < old.navigationGeneration {
                throw WebMCPFailure("stale_page")
            }
            pages[tabID] = page
            revisions[tabID] = UUID()
        } catch {
            // Never retain a callable old snapshot after rejecting its replacement.
            pages.removeValue(forKey: tabID)
            revisions.removeValue(forKey: tabID)
            readConsent = readConsent.filter { $0.tabID != tabID }
            log("snapshot_rejected:\((error as? WebMCPFailure)?.code ?? "invalid_snapshot")")
        }
    }

    func invoke(tabID: String, tool name: String, argumentsJSON: String,
                caller: WebMCPCaller = WebMCPCaller(id: "local", session: "local", preset: nil, readOnly: false),
                contextIsCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> String {
        var decision = WebMCPInvocationPolicy.Decision.reject
        var outcome = "failure"
        var failure = "unavailable"
        let page = pages[tabID]
        defer {
            // Fixed fields only. Never record arguments, output, schema, descriptions or renderer errors.
            let record = ["time": ISO8601DateFormatter().string(from: Date()),
                "caller": String(caller.id.prefix(128)), "origin": page?.origin ?? "",
                "tool": String(name.prefix(128)), "decision": decision.rawValue,
                "outcome": outcome, "error": failure]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { audit(line) }
        }
        do {
            try Task.checkCancellation()
            guard contextIsCurrent() else { throw WebMCPFailure("caller_changed") }
            guard let page, let tool = page.tools.first(where: { $0.name == name }),
                  let revision = revisions[tabID], let invoker = invokers[tabID] else {
                throw WebMCPFailure("tool_unavailable")
            }
            let metadata = EmbeddedBrowserSiteToolMetadata(identifier: tool.name, title: tool.description,
                origin: URL(string: page.origin)!, effect: tool.effect)
            guard EmbeddedBrowserSiteToolPolicy.decision(for: metadata) != .reject else {
                throw WebMCPFailure("origin_rejected")
            }
            _ = try WebMCPPageTools.boundedJSON(argumentsJSON, maximumBytes: WebMCPPageTools.maximumPayloadBytes)
            decision = WebMCPInvocationPolicy.decision(effect: tool.effect, preset: caller.preset, readOnlyCaller: caller.readOnly)
            guard decision != .reject else { throw WebMCPFailure("policy_rejected") }
            let key = ConsentKey(caller: caller.id, session: caller.session, tabID: tabID, origin: page.origin)
            let once = tool.effect == .readOnly && decision == .confirm
            func validate() throws {
                try Task.checkCancellation()
                guard contextIsCurrent() else { throw WebMCPFailure("caller_changed") }
                guard revisions[tabID] == revision, invokers[tabID] != nil else { throw WebMCPFailure("stale_page") }
            }
            if decision == .confirm && !(once && readConsent.contains(key)) {
                // Island titles are capped at 14 characters; origin and tool go in the detail line.
                let allowed = await confirm(tool.effect == .readOnly ? "網頁想讀取資料" : "網頁想執行工具",
                    "\(Self.singleLine(page.origin))・\(Self.singleLine(name))・"
                    + (tool.effect == .readOnly ? "允許此對話讀取？" : "可能修改或送出資料，只允許這一次？"))
                try validate()
                guard allowed else { throw WebMCPFailure("user_denied") }
                if once { readConsent.insert(key) }
            }
            try validate()
            let pending = PendingInvocation()
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.continuation = continuation
                    // A bounded waiter also notices Stop, disconnect, tab close and policy changes
                    // when a renderer never replies. There is no retry or replay.
                    pending.watchdog = Task { @MainActor in
                        let deadline = ProcessInfo.processInfo.systemUptime + invocationTimeout
                        while !Task.isCancelled {
                            do {
                                try validate()
                                if ProcessInfo.processInfo.systemUptime >= deadline { throw WebMCPFailure("invocation_timeout") }
                                try await Task.sleep(nanoseconds: 50_000_000)
                            } catch {
                                pending.finish(.failure(error))
                                return
                            }
                        }
                    }
                    invoker(name, argumentsJSON, page.navigationGeneration) { result, error in
                        Task { @MainActor in
                            do {
                                try validate()
                                if let error {
                                    let stale = ["webmcp_navigation_changed", "webmcp_context_released",
                                        "webmcp_navigation_binding_unavailable", "webmcp_browser_closed"].contains(error)
                                    throw WebMCPFailure(stale ? "stale_page" : "execution_failed")
                                }
                                guard let result else { throw WebMCPFailure("result_unavailable") }
                                _ = try WebMCPPageTools.boundedJSON(result,
                                    maximumBytes: WebMCPPageTools.maximumPayloadBytes, objectOnly: false)
                                pending.finish(.success(result))
                            } catch { pending.finish(.failure(error)) }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in pending.finish(.failure(WebMCPFailure("cancelled"))) }
            }
            try validate()
            outcome = "success"; failure = ""
            return result
        } catch {
            failure = (error as? WebMCPFailure)?.code ?? (error is CancellationError ? "cancelled" : "execution_failed")
            throw WebMCPFailure(failure)
        }
    }

    @MainActor private final class PendingInvocation {
        var continuation: CheckedContinuation<String, Error>?
        var watchdog: Task<Void, Never>?
        func finish(_ result: Result<String, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            watchdog?.cancel(); watchdog = nil
            continuation.resume(with: result)
        }
    }

    private static func singleLine(_ value: String) -> String {
        String(value.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(160))
    }

    static func appendAudit(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WebMCPFailure("audit_unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { throw WebMCPFailure("audit_unavailable") }
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WebMCPFailure("audit_unavailable") }
                offset += count
            }
        }
    }
}
