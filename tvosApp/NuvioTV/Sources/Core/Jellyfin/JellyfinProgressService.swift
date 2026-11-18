import Foundation

/// Continue Watching, playback scrobbling, and watched-state synchronization
/// backed directly by a configured Jellyfin/AioFin server.
@MainActor
enum JellyfinProgressService {
    static let ticksPerSecond: Double = 10_000_000
    private static let maxContinueWatchingItems = 50
    private static var resolvedItemIDCache: [String: String] = [:]

    struct AccountTarget: Equatable, Sendable {
        let server: JellyfinServerConfig
        let baseURL: URL
        let accessToken: String
    }

    struct ProgressSeed {
        let jellyfinItemID: String
        let canonicalID: String
        let imdbID: String?
        let tmdbID: Int?
        let type: String
        let title: String
        let episodeTitle: String?
        let year: Int?
        let overview: String?
        let posterURL: String?
        let backdropURL: String?
        let season: Int?
        let episode: Int?
        let positionTicks: Int64
        let runTimeTicks: Int64?
        let lastWatchedAt: Date
        let isUpNext: Bool
        let hasRemoteCatalogID: Bool

        var placeholderMeta: NuvioMeta {
            NuvioMeta(
                id: canonicalID,
                name: title,
                description: overview,
                posterUrl: posterURL,
                backgroundUrl: backdropURL,
                imdbId: imdbID,
                tmdbId: tmdbID,
                type: type,
                year: year
            )
        }
    }

    nonisolated static func configuredServers(in store: UserDefaults = ProfileSettings.current) -> [JellyfinServerConfig] {
        guard let data = store.data(forKey: SettingsKey.jellyfinServers),
              let servers = try? JSONDecoder().decode([JellyfinServerConfig].self, from: data) else {
            return []
        }
        return servers
    }

