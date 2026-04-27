import SwiftUI

struct EpisodeDetailView: View {
    let episode: EpisodeDTO

    @EnvironmentObject private var player: PlayerController
    @State private var transcriptText: String?
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
        }
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
        } catch {
            errorMessage = error.localizedDescription
        }
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
