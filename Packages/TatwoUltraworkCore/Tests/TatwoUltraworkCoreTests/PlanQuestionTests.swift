import XCTest

@testable import TatwoUltraworkCore

final class PlanQuestionTests: XCTestCase {
  func testParsesValidQuestionAndRemovesMarkerFromVisibleText() throws {
    let input = """
      摘要
      <TATWO_PLAN_QUESTION>{"id":"scope","question":"選哪個範圍？","options":[{"label":"A","detail":"小"},{"label":"B","detail":"大"}]}</TATWO_PLAN_QUESTION>
      結尾
      """
    let result = TatwoPlanQuestionParser.parse(input)
    XCTAssertEqual(result.questions.map(\.id), ["scope"])
    XCTAssertFalse(result.visibleText.contains("TATWO_PLAN_QUESTION"))
    XCTAssertTrue(result.visibleText.contains("摘要"))
    XCTAssertTrue(result.visibleText.contains("結尾"))
  }

  func testMalformedQuestionRemainsVisible() {
    let input = """
      <TATWO_PLAN_QUESTION>{"id":"bad"}</TATWO_PLAN_QUESTION>
      """
    let result = TatwoPlanQuestionParser.parse(input)
    XCTAssertTrue(result.questions.isEmpty)
    XCTAssertEqual(result.visibleText, input)
  }

  func testParsesMultipleQuestions() {
    let block = {
      (id: String) in
      "<TATWO_PLAN_QUESTION>{\"id\":\"\(id)\",\"question\":\"Q?\",\"options\":[{\"label\":\"A\",\"detail\":\"a\"},{\"label\":\"B\",\"detail\":\"b\"}]}</TATWO_PLAN_QUESTION>"
    }
    let result = TatwoPlanQuestionParser.parse(block("one") + block("two"))
    XCTAssertEqual(result.questions.map(\.id), ["one", "two"])
    XCTAssertEqual(result.visibleText, "")
  }

  func testDecodesCodexStyleMultiSelectQuestion() throws {
    let input = """
      <TATWO_PLAN_QUESTION>{"id":"scope","question":"Select areas","allowsMultipleSelections":true,"options":[{"label":"UI","detail":"Views"},{"label":"Tests","detail":"Coverage"}]}</TATWO_PLAN_QUESTION>
      """
    let result = TatwoPlanQuestionParser.parse(input)
    let question = try XCTUnwrap(result.questions.first)
    XCTAssertTrue(question.allowsMultipleSelections)
  }

  func testCodexParityAcceptsOneOrMoreQuestionOptions() {
    let oneOption = PlanQuestionV1(
      id: "one",
      question: "Choose one",
      options: [.init(label: "Only", detail: "Single option")])
    let fourOptions = PlanQuestionV1(
      id: "four",
      question: "Choose one",
      options: [
        .init(label: "A", detail: ""),
        .init(label: "B", detail: ""),
        .init(label: "C", detail: ""),
        .init(label: "D", detail: ""),
      ])

    XCTAssertTrue(
      oneOption.isValid,
      "Current Codex request_user_input accepts a non-empty option list")
    XCTAssertTrue(
      fourOptions.isValid,
      "Current Codex does not cap request_user_input questions at three options")
  }

  func testCodexParityPreservesPerQuestionOtherAvailability() throws {
    let input = """
      <TATWO_PLAN_QUESTION>{"id":"scope","question":"Choose","allowsOtherResponse":false,"options":[{"label":"A","detail":""}]}</TATWO_PLAN_QUESTION>
      """
    let result = TatwoPlanQuestionParser.parse(input)
    let question = try XCTUnwrap(result.questions.first)
    let encoded = try JSONEncoder().encode(question)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    XCTAssertEqual(
      object["allowsOtherResponse"] as? Bool,
      false,
      "Current Codex preserves each request question's isOther capability")
  }

  func testCodexRecommendedSuffixIsDisplayedAsSeparateBadgeText() {
    let recommended = PlanQuestionV1.Option(
      label: "Use current project (Recommended)",
      detail: "Narrowest reversible scope")
    let ordinary = PlanQuestionV1.Option(
      label: "Create a new project",
      detail: "Broader setup")

    XCTAssertTrue(recommended.isCodexRecommended)
    XCTAssertEqual(recommended.codexDisplayLabel, "Use current project")
    XCTAssertFalse(ordinary.isCodexRecommended)
    XCTAssertEqual(ordinary.codexDisplayLabel, ordinary.label)
  }

  func testStreamingSplitMarkerWaitsThenParses() {
    var parser = TatwoPlanQuestionStreamParser()
    let first = parser.consume("before<TATWO_PLAN_QUE")
    XCTAssertTrue(first.hasIncompleteBlock)
    XCTAssertEqual(first.visibleText, "")

    let second = parser.consume("""
      STION>{"id":"stream","question":"Q?","options":[{"label":"A","detail":"a"},{"label":"B","detail":"b"}]}</TATWO_PLAN_QUESTION>after
      """)
    XCTAssertFalse(second.hasIncompleteBlock)
    XCTAssertEqual(second.questions.map(\.id), ["stream"])
    XCTAssertEqual(second.visibleText, "beforeafter")
  }

  func testFinalTruncatedBlockDoesNotReExposePreviouslyParsedQuestionMarkup() {
    let valid = """
      <TATWO_PLAN_QUESTION>{"id":"valid","question":"Q?","options":[{"label":"A","detail":"a"},{"label":"B","detail":"b"}]}</TATWO_PLAN_QUESTION>
      """
    let truncated = """
      <TATWO_PLAN_QUESTION>{"id":"truncated","question":"Still streaming"
      """
    var parser = TatwoPlanQuestionStreamParser()

    let result = parser.consume(
      "before\(valid)between\(truncated)",
      isFinal: true)

    XCTAssertEqual(result.questions.map(\.id), ["valid"])
    XCTAssertEqual(result.visibleText, "beforebetween\(truncated)")
    XCTAssertFalse(result.visibleText.contains("\"id\":\"valid\""))
    XCTAssertFalse(result.hasIncompleteBlock)
  }
}
