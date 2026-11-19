import XCTest
@testable import NuvioTV

final class ActionStreamTests: XCTestCase {
    func testActionStreamBehaviorHintsDecoding() throws {
        let notPlayable = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"notPlayable":true}"#.utf8)
        )
        XCTAssertTrue(notPlayable.isNotPlayable)
        XCTAssertEqual(notPlayable.notPlayable, true)

        let action = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"action":true}"#.utf8)
        )
        XCTAssertTrue(action.isNotPlayable)
        XCTAssertEqual(action.action, true)

        let stringBool = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"notPlayable":"true"}"#.utf8)
        )
        XCTAssertTrue(stringBool.isNotPlayable)

        let integerBool = try JSONDecoder().decode(
            StreamAddonBehaviorHints.self,
            from: Data(#"{"action":1}"#.utf8)
        )
        XCTAssertTrue(integerBool.isNotPlayable)

        let dto = StreamAddonStreamDTO(
            url: "https://addon.example/action/request-subtitles",
            name: "Request Subtitles",
            description: "Click to download subtitles for this episode",
            behaviorHints: notPlayable
        )
        let stream = try XCTUnwrap(dto.toNuvioStream(addonName: "SubtitlesAddon"))
        XCTAssertTrue(stream.isNotPlayable)
        XCTAssertEqual(stream.notPlayable, true)
    }

    func testPlayableStreamsRetainsActionStreamsRegardlessOfFilters() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper card",
            addonName: "Addon",
            notPlayable: true
        )
        let unknownResolution = NuvioStream(
            url: "https://addon.example/movie_unknown",
            name: "Unknown Res CAM",
            description: "CAM release",
            addonName: "Addon"
        )
        let hd = NuvioStream(
            url: "https://addon.example/movie1080p",
            name: "Movie 1080p",
            description: "1080p WEB-DL",
            addonName: "Addon"
        )
        let streams = [action, unknownResolution, hd]

        let defaultPlayable = SmartPlaybackSelector.playableStreams(
            from: streams, includeDebrid: false, cachedOnly: false, preserveAddonStreams: false
        )
        XCTAssertTrue(defaultPlayable.contains(where: { $0.id == action.id }))
        XCTAssertFalse(defaultPlayable.contains(where: { $0.id == unknownResolution.id }))
        XCTAssertTrue(defaultPlayable.contains(where: { $0.id == hd.id }))

        let cachedOnly = SmartPlaybackSelector.playableStreams(
            from: streams, includeDebrid: false, cachedOnly: true, preserveAddonStreams: false
        )
        XCTAssertTrue(cachedOnly.contains(where: { $0.id == action.id }))
    }

    func testStreamPickerListBuilderPreservesActionStreamPositions() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper action",
            addonName: "Addon",
            notPlayable: true
        )
        let hd = NuvioStream(url: "https://addon.example/movie720p", name: "Movie 720p", description: "720p", addonName: "Addon")
        let fullHD = NuvioStream(url: "https://addon.example/movie1080p", name: "Movie 1080p", description: "1080p", addonName: "Addon")
        let uhd = NuvioStream(url: "https://addon.example/movie4k", name: "Movie 4K 2160p", description: "4K", addonName: "Addon")

        let topAction = [action, hd, uhd, fullHD]
        let sortedQuality = StreamPickerListBuilder.sorted(topAction, by: .quality, preserveAddonStreams: false)
        XCTAssertEqual(sortedQuality.map(\.id), [action.id, uhd.id, fullHD.id, hd.id])
        let sortedDefault = StreamPickerListBuilder.sorted(topAction, by: .default, preserveAddonStreams: false)
        XCTAssertEqual(sortedDefault.first?.id, action.id)

        let middleAction = [hd, uhd, action, fullHD]
        let sortedMiddle = StreamPickerListBuilder.sorted(middleAction, by: .quality, preserveAddonStreams: false)
        XCTAssertEqual(sortedMiddle.map(\.id), [uhd.id, fullHD.id, action.id, hd.id])
    }

    func testSmartPlaybackSelectorExcludesActionStreamsFromAutoPlay() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Helper card",
            addonName: "Addon",
            notPlayable: true
        )
        let fullHD = NuvioStream(url: "https://addon.example/movie1080p", name: "Movie 1080p", description: "1080p WEB-DL", addonName: "Addon")
        let uhd = NuvioStream(url: "https://addon.example/movie4k", name: "Movie 2160p", description: "4K UHD", addonName: "Addon")
        let pool = [action, fullHD, uhd]

        let best = SmartPlaybackSelector.bestStream(
            from: pool,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(best?.id, uhd.id)
        XCTAssertFalse(SmartPlaybackSelector.rankedStreams(
            from: pool,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        ).contains(where: { $0.id == action.id }))
    }

    @MainActor
    func testActionPlaybackSessionRemainsUntrackedAfterSubtitleChanges() {
        XCTAssertFalse(PlayerViewModel.shouldTrackPlayback(
            subtitle: "S01 · E02 · Episode title",
            isTrailerSession: false,
            isActionSession: true
        ))
        XCTAssertTrue(PlayerViewModel.shouldTrackPlayback(
            subtitle: "S01 · E02 · Episode title",
            isTrailerSession: false
        ))
        XCTAssertFalse(PlayerViewModel.shouldTrackPlayback(
            subtitle: PlaybackMarkers.trailerSubtitle,
            isTrailerSession: false
        ))
    }

    func testBingeGroupNeverAttachesToActionStream() {
        let action = NuvioStream(
            url: "https://addon.example/action/subtitles",
            name: "Request Subtitles",
            description: "Action",
            addonName: "Addon",
            bingeGroup: "release-group-x",
            notPlayable: true
        )
        let tags = StreamQualityTags.parse(stream: action)
        XCTAssertNil(tags.bingeGroup)
        XCTAssertNil(tags.releaseFingerprint)
    }
}

