import Foundation
import Testing
@testable import DictationCore

struct CleanupChunksTests {
    @Test func shortTextStaysInOnePiece() {
        #expect(CleanupChunks.split("Kurzer Satz. Noch einer.") == ["Kurzer Satz. Noch einer."])
    }

    @Test func listStaysWithItsIntroductionAndCorrectionsWithTheirSentence() {
        let filler = String(repeating: "Das ist ein Satz zum Auffüllen. ", count: 8)
        let text = filler + "Folgende Punkte haben wir geklärt. Erstens, das Budget. Zweitens, der Zeitplan. Drittens, die Folien. "
            + "Bis Mittwoch. Nein, bis Dienstag."
        let chunks = CleanupChunks.split(text, maximumCharacters: 120)
        #expect(chunks.count > 1)
        #expect(chunks.contains { $0.contains("Folgende Punkte") && $0.contains("Erstens") && $0.contains("Drittens") })
        #expect(chunks.contains { $0.contains("Bis Mittwoch. Nein, bis Dienstag.") })
        #expect(chunks.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func sentencesDoNotEndAtNumbers() {
        #expect(CleanupChunks.sentences("Bis zum 15. November. Danach frei.") == ["Bis zum 15. November.", "Danach frei."])
    }

    @Test func mixedDictationNamesBothLanguages() {
        let text = "Der Export läuft jetzt sauber durch. The main risk is the migration of the work items."
        #expect(CleanupChunks.languages(text, main: "de") == "de+en")
        #expect(CleanupChunks.languages("Wir nutzen das Work Item im Backlog.", main: "de") == "de")
    }

    @Test func numberGuard() {
        #expect(!CleanupChunks.keepsNumbers("mit einem Puffer von 0,10.", transcript: "mit einem Puffer von 10%."))
        #expect(!CleanupChunks.keepsNumbers("Das kostet 8.500 Euro.", transcript: "Sprint 42, nein, 43. Das kostet 18.500 Euro."))
        #expect(CleanupChunks.keepsNumbers("In Sprint 43. Um 14:30 Uhr, 12,000 items.", transcript: "In Sprint 42, nein, Sprint 43. Um 14.30 Uhr, 12.000 items."))
    }

    @Test func correctionWordsNeedACommaWhenTheyAreShort() {
        #expect(CleanupChunks.lastCorrection(in: "Let's meet at 3, no, at 4.") != nil)
        #expect(CleanupChunks.lastCorrection(in: "Lass uns um drei treffen, nein, um vier.") != nil)
        #expect(CleanupChunks.lastCorrection(in: "Das kostet 300 Euro, oder nein, 400.") != nil)
        #expect(CleanupChunks.lastCorrection(in: "No problem, the meeting is at 3.") == nil)
        #expect(CleanupChunks.lastCorrection(in: "I have no time at 3 today.") == nil)
        #expect(CleanupChunks.lastCorrection(in: "Machen wir das so oder anders?") == nil)
        #expect(CleanupChunks.opensCorrection("No, at 5."))
        #expect(!CleanupChunks.opensCorrection("No idea why it moved."))
    }

    @Test func aNumberTakenBackInTheNextSentenceMayGo() {
        #expect(CleanupChunks.keepsNumbers("Can I come on Monday at 5?", transcript: "Can I come on Monday at 3? No, at 5."))
        #expect(CleanupChunks.keepsNumbers("Let's meet at 4.", transcript: "Let's meet at 3, no, at 4."))
        // Without a correction the number has to stay.
        #expect(!CleanupChunks.keepsNumbers("The meeting. No idea why it moved.", transcript: "The meeting at 3. No idea why it moved."))
    }

    @Test func shortSentencesWithACorrectionGoToTheModel() {
        #expect(!TextProcessing.isShortAndPlain("Let's meet at 3, no, at 4."))
        #expect(!TextProcessing.isShortAndPlain("Das kostet 300 Euro, oder nein, 400."))
        #expect(TextProcessing.isShortAndPlain("No problem, the meeting is at 3."))
    }

    @Test func aDroppedWeekdayIsRepaired() {
        let transcript = "Das nächste Review ist am Donnerstag um 10, nein, um 11 Uhr. Bis dahin klappt der Export."
        #expect(!CleanupChunks.keepsNumbers("Das nächste Review ist um 11 Uhr. Bis dahin klappt der Export.", transcript: transcript))
        #expect(CleanupChunks.keepsNumbers("Das nächste Review ist am Donnerstag um 11 Uhr. Bis dahin klappt der Export.", transcript: transcript))
        // A weekday that was taken back may go.
        #expect(CleanupChunks.keepsNumbers("Das Release kommt am Dienstag.", transcript: "Das Release kommt am Montag, quatsch, am Dienstag."))
    }

    @Test func anInventedNumberIsNoticed() {
        let transcript = "Die Kosten liegen bei 12.500 Euro. Ich meine 14.000 Euro."
        #expect(CleanupChunks.inventsNumbers("Die Kosten liegen bei 6500 Euro. Ich meine 14.000 Euro.", transcript: transcript))
        #expect(!CleanupChunks.inventsNumbers("Die Kosten liegen bei 14.000 Euro.", transcript: transcript))
        #expect(!CleanupChunks.inventsNumbers("Das Meeting ist um 10:30.", transcript: "Das Meeting ist um halb 11."))
        #expect(!CleanupChunks.inventsNumbers("Das Budget liegt bei 25.000 Euro.", transcript: "Das Budget liegt bei zwanzigtausend Euro, oder nein, bei fünfundzwanzigtausend."))
    }

