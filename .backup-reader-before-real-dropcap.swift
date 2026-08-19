import SwiftUI
import Translation
import Foundation
import UIKit
import WebKit

struct ReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontSize") private var fontSize = 17.0
    @State private var selectedWord: String?
    @State private var selectedSentence = ""
    @State private var selectedTranslationText = ""
    @State private var showSettings = false
    @State private var page = 0
    @State private var showChrome = false
    @State private var pageOffset: CGFloat = 0
    @State private var isTurningPage = false
    @State private var pageCache: [(title: String, paragraphs: [String])] = []
    @State private var showSystemTranslation = false
    @State private var illustrationURLs: [URL] = []
    @State private var restoredPage = false
    @State private var imageZoom: CGFloat = 1
    @State private var imageZoomAnchor: UnitPoint = .center
    @State private var showChapterList = false
    @State private var isPreparingPages = true

    private let demoChapters = [
        (title: "Chapter one", paragraphs: [
            "The morning was quiet, and the town seemed to be holding its breath. Clara opened the old book by the window.",
            "Some words were familiar. Others felt like small locked doors. She tapped one gently, and its meaning appeared in the sentence.",
            "Reading was no longer a race. It was a conversation, one page at a time."
        ]),
        (title: "Chapter two", paragraphs: [
            "Beyond the garden, a narrow path disappeared into the trees. Clara took the book with her and followed it slowly.",
            "The leaves moved above her like quiet waves. Every page gave her a new reason to continue."
        ]),
        (title: "Chapter three", paragraphs: [
            "At the end of the path stood a small house with a blue door. Someone inside was waiting with a cup of tea.",
            "Clara smiled. The difficult words no longer felt like walls. They were invitations to discover something new."
        ])
    ]

    private var chapters: [(title: String, paragraphs: [String])] {
        if let path = book.importedEPUBPath,
           !path.isEmpty,
           let url = Optional(URL(fileURLWithPath: path)),
           let textURL = try? EPUBImporter.extractText(from: url),
           let text = try? String(contentsOf: textURL, encoding: .utf8) {
            return parseChapters(text)
        }
        guard let resource = book.textResource else {
            if let path = book.importedTextPath, let text = try? String(contentsOfFile: path, encoding: .utf8) { return parseChapters(text) }
            return demoChapters
        }
        if resource.hasSuffix(".epub"), let url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books"), let textURL = try? EPUBImporter.extractText(from: url), let text = try? String(contentsOf: textURL, encoding: .utf8) {
            return parseChapters(text)
        }
        if let url = Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "Books"), let text = try? String(contentsOf: url, encoding: .utf8) {
            return parseChapters(text)
        }
        return demoChapters
    }

    private func parseChapters(_ text: String) -> [(title: String, paragraphs: [String])] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [(String, [String])] = []
        var currentTitle = "Reading"
        var current: [String] = []
        var paragraph = ""
        func flushParagraph() {
            let value = paragraph
                .replacingOccurrences(of: "(?m)(^|\\s)[.·•…]+(?=\\s|$)", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: "^[^[:alnum:]]+$", options: .regularExpression) != nil { paragraph = ""; return }
            if !value.isEmpty { current.append(value) }
            paragraph = ""
        }
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "[EPUB_SPINE_BREAK]" {
                flushParagraph()
                if !current.isEmpty {
                    sections.append((currentTitle, current))
                    current = []
                }
                currentTitle = "Reading"
                continue
            }
            if line.hasPrefix("[EPUB_CHAPTER_BREAK:") && line.hasSuffix("]") {
                flushParagraph()
                if !current.isEmpty { sections.append((currentTitle, current)); current = [] }
                let start = line.index(line.startIndex, offsetBy: "[EPUB_CHAPTER_BREAK:".count)
                let end = line.index(before: line.endIndex)
                let title = String(line[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentTitle = title.isEmpty ? "Reading" : title
                continue
            }
            // EPUBs often contain ornament-only lines (a dot, bullets, or separators).
            // They are not readable content and must never become a paragraph.
            if line.range(of: "^[^[:alnum:]\\[]+$", options: .regularExpression) != nil {
                flushParagraph()
                continue
            }
            if line.range(of: "^chapter\\s+[ivxlcdm0-9]+", options: [.regularExpression, .caseInsensitive]) != nil {
                if line.caseInsensitiveCompare(currentTitle) == .orderedSame { continue }
                flushParagraph()
                if !current.isEmpty { sections.append((currentTitle, current)); current = [] }
                currentTitle = line
                if let range = currentTitle.range(of: "(?i)^chapter\\s+[ivxlcdm0-9]+", options: .regularExpression) {
                    let prefix = currentTitle[range].uppercased()
                    currentTitle.replaceSubrange(range, with: prefix)
                }
            } else if line.range(of: "^[[:punct:]\\s]+$", options: .regularExpression) != nil && line != "[IMAGE]" {
                continue
            } else if line.isEmpty {
                flushParagraph()
            } else if !line.hasPrefix("***") && !line.hasPrefix("THE END") {
                paragraph += (paragraph.isEmpty ? "" : " ") + line
            }
        }
        flushParagraph()
        if !current.isEmpty { sections.append((currentTitle, current)) }
        let parsed = sections.map { (title: $0.0, paragraphs: $0.1) }
        return parsed.isEmpty ? demoChapters : parsed
    }

    var body: some View {
        legacyBody
    }

    private var legacyBody: some View {
        Group {
            if isPreparingPages || displayPages.isEmpty {
                ProgressView("Preparing first page…")
                    .tint(.teal)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let nextPage = pageOffset < 0 ? page + 1 : page - 1
                    ZStack {
                        if nextPage >= 0 && nextPage < displayPages.count && pageOffset != 0 {
                            pageView(index: nextPage, item: displayPages[nextPage])
                        } else {
                            pageView(index: page, item: displayPages[page])
                        }
                        if pageOffset == 0 {
                            pageView(index: page, item: displayPages[page])
                        } else {
                            pageView(index: page, item: displayPages[page])
                                .offset(x: pageOffset)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                guard !isTurningPage else { return }
                                let translation = value.translation.width
                                if (translation < 0 && page < displayPages.count - 1) ||
                                   (translation > 0 && page > 0) {
                                    pageOffset = translation
                                } else {
                                    pageOffset = translation * 0.18
                                }
                            }
                            .onEnded { value in
                                guard !isTurningPage else { return }
                                let threshold = max(70, width * 0.22)
                                let direction: Int
                                if value.translation.width < -threshold && page < displayPages.count - 1 { direction = 1 }
                                else if value.translation.width > threshold && page > 0 { direction = -1 }
                                else { direction = 0 }
                                if direction == 0 {
                                    withAnimation(.easeOut(duration: 0.16)) { pageOffset = 0 }
                                    return
                                }
                                isTurningPage = true
                                withAnimation(.easeOut(duration: 0.20)) {
                                    pageOffset = direction == 1 ? -width : width
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                                    page += direction
                                    pageOffset = 0
                                    isTurningPage = false
                                }
                            }
                    )
                }
            }
        }
        .onAppear {
            loadPagesProgressively()
            loadIllustrations()
        }
        /*
        TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 0) {
                    ZStack {
                        Text(shortTitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 240)
                        HStack {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            }
                            Spacer()
                            Button { showSettings = true } label: {
                                Image(systemName: "textformat.size").font(.system(size: 17, weight: .semibold))
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(item.paragraphs, id: \.self) { paragraph in
                            WordParagraph(text: paragraph, fontSize: fontSize) { word in
                                selectedWord = word
                                selectedSentence = paragraph
                                selectedTranslationText = word
                                showSystemTranslation = true
                            } onSentenceLongPress: { word in
                                selectedWord = nil
                                selectedSentence = sentence(containing: word, in: paragraph)
                                selectedTranslationText = selectedSentence
                                showSystemTranslation = true
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                    .clipped()
                    Spacer(minLength: 0)
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.bottom, 14)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        */
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedWord != nil { selectedWord = nil }
            else { showChrome.toggle() }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if showChrome && !displayPages.isEmpty {
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { Double(page) },
                        set: { page = min(max(Int($0.rounded()), 0), max(displayPages.count - 1, 0)) }
                    ), in: 0...Double(max(displayPages.count - 1, 1)), step: 1)
                    Button {
                        showChapterList = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.horizontal, 18)
                .padding(.bottom, 42)
            }
        }
        .ignoresSafeArea(.container, edges: [.bottom])
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
        }
        .sheet(isPresented: $showSettings) { ReadingSettings(fontSize: $fontSize) }
        .sheet(isPresented: $showChapterList) {
            NavigationStack {
                List(chapterEntries, id: \.page) { entry in
                    Button {
                        page = entry.page
                        showChapterList = false
                    } label: {
                        HStack {
                            Text(entry.title)
                            Spacer()
                            Text("\(entry.page + 1)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .navigationTitle("Chapters")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .translationPresentation(isPresented: $showSystemTranslation, text: selectedTranslationText, attachmentAnchor: .point(.bottom), arrowEdge: .bottom)
        .onChange(of: page) { _, _ in
            imageZoom = 1
            imageZoomAnchor = .center
            saveReadingPosition()
        }
        .onChange(of: showSystemTranslation) { _, isPresented in
            if !isPresented {
                selectedWord = nil
                selectedSentence = ""
            }
        }
        .onDisappear { saveReadingPosition() }
    }

    @ViewBuilder
    private func pageView(index: Int, item: (title: String, paragraphs: [String])) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(shortTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 360)
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "textformat.size").font(.system(size: 17, weight: .semibold)) }
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
            if item.paragraphs.first != nil && (index == 0 || displayPages[index - 1].title != item.title) {
                Text(item.title).font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .center).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 22) {
                let rawPageText = item.paragraphs.joined(separator: "\n\n")
                let blocks = rawPageText.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.range(of: "^[^[:alnum:]\\[]+$", options: .regularExpression) == nil }
                let subtitleIndex = (index == 0 || displayPages[index - 1].title != item.title) && !blocks.first!.hasPrefix("[IMAGE:") ?
                    blocks.firstIndex(where: { !$0.hasPrefix("[IMAGE:") && $0.count < 90 }) : nil
                let subtitle = subtitleIndex.map { blocks[$0] }
                let contentBlocks = blocks.enumerated().filter { $0.offset != subtitleIndex }

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 19, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 2)
                }
                ForEach(Array(contentBlocks), id: \.offset) { entry in
                    let block = entry.element
                    if block.hasPrefix("[IMAGE:"),
                       let token = block.components(separatedBy: "[IMAGE:").dropFirst().first?.components(separatedBy: "]").first,
                       let image = imageForPage(named: token) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 500)
                            .scaleEffect(imageZoom, anchor: imageZoomAnchor)
                            .gesture(
                                MagnifyGesture()
                                    .onChanged { value in
                                        imageZoomAnchor = value.startAnchor
                                        imageZoom = min(max(value.magnification, 1), 2.8)
                                    }
                                    .onEnded { _ in
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                                            imageZoom = 1
                                            imageZoomAnchor = .center
                                        }
                                    }
                            )
                            .layoutPriority(2)
                    } else {
                        let isChapterStart = index == 0 || displayPages[index - 1].title != item.title
                        WordParagraph(text: block, fontSize: readerTextSize, highlightedWord: selectedWord, highlightedSentence: selectedSentence, dropCap: isChapterStart && entry.offset == contentBlocks.first?.offset && item.title != "Reading") { word in
                            selectedWord = word
                            selectedSentence = sentence(containing: word, in: block)
                            selectedTranslationText = word
                            showSystemTranslation = true
                        } onSentenceLongPress: { word in
                            selectedWord = nil
                            selectedSentence = sentence(containing: word, in: block)
                            selectedTranslationText = selectedSentence
                            showSystemTranslation = true
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 44).padding(.top, 18).padding(.bottom, 12).clipped()
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("\(index + 1) of \(displayPages.count)")
                ProgressView(value: Double(index + 1), total: Double(displayPages.count))
                    .progressViewStyle(.linear)
                    .tint(.teal)
                    .frame(width: 46, height: 4)
            }
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    private func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .primary
        return result
    }

    private func sentence(containing word: String, in paragraph: String) -> String {
        var result = paragraph
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) { substring, _, _, stop in
            guard let substring else { return }
            let tokens = substring.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let wanted = word.lowercased().split { !$0.isLetter && !$0.isNumber }.joined()
            if tokens.contains(where: { $0.split { !$0.isLetter && !$0.isNumber }.joined() == wanted }) {
                result = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                stop = true
            }
        }
        return result
    }

    private var pages: [(title: String, paragraphs: [String])] {
        makePages(for: chapters[...])
    }

    private func makePages(for source: ArraySlice<(title: String, paragraphs: [String])>) -> [(title: String, paragraphs: [String])] {
        let width = max(280, UIScreen.main.bounds.width - 88)
        // Header and footer leave most of the screen available for text.
        let height = max(500, UIScreen.main.bounds.height - 235)
        return source.flatMap { chapter in
            let sourceText = normalizeEPUBText(chapter.paragraphs.joined(separator: "\n\n"))
            let imageRegex = try? NSRegularExpression(pattern: "\\[IMAGE:[^\\]]+\\]", options: [])
            var blocks: [String] = []
            var cursor = sourceText.startIndex
            if let imageRegex {
                let matches = imageRegex.matches(in: sourceText, range: NSRange(sourceText.startIndex..., in: sourceText))
                for (matchIndex, match) in matches.enumerated() {
                    guard let matchRange = Range(match.range, in: sourceText) else { continue }
                    let before = String(sourceText[cursor..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty { blocks.append(contentsOf: TextKitPaginator.paginate(before, fontSize: readerTextSize, width: width, height: height)) }
                    let imageMarker = String(sourceText[matchRange])
                    let contentStart = matchRange.upperBound
                    let contentEnd = matchIndex + 1 < matches.count ? (Range(matches[matchIndex + 1].range, in: sourceText)?.lowerBound ?? sourceText.endIndex) : sourceText.endIndex
                    let following = String(sourceText[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let followingSentences = following.components(separatedBy: ".")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let imageText = followingSentences.prefix(3).map { $0 + "." }.joined(separator: " ")
                    blocks.append(imageText.isEmpty ? imageMarker : imageMarker + "\n\n" + imageText)
                    cursor = contentStart
                    if !imageText.isEmpty, let range = sourceText.range(of: imageText, range: contentStart..<contentEnd) { cursor = range.upperBound }
                }
            }
            let after = String(sourceText[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !after.isEmpty { blocks.append(contentsOf: TextKitPaginator.paginate(after, fontSize: readerTextSize, width: width, height: height)) }
            if blocks.isEmpty { blocks = TextKitPaginator.paginate(sourceText, fontSize: readerTextSize, width: width, height: height) }
            // Keep a chapter heading with the following illustration instead of
            // leaving a blank heading-only page before it.
            var compacted: [String] = []
            for block in blocks {
                if block.hasPrefix("[IMAGE:"), let previous = compacted.last,
                   previous.count < 500, !previous.contains("[IMAGE:") {
                    compacted[compacted.count - 1] = previous + "\n\n" + block
                } else {
                    compacted.append(block)
                }
            }
            return compacted
                .map { normalizeEPUBText($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { (title: chapter.title, paragraphs: [$0]) }
        }
        /*
        chapters.flatMap { chapter in
            var result: [(title: String, paragraphs: [String])] = []
            var current: [String] = []
            var length = 0
            for paragraph in chapter.paragraphs.flatMap({ splitForPage($0, limit: 1050) }) {
                if !current.isEmpty && length + paragraph.count > 1050 {
                    result.append((title: chapter.title, paragraphs: current)); current = []; length = 0
                }
                current.append(paragraph); length += paragraph.count
            }
            if !current.isEmpty { result.append((title: chapter.title, paragraphs: current)) }
            return result
        }
        */
    }

    private func normalizeEPUBText(_ value: String) -> String {
        var text = value
        // EPUB exports often leave a second full stop after a closing quote.
        text = text.replacingOccurrences(of: "\".", with: "\"")
        text = text.replacingOccurrences(of: ".\".", with: ".\"")
        text = text.replacingOccurrences(of: "!\".", with: "!\"")
        text = text.replacingOccurrences(of: "?\".", with: "?\"")
        text = text.replacingOccurrences(of: ". \"", with: ".\"")
        text = text.replacingOccurrences(of: "! \"", with: "!\"")
        text = text.replacingOccurrences(of: "? \"", with: "?\"")
        if let quoteRegex = try? NSRegularExpression(pattern: "\\s+\"(?=\\s*[.!?,;:]|\\s*$)") {
            text = quoteRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\"")
        }
        text = text.replacingOccurrences(of: "\" ", with: "\"")
        text = text.replacingOccurrences(of: "  ", with: " ")
        return text
    }

    private var displayPages: [(title: String, paragraphs: [String])] {
        pageCache
    }

    private func loadPagesProgressively() {
        guard pageCache.isEmpty else { isPreparingPages = false; return }
        let source = chapters
        guard !source.isEmpty else { isPreparingPages = false; return }
        pageCache = makePages(for: source.prefix(1))
        restoreReadingPositionIfAvailable()
        guard source.count > 1 else { isPreparingPages = false; return }
        Task { @MainActor in
            for offset in 1..<source.count {
                let chapter = source[offset]
                let next = makePages(for: [chapter][...])
                pageCache.append(contentsOf: next)
                restoreReadingPositionIfAvailable()
                await Task.yield()
            }
            isPreparingPages = false
        }
    }

    private func restoreReadingPositionIfAvailable() {
        guard !restoredPage, !pageCache.isEmpty else { return }
        let key = "lingua.reader.page.\(book.id.uuidString)"
        let saved = UserDefaults.standard.integer(forKey: key)
        if saved < pageCache.count {
            page = saved
            restoredPage = true
        }
    }

    private func saveReadingPosition() {
        let key = "lingua.reader.page.\(book.id.uuidString)"
        UserDefaults.standard.set(page, forKey: key)
        guard !displayPages.isEmpty else { return }
        library.updateProgress(for: book, value: Double(page + 1) / Double(displayPages.count))
    }

    private func loadIllustrations() {
        guard illustrationURLs.isEmpty else { return }
        let url: URL?
        if let path = book.importedEPUBPath { url = URL(fileURLWithPath: path) }
        else if let resource = book.textResource, resource.hasSuffix(".epub") { url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books") }
        else { url = nil }
        guard let url else { return }
        Task {
            let images = await Task.detached(priority: .utility) { (try? EPUBImporter.extractImages(from: url)) ?? [] }.value
            illustrationURLs = images
        }
    }

    private func imageForPage(named name: String?) -> UIImage? {
        guard let name else { return nil }
        let basename = (name as NSString).lastPathComponent
        guard let url = illustrationURLs.first(where: { $0.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame }), let data = try? Data(contentsOf: url) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        return trimWhiteMargins(image)
    }

    private func trimWhiteMargins(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3]
                if a > 8 && (r < 244 || g < 244 || b < 244) {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { return image }
        let padding = 8
        let rect = CGRect(x: max(0, minX - padding), y: max(0, minY - padding),
                          width: min(width - max(0, minX - padding), maxX - minX + padding * 2),
                          height: min(height - max(0, minY - padding), maxY - minY + padding * 2))
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private func splitForPage(_ text: String, limit: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { part, _, _, _ in
            if let part, !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(part.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if sentences.isEmpty { sentences = [text] }
        var chunks: [String] = [], current = ""
        let width = max(280, UIScreen.main.bounds.width - 44)
        let height = max(500, UIScreen.main.bounds.height - 300)
        let font = UIFont(name: "Times New Roman", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        func fits(_ value: String) -> Bool {
            let rect = (value as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            return rect.height <= height
        }
        for sentence in sentences {
            if sentence.count > limit {
                for word in sentence.split(separator: " ") {
                    if current.count + word.count + 1 > limit && !current.isEmpty { chunks.append(current); current = "" }
                    current += (current.isEmpty ? "" : " ") + word
                }
            } else if !fits(current.isEmpty ? sentence : current + " " + sentence) && !current.isEmpty {
                chunks.append(current); current = sentence
            } else { current += (current.isEmpty ? "" : " ") + sentence }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private var shortTitle: String {
        book.title.count > 20 ? String(book.title.prefix(20)) + "…" : book.title
    }

    private var chapterEntries: [(title: String, page: Int)] {
        var result: [(title: String, page: Int)] = []
        var previousTitle: String?
        for (index, item) in displayPages.enumerated() where item.title != previousTitle {
            result.append((title: item.title, page: index))
            previousTitle = item.title
        }
        return result
    }

    private var readerTextSize: CGFloat {
        min(fontSize, 17)
    }
}

struct WordParagraph: View {
    let text: String
    let fontSize: Double
    let highlightedWord: String?
    let highlightedSentence: String
    var dropCap: Bool = false
    let onWordTap: (String) -> Void
    let onSentenceLongPress: (String) -> Void

    var body: some View {
        let words = text.split(separator: " ")
        let sentenceForWord = sentenceMapping
        FlowLayout(spacing: 2, dropCap: dropCap) {
            if dropCap, let first = words.first {
                Text(String(first.prefix(1)))
                    .font(.system(size: fontSize * 2.8, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .onTapGesture { onWordTap(clean(first)) }
                    .onLongPressGesture(minimumDuration: 0.45) { onSentenceLongPress(clean(first)) }
                if first.count > 1 {
                    wordView(index: 0, rawWord: Substring(String(first.dropFirst())), sentenceForWord: sentenceMapping)
                }
                ForEach(Array(words.dropFirst().enumerated()), id: \.offset) { offset, rawWord in
                    wordView(index: offset + 1, rawWord: rawWord, sentenceForWord: sentenceMapping)
                }
            } else {
                ForEach(Array(words.enumerated()), id: \.offset) { index, rawWord in
                    wordView(index: index, rawWord: rawWord, sentenceForWord: sentenceMapping)
                }
            }
        }
    }

    @ViewBuilder
    private func wordView(index: Int, rawWord: Substring, sentenceForWord: [String]) -> some View {
                let cleanWord = clean(rawWord)
                let currentSentence = index < sentenceForWord.count ? sentenceForWord[index] : ""
                let normalizedCurrent = normalize(currentSentence)
                let normalizedSelected = normalize(highlightedSentence)
                let isSelectedSentence = !normalizedSelected.isEmpty && normalizedCurrent == normalizedSelected
                let highlightSentence = highlightedWord == nil && isSelectedSentence
                let highlighted = ((highlightedWord == cleanWord && (highlightedSentence.isEmpty || isSelectedSentence)) || highlightSentence)
                Text(String(rawWord) + " ")
                    .font(.system(size: fontSize, design: .serif))
                    .foregroundStyle(.primary)
                    .background(highlighted ? Color.yellow.opacity(0.55) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { onWordTap(clean(rawWord)) }
                    .onLongPressGesture(minimumDuration: 0.45) { onSentenceLongPress(clean(rawWord)) }
    }

    private var sentenceMapping: [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(substring) }
        }
        return sentences.flatMap { sentence in
            Array(repeating: sentence, count: sentence.split { !$0.isLetter && !$0.isNumber }.count)
        }
    }

    private func clean(_ word: Substring) -> String {
        normalize(String(word))
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    }
}

struct EPUBReaderView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var chapters: [URL] = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1)
                Spacer()
                Image(systemName: "textformat.size")
            }
            .font(.system(size: 18, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 12)
            if chapters.isEmpty {
                ProgressView("Opening EPUB…")
            } else {
                TabView {
                    ForEach(chapters, id: \.self) { url in EPUBChapterWebView(url: url) }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(Color(.systemBackground))
        .task {
            guard let resource = book.textResource, let url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books") else { return }
            chapters = (try? await Task.detached(priority: .userInitiated) { try EPUBImporter.extractXHTMLChapters(from: url) }.value) ?? []
        }
    }
}

struct EPUBBookWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.scrollView.isPagingEnabled = true
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.alwaysBounceHorizontal = true
        view.scrollView.alwaysBounceVertical = false
        view.scrollView.isDirectionalLockEnabled = true
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { view.loadHTMLString(html, baseURL: nil) }
}

struct EPUBChapterWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.scrollView.isPagingEnabled = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.alwaysBounceHorizontal = true
        view.scrollView.alwaysBounceVertical = false
        view.scrollView.isDirectionalLockEnabled = true
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        view.loadHTMLString(html, baseURL: nil)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var dropCap = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, row = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let leftInset = dropCap && index > 0 && row < 3 ? min(58, width * 0.18) : 0
            if x == 0 { x = leftInset }
            if x + size.width > width && x > leftInset { x = 0; y += rowHeight + spacing; rowHeight = 0; row += 1; if dropCap && row < 3 { x = min(58, width * 0.18) } }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0, row = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let leftInset = dropCap && index > 0 && row < 3 ? min(58, bounds.width * 0.18) : 0
            if x == bounds.minX { x += leftInset }
            if x + size.width > bounds.maxX && x > bounds.minX + leftInset { x = bounds.minX + (row < 3 && dropCap ? leftInset : 0); y += rowHeight + spacing; rowHeight = 0; row += 1 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ReadingSettings: View {
    @Binding var fontSize: Double
    var body: some View { NavigationStack { Form { Section("Text size") { Slider(value: $fontSize, in: 16...30, step: 1); Text("Preview text").font(.system(size: fontSize, design: .serif)) }; Section("Appearance") { Label("Automatic theme", systemImage: "circle.lefthalf.filled") } }.navigationTitle("Reading") } }
}
