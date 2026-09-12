import Foundation

/// WORK_OS.md「Issue List / 支線等待佇列」資料物件：
/// 全域持久佇列，收留 Plan/chat 支線討論；queued 直到使用者明確 activate。
/// 非 authority source；移除只刪佇列項，絕不動來源 plan/chat/session。
public enum TatwoIssueSourceTypeV1: String, Codable, Sendable {
    case plan
    case chat
}

public enum TatwoIssueEntryStatusV1: String, Codable, Sendable {
    case queued
    case activated
    /// 隨 thread 封存（使用者在封存詢問時選「是」）；仍可在設定/issue list/封存 issue 管理。
    case archived
}

public struct TatwoIssueListEntryV1: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var body: String
    /// Image asset filenames stored in TatwoImageAssetStore. Never persist a
    /// Finder source path here, so moving or deleting the original image does
    /// not break an issue note.
    public var imageAssetPaths: [String]
    public let sourceType: TatwoIssueSourceTypeV1
    public let sourceReference: String
    public let threadReference: String?
    /// 所屬專案（同專案 threads 之間 issue 可流通；nil＝獨立 thread，只留原串）。
    public var projectReference: String?
    public var status: TatwoIssueEntryStatusV1
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        imageAssetPaths: [String] = [],
        sourceType: TatwoIssueSourceTypeV1,
        sourceReference: String,
        threadReference: String? = nil,
        projectReference: String? = nil,
        status: TatwoIssueEntryStatusV1 = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.imageAssetPaths = Self.validImageAssetPaths(imageAssetPaths)
        self.sourceType = sourceType
        self.sourceReference = sourceReference
        self.threadReference = threadReference
        self.projectReference = projectReference
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case imageAssetPaths
        case sourceType
        case sourceReference
        case threadReference
        case projectReference
        case status
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        imageAssetPaths = Self.validImageAssetPaths(
            try values.decodeIfPresent([String].self, forKey: .imageAssetPaths) ?? [])
        sourceType = try values.decode(TatwoIssueSourceTypeV1.self, forKey: .sourceType)
        sourceReference = try values.decode(String.self, forKey: .sourceReference)
        threadReference = try values.decodeIfPresent(String.self, forKey: .threadReference)
        projectReference = try values.decodeIfPresent(String.self, forKey: .projectReference)
        status = try values.decode(TatwoIssueEntryStatusV1.self, forKey: .status)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(body, forKey: .body)
        try values.encode(imageAssetPaths, forKey: .imageAssetPaths)
        try values.encode(sourceType, forKey: .sourceType)
        try values.encode(sourceReference, forKey: .sourceReference)
        try values.encodeIfPresent(threadReference, forKey: .threadReference)
        try values.encodeIfPresent(projectReference, forKey: .projectReference)
        try values.encode(status, forKey: .status)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    static func validImageAssetPaths(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !value.hasPrefix("/"),
                  !value.split(separator: "/").contains(".."),
                  seen.insert(value).inserted
            else { return nil }
            return value
        }
    }
}

/// 持久化：app-support/issue-list.json；原子寫入、讀取 fail-soft。
public final class TatwoIssueListStore {
    private let fileURL: URL

    public init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent("issue-list.json")
    }

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(rootURL: TatwoRuntimeLayout.applicationSupportRoot(environment: environment))
    }

    public func load() -> [TatwoIssueListEntryV1] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TatwoIssueListEntryV1].self, from: data)) ?? []
    }

    @discardableResult
    public func capture(
        title: String,
        body: String,
        sourceType: TatwoIssueSourceTypeV1,
        sourceReference: String,
        threadReference: String? = nil,
        projectReference: String? = nil,
        now: Date = Date()
    ) -> TatwoIssueListEntryV1 {
        let entry = TatwoIssueListEntryV1(
            title: title,
            body: body,
            sourceType: sourceType,
            sourceReference: sourceReference,
            threadReference: threadReference,
            projectReference: projectReference,
            createdAt: now,
            updatedAt: now)
        save(load() + [entry])
        return entry
    }

    /// 只移除佇列項；來源 plan/chat/session 一概不動（規格鐵律）。
    public func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    /// 事後補寫/修訂內文（App 是 read/write user queue；不touch來源）。
    public func updateBody(id: String, body: String, now: Date = Date()) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].body = body
        entries[index].updatedAt = now
        save(entries)
    }

    /// Issue 圖片只接受 Tatwo 附件庫內的相對檔名，避免把使用者電腦的
    /// 原始 Finder 路徑帶進長期 issue JSON。
    public func updateImageAssetPaths(
        id: String,
        imageAssetPaths: [String],
        now: Date = Date()
    ) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].imageAssetPaths = TatwoIssueListEntryV1.validImageAssetPaths(imageAssetPaths)
        entries[index].updatedAt = now
        save(entries)
    }

    /// 明確啟用：僅改佇列項狀態；contract/receipt 路徑由呼叫端走正規 Work OS 流程。
    public func markActivated(id: String, now: Date = Date()) {
        setStatus(id: id, status: .activated, now: now)
    }

    public func setStatus(id: String, status: TatwoIssueEntryStatusV1, now: Date = Date()) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].updatedAt = now
        save(entries)
    }

    /// thread 封存時選「是」：把該 thread 的等待中 issue 一起標為 archived（不刪，可日後管理）。
    public func archiveIssues(threadReference: String, now: Date = Date()) {
        var entries = load()
        var changed = false
        for index in entries.indices where
            entries[index].threadReference == threadReference
            && entries[index].status == .queued {
            entries[index].status = .archived
            entries[index].updatedAt = now
            changed = true
        }
        if changed { save(entries) }
    }

    public func countQueued(threadReference: String) -> Int {
        load().filter { $0.threadReference == threadReference && $0.status == .queued }.count
    }

    private func save(_ entries: [TatwoIssueListEntryV1]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".issue-list-\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard (try? data.write(to: temp)) != nil else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } else {
            _ = try? FileManager.default.moveItem(at: temp, to: fileURL)
        }
    }
}
