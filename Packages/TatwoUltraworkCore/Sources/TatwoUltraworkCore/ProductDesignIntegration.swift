import Foundation

public enum TatwoProductDesignFactory {
  public static let screenshotGroundingRules = [
    "Product Design 只做 UI/UJ 副審收據；不當 builder、不當 final pass。",
    "必須使用本輪截圖或本輪可重現畫面；不接受模型純文字自評。",
    "它補的是可讀性、排版、流程理解、箭頭走位、首屏資訊層次與無障礙風險。",
    "不取代 Swift tests、web-check、layout audit、互動 smoke 或人類確認。",
  ]

  public static func receiptRequirements(
    mode: WorkModeID,
    scenarioProfileID: String
  ) -> [WorkOSReceiptRequirement] {
    guard isUIStrictScenario(scenarioProfileID) else { return [] }
    switch mode {
    case .s:
      return [
        WorkOSReceiptRequirement(
          id: "product-design-quick-audit",
          title: "Product Design quick visual audit",
          kind: "product-design",
          requiredForPass: false,
          plainPurpose: "S 可選：截圖式快速 UI/UJ 副審；只記明顯排版、可讀性、流程理解問題。")
      ]
    case .m:
      return [
        WorkOSReceiptRequirement(
          id: "product-design-audit",
          title: "Product Design UI/UJ audit",
          kind: "product-design",
          requiredForPass: false,
          plainPurpose: "M 建議：若 UI / 工作流視覺被改動，提交 screenshot-grounded Product Design audit。")
      ]
    case .l:
      return [
        WorkOSReceiptRequirement(
          id: "product-design-audit",
          title: "Product Design UI/UJ audit",
          kind: "product-design",
          requiredForPass: true,
          plainPurpose: "L UI/UJ 任務必須有本輪截圖副審，避免 build pass 或模型自評誤判畫面品質。")
      ]
    case .xl, .xxl:
      return [
        WorkOSReceiptRequirement(
          id: "product-design-audit",
          title: "Product Design UI/UJ audit",
          kind: "product-design",
          requiredForPass: true,
          plainPurpose: "XL UI/UJ / dashboard / workflow 視覺改動必須有本輪截圖副審；它只補 UI/UJ 風險，不可直接放行。")
      ]
    }
  }

  public static func domainReceiptRequirements(
    mode: WorkModeID,
    scenarioProfileID: String,
    domain: WorkOSDomainKind
  ) -> [WorkOSReceiptRequirement] {
    guard domain == .ui else { return [] }
    return receiptRequirements(mode: mode, scenarioProfileID: scenarioProfileID)
  }

  private static func isUIStrictScenario(_ scenarioProfileID: String) -> Bool {
    let id = scenarioProfileID.lowercased()
    return id == "ui-ux" || id == "editing" || id == "design"
  }
}
