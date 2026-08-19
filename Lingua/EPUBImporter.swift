import Foundation
import ReadiumZIPFoundation

enum EPUBImporter {
    private static func blocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    static func extractXHTMLChapters(from url: URL) throws -> [URL] {
        let archive = try blocking { try await Archive(url: url, accessMode: .read) }
        let allEntries = try blocking { try await archive.entries() }
        let entries = allEntries.filter {
            let name = ($0.path as NSString).lastPathComponent.lowercased()
            return name.hasPrefix("ch") && name.hasSuffix(".xhtml")
        }.sorted { $0.path < $1.path }
        return try entries.map { entry in
            var data = Data(); _ = try blocking { try await archive.extract(entry) { data.append($0) } }
            var html = String(data: data, encoding: .utf8) ?? ""
            let imagePattern = "(<img[^>]+src=\\\"|<img[^>]+src=')([^\\\"']+)([\\\"'])"
            let regex = try NSRegularExpression(pattern: imagePattern, options: [.caseInsensitive])
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed()
            for match in matches {
                guard match.numberOfRanges >= 4, let srcRange = Range(match.range(at: 2), in: html) else { continue }
                var path = String(html[srcRange]).replacingOccurrences(of: "../", with: "")
                if !path.hasPrefix("OEBPS/") { path = "OEBPS/" + path }
                guard let imageEntry = allEntries.first(where: { $0.path == path }) else { continue }
                var image = Data(); _ = try blocking { try await archive.extract(imageEntry) { image.append($0) } }
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
        let archive = try blocking { try await Archive(url: url, accessMode: .read) }
        let allEntries = try blocking { try await archive.entries() }
        var result: [URL] = []
        for entry in allEntries where ["jpg", "jpeg", "png", "gif"].contains((entry.path as NSString).pathExtension.lowercased()) && !entry.path.lowercased().contains("cover") {
            var data = Data()
            _ = try blocking { try await archive.extract(entry) { data.append($0) } }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent((entry.path as NSString).lastPathComponent)
            try data.write(to: destination)
            result.append(destination)
        }
        return result
    }
    static func extractFirstImage(from url: URL) throws -> URL {
        let archive = try blocking { try await Archive(url: url, accessMode: .read) }
        let allEntries = try blocking { try await archive.entries() }
        guard let entry = allEntries.first(where: { $0.path.lowercased().contains("cover") && ($0.path.lowercased().hasSuffix(".jpg") || $0.path.lowercased().hasSuffix(".jpeg") || $0.path.lowercased().hasSuffix(".png")) }) ?? allEntries.first(where: { $0.path.lowercased().hasSuffix(".jpg") || $0.path.lowercased().hasSuffix(".jpeg") || $0.path.lowercased().hasSuffix(".png") }) else {
            throw NSError(domain: "EPUBImporter", code: 2)
        }
        var data = Data()
        _ = try blocking { try await archive.extract(entry) { data.append($0) } }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (entry.path as NSString).pathExtension)
        try data.write(to: destination)
        return destination
    }
    static func extractText(from url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let archive = try blocking { try await Archive(url: url, accessMode: .read) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        var html = ""
        let allEntries = try blocking { try await archive.entries() }
        let htmlEntries = allEntries.filter { $0.path.lowercased().hasSuffix(".xhtml") || $0.path.lowercased().hasSuffix(".html") }
        let entries = orderedSpineEntries(in: archive, allEntries: allEntries, htmlEntries: htmlEntries)
        let tocTitles = tocTitles(in: archive, allEntries: allEntries)
        for (index, entry) in entries.enumerated() {
            var data = Data()
            _ = try blocking { try await archive.extract(entry) { data.append($0) } }
            // Keep each spine document separated so chapter headings from the
            // next XHTML file are not glued to the previous paragraph.
            var document = String(data: data, encoding: .utf8) ?? ""
            let fileName = (entry.path as NSString).lastPathComponent.lowercased()
            let chapterTitle = titleFromHeading(in: document) ?? tocTitles[fileName]
            // The XHTML title belongs to the document metadata, not to the
            // readable body. Keeping it here made the book title appear a
            // second time above the first paragraph of every spine item.
            document = document.replacingOccurrences(
                of: "<head\\b[^>]*>[\\s\\S]*?</head>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            if chapterTitle != nil {
                document = removingFirstHeading(from: document)
            }
            let marker = chapterTitle.map { "[EPUB_CHAPTER_BREAK:\($0)]" } ?? "[EPUB_SPINE_BREAK]"
            html += "\n\n\(marker)\n\n" + document + "\n\n"
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
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&lsquo;", with: "‘")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
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
        guard (try? blocking { try await archive.extract(opf) { opfData.append($0) } }) != nil,
              let opfText = String(data: opfData, encoding: .utf8) else { return htmlEntries }
        let itemRegex = try? NSRegularExpression(pattern: "<item\\b([^>]*)/?>", options: [.caseInsensitive])
        let refRegex = try? NSRegularExpression(pattern: "<itemref\\b([^>]*)/?>", options: [.caseInsensitive])
        guard let itemRegex, let refRegex else { return htmlEntries }
        struct ManifestItem { let id: String; let href: String; let properties: String }
        var manifest: [String: ManifestItem] = [:]
        for match in itemRegex.matches(in: opfText, range: NSRange(opfText.startIndex..., in: opfText)) {
            guard let attributesRange = Range(match.range(at: 1), in: opfText) else { continue }
            let attributes = String(opfText[attributesRange])
            guard let id = attribute("id", in: attributes), let href = attribute("href", in: attributes) else { continue }
            manifest[id] = ManifestItem(id: id, href: href, properties: attribute("properties", in: attributes) ?? "")
        }
        let base = (opf.path as NSString).deletingLastPathComponent
        var ordered: [Entry] = []
        for match in refRegex.matches(in: opfText, range: NSRange(opfText.startIndex..., in: opfText)) {
            guard let attributesRange = Range(match.range(at: 1), in: opfText) else { continue }
            let attributes = String(opfText[attributesRange])
            guard let idref = attribute("idref", in: attributes), let item = manifest[idref] else { continue }
            let lowerHref = item.href.lowercased()
            if item.properties.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains("nav") || item.id.lowercased() == "toc" || lowerHref.contains("toc") || lowerHref.contains("nav") { continue }
            let target = normalizedArchivePath((base as NSString).appendingPathComponent(item.href))
            if let entry = allEntries.first(where: { normalizedArchivePath($0.path) == target }) { ordered.append(entry) }
        }
        return ordered.isEmpty ? htmlEntries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } : ordered
    }

    private static func tocTitles(in archive: Archive, allEntries: [Entry]) -> [String: String] {
        guard let ncx = allEntries.first(where: { $0.path.lowercased().hasSuffix(".ncx") }) else { return [:] }
        var data = Data()
        guard (try? blocking { try await archive.extract(ncx) { data.append($0) } }) != nil,
              let xml = String(data: data, encoding: .utf8) else { return [:] }
        let pattern = #"(?is)<navPoint\b[^>]*>.*?<navLabel[^>]*>\s*<text[^>]*>\s*(.*?)\s*</text>.*?<content\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*/?>.*?</navPoint>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let titleRange = Range(match.range(at: 1), in: xml),
                  let sourceRange = Range(match.range(at: 2), in: xml) else { continue }
            let title = String(xml[titleRange])
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = String(xml[sourceRange]).components(separatedBy: "#").first ?? ""
            let fileName = (source as NSString).lastPathComponent.lowercased()
            if !title.isEmpty && !fileName.isEmpty { result[fileName] = title }
        }
        return result
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
              let range = Range(match.range(at: 1), in: attributes) else { return nil }
        return String(attributes[range]).removingPercentEncoding ?? String(attributes[range])
    }

    private static func titleFromHeading(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<h[1-3]\\b[^>]*>([\\s\\S]*?)</h[1-3]>", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[_—–-]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func removingFirstHeading(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<h[1-3]\\b[^>]*>[\\s\\S]*?</h[1-3]>", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { return html }
        return String(html[..<range.lowerBound]) + "\n\n" + String(html[range.upperBound...])
    }

    private static func normalizedArchivePath(_ path: String) -> String {
        var components: [String] = []
        for component in (path.removingPercentEncoding ?? path).replacingOccurrences(of: "\\\\", with: "/").split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(component))
        }
        return components.joined(separator: "/")
    }
}
