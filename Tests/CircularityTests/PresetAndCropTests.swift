import CircularityEngine
import CoreGraphics
import UniformTypeIdentifiers
import XCTest

final class PresetTests: XCTestCase {
    func testNamesFitAChip() {
        XCTAssertEqual(Preset(applies: .images, action: .resize(width: 1920, height: nil, stretch: false)).name, "1920w")
        XCTAssertEqual(Preset(applies: .images, action: .resize(width: 1920, height: 1080, stretch: true)).name, "1920×1080")
        XCTAssertEqual(Preset(applies: .images, action: .compressQuality(0.7)).name, "Q70")
        XCTAssertEqual(Preset(applies: .pdfs, action: .compressPDF(.strong)).name, "PDF Strong")
        XCTAssertEqual(Preset(applies: .pdfs, action: .resizePDFPaper(.a4)).name, "A4")
        XCTAssertTrue(Preset(applies: .images, action: .compressTarget(2_000_000)).name.hasPrefix("<2"))
    }

    func testOperations() {
        XCTAssertEqual(Preset(applies: .images, action: .resize(width: 1920, height: nil, stretch: false)).operation,
                       .resize(ResizeSpec(width: 1920, height: nil, mode: .fit)))
        XCTAssertEqual(Preset(applies: .images, action: .compressTarget(500_000)).operation, .compressImage(.targetBytes(500_000)))
        XCTAssertEqual(Preset(applies: .pdfs, action: .resizePDFScale(0.5)).operation, .resizePDF(.scale(0.5)))
    }

    func testJSONRoundTrip() {
        let list = [Preset(applies: .images, action: .compressQuality(0.6)), Preset(applies: .pdfs, action: .compressPDF(.light))]
        XCTAssertEqual(Preset.decodeList(Preset.encodeList(list)), list)
        XCTAssertEqual(Preset.decodeList("not json"), [])
    }

    func testSavedButtonsJoinTheFanForMatchingFilesOnly() {
        let presets = [Preset(applies: .images, action: .resize(width: 1920, height: nil, stretch: false)),
                       Preset(applies: .pdfs, action: .compressPDF(.strong))]
        let images = SlotProvider.menu(for: [.heic], canWrite: { _ in true }, presets: presets)
        XCTAssertEqual(images.fan.first?.label, "1920w")
        XCTAssertEqual(images.fan.first?.action, .preset(presets[0].id))
        XCTAssertFalse(images.fan.contains { $0.label == "PDF Strong" })
        XCTAssertEqual(images.ring[3]?.hint, "\(images.fan.count) more options")
        let pdfs = SlotProvider.menu(for: [.pdf], canWrite: { _ in true }, presets: presets)
        XCTAssertEqual(pdfs.fan.first?.label, "PDF Strong")
        let docs = SlotProvider.menu(for: [.plainText], canWrite: { _ in true }, presets: presets)
        XCTAssertTrue(docs.fan.isEmpty)
    }

    func testAtMostThreeSavedButtons() {
        let presets = (1...5).map { Preset(applies: .images, action: .resize(width: $0 * 100, height: nil, stretch: false)) }
        let menu = SlotProvider.menu(for: [.png], canWrite: { _ in true }, presets: presets)
        XCTAssertEqual(menu.fan.filter { if case .preset = $0.action { return true }; return false }.count, 3)
    }
}

final class CropMathTests: XCTestCase {
    func testCentredRatio() {
        // 16:9 on a 4:3 image: full width, reduced height.
        let r = CropMath.centred(ratio: 16.0 / 9, imageAspect: 4.0 / 3)
        XCTAssertEqual(r.width, 1, accuracy: 0.0001)
        XCTAssertEqual(r.height, (4.0 / 3) / (16.0 / 9), accuracy: 0.0001)
        XCTAssertEqual(r.midY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(CropMath.centred(ratio: nil, imageAspect: 2), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testMoveStaysInside() {
        let r = CropMath.drag(CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), handle: .move,
                              delta: CGVector(dx: 0.5, dy: -0.9), ratio: nil, imageAspect: 1)
        XCTAssertEqual(r.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(r.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(r.width, 0.4, accuracy: 0.0001)
    }

    func testCornerResizeKeepsRatio() {
        let start = CropMath.centred(ratio: 1, imageAspect: 1.5) // square in pixels on a 3:2 image
        let r = CropMath.drag(start, handle: .bottomRight, delta: CGVector(dx: -0.1, dy: 0), ratio: 1, imageAspect: 1.5)
        XCTAssertEqual(r.width * 1.5 / r.height, 1, accuracy: 0.001, "still square in pixels")
        XCTAssertEqual(r.minX, start.minX, accuracy: 0.0001, "the opposite corner stays put")
    }

    func testMinimumSizeAndClamp() {
        let r = CropMath.drag(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), handle: .left,
                              delta: CGVector(dx: 0.9, dy: 0), ratio: nil, imageAspect: 1)
        XCTAssertGreaterThanOrEqual(r.width, 0.05)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(r))
    }
}
