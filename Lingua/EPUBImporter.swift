import Foundation
import ZIPFoundation

enum EPUBImporter {
    static func extractXHTMLChapters(from url: URL) throws -> [URL] {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = archive.filter {
            let name = ($0.path as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("ch") && name.hasSuffix(".xhtml")
        }.sorted { $0.path < $1.path }
        return try entries.map { entry in
            var data = Data(); _ = try archive.extract(entry) { data.append($0) }
            var html = String(data: data, encoding: .utf8) ?? ""
            let imagePattern = "(<img[^>]+src=\\\"|<img[^>]+src=')([^\\\"']+)([\\\"'])"
            let regex = try NSRegularExpression(pattern: imagePattern, options: [.caseInsensitive])
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed()
            for match in matches {
                guard match.numberOfRanges >= 4, let srcRange = Range(match.range(at: 2), in: html) else { continue }
                var path = String(html[srcRange]).replacingOccurrences(of: "../", with: "")
                if !path.hasPrefix("OEBPS/") { path = "OEBPS/" + path }
                guard let imageEntry = archive.first(where: { $0.path == path }) else { continue }
                var image = Data(); _ = try archive.extract(imageEntry) { image.append($0) }
                let mime = imageEntry.path.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
                html.replaceSubrange(srcRange, with: "data:\(mime);base64,\(image.base64EncodedString())")
            }
            html = html.replacingOccurrences(of: "<head>", with: "<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0\">")
            html = html.replacingOccurrences(of: "</head>", with: "<style>html{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}body{font-family:Georgia,serif;font-size:18px;line-height:1.5;padding:18px 22px;width:100vw;height:100vh;box-sizing:border-box;column-width:100vw;column-gap:0;column-fill:auto;overflow:visible;}h1,h2,h3{text-align:center;margin:18px 0 28px;break-after:avoid;}p{text-indent:1.2em;margin:0 0 1.15em;}img{display:block;max-width:90vw;max-height:70vh;height:auto;margin:20px auto;break-inside:avoid;}</style></head>")
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xhtml")
            try html.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        }
    }
    static func extractImages(from url: URL) throws -> [URL] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [URL] = []
        for entry in archive where ["jpg", "jpeg", "png", "gif"].contains((entry.path as NSString).pathExtension.lowercased()) && !entry.path.lowercased().contains("cover") {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent((entry.path as NSString).lastPathComponent)
            try data.write(to: destination)
            result.append(destination)
        }
        return result
    }
    static func extractFirstImage(from url: URL) throws -> URL {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive.first(where: { $0.path.lowercased().contains("cover") && ($0.path.lowercased().hasSuffix(".jpg") || $0.path.lowercased().hasSuffix(".jpeg") || $0.path.lowercased().hasSuffix(".png")) }) ?? archive.first(where: { $0.path.lowercased().hasSuffix(".jpg") || $0.path.lowercased().hasSuffix(".jpeg") || $0.path.lowercased().hasSuffix(".png") }) else {
            throw NSError(domain: "EPUBImporter", code: 2)
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (entry.path as NSString).pathExtension)
        try data.write(to: destination)
        return destination
    }
    static func extractText(from url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let archive = try Archive(url: url, accessMode: .read)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        var html = ""
        let allEntries = Array(archive)
        let htmlEntries = allEntries.filter { $0.path.lowercased().hasSuffix(".xhtml") || $0.path.lowercased().hasSuffix(".html") }
        let entries = orderedSpineEntries(in: archive, allEntries: allEntries, htmlEntries: htmlEntries)
        for (index, entry) in entries.enumerated() {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            // Keep each spine document separated so chapter headings from the
            // next XHTML file are not glued to the previous paragraph.
            html += "\n\n[EPUB_SPINE_BREAK]\n\n" + (String(data: data, encoding: .utf8) ?? "") + "\n\n"
            progress(Double(index + 1) / Double(max(entries.count, 1)))
        }
        let marked = html.replacingOccurrences(of: "<img[^>]+src=[\\\"']([^\\\"']+)[\\\"'][^>]*>", with: "\n\n[IMAGE:$1]\n\n", options: [.regularExpression, .caseInsensitive])
        let blocks = marked
            .replacingOccurrences(of: "</(p|div|section|article|h1|h2|h3|h4|li|blockquote)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        var text = blocks.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(chapter\\s+[ivxlcdm0-9]+)(?:\\s+\\1)+", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^\\s*\\.\\s*$", with: "", options: .regularExpression)
        let entityRegex = try NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);", options: [])
        for match in entityRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[valueRange])
            let number = value.lowercased().hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value, radix: 10)
            if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(range, with: String(Character(scalar))) }
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private static func orderedSpineEntries(in archive: Archive, allEntries: [Entry], htmlEntries: [Entry]) -> [Entry] {
        guard let opf = allEntries.first(where: { $0.path.lowercased().hasSuffix(".opf") }) else {
            return htmlEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        var opfData = Data()
        guard (try? archive.extract(opf) { opfData.append($0) }) != nil,
              let opfText = String(data: opfData, encoding: .utf8) else { return htmlEntries }
        let itemRegex = try? NSRegularExpression(pattern: "<item\\b[^>]*\\bid=[\\\"']([^\\\"']+)[\\\"'][^>]*\\bhref=[\\\"']([^\\\"']+)[\\\"'][^>]*>", options: [.caseInsensitive])
        let refRegex = try? NSRegularExpression(pattern: "<itemref\\b[^>]*\\bidref=[\\\"']([^\\\"']+)[\\\"'][^>]*/?>", options: [.caseInsensitive])
        guard let itemRegex, let refRegex else { return htmlEntries }
        var manifest: [String: String] = [:]
        for match in itemRegex.matches(in: opfText, range: NSRange(opfText.startIndex..., in: opfText)) {
            if let idRange = Range(match.range(at: 1), in: opfText), let hrefRange = Range(match.range(at: 2), in: opfText) {
                manifest[String(opfText[idRange])] = String(opfText[hrefRange]).removingPercentEncoding ?? String(opfText[hrefRange])
            }
        }
        let base = (opf.path as NSString).deletingLastPathComponent
        var ordered: [Entry] = []
        for match in refRegex.matches(in: opfText, range: NSRange(opfText.startIndex..., in: opfText)) {
            guard let idRange = Range(match.range(at: 1), in: opfText), let href = manifest[String(opfText[idRange])] else { continue }
            let lowerHref = href.lowercased()
            // Navigation and cover XHTML are not reading content.
            if lowerHref.contains("toc") || lowerHref.contains("nav") || lowerHref.contains("cover") { continue }
            let target: String
            if href.hasPrefix("OEBPS/") || href.hasPrefix("OPS/") {
                target = href
            } else {
                target = (base as NSString).appendingPathComponent(href).replacingOccurrences(of: "//", with: "/")
            }
            if let entry = htmlEntries.first(where: { $0.path == target || ($0.path as NSString).lastPathComponent == (target as NSString).lastPathComponent }) { ordered.append(entry) }
        }
        return ordered.isEmpty ? htmlEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } : ordered
    }
}
