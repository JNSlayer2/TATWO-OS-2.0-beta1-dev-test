import Foundation

public enum TatwoTerminalSpecialKey: Sendable, Equatable, Hashable {
  case carriageReturn
  case tab
  case backspace
  case deleteForward
  case escape
  case upArrow
  case downArrow
  case leftArrow
  case rightArrow
  case home
  case end
  case pageUp
  case pageDown
}

public enum TatwoTerminalInput: Sendable, Equatable, Hashable {
  case text(String)
  case control(Character)
  case special(TatwoTerminalSpecialKey)
}

public enum TatwoTerminalInputEncoder {
  public static func bytes(
    for input: TatwoTerminalInput,
    optionAsMeta: Bool = false
  ) -> [UInt8] {
    let payload: [UInt8]
    switch input {
    case .text(let text):
      payload = Array(text.utf8)
    case .control(let character):
      payload = controlBytes(for: character)
    case .special(let key):
      payload = specialBytes(for: key)
    }
    return optionAsMeta ? [0x1B] + payload : payload
  }

  private static func controlBytes(for character: Character) -> [UInt8] {
    guard let scalar = String(character).unicodeScalars.first else { return [] }
    let value = scalar.value
    switch value {
    case 0x40...0x5F:
      return [UInt8(value & 0x1F)]
    case 0x61...0x7A:
      return [UInt8((value - 0x20) & 0x1F)]
    case 0x20:
      return [0x00]
    case 0x3F:
      return [0x7F]
    default:
      return Array(String(character).utf8)
    }
  }

  private static func specialBytes(for key: TatwoTerminalSpecialKey) -> [UInt8] {
    switch key {
    case .carriageReturn: return [0x0D]
    case .tab: return [0x09]
    case .backspace: return [0x7F]
    case .deleteForward: return [0x1B, 0x5B, 0x33, 0x7E]
    case .escape: return [0x1B]
    case .upArrow: return [0x1B, 0x5B, 0x41]
    case .downArrow: return [0x1B, 0x5B, 0x42]
    case .rightArrow: return [0x1B, 0x5B, 0x43]
    case .leftArrow: return [0x1B, 0x5B, 0x44]
    case .home: return [0x1B, 0x5B, 0x48]
    case .end: return [0x1B, 0x5B, 0x46]
    case .pageUp: return [0x1B, 0x5B, 0x35, 0x7E]
    case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]
    }
  }
}
