#if os(macOS)
import Darwin
import Foundation

public final class TatwoNativePTYTerminalSession: @unchecked Sendable {
  private var outputRevision: UInt64 = 0
  private var promptTail = ""
  private let onStatusChange: @Sendable (CLISessionStatus, Int32?) -> Void
  private let launch: TatwoNativeTerminalLaunch
  private let onData: @Sendable (Data) -> Void
  private let onUpdate: @Sendable ([TatwoTerminalLine]) -> Void
  private let onStatus: @Sendable (TatwoNativeTerminalStatus) -> Void
  private let queue = DispatchQueue(label: "tatwo.native-terminal.pty", qos: .userInitiated)
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let reaperQueue = DispatchQueue(label: "tatwo.native-terminal.pty.reaper", qos: .utility)
  private let lock = NSLock()
  private let throttleNanoseconds: UInt64
  private let transportOnly: Bool

  private var childPID: pid_t = 0
  private var masterFileDescriptor: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var generation: UInt64 = 0
  private var requestedColumns: Int
  private var requestedRows: Int
  private var screenBuffer: TatwoTerminalScreenBuffer
  private var pendingUTF8 = Data()
  private var flushScheduled = false

  public init(
    launch: TatwoNativeTerminalLaunch,
    columns: Int = 120,
    rows: Int = 40,
    maxLineCount: Int = 1_200,
    throttleInterval: TimeInterval = 0.05,
    transportOnly: Bool = false,
    onStatusChange: @escaping @Sendable (CLISessionStatus, Int32?) -> Void = { _, _ in },
    onData: @escaping @Sendable (Data) -> Void = { _ in },
    onUpdate: @escaping @Sendable ([TatwoTerminalLine]) -> Void,
    onStatus: @escaping @Sendable (TatwoNativeTerminalStatus) -> Void
  ) {
    let boundedColumns = Self.boundedDimension(columns)
    let boundedRows = Self.boundedDimension(rows)
    self.launch = launch
    self.requestedColumns = boundedColumns
    self.requestedRows = boundedRows
    self.onStatusChange = onStatusChange
    self.onData = onData
    self.onUpdate = onUpdate
    self.onStatus = onStatus
    self.throttleNanoseconds = UInt64(max(0.016, throttleInterval) * 1_000_000_000)
    self.transportOnly = transportOnly
    self.screenBuffer = TatwoTerminalScreenBuffer(
      maxLineCount: maxLineCount,
      columns: boundedColumns,
      rows: boundedRows
    )
    self.queue.setSpecific(key: queueKey, value: 1)
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return childPID > 0 && masterFileDescriptor >= 0
  }

  public func start(seedText: String? = nil) {
    queue.async { [weak self] in
      guard let self else { return }
      self.terminateActiveSession()
      self.startOnQueue(seedText: seedText)
    }
  }

  public func send(_ data: Data) {
    guard !data.isEmpty else { return }
    queue.async { [weak self] in
      guard let self, self.isRunning else { return }
      self.outputRevision &+= 1
      self.promptTail = ""
      self.onStatusChange(.running, nil)
      self.writeOnQueue(data)
    }
  }

  public func send(bytes: [UInt8]) {
    send(Data(bytes))
  }

