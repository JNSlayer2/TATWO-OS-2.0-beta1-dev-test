import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import TatwoUltraworkCore

final class ImageAssetStoreTests: XCTestCase {
  func testIngestCopiesImageIntoContentAddressedStoreAndSurvivesSourceDeletion() throws {
    let fixture = try temporaryDirectory()
    let storeRoot = fixture.appendingPathComponent("store", isDirectory: true)
    let source = fixture.appendingPathComponent("outside.png")
    try pngData(red: 240, green: 20, blue: 20).write(to: source)

    let store = TatwoImageAssetStore(rootURL: storeRoot)
    let asset = try store.ingest(fileURL: source)
    try FileManager.default.removeItem(at: source)

    XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
    XCTAssertEqual(store.resolve(relativePath: asset.relativePath), asset.url)
    XCTAssertEqual(asset.url.deletingLastPathComponent(), storeRoot)
    XCTAssertTrue(TatwoImageAssetStore.isDecodableImageFile(atPath: asset.url.path))
  }

  func testContentHashAvoidsSameSizeCollisionAndDeduplicatesIdenticalImage() throws {
    let fixture = try temporaryDirectory()
    let store = TatwoImageAssetStore(
      rootURL: fixture.appendingPathComponent("store", isDirectory: true))
    let firstData = try pngData(red: 10, green: 20, blue: 30)
    let secondData = try pngData(red: 30, green: 20, blue: 10)
    XCTAssertEqual(firstData.count, secondData.count)

    let first = try store.ingest(data: firstData, suggestedName: "first.png")
    let second = try store.ingest(data: secondData, suggestedName: "second.png")
    let duplicate = try store.ingest(data: firstData, suggestedName: "duplicate.png")

    XCTAssertNotEqual(first.relativePath, second.relativePath)
    XCTAssertEqual(first.relativePath, duplicate.relativePath)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).count,
      2)
  }

  func testRenamedTextFileIsRejectedBeforeCreatingGhostAttachment() throws {
    let fixture = try temporaryDirectory()
    let source = fixture.appendingPathComponent("not-an-image.png")
    try Data("plain text".utf8).write(to: source)
    let store = TatwoImageAssetStore(
      rootURL: fixture.appendingPathComponent("store", isDirectory: true))

    XCTAssertThrowsError(try store.ingest(fileURL: source)) { error in
      XCTAssertEqual(error as? TatwoImageAssetError, .invalidImage)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
  }

  func testTiffInputNormalizesToPNGForOneRuntimeImageContract() throws {
    let fixture = try temporaryDirectory()
    let store = TatwoImageAssetStore(
      rootURL: fixture.appendingPathComponent("store", isDirectory: true))
    let asset = try store.ingest(
      data: try imageData(type: .tiff, red: 40, green: 80, blue: 120),
      suggestedName: "photo.tiff")

    XCTAssertEqual(asset.url.pathExtension, "png")
    XCTAssertTrue(TatwoImageAssetStore.isDecodableImageFile(atPath: asset.url.path))
  }

  func testCandidateDetectionUsesOneUTTypeBasedExtensionPolicy() {
    XCTAssertTrue(TatwoImageAssetStore.isImageCandidatePath("/tmp/photo.heif"))
    XCTAssertTrue(TatwoImageAssetStore.isImageCandidatePath("/tmp/photo.tiff"))
    XCTAssertTrue(TatwoImageAssetStore.isImageCandidatePath("/tmp/photo.webp"))
    XCTAssertFalse(TatwoImageAssetStore.isImageCandidatePath("/tmp/notes.txt"))
  }

  func testOversizedInputFailsBeforeDecodeOrDiskWrite() throws {
    let fixture = try temporaryDirectory()
    let store = TatwoImageAssetStore(
      rootURL: fixture.appendingPathComponent("store", isDirectory: true))
    let oversized = Data(count: TatwoImageAssetStore.maximumInputBytes + 1)

    XCTAssertThrowsError(
      try store.ingest(data: oversized, suggestedName: "huge.png")
    ) { error in
      XCTAssertEqual(error as? TatwoImageAssetError, .imageTooLarge)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-image-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func pngData(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
    try imageData(type: .png, red: red, green: green, blue: blue)
  }

  private func imageData(
    type: UTType,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) throws -> Data {
    var pixel = [red, green, blue, 255]
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let image = context.makeImage()
    else {
      throw NSError(domain: "ImageAssetStoreTests", code: 1)
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      type.identifier as CFString,
      1,
      nil)
    else {
      throw NSError(domain: "ImageAssetStoreTests", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "ImageAssetStoreTests", code: 3)
    }
    return output as Data
  }
}
