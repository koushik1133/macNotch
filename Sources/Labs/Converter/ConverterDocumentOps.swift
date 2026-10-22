import AppKit
import CoreText
import Foundation

/// Word / RTF / HTML / text / Markdown → PDF, Word and text; CSV and XLSX →
/// PDF tables; PPTX → text-only slide PDF. Rendering is TextKit 1 laid out
/// off screen (one text container per page) into a CoreGraphics PDF.
enum ConverterDocuments {
    struct Loaded {
        var text: NSAttributedString
        var paperSize: CGSize?
        var margins: NSEdgeInsets?
    }

    // MARK: Loading

    static func load(_ url: URL) throws -> Loaded {
        let ext = url.pathExtension.lowercased()
        if ConverterEngine.kind(of: url) == .markdown {
            let source = try readText(url)
            return Loaded(text: ConverterMarkdown.render(source), paperSize: nil, margins: nil)
        }

        var attributes: NSDictionary?
        let text: NSAttributedString
        do {
            switch ext {
            case "html", "htm", "webarchive":
                // NSAttributedString's HTML importer needs WebKit on the main
                // thread; textutil does the same conversion in its own process
                // and, with -noload, never fetches remote resources.
                let rtf = try ConverterEngine.runTool("/usr/bin/textutil", ["-noload", "-convert", "rtf", "-stdout", url.path])
                text = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: &attributes)
            case "txt", "text":
                let string = try readText(url)
                text = NSAttributedString(string: string, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.black,
                ])
            default:
                let type: NSAttributedString.DocumentType? = switch ext {
                case "docx": .officeOpenXML
                case "doc": .docFormat
                case "rtf": .rtf
                case "rtfd": .rtfd
                case "odt": .openDocument
                case "xml", "wordml": .wordML
                default: nil
                }
                guard let type else { throw ConverterError.unsupported("Can't read .\(ext) files") }
                text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attributes)
            }
        } catch let error as ConverterError {
            throw error
        } catch {
            throw ConverterError.unreadable(url.lastPathComponent)
        }

        let dictionary = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        let paper = (dictionary[.paperSize] as? NSValue)?.sizeValue
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
            (dictionary[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        var margins: NSEdgeInsets?
        if let left = margin(.leftMargin), let right = margin(.rightMargin) {
            margins = NSEdgeInsets(top: margin(.topMargin) ?? 72, left: left, bottom: margin(.bottomMargin) ?? 72, right: right)
        }
        let validPaper = paper.flatMap { $0.width >= 144 && $0.height >= 144 ? $0 : nil }
        return Loaded(text: text, paperSize: validPaper, margins: margins)
    }

    static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ConverterError.unreadable(url.lastPathComponent) }
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .utf16) { return string }
        if let string = String(data: data, encoding: .windowsCP1252) { return string }
        throw ConverterError.unreadable(url.lastPathComponent)
    }

    // MARK: Writing

    static func writeDocx(_ text: NSAttributedString, to url: URL) throws {
        do {
            let data = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
    }

    /// Paginates `text` into a PDF and returns the page count.
    @discardableResult
    static func renderAttributed(
        _ text: NSAttributedString,
        pageSize: CGSize,
        margins: NSEdgeInsets,
        to url: URL,
        progress: ConverterProgress
    ) throws -> Int {
        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " "))
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        let content = CGSize(width: max(72, pageSize.width - margins.left - margins.right),
                             height: max(72, pageSize.height - margins.top - margins.bottom))

        // One container per page until every glyph is placed. A form feed
        // (page break) moves layout to the next container.
        var containers: [NSTextContainer] = []
        var emptyInARow = 0
        while containers.count < 5000 {
            try Task.checkCancellation()
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            emptyInARow = range.length == 0 ? emptyInARow + 1 : 0
            if emptyInARow >= 3 { break }
        }

        var defaultBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextCreator: "SparkV"]
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, info as CFDictionary) else {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
        let appearance = NSAppearance(named: .aqua)
        let origin = CGPoint(x: margins.left, y: margins.top)
        for (index, container) in containers.enumerated() {
            try Task.checkCancellation()
            var box = CGRect(origin: .zero, size: pageSize)
            context.beginPage(mediaBox: &box)
            context.saveGState()
            // TextKit draws in flipped (top-left origin) coordinates.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let range = layout.glyphRange(for: container)
            let draw = {
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()
            progress(Double(index + 1) / Double(containers.count))
        }
        context.closePDF()
        return containers.count
    }

    /// Any document (Word, RTF, HTML, text, Markdown) → PDF at `url`.
    @discardableResult
    static func renderPDF(of input: URL, to url: URL, progress: ConverterProgress) throws -> Int {
        let loaded = try load(input)
        let page = loaded.paperSize ?? ConverterPageSize.regionalDefault
        let margins = loaded.margins ?? NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        return try renderAttributed(loaded.text, pageSize: page, margins: margins, to: url, progress: progress)
    }

    static func toPDF(_ input: URL, in directory: URL, progress: ConverterProgress) throws -> ConverterOutput {
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "pdf")
        let pages = try renderPDF(of: input, to: out, progress: progress)
        return ConverterOutput(files: [out], summary: "\(input.pathExtension.uppercased()) → \(pages)-page PDF")
    }

    static func toWord(_ input: URL, in directory: URL) throws -> ConverterOutput {
        let loaded = try load(input)
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "docx")
        try writeDocx(loaded.text, to: out)
        return ConverterOutput(files: [out], summary: "\(input.pathExtension.uppercased()) → Word")
    }

    static func toText(_ input: URL, in directory: URL) throws -> ConverterOutput {
        let loaded = try load(input)
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "txt")
        do {
            try loaded.text.string.write(to: out, atomically: true, encoding: .utf8)
        } catch {
            throw ConverterError.writeFailed(out.lastPathComponent)
        }
        return ConverterOutput(files: [out], summary: "\(input.pathExtension.uppercased()) → TXT")
    }

    // MARK: Tables (CSV / TSV / XLSX)

    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    static func loadSheets(_ url: URL) throws -> [Sheet] {
        switch ConverterEngine.kind(of: url) {
        case .table:
            let text = try readText(url)
            let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ConverterCSV.guessDelimiter(text)
            return [Sheet(name: ConverterEngine.baseName(url), rows: ConverterCSV.parse(text, delimiter: delimiter))]
        case .spreadsheet:
            return try ConverterXLSX.sheets(of: url)
        default:
            throw ConverterError.unsupported("Not a spreadsheet")
        }
    }

    @discardableResult
    static func renderTablePDF(of input: URL, to url: URL, progress: ConverterProgress) throws -> Int {
        let sheets = try loadSheets(input).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw ConverterError.unreadable("\(input.lastPathComponent) (empty)") }
        return try ConverterTableRenderer.render(sheets, to: url, progress: progress)
    }

    static func tableToPDF(_ input: URL, in directory: URL, progress: ConverterProgress) throws -> ConverterOutput {
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "pdf")
        let pages = try renderTablePDF(of: input, to: out, progress: progress)
        return ConverterOutput(files: [out], summary: "\(input.pathExtension.uppercased()) → \(pages)-page PDF")
    }

    // MARK: Slides (PPTX, text only)

    @discardableResult
    static func renderSlidesPDF(of input: URL, to url: URL, progress: ConverterProgress) throws -> Int {
        let slides = try ConverterXLSX.slideTexts(of: input)
        guard !slides.isEmpty else { throw ConverterError.unreadable("\(input.lastPathComponent) (no slides)") }
        let text = NSMutableAttributedString()
        let titleFont = NSFont.boldSystemFont(ofSize: 26)
        let bodyFont = NSFont.systemFont(ofSize: 15)
        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 6
        let title = NSMutableParagraphStyle()
        title.paragraphSpacing = 14
        for (index, paragraphs) in slides.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\u{0C}", attributes: [.font: bodyFont])) }
            for (line, paragraph) in paragraphs.enumerated() {
                let isTitle = line == 0
                text.append(NSAttributedString(
                    string: (isTitle ? paragraph : "•  " + paragraph) + "\n",
                    attributes: [.font: isTitle ? titleFont : bodyFont, .paragraphStyle: isTitle ? title : body,
                                 .foregroundColor: NSColor.black]
                ))
            }
            if paragraphs.isEmpty { text.append(NSAttributedString(string: " \n", attributes: [.font: bodyFont])) }
        }
        return try renderAttributed(text, pageSize: CGSize(width: 960, height: 540),
                                    margins: NSEdgeInsets(top: 48, left: 56, bottom: 40, right: 56),
                                    to: url, progress: progress)
    }

    static func slidesToPDF(_ input: URL, in directory: URL, progress: ConverterProgress) throws -> ConverterOutput {
        let out = ConverterEngine.uniqueURL(in: directory, name: ConverterEngine.baseName(input), ext: "pdf")
        let pages = try renderSlidesPDF(of: input, to: out, progress: progress)
        return ConverterOutput(files: [out], summary: "\(pages) slide\(pages == 1 ? "" : "s") → PDF (text only)")
    }
}

