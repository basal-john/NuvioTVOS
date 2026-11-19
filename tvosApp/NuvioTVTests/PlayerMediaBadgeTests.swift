import AetherEngine
import XCTest
@testable import NuvioTV

@MainActor
final class PlayerMediaBadgeTests: XCTestCase {
    func testMPVCodecDescriptionReportsAtmosAndClearsItOnAudioSwitch() {
        let atmos = MPVPlayerViewController.audioSpatialFormat(profile: "Dolby Digital Plus", description: "E-AC-3 JOC")
        XCTAssertEqual(atmos, "Atmos")
        XCTAssertEqual(MPVPlayerViewController.audioSpatialFormat(profile: nil, description: "TrueHD + Dolby Atmos"), "Atmos")
        XCTAssertEqual(MPVPlayerViewController.audioSpatialFormat(profile: "DTS:X", description: nil), "DTS:X")
        let initial = telemetry(engine: "MPVKit", codec: "eac3", channels: 8, spatial: atmos)
        let switched = telemetry(engine: "MPVKit", codec: "ac3", channels: 6, spatial: nil)
        let commentary = telemetry(engine: "MPVKit", codec: "aac", channels: 2, spatial: nil)

        XCTAssertEqual(initial.audioBadge, .atmos)
        XCTAssertEqual(initial.channelBadge, .surround71)
        XCTAssertEqual(switched.audioBadge, .dd)
        XCTAssertEqual(switched.channelBadge, .surround51)
        XCTAssertEqual(commentary.audioBadge, .aac)
        XCTAssertEqual(commentary.channelBadge, .stereo)
    }

    func testAetherUsesActiveDTSProfileAndIgnoresOutgoingAtmosOnAAC() {
        let dts = TrackInfo(id: 2, name: "Original", codec: "dts", language: "en",
                            channels: 8, isDefault: true, profile: "DTS-HD MA")
        let aac = TrackInfo(id: 3, name: "Commentary", codec: "aac", language: "en",
                            channels: 2, isDefault: false, profile: nil)
        let source = AetherPlaybackController.audioSourceDiagnostics(for: dts, activeDecoder: nil)
        let switched = AetherPlaybackController.audioSourceDiagnostics(for: aac, activeDecoder: "TrueHD Atmos")
        let initial = telemetry(engine: "AetherEngine", codec: source.codec, channels: source.channels, spatial: source.spatialFormat)
        let commentary = telemetry(engine: "AetherEngine", codec: switched.codec, channels: switched.channels, spatial: switched.spatialFormat)

        XCTAssertEqual(initial.audioBadge, .dtshdma)
        XCTAssertEqual(initial.channelBadge, .surround71)
        XCTAssertEqual(initial.videoBadge, .av1)
        XCTAssertEqual(initial.rangeBadge, .hdr10Plus)
        XCTAssertEqual(commentary.audioBadge, .aac)
        XCTAssertEqual(commentary.channelBadge, .stereo)
        XCTAssertEqual(PlayerAudioBadge(ScenePlaybackInfo(audioCodec: "DTS-HD")), .dtshd)
    }

    func testResolutionDynamicRangeAndChannelsUseLiveFields() {
        XCTAssertEqual(PlayerResolutionBadge("3840 × 1600"), .uhd)
        XCTAssertEqual(PlayerResolutionBadge("1920 × 800"), .fullHD)
        XCTAssertEqual(PlayerResolutionBadge("1280 × 720"), .hd)
        XCTAssertEqual(PlayerDynamicRangeBadge(ScenePlaybackInfo(dynamicRange: "HDR10+", dolbyVisionProfile: "8")), .dolbyVision)
        XCTAssertEqual(PlayerDynamicRangeBadge(ScenePlaybackInfo(dynamicRange: "PQ")), .hdr10)
        XCTAssertEqual(PlayerDynamicRangeBadge(ScenePlaybackInfo(dynamicRange: "HLG")), .hlg)
        XCTAssertEqual(PlayerDynamicRangeBadge(ScenePlaybackInfo(dynamicRange: "HDR")), .hdr)
        XCTAssertEqual(PlayerDynamicRangeBadge(ScenePlaybackInfo(dynamicRange: "SDR")), .sdr)
        XCTAssertEqual(PlayerVideoCodecBadge("av01"), .av1)
        XCTAssertEqual(PlayerVideoCodecBadge("avc"), .h264)
        XCTAssertEqual(PlayerChannelBadge("Surround (7 ch)"), .surround61)
        XCTAssertEqual(PlayerChannelBadge("Mono (1ch)"), .mono)
        XCTAssertNil(PlayerChannelBadge("Surround (12 ch)"))
    }

