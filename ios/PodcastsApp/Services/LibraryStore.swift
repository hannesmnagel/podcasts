import Foundation
import SwiftData

@MainActor
enum LibraryStore {
    private static let lastPlaybackEpisodeIDKey = "playbackState.lastEpisodeStableID"

    static func subscribe(to podcast: PodcastDTO, in context: ModelContext) {
        let stableID = podcast.stableID
        let descriptor = FetchDescriptor<PodcastSubscription>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = nonEmpty(podcast.title) ?? existing.title
            existing.podcastDescription = nonEmpty(podcast.description) ?? existing.podcastDescription
            existing.artworkURL = nonEmpty(podcast.imageURL).flatMap(URL.init(string:)) ?? existing.artworkURL
            existing.feedURL = URL(string: podcast.feedURL) ?? existing.feedURL
            return
        }
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let subscription = PodcastSubscription(
            stableID: stableID,
            feedURL: feedURL,
            title: nonEmpty(podcast.title) ?? podcast.feedURL,
            artworkURL: nonEmpty(podcast.imageURL).flatMap(URL.init(string:))
        )
        subscription.podcastDescription = nonEmpty(podcast.description)
        context.insert(subscription)
    }

    static func subscribe(to podcasts: [PodcastDTO], in context: ModelContext) {
        podcasts.forEach { subscribe(to: $0, in: context) }
    }

    static func updateExistingSubscriptions(with podcasts: [PodcastDTO], in context: ModelContext) {
        let descriptor = FetchDescriptor<PodcastSubscription>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingIDs = Set(existing.map(\.stableID))
        podcasts
            .filter { existingIDs.contains($0.stableID) }
            .forEach { subscribe(to: $0, in: context) }
    }

    static func unsubscribe(_ subscription: PodcastSubscription, in context: ModelContext) {
        let podcastID = subscription.stableID
        let stateDescriptor = FetchDescriptor<LocalEpisodeState>()
        let states = ((try? context.fetch(stateDescriptor)) ?? []).filter { $0.podcastStableID == podcastID }
        let episodeIDs = Set(states.map(\.episodeStableID))
        states.forEach { state in
            if let downloadedFileURL = state.downloadedFileURL {
                Task { await LocalMediaCache.removeFileIfPresent(at: downloadedFileURL) }
            }
            context.delete(state)
        }

        let artifactDescriptor = FetchDescriptor<LocalEpisodeArtifact>()
        let artifacts = (try? context.fetch(artifactDescriptor)) ?? []
        artifacts.filter { episodeIDs.contains($0.episodeStableID) }.forEach {
            context.delete($0)
        }
        context.delete(subscription)
    }

    static func episodeState(for episode: EpisodeDTO, in context: ModelContext) -> LocalEpisodeState? {
        let stableID = episode.stableID
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first
    }

    static func playbackPosition(for episode: EpisodeDTO, in context: ModelContext) -> TimeInterval {
        let state = episodeState(for: episode, in: context)
        guard let position = state?.playbackPosition, position.isFinite, position > 0 else { return 0 }
        if let duration = state?.duration ?? episode.duration, duration > 0, position >= max(0, duration - 30) {
            return 0
        }
        return position
    }

    static func updatePlaybackState(episode: EpisodeDTO, elapsed: TimeInterval, duration: TimeInterval?, in context: ModelContext) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        state.playbackPosition = elapsed
        state.duration = duration ?? episode.duration ?? state.duration
        state.lastListenedAt = .now
        UserDefaults.standard.set(episode.stableID, forKey: lastPlaybackEpisodeIDKey)
    }

    static func lastPlaybackEpisode(in context: ModelContext) -> EpisodeDTO? {
        guard let stableID = UserDefaults.standard.string(forKey: lastPlaybackEpisodeIDKey) else { return nil }
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeStableID == stableID })
        return try? context.fetch(descriptor).first?.episodeDTO(preferDownloadedFile: true)
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

    static func downloadAudio(for episode: EpisodeDTO, in context: ModelContext, progressID: String? = nil) async {
        guard let remoteURL = URL(string: episode.audioURL) else { return }
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        let progressID = progressID ?? episode.stableID
        if let localURL = try? await LocalMediaCache.cachedOrDownload(remoteURL, progressID: progressID) {
            state.downloadedFileURL = localURL
            state.isDownloaded = true
        }
    }

    static func removeDownload(for episode: EpisodeDTO, in context: ModelContext) {
        let state = episodeState(for: episode, in: context) ?? makeEpisodeState(for: episode, in: context)
        let localURL = state.downloadedFileURL
        state.downloadedFileURL = nil
        state.isDownloaded = false
        if let localURL {
            Task { await LocalMediaCache.removeFileIfPresent(at: localURL) }
        }
    }

    static func removeDownloads(for episodes: [EpisodeDTO], in context: ModelContext) {
        episodes.forEach { removeDownload(for: $0, in: context) }
    }

    static func downloadedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Set(states.compactMap { state in
            episodeIDs.contains(state.episodeStableID) && state.isDownloaded ? state.episodeStableID : nil
        })
    }

    static func markAllPlayed(_ episodes: [EpisodeDTO], in context: ModelContext) {
        visibleEpisodes(episodes, in: context).forEach { markPlayed($0, in: context) }
    }

    static func markAllUnplayed(_ episodes: [EpisodeDTO], in context: ModelContext) {
        visibleEpisodes(episodes, in: context).forEach { markUnplayed($0, in: context) }
    }

    static func restoreDeletedEpisodes(forPodcastID podcastID: String, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        let matching = states.filter { $0.podcastStableID == podcastID && $0.isDeleted }
        matching.forEach {
            $0.isDeleted = false
            $0.deletedAt = nil
        }
        return matching.count
    }

    static func visibleEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        episodes.filter { !isDeleted($0, in: context) }
    }

    static func unplayedEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) -> [EpisodeDTO] {
        let playedIDs = playedEpisodeIDs(for: episodes, in: context)
        return visibleEpisodes(episodes, in: context).filter { !playedIDs.contains($0.stableID) }
    }

    static func playedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        episodeIDSets(for: episodes, in: context).played
    }

    static func deletedEpisodeIDs(for episodes: [EpisodeDTO], in context: ModelContext) -> Set<String> {
        episodeIDSets(for: episodes, in: context).deleted
    }

    static func episodeIDSets(for episodes: [EpisodeDTO], in context: ModelContext) -> (played: Set<String>, deleted: Set<String>, downloaded: Set<String>) {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return ([], [], []) }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        var played: Set<String> = []
        var deleted: Set<String> = []
        var downloaded: Set<String> = []

        for state in states where episodeIDs.contains(state.episodeStableID) {
            if state.isDeleted {
                deleted.insert(state.episodeStableID)
            }
            if state.isDownloaded {
                downloaded.insert(state.episodeStableID)
            }
            if let duration = state.duration, duration > 0 {
                if state.playbackPosition >= max(0, duration - 30) {
                    played.insert(state.episodeStableID)
                }
            } else if state.lastListenedAt != nil {
                played.insert(state.episodeStableID)
            }
        }

        return (played, deleted, downloaded)
    }

    static func summarySnippets(for episodes: [EpisodeDTO], in context: ModelContext) -> [String: String] {
        let episodeIDs = Set(episodes.map(\.stableID))
        guard !episodeIDs.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: states.compactMap { state in
            guard episodeIDs.contains(state.episodeStableID),
                  let snippet = state.strippedSummary,
                  !snippet.isEmpty else {
                return nil
            }
            return (state.episodeStableID, snippet)
        })
    }

    static func localEpisode(for episode: EpisodeDTO, in context: ModelContext) -> EpisodeDTO {
        episodeState(for: episode, in: context)?.episodeDTO(preferDownloadedFile: true) ?? episode
    }

    static func localEpisodes(forPodcastIDs podcastIDs: [String], in context: ModelContext) -> [EpisodeDTO] {
        guard !podcastIDs.isEmpty else { return [] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return states
            .filter { !$0.isDeleted && podcastIDs.contains($0.podcastStableID) && $0.cachedAt != nil }
            .map { $0.episodeDTO(preferDownloadedFile: true) }
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
            .map { $0.episodeDTO(preferDownloadedFile: true) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    static func cacheEpisodes(_ episodes: [EpisodeDTO], in context: ModelContext) async {
        let preparedEpisodes = await EpisodeDataProcessor.prepare(episodes)
        let statesByID = existingEpisodeStates(for: preparedEpisodes.map(\.episode.stableID), in: context)
        for preparedEpisode in preparedEpisodes {
            applyPreparedEpisode(preparedEpisode, existingState: statesByID[preparedEpisode.episode.stableID], in: context)
        }
    }

    static func cacheEpisode(_ episode: EpisodeDTO, in context: ModelContext) async {
        guard let preparedEpisode = await EpisodeDataProcessor.prepare([episode]).first else { return }
        applyPreparedEpisode(preparedEpisode, existingState: episodeState(for: episode, in: context), in: context)
    }

    private static func applyPreparedEpisode(_ preparedEpisode: PreparedEpisode, existingState: LocalEpisodeState?, in context: ModelContext) {
        let episode = preparedEpisode.episode
        let state = existingState ?? makeEpisodeState(for: episode, in: context)
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

    private static func existingEpisodeStates(for episodeIDs: [String], in context: ModelContext) -> [String: LocalEpisodeState] {
        let wantedIDs = Set(episodeIDs)
        guard !wantedIDs.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalEpisodeState>()
        let states = (try? context.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: states.compactMap { state in
            wantedIDs.contains(state.episodeStableID) ? (state.episodeStableID, state) : nil
        })
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

    static func cachedTranscriptSegments(for episode: EpisodeDTO, in context: ModelContext) -> [TranscriptSegment] {
        guard let segmentsJSON = artifact(for: episode, in: context)?.transcriptSegmentsJSON else { return [] }
        return TranscriptRenderer.segments(from: segmentsJSON)
    }

    static func cachedChapters(for episode: EpisodeDTO, in context: ModelContext) async -> [EpisodeChapterDTO] {
        guard let chaptersJSON = artifact(for: episode, in: context)?.chaptersJSON else { return [] }
        return await ArtifactDataProcessor.renderChapters(chaptersJSON: chaptersJSON)
    }

    static func embeddedChapters(for episode: EpisodeDTO, in context: ModelContext) async -> [EpisodeChapterDTO] {
        if let artifact = artifact(for: episode, in: context),
           let source = artifact.chaptersSource?.lowercased(),
           source.contains("id3") || source.contains("chap"),
           let chaptersJSON = artifact.chaptersJSON {
            let cached = await ArtifactDataProcessor.renderChapters(chaptersJSON: chaptersJSON)
            if cached.count > 1 { return cached }
        }

        let episode = localEpisode(for: episode, in: context)
        guard let audioURL = URL(string: episode.audioURL) else { return [] }
        let chapters = await EmbeddedChapterLoader.chapters(from: audioURL)
        if chapters.count > 1,
           let data = try? JSONEncoder().encode(chapters),
           let chaptersJSON = String(data: data, encoding: .utf8) {
            cacheChapters(ChapterArtifactDTO(id: nil, source: "id3 embedded", chaptersJSON: chaptersJSON), for: episode, in: context)
        }
        return chapters
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
        if prefersExistingChapters(existingSource: artifact.chaptersSource, incomingSource: chapters.source) {
            return
        }
        artifact.chaptersJSON = chapters.chaptersJSON
        artifact.chaptersSource = chapters.source
        artifact.updatedAt = .now
    }

    private static func prefersExistingChapters(existingSource: String?, incomingSource: String) -> Bool {
        guard let existingSource else { return false }
        let existing = existingSource.lowercased()
        let incoming = incomingSource.lowercased()
        let existingIsGenerated = existing.contains("generated") || existing.contains("model") || existing.contains("llm")
        let incomingIsEmbedded = incoming.contains("feed") || incoming.contains("embedded") || incoming.contains("podcast") || incoming.contains("psc") || incoming.contains("id3") || incoming.contains("chap")
        if existingIsGenerated && incomingIsEmbedded { return false }
        let existingIsEmbedded = existing.contains("feed") || existing.contains("embedded") || existing.contains("podcast") || existing.contains("psc") || existing.contains("id3") || existing.contains("chap")
        let incomingIsGenerated = incoming.contains("generated") || incoming.contains("model") || incoming.contains("llm")
        return existingIsEmbedded && incomingIsGenerated
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
    func episodeDTO(preferDownloadedFile: Bool) -> EpisodeDTO {
        let localAudioURL: URL?
        if preferDownloadedFile,
           isDownloaded,
           let downloadedFileURL,
           FileManager.default.fileExists(atPath: downloadedFileURL.path) {
            localAudioURL = downloadedFileURL
        } else {
            localAudioURL = nil
        }

        return EpisodeDTO(
            id: nil,
            podcastStableID: podcastStableID.isEmpty ? nil : podcastStableID,
            stableID: episodeStableID,
            title: title,
            summary: summary,
            audioURL: localAudioURL?.absoluteString ?? audioURL.absoluteString,
            imageURL: cachedImageFileURL?.absoluteString ?? imageURL?.absoluteString,
            publishedAt: publishedAt,
            duration: duration
        )
    }
}
