import XCTest
@testable import TatwoUltraworkMac

@MainActor
final class TatwoSparkleUpdateCoordinatorTests: XCTestCase {
    func testMissingFeedKeyOrChannelKeepsUpdaterDisabled() {
        let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
        let missingFeed = TatwoSparkleUpdateCoordinator(
            infoDictionary: [
                "SUPublicEDKey": publicKey,
                "TatwoUpdateChannel": "internal-canary",
                "SUEnableAutomaticChecks": true,
                "SUScheduledCheckInterval": 21_600,
                "SUAutomaticallyUpdate": false,
                "SUAllowsAutomaticUpdates": false
            ]
        )
        missingFeed.start()
        XCTAssertEqual(
            missingFeed.runtimeStatus,
            .disabled(.feedMissingOrInsecure)
        )

        let missingKey = TatwoSparkleUpdateCoordinator(
            infoDictionary: [
                "SUFeedURL": "https://updates.example.invalid/appcast.xml",
                "TatwoUpdateChannel": "stable",
                "SUEnableAutomaticChecks": true,
                "SUScheduledCheckInterval": 21_600,
                "SUAutomaticallyUpdate": false,
                "SUAllowsAutomaticUpdates": false
            ]
        )
        missingKey.start()
        XCTAssertEqual(
            missingKey.runtimeStatus,
            .disabled(.publicKeyMissing)
        )

        let missingChannel = TatwoSparkleUpdateCoordinator(
            infoDictionary: [
                "SUFeedURL": "https://updates.example.invalid/appcast.xml",
                "SUPublicEDKey": publicKey,
                "SUEnableAutomaticChecks": true,
                "SUScheduledCheckInterval": 21_600,
                "SUAutomaticallyUpdate": false,
                "SUAllowsAutomaticUpdates": false
            ]
        )
        missingChannel.start()
        XCTAssertEqual(
            missingChannel.runtimeStatus,
            .disabled(.channelMissingOrInvalid)
        )
    }

    func testValidSignedFeedStartsLaunchCheckAndSixHourScheduleWithoutAutoInstall() {
        let driver = RecordingSparkleUpdateDriver()
        let coordinator = TatwoSparkleUpdateCoordinator(
            infoDictionary: validConfiguration(),
            driverFactory: { _ in driver }
        )

        coordinator.start()

        XCTAssertEqual(coordinator.runtimeStatus, .active(channel: .internalCanary))
        XCTAssertEqual(
            driver.intervals,
            [TatwoSparkleUpdateConfiguration.scheduledCheckInterval]
        )
        XCTAssertEqual(driver.backgroundDownloads, [false])
        coordinator.checkForUpdatesFromUser()
        XCTAssertEqual(driver.userChecks, 1)
    }

    func testUnsafePlistOrUpdaterStartFailureStaysDisabled() {
        var unsafe = validConfiguration()
        unsafe["SUAutomaticallyUpdate"] = true
        let unsafeCoordinator = TatwoSparkleUpdateCoordinator(
            infoDictionary: unsafe
        )
        unsafeCoordinator.start()
        XCTAssertEqual(
            unsafeCoordinator.runtimeStatus,
            .disabled(.updateSafetyMissingOrUnsafe)
        )

        let driver = RecordingSparkleUpdateDriver()
        driver.startError = RecordingError.startFailed
        let failedStart = TatwoSparkleUpdateCoordinator(
            infoDictionary: validConfiguration(),
            driverFactory: { _ in driver }
        )
        failedStart.start()
        XCTAssertEqual(
            failedStart.runtimeStatus,
            .disabled(.updaterStartFailed)
        )
        failedStart.checkForUpdatesFromUser()
        XCTAssertEqual(driver.userChecks, 0)
    }

    func testCredentialedFragmentedOrNonCanonicalUpdateTrustIsRejected() {
        var credentialed = validConfiguration()
        credentialed["SUFeedURL"] =
            "https://user:password@updates.example.invalid/appcast.xml"
        let credentialedCoordinator = TatwoSparkleUpdateCoordinator(
            infoDictionary: credentialed
        )
        credentialedCoordinator.start()
        XCTAssertEqual(
            credentialedCoordinator.runtimeStatus,
            .disabled(.feedMissingOrInsecure)
        )

        var fragmented = validConfiguration()
        fragmented["SUFeedURL"] =
            "https://updates.example.invalid/appcast.xml#untrusted"
        let fragmentedCoordinator = TatwoSparkleUpdateCoordinator(
            infoDictionary: fragmented
        )
        fragmentedCoordinator.start()
        XCTAssertEqual(
            fragmentedCoordinator.runtimeStatus,
            .disabled(.feedMissingOrInsecure)
        )

        var nonCanonicalKey = validConfiguration()
        nonCanonicalKey["SUPublicEDKey"] =
            "\(Data(repeating: 7, count: 32).base64EncodedString())\n"
        let nonCanonicalKeyCoordinator = TatwoSparkleUpdateCoordinator(
            infoDictionary: nonCanonicalKey
        )
        nonCanonicalKeyCoordinator.start()
        XCTAssertEqual(
            nonCanonicalKeyCoordinator.runtimeStatus,
            .disabled(.publicKeyMissing)
        )
    }

    private func validConfiguration() -> [String: Any] {
        [
            "SUFeedURL": "https://updates.example.invalid/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "TatwoUpdateChannel": "internal-canary",
            "SUEnableAutomaticChecks": true,
            "SUScheduledCheckInterval": 21_600,
            "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false
        ]
    }
}

@MainActor
private final class RecordingSparkleUpdateDriver: TatwoSparkleUpdateDriving {
    private(set) var intervals: [TimeInterval] = []
    private(set) var backgroundDownloads: [Bool] = []
    private(set) var userChecks = 0
    var startError: Error?

    func startAndCheck(
        interval: TimeInterval,
        backgroundDownloadsEnabled: Bool
    ) throws {
        if let startError {
            throw startError
        }
        intervals.append(interval)
        backgroundDownloads.append(backgroundDownloadsEnabled)
    }

    func checkForUpdatesFromUser() {
        userChecks += 1
    }
}

private enum RecordingError: Error {
    case startFailed
}
