import Foundation
import TatwoUltraworkCore
#if canImport(Darwin)
import Darwin
#endif

/// Cross-process race helper for Wave 0 package G tests.
/// File-store only (O_EXCL); never touches production Keychain.
///
/// Usage:
///   claim --root <dir> --job-id <id> --nonce <n> --digest <d> --barrier <dir> --result <file>
///   consume --root <dir> --job-id <id> --nonce <n> --digest <d> --result-digest <rd> --seq <n> --barrier <dir> --result <file>
///   seal --store <file> --channel <dir> --host <id> --app-support-base <dir> --barrier <dir> --result <file>
///   claim-hold-lock --root <dir> --job-id <id> --nonce <n> --digest <d> --barrier <dir> --hold-ms <ms> --result <file>
@main
enum TatwoAntiRollbackRaceHelper {
  static func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
      fputs("usage: tatwo-ar-race-helper claim|consume|seal|claim-hold-lock ...\n", stderr)
      exit(2)
    }
    args.removeFirst()
    switch command {
    case "claim":
      try runClaim(args)
    case "consume":
      try runConsume(args)
    case "seal":
      try runSeal(args)
    case "claim-hold-lock":
      try runClaimHoldLock(args)
    default:
      fputs("unknown command: \(command)\n", stderr)
      exit(2)
    }
  }

  private static func runClaim(_ args: [String]) throws {
    let root = try required("--root", in: args)
    let jobID = try required("--job-id", in: args)
    let nonce = try required("--nonce", in: args)
    let digest = try required("--digest", in: args)
    let barrier = try required("--barrier", in: args)
    let resultPath = try required("--result", in: args)
    try waitBarrier(URL(fileURLWithPath: barrier, isDirectory: true))
    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: URL(fileURLWithPath: root, isDirectory: true))
    let outcome = claimOutcome(
      jobID: jobID, nonce: nonce, digest: digest, anchor: anchor)
    try writeResult(outcome, to: resultPath)
  }

  private static func runConsume(_ args: [String]) throws {
    let root = try required("--root", in: args)
    let jobID = try required("--job-id", in: args)
    let nonce = try required("--nonce", in: args)
    let digest = try required("--digest", in: args)
    let resultDigest = try required("--result-digest", in: args)
    let seq = UInt64(try required("--seq", in: args)) ?? 0
    let barrier = try required("--barrier", in: args)
    let resultPath = try required("--result", in: args)
    try waitBarrier(URL(fileURLWithPath: barrier, isDirectory: true))
    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: URL(fileURLWithPath: root, isDirectory: true))
    do {
      try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
        jobID: jobID,
        dispatchNonce: nonce,
        jobCanonicalDigest: digest,
        resultDigest: resultDigest,
        projectionSequence: seq,
        anchor: anchor)
      try writeResult("ok", to: resultPath)
    } catch {
      try writeResult("error:\(error)", to: resultPath)
      exit(1)
    }
  }

  private static func runSeal(_ args: [String]) throws {
    let storePath = try required("--store", in: args)
    let channel = try required("--channel", in: args)
    let host = try required("--host", in: args)
    let base = try required("--app-support-base", in: args)
    let barrier = try required("--barrier", in: args)
    let resultPath = try required("--result", in: args)
    try waitBarrier(URL(fileURLWithPath: barrier, isDirectory: true))
    let store = TatwoProductionInstallAnchorFileStore(
      url: URL(fileURLWithPath: storePath))
    do {
      let sealed = try TatwoProductionLayoutLock.sealInstallAnchor(
        hostDeviceID: host,
        requestedChannelRoot: URL(fileURLWithPath: channel, isDirectory: true),
        environment: [:],
        installAnchorStore: store,
        applicationSupportBase: URL(fileURLWithPath: base, isDirectory: true))
      try writeResult("ok:\(sealed.jobChannelRoot.path)", to: resultPath)
    } catch {
      try writeResult("error:\(error)", to: resultPath)
      // non-zero so parent can count winners by result content; exit 0 if file written
      exit(0)
    }
  }

  /// Hold cooperative lock, then claim — parent may unlink lock pathname mid-hold.
  private static func runClaimHoldLock(_ args: [String]) throws {
    let root = try required("--root", in: args)
    let jobID = try required("--job-id", in: args)
    let nonce = try required("--nonce", in: args)
    let digest = try required("--digest", in: args)
    let barrier = try required("--barrier", in: args)
    let holdMs = Int(try required("--hold-ms", in: args)) ?? 200
    let resultPath = try required("--result", in: args)
    let barrierURL = URL(fileURLWithPath: barrier, isDirectory: true)
    try waitBarrier(barrierURL)
    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: URL(fileURLWithPath: root, isDirectory: true))
    try Data("holding\n".utf8).write(
      to: barrierURL.appendingPathComponent("holding-\(ProcessInfo.processInfo.processIdentifier)"))
    // Cooperative flock only — claim correctness must not depend on this inode.
    let lockURL = anchor.mutationLockURL.appendingPathExtension("lock")
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if canImport(Darwin)
    let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else {
      try writeResult("error:open_lock", to: resultPath)
      exit(1)
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      try writeResult("error:flock", to: resultPath)
      exit(1)
    }
    defer { _ = flock(fd, LOCK_UN) }
    #endif
    Thread.sleep(forTimeInterval: Double(holdMs) / 1000.0)
    let outcome = claimOutcome(jobID: jobID, nonce: nonce, digest: digest, anchor: anchor)
    try writeResult(outcome, to: resultPath)
  }

  private static func claimOutcome(
    jobID: String,
    nonce: String,
    digest: String,
    anchor: TatwoLoopGlobalAntiRollbackFileAnchor
  ) -> String {
    do {
      try TatwoProductionLayoutLock.claimTargetExecution(
        jobID: jobID,
        dispatchNonce: nonce,
        jobCanonicalDigest: digest,
        anchor: anchor)
      return "created"
    } catch TatwoProductionLayoutError.targetExecutionAlreadyClaimed {
      return "already_claimed"
    } catch TatwoProductionLayoutError.globalAntiRollbackRegression {
      return "binding_conflict"
    } catch {
      return "error:\(error)"
    }
  }

  private static func waitBarrier(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ready = dir.appendingPathComponent("ready-\(ProcessInfo.processInfo.processIdentifier)")
    try Data("1".utf8).write(to: ready)
    let go = dir.appendingPathComponent("go")
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: go.path) {
      if Date() > deadline {
        fputs("barrier timeout waiting for go\n", stderr)
        exit(3)
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private static func writeResult(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((text + "\n").utf8).write(to: url, options: .atomic)
  }

  private static func required(_ flag: String, in args: [String]) throws -> String {
    guard let idx = args.firstIndex(of: flag), args.index(after: idx) < args.endIndex else {
      throw NSError(
        domain: "TatwoAntiRollbackRaceHelper", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "missing \(flag)"])
    }
    return args[args.index(after: idx)]
  }
}
