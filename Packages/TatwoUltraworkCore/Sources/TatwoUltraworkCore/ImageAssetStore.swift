import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TatwoImageAsset: Sendable, Equatable {
  public let id: String
  public let relativePath: String
  public let url: URL
  public let displayName: String
  public let byteCount: Int

  public init(
    id: String,
    relativePath: String,
    url: URL,
    displayName: String,
    byteCount: Int
  ) {
    self.id = id
    self.relativePath = relativePath
    self.url = url
    self.displayName = displayName
    self.byteCount = byteCount
  }
}

public enum TatwoImageAssetError: LocalizedError, Equatable {
  case missingFile
  case unreadableFile
  case emptyImage
  case imageTooLarge
  case invalidImage
  case unsupportedImage
  case writeFailed

  public var errorDescription: String? {
    switch self {
    case .missingFile: "圖片檔案不存在。"
    case .unreadableFile: "圖片檔案無法讀取。"
    case .emptyImage: "圖片內容是空的。"
    case .imageTooLarge: "圖片檔案過大。"
    case .invalidImage: "檔案內容不是可解碼的圖片。"
    case .unsupportedImage: "圖片格式無法轉成模型可讀格式。"
    case .writeFailed: "圖片無法寫入 Tatwo Ultrawork 附件庫。"
    }
  }
}

public struct TatwoImageAssetStore: Sendable {
  public static let maximumInputBytes = 20 * 1024 * 1024

  public let rootURL: URL

  public init(rootURL: URL = Self.defaultRootURL()) {
    self.rootURL = rootURL.standardizedFileURL
  }

  public static func defaultRootURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      fileManager: fileManager)
      .appendingPathComponent("Attachments", isDirectory: true)
      .appendingPathComponent("images", isDirectory: true)
  }

  public func ingest(fileURL: URL, displayName: String? = nil) throws -> TatwoImageAsset {
    let source = fileURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw TatwoImageAssetError.missingFile
    }
    guard FileManager.default.isReadableFile(atPath: source.path) else {
      throw TatwoImageAssetError.unreadableFile
    }
    guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]) else {
      throw TatwoImageAssetError.unreadableFile
    }
    return try ingest(
      data: data,
      suggestedName: displayName ?? source.lastPathComponent)
  }

  public func ingest(data: Data, suggestedName: String) throws -> TatwoImageAsset {
    guard !data.isEmpty else { throw TatwoImageAssetError.emptyImage }
    guard data.count <= Self.maximumInputBytes else {
      throw TatwoImageAssetError.imageTooLarge
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    else {
      throw TatwoImageAssetError.invalidImage
    }

    let sourceType = CGImageSourceGetType(source) as String?
    let normalized = try normalizedPayload(data: data, source: source, sourceType: sourceType)
    let digest = SHA256.hash(data: normalized.data)
      .map { String(format: "%02x", $0) }
      .joined()
    let filename = "\(digest).\(normalized.fileExtension)"
    let target = rootURL.appendingPathComponent(filename, isDirectory: false)

    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: target.path) {
        try normalized.data.write(to: target, options: [.atomic])
      }
    } catch {
      throw TatwoImageAssetError.writeFailed
    }

    return TatwoImageAsset(
      id: digest,
      relativePath: filename,
      url: target,
      displayName: Self.safeDisplayName(suggestedName, fallbackExtension: normalized.fileExtension),
      byteCount: normalized.data.count)
  }

  public func resolve(relativePath: String) -> URL? {
    let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.hasPrefix("/"),
      !trimmed.split(separator: "/").contains("..")
    else { return nil }
    let target = rootURL.appendingPathComponent(trimmed).standardizedFileURL
    guard target.deletingLastPathComponent() == rootURL else { return nil }
    return target
  }

  public func relativePath(for url: URL) -> String? {
    let target = url.standardizedFileURL
    guard target.deletingLastPathComponent() == rootURL else { return nil }
    return target.lastPathComponent
  }

  public static func isDecodableImageFile(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.isReadableFile(atPath: url.path),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 0
    else { return false }
    return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
  }

  public static func isImageCandidatePath(_ path: String) -> Bool {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard !ext.isEmpty else { return false }
    // UTType lookup may require LaunchServices/XPC, which is unavailable in
    // some headless test runners. Keep the accepted image contract
    // deterministic before asking the platform about less common extensions.
    if [
      "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
      "bmp",
    ].contains(ext) {
      return true
    }
    guard let type = UTType(filenameExtension: ext) else { return false }
    return type.conforms(to: .image)
  }

  private func normalizedPayload(
    data: Data,
    source: CGImageSource,
    sourceType: String?
  ) throws -> (data: Data, fileExtension: String) {
    if let sourceType,
      let type = UTType(sourceType),
      type.conforms(to: .png)
    {
      return (data, "png")
    }
    if let sourceType,
      let type = UTType(sourceType),
      type.conforms(to: .jpeg)
    {
      return (data, "jpg")
    }
    if let sourceType,
      let type = UTType(sourceType),
      type.conforms(to: .gif)
    {
      return (data, "gif")
    }
    if let sourceType,
      let type = UTType(sourceType),
      type.identifier == UTType.webP.identifier
    {
      return (data, "webp")
    }

    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw TatwoImageAssetError.invalidImage
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil)
    else {
      throw TatwoImageAssetError.unsupportedImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw TatwoImageAssetError.unsupportedImage
    }
    return (output as Data, "png")
  }

  private static func safeDisplayName(
    _ raw: String,
    fallbackExtension: String
  ) -> String {
    let candidate = URL(fileURLWithPath: raw).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.isEmpty {
      return "image.\(fallbackExtension)"
    }
    return String(candidate.prefix(180))
  }
}
