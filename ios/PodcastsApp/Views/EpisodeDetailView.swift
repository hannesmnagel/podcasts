import SwiftData
import UIKit

final class EpisodeDetailViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case actions
        case notes
        case transcript
        case chapters
    }

    private let episode: EpisodeDTO
    private let modelContext: ModelContext
    private let player: PlayerController
    private let client = BackendClient()
    private var transcriptText: String?
    private var chapters: [EpisodeChapterDTO] = []
    private var isLoadingTranscript = false

    init(episode: EpisodeDTO, modelContext: ModelContext, player: PlayerController) {
        self.episode = episode
        self.modelContext = modelContext
        self.player = player
        super.init(style: .insetGrouped)
        title = episode.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        loadCachedArtifacts()
        Task { await requestTranscript() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .notes: "Episode Notes"
        case .transcript: "Transcript"
        case .chapters where chapters.count > 1: "Chapters"
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .actions: 2
        case .notes: 1
        case .transcript: 1
        case .chapters: chapters.count > 1 ? chapters.count : 0
        default: 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.contentConfiguration = nil
        cell.accessoryType = .none
        cell.textLabel?.numberOfLines = 0
        cell.imageView?.tintColor = .systemOrange

        switch Section(rawValue: indexPath.section) {
        case .actions:
            cell.textLabel?.text = indexPath.row == 0 ? "Play" : "Request Transcript"
            cell.imageView?.image = UIImage(systemName: indexPath.row == 0 ? "play.fill" : "text.quote")
        case .notes:
            cell.textLabel?.text = episode.summary.map(ShowNotesProcessor.plainText) ?? "No Episode Notes"
            cell.selectionStyle = .none
        case .transcript:
            if isLoadingTranscript {
                var config = UIListContentConfiguration.cell()
                config.text = "Loading Transcript..."
                cell.contentConfiguration = config
            } else if transcriptText != nil {
                cell.textLabel?.text = "Show Transcript"
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.textLabel?.text = "No Transcript Yet"
                cell.selectionStyle = .none
            }
        case .chapters:
            let chapter = chapters[indexPath.row]
            cell.textLabel?.text = "\(format(chapter.start))  \(chapter.title)"
            cell.imageView?.image = UIImage(systemName: "play.circle.fill")
        default:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .actions where indexPath.row == 0:
            player.play(episode, artworkURL: artworkURL)
        case .actions:
            Task { await requestTranscript() }
        case .transcript:
            guard let transcriptText else { return }
            navigationController?.pushViewController(TranscriptTextViewController(text: transcriptText), animated: true)
        case .chapters:
            let chapter = chapters[indexPath.row]
            player.play(
                episode,
                at: chapter.start,
                artworkURL: LibraryStore.cachedChapterImageURL(for: chapter, episode: episode, in: modelContext) ?? chapter.displayImageURL ?? artworkURL
            )
        default:
            break
        }
    }

    private func loadCachedArtifacts() {
        transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
        Task {
            chapters = await LibraryStore.cachedChapters(for: episode, in: modelContext)
            tableView.reloadData()
        }
    }

    private func requestTranscript() async {
        isLoadingTranscript = true
        tableView.reloadData()
        defer {
            isLoadingTranscript = false
            tableView.reloadData()
        }
        do {
            _ = try await client.requestArtifacts(for: episode.stableID)
            do {
                let artifact = try await client.transcript(for: episode.stableID)
                await LibraryStore.cacheTranscript(artifact, for: episode, in: modelContext)
                transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            } catch BackendError.notFound {
                transcriptText = LibraryStore.cachedTranscriptText(for: episode, in: modelContext)
            }
            do {
                let artifact = try await client.chapters(for: episode.stableID)
                LibraryStore.cacheChapters(artifact, for: episode, in: modelContext)
                chapters = await ArtifactDataProcessor.renderChapters(chaptersJSON: artifact.chaptersJSON)
            } catch BackendError.notFound {
                chapters = await LibraryStore.cachedChapters(for: episode, in: modelContext)
            }
        } catch {
            showError(error)
        }
    }

    private var artworkURL: URL? {
        LibraryStore.localArtworkURL(for: episode, in: modelContext)
    }

    private func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

private final class TranscriptTextViewController: UIViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        title = "Transcript"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isEditable = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
