import Testing
import VantageCore
@testable import VantageClientLogic

struct CharacterKeyMapTests {
    @Test func lettersDigitsAndShiftedSymbolsMapToUSLayout() {
        #expect(CharacterKeyMap.stroke(for: "a") == .init(keyCode: 0x00, modifiers: []))
        #expect(CharacterKeyMap.stroke(for: "A") == .init(keyCode: 0x00, modifiers: .shift))
        #expect(CharacterKeyMap.stroke(for: "1") == .init(keyCode: 0x12, modifiers: []))
        #expect(CharacterKeyMap.stroke(for: "!") == .init(keyCode: 0x12, modifiers: .shift))
        #expect(CharacterKeyMap.stroke(for: "?") == .init(keyCode: 0x2C, modifiers: .shift))
        #expect(CharacterKeyMap.stroke(for: " ") == .init(keyCode: 0x31, modifiers: []))
        #expect(CharacterKeyMap.stroke(for: "\n") == .init(keyCode: 0x24, modifiers: []))
        #expect(CharacterKeyMap.stroke(for: "é") == nil)
        #expect(CharacterKeyMap.stroke(for: "🙂") == nil)
    }

    @Test @MainActor func keystrokesModeSendsChordsAndFallsBackToTextForUnmappedCharacters() {
        let input = InputController()
        var sent: [Message] = []
        input.send = { sent.append($0) }
        input.typeCharacters("Hi é!", modifiers: [])
        // H(2) i(2) space(2) é(text) !(2)
        #expect(sent.count == 9)
        guard case .keyEvent(let first) = sent[0] else { Issue.record("expected key event"); return }
        #expect(first.keyCode == 0x04 && first.isDown && first.modifiers == .shift)
        guard case .textInput(let text) = sent[6] else { Issue.record("expected text input"); return }
        #expect(text.text == "é")
    }
}
