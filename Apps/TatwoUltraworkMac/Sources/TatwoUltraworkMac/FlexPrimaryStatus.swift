import Foundation

// 讀取彈性主權狀態（scripts/tatwo-device-sync.sh 的 primary.json + 本機設備身分）。
// 純唯讀，不 spawn Process；設定主設備仍走複製命令（與同步版本/資料庫一致）。

struct TatwoFlexPrimaryState: Equatable {
    let localDeviceName: String
    let currentPrimaryName: String?
    let epoch: Int?
    let changedAt: Date?

    var isLocalPrimary: Bool {
        guard let currentPrimaryName else { return false }
        return currentPrimaryName == localDeviceName
    }

    var isAssigned: Bool { currentPrimaryName != nil }
}

enum TatwoFlexPrimaryReader {
    static func read(
        appSupportRoot: URL = DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
    ) -> TatwoFlexPrimaryState {
        let localName = readLocalDeviceName(appSupportRoot: appSupportRoot)
        let primaryURL = appSupportRoot
            .appendingPathComponent("device-sync-channel", isDirectory: true)
            .appendingPathComponent("primary.json", isDirectory: false)

        guard
            let data = try? Data(contentsOf: primaryURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String
        else {
            return TatwoFlexPrimaryState(
                localDeviceName: localName,
                currentPrimaryName: nil,
                epoch: nil,
                changedAt: nil
            )
        }

        let epoch = (object["epoch"] as? NSNumber)?.intValue
        let changedAt = (object["changedAt"] as? String).flatMap { string in
            ISO8601DateFormatter().date(from: string)
        }
        return TatwoFlexPrimaryState(
            localDeviceName: localName,
            currentPrimaryName: name,
            epoch: epoch,
            changedAt: changedAt
        )
    }

    private static func readLocalDeviceName(appSupportRoot: URL) -> String {
        let identityURL = appSupportRoot.appendingPathComponent(
            "device-identity.json",
            isDirectory: false
        )
        if
            let data = try? Data(contentsOf: identityURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String,
            !name.isEmpty
        {
            return name
        }
        return ProcessInfo.processInfo.hostName
            .split(separator: ".")
            .first
            .map(String.init) ?? "此設備"
    }
}
