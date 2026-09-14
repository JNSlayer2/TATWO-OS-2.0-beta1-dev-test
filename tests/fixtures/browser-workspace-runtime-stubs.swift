import AppKit
import SwiftUI
import Combine

enum EmbeddedBrowserRuntimeProfile { case persistent(UUID)
    var registryKey: UUID { switch self { case let .persistent(id): return id } }
}
enum EmbeddedBrowserProfileAccessState: Equatable {
    case checking(profileKey: UUID), ready(profileKey: UUID), blocked(profileKey: UUID, failure: Failure)
    func isReady(for id: UUID) -> Bool { self == .ready(profileKey: id) }
}
struct Failure: Error, Equatable { let visibleMessage: String; var message: String { visibleMessage } }
enum Engine { case chromiumCEF }
@MainActor struct EmbeddedBrowserProfileAccessCoordinator {
    static let live = Self()
    func recordAccessAndEnforce(profile: EmbeddedBrowserRuntimeProfile, engine: Engine) async -> Result<Void, Failure> { .success(()) }
}
struct EmbeddedBrowserCommand { let id = UUID() }
struct EmbeddedBrowserNavigationState {
    static let blank = Self()
    var committedMainFrameURLString: String?
    var visibleError: Failure?
}
struct EmbeddedChromiumBrowserMountIdentity { let profile: EmbeddedBrowserRuntimeProfile }
enum BrowserTabOwner: Equatable { case workSpace(UUID), chat, chatSession(sessionID: String) }
typealias Owner = BrowserTabOwner
struct TatwoBrowserProfileIdentity {
    let dataStoreIdentifier: UUID
    init?(sessionID: String) { dataStoreIdentifier = UUID(uuidString: sessionID) ?? UUID() }
}
enum EmbeddedBrowserView {
    static func committedURLForPersistence(_ state: EmbeddedBrowserNavigationState) -> URL? {
        state.committedMainFrameURLString.flatMap(URL.init(string:))
    }
}
struct BrowserTab {
    let id: UUID
    let owner: Owner
    var url: URL?
    var title = "Title"
    var faviconPNG: Data?
    var isSleeping = false
    var lastActiveAt = Date()
    var folderID: UUID? = nil
    var usesAgentContext = false
}
@MainActor final class BrowserTabRegistry {
    static let shared = BrowserTabRegistry()
    let changes = PassthroughSubject<Void, Never>()
    var tabs: [BrowserTab] = []
    var writes = 0
    func tabs(ownedBy owner: Owner) -> [BrowserTab] { tabs.filter { $0.owner == owner } }
    func selectedTab(ownedBy owner: Owner) -> BrowserTab? { tabs(ownedBy: owner).max { $0.lastActiveAt < $1.lastActiveAt } }
    func select(_ id: UUID) { touch(id) }
    func touch(_ id: UUID) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].lastActiveAt = Date() } }
    func markSleeping(_ id: UUID, _ value: Bool) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].isSleeping = value } }
    func update(_ id: UUID, url: URL?, title: String, favicon: Data?) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].url = url; tabs[i].title = title; tabs[i].faviconPNG = favicon; writes += 1
    }
    @discardableResult func openTab(owner: Owner, url: URL?, folderID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), owner: owner, url: url, folderID: folderID); tabs.append(tab); return tab
    }
}
// Engine double verifies production controller wiring, not actual CEF/network/visual behavior.
@MainActor final class TatwoCEFTabHostView: NSView {
    static var creations = 0
    var onDailyShortcut: ((String, String) -> Void)?
    var onFindResult: ((String, Int, Int) -> Void)?
    var onPageMetadataChange: (String, String, String?, Data?) -> Void = { _,_,_,_ in }
    var onTabPopupRequested: ((String, URL) -> Void)?
    var onIdle: (() -> Void)?
    var isIdle: Bool { nativeIDs.isEmpty }
    func close() { nativeIDs = [:]; onIdle?() }
    var state: (String, EmbeddedBrowserNavigationState) -> Void
    var pendingState: (String, EmbeddedBrowserNavigationState)?
    func flushTabState(_ id: String) {
        if let pendingState, pendingState.0 == id { state(id, pendingState.1) }
    }
    var live: Set<String> = []
    var selected: String?
    var nativeIDs: [String: UUID] = [:]
    init(mountIdentity: EmbeddedChromiumBrowserMountIdentity, onNavigationStateChange: @escaping (String, EmbeddedBrowserNavigationState) -> Void) {
        state = onNavigationStateChange; super.init(frame: .zero); Self.creations += 1
    }
    required init?(coder: NSCoder) { nil }
    func update(tabID: String?, initialURL: URL?, isAgentTab: Bool = false, openTabIDs: Set<String>, command: EmbeddedBrowserCommand?, isGeometryDragInProgress: Bool) {
        nativeIDs = nativeIDs.filter { openTabIDs.contains($0.key) }
        if let tabID, initialURL != nil, openTabIDs.contains(tabID), nativeIDs[tabID] == nil { nativeIDs[tabID] = UUID() }
        selected = tabID; live = openTabIDs
        if isIdle { onIdle?() }
    }
}

@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    var messages: [String] = []
    func info(title: String, detail: String, duration: TimeInterval) { messages.append(title) }
}
