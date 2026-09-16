import AppKit
import Combine
import Quartz

@MainActor
final class BrowserDownloadStore: NSResponder, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = BrowserDownloadStore()
    enum State: String, Codable { case starting, downloading, paused, completed, failed, cancelled
        var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    struct Item: Identifiable, Equatable, Codable {
        let id: String
        let filename: String
        var received: Int64
        var total: Int64
        var state: State
        let fileURL: URL
        let createdAt: Date
        var failure: String?
        // History records an origin only. Signed query strings, userinfo, and the
        // actual retry URL remain exclusively in the process-local Controls.
        var sourceOrigin: String?
        var done: Bool { state == .completed }
        var name: String { filename }
        var size: String { ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file) }
        var time: String {
            switch state {
            case .starting: return "準備下載…"
            case .downloading: return "下載中 · \(size) / \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "未知大小")"
            case .paused: return "已暫停 · \(size)"
            case .completed: return "已完成 · \(size)"
            case .failed: return "下載失敗 · \(size)"
            case .cancelled: return "已取消 · \(size)"
            }
        }
        var section: String {
            Calendar.current.isDateInToday(createdAt) ? "今天" : Calendar.current.isDateInYesterday(createdAt) ? "昨天" : "Earlier"
        }
        var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp"].contains(fileURL.pathExtension.lowercased()) }
    }
    struct Controls {
        let cancel: () -> Bool
        let pause: () -> Bool
        let resume: () -> Bool
        let retry: () -> Bool
    }
    @Published private(set) var downloads: [Item] = []
    private var controls: [String: Controls] = [:]
    private let storageURL: URL?
    private var lastPersisted = Date.distantPast
    private var previewURL: URL?
    private weak var previewWindow: NSWindow?
    private var hiddenIDs: Set<String> = []
    nonisolated static var defaultStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/browser-downloads.json")
    }

    init(storageURL: URL? = BrowserDownloadStore.defaultStorageURL) {
        self.storageURL = storageURL
        super.init()
        guard let storageURL, let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        downloads = saved.prefix(300).map { entry in
            var item = entry
            if !item.state.isTerminal {
                item.state = .failed
                item.failure = "App 已重新啟動；請回原網站重新下載。"
            }
            return item
        }
    }
    required init?(coder: NSCoder) { nil }

    static func safeOrigin(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil; parts.password = nil; parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }

    func update(event: [String: Any], controls incomingControls: Controls?) {
        guard let id = event["id"] as? String, !id.isEmpty,
              let filename = event["filename"] as? String, !filename.isEmpty,
              filename == (filename as NSString).lastPathComponent, filename != ".", filename != "..",
              let rawState = event["state"] as? String, let state = State(rawValue: rawState) else { return }
        guard !hiddenIDs.contains(id) else { return }
        if let incomingControls { controls[id] = incomingControls }
        let previous = downloads.first { $0.id == id }
        // A late cancellation callback from CEF must not turn an interrupted
        // download into success or erase the visible failure reason.
        if let previous, previous.state.isTerminal, previous.state != state { return }
        let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(filename)
        let path = event["path"] as? String ?? ""
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : defaultURL
        let error = event["error"] as? String
        let item = Item(id: id, filename: filename,
                        received: max(0, (event["received"] as? NSNumber)?.int64Value ?? 0),
                        total: (event["total"] as? NSNumber)?.int64Value ?? -1, state: state,
                        fileURL: url, createdAt: previous?.createdAt ?? Date(),
                        failure: error?.isEmpty == false ? error : previous?.failure,
                        sourceOrigin: Self.safeOrigin(event["sourceURL"] as? String ?? ""))
        if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index] = item }
        else { downloads.insert(item, at: 0) }
        persist(force: state.isTerminal || previous == nil)
        if state == .completed && previous?.state != .completed {
            IslandNotice.shared.info(title: BrowserHumanInteraction.title("已下載 \(filename)"),
                                     detail: BrowserHumanInteraction.oneLine(filename))
        }
    }

    // Compatibility for callers without the richer CEF lifecycle event.
    func update(id: String, filename: String, received: Int64, total: Int64, done: Bool) {
        update(event: ["id": id, "filename": filename, "received": received, "total": total,
                       "state": done ? "completed" : "downloading"], controls: nil)
    }
    func canRetry(_ item: Item) -> Bool { (item.state == .failed || item.state == .cancelled) && controls[item.id] != nil }
    func canCancel(_ item: Item) -> Bool { !item.state.isTerminal && controls[item.id] != nil }
    func canPause(_ item: Item) -> Bool { item.state == .downloading && controls[item.id] != nil }
    func canResume(_ item: Item) -> Bool { item.state == .paused && controls[item.id] != nil }
    func cancel(_ item: Item) { perform(item) { $0.cancel() } }
    func pause(_ item: Item) { perform(item) { $0.pause() } }
    func resume(_ item: Item) { perform(item) { $0.resume() } }
    func retry(_ item: Item) { perform(item) { $0.retry() } }
    private func perform(_ item: Item, action: (Controls) -> Bool) {
        guard let controls = controls[item.id], action(controls) else {
            if let index = downloads.firstIndex(where: { $0.id == item.id }) {
                if !downloads[index].state.isTerminal { downloads[index].state = .failed }
                downloads[index].failure = "來源分頁已關閉或操作不可用；請回原網站重新下載。"
                self.controls[item.id] = nil
                persist(force: true)
            }
            return
        }
    }
    private func persist(force: Bool = false) {
        guard let storageURL, force || Date().timeIntervalSince(lastPersisted) >= 1,
              let data = try? JSONEncoder().encode(Array(downloads.prefix(300))) else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            lastPersisted = Date()
        } catch { /* Download success must not be changed by an unavailable history file. */ }
    }
    // Clear/hide removes terminal history entries, never files from disk.
    func clearDownloads() {
        let ids = downloads.filter { $0.state.isTerminal }.map(\.id)
        hiddenIDs.formUnion(ids)
        for id in ids { controls[id] = nil }
        downloads.removeAll { $0.state.isTerminal }
        persist(force: true)
    }
    func hide(_ item: Item) {
        guard item.state.isTerminal else { return }
        hiddenIDs.insert(item.id)
        controls[item.id] = nil
        downloads.removeAll { $0.id == item.id }
        persist(force: true)
    }
    func reveal(_ item: Item) {
        guard item.done, FileManager.default.fileExists(atPath: item.fileURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }
    func preview(_ item: Item) {
        guard item.done, FileManager.default.fileExists(atPath: item.fileURL.path),
              let panel = QLPreviewPanel.shared() else { return }
        previewURL = item.fileURL
        if previewWindow == nil, let window = NSApp.keyWindow ?? NSApp.mainWindow {
            previewWindow = window
            nextResponder = window.nextResponder
            window.nextResponder = self
        }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        if previewWindow?.nextResponder === self { previewWindow?.nextResponder = nextResponder }
        previewWindow = nil
        nextResponder = nil
        previewURL = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
