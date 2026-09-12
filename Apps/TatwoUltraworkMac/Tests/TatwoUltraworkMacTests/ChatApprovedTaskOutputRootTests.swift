import XCTest
@testable import TatwoUltraworkMac

final class ChatApprovedTaskOutputRootTests: XCTestCase {
    private let fileManager = FileManager.default

    func testApprovesUniqueDescendantAndReturnsOnlyCanonicalTarget() {
        XCTAssertEqual(
            ChatApprovedTaskOutputRoot.resolve(
                in: """
                請只寫入 \(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/session-main-plan-plg-terra-r2
                並建立三個檔案。
                """),
            .approved(
                targetPath:
                    "\(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/session-main-plan-plg-terra-r2"))
    }

    func testRejectsTraversalOutsideAllowlist() {
        XCTAssertEqual(
            ChatApprovedTaskOutputRoot.resolve(
                in:
                    "寫到 \(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/../../outside"),
            .invalid)
    }

    func testMultipleTargetsFailClosedAsAmbiguous() {
        let resolution = ChatApprovedTaskOutputRoot.resolve(
            in: """
            \(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/one
            \(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/two
            """)
        guard case .ambiguous(let paths) = resolution else {
            return XCTFail("expected ambiguous resolution")
        }
        XCTAssertEqual(paths.count, 2)
    }

    func testUnconfirmedTextHasNoCapabilityByItself() {
        XCTAssertEqual(
            ChatApprovedTaskOutputRoot.resolve(in: "請在一般專案工作"),
            .none)
    }

    func testRejectsExistingSymlinkEscape() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let escape = fixture.root.appendingPathComponent(
            "escape",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: escape,
            withDestinationURL: fixture.outside)

        XCTAssertEqual(
            resolve(
                path: escape.appendingPathComponent("existing").path,
                root: fixture.root),
            .invalid)
    }

    func testRejectsNonexistentChildUnderEscapingSymlink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let escape = fixture.root.appendingPathComponent(
            "escape",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: escape,
            withDestinationURL: fixture.outside)

        XCTAssertEqual(
            resolve(
                path: escape
                    .appendingPathComponent("not-created")
                    .appendingPathComponent("child")
                    .path,
                root: fixture.root),
            .invalid)
    }

    func testRejectsChainedSymlinkEscape() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let second = fixture.root.appendingPathComponent(
            "second",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: second,
            withDestinationURL: fixture.outside)
        let first = fixture.root.appendingPathComponent(
            "first",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: first,
            withDestinationURL: second)

        XCTAssertEqual(
            resolve(
                path: first.appendingPathComponent("existing").path,
                root: fixture.root),
            .invalid)
    }

    func testRejectsDanglingSymlinkEscape() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let missingOutside = fixture.outside.appendingPathComponent(
            "not-created",
            isDirectory: true)
        let escape = fixture.root.appendingPathComponent(
            "dangling-escape",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: escape,
            withDestinationURL: missingOutside)

        XCTAssertEqual(
            resolve(
                path: escape.appendingPathComponent("future").path,
                root: fixture.root),
            .invalid)
    }

    func testRejectsInRootSymlinkByExplicitFailClosedPolicy() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let realDirectory = fixture.root.appendingPathComponent(
            "real",
            isDirectory: true)
        try fileManager.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent(
            "alias",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: alias,
            withDestinationURL: realDirectory)

        XCTAssertEqual(
            resolve(
                path: alias.appendingPathComponent("future").path,
                root: fixture.root),
            .invalid)
    }

    func testNormalizesSymlinkedRootBeforeAuthorizingCandidate() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let rootAlias = fixture.container.appendingPathComponent(
            "root-alias",
            isDirectory: true)
        try fileManager.createSymbolicLink(
            at: rootAlias,
            withDestinationURL: fixture.root)

        XCTAssertEqual(
            resolve(
                path: rootAlias.appendingPathComponent("future").path,
                root: rootAlias),
            .approved(
                targetPath:
                    fixture.root.appendingPathComponent("future").path))
    }

    func testApprovedTargetDoesNotAuthorizeSibling() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let target = fixture.root.appendingPathComponent(
            "job-a",
            isDirectory: true)
        let sibling = fixture.root.appendingPathComponent(
            "job-b",
            isDirectory: true)

        let resolution = resolve(path: target.path, root: fixture.root)
        guard case let .approved(targetPath) = resolution else {
            return XCTFail("expected one approved target")
        }
        XCTAssertEqual(targetPath, target.path)
        XCTAssertFalse(
            sibling.path == targetPath
                || sibling.path.hasPrefix(targetPath + "/"))
    }

    func testRevalidationRejectsApprovedTargetReplacedBySymlink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }
        let target = fixture.root.appendingPathComponent(
            "job-a",
            isDirectory: true)
        guard case let .approved(targetPath) = resolve(
            path: target.path,
            root: fixture.root)
        else {
            return XCTFail("expected initial approval")
        }

        try fileManager.createSymbolicLink(
            at: target,
            withDestinationURL: fixture.outside)

        XCTAssertNil(
            ChatApprovedTaskOutputRoot.revalidatedWritableTarget(
                targetPath,
                allowlistRoot: fixture.root,
                fileManager: fileManager))
    }

    func testRejectsMissingOrNonDirectoryAllowlistRoot() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.container) }

        let missingRoot = fixture.container.appendingPathComponent(
            "missing-root",
            isDirectory: true)
        XCTAssertEqual(
            resolve(
                path: missingRoot.appendingPathComponent("child").path,
                root: missingRoot),
            .invalid)
    }

    private func resolve(path: String, root: URL)
        -> ChatApprovedTaskOutputRoot.Resolution
    {
        ChatApprovedTaskOutputRoot.resolve(
            in: "請只寫入 \(path)\n",
            allowlistRoot: root,
            fileManager: fileManager)
    }

    private func makeFixture() throws -> (
        container: URL,
        root: URL,
        outside: URL
    ) {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ChatApprovedTaskOutputRootTests-\(UUID().uuidString)",
                isDirectory: true)
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent(
            "outside",
            isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: outside.appendingPathComponent("existing"),
            withIntermediateDirectories: true)
        return (container, root, outside)
    }
}
