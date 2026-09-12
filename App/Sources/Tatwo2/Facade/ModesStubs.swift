// 來源：1.0 TatwoCatalog.swift、IdentityGroups.swift、TeamRouting.swift 與 trait/arena 型別；只保留 run A 畫面欄位與記憶體假資料
import Foundation

enum ModesFixture {
    static let workModes: [WorkMode] = [
        .init(mode: .s, englishName: "Small", chineseName: "S 小修", plainDescription: "單主控處理小修，不開隊伍，避免協調成本比任務還大。", maxHelpers: 0, maxRounds: 1, requiresHumanApproval: false, requiresIndependentVerification: false),
        .init(mode: .m, englishName: "Medium", chineseName: "M 協作", plainDescription: "主控加 reviewer，預設 3 個 domain loops（自定義至 8）；適合中型修補或一次架構檢查。", maxHelpers: 4, maxRounds: 2, requiresHumanApproval: false, requiresIndependentVerification: true),
        .init(mode: .l, englishName: "Large", chineseName: "L 專案", plainDescription: "多模組、多風險；預設 8 個 loops（cycle 展開，自定義至 20），需要沙盒或獨立驗證。", maxHelpers: 16, maxRounds: 2, requiresHumanApproval: false, requiresIndependentVerification: true),
        .init(mode: .xl, englishName: "Extra Large", chineseName: "XL 重型", plainDescription: "大型未知任務；預設 20 個 loops（自定義至 64），沙盒跑到無誤再備份實裝主機。", maxHelpers: 48, maxRounds: 3, requiresHumanApproval: true, requiresIndependentVerification: true),
        .init(mode: .xxl, englishName: "Orchestration", chineseName: "XXL 編排級", plainDescription: "單一編排手統帥多條 Loops 與 subs；最多 4 個 helper 同時存活，工作量以分波方式擴張。", maxHelpers: 4, maxRounds: 3, requiresHumanApproval: true, requiresIndependentVerification: true),
    ]

    static let scenarioProfiles: [ScenarioProfile] = [
        .init(id: "ui-ux", displayName: "UI / UX", baseScenario: .design, plainPurpose: "先看架構與畫面目標，再落地 UI；預設不啟用消息。", defaultMode: .m),
        .init(id: "daily", displayName: "通用", baseScenario: .daily, plainPurpose: "通用問答、整理、輕量修補與跨領域小協作；能單引擎完成就不開大隊伍。", defaultMode: .s),
        .init(id: "debug", displayName: "Debug", baseScenario: .coding, plainPurpose: "主導定位問題，監督檢查假設，sub 做局部掃描，顧問提出修法。", defaultMode: .m),
        .init(id: "coding", displayName: "寫代碼", baseScenario: .coding, plainPurpose: "Codex host 落地，其他 engine 審稿、草稿或裁決。", defaultMode: .m),
        .init(id: "trading-risk", displayName: "交易 / 風控", baseScenario: .trading, plainPurpose: "預設只讀；涉及資金、槓桿、停損、下單必須人工風控。", defaultMode: .l),
        .init(id: "modeling", displayName: "建模", baseScenario: .modeling, plainPurpose: "多候選、多反例、可重現測試收斂。", defaultMode: .l),
        .init(id: "editing", displayName: "剪輯", baseScenario: .design, plainPurpose: "整理素材、節奏、字幕、分鏡與輸出驗收。", defaultMode: .m),
        .init(id: "video-research", displayName: "影片研究", baseScenario: .modeling, plainPurpose: "需要消息、來源、剪輯線索與反方驗證的長研究。", defaultMode: .l),
    ]

    private static func trait(_ id: String, _ name: String, _ summary: String, _ reasoning: Int, _ coding: Int, _ review: Int) -> ModelTrait {
        .init(id: id, displayName: name, plainSummary: summary, plainFailureMode: "", verificationRule: "", strengths: [], weaknesses: [], bestRoles: [], avoidRoles: [], calibrationNotes: [], scores: .init(reasoning: reasoning, coding: coding, designSense: 3, researchFreshness: 3, bulkThroughput: 3, reviewStrictness: review, costRisk: 3, stabilityRisk: 3, executionAuthority: 1))
    }

    static let modelTraits: [ModelTrait] = [
        trait("fable-5", "Fable 5", "已可透過 gateway 跑正式 Web Arena；目前定位是昂貴高階候選，適合架構/產品草稿觀察，但不自動進常駐協作流。", 5, 4, 4),
        trait("gpt-5.5", "GPT-5.5", "最適合當主控：整理大架構、把不同模型意見收斂成可執行步驟，並理解 Codex 工具語義。", 5, 5, 4),
        trait("opus-5", "Opus 5", "最適合作保守裁決與高風險審稿：沒有證據時寧可擋下。", 5, 4, 5),
        trait("sonnet-5", "Sonnet 5", "TATWO 的主力工程副審：比舊 Sonnet lane 更適合承擔代碼一致性、漏測檢查、M/L 級 debug 主導與 patch intent。", 5, 5, 5),
        trait("minimax-m3", "MiniMax M3", "適合扛量：候選、草稿、檢查清單、分檔掃描；不能當最後裁決。", 3, 3, 3),
        trait("grok", "Grok", "適合消息、外部視角與尖銳反例；查完仍需來源與主控收斂。", 3, 3, 3),
    ]
}

