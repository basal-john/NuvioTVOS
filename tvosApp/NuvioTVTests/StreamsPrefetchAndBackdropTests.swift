//
//  StreamsPrefetchAndBackdropTests.swift
//  NuvioTVTests
//
//  Coverage for multi-entry LRU stream prefetching, TV episode/movie target prediction,
//  monochrome Details Play progress evaluation, and high-res backdrop resolution.
//

import XCTest
@testable import NuvioTV

@MainActor
final class StreamsPrefetchRepositoryTests: XCTestCase {

    func testCacheHitReusesCompletedDiscoveryWithoutReinvokingHandler() async {
        var now = Date(timeIntervalSince1970: 1_000)
        var handlerCalls = 0
        let addonURL = URL(string: "https://addon.example/manifest.json")!

        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [addonURL] },
            discoveryHandler: { _, _, videoId, _, publish in
                handlerCalls += 1
                let stream = NuvioStream(
                    url: "https://cdn.example/\(videoId).mkv",
                    name: "1080p",
                    description: "Movie",
                    addonName: "Addon"
                )
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [stream], isLoading: false)], false, nil, true)
            }
        )

        repo.load(type: "movie", videoId: "tt1111111")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(handlerCalls, 1)
        XCTAssertEqual(repo.state.allStreams.count, 1)

        // Advance within TTL and switch to another title, then back.
        now = now.addingTimeInterval(60)
        repo.load(type: "movie", videoId: "tt2222222")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(handlerCalls, 2)

        now = now.addingTimeInterval(30)
        repo.load(type: "movie", videoId: "tt1111111")
        XCTAssertEqual(handlerCalls, 2, "Cached entry within TTL must be served without invoking discovery handler again")
        XCTAssertEqual(repo.state.requestKey, StreamsRepository.requestKey(type: "movie", videoId: "tt1111111"))
        XCTAssertEqual(repo.state.allStreams.first?.url, "https://cdn.example/tt1111111.mkv")
        XCTAssertFalse(repo.state.isAnyLoading)
    }

    func testLRUCacheEvictsLeastRecentlyUsedEntryBeyondCapacity() async {
        var clock = Date(timeIntervalSince1970: 2_000)
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 3,
            cacheTTL: 300,
            nowProvider: { clock },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { _, _, videoId, _, publish in
                let stream = NuvioStream(url: "https://cdn.example/\(videoId).mkv", name: "1080p", description: "Test", addonName: "Addon")
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [stream], isLoading: false)], false, nil, true)
            }
        )

        for idx in 1...3 {
            clock = clock.addingTimeInterval(1)
            repo.prefetch(type: "movie", videoId: "tt000000\(idx)")
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // Touch tt0000001 via foreground load so tt0000002 becomes LRU.
        clock = clock.addingTimeInterval(1)
        repo.load(type: "movie", videoId: "tt0000001")

        // Insert a 4th item -> must evict tt0000002, keeping tt0000001, tt0000003, tt0000004.
        clock = clock.addingTimeInterval(1)
        repo.prefetch(type: "movie", videoId: "tt0000004")
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(repo.cachedKeysInOrderForTesting.count, 3)
        XCTAssertNil(repo.cachedState(forType: "movie", videoId: "tt0000002"))
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt0000001"))
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt0000003"))
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt0000004"))
    }

    func testTTLExpirationAndAddonConfigChangeInvalidateCache() async {
        var now = Date(timeIntervalSince1970: 5_000)
        var addons = [URL(string: "https://addon-a.example/manifest.json")!]
        var handlerCalls = 0

        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { addons },
            discoveryHandler: { _, _, videoId, _, publish in
                handlerCalls += 1
                let stream = NuvioStream(url: "https://cdn.example/\(videoId)-\(handlerCalls).mkv", name: "1080p", description: "Test", addonName: "Addon")
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [stream], isLoading: false)], false, nil, true)
            }
        )

        repo.prefetch(type: "movie", videoId: "tt7777777")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(handlerCalls, 1)
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt7777777"))

        // Config change invalidates cache immediately even before TTL.
        addons = [URL(string: "https://addon-b.example/manifest.json")!]
        XCTAssertNil(repo.cachedState(forType: "movie", videoId: "tt7777777"))

        repo.load(type: "movie", videoId: "tt7777777")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(handlerCalls, 2)

        // Advance past 300s TTL -> expires.
        now = now.addingTimeInterval(301)
        XCTAssertNil(repo.cachedState(forType: "movie", videoId: "tt7777777"))

        repo.load(type: "movie", videoId: "tt7777777")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(handlerCalls, 3)

        // forceRefresh bypasses valid cache even within TTL.
        now = now.addingTimeInterval(5)
        repo.load(type: "movie", videoId: "tt7777777", forceRefresh: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(handlerCalls, 4)
    }

    func testBackgroundPrefetchIsIsolatedAndPromotesInFlightWhenLoadMatches() async {
        var handlerCalls = 0
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { _, _, videoId, _, publish in
                handlerCalls += 1
                let partial = AddonStreamGroup(
                    addonId: "a1",
                    displayName: "Addon",
                    streams: [NuvioStream(url: "https://cdn.example/\(videoId)-1.mkv", name: "720p", description: "720p", addonName: "Addon")],
                    isLoading: false
                )
                let pending = AddonStreamGroup(addonId: "a2", displayName: "Addon 2", streams: [], isLoading: true)
                publish([partial, pending], true, nil, true)
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                let done = AddonStreamGroup(
                    addonId: "a2",
                    displayName: "Addon 2",
                    streams: [NuvioStream(url: "https://cdn.example/\(videoId)-2.mkv", name: "1080p", description: "1080p", addonName: "Addon 2")],
                    isLoading: false
                )
                publish([partial, done], false, nil, true)
            }
        )

        // Foreground has active movie, background prefetches next episode.
        repo.load(type: "movie", videoId: "tt1010101")
        try? await Task.sleep(nanoseconds: 120_000_000)
        let foregroundMovieKey = StreamsRepository.requestKey(type: "movie", videoId: "tt1010101")
        XCTAssertEqual(repo.state.requestKey, foregroundMovieKey)

        repo.prefetch(type: "series", videoId: "tt2020202:1:2", season: 1, episode: 2)
        try? await Task.sleep(nanoseconds: 25_000_000)

        // Foreground state must NOT be polluted by background prefetch.
        XCTAssertEqual(repo.state.requestKey, foregroundMovieKey)

        // Promoting in-flight episode prefetch via load(...) must reuse the in-flight job without restarting!
        repo.load(type: "series", videoId: "tt2020202:1:2", season: 1, episode: 2)
        XCTAssertEqual(handlerCalls, 2, "Load matching in-flight prefetch must promote job without starting a duplicate fetch")
        XCTAssertEqual(repo.state.requestKey, StreamsRepository.requestKey(type: "series", videoId: "tt2020202:1:2", season: 1, episode: 2))
        XCTAssertEqual(repo.state.allStreams.count, 1)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(repo.state.isAnyLoading)
        XCTAssertEqual(repo.state.allStreams.count, 2)
    }

    private func streams(for videoId: String, count: Int) -> [NuvioStream] {
        guard count > 0 else { return [] }
        return (1...count).map {
            NuvioStream(url: "https://cdn.example/\(videoId)-\($0).mkv", name: "1080p", description: "v\($0)", addonName: "Addon")
        }
    }

    func testEmptyZeroStreamResultsAreNotReusedFromCachePrefetchOrCachedState() async {
        var now = Date(timeIntervalSince1970: 10_000)
        var calls: [String] = []
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { _, _, videoId, _, publish in
                calls.append(videoId)
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [], isLoading: false)], false, .noStreamsFound, true)
            }
        )
        let emptyKey = StreamsRepository.requestKey(type: "movie", videoId: "tt0000010")

        repo.load(type: "movie", videoId: "tt0000010")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt0000010"])
        XCTAssertEqual(repo.state.requestKey, emptyKey)
        XCTAssertEqual(repo.state.emptyStateReason, .noStreamsFound)

        now = now.addingTimeInterval(5)
        repo.load(type: "movie", videoId: "tt0000010")
        XCTAssertEqual(calls, ["tt0000010"])
        XCTAssertEqual(repo.state.emptyStateReason, .noStreamsFound)
        XCTAssertFalse(repo.state.isAnyLoading)

        XCTAssertNil(repo.cachedState(forType: "movie", videoId: "tt0000010"))

        repo.load(type: "movie", videoId: "tt0000020")
        try? await Task.sleep(nanoseconds: 30_000_000)
        repo.load(type: "movie", videoId: "tt0000010")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt0000010", "tt0000020", "tt0000010"])

        repo.load(type: "movie", videoId: "tt0000030")
        try? await Task.sleep(nanoseconds: 30_000_000)
        repo.prefetch(type: "movie", videoId: "tt0000010")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt0000010", "tt0000020", "tt0000010", "tt0000030"])

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 1)
        repo.prefetch(type: "movie", videoId: "tt0000010")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt0000010", "tt0000020", "tt0000010", "tt0000030", "tt0000010"])

        XCTAssertEqual(
            repo.cachedState(forType: "movie", videoId: "tt0000010", includeCompletedEmpty: true)?.emptyStateReason,
            .noStreamsFound
        )
    }

    func testEmptyEntriesAreEvictedBeforePopulatedTitles() async {
        var clock = Date(timeIntervalSince1970: 11_000)
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 2,
            cacheTTL: 300,
            nowProvider: { clock },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                let found = videoId == "tt0000099" ? [] : self.streams(for: videoId, count: 1)
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: found, isLoading: false)], false, nil, true)
            }
        )

        repo.prefetch(type: "movie", videoId: "tt0000001")
        try? await Task.sleep(nanoseconds: 30_000_000)
        clock = clock.addingTimeInterval(1)
        repo.prefetch(type: "movie", videoId: "tt0000099")
        try? await Task.sleep(nanoseconds: 30_000_000)
        clock = clock.addingTimeInterval(1)
        repo.prefetch(type: "movie", videoId: "tt0000002")
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(repo.cachedKeysInOrderForTesting.count, 2)
        XCTAssertFalse(repo.cachedKeysInOrderForTesting.contains(StreamsRepository.requestKey(type: "movie", videoId: "tt0000099")))
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt0000001"), "Least recently used populated title must survive an empty entry")
        XCTAssertNotNil(repo.cachedState(forType: "movie", videoId: "tt0000002"))
    }

    func testRevalidateIfCachedServesCachedStreamsThenPublishesRefreshedStreams() async {
        var now = Date(timeIntervalSince1970: 20_000)
        var calls: [String] = []
        var streamCount = 1
        var slow = false
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                calls.append(videoId)
                let count = streamCount
                if slow {
                    publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [], isLoading: true)], true, nil, true)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                }
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: self.streams(for: videoId, count: count), isLoading: false)], false, nil, true)
            }
        )
        let key = StreamsRepository.requestKey(type: "movie", videoId: "tt3000000")

        repo.load(type: "movie", videoId: "tt3000000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        repo.load(type: "movie", videoId: "tt3000001")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt3000000", "tt3000001"])

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 5)
        streamCount = 2
        slow = true
        repo.load(type: "movie", videoId: "tt3000000", revalidateIfCached: true)
        let servedRevision = repo.state.revision

        XCTAssertEqual(repo.state.requestKey, key)
        XCTAssertEqual(repo.state.allStreams.count, 1, "Cached streams must be served instantly")
        XCTAssertFalse(repo.state.isAnyLoading)
        XCTAssertTrue(repo.isRevalidating(requestKey: key))

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(calls, ["tt3000000", "tt3000001", "tt3000000"])
        XCTAssertEqual(repo.state.allStreams.count, 1)
        XCTAssertFalse(repo.state.isAnyLoading)
        XCTAssertEqual(repo.state.revision, servedRevision)
        XCTAssertEqual(repo.cachedState(forType: "movie", videoId: "tt3000000")?.allStreams.count, 1)
        XCTAssertEqual(repo.cachedState(forType: "movie", videoId: "tt3000000")?.isAnyLoading, false)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(repo.isRevalidating(requestKey: key))
        XCTAssertEqual(repo.state.allStreams.count, 2, "Refreshed streams must be published once revalidation completes")
        XCTAssertGreaterThan(repo.state.revision, servedRevision)
        XCTAssertFalse(repo.state.isAnyLoading)
        XCTAssertEqual(repo.cachedState(forType: "movie", videoId: "tt3000000")?.allStreams.count, 2)
    }

    func testRevalidationKeepsCachedStreamsWhenRefreshErrorsWithZeroStreams() async {
        var now = Date(timeIntervalSince1970: 30_000)
        var failing = false
        var calls = 0
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                calls += 1
                let group = failing
                    ? AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [], isLoading: false, error: "timeout")
                    : AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: self.streams(for: videoId, count: 1), isLoading: false)
                publish([group], false, nil, true)
            }
        )

        repo.load(type: "movie", videoId: "tt4000000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 1)
        failing = true
        repo.load(type: "movie", videoId: "tt4000000", revalidateIfCached: true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(repo.isRevalidating(requestKey: StreamsRepository.requestKey(type: "movie", videoId: "tt4000000")))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(repo.state.allStreams.count, 1)
        XCTAssertEqual(repo.cachedState(forType: "movie", videoId: "tt4000000")?.allStreams.count, 1)

        now = now.addingTimeInterval(5)
        repo.load(type: "movie", videoId: "tt4000000", revalidateIfCached: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, 2)
    }

    func testRevalidationCarriesForwardStreamsOfAnAddonThatFailedThisTime() async {
        var now = Date(timeIntervalSince1970: 35_000)
        var refresh = false
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                let debrid = refresh
                    ? AddonStreamGroup(addonId: "debrid", displayName: "Debrid", streams: [], isLoading: false, error: "Timed out")
                    : AddonStreamGroup(addonId: "debrid", displayName: "Debrid", streams: self.streams(for: "\(videoId)-d", count: 3), isLoading: false)
                let aio = AddonStreamGroup(
                    addonId: "aio",
                    displayName: "AIOStreams",
                    streams: self.streams(for: "\(videoId)-a", count: refresh ? 2 : 1),
                    isLoading: false
                )
                publish([debrid, aio], false, nil, true)
            }
        )

        repo.load(type: "movie", videoId: "tt4500000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(repo.state.allStreams.count, 4)

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 1)
        refresh = true
        repo.load(type: "movie", videoId: "tt4500000", revalidateIfCached: true)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(repo.state.groups.first { $0.addonId == "debrid" }?.streams.count, 3, "A timed-out add-on keeps its cached streams")
        XCTAssertEqual(repo.state.groups.first { $0.addonId == "aio" }?.streams.count, 2, "Healthy add-ons publish their refreshed streams")
        XCTAssertEqual(repo.state.allStreams.count, 5)
    }

    func testRevalidationCarriesMissingAddonsButNotLocalGroupsAndCleanEmptyClears() async {
        var now = Date(timeIntervalSince1970: 37_000)
        var phase = 0
        var calls = 0
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                calls += 1
                let local = AddonStreamGroup(addonId: "local.smb", displayName: "SMB", streams: self.streams(for: "\(videoId)-l", count: 1), isLoading: false)
                let debrid = AddonStreamGroup(addonId: "debrid", displayName: "Debrid", streams: self.streams(for: "\(videoId)-d", count: 2), isLoading: false)
                let aio = AddonStreamGroup(addonId: "aio", displayName: "AIOStreams", streams: self.streams(for: "\(videoId)-a", count: 1), isLoading: false)
                switch phase {
                case 0:
                    publish([local, debrid, aio], false, nil, true)
                case 1:
                    publish([aio], false, nil, true)
                default:
                    publish([AddonStreamGroup(addonId: "aio", displayName: "AIOStreams", streams: [], isLoading: false)], false, .noStreamsFound, true)
                }
            }
        )
        let key = StreamsRepository.requestKey(type: "movie", videoId: "tt4700000")

        repo.load(type: "movie", videoId: "tt4700000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(repo.state.allStreams.count, 4)

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 1)
        phase = 1
        repo.load(type: "movie", videoId: "tt4700000", revalidateIfCached: true)
        XCTAssertTrue(repo.isRevalidating(requestKey: key))
        repo.prefetch(type: "movie", videoId: "tt4700000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, 2, "prefetch of a key under revalidation must not start a duplicate discovery")
        XCTAssertEqual(repo.state.groups.first { $0.addonId == "debrid" }?.streams.count, 2, "An add-on missing from the refresh keeps its cached streams")
        XCTAssertNil(repo.state.groups.first { $0.addonId == "local.smb" }, "Local index groups are not carried forward")
        XCTAssertEqual(repo.state.allStreams.count, 3)

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 1)
        phase = 2
        repo.load(type: "movie", videoId: "tt4700000", revalidateIfCached: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(repo.state.groups.first { $0.addonId == "debrid" }?.streams.count, 2, "A still-missing add-on stays carried")
        XCTAssertEqual(repo.state.groups.first { $0.addonId == "aio" }?.streams.count, 0, "A clean empty answer clears that add-on")
    }

    func testRevalidationCooldownSkipsRightAfterPrefetchAndDetailsObserverReceivesUpdate() async {
        var now = Date(timeIntervalSince1970: 40_000)
        var calls: [String] = []
        var streamCount = 1
        var slow = false
        let repo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            nowProvider: { now },
            configuredAddonsProvider: { [URL(string: "https://addon.example/manifest.json")!] },
            discoveryHandler: { [unowned self] _, _, videoId, _, publish in
                calls.append(videoId)
                let count = streamCount
                if slow {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                }
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: self.streams(for: videoId, count: count), isLoading: false)], false, nil, true)
            }
        )
        let movie = NuvioMeta(id: "tt5000000", name: "Movie", type: "movie")
        let key = StreamsRepository.requestKey(type: "movie", videoId: "tt5000000")

        repo.prefetch(type: "movie", videoId: "tt5000000")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt5000000"])

        now = now.addingTimeInterval(5)
        let firstVisit = DetailsViewModel(repository: MockCatalogRepository(), streamsRepository: repo, streamDiscoveryMode: .shared)
        firstVisit.triggerStreamPreFetch(for: movie)
        XCTAssertFalse(repo.isRevalidating(requestKey: key))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, ["tt5000000"])
        XCTAssertEqual(firstVisit.uiState.streams.count, 1)

        now = now.addingTimeInterval(StreamsRepository.defaultMinimumRevalidateAge + 5)
        streamCount = 2
        slow = true
        let revisit = DetailsViewModel(repository: MockCatalogRepository(), streamsRepository: repo, streamDiscoveryMode: .shared)
        revisit.triggerStreamPreFetch(for: movie)
        XCTAssertTrue(repo.isRevalidating(requestKey: key))
        XCTAssertEqual(revisit.uiState.streams.count, 1)
        XCTAssertFalse(revisit.uiState.isLoadingStreams)
        let servedRevision = revisit.uiState.streamsRevision

        try? await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(calls, ["tt5000000", "tt5000000"])
        XCTAssertFalse(repo.isRevalidating(requestKey: key))
        XCTAssertEqual(revisit.uiState.streams.count, 2, "Details observer must receive the background revalidation result")
        XCTAssertNotEqual(revisit.uiState.streamsRevision, servedRevision)
        XCTAssertFalse(revisit.uiState.isLoadingStreams)
    }
}

