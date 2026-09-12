import TatwoUltraworkCore

struct TatwoChatCooldownGate: Equatable {
    let projection: TatwoGatewayCooldownProjectionV1
    let modelDisplayName: String

    var canDispatch: Bool { projection.dispatchAllowed }
    var canResume: Bool { projection.dispatchAllowed }

    var statusText: String {
        guard !projection.dispatchAllowed else { return "" }
        let reason = projection.record?.reason ?? projection.code
        if projection.state == .requiresProbe {
            return "\(modelDisplayName) 暫停：\(reason)。Work OS 健康探針與 contract 驗證完成前不可續跑。"
        }
        if let retryAtUTC = projection.retryAtUTC {
            return "\(modelDisplayName) 暫停：\(reason)。最早重試 \(retryAtUTC)，之後仍需 Work OS 健康探針。"
        }
        return "\(modelDisplayName) 暫停：\(reason)。此路線目前不可續跑。"
    }
}