// MARK: - Markdown

/// Small Markdown → NSAttributedString renderer: headings, lists, quotes,
/// code blocks, rules, and inline bold/italic/code/links (via Foundation's
/// inline Markdown parser).
enum ConverterMarkdown {
    static func render(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11.5)
        let code = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        var inCode = false

        func paragraph(indent: CGFloat = 0, spacing: CGFloat = 5) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            return style
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                output.append(NSAttributedString(string: rawLine + "\n", attributes: [
                    .font: code, .foregroundColor: NSColor(white: 0.15, alpha: 1),
                    .backgroundColor: NSColor(white: 0.94, alpha: 1), .paragraphStyle: paragraph(indent: 8, spacing: 0),
                ]))
                continue
            }
            if line.isEmpty {
                output.append(NSAttributedString(string: "\n", attributes: [.font: body]))
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                output.append(NSAttributedString(string: String(repeating: "─", count: 40) + "\n", attributes: [
                    .font: body, .foregroundColor: NSColor(white: 0.7, alpha: 1),
                ]))
                continue
            }
            var level = 0
            while level < line.count, line[line.index(line.startIndex, offsetBy: level)] == "#" { level += 1 }
            if level > 0, level <= 6, line.dropFirst(level).first == " " {
                let sizes: [CGFloat] = [22, 18, 15, 13, 12, 11.5]
                let font = NSFont.boldSystemFont(ofSize: sizes[level - 1])
                output.append(inline(String(line.dropFirst(level + 1)), font: font, style: paragraph(spacing: 8)))
                continue
            }
            if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                let text = line.dropFirst(marker.count)
                let taskDone = text.hasPrefix("[x] ") || text.hasPrefix("[X] ")
                let taskOpen = text.hasPrefix("[ ] ")
                let bullet = taskDone ? "☑︎ " : taskOpen ? "☐ " : "•  "
                let content = taskDone || taskOpen ? String(text.dropFirst(4)) : String(text)
                let indent = CGFloat((rawLine.prefix { $0 == " " }.count / 2) * 14)
                output.append(inline(bullet + content, font: body, style: paragraph(indent: 10 + indent, spacing: 3)))
                continue
            }
            if line.hasPrefix(">") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                let italic = NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: body.pointSize) ?? body
                output.append(inline(text, font: italic, style: paragraph(indent: 16), color: NSColor(white: 0.35, alpha: 1)))
                continue
            }
            output.append(inline(line, font: body, style: paragraph()))
        }
        return output
    }

    private static func inline(_ text: String, font: NSFont, style: NSParagraphStyle, color: NSColor = .black) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let parsed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var traits = font.fontDescriptor.symbolicTraits
            var strike = false
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.strikethrough) { strike = true }
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                }
            }
            if runFont == font, traits != font.fontDescriptor.symbolicTraits {
                runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color, .paragraphStyle: style]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1)
            }
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        return result
    }
}

