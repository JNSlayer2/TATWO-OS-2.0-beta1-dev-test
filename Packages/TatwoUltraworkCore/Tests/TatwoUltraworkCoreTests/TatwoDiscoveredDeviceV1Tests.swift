import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDiscoveredDeviceV1Tests: XCTestCase {
  private func sampleDevice(
    transport: TatwoDiscoveredTransportV1 = .usb,
    name: String = "ESD360C",
    fingerprint: String = "sha256:98542df8279a60c512257d00c122db107f75f3ab600ef053bc3963f4be9ec01c",
    trustState: String = "untrusted"
  ) -> TatwoDiscoveredDeviceV1 {
    TatwoDiscoveredDeviceV1(
      transport: transport,
      name: name,
      identityFingerprint: fingerprint,
      interfaces: ["usb", "location:0x01200000"],
      capabilitiesObserved: ["usb-device", "hardware-type:Removable"],
      storageGB: nil,
      cpuGpuMemory: nil,
      powerThermal: nil,
      trustState: trustState)
  }

  private func encode(_ value: TatwoDiscoveredDeviceV1) throws -> Data {
    try JSONEncoder().encode(value)
  }

  // MARK: - Decode

  func testDecodeRoundTrip() throws {
    let original = sampleDevice()
    let decoded = try TatwoDiscoveredDeviceV1.decode(from: try encode(original))
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.schema, TatwoDiscoveredDeviceV1.schemaName)
    XCTAssertEqual(decoded.trustState, "untrusted")
  }

  func testDecodeScriptShapedJSON() throws {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "thunderbolt",
      "name": "Peer MacBook",
      "identityFingerprint": "sha256:30ff7850a160696ad27d0f22c5d8cf8f385484469f442455622fd5bc85f078f0",
      "interfaces": ["thunderbolt"],
      "capabilitiesObserved": ["thunderbolt-device"],
      "storageGB": null,
      "cpuGpuMemory": null,
      "powerThermal": null,
      "trustState": "untrusted"
    }
    """
    let decoded = try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)
    XCTAssertEqual(decoded.transport, .thunderbolt)
    XCTAssertEqual(decoded.name, "Peer MacBook")
    XCTAssertFalse(decoded.hasUnstableIdentity)
    XCTAssertNil(decoded.storageGB)
    XCTAssertNil(decoded.cpuGpuMemory)
    XCTAssertNil(decoded.powerThermal)
  }

  func testDecodeUnstableFingerprintWithoutSerial() throws {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "usb",
      "name": "Cruzer",
      "identityFingerprint": "unstable:9b93524b943329fe9f7d135ca2a533def5f20699664c3adf22349997653eaa2d",
      "interfaces": ["usb"],
      "capabilitiesObserved": ["usb-device"],
      "storageGB": null,
      "cpuGpuMemory": null,
      "powerThermal": null,
      "trustState": "untrusted"
    }
    """
    let decoded = try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)
    XCTAssertTrue(decoded.hasUnstableIdentity)
    XCTAssertFalse(decoded.canBeManaged)
  }

  func testDecodeBonjourNullTelemetry() throws {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "bonjour",
      "name": "studio Pro",
      "identityFingerprint": "unstable:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "interfaces": ["bonjour", "_workstation._tcp", "local"],
      "capabilitiesObserved": ["bonjour-service:_workstation._tcp", "claimed-untrusted"],
      "storageGB": null,
      "cpuGpuMemory": null,
      "powerThermal": null,
      "trustState": "untrusted"
    }
    """
    let decoded = try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)
    XCTAssertEqual(decoded.transport, .bonjour)
    XCTAssertNil(decoded.cpuGpuMemory)
    XCTAssertNil(decoded.powerThermal)
  }

  func testDecodeRejectsWrongSchema() {
    let json = """
    {
      "schema": "OtherV1",
      "transport": "usb",
      "name": "x",
      "identityFingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "interfaces": [],
      "capabilitiesObserved": [],
      "trustState": "untrusted"
    }
    """
    XCTAssertThrowsError(try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(error as? TatwoDiscoveredDeviceErrorV1, .schemaMismatch("OtherV1"))
    }
  }

  func testDecodeRejectsNonUntrustedTrustState() {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "usb",
      "name": "x",
      "identityFingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "interfaces": [],
      "capabilitiesObserved": [],
      "trustState": "enrolled"
    }
    """
    XCTAssertThrowsError(try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoDiscoveredDeviceErrorV1,
        .invalidTrustState("enrolled"))
    }
  }

  func testDecodeRejectsEmptyName() {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "usb",
      "name": "  ",
      "identityFingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "interfaces": [],
      "capabilitiesObserved": [],
      "trustState": "untrusted"
    }
    """
    XCTAssertThrowsError(try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(error as? TatwoDiscoveredDeviceErrorV1, .emptyField("name"))
    }
  }

  func testDecodeRejectsFingerprintWithoutPrefix() {
    let json = """
    {
      "schema": "TatwoDiscoveredDeviceV1",
      "transport": "usb",
      "name": "x",
      "identityFingerprint": "not-a-hash",
      "interfaces": [],
      "capabilitiesObserved": [],
      "trustState": "untrusted"
    }
    """
    XCTAssertThrowsError(try TatwoDiscoveredDeviceV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(error as? TatwoDiscoveredDeviceErrorV1, .emptyField("identityFingerprint"))
    }
  }

  // MARK: - canBeManaged constant

  func testCanBeManagedAlwaysFalse() throws {
    let devices = [
      sampleDevice(transport: .usb),
      sampleDevice(transport: .thunderbolt, name: "TB", fingerprint: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
      sampleDevice(
        transport: .bonjour,
        name: "host",
        fingerprint: "unstable:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
    ]
    for device in devices {
      XCTAssertFalse(device.canBeManaged, "S1 canBeManaged must be false for \(device.transport)")
      let decoded = try TatwoDiscoveredDeviceV1.decode(from: try encode(device))
      XCTAssertFalse(decoded.canBeManaged)
    }
  }

  // MARK: - Report envelope

  func testReportDecodeEnforcesStageAndNextStep() throws {
    let device = sampleDevice()
    let report = TatwoDeviceDiscoveryReportV1(devices: [device], notes: ["ok"])
    let data = try JSONEncoder().encode(report)
    let decoded = try TatwoDeviceDiscoveryReportV1.decode(from: data)
    XCTAssertEqual(decoded.stage, "discovery-only")
    XCTAssertEqual(decoded.nextStep, "requires-pairing-code")
    XCTAssertEqual(decoded.devices.count, 1)
    XCTAssertFalse(decoded.canAnyBeManaged)
  }

  func testReportDecodeEmptyDevicesFailSoft() throws {
    let json = """
    {
      "schema": "TatwoDeviceDiscoveryReportV1",
      "stage": "discovery-only",
      "nextStep": "requires-pairing-code",
      "devices": [],
      "notes": ["No devices observed; returning empty devices[] (fail-soft, not an error)."]
    }
    """
    let decoded = try TatwoDeviceDiscoveryReportV1.decode(jsonUTF8: json)
    XCTAssertTrue(decoded.devices.isEmpty)
    XCTAssertFalse(decoded.notes.isEmpty)
  }

  func testReportRejectsWrongStage() {
    let json = """
    {
      "schema": "TatwoDeviceDiscoveryReportV1",
      "stage": "enrolled",
      "nextStep": "requires-pairing-code",
      "devices": [],
      "notes": []
    }
    """
    XCTAssertThrowsError(try TatwoDeviceDiscoveryReportV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoDeviceDiscoveryReportErrorV1,
        .invalidStage("enrolled"))
    }
  }

  func testReportRejectsWrongNextStep() {
    let json = """
    {
      "schema": "TatwoDeviceDiscoveryReportV1",
      "stage": "discovery-only",
      "nextStep": "auto-enroll",
      "devices": [],
      "notes": []
    }
    """
    XCTAssertThrowsError(try TatwoDeviceDiscoveryReportV1.decode(jsonUTF8: json)) { error in
      XCTAssertEqual(
        error as? TatwoDeviceDiscoveryReportErrorV1,
        .invalidNextStep("auto-enroll"))
    }
  }

  func testReportRejectsDeviceWithBadTrust() {
    let json = """
    {
      "schema": "TatwoDeviceDiscoveryReportV1",
      "stage": "discovery-only",
      "nextStep": "requires-pairing-code",
      "devices": [{
        "schema": "TatwoDiscoveredDeviceV1",
        "transport": "usb",
        "name": "x",
        "identityFingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "interfaces": [],
        "capabilitiesObserved": [],
        "trustState": "paired_unmanaged"
      }],
      "notes": []
    }
    """
    XCTAssertThrowsError(try TatwoDeviceDiscoveryReportV1.decode(jsonUTF8: json)) { error in
      guard let reportError = error as? TatwoDeviceDiscoveryReportErrorV1,
        case let .deviceInvariant(inner) = reportError
      else {
        return XCTFail("expected deviceInvariant, got \(error)")
      }
      XCTAssertEqual(inner, .invalidTrustState("paired_unmanaged"))
    }
  }

  /// Compile-time / API surface documentation: type has no pairing methods.
  /// (If someone adds createPairing/enroll on the type, this file should gain
  /// explicit negative tests — S1 intentionally has zero such APIs.)
  func testTypeLayerHasNoManageabilityEscape() {
    let device = sampleDevice()
    XCTAssertFalse(device.canBeManaged)
    // Mirror product rule: discovery card is observation only.
    XCTAssertEqual(device.trustState, TatwoDiscoveredDeviceV1.requiredTrustState)
  }
}
