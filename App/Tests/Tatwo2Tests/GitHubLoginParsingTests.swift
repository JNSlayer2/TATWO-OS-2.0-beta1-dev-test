import XCTest
@testable import Tatwo2

final class GitHubLoginParsingTests: XCTestCase {
    func testFinderEnvironmentIncludesHomebrew() {
        let environment = GitHubAccountsStore.commandEnvironment(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertTrue(environment["PATH"]!.components(separatedBy: ":").contains("/opt/homebrew/bin"))
        XCTAssertTrue(environment["PATH"]!.components(separatedBy: ":").contains("/usr/local/bin"))
    }

    func testCallerGHExecutableWinsOverFallbacks() throws {
        let fixtureRoot = ProcessInfo.processInfo.environment["TATWO_GITHUB_TEST_ROOT"]
            ?? FileManager.default.currentDirectoryPath + "/evidence/github-login-tests"
        let directory = URL(fileURLWithPath: fixtureRoot).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("gh")
        try Data("#!/bin/sh\necho fixture-gh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "--version"]
        process.environment = GitHubAccountsStore.commandEnvironment(["PATH": directory.path])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture-gh\n")
    }

    func testCommandEnvironmentPreservesCallerPriorityAndOtherValues() {
        let original = ["PATH": "/fixture/bin:/usr/local/bin:/usr/bin", "GH_CONFIG_DIR": "/fixture/config"]
        let environment = GitHubAccountsStore.commandEnvironment(original)
        XCTAssertTrue(environment["PATH"]!.hasPrefix(original["PATH"]! + ":"))
        XCTAssertEqual(environment["GH_CONFIG_DIR"], original["GH_CONFIG_DIR"])
        XCTAssertEqual(environment["PATH"]!.components(separatedBy: ":").filter { $0 == "/usr/local/bin" }.count, 1)
        XCTAssertEqual(GitHubAccountsStore.commandEnvironment(environment), environment)
    }

    func testMissingPATHReceivesCLISearchDirectories() {
        let environment = GitHubAccountsStore.commandEnvironment([:])
        XCTAssertTrue(environment["PATH"]!.components(separatedBy: ":").contains("/usr/bin"))
        XCTAssertFalse(environment["PATH"]!.hasPrefix(":"))
    }

    func testGHDeviceLoginSampleWithoutTrailingNewline() {
        let output = """
        ! First copy your one-time code: 1234-ABCD
        Press Enter to open https://github.com/login/device in your browser...
        """
        let parsed = GitHubAccountsStore.parseLoginOutput(output)
        XCTAssertEqual(parsed.deviceCode, "1234-ABCD")
        XCTAssertEqual(parsed.verificationURL?.absoluteString, "https://github.com/login/device")
    }

    func testCodeOnlyAndPromptOnly() {
        let code = GitHubAccountsStore.parseLoginOutput("! First copy your one-time code: ABCD-5678")
        XCTAssertEqual(code.deviceCode, "ABCD-5678")
        XCTAssertNil(code.verificationURL)
        let prompt = GitHubAccountsStore.parseLoginOutput(
            "Press Enter to open https://github.com/login/device in your browser...", isComplete: false)
        XCTAssertNil(prompt.deviceCode)
        XCTAssertEqual(prompt.verificationURL?.absoluteString, "https://github.com/login/device")
    }

    func testANSIColorsAndWrappedURL() {
        let parsed = GitHubAccountsStore.parseLoginOutput(
            "! First copy your one-time code: \u{1B}[1;33m1234-ABCD\u{1B}[0m\r\n"
                + "Press Enter to open <https://github.com/login/device> in your browser...")
        XCTAssertEqual(parsed.deviceCode, "1234-ABCD")
        XCTAssertEqual(parsed.verificationURL?.absoluteString, "https://github.com/login/device")
    }

    func testFirstCodeAndURLWin() {
        let parsed = GitHubAccountsStore.parseLoginOutput(
            "1234-ABCD 5678-EFGH https://github.com/login/device https://example.com/help")
        XCTAssertEqual(parsed.deviceCode, "1234-ABCD")
        XCTAssertEqual(parsed.verificationURL?.absoluteString, "https://github.com/login/device")
    }

    func testNoCodeOrURLInUnrelatedOutput() {
        for output in ["", "gh auth login failed", "123-ABCD", "1234-abcD",
                       "X1234-ABCD", "1234-ABCDX", "ftp://github.com/login/device"] {
            let parsed = GitHubAccountsStore.parseLoginOutput(output)
            XCTAssertNil(parsed.deviceCode, output)
            XCTAssertNil(parsed.verificationURL, output)
        }
    }

    func testBufferedChunkBoundariesDoNotLoseCodeOrOpenTruncatedURL() {
        var buffered = "! First copy your one-time code: 1234-"
        XCTAssertNil(GitHubAccountsStore.parseLoginOutput(buffered, isComplete: false).deviceCode)
        buffered += "ABCD\nPress Enter to open https://github.com/login/dev"
        let partial = GitHubAccountsStore.parseLoginOutput(buffered, isComplete: false)
        XCTAssertEqual(partial.deviceCode, "1234-ABCD")
        XCTAssertNil(partial.verificationURL)
        buffered += "ice in your browser..."
        XCTAssertEqual(
            GitHubAccountsStore.parseLoginOutput(buffered, isComplete: false).verificationURL?.absoluteString,
            "https://github.com/login/device")
    }

    func testBareURLAtEndOfCompletedOutput() {
        let output = "https://github.com/login/device"
        XCTAssertNil(GitHubAccountsStore.parseLoginOutput(output, isComplete: false).verificationURL)
        XCTAssertEqual(
            GitHubAccountsStore.parseLoginOutput(output).verificationURL?.absoluteString, output)
    }

    func testSubmitWithoutActiveLoginReturnsFalse() {
        let store = GitHubAccountsStore(environment: [:])
        XCTAssertFalse(store.submitLoginInput(""))
        XCTAssertFalse(store.submitLoginInput("1234-ABCD"))
    }
}
