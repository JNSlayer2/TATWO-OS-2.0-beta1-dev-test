import Foundation

/// The snapshot is persisted BEFORE either write. A reopened/failed submission is
/// never automatically retried: the user must first check the reported destinations.
struct DistillSubmission: Codable, Equatable, Sendable {
    var id = UUID()
    let threadID: UUID
    let content: String
    let title: String
    let slug: String
    let gbrain: Bool
    let skillet: Bool
    var message = "送出已開始；若中斷，請先查目的地，不會自動重送。"
}
