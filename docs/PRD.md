# Privacy-First Speed Podcast App

A high-speed podcast app for people who listen faster than normal podcast apps support. The app prioritizes reliable playback above 3x, searchable time-aligned transcripts, automatic chapters, and privacy: subscriptions, queues, playback history, and playlists live in SwiftData and the user's private CloudKit database. The backend stores only public podcast/episode metadata plus shared transcript/chapter/fingerprint artifacts, and infers processing priority from anonymous transcript/artifact requests rather than storing user subscriptions.
