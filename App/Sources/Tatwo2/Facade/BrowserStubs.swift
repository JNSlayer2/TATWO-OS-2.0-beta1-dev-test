// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/EmbeddedBrowserProfile.swift、BrowserNetworkSecurity.swift；只保留畫面與瀏覽器管理假資料欄位。
import Foundation

// ChromiumCEFBackend 已接回的同名型別已移至 Browser/ChromiumCEFBackend.swift；
// 本檔只保留尚未搬入 Tatwo2 的生命週期／管理面 Facade。
enum EmbeddedBrowserLifecycleStage: String, Codable, Equatable, Sendable {
    case pendingPurge
    case purgedCommitRequired
    case archivePrepared
    case finalMutationApplied
    case committed
}

struct EmbeddedBrowserLifecycleIntent: Sendable {
    let intentID: UUID
    let stage: EmbeddedBrowserLifecycleStage
}

struct EmbeddedBrowserLifecycleIntentStore: Sendable {
    static let live = EmbeddedBrowserLifecycleIntentStore()
    func pendingIntent(profileIdentifier: UUID) throws -> EmbeddedBrowserLifecycleIntent? { nil }
}

enum BrowserRequestPolicyEvaluator {
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }
}

enum EmbeddedBrowserSiteDataMaintenanceError: Error, Equatable, Sendable {
    case invalidOrigin
    var visibleMessage: String { "CEF 網站資料維護尚未接回" }
}

struct EmbeddedBrowserSiteDataClearOutcome: Equatable, Sendable {
    var visibleMessage: String { "CEF 網站資料維護尚未接回" }
}

@MainActor
struct EmbeddedBrowserSiteDataMaintenanceCoordinator {
    func clear(
        originURL: URL,
        sessionID: String,
        engine: EmbeddedBrowserEngine
    ) async -> Result<EmbeddedBrowserSiteDataClearOutcome, EmbeddedBrowserSiteDataMaintenanceError> {
        .success(.init())
    }
}

enum EmbeddedBrowserSessionLifecycleError: Error, Equatable, Sendable {
    case invalidSessionID
    var visibleMessage: String { "CEF session 維護尚未接回" }
}

struct EmbeddedBrowserSessionLifecycleReceipt: Equatable, Sendable {}

@MainActor
struct EmbeddedBrowserSessionLifecycleTransaction {
    init(disposition: EmbeddedBrowserSessionDisposition, sessionID: String) {}
    func prepare() async -> Result<EmbeddedBrowserSessionLifecycleReceipt, EmbeddedBrowserSessionLifecycleError> { .success(.init()) }
    func commitProfileOnly(receipt: EmbeddedBrowserSessionLifecycleReceipt) -> Result<EmbeddedBrowserSessionLifecycleReceipt, EmbeddedBrowserSessionLifecycleError> { .success(receipt) }
    func commitDeletedProfile(receipt: EmbeddedBrowserSessionLifecycleReceipt) -> Result<EmbeddedBrowserSessionLifecycleReceipt, EmbeddedBrowserSessionLifecycleError> { .success(receipt) }
}

extension TatwoNativeChatStoreDocument {
    var threads: [TatwoNativeChatThread] { [] }
}

extension TatwoNativeChatThread {
    var updatedAt: Date { .distantPast }
    var isArchived: Bool { false }
}

@MainActor
extension ChatPageModel {
    func performBrowserManagementAction(
        _ action: TatwoBrowserManagementAction,
        session: TatwoBrowserManagementSession
    ) async -> String { "預覽模式不會更動真實瀏覽資料。" }

    func clearBrowserAgentActivePage(sessionID: String?) {}
    func updateBrowserAgentActivePage(
        sessionID: String?,
        state: EmbeddedBrowserNavigationState
    ) {}
}
