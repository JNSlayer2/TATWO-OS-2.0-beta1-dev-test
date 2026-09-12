import CryptoKit
import Darwin
import Foundation

public struct TatwoGitHubRepoBinding: Codable, Sendable, Equatable, Hashable {
  public enum Visibility: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case pub = "public"
    case priv = "private"
    case unknown
  }

  public var url: String
  public var accountLabel: String
  public var visibility: Visibility
  public var hasUpdate: Bool
  public var lastCheckedISO: String?

  public init(
    url: String,
    accountLabel: String,
    visibility: Visibility = .unknown,
    hasUpdate: Bool = false,
    lastCheckedISO: String? = nil
  ) {
    self.url = url
    self.accountLabel = accountLabel
    self.visibility = visibility
    self.hasUpdate = hasUpdate
    self.lastCheckedISO = lastCheckedISO
  }
}

public struct TatwoNativeChatProject: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var workdir: String
  public var isExpanded: Bool
  public var threads: [TatwoNativeChatThread]
  /// A project can be mirrored to several GitHub repos (one per account /
  /// mirror). Ordered; the first entry is the primary.
  public var githubRepos: [TatwoGitHubRepoBinding]
  public var sessions: [TatwoNativeCLISession]

  /// Legacy single-repo accessor kept for callers and the on-disk format;
  /// reads/writes the primary (first) binding.
  public var githubRepo: TatwoGitHubRepoBinding? {
    get { githubRepos.first }
    set {
      if let newValue {
        if githubRepos.isEmpty { githubRepos = [newValue] } else { githubRepos[0] = newValue }
      } else if !githubRepos.isEmpty {
        githubRepos.removeFirst()
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case workdir
    case isExpanded
    case threads
    case githubRepo
    case githubRepos
    case sessions
  }

  public init(
    id: UUID = UUID(),
    name: String,
    workdir: String,
    isExpanded: Bool = true,
    threads: [TatwoNativeChatThread] = [],
    githubRepo: TatwoGitHubRepoBinding? = nil,
    githubRepos: [TatwoGitHubRepoBinding]? = nil,
    sessions: [TatwoNativeCLISession] = []
  ) {
    self.id = id
    self.name = name
    self.workdir = workdir
    self.isExpanded = isExpanded
    self.threads = threads
    self.githubRepos = githubRepos ?? githubRepo.map { [$0] } ?? []
    self.sessions = sessions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.workdir = try container.decode(String.self, forKey: .workdir)
    self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    self.threads = try container.decodeIfPresent([TatwoNativeChatThread].self, forKey: .threads) ?? []
    if let repos = try container.decodeIfPresent([TatwoGitHubRepoBinding].self, forKey: .githubRepos) {
      self.githubRepos = repos
    } else {
      self.githubRepos = try container.decodeIfPresent(TatwoGitHubRepoBinding.self, forKey: .githubRepo).map { [$0] } ?? []
    }
    self.sessions = try container.decodeIfPresent([TatwoNativeCLISession].self, forKey: .sessions) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(workdir, forKey: .workdir)
    try container.encode(isExpanded, forKey: .isExpanded)
    try container.encode(threads, forKey: .threads)
    try container.encode(githubRepos, forKey: .githubRepos)
    // Older builds (e.g. the other synced device) still read the single key.
    try container.encodeIfPresent(githubRepos.first, forKey: .githubRepo)
    try container.encode(sessions, forKey: .sessions)
  }
}
