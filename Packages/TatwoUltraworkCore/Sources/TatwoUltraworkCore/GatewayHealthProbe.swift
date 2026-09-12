import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TatwoGatewayHealthState: String, Codable, Sendable, CaseIterable {
  case healthy
  case degraded
  case unknown

  public var installState: InstallState {
    switch self {
    case .healthy:
      return .installed
    case .degraded:
      return .missing
    case .unknown:
      return .unknown
    }
  }

  public var plainLabel: String {
    switch self {
    case .healthy:
      return "健康"
    case .degraded:
      return "降級"
    case .unknown:
      return "未驗證"
    }
  }
}

public struct TatwoOperationalBlockerDescriptor: Codable, Sendable, Equatable {
  public let blockerClass: String
  public let resetAt: String?
  public let retryAllowed: Bool?
  public let detail: String

  public init(
    blockerClass: String,
    resetAt: String? = nil,
    retryAllowed: Bool? = nil,
    detail: String = ""
  ) {
    let normalizedClass = Self.normalizedClass(blockerClass)
    self.blockerClass = normalizedClass
    self.resetAt = Self.nonEmpty(resetAt)
    self.retryAllowed = retryAllowed ?? (Self.disablesAutomaticRetry(normalizedClass) ? false : nil)
    self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var serializedReason: String {
    var fields = ["blocker_class=\(blockerClass)"]
    if let resetAt { fields.append("reset_at=\(resetAt)") }
    if let retryAllowed { fields.append("retry_allowed=\(retryAllowed)") }
    return fields.joined(separator: ";")
  }

  public var resetDisplay: String {
    resetAt ?? "上游尚未回報"
  }

  public var retryDisplay: String {
    switch retryAllowed {
    case false:
      return "禁止自動重試"
    case true:
      return "允許人工重試"
    case nil:
      return "重試策略未提供"
    }
  }

  public static func parse(_ raw: String?) -> TatwoOperationalBlockerDescriptor? {
    guard let raw = nonEmpty(raw) else { return nil }
    let fields = raw
      .split(separator: ";")
      .reduce(into: [String: String]()) { result, segment in
        let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { return }
        let key = pair[0]
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        result[key] = value
      }

    let blockerClass = fields["blocker_class"] ?? inferredClass(from: raw)
    guard let blockerClass else { return nil }
    let retryAllowed = fields["retry_allowed"].flatMap(Self.parseBool)
    return TatwoOperationalBlockerDescriptor(
      blockerClass: blockerClass,
      resetAt: fields["reset_at"] ?? inferredResetAt(from: raw),
      retryAllowed: retryAllowed,
      detail: raw)
  }

  private static func inferredClass(from raw: String) -> String? {
    let normalized = raw.lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    let known = [
      "session_limit",
      "rate_limit",
      "quota",
      "auth",
      "permission_denied",
      "tool_unavailable",
      "contract_missing",
      "timeout",
    ]
    return known.first(where: normalized.contains)
  }

  private static func inferredResetAt(from raw: String) -> String? {
    let patterns = [
      #"reset_at\s*=\s*([^;\n]+)"#,
      #"\breset\s+([^;\n]+)"#,
      #"\bresets?\s+([0-9]{1,2}:[0-9]{2}\s*(?:am|pm)?(?:\s*\([^)]+\))?)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        continue
      }
      let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
      guard
        let match = regex.firstMatch(in: raw, range: range),
        match.numberOfRanges > 1,
        let valueRange = Range(match.range(at: 1), in: raw)
      else {
        continue
      }
      return nonEmpty(String(raw[valueRange]))
    }
    return nil
  }

