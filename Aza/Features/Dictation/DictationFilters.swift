import Foundation

/// Чистая логика фильтров диктовки. Вынесена из DictationController,
/// чтобы тестироваться без WhisperKit (тест-таргет собирает явный список
/// файлов и пакет не линкует).
enum DictationFilters {

    /// Whisper на тишине галлюцинирует связный текст («Субтитры сделал…»),
    /// поэтому запись без единого громкого окна не распознаём вовсе — это
    /// заодно экономит прогон модели.
    // ponytail: энергетический порог вместо VAD-модели; ослабить по логам,
    // если тихую речь начнёт принимать за тишину.
    static let speechRMSThreshold: Float = 0.005

    static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = 1600 // 100 мс при 16 кГц
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var energy: Float = 0
            for sample in samples[index..<end] { energy += sample * sample }
            if (energy / Float(end - index)).squareRoot() >= speechRMSThreshold {
                return true
            }
            index = end
        }
        return false
    }

    /// Свои слова из настройки: строка через запятую или с новой строки.
    static func words(fromCustomList raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Сегменты-галлюцинации по классической эвристике openai/whisper:
    /// модель сама считает окно тишиной (noSpeechProb > 0.6) и при этом
    /// не уверена в тексте (avgLogprob < −1.0) — такой текст выдуман.
    /// WhisperKit эти сегменты не выбрасывает (fallback «silence»
    /// оставляет текст), поэтому чистим сами.
    static func reliableText(
        segments: [(text: String, avgLogprob: Float, noSpeechProb: Float)]
    ) -> String {
        segments
            .filter { $0.noSpeechProb <= 0.6 || $0.avgLogprob >= -1.0 }
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