// MARK: - CSV

enum ConverterCSV {
    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let counts: [(Character, Int)] = [",", ";", "\t", "|"].map { delimiter in
            (delimiter, firstLine.filter { $0 == delimiter }.count)
        }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// RFC 4180-style: quoted fields, "" escapes, newlines inside quotes.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                quoted = true
            case delimiter:
                row.append(field)
                field = ""
            case "\n", "\r", "\r\n":
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default:
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

// MARK: - XLSX / PPTX (zip + XML)

enum ConverterXLSX {
    private static func entries(of url: URL) throws -> [String] {
        let data = try ConverterEngine.runTool("/usr/bin/unzip", ["-Z1", url.path])
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func member(_ name: String, of url: URL) throws -> Data {
        try ConverterEngine.runTool("/usr/bin/unzip", ["-p", url.path, name])
    }

    /// Sorts "xl/worksheets/sheet10.xml" after "sheet2.xml".
    private static func numbered(_ names: [String], prefix: String) -> [String] {
        names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }
            .sorted { lhs, rhs in
                let left = Int(lhs.dropFirst(prefix.count).dropLast(4)) ?? 0
                let right = Int(rhs.dropFirst(prefix.count).dropLast(4)) ?? 0
                return left < right
            }
    }

    static func sheets(of url: URL) throws -> [ConverterDocuments.Sheet] {
        let names: [String]
        do { names = try entries(of: url) } catch { throw ConverterError.unreadable(url.lastPathComponent) }
        let sheetFiles = numbered(names, prefix: "xl/worksheets/sheet")
        guard !sheetFiles.isEmpty else { throw ConverterError.unreadable("\(url.lastPathComponent) (no sheets)") }
        let shared = names.contains("xl/sharedStrings.xml")
            ? SharedStringsParser.parse((try? member("xl/sharedStrings.xml", of: url)) ?? Data())
            : []
        let titles = names.contains("xl/workbook.xml")
            ? SheetNamesParser.parse((try? member("xl/workbook.xml", of: url)) ?? Data())
            : []
        var sheets: [ConverterDocuments.Sheet] = []
        for (index, file) in sheetFiles.enumerated() {
            try Task.checkCancellation()
            let rows = WorksheetParser.parse(try member(file, of: url), shared: shared)
            let name = index < titles.count ? titles[index] : "Sheet \(index + 1)"
            sheets.append(ConverterDocuments.Sheet(name: name, rows: rows))
        }
        return sheets
    }

