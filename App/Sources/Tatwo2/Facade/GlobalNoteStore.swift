import Foundation

/// File operations run exclusively on a serial utility queue. Paths are relative, one folder deep;
/// symlinks inside the library are rejected. No live root is touched until the panel is opened.
final class GlobalNoteStore {
    struct Entry: Identifiable, Equatable {
        let path: String
        let isFolder: Bool
        var id: String { path }
    }
    struct Hit: Identifiable {
        let path: String
        let line: Int
        let snippet: String
        var id: String { "\(path):\(line)" }
    }
    enum Failure: LocalizedError {
        case invalidPath, readOnly, conflict, corrupt
        var errorDescription: String? {
            switch self {
            case .invalidPath: return "無效路徑或符號連結"
            case .readOnly: return "筆記唯讀，未覆蓋原檔"
            case .conflict: return "檔案已變更或目標已存在，未覆蓋"
            case .corrupt: return "檔案不是有效 UTF-8，未覆蓋"
            }
        }
    }
    // Panels may create separate stores for the same library. Serialize their
    // compare-and-save operations together, not just each instance's calls.
    private static let queue = DispatchQueue(label: "tatwo2.global-note.io", qos: .utility)
    private let fm = FileManager.default
    private let entrance: URL
    private var root: URL { entrance.appendingPathComponent("note", isDirectory: true) }
    private var fallback = false
    init(root: String = OSUpstreamBinding.osRoot()) { entrance = URL(fileURLWithPath: root).standardizedFileURL }

