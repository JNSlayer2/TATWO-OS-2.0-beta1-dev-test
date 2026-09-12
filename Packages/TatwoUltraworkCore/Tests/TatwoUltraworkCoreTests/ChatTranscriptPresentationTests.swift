import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatTranscriptPresentationTests: XCTestCase {
  func testHeadingHierarchyStripsRawMarkers() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      # Primary

      ## Secondary

      ### Tertiary
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.heading(level: 1), .heading(level: 2), .heading(level: 3)])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["Primary", "Secondary", "Tertiary"])
    XCTAssertFalse(document.blocks[1].plainText.contains("##"))
  }

  func testHeadingLevelsFourThroughSixAreRecognized() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      #### Fourth

      ##### Fifth

      ###### Sixth
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.heading(level: 4), .heading(level: 5), .heading(level: 6)])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["Fourth", "Fifth", "Sixth"])
  }

  func testHeadingLevelsFourThroughSixMapToHeadingRendererKinds() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      #### Fourth

      ##### Fifth

      ###### Sixth
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind.renderKind),
      [.heading(level: 4), .heading(level: 5), .heading(level: 6)])
  }

  func testGFMTableParsesHeaderAlignmentAndBodyRows() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      | **Name** | Value |
      | :--- | ---: |
      | Alpha | 1 |
      | Beta | 2 |
      """)
    let block = try XCTUnwrap(document.blocks.first)
    guard case .table(let table) = block.kind else {
      return XCTFail("Expected table block")
    }

    XCTAssertEqual(
      table.header.map { String($0.characters) },
      ["Name", "Value"])
    XCTAssertEqual(
      table.rows.map { row in row.map { String($0.characters) } },
      [["Alpha", "1"], ["Beta", "2"]])
    XCTAssertEqual(table.alignments, [.leading, .trailing])
    XCTAssertEqual(block.plainText, "Name | Value\nAlpha | 1\nBeta | 2")
  }

  func testTableBlockMapsToTableRendererKind() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      Name | Value
      --- | ---
      Alpha | 1
      """)
    let block = try XCTUnwrap(document.blocks.first)

    guard case .table = block.kind.renderKind else {
      return XCTFail("Expected table renderer kind")
    }
  }

  func testBlockquoteParsesConsecutivePrefixedLines() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      > First **line**
      > second line
      """)
    let block = try XCTUnwrap(document.blocks.first)

    XCTAssertEqual(block.kind, .blockquote)
    XCTAssertEqual(block.plainText, "First line\nsecond line")
  }

  func testBlockquoteMapsToBlockquoteRendererKind() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "> Quoted")
    let block = try XCTUnwrap(document.blocks.first)

    XCTAssertEqual(block.kind.renderKind, .blockquote)
  }

  func testDashAndAsteriskHorizontalRulesBecomeSemanticBlocks() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      Before

      ---

      ***

      After
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.paragraph, .horizontalRule, .horizontalRule, .paragraph])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["Before", "", "", "After"])
  }

  func testHorizontalRuleMapsToHorizontalRuleRendererKind() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "---")
    let block = try XCTUnwrap(document.blocks.first)

    XCTAssertEqual(block.kind.renderKind, .horizontalRule)
  }

  func testOrdinaryParagraphBecomesParagraphBlock() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "A normal assistant paragraph.")

    XCTAssertEqual(document.blocks.map(\.kind), [.paragraph])
    XCTAssertEqual(document.blocks.map(\.plainText), ["A normal assistant paragraph."])
  }

  func testUnorderedListUsesSemanticListItemsWithoutRawMarkers() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      - First
      - Second
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.unorderedListItem(depth: 0), .unorderedListItem(depth: 0)])
    XCTAssertEqual(document.blocks.map(\.plainText), ["First", "Second"])
  }

  func testOrderedListRetainsOrdinalsOutsideTextContent() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      1. First
      2. Second
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [
        .orderedListItem(depth: 0, ordinal: 1),
        .orderedListItem(depth: 0, ordinal: 2)
      ])
    XCTAssertEqual(document.blocks.map(\.plainText), ["First", "Second"])
  }

  func testNestedListCarriesVisibleDepthHierarchy() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      - Parent
        - Child
          1. Grandchild
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [
        .unorderedListItem(depth: 0),
        .unorderedListItem(depth: 1),
        .orderedListItem(depth: 2, ordinal: 1)
      ])
  }

  func testIndentedListContinuationPreservesParentAndChildHierarchy() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      - Parent first line
        continuation
        - Child
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [
        .unorderedListItem(depth: 0),
        .unorderedListItem(depth: 1)
      ])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["Parent first line\ncontinuation", "Child"])
  }

  func testBlankLineSeparatesTwoParagraphBlocks() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      First paragraph.

      Second paragraph.
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.paragraph, .paragraph])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["First paragraph.", "Second paragraph."])
  }

  func testAppendingMarkdownKeepsExistingBlockIDsStable() {
    let prefix = """
      Repeat

      Repeat
      """
    let initial = TatwoAssistantTranscriptPresentation.document(markdown: prefix)
    let grown = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      \(prefix)

      Repeat

      Tail
      """)

    XCTAssertEqual(
      Array(grown.blocks.prefix(initial.blocks.count).map(\.id)),
      initial.blocks.map(\.id))
    XCTAssertEqual(Set(grown.blocks.map(\.id)).count, grown.blocks.count)
  }

  func testInlineBoldAndCodeRemainAttributedInsideParagraphBlock() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "Use **bold** and `code`.")
    let block = try XCTUnwrap(document.blocks.first)

    XCTAssertEqual(block.plainText, "Use bold and code.")
    XCTAssertTrue(
      block.content.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
    XCTAssertTrue(
      block.content.runs.contains {
        $0.inlinePresentationIntent?.contains(.code) == true
      })
  }

  func testInlineEmphasisRemainsAttributedInsideParagraphBlock() throws {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "Use *emphasis* here.")
    let block = try XCTUnwrap(document.blocks.first)

    XCTAssertEqual(block.plainText, "Use emphasis here.")
    XCTAssertTrue(
      block.content.runs.contains {
        $0.inlinePresentationIntent?.contains(.emphasized) == true
      })
  }

  func testWhitespaceOnlyInputProducesNoVisibleBlocks() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: " \n\t\n ")

    XCTAssertTrue(document.blocks.isEmpty)
    XCTAssertFalse(document.usedFallback)
  }

  func testFencedCodeKeepsHeadingAndListMarkersLiteral() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      ```yaml
      # comment
      - literal
      1. ordered literal
      ```
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.codeBlock(language: "yaml")])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["# comment\n- literal\n1. ordered literal"])
    XCTAssertFalse(document.usedFallback)
  }

  func testUnclosedFencedCodePreservesLiteralContentToEndOfInput() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      ~~~swift
      # not a heading
      - not a list
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.codeBlock(language: "swift")])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["# not a heading\n- not a list"])
    XCTAssertTrue(document.usedFallback)
  }

  func testFourSpaceIndentedFenceInsideCodeDoesNotCloseOuterFence() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: """
      ```text
          ```
      # still code
      - still code
      1. still code
      ```
      """)

    XCTAssertEqual(
      document.blocks.map(\.kind),
      [.codeBlock(language: "text")])
    XCTAssertEqual(
      document.blocks.map(\.plainText),
      ["    ```\n# still code\n- still code\n1. still code"])
    XCTAssertFalse(document.usedFallback)
  }

  func testSameLineBacktickLiteralIsNotConsumedAsEmptyFence() {
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: "```literal```")

    XCTAssertEqual(document.blocks.map(\.kind), [.paragraph])
    XCTAssertEqual(document.blocks.map(\.plainText), ["literal"])
    XCTAssertFalse(document.usedFallback)
  }

  func testMalformedMarkdownNeverDropsTailContent() {
    let raw = "Start **unmatched emphasis and [broken link](https://example.com Tail sentinel"
    let document = TatwoAssistantTranscriptPresentation.document(markdown: raw)
    let output = document.blocks.map(\.plainText).joined(separator: "\n")

    XCTAssertTrue(output.hasPrefix("Start"))
    XCTAssertTrue(output.contains("broken link"))
    XCTAssertTrue(output.hasSuffix("Tail sentinel"))
  }

  func testParserFailurePreservesBlockHierarchyWithoutRawHeadingMarker() {
    enum ExpectedParserFailure: Error {
      case failed
    }

    let raw = "## **raw fallback**"
    let document = TatwoAssistantTranscriptPresentation.document(
      markdown: raw,
      inlineParser: { _ in throw ExpectedParserFailure.failed })

    XCTAssertTrue(document.usedFallback)
    XCTAssertEqual(document.blocks.map(\.kind), [.heading(level: 2)])
    XCTAssertEqual(document.blocks.map(\.plainText), ["**raw fallback**"])
    XCTAssertFalse(document.blocks[0].plainText.contains("##"))
  }

  func testAssistantContextCheckpointIsHidden() {
    let text = """
      # Context Checkpoint — TATWO Chat Slider Loop 12

      Internal continuation state.
      """

    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isInternalArtifact(
        text,
        role: .assistant))
  }

  func testSystemContextCheckpointIsHidden() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isInternalArtifact(
        "# Context Checkpoint — TATWO Chat Slider Loop 13A",
        role: .system))
  }

  func testUserContextCheckpointRemainsVisible() {
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "# Context Checkpoint — TATWO Chat Slider Loop 12",
        role: .user,
        status: nil,
        eventKind: .message))
  }

  func testAssistantProseMentioningOrQuotingContextCheckpointRemainsVisible() {
    let examples = [
      "The Context Checkpoint explains where the prior loop stopped.",
      "Please quote “# Context Checkpoint — TATWO Chat Slider Loop” in the report."
    ]

    for text in examples {
      XCTAssertFalse(
        TatwoChatTranscriptPresentation.isInternalArtifact(
          text,
          role: .assistant))
    }
  }

  func testExistingAssistantHandoffMarkerStaysHidden() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isInternalArtifact(
        "## Handoff Summary\nContinue from the prior implementation.",
        role: .assistant))
  }

  func testCompleteAssistantDelegationEnvelopeStaysHidden() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isInternalArtifact(
        """
        You are a Loops Executor.
        ContractID=contract-test
        Finish and stop.
        Do not run git.
        """,
        role: .assistant))
  }

  func testUserAuthoredHandoffAndDelegationExamplesRemainVisible() {
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "## Handoff Summary\nPlease explain what this heading means.",
        role: .user,
        status: nil,
        eventKind: .message))
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "You are a Loops Executor. Is this wording correct?",
        role: .user,
        status: nil,
        eventKind: .message))
  }

  func testAssistantBoldMarkdownProducesStrongTextWithoutLiteralMarkers() {
    let rendered = TatwoChatTranscriptPresentation.assistantMarkdown(
      "**Sonnet review complete.**")

    XCTAssertEqual(String(rendered.characters), "Sonnet review complete.")
    XCTAssertTrue(
      rendered.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
  }

  func testAssistantMarkdownPreservesLineBreaks() {
    let rendered = TatwoChatTranscriptPresentation.assistantMarkdown(
      "**First line**\n\nSecond line")

    XCTAssertEqual(String(rendered.characters), "First line\n\nSecond line")
  }

  func testAssistantMarkdownKeepsUnmatchedMarkdownContentThroughPublicPath() {
    let rawText = "Start **unmatched emphasis and [broken link](https://example.com Tail sentinel"
    let rendered = TatwoChatTranscriptPresentation.assistantMarkdown(rawText)
    let output = String(rendered.characters)

    XCTAssertFalse(output.isEmpty)
    XCTAssertTrue(output.hasPrefix("Start"))
    XCTAssertTrue(output.contains("broken link"))
    XCTAssertTrue(output.hasSuffix("Tail sentinel"))
  }

  func testAssistantMarkdownFallsBackToRawTextWhenParserFails() {
    enum ExpectedParserFailure: Error {
      case failed
    }

    let rendered = TatwoChatTranscriptPresentation.assistantMarkdown(
      "**raw fallback**",
      parser: { _ in throw ExpectedParserFailure.failed })

    XCTAssertEqual(String(rendered.characters), "**raw fallback**")
  }

  func testActiveAssistantEmptyMessageStatusesUseCompactActivity() {
    for status in ["thinking", "working", "calling-tool"] {
      XCTAssertTrue(
        TatwoChatTranscriptPresentation.usesCompactActivity(
          role: .assistant,
          eventKind: .message,
          text: "",
          status: status))
    }
  }

  func testHistoricalThinkingAndToolUseAreSuppressed() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.suppressesHistoricalActivity(
        eventKind: .thinking))
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.suppressesHistoricalActivity(
        eventKind: .toolUse))
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.suppressesHistoricalActivity(
        eventKind: .message))
  }

  func testMeaningfulActivityRowsRemainVisibleInTranscript() {
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "/bin/zsh -lc /bin/pwd",
        role: .assistant,
        status: "completed|/bin/zsh -lc /bin/pwd",
        eventKind: .toolUse))
    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "正在檢查工作目錄",
        role: .assistant,
        status: nil,
        eventKind: .thinking))
  }

  func testInertEmptyHistoricalActivityRemainsSuppressed() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "",
        role: .assistant,
        status: nil,
        eventKind: .thinking))
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "",
        role: .assistant,
        status: nil,
        eventKind: .toolUse))
  }

  func testUserTextStartingWithAgentOrEnvironmentSignatureRemainsVisible() {
    let examples = [
      "# AGENTS.md instructions\nPlease explain this user-provided policy.",
      "<environment_context>\nUser-authored environment example."
    ]

    for text in examples {
      XCTAssertFalse(
        TatwoChatTranscriptPresentation.isTranscriptNoise(
          text,
          role: .user,
          status: nil,
          eventKind: .message))
    }
  }

  func testUserEnvelopeLiteralsRemainVisibleAndPersistable() {
    let examples = [
      "請解釋這段 <codex_internal_context>demo</codex_internal_context>",
      "請保留 <oai-mem-citation>example</oai-mem-citation> 這段字面內容",
      "<codex_internal_context>envelope-only user text</codex_internal_context>"
    ]

    for text in examples {
      XCTAssertFalse(
        TatwoChatTranscriptPresentation.isTranscriptNoise(
          text,
          role: .user,
          status: nil,
          eventKind: .message))
      XCTAssertEqual(
        TatwoChatTranscriptPresentation.cleanedTranscriptSource(
          text,
          role: .user),
      text)
    }
  }

  func testUserPairedHiddenContextAtEndIsRemovedFromDisplaySource() {
    let text = """
      Keep this user request visible.

      [Hidden TATWO Work OS contract context — do not quote to the user unless asked]
      contractID=contract-private
      [/Hidden TATWO Work OS contract context]
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      "Keep this user request visible.")
  }

  func testUserPairedHiddenContextInMiddleCollapsesSurroundingBlankLines() {
    let text = """
      Visible before.


      [Hidden TATWO Ultrawork loopsConfig context — do not quote to the user unless asked]
      {"mode":"L"}
      [/Hidden TATWO Ultrawork loopsConfig context]


      Visible after.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      "Visible before.\n\nVisible after.")
  }

  func testUserMultiplePairedHiddenContextsAreAllRemoved() {
    let text = """
      First visible section.

      [Hidden TATWO Work OS contract context]
      private contract
      [/Hidden TATWO Work OS contract context]

      Middle visible section.

      [Hidden TATWO Ultrawork pendingHandoff context]
      private handoff
      [/Hidden TATWO Ultrawork pendingHandoff context]

      Last visible section.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      """
      First visible section.

      Middle visible section.

      Last visible section.
      """)
  }

  func testExactAppInjectedHiddenContractsAreRemovedWithoutBlankUserBubble() {
    let labels = [
      "TATWO Chat interface contract",
      "TATWO Work OS authority frame",
      "Codex-style Goal state",
      "Codex-style Plan mode contract",
      "TATWO Computer Host contract",
      "TATWO PLG phase state",
      "TATWO thread plugins decision context",
      "image context receipt",
    ]

    for label in labels {
      let mixed = """
        [Hidden \(label) — do not quote to the user unless asked]
        private transport context
        [/Hidden \(label)]

        Keep the real request visible.
        """
      XCTAssertEqual(
        TatwoChatTranscriptPresentation.cleanedTranscriptSource(
          mixed,
          role: .user),
        "Keep the real request visible.",
        label)

      let internalOnly = """
        [Hidden \(label)]
        private transport context
        [/Hidden \(label)]
        """
      XCTAssertEqual(
        TatwoChatTranscriptPresentation.cleanedTranscriptSource(
          internalOnly,
          role: .user),
        "",
        label)
      XCTAssertTrue(
        TatwoChatTranscriptPresentation.isTranscriptNoise(
          internalOnly,
          role: .user,
          status: nil,
          eventKind: .message),
        label)
    }
  }

  func testCappedStatelessEnvelopeKeepsOnlyCurrentVisibleRequest() {
    let text = """
      Conversation history from this same Tatwo thread:
      bridgePolicy=capped-stateless; includedMessages=2; omittedMessages=0; maxCharacters=120000
      [user] earlier request

      [assistant model=fable5] earlier response

      Current user request:
      [Hidden TATWO Chat interface contract — do not quote to the user unless asked]
      private UI contract
      [/Hidden TATWO Chat interface contract]

      [Hidden Codex-style Goal state]
      private goal
      [/Hidden Codex-style Goal state]

      FABLE-AUG02-05-RETRY｜Keep only this request.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      "FABLE-AUG02-05-RETRY｜Keep only this request.")
  }

  func testAnchoredCodexDelegationKeepsOnlyInputBody() {
    let text = """
      <codex_delegation>
        <source_thread_id>019fb652-a553-7890-b177-b939073e4f0d</source_thread_id>
        <input>GROK-AUG02-07｜Keep this visible request.
      Second visible line.</input>
      </codex_delegation>
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      """
      GROK-AUG02-07｜Keep this visible request.
      Second visible line.
      """)
  }

  func testCodexDelegationLiteralInsideFenceRemainsVisible() {
    let text = """
      ```xml
      <codex_delegation>
        <source_thread_id>literal</source_thread_id>
        <input>literal example</input>
      </codex_delegation>
      ```
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testUserUnclosedHiddenContextRemainsByteForByteVisible() {
    let text = """
      Keep the incomplete injected context as a safe fallback.

      [Hidden TATWO Work OS contract context]
      contractID=contract-unclosed
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testUserHiddenContextLiteralInsideFencedCodeRemainsVisible() {
    for fence in ["```", "~~~"] {
      let text = """
        Keep this documentation example visible.

        \(fence)text
        [Hidden TATWO Work OS contract context]
        contractID=literal-example
        [/Hidden TATWO Work OS contract context]
        \(fence)

        Keep the tail visible.
        """

      XCTAssertEqual(
        TatwoChatTranscriptPresentation.cleanedTranscriptSource(
          text,
          role: .user),
        text,
        "Hidden literals inside \(fence) fences must remain user-visible")
    }
  }

  func testUserHiddenContextLiteralInsideInlineCodeRemainsVisible() {
    let text = """
      Keep `[Hidden TATWO Work OS contract context]` as a same-line literal.

      `This multiline inline code span also stays literal.
      [Hidden TATWO Work OS contract context]
      contractID=literal-example
      [/Hidden TATWO Work OS contract context]
      End of inline code span.`
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testUserNestedHiddenContextsAreRemovedAtomicallyWithoutResidualMarkers() {
    let complete = """
      Visible before.

      [Hidden TATWO Work OS contract context]
      outer payload
      [Hidden TATWO Ultrawork loopsConfig context]
      nested payload
      [/Hidden TATWO Ultrawork loopsConfig context]
      outer payload continues
      [/Hidden TATWO Work OS contract context]

      Visible after.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        complete,
        role: .user),
      "Visible before.\n\nVisible after.")

    let malformed = """
      Visible before.

      [Hidden TATWO Work OS contract context]
      outer payload
      [Hidden TATWO Ultrawork loopsConfig context]
      nested payload
      [/Hidden TATWO Work OS contract context]

      Visible after.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        malformed,
        role: .user),
      malformed,
      "A malformed nested block must be preserved as one atomic fallback")
  }

  func testOnlyNormalAppInjectedHiddenContextBlockIsRemoved() {
    let userAuthoredLiteral = """
      [Hidden customer-authored documentation example]
      This is user content, not app-injected context.
      [/Hidden customer-authored documentation example]
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        userAuthoredLiteral,
        role: .user),
      userAuthoredLiteral)

    let appInjected = """
      Keep this request.

      [Hidden TATWO Work OS contract context — do not quote to the user unless asked]
      contractID=contract-private
      [/Hidden TATWO Work OS contract context]
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        appInjected,
        role: .user),
      "Keep this request.")
  }

  func testAssistantPairedHiddenContextLiteralRemainsByteForByteVisible() {
    let text = """
      [Hidden example context]
      Assistant-authored documentation example.
      [/Hidden example context]
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantTrailingMemoryCitationIsRemovedFromDisplaySource() {
    let body = """
      Keep the assistant answer visible.
      Preserve this final body line.
      """
    let text = body + """


      <oai-mem-citation>
      <citation_entries>
      MEMORY.md:442-451|note=[workspace evidence]
      </citation_entries>
      <rollout_ids>
      019f2967-9bb0-7702-9e39-e82e06a861b3
      </rollout_ids>
      </oai-mem-citation>
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      body)
  }

  func testUserTrailingMemoryCitationLiteralRemainsByteForByteVisible() {
    let text = """
      User-authored citation example:

      <oai-mem-citation>
      <citation_entries>
      MEMORY.md:1-2|note=[literal user text]
      </citation_entries>
      <rollout_ids>
      </rollout_ids>
      </oai-mem-citation>
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testAssistantInlineMemoryCitationDiscussionRemainsByteForByteVisible() {
    let text = "Explain the literal <oai-mem-citation>example</oai-mem-citation> tag inline."

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantStartOfMessageSameLineMemoryCitationDiscussionRemainsByteForByteVisible() {
    let text = "<oai-mem-citation>literal</oai-mem-citation> is discussed here."

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantStartOfMessageCitationBlockFollowedByProseRemainsByteForByteVisible() {
    let text = """
      <oai-mem-citation>
      <citation_entries>
      MEMORY.md:1-2|note=[quoted at the start]
      </citation_entries>
      <rollout_ids>
      </rollout_ids>
      </oai-mem-citation>
      Ordinary assistant prose follows the quoted block.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantIncompleteMemoryCitationRemainsByteForByteVisible() {
    let text = """
      Keep this incomplete example:
      <oai-mem-citation>
      <citation_entries>
      MEMORY.md:1-2|note=[unfinished]
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantCompleteMemoryCitationFollowedByProseRemainsVisible() {
    let text = """
      This block is quoted for discussion:
      <oai-mem-citation>
      <citation_entries>
      MEMORY.md:1-2|note=[quoted]
      </citation_entries>
      <rollout_ids>
      </rollout_ids>
      </oai-mem-citation>
      The trailing explanation means the block is not anchored to the end.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testUserInlineRequestMarkerDiscussionIsNotTruncated() {
    let text = "請保留前文，並解釋 ## My request for Codex: 這個字面標記後的內容。"

    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        text,
        role: .user,
        status: nil,
        eventKind: .message))
    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testUserProseWithLiteralFilesHeadingRemainsByteForByteVisible() {
    let text = """
      請解釋下面這個字面標記：
      # Files mentioned by the user:
      這一行也是使用者自行輸入的內容
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testIncompleteUserFilesEnvelopeLiteralRemainsByteForByteVisible() {
    let text = """
      # Files mentioned by the user:

      ## example.png: /tmp/example.png
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user),
      text)
  }

  func testCompleteImportedFilesRequestWrapperCleansToActualUserRequest() {
    let text = """
      # Files mentioned by the user:

      ## example.png: /tmp/example.png

      ## My request for Codex:
      Keep the complete actual request visible.
      Do not truncate this second line.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .user)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      """
      Keep the complete actual request visible.
      Do not truncate this second line.
      """)
  }

  func testAssistantLiteralFilesHeadingDiscussionRemainsByteForByteVisible() {
    let text = """
      The literal heading below is being discussed, not used as an imported wrapper:
      # Files mentioned by the user:
      Keep this quoted explanation visible.
      """

    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant),
      text)
  }

  func testAssistantDiscussionOfInternalMarkersRemainsVisible() {
    let examples = [
      "The literal tag <environment_context> can appear in documentation.",
      "The sentence “Another language model started to solve this problem” is part of the handoff template.",
      "The heading ## Handoff Summary is discussed here rather than used as an envelope.",
      "你是 Loops 流程的使用者說明，不是內部委派封套。"
    ]

    for text in examples {
      XCTAssertFalse(
        TatwoChatTranscriptPresentation.isTranscriptNoise(
          text,
          role: .assistant,
          status: nil,
          eventKind: .message))
    }
  }

  func testAnchoredCompleteEnvironmentEnvelopeIsHidden() {
    XCTAssertTrue(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        "<environment_context>\ninternal values\n</environment_context>",
        role: .assistant,
        status: nil,
        eventKind: .message))
  }

  func testAnchoredImportedWrapperCleansToVisibleRequest() {
    let text = """
      <codex_internal_context>internal values</codex_internal_context>
      ## My request for Codex:
      Keep this visible.
      """

    XCTAssertFalse(
      TatwoChatTranscriptPresentation.isTranscriptNoise(
        text,
        role: .assistant,
        status: nil,
        eventKind: .message))
    XCTAssertEqual(
      TatwoChatTranscriptPresentation.cleanedTranscriptSource(
        text,
        role: .assistant)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "Keep this visible.")
  }

  func testPersistenceLimitAppliesAfterTranscriptFiltering() {
    struct Fixture {
      let id: String
      let role: TatwoChatTranscriptRole
      let text: String
      let status: String?
      let eventKind: TatwoNativeChatEventKind
    }

    var messages = (0..<119).map {
      Fixture(
        id: "visible-\($0)",
        role: $0.isMultiple(of: 2) ? .user : .assistant,
        text: "Visible message \($0)",
        status: nil,
        eventKind: .message)
    }
    messages += (0..<5).map {
      Fixture(
        id: "thinking-\($0)",
        role: .assistant,
        text: "hidden thinking",
        status: "thinking",
        eventKind: .thinking)
    }
    messages += (0..<5).map {
      Fixture(
        id: "tool-\($0)",
        role: .assistant,
        text: "hidden tool",
        status: "tool-use",
        eventKind: .toolUse)
    }
    messages += (0..<5).map {
      Fixture(
        id: "internal-\($0)",
        role: .assistant,
        text: "# Context Checkpoint — TATWO Chat Slider Loop \($0)",
        status: nil,
        eventKind: .message)
    }

    let retained = TatwoChatTranscriptPresentation.retainedPersistableSuffix(
      messages,
      limit: 120
    ) {
      !TatwoChatTranscriptPresentation.isTranscriptNoise(
        $0.text,
        role: $0.role,
        status: $0.status,
        eventKind: $0.eventKind)
        && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.status != nil)
    }

    XCTAssertEqual(retained.count, 120)
    XCTAssertEqual(
      retained.map(\.id),
      (9..<119).map { "visible-\($0)" }
        + (0..<5).map { "thinking-\($0)" }
        + (0..<5).map { "tool-\($0)" })
  }
}
