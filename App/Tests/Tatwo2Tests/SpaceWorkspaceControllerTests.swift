import XCTest
@testable import Tatwo2

@MainActor
final class SpaceWorkspaceControllerTests: XCTestCase {
    private func library() async -> BotLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-space-controller-\(UUID().uuidString)")
        let library = BotLibrary(root: root)
        await library.ready()
        return library
    }

    func testCustomWorkSpacePersistsNameOrderVisibilityWithoutCreatingBot() async throws {
        let store = await library()
        let controller = SpaceWorkspaceController()
        await controller.load(library: store)
        let domain = try XCTUnwrap(controller.state?.selectedDomain)
        domain.screen = .settings
        let originalBots = store.list().count
        domain.addWorkSpace()
        let tab = try XCTUnwrap(domain.tabs.last)
        XCTAssertTrue(tab.isCustom)
        XCTAssertEqual(domain.name(for: tab), "Work Space 1")
        domain.renameWorkSpace(tab, to: "Custom renamed")
        domain.moveTab(tab, before: .chat)
        XCTAssertEqual(controller.visibleModes.first, .custom(tab.rawValue))
        if case .settings = domain.screen {} else { XCTFail("+add navigated away from Settings") }
        await controller.flushWrites()
        XCTAssertNil(controller.error)
        let reloaded = SpaceWorkspaceController()
        await reloaded.load(library: BotLibrary(root: store.root))
        XCTAssertEqual(reloaded.state?.selectedDomain.tabs.first, tab)
        XCTAssertEqual(reloaded.displayName(for: tab.rawValue), "Custom renamed")
        XCTAssertEqual(reloaded.visibleModes.first, .custom(tab.rawValue))
        reloaded.state?.selectedDomain.toggle(tab)
        await reloaded.flushWrites()
        let disabled = SpaceWorkspaceController()
        await disabled.load(library: BotLibrary(root: store.root))
        XCTAssertFalse(disabled.visibleModes.contains(.custom(tab.rawValue)))
        XCTAssertEqual(store.list().count, originalBots)
        XCTAssertTrue(domain.interfaces.isEmpty)
    }

    func testLegacyEmptyLibraryKeepsOriginalTabs() async {
        let controller = SpaceWorkspaceController()
        await controller.load(library: await library())
        XCTAssertEqual(controller.visibleModes, [.chat, .cli, .bot])
        XCTAssertTrue(controller.allows(.cli))
        XCTAssertTrue(controller.allows(.chat))
        XCTAssertTrue(controller.allows(.bot))
    }

    func testCorruptWorkspaceDoesNotEnableDedicatedResources() async throws {
        let store = await library()
        try Data("invalid".utf8).write(to: store.root.appendingPathComponent("space-workspaces.json"))
        let reloaded = BotLibrary(root: store.root)
        let controller = SpaceWorkspaceController()
        await controller.load(library: reloaded)
        XCTAssertEqual(controller.visibleModes, [])
        XCTAssertFalse(controller.allows(.cli))
        XCTAssertNotNil(controller.error)
    }

    func testSelectionAndOverlaysStayWithOwnerAndSelectionReloads() async throws {
        let store = await library()
        try await store.saveSpaces([
            .init(id: "tattoo", name: "刺青", density: "full", ownerBotID: "bot"),
            .init(id: "admin", name: "行政", density: "full", ownerBotID: "admin-bot")
        ])
        _ = try await store.create(.init(id: "bot", name: "Bot", emoji: "🤖",
            role: "assistant", engine: "codex", workdir: store.root.path,
            spaceIDs: ["tattoo"]), instructions: "")
        let first = SpaceWorkInterfaceRecord(id: UUID(), spaceID: "tattoo",
            botID: "bot", conversationID: UUID(), createsDedicatedBot: false,
            name: "後台", initialRequest: "後台", submission: .accepted)
        let second = SpaceWorkInterfaceRecord(id: UUID(), spaceID: "tattoo",
            botID: "bot", conversationID: UUID(), createsDedicatedBot: false,
            name: "預約", initialRequest: "預約", submission: .accepted)
        _ = try await store.updateSpaceDomain(id: "tattoo") {
            $0.interfaces = [first, second]
            $0.selectedInterfaceID = second.id
        }
        let controller = SpaceWorkspaceController()
        await controller.load(library: store)
        controller.selectDomain("tattoo")
        controller.openInterface(first.id.uuidString)
        XCTAssertTrue(controller.presentsInterface)
        controller.selectDomain("admin")
        XCTAssertFalse(controller.presentsInterface)
        controller.selectDomain("tattoo")
        XCTAssertTrue(controller.presentsInterface)
        await controller.flushWrites()
        let reloaded = SpaceWorkspaceController()
        await reloaded.load(library: BotLibrary(root: store.root))
        XCTAssertEqual(reloaded.state?.selectedDomain.selectedInterfaceID, first.id.uuidString)
        XCTAssertEqual(reloaded.state?.selectedDomain.interfaces.count, 2)
    }
}
