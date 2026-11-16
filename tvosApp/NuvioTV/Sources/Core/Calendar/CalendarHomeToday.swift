import SwiftUI

/// Home's "Today" row: what comes out today from the library, taken from the
/// calendar (series, anime and movies alike), one card per title in airing
/// order.
struct CalendarHomeToday: Equatable {
    /// What the card shows besides the title, in the slots Continue
    /// Watching's Up Next cards use.
    struct CardLabel: Equatable {
        /// "S2E5" for episodes.
        let episode: String?
        /// The episode's name, unless spoilers are hidden.
        let episodeTitle: String?
        /// The broadcast time, "AIRING TODAY", or the movie's release kind.
        let badge: String
        /// The episode's picture for landscape cards, unless spoilers are hidden.
        let artworkURL: String?
    }

    var metas: [NuvioMeta] = []
    /// By title id (the row's card ids).
    var labels: [String: CardLabel] = [:]
    /// The calendar entry each card opens, by title id.
    var entries: [String: CalendarEntry] = [:]

    var isEmpty: Bool { metas.isEmpty }

    /// The row for `today`. A title with several entries today (a double
    /// episode) gets one card, for its first entry.
    static func build(
        from result: CalendarResult?,
        today: CalendarDay,
        hideSpoilers: Bool,
        time: (Date) -> String = CalendarFormat.time
    ) -> CalendarHomeToday {
        guard let result else { return CalendarHomeToday() }
        var row = CalendarHomeToday()
        // Already in airing order (timed first), then by title.
        for entry in result.entries(on: today) where isWatchableToday(entry) && row.entries[entry.itemId] == nil {
            row.entries[entry.itemId] = entry
            row.metas.append(meta(for: entry))
            row.labels[entry.itemId] = CardLabel(
                episode: entry.episodeCode,
                episodeTitle: hideSpoilers ? nil : entry.episodeName,
                badge: badge(for: entry, time: time),
                artworkURL: hideSpoilers ? nil : entry.stillURL?.absoluteString
            )
        }
        return row
    }

    /// Cinema releases can't be watched at home, so they are left out.
    static func isWatchableToday(_ entry: CalendarEntry) -> Bool {
        entry.releaseKind != .theatrical
    }

    static func badge(for entry: CalendarEntry, time: (Date) -> String) -> String {
        if let airTime = entry.airTime { return time(airTime) }
        if entry.kind == .movie, let release = CalendarFormat.releaseLabel(entry.releaseKind) { return release }
        return L10n.string("calendar_home_today_badge", fallback: "AIRING TODAY")
    }

    /// A compact card; Home fills in the hero's details once it is focused,
    /// as for add-on catalogs. The show's backdrop is left to that too: the
    /// episode's picture would be a spoiler there.
    private static func meta(for entry: CalendarEntry) -> NuvioMeta {
        let imdb = entry.itemId.hasPrefix("tt") ? String(entry.itemId.prefix { $0 != ":" }) : nil
        return NuvioMeta(
            id: entry.itemId,
            name: entry.title,
            posterUrl: entry.posterURL?.absoluteString,
            imdbId: imdb,
            tmdbId: entry.isFromAniList ? nil : entry.tmdbId,
            type: entry.itemType.isEmpty ? (entry.kind == .series ? "series" : "movie") : entry.itemType
        )
    }

    /// Seconds to a few moments after the next local midnight.
    static func secondsUntilTomorrow(from now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(24 * 60 * 60)
        return max(60, next.timeIntervalSince(now) + 5)
    }
}

/// Keeps Home's Today row in step with the shared calendar: the saved one
/// at once, a newer one a moment after Home's own rows have loaded, and the
/// next day's at midnight.
struct CalendarTodayHomeFeed: ViewModifier {
    /// How old the calendar may be before Home asks for a new one.
    static let maxAge: TimeInterval = 3 * 60 * 60

