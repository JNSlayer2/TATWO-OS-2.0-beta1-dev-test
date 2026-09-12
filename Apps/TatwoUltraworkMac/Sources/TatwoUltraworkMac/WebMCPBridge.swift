import CryptoKit
import Foundation
import TatwoCEFBridge
import TatwoUltraworkCore

struct TatwoWebMCPToolDescriptor: Equatable, Sendable {
    let tabID: String
    let origin: String
    let navigationGeneration: UInt64
    let pageToolName: String
    let mcpToolName: String
    let description: String
    let inputSchema: JSONValue
    let inputSchemaJSON: String
    let bindingHash: String

    var definition: TatwoMCPToolDefinition {
        TatwoMCPToolDefinition(
            name: mcpToolName,
            plainPurpose: description.isEmpty
                ? "Untrusted page-provided WebMCP tool. Calling it only freezes a plan; execution requires the Tatwo human gate."
                : description,
            returnsSchema: "TatwoBrowserTypedPlanTokenV1",
            hostMutationAllowed: false,
            metadata: [
                "trust": "untrusted_web",
                "origin": origin,
                "navigationGeneration": String(navigationGeneration),
                "pageToolName": pageToolName,
                "inputSchemaJSON": inputSchemaJSON,
                "executionPolicy": "plan_then_execute_human_gate",
            ])
    }
}

struct TatwoWebMCPInvocationOutcome: Equatable, Sendable {
    let value: JSONValue?
    let errorCode: String?
}

private struct TatwoCEFWebMCPToolsSnapshotV1: Decodable {
    struct Tool: Decodable {
        let name: String
        let description: String
        let inputSchemaJSON: String
        let origin: String
        let navigationGeneration: UInt64
    }

    let schema: String
    let origin: String
    let navigationGeneration: UInt64
    let tools: [Tool]
}

private struct TatwoWebMCPBindingHashPayload: Encodable {
    let tabID: String
    let origin: String
    let navigationGeneration: UInt64
    let pageToolName: String
    let mcpToolName: String
    let description: String
    let inputSchema: JSONValue
}

enum TatwoWebMCPMetadataSanitizer {
    static func sanitizeSchema(_ value: JSONValue) -> JSONValue? {
        switch value {
        case let .string(raw):
            return .string(TatwoBrowserUnicodeSanitizer.sanitize(raw).text)
        case let .array(values):
            var sanitized: [JSONValue] = []
            sanitized.reserveCapacity(values.count)
            for value in values {
                guard let safe = sanitizeSchema(value) else { return nil }
                sanitized.append(safe)
            }
            return .array(sanitized)
        case let .object(object):
            var sanitized: [String: JSONValue] = [:]
            for (rawKey, rawValue) in object {
                let key = TatwoBrowserUnicodeSanitizer.sanitize(rawKey).text
                guard !key.isEmpty,
                      sanitized[key] == nil,
                      let value = sanitizeSchema(rawValue)
                else {
                    return nil
                }
                sanitized[key] = value
            }
            return .object(sanitized)
        case .number, .bool, .null:
            return value
        }
    }

