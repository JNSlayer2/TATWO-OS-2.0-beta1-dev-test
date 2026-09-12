import XCTest
import Combine
@testable import Tatwo2

/// Fixture-state tests only; these cannot establish production lifecycle or persistence.
@MainActor
final class SpaceSetupPreviewStateTests: XCTestCase {
    func testComposerChoicesRemainOwnedByTheirDomain() throws {
        let preview = SpaceSetupPreviewState()
        let tattoo = preview.selectedDomain
        let admin = preview.domains[1]
        let originalRoute = admin.composerRoute
        let another = try XCTUnwrap(ChatRouteChoice.all.first { $0.id != originalRoute.id })
        tattoo.selectComposerRoute(another.id)
        tattoo.composerPermission = .fullAccess
        tattoo.composerCollaboration = .xl
        preview.selectDomain(admin.id)
        XCTAssertEqual(admin.composerRoute, originalRoute)
        XCTAssertEqual(admin.composerPermission, .askFirst)
        XCTAssertEqual(admin.composerCollaboration, .off)
        preview.selectDomain(tattoo.id)
        XCTAssertEqual(tattoo.composerRoute, another)
        XCTAssertEqual(tattoo.composerPermission, .fullAccess)
        XCTAssertEqual(tattoo.composerCollaboration, .xl)
        XCTAssertTrue(tattoo.interfaces.isEmpty)
        XCTAssertEqual(tattoo.bots.count, 1)
    }

    func testComposerRouteChoicesUseExistingCatalogCapabilities() {
        let domain = SpaceSetupPreviewState().selectedDomain
        for route in ChatRouteChoice.all {
            domain.selectComposerRoute(route.id)
            XCTAssertEqual(domain.composerRoute, route)
            if route.supportsNativeReasoningControl {
                XCTAssertTrue(route.allowedEfforts.contains(domain.composerEffort))
            }
            if let speed = domain.composerSpeed {
                XCTAssertTrue(route.allowedSpeedTiers.contains(speed))
            }
        }
        let previous = domain.composerRoute
        domain.selectComposerRoute("not-a-real-catalog-route")
        XCTAssertEqual(domain.composerRoute, previous)
    }

    func testOriginalShellPreviewCannotUseLiveBotLibrary() {
        let botState = BotPageState(sceneID: "add-space", isUIOnlyPreview: true)
        XCTAssertTrue(botState.isUIOnlyPreview)
        XCTAssertFalse(botState.unknownScene)
        XCTAssertFalse(botState.usesLiveBots)
    }

    func testDomainChangesInvalidateOriginalShellProjection() {
        let preview = SpaceSetupPreviewState()
        var changes = 0
        let observation = preview.objectWillChange.sink { changes += 1 }
        preview.selectedDomain.toggle(.cli)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(preview.selectedDomain.visibleTabs, [.chat, .bot])
        XCTAssertEqual(preview.domains[1].visibleTabs, [.chat, .cli, .bot])
        withExtendedLifetime(observation) {}
    }

    func testDefaultsAndDomainDraftIsolation() {
        let preview = SpaceSetupPreviewState()
        let tattoo = preview.selectedDomain
        tattoo.draft = "刺青後台"
        tattoo.chosenBotID = tattoo.bots[0].id
        preview.selectDomain(preview.domains[1].id)
        let admin = preview.selectedDomain
        XCTAssertTrue(admin.draft.isEmpty)
        XCTAssertTrue(admin.chosenBotID.isEmpty)
        XCTAssertEqual(admin.visibleTabs, [.chat, .cli, .bot])
        admin.draft = "行政流程"
        preview.selectDomain(tattoo.id)
        XCTAssertTrue(preview.selectedDomain === tattoo)
        XCTAssertEqual(tattoo.draft, "刺青後台")
        XCTAssertEqual(tattoo.chosenBotID, tattoo.bots[0].id)
        XCTAssertEqual(admin.draft, "行政流程")
    }

    func testDedicatedBotAndConversationEntrypoints() throws {
        let domain = SpaceSetupPreviewState().selectedDomain
        let count = domain.bots.count
        domain.draft = "新增專屬工作介面"
        domain.previewResult()
        let item = try XCTUnwrap(domain.selectedInterface)
        XCTAssertEqual(domain.bots.count, count + 1)
        XCTAssertTrue(domain.bots.contains(item.bot))
        domain.selectInterface(item.id, conversation: true)
        XCTAssertEqual(domain.selectedInterface?.conversationID, item.conversationID)
        domain.selectInterface(item.id)
        XCTAssertEqual(domain.selectedInterface?.conversationID, item.conversationID)
        domain.previewResult() // Cleared input must not create another object.
        XCTAssertEqual(domain.interfaces.count, 1)
        XCTAssertEqual(domain.bots.count, count + 1)
    }