  public func sendLine(_ text: String) {
    send(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
  }

  @discardableResult
  public func resize(columns: Int, rows: Int) -> Bool {
    let boundedColumns = Self.boundedDimension(columns)
    let boundedRows = Self.boundedDimension(rows)

    return syncOnQueue {
      lock.lock()
      requestedColumns = boundedColumns
      requestedRows = boundedRows
      let descriptor = masterFileDescriptor
      lock.unlock()
      self.screenBuffer.resize(columns: boundedColumns, rows: boundedRows)
      self.scheduleFlushOnQueue()

      guard descriptor >= 0 else { return false }
      var size = Self.windowSize(columns: boundedColumns, rows: boundedRows)
      return ioctl(descriptor, TIOCSWINSZ, &size) == 0
    }
  }

  public func terminate() {
    syncOnQueue {
      terminateActiveSession()
    }
  }

  private func startOnQueue(seedText: String?) {
    generation &+= 1
    let currentGeneration = generation

    outputRevision &+= 1
    promptTail = ""
    onStatusChange(.running, nil)
    emitStatus(.starting)
    screenBuffer.clear()
    pendingUTF8.removeAll(keepingCapacity: true)
    if let seedText, !seedText.isEmpty {
      screenBuffer.append(seedText)
      scheduleFlushOnQueue()
    }

    lock.lock()
    let columns = requestedColumns
    let rows = requestedRows
    lock.unlock()
    screenBuffer.resize(columns: columns, rows: rows)

    let arguments = [launch.executable] + launch.arguments
    let environment = launchEnvironment()
    guard
      var argumentPointers = duplicatedCStrings(arguments),
      var environmentPointers = duplicatedCStrings(environment),
      let executablePointer = argumentPointers.first ?? nil,
      let workingDirectoryPointer = strdup(launch.workingDirectory.path)
    else {
      emitStatus(.failed("pty launch argument allocation failed"))
      return
    }
    defer {
      freeDuplicatedCStrings(&argumentPointers)
      freeDuplicatedCStrings(&environmentPointers)
      free(workingDirectoryPointer)
    }

    var master: Int32 = -1
    var size = Self.windowSize(columns: columns, rows: rows)
    var spawnedPID: pid_t = -1

    argumentPointers.withUnsafeMutableBufferPointer { argv in
      environmentPointers.withUnsafeMutableBufferPointer { envp in
        spawnedPID = forkpty(&master, nil, nil, &size)
        if spawnedPID == 0 {
          var signalMask = sigset_t()
          sigemptyset(&signalMask)
          _ = sigprocmask(SIG_SETMASK, &signalMask, nil)
          _ = signal(SIGHUP, SIG_DFL)
          _ = signal(SIGINT, SIG_DFL)
          _ = signal(SIGQUIT, SIG_DFL)
          _ = signal(SIGPIPE, SIG_DFL)
          _ = signal(SIGTERM, SIG_DFL)
          _ = signal(SIGCHLD, SIG_DFL)
          _ = signal(SIGTSTP, SIG_DFL)
          _ = signal(SIGTTIN, SIG_DFL)
          _ = signal(SIGTTOU, SIG_DFL)
          _ = signal(SIGWINCH, SIG_DFL)
          if chdir(workingDirectoryPointer) != 0 {
            _exit(126)
          }
          execve(executablePointer, argv.baseAddress, envp.baseAddress)
          _exit(127)
        }
      }
    }

    guard spawnedPID > 0, master >= 0 else {
      let message = String(cString: strerror(errno))
      emitStatus(.failed("forkpty failed: \(message)"))
      return
    }

    let currentFlags = fcntl(master, F_GETFL)
    if currentFlags >= 0 {
      _ = fcntl(master, F_SETFL, currentFlags | O_NONBLOCK)
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
    source.setEventHandler { [weak self] in
      self?.drainMasterOnQueue(fileDescriptor: master, generation: currentGeneration)
    }
    source.setCancelHandler {}

    lock.lock()
    childPID = spawnedPID
    masterFileDescriptor = master
    readSource = source
    lock.unlock()

    source.resume()
    emitStatus(.running(pid: spawnedPID))
    reap(spawnedPID, generation: currentGeneration)
  }

  private func launchEnvironment() -> [String] {
    var environment = ProcessInfo.processInfo.environment
    if environment["TERM"] == nil || environment["TERM"] == "dumb" {
      environment["TERM"] = "xterm-256color"
    }
    environment["CLICOLOR"] = environment["CLICOLOR"] ?? "1"
    environment["PS1"] = environment["PS1"] ?? "%F{cyan}tatwo%f %1~ %# "
    for (key, value) in launch.environment {
      environment[key] = value
    }
    return environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
  }

  private func drainMasterOnQueue(fileDescriptor: Int32, generation: UInt64) {
    guard generation == self.generation else { return }
    var storage = [UInt8](repeating: 0, count: 16_384)

    while true {
      let count = Darwin.read(fileDescriptor, &storage, storage.count)
      if count > 0 {
        consumeOnQueue(Data(storage.prefix(Int(count))))
        continue
      }
      if count == 0 {
        return
      }
      if errno == EINTR {
        continue
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }
      return
    }
  }

  private func consumeOnQueue(_ data: Data) {
    guard !data.isEmpty else { return }
    // The workbench delegates parsing/rendering to SwiftTerm. This is only PTY transport.
    if transportOnly {
      DispatchQueue.main.async { [onData] in onData(data) }
      return
    }
    outputRevision &+= 1
    let revision = outputRevision
    let currentGeneration = generation
    promptTail = String((promptTail + String(decoding: data, as: UTF8.self)).suffix(4096))
    onStatusChange(.running, nil)
    queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self, self.generation == currentGeneration,
            self.outputRevision == revision, self.isRunning else { return }
      let clean = self.promptTail.replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
      let last = clean.components(separatedBy: .newlines).last ?? ""
      if ["$ ", "% ", "> ", "? ", ": "].contains(where: last.hasSuffix) || last.contains("[y/N]") {
        self.onStatusChange(.waitingInput, nil)
      }
    }
    DispatchQueue.main.async { [onData] in
      onData(data)
    }

    pendingUTF8.append(data)
    if let text = String(data: pendingUTF8, encoding: .utf8) {
      pendingUTF8.removeAll(keepingCapacity: true)
      screenBuffer.append(text)
      scheduleFlushOnQueue()
      return
    }

    let maximumIncompleteSuffix = min(3, pendingUTF8.count)
    if maximumIncompleteSuffix > 0 {
      for suffixLength in 1...maximumIncompleteSuffix {
        let prefixCount = pendingUTF8.count - suffixLength
        guard prefixCount > 0 else { continue }
        let prefix = pendingUTF8.prefix(prefixCount)
        if let text = String(data: prefix, encoding: .utf8) {
          let suffix = pendingUTF8.suffix(suffixLength)
          pendingUTF8 = Data(suffix)
          screenBuffer.append(text)
          scheduleFlushOnQueue()
          return
        }
      }
    }

    screenBuffer.append(String(decoding: pendingUTF8, as: UTF8.self))
    pendingUTF8.removeAll(keepingCapacity: true)
    scheduleFlushOnQueue()
  }

  private func writeOnQueue(_ data: Data) {
    lock.lock()
    let descriptor = masterFileDescriptor
    lock.unlock()
    guard descriptor >= 0 else { return }

    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var written = 0
      var retryCount = 0
      while written < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          rawBuffer.count - written
        )
        if result > 0 {
          written += result
          retryCount = 0
        } else if result < 0, errno == EINTR {
          continue
        } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          retryCount += 1
          if retryCount > 100 { return }
          usleep(1_000)
        } else {
          return
        }
      }
    }
  }

  private func reap(_ pid: pid_t, generation: UInt64) {
    reaperQueue.async { [weak self] in
      var status: Int32 = 0
      var result: pid_t
      repeat {
        result = waitpid(pid, &status, 0)
      } while result == -1 && errno == EINTR

      guard result == pid else { return }
      let exitStatus = Self.normalizedExitStatus(status)
      self?.queue.async { [weak self] in
        self?.finishOnQueue(pid: pid, generation: generation, exitStatus: exitStatus)
      }
    }
  }

  private func finishOnQueue(pid: pid_t, generation: UInt64, exitStatus: Int32) {
    lock.lock()
    guard self.generation == generation, childPID == pid else {
      lock.unlock()
      return
    }
    let descriptor = masterFileDescriptor
    let source = readSource
    childPID = 0
    masterFileDescriptor = -1
    readSource = nil
    lock.unlock()

    source?.cancel()
    if descriptor >= 0 {
      Darwin.close(descriptor)
    }
    outputRevision &+= 1
    onStatusChange(.exited, exitStatus)
    emitStatus(.exited(exitStatus))
  }

  private func terminateActiveSession() {
    lock.lock()
    let pid = childPID
    let descriptor = masterFileDescriptor
    let source = readSource
    masterFileDescriptor = -1
    readSource = nil
    lock.unlock()

    source?.cancel()
    if descriptor >= 0 {
      Darwin.close(descriptor)
    }
    guard pid > 0 else { return }

    _ = kill(pid, SIGHUP)
    _ = killpg(pid, SIGHUP)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
      if kill(pid, 0) == 0 {
        _ = kill(pid, SIGTERM)
        _ = killpg(pid, SIGTERM)
      }
    }
  }

  private func scheduleFlushOnQueue() {
    guard !flushScheduled else { return }
    flushScheduled = true
    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(throttleNanoseconds))) { [weak self] in
      guard let self else { return }
      self.flushScheduled = false
      let lines = self.screenBuffer.lines
      DispatchQueue.main.async { [onUpdate] in
        onUpdate(lines)
      }
    }
  }

  private func emitStatus(_ status: TatwoNativeTerminalStatus) {
    if case .failed = status { onStatusChange(.exited, nil) }
    DispatchQueue.main.async { [onStatus] in
      onStatus(status)
    }
  }

  private func syncOnQueue<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) == 1 {
      return work()
    }
    return queue.sync(execute: work)
  }

  private static func boundedDimension(_ value: Int) -> Int {
    min(Int(UInt16.max), max(1, value))
  }

  private static func windowSize(columns: Int, rows: Int) -> winsize {
    winsize(
      ws_row: UInt16(boundedDimension(rows)),
      ws_col: UInt16(boundedDimension(columns)),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
  }

  private static func normalizedExitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7F
    if signal == 0 {
      return (status >> 8) & 0xFF
    }
    return 128 + signal
  }

  private func duplicatedCStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?]? {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(values.count + 1)
    for value in values {
      guard let pointer = strdup(value) else {
        freeDuplicatedCStrings(&pointers)
        return nil
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    return pointers
  }

  private func freeDuplicatedCStrings(_ pointers: inout [UnsafeMutablePointer<CChar>?]) {
    for pointer in pointers {
      if let pointer {
        free(pointer)
      }
    }
    pointers.removeAll(keepingCapacity: false)
  }

  deinit {
    terminateActiveSession()
  }
}
#endif