struct TatwoLeadStrategy { let leadModelID: String }
struct TatwoCollabEvidenceMemberV1: Identifiable { let id = UUID(); let model: String; let role: String }
enum TatwoCollabEvidenceSourceV1: String { case sandboxExam, liveRunHumanVerdict }
struct TatwoCollabEvidenceV1: Identifiable { let id = UUID(); let members: [TatwoCollabEvidenceMemberV1] = []; let taskClass = ""; let strongBaseline = ""; let weakBaseline = ""; let qualitativeVerdict = ""; let deltaDirection: TatwoCollabDeltaDirectionV1 = .flat; let source: TatwoCollabEvidenceSourceV1 = .sandboxExam; let note = "" }
enum TatwoCollabDeltaDirectionV1: String { case positive, flat, negative }
struct TatwoHumanCollabRatingV1: Identifiable { let id: String; let comboLabel: String; let verdict: String; let deltaDirection: String; let note: String; let ratedAt: String }
struct TatwoHumanCollabRatingStore { static func `default`() -> Self { .init() }; func all() -> [TatwoHumanCollabRatingV1] { [] }; func upsert(_ value: TatwoHumanCollabRatingV1) throws -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }; func remove(id: String) throws -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) } }

struct TatwoModelTraitClaim: Identifiable { let label: String; let plainClaim: String; let evidenceRefs: [String]; var id: String { label } }
struct TatwoModelTraitDimensionScore: Identifiable { let dimensionID: String; let value0To10: Double; let status: String; var id: String { dimensionID } }
struct TatwoModelTraitCardV1: Identifiable { let modelID: String; let oneLiner: String; let strengths: [TatwoModelTraitClaim]; let weaknesses: [TatwoModelTraitClaim]; let dimensionScores: [TatwoModelTraitDimensionScore]; let notes: String; var id: String { modelID } }
struct TatwoModelTraitCardStore { static func `default`() -> Self { .init() }; func allCards() -> [TatwoModelTraitCardV1] { [] } }
struct TatwoHumanTraitRatingV1: Identifiable { var id: String { "\(modelID)#\(dimensionID)" }; let modelID: String; let dimensionID: String; let value0To10: Double; let ratedAt: String; let note: String }
struct TatwoHumanTraitRatingStore { static func `default`() -> Self { .init() }; func all() -> [TatwoHumanTraitRatingV1] { [] }; func upsert(_ value: TatwoHumanTraitRatingV1) throws -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }; func remove(modelID: String, dimensionID: String) throws -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) } }

struct TatwoWebArenaTraitDimensionEvidence: Identifiable { var id: String { dimensionID }; let dimensionID: String; let dimensionTitle: String; let value0To10: Double; let evidenceSource: String; let status: String; let note: String }
struct TatwoWebArenaCaseEvidence: Identifiable { let id = UUID(); let title: String; let score: Int }
struct TatwoWebArenaModelEvidence {
    let modelSlug: String; let displayName: String; let arena: String; let runID: String; let testedAt: String; let status: String; let averageScore: Double; let reportCount: Int; let sealVerifiedReportCount: Int; let dispatchComplete: Bool; let routingImplication: String; let caseEvidence: [TatwoWebArenaCaseEvidence]; let traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence]
    var examScoreSummaryLabel: String { "Web \(Int(averageScore.rounded()))/100" }
}
enum TatwoWebArenaFactory { static let importedModelEvidence: [TatwoWebArenaModelEvidence] = [] }
enum TatwoWebArenaTraitMappingCatalog { static func derivedEvidence(from value: TatwoWebArenaModelEvidence) -> [TatwoWebArenaTraitDimensionEvidence] { [] } }
struct Tatwo3DModelingArenaCaseEvidence: Identifiable { let id = UUID(); let title: String; let score0To100: Int?; let status: String; let official: Bool }
struct Tatwo3DModelingArenaModelEvidence {
    let modelSlug: String; let displayName: String; let arena: String; let runID: String; let testedAt: String; let status: String; let canonicalScore0To100: Int?; let scoreStatusLabel: String; let routingImplication: String; let caseEvidence: [Tatwo3DModelingArenaCaseEvidence]; let traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence]
    var examScoreSummaryLabel: String { canonicalScore0To100.map { "3D \($0)/100" } ?? scoreStatusLabel }
}
enum Tatwo3DModelingArenaFactory { static let importedModelEvidence: [Tatwo3DModelingArenaModelEvidence] = [] }
