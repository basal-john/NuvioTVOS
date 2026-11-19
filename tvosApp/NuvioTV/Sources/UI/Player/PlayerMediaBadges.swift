import SwiftUI

/// Resolution classes shown as vector badges.
enum PlayerResolutionBadge: String {
    case uhd = "4k", fullHD = "1080p", hd = "720p"

    init?(_ resolution: String) {
        let dimensions = resolution.split(whereSeparator: { "×xX".contains($0) })
        guard dimensions.count == 2,
              let width = Int(dimensions[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(dimensions[1].trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else { return nil }
        if width >= 3840 || height >= 2160 { self = .uhd }
        else if width >= 1920 && height <= 1080 { self = .fullHD }
        else if width >= 1280 && height <= 720 { self = .hd }
        else { return nil }
    }
}

/// Source dynamic range, including Dolby Vision streams with output fallback.
enum PlayerDynamicRangeBadge: String {
    case dolbyVision = "dv", hdr10Plus = "hdr10plus", hdr10, hlg, hdr, sdr

    init?(_ info: ScenePlaybackInfo) {
        let range = info.dynamicRange.uppercased()
        if info.dolbyVisionProfile != nil || range.contains("DOLBY VISION") { self = .dolbyVision }
        else if range.contains("HDR10+") { self = .hdr10Plus }
        else if range.contains("HDR10") || range.contains("PQ") { self = .hdr10 }
        else if range.contains("HLG") { self = .hlg }
        else if range.contains("HDR") { self = .hdr }
        else if range == "SDR" { self = .sdr }
        else { return nil }
    }
}

/// Video codec reported by the active engine.
enum PlayerVideoCodecBadge: String {
    case hevc, av1, h264

    init?(_ codec: String) {
        switch codec.lowercased() {
        case "hevc", "h265", "h.265": self = .hevc
        case "av1", "av01": self = .av1
        case "h264", "h.264", "avc", "avc1": self = .h264
        default: return nil
        }
    }
}

/// The spatial format takes precedence over the active track's base codec.
enum PlayerAudioBadge: String {
    case atmos, dtsx, truehd, ddplus, dd, dtshdma, dtshd, dts, flac, opus, aac

    init?(_ info: ScenePlaybackInfo) {
        let spatial = info.audioSpatialFormat.uppercased()
        if spatial.contains("ATMOS") {
            self = .atmos
            return
        }
        if spatial.contains("DTS:X") {
            self = .dtsx
            return
        }
        switch info.audioCodec.uppercased() {
        case "DTS:X": self = .dtsx
        case "TRUEHD": self = .truehd
        case "E-AC-3", "EAC3": self = .ddplus
        case "AC-3", "AC3": self = .dd
        case "DTS-HD MA": self = .dtshdma
        case "DTS-HD": self = .dtshd
        case "DTS": self = .dts
        case "FLAC": self = .flac
        case "OPUS": self = .opus
        case "AAC": self = .aac
        default: return nil
        }
    }
}

/// Channel layouts shown independently of codec or spatial format.
enum PlayerChannelBadge: String {
    case surround71 = "71", surround61 = "61", surround51 = "51", stereo = "20", mono = "10"

    init?(_ channels: String) {
        let layout = channels.lowercased().replacingOccurrences(of: " ", with: "")
        if layout.contains("7.1") || layout.range(of: #"(?<![0-9.])8ch"#, options: .regularExpression) != nil { self = .surround71 }
        else if layout.contains("6.1") || layout.range(of: #"(?<![0-9.])7ch"#, options: .regularExpression) != nil { self = .surround61 }
        else if layout.contains("5.1") || layout.range(of: #"(?<![0-9.])6ch"#, options: .regularExpression) != nil { self = .surround51 }
        else if layout.contains("2.0") || layout.contains("stereo") || layout.range(of: #"(?<![0-9.])2ch"#, options: .regularExpression) != nil { self = .stereo }
        else if layout.contains("1.0") || layout.contains("mono") || layout.range(of: #"(?<![0-9.])1ch"#, options: .regularExpression) != nil { self = .mono }
        else { return nil }
    }
}

/// Template artwork inherits the ink color of the surrounding player control.
struct PlayerBadgeImage: View {
    let asset: String
    var height: CGFloat = 21

    var body: some View {
        Image("PlayerBadge-\(asset)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .fixedSize()
    }
}