@MainActor
final class SmartPlaybackTorBoxPreferenceTests: XCTestCase {
    func testSmartSelectorPrefersTorBoxAtSameResolution() {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.preferTorBoxStreams)
        defer { defaults.set(previous, forKey: SettingsKey.preferTorBoxStreams) }
        defaults.removeObject(forKey: SettingsKey.preferTorBoxStreams)

        let realDebrid = NuvioStream(
            url: "https://proxy.example/rd/movie.mkv",
            name: "Hollow Man (2000) · RD",
            description: "BluRay REMUX · 1080p · TrueHD 5.1 · 25 GB",
            addonName: "AIOStreams"
        )
        let torBox = NuvioStream(
            url: "https://proxy.example/tb/movie.mkv",
            name: "Hollow Man (2000) · TB",
            description: "BluRay · 1080p · 10bit · TrueHD 5.1 · 8.94 GB",
            addonName: "AIOStreams"
        )

        let ranked = SmartPlaybackSelector.rankedStreams(
            from: [realDebrid, torBox],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(ranked.first?.id, torBox.id)

        defaults.set(false, forKey: SettingsKey.preferTorBoxStreams)
        let unboosted = SmartPlaybackSelector.rankedStreams(
            from: [realDebrid, torBox],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(unboosted.first?.id, realDebrid.id)
    }

    func testSmartSelectorKeepsHigherResolutionOverTorBox() {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.preferTorBoxStreams)
        defer { defaults.set(previous, forKey: SettingsKey.preferTorBoxStreams) }
        defaults.removeObject(forKey: SettingsKey.preferTorBoxStreams)

        let realDebrid4K = NuvioStream(
            url: "https://proxy.example/rd/movie.mkv",
            name: "Movie (2020) · RD",
            description: "WEB-DL · 2160p · HEVC · 15 GB",
            addonName: "AIOStreams"
        )
        let torBox1080 = NuvioStream(
            url: "https://proxy.example/tb/movie.mkv",
            name: "Movie (2020) · TB",
            description: "WEB-DL · 1080p · HEVC · 6 GB",
            addonName: "AIOStreams"
        )

        let ranked = SmartPlaybackSelector.rankedStreams(
            from: [torBox1080, realDebrid4K],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(ranked.first?.id, realDebrid4K.id)
    }

    func testTopResultPoolMovesTorBoxAheadWithinResolutionOnly() {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.preferTorBoxStreams)
        defer { defaults.set(previous, forKey: SettingsKey.preferTorBoxStreams) }
        defaults.removeObject(forKey: SettingsKey.preferTorBoxStreams)

        let rd4K = NuvioStream(url: "https://p/1", name: "Movie · RD", description: "WEB-DL · 2160p", addonName: "A")
        let tb1080 = NuvioStream(url: "https://p/2", name: "Movie · TB", description: "BluRay · 1080p", addonName: "A")
        let rd1080 = NuvioStream(url: "https://p/3", name: "Movie · RD", description: "BluRay REMUX · 1080p", addonName: "A")
        let tb1080b = NuvioStream(url: "https://p/4", name: "Movie · TB", description: "WEB-DL · 1080p", addonName: "A")

        let reordered = SmartPlaybackSelector.preferringTorBox([rd4K, rd1080, tb1080, tb1080b])
        XCTAssertEqual(reordered.map(\.id), [rd4K.id, tb1080.id, tb1080b.id, rd1080.id])

        let aio1080 = NuvioStream(url: "https://p/5", name: "Movie · AIO", description: "BluRay REMUX · 1080p", addonName: "A")
        XCTAssertEqual(SmartPlaybackSelector.preferringTorBox([aio1080, rd4K, tb1080]).map(\.id), [aio1080.id, rd4K.id, tb1080.id])
        XCTAssertEqual(SmartPlaybackSelector.preferringTorBox([aio1080, rd1080, tb1080]).map(\.id), [tb1080.id, aio1080.id, rd1080.id])

        defaults.set(false, forKey: SettingsKey.preferTorBoxStreams)
        XCTAssertEqual(SmartPlaybackSelector.preferringTorBox([rd4K, rd1080, tb1080]).map(\.id), [rd4K.id, rd1080.id, tb1080.id])
    }

