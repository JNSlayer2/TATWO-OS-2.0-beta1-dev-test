import Foundation
import CryptoKit

struct OSBindingPreview: Equatable {
    struct Item: Identifiable, Equatable {
        enum State: String { case bound, stale, unbound, unreadable, edited = "已手改" }
        let target: UpstreamBindingTarget
        var id: String { target.id }
        var path: String { target.path }
        let state: State
        let currentBlockHash: String?
        let expectedHash: String
        let diff: String
        let error: String?
        let original: String?
    }
    let root: String
    let items: [Item]
    let upstream: String
    let constitutionMissing: Bool
    let seed: Bool
    let error: String?
    var notices: [String] {
        (constitutionMissing ? ["入口缺憲法，請先由主設備派發"] : []) +
        (seed ? ["入口尚無 os-upstream.md：確認後只種入內建上游規則；不封存、不覆寫、不種入 os.md。"] : [])
    }
    var paths: [String] {
        (seed ? [root + "/os-upstream.md"] : []) +
        items.filter { $0.state != .bound }.map(\.path)
    }
}

struct OSBindingWriteReport {
    var modified: [String] = []
    var backups: [String] = []
    var failure: String?
    var text: String {
        let status = failure.map { "已停止：" + $0 } ?? "讀回 hash 驗證完成"
        return "已寫入：\n\(modified.joined(separator: "\n"))\n備份：\n\(backups.joined(separator: "\n"))\n\(status)"
    }
}

