import Darwin
import Foundation

public struct TatwoMCPHTTPHealth: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let server: String
  public let engineAgnostic: Bool
  public let defaultHostEngine: String
  public let hostMutationAllowed: Bool
  public let plainSummary: String

  public init(
    schema: String = "TatwoMCPHTTPHealthV1",
    ok: Bool = true,
    server: String = "tatwo-ultrawork-app-mcp",
    engineAgnostic: Bool = true,
    defaultHostEngine: String = EngineID.codex.rawValue,
    hostMutationAllowed: Bool = false,
    plainSummary: String = "Tatwo App MCP is reachable over local HTTP; Codex is the highest-fit host, not the only client."
  ) {
    self.schema = schema
    self.ok = ok
    self.server = server
    self.engineAgnostic = engineAgnostic
    self.defaultHostEngine = defaultHostEngine
    self.hostMutationAllowed = hostMutationAllowed
    self.plainSummary = plainSummary
  }
}

public struct TatwoMCPPortServeStatus: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let url: String
  public let port: UInt16
  public let transport: String
  public let hostMutationAllowed: Bool
  public let fallbackAvailable: Bool
  public let endpoints: [String]
  public let cliExamples: [String]

  public init(
    schema: String = "TatwoMCPPortServeStatusV1",
    ok: Bool = true,
    url: String,
    port: UInt16,
    transport: String = "local-http",
    hostMutationAllowed: Bool = false,
    fallbackAvailable: Bool = true,
    endpoints: [String] = ["/health", "/manifest", "/tools/list", "/tools/call"],
    cliExamples: [String]
  ) {
    self.schema = schema
    self.ok = ok
    self.url = url
    self.port = port
    self.transport = transport
    self.hostMutationAllowed = hostMutationAllowed
    self.fallbackAvailable = fallbackAvailable
    self.endpoints = endpoints
    self.cliExamples = cliExamples
  }
}

public final class TatwoLocalMCPHTTPServer: @unchecked Sendable {
  public typealias ToolCaller = @Sendable (String, [String: JSONValue]) -> TatwoMCPToolCallResult

  private let lock = NSLock()
  private let toolCaller: ToolCaller
  private var socketFD: Int32 = -1
  private var running = false
  private var acceptThread: Thread?

  public private(set) var port: UInt16 = 0

  public init(
    toolCaller: @escaping ToolCaller = {
      TatwoMCPRegistry.call(tool: $0, arguments: $1)
    }
  ) {
    self.toolCaller = toolCaller
  }

  deinit {
    stop()
  }

