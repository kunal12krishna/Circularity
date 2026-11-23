import AppKit
import AVFoundation
import CircularityEngine
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// EngineSmokeTest (PLAN.md §4): generates fixtures, runs every conversion,
// resize, crop and compress through the real engine and queue, and checks the
// results. Exit code 0 only if every check passes. `--large` adds the 100 MP
// image and 200-page PDF used for the performance report.

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let large = CommandLine.arguments.contains("--large")

var failures = 0
var passes = 0
@MainActor func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS  \(label)" : "FAIL  \(label)")
    if ok { passes += 1 } else { failures += 1 }
}

// MARK: Fixtures

func noisy(_ w: Int, _ h: Int, alpha: Bool = false, seed: UInt64 = 7) -> CGImage {
    var state = seed
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(w * h) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let v = UInt8(truncatingIfNeeded: state >> 33)
        let gx = UInt8(truncatingIfNeeded: (i % w) * 255 / max(w, 1))
        data[i * 4] = gx; data[i * 4 + 1] = v; data[i * 4 + 2] = 255 &- gx; data[i * 4 + 3] = 255
    }
    if alpha { // transparent left half
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    }
    return ctx.makeImage()!
}

/// A gradient with mild grain: closer to a real photo than pure noise.
func photoLikeImage(_ w: Int, _ h: Int) -> CGImage {
    let base = gradient(w, h)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var state: UInt64 = 11
    for i in 0..<(w * h * 4) where i % 4 != 3 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let grain = Int(state >> 60) - 8
        data[i] = UInt8(clamping: Int(data[i]) + grain)
    }
    return ctx.makeImage()!
}

func gradient(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [CGColor(srgbRed: 1, green: 0.54, blue: 0, alpha: 1), CGColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    return ctx.makeImage()!
}

func writeImage(_ image: CGImage, _ type: UTType, to url: URL, properties: [CFString: Any] = [:]) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func makePDF(_ url: URL, pages: Int, imageEvery: Int = 0, size: CGSize = CGSize(width: 612, height: 792)) {
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let photo = imageEvery > 0 ? noisy(1600, 1200) : nil
    for p in 1...pages {
        ctx.beginPage(mediaBox: &box)
        let text = NSAttributedString(string: "Page \(p) of the Circularity smoke test", attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
        ctx.textPosition = CGPoint(x: 72, y: size.height - 96)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        if let photo, p % imageEvery == 0 { ctx.draw(photo, in: CGRect(x: 72, y: 120, width: 468, height: 351)) }
        ctx.endPage()
    }
    ctx.closePDF()
}

// MARK: Inspection

func pixelSize(_ url: URL) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return CGSize(width: w, height: h)
}

func properties(_ url: URL) -> [CFString: Any] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
}

/// RGBA at (x, y) from the top-left.
func pixel(_ url: URL, x: Int, y: Int) -> [UInt8] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return [d[0], d[1], d[2], d[3]]
}

func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

// MARK: Media fixtures (AVFoundation only: a picture track, a tone, then one file)

/// A moving pattern with grain (so compression has something to do), H.264, no sound.
func writeSilentVideo(_ url: URL, size: CGSize, seconds: Double, fps: Int32 = 30, transform: CGAffineTransform = .identity) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 6)],
    ])
    input.transform = transform
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * Double(fps))
    var state: UInt64 = 3
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { throw JobError.encodeFailed("fixture frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let w = Int(size.width), h = Int(size.height), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let grain = UInt8(truncatingIfNeeded: state >> 58)
                let p = base + y * row + x * 4
                p[0] = UInt8(truncatingIfNeeded: x * 255 / w) &+ grain
                p[1] = UInt8(truncatingIfNeeded: (y + f * 8) % 256) &+ grain
                p[2] = UInt8(truncatingIfNeeded: (x + f * 12) % 256)
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? JobError.encodeFailed("fixture video") }
}

/// A 440 Hz tone as 16-bit WAV.
func writeTone(_ url: URL, seconds: Double, rate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.3 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) }
    }
    try file.write(from: buffer)
}

/// Picture + tone in one file: `.mp4` with H.264 and AAC (as a phone or browser makes them).
func makeClip(_ url: URL, size: CGSize, seconds: Double, transform: CGAffineTransform = .identity, in dir: URL) async throws {
    let silent = dir.appendingPathComponent(UUID().uuidString + ".mov")
    let tone = dir.appendingPathComponent(UUID().uuidString + ".wav")
    try await writeSilentVideo(silent, size: size, seconds: seconds, transform: transform)
    try writeTone(tone, seconds: seconds)
    let composition = AVMutableComposition()
    let video = AVURLAsset(url: silent), audio = AVURLAsset(url: tone)
    let vt = try await video.loadTracks(withMediaType: .video)[0], at = try await audio.loadTracks(withMediaType: .audio)[0]
    let range = CMTimeRange(start: .zero, duration: try await video.load(.duration))
    let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try cv.insertTimeRange(range, of: vt, at: .zero)
    cv.preferredTransform = transform
    try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: min(range.duration, try await audio.load(.duration))), of: at, at: .zero)
    let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
    session.outputURL = url
    session.outputFileType = url.pathExtension == "mov" ? .mov : .mp4
    await session.export()
    guard session.status == .completed else { throw session.error ?? JobError.encodeFailed("fixture clip") }
}

struct MediaInfo {
    var duration: Double
    var video: Int
    var audio: Int
    var codec: FourCharCode?
    var size: CGSize?
}

func mediaInfo(_ url: URL) async -> MediaInfo? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration).seconds,
          let v = try? await asset.loadTracks(withMediaType: .video), let a = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
    var info = MediaInfo(duration: duration, video: v.count, audio: a.count)
    if let first = v.first, let (natural, transform, descs) = try? await first.load(.naturalSize, .preferredTransform, .formatDescriptions) {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        info.size = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
        info.codec = descs.first.map(CMFormatDescriptionGetMediaSubType)
    } else if let first = a.first, let descs = try? await first.load(.formatDescriptions) {
        info.codec = descs.first.map(CMFormatDescriptionGetMediaSubType)
    }
    return info
}

func gifFrames(_ url: URL) -> (count: Int, size: CGSize?) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (0, nil) }
    return (CGImageSourceGetCount(source), pixelSize(url))
}

// MARK: Run

