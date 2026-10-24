import Testing
@testable import DictationCore

struct TranslationAndListEndTests {
    @Test func aTranslatedClauseIsNoticed() {
        let raw = "Der Deploy auf dem Server hat geklappt, but the frontend still shows the old version."
        #expect(TranslationGuard.translated("Der Deploy auf dem Server hat geklappt. Das Frontend zeigt immer noch die alte Version.", transcript: raw))
        #expect(!TranslationGuard.translated("Der Deploy auf dem Server hat geklappt, but the frontend still shows the old version.", transcript: raw))
    }

    @Test func cleaningAndCorrectionsAreNotTranslation() {
        #expect(!TranslationGuard.translated("Please send the invoice to Julia.", transcript: "Please send the invoice to Paul. No, sorry, to Julia."))
        #expect(!TranslationGuard.translated("Also, ich glaube, wir sollten das nochmal testen.",
                                             transcript: "Ähm, also, ich glaube, äh, wir sollten das, ähm, nochmal testen."))
    }

    @Test func aSentenceAfterTheListGetsItsOwnParagraph() {
        let text = "Drei offene Punkte:\n1. Das Dashboard lädt langsam.\n2. Die Spalte fehlt.\n3. Die Übersetzung stimmt nicht. Das nächste Review ist am Donnerstag.\n\nBis dahin klappt der Export."
        #expect(CountedList.separateAfterList(text)
                == "Drei offene Punkte:\n1. Das Dashboard lädt langsam.\n2. Die Spalte fehlt.\n3. Die Übersetzung stimmt nicht.\n\nDas nächste Review ist am Donnerstag.\n\nBis dahin klappt der Export.")
    }

    @Test func anItemWithTwoSentencesInsideAListStays() {
        let text = "Zwei Punkte:\n1. Der Export ist langsam. Das war schon gestern so.\n2. Der Import bricht ab. Das ist neu."
        #expect(CountedList.separateAfterList(text) == text)
    }

    @Test func aCorrectionThatDropsWordsIsNoTranslation() {
        #expect(!TranslationGuard.translated("Let's use the green one.",
                                             transcript: "Let's use the blue design. Scratch that, let's use the green one."))
    }

    @Test func sentencesTheModelMadeIntoBulletsBecomeTextAgain() {
        let transcript = "Notizen aus dem Gespräch. Der Kunde möchte die Freigabe der Dokumente vereinfachen. Wir haben vorgeschlagen, dass nur noch der Projektleiter unterschreibt."
        let model = "Notizen aus dem Gespräch:\n- Der Kunde möchte die Freigabe der Dokumente vereinfachen.\n- Wir haben vorgeschlagen, dass nur noch der Projektleiter unterschreibt."
        #expect(CountedList.unlistSentences(model, transcript: transcript)
                == "Notizen aus dem Gespräch. Der Kunde möchte die Freigabe der Dokumente vereinfachen. Wir haben vorgeschlagen, dass nur noch der Projektleiter unterschreibt.")
    }

    @Test func aRealEnumerationStaysAList() {
        let model = "Für die Demo brauchen wir:\n- den Laptop\n- den Beamer\n- das Testkonto"
        #expect(CountedList.unlistSentences(model, transcript: "Für die Demo brauchen wir den Laptop, den Beamer und das Testkonto.") == model)
    }
}
