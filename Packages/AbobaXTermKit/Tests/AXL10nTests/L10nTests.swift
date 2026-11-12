import Testing
@testable import AXL10n

@Suite("L10n", .serialized)
struct L10nTests {
    @Test("English is the identity translation")
    func englishIdentity() {
        L10n.shared.overrideForThisRun(.english)
        #expect(L("Settings") == "Settings")
        #expect(L("Connect to %@", "example.com") == "Connect to example.com")
    }

    @Test("Russian looks up a known key and falls back for an unknown one")
    func russianLookup() {
        L10n.shared.overrideForThisRun(.russian)
        #expect(L("Settings") == "Настройки")
        #expect(L("Not a translated phrase at all") == "Not a translated phrase at all")
        L10n.shared.overrideForThisRun(.english)
    }

    @Test("Positional placeholders fill in order")
    func positionalPlaceholders() {
        L10n.shared.overrideForThisRun(.english)
        #expect(L10nFormat.fill("%2$@ / %1$@", ["a", "b"]) == "b / a")
    }

    @Test("Sequential placeholders fill in order")
    func sequentialPlaceholders() {
        #expect(L10nFormat.fill("%@ of %@", ["3", "10"]) == "3 of 10")
    }

    @Test("Russian plural index follows one/few/many")
    func russianPluralIndex() {
        #expect(L10nFormat.russianPluralIndex(1) == 0)
        #expect(L10nFormat.russianPluralIndex(21) == 0)
        #expect(L10nFormat.russianPluralIndex(2) == 1)
        #expect(L10nFormat.russianPluralIndex(24) == 1)
        #expect(L10nFormat.russianPluralIndex(5) == 2)
        #expect(L10nFormat.russianPluralIndex(11) == 2)
        #expect(L10nFormat.russianPluralIndex(0) == 2)
    }

    @Test("LN picks the Russian form and falls back without a table entry")
    func lnRussian() {
        L10n.shared.overrideForThisRun(.russian)
        #expect(LN(1, "%@ session", "%@ sessions") == "1 сессия")
        #expect(LN(2, "%@ session", "%@ sessions") == "2 сессии")
        #expect(LN(5, "%@ session", "%@ sessions") == "5 сессий")
        #expect(LN(3, "%@ widget", "%@ widgets") == "3 widgets")
        L10n.shared.overrideForThisRun(.english)
    }

    @Test("LN picks English singular vs. plural")
    func lnEnglish() {
        L10n.shared.overrideForThisRun(.english)
        #expect(LN(1, "%@ session", "%@ sessions") == "1 session")
        #expect(LN(2, "%@ session", "%@ sessions") == "2 sessions")
    }
}
