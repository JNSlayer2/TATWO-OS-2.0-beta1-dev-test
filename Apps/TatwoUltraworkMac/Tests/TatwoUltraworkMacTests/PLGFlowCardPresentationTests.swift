import Foundation
import XCTest
@testable import TatwoUltraworkMac

final class PLGFlowCardPresentationTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot(fromTestFile: #filePath)
    }

    func testTwentyBranchesStartCollapsed() {
        let ids = (0..<20).map { _ in UUID() }
        let state = PLGBranchAccordionState()

        XCTAssertNil(state.expandedBranchID)
        XCTAssertFalse(ids.contains(where: state.isExpanded))
    }

    func testOnlyOneBranchExpandsAndSecondClickCollapsesIt() {
        let first = UUID()
        let second = UUID()
        var state = PLGBranchAccordionState()

        state.toggle(first)
        XCTAssertTrue(state.isExpanded(first))
        XCTAssertFalse(state.isExpanded(second))

        state.toggle(second)
        XCTAssertFalse(state.isExpanded(first))
        XCTAssertTrue(state.isExpanded(second))

        state.toggle(second)
        XCTAssertNil(state.expandedBranchID)
    }

    func testReconcileClearsRemovedSelectionButPreservesReorderedSelection() {
        let first = UUID()
        let second = UUID()
        var state = PLGBranchAccordionState(expandedBranchID: second)

        state.reconcile(validIDs: [second, first])
        XCTAssertEqual(state.expandedBranchID, second)

        state.reconcile(validIDs: [first])
        XCTAssertNil(state.expandedBranchID)
    }

    func testSourceKeepsBranchDetailsBehindCompactAccordion() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift"),
            encoding: .utf8)
        let row = try XCTUnwrap(
            source.slice(
                from: "private func branchRow(",
                through: "private func branchDetail("))
        let detail = try XCTUnwrap(
            source.slice(
                from: "private func branchDetail(",
                through: "private func branchPresentation("))

        XCTAssertTrue(source.contains("@State private var branchAccordionState"))
        XCTAssertTrue(source.contains("branchAccordionState.reconcile(validIDs: validIDs)"))
        XCTAssertTrue(row.contains("branchAccordionState.toggle(branch.id)"))
        XCTAssertTrue(row.contains("if isExpanded"))
        XCTAssertTrue(row.contains("minHeight: 48"))
        XCTAssertTrue(row.contains("maxHeight: 48"))
        XCTAssertGreaterThanOrEqual(
            row.components(separatedBy: ".lineLimit(1)").count - 1,
            3)
        XCTAssertTrue(row.contains(#""收合" : "展開""#))
        XCTAssertTrue(row.contains("branchStatusLabel(presentation.visualStatus)"))
        XCTAssertTrue(detail.contains("presentation.receipt"))
        XCTAssertTrue(detail.contains("branch.planSlice"))
        XCTAssertTrue(detail.contains("branch.reason"))
        XCTAssertFalse(source.contains("branchStatusLabel(branch.status)"))
        XCTAssertFalse(source.contains("branchColor(branch.status)"))
    }

    func testPlanConfirmationKeepsAnExplicitComputerUseAndKeyboardAction() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/PLGFlowCard.swift"),
            encoding: .utf8)
        let planning = try XCTUnwrap(
            source.slice(
                from: "case .planning:",
                through: "case .leadAdversarial:"))

        XCTAssertTrue(planning.contains(#".accessibilityIdentifier("plg-confirm-plan")"#))
        XCTAssertTrue(
            planning.contains(
                ".keyboardShortcut(.return, modifiers: [.command, .shift])"))
        XCTAssertTrue(planning.contains(".contentShape(Capsule())"))
    }
}
