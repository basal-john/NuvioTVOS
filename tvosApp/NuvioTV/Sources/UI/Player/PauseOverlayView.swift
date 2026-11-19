import SwiftUI

extension Color {
    static let playerGlassInk = Color(red: 8 / 255, green: 9 / 255, blue: 12 / 255)
}

/// A monochrome surface shared by stationary player chrome, with a material fallback for older tvOS.
struct PlayerGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var filled = false
    var darkOpacity: Double = 0.28

    func body(content: Content) -> some View {
        content.background {
            if filled {
                shape.fill(.white)
            } else if #available(tvOS 26.0, *) {
                shape.fill(.black.opacity(darkOpacity))
                    .overlay { shape.fill(.white.opacity(0.08)) }
                    .glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(.black.opacity(darkOpacity + 0.12)) }
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false) }
    }
}

/// Compact, display-ready technical data for the active stream. Absent metadata leaves no empty fields.
struct PlayerTelemetry: Equatable {
    let resolutionBadge: PlayerResolutionBadge?
    let rangeBadge: PlayerDynamicRangeBadge?
    let videoBadge: PlayerVideoCodecBadge?
    let audioBadge: PlayerAudioBadge?
    let channelBadge: PlayerChannelBadge?
    let dynamicRange: String?
    let videoStream: String?
    let audioPipeline: String?
    let resolution: String?
    let quality: String?
    let fileType: String?
    let audio: String?
    let audioValue: String?
    let fileSize: String?
    let bitrate: String?
    let buffer: String?
    let engine: String?

    init(
        info: ScenePlaybackInfo = ScenePlaybackInfo(), filename: String? = nil, streamTitle: String? = nil,
        fileSize: Int64? = nil, bufferedAhead: Double? = nil, dialogueEnhanced: Bool = false, nightMode: Bool = false
    ) {
        resolutionBadge = PlayerResolutionBadge(info.resolution)
        rangeBadge = PlayerDynamicRangeBadge(info)
        videoBadge = PlayerVideoCodecBadge(info.videoCodec)
        audioBadge = PlayerAudioBadge(info)
        channelBadge = PlayerChannelBadge(info.audioChannels)
        self.dynamicRange = Self.join([Self.value(info.dynamicRange), Self.value(info.dolbyVisionProfile).map { "Profile \($0)" }])
        videoStream = Self.join([Self.join([Self.value(info.videoCodec), Self.value(info.resolution)], separator: " "),
                                 Self.value(info.frameRate)])
        audioPipeline = Self.value(info.audioDecoder)
        resolution = Self.resolutionLabel(info.resolution)
        let dynamicRange = Self.value(info.dynamicRange)?.replacingOccurrences(of: "Dolby Vision", with: "DV")
        let profile = Self.value(info.dolbyVisionProfile).map { "P\($0)" }
        quality = Self.join([resolution, dynamicRange, profile], separator: " ")
        let extensionLabel = filename.map { ($0 as NSString).pathExtension.uppercased() }
        let knownContainers = ["MKV", "WEBM", "MP4", "M4V", "MOV", "TS", "M2TS", "AVI", "ISO"]
        let container = extensionLabel.flatMap { knownContainers.contains($0) ? $0 : nil }
            ?? Self.value(info.container).map { value in
                switch value {
                case "matroska,webm": "MKV"
                case "quicktime,mov,mp4,m4a,3gp,3g2,mj2": "MP4"
                case "hls,applehttp": "HLS"
                default: value.uppercased()
                }
            }
        fileType = Self.join([container, Self.value(info.videoCodec), Self.releaseType(filename, streamTitle)])
        let language = Self.language(info.audioLanguage)
        let codec = Self.value(info.audioCodec).map { codec in
            switch codec {
            case "E-AC-3": "DD+"
            case "AC-3": "DD"
            case "TRUEHD": "TrueHD"
            default: codec
            }
        }
        let channels = Self.value(info.audioChannels).map { channels in
            if channels.hasPrefix("Mono") { return "Mono" }
            if channels.hasPrefix("Stereo") { return "Stereo" }
            return channels.split(separator: "(").last.map {
                $0.replacingOccurrences(of: "ch)", with: "")
            } ?? channels
        }
        let spatial = Self.value(info.audioSpatialFormat).map {
            $0.localizedCaseInsensitiveContains("Atmos") ? "Atmos" : $0
        }
        let format = Self.join([codec, channels, spatial], separator: " ")
        let voice = dialogueEnhanced ? "Dialogue+" : (nightMode ? "Night" : "Direct")
        audio = format != nil || language != nil ? Self.join([language, format, voice]) : nil
        audioValue = spatial ?? channels ?? language
        self.fileSize = fileSize.flatMap {
            $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil
        }
        bitrate = Self.value(info.videoBitrate)
        buffer = bufferedAhead.flatMap {
            $0.isFinite ? $0.formatted(.number.precision(.fractionLength(1))) + " s ahead" : nil
        }
        switch info.engine {
        case "MPVKit":
            engine = info.videoDecoder.localizedCaseInsensitiveContains("(HW)") ? "MPV · HW" : "MPV"
        case "AetherEngine":
            engine = "Aether"
        default:
            engine = Self.value(info.engine)
        }
    }

