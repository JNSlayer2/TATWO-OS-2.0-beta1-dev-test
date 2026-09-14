import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoBrowserSessionPolicyTests: XCTestCase {
  func testOrdinaryTextBecomesPercentEncodedGoogleSearch() throws {
    let resolution = TatwoBrowserAddressResolver.resolve("  兩岸 AI safety & privacy  ")
    let url = try navigateURL(from: resolution)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "www.google.com")
    XCTAssertEqual(components.path, "/search")
    XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "兩岸 AI safety & privacy")])
    XCTAssertFalse(url.absoluteString.contains(" "))
    XCTAssertTrue(url.absoluteString.contains("%"))
  }

  func testExplicitHTTPAndHTTPSURLsNavigateDirectly() throws {
    let httpsURL = try navigateURL(
      from: TatwoBrowserAddressResolver.resolve("https://example.com/a?q=one%20two"))
    let httpURL = try navigateURL(
      from: TatwoBrowserAddressResolver.resolve("HTTP://example.com:8080/path"))

    XCTAssertEqual(httpsURL.absoluteString, "https://example.com/a?q=one%20two")
    XCTAssertEqual(httpURL.scheme?.lowercased(), "http")
    XCTAssertEqual(httpURL.host, "example.com")
    XCTAssertEqual(httpURL.port, 8080)
    XCTAssertEqual(httpURL.path, "/path")
  }

  func testBareHostnameNavigatesWithImplicitHTTPS() throws {
    let url = try navigateURL(from: TatwoBrowserAddressResolver.resolve("example.com"))

    XCTAssertEqual(url.absoluteString, "https://example.com")
  }

  func testSpaceSeparatedWordsRemainGoogleSearchText() throws {
    let url = try navigateURL(
      from: TatwoBrowserAddressResolver.resolve("hello world"))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "q" })?.value

    XCTAssertEqual(url.host, "www.google.com")
    XCTAssertEqual(query, "hello world")
  }

  func testIPv4AddressNavigatesWithImplicitHTTPS() throws {
    let url = try navigateURL(
      from: TatwoBrowserAddressResolver.resolve([192, 168, 1, 1].map(String.init).joined(separator: ".")))

    XCTAssertEqual(url.absoluteString, "https://" + [192, 168, 1, 1].map(String.init).joined(separator: "."))
  }

  func testHostPortNavigatesWhileOtherColonBearingTextRemainsSearch() throws {
    let hostPortURL = try navigateURL(
      from: TatwoBrowserAddressResolver.resolve("example.com:8443/path"))

    XCTAssertEqual(hostPortURL.scheme, "https")
    XCTAssertEqual(hostPortURL.host, "example.com")
    XCTAssertEqual(hostPortURL.port, 8443)
    XCTAssertEqual(hostPortURL.path, "/path")

    for input in [
      "swift: how to decode JSON",
      "localhost:3000",
      "mailto:someone@example.com",
    ] {
      let url = try navigateURL(from: TatwoBrowserAddressResolver.resolve(input))
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "q" })?.value

      XCTAssertEqual(url.host, "www.google.com", input)
      XCTAssertEqual(query, input, input)
    }
  }

  func testUnsafeAndCustomSchemesFailClosedInsteadOfSearching() {
    for input in [
      "file:///Users/example/private.txt",
      "javascript:alert(1)",
      "data:text/plain,secret",
      "custom-scheme://host/path",
      "CUSTOM+SCHEME://host/path",
    ] {
      XCTAssertEqual(
        TatwoBrowserAddressResolver.resolve(input),
        .reject(.unsupportedScheme),
        input)
    }
  }

  func testMalformedExplicitHTTPURLFailsClosed() {
    XCTAssertEqual(
      TatwoBrowserAddressResolver.resolve("https:///missing-host"),
      .reject(.malformedHTTPURL))
    XCTAssertEqual(
      TatwoBrowserAddressResolver.resolve("   "),
      .reject(.emptyInput))
  }

  func testSameSessionMapsToSamePersistentProfileAcrossReconstruction() throws {
    let first = try XCTUnwrap(TatwoBrowserProfileIdentity(sessionID: " thread-A "))
    let reconstructed = try XCTUnwrap(TatwoBrowserProfileIdentity(sessionID: "thread-A"))

    XCTAssertEqual(first, reconstructed)
    XCTAssertEqual(first.dataStoreIdentifier, reconstructed.dataStoreIdentifier)
  }

  func testDistinctAndCaseDistinctSessionsNeverShareProfileIdentity() throws {
    let original = try XCTUnwrap(TatwoBrowserProfileIdentity(sessionID: "thread-original"))
    let other = try XCTUnwrap(TatwoBrowserProfileIdentity(sessionID: "thread-other"))
    let caseDistinct = try XCTUnwrap(TatwoBrowserProfileIdentity(sessionID: "THREAD-ORIGINAL"))

    XCTAssertNotEqual(original.dataStoreIdentifier, other.dataStoreIdentifier)
    XCTAssertNotEqual(original.dataStoreIdentifier, caseDistinct.dataStoreIdentifier)
    XCTAssertNotEqual(other.dataStoreIdentifier, caseDistinct.dataStoreIdentifier)
  }

  func testBlankSessionCannotAcquirePersistentBrowserProfile() {
    XCTAssertNil(TatwoBrowserProfileIdentity(sessionID: " \n "))
  }

  func testEveryNewSessionStartsAtGoogle() {
    XCTAssertEqual(TatwoBrowserSessionPolicy.initialURL.absoluteString, "https://www.google.com/")
  }

  private func navigateURL(
    from resolution: TatwoBrowserAddressResolution
  ) throws -> URL {
    guard case let .navigate(url) = resolution else {
      XCTFail("Expected navigation, received \(resolution)")
      throw TestError.expectedNavigation
    }
    return url
  }

  private enum TestError: Error {
    case expectedNavigation
  }
}
