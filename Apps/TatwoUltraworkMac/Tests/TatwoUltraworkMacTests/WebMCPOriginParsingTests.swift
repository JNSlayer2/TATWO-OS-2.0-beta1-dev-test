import TatwoCEFBridge
import XCTest

@MainActor
final class WebMCPOriginParsingTests: XCTestCase {
    func testOriginParserIsExceptionSafeAndOnlyReturnsHTTPOrigins() throws {
        guard TatwoCEFRuntime.compiled else {
            throw XCTSkip("real CEF bridge was not compiled")
        }

        XCTAssertNil(TatwoCEFOriginForURLString(nil))
        XCTAssertNil(TatwoCEFOriginForURLString(""))
        XCTAssertNil(TatwoCEFOriginForURLString("wikipedia.org"))
        XCTAssertNil(TatwoCEFOriginForURLString("about:blank"))
        XCTAssertNil(TatwoCEFOriginForURLString(
            "data:text/plain,hello"))
        XCTAssertNil(TatwoCEFOriginForURLString(
            "https://wiki pedia.org/"))

        XCTAssertEqual(
            TatwoCEFOriginForURLString(
                "https://wikipedia.org/a path/with|invalid"),
            "https://wikipedia.org")
        XCTAssertEqual(
            TatwoCEFOriginForURLString(
                "http://wikipedia.org:80/wiki/Main_Page"),
            "http://wikipedia.org")
        XCTAssertEqual(
            TatwoCEFOriginForURLString(
                "https://wikipedia.org:8443/wiki/Main_Page"),
            "https://wikipedia.org:8443")
    }
}
