import XCTest
@testable import Tatwo2

final class SpaceWorkspacePersistenceTests: XCTestCase {
    func testInterfaceNameUsesFilledSpecificationField() {
        XCTAssertEqual(SpaceBuilderDraft(text: """
            請協助我在目前 Space 搭建以下工作介面：
            【名稱】
            預約管理
            【主要功能】
            登記預約
            """).interfaceName, "預約管理")
        XCTAssertEqual(SpaceBuilderDraft(text: "【名稱】：刺青後台").interfaceName, "刺青後台")
        XCTAssertEqual(SpaceBuilderDraft(text: "【名稱】\n【主要功能】").interfaceName, "工作介面")
        XCTAssertEqual(SpaceBuilderDraft(text: "行政介面").interfaceName, "行政介面")
    }

    func testFollowupAndConversationDraftRejectForeignInterface() throws {
        var doc = SpaceWorkspaceDocument()
        var domain = SpaceDomainRecord(id: "tattoo")
        let foreignID = UUID()
        domain.followupRequests = [foreignID.uuidString: .init(
            id: UUID(), interfaceID: foreignID, text: "需求", status: .dispatching)]
        doc.domains[domain.id] = domain
        XCTAssertThrowsError(try doc.validated())
        domain.followupRequests = [:]
        domain.conversationDrafts = [foreignID.uuidString: "草稿"]
        doc.domains[domain.id] = domain
        XCTAssertThrowsError(try doc.validated())
    }

