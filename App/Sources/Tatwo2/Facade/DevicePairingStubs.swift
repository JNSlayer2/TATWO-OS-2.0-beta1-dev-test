import Foundation

// 來源：Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoDevicePairingV1.swift:297-327
// 只保留 R1 配對碼 engine 會拋出的同名錯誤；不搬 1.0 pairing state／proof／治理型別。
enum TatwoDevicePairingErrorV1: Error, LocalizedError, Equatable, Sendable {
    case invalidSeedFormat(String)
    case invalidTTL
    case emptyAuthority
    case seedEntropyUnavailable
    case seedMismatch
    case codeExpired
    case codeAlreadyConsumed
    case authorityMismatch

    var errorDescription: String? {
        switch self {
        case let .invalidSeedFormat(seed): "pairing seed format invalid: \(seed)"
        case .invalidTTL: "pairing TTL must be positive"
        case .emptyAuthority: "pairing authority primary/createdBy must be non-empty"
        case .seedEntropyUnavailable: "pairing seed entropy unavailable"
        case .seedMismatch: "pairing seed does not match the active request"
        case .codeExpired: "pairing code expired"
        case .codeAlreadyConsumed: "pairing code already consumed (replay rejected)"
        case .authorityMismatch: "pairing code authority primary/epoch mismatch"
        }
    }
}
