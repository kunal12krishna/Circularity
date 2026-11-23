import CircularityEngine
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import XCTest

final class WheelGeometryTests: XCTestCase {
    private let ring = WheelGeometry.ring()

    func testOffsetsUseClockAngles() {
        let top = WheelGeometry.offset(radius: 100, angle: 0)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertEqual(top.y, -100, accuracy: 0.001, "12 o'clock is up (y-down space)")
        let right = WheelGeometry.offset(radius: 100, angle: 90)
        XCTAssertEqual(right.x, 100, accuracy: 0.001)
        XCTAssertEqual(WheelGeometry.angle(of: CGPoint(x: -100, y: 0)), 270, accuracy: 0.001)
    }

    func testFanMatchesBoardD() {
        let angles = ring.fanAngles(count: 6, flipped: false)
        XCTAssertEqual(angles, [127.5, 148.5, 169.5, 190.5, 211.5, 232.5])
        let heic = ring.fanOffsets(count: 6, flipped: false)[0]
        // Board D: HEIC chip centre at (574.2, 524.4) on a 720 canvas.
        XCTAssertEqual(360 + heic.x, 574.2, accuracy: 0.1)
        XCTAssertEqual(360 + heic.y, 524.4, accuracy: 0.1)
    }

    func testFlippedFanKeepsFormatsRightAndCropLeft() {
        let angles = ring.fanAngles(count: 6, flipped: true)
        XCTAssertEqual(angles.first, 52.5)
        XCTAssertEqual(angles.last, -52.5)
    }

    func testFanFlipsNearTheBottomOfTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(ring.fanNeedsFlip(center: CGPoint(x: 720, y: 450), visibleFrame: visible, count: 6))
        XCTAssertTrue(ring.fanNeedsFlip(center: CGPoint(x: 720, y: 200), visibleFrame: visible, count: 6))
    }

    func testHitTesting() {
        XCTAssertEqual(ring.hitTest(.zero, fanCount: 6, fanOpen: false, fanFlipped: false), .centre)
        XCTAssertEqual(ring.hitTest(CGPoint(x: 0, y: -150), fanCount: 6, fanOpen: false, fanFlipped: false), .segment(0))
        let jpg = WheelGeometry.offset(radius: 150, angle: 60)
        XCTAssertEqual(ring.hitTest(jpg, fanCount: 6, fanOpen: false, fanFlipped: false), .segment(1))
        // The 3° gap between PNG and JPG belongs to the nearest segment, not a dead zone.
        let gap = WheelGeometry.offset(radius: 150, angle: 29.9)
        XCTAssertEqual(ring.hitTest(gap, fanCount: 6, fanOpen: false, fanFlipped: false), .segment(0))
        XCTAssertEqual(ring.hitTest(CGPoint(x: 0, y: -300), fanCount: 6, fanOpen: false, fanFlipped: false), .none)
    }

    func testFanChipsAreHitOnlyWhenOpen() {
        let chip = ring.fanOffsets(count: 6, flipped: false)[2]
        XCTAssertEqual(ring.hitTest(chip, fanCount: 6, fanOpen: true, fanFlipped: false), .fanChip(2))
        XCTAssertEqual(ring.hitTest(chip, fanCount: 6, fanOpen: false, fanFlipped: false), .none)
    }

    func testDismissDistanceExtendsTowardTheOpenFan() {
        let towardFan = WheelGeometry.offset(radius: 255, angle: 180)
        XCTAssertTrue(ring.isBeyondDismissDistance(towardFan, fanCount: 6, fanOpen: false, fanFlipped: false))
        XCTAssertFalse(ring.isBeyondDismissDistance(towardFan, fanCount: 6, fanOpen: true, fanFlipped: false))
        let awayFromFan = WheelGeometry.offset(radius: 255, angle: 0)
        XCTAssertTrue(ring.isBeyondDismissDistance(awayFromFan, fanCount: 6, fanOpen: true, fanFlipped: false))
    }

    func testScaleApplies() {
        let big = WheelGeometry.ring(scale: 1.4)
        XCTAssertEqual(big.size, 1008, accuracy: 0.001)
        XCTAssertEqual(big.outer(hovered: true), 216 * 1.4, accuracy: 0.001)
    }
}

