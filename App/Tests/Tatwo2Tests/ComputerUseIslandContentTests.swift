import XCTest
@testable import Tatwo2

final class ComputerUseIslandContentTests: XCTestCase {
    func testExpandedWithoutPendingConsentUsesBlankTemplate() {
        XCTAssertEqual(
            ComputerUseIslandContentKind.select(isExpanded: true, hasPendingConsent: false),
            .blankTemplate
        )
    }

    func testExpandedPendingConsentUsesConsentCard() {
        XCTAssertEqual(
            ComputerUseIslandContentKind.select(isExpanded: true, hasPendingConsent: true),
            .consent
        )
    }

    func testExpandedWorkInboxUsesWorkContentWhenRequested() {
        XCTAssertEqual(
            ComputerUseIslandContentKind.select(isExpanded: true, hasPendingConsent: false, showsWork: true),
            .work
        )
    }

    func testConsentTakesPriorityOverWork() {
        XCTAssertEqual(
            ComputerUseIslandContentKind.select(isExpanded: true, hasPendingConsent: true, showsWork: true),
            .consent
        )
    }

    func testCollapsedHidesContentRegardlessOfConsent() {
        for hasPendingConsent in [false, true] {
            XCTAssertEqual(
                ComputerUseIslandContentKind.select(
                    isExpanded: false, hasPendingConsent: hasPendingConsent
                ),
                .collapsed
            )
        }
    }
}