    /// Each slide's paragraphs (title first), from ppt/slides/slideN.xml.
    static func slideTexts(of url: URL) throws -> [[String]] {
        let names: [String]
        do { names = try entries(of: url) } catch { throw ConverterError.unreadable(url.lastPathComponent) }
        return try numbered(names, prefix: "ppt/slides/slide").map { file in
            try Task.checkCancellation()
            return SlideTextParser.parse(try member(file, of: url))
        }
    }

    // MARK: Parsers

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inText = false
        var inItem = false
        var inPhonetic = false

        static func parse(_ data: Data) -> [String] {
            let delegate = SharedStringsParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "si": inItem = true; current = ""
            case "rPh": inPhonetic = true
            case "t": inText = inItem && !inPhonetic
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": strings.append(current); inItem = false
            case "rPh": inPhonetic = false
            case "t": inText = false
            default: break
            }
        }
    }

    private final class SheetNamesParser: NSObject, XMLParserDelegate {
        var names: [String] = []

        static func parse(_ data: Data) -> [String] {
            let delegate = SheetNamesParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.names
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "sheet", let title = attributes["name"] { names.append(title) }
        }
    }

    private final class WorksheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var cells: [Int: [Int: String]] = [:]
        var rowIndex = -1
        var column = 0
        var cellType = ""
        var value = ""
        var collecting = false
        var maxColumn = -1

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let delegate = WorksheetParser(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            guard let lastRow = delegate.cells.keys.max(), delegate.maxColumn >= 0 else { return [] }
            let width = min(delegate.maxColumn + 1, 200)
            return (0...min(lastRow, 50_000)).map { row in
                (0..<width).map { delegate.cells[row]?[$0] ?? "" }
            }
        }

        /// "BC12" → column 54 (0-based), row 11.
        static func position(_ reference: String) -> (column: Int, row: Int)? {
            var column = 0
            var digits = ""
            for char in reference.uppercased() {
                if let ascii = char.asciiValue, char.isLetter {
                    column = column * 26 + Int(ascii - 64)
                } else if char.isNumber {
                    digits.append(char)
                }
            }
            guard column > 0, let row = Int(digits) else { return nil }
            return (column - 1, row - 1)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                if let r = attributes["r"], let index = Int(r) { rowIndex = index - 1 } else { rowIndex += 1 }
                column = 0
            case "c":
                if let reference = attributes["r"], let position = Self.position(reference) {
                    column = position.column
                    rowIndex = position.row
                }
                cellType = attributes["t"] ?? ""
                value = ""
            case "v", "t":
                collecting = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t":
                collecting = false
            case "c":
                let text: String
                switch cellType {
                case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "b": text = value == "1" ? "TRUE" : "FALSE"
                case "inlineStr", "str", "e": text = value
                default: text = Self.formatNumber(value)
                }
                if !text.isEmpty, rowIndex >= 0 {
                    cells[rowIndex, default: [:]][column] = text
                    maxColumn = max(maxColumn, column)
                }
                column += 1
            default:
                break
            }
        }

        static func formatNumber(_ raw: String) -> String {
            guard let number = Double(raw), raw.contains(".") || raw.contains("E") || raw.contains("e") else { return raw }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.maximumSignificantDigits = 10
            formatter.usesSignificantDigits = true
            return formatter.string(from: NSNumber(value: number)) ?? raw
        }
    }

    private final class SlideTextParser: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        var current = ""
        var inText = false

        static func parse(_ data: Data) -> [String] {
            let delegate = SlideTextParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.paragraphs
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "a:p" { current = "" }
            if name == "a:t" { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "a:t" { inText = false }
            if name == "a:p" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { paragraphs.append(trimmed) }
            }
        }
    }
}