  private static func parseBool(_ raw: String) -> Bool? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes":
      return true
    case "false", "0", "no":
      return false
    default:
      return nil
    }
  }

  private static func disablesAutomaticRetry(_ blockerClass: String) -> Bool {
    ["session_limit", "rate_limit", "quota", "auth"].contains(blockerClass)
  }

  private static func normalizedClass(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct TatwoRouteHealthReceiptV2: Codable, Sendable, Equatable {
  public let schema: String
  public let attempts: Int?
  public let hasError: Bool?
  public let errorKind: String?
  public let observedAt: String?
  public let lastOKAt: String?
  public let requiredFieldsPresent: Bool

  public init(
    schema: String = "TatwoRouteHealthReceiptV2",
    attempts: Int?,
    hasError: Bool?,
    errorKind: String?,
    observedAt: String?,
    lastOKAt: String?,
    requiredFieldsPresent: Bool = true
  ) {
    self.schema = schema
    self.attempts = attempts
    self.hasError = hasError
    self.errorKind = errorKind
    self.observedAt = observedAt
    self.lastOKAt = lastOKAt
    self.requiredFieldsPresent = requiredFieldsPresent
  }

  public var isComplete: Bool {
    schema == "TatwoRouteHealthReceiptV2" && requiredFieldsPresent
  }

  public func isHealthy(
    at checkedAt: Date,
    maxAge: TimeInterval = TatwoGatewayRouteObservation.healthyObservationMaxAge
  ) -> Bool {
    guard isComplete else { return false }
    guard let attempts, attempts > 0 else { return false }
    guard hasError == false, errorKind == nil else { return false }
    guard
      let observed = Self.parseDate(observedAt),
      let lastOK = Self.parseDate(lastOKAt)
    else { return false }
    let observedAge = checkedAt.timeIntervalSince(observed)
    let successAge = checkedAt.timeIntervalSince(lastOK)
    guard observedAge >= -60, observedAge <= maxAge else { return false }
    guard successAge >= -60, successAge <= maxAge else { return false }
    guard lastOK.timeIntervalSince(observed) <= 60 else { return false }
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case attempts
    case hasError = "has_error"
    case errorKind = "error_kind"
    case observedAt = "observed_at"
    case lastOKAt = "last_ok_at"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? ""
    attempts = try container.decodeIfPresent(Int.self, forKey: .attempts)
    hasError = try container.decodeIfPresent(Bool.self, forKey: .hasError)
    errorKind = try container.decodeIfPresent(String.self, forKey: .errorKind)
    observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
    lastOKAt = try container.decodeIfPresent(String.self, forKey: .lastOKAt)
    requiredFieldsPresent = [
      CodingKeys.schema,
      CodingKeys.attempts,
      .hasError,
      .errorKind,
      .observedAt,
      .lastOKAt,
    ].allSatisfy(container.contains)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    if let attempts {
      try container.encode(attempts, forKey: .attempts)
    } else {
      try container.encodeNil(forKey: .attempts)
    }
    if let hasError {
      try container.encode(hasError, forKey: .hasError)
    } else {
      try container.encodeNil(forKey: .hasError)
    }
    if let errorKind {
      try container.encode(errorKind, forKey: .errorKind)
    } else {
      try container.encodeNil(forKey: .errorKind)
    }
    if let observedAt {
      try container.encode(observedAt, forKey: .observedAt)
    } else {
      try container.encodeNil(forKey: .observedAt)
    }
    if let lastOKAt {
      try container.encode(lastOKAt, forKey: .lastOKAt)
    } else {
      try container.encodeNil(forKey: .lastOKAt)
    }
  }

  static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

public struct TatwoGatewayRouteObservation: Codable, Sendable, Equatable, Identifiable {
  public static let healthyObservationMaxAge: TimeInterval = 15 * 60

  public let id: String
  public let attempts: Int?
  public let hasError: Bool?
  public let errorKind: String?
  public let observedAt: String?
  public let lastOKAt: String?
  public let lastErrorAt: String?
  public let resetAt: String?
  public let retryAllowed: Bool?
  public let requiredV2FieldsPresent: Bool

  public init(
    id: String,
    attempts: Int? = nil,
    hasError: Bool?,
    errorKind: String?,
    observedAt: String? = nil,
    lastOKAt: String?,
    lastErrorAt: String?,
    resetAt: String? = nil,
    retryAllowed: Bool? = nil,
    requiredV2FieldsPresent: Bool = true
  ) {
    self.id = id
    self.attempts = attempts
    self.hasError = hasError
    self.errorKind = errorKind
    self.observedAt = observedAt
    self.lastOKAt = lastOKAt
    self.lastErrorAt = lastErrorAt
    self.resetAt = resetAt
    self.retryAllowed = retryAllowed
    self.requiredV2FieldsPresent = requiredV2FieldsPresent
  }

  public var routeHealthReceiptV2: TatwoRouteHealthReceiptV2 {
    TatwoRouteHealthReceiptV2(
      attempts: attempts,
      hasError: hasError,
      errorKind: errorKind,
      observedAt: observedAt,
      lastOKAt: lastOKAt,
      requiredFieldsPresent: requiredV2FieldsPresent)
  }

  public var wasProbed: Bool {
    (attempts ?? 0) > 0
  }

  public var hasActiveError: Bool {
    if hasError == true { return true }
    if errorKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      return true
    }
    let lastOK = TatwoRouteHealthReceiptV2.parseDate(lastOKAt)
    let lastError = TatwoRouteHealthReceiptV2.parseDate(lastErrorAt)
    if let lastError {
      guard let lastOK else { return true }
      if lastError >= lastOK { return true }
    }
    return false
  }

  public var hasExplicitOutcome: Bool {
    routeHealthReceiptV2.isComplete
  }

  public var isExplicitlyHealthy: Bool {
    isExplicitlyHealthy(at: Date())
  }

  public func isExplicitlyHealthy(
    at checkedAt: Date,
    maxAge: TimeInterval = Self.healthyObservationMaxAge
  ) -> Bool {
    guard !hasActiveError, routeHealthReceiptV2.isHealthy(at: checkedAt, maxAge: maxAge)
    else { return false }
    guard let lastOK = TatwoRouteHealthReceiptV2.parseDate(lastOKAt) else { return false }
    if let lastError = TatwoRouteHealthReceiptV2.parseDate(lastErrorAt), lastError >= lastOK {
      return false
    }
    return true
  }
}

public struct TatwoGatewayLiveStatus: Codable, Sendable, Equatable {
  public let endpoint: String
  public let runtimeState: TatwoGatewayHealthState
  public let routeState: TatwoGatewayHealthState
  public let healthOK: Bool
  public let catalogAvailable: Bool
  public let catalogModelCount: Int
  public let routes: [TatwoGatewayRouteObservation]
  public let requiredRouteIDs: [String]?
  public let catalogRouteIDs: [String]?
  public let errorMessage: String?
  public let checkedAt: Date

  public init(
    endpoint: String,
    runtimeState: TatwoGatewayHealthState,
    routeState: TatwoGatewayHealthState,
    healthOK: Bool,
    catalogAvailable: Bool,
    catalogModelCount: Int,
    routes: [TatwoGatewayRouteObservation],
    requiredRouteIDs: [String] = [],
    catalogRouteIDs: [String] = [],
    errorMessage: String? = nil,
    checkedAt: Date = Date()
  ) {
    self.endpoint = endpoint
    self.runtimeState = runtimeState
    self.routeState = routeState
    self.healthOK = healthOK
    self.catalogAvailable = catalogAvailable
    self.catalogModelCount = catalogModelCount
    self.routes = routes.sorted { $0.id < $1.id }
    self.requiredRouteIDs = Self.normalizedRouteIDs(requiredRouteIDs)
    self.catalogRouteIDs = Self.normalizedRouteIDs(catalogRouteIDs)
    self.errorMessage = errorMessage
    self.checkedAt = checkedAt
  }

  public static func unavailable(endpoint: URL, reason: String) -> TatwoGatewayLiveStatus {
    TatwoGatewayLiveStatus(
      endpoint: endpoint.absoluteString,
      runtimeState: .unknown,
      routeState: .unknown,
      healthOK: false,
      catalogAvailable: false,
      catalogModelCount: 0,
      routes: [],
      errorMessage: reason
    )
  }

  public var probedRouteCount: Int {
    routes.filter(\.wasProbed).count
  }

  public var healthyRouteCount: Int {
    routes.filter { $0.isExplicitlyHealthy(at: checkedAt) }.count
  }

  public var failedRoutes: [TatwoGatewayRouteObservation] {
    routes.filter(\.hasActiveError)
  }

  public var missingRequiredRouteIDs: [String] {
    let observed = Set(routes.map { $0.id.lowercased() })
    return normalizedRequiredRouteIDs.filter { !observed.contains($0.lowercased()) }
  }

  public var missingRequiredCatalogRouteIDs: [String] {
    let catalog = Set((catalogRouteIDs ?? []).map { $0.lowercased() })
    return normalizedRequiredRouteIDs.filter { !catalog.contains($0.lowercased()) }
  }

  public var directRouteSummary: String {
    switch routeState {
    case .healthy:
      return "已讀取 gateway route 狀態；\(healthyRouteCount) 條已探測路線目前健康，required routes 均已驗證。"
    case .degraded:
      let names = failedRoutes.prefix(3).map(\.id).joined(separator: "、")
      var details: [String] = []
      if !names.isEmpty { details.append("錯誤：\(names)") }
      if !missingRequiredCatalogRouteIDs.isEmpty {
        details.append("catalog 缺：\(missingRequiredCatalogRouteIDs.joined(separator: "、"))")
      }
      let suffix = details.isEmpty ? "" : "（\(details.joined(separator: "；"))）"
      return "gateway 可用，但 required route 狀態降級\(suffix)。"
    case .unknown:
      if !missingRequiredRouteIDs.isEmpty {
        return "gateway health 有回應，但缺少 required route 狀態：\(missingRequiredRouteIDs.joined(separator: "、"))；不能標示健康。"
      }
      return "gateway route 狀態尚未取得；不能把總 health 綠燈當成每條 route 都通過。"
    }
  }

  public var runtimeSummary: String {
    switch runtimeState {
    case .healthy:
      return "gateway healthz 正常；catalog 已讀取 \(catalogModelCount) 個模型。"
    case .degraded:
      return "gateway 回應了，但 health/catalog 未完整通過。"
    case .unknown:
      return errorMessage.map { "gateway live probe 未完成：\($0)" }
        ?? "gateway live health 尚未驗證。"
    }
  }

  private var normalizedRequiredRouteIDs: [String] {
    Self.normalizedRouteIDs(requiredRouteIDs ?? [])
  }

  private static func normalizedRouteIDs(_ values: [String]) -> [String] {
    Array(Set(values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }))
      .sorted()
  }
}

