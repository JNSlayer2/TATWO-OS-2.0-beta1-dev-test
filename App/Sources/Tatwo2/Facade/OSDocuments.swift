import Foundation

struct OSDocument: Identifiable, Hashable {
    enum Audience: String, CaseIterable, Hashable {
        case user
        case engineering
    }

    let id: String
    let title: String
    let audience: Audience
    let path: String
    let whatItIsFor: String
    let isEditable: Bool
}

enum OSDocuments {
    enum DocumentError: LocalizedError {
        case unknownDocument(String)
        case readOnly(String)
        case missingSource(String)

        var errorDescription: String? {
            switch self {
            case let .unknownDocument(id):
                return "找不到文件：\(id)"
            case let .readOnly(id):
                return "文件不可編輯：\(id)"
            case let .missingSource(path):
                return "找不到可建立文件的來源：\(path)"
            }
        }
    }

    /// 正本依 docs/決策紀錄.md 與 docs/os.md §6：
    /// os.md／todo.md／issue.md／os-upstream.md 以 2.0 專案 docs 為準；
    /// skillet.md 仍以使用者的 OS 根為準。
    static var osRoot: String {
        ProcessInfo.processInfo.environment["TATWO2_OS_ROOT"]
            ?? "\(NSHomeDirectory())/Library/Application Support/tatwo2"
    }

    static var docsRoot: String {
        ProcessInfo.processInfo.environment["TATWO2_DOCS_ROOT"]
            ?? "\(NSHomeDirectory())/Library/Application Support/tatwo2/docs"
    }

    static var skilletPath: String {
        ProcessInfo.processInfo.environment["TATWO2_SKILLET_PATH"]
            ?? URL(fileURLWithPath: osRoot, isDirectory: true)
                .appendingPathComponent("skillet.md").path
    }

    static func list() -> [OSDocument] {
        try? ensureOSUpstreamOverride()
        return [
            OSDocument(
                id: "os",
                title: "os.md",
                audience: .user,
                path: docsURL.appendingPathComponent("os.md").path,
                whatItIsFor: "放 TATWO OS 長期不變的規矩。",
                isEditable: true),
            OSDocument(
                id: "skillet",
                title: "skillet.md",
                audience: .user,
                path: skilletPath,
                whatItIsFor: "放主設備上各家 AI 共用的常用技能說明。",
                isEditable: true),
            OSDocument(
                id: "os-upstream",
                title: "os-upstream.md",
                audience: .user,
                path: OSUpstream.overridePath,
                whatItIsFor: "放每條新對話啟動時交給引擎的一頁規則。",
                isEditable: true),
            OSDocument(
                id: "todo",
                title: "todo.md",
                audience: .engineering,
                path: docsURL.appendingPathComponent("todo.md").path,
                whatItIsFor: "放已經決定、可以直接施工的工作。",
                isEditable: true),
            OSDocument(
                id: "issue",
                title: "issue.md",
                audience: .engineering,
                path: docsURL.appendingPathComponent("issue.md").path,
                whatItIsFor: "放還需要使用者拍板的方向。",
                isEditable: true),
        ]
    }

    static func read(id: String) throws -> String {
        if id == "os-upstream" {
            try ensureOSUpstreamOverride()
        }
        let document = try document(id: id)
        return try String(contentsOfFile: document.path, encoding: .utf8)
    }

    static func write(id: String, text: String) throws {
        let document = try document(id: id)
        guard document.isEditable else { throw DocumentError.readOnly(id) }
        if id == "os-upstream" {
            try ensureOSUpstreamOverride()
        }

        let fileURL = URL(fileURLWithPath: document.path)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: fileURL.path) {
            let backupDirectory = directory.appendingPathComponent(".tatwo2-backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let backupURL = nextBackupURL(for: fileURL, in: backupDirectory)
            try fileManager.copyItem(at: fileURL, to: backupURL)
            try pruneBackups(for: fileURL, in: backupDirectory, keeping: 20)
        }

        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    static func modifiedAt(id: String) -> Date? {
        guard let document = try? document(id: id),
              let attributes = try? fileManager.attributesOfItem(atPath: document.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    static func backupURLs(id: String) -> [URL] {
        guard let document = try? document(id: id) else { return [] }
        let fileURL = URL(fileURLWithPath: document.path)
        let directory = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tatwo2-backups", isDirectory: true)
        return backupURLs(for: fileURL, in: directory)
    }

    private static let fileManager = FileManager.default

    private static var docsURL: URL {
        URL(fileURLWithPath: docsRoot, isDirectory: true)
    }

    private static func document(id: String) throws -> OSDocument {
        guard let document = list().first(where: { $0.id == id }) else {
            throw DocumentError.unknownDocument(id)
        }
        return document
    }

    private static func ensureOSUpstreamOverride() throws {
        let destination = URL(fileURLWithPath: OSUpstream.overridePath)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let bundled = Bundle.module.url(forResource: "os-upstream", withExtension: "md")
            ?? Bundle.main.url(forResource: "os-upstream", withExtension: "md")
        let projectSource = docsURL.appendingPathComponent("os-upstream.md")
        let source = bundled
            ?? (fileManager.fileExists(atPath: projectSource.path) ? projectSource : nil)
        guard let source else {
            throw DocumentError.missingSource(projectSource.path)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func nextBackupURL(for fileURL: URL, in directory: URL) -> URL {
        var timestamp = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        while true {
            let candidate = directory.appendingPathComponent(
                "\(fileURL.lastPathComponent).\(timestamp).md")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            timestamp += 1
        }
    }

    private static func backupURLs(for fileURL: URL, in directory: URL) -> [URL] {
        let prefix = fileURL.lastPathComponent + "."
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "md" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
                return left < right
            }
    }

    private static func pruneBackups(
        for fileURL: URL,
        in directory: URL,
        keeping limit: Int
    ) throws {
        let backups = backupURLs(for: fileURL, in: directory)
        guard backups.count > limit else { return }
        for backup in backups.prefix(backups.count - limit) {
            try fileManager.removeItem(at: backup)
        }
    }
}
