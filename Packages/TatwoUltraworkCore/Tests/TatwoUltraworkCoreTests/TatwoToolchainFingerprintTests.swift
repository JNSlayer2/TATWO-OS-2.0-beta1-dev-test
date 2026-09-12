import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoToolchainFingerprintTests: XCTestCase {
  private func fixture(
    swift: String = "6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)",
    xcodePath: String? = "/Applications/Xcode.app/Contents/Developer",
    xcodeVersion: String? = "Xcode 27.0 (27A5194q)",
    os: String = "macOS 27.0 (26A5353q)",
    arch: String = "arm64",
    host: String = "mini.local",
    ramGB: Int = 16,
    logicalCPU: Int = 10,
    generatedAt: String = "2026-07-30T00:00:00Z"
  ) -> TatwoToolchainFingerprintV1 {
    TatwoToolchainFingerprintV1(
      swiftVersion: swift,
      xcodePath: xcodePath,
      xcodeVersion: xcodeVersion,
      os: os,
      arch: arch,
      hostName: host,
      ramGB: ramGB,
      logicalCPU: logicalCPU,
      generatedAt: generatedAt)
  }

  private func encode(_ value: TatwoToolchainFingerprintV1) throws -> Data {
    try JSONEncoder().encode(value)
  }

  // MARK: - Decode

  func testDecodeRoundTripFromJSON() throws {
    let original = fixture()
    let data = try encode(original)
    let decoded = try TatwoToolchainFingerprintV1.decode(from: data)
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.schema, TatwoToolchainFingerprintV1.schemaName)
  }

  func testDecodeAllowsNullXcodeFields() throws {
    let json = """
    {
      "schema":"TatwoToolchainFingerprintV1",
      "swiftVersion":"6.3",
      "xcodePath":null,
      "xcodeVersion":null,
      "os":"macOS 15.0 (24A335)",
      "arch":"arm64",
      "hostName":"macbook.local",
      "ramGB":32,
      "logicalCPU":12,
      "generatedAt":"2026-07-30T12:00:00Z"
    }
    """
    let decoded = try TatwoToolchainFingerprintV1.decode(jsonUTF8: json)
    XCTAssertEqual(decoded.swiftVersion, "6.3")
    XCTAssertNil(decoded.xcodePath)
    XCTAssertNil(decoded.xcodeVersion)
    XCTAssertEqual(decoded.ramGB, 32)
    XCTAssertEqual(decoded.logicalCPU, 12)
  }

  func testDecodeRejectsEmptySwiftVersion() {
    let json = """
    {
      "schema":"TatwoToolchainFingerprintV1",
      "swiftVersion":"  ",
      "os":"macOS 15.0",
      "arch":"arm64",
      "hostName":"host",
      "ramGB":8,
      "logicalCPU":8,
      "generatedAt":"2026-07-30T12:00:00Z"
    }
    """
    XCTAssertThrowsError(try TatwoToolchainFingerprintV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoToolchainFingerprintErrorV1,
        .emptyField("swiftVersion"))
    }
  }

  func testDecodeRejectsNonPositiveRAM() {
    let json = """
    {
      "schema":"TatwoToolchainFingerprintV1",
      "swiftVersion":"6.4",
      "os":"macOS 15.0",
      "arch":"arm64",
      "hostName":"host",
      "ramGB":0,
      "logicalCPU":8,
      "generatedAt":"2026-07-30T12:00:00Z"
    }
    """
    XCTAssertThrowsError(try TatwoToolchainFingerprintV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoToolchainFingerprintErrorV1,
        .nonPositiveField("ramGB"))
    }
  }

  func testDecodeRejectsWrongSchema() {
    let json = """
    {
      "schema":"OtherV1",
      "swiftVersion":"6.4",
      "os":"macOS 15.0",
      "arch":"arm64",
      "hostName":"host",
      "ramGB":8,
      "logicalCPU":8,
      "generatedAt":"2026-07-30T12:00:00Z"
    }
    """
    XCTAssertThrowsError(try TatwoToolchainFingerprintV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoToolchainFingerprintErrorV1,
        .schemaMismatch("OtherV1"))
    }
  }

  // MARK: - matches

  func testMatchesCompatibleSameSwiftAndXcode() {
    let a = fixture(host: "mini.local", generatedAt: "2026-07-30T01:00:00Z")
    let b = fixture(host: "macbook.local", generatedAt: "2026-07-30T02:00:00Z")
    let match = a.matches(b)
    XCTAssertEqual(match, .compatible)
    XCTAssertTrue(match.isCompatible)
    XCTAssertFalse(match.isDegraded)
    XCTAssertTrue(a.isSameFingerprintClass(as: b))
    XCTAssertNil(match.environmentSkewLabel)
  }

  func testMatchesDegradedWhenXcodeVersionDiffers() {
    // Motivation: mini Xcode 27 beta vs MacBook release toolchain packaging —
    // same Swift primary still degraded-compatible, not hard fail.
    let mini = fixture(
      swift: "6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)",
      xcodePath: "/tmp/tatwo2-fixture/Applications/XCODE/Xcode-27.0.0-Beta.app/Contents/Developer",
      xcodeVersion: "Xcode 27.0 (27A5194q)",
      host: "Mac-mini.local")
    let book = fixture(
      swift: "6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)",
      xcodePath: "/Applications/Xcode.app/Contents/Developer",
      xcodeVersion: "Xcode 16.4 (16F6)",
      host: "MacBook.local")
    let match = mini.matches(book)
    XCTAssertEqual(match, .degradedCompatible)
    XCTAssertTrue(match.isCompatible)
    XCTAssertTrue(match.isDegraded)
    XCTAssertTrue(mini.isSameFingerprintClass(as: book))
    XCTAssertEqual(match.environmentSkewLabel, "environment_skew_degraded")
  }

  func testMatchesDegradedWhenOneSideMissingXcode() {
    let withXcode = fixture(xcodePath: "/A", xcodeVersion: "Xcode 27.0")
    let without = fixture(xcodePath: nil, xcodeVersion: nil)
    XCTAssertEqual(withXcode.matches(without), .degradedCompatible)
  }

  func testMatchesMismatchOnSwiftVersion() {
    let mini = fixture(swift: "6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)")
    let book = fixture(swift: "6.3")
    let match = mini.matches(book)
    XCTAssertEqual(match, .mismatch)
    XCTAssertFalse(match.isCompatible)
    XCTAssertFalse(mini.isSameFingerprintClass(as: book))
    XCTAssertEqual(match.environmentSkewLabel, "environment_skew")
    XCTAssertTrue(
      TatwoToolchainEnvironmentSkewPolicyV1.treatDivergenceAsEnvironment(lhs: mini, rhs: book))
  }

  func testCompatibilityKeyIgnoresHostName() {
    let a = fixture(host: "a.local", generatedAt: "2026-01-01T00:00:00Z")
    let b = fixture(host: "b.local", generatedAt: "2026-12-31T23:59:59Z")
    XCTAssertEqual(a.compatibilityKey, b.compatibilityKey)
    XCTAssertNotEqual(a.hostName, b.hostName)
  }

  func testLogSummaryFormat() {
    let fp = fixture(swift: "6.4", host: "mini.local")
    XCTAssertEqual(fp.logSummary, "6.4@mini.local")
  }

  func testEnvironmentSkewPolicyClassify() {
    let a = fixture(swift: "6.4")
    let b = fixture(swift: "6.3")
    XCTAssertEqual(
      TatwoToolchainEnvironmentSkewPolicyV1.classify(lhs: a, rhs: b),
      .mismatch)
    let c = fixture(swift: "6.4", xcodeVersion: "Xcode 16")
    let d = fixture(swift: "6.4", xcodeVersion: "Xcode 27")
    XCTAssertEqual(
      TatwoToolchainEnvironmentSkewPolicyV1.classify(lhs: c, rhs: d),
      .degradedCompatible)
  }
}
