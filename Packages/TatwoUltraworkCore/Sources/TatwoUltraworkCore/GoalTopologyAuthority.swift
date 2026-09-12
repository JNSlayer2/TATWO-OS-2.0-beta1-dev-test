import Foundation

/// Decides whether one `/goal` submission may bind an Ultrawork (multi-model)
/// topology to its thread.
///
/// 2026-08-27 live regression (staging61, thread `34b8b85a…`): an ordinary
/// `/goal <objective>` typed from a GPT-5.6 Terra thread was classified as a
/// development request by the visible-turn intent classifier, which was then
/// treated as permission to bind the exact XXL Sol/Opus native-development
/// scenario. The thread was mutated to `ultrawork XXL`, an XXL contract was
/// minted, and the runner left the composing Terra route.
///
/// Intent classification answers "does this turn ask for development work".
/// It must never answer "did the user ask for an Ultrawork topology". Only an
/// explicit current-revision request may do that:
///
/// * the Ultrawork collaboration control is already enabled for this thread
///   revision (the user turned it on), or
/// * the same command carries an executable `$tatwo-ultrawork` control line, or
/// * the same command literally names an Ultrawork/XXL topology.
///
/// Anything else — including a thread that still carries a stale XXL
/// `loopsConfig` from an earlier revision — resolves to `.singleModel`.
public enum TatwoGoalTopologyAuthority {
  public enum Topology: String, Sendable, Equatable {
    case singleModel = "single_model"
    case ultrawork
  }

  /// - Parameters:
  ///   - commandText: the exact submitted command for this revision.
  ///   - explicitUltraworkRequest: an out-of-band explicit request from the
  ///     current revision — today only the Plan canvas, where the user picks
  ///     Ultrawork collaboration and Goal as the destination in one action.
  ///
  /// The thread's carried `loopsConfig` is deliberately **not** an input.
  /// 2026-08-27 staging61: thread `34b8b85a…` was left holding
  /// `general-xxl-sol-opus5-luna-grok-exact` (mode XXL,
  /// `primaryModelID: gpt-5.5`) from an earlier `/plan`. Because "thread has a
  /// loops config" is the App's definition of "collaboration enabled", the
  /// next ordinary `/goal` inherited both the XXL topology and the stale
  /// `gpt-5.5` model override, and the composing GPT-5.6 Terra route was
  /// silently replaced. Carried thread state is exactly the stale inheritance
  /// this policy exists to stop, so it can never be its own authority.
  public static func requestedTopology(
    commandText: String,
    explicitUltraworkRequest: Bool = false
  ) -> Topology {
    if explicitUltraworkRequest { return .ultrawork }
    return explicitlyNamesUltraworkTopology(in: commandText)
      ? .ultrawork
      : .singleModel
  }

  /// Explicit topology tokens. `xl` alone is deliberately absent: it collides
  /// with ordinary prose and file names far too often to be an authority
  /// signal.
  private static let topologyPattern =
    #"(?:\bultra[\s_-]*work\b|\bxxl\b|超級協作|多模型協作)"#

  private static let negationPattern =
    #"(?:不要|不用|不需|不需要|別|别|請勿|请勿|禁止|停用|關閉|关闭|避免|no|not|without|never|avoid|disable|off|don['’]?t)"#

  /// True when the exact command text carries an executable Ultrawork control
  /// line or literally names an Ultrawork/XXL topology.
  ///
  /// Fenced blocks and blockquotes are documentation, not authority, and a
  /// negated mention ("不要 ultrawork", "without XXL") is an explicit refusal.
  public static func explicitlyNamesUltraworkTopology(
    in commandText: String
  ) -> Bool {
    var fenced = false
    for rawLine in commandText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
    {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        fenced.toggle()
        continue
      }
      guard !fenced, !line.hasPrefix(">"), !line.isEmpty else { continue }
      if lineNamesUltraworkTopology(line.lowercased()) { return true }
    }
    return false
  }

  private static func lineNamesUltraworkTopology(_ line: String) -> Bool {
    if line.hasPrefix("$tatwo-ultrawork") {
      // The control-line dialect is owned by the Chat composer. Reaching here
      // means the marker starts the line; a negated directive is handled by
      // the shared negation guard below.
      return !isNegated(line, around: line.startIndex)
    }
    guard let match = line.range(
      of: topologyPattern,
      options: .regularExpression)
    else { return false }
    return !isNegated(line, around: match.lowerBound)
  }

  private static func isNegated(
    _ line: String,
    around index: String.Index
  ) -> Bool {
    let windowStart = line.index(
      index,
      offsetBy: -24,
      limitedBy: line.startIndex) ?? line.startIndex
    let window = String(line[windowStart..<index])
    return window.range(
      of: negationPattern,
      options: .regularExpression) != nil
  }
}