extension OSUpstreamBinding {
    private static let writeLock = NSLock()
    static let byteLimit = 1_048_576
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func readText(_ path: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o444 != 0 else {
            throw failure("不是可讀的一般檔案：" + path)
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit, String(data: data, encoding: .utf8) != nil else {
            throw failure("超過 1 MiB 或不是 UTF-8：" + path)
        }
        // Foundation's encoding initializer strips a UTF-8 BOM. Preserve every
        // original byte for source hashes, non-managed content and removal.
        return String(decoding: data, as: UTF8.self)
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "OSBinding", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func bundled(_ name: String) throws -> String {
        guard let url = TatwoResources.url(forResource: name, withExtension: "md") else {
            throw failure("缺少內建資源：" + name)
        }
        let text = try readText(url.path)
        guard !text.isEmpty else { throw failure("內建資源是空檔") }
        return text
    }
    static func blockRange(_ text: String) throws -> Range<String.Index>? {
        let begins = text.components(separatedBy: beginMarker).count - 1
        let ends = text.components(separatedBy: endMarker).count - 1
        guard begins != 0 || ends != 0 else { return nil }
        guard begins == 1, ends == 1, let b = text.range(of: beginMarker),
              let e = text.range(of: endMarker), b.upperBound <= e.lowerBound else {
            throw failure("V2 區塊標記不完整或重複；拒絕猜測替換範圍")
        }
        return b.lowerBound..<e.upperBound
    }
    static func preview(environment: [String: String] = ProcessInfo.processInfo.environment) -> OSBindingPreview {
        let root = osRoot(environment: environment)
        let fm = FileManager.default
        let seed = runtimeSource == nil && !fm.fileExists(atPath: root + "/os-upstream.md")
        // The constitution is dispatched by the primary device, never by this seed path.
        let constitutionMissing = !fm.fileExists(atPath: root + "/os.md")
        var upstream = "", issue: String?
        do {
            if let runtimeSource { upstream = try runtimeSource(environment) }
            else { upstream = try seed ? bundled("os-upstream") : readText(root + "/os-upstream.md") }
            guard !upstream.isEmpty else { throw failure("上游宣告不可為空") }
        } catch { issue = error.localizedDescription }
        let items = targets(environment: environment).map { target -> OSBindingPreview.Item in
            var expected = block(root: root, hash: String(digest(upstream).prefix(12)))
            do {
                if let issue { throw failure(issue) }
                if let translatedBlock { expected = try translatedBlock(target, environment, String(digest(upstream).prefix(12))) }
                let exists = fm.fileExists(atPath: target.path)
                let parent = (target.path as NSString).deletingLastPathComponent
                var directory: ObjCBool = false
                guard fm.fileExists(atPath: parent, isDirectory: &directory), directory.boolValue else { throw failure("目標資料夾不存在") }
                let text = exists ? try readText(target.path) : ""
                let range = try blockRange(text)
                let current = range.map { String(text[$0]) }
                let installed = receipt(target.path, root: root)?.blockHash
                let edited = current != nil ? installed != current.map(digest) : installed?.isEmpty == false
                let state: OSBindingPreview.Item.State = edited && translatedBlock != nil ? .edited :
                    current == nil ? .unbound :
                    current.map(digest) == digest(expected) ? .bound : .stale
                let diff = state == .bound ? "" : (current.map { $0.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n") + "\n" } ?? "") + expected.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
                return .init(target: target, state: state, currentBlockHash: current.map(digest), expectedHash: digest(expected), diff: diff, error: nil, original: exists ? text : nil)
            } catch {
                return .init(target: target, state: .unreadable, currentBlockHash: nil, expectedHash: digest(expected), diff: "", error: error.localizedDescription, original: nil)
            }
        }
        return .init(root: root, items: items, upstream: upstream, constitutionMissing: constitutionMissing, seed: seed, error: issue)
    }

    // Called only with the exact preview approved by the user. Recheck bytes before each write.
    static func apply(_ plan: OSBindingPreview, environment: [String: String] = ProcessInfo.processInfo.environment) -> OSBindingWriteReport {
        var report = OSBindingWriteReport()
        guard writeLock.try() else {
            report.failure = "已有綁定寫入進行中；請完成後重新預覽"
            return report
        }
        defer { writeLock.unlock() }
        let fm = FileManager.default
        var active = plan.root
        let batch = plan.root + "/backups/bindings/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString
        func backup(_ path: String, old: String, index: Int) throws {
                let attrs = try fm.attributesOfItem(atPath: path)
                guard ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0,
                      fm.isWritableFile(atPath: path) else { throw failure("唯讀檔：" + path) }
                // Index subdirectory prevents CLAUDE.md / AGENTS.md basename collisions.
                let folder = batch + "/\(index)"
                try fm.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let backup = folder + "/" + (path as NSString).lastPathComponent
                try Data(old.utf8).write(to: URL(fileURLWithPath: backup), options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
                report.backups.append(backup)
                guard try digest(readText(path)) == digest(old) else { throw failure("備份期間內容已改變：" + path) }
        }
        func write(_ path: String, old: String?, new: String, index: Int) throws {
            active = path
            let current = fm.fileExists(atPath: path) ? try readText(path) : nil
            guard current.map(digest) == old.map(digest) else { throw failure("預覽後內容已改變，請重新預覽：" + path) }
            if let old { try backup(path, old: old, index: index) }
            guard new.utf8.count <= byteLimit else { throw failure("寫入結果超過 1 MiB") }
            try Data(new.utf8).write(to: URL(fileURLWithPath: path), options: old == nil ? .withoutOverwriting : .atomic)
            if !report.modified.contains(path) { report.modified.append(path) }
            guard try digest(readText(path)) == digest(new) else { throw failure("讀回 hash 不一致：" + path) }
        }
        do {
            let fresh = preview(environment: environment)
            guard fresh == plan,
                  digest(fresh.upstream) == digest(plan.upstream),
                  zip(fresh.items, plan.items).allSatisfy({ $0.original.map(digest) == $1.original.map(digest) }) else {
                throw failure("預覽已過期，請重新預覽")
            }
            if let error = plan.error { throw failure(error) }
            if plan.seed {
                try fm.createDirectory(atPath: plan.root, withIntermediateDirectories: true)
                try write(plan.root + "/os-upstream.md", old: nil, new: plan.upstream, index: -1)
            }
            for (index, item) in plan.items.enumerated() where item.state != .bound {
                active = item.path
                if item.state == .unreadable { throw failure(item.error ?? "讀不到") }
                let expected = try translatedBlock?(item.target, environment, String(digest(plan.upstream).prefix(12)))
                    ?? block(root: plan.root, hash: String(digest(plan.upstream).prefix(12)))
                var text = item.original ?? ""
                var record = receipt(item.path, root: plan.root)
                    ?? Receipt(blockHash: digest(expected), prefix: "", suffix: "", kept: nil)
                if let range = try blockRange(text) { text.replaceSubrange(range, with: expected) }
                else {
                    record.prefix = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
                    record.suffix = "\n"
                    text += record.prefix + expected + record.suffix
                }
                try write(item.path, old: item.original, new: text, index: index)
                let readback = try readText(item.path)
                guard let range = try blockRange(readback), digest(String(readback[range])) == item.expectedHash else {
                    throw failure("區塊 hash 不一致")
                }
                record.blockHash = digest(expected)
                record.kept = nil
                try saveReceipt(record, path: item.path, root: plan.root)
            }
        } catch { report.failure = active + "：" + error.localizedDescription }
        return report
    }

    private struct Receipt: Codable {
        var blockHash: String
        var prefix: String
        var suffix: String
        var kept: String?
    }
    private static func receiptURL(_ path: String, root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(".rule-bindings/\(digest(path)).json")
    }
    private static func receipt(_ path: String, root: String) -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL(path, root: root)) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }
    private static func saveReceipt(_ value: Receipt, path: String, root: String) throws {
        let url = receiptURL(path, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func keep(_ plan: OSBindingPreview, environment: [String: String]) throws {
        try writeLock.withLock {
            guard preview(environment: environment) == plan else { throw failure("預覽已過期，請重新預覽") }
            for item in plan.items where item.state == .edited {
                var record = receipt(item.path, root: plan.root)
                    ?? Receipt(blockHash: "", prefix: "", suffix: "", kept: nil)
                record.kept = (item.currentBlockHash ?? "") + "\n" + item.expectedHash
                try saveReceipt(record, path: item.path, root: plan.root)
            }
        }
    }

    /// Explicitly reviewed removal preserves all non-managed bytes, including original EOF style.
    static func removeBlock(target: UpstreamBindingTarget, reviewedText: String,
                            environment: [String: String]) throws {
        try writeLock.withLock {
            let root = osRoot(environment: environment)
            guard try digest(readText(target.path)) == digest(reviewedText),
                  let range = try blockRange(reviewedText) else { throw failure("預覽已過期，請重新預覽") }
            var before = String(reviewedText[..<range.lowerBound])
            var after = String(reviewedText[range.upperBound...])
            if let record = receipt(target.path, root: root) {
                if !record.prefix.isEmpty && before.hasSuffix(record.prefix) { before.removeLast(record.prefix.count) }
                if !record.suffix.isEmpty && after.hasPrefix(record.suffix) { after.removeFirst(record.suffix.count) }
            }
            let backup = URL(fileURLWithPath: root).appendingPathComponent("backups/bindings/remove-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(reviewedText.utf8).write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            guard try digest(readText(target.path)) == digest(reviewedText) else { throw failure("備份期間內容已改變") }
            try Data((before + after).utf8).write(to: URL(fileURLWithPath: target.path), options: .atomic)
            guard try digest(readText(target.path)) == digest(before + after) else { throw failure("讀回不一致") }
            // An explicitly removed block is unbound, unlike an externally deleted one.
            try saveReceipt(Receipt(blockHash: "", prefix: "", suffix: "", kept: nil), path: target.path, root: root)
        }
    }
}
