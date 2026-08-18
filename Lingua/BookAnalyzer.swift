import Foundation

struct BookAnalysis {
    let level: EnglishLevel
    let a1a2Share: Int
    let b1Share: Int
    let b2PlusShare: Int
    let explanation: String
}

enum BookAnalyzer {
    /// Lightweight, offline MVP heuristic. Replace the word bands with a bundled frequency list later.
    static func analyze(_ text: String) -> BookAnalysis {
        let words = text.lowercased().split { !$0.isLetter }
        guard !words.isEmpty else { return BookAnalysis(level: .b1, a1a2Share: 65, b1Share: 25, b2PlusShare: 10, explanation: "Подойдёт для B1, иногда потребуется перевод.") }
        let longWords = words.filter { $0.count >= 9 }.count
        let sentences = max(1, text.split(whereSeparator: { ".!?".contains($0) }).count)
        let averageSentenceLength = Double(words.count) / Double(sentences)
        let difficulty = Double(longWords) / Double(words.count) * 100 + max(0, averageSentenceLength - 14) * 0.7
        let level: EnglishLevel = difficulty < 9 ? .a2 : difficulty < 15 ? .b1 : difficulty < 22 ? .b2 : difficulty < 30 ? .c1 : .c2
        let easy = max(35, min(80, Int(78 - difficulty * 1.4)))
        let mid = max(12, min(40, Int(17 + difficulty * 0.5)))
        return BookAnalysis(level: level, a1a2Share: easy, b1Share: mid, b2PlusShare: 100 - easy - mid, explanation: "Подойдёт для \(level.rawValue), иногда потребуется перевод.")
    }
}