    func testRememberedMovieReleaseGivesWayToTorBoxButSeriesKeepsIt() {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.preferTorBoxStreams)
        defer { defaults.set(previous, forKey: SettingsKey.preferTorBoxStreams) }
        defaults.removeObject(forKey: SettingsKey.preferTorBoxStreams)

        let remembered = NuvioStream(url: "https://p/1", name: "Movie · RD", description: "BluRay REMUX · 1080p", addonName: "A")
        let tb1080 = NuvioStream(url: "https://p/2", name: "Movie · TB", description: "BluRay · 1080p", addonName: "A")
        let tb720 = NuvioStream(url: "https://p/3", name: "Movie · TB", description: "WEB-DL · 720p", addonName: "A")
        let pool = [remembered, tb1080, tb720]

        XCTAssertEqual(SmartPlaybackSelector.fasterEquivalent(of: remembered, in: pool, isSeries: false)?.id, tb1080.id)
        XCTAssertEqual(SmartPlaybackSelector.fasterEquivalent(of: remembered, in: pool, isSeries: true)?.id, remembered.id)
        XCTAssertEqual(SmartPlaybackSelector.fasterEquivalent(of: remembered, in: [remembered, tb720], isSeries: false)?.id, remembered.id)
        XCTAssertNil(SmartPlaybackSelector.fasterEquivalent(of: nil, in: pool, isSeries: false))
    }

    func testTorBoxNeverLiftsLowerResolutionUnderAnyPreference() {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.preferTorBoxStreams)
        defer { defaults.set(previous, forKey: SettingsKey.preferTorBoxStreams) }
        defaults.removeObject(forKey: SettingsKey.preferTorBoxStreams)

        let rd1080 = NuvioStream(url: "https://p/1", name: "Movie · RD", description: "BluRay · 1080p", addonName: "A")
        let tb720 = NuvioStream(url: "https://p/2", name: "Movie · TB", description: "WEB-DL · 720p", addonName: "A")
        for preference in ["Highest", "4K", "1080p"] {
            let ranked = SmartPlaybackSelector.rankedStreams(
                from: [tb720, rd1080],
                qualityPreference: preference,
                subtitleLanguages: [],
                shouldMatchSubtitles: false
            )
            XCTAssertEqual(ranked.first?.id, rd1080.id, preference)
        }
    }

    func testTorBoxDetectionIgnoresOtherServicesAndSizes() {
        XCTAssertTrue(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "Movie · TB", description: nil, addonName: "A")))
        XCTAssertTrue(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "[TB+] Movie 1080p", description: nil, addonName: "A")))
        XCTAssertTrue(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "Movie", description: "TorBox cached", addonName: "A")))
        XCTAssertFalse(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "Movie · RD", description: nil, addonName: "A")))
        XCTAssertFalse(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "Movie · AIO", description: nil, addonName: "A")))
        XCTAssertFalse(SmartPlaybackSelector.isTorBoxStream(NuvioStream(url: "https://x/a", name: "TBS Special 1080p", description: nil, addonName: "A")))
    }
}

final class HomeStreamAddonAutoHideTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HomeStreamAddonAutoHideTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStreamAddonIsHiddenWhenMetadataAddonSuppliesRows() {
        XCTAssertTrue(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aio", servesStreams: true, metadataOnlyAddonInstalled: true, in: store))
        XCTAssertEqual(TVHomeCatalogOrder.homeHiddenAddonIDs(in: store), ["aio"])
        XCTAssertFalse(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aio", servesStreams: true, metadataOnlyAddonInstalled: true, in: store))
    }

    func testStreamAddonKeepsRowsWithoutAMetadataAddon() {
        XCTAssertFalse(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aio", servesStreams: true, metadataOnlyAddonInstalled: false, in: store))
        XCTAssertTrue(TVHomeCatalogOrder.homeHiddenAddonIDs(in: store).isEmpty)
    }

    func testMetadataAddonIsNeverHidden() {
        XCTAssertFalse(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aiom", servesStreams: false, metadataOnlyAddonInstalled: true, in: store))
        XCTAssertTrue(TVHomeCatalogOrder.homeHiddenAddonIDs(in: store).isEmpty)
    }

    func testExplicitShowSurvivesLaterLoadsAndHideClearsIt() {
        TVHomeCatalogOrder.setHomeHidden(false, addonID: "aio", in: store)
        XCTAssertFalse(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aio", servesStreams: true, metadataOnlyAddonInstalled: true, in: store))
        XCTAssertTrue(TVHomeCatalogOrder.homeHiddenAddonIDs(in: store).isEmpty)

        TVHomeCatalogOrder.setHomeHidden(true, addonID: "aio", in: store)
        TVHomeCatalogOrder.setHomeHidden(false, addonID: "aio", in: store)
        TVHomeCatalogOrder.setHomeHidden(true, addonID: "aio", in: store)
        store.removeObject(forKey: SettingsKey.homeHiddenAddonIDs)
        XCTAssertTrue(TVHomeCatalogOrder.autoHideStreamAddonIfNeeded(
            addonID: "aio", servesStreams: true, metadataOnlyAddonInstalled: true, in: store))
    }
}