public enum TatwoGatewayDispatchGateDecision: Sendable, Equatable {
  case allowed
  case blocked(reason: String)
}

public enum TatwoGatewayDispatchGate {
  public static func evaluate(
    status: TatwoGatewayLiveStatus?,
    modelID: String,
    now: Date = Date(),
    maxStatusAge: TimeInterval = 15 * 60
  ) -> TatwoGatewayDispatchGateDecision {
    guard let status else {
      return .blocked(reason: "gateway_health_unavailable")
    }
    let statusAge = now.timeIntervalSince(status.checkedAt)
    guard statusAge >= -60, statusAge <= maxStatusAge else {
      return .blocked(reason: "gateway_health_stale")
    }
    guard status.runtimeState == .healthy else {
      return .blocked(reason: "gateway_runtime_\(status.runtimeState.rawValue)")
    }

    let routeID = TatwoGatewayDispatchCatalog.normalize(modelID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !routeID.isEmpty else {
      return .blocked(reason: "route_health_missing:unknown")
    }

    let catalogIDs = Set((status.catalogRouteIDs ?? []).map { $0.lowercased() })
    guard catalogIDs.contains(routeID) else {
      return .blocked(reason: "route_catalog_missing:\(routeID)")
    }
    guard let route = status.routes.first(where: { $0.id.lowercased() == routeID }) else {
      return .blocked(reason: "route_health_missing:\(routeID)")
    }
    if route.hasActiveError {
      let reason = route.errorKind?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard reason?.isEmpty == false else {
        return .blocked(reason: "route_degraded:\(routeID)")
      }
      return .blocked(
        reason: TatwoOperationalBlockerDescriptor(
          blockerClass: reason!,
          resetAt: route.resetAt,
          retryAllowed: route.retryAllowed)
          .serializedReason)
    }
    guard route.isExplicitlyHealthy(at: now) else {
      return .blocked(reason: "route_health_unknown:\(routeID)")
    }
    return .allowed
  }
}

public enum TatwoGatewayHealthDecoder {
  public static func decode(
    healthData: Data,
    catalogData: Data?,
    endpoint: URL,
    requiredRouteIDs: [String] = [],
    checkedAt: Date = Date()
  ) -> TatwoGatewayLiveStatus {
    guard
      let healthObject = jsonObject(from: healthData),
      let health = healthObject as? [String: Any]
    else {
      return .unavailable(endpoint: endpoint, reason: "healthz JSON 無法解析")
    }

    let healthOK = bool(health["ok"]) == true
    let routes = routeObservations(from: health)
    let catalog = catalogSummary(from: catalogData)
    let requiredRoutes = Array(Set(requiredRouteIDs
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }))
      .sorted()
    let runtimeState: TatwoGatewayHealthState
    if !healthOK {
      runtimeState = .degraded
    } else if catalog.available && catalog.modelCount > 0 {
      runtimeState = .healthy
    } else {
      runtimeState = .degraded
    }

