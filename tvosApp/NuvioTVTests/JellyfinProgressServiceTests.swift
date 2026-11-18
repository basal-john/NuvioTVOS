import Foundation
import XCTest
@testable import NuvioTV

private final class JellyfinProgressMockProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockJellyfinCredentialStorage: JellyfinCredentialStorage {
    var tokens: [String: String] = [:]

    func token(forServerID serverID: String, profileScope: String) -> String? {
        tokens["\(serverID).\(profileScope)"]
    }

    @discardableResult
    func save(_ token: String, forServerID serverID: String, profileScope: String) -> Bool {
        tokens["\(serverID).\(profileScope)"] = token
        return true
    }

    @discardableResult
    func remove(forServerID serverID: String, profileScope: String) -> Bool {
        tokens.removeValue(forKey: "\(serverID).\(profileScope)")
        return true
    }
}

private final class StubProgressCatalogRepository: MockCatalogRepository {
    var customMeta: [String: NuvioMeta] = [:]

    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let custom = customMeta[id] {
            return custom
        }
        return NuvioMeta(
            id: id,
            name: "Resolved \(id)",
            description: "Description for \(id)",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: "https://example.com/backdrop.jpg",
            type: type,
            runtime: type == "movie" ? "100 min" : "45 min"
        )
    }
}

@MainActor
final class JellyfinProgressServiceTests: XCTestCase {
    private var session: URLSession!
    private var testProfileID = ""
    private var previousProfileID: String?
    private var previousProfileIsPrimary = false
    private var previousCredentialStorage: JellyfinCredentialStorage!
    private var mockCredentials: MockJellyfinCredentialStorage!
    private let baseURLString = "http://127.0.0.1:8096"
    private let serverID = "aiofin-test-1"
    private let userID = "user-abc"

    override func setUp() {
        super.setUp()
        previousProfileID = ProfileSettings.activeProfileID
        previousProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousCredentialStorage = JellyfinCredentialStore.storage

        mockCredentials = MockJellyfinCredentialStorage()
        JellyfinCredentialStore.storage = mockCredentials

        testProfileID = "jf-progress-test-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(testProfileID, isPrimary: false)
        JellyfinServerStore.shared.reload()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinProgressMockProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        JellyfinProgressMockProtocol.requestHandler = nil
        session = nil
        for server in JellyfinServerStore.shared.servers {
            JellyfinServerStore.shared.remove(server.id)
        }
        JellyfinCredentialStore.storage = previousCredentialStorage
        if let previousProfileID {
            ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileID)")
        super.tearDown()
    }

