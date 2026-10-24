@testable import DictationCore
import Testing

struct TextProcessingTests {
    @Test(arguments: [
        "Untertitel im Auftrag des ZDF, 2020",
        "Untertitel der Amara.org-Community",
        "Vielen Dank fürs Zuschauen!",
        "[BLANK_AUDIO]",
        "(Musik)",
        "  Thanks for watching.  ",
    ])
    func hallucinationsBecomeEmpty(_ text: String) {
        #expect(TextProcessing.cleanTranscript(text) == "")
    }

    @Test(arguments: ["...", " . . ", "?!", "—"])
    func punctuationOnlyBecomesEmpty(_ text: String) {
        #expect(TextProcessing.cleanTranscript(text) == "")
    }

    @Test func promptEchoIsDetected() {
        let vocabulary = ["Jonas", "Polarion", "LiveDoc", "Velocity"]
        #expect(TextProcessing.echoesPrompt("Jonas, Polarion, Proyect, Bild, Noctivino.", vocabulary: vocabulary))
        #expect(TextProcessing.echoesPrompt("Polarion, LiveDoc, Velocity, Northwind.", vocabulary: vocabulary))
        #expect(!TextProcessing.echoesPrompt("Im Polarion Projekt fehlt das LiveDoc.", vocabulary: vocabulary))
        #expect(!TextProcessing.echoesPrompt("Jonas hier, kurze Frage zu Polarion.", vocabulary: vocabulary))
        #expect(!TextProcessing.echoesPrompt("Jonas Polarion", vocabulary: ["Jonas"]))
    }

    @Test func sentencesAboutSubtitlesAreKept() {
        let text = "Untertitel brauchen wir für das Schulungsvideo, das wir nächste Woche für den Kunden aufnehmen."
        #expect(TextProcessing.cleanTranscript(text) == text)
    }

    @Test func realSpeechIsKept() {
        #expect(TextProcessing.cleanTranscript(" Das ist ein  Test. ") == "Das ist ein Test.")
        #expect(TextProcessing.cleanTranscript("Hallo [Musik] Welt") == "Hallo Welt")
    }

    @Test func replacementsMatchWholeWordsIgnoringCase() {
        let rules = [Replacement(from: "polarian", to: "Polarion"), Replacement(from: "live doc", to: "LiveDoc")]
        #expect(TextProcessing.applyReplacements("Polarian und die live Doc", rules) == "Polarion und die LiveDoc")
        #expect(TextProcessing.applyReplacements("polarians", rules) == "polarians")
    }

    @Test func replacementTextIsLiteral() {
        let rules = [Replacement(from: "dollar", to: "$1 \\n")]
        #expect(TextProcessing.applyReplacements("ein dollar", rules) == "ein $1 \\n")
    }

    @Test func snippetsMatchWholeDictationOnly() {
        let snippets = [Snippet(trigger: "meine Adresse", text: "Musterstraße 1, 12345 Musterstadt")]
        #expect(TextProcessing.expandSnippet("Meine Adresse.", snippets) == "Musterstraße 1, 12345 Musterstadt")
        #expect(TextProcessing.expandSnippet("Schick mir meine Adresse", snippets) == nil)
        #expect(TextProcessing.expandSnippet("", snippets) == nil)
    }

    @Test func englishFillersAreRemoved() {
        #expect(TextProcessing.removeFillers("Um, so we need uh the fix", language: "en") == "So we need the fix")
        #expect(TextProcessing.removeFillers("umbrella and drum", language: "en") == "umbrella and drum")
    }

    @Test func germanUmIsKept() {
        #expect(TextProcessing.removeFillers("Äh, das Meeting ist um 3, ähm, glaube ich", language: "de")
            == "Das Meeting ist um 3, glaube ich")
    }

    @Test func unknownLanguageIsUnchanged() {
        #expect(TextProcessing.removeFillers("euh bonjour", language: "fr") == "euh bonjour")
    }

    @Test func basicCleanupCapitalisesAndTrims() {
        #expect(TextProcessing.basicCleanup("  hallo   welt ") == "Hallo welt")
        #expect(TextProcessing.basicCleanup("") == "")
    }
}

