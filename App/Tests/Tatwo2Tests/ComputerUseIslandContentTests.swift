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
