import Foundation

enum ShowNotesProcessor {
    static func plainText(_ html: String) -> String {
        let anchorExpanded = expandAnchors(in: html)
        return anchorExpanded.decodingHTMLEntities().strippingHTMLTags()
            .replacingOccurrences(of: #"\s+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func linkedText(_ html: String) -> AttributedString {
        var output = AttributedString()
        let source = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchorPattern = #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return linkedPlainText(stripTags(source))
        }

        var cursor = source.startIndex
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: fullRange) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            output += linkedPlainText(stripTags(String(source[cursor..<matchRange.lowerBound])))

            let href = matchRangeAt(1, in: match, source: source).map { String(source[$0]) }
            let label = matchRangeAt(2, in: match, source: source).map { stripTags(String(source[$0])) } ?? ""
            var linkText = linkedPlainText(label.isEmpty ? href ?? "" : label)
            if let href, let url = URL(string: decodeEntities(href)) {
                linkText.link = url
            }
            output += linkText
            cursor = matchRange.upperBound
        }

        output += linkedPlainText(stripTags(String(source[cursor..<source.endIndex])))
        return output
    }

    private static func linkedPlainText(_ text: String) -> AttributedString {
        var output = AttributedString()
        let plain = plainText(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var cursor = plain.startIndex
        let range = NSRange(plain.startIndex..<plain.endIndex, in: plain)

        for match in detector?.matches(in: plain, range: range) ?? [] {
            guard let matchRange = Range(match.range, in: plain) else { continue }
            output += AttributedString(String(plain[cursor..<matchRange.lowerBound]))

            var link = AttributedString(String(plain[matchRange]))
            if let url = match.url {
                link.link = url
            }
            output += link
            cursor = matchRange.upperBound
        }

        output += AttributedString(String(plain[cursor..<plain.endIndex]))
        return output
    }

    private static func stripTags(_ html: String) -> String {
        html.strippingHTMLTags()
    }

    private static func decodeEntities(_ value: String) -> String {
        value.decodingHTMLEntities()
    }

    private static func matchRangeAt(_ index: Int, in match: NSTextCheckingResult, source: String) -> Range<String.Index>? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return Range(range, in: source)
    }

    private static func expandAnchors(in html: String) -> String {
        let anchorPattern = #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }

        var output = ""
        var cursor = html.startIndex
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: fullRange) {
            guard let matchRange = Range(match.range, in: html) else { continue }
            output += String(html[cursor..<matchRange.lowerBound])

            let href = matchRangeAt(1, in: match, source: html).map { decodeEntities(String(html[$0])) } ?? ""
            let label = matchRangeAt(2, in: match, source: html).map { decodeEntities(stripTags(String(html[$0]))) } ?? href
            output += label.contains(href) || href.isEmpty ? label : "\(label) \(href)"
            cursor = matchRange.upperBound
        }
        output += String(html[cursor..<html.endIndex])
        return output
    }
}

struct ShowNotesBlock {
    enum Kind {
        case heading(String)
        case paragraph(String)
        case bulletList([String])
    }

    let kind: Kind
}

enum ShowNotesBlockParser {
    static func parse(_ raw: String) -> [ShowNotesBlock] {
        let normalized = expandAnchors(in: raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</li\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "\n- ", options: .regularExpression)
            .strippingHTMLTags()
            .decodingHTMLEntities()

        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var blocks: [ShowNotesBlock] = []
        var paragraphLines: [String] = []
        var bullets: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(ShowNotesBlock(kind: .paragraph(text)))
            }
            paragraphLines.removeAll()
        }

        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(ShowNotesBlock(kind: .bulletList(bullets)))
            }
            bullets.removeAll()
        }

        for line in lines {
            guard !line.isEmpty else {
                flushParagraph()
                flushBullets()
                continue
            }

            if isHeading(line) {
                flushParagraph()
                flushBullets()
                blocks.append(ShowNotesBlock(kind: .heading(line)))
            } else if let bullet = bulletText(from: line) {
                flushParagraph()
                bullets.append(bullet)
            } else {
                flushBullets()
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        flushBullets()
        return blocks
    }

    private static func isHeading(_ line: String) -> Bool {
        guard line.count <= 64 else { return false }
        if line.hasSuffix(":") { return true }
        if line == "Episode Notes" { return true }
        if line.range(of: #"^[A-Z][A-Za-z0-9 '&/+-]{2,}$"#, options: .regularExpression) != nil,
           !line.contains("."),
           !line.contains("http") {
            return true
        }
        return false
    }

    private static func bulletText(from line: String) -> String? {
        let prefixes = ["- ", "* ", "• ", "– ", "— "]
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func expandAnchors(in html: String) -> String {
        let anchorPattern = #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return html
        }

        var output = ""
        var cursor = html.startIndex
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: fullRange) {
            guard let matchRange = Range(match.range, in: html) else { continue }
            output += String(html[cursor..<matchRange.lowerBound])
            let href = Range(match.range(at: 1), in: html).map { String(html[$0]).decodingHTMLEntities() } ?? ""
            let label = Range(match.range(at: 2), in: html).map { String(html[$0]).strippingHTMLTags().decodingHTMLEntities() } ?? href
            output += label.contains(href) || href.isEmpty ? label : "\(label) \(href)"
            cursor = matchRange.upperBound
        }
        output += String(html[cursor..<html.endIndex])
        return output
    }
}

extension String {
    func decodingHTMLEntities() -> String {
        var output = self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#) else {
            return output
        }

        let matches = regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let valueRange = Range(match.range(at: 1), in: output) else { continue }
            let rawValue = String(output[valueRange])
            let scalarValue: UInt32?
            if rawValue.hasPrefix("x") {
                scalarValue = UInt32(rawValue.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(rawValue, radix: 10)
            }
            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            output.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return output
    }

    func strippingHTMLTags() -> String {
        replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</li\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
