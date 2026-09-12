import XCTest

@testable import TatwoUltraworkCore

/// The canonical transcript journal stores string attributes only, so a
/// clarification-only turn (staging-62 thread 8d47658b) can survive a restart
/// solely through this codec.
final class PlanQuestionJournalCodecTests: XCTestCase {
  private let questions = [
    PlanQuestionV1(
      id: "sample-task-list",
      question: "內建範例任務清單要採用哪一組固定資料？",
      options: [
        PlanQuestionV1.Option(
          label: "3 todo、2 done (Recommended)",
          detail: "範例清楚、測試涵蓋剛好。"),
        PlanQuestionV1.Option(label: "2 todo、2 done", detail: "最對稱的最小範例。"),
      ],
      allowsMultipleSelections: false,
      allowsOtherResponse: true)
  ]

  func testRoundTripPreservesEveryField() throws {
    let encoded = try XCTUnwrap(
      TatwoPlanQuestionJournalCodec.encode(questions))
    XCTAssertEqual(TatwoPlanQuestionJournalCodec.decode(encoded), questions)
  }

  func testEncodingIsDeterministic() throws {
    let first = TatwoPlanQuestionJournalCodec.encode(questions)
    let second = TatwoPlanQuestionJournalCodec.encode(questions)
    XCTAssertNotNil(first)
    XCTAssertEqual(first, second)
  }

  func testEmptyOrInvalidQuestionsAreNotEncoded() {
    XCTAssertNil(TatwoPlanQuestionJournalCodec.encode([]))
    XCTAssertNil(
      TatwoPlanQuestionJournalCodec.encode([
        PlanQuestionV1(id: "", question: "Q?", options: [])
      ]))
  }

  func testUnreadablePayloadsDecodeToNoQuestions() {
    XCTAssertEqual(TatwoPlanQuestionJournalCodec.decode(nil), [])
    XCTAssertEqual(TatwoPlanQuestionJournalCodec.decode(""), [])
    XCTAssertEqual(TatwoPlanQuestionJournalCodec.decode("{not json"), [])
    XCTAssertEqual(TatwoPlanQuestionJournalCodec.decode("[]"), [])
    XCTAssertEqual(
      TatwoPlanQuestionJournalCodec.decode(
        #"[{"id":"x","question":"Q?","options":[]}]"#),
      [],
      "an invalid question must never project a card with no options")
  }

  func testTerminalAgentMessagePayloadEncodesWhatTheParserProduced() throws {
    let terminal = """
      <TATWO_PLAN_QUESTION>{"id":"sample-task-list","question":"內建範例任務清單要採用哪一組固定資料？","allowsMultipleSelections":false,"allowsOtherResponse":true,"options":[{"label":"3 todo、2 done (Recommended)","detail":"範例清楚、測試涵蓋剛好。"},{"label":"2 todo、2 done","detail":"最對稱的最小範例。"}]}</TATWO_PLAN_QUESTION>
      """
    let parsed = TatwoPlanQuestionParser.parse(terminal)
    XCTAssertEqual(parsed.visibleText, "")
    XCTAssertFalse(parsed.hasIncompleteBlock)

    let encoded = try XCTUnwrap(
      TatwoPlanQuestionJournalCodec.encode(parsed.questions))
    XCTAssertEqual(
      TatwoPlanQuestionJournalCodec.decode(encoded),
      parsed.questions)
  }
}