// MARK: - Table rendering

/// Draws sheets as grids: bold header row repeated on every page, zebra
/// rows, column widths from content, landscape and smaller type for wide
/// sheets.
enum ConverterTableRenderer {
    static func render(_ sheets: [ConverterDocuments.Sheet], to url: URL, progress: ConverterProgress) throws -> Int {
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextCreator: "SparkV"]
        guard let context = CGContext(url as CFURL, mediaBox: &defaultBox, info as CFDictionary) else {
            throw ConverterError.writeFailed(url.lastPathComponent)
        }
        let portrait = ConverterPageSize.regionalDefault
        let margin: CGFloat = 32
        let text = CGColor(gray: 0.1, alpha: 1)
        let grid = CGColor(gray: 0.8, alpha: 1)
        let headerFill = CGColor(gray: 0.9, alpha: 1)
        let zebra = CGColor(gray: 0.97, alpha: 1)
        var pages = 0
        let totalRows = max(1, sheets.reduce(0) { $0 + $1.rows.count })
        var drawnRows = 0

        for sheet in sheets {
            let columns = sheet.rows.map(\.count).max() ?? 0
            guard columns > 0 else { continue }
            // Natural widths at 9 pt from the first 400 rows.
            let probeFont = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
            var widths = [CGFloat](repeating: 24, count: columns)
            for row in sheet.rows.prefix(400) {
                for (index, cell) in row.enumerated() where !cell.isEmpty {
                    let width = ConverterPDF.lineWidth(ConverterPDF.makeLine(String(cell.prefix(80)), font: probeFont, color: text)) + 10
                    widths[index] = min(max(widths[index], width), 200)
                }
            }
            let natural = widths.reduce(0, +)
            let landscape = natural > portrait.width - margin * 2
            let pageSize = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
            let available = pageSize.width - margin * 2
            let scale = min(1, max(0.45, available / natural))
            let fontSize = 9 * scale
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
            let columnWidths = widths.map { $0 * scale }
            let rowHeight = fontSize * 1.75
            let header = sheet.rows[0]
            let body = Array(sheet.rows.dropFirst())
            var cursor = 0
            var first = true

            repeat {
                try Task.checkCancellation()
                var box = CGRect(origin: .zero, size: pageSize)
                context.beginPage(mediaBox: &box)
                pages += 1
                var y = pageSize.height - margin
                if first, sheets.count > 1 || !sheet.name.isEmpty {
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: margin, y: y - 12)
                    CTLineDraw(ConverterPDF.makeLine(sheet.name, font: titleFont, color: text), context)
                    y -= 22
                }
                first = false

                func drawRow(_ cells: [String], top: CGFloat, font: CTFont, fill: CGColor?) {
                    var x = margin
                    let rect = CGRect(x: margin, y: top - rowHeight, width: min(available, columnWidths.reduce(0, +)), height: rowHeight)
                    if let fill {
                        context.setFillColor(fill)
                        context.fill(rect)
                    }
                    for (index, width) in columnWidths.enumerated() {
                        let cell = index < cells.count ? cells[index] : ""
                        let cellRect = CGRect(x: x, y: top - rowHeight, width: width, height: rowHeight)
                        if !cell.isEmpty {
                            context.saveGState()
                            context.clip(to: cellRect.insetBy(dx: 2, dy: 0))
                            context.textMatrix = .identity
                            context.textPosition = CGPoint(x: x + 4 * scale, y: top - rowHeight + rowHeight * 0.32)
                            let flat = cell.replacingOccurrences(of: "\n", with: " ")
                            CTLineDraw(ConverterPDF.makeLine(flat, font: font, color: text), context)
                            context.restoreGState()
                        }
                        context.setStrokeColor(grid)
                        context.setLineWidth(0.5)
                        context.stroke(cellRect)
                        x += width
                    }
                }

                drawRow(header, top: y, font: bold, fill: headerFill)
                y -= rowHeight
                var stripe = false
                while cursor < body.count, y - rowHeight >= margin {
                    drawRow(body[cursor], top: y, font: font, fill: stripe ? zebra : nil)
                    stripe.toggle()
                    y -= rowHeight
                    cursor += 1
                    drawnRows += 1
                }
                context.endPage()
                progress(Double(drawnRows) / Double(totalRows))
            } while cursor < body.count
        }
        context.closePDF()
        guard pages > 0 else { throw ConverterError.unreadable("the sheet (empty)") }
        return pages
    }
}