    static func join(_ parts: [String?], separator: String = " · ") -> String? {
        let values = parts.compactMap(value)
        return values.isEmpty ? nil : values.joined(separator: separator)
    }

    static func language(_ raw: String?) -> String? {
        guard let code = value(raw), code.caseInsensitiveCompare("und") != .orderedSame else { return nil }
        let language = Locale.Language(identifier: code)
        return language.languageCode?.identifier.uppercased()
    }

    private static func value(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !["", "—", "--", "unknown", "unavailable", "not confirmed"].contains(value.lowercased()) else { return nil }
        return value
    }

    private static func resolutionLabel(_ raw: String) -> String? {
        let parts = raw.split(whereSeparator: { $0 == "×" || $0 == "x" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
            let (width, height) = (parts[0], parts[1])
            if width >= 7680 || height >= 4320 { return "8K" }
            if width >= 3840 || height >= 2160 { return "4K" }
            if width >= 1920 && height <= 1080 { return "1080p" }
            return height > 0 ? "\(height)p" : nil
        }
        return value(raw)
    }

    private static func releaseType(_ filename: String?, _ streamTitle: String?) -> String? {
        for label in [filename, streamTitle].compactMap(value) {
            for (pattern, type) in [
                ("remux", "Remux"), ("web[ ._-]?dl", "WEB-DL"), ("web[ ._-]?rip", "WEBRip"),
                ("blu[ ._-]?ray", "BluRay"), ("hdrip", "HDRip"), ("hdtv", "HDTV")
            ] where label.range(of: "(?<![A-Za-z0-9])\(pattern)(?![A-Za-z0-9])",
                                options: [.regularExpression, .caseInsensitive]) != nil {
                return type
            }
        }
        return nil
    }
}

/// Playing-version capsule and estimated finish clock, shared by playback and pause.
struct PlayerTelemetryBar: View {
    @ObservedObject var viewModel: PlayerViewModel
    let showsFinishTime: Bool
    var isPauseCard = false

