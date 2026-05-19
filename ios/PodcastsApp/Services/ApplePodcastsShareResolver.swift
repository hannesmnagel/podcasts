import Foundation
import SwiftData
import UIKit

struct ApplePodcastsShareResolver: Sendable {
    static let shared = ApplePodcastsShareResolver()

    func podcastShareURL(title: String, feedURL: URL?) async -> URL {
        if let match = await lookupPodcast(title: title, feedURL: feedURL) {
            return match
        }
        return searchURL(term: title.isEmpty ? feedURL?.absoluteString ?? "podcast" : title)
    }

    func episodeShareURL(episodeTitle: String, podcastTitle: String?, feedURL: URL?) async -> URL {
        if let match = await lookupEpisode(episodeTitle: episodeTitle, podcastTitle: podcastTitle, feedURL: feedURL) {
            return match
        }
        return await podcastShareURL(title: podcastTitle ?? episodeTitle, feedURL: feedURL)
    }

    private func lookupPodcast(title: String, feedURL: URL?) async -> URL? {
        guard !NetworkMonitor.shared.isOffline else { return nil }
        let term = title.isEmpty ? feedURL?.absoluteString ?? "" : title
        guard !term.isEmpty,
              let url = iTunesSearchURL(term: term, entity: "podcast", limit: 10) else {
            return nil
        }

        guard let response: ITunesSearchResponse<ITunesPodcastResult> = try? await fetch(url) else { return nil }
        let normalizedFeed = feedURL.map(normalizedURLString)
        let result = response.results.first { result in
            guard let normalizedFeed, let resultFeed = result.feedUrl.flatMap(URL.init(string:)) else { return false }
            return normalizedURLString(resultFeed) == normalizedFeed
        } ?? response.results.first { normalized($0.collectionName ?? $0.trackName ?? "") == normalized(title) } ?? response.results.first

        return result.flatMap { appleURL($0.collectionViewUrl ?? $0.trackViewUrl) }
    }

    private func lookupEpisode(episodeTitle: String, podcastTitle: String?, feedURL: URL?) async -> URL? {
        guard !NetworkMonitor.shared.isOffline else { return nil }
        let term = [episodeTitle, podcastTitle].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.joined(separator: " ")
        guard !term.isEmpty,
              let url = iTunesSearchURL(term: term, entity: "podcastEpisode", limit: 25) else {
            return nil
        }

        guard let response: ITunesSearchResponse<ITunesEpisodeResult> = try? await fetch(url) else { return nil }
        let normalizedEpisode = normalized(episodeTitle)
        let normalizedPodcast = normalized(podcastTitle ?? "")
        let normalizedFeed = feedURL.map(normalizedURLString)

        let result = response.results.first { result in
            normalized(result.trackName ?? "") == normalizedEpisode
                && podcastMatches(result, podcastTitle: normalizedPodcast, feedURL: normalizedFeed)
        } ?? response.results.first { normalized($0.trackName ?? "") == normalizedEpisode } ?? response.results.first

        return result.flatMap { appleURL($0.trackViewUrl ?? $0.collectionViewUrl) }
    }

    private func podcastMatches(_ result: ITunesEpisodeResult, podcastTitle: String, feedURL: String?) -> Bool {
        if let feedURL, let resultFeed = result.feedUrl.flatMap(URL.init(string:)) {
            return normalizedURLString(resultFeed) == feedURL
        }
        guard !podcastTitle.isEmpty else { return true }
        return normalized(result.collectionName ?? "") == podcastTitle
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func iTunesSearchURL(term: String, entity: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "term", value: term)
        ]
        return components?.url
    }

    private func searchURL(term: String) -> URL {
        var components = URLComponents(string: "https://podcasts.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: term)]
        return components.url!
    }

    private func appleURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.host()?.contains("apple.com") == true else { return nil }
        return url
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func normalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString.lowercased()
    }
}

private struct ITunesSearchResponse<Result: Decodable>: Decodable {
    let results: [Result]
}

private struct ITunesPodcastResult: Decodable {
    let collectionName: String?
    let trackName: String?
    let feedUrl: String?
    let collectionViewUrl: String?
    let trackViewUrl: String?
}

private struct ITunesEpisodeResult: Decodable {
    let trackName: String?
    let collectionName: String?
    let feedUrl: String?
    let trackViewUrl: String?
    let collectionViewUrl: String?
}

@MainActor
extension UIViewController {
    func presentPodcastShareOptions(for episode: EpisodeDTO, in context: ModelContext, sourceView: UIView? = nil) {
        let audioFileURL = downloadedAudioFileURL(for: episode, in: context)
        guard audioFileURL != nil else {
            shareApplePodcastsLink(for: episode, in: context)
            return
        }

        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Share Apple Podcasts Link", style: .default) { [weak self] _ in
            self?.shareApplePodcastsLink(for: episode, in: context)
        })
        alert.addAction(UIAlertAction(title: "Share Audio File", style: .default) { [weak self] _ in
            guard let audioFileURL else { return }
            self?.shareItems([audioFileURL])
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? view
            popover.sourceRect = sourceView?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = sourceView == nil ? [] : .any
        }
        present(alert, animated: true)
    }

    func shareApplePodcastsLink(for episode: EpisodeDTO, in context: ModelContext) {
        let subscription = podcastSubscription(for: episode.podcastStableID, in: context)
        let feedURL = subscription?.feedURL
        let podcastTitle = subscription?.title
        Task { [weak self] in
            let url = await ApplePodcastsShareResolver.shared.episodeShareURL(
                episodeTitle: episode.title,
                podcastTitle: podcastTitle,
                feedURL: feedURL
            )
            await MainActor.run {
                self?.shareItems([url])
            }
        }
    }

    func shareApplePodcastsLink(for subscription: PodcastSubscription) {
        let title = subscription.title
        let feedURL = subscription.feedURL
        Task { [weak self] in
            let url = await ApplePodcastsShareResolver.shared.podcastShareURL(title: title, feedURL: feedURL)
            await MainActor.run {
                self?.shareItems([url])
            }
        }
    }

    func shareDownloadedAudioFile(for episode: EpisodeDTO, in context: ModelContext) {
        guard let url = downloadedAudioFileURL(for: episode, in: context) else {
            let alert = UIAlertController(
                title: "Audio File Not Downloaded",
                message: "Download the episode before sharing its audio file.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        shareItems([url])
    }

    func shareItems(_ items: [Any]) {
        present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
    }

    func downloadedAudioFileURL(for episode: EpisodeDTO, in context: ModelContext) -> URL? {
        if let downloaded = LibraryStore.episodeState(for: episode, in: context)?.downloadedFileURL,
           downloaded.isFileURL,
           FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        guard let url = URL(string: episode.audioURL),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func podcastSubscription(for stableID: String?, in context: ModelContext) -> PodcastSubscription? {
        guard let stableID else { return nil }
        var descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
