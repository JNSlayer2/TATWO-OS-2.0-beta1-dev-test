import AppKit
import SwiftUI
import TatwoCEFBridge
import TatwoUltraworkCore
import WebKit
import Darwin

// MARK: - Annotation model + store（#30：app 內瀏覽器註解）

struct EmbeddedBrowserAnnotation: Identifiable, Codable, Equatable {
    let id: UUID
    let profileKey: UUID
    let url: String
    let title: String
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        profileKey: UUID,
        url: String,
        title: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileKey = profileKey
        self.url = url
        self.title = title
        self.text = text
        self.createdAt = createdAt
    }
}

enum EmbeddedBrowserAnnotationPolicy {
    static let maximumTextCharacters = 4_096
    static let maximumURLCharacters = 4_096
    static let maximumTitleCharacters = 512
    static let maximumAnnotationsPerProfile = 500
    static let maximumPersistedBytes = 1_048_576
    static let maximumAddsPerRateWindow = 12
    static let rateWindowSeconds: TimeInterval = 60

    static func candidate(
        isMainFrame: Bool,
        text: String?,
        committedURLString: String?,
        currentNativeURLString: String?,
        nativeTitle: String?,
        profileKey: UUID,
        createdAt: Date = Date()
    ) -> EmbeddedBrowserAnnotation? {
        guard isMainFrame,
              let committedURLString,
              committedURLString == currentNativeURLString,
              committedURLString.count <= maximumURLCharacters,
              let text = text?.trimmingCharacters(
                in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count <= maximumTextCharacters
        else {
            return nil
        }
        let title = String(
            (nativeTitle ?? "").prefix(maximumTitleCharacters))
        return EmbeddedBrowserAnnotation(
            profileKey: profileKey,
            url: committedURLString,
            title: title,
            text: text,
            createdAt: createdAt)
    }

    static func permitsAppend(
        _ candidate: EmbeddedBrowserAnnotation,
        to annotations: [EmbeddedBrowserAnnotation],
        recentAcceptedAt: [Date],
        now: Date,
        encodedByteCount: Int
    ) -> Bool {
        guard candidate.text.count <= maximumTextCharacters,
              candidate.url.count <= maximumURLCharacters,
              candidate.title.count <= maximumTitleCharacters,
              annotations.lazy.filter({
                  $0.profileKey == candidate.profileKey
              }).count < maximumAnnotationsPerProfile,
              encodedByteCount <= maximumPersistedBytes
        else {
            return false
        }
        let windowStart = now.addingTimeInterval(-rateWindowSeconds)
        return recentAcceptedAt.lazy.filter { $0 >= windowStart }.count
            < maximumAddsPerRateWindow
    }
}

/// 持久化的瀏覽器註解庫。每筆資料綁定 native profile key，查詢與容量
/// 均以 profile 分區；app 內閉環，外部瀏覽器右鍵整合為後續授權項目。
/// `@unchecked Sendable` is required because serialized GCD I/O closures capture the store before UI mutation returns to the main queue.
final class EmbeddedBrowserAnnotationStore:
    ObservableObject,
    @unchecked Sendable
{
    // 全部 mutation 經 DispatchQueue.main / SwiftUI 主執行緒；nonisolated(unsafe) 靜默 Swift6 併發診斷。
    nonisolated(unsafe) static let shared = EmbeddedBrowserAnnotationStore()

    @Published private(set) var annotations: [EmbeddedBrowserAnnotation] = []

    private let fileURL: URL
    private var acceptedAtByProfile: [UUID: [Date]] = [:]
    private let ioQueue = DispatchQueue(
        label: "tatwo.browser-annotations.io",
        qos: .utility)

    init() {
        let dir = TatwoRuntimeLayout.applicationSupportRoot()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser-annotations-v2.json")
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func annotations(
        forURL url: String,
        profileKey: UUID
    ) -> [EmbeddedBrowserAnnotation] {
        annotations.filter {
            $0.profileKey == profileKey && $0.url == url
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(
        _ annotation: EmbeddedBrowserAnnotation,
        now: Date = Date()
    ) -> Bool {
        let candidateAnnotations = annotations + [annotation]
        guard let data = try? JSONEncoder().encode(candidateAnnotations),
              EmbeddedBrowserAnnotationPolicy.permitsAppend(
                annotation,
                to: annotations,
                recentAcceptedAt:
                    acceptedAtByProfile[annotation.profileKey] ?? [],
                now: now,
                encodedByteCount: data.count)
        else {
            return false
        }
        annotations = candidateAnnotations
        let windowStart = now.addingTimeInterval(
            -EmbeddedBrowserAnnotationPolicy.rateWindowSeconds)
        acceptedAtByProfile[annotation.profileKey] =
            (acceptedAtByProfile[annotation.profileKey] ?? [])
            .filter { $0 >= windowStart } + [now]
        save()
        return true
    }

    func remove(_ annotation: EmbeddedBrowserAnnotation) {
        annotations.removeAll { $0.id == annotation.id }
        save()
    }

    // 讀取也走背景 ioQueue，避免啟動時主執行緒同步磁碟 I/O。
    private func load() {
        let url = fileURL
        ioQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  data.count
                    <= EmbeddedBrowserAnnotationPolicy.maximumPersistedBytes,
                  let decoded = try? JSONDecoder().decode([EmbeddedBrowserAnnotation].self, from: data),
                  !decoded.isEmpty,
                  decoded.allSatisfy({
                      $0.text.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumTextCharacters
                          && $0.url.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumURLCharacters
                          && $0.title.count
                          <= EmbeddedBrowserAnnotationPolicy
                          .maximumTitleCharacters
                  }),
                  Dictionary(grouping: decoded, by: \.profileKey)
                    .values.allSatisfy({
                        $0.count
                            <= EmbeddedBrowserAnnotationPolicy
                            .maximumAnnotationsPerProfile
                    })
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.annotations = decoded
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(annotations) else { return }
        let url = fileURL
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Bookmark model + store

struct EmbeddedBrowserBookmark: Identifiable, Codable, Equatable {
    let id: UUID
    let profileKey: UUID
    let url: String
    let title: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        profileKey: UUID,
        url: String,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileKey = profileKey
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }

    var resolvedURL: URL? {
        URL(string: url)
    }

    var host: String {
        guard let host = resolvedURL?.host, !host.isEmpty else {
            return url
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var initial: String {
        String(displayTitle.prefix(1)).uppercased()
    }

    var tooltip: String {
        displayTitle == host ? host : "\(displayTitle)\n\(host)"
    }

    var faviconURL: URL? {
        guard let source = resolvedURL,
              let scheme = source.scheme,
              let host = source.host
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = source.port
        components.path = "/favicon.ico"
        return components.url
    }
}

enum EmbeddedBrowserBookmarkPolicy {
    static let maximumURLCharacters = 4_096
    static let maximumTitleCharacters = 512
    static let maximumBookmarksPerProfile = 100
    static let maximumPersistedBytes = 524_288

    static func candidate(
        urlString: String,
        title: String,
        profileKey: UUID,
        createdAt: Date = Date()
    ) -> EmbeddedBrowserBookmark? {
        let trimmedURL = urlString.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard trimmedURL.count <= maximumURLCharacters,
              trimmedTitle.count <= maximumTitleCharacters,
              let url = URL(string: trimmedURL),
              EmbeddedBrowserNavigationPolicy.decision(for: url) == .allow
        else {
            return nil
        }
        return EmbeddedBrowserBookmark(
            profileKey: profileKey,
            url: url.absoluteString,
            title: trimmedTitle,
            createdAt: createdAt)
    }

    static func permitsAppend(
        _ candidate: EmbeddedBrowserBookmark,
        to bookmarks: [EmbeddedBrowserBookmark],
        encodedByteCount: Int
    ) -> Bool {
        candidate.url.count <= maximumURLCharacters
            && candidate.title.count <= maximumTitleCharacters
            && bookmarks.lazy.filter({
                $0.profileKey == candidate.profileKey
            }).count < maximumBookmarksPerProfile
            && !bookmarks.contains(where: {
                $0.profileKey == candidate.profileKey
                    && $0.url == candidate.url
            })
            && encodedByteCount <= maximumPersistedBytes
    }

    static func isValidPersistedCollection(
        _ bookmarks: [EmbeddedBrowserBookmark],
        encodedByteCount: Int
    ) -> Bool {
        encodedByteCount <= maximumPersistedBytes
            && bookmarks.allSatisfy {
                $0.url.count <= maximumURLCharacters
                    && $0.title.count <= maximumTitleCharacters
                    && $0.resolvedURL != nil
            }
            && Dictionary(grouping: bookmarks, by: \.profileKey)
                .values.allSatisfy {
                    $0.count <= maximumBookmarksPerProfile
                }
    }
}

struct EmbeddedBrowserBookmarkUndoState: Equatable {
    private(set) var bookmarks: [EmbeddedBrowserBookmark]
    private(set) var lastRemoved: EmbeddedBrowserBookmark?
    private var lastRemovedIndex: Int?

    init(bookmarks: [EmbeddedBrowserBookmark]) {
        self.bookmarks = bookmarks
    }

    @discardableResult
    mutating func remove(id: UUID) -> EmbeddedBrowserBookmark? {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = bookmarks.remove(at: index)
        lastRemoved = removed
        lastRemovedIndex = index
        return removed
    }

    @discardableResult
    mutating func undo() -> EmbeddedBrowserBookmark? {
        guard let bookmark = lastRemoved else { return nil }
        let index = min(lastRemovedIndex ?? bookmarks.endIndex, bookmarks.endIndex)
        bookmarks.insert(bookmark, at: index)
        lastRemoved = nil
        lastRemovedIndex = nil
        return bookmark
    }
}

/// Profile-partitioned JSON store. Its live location, background I/O, and
/// bounded decode/write behavior intentionally mirror the annotation store.
final class EmbeddedBrowserBookmarkStore:
    ObservableObject,
    @unchecked Sendable
{
    nonisolated(unsafe) static let shared = EmbeddedBrowserBookmarkStore()

    @Published private(set) var bookmarks: [EmbeddedBrowserBookmark]

    private let fileURL: URL?
    private let ioQueue = DispatchQueue(
        label: "tatwo.browser-bookmarks.io",
        qos: .utility)

    init() {
        let dir = TatwoRuntimeLayout.applicationSupportRoot()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("browser-bookmarks-v1.json")
        bookmarks = []
        load()
    }

    init(
        fileURL: URL?,
        seedBookmarks: [EmbeddedBrowserBookmark] = []
    ) {
        self.fileURL = fileURL
        bookmarks = seedBookmarks
        if fileURL != nil {
            load()
        }
    }

    func bookmarks(profileKey: UUID) -> [EmbeddedBrowserBookmark] {
        bookmarks.filter { $0.profileKey == profileKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(_ bookmark: EmbeddedBrowserBookmark) -> Bool {
        let candidateBookmarks = bookmarks + [bookmark]
        guard let data = try? JSONEncoder().encode(candidateBookmarks),
              EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: bookmarks,
                encodedByteCount: data.count)
        else {
            return false
        }
        bookmarks = candidateBookmarks
        save()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> EmbeddedBrowserBookmark? {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
            return nil
        }
        bookmarks.removeAll { $0.id == id }
        save()
        return bookmark
    }

    @discardableResult
    func restore(_ bookmark: EmbeddedBrowserBookmark) -> Bool {
        add(bookmark)
    }

    private func load() {
        guard let fileURL else { return }
        ioQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(
                    [EmbeddedBrowserBookmark].self,
                    from: data),
                  EmbeddedBrowserBookmarkPolicy.isValidPersistedCollection(
                    decoded,
                    encodedByteCount: data.count)
            else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.bookmarks = decoded
            }
        }
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(bookmarks),
              data.count
                <= EmbeddedBrowserBookmarkPolicy.maximumPersistedBytes
        else {
            return
        }
        ioQueue.async {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum EmbeddedBrowserBookmarkRailLayoutPolicy {
    static let searchCardMaximumWidth: CGFloat = 620
    static let railTopSpacing: CGFloat = 10
    static let collapsedWidth: CGFloat = 30
    static let bubbleWidth: CGFloat = 30
    static let bubbleSpacing: CGFloat = 6
    static let anchorVisualSize: CGFloat = 18
    static let anchorSymbolSize: CGFloat = 11

    static func width(
        isExpanded: Bool,
        bookmarkCount: Int,
        cardContentWidth: CGFloat
    ) -> CGFloat {
        guard isExpanded else { return collapsedWidth }
        let bubbleCount = max(0, bookmarkCount) + 2
        let requested =
            CGFloat(bubbleCount) * bubbleWidth
            + CGFloat(max(0, bubbleCount - 1)) * bubbleSpacing
        let available = max(collapsedWidth, cardContentWidth)
        return min(requested, available)
    }

    static func visibleRailFrame(
        searchCardFrame: CGRect,
        isExpanded: Bool,
        bookmarkCount: Int
    ) -> CGRect {
        CGRect(
            x: searchCardFrame.minX,
            y: searchCardFrame.maxY + railTopSpacing,
            width: width(
                isExpanded: isExpanded,
                bookmarkCount: bookmarkCount,
                cardContentWidth: searchCardFrame.width),
            height: bubbleWidth)
    }
}

enum EmbeddedBrowserToolbarLayoutPolicy {
    static let rowHeight: CGFloat = 36
    static let toolbarControlSpacing: CGFloat = 10
    static let trailingControlSpacing: CGFloat = 2
    static let toolbarVerticalPadding: CGFloat = 7
    static let tabSpacing: CGFloat = 8
    static let tabTitleCloseSpacing: CGFloat = 8
    static let tabContentSpacing: CGFloat = 7
    static let tabHorizontalPadding: CGFloat = 9
    static let controlHitTarget: CGFloat = 32
    static let tabHeight: CGFloat = 32
    static let tabFaviconSize: CGFloat = 16
    static let tabCloseHitTarget: CGFloat = 22
}

enum EmbeddedBrowserNewTabAction {
    static func perform(
        state: TatwoBrowserLaneState,
        id: TatwoBrowserLaneID,
        now: Date
    ) -> TatwoBrowserLaneState {
        TatwoBrowserLaneReducer.reduce(
            state: state,
            action: .open(
                id: id,
                binding: .unboundReadOnly,
                title: "新分頁"),
            now: now)
    }
}

enum EmbeddedBrowserBookmarkRailHoverPolicy {
    static let verticalPadding: CGFloat = 10
    static let collapseDelayMilliseconds = 400
    static var collapseDelay: Duration {
        .milliseconds(collapseDelayMilliseconds)
    }

    static func hoverRegion(
        isExpanded: Bool,
        bookmarkCount: Int,
        cardContentWidth: CGFloat
    ) -> CGRect {
        CGRect(
            x: 0,
            y: -verticalPadding,
            width: EmbeddedBrowserBookmarkRailLayoutPolicy.width(
                isExpanded: isExpanded,
                bookmarkCount: bookmarkCount,
                cardContentWidth: cardContentWidth),
            height:
                EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth
                + verticalPadding * 2)
    }

    static func shouldCollapse(
        isPointerInside: Bool,
        isPinnedOpen: Bool,
        isContextMenuVisible: Bool
    ) -> Bool {
        !isPointerInside && !isPinnedOpen && !isContextMenuVisible
    }
}

struct EmbeddedBrowserBookmarkRailInteractionState: Equatable {
    private(set) var isExpanded = false
    private(set) var isPointerInside = false
    private(set) var isClickExpanded = false

    mutating func toggleClick() {
        if isClickExpanded {
            isClickExpanded = false
            isExpanded = false
        } else {
            isClickExpanded = true
            isExpanded = true
        }
    }

    mutating func pointerEntered() {
        isPointerInside = true
        isExpanded = true
    }

    mutating func pointerExited() {
        isPointerInside = false
    }

    mutating func collapseIfAllowed(
        isContextMenuVisible: Bool
    ) {
        guard EmbeddedBrowserBookmarkRailHoverPolicy.shouldCollapse(
            isPointerInside: isPointerInside,
            isPinnedOpen: isClickExpanded,
            isContextMenuVisible: isContextMenuVisible)
        else {
            return
        }
        isExpanded = false
    }

    mutating func collapseFromOutside() {
        isClickExpanded = false
        isExpanded = false
    }
}

struct EmbeddedBrowserSecondaryClickSurface:
    NSViewRepresentable
{
    let action: () -> Void

    func makeNSView(context _: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(
        _ nsView: SecondaryClickView,
        context _: Context
    ) {
        nsView.action = action
    }

    final class SecondaryClickView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown
                    || event.type == .otherMouseDown
            else {
                return nil
            }
            return bounds.contains(point) ? self : nil
        }

        override func rightMouseDown(with _: NSEvent) {
            action()
        }

        override func otherMouseDown(with _: NSEvent) {
            action()
        }
    }
}
