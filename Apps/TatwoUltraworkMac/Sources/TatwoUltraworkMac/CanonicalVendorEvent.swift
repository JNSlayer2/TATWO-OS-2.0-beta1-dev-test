import Foundation

enum CanonicalVendorEvent: Sendable, Equatable {
    case assistantDelta(String)
    case assistantMessage(String)
    case toolCalls
    case turnCompleted
}

enum CanonicalVendorEventAdapterError: Error, Equatable { case invalidEvent }

enum CanonicalVendorEventReadPath {
    static let rollbackEnvironmentKey = "TATWO_USE_LEGACY_VENDOR_EVENT_PARSER"

    static func usesCanonicalAdapter(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[rollbackEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return true }
        return !["1", "true", "yes", "on", "legacy"].contains(raw)
    }
}

enum ChatNativeSubscriptionCanonicalAdapter {
    static func adapt(_ data: Data) throws -> CanonicalVendorEvent? {
        let object = try jsonObject(data)
        switch object["method"] as? String {
        case "item/agentMessage/delta":
            guard let params = object["params"] as? [String: Any], let delta = params["delta"] as? String else { throw CanonicalVendorEventAdapterError.invalidEvent }
            return .assistantDelta(delta)
        case "item/completed":
            guard let params = object["params"] as? [String: Any], let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String else { return nil }
            return .assistantMessage(text)
        case "turn/completed": return .turnCompleted
        default: return nil
        }
    }
}

enum ClaudeRuntimeCanonicalAdapter {
    static func adapt(_ data: Data) throws -> CanonicalVendorEvent? {
        let object = try jsonObject(data)
        switch object["type"] as? String {
        case "assistant_delta":
            guard let text = object["text"] as? String else { throw CanonicalVendorEventAdapterError.invalidEvent }
            return .assistantDelta(text)
        case "result":
            return assistantMessage(in: object)
        case nil:
            return assistantMessage(in: object)
        default:
            return nil
        }
    }

    private static func assistantMessage(in object: [String: Any]) -> CanonicalVendorEvent? {
        guard let output = object["structured_output"] as? [String: Any],
              output["kind"] as? String == "assistant_text",
              let text = output["text"] as? String
        else { return nil }
        return .assistantMessage(text)
    }
}

enum GrokRuntimeCanonicalAdapter {
    static func adapt(_ data: Data) throws -> CanonicalVendorEvent? {
        let object = try jsonObject(data)
        switch object["type"] as? String {
        case "assistant_delta":
            guard let text = object["text"] as? String else { throw CanonicalVendorEventAdapterError.invalidEvent }
            return .assistantDelta(text)
        case "result":
            return try assistantMessage(in: object)
        case nil:
            return try assistantMessage(in: object)
        default:
            return nil
        }
    }

    private static func assistantMessage(in object: [String: Any]) throws -> CanonicalVendorEvent? {
        guard let text = object["text"] as? String,
              let data = text.data(using: .utf8),
              let output = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              output["kind"] as? String == "assistant_text",
              let value = output["text"] as? String
        else { return nil }
        return .assistantMessage(value)
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CanonicalVendorEventAdapterError.invalidEvent }
    return value
}
