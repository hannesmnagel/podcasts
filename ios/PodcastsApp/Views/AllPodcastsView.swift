import SwiftData
import SwiftUI

struct AllPodcastsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PodcastSubscription.sortIndex) private var subscriptions: [PodcastSubscription]
    @State private var feedURL = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    private let client = BackendClient()

    var body: some View {
        NavigationStack {
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
                        NavigationLink(subscription.title.isEmpty ? subscription.feedURL.absoluteString : subscription.title) {
                            EpisodeListView(title: subscription.title, podcastID: subscription.stableID)
                        }
                    }
                }
            }
            .navigationTitle("Library")
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
