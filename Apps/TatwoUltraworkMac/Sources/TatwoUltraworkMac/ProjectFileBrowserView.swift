import Foundation
import SwiftUI

/// 右側面板「檔案」模式：唯讀瀏覽專案工作目錄的檔案，點選文字檔即預覽。
/// 純唯讀（不寫、不刪、不執行）；對齊 os.md §9.1 ③ App 原生（右側面板檔案檢視）。
struct ProjectFileBrowserView: View {
    let rootPath: String

    @State private var currentPath: String = ""
    @State private var entries: [FileEntry] = []
    @State private var selectedPath: String?
    @State private var previewText: String = ""
    @State private var previewNote: String?

    struct FileEntry: Identifiable, Hashable {
        let id: String
        let name: String
        let isDirectory: Bool
    }

    private static let maxPreviewBytes = 512_000
    private static let maxEntries = 400

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if entries.isEmpty {
                emptyState
            } else {
                fileList
            }
            if selectedPath != nil {
                Divider().overlay(Color.white.opacity(0.08))
                previewPane
            }
        }
        .onAppear {
            if currentPath.isEmpty { currentPath = rootPath }
            load()
        }
        .onChange(of: rootPath) { _, newValue in
            currentPath = newValue
            selectedPath = nil
            load()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                let parent = (currentPath as NSString).deletingLastPathComponent
                if !parent.isEmpty, currentPath != rootPath {
                    currentPath = parent
                    selectedPath = nil
                    load()
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(currentPath == rootPath || currentPath.isEmpty)
            .help("上層資料夾")

            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text((currentPath as NSString).lastPathComponent.isEmpty ? currentPath : (currentPath as NSString).lastPathComponent)
                .font(ChatTypography.systemUI(11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button { load() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("重新整理")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(rootPath.isEmpty ? "此專案尚無工作目錄" : "空目錄或無法讀取")
                .font(ChatTypography.systemUI(11.5, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var fileList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(entries) { entry in
                    Button {
                        if entry.isDirectory {
                            currentPath = entry.id
                            selectedPath = nil
                            load()
                        } else {
                            preview(entry)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : fileSymbol(entry.name))
                                .font(.system(size: 11))
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                .frame(width: 15)
                            Text(entry.name)
                                .font(ChatTypography.systemUI(11.5, weight: selectedPath == entry.id ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedPath == entry.id ? Color.white.opacity(0.06) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: selectedPath == nil ? .infinity : 240)
        .scrollIndicators(.hidden)
    }

    private var previewPane: some View {
        ScrollView(.vertical) {
            if let note = previewNote {
                Text(note)
                    .font(ChatTypography.systemUI(11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.hidden)
    }

    /// root 的 canonical(解 symlink)絕對路徑；containment 基準。
    private var canonicalRoot: String {
        URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 路徑解 symlink 後是否仍在 root 內（含 root 本身）；防越界(../, symlink 逃逸)。
    private func isWithinRoot(_ path: String) -> Bool {
        guard !rootPath.isEmpty else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let root = canonicalRoot
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    private func load() {
        let path = currentPath.isEmpty ? rootPath : currentPath
        guard !path.isEmpty, isWithinRoot(path) else { entries = []; return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { entries = []; return }
        let mapped = items
            .filter { !$0.hasPrefix(".") || $0 == ".gitignore" }
            .sorted { lhs, rhs in lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending }
            .prefix(Self.maxEntries)
            .compactMap { name -> FileEntry? in
                let full = (path as NSString).appendingPathComponent(name)
                // 逐項 containment：symlink 指向 root 外者不列。
                guard isWithinRoot(full) else { return nil }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                return FileEntry(id: full, name: name, isDirectory: isDir.boolValue)
            }
        // 目錄在前、檔案在後
        entries = mapped.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    private func preview(_ entry: FileEntry) {
        selectedPath = entry.id
        let fm = FileManager.default
        guard isWithinRoot(entry.id) else {
            previewNote = "超出專案目錄範圍，不預覽"; previewText = ""; return
        }
        // 先查大小(不讀內容)，過大直接拒讀，避免把大檔載進記憶體。
        let attrs = try? fm.attributesOfItem(atPath: entry.id)
        if let size = attrs?[.size] as? Int, size > Self.maxPreviewBytes {
            previewNote = "檔案過大（\(size / 1024) KB），不預覽"; previewText = ""; return
        }
        guard let handle = FileManager.default.contents(atPath: entry.id) else {
            previewNote = "無法讀取此檔案"; previewText = ""; return
        }
        guard handle.count <= Self.maxPreviewBytes else {
            previewNote = "檔案過大（\(handle.count / 1024) KB），不預覽"; previewText = ""; return
        }
        guard let text = String(data: handle, encoding: .utf8) else {
            previewNote = "二進位檔，不預覽"; previewText = ""; return
        }
        previewNote = nil
        previewText = text
    }

    private func fileSymbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "m", "java", "kt": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "dmg": return "archivebox"
        default: return "doc"
        }
    }
}