    func perform<T>(_ operation: @escaping (GlobalNoteStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try operation(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func regular(_ url: URL, directory: Bool = false) throws {
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular) else { throw Failure.invalidPath }
    }
    private func writable(_ url: URL) throws {
        let a = try fm.attributesOfItem(atPath: url.path)
        guard ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0,
              fm.isWritableFile(atPath: url.path) else { throw Failure.readOnly }
    }
    private func url(_ path: String, folder: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= (folder ? 1 : 2),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") }),
              folder || ["md", "txt"].contains((path as NSString).pathExtension.lowercased()) else { throw Failure.invalidPath }
        try regular(root, directory: true)
        var result = root
        for (index, part) in parts.enumerated() {
            result.appendPathComponent(String(part))
            if exists(result) { try regular(result, directory: index < parts.count - 1 || folder) }
        }
        return result
    }
    func prepare() throws {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        try regular(entrance, directory: true)
        let old = entrance.appendingPathComponent("note.md")
        do {
            if !exists(root) { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
            try regular(root, directory: true)
            let destination = root.appendingPathComponent("note.md")
            if exists(old), (try fm.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType) != .typeSymbolicLink {
                try regular(old)
                guard !exists(destination) else { throw Failure.conflict }
                _ = try readUTF8(old)
                try fm.moveItem(at: old, to: destination)
                do { try fm.createSymbolicLink(atPath: old.path, withDestinationPath: "note/note.md") }
                catch { try fm.moveItem(at: destination, to: old); throw error }
            } else if exists(old) {
                guard old.resolvingSymlinksInPath() == destination.standardizedFileURL else { throw Failure.invalidPath }
            }
            if !exists(destination) { try writeNew(destination) }
            fallback = false
        } catch {
            // Migration failure never authorizes writing the old source.
            if exists(old), (try? regular(old)) != nil, (try? readUTF8(old)) != nil { fallback = true; return }
            throw error
        }
    }
    func list() throws -> [Entry] {
        if fallback { return [Entry(path: "note.md", isFolder: false)] }
        try regular(root, directory: true)
        var entries: [Entry] = []
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let type = try fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                entries.append(Entry(path: item.lastPathComponent, isFolder: true))
                for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let path = item.lastPathComponent + "/" + child.lastPathComponent
                    if (try? url(path)) != nil { entries.append(Entry(path: path, isFolder: false)) }
                }
            } else if (try? url(item.lastPathComponent)) != nil {
                entries.append(Entry(path: item.lastPathComponent, isFolder: false))
            }
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    private func readUTF8(_ file: URL) throws -> String {
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw Failure.corrupt }
        return text
    }
    func read(_ path: String) throws -> String {
        if fallback {
            guard path == "note.md" else { throw Failure.readOnly }
            let file = entrance.appendingPathComponent(path)
            try regular(file)
            return try readUTF8(file)
        }
        return try readUTF8(url(path))
    }
    func save(_ path: String, text: String, expected: String) throws {
        guard !fallback else { throw Failure.readOnly }
        let file = try url(path)
        try writable(file); try writable(file.deletingLastPathComponent())
        guard try readUTF8(file) == expected else { throw Failure.conflict }
        let backup = root.appendingPathComponent(".backup")
        if exists(backup) { try regular(backup, directory: true) }
        else { try fm.createDirectory(at: backup, withIntermediateDirectories: false) }
        // Same pre-save copy + microsecond timestamp rule as OSDocuments; retain all backups
        // rather than inheriting its permanent-prune behavior (room forbids permanent deletion).
        let name = path.replacingOccurrences(of: "/", with: "_")
        try fm.copyItem(at: file, to: backup.appendingPathComponent("\(name).\(Int64(Date().timeIntervalSince1970 * 1_000_000)).\(UUID().uuidString).md"))
        try Data(text.utf8).write(to: file, options: .atomic)
    }
    private func writeNew(_ destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".create-" + UUID().uuidString)
        try Data().write(to: staging, options: .atomic)
        try fm.moveItem(at: staging, to: destination) // atomic rename, refuses existing destination
    }
    func create(_ path: String, folder: Bool) throws {
        guard !fallback else { throw Failure.readOnly }
        let destination = try url(path, folder: folder)
        guard !exists(destination) else { throw Failure.conflict }
        try writable(destination.deletingLastPathComponent())
        if folder { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
        else { try writeNew(destination) }
    }
    func move(_ path: String, to target: String, folder: Bool) throws {
        guard !fallback else { throw Failure.readOnly }
        // Keep the entry symlink valid; the canonical note cannot be renamed or trashed.
        guard path != "note.md" else { throw Failure.readOnly }
        let source = try url(path, folder: folder), destination = try url(target, folder: folder)
        guard !exists(destination) else { throw Failure.conflict }
        try fm.moveItem(at: source, to: destination)
    }
    func trash(_ path: String, folder: Bool) throws {
        guard !fallback, path != "note.md" else { throw Failure.readOnly }
        let source = try url(path, folder: folder)
        let trashRoot = root.appendingPathComponent(".trash")
        if exists(trashRoot) { try regular(trashRoot, directory: true) }
        else { try fm.createDirectory(at: trashRoot, withIntermediateDirectories: false) }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = trashRoot.appendingPathComponent(date + "-" + UUID().uuidString)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("來源：\(path)\n還原：把同目錄的 \(source.lastPathComponent) 搬回 note/\(path)。\n原因：使用者在全域筆記選擇刪除；只封存，未永久刪除。\n".utf8).write(to: destination.appendingPathComponent("RESTORE.md"), options: .atomic)
        try fm.moveItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
    }
    func search(_ query: String, cancelled: () -> Bool, onUnreadable: (String) -> Void = { _ in }) throws -> [Hit] {
        guard !query.isEmpty else { return [] }
        if cancelled() { throw CancellationError() }
        var hits: [Hit] = []
        for entry in try list() where !entry.isFolder {
            if cancelled() { throw CancellationError() }
            if entry.path.localizedCaseInsensitiveContains(query) { hits.append(Hit(path: entry.path, line: 0, snippet: entry.path)) }
            let text: String
            do { text = try read(entry.path) }
            catch {
                if cancelled() { throw CancellationError() }
                // A bad file must not discard healthy results. Report incomplete
                // coverage to the caller; never repair or overwrite the source.
                onUnreadable(entry.path)
                continue
            }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if cancelled() { throw CancellationError() }
                if line.localizedCaseInsensitiveContains(query) { hits.append(Hit(path: entry.path, line: index + 1, snippet: String(line.prefix(200)))) }
            }
        }
        if cancelled() { throw CancellationError() }
        return hits
    }
}

