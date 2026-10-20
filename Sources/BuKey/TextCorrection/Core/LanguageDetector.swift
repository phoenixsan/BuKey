import Foundation

protocol WordScoring {
    func score(_ word: String, layout: KeyboardLayout) -> Double
}

protocol LanguageDetecting {
    func correction(for token: String) -> String?
}

struct LanguageDetector: LanguageDetecting {
    private let scorer: any WordScoring
    private let minimumGain: Double
    private let plausibilityFloor: Double

    init(scorer: any WordScoring = BundledWordScorer.shared, minimumGain: Double = 8.0, plausibilityFloor: Double = -10) {
        self.scorer = scorer
        self.minimumGain = minimumGain
        self.plausibilityFloor = plausibilityFloor
    }

    func correction(for token: String) -> String? {
        guard TokenPolicy.isEligibleForAutomaticCorrection(token) else { return nil }
        let candidate = LayoutConverter.convertToOppositeLayout(token)
        guard candidate != token, let originalLayout = LayoutConverter.dominantLayout(in: token) else { return nil }

        let candidateLayout: KeyboardLayout = originalLayout == .english ? .russian : .english
        let originalScore = scorer.score(token.lowercased(), layout: originalLayout)
        let candidateScore = scorer.score(candidate.lowercased(), layout: candidateLayout)
        guard candidateScore >= plausibilityFloor, candidateScore - originalScore >= minimumGain else { return nil }
        return candidate
    }
}

private struct BundledWordScorer: WordScoring {
    static let shared = BundledWordScorer()

    private let frequencies: [String: Double]
    private let bigrams: [String: Double]
    private let totalBigrams: Double

    private init() {
        let lines = Self.wordLists.flatMap { $0.split(separator: "\n") }
        var parsed: [String: Double] = [:]
        var counts: [String: Double] = [:]
        for line in lines {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let frequency = Double(parts[1]) else { continue }
            let word = String(parts[0]).lowercased()
            parsed[word] = frequency
            for bigram in Self.bigrams(in: word) { counts[bigram, default: 0] += frequency }
        }
        frequencies = parsed
        bigrams = counts
        totalBigrams = max(counts.values.reduce(0, +), 1)
    }

    func score(_ word: String, layout: KeyboardLayout) -> Double {
        if let frequency = frequencies[word] { return Foundation.log(frequency) }
        let wordBigrams = Self.bigrams(in: word)
        guard !wordBigrams.isEmpty else { return -100 }
        let vocabularySize = Double(max(bigrams.count, 1))
        let likelihood = wordBigrams.reduce(0.0) { partial, bigram in
            partial + Foundation.log((bigrams[bigram, default: 0] + 1) / (totalBigrams + vocabularySize))
        }
        return likelihood / Double(wordBigrams.count)
    }

    private static func bigrams(in word: String) -> [String] {
        let padded = Array("^") + Array(word) + Array("$")
        return zip(padded, padded.dropFirst()).map { String($0.0) + String($0.1) }
    }

    private static var wordLists: [String] {
        ["en_words", "ru_words"].compactMap { name in
#if SWIFT_PACKAGE
            Bundle.module.url(forResource: name, withExtension: "txt")
#else
            Bundle.main.url(forResource: name, withExtension: "txt")
#endif
        }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
