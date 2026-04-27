import SwiftUI

struct EpisodeDetailView: View {
    let episode: EpisodeDTO

    @EnvironmentObject private var player: PlayerController
    @State private var transcriptText: String?
    @State private var chapters: [EpisodeChapterDTO] = []
    @State private var demand: ArtifactRequestDTO?
    @State private var errorMessage: String?
    @State private var isLoadingTranscript = false
    private let client = BackendClient()

    var body: some View {
        List {
            Section {
                Button("Play", systemImage: "play.fill") {
                    player.play(episode)
                }
                Button("Request Transcript", systemImage: "text.quote") {
                    Task { await requestTranscript() }
                }
            }

            if let demand {
                Section("Anonymous demand signal") {
                    LabeledContent("Transcript requests", value: "\(demand.transcriptCount)")
                    LabeledContent("Chapter requests", value: "\(demand.chapterCount)")
                }
            }

            Section("Transcript") {
                if isLoadingTranscript {
                    ProgressView()
                } else if let transcriptText {
                    Text(transcriptText)
                        .textSelection(.enabled)
                } else {
                    ContentUnavailableView("No Transcript Yet", systemImage: "text.quote", description: Text("Opening this screen requests one anonymously and puts this podcast higher in the worker queue."))
                }
            }

            Section("Chapters") {
                if chapters.isEmpty {
                    ContentUnavailableView("No Chapters Yet", systemImage: "list.bullet.rectangle")
                } else {
                    ForEach(chapters) { chapter in
                        LabeledContent(chapter.title, value: format(chapter.start))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(episode.title)
        .task { await requestTranscript() }
        .alert("Transcript", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: { Text(errorMessage ?? "") })
    }

    private func requestTranscript() async {
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }
        do {
            demand = try await client.requestArtifacts(for: episode.stableID)
            do {
                let artifact = try await client.transcript(for: episode.stableID)
                transcriptText = TranscriptRenderer.render(segmentsJSON: artifact.segmentsJSON)
            } catch BackendError.notFound {
                transcriptText = nil
            }
            do {
                let artifact = try await client.chapters(for: episode.stableID)
                chapters = ChapterRenderer.render(chaptersJSON: artifact.chaptersJSON)
            } catch BackendError.notFound {
                chapters = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

enum TranscriptRenderer {
    static func render(segmentsJSON: String) -> String {
        if let data = segmentsJSON.data(using: .utf8),
           let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) {
            return segments.map(\.text).joined(separator: "\n")
        }
        return segmentsJSON
    }
}

struct TranscriptSegment: Decodable {
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

enum ChapterRenderer {
    static func render(chaptersJSON: String) -> [EpisodeChapterDTO] {
        guard let data = chaptersJSON.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([EpisodeChapterDTO].self, from: data) else {
            return []
        }
        return chapters
    }
}
