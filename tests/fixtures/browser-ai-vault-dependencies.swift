import Foundation
import SwiftUI

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

// W54 values are provided by the exact production token block in the test runner.
enum LiquidGlassTokens {}