final class DetailsTargetPredictorAndProgressTests: XCTestCase {

    private func airedDate(_ offsetDays: TimeInterval = -10) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date().addingTimeInterval(offsetDays * 86_400))
    }

    private func futureDate(_ offsetDays: TimeInterval = 30) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date().addingTimeInterval(offsetDays * 86_400))
    }

    func testPredictTargetCoversMoviesLiveNonCanonicalAndSeriesPaths() {
        let movie = NuvioMeta(id: "tt0133093", name: "The Matrix", type: "movie")
        let moviePred = DetailsPlayTargetPredictor.predict(meta: movie, continueItem: nil, watchedKeys: [])
        XCTAssertEqual(moviePred?.streamId, "tt0133093")
        XCTAssertNil(moviePred?.episode)

        let nonCanonicalMovie = NuvioMeta(id: "tmdb:603", name: "The Matrix", tmdbId: 603, type: "movie")
        XCTAssertNil(DetailsPlayTargetPredictor.predict(meta: nonCanonicalMovie, continueItem: nil, watchedKeys: []))

        let liveSports = NuvioMeta(id: "pp-live:match1", name: "[LIVE] Match", type: "tv")
        XCTAssertNil(DetailsPlayTargetPredictor.predict(meta: liveSports, continueItem: nil, watchedKeys: []))

        let past = airedDate()
        let future = futureDate()
        let episodes = [
            NuvioVideo(id: "tt900:0:1", title: "Special", season: 0, episode: 1, released: past),
            NuvioVideo(id: "tt900:1:1", title: "Pilot", season: 1, episode: 1, released: past),
            NuvioVideo(id: "tt900:1:2", title: "Second", season: 1, episode: 2, released: past),
            NuvioVideo(id: "tt900:2:1", title: "Season 2 Premiere", season: 2, episode: 1, released: past),
            NuvioVideo(id: "tt900:2:2", title: "Future Ep", season: 2, episode: 2, released: future)
        ]
        let series = NuvioMeta(id: "tt900", name: "Show", type: "series", videos: episodes)

        // Fresh series falls back to S1E1 (skipping season 0 specials).
        let freshPred = DetailsPlayTargetPredictor.predict(meta: series, continueItem: nil, watchedKeys: [])
        XCTAssertEqual(freshPred?.streamId, "tt900:1:1")
        XCTAssertEqual(freshPred?.episode?.episode, 1)

        // Watched S1E1 & S1E2 rolls forward into S2E1.
        let rolledPred = DetailsPlayTargetPredictor.predict(meta: series, continueItem: nil, watchedKeys: ["1:1", "1:2"])
        XCTAssertEqual(rolledPred?.streamId, "tt900:2:1")

        // Unaired focused episode is rejected.
        let futureFocused = DetailsPlayTargetPredictor.predict(
            meta: series,
            continueItem: nil,
            watchedKeys: [],
            focusedEpisode: episodes.last
        )
        XCTAssertNil(futureFocused)

        // Continue Watching works even on partial series metadata without `videos`.
        let sparseSeries = NuvioMeta(id: "tt900", name: "Show", imdbId: "tt900", type: "series", videos: nil)
        let cw = ContinueWatchingItem(
            meta: sparseSeries,
            streamUrl: "https://example.com/s1e2.mkv",
            position: 420,
            duration: 2400,
            lastWatchedAt: Date(),
            season: 1,
            episode: 2
        )
        let sparsePred = DetailsPlayTargetPredictor.predict(meta: sparseSeries, continueItem: cw, watchedKeys: [])
        XCTAssertEqual(sparsePred?.streamId, "tt900:1:2")
        XCTAssertEqual(sparsePred?.episode?.season, 1)
        XCTAssertEqual(sparsePred?.episode?.episode, 2)

        // Next aired episode skips specials & unaired future episodes.
        XCTAssertEqual(DetailsPlayTargetPredictor.nextAiredEpisode(after: episodes[1], in: episodes)?.id, "tt900:1:2")
        XCTAssertEqual(DetailsPlayTargetPredictor.nextAiredEpisode(after: episodes[2], in: episodes)?.id, "tt900:2:1")
        XCTAssertNil(DetailsPlayTargetPredictor.nextAiredEpisode(after: episodes[3], in: episodes))

        // Season switch picks first unwatched aired episode.
        XCTAssertEqual(DetailsPlayTargetPredictor.targetEpisode(forSeason: 1, in: episodes, watchedKeys: ["1:1"])?.id, "tt900:1:2")
        XCTAssertEqual(DetailsPlayTargetPredictor.targetEpisode(forSeason: 2, in: episodes, watchedKeys: ["2:1"])?.id, "tt900:2:1")
    }

    func testPlayButtonProgressEvaluatorTransitionsThroughPhases() {
        // Disabled -> hidden.
        XCTAssertEqual(
            TvDetailsPrefetchProgressEvaluator.evaluate(
                enabled: false, isPlayable: true, isLiveOrSports: false,
                hasSavedTarget: false, hasPreResolvedURL: false, isResolvingDebrid: false,
                smartStreamSelection: true, debridEnabled: true, targetMatchesRequest: true,
                isLoadingStreams: true, streamGroups: [], playableStreamCount: 0
            ),
            .hidden
        )

        // Target mismatch while metadata still warming -> initial 8% searching.
        let initial = TvDetailsPrefetchProgressEvaluator.evaluate(
            enabled: true, isPlayable: true, isLiveOrSports: false,
            hasSavedTarget: false, hasPreResolvedURL: false, isResolvingDebrid: false,
            smartStreamSelection: true, debridEnabled: true, targetMatchesRequest: false,
            isLoadingStreams: false, streamGroups: [], playableStreamCount: 0
        )
        XCTAssertEqual(initial.phase, .searching)
        XCTAssertEqual(initial.fraction, 0.08, accuracy: 0.001)

        // Partial add-on groups with debrid tail reserved.
        let groups = [
            AddonStreamGroup(addonId: "a1", displayName: "A1", streams: [
                NuvioStream(url: "https://cdn.example/1.mkv", name: "1080p", description: "1080p", addonName: "A1"),
                NuvioStream(url: "https://cdn.example/2.mkv", name: "4K", description: "4K", addonName: "A1")
            ], isLoading: false),
            AddonStreamGroup(addonId: "a2", displayName: "A2", streams: [], isLoading: true)
        ]
        let partial = TvDetailsPrefetchProgressEvaluator.evaluate(
            enabled: true, isPlayable: true, isLiveOrSports: false,
            hasSavedTarget: false, hasPreResolvedURL: false, isResolvingDebrid: false,
            smartStreamSelection: true, debridEnabled: true, targetMatchesRequest: true,
            isLoadingStreams: true, streamGroups: groups, playableStreamCount: 2
        )
        XCTAssertEqual(partial.phase, .searching)
        XCTAssertEqual(partial.fraction, 0.46, accuracy: 0.01)
        XCTAssertEqual(partial.statusNote, "Found 2 sources…")

        // Resolving debrid -> 0.85.
        let debrid = TvDetailsPrefetchProgressEvaluator.evaluate(
            enabled: true, isPlayable: true, isLiveOrSports: false,
            hasSavedTarget: false, hasPreResolvedURL: false, isResolvingDebrid: true,
            smartStreamSelection: true, debridEnabled: true, targetMatchesRequest: true,
            isLoadingStreams: false, streamGroups: groups, playableStreamCount: 2
        )
        XCTAssertEqual(debrid.phase, .resolvingDebrid)
        XCTAssertEqual(debrid.fraction, 0.85, accuracy: 0.001)

        // Ready -> 1.0 + playable count.
        let ready = TvDetailsPrefetchProgressEvaluator.evaluate(
            enabled: true, isPlayable: true, isLiveOrSports: false,
            hasSavedTarget: false, hasPreResolvedURL: true, isResolvingDebrid: false,
            smartStreamSelection: true, debridEnabled: true, targetMatchesRequest: true,
            isLoadingStreams: false, streamGroups: groups, playableStreamCount: 2
        )
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(ready.fraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(ready.statusNote, "2 sources ready")

        // Finished empty -> 1.0 "No sources found".
        let empty = TvDetailsPrefetchProgressEvaluator.evaluate(
            enabled: true, isPlayable: true, isLiveOrSports: false,
            hasSavedTarget: false, hasPreResolvedURL: false, isResolvingDebrid: false,
            smartStreamSelection: true, debridEnabled: false, targetMatchesRequest: true,
            isLoadingStreams: false, streamGroups: [], playableStreamCount: 0
        )
        XCTAssertEqual(empty.phase, .ready)
        XCTAssertEqual(empty.statusNote, "No sources found")

        // Subtext includes prefetchNote alongside hold-to-switch hint.
        let movie = NuvioMeta(id: "tt0133093", name: "The Matrix", type: "movie")
        let sub = TvDetailsHeroFormatter.playSubtext(
            meta: movie,
            playTarget: TvDetailsPlayTarget(episode: nil, label: "Play", isPlayable: true),
            continueItem: nil,
            canBypassPicker: true,
            prefetchNote: ready.statusNote
        )
        XCTAssertEqual(sub, "2 sources ready · Hold Select for sources")
    }

    func testPlayButtonProgressUsesCachedFallbackWhenRequestedStreamPointsToDifferentEpisode() {
        let cachedGroups = [
            AddonStreamGroup(
                addonId: "jellyfin.s1",
                displayName: "Jellyfin",
                streams: [
                    NuvioStream(url: "https://cdn.example/s1e1-a.mkv", name: "1080p", description: "1080p", addonName: "Jellyfin"),
                    NuvioStream(url: "https://cdn.example/s1e1-b.mkv", name: "720p", description: "720p", addonName: "Jellyfin")
                ],
                isLoading: false
            )
        ]
        let cachedFallback = StreamsDiscoveryState(
            requestKey: StreamsRepository.requestKey(type: "series", videoId: "tt900:1:1", season: 1, episode: 1),
            revision: 2,
            groups: cachedGroups,
            isAnyLoading: false,
            emptyStateReason: nil,
            hasResolvedTargets: true
        )

        let recovered = TvDetailsPrefetchProgressEvaluator.evaluateWithCachedFallback(
            enabled: true,
            isPlayable: true,
            isLiveOrSports: false,
            hasSavedTarget: false,
            hasPreResolvedURL: false,
            isResolvingDebrid: false,
            smartStreamSelection: true,
            debridEnabled: false,
            targetMatchesRequest: false,
            isLoadingStreams: false,
            streamGroups: [],
            playableStreamCount: 0,
            cachedFallbackState: cachedFallback
        )
        XCTAssertEqual(recovered.phase, .ready)
        XCTAssertEqual(recovered.fraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(recovered.statusNote, "2 sources ready")

        // Without any cached fallback, mismatched request still reports initial searching.
        let uncached = TvDetailsPrefetchProgressEvaluator.evaluateWithCachedFallback(
            enabled: true,
            isPlayable: true,
            isLiveOrSports: false,
            hasSavedTarget: false,
            hasPreResolvedURL: false,
            isResolvingDebrid: false,
            smartStreamSelection: true,
            debridEnabled: false,
            targetMatchesRequest: false,
            isLoadingStreams: false,
            streamGroups: [],
            playableStreamCount: 0,
            cachedFallbackState: nil
        )
        XCTAssertEqual(uncached.phase, .searching)
        XCTAssertEqual(uncached.fraction, 0.08, accuracy: 0.001)
        XCTAssertEqual(uncached.statusNote, "Checking sources…")
    }

    @MainActor
    func testSyncStreamsToDefaultPlayTargetRestoresHeroEpisodeFromLRUCacheWithoutRefetch() async {
        var handlerCalls: [String] = []
        let addonURL = URL(string: "https://addon.example/manifest.json")!
        let streamsRepo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            configuredAddonsProvider: { [addonURL] },
            discoveryHandler: { _, _, videoId, _, publish in
                handlerCalls.append(videoId)
                let streams: [NuvioStream] = videoId.hasSuffix(":1:1")
                    ? [NuvioStream(url: "https://cdn.example/s1e1.mkv", name: "1080p", description: "S1E1", addonName: "Addon")]
                    : []
                publish(
                    [AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: streams, isLoading: false)],
                    false,
                    streams.isEmpty ? .noStreamsFound : nil,
                    true
                )
            }
        )

        let past = airedDate()
        let seriesMeta = NuvioMeta(
            id: "tt900",
            name: "Show",
            type: "series",
            videos: [
                NuvioVideo(id: "tt900:1:1", title: "Pilot", season: 1, episode: 1, released: past),
                NuvioVideo(id: "tt900:1:2", title: "Second", season: 1, episode: 2, released: past)
            ]
        )

        let vm = DetailsViewModel(
            repository: MockCatalogRepository(),
            streamsRepository: streamsRepo,
            streamDiscoveryMode: .shared
        )

        vm.triggerStreamPreFetch(for: seriesMeta)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(handlerCalls, ["tt900:1:1"])
        XCTAssertEqual(vm.requestedStreamId, "tt900:1:1")
        XCTAssertEqual(vm.uiState.streams.count, 1)

        // Simulate user selecting Episode 2 manually, switching active requestedStreamId away from Hero default.
        vm.prepareStreams(forId: "tt900:1:2", type: "series")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(handlerCalls, ["tt900:1:1", "tt900:1:2"])
        XCTAssertEqual(vm.requestedStreamId, "tt900:1:2")
        XCTAssertTrue(vm.uiState.streams.isEmpty)

        // Dismissing Episode 2 picker syncs foreground streams back to Hero S1E1 from LRU cache with 0 new fetches.
        vm.syncStreamsToDefaultPlayTargetIfNeeded(for: seriesMeta)
        XCTAssertEqual(handlerCalls, ["tt900:1:1", "tt900:1:2"], "Restoring Hero S1E1 must reuse completed LRU cache entry")
        XCTAssertEqual(vm.requestedStreamId, "tt900:1:1")
        XCTAssertEqual(vm.prefetchedStreamId, "tt900:1:1")
        XCTAssertEqual(vm.prefetchedEpisode?.episode, 1)
        XCTAssertEqual(vm.uiState.streams.count, 1)
        XCTAssertFalse(vm.uiState.isLoadingStreams)
    }

    func testBackdropArtworkResolverUpgradesHostsAndAdaptsToRAM() {
        let tmdb = URL(string: "https://image.tmdb.org/t/p/w1280/abc123.jpg")!
        XCTAssertEqual(
            BackdropArtworkResolver.candidateURLs(for: tmdb).map(\.absoluteString),
            ["https://image.tmdb.org/t/p/original/abc123.jpg", "https://image.tmdb.org/t/p/w1280/abc123.jpg"]
        )

        let metahub = URL(string: "https://images.metahub.space/background/medium/tt0133093/img")!
        XCTAssertEqual(
            BackdropArtworkResolver.candidateURLs(for: metahub).map(\.absoluteString),
            ["https://images.metahub.space/background/large/tt0133093/img", "https://images.metahub.space/background/medium/tt0133093/img"]
        )

        let fanartNested = URL(string: "https://assets.fanart.tv/fanart/movies/603/moviebackground/preview/abc.jpg")!
        XCTAssertEqual(
            BackdropArtworkResolver.candidateURLs(for: fanartNested).map(\.absoluteString),
            ["https://assets.fanart.tv/fanart/movies/603/moviebackground/abc.jpg", "https://assets.fanart.tv/fanart/movies/603/moviebackground/preview/abc.jpg"]
        )

        let fanartLeading = URL(string: "https://assets.fanart.tv/preview/movies/603/moviebackground/abc.jpg")!
        XCTAssertEqual(
            BackdropArtworkResolver.candidateURLs(for: fanartLeading).map(\.absoluteString),
            ["https://assets.fanart.tv/fanart/movies/603/moviebackground/abc.jpg", "https://assets.fanart.tv/preview/movies/603/moviebackground/abc.jpg"]
        )

        let alreadyOriginal = URL(string: "https://image.tmdb.org/t/p/original/abc123.jpg")!
        XCTAssertEqual(BackdropArtworkResolver.candidateURLs(for: alreadyOriginal), [alreadyOriginal])

        XCTAssertEqual(BackdropArtworkResolver.maxPixelSize(physicalMemoryBytes: 4_294_967_296), 3840.0)
        XCTAssertEqual(BackdropArtworkResolver.maxPixelSize(physicalMemoryBytes: 3_221_225_472), 2560.0)
        XCTAssertEqual(BackdropArtworkResolver.maxPixelSize(physicalMemoryBytes: 2_147_483_648), 1920.0)
    }

    @MainActor
    func testContinueWatchingIdentityDistinguishesEpisodeAndUpNextChanges() {
        let series = NuvioMeta(id: "tt9813792", name: "FROM", imdbId: "tt9813792", type: "series")
        let s1e1Resume = ContinueWatchingItem(
            meta: series,
            streamUrl: "https://example.com/s1e1.mkv",
            position: 120,
            duration: 3000,
            lastWatchedAt: Date(),
            season: 1,
            episode: 1,
            isUpNext: false
        )
        let s3e1Resume = ContinueWatchingItem(
            meta: series,
            streamUrl: "https://example.com/s3e1.mkv",
            position: 120,
            duration: 3000,
            lastWatchedAt: Date(),
            season: 3,
            episode: 1,
            isUpNext: false
        )
        let s3e1UpNext = ContinueWatchingItem(
            meta: series,
            streamUrl: "",
            position: 0,
            duration: 0,
            lastWatchedAt: Date(),
            season: 3,
            episode: 1,
            isUpNext: true
        )

        let id1 = TraktProgressService.continueWatchingSnapshotIdentityForTesting([s1e1Resume])
        let id2 = TraktProgressService.continueWatchingSnapshotIdentityForTesting([s3e1Resume])
        let id3 = TraktProgressService.continueWatchingSnapshotIdentityForTesting([s3e1UpNext])

        XCTAssertNotEqual(id1, id2, "Episode progression on the same series must change snapshot identity so notifications fire")
        XCTAssertNotEqual(id2, id3, "Resume vs Up Next transition must change snapshot identity")
    }

    @MainActor
    func testLoadDetailsClearsRequestedStreamIdAcrossDistinctImdbTitles() async {
        let addonURL = URL(string: "https://addon.example/manifest.json")!
        let streamsRepo = StreamsRepository.makeForTesting(
            maxCacheEntries: 8,
            cacheTTL: 300,
            configuredAddonsProvider: { [addonURL] },
            discoveryHandler: { _, _, videoId, _, publish in
                let stream = NuvioStream(url: "https://cdn.example/\(videoId).mkv", name: "1080p", description: "1080p", addonName: "Addon")
                publish([AddonStreamGroup(addonId: "a1", displayName: "Addon", streams: [stream], isLoading: false)], false, nil, true)
            }
        )
        let vm = DetailsViewModel(
            repository: MockCatalogRepository(),
            streamsRepository: streamsRepo,
            streamDiscoveryMode: .shared
        )
        vm.prepareStreams(forId: "tt1111111", type: "movie")
        XCTAssertEqual(vm.requestedStreamId, "tt1111111")

        let loadTask = vm.loadDetails(id: "tt2222222", type: "movie")
        XCTAssertNil(vm.requestedStreamId, "Loading a different IMDb title must not preserve another title's requestedStreamId")
        loadTask.cancel()
    }
}
