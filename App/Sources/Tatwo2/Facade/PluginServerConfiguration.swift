import Foundation

/// Read the stdio fields needed for a non-executing liveness check. Unsupported TOML
/// remains unknown, never "connected". Preserve original text when removing a table.
struct PluginServerConfiguration {
    static let managedMarker = "# tatwo2-mcp-registry-managed"
    var command: String?
    var args: [String] = []
    var enabled = true
    var path: String?

    init(_ object: [String: Any]) {
        command = object["command"] as? String
        args = object["args"] as? [String] ?? []
        enabled = object["enabled"] as? Bool != false && object["disabled"] as? Bool != true
        path = (object["env"] as? [String: String])?["PATH"]
    }

    static func tableName(_ line: String) -> (name: String, nested: Bool)? {
        let pattern = #"^\s*\[mcp_servers\.(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_-]+))(\.[A-Za-z0-9_-]+)?\]\s*(?:#.*)?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let name = (1...3).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }.first!
        return (name, match.range(at: 4).location != NSNotFound)
    }

    private static func string(_ text: String) -> String? {
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 { return String(text.dropFirst().dropLast()) }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? String
    }

    /// Strip TOML comments only outside strings.
    private static func uncomment(_ text: String) -> String {
        var quote: Character?, escaped = false
        var result = ""
        for c in text {
            if escaped { escaped = false; result.append(c); continue }
            if c == "\\", quote == "\"" { escaped = true; result.append(c); continue }
            if let current = quote {
                if c == current { quote = nil }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "#" { break }
            result.append(c)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTOML(_ text: String) -> [String: PluginServerConfiguration] {
        var objects: [String: [String: Any]] = [:]
        var current: String?, nested = false, environmentTable = false, pendingArgs: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = uncomment(rawLine)
            if line.hasPrefix("[") && pendingArgs == nil {
                let table = tableName(line)
                current = table?.name; nested = table?.nested ?? false
                environmentTable = nested && line.contains(".env]")
                if let current, objects[current] == nil { objects[current] = [:] }
                continue
            }
            guard let current else { continue }
            if nested {
                if environmentTable, let equal = line.firstIndex(of: "="),
                   line[..<equal].trimmingCharacters(in: .whitespaces) == "PATH",
                   let path = string(line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)) {
                    objects[current]?["env"] = ["PATH": path]
                }
                continue
            }
            if let pending = pendingArgs {
                pendingArgs = pending + line
                if line.contains("]") {
                    objects[current]?["args"] = stringArray(pendingArgs!)
                    pendingArgs = nil
                }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key == "command" || key == "url" { objects[current]?[key] = string(value) }
            if key == "enabled" || key == "disabled", ["true", "false"].contains(value) {
                objects[current]?[key] = value == "true"
            }
            if key == "args" {
                if value.contains("]") { objects[current]?[key] = stringArray(value) }
                else { pendingArgs = value }
            }
            if key == "env" {
                let regex = try! NSRegularExpression(pattern: #"(?:\{|,)\s*(?:"PATH"|'PATH'|PATH)\s*=\s*("(?:\\.|[^"\\])*"|'[^']*')"#)
                if let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                   let range = Range(match.range(at: 1), in: value), let path = string(String(value[range])) {
                    objects[current]?["env"] = ["PATH": path]
                }
            }
        }
        return objects.mapValues(Self.init)
    }

    private static func stringArray(_ text: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'[^']*'"#)
        let strings = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return strings.compactMap { Range($0.range, in: text).flatMap { string(String(text[$0])) } }
    }

    enum EditError: LocalizedError {
        case unsupportedMultiline
        var errorDescription: String? { "設定檔含多行字串，無法安全移除；原檔未修改。" }
    }

    static func removingTOMLServer(_ name: String, from text: String) throws -> String {
        // This small reader is not a complete TOML editor. Never mistake a header-like
        // line inside a multiline string for a table boundary and corrupt another server.
        guard !text.contains("\"\"\""), !text.contains("'''") else { throw EditError.unsupportedMultiline }
        var removing = false
        return text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                removing = tableName(line)?.name == name
            }
            return !removing
        }.joined(separator: "\n")
    }
}