    let routeIDs = Set(routes.map { $0.id.lowercased() })
    let catalogIDs = Set(catalog.routeIDs.map { $0.lowercased() })
    let requiredRouteSet = Set(requiredRoutes.map { $0.lowercased() })
    let missingRequiredRoutes = requiredRoutes.filter { !routeIDs.contains($0.lowercased()) }
    let missingRequiredCatalogRoutes = requiredRoutes.filter { !catalogIDs.contains($0.lowercased()) }
    let relevantRoutes = requiredRouteSet.isEmpty
      ? routes
      : routes.filter { requiredRouteSet.contains($0.id.lowercased()) }
    let probedRoutes = relevantRoutes.filter(\.wasProbed)
    let failedRoutes = relevantRoutes.filter(\.hasActiveError)
    let routeState: TatwoGatewayHealthState
    if !failedRoutes.isEmpty || !missingRequiredCatalogRoutes.isEmpty {
      routeState = .degraded
    } else if !missingRequiredRoutes.isEmpty {
      routeState = .unknown
    } else if !requiredRoutes.isEmpty,
      relevantRoutes.count == requiredRoutes.count,
      relevantRoutes.allSatisfy({ $0.isExplicitlyHealthy(at: checkedAt) })
    {
      routeState = .healthy
    } else if requiredRoutes.isEmpty,
      failedRoutes.isEmpty,
      !probedRoutes.isEmpty,
      probedRoutes.allSatisfy({ $0.isExplicitlyHealthy(at: checkedAt) })
    {
      routeState = .healthy
    } else {
      routeState = .unknown
    }

