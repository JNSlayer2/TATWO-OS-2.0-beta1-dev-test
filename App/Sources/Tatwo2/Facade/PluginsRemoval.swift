import Foundation

extension PluginsSource {
    enum RemovalError: LocalizedError {
        case unsupported, changed, unsafeSource
        var errorDescription: String? {
            switch self {
            case .unsupported: "這筆登記不是可移除的設定檔項目；請到其來源管理。"
            case .changed: "設定檔已變動，請重新探活後再試。"
            case .unsafeSource: "設定檔不是可安全備份的一般檔案，未修改。"
            }
        }
    }

    /// Invoked only through onRemove after Island confirmation. Removes the definition,
    /// not the executable/data; saves the entire original beside each config as a private .bak.
    static func removeRegistration(id: String,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) throws -> PluginRegistryEntry {
        guard NativeStagingIsolation.validationError(environment) == nil, !isExport(environment),
              let engine = mcpEngine(from: id), let name = mcpName(from: id),
              let entry = scanNow(environment: environment).first(where: { $0.id == id }) else { throw RemovalError.unsupported }
        let manager = FileManager.default
        let urls = configurationURLs(engine: engine, environment: environment)
        var seen = Set<String>()
        var changes: [(url: URL, original: Data, next: Data)] = []
        for url in urls where seen.insert(url.path).inserted && manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw RemovalError.unsafeSource }
            let original = try Data(contentsOf: url)
            let next: Data
            if engine == .claude {
                guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                      var servers = root["mcpServers"] as? [String: Any],
                      servers.removeValue(forKey: name) != nil else { continue }
                root["mcpServers"] = servers
                next = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            } else {
                let text = String(decoding: original, as: UTF8.self)
                guard PluginServerConfiguration.parseTOML(text)[name] != nil else { continue }
                var updated = try PluginServerConfiguration.removingTOMLServer(name, from: text)
                if engine == .codex && !updated.contains(PluginServerConfiguration.managedMarker) {
                    // Removing the last isolated table must not re-import a separate host config.
                    updated = PluginServerConfiguration.managedMarker + "\n" + updated
                }
                next = Data(updated.utf8)
            }
            changes.append((url, original, next))
        }
        guard !changes.isEmpty else { throw RemovalError.unsupported }
        // All backups precede any mutation. No direct file deletion, no engine restart.
        for change in changes {
            let backup = change.url.appendingPathExtension("w62-\(UUID().uuidString).bak")
            guard manager.createFile(atPath: backup.path, contents: change.original,
                                     attributes: [.posixPermissions: 0o600]) else { throw RemovalError.unsafeSource }
        }
        for change in changes {
            guard try Data(contentsOf: change.url) == change.original else { throw RemovalError.changed }
        }
        for change in changes {
            try change.next.write(to: change.url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: change.url.path)
        }
        invalidateLivenessAfterRemoval(environment: environment)
        return entry
    }
}