extension GlobalNoteStore {
    /// Runs before app startup: no engine, live OS entry, or application preferences are touched.
    static func runTestIfRequested() {
        guard ProcessInfo.processInfo.environment["TATWO2_NOTETEST"] == "1" else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var passed = false
        Task.detached {
            do {
                let fm = FileManager.default
                let base = fm.temporaryDirectory.appendingPathComponent("global-note-test-" + UUID().uuidString)
                try fm.createDirectory(at: base, withIntermediateDirectories: false)
                let old = base.appendingPathComponent("note.md")
                try Data("original\nNeedle content\n".utf8).write(to: old, options: .atomic)
                let store = GlobalNoteStore(root: base.path)
                try await store.perform { s in
                    try s.prepare()
                    guard try fm.destinationOfSymbolicLink(atPath: old.path) == "note/note.md" else { throw Failure.conflict }
                    print("NOTETEST PASS migration + symlink")
                    try s.create("folder", folder: true)
                    try s.create("folder/filename-needle.txt", folder: false)
                    try s.move("folder/filename-needle.txt", to: "folder/renamed.txt", folder: false)
                    try s.move("folder/renamed.txt", to: "filename-needle.txt", folder: false)
                    try s.save("filename-needle.txt", text: "saved", expected: "")
                    guard try fm.contentsOfDirectory(atPath: base.appendingPathComponent("note/.backup").path).count == 1 else { throw Failure.conflict }
                    print("NOTETEST PASS create folder/file + rename + move + atomic save backup")
                    let hits = try s.search("needle", cancelled: { false })
                    guard hits.contains(where: { $0.line == 0 && $0.path == "filename-needle.txt" }),
                          hits.contains(where: { $0.line == 2 && $0.path == "note.md" }) else { throw Failure.conflict }
                    print("NOTETEST PASS filename + content search")
                    try s.trash("filename-needle.txt", folder: false)
                    guard !(try s.list()).contains(where: { $0.path == "filename-needle.txt" }),
                          try fm.contentsOfDirectory(atPath: base.appendingPathComponent("note/.trash").path).count == 1 else { throw Failure.conflict }
                    print("NOTETEST PASS trash + restore manifest")
                    let file = base.appendingPathComponent("note/note.md")
                    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
                    do { try s.save("note.md", text: "bad", expected: "original\nNeedle content\n"); throw Failure.conflict }
                    catch Failure.readOnly { }
                    guard try s.read("note.md") == "original\nNeedle content\n" else { throw Failure.conflict }
                    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                    let corrupt = Data([0xff, 0xfe, 0xff])
                    try corrupt.write(to: file, options: .atomic)
                    do { try s.save("note.md", text: "bad", expected: ""); throw Failure.conflict }
                    catch Failure.corrupt { }
                    guard try Data(contentsOf: file) == corrupt else { throw Failure.conflict }
                    print("NOTETEST PASS read-only + corrupt reject without overwrite")
                    do { try s.create("../escape.md", folder: false); throw Failure.conflict }
                    catch Failure.invalidPath { }
                    try fm.createSymbolicLink(atPath: base.appendingPathComponent("note/link.md").path, withDestinationPath: old.path)
                    do { _ = try s.read("link.md"); throw Failure.conflict }
                    catch Failure.invalidPath { }
                    print("NOTETEST PASS traversal + symlink reject")
                    do { _ = try s.search("needle", cancelled: { true }); throw Failure.conflict }
                    catch is CancellationError { }
                    print("NOTETEST PASS search cancellation")
                }
                let fallbackRoot = base.appendingPathComponent("fallback")
                try fm.createDirectory(at: fallbackRoot, withIntermediateDirectories: false)
                try Data("retained".utf8).write(to: fallbackRoot.appendingPathComponent("note.md"), options: .atomic)
                try Data("not a directory".utf8).write(to: fallbackRoot.appendingPathComponent("note"), options: .atomic)
                let fallbackStore = GlobalNoteStore(root: fallbackRoot.path)
                try await fallbackStore.perform { s in
                    try s.prepare()
                    guard try s.read("note.md") == "retained" else { throw Failure.conflict }
                    do { try s.save("note.md", text: "bad", expected: "retained"); throw Failure.conflict }
                    catch Failure.readOnly { }
                    guard try s.read("note.md") == "retained" else { throw Failure.conflict }
                    print("NOTETEST PASS failed migration read-only fallback")
                }
                print("NOTETEST artifacts retained: \(base.path)")
                print("NOTETEST PASS")
                passed = true
            } catch { print("NOTETEST FAIL: \(error)") }
            semaphore.signal()
        }
        semaphore.wait()
        exit(passed ? 0 : 1)
    }
}
