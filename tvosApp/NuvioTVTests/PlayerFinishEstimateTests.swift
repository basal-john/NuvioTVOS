import XCTest
@testable import NuvioTV

final class PlayerFinishEstimateTests: XCTestCase {
    func testEstimateUsesRemainingDurationAndPlaybackSpeed() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 600, duration: 4_200, speed: 1), now.addingTimeInterval(3_600))
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 600, duration: 4_200, speed: 2), now.addingTimeInterval(1_800))
    }

    func testEstimateRejectsUnknownOrInvalidTimes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: 0, duration: 0, speed: 1))
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: .nan, duration: 60, speed: 1))
        XCTAssertNil(PlayerFinishEstimate.date(now: now, position: 0, duration: 60, speed: 0))
        XCTAssertEqual(PlayerFinishEstimate.date(now: now, position: 80, duration: 60, speed: 1), now)
    }
}

final class PlayerTelemetryTests: XCTestCase {
    func testActiveStreamSummaryUsesReportedMediaAndVoiceMode() {
        let info = ScenePlaybackInfo(
            engine: "MPVKit", videoCodec: "HEVC", resolution: "3840 × 2160",
            dynamicRange: "Dolby Vision", dolbyVisionProfile: "8",
            videoBitrate: "24.8 Mbps", container: "matroska,webm", videoDecoder: "VideoToolbox HEVC (HW)",
            audioCodec: "DD+", audioChannels: "5.1", audioLanguage: "en", audioSpatialFormat: "Atmos"
        )
        let telemetry = PlayerTelemetry(
            info: info, filename: "Show.S02E05.2160p.WEB-DL.mkv", fileSize: 14_800_000_000, dialogueEnhanced: true
        )

        XCTAssertEqual(telemetry.resolution, "4K")
        XCTAssertEqual(telemetry.quality, "4K DV P8")
        XCTAssertEqual(telemetry.fileType, "MKV · HEVC · WEB-DL")
        XCTAssertEqual(telemetry.audio, "EN · DD+ 5.1 Atmos · Dialogue+")
        XCTAssertEqual(telemetry.audioValue, "Atmos")
        XCTAssertEqual(telemetry.fileSize, ByteCountFormatter.string(fromByteCount: 14_800_000_000, countStyle: .file))
        XCTAssertEqual(telemetry.bitrate, "24.8 Mbps")
        XCTAssertEqual(telemetry.engine, "MPV · HW")
    }

    func testReleaseParsingPrefersFilenameAndRejectsSubstringMatches() {
        XCTAssertEqual(PlayerTelemetry(filename: "Movie.BluRay.Remux.webm", streamTitle: "WEB-DL").fileType, "WEBM · Remux")
        XCTAssertEqual(PlayerTelemetry(streamTitle: "Film · web_dl").fileType, "WEB-DL")
        XCTAssertNil(PlayerTelemetry(filename: "Notaremux", streamTitle: "SomeWEBRip").fileType)
    }

    func testMissingFieldsAndUnknownAudioAreOmitted() {
        let info = ScenePlaybackInfo(audioLanguage: "und")
        let telemetry = PlayerTelemetry(info: info, fileSize: -1, nightMode: true)

        XCTAssertNil(telemetry.quality)
        XCTAssertNil(telemetry.fileType)
        XCTAssertNil(telemetry.audio)
        XCTAssertNil(telemetry.audioValue)
        XCTAssertNil(telemetry.fileSize)
        XCTAssertNil(telemetry.bitrate)
        XCTAssertNil(telemetry.engine)
    }

    func testAvailableAudioCanReportNightOrDirect() {
        let info = ScenePlaybackInfo(audioCodec: "TrueHD", audioChannels: "7.1")
        XCTAssertEqual(PlayerTelemetry(info: info, nightMode: true).audio, "TrueHD 7.1 · Night")
        XCTAssertEqual(PlayerTelemetry(info: info).audio, "TrueHD 7.1 · Direct")
    }
}
