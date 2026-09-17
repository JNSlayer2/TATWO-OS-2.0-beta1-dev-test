import Foundation

/// Installation baseline is immutable. Refuse removal if either the backup or live file changed.
enum ManagedRulesRemoval {
    struct Record: Codable {
        let id: String
        let path: String
        let originalHash: String?
        let installedHash: String
        let backup: String?
    }
    static func manifest(_ entry: TatwoEntry) -> URL {
        entry.root.appendingPathComponent("backups/onboarding/manifest.json")
    }

    private static func isManaged(_ current: Data, record: Record, original: Data?, entry: TatwoEntry) throws -> Bool {
        if RuleGenerator.hash(current) == record.installedHash { return true }
        // W79 may have legitimately regenerated the block since installation. Its latest
        // receipt must vouch for that block, and every non-managed byte must still equal
        // the original baseline. An edited/kept block is not a generated receipt.
        let text = String(decoding: current, as: UTF8.self)
        guard let range = try OSUpstreamBinding.blockRange(text) else { return false }
        let block = String(text[range])
        let receipt = entry.root.appendingPathComponent(".rule-bindings/\(OSUpstreamBinding.digest(record.path)).json")
        guard let bytes = try? Data(contentsOf: receipt),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["blockHash"] as? String == OSUpstreamBinding.digest(block) else { return false }
        let old = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Data((old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + block + "\n").utf8) == current
    }
    static func saveBaseline(_ targets: [OSOnboarding.TargetSnapshot], entry: TatwoEntry) throws {
        let directory = manifest(entry).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var records: [Record] = []
        for (index, item) in targets.enumerated() {
            let old = item.original.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let installed = old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + item.expectedBlock + "\n"
            let backup = item.original == nil ? nil : "\(UUID().uuidString)-\(index).bin"
            if let backup, let original = item.original {
                let url = directory.appendingPathComponent(backup)
                try original.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            records.append(Record(id: item.target.id, path: item.target.path,
                                  originalHash: item.original.map(RuleGenerator.hash),
                                  installedHash: RuleGenerator.hash(Data(installed.utf8)), backup: backup))
        }
        try JSONEncoder().encode(records).write(to: manifest(entry), options: .atomic)
    }

    static func remove(entry: TatwoEntry) throws {
        let file = manifest(entry)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw OSUpstreamBinding.failure("沒有本次接入的安裝前備份紀錄；不猜測或覆寫既有引擎檔案")
        }
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
        var originals: [String: Data] = [:]
        // Validate the entire batch first. User edits never get discarded by a partial removal.
        for record in records {
            if let backup = record.backup {
                guard !backup.contains("/"), let hash = record.originalHash else {
                    throw OSUpstreamBinding.failure("無效備份紀錄")
                }
                let data = try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(backup))
                guard RuleGenerator.hash(data) == hash else { throw OSUpstreamBinding.failure("備份雜湊不符") }
                originals[record.path] = data
            }
            let current = try OSOnboarding.readOptional(URL(fileURLWithPath: record.path))
            let hash = current.map(RuleGenerator.hash)
            let managed = try current.map { try isManaged($0, record: record, original: originals[record.path], entry: entry) } ?? false
            guard hash == record.originalHash || managed else {
                throw OSUpstreamBinding.failure("檔案在安裝後已修改，保留內容；請先人工檢視：" + record.path)
            }
        }
        let env = OSOnboarding.bindingEnvironment(entry: entry, targets: records.map {
            .init(id: $0.id, label: $0.id, path: $0.path)
        })
        for record in records {
            let url = URL(fileURLWithPath: record.path)
            let current = try OSOnboarding.readOptional(url)
            if current.map(RuleGenerator.hash) == record.originalHash { continue }
            guard let current, try isManaged(current, record: record, original: originals[record.path], entry: entry) else {
                throw OSUpstreamBinding.failure("移除期間檔案已變更")
            }
            try OSUpstreamBinding.removeBlock(target: .init(id: record.id, label: record.id, path: record.path),
                                             reviewedText: String(decoding: current, as: UTF8.self), environment: env)
            let restored = try Data(contentsOf: url)
            if let original = originals[record.path] {
                guard RuleGenerator.hash(restored) == RuleGenerator.hash(original) else {
                    throw OSUpstreamBinding.failure("還原後與安裝前備份雜湊不符")
                }
            } else {
                guard restored.isEmpty else { throw OSUpstreamBinding.failure("新增檔案含其他內容，不刪除") }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
