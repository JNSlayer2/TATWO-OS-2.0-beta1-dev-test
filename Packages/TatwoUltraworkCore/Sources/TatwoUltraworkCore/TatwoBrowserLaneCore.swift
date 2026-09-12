import CryptoKit
import Foundation

public enum TatwoBrowserAddressRejection: String, Sendable, Equatable {
  case emptyInput
  case malformedHTTPURL
  case unsupportedScheme
}

public enum TatwoBrowserAddressResolution: Sendable, Equatable {
  case navigate(URL)
  case reject(TatwoBrowserAddressRejection)
}

/// Resolves explicit HTTP(S) URLs, valid bare domain names, and IPv4 hosts as
/// direct navigation. Whitespace-bearing text and values without a host-shaped
/// dot remain Google searches. Known executable/local-data schemes and
/// explicit custom `scheme://` URIs fail closed rather than being smuggled
/// into search.
public enum TatwoBrowserAddressResolver {
  public static let googleHomeURL = URL(string: "https://www.google.com/")!
  private static let dangerousSchemes: Set<String> = [
    "data",
    "file",
    "javascript",
  ]

  public static func resolve(_ rawValue: String) -> TatwoBrowserAddressResolution {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .reject(.emptyInput)
    }

    if let scheme = explicitScheme(in: trimmed) {
      if dangerousSchemes.contains(scheme) {
        return .reject(.unsupportedScheme)
      }

      if scheme == "http" || scheme == "https" {
        guard
          let components = URLComponents(string: trimmed),
          let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty,
          let url = components.url
        else {
          return .reject(.malformedHTTPURL)
        }
        return .navigate(url)
      }

      if hasExplicitURIAuthority(in: trimmed) {
        return .reject(.unsupportedScheme)
      }
    }

    if !trimmed.contains(where: \.isWhitespace),
       let directURL = implicitHTTPSURL(for: trimmed)
    {
      return .navigate(directURL)
    }

    return googleSearchURL(for: trimmed)
  }

  private static func implicitHTTPSURL(for value: String) -> URL? {
    guard
      let components = URLComponents(string: "https://\(value)"),
      components.user == nil,
      components.password == nil,
      let host = components.host?.lowercased(),
      isNavigableBareHost(host),
      let url = components.url
    else {
      return nil
    }
    return url
  }

  private static func isNavigableBareHost(_ host: String) -> Bool {
    isValidIPv4Address(host) || isValidDomainName(host)
  }

  private static func isValidIPv4Address(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty
        && part.allSatisfy(\.isNumber)
        && part.count <= 3
        && Int(part).map { (0...255).contains($0) } == true
    }
  }

  private static func isValidDomainName(_ host: String) -> Bool {
    guard host.count <= 253, host.contains(".") else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
          labels.allSatisfy(isValidDomainLabel),
          let topLevelDomain = labels.last
    else {
      return false
    }
    if topLevelDomain.lowercased().hasPrefix("xn--") {
      return topLevelDomain.count > 4
    }
    return (2...63).contains(topLevelDomain.count)
      && topLevelDomain.allSatisfy { $0.isASCII && $0.isLetter }
  }

  private static func isValidDomainLabel(_ label: Substring) -> Bool {
    guard (1...63).contains(label.count),
          label.first != "-",
          label.last != "-"
    else {
      return false
    }
    return label.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
    }
  }

  private static func googleSearchURL(
    for value: String
  ) -> TatwoBrowserAddressResolution {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.google.com"
    components.path = "/search"
    components.queryItems = [URLQueryItem(name: "q", value: value)]
    guard let url = components.url else {
      return .reject(.malformedHTTPURL)
    }
    return .navigate(url)
  }

  private static func explicitScheme(in value: String) -> String? {
    guard let separator = value.firstIndex(of: ":") else {
      return nil
    }
    let candidate = value[..<separator]
    guard let first = candidate.first, first.isASCII, first.isLetter else {
      return nil
    }
    guard candidate.dropFirst().allSatisfy({
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
    }) else {
      return nil
    }
    return candidate.lowercased()
  }

  private static func hasExplicitURIAuthority(in value: String) -> Bool {
    guard let separator = value.firstIndex(of: ":") else {
      return false
    }
    return value[value.index(after: separator)...].hasPrefix("//")
  }
}

public struct TatwoBrowserProfileIdentity: Sendable, Hashable, Equatable {
  public let sessionID: String
  public let dataStoreIdentifier: UUID

  public init?(sessionID: String) {
    let normalizedSessionID = sessionID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSessionID.isEmpty else {
      return nil
    }

    self.sessionID = normalizedSessionID
    self.dataStoreIdentifier = Self.stableIdentifier(for: normalizedSessionID)
  }

  private static func stableIdentifier(for sessionID: String) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data("tatwo.browser.profile.v1|\(sessionID)".utf8)).prefix(16))
    // RFC 4122 variant plus a deterministic version-5-style marker.
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

public enum TatwoBrowserSessionPolicy {
  /// Legacy explicit home destination. The macOS browser UI deliberately does
  /// not load this value until the user submits a search or URL.
  public static let initialURL = TatwoBrowserAddressResolver.googleHomeURL
}