    let enabled: Bool
    let homeReady: Bool
    let isActive: Bool
    @Binding var row: CalendarHomeToday
    @AppStorage(SettingsKey.calendarHideSpoilers) private var hideSpoilers = CalendarOptions.defaultHideSpoilers

    /// Not observed: Home redraws only when its row changes.
    private var model: CalendarViewModel { .shared }

    private struct Trigger: Equatable {
        let enabled: Bool
        let ready: Bool
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .onReceive(model.$state) { update($0) }
            .onChange(of: enabled) { _, _ in update(model.state) }
            .onChange(of: hideSpoilers) { _, _ in update(model.state) }
            .task(id: Trigger(enabled: enabled, ready: homeReady, active: isActive)) {
                guard enabled, isActive else { return }
                model.showSaved()
                guard homeReady else { return }
                // Home's own rows first.
                try? await Task.sleep(for: .seconds(2))
                while !Task.isCancelled {
                    model.loadIfNeeded(maxAge: Self.maxAge)
                    // The day may have changed since the row was made.
                    update(model.state)
                    try? await Task.sleep(for: .seconds(CalendarHomeToday.secondsUntilTomorrow(from: Date())))
                }
            }
    }

    private func update(_ state: CalendarViewModel.State) {
        let today = CalendarHomeToday.build(
            from: model.currentResult(from: state),
            today: CalendarDay(date: Date()),
            hideSpoilers: hideSpoilers
        )
        // The Top Shelf can show Today even when Home's row is off.
        TopShelfTodayFeed.write(today)
        let next = enabled ? today : CalendarHomeToday()
        if next != row { row = next }
    }
}

struct AiringWeekLabel: Equatable, Sendable {
    let episodeCode: String
    let episodeTitle: String
    let badge: String
    let isOut: Bool
    let airDate: Date
}

enum AiringWeekEpisodes {
    /// The library's exact name.
    static let libraryName = "Airing This Week"
    
    private actor Cache {
        struct Entry {
            let label: AiringWeekLabel
            let expiresAt: Date
        }
        var labels: [Int: Entry] = [:]
        
        func get(_ id: Int, now: Date) -> AiringWeekLabel? {
            if let entry = labels[id], entry.expiresAt > now {
                return entry.label
            }
            labels[id] = nil
            return nil
        }
        
        func set(_ id: Int, label: AiringWeekLabel, expiresAt: Date) {
            labels[id] = Entry(label: label, expiresAt: expiresAt)
        }
    }
    
    private static let cache = Cache()