    func testAvailabilityAccountBindingAndNuvioSyncOwnership() {
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "AioFin",
            baseURLString: baseURLString,
            authKind: .apiKey,
            username: "",
            userId: userID
        )
        JellyfinServerStore.shared.upsert(server)
        ProfileSettings.current.set(TraktWatchProgressSource.jellyfin.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertFalse(JellyfinProgressService.isAvailable(in: ProfileSettings.current))
        XCTAssertNil(JellyfinProgressService.accountBindingID(in: ProfileSettings.current))
        XCTAssertTrue(NuvioSyncManager.ownsWatchState(for: testProfileID))

        JellyfinCredentialStore.save("token-xyz", forServerID: serverID, profileScope: testProfileID)

        XCTAssertTrue(JellyfinProgressService.isAvailable(in: ProfileSettings.current))
        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.jellyfin, in: ProfileSettings.current))
        XCTAssertEqual(JellyfinProgressService.accountBindingID(in: ProfileSettings.current), "jellyfin:\(serverID):\(userID)")
        XCTAssertFalse(NuvioSyncManager.ownsWatchState(for: testProfileID))

        let otherStore = UserDefaults(suiteName: "nuvio.tv.profile.settings.other-\(UUID().uuidString)")!
        XCTAssertFalse(JellyfinProgressService.isAvailable(in: otherStore, profileScope: testProfileID))
    }

    func testBuildContinueWatchingSeedsExtractsParentSeriesIDsAndDedupesResumeOverNextUp() {
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "AioFin",
            baseURLString: baseURLString,
            authKind: .apiKey,
            username: "",
            userId: userID
        )
        let target = JellyfinProgressService.AccountTarget(
            server: server,
            baseURL: URL(string: baseURLString)!,
            accessToken: "token-xyz"
        )

        let resumeEp = episodeItem(
            id: "ep-good-s1e4",
            name: "Chapter Four",
            seriesId: "series-good",
            seriesName: "The Good Daughter",
            season: 1,
            episode: 4,
            playbackPositionTicks: 15_000_000_000,
            runTimeTicks: 30_000_000_000,
            lastPlayedDate: "2026-11-17T20:00:00Z"
        )
        let duplicateNextUpEp = episodeItem(
            id: "ep-good-s1e5",
            name: "Chapter Five",
            seriesId: "series-good",
            seriesName: "The Good Daughter",
            season: 1,
            episode: 5,
            playbackPositionTicks: 0,
            runTimeTicks: 30_000_000_000,
            lastPlayedDate: nil
        )
        let yagaNextUpEp = episodeItem(
            id: "ep-yaga-s1e5",
            name: "Episode 5",
            seriesId: "series-yaga",
            seriesName: "YAGA",
            season: 1,
            episode: 5,
            playbackPositionTicks: 0,
            runTimeTicks: 27_000_000_000,
            lastPlayedDate: "2026-11-16T18:00:00Z"
        )

        let seriesByID: [String: JellyfinMediaItem] = [
            "series-good": seriesItem(id: "series-good", name: "The Good Daughter", imdbId: "tt31842126", tmdbId: nil, year: 2026),
            "series-yaga": seriesItem(id: "series-yaga", name: "YAGA", imdbId: nil, tmdbId: 290123, year: 2026)
        ]

        let seeds = JellyfinProgressService.buildContinueWatchingSeeds(
            resumeItems: [resumeEp],
            nextUpItems: [duplicateNextUpEp, yagaNextUpEp],
            seriesByID: seriesByID,
            target: target
        )

        XCTAssertEqual(seeds.count, 2)
        XCTAssertEqual(seeds[0].canonicalID, "tt31842126")
        XCTAssertEqual(seeds[0].title, "The Good Daughter")
        XCTAssertEqual(seeds[0].season, 1)
        XCTAssertEqual(seeds[0].episode, 4)
        XCTAssertFalse(seeds[0].isUpNext)
        XCTAssertEqual(seeds[0].positionTicks, 15_000_000_000)

        XCTAssertEqual(seeds[1].canonicalID, "tmdb:290123")
        XCTAssertEqual(seeds[1].title, "YAGA")
        XCTAssertEqual(seeds[1].season, 1)
        XCTAssertEqual(seeds[1].episode, 5)
        XCTAssertTrue(seeds[1].isUpNext)
    }

    func testFetchContinueWatchingFetchesSeriesParentMetadataWithoutAnyProviderIdEquals() async {
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "AioFin",
            baseURLString: baseURLString,
            authKind: .apiKey,
            username: "",
            userId: userID
        )
        JellyfinServerStore.shared.upsert(server)
        JellyfinCredentialStore.save("token-xyz", forServerID: serverID, profileScope: testProfileID)
        ProfileSettings.current.set(TraktWatchProgressSource.jellyfin.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        var seenURLs: [String] = []
        JellyfinProgressMockProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            seenURLs.append(urlString)
            XCTAssertFalse(urlString.contains("AnyProviderIdEquals"), "AioFin ignores AnyProviderIdEquals; must never be sent")

            let path = request.url?.path ?? ""
            let payload: String
            if path.hasSuffix("/Items/Resume") {
                payload = """
                {
                  "Items": [{
                    "Id": "ep-good-4",
                    "Name": "Chapter Four",
                    "Type": "Episode",
                    "SeriesId": "series-good",
                    "SeriesName": "The Good Daughter",
                    "ParentIndexNumber": 1,
                    "IndexNumber": 4,
                    "RunTimeTicks": 30000000000,
                    "UserData": { "PlaybackPositionTicks": 12000000000, "Played": false, "LastPlayedDate": "2026-11-17T19:00:00Z" }
                  }],
                  "TotalRecordCount": 1
                }
                """
            } else if path.hasSuffix("/Shows/NextUp") {
                payload = """
                {
                  "Items": [{
                    "Id": "ep-yaga-5",
                    "Name": "YAGA E5",
                    "Type": "Episode",
                    "SeriesId": "series-yaga",
                    "SeriesName": "YAGA",
                    "ParentIndexNumber": 1,
                    "IndexNumber": 5,
                    "RunTimeTicks": 27000000000
                  }],
                  "TotalRecordCount": 1
                }
                """
            } else if path.hasSuffix("/Users/\(self.userID)/Items") {
                payload = """
                {
                  "Items": [
                    { "Id": "series-good", "Name": "The Good Daughter", "Type": "Series", "ProductionYear": 2026, "ProviderIds": { "Imdb": "tt31842126" } },
                    { "Id": "series-yaga", "Name": "YAGA", "Type": "Series", "ProductionYear": 2026, "ProviderIds": { "Imdb": "tt39980704" } }
                  ],
                  "TotalRecordCount": 2
                }
                """
            } else {
                XCTFail("Unexpected request: \(urlString)")
                payload = "{}"
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(payload.utf8))
        }

        let repo = StubProgressCatalogRepository()
        let items = await JellyfinProgressService.fetchContinueWatching(
            repository: repo,
            store: ProfileSettings.current,
            urlSession: session
        )

        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].meta.id, "tt31842126")
        XCTAssertEqual(items?[0].season, 1)
        XCTAssertEqual(items?[0].episode, 4)
        XCTAssertEqual(items?[0].position ?? 0, 1200, accuracy: 0.1)
        XCTAssertEqual(items?[0].isUpNext, false)
        XCTAssertEqual(items?[1].meta.id, "tt39980704")
        XCTAssertEqual(items?[1].isUpNext, true)
    }

    func testRemovePlaybackResolvesSeriesViaSearchAndClearsResumeAndUserData() async {
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "AioFin",
            baseURLString: baseURLString,
            authKind: .apiKey,
            username: "",
            userId: userID
        )
        JellyfinServerStore.shared.upsert(server)
        JellyfinCredentialStore.save("token-xyz", forServerID: serverID, profileScope: testProfileID)
        ProfileSettings.current.set(TraktWatchProgressSource.jellyfin.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        var stoppedCalled = false
        var userDataCleared = false
        JellyfinProgressMockProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            XCTAssertFalse(urlString.contains("AnyProviderIdEquals"))
            let path = request.url?.path ?? ""

            if path.hasSuffix("/Users/\(self.userID)/Items") {
                let payload = """
                { "Items": [{ "Id": "series-phony", "Name": "Phony", "Type": "Series", "ProviderIds": { "Imdb": "tt21952924" } }], "TotalRecordCount": 1 }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(payload.utf8))
            } else if path.hasSuffix("/Shows/series-phony/Episodes") {
                let payload = """
                { "Items": [{ "Id": "ep-phony-4", "Name": "Ep 4", "Type": "Episode", "SeriesId": "series-phony", "ParentIndexNumber": 1, "IndexNumber": 4 }], "TotalRecordCount": 1 }
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(payload.utf8))
            } else if path.hasSuffix("/Sessions/Playing/Stopped") {
                stoppedCalled = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else if path.hasSuffix("/Users/\(self.userID)/Items/ep-phony-4/UserData") {
                userDataCleared = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{}".utf8))
            }

            XCTFail("Unexpected request: \(urlString)")
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let item = ContinueWatchingItem(
            meta: NuvioMeta(id: "tt21952924", name: "Phony", type: "series"),
            streamUrl: "",
            position: 600,
            duration: 2400,
            lastWatchedAt: Date(),
            season: 1,
            episode: 4,
            isUpNext: false
        )

        let removed = await JellyfinProgressService.removePlayback(
            for: item,
            store: ProfileSettings.current,
            urlSession: session
        )

        XCTAssertTrue(removed)
        XCTAssertTrue(stoppedCalled)
        XCTAssertTrue(userDataCleared)
    }

    private func seriesItem(id: String, name: String, imdbId: String?, tmdbId: Int?, year: Int?) -> JellyfinMediaItem {
        JellyfinMediaItem(
            id: id,
            name: name,
            type: "Series",
            overview: nil,
            productionYear: year,
            premiereDate: nil,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            runTimeTicks: nil,
            imdbId: imdbId,
            tmdbId: tmdbId,
            primaryImageTag: nil,
            backdropImageTag: nil,
            cast: nil,
            directors: nil,
            seriesId: nil,
            parentIndexNumber: nil,
            indexNumber: nil,
            container: nil,
            sizeBytes: nil,
            seriesName: nil,
            userData: nil
        )
    }

    private func episodeItem(
        id: String,
        name: String,
        seriesId: String,
        seriesName: String,
        season: Int,
        episode: Int,
        playbackPositionTicks: Int64,
        runTimeTicks: Int64,
        lastPlayedDate: String?
    ) -> JellyfinMediaItem {
        JellyfinMediaItem(
            id: id,
            name: name,
            type: "Episode",
            overview: nil,
            productionYear: nil,
            premiereDate: nil,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            runTimeTicks: runTimeTicks,
            imdbId: nil,
            tmdbId: nil,
            primaryImageTag: nil,
            backdropImageTag: nil,
            cast: nil,
            directors: nil,
            seriesId: seriesId,
            parentIndexNumber: season,
            indexNumber: episode,
            container: nil,
            sizeBytes: nil,
            seriesName: seriesName,
            userData: JellyfinUserItemData(
                playbackPositionTicks: playbackPositionTicks,
                played: false,
                lastPlayedDate: lastPlayedDate,
                playCount: nil
            )
        )
    }
}
