import Foundation
import XCTest
@testable import TatwoUltraworkMac

final class ChatRouteReceiptJournalTests: XCTestCase {
    func testCustomChatWorkingDirectoryRemainsUnmodified()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-route-journal-\(UUID().uuidString)",
                isDirectory: true)
        let chatWorkingDirectory = root
            .appendingPathComponent(
                "clean-demo-repo",
                isDirectory: true)
        let appSupport = root
            .appendingPathComponent(
                "app-support",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: chatWorkingDirectory,
            withIntermediateDirectories: true)
        let before = try relativeTree(at: chatWorkingDirectory)
        let journal = ChatRouteReceiptJournal(
            rootURL: appSupport)

        try journal.append(
            header: "# Claude route spawn journal\n\n",
            entry:
                "- workingDirectory: `\(chatWorkingDirectory.path)`\n")

        XCTAssertEqual(
            try relativeTree(at: chatWorkingDirectory),
            before)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: journal.receiptURL.path))
        XCTAssertTrue(
            journal.receiptURL.path.hasPrefix(
                appSupport.path + "/"))
        XCTAssertFalse(
            journal.receiptURL.path.hasPrefix(
                chatWorkingDirectory.path + "/"))
    }

    func testChatPageWriterDoesNotContainWorkspaceRelativeReceiptPath()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try ChatSourceFamily.read("ChatPageModel.swift")

        XCTAssertTrue(
            source.contains("ChatRouteReceiptJournal().append"))
        XCTAssertFalse(
            source.contains(
                "appendingPathComponent(\"docs/plans/receipts/round18-receipt.md\")"))
    }

    private func relativeTree(at root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil)
        else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return String(
                url.path.dropFirst(root.path.count))
        }.sorted()
    }
}
