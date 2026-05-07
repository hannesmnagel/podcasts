import Foundation

struct ChapterSkipRule: Codable, Identifiable, Hashable, Sendable {
    enum MatchKind: String, Codable, Sendable {
        case exactTitle
        case regex
    }

    let id: UUID
    var kind: MatchKind
    var pattern: String
    var createdAt: Date

    init(id: UUID = UUID(), kind: MatchKind, pattern: String, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }

    var displayTitle: String {
        switch kind {
        case .exactTitle: pattern
        case .regex: "/\(pattern)/"
        }
    }

    func matches(chapterTitle: String) -> Bool {
        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .exactTitle:
            return title.compare(pattern.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .regex:
            return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

enum ChapterSkipRuleStore {
    private static let key = "chapterSkipRules.v1"

    static var rules: [ChapterSkipRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let rules = try? JSONDecoder().decode([ChapterSkipRule].self, from: data) else {
                return []
            }
            return rules
        }
        set {
            let cleaned = deduplicated(newValue.filter { !$0.pattern.isEmpty })
            if let data = try? JSONEncoder().encode(cleaned) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func addExactTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = rules
        current.append(ChapterSkipRule(kind: .exactTitle, pattern: trimmed))
        rules = current
    }

    static func addRegex(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) != nil else {
            return false
        }
        var current = rules
        current.append(ChapterSkipRule(kind: .regex, pattern: trimmed))
        rules = current
        return true
    }

    static func remove(_ rule: ChapterSkipRule) {
        rules = rules.filter { $0.id != rule.id }
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func shouldSkip(chapterTitle: String) -> Bool {
        rules.contains { $0.matches(chapterTitle: chapterTitle) }
    }

    private static func deduplicated(_ rules: [ChapterSkipRule]) -> [ChapterSkipRule] {
        var seen = Set<String>()
        var result: [ChapterSkipRule] = []
        for rule in rules {
            let key = "\(rule.kind.rawValue):\(rule.pattern.lowercased())"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(rule)
        }
        return result
    }
}
