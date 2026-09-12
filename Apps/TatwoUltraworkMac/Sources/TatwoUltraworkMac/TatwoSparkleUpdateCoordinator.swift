import Foundation
import Sparkle

enum TatwoSparkleUpdateChannel: String, Equatable {
    case internalCanary = "internal-canary"
    case stable
}

struct TatwoSparkleUpdateConfiguration: Equatable {
    static let scheduledCheckInterval: TimeInterval = 6 * 60 * 60

    let feedURL: URL
    let publicEDKey: String
    let channel: TatwoSparkleUpdateChannel

    static func resolve(
        infoDictionary: [String: Any]?
    ) -> TatwoSparkleUpdateConfigurationResolution {
        guard let infoDictionary,
              let feedString = infoDictionary["SUFeedURL"] as? String,
              !feedString.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters
                    .union(.whitespacesAndNewlines)
                    .contains($0)
              }),
              let feedURL = URL(string: feedString),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              feedURL.user == nil,
              feedURL.password == nil,
              feedURL.fragment == nil
        else {
            return .disabled(.feedMissingOrInsecure)
        }
        guard let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
              let decodedPublicEDKey = Data(base64Encoded: publicEDKey),
              decodedPublicEDKey.count == 32,
              decodedPublicEDKey.base64EncodedString() == publicEDKey
        else {
            return .disabled(.publicKeyMissing)
        }
        guard let rawChannel = infoDictionary["TatwoUpdateChannel"] as? String,
              let channel = TatwoSparkleUpdateChannel(rawValue: rawChannel)
        else {
            return .disabled(.channelMissingOrInvalid)
        }
        guard infoDictionary["SUEnableAutomaticChecks"] as? Bool == true,
              let interval = infoDictionary["SUScheduledCheckInterval"] as? NSNumber,
              interval.doubleValue == scheduledCheckInterval,
              infoDictionary["SUAutomaticallyUpdate"] as? Bool == false,
              infoDictionary["SUAllowsAutomaticUpdates"] as? Bool == false
        else {
            return .disabled(.updateSafetyMissingOrUnsafe)
        }
        return .enabled(
            TatwoSparkleUpdateConfiguration(
                feedURL: feedURL,
                publicEDKey: publicEDKey,
                channel: channel
            )
        )
    }
}

enum TatwoSparkleUpdateDisabledReason: String, Equatable {
    case feedMissingOrInsecure
    case publicKeyMissing
    case channelMissingOrInvalid
    case updateSafetyMissingOrUnsafe
    case updaterStartFailed
}

enum TatwoSparkleUpdateConfigurationResolution: Equatable {
    case enabled(TatwoSparkleUpdateConfiguration)
    case disabled(TatwoSparkleUpdateDisabledReason)
}

enum TatwoSparkleUpdateRuntimeStatus: Equatable {
    case notStarted
    case disabled(TatwoSparkleUpdateDisabledReason)
    case active(channel: TatwoSparkleUpdateChannel)
}

@MainActor
protocol TatwoSparkleUpdateDriving: AnyObject {
    func startAndCheck(
        interval: TimeInterval,
        backgroundDownloadsEnabled: Bool
    ) throws
    func checkForUpdatesFromUser()
}

@MainActor
private final class TatwoSparkleStandardUpdateDriver:
    TatwoSparkleUpdateDriving
{
    private let controller: SPUStandardUpdaterController

    init(delegate: SPUUpdaterDelegate) {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    func startAndCheck(
        interval: TimeInterval,
        backgroundDownloadsEnabled: Bool
    ) throws {
        try controller.updater.start()
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = interval
        controller.updater.automaticallyDownloadsUpdates =
            backgroundDownloadsEnabled
        controller.updater.checkForUpdatesInBackground()
    }

    func checkForUpdatesFromUser() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class TatwoSparkleUpdateCoordinator: NSObject, SPUUpdaterDelegate {
    typealias DriverFactory = (SPUUpdaterDelegate) -> any TatwoSparkleUpdateDriving

    private let resolution: TatwoSparkleUpdateConfigurationResolution
    private let driverFactory: DriverFactory
    private var driver: (any TatwoSparkleUpdateDriving)?

    private(set) var runtimeStatus: TatwoSparkleUpdateRuntimeStatus = .notStarted

    init(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        driverFactory: @escaping DriverFactory = {
            TatwoSparkleStandardUpdateDriver(delegate: $0)
        }
    ) {
        resolution = TatwoSparkleUpdateConfiguration.resolve(
            infoDictionary: infoDictionary
        )
        self.driverFactory = driverFactory
        super.init()
    }

    func start() {
        guard case .enabled(let configuration) = resolution else {
            if case .disabled(let reason) = resolution {
                runtimeStatus = .disabled(reason)
            }
            return
        }

        let driver = driverFactory(self)
        do {
            try driver.startAndCheck(
                interval: TatwoSparkleUpdateConfiguration.scheduledCheckInterval,
                // Sparkle couples background download to silent install-on-quit.
                // Keep it off until TatwoUpdater can retain explicit user approval
                // after a verified background download.
                backgroundDownloadsEnabled: false
            )
        } catch {
            runtimeStatus = .disabled(.updaterStartFailed)
            return
        }
        self.driver = driver
        runtimeStatus = .active(channel: configuration.channel)
    }

    func checkForUpdatesFromUser() {
        driver?.checkForUpdatesFromUser()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard case .enabled(let configuration) = resolution else { return nil }
        return configuration.feedURL.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard case .enabled(let configuration) = resolution else { return [] }
        return [configuration.channel.rawValue]
    }
}