final class SlotProviderTests: XCTestCase {
    private let everything: (OutputFormat) -> Bool = { _ in true }
    private let noWebP: (OutputFormat) -> Bool = { $0 != .webp }

    private func labels(_ slots: [WheelSlot?]) -> [String] { slots.map { $0?.label ?? "—" } }

    func testImageMenuMatchesBoardD() {
        let menu = SlotProvider.menu(for: [.heic], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "WebP", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["AVIF", "TIFF", "GIF", "BMP", "PDF", "Cut out", "Crop"],
                       "HEIC is the source, so BMP fills the fan")
    }

    func testFanForANonHEICSourceIsBoardDExactly() {
        let menu = SlotProvider.menu(for: [.bmp], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "WebP", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["HEIC", "AVIF", "TIFF", "GIF", "PDF", "Cut out", "Crop"])
    }

    func testSourceFormatIsSkipped() {
        let menu = SlotProvider.menu(for: [.png], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["JPG", "WebP", "HEIC", "More", "Compress", "Resize"])
    }

    func testWebPUnavailableMovesUpTheNextFormatAndBMPJoinsTheFan() {
        let menu = SlotProvider.menu(for: [.jpeg], canWrite: noWebP)
        XCTAssertEqual(labels(menu.ring), ["PNG", "HEIC", "AVIF", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.fan.map(\.label), ["TIFF", "GIF", "BMP", "PDF", "Cut out", "Crop"])
    }

    func testToolsAndMoreNeverMoveWithSmartOrdering() {
        let usage = ["convert.gif": 9, "convert.tiff": 4]
        let menu = SlotProvider.menu(for: [.heic], canWrite: everything, usage: usage, smartOrdering: true)
        XCTAssertEqual(labels(menu.ring), ["GIF", "TIFF", "PNG", "More", "Compress", "Resize"])
    }

    func testImageBatchPutsCombineOnTheRing() {
        let menu = SlotProvider.menu(for: [.jpeg, .png], canWrite: everything)
        XCTAssertEqual(menu.ring[2]?.action, .combinePDF, "board B: Combine sits on the ring for batches")
        XCTAssertEqual(menu.ring[2]?.verb, "Combine into one PDF")
        XCTAssertEqual(menu.ring[0]?.verb, "Convert 2 to PNG")
        XCTAssertEqual(menu.fan.first { $0.action == .combinePDF }?.label, "1 PDF", "the fan offers one combined PDF…")
        XCTAssertEqual(menu.fan.first { $0.action == .convert(.pdf) }?.label, "2 PDFs", "…or a separate PDF per image")
        XCTAssertEqual(menu.fan.last?.action, .crop, "Crop stays last (leftmost)")
        XCTAssertTrue(menu.fan.contains { $0.action == .convert(.webp) }, "the displaced format moves to the fan")
    }

    func testPDFMenu() {
        let menu = SlotProvider.menu(for: [.pdf], canWrite: everything)
        XCTAssertEqual(labels(menu.ring), ["PNG", "JPG", "TXT", "More", "Compress", "Resize"])
        XCTAssertEqual(menu.ring[0]?.action, .pdfPages(.png))
        XCTAssertEqual(menu.fan.map(\.label), ["Crop"])
    }

    func testDocumentMenus() {
        let md = SlotProvider.menu(for: [UTType("net.daringfireball.markdown")!], canWrite: everything)
        XCTAssertEqual(labels(md.ring), ["PDF", "HTML", "TXT", "—", "—", "—"])
    }

    func testOfficeFilesGetPDFAndCompressOnly() {
        // Word, Excel, PowerPoint and their open formats: PDF, plus Compress where the file is a zip package.
        for id in ["org.openxmlformats.wordprocessingml.document", "org.oasis-open.opendocument.text",
                   "org.openxmlformats.spreadsheetml.sheet", "org.oasis-open.opendocument.spreadsheet",
                   "org.openxmlformats.presentationml.presentation", "org.oasis-open.opendocument.presentation"] {
            let menu = SlotProvider.menu(for: [UTType(id)!], canWrite: everything)
            XCTAssertEqual(labels(menu.ring), ["PDF", "Compress", "—", "—", "—", "—"], id)
            XCTAssertEqual(menu.ring[0]?.action, .convert(.pdf), id)
            XCTAssertEqual(menu.ring[1]?.action, .compress, id)
            XCTAssertTrue(menu.fan.isEmpty, id)
        }
        // The older binary formats, RTF and CSV can't be compressed: PDF alone.
        for id in ["com.microsoft.word.doc", "public.rtf", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
                   "public.comma-separated-values-text"] {
            XCTAssertEqual(labels(SlotProvider.menu(for: [UTType(id)!], canWrite: everything).ring), ["PDF", "—", "—", "—", "—", "—"], id)
        }
        let hints = [("org.openxmlformats.spreadsheetml.sheet", "every sheet, fitted to the page"),
                     ("org.openxmlformats.presentationml.presentation", "one page per slide"),
                     ("org.openxmlformats.wordprocessingml.document", "every page, as a PDF")]
        for (id, hint) in hints {
            XCTAssertEqual(SlotProvider.menu(for: [UTType(id)!], canWrite: everything).ring[0]?.hint, hint, id)
        }
        // A workbook and a deck together aren't one kind: nothing to offer.
        let mixed = SlotProvider.menu(for: [UTType("org.openxmlformats.spreadsheetml.sheet")!,
                                            UTType("org.openxmlformats.presentationml.presentation")!], canWrite: everything)
        XCTAssertTrue(mixed.isEmpty)
    }

    func testVideoGetsFormatsGIFCompressAndTrim() {
        let menu = SlotProvider.menu(for: [.mpeg4Movie], canWrite: everything)
        XCTAssertNil(menu.notice)
        XCTAssertEqual(menu.ring.map { $0?.action }, [.convert(.mov), .convert(.m4v), .convert(.gif), .more, .compress, .trim],
                       "an MP4 isn't offered MP4")
        XCTAssertEqual(menu.fan.map(\.action), [.convert(.m4a), .convert(.wav), .convert(.aiff), .convert(.flac), .mute])
        XCTAssertEqual(menu.fan.first?.kicker, "SOUND AS")
    }

    func testSeveralVideosJoinInsteadOfTrim() {
        let menu = SlotProvider.menu(for: [.quickTimeMovie, .quickTimeMovie], canWrite: everything)
        XCTAssertEqual(menu.ring.map { $0?.action }, [.convert(.mp4), .convert(.m4v), .convert(.gif), .more, .compress, .combineMedia])
        XCTAssertFalse(menu.fan.contains { $0.action == .trim })
    }

    func testAudioGetsAudioFormats() {
        let menu = SlotProvider.menu(for: [.mp3], canWrite: everything)
        XCTAssertEqual(menu.ring.map { $0?.action }, [.convert(.m4a), .convert(.wav), .convert(.aiff), .more, .compress, .trim])
        XCTAssertEqual(menu.fan.map(\.action), [.convert(.flac)])
        // No FLAC encoder on this Mac: no More either.
        let noFLAC = SlotProvider.menu(for: [.wav], canWrite: { $0 != .flac })
        XCTAssertEqual(noFLAC.ring.map { $0?.action }, [.convert(.m4a), .convert(.aiff), nil, nil, .compress, .trim])
    }

    func testVideoAndAudioTogetherOfferTheSoundButNoJoin() {
        let menu = SlotProvider.menu(for: [.mpeg4Movie, .mp3], canWrite: everything)
        XCTAssertEqual(menu.ring[0]?.action, .convert(.m4a))
        XCTAssertNil(menu.ring[5])
    }

    // MARK: Tools and Actions wheels

    func testToolsWheelPerKind() {
        let image = SlotProvider.toolsMenu(for: [.jpeg], cutout: true)
        XCTAssertEqual(image.kind, .tools)
        XCTAssertEqual(image.ring.map { $0?.action }, [.compress, .fit, .copyText, .more, .crop, .resize])
        XCTAssertEqual(image.fan.map(\.action), [.cutout, .convert(.pdf), .searchable, .stripLocation])
        let pdf = SlotProvider.toolsMenu(for: [.pdf])
        XCTAssertEqual(pdf.ring.map { $0?.action }, [.compress, .fit, .copyText, .more, .editPages, .password])
        XCTAssertEqual(pdf.fan.map(\.action), [.searchable, .splitPDF, .resize, .crop])
        let pdfs = SlotProvider.toolsMenu(for: [.pdf, .pdf])
        XCTAssertEqual(pdfs.ring[4]?.action, .combinePDF, "two PDFs: Combine instead of Pages")
        let video = SlotProvider.toolsMenu(for: [.mpeg4Movie])
        XCTAssertEqual(video.ring.map { $0?.action }, [.trim, .compress, .fit, .more, .speed, .mute])
        XCTAssertEqual(video.fan.map(\.action), [.convert(.gif), .convert(.m4a)])
        let songs = SlotProvider.toolsMenu(for: [.mp3, .mp3])
        XCTAssertEqual(songs.ring.map { $0?.action }, [.compress, .fit, .speed, .combineMedia, nil, nil])
        let word = SlotProvider.toolsMenu(for: [UTType("org.openxmlformats.wordprocessingml.document")!])
        XCTAssertEqual(word.ring.map { $0?.action }, [.compress, .fit, nil, nil, nil, nil])
    }

    /// Every button on every wheel: words that fit their spot, and an icon this Mac has.
    func testEveryButtonFitsAndHasAnIcon() {
        let docx = UTType("org.openxmlformats.wordprocessingml.document")!
        let kinds: [[UTType]] = [[.heic], [.png, .png], [.pdf], [.pdf, .pdf], [.mpeg4Movie], [.mpeg4Movie, .mpeg4Movie],
                                 [.mp3], [.mp3, .wav], [docx], [.folder], [.heic, .pdf]]
        var menus: [WheelMenu] = kinds.flatMap { types in
            [SlotProvider.menu(for: types, canWrite: everything), SlotProvider.toolsMenu(for: types, cutout: true)]
        }
        menus += [SlotProvider.actionsMenu(count: 1), SlotProvider.actionsMenu(count: 3)]
        for slot in menus.flatMap({ $0.ring.compactMap { $0 } + $0.fan }) {
            XCTAssertLessThanOrEqual(slot.label.count, 8, "Ring/Orbit label too long: \(slot.label)")
            XCTAssertLessThanOrEqual(slot.monoLabel.count, 7, "Halo label too long: \(slot.monoLabel)")
            XCTAssertLessThanOrEqual(slot.caption.count, 11, "caption too long: \(slot.caption)")
            XCTAssertLessThanOrEqual(slot.big.count, 9, "centre word too long: \(slot.big)")
            XCTAssertLessThanOrEqual(slot.kicker.count, 13, "centre line too long: \(slot.kicker)")
            XCTAssertNotNil(NSImage(systemSymbolName: slot.symbol, accessibilityDescription: nil), "no such icon: \(slot.symbol)")
        }
    }

    func testAMixOfKindsCanStillBeMadeToFit() {
        let menu = SlotProvider.toolsMenu(for: [.heic, .mpeg4Movie, .pdf])
        XCTAssertEqual(menu.ring[0]?.action, .fit)
        XCTAssertNil(menu.notice)
        XCTAssertTrue(SlotProvider.toolsMenu(for: [.heic, .folder]).isEmpty, "a folder can't be made to fit")
    }

    func testToolsWheelHasNothingForAFolder() {
        let menu = SlotProvider.toolsMenu(for: [.folder])
        XCTAssertTrue(menu.isEmpty)
        XCTAssertEqual(menu.notice?.big, "Folder")
    }

    func testMoreThanSixToolsUseMore() {
        let slots = (0..<8).map { _ in SlotProvider.cropSlot(count: 1) }
        let menu = SlotProvider.ringWithMore(slots)
        XCTAssertEqual(menu.ring.count, 6)
        XCTAssertEqual(menu.ring.firstIndex { $0?.action == .more }, 3)
        XCTAssertEqual(menu.fan.count, 3)
    }

    func testActionsWheelIsTheSameForEverything() {
        let menu = SlotProvider.actionsMenu(count: 2)
        XCTAssertEqual(menu.kind, .actions)
        XCTAssertEqual(menu.ring.map { $0?.action }, [.file(.airDrop), .file(.copy), .file(.zip), .more, .file(.copyPath), .file(.stash)])
        XCTAssertEqual(menu.fan.map(\.action), [.file(.mail), .file(.terminal), .file(.moveTo), .file(.copyTo), .file(.quickLook), .file(.reveal)])
        XCTAssertEqual(menu.ring[4]?.hint, "one path per line")
        XCTAssertEqual(menu.ring[2]?.hint, "one .zip with all 2")
    }

    func testWheelKeysNeverShareAKey() {
        let map = WheelKeyMap(convert: "shift", tools: "command", actions: "control")
        XCTAssertEqual(map.kinds(down: ["command", "option"]), [.tools])
        XCTAssertEqual(map.restHint(for: .convert), "⌘ tools · ⌃ actions")
        XCTAssertEqual(map.restHint(for: .actions), "⇧ convert · ⌘ tools")
        // Convert on Control (an older setting) takes it from Actions.
        let clash = WheelKeyMap(convert: "control", tools: "command", actions: "control")
        XCTAssertEqual(clash.key(for: .convert), "control")
        XCTAssertNil(clash.key(for: .actions))
        XCTAssertNotNil(clash.conflict(for: .actions, wanted: "control"))
        XCTAssertEqual(clash.restHint(for: .convert), "⌘ tools")
        let off = WheelKeyMap(convert: "shift", tools: "off", actions: "off")
        XCTAssertNil(off.restHint(for: .convert))
        XCTAssertNil(off.conflict(for: .tools, wanted: "off"))
    }

    func testMixedImagesAndPDFsOfferCombine() {
        let menu = SlotProvider.menu(for: [.png, .pdf], canWrite: everything)
        XCTAssertEqual(menu.ring[0]?.action, .combinePDF)
    }

    func testUnsupportedFilesExplainThemselves() {
        let menu = SlotProvider.menu(for: [.zip], canWrite: everything)
        XCTAssertEqual(menu.notice?.kicker, "CAN'T CONVERT")
        XCTAssertEqual(menu.notice?.big, "ZIP")
    }
}

final class WheelTweaksTests: XCTestCase {
    func testBoardTweaksChangeNothing() {
        XCTAssertEqual(WheelGeometry.make(.ring, tweaks: .board), WheelGeometry.ring())
        XCTAssertEqual(WheelGeometry.make(.halo, tweaks: .board), WheelGeometry.halo())
    }