/// Junk lines from meetings and short real answers that must stay.
struct ForeignPieceTests {
    @Test(arguments: ["Grazie.", "Grazie. Grazie. Grazie", "Ja, okay, det er godt.", "Vi har, uh... Yeah.",
                      "C'est un win-win, c'est super.", "Assoluto. Tenin' quevalanche.", "Is hier nou wat drin?",
                      "Tenks on, ja, ja.", "BIRDLE Mhm."])
    func foreignShortPieceIsDropped(_ text: String) {
        #expect(TextProcessing.isForeignShortPiece(text))
    }

    @Test(arguments: ["Ja.", "Mhm.", "Okay.", "Genau.", "Ah, ok.", "Yeah.", "Mm-hmm.", "Thank you.", "Vielen Dank.",
                      "Stimmt, ich habe vergessen.", "Ja, mach ich.", "Okay, perfect.", "Achso.", "Na gut.", "Nope.",
                      "Product.", "Region LDC.", "Hahahaha", "Kost Ja, das wäre eine sinnvolle Aufteilung.",
                      "Dass man mal sehen könnte, wie so ein Glossary Dictionary in DeepL direkt aussieht."])
    func germanAndEnglishStay(_ text: String) {
        #expect(!TextProcessing.isForeignShortPiece(text))
    }

    @Test func echoThanks() {
        #expect(TextProcessing.isEchoThanks("Grazie. Grazie. Thank you."))
        #expect(TextProcessing.isEchoThanks("Vielen Dank."))
        #expect(!TextProcessing.isEchoThanks("Thank you, I'll send it tomorrow."))
        #expect(!TextProcessing.isEchoThanks("Ja."))
    }
}

struct SpellingGuardTests {
    @Test func misspelledCopiesAreRestored() {
        let spoken = "Mit dem MCP ist ganz cool, aber ich glaube, das funktioniert hier lokal nicht so gut."
        let cleaned = "Mit dem MCP ist ganz cool, aber ich glabe, das funktioniert hier lokal nicht so gut."
        #expect(SpellingGuard.repair(cleaned, transcript: spoken, vocabulary: []) == spoken)
    }

    @Test func intendedChangesStay() {
        #expect(SpellingGuard.repair("Ich nutze novaClinical.", transcript: "ich nutze nowaclinical", vocabulary: ["novaClinical"]) == "Ich nutze novaClinical.")
        #expect(SpellingGuard.repair("Das Ticket ist offen.", transcript: "das ticket ist offen", vocabulary: []) == "Das Ticket ist offen.")
        #expect(SpellingGuard.repair("Um 3 Uhr.", transcript: "um drei uhr", vocabulary: []) == "Um 3 Uhr.")
    }
}

struct CorrectionLearnerTests {
    @Test func replacedWordsAreFound() {
        let pasted = "Ich habe das Meeting in TLD file aufgenommen und an Nowaclinical geschickt."
        let field = "Hallo Kevin,\nIch habe das Meeting in tl;dv aufgenommen und an novaClinical geschickt.\nGruß"
        let found = CorrectionLearner.corrections(pasted: pasted, field: field)
        #expect(found == [Replacement(from: "TLD file", to: "tl;dv"), Replacement(from: "Nowaclinical", to: "novaClinical")])
    }

    @Test func rewritesAndGrammarAreNoCorrections() {
        #expect(CorrectionLearner.corrections(pasted: "Wir testen das morgen früh.", field: "Ganz anderer Text hier.").isEmpty)
        #expect(CorrectionLearner.corrections(pasted: "Die Test laufen morgen.", field: "Die Tests laufen morgen.").isEmpty)
        #expect(CorrectionLearner.corrections(pasted: "Das ist gut.", field: "Das ist gut!").isEmpty)
    }
}

struct TransformResultTests {
    @Test func translationWithOriginalIsCut() {
        let original = "Wir treffen uns morgen um zehn im Büro.\n- Laptop\n- Ladegerät"
        let translation = "We are meeting tomorrow at ten in the office.\n- Laptop\n- Charger"
        #expect(Transform.withoutOriginal(original + "\n\n" + translation, original: original) == translation)
        #expect(Transform.withoutOriginal(translation + "\n\n---\n\n" + original, original: original) == translation)
        #expect(Transform.withoutOriginal(translation, original: original) == translation)
    }

    @Test func correctIsTheNinthAndOldListsGetIt() {
        #expect(Transform.presets.last?.name == "Correct")
        let old = Transform.presets.dropLast().map { $0 }
        #expect(Transform.migrated(old).map(\.name) == Transform.presets.map(\.name))
    }
}