    func testUnknownTelemetryDoesNotInferBadgesFromSourceName() {
        let missing = PlayerTelemetry(filename: "Show.2160p.HDR10.Atmos.71.mkv", streamTitle: "4K DV HEVC")
        XCTAssertNil(missing.resolutionBadge)
        XCTAssertNil(missing.rangeBadge)
        XCTAssertNil(missing.videoBadge)
        XCTAssertNil(missing.audioBadge)
        XCTAssertNil(missing.channelBadge)
        XCTAssertNil(missing.fileSize)
    }

    func testParseFileSizeExtractsHumanReadableSizeFromStreamMetadata() {
        XCTAssertEqual(
            PlayerTelemetry.parseFileSize(from: "M&Ms | TweakApps · WEB-DL · 2160p · 10bit · DD+ 5.1 · Kitsune · 20.7 GB"),
            "20.7 GB"
        )
        XCTAssertEqual(PlayerTelemetry.parseFileSize(from: "Remux · 4,52 GiB · Atmos"), "4.52 GB")
        XCTAssertEqual(PlayerTelemetry.parseFileSize(from: "720p · 850MB"), "850 MB")
        XCTAssertNil(PlayerTelemetry.parseFileSize(from: "WEB-DL · 2160p · DD+ 5.1"))

        let withFallback = PlayerTelemetry(fileSize: nil, fallbackFileSizeText: "20.7 GB")
        XCTAssertEqual(withFallback.fileSize, "20.7 GB")
    }

    func testBestMatchingSourceIDHandlesRotatedResolveURLsAndQueryTokens() {
        let kitsune = NuvioStream(
            url: "https://aio.example.com/resolve/fresh-token-1/stream",
            name: "Gentle Monster (2026) · AIO",
            description: "M&Ms | TweakApps · WEB-DL · 2160p · 10bit · DD+ 5.1 · Kitsune · 20.7 GB",
            addonName: "AIO",
            filename: "Gentle.Monster.2026.2160p.WEB-DL.DDP5.1.H.265-Kitsune.mkv"
        )
        let playWeb = NuvioStream(
            url: "https://aio.example.com/resolve/fresh-token-2/stream",
            name: "Gentle Monster (2026) · AIO",
            description: "M&Ms | TweakApps · WEB-DL · 2160p · DD+ 5.1 · playWEB · 22.4 GB",
            addonName: "AIO",
            filename: "Gentle.Monster.2026.2160p.WEB-DL.DDP5.1.H.265-playWEB.mkv"
        )
        let jellyfin = NuvioStream(
            url: "https://jf.example.com/Videos/abc123/stream?Static=true&PlaySessionId=new-session",
            name: "AioFin",
            description: "4K SDR",
            addonName: "Jellyfin"
        )

        // Rotated AIOStreams resolve token falls back cleanly to exact filename match.
        let matchedAIO = PlayerViewModel.bestMatchingSourceID(
            in: [kitsune, playWeb],
            activeSourceID: "https://aio.example.com/resolve/stale-token-999/stream",
            activeStreamURL: "https://cdn.torbox.app/dl/abc/Gentle.Monster.2026.2160p.WEB-DL.DDP5.1.H.265-Kitsune.mkv",
            activeFilename: "Gentle.Monster.2026.2160p.WEB-DL.DDP5.1.H.265-Kitsune.mkv",
            activeVideoHash: nil,
            activeVideoSize: nil,
            activeCacheFileIdentity: nil
        )
        XCTAssertEqual(matchedAIO, kitsune.id)

        // Volatile Jellyfin PlaySessionId query param still matches the normalized URL path.
        let matchedJF = PlayerViewModel.bestMatchingSourceID(
            in: [kitsune, jellyfin],
            activeSourceID: nil,
            activeStreamURL: "https://jf.example.com/Videos/abc123/stream?Static=true&PlaySessionId=old-session",
            activeFilename: nil,
            activeVideoHash: nil,
            activeVideoSize: nil,
            activeCacheFileIdentity: nil
        )
        XCTAssertEqual(matchedJF, jellyfin.id)
    }

    func testSwipeDownWhileControlsVisibleDoesNotOpenSceneInfo() {
        let vm = PlayerViewModel()
        vm.status = .playing
        vm.showControls = true
        vm.showScenePanel = false
        XCTAssertTrue(vm.isSceneEnabled)

        vm.remoteTouchBegan()
        vm.remoteTouchMoved(dx: 0, dy: 40)

        XCTAssertFalse(vm.showScenePanel)
        XCTAssertTrue(vm.showControls)
    }

    private func telemetry(engine: String, codec: String?, channels: Int?, spatial: String?) -> PlayerTelemetry {
        PlayerTelemetry(
            info: ScenePlaybackInfo(
                engine: engine,
                videoCodec: "AV1",
                resolution: "3840 × 2160",
                dynamicRange: "HDR10+",
                audioCodec: codec ?? "—",
                audioChannels: channels.map { "\($0)ch" } ?? "—",
                audioSpatialFormat: spatial ?? "—"
            )
        )
    }
}