    return TatwoGatewayLiveStatus(
      endpoint: endpoint.absoluteString,
      runtimeState: runtimeState,
      routeState: routeState,
      healthOK: healthOK,
      catalogAvailable: catalog.available,
      catalogModelCount: catalog.modelCount,
      routes: routes,
      requiredRouteIDs: requiredRoutes,
      catalogRouteIDs: catalog.routeIDs,
      errorMessage: nil,
      checkedAt: checkedAt
    )
  }

  private static func routeObservations(from health: [String: Any])
    -> [TatwoGatewayRouteObservation]
  {
    let rawRoutes =
      (health["routes"] as? [String: Any])
      ?? (health["healthz.routes"] as? [String: Any])
      ?? [:]

    return rawRoutes.compactMap { id, value in
      guard let route = value as? [String: Any] else { return nil }
      let requiredV2Keys = [
        "attempts",
        "has_error",
        "error_kind",
        "observed_at",
        "last_ok_at",
      ]
      return TatwoGatewayRouteObservation(
        id: id,
        attempts: int(route["attempts"]),
        hasError: bool(route["has_error"]),
        errorKind: string(route["error_kind"]),
        observedAt: string(route["observed_at"]),
        lastOKAt: string(route["last_ok_at"]) ?? string(route["last_ok"]),
        lastErrorAt: string(route["last_error_at"]),
        resetAt: string(route["reset_at"]),
        retryAllowed: bool(route["retry_allowed"]),
        requiredV2FieldsPresent: requiredV2Keys.allSatisfy(route.keys.contains)
      )
    }
  }