    func testThicknessGapAndOrb() {
        let g = WheelGeometry.make(.ring, tweaks: WheelTweaks(thickness: 1.2, gap: 6, orbScale: 1.15))
        XCTAssertEqual(g.restInner, 98)
        XCTAssertEqual(g.restOuter, 98 + 106 * 1.2, accuracy: 0.001)
        XCTAssertEqual(g.hoverOuter - g.restOuter, 12, accuracy: 0.001, "the bulge stays the same")
        XCTAssertEqual(g.segmentSpan, 54)
        XCTAssertLessThanOrEqual(g.orbDiameter, g.restInner * 2 - 8, "the orb never grows into the segments")
        XCTAssertGreaterThanOrEqual(g.discDiameter / 2, g.hoverOuter, "the disc still contains the bulge")
    }

    func testOutOfRangeValuesAreClamped() {
        let g = WheelGeometry.make(.ring, tweaks: WheelTweaks(thickness: 9, gap: 40, orbScale: 0.1))
        XCTAssertEqual(g.restOuter, 98 + 106 * 1.2, accuracy: 0.001)
        XCTAssertEqual(g.segmentSpan, 52)
        XCTAssertEqual(g.orbDiameter, 180 * 0.85, accuracy: 0.001)
    }
}

final class FormatOrderTests: XCTestCase {
    func testOrderSettingIsParsedAndCompleted() {
        let order = SlotProvider.imageFormatOrder("heic, JPEG,bogus,png,heic")
        XCTAssertEqual(Array(order.prefix(3)), [.heic, .jpg, .png])
        XCTAssertEqual(Set(order), Set(SlotProvider.ringImageCandidates), "every format is still offered")
        XCTAssertEqual(SlotProvider.imageFormatOrder(""), SlotProvider.ringImageCandidates)
    }

