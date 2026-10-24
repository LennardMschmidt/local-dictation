import Testing
@testable import DictationCore

struct CountedListTests {
    @Test func germanItemsBecomeANumberedList() {
        let text = "Ich habe zwei Punkte. Erstens, der Export-Button reagiert nicht. Zweitens wird der Titel überschrieben, wenn ich importiere."
        #expect(CountedList.format(text) == "Ich habe zwei Punkte:\n1. Der Export-Button reagiert nicht.\n2. Wird der Titel überschrieben, wenn ich importiere.")
    }

    @Test func shortPhrasesStayAsSpoken() {
        let text = "Für die Demo brauchen wir erstens den Server, zweitens die Testdaten und drittens die Folien."
        #expect(CountedList.format(text) == "Für die Demo brauchen wir:\n1. den Server\n2. die Testdaten\n3. die Folien")
    }

    @Test func englishClauseStartsCount() {
        let text = "Two things. First, the bar is too big. Second, the hover is too aggressive."
        #expect(CountedList.format(text) == "Two things:\n1. The bar is too big.\n2. The hover is too aggressive.")
    }

    @Test func ordinaryEnglishIsLeftAlone() {
        let text = "At first I thought it was the second model that failed."
        #expect(CountedList.format(text) == text)
        let single = "Erstens ist das nur ein Punkt."
        #expect(CountedList.format(single) == single)
    }

    @Test func itemsWithoutIntroStartTheList() {
        #expect(CountedList.format("Firstly the server. Secondly the data.") == "1. The server.\n2. The data.")
    }

    @Test func aListAlreadyFormattedStaysUnchanged() {
        let text = "Zwei Punkte:\n1. Der Export.\n2. Der Titel."
        #expect(CountedList.format(text) == text)
    }
}

struct CountedListPipelineTests {
    @Test func rawTextGetsTheListWhenCleanupIsOff() async {
        var settings = DictationSettings()
        settings.llm.enabled = false
        let pipeline = DictationPipeline(settings: settings, transcriber: SilentTranscriber(), cleaner: nil)
        let result = await pipeline.process(transcript: Transcript(text: "Zwei Punkte. Erstens der Export. Zweitens der Titel.", language: "de"),
                                            style: .code)
        #expect(result.text == "Zwei Punkte:\n1. Der Export.\n2. Der Titel.")
    }
}

private struct SilentTranscriber: Transcriber {
    func transcribe(samples: [Float], language: String?, vocabulary: [String]) async throws -> Transcript {
        Transcript(text: "", language: "de")
    }
}