  @discardableResult
  public func start(port requestedPort: UInt16 = 17377) throws -> UInt16 {
    lock.lock()
    defer { lock.unlock() }
    if running { return port }

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TatwoLocalMCPHTTPError.socket(errno) }
    // 2026-08-23 根治 bind_failed:48：監聽 socket 被 App spawn 的終端 zsh
    // 繼承，舊 App 退出後孤兒 shell 抱著 port 不放（8/13 的兩隻佔到 8/23）。
    // CLOEXEC 讓任何 exec 出去的子程序都拿不到這顆 fd。
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = requestedPort.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let code = errno
      close(fd)
      throw TatwoLocalMCPHTTPError.bind(code)
    }

    guard listen(fd, 16) == 0 else {
      let code = errno
      close(fd)
      throw TatwoLocalMCPHTTPError.listen(code)
    }

    var actual = sockaddr_in()
    var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(fd, sockaddrPointer, &actualLength)
      }
    }
    guard nameResult == 0 else {
      let code = errno
      close(fd)
      throw TatwoLocalMCPHTTPError.getsockname(code)
    }

    socketFD = fd
    port = UInt16(bigEndian: actual.sin_port)
    running = true
    let listenFD = fd
    let boundPort = port
    lock.unlock()

    let thread = Thread { [weak self] in
      self?.acceptLoop(fd: listenFD)
    }
    thread.name = "tatwo.local-mcp.http.accept"
    thread.qualityOfService = .utility
    thread.start()

    lock.lock()
    acceptThread = thread
    return boundPort
  }

  public func stop() {
    lock.lock()
    let fd = socketFD
    socketFD = -1
    running = false
    acceptThread = nil
    lock.unlock()
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      close(fd)
    }
  }

  public static func status(for port: UInt16) -> TatwoMCPPortServeStatus {
    let url = "http://127.0.0.1:\(port)"
    return TatwoMCPPortServeStatus(
      url: url,
      port: port,
      cliExamples: [
        "tatwo-ultrawork mcp call tatwo.mode.plan --app-url \(url) --mode L --scenario ui-ux --json",
        "tatwo-ultrawork mcp call tatwo.workflow.preview --app-url \(url) --mode XL --scenario coding --json",
        "curl \(url)/health",
      ])
  }

  private func acceptLoop(fd: Int32) {
    while isRunning {
      var clientAddress = sockaddr()
      var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(fd, &clientAddress, &clientLength)
      if client >= 0 { _ = fcntl(client, F_SETFD, FD_CLOEXEC) }
      if client < 0 {
        if isRunning { usleep(20_000) }
        continue
      }
      var noSigPipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      handle(client: client)
      close(client)
    }
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  private func handle(client: Int32) {
    do {
      let request = try readRequest(from: client)
      let response = try route(request)
      write(response: response, to: client)
    } catch TatwoLocalMCPHTTPError.badRequest {
      write(
        response: errorResponse(
          status: "400 Bad Request",
          error: "bad_request:malformed_http_request"),
        to: client)
    } catch {
      let safeError = TatwoPrivacyRedactor.redacted(error.localizedDescription)
      write(
        response: errorResponse(
          status: "500 Internal Server Error",
          error: "internal_error:\(safeError)"),
        to: client)
    }
  }

  private func route(_ request: HTTPRequest) throws -> HTTPResponse {
    switch (request.method, request.path) {
    case ("GET", "/health"):
      return HTTPResponse(status: "200 OK", body: try encode(TatwoMCPHTTPHealth()))
    case ("GET", "/manifest"):
      return HTTPResponse(status: "200 OK", body: try encode(TatwoMCPRegistry.manifest))
    case ("GET", "/tools/list"):
      return HTTPResponse(
        status: "200 OK",
        body: try encode(["tools": TatwoMCPRegistry.tools]))
    case ("POST", "/tools/call"):
      let object: [String: Any]
      do {
        guard
          let decoded = try JSONSerialization.jsonObject(with: request.body, options: [])
            as? [String: Any]
        else {
          return errorResponse(status: "400 Bad Request", error: "bad_request:tool_call_object_required")
        }
        object = decoded
      } catch {
        return errorResponse(status: "400 Bad Request", error: "bad_request:malformed_json")
      }
      let params = object["params"] as? [String: Any]
      guard let tool =
        object["tool"] as? String
        ?? object["name"] as? String
        ?? params?["name"] as? String
      else {
        return errorResponse(status: "400 Bad Request", error: "bad_request:missing_tool")
      }
      let rawArguments =
        object["arguments"] as? [String: Any]
        ?? params?["arguments"] as? [String: Any]
        ?? [:]
      let result = toolCaller(
        tool, rawArguments.mapValues { JSONValue.fromAny($0) })
      let data = try encode(
        TatwoMCPToolCallResult(
          tool: result.tool,
          ok: result.ok,
          payload: result.payload,
          error: result.error,
          failureKind: result.failureKind,
          fallbackCoreLibraryUsed: false,
          hostMutationAllowed: result.hostMutationAllowed))
      let status: String
      if result.ok {
        status = "200 OK"
      } else {
        switch result.failureKind {
        case .notFound:
          status = "404 Not Found"
        case .internalFailure:
          status = "500 Internal Server Error"
        case .contract, nil:
          status = result.error?.hasPrefix("unknown_tool:") == true
            ? "404 Not Found"
            : "422 Unprocessable Entity"
        }
      }
      return HTTPResponse(status: status, body: data)
    default:
      return errorResponse(
        status: "404 Not Found",
        error: "not_found:\(request.method):\(request.path)")
    }
  }

  private func errorResponse(status: String, error: String) -> HTTPResponse {
    let result = TatwoMCPToolCallResult(
      tool: "local-http",
      ok: false,
      payload: nil,
      error: error,
      fallbackCoreLibraryUsed: false)
    return HTTPResponse(
      status: status,
      body: (try? encode(result)) ?? Data("{\"schema\":\"TatwoMCPToolCallResultV1\",\"ok\":false}".utf8))
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private func write(response: HTTPResponse, to client: Int32) {
    write(status: response.status, body: response.body, to: client)
  }

  private func write(status: String, body: Data, to client: Int32) {
    let headers =
      "HTTP/1.1 \(status)\r\n"
      + "Content-Type: application/json; charset=utf-8\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Cache-Control: no-store\r\n"
      + "Connection: close\r\n"
      + "\r\n"
    writeAll(Data(headers.utf8), to: client)
    writeAll(body, to: client)
  }

  private func writeAll(_ data: Data, to client: Int32) {
    data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var sent = 0
      while sent < data.count {
        let result = Darwin.send(client, base.advanced(by: sent), data.count - sent, 0)
        if result > 0 {
          sent += result
        } else if result == -1 && errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
  }

  private func readRequest(from client: Int32) throws -> HTTPRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var expectedBodyLength = 0
    var headerEnd: Data.Index?

    while data.count < 1_048_576 {
      let count = recv(client, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      data.append(buffer, count: count)

      if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
        headerEnd = range.upperBound
        let headerData = data[..<range.lowerBound]
        let header = String(data: headerData, encoding: .utf8) ?? ""
        expectedBodyLength = contentLength(from: header)
        if expectedBodyLength == 0 { break }
      }

      if let headerEnd, data.count >= headerEnd + expectedBodyLength {
        break
      }
    }

    guard let headerEnd else { throw TatwoLocalMCPHTTPError.badRequest }
    let header = String(data: data[..<(headerEnd - 4)], encoding: .utf8) ?? ""
    let firstLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else { throw TatwoLocalMCPHTTPError.badRequest }

    let body = data[headerEnd..<min(data.count, headerEnd + expectedBodyLength)]
    return HTTPRequest(
      method: String(parts[0]).uppercased(),
      path: String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/",
      body: Data(body))
  }

  private func contentLength(from header: String) -> Int {
    for line in header.components(separatedBy: "\r\n") {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == "content-length"
      {
        return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
      }
    }
    return 0
  }
}

private struct HTTPRequest {
  let method: String
  let path: String
  let body: Data
}

private struct HTTPResponse {
  let status: String
  let body: Data
}

public enum TatwoLocalMCPHTTPError: Error, LocalizedError, Sendable {
  case socket(Int32)
  case bind(Int32)
  case listen(Int32)
  case getsockname(Int32)
  case badRequest

  public var errorDescription: String? {
    switch self {
    case .socket(let code): return "socket_failed:\(code)"
    case .bind(let code): return "bind_failed:\(code)"
    case .listen(let code): return "listen_failed:\(code)"
    case .getsockname(let code): return "getsockname_failed:\(code)"
    case .badRequest: return "bad_http_request"
    }
  }
}
