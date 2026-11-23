@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// What this Mac's AVFoundation can open and write. Everything here is Apple's
/// own: no FFmpeg, nothing downloaded, so MP3, WebM, MKV, OGG and Opus can be
/// read only where macOS reads them, and never written.
public enum MediaSupport {
    /// Type identifiers AVFoundation can open (MOV, MP4, M4V, 3GP, M4A, MP3, WAV, AIFF, FLAC, CAF…).
    public static let readableTypes: Set<String> = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    public static func canRead(_ type: UTType) -> Bool {
        if readableTypes.contains(type.identifier) { return true }
        return readableTypes.contains { UTType($0).map { type.conforms(to: $0) && $0 != .data && $0 != .item } ?? false }
    }

    /// Core Audio has a FLAC encoder on recent macOS; probed once.
    public static let canWriteFLAC: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flac-probe-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = MediaBackend.audioFileSettings(.flac, sampleRate: 44_100, channels: 2, sourceBits: 16, bitRate: nil)
        return (try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)) != nil
    }()

    /// The format a video or audio file is in, if the engine can also write it.
    public static func format(of url: URL) -> OutputFormat? {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "mov", "qt": .mov
        case "m4v": .m4v
        case "m4a", "aac": .m4a
        case "wav", "wave": .wav
        case "aif", "aiff", "aifc": .aiff
        case "flac": canWriteFLAC ? .flac : nil
        default: nil
        }
    }

    /// Same format when it can be written, else MP4 (video) or M4A (audio).
    static func sameOrDefault(_ url: URL, video: Bool) -> OutputFormat {
        if let f = format(of: url), f.isVideo == video { return f }
        return video ? .mp4 : .m4a
    }
}

/// Video and audio with AVFoundation (PLAN.md §7, the v1.1 media slot).
/// Video: remux when the codecs allow it (instant, lossless), else re-encode.
/// Audio: decoded to PCM and written by Core Audio in the chosen format.
enum MediaBackend {
    typealias Progress = @Sendable (Double) -> Void

    static func fileType(_ format: OutputFormat) -> AVFileType {
        switch format {
        case .mov: .mov
        case .m4v: .m4v
        case .m4a: .m4a
        case .wav: .wav
        case .aiff: .aiff
        default: .mp4
        }
    }

    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    static func hasVideo(_ url: URL) async -> Bool {
        ((try? await asset(url).loadTracks(withMediaType: .video)) ?? []).isEmpty == false
    }

    // MARK: Video → video

