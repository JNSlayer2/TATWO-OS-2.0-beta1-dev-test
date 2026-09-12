import XCTest
@testable import TatwoUltraworkMac

final class DeviceEnrollmentCommandTests: XCTestCase {
    func testEnrollmentCommandRequiresExplicitPrivateChannelRemote() {
        XCTAssertNil(
            TatwoDeviceEnrollmentCommand.command(
                deviceName: "macbook",
                pairingSeed: "PAIR1234",
                channelRemote: ""
            )
        )
        XCTAssertNil(
            TatwoDeviceEnrollmentCommand.command(
                deviceName: "macbook",
                pairingSeed: "PAIR1234",
                channelRemote: "https://github.com/tatwo214/hot-sync.git"
            )
        )
    }

    func testEnrollmentCommandCarriesPrivateRemoteAndQuotesValues() throws {
        let command = try XCTUnwrap(
            TatwoDeviceEnrollmentCommand.command(
                deviceName: "macbook-m3",
                pairingSeed: "PAIR1234",
                channelRemote: "git@sync-host:tatwo/hot-sync.git"
            )
        )

        XCTAssertTrue(command.contains("--name 'macbook-m3'"))
        XCTAssertTrue(command.contains("--pairing-seed 'PAIR1234'"))
        XCTAssertTrue(
            command.contains("--channel-remote 'git@sync-host:tatwo/hot-sync.git'")
        )
    }
}
