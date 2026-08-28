import XCTest

@MainActor
final class DictationFilterTests: XCTestCase {
    func testSilenceGate() {
        // Чистая тишина и шум ниже порога — не речь.
        XCTAssertFalse(DictationFilters.hasSpeech([Float](repeating: 0, count: 16000)))
        XCTAssertFalse(DictationFilters.hasSpeech(
            [Float](repeating: 0.001, count: 16000)))
        // Один громкий всплеск (100 мс) среди тишины — уже речь.
        var speech = [Float](repeating: 0, count: 16000)
        for index in 8000..<9600 { speech[index] = 0.1 }
        XCTAssertTrue(DictationFilters.hasSpeech(speech))
    }

    func testHallucinatedSegmentsDropped() {
        XCTAssertEqual(
            DictationFilters.reliableText(segments: [
                (" Привет, мир.", -0.3, 0.1),
                (" Субтитры сделал DimaTorzok", -1.5, 0.9),
            ]),
            "Привет, мир.")
        // Спец-токены из текста сегмента вычищаются.
        XCTAssertEqual(
            DictationFilters.reliableText(segments: [("<|ru|> Привет.<|endoftext|>", 0, 0)]),
            "Привет.")
    }

    func testCustomWordsParsing() {
        XCTAssertEqual(
            DictationFilters.words(fromCustomList: " Ахьмад, ,\nСоьлжа-ГӀала "),
            ["Ахьмад", "Соьлжа-ГӀала"])
        XCTAssertEqual(DictationFilters.words(fromCustomList: ""), [])
    }
}