    @Test func halfPastMustNotLoseTheHalf() {
        #expect(CleanupChunks.losesHalfHour("Das Meeting ist am Donnerstag um 11.", transcript: "Das Meeting ist am Donnerstag um 10, nein um halb 11."))
        #expect(!CleanupChunks.losesHalfHour("Das Meeting ist am Donnerstag um halb 11.", transcript: "Das Meeting ist am Donnerstag um 10, nein um halb 11."))
        #expect(!CleanupChunks.losesHalfHour("Das Meeting ist am Donnerstag um 10:30.", transcript: "Das Meeting ist um halb 11."))
        #expect(!CleanupChunks.losesHalfHour("Das Meeting ist um 11.", transcript: "Das Meeting ist um 11."))
    }

    @Test func stuttersGoButRelativeClausesStay() {
        #expect(TextProcessing.removeFillers("müssen die die Testfälle", language: "de") == "müssen die Testfälle")
        #expect(TextProcessing.removeFillers("Kunden, die die Software nutzen", language: "de") == "Kunden, die die Software nutzen")
    }
}

struct CleanupRepairTests {
    @Test func lostNumberIsRepairedInItsSentenceOnly() {
        let transcript = "Sprint 42, nein, Sprint 43. Das Angebot liegt bei 18.500 Euro netto."
        let cleaned = "Sprint 43.\nDas Angebot liegt bei 8.500 Euro netto."
        #expect(CleanupChunks.repairNumbers(cleaned, transcript: transcript) == "Sprint 43.\nDas Angebot liegt bei 18.500 Euro netto.")
    }

    @Test func countedItemsWrittenAsBulletsGetNumbers() {
        let transcript = "Wir haben drei Punkte. Erstens, das Budget. Zweitens, der Zeitplan. Drittens, die Folien."
        let text = "Wir haben drei Punkte:\n- Das Budget.\n- Der Zeitplan.\n- Die Folien."
        #expect(CountedList.numberCountedBullets(text, transcript: transcript) == "Wir haben drei Punkte:\n1. Das Budget.\n2. Der Zeitplan.\n3. Die Folien.")
        #expect(CountedList.numberCountedBullets(text, transcript: "Budget, Zeitplan und Folien.") == text)
    }

    @Test func orderedLinesBecomeANumberedList() {
        let text = "Wir haben drei Punkte:\nErstens, das Budget.\nZweitens, der Zeitplan.\n\nErstens kommt es anders."
        #expect(CountedList.formatLines(text) == "Wir haben drei Punkte:\n1. Das Budget.\n2. Der Zeitplan.\n\nErstens kommt es anders.")
    }
}

struct EarlyCleanupTests {
    static let long = """
    Hallo Lea, hier die Zusammenfassung von unserem Termin mit Proseware heute Vormittag. Es ging hauptsächlich um novaRisk und novaFMEA. \
    Folgende Punkte haben wir geklärt. Erstens, die Risikobewertung soll künftig 5 statt 3 Stufen haben. Zweitens, Proseware möchte \
    die FMEA-Tabellen als Excel exportieren können. Drittens, für die Validierung brauchen wir bis zum 30. November ein Testprotokoll. \
    Nina hat gefragt, ob wir das in Sprint 42, nein, Sprint 43 einplanen können. Ich denke, das geht, wenn Tim die Migration bis \
    Mittwoch, ach nein, bis Dienstag fertig hat. Zum Budget. Das Angebot liegt bei 18.500 Euro netto, also etwa 22.000 Euro brutto. \
    Was meinst du, sollen wir den Workshop vor Ort in Feldkirchen machen oder remote? Noch zwei Sachen am Rande. Die Aufnahme liegt in tl;dv. \
    Und bitte schick mir bis morgen um 9 Uhr die aktuelle Version vom MDX-Konzept. Okay, I think that's everything for now.
    """

    /// Whatever the recording has reached, the sections cleaned early are the first sections of
    /// the final text, so the final run can take them over.
    @Test func earlySectionsAreTheFirstSectionsOfTheFinalText() {
        let sentences = CleanupChunks.sentences(Self.long)
        let final = CleanupChunks.split(Self.long)
        #expect(final.count >= 3)
        for count in 1..<sentences.count {
            let early = CleanupChunks.split(sentences.prefix(count).joined(separator: " ")).dropLast()
            #expect(Array(final.prefix(early.count)) == Array(early), "after \(count) sentences")
        }
    }

    @Test func finalRunTakesTheSectionsCleanedEarly() async {
        let counter = CountingCleaner()
        var settings = DictationSettings()
        settings.vocabulary = []
        let pipeline = DictationPipeline(settings: settings, transcriber: SilentTranscriber(), cleaner: counter)
        let early = EarlyCleanup()
        let sentences = CleanupChunks.sentences(Self.long)
        await early.update(text: sentences.prefix(sentences.count - 3).joined(separator: " "), language: "de", bundleId: nil, pipeline: pipeline)
        let started = await early.count
        #expect(started >= 1)
        let result = await pipeline.process(transcript: Transcript(text: Self.long, language: "de"), style: .plain, early: early)
        #expect(result.sectionsCleanedEarly == started)
        #expect(await counter.calls == result.sections)
    }
}

private actor CallCount { var value = 0; func add() { value += 1 } }

private struct CountingCleaner: TextCleaner {
    let count = CallCount()
    var calls: Int { get async { await count.value } }
    func clean(_ request: CleanupRequest) async throws -> String {
        await count.add()
        return request.transcript
    }
}

private struct SilentTranscriber: Transcriber {
    func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        Transcript(text: "", language: "de")
    }
}
