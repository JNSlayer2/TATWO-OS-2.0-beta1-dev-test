import Foundation
import TatwoUltraworkCore
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class BrowserManagementViewModelTests: XCTestCase {
    func testFixtureProviderRendersCapacityAndPersistentEphemeralRows()
        throws
    {
        let snapshot = try TatwoBrowserManagementFixtureProvider()
            .snapshot(for: [])

        XCTAssertEqual(snapshot.source, .fixture)
        XCTAssertEqual(
            snapshot.byteLimit,
            EmbeddedBrowserSessionPersistenceContract
                .maximumCEFProfileBytes)
        XCTAssertEqual(snapshot.usedBytes, 318 * 1_024 * 1_024)
        XCTAssertEqual(snapshot.sessions.count, 3)
        XCTAssertTrue(
            snapshot.sessions.contains {
                $0.persistence == .persistent && !$0.isArchived
            })
        XCTAssertTrue(
            snapshot.sessions.contains {
                $0.persistence == .ephemeral
            })
        XCTAssertEqual(
            TatwoBrowserManagementPersistence.persistent.label,
            "登入會記住")
        XCTAssertEqual(
            TatwoBrowserManagementPersistence.ephemeral.label,
            "關掉就忘")
        XCTAssertEqual(
            TatwoBrowserManagementCopy.capacityHeadline(
                usedBytes: 120_900_000,
                limitBytes: 512 * 1_024 * 1_024),
            "瀏覽器資料 115.3 MB／上限 512 MB")
        XCTAssertEqual(
            TatwoBrowserManagementCopy.capacityExplanation,
            "超過上限時，會先清掉最久沒用、已封存的資料。")
    }

    func testFixtureModeRejectsAllManagementActionsBeforeDispatch()
        async throws
    {
        let provider = TatwoBrowserManagementProviderFactory.make(
            environment: ["TATWO_BROWSER_MANAGEMENT_FIXTURE": "1"])
        let viewModel = TatwoBrowserManagementViewModel(
            provider: provider)
        viewModel.reload(descriptors: [])
        let session = try XCTUnwrap(viewModel.snapshot?.sessions.first)
        var dispatchCount = 0

        for action in [
            TatwoBrowserManagementAction.clearCurrentSite,
            .reset,
            .archive,
            .delete,
        ] {
            let didExecute = await viewModel.performAction(
                action,
                sessionID: session.id
            ) {
                dispatchCount += 1
                return "不應執行"
            }

            XCTAssertFalse(didExecute, "\(action) must remain fixture-only")
            XCTAssertEqual(viewModel.activeSessionID, nil)
            XCTAssertEqual(
                viewModel.statusMessage,
                "預覽模式不會更動真實瀏覽資料。")
        }

        XCTAssertEqual(dispatchCount, 0)
    }

    func testLiveProviderReadsLedgerCEFBytesAndNavigationJournal()
        throws
    {
        let root = temporaryRoot()
        let ledgerRoot = root.appendingPathComponent(
            "ledger",
            isDirectory: true)
        let cefRoot = root.appendingPathComponent(
            "cef",
            isDirectory: true)
        let journalRoot = root.appendingPathComponent(
            "journals",
            isDirectory: true)
        let descriptor = TatwoBrowserManagementSessionDescriptor(
            sessionID: UUID(
                uuidString: "e474b90a-9549-4cf3-aead-06ef92ce2691")!,
            name: "Real provider",
            updatedAt: Date(timeIntervalSince1970: 10),
            isArchived: false)
        let identity = try XCTUnwrap(
            TatwoBrowserProfileIdentity(
                sessionID: descriptor.sessionID.uuidString.lowercased()))
        let profile = EmbeddedBrowserRuntimeProfile.persistent(
            identity.dataStoreIdentifier)
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: ledgerRoot,
            maximumPersistentProfileCount: 8)
        try ledgerStore.recordAccess(
            profile: profile,
            storageKind: .cefAppOwned,
            generation: 0,
            at: Date(timeIntervalSince1970: 20))
        let cefStore = TatwoCEFProfileStore(rootCacheURL: cefRoot)
        let profileURL = try cefStore.prepareProfileParent(
            for: identity.dataStoreIdentifier)
        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: false)
        let payload = Data(repeating: 0x5a, count: 4_096)
        try payload.write(
            to: profileURL.appendingPathComponent("fixture.bin"))
        let journalStore = EmbeddedBrowserNavigationJournalStore(
            profileRoot: journalRoot)
        let currentURL = URL(string: "https://example.com/account")!
        try journalStore.save(
            try XCTUnwrap(
                EmbeddedBrowserNavigationJournal(
                    urls: [currentURL],
                    currentIndex: 0)),
            profile: profile)

        let snapshot = try TatwoBrowserManagementLiveProvider(
            ledgerStore: ledgerStore,
            cefStore: cefStore,
            journalStore: journalStore)
            .snapshot(for: [descriptor])

        XCTAssertEqual(snapshot.source, .live)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].name, "Real provider")
        XCTAssertEqual(snapshot.sessions[0].lastUsedAt, Date(
            timeIntervalSince1970: 20))
        XCTAssertEqual(snapshot.sessions[0].currentOriginURL, currentURL)
        XCTAssertGreaterThan(snapshot.sessions[0].sizeBytes ?? 0, 0)
        XCTAssertEqual(
            snapshot.usedBytes,
            snapshot.sessions[0].sizeBytes)
    }

    func testLiveProviderOmitsUnusedZeroByteDescriptorWithoutProfileEvidence()
        throws
    {
        let root = temporaryRoot()
        let descriptor = TatwoBrowserManagementSessionDescriptor(
            sessionID: UUID(),
            name: "Never used",
            updatedAt: Date(timeIntervalSince1970: 10),
            isArchived: false)
        let snapshot = try TatwoBrowserManagementLiveProvider(
            ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore(
                profileRoot:
                    root.appendingPathComponent(
                        "ledger",
                        isDirectory: true),
                maximumPersistentProfileCount: 8),
            cefStore: TatwoCEFProfileStore(
                rootCacheURL:
                    root.appendingPathComponent(
                        "cef",
                        isDirectory: true)),
            journalStore: EmbeddedBrowserNavigationJournalStore(
                profileRoot:
                    root.appendingPathComponent(
                        "journals",
                        isDirectory: true)))
            .snapshot(for: [descriptor])

        XCTAssertEqual(snapshot.usedBytes, 0)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testManagementViewUsesPlainCopyConditionalSiteActionAndMoreMenu()
        throws
    {
        let source = try browserManagementViewSource()

        XCTAssertFalse(source.contains("維護狀態"))
        XCTAssertFalse(source.contains("fail-closed"))
        XCTAssertTrue(source.contains(
            "if session.currentOriginURL != nil"))
        XCTAssertTrue(source.contains(
            "\"清這個網站的資料\""))
        XCTAssertTrue(source.contains(
            "\"清空這個 session 的瀏覽資料\""))
        XCTAssertTrue(source.contains(
            "Label(\"封存\", systemImage: \"archivebox\")"))
        XCTAssertTrue(source.contains(
            "Label(\"刪除瀏覽資料…\", systemImage: \"trash\")"))
        XCTAssertTrue(source.contains(
            ".menuIndicator(.hidden)"))
    }

    func testLifecycleIntentFactoryCreatesDeletePendingPurgeIntent() {
        let intentID = UUID(
            uuidString: "f9ed502a-871b-4052-b0af-eb53c08af0bb")!
        let profileID = UUID(
            uuidString: "c7521441-81f4-43dc-a749-7f73819fa1cf")!
        let date = Date(timeIntervalSince1970: 42)

        let intent = EmbeddedBrowserLifecycleIntentFactory.make(
            disposition: .delete,
            sessionID: "session-delete",
            profileIdentifier: profileID,
            generation: 7,
            intentID: intentID,
            at: date)

        XCTAssertEqual(intent.intentID, intentID)
        XCTAssertEqual(intent.disposition, .delete)
        XCTAssertEqual(intent.stage, .pendingPurge)
        XCTAssertEqual(intent.profileIdentifier, profileID)
        XCTAssertEqual(intent.generation, 7)
        XCTAssertEqual(intent.createdAt, date)
        XCTAssertEqual(intent.updatedAt, date)
    }

    func testSafetyAndDiagnosticMappingsAreSpecific() {
        XCTAssertEqual(
            EmbeddedBrowserVisibleError.downloadBlocked.message,
            "這個網站要求下載檔案，內建瀏覽器目前不允許下載")
        XCTAssertEqual(
            EmbeddedBrowserVisibleError
                .sensitivePermissionBlocked(.camera).message,
            "已拒絕相機權限")
        XCTAssertEqual(
            EmbeddedBrowserSecurityStatusPresentation.title(
                for: EmbeddedBrowserVisibleError.downloadBlocked.message),
            "下載已阻擋")
        XCTAssertEqual(
            EmbeddedBrowserSecurityStatusPresentation.title(
                for: EmbeddedBrowserVisibleError
                    .sensitivePermissionBlocked(.microphone).message),
            "網站權限已拒絕")

        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: navigationState(
                    isLoading: true,
                    phase: .creating,
                    committedURL: nil)),
            .pageCreating)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: navigationState(
                    isLoading: true,
                    phase: .committed,
                    committedURL: "https://example.com")),
            .loadedAwaitingPaint)
        XCTAssertEqual(
            EmbeddedBrowserSurfacePresentation.condition(
                for: navigationState(
                    isLoading: false,
                    phase: .rendererFailed,
                    committedURL: "https://example.com")),
            .subprocessRestart(
                message:
                    "Chromium renderer 已停止，正在等待安全重啟。",
                code: nil))
    }

    private func navigationState(
        isLoading: Bool,
        phase: EmbeddedBrowserLoadPhase,
        committedURL: String?
    ) -> EmbeddedBrowserNavigationState {
        EmbeddedBrowserNavigationState(
            urlString: committedURL,
            canGoBack: false,
            canGoForward: false,
            visibleError: nil,
            isLoading: isLoading,
            phase: phase,
            committedMainFrameURLString: committedURL)
    }

    private func temporaryRoot() -> URL {
        let baseURL = ProcessInfo.processInfo.environment["TMPDIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(
                "tatwo-browser-management-\(UUID().uuidString)",
                isDirectory: true)
    }

    private func browserManagementViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/BrowserManagementView.swift"),
            encoding: .utf8)
    }
}
