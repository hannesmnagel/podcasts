import Crypto
import Foundation

enum StableID {
    static func podcastID(feedURL: String) -> String {
        sha256(normalizeURL(feedURL))
    }

    static func episodeID(podcastID: String, guid: String?, audioURL: String?, title: String, publishedAt: Date?) -> String {
        let stablePart: String
        if let guid, !guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stablePart = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stablePart = [normalizeURL(audioURL ?? ""), title.trimmingCharacters(in: .whitespacesAndNewlines), publishedAt?.timeIntervalSince1970.description ?? ""].joined(separator: "|")
        }
        return sha256(podcastID + "|" + stablePart)
    }

    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? trimmed.lowercased()
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