    nonisolated static func activeTarget(
        in store: UserDefaults = ProfileSettings.current,
        servers: [JellyfinServerConfig]? = nil,
        tokenProvider: ((String, String) -> String)? = nil,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> AccountTarget? {
        let configured = servers ?? configuredServers(in: store)
        let readToken = tokenProvider ?? { serverID, scope in
            JellyfinCredentialStore.token(forServerID: serverID, profileScope: scope)
        }
        for server in configured {
            let userId = server.userId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userId.isEmpty, let baseURL = server.baseURL else { continue }
            let token = readToken(server.id, profileScope).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            return AccountTarget(server: server, baseURL: baseURL, accessToken: token)
        }
        return nil
    }

    nonisolated static func isAvailable(
        in store: UserDefaults = ProfileSettings.current,
        servers: [JellyfinServerConfig]? = nil,
        tokenProvider: ((String, String) -> String)? = nil,
        profileScope: String? = nil
    ) -> Bool {
        guard ProfileSettings.isActiveStore(store) else { return false }
        let scope = profileScope ?? ProfileSettings.activeProfileScope
        return activeTarget(in: store, servers: servers, tokenProvider: tokenProvider, profileScope: scope) != nil
    }

    nonisolated static func accountBindingID(
        in store: UserDefaults = ProfileSettings.current,
        servers: [JellyfinServerConfig]? = nil,
        tokenProvider: ((String, String) -> String)? = nil,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> String? {
        guard let target = activeTarget(in: store, servers: servers, tokenProvider: tokenProvider, profileScope: profileScope) else {
            return nil
        }
        return "jellyfin:\(target.server.id):\(target.server.userId)"
    }

    static func fetchContinueWatching(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        targetOverride: AccountTarget? = nil,
        urlSession: URLSession = .shared
    ) async -> [ContinueWatchingItem]? {
        guard ProfileSettings.isActiveStore(store),
              TraktSettingsStore.watchProgressSource(in: store) == .jellyfin,
              let target = targetOverride ?? activeTarget(in: store) else {
            return []
        }

        let client = JellyfinClient(
            baseURL: target.baseURL,
            accessToken: target.accessToken,
            session: urlSession
        )
        let userId = target.server.userId

        async let resumeTask: [JellyfinMediaItem]? = try? await client.resumeItems(
            userId: userId,
            limit: maxContinueWatchingItems
        )
        async let nextUpTask: [JellyfinMediaItem]? = try? await client.nextUpItems(
            userId: userId,
            limit: maxContinueWatchingItems
        )
        let (resumeItems, nextUpItems) = await (resumeTask, nextUpTask)
        guard resumeItems != nil || nextUpItems != nil else { return nil }

        let seriesIDs = Set(((resumeItems ?? []) + (nextUpItems ?? [])).compactMap { item -> String? in
            guard item.type == "Episode", let seriesId = item.seriesId, !seriesId.isEmpty else { return nil }
            return seriesId
        })
        let seriesItems = (try? await client.items(userId: userId, ids: Array(seriesIDs))) ?? []
        let seriesByID = Dictionary(uniqueKeysWithValues: seriesItems.map { ($0.id, $0) })

        let seeds = buildContinueWatchingSeeds(
            resumeItems: resumeItems ?? [],
            nextUpItems: nextUpItems ?? [],
            seriesByID: seriesByID,
            target: target
        )
        cacheResolvedSeeds(seeds, serverID: target.server.id)

        let cappedSeeds = Array(seeds.prefix(maxContinueWatchingItems))
        return await TraktProgressService.resolveContinueWatchingMetadata(from: cappedSeeds, batchSize: 6) { seed in
            let loaded: NuvioMeta? = if seed.hasRemoteCatalogID {
                try? await repository.getMetadata(id: seed.canonicalID, type: seed.type)
            } else {
                nil
            }
            let meta = loaded ?? seed.placeholderMeta
            let durationSeconds = resolvedDurationSeconds(
                loaded: loaded,
                runTimeTicks: seed.runTimeTicks,
                contentType: seed.type
            )
            let positionSeconds: Double = seed.isUpNext
                ? 0
                : max(1, Double(seed.positionTicks) / ticksPerSecond)

            return ContinueWatchingItem(
                meta: meta,
                streamUrl: "",
                position: positionSeconds,
                duration: durationSeconds,
                lastWatchedAt: seed.lastWatchedAt,
                season: seed.season,
                episode: seed.episode,
                episodeTitleOverride: seed.episodeTitle,
                isUpNext: seed.isUpNext
            )
        }
    }

    static func buildContinueWatchingSeeds(
        resumeItems: [JellyfinMediaItem],
        nextUpItems: [JellyfinMediaItem],
        seriesByID: [String: JellyfinMediaItem],
        target: AccountTarget
    ) -> [ProgressSeed] {
        var seeds: [ProgressSeed] = []
        var seenSeriesIDs = Set<String>()
        var seenContentIDs = Set<String>()
        let baseDate = Date()

        func appendSeed(for item: JellyfinMediaItem, isUpNext: Bool, fallbackOffset: Int) {
            let isEpisode = item.type == "Episode"
            let parentSeries = isEpisode ? item.seriesId.flatMap { seriesByID[$0] } : nil
            if isEpisode, let seriesId = item.seriesId, !seriesId.isEmpty {
                guard seenSeriesIDs.insert(seriesId).inserted else { return }
            }

            let rawImdb = (parentSeries?.imdbId ?? item.imdbId)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalImdb = rawImdb.flatMap(NuvioMeta.canonicalImdbID(from:))
            let tmdbID = parentSeries?.tmdbId ?? item.tmdbId

            let remoteCanonicalID: String? = if let canonicalImdb {
                canonicalImdb
            } else if let tmdbID {
                "tmdb:\(tmdbID)"
            } else {
                nil
            }

            let contentID = remoteCanonicalID ?? JellyfinLibraryIndex.contentId(
                serverID: target.server.id,
                itemId: isEpisode ? (item.seriesId ?? item.id) : item.id
            )
            let dedupeKey = "\(isEpisode ? "series" : "movie"):\(contentID.lowercased())"
            guard seenContentIDs.insert(dedupeKey).inserted else { return }

            let title = isEpisode
                ? (parentSeries?.name ?? item.seriesName ?? item.name)
                : item.name
            let posterSourceID = isEpisode ? (parentSeries?.id ?? item.seriesId ?? item.id) : item.id
            let posterTag = isEpisode ? (parentSeries?.primaryImageTag ?? item.primaryImageTag) : item.primaryImageTag
            let backdropSourceID = isEpisode ? (item.id) : item.id
            let backdropTag = item.primaryImageTag ?? item.backdropImageTag ?? parentSeries?.backdropImageTag

            let posterURL = JellyfinClient.imageURL(
                baseURL: target.baseURL,
                itemId: posterSourceID,
                imageType: "Primary",
                tag: posterTag,
                accessToken: target.accessToken
            )?.absoluteString
            let backdropURL = JellyfinClient.imageURL(
                baseURL: target.baseURL,
                itemId: backdropSourceID,
                imageType: item.primaryImageTag != nil ? "Primary" : "Backdrop",
                tag: backdropTag,
                accessToken: target.accessToken
            )?.absoluteString

            let parsedDate = parseJellyfinDate(item.userData?.lastPlayedDate)
                ?? baseDate.addingTimeInterval(-Double(fallbackOffset) * 60)

            seeds.append(ProgressSeed(
                jellyfinItemID: item.id,
                canonicalID: contentID,
                imdbID: canonicalImdb,
                tmdbID: tmdbID,
                type: isEpisode ? "series" : "movie",
                title: title,
                episodeTitle: isEpisode ? item.name : nil,
                year: parentSeries?.productionYear ?? item.productionYear,
                overview: item.overview ?? parentSeries?.overview,
                posterURL: posterURL,
                backdropURL: backdropURL,
                season: isEpisode ? item.parentIndexNumber : nil,
                episode: isEpisode ? item.indexNumber : nil,
                positionTicks: item.userData?.playbackPositionTicks ?? 0,
                runTimeTicks: item.runTimeTicks,
                lastWatchedAt: parsedDate,
                isUpNext: isUpNext,
                hasRemoteCatalogID: remoteCanonicalID != nil
            ))
        }

        for (index, item) in resumeItems.enumerated() {
            appendSeed(for: item, isUpNext: false, fallbackOffset: index)
        }
        let nextUpOffsetBase = max(resumeItems.count, 100)
        for (index, item) in nextUpItems.enumerated() {
            appendSeed(for: item, isUpNext: true, fallbackOffset: nextUpOffsetBase + index)
        }
        return seeds
    }

    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults = ProfileSettings.current,
        targetOverride: AccountTarget? = nil,
        urlSession: URLSession = .shared
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .jellyfin
                || RemoteTrackingState.isScrobbleEnabled(for: .jellyfin, in: store)),
              position.isFinite,
              duration.isFinite,
              duration > 0,
              let target = targetOverride ?? activeTarget(in: store) else {
            return false
        }

        let client = JellyfinClient(
            baseURL: target.baseURL,
            accessToken: target.accessToken,
            session: urlSession
        )
        guard let itemID = await resolveItemID(
            meta: meta,
            season: season,
            episode: episode,
            target: target,
            client: client
        ) else {
            return false
        }

        let ticks = Int64((max(0, position) * ticksPerSecond).rounded())
        do {
            switch action {
            case .start:
                try await client.reportPlaybackStart(itemId: itemID, positionTicks: ticks)
            case .pause:
                try await client.reportPlaybackProgress(itemId: itemID, positionTicks: ticks, isPaused: true)
            case .stop:
                try await client.reportPlaybackStopped(itemId: itemID, positionTicks: ticks)
                if position / duration >= WatchProgressLedger.completionFraction {
                    try? await client.setPlayed(userId: target.server.userId, itemId: itemID, played: true)
                }
            }
            guard ProfileSettings.isActiveStore(store) else { return false }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func removePlayback(
        for item: ContinueWatchingItem,
        store: UserDefaults = ProfileSettings.current,
        targetOverride: AccountTarget? = nil,
        urlSession: URLSession = .shared
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .jellyfin
                || RemoteTrackingState.isScrobbleEnabled(for: .jellyfin, in: store)),
              let target = targetOverride ?? activeTarget(in: store) else {
            return false
        }

        let client = JellyfinClient(
            baseURL: target.baseURL,
            accessToken: target.accessToken,
            session: urlSession
        )
        guard let itemID = await resolveItemID(
            meta: item.meta,
            season: item.season,
            episode: item.episode,
            target: target,
            client: client
        ) else {
            return false
        }

        do {
            try await client.reportPlaybackStopped(itemId: itemID, positionTicks: 0)
            try? await client.updateUserData(
                userId: target.server.userId,
                itemId: itemID,
                playbackPositionTicks: 0,
                played: false
            )
            guard ProfileSettings.isActiveStore(store) else { return false }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .jellyfin, in: store)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episodes: [Int] = [],
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        targetOverride: AccountTarget? = nil,
        urlSession: URLSession = .shared
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .jellyfin
                || RemoteTrackingState.isScrobbleEnabled(for: .jellyfin, in: store)),
              let target = targetOverride ?? activeTarget(in: store) else {
            return false
        }

        let client = JellyfinClient(
            baseURL: target.baseURL,
            accessToken: target.accessToken,
            session: urlSession
        )

        var anySucceeded = false
        if meta.isSeries, let season {
            let episodeList = episodes.isEmpty ? [] : episodes
            for episode in episodeList {
                guard let itemID = await resolveItemID(
                    meta: meta,
                    season: season,
                    episode: episode,
                    target: target,
                    client: client
                ) else { continue }
                if (try? await client.setPlayed(userId: target.server.userId, itemId: itemID, played: isWatched)) != nil {
                    anySucceeded = true
                }
            }
        } else if let itemID = await resolveItemID(
            meta: meta,
            season: season,
            episode: episodes.first,
            target: target,
            client: client
        ) {
            if (try? await client.setPlayed(userId: target.server.userId, itemId: itemID, played: isWatched)) != nil {
                anySucceeded = true
            }
        }

        guard anySucceeded else { return false }
        NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .jellyfin, in: store)
        return true
    }

    // MARK: - Item Resolution

    private static func resolveItemID(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        target: AccountTarget,
        client: JellyfinClient
    ) async -> String? {
        let keys = identityKeys(for: meta)
        for key in keys {
            if let cached = resolvedItemIDCache[cacheKey(serverID: target.server.id, identity: key, season: season, episode: episode)] {
                return cached
            }
        }

        let indexedTitles = keys.flatMap { JellyfinLibraryIndex.shared.titles(matching: $0) }
            .filter { $0.serverID == target.server.id }
        for title in indexedTitles {
            if meta.isSeries {
                if let season, let episode,
                   let match = title.items.first(where: { $0.season == season && $0.episode == episode }) {
                    cacheResolvedItemID(match.itemId, serverID: target.server.id, keys: keys, season: season, episode: episode)
                    return match.itemId
                } else if season == nil && episode == nil {
                    return title.itemId
                }
            } else if let match = title.items.first {
                cacheResolvedItemID(match.itemId, serverID: target.server.id, keys: keys, season: nil, episode: nil)
                return match.itemId
            }
        }

        let itemType = meta.isSeries ? "Series" : "Movie"
        guard let searchResults = try? await client.searchItems(
            userId: target.server.userId,
            term: meta.name,
            includeItemTypes: itemType
        ),
              let matched = bestSearchMatch(in: searchResults, for: meta, keys: keys) else {
            return nil
        }

        if meta.isSeries {
            guard let season, let episode,
                  let episodes = try? await client.episodes(seriesId: matched.id, userId: target.server.userId),
                  let epMatch = episodes.first(where: { $0.parentIndexNumber == season && $0.indexNumber == episode }) else {
                return season == nil && episode == nil ? matched.id : nil
            }
            cacheResolvedItemID(epMatch.id, serverID: target.server.id, keys: keys, season: season, episode: episode)
            return epMatch.id
        } else {
            cacheResolvedItemID(matched.id, serverID: target.server.id, keys: keys, season: nil, episode: nil)
            return matched.id
        }
    }

    private static func bestSearchMatch(
        in candidates: [JellyfinMediaItem],
        for meta: NuvioMeta,
        keys: [String]
    ) -> JellyfinMediaItem? {
        let targetImdb = meta.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:))
            ?? NuvioMeta.canonicalImdbID(from: meta.id)
        let targetTmdb = meta.tmdbId
            ?? (meta.id.hasPrefix("tmdb:") ? Int(meta.id.dropFirst("tmdb:".count)) : nil)

        if let targetImdb,
           let imdbMatch = candidates.first(where: {
               $0.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:)) == targetImdb
           }) {
            return imdbMatch
        }
        if let targetTmdb,
           let tmdbMatch = candidates.first(where: { $0.tmdbId == targetTmdb }) {
            return tmdbMatch
        }
        let exactNameMatches = candidates.filter {
            $0.name.caseInsensitiveCompare(meta.name) == .orderedSame
        }
        if let year = meta.year,
           let yearMatch = exactNameMatches.first(where: { $0.productionYear == year }) {
            return yearMatch
        }
        return exactNameMatches.first
    }

    private static func cacheResolvedSeeds(_ seeds: [ProgressSeed], serverID: String) {
        for seed in seeds {
            var keys = [seed.canonicalID.lowercased()]
            if let imdb = seed.imdbID?.lowercased() { keys.append(imdb) }
            if let tmdb = seed.tmdbID { keys.append("tmdb:\(tmdb)") }
            cacheResolvedItemID(
                seed.jellyfinItemID,
                serverID: serverID,
                keys: keys,
                season: seed.season,
                episode: seed.episode
            )
        }
    }

    private static func cacheResolvedItemID(
        _ itemID: String,
        serverID: String,
        keys: [String],
        season: Int?,
        episode: Int?
    ) {
        for key in keys {
            resolvedItemIDCache[cacheKey(serverID: serverID, identity: key, season: season, episode: episode)] = itemID
        }
    }

    private static func cacheKey(serverID: String, identity: String, season: Int?, episode: Int?) -> String {
        "\(serverID)|\(identity.lowercased())|\(season ?? -1)|\(episode ?? -1)"
    }

    private static func identityKeys(for meta: NuvioMeta) -> [String] {
        var keys: [String] = []
        if let imdb = meta.imdbId.flatMap(NuvioMeta.canonicalImdbID(from:))
            ?? NuvioMeta.canonicalImdbID(from: meta.id) {
            keys.append(imdb)
        }
        if let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:") ? Int(meta.id.dropFirst("tmdb:".count)) : nil) {
            keys.append("tmdb:\(tmdb)")
        }
        keys.append(meta.id)
        return keys
    }

    private static func resolvedDurationSeconds(
        loaded: NuvioMeta?,
        runTimeTicks: Int64?,
        contentType: String
    ) -> Double {
        if let runTimeTicks, runTimeTicks > 0 {
            return max(Double(runTimeTicks) / ticksPerSecond, 60)
        }
        if let rawRuntime = loaded?.runtime,
           let minutes = TopShelfEntry.runtimeMinutes(rawRuntime),
           minutes > 0 {
            return Double(minutes) * 60
        }
        return contentType == "movie" ? 5400 : 2700
    }

    private static func parseJellyfinDate(_ raw: String?) -> Date? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: trimmed)
    }
}
