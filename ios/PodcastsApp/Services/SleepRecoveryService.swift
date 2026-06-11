#if canImport(HealthKit)
import Foundation
import HealthKit
import SwiftData

struct SleepRecoveryResult {
    let episodeStableID: String
    let episodeTitle: String
    let seekPosition: Double
    let sleepOnset: Date
    /// IDs of episodes whose playback started entirely after sleep onset — should be marked unplayed.
    let episodesStartedDuringSleep: [String]
}

@MainActor
final class SleepRecoveryService {
    static let bufferSeconds: Double = 90  // seek this far back from sleep onset point

    private static let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func requestAuthorization() async {
        guard isAvailable else { return }
        let sleepType = HKCategoryType(.sleepAnalysis)
        try? await store.requestAuthorization(toShare: [], read: [sleepType])
    }

    /// Returns the most recent detected sleep onset from HealthKit (Watch-sourced only).
    static func lastSleepOnset() async -> Date? {
        guard isAvailable else { return nil }
        let sleepType = HKCategoryType(.sleepAnalysis)
        // Only asleep phases — not inBed
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-36 * 3600),
            end: Date(),
            options: .strictStartDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 200, sortDescriptors: [sort]) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil)
                    return
                }
                // Filter to Watch-sourced samples (most reliable) or any source if none
                let watchSamples = samples.filter { $0.sourceRevision.source.bundleIdentifier.contains("com.apple.health") == false }
                let candidates = watchSamples.isEmpty ? samples : watchSamples
                let asleep = candidates.filter { asleepValues.contains($0.value) }
                // Find the earliest start of the most recent contiguous sleep block
                guard !asleep.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // Sort ascending to find contiguous block
                let sorted = asleep.sorted { $0.startDate < $1.startDate }
                // Walk backward from the latest sample to find the start of the last sleep block
                // (gap > 30 min means a new block)
                var blockStart = sorted.last!.startDate
                for i in stride(from: sorted.count - 2, through: 0, by: -1) {
                    let gap = sorted[i + 1].startDate.timeIntervalSince(sorted[i].endDate)
                    if gap > 30 * 60 { break }
                    blockStart = sorted[i].startDate
                }
                continuation.resume(returning: blockStart)
            }
            store.execute(query)
        }
    }

    /// Correlates sleep onset with AppEvent playback records to compute a recovery result.
    static func findRecovery(sleepOnset: Date, context: ModelContext) -> SleepRecoveryResult? {
        let descriptor = FetchDescriptor<AppEvent>(
            predicate: #Predicate { $0.kind == "playback" },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
        guard let events = try? context.fetch(descriptor) else { return nil }

        // occurredAt = session start (wall clock)
        // wall-clock end = occurredAt + (endPosition - startPosition) / playbackSpeed
        var sessionAtSleep: AppEvent?
        for event in events {
            guard let startPos = event.startPosition,
                  let endPos = event.endPosition,
                  let speed = event.playbackSpeed,
                  speed > 0 else { continue }
            let wallStart = event.occurredAt
            let audioSeconds = endPos - startPos
            let wallEnd = wallStart.addingTimeInterval(audioSeconds / speed)
            if wallStart <= sleepOnset && wallEnd >= sleepOnset {
                sessionAtSleep = event
                break
            }
        }

        guard let session = sessionAtSleep,
              let startPos = session.startPosition,
              let speed = session.playbackSpeed,
              let episodeID = session.episodeStableID,
              let episodeTitle = session.episodeTitle else { return nil }

        // Audio position at sleep onset
        let secondsIntoSession = sleepOnset.timeIntervalSince(session.occurredAt) * speed
        let rawPosition = startPos + secondsIntoSession
        let seekPosition = max(0, rawPosition - bufferSeconds)

        // Episodes whose sessions started entirely after sleep onset
        let episodesStartedDuringSleep = events
            .filter { $0.episodeStableID != episodeID && $0.occurredAt > sleepOnset }
            .compactMap { $0.episodeStableID }

        return SleepRecoveryResult(
            episodeStableID: episodeID,
            episodeTitle: episodeTitle,
            seekPosition: seekPosition,
            sleepOnset: sleepOnset,
            episodesStartedDuringSleep: Array(Set(episodesStartedDuringSleep))
        )
    }
}

#else  // Mac Catalyst and other non-HealthKit platforms

import Foundation
import SwiftData

struct SleepRecoveryResult {
    let episodeStableID: String
    let episodeTitle: String
    let seekPosition: Double
    let sleepOnset: Date
    let episodesStartedDuringSleep: [String]
}

@MainActor
final class SleepRecoveryService {
    static var isAvailable: Bool { false }
    static func requestAuthorization() async {}
    static func lastSleepOnset() async -> Date? { nil }
    static func findRecovery(sleepOnset: Date, context: ModelContext) -> SleepRecoveryResult? { nil }
}

#endif
