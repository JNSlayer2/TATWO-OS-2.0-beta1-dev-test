import Foundation

/// Navigation may update the committed URL while the user is drafting another.
/// Explicit submit, cancel and tab/session switches still replace the draft.
enum EmbeddedBrowserAddressPresentation {
    static func text(
        draft: String,
        navigationURL: String?,
        isEditing: Bool
    ) -> String {
        isEditing ? draft : navigationURL ?? ""
    }
}
