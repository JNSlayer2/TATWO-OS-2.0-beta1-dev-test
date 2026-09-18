import XCTest
@testable import Tatwo2

final class IslandWorkInboxTests: XCTestCase {
    @MainActor
    func testListAndFooterShareOneSnapshot() async {
        var snapshot = IslandWorkSnapshot(exceptions: (0..<6).map {
            .init(kind: .failed, title: "工作 \($0)", target: .init(threadID: UUID()),
                  since: Date(timeIntervalSince1970: Double($0)), hint: "需要查看原因")
        })
        let inbox = IslandExceptionsCount { snapshot }
        XCTAssertFalse(inbox.hasLoaded)
        await inbox.refresh(now: 10)
        XCTAssertTrue(inbox.hasLoaded)
        XCTAssertEqual(inbox.count, 6)
        XCTAssertEqual(inbox.data.exceptions.map(\.title), (0..<6).map { "工作 \($0)" })

        snapshot = .init()
        await inbox.refresh(now: 11)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertTrue(inbox.data.exceptions.isEmpty)
    }

    @MainActor
    func testDetachedBackgroundJobHasAnActionableRoute() async {
        let job = IslandWorkSnapshot.Item(kind: .failed, title: "背景工作",
                                           target: .init(jobID: UUID()), since: Date(), hint: "失敗")
        let inbox = IslandExceptionsCount { .init(exceptions: [job]) }
        await inbox.refresh(now: 10)
        XCTAssertEqual(inbox.data.exceptions.first?.jobID, job.jobID)
    }
}
