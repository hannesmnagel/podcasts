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
        _ = save(ChapterSkipRule(kind: .exactTitle, pattern: title))
    }

    static func addRegex(_ pattern: String) -> Bool {
        save(ChapterSkipRule(kind: .regex, pattern: pattern))
    }

    @discardableResult
    static func save(_ rule: ChapterSkipRule) -> Bool {
        guard isValid(rule) else { return false }
        var current = rules
        if let index = current.firstIndex(where: { $0.id == rule.id }) {
            current[index] = rule
        } else {
            current.append(rule)
        }
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

    static func isValid(_ rule: ChapterSkipRule) -> Bool {
        guard !rule.pattern.isEmpty else { return false }
        switch rule.kind {
        case .exactTitle:
            return true
        case .regex:
            return (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])) != nil
        }
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