public struct TatwoBrowserLaneID:
  RawRepresentable,
  Codable,
  Sendable,
  Hashable,
  Equatable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum TatwoBrowserLaneBinding: Codable, Sendable, Equatable {
  case unboundReadOnly
  case goal(goalID: String, contractID: String)

  fileprivate var isComplete: Bool {
    switch self {
    case .unboundReadOnly:
      true
    case let .goal(goalID, contractID):
      !goalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !contractID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

public struct TatwoBrowserLane: Identifiable, Codable, Sendable, Equatable {
  public let id: TatwoBrowserLaneID
  public let binding: TatwoBrowserLaneBinding
  public let title: String
  public private(set) var isPinned: Bool
  public let createdAt: Date
  public private(set) var lastActiveAt: Date

  public init(
    id: TatwoBrowserLaneID,
    binding: TatwoBrowserLaneBinding,
    title: String,
    isPinned: Bool = false,
    createdAt: Date,
    lastActiveAt: Date
  ) {
    self.id = id
    self.binding = binding
    self.title = title
    self.isPinned = isPinned
    self.createdAt = createdAt
    self.lastActiveAt = lastActiveAt
  }

  fileprivate mutating func setPinned(_ isPinned: Bool) {
    self.isPinned = isPinned
  }

  fileprivate mutating func markActive(at date: Date) {
    lastActiveAt = date
  }
}

public struct TatwoBrowserLaneState: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1
  public static let defaultMaximumLaneCount = 8

  public let schemaVersion: Int
  public let maximumLaneCount: Int
  public fileprivate(set) var lanes: [TatwoBrowserLane]
  public fileprivate(set) var selectedLaneID: TatwoBrowserLaneID?

  public init(
    schemaVersion: Int = TatwoBrowserLaneState.currentSchemaVersion,
    maximumLaneCount: Int = TatwoBrowserLaneState.defaultMaximumLaneCount,
    lanes: [TatwoBrowserLane] = [],
    selectedLaneID: TatwoBrowserLaneID? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.maximumLaneCount = max(1, maximumLaneCount)
    self.lanes = Self.pinnedFirst(
      Array(lanes.prefix(max(1, maximumLaneCount))))
    if let selectedLaneID, self.lanes.contains(where: { $0.id == selectedLaneID }) {
      self.selectedLaneID = selectedLaneID
    } else {
      self.selectedLaneID = self.lanes.first?.id
    }
  }

  public var selectedLane: TatwoBrowserLane? {
    guard let selectedLaneID else {
      return nil
    }
    return lanes.first(where: { $0.id == selectedLaneID })
  }

  fileprivate static func pinnedFirst(
    _ lanes: [TatwoBrowserLane]
  ) -> [TatwoBrowserLane] {
    lanes.filter(\.isPinned) + lanes.filter { !$0.isPinned }
  }
}

public enum TatwoBrowserLaneAction: Codable, Sendable, Equatable {
  case open(
    id: TatwoBrowserLaneID,
    binding: TatwoBrowserLaneBinding,
    title: String)
  case close(TatwoBrowserLaneID)
  case select(TatwoBrowserLaneID)
  case pin(TatwoBrowserLaneID, Bool)
}

public enum TatwoBrowserLaneReducer {
  public static func reduce(
    state: TatwoBrowserLaneState,
    action: TatwoBrowserLaneAction,
    now: Date
  ) -> TatwoBrowserLaneState {
    var next = state

    switch action {
    case let .open(id, binding, title):
      guard isValid(id),
            binding.isComplete,
            !next.lanes.contains(where: { $0.id == id }),
            next.lanes.count < next.maximumLaneCount
      else {
        return state
      }

      next.lanes.append(
        TatwoBrowserLane(
          id: id,
          binding: binding,
          title: title,
          createdAt: now,
          lastActiveAt: now))
      next.selectedLaneID = id

    case let .select(id):
      guard let index = next.lanes.firstIndex(where: { $0.id == id }) else {
        return state
      }
      next.selectedLaneID = id
      next.lanes[index].markActive(at: now)

    case let .pin(id, isPinned):
      guard let index = next.lanes.firstIndex(where: { $0.id == id }) else {
        return state
      }
      next.lanes[index].setPinned(isPinned)

    case let .close(id):
      guard let closingIndex = next.lanes.firstIndex(where: { $0.id == id }) else {
        return state
      }

      let closedSelectedLane = next.selectedLaneID == id
      next.lanes.remove(at: closingIndex)

      guard !next.lanes.isEmpty else {
        next.selectedLaneID = nil
        return next
      }

      let selectionIsMissing = next.selectedLaneID.map {
        selectedID in !next.lanes.contains(where: { $0.id == selectedID })
      } ?? true
      if closedSelectedLane || selectionIsMissing {
        let neighborIndex = closingIndex > 0 ? closingIndex - 1 : 0
        next.selectedLaneID = next.lanes[neighborIndex].id
        next.lanes[neighborIndex].markActive(at: now)
      }
    }

    next.lanes = TatwoBrowserLaneState.pinnedFirst(next.lanes)
    return next
  }

  private static func isValid(_ id: TatwoBrowserLaneID) -> Bool {
    !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