    /// Labels keyed by NuvioMeta.id. Titles with no episode found are left out.
    /// Fetches concurrently (at most 6 at a time) and caches results in memory for 3 hours per TMDB id.
    static func labels(for metas: [NuvioMeta], now: Date = Date()) async -> [String: AiringWeekLabel] {
        guard CalendarLibrarySource.isTmdbConfigured else { return [:] }
        let client = CalendarLibrarySource.makeClient()
        let expiresAt = now.addingTimeInterval(3 * 60 * 60)
        
        return await withTaskGroup(of: (String, AiringWeekLabel?).self) { group in
            var activeTasks = 0
            let maxConcurrent = 6
            var results: [String: AiringWeekLabel] = [:]
            
            for meta in metas {
                if activeTasks >= maxConcurrent {
                    if let result = await group.next(), let label = result.1 {
                        results[result.0] = label
                    }
                    activeTasks -= 1
                }
                
                activeTasks += 1
                group.addTask {
                    guard let resolved = await TmdbDetailsService.resolveTmdbId(for: meta) else {
                        return (meta.id, nil)
                    }
                    
                    if let cached = await cache.get(resolved.id, now: now) {
                        return (meta.id, cached)
                    }
                    
                    guard let details = try? await client.tvDetails(resolved.id) else {
                        return (meta.id, nil)
                    }
                    
                    let fmt = DateFormatter()
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    fmt.dateFormat = "yyyy-MM-dd"
                    fmt.timeZone = TimeZone(secondsFromGMT: 0)
                    
                    var nextAir: Date? = nil
                    if let n = details.nextEpisodeToAir?.airDate, let d = fmt.date(from: n) { nextAir = d }
                    var lastAir: Date? = nil
                    if let l = details.lastEpisodeToAir?.airDate, let d = fmt.date(from: l) { lastAir = d }
                    
                    let tvmaze = CalendarTvmazeTimes()
                    let knownIds = CalendarTvmazeTimes.ShowIds(imdb: meta.imdbId, tvdb: nil)
                    if let tvmazeId = await tvmaze.showId(tmdbId: resolved.id, known: knownIds, externalIds: { _ in nil }) {
                        let firstDay = CalendarDay(date: now.addingTimeInterval(-14 * 86400), timeZone: .current)
                        let lastDay = CalendarDay(date: now.addingTimeInterval(14 * 86400), timeZone: .current)
                        let airings = await tvmaze.airings(tvmazeId: tvmazeId, first: firstDay, last: lastDay)
                        
                        if let next = details.nextEpisodeToAir {
                            if let match = airings.first(where: { $0.season == next.seasonNumber && $0.number == next.episodeNumber }), let at = match.at {
                                nextAir = at
                            }
                        }
                        if let last = details.lastEpisodeToAir {
                            if let match = airings.first(where: { $0.season == last.seasonNumber && $0.number == last.episodeNumber }), let at = match.at {
                                lastAir = at
                            }
                        }
                    }
                    
                    guard let picked = pick(next: details.nextEpisodeToAir, nextAir: nextAir, last: details.lastEpisodeToAir, lastAir: lastAir, now: now) else {
                        return (meta.id, nil)
                    }
                    
                    let season = picked.episode.seasonNumber ?? 0
                    let episode = picked.episode.episodeNumber ?? 0
                    let epCode = "S\(season)E\(episode)"
                    
                    var epTitle = (picked.episode.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = epTitle.lowercased()
                    if lower.isEmpty || lower == "tba" || lower.hasPrefix("episode \(episode)") {
                        epTitle = "Episode \(episode)"
                    }
                    
                    let badgeStr = badge(air: picked.air, isOut: picked.isOut, now: now)
                    
                    let label = AiringWeekLabel(
                        episodeCode: epCode,
                        episodeTitle: epTitle,
                        badge: badgeStr,
                        isOut: picked.isOut,
                        airDate: picked.air
                    )
                    
                    await cache.set(resolved.id, label: label, expiresAt: expiresAt)
                    return (meta.id, label)
                }
            }
            
            for await result in group {
                if let label = result.1 {
                    results[result.0] = label
                }
            }
            
            return results
        }
    }
    
    /// Pure, unit-testable: which episode to show.
    /// Rule: if `last` aired within the past 36 hours of `now`, show it (isOut = true).
    /// Otherwise show `next` if it exists. Otherwise nil.
    static func pick(next: CalendarTmdb.Episode?, nextAir: Date?, last: CalendarTmdb.Episode?, lastAir: Date?, now: Date) -> (episode: CalendarTmdb.Episode, air: Date, isOut: Bool)? {
        if let last = last, let lastAir = lastAir {
            let elapsed = now.timeIntervalSince(lastAir)
            if elapsed >= 0 && elapsed <= 36 * 3600 {
                return (last, lastAir, true)
            }
        }
        if let next = next, let nextAir = nextAir {
            return (next, nextAir, now >= nextAir)
        }
        return nil
    }
    
    /// Pure: badge text. isOut -> "OUT NOW". Same local day -> "TODAY". Next local day -> "TOMORROW". Else "EEE d MMM" uppercased ("FRI 20 NOV").
    static func badge(air: Date, isOut: Bool, now: Date, calendar: Calendar = .current) -> String {
        if isOut { return "OUT NOW" }
        if calendar.isDate(air, inSameDayAs: now) { return "TODAY" }
        if calendar.isDate(air, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) { return "TOMORROW" }
        
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE d MMM"
        fmt.timeZone = calendar.timeZone
        return fmt.string(from: air).uppercased()
    }
}
