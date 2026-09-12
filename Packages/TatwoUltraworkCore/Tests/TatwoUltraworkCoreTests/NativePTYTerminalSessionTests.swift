import Foundation
import XCTest

@testable import TatwoUltraworkCore

#if os(macOS)
final class NativePTYTerminalSessionTests: XCTestCase {
  func testImmediateTerminateAfterStartDoesNotLeaveChildRunning() async throws {
    let probe = PTYProbe()
    let session = TatwoNativePTYTerminalSession(
      launch: TatwoNativeTerminalLaunch(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'READY\\n'; while :; do sleep 1; done"],
        workingDirectory: FileManager.default.temporaryDirectory
      ),
      throttleInterval: 0.016,
      onData: { probe.append($0) },
      onUpdate: { _ in },
      onStatus: { probe.append($0) }
    )
    defer { session.terminate() }

    session.start()
    session.terminate()
    try await waitUntil { probe.hasExited }

    XCTAssertFalse(session.isRunning)
  }

  func testPTYSessionProvidesTTYRawBytesResizeTerminateAndRestart() async throws {
    let probe = PTYProbe()
    let script = """
      if [ -t 0 ] && [ -t 1 ]; then printf 'TTY\\n'; else printf 'NOTTY\\n'; fi
      stty raw -echo
      bytes=$(dd bs=1 count=3 2>/dev/null | od -An -t u1 | tr -s ' ')
      printf 'BYTES:%s\\n' "$bytes"
      stty -raw -echo
      while IFS= read -r line; do
        if [ "$line" = size ]; then
          stty size
        else
          printf 'ECHO:%s\\n' "$line"
        fi
      done
      """
    let session = TatwoNativePTYTerminalSession(
      launch: TatwoNativeTerminalLaunch(
        executable: "/bin/sh",
        arguments: ["-c", script],
        workingDirectory: FileManager.default.temporaryDirectory
      ),
      columns: 80,
      rows: 24,
      throttleInterval: 0.016,
      onData: { probe.append($0) },
      onUpdate: { _ in },
      onStatus: { probe.append($0) }
    )

    session.start()
    try await waitUntil { probe.text.contains("TTY") && probe.runningCount == 1 }
    XCTAssertTrue(session.isRunning)
    XCTAssertFalse(probe.text.contains("NOTTY"))

    session.send(Data([0x1B, 0x5B, 0x41]))
    try await waitUntil {
      probe.text.contains("BYTES: 27 91 65") || probe.text.contains("BYTES:27 91 65")
    }

    XCTAssertTrue(session.resize(columns: 132, rows: 41))
    session.send(Data("size\n".utf8))
    try await waitUntil { probe.text.contains("41 132") }

    session.send(Data("hello\n".utf8))
    try await waitUntil { probe.text.contains("ECHO:hello") }

    session.terminate()
    try await waitUntil { !session.isRunning && probe.hasExited }

    session.start()
    try await waitUntil { probe.runningCount == 2 && probe.ttyCount == 2 }
    session.send(Data([0x1B, 0x5B, 0x41]))
    try await waitUntil { probe.bytesCount == 2 }

    session.terminate()
    try await waitUntil { !session.isRunning && probe.exitCount >= 2 }
  }

  private func waitUntil(
    timeout: TimeInterval = 5,
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for PTY condition")
    throw PTYTestError.timeout
  }
}

private enum PTYTestError: Error {
  case timeout
}

private final class PTYProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var statuses: [TatwoNativeTerminalStatus] = []

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    lock.unlock()
  }

  func append(_ status: TatwoNativeTerminalStatus) {
    lock.lock()
    statuses.append(status)
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }

  var runningCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return statuses.filter {
      if case .running = $0 { return true }
      return false
    }.count
  }

  var exitCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return statuses.filter {
      if case .exited = $0 { return true }
      return false
    }.count
  }

  var hasExited: Bool {
    exitCount > 0
  }

  var ttyCount: Int {
    text.components(separatedBy: "TTY").count - 1
  }

  var bytesCount: Int {
    text.components(separatedBy: "BYTES:").count - 1
  }
}
#endif