    var body: some View {
        let telemetry = viewModel.playerTelemetry
        let quality = [telemetry.resolutionBadge?.rawValue, telemetry.rangeBadge?.rawValue].compactMap { $0 }
        let audio = [telemetry.channelBadge?.rawValue, telemetry.audioBadge?.rawValue].compactMap { $0 }

        HStack(alignment: .top, spacing: 25) {
            if !quality.isEmpty || telemetry.videoBadge != nil || !audio.isEmpty || telemetry.fileSize != nil {
                HStack(spacing: 12) {
                    if !quality.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(quality, id: \.self) { PlayerBadgeImage(asset: $0) }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.playerGlassInk)
                        .background(.white, in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(telemetry.quality ?? "")
                    }
                    if let codec = telemetry.videoBadge {
                        PlayerBadgeImage(asset: codec.rawValue)
                            .accessibilityLabel(codec.rawValue.uppercased())
                    }
                    if !audio.isEmpty {
                        if !quality.isEmpty || telemetry.videoBadge != nil { divider }
                        HStack(spacing: 10) {
                            ForEach(audio, id: \.self) { PlayerBadgeImage(asset: $0) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(telemetry.audio ?? "")
                    }
                    if let size = telemetry.fileSize {
                        if !quality.isEmpty || telemetry.videoBadge != nil || !audio.isEmpty { divider }
                        Text(size)
                    }
                }
                .font(.system(size: 17, weight: .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .modifier(PlayerGlassSurface(shape: Capsule()))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            if showsFinishTime && !viewModel.isLiveStream {
                PlayerEstimatedFinishTime(
                    clock: viewModel.clock, playbackSpeed: Double(viewModel.playbackSpeed.rawValue),
                    status: viewModel.status, isScrubbing: viewModel.isScrubbing,
                    pendingSeekDelta: viewModel.pendingSeekDelta, isPauseCard: isPauseCard
                )
                .fixedSize()
            }
        }
        .foregroundStyle(.white)
    }
    private var divider: some View {
        Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 19)
            .accessibilityHidden(true)
    }
}

/// Editorial metadata and the primary Resume action shown after the configured pause delay.
struct PauseOverlayView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    var onResume: () -> Void
    var onMove: (MoveCommandDirection) -> Void
    var onExit: () -> Void

    @FocusState private var resumeFocused: Bool
    @AppStorage(SettingsKey.playerShowFinishTime) private var playerShowFinishTime = true

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.16), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            PlayerTelemetryBar(viewModel: viewModel, showsFinishTime: playerShowFinishTime, isPauseCard: true)
                .padding(.top, 50)
                .padding(.horizontal, 60)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 28) {
                metadataCard.allowsHitTesting(false)
                Spacer(minLength: 0)
                resumeControl
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 54)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .focusSection()
        .defaultFocus($resumeFocused, true)
        .onAppear { resumeFocused = true }
        .onMoveCommand(perform: onMove)
        .onExitCommand(perform: onExit)
    }

    private var metadataCard: some View {
        let meta = viewModel.activeMeta
        let metadata = PlayerTelemetry.join([meta?.year.map(String.init), meta?.certification,
                                            meta?.genres?.prefix(3).joined(separator: ", ")])
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 19) {
                CachedPosterArtwork(urlString: meta?.posterUrl, width: 108, height: 162, maximumWidth: 500) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.09))
                        .overlay { Image(systemName: "film").font(.system(size: 32)).foregroundStyle(.white.opacity(0.65)) }
                }
                .frame(width: 108, height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let rating = meta?.rating, rating.isFinite, rating > 0 {
                            Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .foregroundStyle(Color.playerGlassInk)
                                .background(.white, in: Capsule())
                        }
                        if let metadata { Text(metadata).font(.system(size: 19)).foregroundStyle(.white.opacity(0.78)) }
                    }
                    Text(viewModel.title)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle = viewModel.pauseOverlayEpisodeLine {
                        Text(subtitle).font(.system(size: 21, weight: .medium)).lineLimit(2)
                    }
                }
            }
            if let synopsis = viewModel.pauseOverlayDescription, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.83))
                    .lineLimit(3)
            }
        }
        .padding(26)
        .frame(width: 880, alignment: .leading)
        .modifier(PlayerGlassSurface(shape: RoundedRectangle(cornerRadius: 26), darkOpacity: 0.55))
        .foregroundStyle(.white)
    }

    private var resumeControl: some View {
        VStack(alignment: .center, spacing: 10) {
            Button(action: onResume) {
                Label("Resume \(PlayerTimeFormat.clock(clock.position))", systemImage: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.playerGlassInk)
                    .padding(.horizontal, 27)
                    .frame(height: 64)
                    .modifier(PlayerGlassSurface(shape: Capsule(), filled: true))
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($resumeFocused)
            .accessibilityIdentifier("pause_resume")
            if clock.duration.isFinite && clock.duration > 0 {
                Text("\(PlayerTimeFormat.clock(clock.duration - clock.position)) remaining")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .monospacedDigit()
    }
}

extension PlaybackSpeed {
    var dockLabel: String { self == .normal ? "1.0×" : label.replacingOccurrences(of: "x", with: "×") }
}
