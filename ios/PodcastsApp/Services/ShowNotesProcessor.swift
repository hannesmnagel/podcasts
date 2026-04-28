import Foundation

enum ShowNotesProcessor {
    static func plainText(_ html: String) -> String {
        let anchorExpanded = expandAnchors(in: html)
        return decodeEntities(stripTags(anchorExpanded))
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
        html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</li\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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
