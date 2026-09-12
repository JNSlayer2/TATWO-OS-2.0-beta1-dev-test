import XCTest
@testable import Tatwo2

/// Exercises the real model/store entrypoints with the existing in-process
/// transport hook. This is not evidence of an external provider response.
@MainActor
final class SpaceSubmissionTests: XCTestCase {
    private func fixture() async throws -> (ChatPageModel, BotLibrary) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-space-submission-\(UUID().uuidString)")
        let store = BotStore(root: root)
        await store.library.ready()
        try await store.library.saveSpaces([
            .init(id: "tattoo", name: "刺青", density: "full", ownerBotID: "shared")
        ])
        let environment = ["TATWO2_LIVE_ROOT": root.path,
                           "TATWO2_ENGINES_ROOT": root.appendingPathComponent("engines").path]
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root), environment: environment)
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, store))
        return (model, store.library)
    }

    func testExistingBotInterfacesAndFollowupRetryUseOwnedConversations() async throws {
        let (model, library) = try await fixture()
        _ = try await library.create(.init(id: "shared", name: "Bot", emoji: "🤖",
            role: "assistant", engine: "codex", workdir: library.root.path,
            spaceIDs: ["tattoo"]), instructions: "")
        var dispatched: [UUID] = []
        model.botSendTestHook = { threadID, _, _ in dispatched.append(threadID) }
        let route = try XCTUnwrap(ChatRouteChoice.all.first { $0.brandGroup == .openAI })
        var interfaces: [SpaceWorkInterfaceRecord] = []
        for name in ["後台", "預約"] {
            let draft = try await library.updateSpaceDomain(id: "tattoo") {
                $0.draft = SpaceBuilderDraft(text: name, existingBotID: "shared")
            }
            interfaces.append(try await model.submitSpaceInterface(spaceID: "tattoo",
                draftID: draft.draft.id, name: name, route: route,
                workdir: library.root.path, permission: .askFirst))
        }
        XCTAssertEqual(library.list().count, 1)
        XCTAssertEqual(Set(dispatched).count, 2)
        XCTAssertEqual(dispatched, interfaces.map(\.conversationID))
        let requestID = UUID()
        for _ in 0..<2 {
            try await model.sendSpaceFollowup(spaceID: "tattoo", interfaceID: interfaces[0].id,
                requestID: requestID, text: "後續需求")
        }
        XCTAssertEqual(dispatched.count, 3, "Accepted retry must not send twice.")
        XCTAssertEqual(dispatched.last, interfaces[0].conversationID)
        XCTAssertTrue(library.snapshot.sessions["shared"]?.isEmpty ?? true)
    }

    func testDedicatedBotRetryRetainsIdentityAndForeignSpaceCannotSend() async throws {
        let (model, library) = try await fixture()
        var sends = 0
        model.botSendTestHook = { _, _, _ in sends += 1 }
        let route = try XCTUnwrap(ChatRouteChoice.all.first { $0.brandGroup == .openAI })
        let domain = try await library.updateSpaceDomain(id: "tattoo") { $0.draft.text = "搭建後台" }
        let first = try await model.submitSpaceInterface(spaceID: "tattoo",
            draftID: domain.draft.id, name: "後台", route: route,
            workdir: library.root.path, permission: .askFirst)
        let retry = try await model.submitSpaceInterface(spaceID: "tattoo",
            draftID: domain.draft.id, name: "後台", route: route,
            workdir: library.root.path, permission: .askFirst)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(library.list().count, 1)
        XCTAssertEqual(sends, 1)
        XCTAssertNil(model.sendAsBot(botID: first.botID, text: "不得串台",
            spaceID: "admin", interfaceID: first.id))
        XCTAssertEqual(sends, 1)
    }
}
