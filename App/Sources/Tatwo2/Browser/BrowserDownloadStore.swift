import AppKit
import Combine
import Quartz

@MainActor
final class BrowserDownloadStore: NSResponder, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = BrowserDownloadStore()
    struct Item: Identifiable, Equatable {
        let id: String
        let filename: String
        var received: Int64
        var total: Int64
        var done: Bool
        let fileURL: URL
        let createdAt: Date
        var name: String { filename }
        var size: String { ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file) }
        var time: String { done ? "已完成 · \(size)" : "\(size) / \(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "未知大小")" }
        var section: String {
            Calendar.current.isDateInToday(createdAt) ? "今天" : Calendar.current.isDateInYesterday(createdAt) ? "昨天" : "Earlier"
        }
        var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp"].contains(fileURL.pathExtension.lowercased()) }
    }
    @Published private(set) var downloads: [Item] = []
    private var previewURL: URL?
    private weak var previewWindow: NSWindow?
    private var hiddenIDs: Set<String> = []

    func update(id: String, filename: String, received: Int64, total: Int64, done: Bool) {
        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent,
              filename != ".", filename != ".." else { return }
        let previous = downloads.first { $0.id == id }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(filename)
        let item = Item(id: id, filename: filename, received: max(0, received), total: total,
                        done: done, fileURL: url, createdAt: previous?.createdAt ?? Date())
        if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index] = item }
        else if !hiddenIDs.contains(id) { downloads.insert(item, at: 0) }
        if done && previous?.done != true && !hiddenIDs.contains(id) {
            IslandNotice.shared.info(title: BrowserHumanInteraction.title("已下載 \(filename)"),
                                     detail: BrowserHumanInteraction.oneLine(filename))
        }
    }
    // Clear removes completed entries from the panel, never files from disk.
    func clearDownloads() {
        hiddenIDs.formUnion(downloads.filter(\.done).map(\.id))
        downloads.removeAll(where: \.done)
    }
    func hide(_ item: Item) {
        guard item.done else { return }
        hiddenIDs.insert(item.id)
        downloads.removeAll { $0.id == item.id }
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
