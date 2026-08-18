import Foundation
import Translation

@available(iOS 26.0, *)
@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()
    private var cache: [String: String] = [:]
    private init() {}

    func warm(sentences: [String], target: String) async {
        for sentence in sentences where cache[sentence] == nil { _ = await translate(sentence, target: target) }
    }

    func translate(_ sentence: String, target: String) async -> String? {
        if let cached = cache[sentence] { return cached }
        let identifier = target
        guard identifier != "en" else { return sentence }
        do {
            let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: identifier))
            let response = try await session.translate(sentence)
            cache[sentence] = response.targetText
            return response.targetText
        } catch { return nil }
    }
}
