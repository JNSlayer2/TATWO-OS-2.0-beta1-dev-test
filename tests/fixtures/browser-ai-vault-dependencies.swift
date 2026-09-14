import Foundation

// Only unrelated browser-import dependencies are stubbed. The vault, CSV tokenizer,
// policy, coordinators and settings UI under test are the production sources.
struct BrowserImportReadResult<Item: Sendable>: Sendable {
    var items: [Item] = []
    var skipped = 0
}
enum BrowserImportError: Error { case tooLarge, invalidData }
enum ChromiumImporter {
    static func navigationURL(_ raw: String?) -> URL? {
        raw.flatMap(BrowserPasswordOrigin.normalized).flatMap(URL.init(string:))
    }
}