  private static func catalogSummary(from data: Data?)
    -> (available: Bool, modelCount: Int, routeIDs: [String])
  {
    guard
      let data,
      let object = jsonObject(from: data) as? [String: Any],
      let models = object["data"] as? [[String: Any]]
    else {
      return (false, 0, [])
    }
    let routeIDs = models.compactMap { model in
      string(model["id"]) ?? string(model["slug"]) ?? string(model["model"])
    }
    return (true, models.count, routeIDs)
  }

  private static func jsonObject(from data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }

  private static func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }
}

public enum TatwoGatewayLiveProbe {
  typealias DataLoader = @Sendable (URL, TimeInterval) async throws -> Data

  public static func endpoint(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> URL
  {
    if let explicit = environment["TATWO_MODEL_GATEWAY_URL"],
      let url = URL(string: explicit.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme != nil
    {
      return url
    }
    if let responses = environment["TATWO_MODEL_GATEWAY_RESPONSES_URL"],
      let url = URL(string: responses.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme != nil
    {
      return url.deletingLastPathComponent().deletingLastPathComponent()
    }
    return URL(string: "http://127.0.0.1:4177")!
  }

  public static func fetch(
    endpoint: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 1.5
  ) async -> TatwoGatewayLiveStatus {
    await fetch(
      endpoint: endpoint,
      environment: environment,
      timeout: timeout,
      dataLoader: requestData
    )
  }

  static func fetch(
    endpoint: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 1.5,
    dataLoader: @escaping DataLoader
  ) async -> TatwoGatewayLiveStatus {
    let root = endpoint ?? self.endpoint(environment: environment)
    let healthURL = root.appendingPathComponent("healthz")
    let catalogURL = root.appendingPathComponent("v1/models")
    do {
      async let health = dataLoader(healthURL, timeout)
      async let catalog = dataLoader(catalogURL, timeout)
      let healthData = try await health
      let catalogData = try? await catalog
      return TatwoGatewayHealthDecoder.decode(
        healthData: healthData,
        catalogData: catalogData,
        endpoint: root,
        requiredRouteIDs: TatwoChatRouteProfile.defaults
          .filter { $0.runtimeAdapter == .gatewayDirect }
          .map(\.canonicalModelSlug)
      )
    } catch {
      return .unavailable(endpoint: root, reason: "healthz request failed")
    }
  }

  public static func fetchSynchronously(
    endpoint: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 1.5
  ) -> TatwoGatewayLiveStatus {
    let root = endpoint ?? self.endpoint(environment: environment)
    let box = LiveStatusBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      box.set(await fetch(endpoint: root, environment: environment, timeout: timeout))
      semaphore.signal()
    }
    let waitResult = semaphore.wait(
      timeout: .now() + max(0.5, timeout + 0.5)
    )
    guard waitResult == .success, let status = box.get() else {
      return .unavailable(endpoint: root, reason: "live probe timeout")
    }
    return status
  }

  private static func requestData(from url: URL, timeout: TimeInterval) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = max(0.2, timeout)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    return data
  }
}

private final class LiveStatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TatwoGatewayLiveStatus?

  func set(_ value: TatwoGatewayLiveStatus) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> TatwoGatewayLiveStatus? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