@MainActor
func runAll() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("EngineSmokeTest-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let engine = ConversionEngine()
    let support = FormatSupport.current
    var policy = OutputPolicy(fallbackFolder: root.appendingPathComponent("Converted", isDirectory: true))

    func run(_ inputs: [URL], _ op: CircularityEngine.Operation, _ p: OutputPolicy? = nil) async -> Result<JobResult, Error> {
        do { return .success(try await engine.run(JobRequest(inputs: inputs, operation: op, output: p ?? policy))) } catch { return .failure(error) }
    }
    func output(_ r: Result<JobResult, Error>) -> URL? { (try? r.get())?.outputs.first }

    // Fixtures
    let alphaPNG = root.appendingPathComponent("alpha.png")
    writeImage(noisy(800, 600, alpha: true), .png, to: alphaPNG)
    let rotated = root.appendingPathComponent("rotated.jpg")
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"]
    writeImage(gradient(600, 400), .jpeg, to: rotated, properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps])
    let photo = root.appendingPathComponent("photo.png")
    writeImage(noisy(3000, 2000), .png, to: photo)
    let svg = root.appendingPathComponent("icon.svg")
    try? """
    <svg xmlns="http://www.w3.org/2000/svg" width="64" height="32"><rect width="64" height="32" fill="#ff8a00"/>\
    <image href="https://example.invalid/never.png" width="10" height="10"/></svg>
    """.write(to: svg, atomically: true, encoding: .utf8)

    // 1. Every writable image format
    for format in OutputFormat.allCases where format.imageTypeIdentifier != nil {
        guard support.canWrite(format) else { print("SKIP  \(format.displayName): not writable on this Mac"); continue }
        let out = output(await run([alphaPNG], .convert(format)))
        check(out.flatMap(pixelSize) == CGSize(width: 800, height: 600), "PNG → \(format.displayName) decodes at 800 × 600")
    }
    let jpg = output(await run([alphaPNG], .convert(.jpg)))
    check(jpg.map { pixel($0, x: 10, y: 10) }.map { $0[0] > 240 && $0[1] > 240 && $0[2] > 240 } == true,
          "transparent pixels become white in JPG")
    check(jpg?.lastPathComponent == "alpha (1).jpg", "a second JPG gets (1): \(jpg?.lastPathComponent ?? "-")")
    let toPDF = output(await run([alphaPNG], .convert(.pdf)))
    check(toPDF.flatMap { PDFDocument(url: $0)?.pageCount } == 1, "image → PDF has one page")

    // 2. EXIF orientation and metadata
    let upright = output(await run([rotated], .convert(.png)))
    check(upright.flatMap(pixelSize) == CGSize(width: 400, height: 600), "EXIF-rotated JPEG comes out upright (400 × 600)")
    let kept = output(await run([rotated], .convert(.jpg)))
    check(kept.map { properties($0)[kCGImagePropertyGPSDictionary] != nil } == true, "metadata kept by default (GPS present)")
    policy.metadata = .stripGPS
    let noGPS = output(await run([rotated], .convert(.jpg)))
    check(noGPS.map { properties($0)[kCGImagePropertyGPSDictionary] == nil } == true, "No GPS strips location")
    policy.metadata = .keep

    // 3. SVG (rendered locally, small icons scaled up to 1024 px)
    let svgOut = output(await run([svg], .convert(.png)))
    check(svgOut.flatMap(pixelSize) == CGSize(width: 1024, height: 512), "SVG renders at 1024 px long edge without network")

    // 4. Resize and crop
    let fitted = output(await run([alphaPNG], .resize(ResizeSpec(width: 400, height: 400))))
    check(fitted.flatMap(pixelSize) == CGSize(width: 400, height: 300), "fit 400 × 400 → 400 × 300")
    check(fitted?.lastPathComponent == "alpha (resized).png", "resize naming: \(fitted?.lastPathComponent ?? "-")")
    check(output(await run([alphaPNG], .resize(ResizeSpec(width: 200, height: 200, mode: .stretch)))).flatMap(pixelSize) == CGSize(width: 200, height: 200),
          "stretch → 200 × 200")
    check(output(await run([alphaPNG], .resize(ResizeSpec(width: 1600, height: nil)))).flatMap(pixelSize) == CGSize(width: 1600, height: 1200),
          "upscale to 1600 wide keeps the aspect")
    let cropped = output(await run([alphaPNG], .cropImage(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))))
    check(cropped.flatMap(pixelSize) == CGSize(width: 400, height: 300), "crop centre half → 400 × 300")

    // 5. Compress
    let byQuality = output(await run([photo], .compressImage(.quality(0.6))))
    check(byQuality.map { fileSize($0) < fileSize(photo) } == true, "quality compress is smaller (\(byQuality.map { fileSize($0) } ?? 0) < \(fileSize(photo)))")
    let target: Int64 = 400_000
    let byTarget = output(await run([photo], .compressImage(.targetBytes(target))))
    check(byTarget.map { fileSize($0) <= target } == true, "target size ≤ 400 KB (got \(byTarget.map { fileSize($0) } ?? -1))")
    let photoLikeBig = root.appendingPathComponent("photo-big.png")
    writeImage(photoLikeImage(4000, 3000), .png, to: photoLikeBig)
    let tenKB = try? await run([photoLikeBig], .compressImage(.targetBytes(10_000))).get()
    check(tenKB?.outputs.first.map { fileSize($0) <= 10_000 } == true,
          "compress a 12 MP photo under 10 KB (\(tenKB?.outputs.first.map { fileSize($0) } ?? -1) bytes, \(tenKB?.notes.first ?? "no note"))")
    let alreadyUnder = try? await run([photoLikeBig], .compressImage(.targetBytes(500_000_000))).get()
    check(alreadyUnder?.outputs.isEmpty == true && alreadyUnder?.notes.first?.contains("already under") == true,
          "a file already under the target is kept (\(alreadyUnder?.notes.first ?? "-"))")
    let tiny = root.appendingPathComponent("tiny.jpg")
    writeImage(gradient(64, 64), .jpeg, to: tiny, properties: [kCGImageDestinationLossyCompressionQuality: 0.3])
    let alreadySmall = try? await run([tiny], .compressImage(.quality(0.95))).get()
    check(alreadySmall?.outputs.isEmpty == true && alreadySmall?.notes.isEmpty == false, "already-small image keeps the original")

    // 6. Batches, unsupported input, fallback folder
    let batch = try? await run([alphaPNG, rotated, photo], .convert(.heic)).get()
    check(batch?.outputs.count == 3, "batch of 3 → 3 outputs")
    let zip = root.appendingPathComponent("archive.zip")
    try? Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
    if case let .failure(error) = await run([zip], .convert(.png)) {
        check(error is JobError, "unsupported input reports a friendly error: \(error.localizedDescription)")
    } else { check(false, "unsupported input should fail") }
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let lockedPNG = locked.appendingPathComponent("inside.png")
    try? fm.copyItem(at: alphaPNG, to: lockedPNG)
    try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    let fallback = try? await run([lockedPNG], .convert(.jpg)).get()
    check(fallback?.outcomes.first?.usedFallbackFolder == true && fallback?.outputs.first?.deletingLastPathComponent().lastPathComponent == "Converted",
          "unwritable folder falls back to Converted")
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

    // 7. Cancellation leaves nothing behind
    let big = root.appendingPathComponent("cancel", isDirectory: true)
    try? fm.createDirectory(at: big, withIntermediateDirectories: true)
    let bigPNG = big.appendingPathComponent("big.png")
    writeImage(noisy(4000, 3000, seed: 3), .png, to: bigPNG)
    let before = Set((try? fm.contentsOfDirectory(atPath: big.path)) ?? [])
    let task = Task { try await engine.run(JobRequest(inputs: [bigPNG], operation: .compressImage(.targetBytes(5_000)), output: policy)) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    let cancelled = await task.result
    let after = Set((try? fm.contentsOfDirectory(atPath: big.path)) ?? [])
    check((try? cancelled.get()) == nil, "cancelled job throws")
    check(before == after, "cancelled job leaves no file behind")

    // 8. PDFs
    let doc12 = root.appendingPathComponent("report.pdf")
    makePDF(doc12, pages: 12, imageEvery: 3)
    if let folder = output(await run([doc12], .pdfPages(.png, scale: 1))) {
        let pages = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        check(folder.lastPathComponent == "report (pages)" && pages.count == 12, "PDF → 12 PNG pages in \"report (pages)\"")
        check(pages.first == "report page 01.png", "pages are numbered: \(pages.first ?? "-")")
        check(pixelSize(folder.appendingPathComponent(pages[0])) == CGSize(width: 612, height: 792), "page image is 612 × 792 at 1×")
    } else { check(false, "PDF → pages produced a folder") }
    let text = output(await run([doc12], .extractText))
    check(text.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("Page 7 of the Circularity") == true, "PDF → TXT keeps the text")
    let combined = output(await run([doc12, alphaPNG, rotated], .combinePDF))
    check(combined.flatMap { PDFDocument(url: $0)?.pageCount } == 14, "combine PDF + 2 images → 14 pages, in drop order")
    check(combined?.lastPathComponent == "report (combined).pdf", "combine naming: \(combined?.lastPathComponent ?? "-")")
    let compressed = try? await run([doc12], .compressPDF(.balanced)).get()
    if let out = compressed?.outputs.first {
        check(fileSize(out) < fileSize(doc12), "image-heavy PDF compresses (\(fileSize(doc12)) → \(fileSize(out)))")
        check(PDFDocument(url: out)?.page(at: 6)?.string?.contains("Page 7") == true, "compressed PDF keeps its text")
    } else {
        check(false, "image-heavy PDF compress: \(compressed?.notes.first ?? "failed")")
    }
    let textOnly = root.appendingPathComponent("letter.pdf")
    makePDF(textOnly, pages: 2)
    let notSmaller = try? await run([textOnly], .compressPDF(.strong)).get()
    check(notSmaller?.outputs.isEmpty == true, "text-only PDF keeps the original (\(notSmaller?.notes.first ?? "-"))")
    let half = output(await run([doc12], .resizePDF(.scale(0.5))))
    check(half.flatMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .mediaBox).size } == CGSize(width: 306, height: 396), "PDF scaled to 50 %")
    let a4 = output(await run([doc12], .resizePDF(.paper(.a4))))
    check(a4.flatMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .mediaBox).width }.map { abs($0 - 595.28) < 1 } == true, "PDF fitted to A4")
    let pdfCrop = output(await run([doc12], .cropPDF(CGRect(x: 0, y: 0, width: 1, height: 0.5))))
    check(pdfCrop.flatMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .cropBox).height } == 396, "PDF crop box set to the top half")

    // 9. Documents
    let md = root.appendingPathComponent("notes.md")
    try? """
    # Hello Circularity

    Some **bold**, *italic* and `code`, a [link](https://example.com).

    | Format | Size |
    |---|---|
    | JPG | small |

    - one
    - two
      - nested

    ![remote](https://example.invalid/never.png)
    """.write(to: md, atomically: true, encoding: .utf8)
    let mdHTML = output(await run([md], .convert(.html)))
    let mdHTMLText = mdHTML.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    check(mdHTMLText.contains("<h1>Hello Circularity</h1>") && mdHTMLText.contains("<table>") && mdHTMLText.contains("<strong>bold</strong>"),
          "Markdown → HTML has heading, table and emphasis")
    let mdPDF = output(await run([md], .convert(.pdf)))
    check(mdPDF.flatMap { PDFDocument(url: $0)?.string }?.contains("Hello Circularity") == true,
          "Markdown → PDF renders offscreen (remote image blocked, no hang)")
    let mdTXT = output(await run([md], .convert(.txt)))
    check(mdTXT.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("Hello Circularity") == true, "Markdown → TXT")

    let long = root.appendingPathComponent("long.txt")
    try? (1...400).map { "Line \($0): the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")
        .write(to: long, atomically: true, encoding: .utf8)
    let longPDF = output(await run([long], .convert(.pdf)))
    let longPages = longPDF.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
    check(longPages > 3, "long TXT → PDF paginates (\(longPages) pages, \(PaperSize.regional.rawValue))")

    let html = root.appendingPathComponent("page.html")
    try? "<html><body><h1>Web page</h1><img src=\"https://example.invalid/x.png\"><p>Body text</p></body></html>"
        .write(to: html, atomically: true, encoding: .utf8)
    check(output(await run([html], .convert(.pdf))).flatMap { PDFDocument(url: $0)?.string }?.contains("Web page") == true, "HTML → PDF")
    check(output(await run([html], .convert(.txt))).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("Body text") == true, "HTML → TXT")

    let rtf = root.appendingPathComponent("memo.rtf")
    let attributed = NSAttributedString(string: "Memo for the smoke test", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    try? attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])?.write(to: rtf)
    let docx = output(await run([rtf], .convert(.docx)))
    check(docx.map { $0.pathExtension == "docx" && fileSize($0) > 0 } == true, "RTF → DOCX via textutil")
    if let docx {
        check(output(await run([docx], .convert(.pdf))).flatMap { PDFDocument(url: $0)?.string }?.contains("Memo for the smoke test") == true,
              "DOCX → PDF")
        check(output(await run([docx], .convert(.txt))).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("Memo") == true,
              "DOCX → TXT")
    }

    // 9b. Spreadsheets and presentations → PDF (fixtures in Tests/Fixtures/office, copied here first)
    let officeFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/office")
    func office(_ name: String) -> URL? {
        let source = officeFixtures.appendingPathComponent(name), copy = root.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else { return nil }
        try? fm.copyItem(at: source, to: copy)
        return copy
    }
    func pdfText(_ url: URL?) -> String { url.flatMap { PDFDocument(url: $0)?.string } ?? "" }
    func pageSize(_ url: URL?) -> CGSize { url.flatMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .mediaBox).size } ?? .zero }
    func pages(_ url: URL?) -> Int { url.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0 }
    // SMOKE_KEEP=<folder> keeps these PDFs to look at.
    func keep(_ url: URL?) {
        guard let url, let dir = ProcessInfo.processInfo.environment["SMOKE_KEEP"] else { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.copyItem(at: url, to: URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent))
    }
    if let csv = office("sample.csv") {
        let pdf = output(await run([csv], .convert(.pdf)))
        keep(pdf)
        let text = pdfText(pdf)
        check(text.contains("Pune, MH") && text.contains("Ravi \"R\" Kumar") && pageSize(pdf).width > pageSize(pdf).height,
              "CSV → PDF: quoted commas and quotes survive, landscape page")
    } else { check(false, "office fixtures found at \(officeFixtures.path)") }
    if let xlsx = office("sample.xlsx") {
        let pdf = output(await run([xlsx], .convert(.pdf)))
        keep(pdf)
        let text = pdfText(pdf)
        check(text.contains("Subject 20") && text.contains("Student 60") && text.contains("Totals") && text.contains("Total students"),
              "XLSX → PDF: every column and row of a wide sheet, and the second sheet under its name (\(pages(pdf)) pages)")
    }
    // A sheet longer than Quick Look shows (4,096 rows): every row must reach the PDF, dates and percentages shown.
    do {
        let parts = root.appendingPathComponent("long-xlsx", isDirectory: true)
        func put(_ path: String, _ text: String) {
            let url = parts.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        put("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#)
        put("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        put("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Ledger\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        put("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#)
        put("xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><styleSheet xmlns=\"\(ns)\"><cellXfs count=\"3\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"9\"/></cellXfs></styleSheet>")
        var rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Entry</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Date</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Share</t></is></c></row>"
        for r in 2...5001 { rows += "<row r=\"\(r)\"><c r=\"A\(r)\" t=\"inlineStr\"><is><t>Row \(r - 1)</t></is></c><c r=\"B\(r)\" s=\"1\"><v>46346</v></c><c r=\"C\(r)\" s=\"2\"><v>0.25</v></c></row>" }
        put("xl/worksheets/sheet1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"\(ns)\"><sheetData>\(rows)</sheetData></worksheet>")
        let long = root.appendingPathComponent("long.xlsx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); zip.arguments = ["-c", "-k", parts.path, long.path]
        try? zip.run(); zip.waitUntilExit()
        let pdf = output(await run([long], .convert(.pdf)))
        keep(pdf)
        let text = pdfText(pdf)
        check(text.contains("Row 5000") && text.contains("Row 4500") && text.contains("2026-11-20") && text.contains("25%"),
              "XLSX → PDF: a 5,000-row sheet keeps every row (Quick Look stops at 4,096), dates and percentages shown (\(pages(pdf)) pages)")
    }
    let emptyCSV = root.appendingPathComponent("empty.csv")
    try? "".write(to: emptyCSV, atomically: true, encoding: .utf8)
    if case let .failure(error) = await run([emptyCSV], .convert(.pdf)) {
        check(error.localizedDescription.contains("empty"), "an empty CSV says it's empty (\(error.localizedDescription))")
    } else { check(false, "an empty CSV says it's empty instead of making a blank PDF") }
    let damaged = root.appendingPathComponent("damaged.pptx")
    try? Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) }).write(to: damaged)
    if case let .failure(error) = await run([damaged], .convert(.pdf)) {
        check(error.localizedDescription.contains("damaged"), "a damaged PPTX fails with a clear message (\(error.localizedDescription))")
    } else { check(false, "a damaged PPTX fails with a clear message") }
    if let ods = office("sample.ods") {
        let pdf = output(await run([ods], .convert(.pdf)))
        keep(pdf)
        let text = pdfText(pdf)
        check(text.contains("Apples") && text.contains("Fresh every Monday") && pages(pdf) <= 3,
              "ODS → PDF: both sheets, a million repeated empty rows trimmed (\(pages(pdf)) pages)")
    }
    if let pptx = office("sample.pptx") {
        let pdf = output(await run([pptx], .convert(.pdf)))
        keep(pdf)
        let size = pageSize(pdf), text = pdfText(pdf)
        check(pages(pdf) == 3 && abs(size.width / max(size.height, 1) - 16.0 / 9) < 0.02,
              "PPTX → PDF: one 16:9 page per slide (\(pages(pdf)) pages, \(Int(size.width))×\(Int(size.height)))")
        check(text.contains("Bullet points") && text.contains("Pink shape") && text.contains("R2C2"), "PPTX → PDF keeps titles, shapes and tables")
        let first = pdf.flatMap { PDFDocument(url: $0)?.page(at: 0)?.string } ?? ""
        check(first.contains("Circularity deck") && !first.contains("Pink shape"), "PPTX → PDF: each page holds only its own slide")
    }
    if let odp = office("sample.odp") {
        let pdf = output(await run([odp], .convert(.pdf)))
        keep(pdf)
        let size = pageSize(pdf), text = pdfText(pdf)
        check(pages(pdf) == 2 && abs(size.width / max(size.height, 1) - 28 / 15.75) < 0.02,
              "ODP → PDF: one page per slide at the slide's size (\(pages(pdf)) pages, \(Int(size.width))×\(Int(size.height)))")
        check(text.contains("Hello from ODP") && text.contains("Second point") && !text.contains("SECRET SPEAKER NOTES"),
              "ODP → PDF keeps titles and bullets, leaves speaker notes out")
    }
    // Compress for Office files: big photos inside a PPTX and an ODP shrink; same format, same parts, still opens.
    func sh(_ tool: String, _ args: [String], in dir: URL? = nil) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    func zipEntries(_ url: URL) -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo"); p.arguments = ["-1", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
    }
    for (name, media, expected) in [("sample.pptx", "ppt/media", 3), ("sample.odp", "Pictures", 2)] {
        guard let source = office(name) else { continue }
        let parts = root.appendingPathComponent("big-\(name)", isDirectory: true)
        sh("/usr/bin/ditto", ["-x", "-k", source.path, parts.path])
        let pictures = (try? fm.contentsOfDirectory(at: parts.appendingPathComponent(media), includingPropertiesForKeys: nil)) ?? []
        for picture in pictures where ["jpg", "jpeg", "png"].contains(picture.pathExtension.lowercased()) {
            writeImage(photoLikeImage(3200, 2400), picture.pathExtension.lowercased() == "png" ? .png : .jpeg, to: picture)
        }
        let big = root.appendingPathComponent("photos-" + name)
        if name.hasSuffix(".odp") {
            sh("/usr/bin/zip", ["-X", "-0", "-q", big.path, "mimetype"], in: parts)
            sh("/usr/bin/zip", ["-X", "-r", "-q", big.path, ".", "-x", "mimetype"], in: parts)
        } else {
            sh("/usr/bin/zip", ["-X", "-r", "-q", big.path, "."], in: parts)
        }
        let result = await run([big], .compressOffice(.balanced))
        let out = output(result)
        let kind = name.hasSuffix(".odp") ? "ODP" : "PPTX"
        check(out.map { $0.pathExtension == big.pathExtension && $0.lastPathComponent.contains("(compressed)") } == true
              && out.map(fileSize).map { $0 < fileSize(big) / 2 } == true,
              "Compress \(kind): photos inside shrink, same format (\(fileSize(big) / 1000) KB → \(out.map(fileSize).map { $0 / 1000 } ?? 0) KB)")
        if let out {
            check(Set(zipEntries(out)) == Set(zipEntries(big)) && (kind == "PPTX" || zipEntries(out).first == "mimetype"),
                  "Compress \(kind): exactly the same parts\(kind == "ODP" ? ", mimetype first" : "")")
            if kind == "PPTX" {
                // The photo is shown 5 in wide: Balanced (150 ppi) keeps about 750 px, not the 1920 px cap.
                let unpacked = root.appendingPathComponent("unpacked-\(name)", isDirectory: true)
                sh("/usr/bin/ditto", ["-x", "-k", out.path, unpacked.path])
                let media = (try? fm.contentsOfDirectory(at: unpacked.appendingPathComponent(media), includingPropertiesForKeys: nil)) ?? []
                let widths = media.compactMap { url -> Int? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                    return props[kCGImagePropertyPixelWidth] as? Int
                }
                check(!widths.isEmpty && widths.allSatisfy { $0 >= 700 && $0 <= 800 },
                      "Compress PPTX resamples a picture to the size it's shown at, 150 ppi (\(widths) px wide)")
            }
            let pdf = output(await run([out], .convert(.pdf)))
            check(pages(pdf) == expected, "Compress \(kind): the compressed file still opens and converts (\(pages(pdf)) pages)")
            let again = try? await run([out], .compressOffice(.balanced)).get()
            check(again?.outputs.isEmpty == true && again?.notes.first?.contains("Kept the original") == true,
                  "Compress \(kind) again: nothing left to shrink, the original is kept")
        }
    }

    // SMOKE_OFFICE_EXTRA=<folder>: also converts every file there to PDF (real decks and workbooks; kept with SMOKE_KEEP).
    if let extra = ProcessInfo.processInfo.environment["SMOKE_OFFICE_EXTRA"],
       let names = try? fm.contentsOfDirectory(atPath: extra) {
        for name in names.sorted() where !name.hasPrefix(".") {
            let copy = root.appendingPathComponent(name)
            try? fm.copyItem(at: URL(fileURLWithPath: extra).appendingPathComponent(name), to: copy)
            let started = Date()
            let result = await run([copy], .convert(.pdf))
            let pdf = output(result)
            keep(pdf)
            if case let .failure(error) = result { print("EXTRA \(name): \(error.localizedDescription)") }
            print("EXTRA \(name) → \(pages(pdf)) pages, \(Int(pageSize(pdf).width))×\(Int(pageSize(pdf).height)), \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            if OfficeCompressor.canCompress(copy) {
                let squeezed = await run([copy], .compressOffice(.balanced))
                let out = output(squeezed)
                let note = (try? squeezed.get())?.notes.first ?? ""
                keep(out)
                let reopened = out.map { url in Task { await output(run([url], .convert(.pdf))) } }
                let reopenedPDF = await reopened?.value
                if let reopenedPDF, let dir = ProcessInfo.processInfo.environment["SMOKE_KEEP"] {
                    try? fm.copyItem(at: reopenedPDF, to: URL(fileURLWithPath: dir).appendingPathComponent("compressed-" + reopenedPDF.lastPathComponent))
                }
                let reopenedPages = pages(reopenedPDF)
                print("EXTRA \(name) compressed → \(out.map { "\(fileSize(copy) / 1000) KB → \(fileSize($0) / 1000) KB, same parts: \(Set(zipEntries($0)) == Set(zipEntries(copy))), reopens: \(reopenedPages) pages" } ?? note)")
            }
        }
    }

    // 10. Size estimates
    let photoLike = root.appendingPathComponent("photo-like.png")
    writeImage(photoLikeImage(3000, 2000), .png, to: photoLike)
    let estimates = SizeEstimator.estimate(photoLike, formats: [.jpg, .png, .heic, .avif, .tiff, .gif])
    // Derived estimates (no HEIC/AVIF encoder is loaded for the wheel's hints)
    // build on the sampled JPEG estimate, which reads this synthetic noise
    // image ~2× low, so they are held to 3× here; on real photos they land
    // much closer (ratios calibrated on photos, see SizeEstimator). GIF is
    // left out: its size depends on dithering (this noise image is 3.4× the
    // hint), so the GIF hint is only a rough guide.
    for format in [OutputFormat.heic, .avif, .tiff] where support.canWrite(format) {
        if let guess = estimates[format], let real = output(await run([photoLike], .convert(format))) {
            let r = Double(guess) / Double(fileSize(real))
            check(r > 0.33 && r < 3, "\(format.displayName) wheel estimate within 3× (\(guess) vs \(fileSize(real)))")
        } else { check(false, "\(format.displayName) wheel estimate produced") }
    }
    if let estimatedJPG = estimates[.jpg], let realJPG = output(await run([photoLike], .convert(.jpg))) {
        let ratio = Double(estimatedJPG) / Double(fileSize(realJPG))
        check(ratio > 0.5 && ratio < 2, "JPG size estimate within 2× (\(estimatedJPG) vs \(fileSize(realJPG)))")
    } else { check(false, "size estimate produced") }

    // 12. Review fixes
    // A batch with one unreadable file keeps the others' results.
    let good = root.appendingPathComponent("good.png")
    writeImage(noisy(200, 150), .png, to: good)
    let bad = root.appendingPathComponent("bad.png")
    try? Data("not an image".utf8).write(to: bad)
    let mixed = try? await run([good, bad], .convert(.jpg)).get()
    check(mixed?.outputs.count == 1 && mixed?.notes.contains { $0.contains("bad.png") } == true,
          "a batch with one bad file keeps the good result (\(mixed?.notes ?? ["failed"]))")
    if case .failure = await run([bad, bad], .convert(.jpg)) { check(true, "a batch where every file fails is a failure") }
    else { check(false, "a batch where every file fails is a failure") }

    // Crop on a page stored with /Rotate 90: the upright top half is the stored left half.
    let rotatedPDF = root.appendingPathComponent("rotated.pdf")
    makePDF(rotatedPDF, pages: 1)
    if let doc = PDFDocument(url: rotatedPDF), let page = doc.page(at: 0) {
        page.rotation = 90
        doc.write(to: rotatedPDF)
    }
    if let cropped = output(await run([rotatedPDF], .cropPDF(CGRect(x: 0, y: 0, width: 1, height: 0.5)))),
       let page = PDFDocument(url: cropped)?.page(at: 0) {
        let box = page.bounds(for: .cropBox)
        check(abs(box.width - 306) < 1 && abs(box.height - 792) < 1 && box.minX < 1,
              "crop on a rotated PDF page uses the upright top half (cropBox \(box))")
    } else { check(false, "crop on a rotated PDF page") }

    // Animated GIF → GIF keeps looping.
    let anim = root.appendingPathComponent("anim.gif")
    if let dest = CGImageDestinationCreateWithURL(anim as CFURL, UTType.gif.identifier as CFString, 2, nil) {
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for seed in [1, 2] as [UInt64] { CGImageDestinationAddImage(dest, noisy(40, 40, seed: seed), nil) }
        CGImageDestinationFinalize(dest)
    }
    if let gifOut = output(await run([anim], .convert(.gif), {
        var p = policy; p.destination = .folder(root.appendingPathComponent("gif-out", isDirectory: true)); return p }())),
       let src = CGImageSourceCreateWithURL(gifOut as CFURL, nil) {
        let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let loop = (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        check(CGImageSourceGetCount(src) == 2 && loop == 0, "GIF → GIF keeps both frames and loops forever (loop \(loop.map(String.init) ?? "missing"))")
    } else { check(false, "GIF → GIF") }

    // Stretch to another aspect ratio: exact size.
    let wide = root.appendingPathComponent("wide.png")
    writeImage(gradient(4000, 1000), .png, to: wide)
    let stretched = output(await run([wide], .resize(ResizeSpec(width: 1000, height: 900, mode: .stretch))))
    check(stretched.flatMap(pixelSize) == CGSize(width: 1000, height: 900), "stretch 4000×1000 → 1000×900")

    // Cancelling a document job right away: no crash, a clean cancellation.
    let cancelMD = root.appendingPathComponent("cancel.md")
    try? "# Hi\n\ntext".write(to: cancelMD, atomically: true, encoding: .utf8)
    let cancelledDoc = Task { await run([cancelMD], .convert(.docx)) }
    cancelledDoc.cancel()
    if case let .failure(error) = await cancelledDoc.value { check(error is CancellationError, "cancelling a document job at once (\(error))") }
    else { check(true, "cancelling a document job at once finished cleanly") }

    // 13. Cut out (background removal, macOS 14+): a subject on a plain background.
    if Cutout.isAvailable {
        let subject = root.appendingPathComponent("subject.png")
        let w = 900, h = 700
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.91, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.35, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 300, y: 180, width: 300, height: 340))
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.25, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 360, y: 60, width: 180, height: 160))
            if let image = ctx.makeImage() { writeImage(image, .png, to: subject) }
        }
        let cut = await run([subject], .removeBackground)
        switch cut {
        case let .success(r):
            if let out = r.outputs.first {
                let corner = pixel(out, x: 5, y: 5), centre = pixel(out, x: 450, y: 350)
                check(out.pathExtension == "png" && corner.count == 4 && corner[3] < 20 && centre[3] > 200,
                      "cut out: background transparent, subject kept (\(out.lastPathComponent), corner α \(corner.last ?? 255), centre α \(centre.last ?? 0))")
            } else { check(false, "cut out wrote nothing (\(r.notes))") }
        case let .failure(error):
            // Vision found no subject: the error must say so plainly.
            check(error.localizedDescription.contains("subject"), "cut out: \(error.localizedDescription)")
        }
    }

    // Cut out on a black-and-white picture (gray colour space).
    if Cutout.isAvailable {
        let grayURL = root.appendingPathComponent("gray subject.png")
        if let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.setFillColor(gray: 0.92, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            ctx.setFillColor(gray: 0.15, alpha: 1); ctx.fillEllipse(in: CGRect(x: 260, y: 160, width: 280, height: 320))
            if let image = ctx.makeImage() { writeImage(image, .png, to: grayURL) }
        }
        switch await run([grayURL], .removeBackground) {
        case let .success(r): check(r.outputs.first?.pathExtension == "png", "cut out works on a black-and-white picture")
        case let .failure(error): check(error.localizedDescription.contains("subject"), "cut out on gray: \(error.localizedDescription)")
        }
    }

    // 11. Video and audio (AVFoundation; no FFmpeg)
    do {
        let clip = root.appendingPathComponent("clip.mp4")
        let portrait = root.appendingPathComponent("portrait.mp4")
        let big = root.appendingPathComponent("big.mov")
        let tone = root.appendingPathComponent("tone.wav")
        let tone2 = root.appendingPathComponent("tone two.wav")
        try await makeClip(clip, size: CGSize(width: 640, height: 360), seconds: 3, in: root)
        // Recorded sideways, shown upright (as a phone films in portrait).
        try await makeClip(portrait, size: CGSize(width: 480, height: 272), seconds: 2,
                           transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 272, ty: 0), in: root)
        try await writeSilentVideo(big, size: CGSize(width: 1920, height: 1080), seconds: 2)
        try writeTone(tone, seconds: 4)
        try writeTone(tone2, seconds: 2, rate: 48_000, channels: 1)
        let base = await mediaInfo(clip)
        check(base?.video == 1 && base?.audio == 1, "fixture clip has picture and sound")

        func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.15) -> Bool { a.map { abs($0 - b) <= tolerance } ?? false }
        for format in [OutputFormat.mov, .m4v] {
            let out = output(await run([clip], .convert(format)))
            let info = await out.asyncMap(mediaInfo)
            check(out?.pathExtension == format.fileExtension && info?.video == 1 && info?.audio == 1 && near(info?.duration, 3),
                  "MP4 → \(format.displayName): picture, sound, 3 s (\(info.map { String(format: "%.2f s", $0.duration) } ?? "-"))")
        }
        let toMP4 = output(await run([big], .convert(.mp4)))
        check(await toMP4.asyncMap(mediaInfo)?.size == CGSize(width: 1920, height: 1080), "MOV → MP4 keeps 1920 × 1080")

        for format in OutputFormat.audioFormats {
            guard support.canWrite(format) else { print("SKIP  video → \(format.displayName): no encoder on this Mac"); continue }
            let out = output(await run([clip], .convert(format)))
            let info = await out.asyncMap(mediaInfo)
            check(info?.video == 0 && info?.audio == 1 && near(info?.duration, 3, 0.1),
                  "video → \(format.displayName): just the sound, 3 s")
        }
        let gif = output(await run([clip], .convert(.gif)))
        let frames = gif.map(gifFrames)
        check((frames?.count ?? 0) >= 30 && frames?.size.map { max($0.width, $0.height) <= 480 } == true,
              "video → GIF: \(frames?.count ?? 0) frames, \(frames?.size.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "-")")
        let uprightGIF = output(await run([portrait], .convert(.gif))).flatMap(pixelSize)
        check(uprightGIF.map { $0.height > $0.width } == true, "a portrait video makes an upright GIF")

        let trimmed = output(await run([clip], .trimMedia(start: 0.5, end: 2)))
        let trimmedInfo = await trimmed.asyncMap(mediaInfo)
        check(trimmed?.lastPathComponent == "clip (trimmed).mp4" && near(trimmedInfo?.duration, 1.5, 0.2) && trimmedInfo?.audio == 1,
              "trim keeps 0.5–2 s with sound: \(trimmed?.lastPathComponent ?? "-") \(trimmedInfo.map { String(format: "%.2f s", $0.duration) } ?? "-")")

        let muted = output(await run([clip], .removeAudio))
        let mutedInfo = await muted.asyncMap(mediaInfo)
        check(mutedInfo?.video == 1 && mutedInfo?.audio == 0 && muted?.lastPathComponent == "clip (no sound).mp4",
              "mute: picture only (\(muted?.lastPathComponent ?? "-"))")
        switch await run([big], .removeAudio) {
        case .success: check(false, "mute on a silent video should say there's no sound")
        case let .failure(error): check(error.localizedDescription.contains("no sound"), "mute on a silent video: \(error.localizedDescription)")
        }

        for level in PDFCompression.allCases {
            let start = Date()
            let r = try? await run([big], .compressMedia(level)).get()
            let info = await r?.outputs.first.asyncMap(mediaInfo)
            let expected: CGFloat = level == .light ? 1080 : level == .balanced ? 1080 : 720
            check(info?.codec == kCMVideoCodecType_HEVC && info?.size?.height == expected && (r?.bytesOut ?? .max) < (r?.bytesIn ?? 0),
                  String(format: "compress video %@: HEVC, %@ high, %@ → %@ in %.1f s", level.rawValue,
                         info?.size.map { "\(Int($0.height))" } ?? "-", Bytes(r?.bytesIn), Bytes(r?.bytesOut), Date().timeIntervalSince(start)))
        }
        let shrunkClip = try? await run([clip], .compressMedia(.balanced)).get()
        let shrunkInfo = await shrunkClip?.outputs.first.asyncMap(mediaInfo)
        check(shrunkClip?.outputs.isEmpty == true || (shrunkInfo?.audio == 1 && near(shrunkInfo?.duration, 3, 0.2)),
              "compressing a clip keeps its sound and length (or keeps the original: \(shrunkClip?.notes.first ?? "written"))")

        let joined = output(await run([clip, clip], .combineMedia))
        let joinedInfo = await joined.asyncMap(mediaInfo)
        check(near(joinedInfo?.duration, 6, 0.2) && joinedInfo?.audio == 1, "join two clips: 6 s with sound")
        let mixed = output(await run([clip, portrait], .combineMedia))
        let mixedInfo = await mixed.asyncMap(mediaInfo)
        check(near(mixedInfo?.duration, 5, 0.25) && mixedInfo?.size == CGSize(width: 640, height: 360),
              "join landscape + portrait: 5 s in the first clip's 640 × 360 frame (\(mixedInfo?.size.map { "\($0)" } ?? "-"))")

        // Audio
        for format in [OutputFormat.m4a, .aiff, .flac] {
            guard support.canWrite(format) else { print("SKIP  WAV → \(format.displayName): no encoder on this Mac"); continue }
            let out = output(await run([tone], .convert(format)))
            let info = await out.asyncMap(mediaInfo)
            check(info?.audio == 1 && near(info?.duration, 4, 0.1), "WAV → \(format.displayName): 4 s")
        }
        let toneTrim = output(await run([tone], .trimMedia(start: 1, end: 2.5)))
        check(near(await toneTrim.asyncMap(mediaInfo)?.duration, 1.5, 0.05) && toneTrim?.pathExtension == "wav",
              "trim WAV 1–2.5 s stays WAV")
        let toneSmall = try? await run([tone], .compressMedia(.balanced)).get()
        check(toneSmall?.outputs.first?.pathExtension == "m4a" && (toneSmall?.bytesOut ?? .max) < (toneSmall?.bytesIn ?? 0),
              "compress WAV → smaller M4A (\(Bytes(toneSmall?.bytesIn)) → \(Bytes(toneSmall?.bytesOut)))")
        let joinedAudio = output(await run([tone, tone2], .combineMedia))
        let joinedAudioInfo = await joinedAudio.asyncMap(mediaInfo)
        check(joinedAudio?.pathExtension == "wav" && near(joinedAudioInfo?.duration, 6, 0.1),
              "join WAVs of different rates and channels: 6 s WAV")
        let fromM4A = output(await run([output(await run([tone], .convert(.m4a)))!], .convert(.wav)))
        check(near(await fromM4A.asyncMap(mediaInfo)?.duration, 4, 0.1), "M4A → WAV round trip: 4 s")

        // Cancelling a long job leaves nothing behind
        let before = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let task = Task { await run([big], .compressMedia(.light)) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let cancelled = await task.value
        let after = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        check({ if case let .failure(e) = cancelled { return e is CancellationError }; return false }() && after == before,
              "cancelling a video compress writes nothing")
    } catch {
        check(false, "media fixtures: \(error.localizedDescription)")
    }

    // SMOKE_MEDIA_EXTRA=<folder>: your own videos and songs through convert, compress and GIF (kept with SMOKE_KEEP).
    if let extra = ProcessInfo.processInfo.environment["SMOKE_MEDIA_EXTRA"],
       let names = try? fm.contentsOfDirectory(atPath: extra) {
        for name in names.sorted() where !name.hasPrefix(".") {
            let copy = root.appendingPathComponent(name)
            try? fm.copyItem(at: URL(fileURLWithPath: extra).appendingPathComponent(name), to: copy)
            let type = UTType(filenameExtension: copy.pathExtension) ?? .data
            guard MediaSupport.canRead(type) else { print("EXTRA \(name): macOS can't read this (\(type.identifier))"); continue }
            let isVideo = await mediaInfo(copy).map { $0.video > 0 } ?? false
            let half = max(fileSize(copy) / 2, 50_000)
            let ops: [(String, CircularityEngine.Operation)] = isVideo
                ? [("fit half", .fitTo(bytes: half, together: false)), ("2x", .changeSpeed(2)),
                   ("MP4", .convert(.mp4)), ("MOV", .convert(.mov)), ("M4A", .convert(.m4a)), ("GIF", .convert(.gif)),
                   ("compress", .compressMedia(.balanced)), ("trim", .trimMedia(start: 0.2, end: 1.2)), ("mute", .removeAudio)]
                : [("M4A", .convert(.m4a)), ("WAV", .convert(.wav)), ("FLAC", .convert(.flac)), ("compress", .compressMedia(.balanced)),
                   ("trim", .trimMedia(start: 0.2, end: 1.2))]
            for (label, op) in ops {
                let started = Date()
                let result = await run([copy], op)
                switch result {
                case let .success(r):
                    let info = await r.outputs.first.asyncMap(mediaInfo)
                    r.outputs.forEach { keep($0) }
                    let codec = info?.codec.map { c in String((0..<4).map { Character(UnicodeScalar(UInt8((c >> (24 - $0 * 8)) & 0xFF))) }) } ?? "-"
                    print("EXTRA \(name) \(label): \(r.outputs.first?.lastPathComponent ?? (r.notes.first ?? "nothing")) \(Bytes(r.bytesIn)) → \(Bytes(r.bytesOut)), \(codec), \(info.map { String(format: "%.2f s", $0.duration) } ?? "-"), \(info?.size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                case let .failure(error):
                    print("EXTRA \(name) \(label): FAILED \(error.localizedDescription)")
                }
            }
        }
    }

    // 12a. Make it fit, Text, Searchable, Password, Pages, Speed
    do {
        // A picture with words on it, as a phone photo of a sign would be.
        let words = root.appendingPathComponent("sign.png")
        let ctx = CGContext(data: nil, width: 1400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 500))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        for (i, text) in ["Circularity reads text", "Invoice 4821 due Friday"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 60, y: 320 - CGFloat(i) * 150); CTLineDraw(line, ctx)
        }
        writeImage(ctx.makeImage()!, .png, to: words)
        let txt = output(await run([words], .recognizeText))
        let read = txt.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(read.contains("Circularity reads text") && read.contains("4821"), "Text: reads the words in a picture (\(read.replacingOccurrences(of: "\n", with: " / ")))")

        // A scanned PDF: the picture as a page, no text layer.
        let scan = root.appendingPathComponent("scan.pdf")
        _ = await run([words], .convert(.pdf))
        try? fm.moveItem(at: root.appendingPathComponent("sign.pdf"), to: scan)
        check(PDFDocument(url: scan)?.string?.isEmpty != false, "the scan starts with no text to find")
        let searchable = output(await run([scan], .searchablePDF))
        let found = searchable.flatMap { PDFDocument(url: $0)?.string } ?? ""
        check(found.contains("Invoice 4821") && searchable?.lastPathComponent == "scan (searchable).pdf",
              "Searchable PDF: the scan's words can be found (\(found.prefix(40)))")
        let scanText = (try? String(contentsOf: output(await run([scan], .recognizeText))!, encoding: .utf8)) ?? ""
        check(scanText.contains("Circularity"), "Text from a scanned PDF")

        // Password
        let doc = root.appendingPathComponent("private.pdf")
        makePDF(doc, pages: 3)
        let locked = output(await run([doc], .protectPDF(password: "s3cret")))
        check(locked.flatMap { PDFDocument(url: $0) }.map { $0.isLocked && $0.unlock(withPassword: "s3cret") } == true,
              "Lock: the copy asks for the password, and it opens with it (\(locked?.lastPathComponent ?? "-"))")
        if let locked {
            switch await run([locked], .unlockPDF(password: "wrong")) {
            case .success: check(false, "a wrong password should not unlock")
            case let .failure(e): check(e.localizedDescription == "That password doesn't open private (locked).pdf.", "wrong password: \(e.localizedDescription)")
            }
            let unlocked = output(await run([locked], .unlockPDF(password: "s3cret")))
            check(unlocked.flatMap { PDFDocument(url: $0) }.map { !$0.isEncrypted && $0.pageCount == 3 } == true, "Unlock: no password, all 3 pages")
            switch await run([locked], .compressPDF(.balanced)) {
            case .success: check(true, "compressing a locked PDF doesn't crash")
            case let .failure(e): check(true, "compressing a locked PDF says why: \(e.localizedDescription)")
            }
        }

        // Pages: 3 → [3, 1 turned], page 2 left out
        let edited = output(await run([doc], .arrangePDF([PageEdit(index: 2), PageEdit(index: 0, rotation: 90)])))
        let editedDoc = edited.flatMap { PDFDocument(url: $0) }
        let originalDoc = PDFDocument(url: doc)
        check(editedDoc?.pageCount == 2 && editedDoc?.page(at: 0)?.string == originalDoc?.page(at: 2)?.string
              && editedDoc?.page(at: 1)?.rotation == 90 && edited?.lastPathComponent == "private (edited).pdf",
              "Pages: reordered, turned and one left out")

        // Make it fit
        let photoFit = try? await run([photo], .fitTo(bytes: 400_000, together: false)).get()
        check((photoFit?.bytesOut ?? .max) <= 400_000 && photoFit?.outputs.first?.lastPathComponent.contains("(to send)") == true,
              "Fit: a \(Bytes(photoFit?.bytesIn)) picture under 400 KB (\(Bytes(photoFit?.bytesOut)))")
        let already = try? await run([words], .fitTo(bytes: 50_000_000, together: false)).get()
        check(already?.outputs.isEmpty == true && already?.notes.first?.contains("already fits") == true, "Fit: something that already fits is left alone")
        let big = root.appendingPathComponent("big.mov")
        let videoFit = try? await run([big], .fitTo(bytes: 1_500_000, together: false)).get()
        check((videoFit?.bytesOut ?? .max) <= 1_500_000 && (videoFit?.bytesOut ?? 0) >= 600_000,
              "Fit: a \(Bytes(videoFit?.bytesIn)) video under 1.5 MB (\(Bytes(videoFit?.bytesOut)))")
        let tone = root.appendingPathComponent("tone.wav")
        let audioFit = try? await run([tone], .fitTo(bytes: 130_000, together: false)).get()
        check((audioFit?.bytesOut ?? .max) <= 130_000 && audioFit?.outputs.first?.pathExtension == "m4a",
              "Fit: WAV under 130 KB as M4A (\(Bytes(audioFit?.bytesOut)))")
        switch await run([big], .fitTo(bytes: 5_000, together: false)) {
        case .success: check(false, "a video can't fit in 5 KB")
        case let .failure(e): check(e.localizedDescription.contains("can't fit"), "Fit: an impossible size says so (\(e.localizedDescription))")
        }
        let two = try? await run([photo, alphaPNG], .fitTo(bytes: 600_000, together: true)).get()
        check((two?.bytesOut ?? .max) <= 600_000, "Fit together: two pictures share 600 KB (\(Bytes(two?.bytesOut)))")
        let pdfFit = try? await run([doc12], .fitTo(bytes: fileSize(doc12) * 6 / 10, together: false)).get()
        check(pdfFit != nil, "Fit a PDF: \(Bytes(pdfFit?.bytesIn)) → \(Bytes(pdfFit?.bytesOut)) \(pdfFit?.notes.first ?? "")")

        // Speed
        let clip = root.appendingPathComponent("clip.mp4")
        let fast = output(await run([clip], .changeSpeed(2)))
        let fastInfo = await fast.asyncMap(mediaInfo)
        check(abs((fastInfo?.duration ?? 0) - 1.5) < 0.15 && fastInfo?.audio == 1 && fast?.lastPathComponent == "clip (faster).mp4",
              "Speed 2×: 3 s → \(fastInfo.map { String(format: "%.2f s", $0.duration) } ?? "-") with sound")
        let slow = output(await run([tone], .changeSpeed(0.5)))
        let slowInfo = await slow.asyncMap(mediaInfo)
        check(abs((slowInfo?.duration ?? 0) - 8) < 0.2 && slow?.pathExtension == "m4a", "Speed 0.5× on audio: 4 s → 8 s M4A")
        let estimate = await MediaSupport.estimate(clip)
        check((estimate?.compress[.balanced] ?? 0) > 0 && estimate?.formats[.mov] == fileSize(clip), "hover estimates for a video")
        let frames = await MediaSupport.previewFrames(clip, count: 8, maxPixel: 120)
        check(frames.count == 8, "GIF hover preview: 8 frames")
    }

    // 12. Split a PDF into pages
    let splitMe = root.appendingPathComponent("split me.pdf")
    makePDF(splitMe, pages: 3)
    let pagesFolder = output(await run([splitMe], .splitPDF))
    let pageFiles = pagesFolder.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) }?.sorted() ?? []
    check(pageFiles == ["split me page 1.pdf", "split me page 2.pdf", "split me page 3.pdf"],
          "split: one PDF per page in \(pagesFolder?.lastPathComponent ?? "-") \(pageFiles)")

    // 13. Large files (performance report)
    if large {
        let huge = root.appendingPathComponent("huge.png")
        writeImage(gradient(10_000, 10_000), .png, to: huge)
        let start = Date()
        let hugeOut = output(await run([huge], .convert(.jpg)))
        check(hugeOut.flatMap(pixelSize) == CGSize(width: 10_000, height: 10_000),
              String(format: "100 MP PNG → JPG in %.1f s, peak RSS %.0f MB", Date().timeIntervalSince(start), peakRSSMB()))
        let doc200 = root.appendingPathComponent("long.pdf")
        makePDF(doc200, pages: 200, imageEvery: 2)
        let t2 = Date()
        let r = try? await run([doc200], .compressPDF(.balanced)).get()
        check(r != nil, String(format: "200-page PDF compress in %.1f s (%@), peak RSS %.0f MB", Date().timeIntervalSince(t2),
                               r?.outputs.isEmpty == false ? "smaller" : (r?.notes.first ?? "failed"), peakRSSMB()))
    }
}

func Bytes(_ n: Int64?) -> String { n.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-" }

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

Task { @MainActor in
    await runAll()
    print(failures == 0 ? "EngineSmokeTest: all \(passes) checks passed" : "EngineSmokeTest: \(failures) of \(passes + failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