    func testFollowupIntentAndOwnedDraftSurviveReload() async throws {
        let store = await library()
        let domain = try await store.updateSpaceDomain(id: "tattoo") { $0.draft.text = "介面" }
        let item = try await store.reserveSpaceInterface(
            spaceID: domain.id, draftID: domain.draft.id, name: "介面")
        let request = SpaceFollowupRequest(id: UUID(), interfaceID: item.id,
            text: "後續需求", status: .dispatching)
        _ = try await store.updateSpaceDomain(id: domain.id) {
            $0.followupRequests = [item.id.uuidString: request]
            $0.conversationDrafts = [item.id.uuidString: "後續需求"]
        }
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains[domain.id]?
            .followupRequests?[item.id.uuidString], request)
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains[domain.id]?
            .conversationDrafts?[item.id.uuidString], "後續需求")
    }

    private func library() async -> BotLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-space-tests-\(UUID().uuidString)")
        let library = BotLibrary(root: root)
        await library.ready()
        return library
    }

    func testDefaultsAndIndependentDraftsSurviveReload() async throws {
        let store = await library()
        let tattoo = try await store.updateSpaceDomain(id: "tattoo") {
            $0.draft.text = "預約管理"
            $0.disabledTabs.insert(.cli)
            $0.tabOrder = [.bot, .chat, .cli]
        }
        _ = try await store.updateSpaceDomain(id: "admin") { $0.draft.text = "行政後台" }
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains["tattoo"], tattoo)
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains["admin"]?.draft.text, "行政後台")
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains["admin"]?.disabledTabs, [])
        XCTAssertTrue(reloaded.list().isEmpty, "Saving drafts must not create Bots.")
    }

    func testReservationRetryKeepsAllIdentitiesWithoutCreatingBot() async throws {
        let store = await library()
        let domain = try await store.updateSpaceDomain(id: "tattoo") { $0.draft.text = "預約管理" }
        let first = try await store.reserveSpaceInterface(spaceID: domain.id, draftID: domain.draft.id, name: "預約")
        let retry = try await store.reserveSpaceInterface(spaceID: domain.id, draftID: domain.draft.id, name: "預約")
        XCTAssertEqual(first, retry)
        XCTAssertEqual(store.snapshot.spaceWorkspace.domains["tattoo"]?.interfaces.count, 1)
        XCTAssertTrue(store.list().isEmpty)
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        let afterRestart = try await reloaded.reserveSpaceInterface(spaceID: domain.id, draftID: domain.draft.id, name: "預約")
        XCTAssertEqual(first, afterRestart)
    }

    func testRejectsForeignBotAndLeavesDocumentUnchanged() async throws {
        let store = await library()
        _ = try await store.create(.init(id: "admin-bot", name: "行政", emoji: "🤖",
            role: "assistant", engine: "codex", workdir: store.root.path, spaceIDs: ["admin"]),
            instructions: "")
        let domain = try await store.updateSpaceDomain(id: "tattoo") {
            $0.draft.text = "預約"
            $0.draft.existingBotID = "admin-bot"
        }
        do {
            _ = try await store.reserveSpaceInterface(spaceID: domain.id, draftID: domain.draft.id, name: "預約")
            XCTFail("Cross-domain Bot was accepted")
        } catch {}
        XCTAssertEqual(store.snapshot.spaceWorkspace.domains["tattoo"], domain)
    }

    func testMalformedDocumentIsPreservedAndWritesFailClosed() async throws {
        let store = await library()
        let url = store.root.appendingPathComponent("space-workspaces.json")
        let malformed = Data("{\"version\":999,\"domains\":{}}".utf8)
        try malformed.write(to: url)
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        XCTAssertNotNil(reloaded.snapshot.spaceWorkspaceError)
        do {
            _ = try await reloaded.updateSpaceDomain(id: "tattoo") { $0.draft.text = "test" }
            XCTFail("Unsupported document was overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testDuplicateConversationAcrossDomainsRejected() throws {
        let conversation = UUID()
        var doc = SpaceWorkspaceDocument()
        for id in ["tattoo", "admin"] {
            var domain = SpaceDomainRecord(id: id)
            domain.interfaces = [.init(id: UUID(), spaceID: id, botID: "\(id)-bot",
                conversationID: conversation, createsDedicatedBot: false, name: id, initialRequest: "test")]
            doc.domains[id] = domain
        }
        XCTAssertThrowsError(try doc.validated())
    }

    func testBrokenLegacySpacesCannotEraseWorkspace() async throws {
        let store = await library()
        let domain = try await store.updateSpaceDomain(id: "tattoo") { $0.draft.text = "保留此草稿" }
        try Data("invalid-json".utf8).write(to: store.root.appendingPathComponent("bot-spaces.json"))
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains["tattoo"], domain)
        _ = try await reloaded.updateSpaceDomain(id: "admin") { $0.draft.text = "另一領域" }
        XCTAssertEqual(reloaded.snapshot.spaceWorkspace.domains["tattoo"], domain)
    }

    func testDefaultBotBindingDoesNotChooseInterfaceConversation() async throws {
        let store = await library()
        _ = try await store.create(.init(id: "bot", name: "Bot", emoji: "🤖", role: "assistant",
            engine: "codex", workdir: store.root.path, spaceIDs: ["tattoo"]), instructions: "")
        let normal = UUID()
        try await store.recordSession(botID: "bot", threadID: normal.uuidString, engine: "codex")
        let domain = try await store.updateSpaceDomain(id: "tattoo") {
            $0.draft.text = "專屬對話"
            $0.draft.existingBotID = "bot"
        }
        let item = try await store.reserveSpaceInterface(spaceID: "tattoo", draftID: domain.draft.id, name: "介面")
        try await store.recordSession(botID: "bot", threadID: item.conversationID.uuidString.lowercased(), engine: "codex")
        let adapter = BotStore(root: store.root)
        await adapter.library.ready()
        XCTAssertEqual(adapter.threadID(forBotID: "bot"), normal)
        try Data("invalid".utf8).write(to: store.root.appendingPathComponent("space-workspaces.json"))
        let broken = BotStore(root: store.root)
        await broken.library.ready()
        XCTAssertNil(broken.threadID(forBotID: "bot"), "Do not recover default Chat from an unclassified session.")
    }

    func testAcceptedReservationRemainsIdempotentAfterDraftAdvances() async throws {
        let store = await library()
        let domain = try await store.updateSpaceDomain(id: "tattoo") { $0.draft.text = "第一個介面" }
        let first = try await store.reserveSpaceInterface(spaceID: "tattoo", draftID: domain.draft.id, name: "第一個")
        _ = try await store.updateSpaceDomain(id: "tattoo") {
            $0.interfaces[0].submission = .accepted
            $0.draft = SpaceBuilderDraft()
        }
        let retry = try await store.reserveSpaceInterface(spaceID: "tattoo", draftID: domain.draft.id, name: "重試")
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(first.botID, retry.botID)
        XCTAssertEqual(first.conversationID, retry.conversationID)
        XCTAssertEqual(retry.submission, .accepted)
    }

    func testDedicatedBotCreationIsIdempotentAndLeavesNoLivePartialFolder() async throws {
        let store = await library()
        let domain = try await store.updateSpaceDomain(id: "tattoo") { $0.draft.text = "搭建需求" }
        let item = try await store.reserveSpaceInterface(spaceID: "tattoo", draftID: domain.draft.id, name: "介面")
        let bot = BotLibraryRecord(id: item.botID, name: "專屬 Bot", emoji: "🤖",
            role: "assistant", engine: "codex", workdir: store.root.path, spaceIDs: ["tattoo"])
        let first = try await store.createSpaceBot(bot, reservation: item, instructions: "先詢問")
        let retry = try await store.createSpaceBot(bot, reservation: item, instructions: "先詢問")
        XCTAssertEqual(first, retry)
        XCTAssertEqual(store.list().count, 1)
        let reloaded = BotLibrary(root: store.root)
        await reloaded.ready()
        XCTAssertEqual(reloaded.bot(id: item.botID), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root
            .appendingPathComponent("space-bot-staging")
            .appendingPathComponent(item.id.uuidString.lowercased()).path))
    }
}
