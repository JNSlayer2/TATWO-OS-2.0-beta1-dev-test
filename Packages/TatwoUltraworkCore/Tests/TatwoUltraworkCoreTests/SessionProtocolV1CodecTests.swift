import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("SessionProtocolV1 JSON codec")
struct SessionProtocolV1CodecTests {
  @Test("encode decode preserves every envelope field")
  func roundTrip() throws {
    let fixture = try SessionProtocolV1.Envelope.notification(
      method: .itemDelta,
      payload: SessionProtocolV1.Item(
        id: "item-1", turnID: "turn-1", kind: .message, delta: "chunk"),
      client: SessionProtocolV1.Client(
        kind: .localChat, executionLocation: .local),
      adapterMetadata: .init(source: "native"))

    let encoded = try SessionProtocolV1.JSONCodec.encode(fixture)
    let decoded = try SessionProtocolV1.JSONCodec.decode(encoded)
    #expect(decoded == fixture)
  }

  @Test("unknown event is preserved without authority promotion")
  func unknownEvent() throws {
    let json = Data("""
      {"majorVersion":1,"minorVersion":99,"kind":"notification",
       "method":"tatwo.future.capability","payload":{"authority":"owner","value":7}}
      """.utf8)
    let decoded = try SessionProtocolV1.JSONCodec.decode(json)
    #expect(decoded.method == "tatwo.future.capability")
    #expect(decoded.payload == .object([
      "authority": .string("owner"), "value": .number(7),
    ]))
    #expect(decoded.authorityEffect == .none)
  }

  @Test("unknown major version is rejected")
  func rejectsUnknownMajor() {
    let json = Data("""
      {"majorVersion":2,"minorVersion":0,"kind":"notification",
       "method":"tatwo.turn.started","payload":{}}
      """.utf8)
    #expect(throws: SessionProtocolV1.CodecError.self) {
      try SessionProtocolV1.JSONCodec.decode(json)
    }
  }
}
