import Foundation
import UIKit

enum TextKitPaginator {
    static func paginate(_ text: String, fontSize: CGFloat, width: CGFloat, height: CGFloat) -> [String] {
        let font = UIFont(name: "Times New Roman", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        func fits(_ value: String) -> Bool {
            let rect = (value as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: style], context: nil)
            return rect.height <= height
        }
        var pages: [String] = [], current = ""
        for paragraph in paragraphs {
            let protectedParagraph = paragraph.replacingOccurrences(of: ".jpg", with: "§jpg").replacingOccurrences(of: ".jpeg", with: "§jpeg").replacingOccurrences(of: ".png", with: "§png")
            let sentences = protectedParagraph.split(separator: ".", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "§", with: ".") + "." }
            for sentence in (sentences.isEmpty ? [paragraph] : sentences) {
                if current.isEmpty && !fits(sentence) {
                    var chunk = ""
                    for word in sentence.split(separator: " ") {
                        let candidate = chunk.isEmpty ? String(word) : chunk + " " + word
                        if !chunk.isEmpty && !fits(candidate) {
                            pages.append(chunk)
                            chunk = String(word)
                        } else {
                            chunk = candidate
                        }
                    }
                    current = chunk
                    continue
                }
                let candidate = current.isEmpty ? sentence : current + " " + sentence
                if !current.isEmpty && !fits(candidate) { pages.append(current); current = sentence }
                else { current = candidate }
            }
            if !current.isEmpty {
                let separated = current + "\n\n"
                if fits(separated) { current = separated }
                else { pages.append(current); current = "" }
            }
        }
        if !current.isEmpty { pages.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return pages.isEmpty ? [text] : pages
    }
}