    func testRingFollowsTheOrder() {
        let menu = SlotProvider.menu(for: [.png], canWrite: { _ in true }, presets: [],
                                     formatOrder: SlotProvider.imageFormatOrder("avif,heic,jpg"))
        XCTAssertEqual(menu.ring.prefix(3).map { $0?.action }, [.convert(.avif), .convert(.heic), .convert(.jpg)])
    }
}

final class CustomSlotsTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SlotProvider.parseSlots("png, jpg,cutout,more,compress,resize"), ["png", "jpg", "cutout", "more", "compress", "resize"])
        XCTAssertNil(SlotProvider.parseSlots(""), "empty = built-in layout")
        XCTAssertNil(SlotProvider.parseSlots("png,jpg,webp,compress,resize,crop"), "More is required")
        XCTAssertNil(SlotProvider.parseSlots("png,png,webp,more,compress,resize"), "no duplicates")
        XCTAssertNil(SlotProvider.parseSlots("png,jpg,mp4,more,compress,resize"), "unknown token")
    }

    func testCustomRingAndFan() {
        let menu = SlotProvider.menu(for: [.heic], canWrite: { _ in true }, presets: [],
                                     slots: ["cutout", "jpg", "png", "more", "crop", "compress"], cutout: true)
        XCTAssertEqual(menu.ring.map { $0?.action }, [.cutout, .convert(.jpg), .convert(.png), .more, .crop, .compress])
        XCTAssertTrue(menu.fan.contains { $0.action == .resize }, "tools not on the ring go into the fan")
        XCTAssertFalse(menu.fan.contains { $0.action == .crop }, "no duplicates between ring and fan")
        XCTAssertFalse(menu.fan.contains { $0.action == .convert(.heic) }, "not the file's own format")
    }

    func testOwnFormatAndUnwritableAreReplaced() {
        let menu = SlotProvider.menu(for: [.png], canWrite: { $0 != .webp }, presets: [],
                                     slots: ["png", "webp", "jpg", "more", "compress", "resize"], cutout: true)
        let formats = menu.ring.prefix(3).compactMap { $0?.action }
        XCTAssertEqual(formats.count, 3, "every slot is filled")
        XCTAssertFalse(formats.contains(.convert(.png)), "the file is already PNG")
        XCTAssertFalse(formats.contains(.convert(.webp)), "this Mac can't write WebP")
        XCTAssertEqual(Set(formats).count, 3, "no format twice")
    }

    func testCutoutOnlyWhereAvailable() {
        let old = SlotProvider.menu(for: [.jpeg], canWrite: { _ in true }, presets: [],
                                    slots: ["cutout", "png", "webp", "more", "compress", "resize"], cutout: false)
        XCTAssertFalse(old.ring.contains { $0?.action == .cutout } || old.fan.contains { $0.action == .cutout })
        let builtIn = SlotProvider.menu(for: [.jpeg], canWrite: { _ in true }, presets: [], cutout: true)
        XCTAssertTrue(builtIn.fan.contains { $0.action == .cutout }, "the built-in wheel has Cut out under More")
    }
}
