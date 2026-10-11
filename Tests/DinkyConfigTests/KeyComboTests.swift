import Carbon.HIToolbox
import Testing
@testable import DinkyConfig

struct KeyComboTests {
    @Test func forms() throws {
        #expect(try KeyCombo("esc") == KeyCombo(key: "esc"))
        #expect(try KeyCombo("r") == KeyCombo(key: "r"))
        #expect(try KeyCombo("ctrl-left") == KeyCombo(modifiers: .ctrl, key: "left"))
        #expect(try KeyCombo("alt-1") == KeyCombo(modifiers: .alt, key: "1"))
        #expect(try KeyCombo("alt-shift-h") == KeyCombo(modifiers: [.alt, .shift], key: "h"))
        #expect(try KeyCombo("alt-shift-semicolon") == KeyCombo(modifiers: [.alt, .shift], key: "semicolon"))
        #expect(try KeyCombo("cmd-ctrl-alt-shift-f12") == KeyCombo(modifiers: [.alt, .ctrl, .cmd, .shift], key: "f12"))
        #expect(try KeyCombo("alt-minus").key == "minus")
        #expect(try KeyCombo("keypad-enter").key == "keypad-enter")
        #expect(try KeyCombo("alt-page-up") == KeyCombo(modifiers: .alt, key: "page-up"))
        #expect(try KeyCombo("page-down") == KeyCombo(key: "page-down"))
        #expect(try KeyCombo("shift-alt-left-bracket").description == "alt-shift-left-bracket")
        for name in KeyCombo.keyCodes.keys {
            #expect(try KeyCombo("alt-\(name)").key == name)
            #expect(try KeyCombo(name).key == name)
        }
    }

    @Test func `Mouse buttons`() throws {
        #expect(try KeyCombo("alt-mouse-middle") == KeyCombo(modifiers: .alt, key: "mouse-middle"))
        #expect(try KeyCombo("mouse-4").mouseButton == 3)
        #expect(try KeyCombo("ctrl-shift-mouse-left").mouseButton == 0)
        #expect(try KeyCombo("alt-h").mouseButton == nil)
        for name in KeyCombo.mouseButtons.keys {
            #expect(KeyCombo.keyCodes[name] == nil, "\(name) is also a key")
            #expect(try KeyCombo("cmd-\(name)").key == name)
        }
        #expect(throws: ConfigError.self) { try KeyCombo("alt-mouse-6") }
    }

    @Test func `Modifier names`() {
        #expect(KeyCombo.Modifiers(names: "alt") == .alt)
        #expect(KeyCombo.Modifiers(names: "shift-ctrl-alt") == [.alt, .ctrl, .shift])
        #expect(KeyCombo.Modifiers(names: "super") == nil)
        #expect(KeyCombo.Modifiers(names: "alt-") == nil)
        #expect(KeyCombo.Modifiers(names: "alt-h") == nil)
    }

    @Test func `Key names are kebab-case`() {
        for name in KeyCombo.keyCodes.keys {
            #expect(name == name.lowercased(), "\(name)")
        }
    }

    @Test func `Key codes`() {
        #expect(KeyCombo.keyCodes.count == 100)
        #expect(Set(KeyCombo.keyCodes.values).count == 100, "two names share a keycode")
        #expect(KeyCombo.keyCodes["a"] == UInt16(kVK_ANSI_A))
        #expect(KeyCombo.keyCodes["page-up"] == UInt16(kVK_PageUp))
        #expect(KeyCombo.keyCodes["keypad-enter"] == UInt16(kVK_ANSI_KeypadEnter))
        #expect(KeyCombo.keyCodes["backtick"] == UInt16(kVK_ANSI_Grave))
    }

    @Test(arguments: ["", "alt-", "alt--", "hyper-a", "alt-shift-hh", "alt-Semicolon", "-a", "option-a", "pageUp", "alt-page"])
    func `Bad combos`(combo: String) {
        let error = #expect(throws: ConfigError.self) {
            try KeyCombo(combo)
        }
        if let error { #expect("\(error)".contains("'\(combo)'"), "\(error)") }
    }
}