    /// MOV ↔ MP4 ↔ M4V. Tries a remux first (same picture and sound, seconds
    /// not minutes); re-encodes at the highest quality if the codecs don't fit.
    static func convertVideo(_ input: URL, to format: OutputFormat, output: URL, progress: @escaping Progress) async throws {
        let asset = asset(input)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw JobError.unsupported("\(input.lastPathComponent) to \(format.displayName): it has no picture")
        }
        try await exportPreferringPassthrough(asset, to: output, type: fileType(format), progress: progress)
    }

    /// Passthrough when the container accepts the tracks as they are, else
    /// the highest-quality re-encode. `configure` sets a time range or a composition.
    static func exportPreferringPassthrough(_ asset: AVAsset, to output: URL, type: AVFileType, progress: @escaping Progress,
                                            configure: (AVAssetExportSession) -> Void = { _ in }) async throws {
        if let pass = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
           pass.supportedFileTypes.contains(type) {
            configure(pass)
            do {
                try await export(pass, to: output, type: type, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(type) else {
            throw JobError.unsupported("this video as \(type.rawValue)")
        }
        configure(session)
        try await export(session, to: output, type: type, progress: progress)
    }

    /// Runs an export session with progress and cancellation.
    static func export(_ session: AVAssetExportSession, to output: URL, type: AVFileType, progress: @escaping Progress) async throws {
        session.outputURL = output
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        let box = Unchecked(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.value.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed: c.resume()
                    case .cancelled: c.resume(throwing: CancellationError())
                    default: c.resume(throwing: JobError.toolFailed(box.value.error?.localizedDescription ?? "the export stopped"))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        try Task.checkCancellation()
    }

    // MARK: Trim, mute, merge (video)

    static func trimVideo(_ input: URL, start: Double, end: Double, format: OutputFormat, output: URL,
                          progress: @escaping Progress) async throws {
        let asset = asset(input)
        let duration = try await asset.load(.duration).seconds
        let range = try timeRange(start: start, end: end, duration: duration)
        try await exportPreferringPassthrough(asset, to: output, type: fileType(format), progress: progress) { $0.timeRange = range }
    }

    static func timeRange(start: Double, end: Double, duration: Double) throws -> CMTimeRange {
        let s = max(0, start), e = min(end, duration.isFinite ? duration : end)
        guard e - s >= 0.05 else { throw JobError.unsupported("a trim shorter than a frame") }
        return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), end: CMTime(seconds: e, preferredTimescale: 600))
    }

    /// The picture only, untouched.
    static func removeAudio(_ input: URL, format: OutputFormat, output: URL, progress: @escaping Progress) async throws {
        let asset = asset(input)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw JobError.unsupported("\(input.lastPathComponent): it has no picture") }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw JobError.unsupported("\(input.lastPathComponent): it has no sound to remove")
        }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in tracks {
            guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = try await track.load(.timeRange)
            try ct.insertTimeRange(CMTimeRange(start: range.start, duration: min(range.duration, duration)), of: track, at: range.start)
            ct.preferredTransform = try await track.load(.preferredTransform)
        }
        try await exportPreferringPassthrough(composition, to: output, type: fileType(format), progress: progress)
    }

    /// Clips one after another. Same size and orientation: a lossless join;
    /// otherwise each clip is fitted into the first one's frame.
    static func mergeVideos(_ inputs: [URL], format: OutputFormat, output: URL, progress: @escaping Progress) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw JobError.encodeFailed("a combined video")
        }
        var audio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        struct Segment { var start: CMTime; var natural: CGSize; var transform: CGAffineTransform }
        var segments: [Segment] = []
        for url in inputs {
            try Task.checkCancellation()
            let asset = asset(url)
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
                throw JobError.unsupported("\(url.lastPathComponent) in a combined video: it has no picture")
            }
            let duration = try await asset.load(.duration)
            let (natural, transform, vRange) = try await vt.load(.naturalSize, .preferredTransform, .timeRange)
            let length = min(duration, vRange.duration)
            try video.insertTimeRange(CMTimeRange(start: vRange.start, duration: length), of: vt, at: cursor)
            if let at = try await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                let aRange = try await at.load(.timeRange)
                try? audio?.insertTimeRange(CMTimeRange(start: aRange.start, duration: min(length, aRange.duration)), of: at, at: cursor)
            }
            segments.append(Segment(start: cursor, natural: natural, transform: transform))
            cursor = cursor + length
        }
        guard let first = segments.first else { throw JobError.unsupported("an empty selection") }
        let uniform = segments.allSatisfy { $0.natural == first.natural && $0.transform == first.transform }
        if uniform {
            video.preferredTransform = first.transform
            try await exportPreferringPassthrough(composition, to: output, type: fileType(format), progress: progress)
            return
        }
        // Different sizes or orientations: fit each clip into the first one's upright frame.
        let render = upright(first.natural, first.transform).size
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        for segment in segments {
            let box = upright(segment.natural, segment.transform)
            let k = min(render.width / box.width, render.height / box.height)
            let t = segment.transform
                .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: (render.width - box.width * k) / 2, y: (render.height - box.height * k) / 2))
            layer.setTransform(t, at: segment.start)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: even(render.width), height: even(render.height))
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw JobError.encodeFailed("a combined video")
        }
        session.videoComposition = videoComposition
        try await export(session, to: output, type: fileType(format), progress: progress)
    }

    static func upright(_ natural: CGSize, _ transform: CGAffineTransform) -> CGRect {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGRect(x: r.minX, y: r.minY, width: abs(r.width), height: abs(r.height))
    }

    static func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }

    // MARK: Video → GIF

    /// An animated GIF, at most 480 px on the long side. Long videos get fewer
    /// frames per second; past 75 s only the start is used (the note says so).
    static func gif(_ input: URL, output: URL, progress: @escaping Progress) async throws -> String? {
        let asset = asset(input)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw JobError.unsupported("\(input.lastPathComponent) to GIF: it has no picture")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw JobError.unreadable(input.lastPathComponent) }
        let plan = gifPlan(duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.5 / plan.fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, plan.frames, nil) else {
            throw JobError.encodeFailed("GIF")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / plan.fps
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                               kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for i in 0..<plan.frames {
            try Task.checkCancellation()
            let time = CMTime(seconds: min(Double(i) / plan.fps, max(0, duration - 0.01)), preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frameProperties)
            progress(Double(i + 1) / Double(plan.frames) * 0.9)
        }
        guard CGImageDestinationFinalize(destination) else { throw JobError.encodeFailed("GIF") }
        return plan.truncated ? "Only the first \(Int(plan.seconds)) seconds: trim the video first for another part." : nil
    }

    /// 12 fps up to 25 s, then fewer (down to 4 fps) to stay under 300 frames.
    static func gifPlan(duration: Double) -> (fps: Double, frames: Int, seconds: Double, truncated: Bool) {
        let maxFrames = 300.0
        let fps = max(4, min(12, maxFrames / duration))
        let seconds = min(duration, maxFrames / fps)
        let frames = max(1, Int((seconds * fps).rounded(.down)))
        return (fps, frames, seconds, seconds < duration - 0.05)
    }

    // MARK: Compress (video)

    /// HEVC at a lower bit rate: Light keeps the size, Balanced fits 1080p,
    /// Strong fits 720p. HDR stays HDR (10-bit, the source's colour).
    /// `fit`: exact numbers instead of the level's (Make it fit).
    static func compressVideo(_ input: URL, level: PDFCompression, format: OutputFormat, output: URL,
                              fit: (shortSide: CGFloat?, videoBitRate: Int, audioBitRate: Int)? = nil,
                              progress: @escaping Progress) async throws {
        let asset = asset(input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw JobError.unsupported("compressing \(input.lastPathComponent): it has no picture")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let (natural, transform, nominalFPS, dataRate, descriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let size = fit.map { capped(natural, shortSide: $0.shortSide) } ?? compressedSize(natural, level: level)
        let bitRate = fit?.videoBitRate ?? videoBitRate(size: size, fps: fps, level: level, sourceRate: Double(dataRate))
        let colour = colourProperties(descriptions.first)
        let hdr = colour?[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_2100_HLG
            || colour?[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_SMPTE_ST_2084_PQ

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType(format))
        writer.shouldOptimizeForNetworkUse = true

        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOut.alwaysCopiesSampleData = false
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitRate, AVVideoExpectedSourceFrameRateKey: fps,
                                          AVVideoMaxKeyFrameIntervalDurationKey: 2,
                                          AVVideoProfileLevelKey: hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel]
        compression[AVVideoAllowFrameReorderingKey] = true
        var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width),
                                            AVVideoHeightKey: Int(size.height), AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                                            AVVideoCompressionPropertiesKey: compression]
        if let colour { videoSettings[AVVideoColorPropertiesKey] = colour }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw JobError.unsupported("compressing this video") }
        reader.add(videoOut)
        writer.add(videoIn)
        var lanes = [Lane(output: videoOut, input: videoIn, reportsProgress: true)]

        if !audioTracks.isEmpty {
            let rate = 48_000.0, channels = 2
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            ])
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: fit?.audioBitRate ?? audioBitRate(level, channels: channels),
            ])
            audioIn.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOut), writer.canAdd(audioIn) {
                reader.add(audioOut)
                writer.add(audioIn)
                lanes.append(Lane(output: audioOut, input: audioIn, reportsProgress: false))
            }
        }
        try await Pump(reader: reader, writer: writer, lanes: lanes, duration: duration).run(progress: progress)
    }

    /// Never larger than the source; even sides (4:2:0 needs them).
    static func compressedSize(_ natural: CGSize, level: PDFCompression) -> CGSize {
        let cap: CGFloat? = switch level {
        case .light: nil
        case .balanced: 1080
        case .strong: 720
        }
        return capped(natural, shortSide: cap)
    }

    static func capped(_ natural: CGSize, shortSide cap: CGFloat?) -> CGSize {
        let w = abs(natural.width), h = abs(natural.height)
        let short = min(w, h)
        let k = cap.map { short > $0 ? $0 / short : 1 } ?? 1
        return CGSize(width: even(w * k), height: even(h * k))
    }

    // MARK: Make it fit

    /// The bit rates and size that land a video under `bytes`: the sound gets a
    /// modest share, the picture the rest, and the resolution drops until each
    /// pixel has enough bits to look clean. nil if even 240p can't fit.
    static func fitPlan(bytes: Int64, duration: Double, natural: CGSize, fps: Double, hasAudio: Bool)
        -> (shortSide: CGFloat?, videoBitRate: Int, audioBitRate: Int)? {
        guard duration > 0 else { return nil }
        let total = Double(bytes) * 8 * 0.92 / duration // container overhead and encoder wobble
        let audio = hasAudio ? (total < 1_000_000 ? 64_000 : 128_000) : 0
        let video = total - Double(audio)
        guard video >= 80_000 else { return nil }
        let short = min(abs(natural.width), abs(natural.height))
        for cap in [nil, 1080, 720, 540, 360, 240] as [CGFloat?] {
            if let cap, cap >= short { continue }
            let size = capped(natural, shortSide: cap)
            if video / (Double(size.width * size.height) * min(fps, 60)) >= 0.035 || cap == 240 {
                return (cap, Int(video), audio)
            }
        }
        return nil
    }

    /// Video under `bytes`. Encoders treat a bit rate as a wish, and busy
    /// footage (grain, water, confetti) overshoots, so each try is measured and
    /// the next one aims lower by exactly the overshoot. Up to three tries.
    static func fitVideo(_ input: URL, bytes: Int64, format: OutputFormat, output: URL, progress: @escaping Progress) async throws {
        let asset = asset(input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw JobError.unsupported("\(input.lastPathComponent): it has no picture")
        }
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let duration = try await asset.load(.duration).seconds
        let (natural, fpsValue) = try await track.load(.naturalSize, .nominalFrameRate)
        let fps = fpsValue > 0 ? Double(fpsValue) : 30
        var budget = bytes
        let tries = 4
        let fm = FileManager.default
        var best: (url: URL, bytes: Int64)?     // the largest try that fits
        var closest: (url: URL, bytes: Int64)?  // the smallest try, if none fits
        var attempts: [URL] = []
        defer { for url in attempts where url != best?.url && url != closest?.url { try? fm.removeItem(at: url) } }
        for attempt in 0..<tries {
            guard let plan = fitPlan(bytes: budget, duration: duration, natural: natural, fps: fps, hasAudio: hasAudio) else { break }
            let url = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(output.pathExtension)
            attempts.append(url)
            let slice = 1 / Double(tries)
            try await compressVideo(input, level: .balanced, format: format, output: url, fit: plan) {
                progress(Double(attempt) * slice + $0 * slice)
            }
            let got = ConversionEngine.size(of: url)
            if got <= bytes {
                if best == nil || got > best!.bytes { best = (url, got) }
                if got >= bytes * 3 / 4 { break } // close enough: good use of the room
            } else if closest == nil || got < closest!.bytes {
                closest = (url, got)
            }
            // Aim again by the measured miss, in either direction.
            budget = Int64(Double(budget) * Double(bytes) / Double(max(got, 1)) * (got > bytes ? 0.92 : 0.97))
        }
        guard let chosen = best ?? closest else {
            throw JobError.message("A \(Self.minutes(duration)) video can't fit in \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Trim it first.")
        }
        try? fm.removeItem(at: output)
        try fm.moveItem(at: chosen.url, to: output)
    }

    /// Audio under `bytes`: AAC at the highest bit rate that fits, measured
    /// and re-aimed like video (an M4A has a fixed overhead that matters for short clips).
    static func fitAudio(_ input: URL, bytes: Int64, output: URL, progress: @escaping Progress) async throws {
        let duration = max(try await asset(input).load(.duration).seconds, 0.1)
        let channels = min(try await audioShape(input).channels, 2)
        let steps = [24_000, 32_000, 48_000, 64_000, 80_000, 96_000, 128_000, 160_000, 192_000, 256_000].map { max(16_000, $0 * channels / 2) }
        let ceiling = channels == 1 ? 160_000 : 256_000
        var overhead: Int64 = 0
        for _ in 0..<3 {
            let rate = Int(Double(bytes - overhead) * 8 * 0.95 / duration)
            guard rate >= steps[0] else {
                throw JobError.message("\(minutes(duration).capitalized) of sound can't fit in \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Trim it first.")
            }
            let chosen = steps.last { $0 <= min(rate, ceiling) } ?? steps[0]
            try? FileManager.default.removeItem(at: output)
            try await writeAudio([input], to: .m4a, bitRate: chosen, output: output, progress: progress)
            let got = ConversionEngine.size(of: output)
            if got <= bytes { return }
            overhead = max(overhead, got - Int64(Double(chosen) / 8 * duration))
        }
        throw JobError.message("Couldn't get the sound under \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). Trim it first.")
    }

    static func minutes(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded()))-second" : "\(Int((seconds / 60).rounded()))-minute"
    }

    // MARK: Speed

    /// Faster or slower; voices and music keep their pitch. Audio comes out as M4A.
    static func changeSpeed(_ input: URL, rate: Double, video: Bool, format: OutputFormat, output: URL,
                            progress: @escaping Progress) async throws {
        guard rate > 0.05, rate < 20, abs(rate - 1) > 0.001 else { throw JobError.message("Pick a speed other than 1×.") }
        let source = asset(input)
        let duration = try await source.load(.duration)
        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)
        for type in [AVMediaType.video, .audio] where video || type == .audio {
            for track in try await source.loadTracks(withMediaType: type) {
                guard let ct = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let range = try await track.load(.timeRange)
                try ct.insertTimeRange(CMTimeRange(start: range.start, duration: min(range.duration, duration)), of: track, at: range.start)
                if type == .video { ct.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        composition.scaleTimeRange(full, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / rate))
        // HEVC keeps HDR and stays compact; audio-only becomes AAC.
        let preset = video ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw JobError.encodeFailed("the new speed") }
        session.audioTimePitchAlgorithm = .spectral
        try await export(session, to: output, type: video ? fileType(format) : .m4a, progress: progress)
    }

    /// HEVC bits per pixel per frame, capped below the source's own rate.
    static func videoBitRate(size: CGSize, fps: Double, level: PDFCompression, sourceRate: Double) -> Int {
        let (bpp, share): (Double, Double) = switch level {
        case .light: (0.09, 0.7)
        case .balanced: (0.06, 0.5)
        case .strong: (0.045, 0.35)
        }
        var rate = Double(size.width * size.height) * min(fps, 60) * bpp
        if sourceRate > 0 { rate = min(rate, sourceRate * share) }
        return Int(max(rate, 300_000))
    }

    static func audioBitRate(_ level: PDFCompression, channels: Int) -> Int {
        let stereo: Int = switch level {
        case .light: 192_000
        case .balanced: 128_000
        case .strong: 80_000
        }
        return channels == 1 ? stereo / 2 : stereo
    }

    /// The source's colour primaries, transfer function and matrix, when it states all three.
    static func colourProperties(_ description: CMFormatDescription?) -> [String: Any]? {
        guard let description,
              let primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
              let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
              let matrix = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        else { return nil }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }

    // MARK: Audio

    /// Any readable audio (or a video's sound) into one audio file. Several
    /// inputs are joined in order; `range` trims a single input.
    static func writeAudio(_ inputs: [URL], range: (start: Double, end: Double)? = nil, to format: OutputFormat,
                           bitRate: Int? = nil, output: URL, progress: @escaping Progress) async throws {
        precondition(format.isAudio)
        // The first input decides the sample rate, channels and bit depth.
        guard let first = inputs.first else { throw JobError.unsupported("an empty selection") }
        let probe = try await audioShape(first)
        let sampleRate = format == .m4a ? min(probe.rate, 48_000) : probe.rate
        let channels = min(probe.channels, 2)
        let settings = audioFileSettings(format, sampleRate: sampleRate, channels: channels, sourceBits: probe.bits, bitRate: bitRate)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw JobError.encodeFailed(format.displayName)
        }
        var total = 0.0
        var durations: [Double] = []
        for url in inputs {
            let d = try await asset(url).load(.duration).seconds
            durations.append(range.map { $0.end - $0.start } ?? d)
            total += durations.last ?? 0
        }
        do {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            } catch {
                throw JobError.encodeFailed("\(format.displayName): \(error.localizedDescription)")
            }
            var done = 0.0
            for (i, url) in inputs.enumerated() {
                let asset = asset(url)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else { throw JobError.unsupported("\(url.lastPathComponent): it has no sound") }
                let reader = try AVAssetReader(asset: asset)
                if let range {
                    let duration = try await asset.load(.duration).seconds
                    reader.timeRange = try timeRange(start: range.start, end: range.end, duration: duration)
                }
                let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                ])
                guard reader.canAdd(out) else { throw JobError.unsupported("reading \(url.lastPathComponent)") }
                reader.add(out)
                guard reader.startReading() else {
                    throw JobError.unreadable("\(url.lastPathComponent): \(reader.error?.localizedDescription ?? "")")
                }
                let offset = reader.timeRange.start.seconds.isFinite ? reader.timeRange.start.seconds : 0
                while let sample = out.copyNextSampleBuffer() {
                    if Task.isCancelled {
                        reader.cancelReading()
                        throw CancellationError()
                    }
                    let frames = CMSampleBufferGetNumSamples(sample)
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                              into: buffer.mutableAudioBufferList)
                    guard status == noErr else { throw JobError.toolFailed("couldn't read the sound (\(status))") }
                    try file.write(from: buffer)
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - offset
                    if total > 0, t.isFinite { progress(min(1, (done + t) / total)) }
                }
                if reader.status == .failed {
                    throw JobError.unreadable("\(url.lastPathComponent): \(reader.error?.localizedDescription ?? "")")
                }
                done += durations[i]
            }
        } // the file is closed here
        try Task.checkCancellation()
    }

    /// Sample rate, channels and (for PCM, FLAC and ALAC) bit depth of the first sound track.
    static func audioShape(_ url: URL) async throws -> (rate: Double, channels: Int, bits: Int) {
        let asset = asset(url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw JobError.unsupported("\(url.lastPathComponent): it has no sound")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let d = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee else {
            return (44_100, 2, 16)
        }
        var bits = Int(asbd.mBitsPerChannel)
        if asbd.mFormatID == kAudioFormatFLAC || asbd.mFormatID == kAudioFormatAppleLossless {
            bits = asbd.mFormatFlags == 2 ? 20 : asbd.mFormatFlags >= 3 ? 24 : 16
        }
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        return (rate, max(1, Int(asbd.mChannelsPerFrame)), bits)
    }

    /// File settings for Core Audio. Lossless formats keep 24-bit sources at 24 bits.
    static func audioFileSettings(_ format: OutputFormat, sampleRate: Double, channels: Int, sourceBits: Int,
                                  bitRate: Int?) -> [String: Any] {
        let depth = sourceBits > 16 ? 24 : 16
        var s: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch format {
        case .wav, .aiff:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = depth
            s[AVLinearPCMIsFloatKey] = false
            s[AVLinearPCMIsBigEndianKey] = format == .aiff
            s[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            s[AVFormatIDKey] = kAudioFormatFLAC
            s[AVEncoderBitDepthHintKey] = depth
        default: // .m4a
            s[AVFormatIDKey] = kAudioFormatMPEG4AAC
            s[AVEncoderBitRateKey] = bitRate ?? (channels == 1 ? 128_000 : 256_000)
        }
        return s
    }
}

// MARK: For the wheel (hover hints and the GIF preview)

/// What a video or audio file would roughly become, for the wheel's hints.
public struct MediaEstimate: Sendable {
    public var formats: [OutputFormat: Int64] = [:]
    public var compress: [PDFCompression: Int64] = [:]
    public var duration: Double = 0
}

extension MediaSupport {
    /// Fast: reads the track headers only.
    public static func estimate(_ url: URL) async -> MediaEstimate? {
        let asset = MediaBackend.asset(url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        let bytes = ConversionEngine.size(of: url)
        var e = MediaEstimate(duration: duration)
        let video = try? await asset.loadTracks(withMediaType: .video).first
        let shape = try? await MediaBackend.audioShape(url)
        if let shape {
            let channels = min(shape.channels, 2)
            let pcm = Int64(shape.rate * Double(channels) * Double(shape.bits > 16 ? 3 : 2) * duration)
            e.formats[.wav] = pcm
            e.formats[.aiff] = pcm
            e.formats[.flac] = pcm * 55 / 100
            e.formats[.m4a] = Int64(Double(channels == 1 ? 128_000 : 256_000) / 8 * duration)
        }
        if let video, let (natural, fps, rate) = try? await video.load(.naturalSize, .nominalFrameRate, .estimatedDataRate) {
            for f in OutputFormat.videoFormats { e.formats[f] = bytes } // remux: about the same
            let plan = MediaBackend.gifPlan(duration: duration)
            let side = MediaBackend.capped(natural, shortSide: nil)
            let k = min(1, 480 / max(side.width, side.height, 1))
            e.formats[.gif] = Int64(Double(plan.frames) * Double(side.width * k * side.height * k) * 0.45)
            for level in PDFCompression.allCases {
                let size = MediaBackend.compressedSize(natural, level: level)
                let v = MediaBackend.videoBitRate(size: size, fps: fps > 0 ? Double(fps) : 30, level: level, sourceRate: Double(rate))
                let a = shape == nil ? 0 : MediaBackend.audioBitRate(level, channels: 2)
                e.compress[level] = min(bytes, Int64(Double(v + a) / 8 * duration))
            }
        } else if shape != nil {
            for level in PDFCompression.allCases {
                e.compress[level] = min(bytes, Int64(Double(MediaBackend.audioBitRate(level, channels: 2)) / 8 * duration))
            }
        }
        return e
    }

    /// A few small frames across the clip, for a moving preview.
    public static func previewFrames(_ url: URL, count: Int, maxPixel: CGFloat) async -> [CGImage] {
        let asset = MediaBackend.asset(url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // The first few seconds, as the GIF would show them.
        let span = min(duration, MediaBackend.gifPlan(duration: duration).seconds)
        var frames: [CGImage] = []
        for i in 0..<count {
            guard !Task.isCancelled else { break }
            let t = CMTime(seconds: span * Double(i) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: t).image { frames.append(image) }
        }
        return frames
    }
}

/// One reader output feeding one writer input.
private final class Lane: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let reportsProgress: Bool
    var finished = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool) {
        self.output = output
        self.input = input
        self.reportsProgress = reportsProgress
    }
}

/// Moves samples from an AVAssetReader to an AVAssetWriter, each lane on its own queue.
private final class Pump: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let lanes: [Lane]
    let duration: Double
    private let lock = NSLock()
    private var cancelled = false

    init(reader: AVAssetReader, writer: AVAssetWriter, lanes: [Lane], duration: Double) {
        self.reader = reader
        self.writer = writer
        self.lanes = lanes
        self.duration = duration
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func run(progress: @escaping MediaBackend.Progress) async throws {
        guard writer.startWriting() else { throw JobError.encodeFailed(writer.error?.localizedDescription ?? "the video") }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw JobError.unreadable(reader.error?.localizedDescription ?? "the video")
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for (i, lane) in lanes.enumerated() {
                    group.enter()
                    lane.input.requestMediaDataWhenReady(on: DispatchQueue(label: "circularity.media.\(i)")) { [self] in
                        while lane.input.isReadyForMoreMediaData, !lane.finished {
                            guard !isCancelled, reader.status == .reading, let sample = lane.output.copyNextSampleBuffer() else {
                                lane.finished = true
                                lane.input.markAsFinished()
                                group.leave()
                                return
                            }
                            if lane.reportsProgress, duration > 0 {
                                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                if t.isFinite { progress(min(0.99, t / duration)) }
                            }
                            if !lane.input.append(sample) {
                                lane.finished = true
                                lane.input.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }
                group.notify(queue: .global()) { c.resume() }
            }
        } onCancel: {
            lock.lock(); cancelled = true; lock.unlock()
        }
        if isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw JobError.unreadable(reader.error?.localizedDescription ?? "the video")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw JobError.encodeFailed(writer.error?.localizedDescription ?? "the video")
        }
    }
}

/// Carries a non-Sendable value across a hop the caller knows is safe.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