    static func toolSuffix(_ raw: String) -> String? {
        let normalized = TatwoBrowserUnicodeSanitizer.sanitize(raw)
            .text.lowercased()
        var result = ""
        var lastWasSeparator = false
        for scalar in normalized.unicodeScalars {
            let allowed =
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "_" || scalar == "-"
            if allowed {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator && !result.isEmpty {
                result.append("_")
                lastWasSeparator = true
            }
            if result.utf8.count >= 64 { break }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return result.isEmpty ? nil : result
    }
}

final class TatwoWebMCPRuntime: @unchecked Sendable {
    typealias MainActorInvoker = @MainActor (
        _ pageToolName: String,
        _ argumentsJSON: String,
        _ navigationGeneration: UInt64,
        _ completion: @escaping (String?, String?) -> Void
    ) -> Void

    static let shared = TatwoWebMCPRuntime()
    private static let dynamicRegistrySource = "tatwo.webmcp"

    private struct TabState {
        var origin = ""
        var navigationGeneration: UInt64 = 0
        var tools: [String: TatwoWebMCPToolDescriptor] = [:]
        var invoker: MainActorInvoker?
    }

    private let lock = NSLock()
    private var tabs: [String: TabState] = [:]
    private var selectedTabID: String?

    private init() {}

    func attach(tabID: String, invoker: @escaping MainActorInvoker) {
        guard !tabID.isEmpty else { return }
        lock.lock()
        var state = tabs[tabID] ?? TabState()
        state.invoker = invoker
        tabs[tabID] = state
        publishDynamicToolsLocked()
        lock.unlock()
    }

    func activate(tabID: String) {
        guard !tabID.isEmpty else { return }
        lock.lock()
        selectedTabID = tabID
        if tabs[tabID] == nil {
            tabs[tabID] = TabState()
        }
        publishDynamicToolsLocked()
        lock.unlock()
    }

    func detach(tabID: String) {
        lock.lock()
        tabs.removeValue(forKey: tabID)
        if selectedTabID == tabID {
            selectedTabID = nil
        }
        publishDynamicToolsLocked()
        lock.unlock()
    }

    func invalidate(tabID: String) {
        lock.lock()
        guard var state = tabs[tabID] else {
            lock.unlock()
            return
        }
        state.origin = ""
        state.navigationGeneration = 0
        state.tools.removeAll()
        tabs[tabID] = state
        publishDynamicToolsLocked()
        lock.unlock()
    }

    @discardableResult
    func update(
        tabID: String,
        snapshotJSONString: String
    ) -> [TatwoWebMCPToolDescriptor] {
        guard let data = snapshotJSONString.data(using: .utf8),
              data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(
                  TatwoCEFWebMCPToolsSnapshotV1.self,
                  from: data),
              snapshot.schema == "TatwoCEFWebMCPToolsSnapshotV1",
              snapshot.navigationGeneration > 0,
              let originURL = URL(string: snapshot.origin),
              EmbeddedBrowserNavigationPolicy.allows(originURL)
        else {
            invalidate(tabID: tabID)
            return []
        }

        let originHash = Self.sha256Hex(snapshot.origin).prefix(16)
        var tools: [String: TatwoWebMCPToolDescriptor] = [:]
        for candidate in snapshot.tools.prefix(128) {
            guard candidate.origin == snapshot.origin,
                  candidate.navigationGeneration
                    == snapshot.navigationGeneration,
                  let suffix = TatwoWebMCPMetadataSanitizer.toolSuffix(
                      candidate.name),
                  let schemaData = candidate.inputSchemaJSON.data(
                      using: .utf8),
                  schemaData.count <= 65_536,
                  let rawSchema = try? JSONDecoder().decode(
                      JSONValue.self,
                      from: schemaData),
                  case .object = rawSchema,
                  let safeSchema =
                    TatwoWebMCPMetadataSanitizer.sanitizeSchema(rawSchema),
                  let safeSchemaData = try? Self.canonicalData(safeSchema),
                  let safeSchemaJSON = String(
                      data: safeSchemaData,
                      encoding: .utf8)
            else {
                continue
            }
            let description = TatwoBrowserUnicodeSanitizer
                .sanitize(candidate.description).text
            var mcpName = "tatwo.webmcp.\(originHash).\(suffix)"
            if tools[mcpName] != nil {
                let collision = Self.sha256Hex(candidate.name).prefix(8)
                mcpName += "_\(collision)"
            }
            let payload = TatwoWebMCPBindingHashPayload(
                tabID: tabID,
                origin: snapshot.origin,
                navigationGeneration: snapshot.navigationGeneration,
                pageToolName: candidate.name,
                mcpToolName: mcpName,
                description: description,
                inputSchema: safeSchema)
            guard let bindingHash =
                    try? TatwoBrowserCanonicalJSON.sha256(payload)
            else {
                continue
            }
            tools[mcpName] = TatwoWebMCPToolDescriptor(
                tabID: tabID,
                origin: snapshot.origin,
                navigationGeneration: snapshot.navigationGeneration,
                pageToolName: candidate.name,
                mcpToolName: mcpName,
                description: description,
                inputSchema: safeSchema,
                inputSchemaJSON: safeSchemaJSON,
                bindingHash: bindingHash)
        }

        lock.lock()
        var state = tabs[tabID] ?? TabState()
        state.origin = snapshot.origin
        state.navigationGeneration = snapshot.navigationGeneration
        state.tools = tools
        tabs[tabID] = state
        publishDynamicToolsLocked()
        let result = tools.values.sorted {
            $0.mcpToolName < $1.mcpToolName
        }
        lock.unlock()
        return result
    }

    func descriptor(named mcpToolName: String)
        -> TatwoWebMCPToolDescriptor?
    {
        lock.lock()
        defer { lock.unlock() }
        guard let selectedTabID else { return nil }
        return tabs[selectedTabID]?.tools[mcpToolName]
    }

    func canonicalArgumentsJSON(
        from arguments: [String: JSONValue]
    ) throws -> String {
        let reserved: Set<String> = [
            "grant", "contractID", "runID", "leaseID", "sessionID",
            "workspaceRoot", "approvedPlanToken",
        ]
        let pageArguments = arguments.filter {
            !reserved.contains($0.key)
        }
        let data = try Self.canonicalData(JSONValue.object(pageArguments))
        guard data.count <= 1_048_576,
              let json = String(data: data, encoding: .utf8)
        else {
            throw TatwoBrowserSecurityError.invalidPlan
        }
        return json
    }

    func invoke(
        descriptor: TatwoWebMCPToolDescriptor,
        argumentsJSON: String,
        timeout: TimeInterval = 35
    ) -> TatwoWebMCPInvocationOutcome {
        guard !Thread.isMainThread else {
            return .init(
                value: nil,
                errorCode: "webmcp_main_thread_call_forbidden")
        }
        lock.lock()
        let state = tabs[descriptor.tabID]
        let current = state?.tools[descriptor.mcpToolName]
        let invoker = state?.invoker
        lock.unlock()
        guard current == descriptor, let invoker else {
            return .init(
                value: nil,
                errorCode: "webmcp_navigation_binding_unavailable")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        nonisolated(unsafe) var result: TatwoWebMCPInvocationOutcome?
        DispatchQueue.main.async {
            invoker(
                descriptor.pageToolName,
                argumentsJSON,
                descriptor.navigationGeneration
            ) { resultJSON, errorCode in
                let resolved: TatwoWebMCPInvocationOutcome
                if let errorCode {
                    resolved = .init(value: nil, errorCode: errorCode)
                } else if let resultJSON,
                          let data = resultJSON.data(using: .utf8),
                          let value = try? JSONDecoder().decode(
                              JSONValue.self,
                              from: data)
                {
                    resolved = .init(value: value, errorCode: nil)
                } else {
                    resolved = .init(
                        value: nil,
                        errorCode: "webmcp_result_invalid")
                }
                resultLock.lock()
                result = resolved
                resultLock.unlock()
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return .init(
                value: nil,
                errorCode: "webmcp_invocation_timed_out")
        }
        resultLock.lock()
        let resolved = result
        resultLock.unlock()
        return resolved ?? .init(
            value: nil,
            errorCode: "webmcp_result_invalid")
    }

    func resetForTesting() {
        lock.lock()
        tabs.removeAll()
        selectedTabID = nil
        publishDynamicToolsLocked()
        lock.unlock()
    }

    private func publishDynamicToolsLocked() {
        let definitions = selectedTabID
            .flatMap { tabs[$0] }?
            .tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
            ?? []
        TatwoMCPDynamicToolRegistry.shared.replace(
            source: Self.dynamicRegistrySource,
            tools: definitions)
    }

    private static func canonicalData(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
