import Foundation

public enum TatwoUIFireworksBranchKind: String, Codable, Sendable, CaseIterable, Equatable {
  case exploration
  case review
  case adversarialRefinement = "adversarial_refinement"
  case synthesis
}

public struct TatwoUIFireworksBranch: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: TatwoUIFireworksBranchKind
  public let title: String
  public let plainPurpose: String

  public init(
    id: String,
    kind: TatwoUIFireworksBranchKind,
    title: String,
    plainPurpose: String
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.plainPurpose = plainPurpose
  }
}

public struct TatwoUIFireworksReviewDimension: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainPurpose: String

  public init(id: String, title: String, plainPurpose: String) {
    self.id = id
    self.title = title
    self.plainPurpose = plainPurpose
  }
}

public enum TatwoUIFireworksLoopTemplate {
  public static let id = "ui-fireworks"
  public static let displayName = "UI 煙火線"
  public static let shortLabel = "UI 煙火線"
  public static let plainDescription = "N 個方向並行→八維評審→紅隊精煉→單一交付"
  public static let branchStructureLabel = "探索×N / 評審 / 對抗精煉 / 合成"

  public static let reviewDimensions: [TatwoUIFireworksReviewDimension] = [
    TatwoUIFireworksReviewDimension(id: "hierarchy", title: "層級", plainPurpose: "畫面主次、視覺焦點與資訊層級是否清楚。"),
    TatwoUIFireworksReviewDimension(id: "typography", title: "排版", plainPurpose: "文字、間距、對齊、閱讀節奏是否穩定。"),
    TatwoUIFireworksReviewDimension(id: "color", title: "色彩", plainPurpose: "配色、對比、狀態色與品牌氛圍是否成立。"),
    TatwoUIFireworksReviewDimension(id: "motion", title: "動效", plainPurpose: "互動、轉場與動態提示是否幫助理解而非干擾。"),
    TatwoUIFireworksReviewDimension(id: "craft", title: "工藝", plainPurpose: "細節完成度、玻璃/材質/邊界處理與工程可落地性。"),
    TatwoUIFireworksReviewDimension(id: "delight", title: "趣味", plainPurpose: "是否有記憶點、驚喜感與產品個性。"),
    TatwoUIFireworksReviewDimension(id: "at-a-glance", title: "一眼懂", plainPurpose: "首屏 10 秒內是否能知道這頁要做什麼。"),
    TatwoUIFireworksReviewDimension(id: "inside-outside-consistency", title: "表裡一致", plainPurpose: "UI 顯示、狀態、store 與真實權限/流程是否一致。"),
  ]

  public static func explorationBranchCount(for mode: WorkModeID) -> Int {
    switch mode {
    case .s: return 2
    case .m: return 3
    case .l: return 5
    case .xl: return 8
    case .xxl: return 12
    }
  }

  public static func totalBranchCount(for mode: WorkModeID) -> Int {
    explorationBranchCount(for: mode) + 3
  }

  public static func branchStructure(for mode: WorkModeID) -> [TatwoUIFireworksBranch] {
    let n = explorationBranchCount(for: mode)
    let explorations = (1...n).map { index in
      TatwoUIFireworksBranch(
        id: "ui-fireworks-exploration-\(index)",
        kind: .exploration,
        title: "探索 \(index)/\(n)",
        plainPurpose: "配發不同設計立場，產出完整方案、立場聲明、取捨表與快照。")
    }
    return explorations + [
      TatwoUIFireworksBranch(
        id: "ui-fireworks-review",
        kind: .review,
        title: "八維評審",
        plainPurpose: "用八維 0-10 評分卡比較每個方案，標出最強與最弱一點。"),
      TatwoUIFireworksBranch(
        id: "ui-fireworks-adversarial-refinement",
        kind: .adversarialRefinement,
        title: "對抗精煉",
        plainPurpose: "Top-2 互為紅隊，各指出三個缺陷，由主導裁決是否成立。"),
      TatwoUIFireworksBranch(
        id: "ui-fireworks-synthesis",
        kind: .synthesis,
        title: "合成",
        plainPurpose: "冠軍為骨、嫁接亞軍最強元素、修成立缺陷，收斂成單一交付候選。"),
    ]
  }
}
