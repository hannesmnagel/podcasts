import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    static func subscribe(to podcast: PodcastDTO, in context: ModelContext) {
        let stableID = podcast.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = podcast.title.isEmpty ? existing.title : podcast.title
            existing.artworkURL = podcast.imageURL.flatMap(URL.init(string:)) ?? existing.artworkURL
            existing.feedURL = URL(string: podcast.feedURL) ?? existing.feedURL
            return
        }
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let subscription = PodcastSubscription(
            stableID: stableID,
            feedURL: feedURL,
            title: podcast.title.isEmpty ? podcast.feedURL : podcast.title,
            artworkURL: podcast.imageURL.flatMap(URL.init(string:))
        )
        context.insert(subscription)
    }

    static func episodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    static func markPlayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = episode.duration ?? state.duration ?? 0
        state.duration = episode.duration ?? state.duration
        state.lastListenedAt = .now
    }

    static func markUnplayed(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = 0
        state.duration = episode.duration ?? state.duration
        state.lastListenedAt = nil
    }

    static func isPlayed(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        guard let state = episodeState(for: episode, in: context) else { return false }
        if let duration = state.duration, duration > 0 {
            return state.playbackPosition >= max(0, duration - 30)
        }
        return state.lastListenedAt != nil
    }

    static func markDeleted(_ episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.isDeleted = true
        state.deletedAt = .now
        state.isDownloaded = false
        state.downloadedFileURL = nil
    }

    static func restoreDeleted(_ episode: EpisodeDTO, in context: ModelContext) {
        guard let state = episodeState(for: episode, in: context) else { return }
        state.isDeleted = false
        state.deletedAt = nil
    }

    static func isDeleted(_ episode: EpisodeDTO, in context: ModelContext) -> Bool {
        episodeState(for: episode, in: context)?.isDeleted ?? false
    }

    static func visibleEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        episodes.filter { !isDeleted($0, in: context) }
    }

    static func unplayedEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        let playedIDs = playedEpisodeIDs(for: episodes, in: context)
        return visibleEpisodes(episodes, in: context).filter { !playedIDs.contains($0.stableID) }
    }

    static func playedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Set(states.compactMap { state in
            guard episodeIDs.contains(state.episodeStableID) else { return nil }
            if let duration = state.duration, duration > 0 {
                return state.playbackPosition >= max(0, duration - 30) ? state.episodeStableID : nil
            }
            return state.lastListenedAt != nil ? state.episodeStableID : nil
        })
    }

    static func deletedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Set(states.compactMap { state in
            episodeIDs.contains(state.episodeStableID) && state.isDeleted ? state.episodeStableID : nil
        })
    }

    static func localEpisode(for episode: EpisodeDTO, in context: ModelContext) -> EpisodeDTO {
        episodeState(for: episode, in: context)?.episodeDTO ?? episode
    }

    static func localEpisodes(forPodcastIDs podcastIDs: [String], in context: ModelContext) -> [EpisodeDTO] {
        guard !podcastIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return states
            .filter { !$0.isDeleted && podcastIDs.contains($0.podcastStableID) && $0.cachedAt != nil }
            .map(\.episodeDTO)
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func localEpisodes(matching query: String, in context: ModelContext) -> [EpisodeDTO] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return states
            .filter {
                !$0.isDeleted
                    && $0.cachedAt != nil
                    && ($0.title.lowercased().contains(trimmed) || ($0.summary?.lowercased().contains(trimmed) ?? false))
            }
            .map(\.episodeDTO)
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func cacheEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) async {
        let preparedEpisodes = await EpisodeDataProcessor.prepare(episodes)
        for preparedEpisode in preparedEpisodes {
            applyPreparedEpisode(preparedEpisode, in: context)
        }
    }

    static func cacheEpisode(_ episode: EpisodeDTO, in context: ModelContext) async {
        guard let preparedEpisode = await EpisodeDataProcessor.prepare([episode]).first else { return }
        applyPreparedEpisode(preparedEpisode, in: context)
    }

    private static func applyPreparedEpisode(_ preparedEpisode: PreparedEpisode, in context: ModelContext) {
        let episode = preparedEpisode.episode
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.podcastStableID = episode.podcastStableID ?? state.podcastStableID
        state.title = episode.title
        state.summary = episode.summary
        state.strippedSummary = preparedEpisode.strippedSummary
        state.audioURL = preparedEpisode.audioURL ?? state.audioURL
        state.imageURL = preparedEpisode.imageURL
        state.publishedAt = episode.publishedAt
        state.duration = episode.duration ?? state.duration
        state.cachedAt = .now
    }

    static func prefetchDetails(for episodes: [EpisodeDTO], client: BackendClient, in context: ModelContext) async {
        for episode in episodes.prefix(30) {
            await cacheEpisode(episode, in: context)
            await prefetchImage(for: episode, in: context)
            await prefetchArtifacts(for: episode, client: client, in: context)
            await Task.yield()
        }
    }

    static func localArtworkURL(for episode: EpisodeDTO, in context: ModelContext) -> URL? {
        if let cached = episodeState(for: episode, in: context)?.cachedImageFileURL {
            return cached
        }
        return episode.imageURL.flatMap(URL.init) ?? showArtworkURL(for: episode, in: context)
    }

    static func cachedChapterImageURL(for chapter: EpisodeChapterDTO, episode: EpisodeDTO, in context: ModelContext) -> URL? {
        guard let data = artifact(for: episode, in: context)?.chapterImageFilesJSON,
              let mapping = try? JSONDecoder().decode([String: String].self, from: data),
              let remote = chapter.displayImageURL?.absoluteString,
              let local = mapping[remote] else {
            return nil
        }
        return URL(string: local)
    }

    static func showArtworkURL(for episode: EpisodeDTO, in context: ModelContext) -> URL? {
        guard let podcastStableID = episode.podcastStableID else { return nil }
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == podcastStableID })
        return try? context.fetch(descriptor).first?.artworkURL
    }

    static func artifact(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeArtifact? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeArtifact>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    static func cachedTranscriptText(for episode: EpisodeDTO, in context: ModelContext) -> String? {
        artifact(for: episode, in: context)?.transcriptText
    }

    static func cachedChapters(for episode: EpisodeDTO, in context: ModelContext) async -> [EpisodeChapterDTO] {
        guard let chaptersJSON = artifact(for: episode, in: context)?.chaptersJSON else { return [] }
        return await ArtifactDataProcessor.renderChapters(chaptersJSON: chaptersJSON)
    }

    static func cacheTranscript(_ transcript: TranscriptArtifactDTO, for episode: EpisodeDTO, in context: ModelContext) async {
        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        artifact.transcriptSegmentsJSON = transcript.segmentsJSON
        artifact.transcriptText = await ArtifactDataProcessor.renderTranscript(segmentsJSON: transcript.segmentsJSON)
        artifact.transcriptLocale = transcript.locale
        artifact.transcriptModel = transcript.model
        artifact.transcriptTextHash = transcript.textHash
        artifact.updatedAt = .now
    }

    static func cacheChapters(_ chapters: ChapterArtifactDTO, for episode: EpisodeDTO, in context: ModelContext) {
        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        artifact.chaptersJSON = chapters.chaptersJSON
        artifact.chaptersSource = chapters.source
        artifact.updatedAt = .now
    }

    private static func makeEpisodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState {
        let state = LocalEpisodeState(
            episodeStableID: episode.stableID,
            podcastStableID: episode.podcastStableID ?? "",
            title: episode.title,
            audioURL: URL(string: episode.audioURL) ?? URL(fileURLWithPath: "/")
        )
        state.duration = episode.duration
        state.summary = episode.summary
        state.strippedSummary = nil
        state.imageURL = episode.imageURL.flatMap(URL.init(string:))
        state.publishedAt = episode.publishedAt
        state.cachedAt = .now
        context.insert(state)
        return state
    }

    private static func makeArtifact(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeArtifact {
        let artifact = LocalEpisodeArtifact(episodeStableID: episode.stableID)
        context.insert(artifact)
        return artifact
    }

    private static func prefetchImage(for episode: EpisodeDTO, in context: ModelContext) async {
        guard let state = episodeState(for: episode, in: context),
              state.cachedImageFileURL == nil,
              let remoteURL = episode.imageURL.flatMap(URL.init(string:)) else {
            return
        }
        if let localURL = try? await LocalMediaCache.cachedOrDownload(remoteURL) {
            state.cachedImageFileURL = localURL
        }
    }

    private static func prefetchArtifacts(for episode: EpisodeDTO, client: BackendClient, in context: ModelContext) async {
        let existing = artifact(for: episode, in: context)
        if existing?.transcriptSegmentsJSON == nil,
           let transcript = try? await client.transcript(for: episode.stableID) {
            await cacheTranscript(transcript, for: episode, in: context)
        }

        let artifact = artifact(for: episode, in: context) ?? makeArtifact(for: episode, in: context)
        if artifact.chaptersJSON == nil,
           let chapters = try? await client.chapters(for: episode.stableID) {
            cacheChapters(chapters, for: episode, in: context)
        }

        let chapters = await cachedChapters(for: episode, in: context)
        guard !chapters.isEmpty else { return }
        var imageFiles = await EpisodeDataProcessor.decodeChapterImageFiles(artifact.chapterImageFilesJSON)
        for chapter in chapters {
            guard let remoteURL = chapter.displayImageURL, imageFiles[remoteURL.absoluteString] == nil else { continue }
            if let localURL = try? await LocalMediaCache.cachedOrDownload(remoteURL) {
                imageFiles[remoteURL.absoluteString] = localURL.absoluteString
                artifact.chapterImageFilesJSON = await EpisodeDataProcessor.encodeChapterImageFiles(imageFiles)
            }
            await Task.yield()
        }
    }
}

private extension LocalEpisodeState {
    var episodeDTO: EpisodeDTO {
        EpisodeDTO(
            id: nil,
            podcastStableID: podcastStableID.isEmpty ? nil : podcastStableID,
            stableID: episodeStableID,
            title: title,
            summary: strippedSummary ?? summary,
            audioURL: audioURL.absoluteString,
            imageURL: cachedImageFileURL?.absoluteString ?? imageURL?.absoluteString,
            publishedAt: publishedAt,
            duration: duration
        )
    }
}