    func testExistingBotHasSeparateConversationPerInterface() throws {
        let domain = SpaceSetupPreviewState().selectedDomain
        let existing = domain.bots[0]
        for name in ["後台", "預約管理"] {
            domain.openBuilder()
            domain.chosenBotID = existing.id
            domain.draft = name
            domain.previewResult()
        }
        XCTAssertEqual(domain.bots, [existing])
        XCTAssertEqual(domain.interfaces.count, 2)
        XCTAssertEqual(Set(domain.interfaces.map(\.conversationID)).count, 2)
        XCTAssertTrue(domain.interfaces.allSatisfy { $0.bot == existing })
        let first = try XCTUnwrap(domain.interfaces.first)
        domain.selectInterface(first.id, conversation: true)
        XCTAssertEqual(domain.selectedInterface?.specification, "後台")
    }

    func testCancellationAndInvalidBotDoNotCreateOrEraseDraft() {
        let preview = SpaceSetupPreviewState()
        let domain = preview.selectedDomain
        let bots = domain.bots
        domain.draft = "保留我的需求"
        domain.cancelBuilder()
        XCTAssertEqual(domain.bots, bots)
        XCTAssertTrue(domain.interfaces.isEmpty)
        XCTAssertEqual(domain.draft, "保留我的需求")
        domain.openBuilder()
        domain.chosenBotID = preview.domains[1].bots[0].id
        XCTAssertFalse(domain.canPreview)
        domain.previewResult()
        XCTAssertTrue(domain.interfaces.isEmpty)
        XCTAssertEqual(domain.bots, bots)
        XCTAssertEqual(domain.draft, "保留我的需求")
        XCTAssertNotNil(domain.validationMessage)
    }

    func testCapturedDomainRemainsOwnerAfterSwitch() {
        let preview = SpaceSetupPreviewState()
        let owner = preview.selectedDomain
        owner.draft = "原領域結果"
        preview.selectDomain(preview.domains[1].id)
        owner.previewResult()
        XCTAssertEqual(owner.interfaces.count, 1)
        XCTAssertTrue(preview.selectedDomain.interfaces.isEmpty)
        preview.selectedDomain.selectInterface(owner.interfaces[0].id)
        XCTAssertNil(preview.selectedDomain.selectedInterface)
    }

    func testTabOrderingAndDisablingStayInDomain() {
        let preview = SpaceSetupPreviewState()
        let domain = preview.selectedDomain
        domain.moveTab(.bot, before: .chat)
        XCTAssertEqual(domain.visibleTabs, [.bot, .chat, .cli])
        domain.toggle(.cli)
        XCTAssertEqual(domain.visibleTabs, [.bot, .chat])
        domain.toggle(.cli)
        XCTAssertEqual(domain.visibleTabs, [.bot, .chat, .cli])
        domain.moveTab(.cli, offset: -1)
        XCTAssertEqual(domain.visibleTabs, [.bot, .cli, .chat])
        for tab in SpaceSetupPreviewState.Tab.allCases { domain.toggle(tab) }
        XCTAssertTrue(domain.visibleTabs.isEmpty)
        domain.openBuilder() // All tabs disabled must not strand Settings/+add.
        XCTAssertTrue(domain.interfaces.isEmpty)
        XCTAssertEqual(preview.domains[1].visibleTabs, [.chat, .cli, .bot])
    }

    func testRunningTaskDefersDisableAndAllowsCancellation() {
        let domain = SpaceSetupPreviewState().selectedDomain
        domain.setPreviewTaskRunning(true, for: .bot)
        domain.toggle(.bot)
        XCTAssertFalse(domain.isRequestedEnabled(.bot))
        XCTAssertTrue(domain.visibleTabs.contains(.bot))
        XCTAssertTrue(domain.runningTabs.contains(.bot))
        XCTAssertTrue(domain.pendingDisabledTabs.contains(.bot))
        domain.toggle(.bot) // Cancel the pending disable, not the task.
        XCTAssertTrue(domain.isRequestedEnabled(.bot))
        XCTAssertTrue(domain.runningTabs.contains(.bot))
        XCTAssertTrue(domain.pendingDisabledTabs.isEmpty)
        domain.toggle(.bot)
        domain.setPreviewTaskRunning(false, for: .bot)
        XCTAssertFalse(domain.visibleTabs.contains(.bot))
        XCTAssertFalse(domain.runningTabs.contains(.bot))
        XCTAssertTrue(domain.pendingDisabledTabs.isEmpty)
        domain.setPreviewTaskRunning(true, for: .bot)
        XCTAssertFalse(domain.runningTabs.contains(.bot))
    }
}
