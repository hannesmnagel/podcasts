import SwiftData
import SwiftUI

struct AllPodcastsView: View {
    @Binding var selectedPodcastID: String?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PodcastSubscription.sortIndex) private var subscriptions: [PodcastSubscription]
    @State private var feedURL = ""
    @State private var path: [String] = []
    @State private var errorMessage: String?
    @State private var isAdding = false
    private let client = BackendClient()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Add Feed To Your Library") {
                    TextField("RSS feed URL", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button(isAdding ? "Adding…" : "Add Podcast", action: addPodcast)
                        .disabled(URL(string: feedURL) == nil || isAdding)
                }

                Section("Your Podcasts") {
                    ForEach(subscriptions) { subscription in
                        NavigationLink(value: subscription.stableID) {
                            Text(subscription.title.isEmpty ? subscription.feedURL.absoluteString : subscription.title)
                        }
                        .contextMenu {
                            ShareLink(item: subscription.feedURL) {
                                Label("Share Feed", systemImage: "square.and.arrow.up")
                            }
                            Button("Delete Podcast", systemImage: "trash", role: .destructive) {
                                modelContext.delete(subscription)
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                modelContext.delete(subscription)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { podcastID in
                let title = subscriptions.first { $0.stableID == podcastID }?.title ?? "Podcast"
                EpisodeListView(title: title, podcastID: podcastID)
            }
            .onChange(of: selectedPodcastID) { _, podcastID in
                guard let podcastID else { return }
                path = [podcastID]
                selectedPodcastID = nil
            }
            .overlay {
                if subscriptions.isEmpty {
                    ContentUnavailableView("No Podcasts", systemImage: "square.stack", description: Text("Add an RSS feed or search Apple Podcasts."))
                }
            }
            .alert("Backend error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private func addPodcast() {
        guard let url = URL(string: feedURL) else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let podcast = try await client.addPodcast(feedURL: url)
                LibraryStore.subscribe(to: podcast, in: modelContext)
                feedURL = ""
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
