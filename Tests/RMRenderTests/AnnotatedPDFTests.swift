// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import ImageIO
import RMLines
@testable import RMRender
import Testing

// A page of an imported PDF and a page added on the tablet are told apart by
// one thing: whether `redir` is there. Read that wrong and the marks land on
// someone else's page — a document that looks entirely fine and is wrong.

@Test("A page of the imported file carries its number, an inserted one does not")
func redirTellsInsertedPagesApart() throws {
    // Shaped after a real file: the first pages come from the PDF,
    // the last was added on the tablet and has no `redir` key at all.
    let content = """
    {"formatVersion": 2, "cPages": {"pages": [
      {"id": "p0", "redir": {"timestamp": "1:2", "value": 0}, "template": {"timestamp": "1:2", "value": "Blank"}},
      {"id": "p1", "redir": {"timestamp": "1:2", "value": 1}, "template": {"timestamp": "1:2", "value": "Blank"}},
      {"id": "p3", "template": {"timestamp": "1:2", "value": "Blank"}}
    ]}}
    """

    let layout = try PageOrder.layout(from: Data(content.utf8))

    #expect(layout.pages.map(\.id) == ["p0", "p1", "p3"])
    #expect(layout.pages.map(\.redir) == [0, 1, nil])
}

@Test("The flat form maps pages by position")
func flatRedirectionMapIsRead() throws {
    // A one-page document carries this shape instead
    // of `cPages`. Both forms occur, so both are read.
    let content = #"{"pages": ["p0", "p1", "p2"], "redirectionPageMap": [0, 1, 2]}"#

    let layout = try PageOrder.layout(from: Data(content.utf8))

    #expect(layout.pages.map(\.id) == ["p0", "p1", "p2"])
    #expect(layout.pages.map(\.redir) == [0, 1, 2])
}

@Test("Without a map the flat form claims no page of the original")
func flatFormWithoutMapHasNoRedirection() throws {
    let layout = try PageOrder.layout(from: Data(#"{"pages": ["p0"]}"#.utf8))

    // A notebook has no imported file behind it. Answering zero here would
    // put its every page on page one of a PDF that does not exist.
    #expect(layout.pages.map(\.redir) == [nil])
}

@Test("An inserted page is sized from the panel it was made on")
func insertedPageKeepsItsDeviceSheet() {
    // Both numbers come from the same source: the scene block of the page's own `.rm`
    // against the sheet the tablet's app exported for it.
    let rm2 = AnnotationGeometry.sheet(forScene: CGSize(width: 1404, height: 1872))
    let move = AnnotationGeometry.sheet(forScene: CGSize(width: 820, height: 1458))

    // Within a point of the export, and a point is as fine as the comparison
    // goes: the sheets of the reference were read to whole points, while the
    // unit is the tablet's own `0.317180616` out of its content stream.
    #expect(abs(rm2.width - 445.6) < 1)
    #expect(abs(rm2.height - 594.1) < 1)
    // The export of that document gave 260 × 463 pt for the pages added on a
    // Paper Pro Move.
    #expect(abs(move.width - 260) < 1)
    #expect(abs(move.height - 463) < 1)
}

@Test("Points and units are one measurement read two ways")
func unitsRoundTrip() {
    let sheet = CGSize(width: 612, height: 792)
    let units = AnnotationGeometry.units(of: sheet)

    // US Letter is about 1928 × 2495 units of the panel — wider than the 1404
    // of an rM2 screen, and that is the point: the coordinates are in the
    // space of the page, not of the display.
    #expect(units.width > 1900 && units.width < 1950)
    #expect(abs(units.width * Calibration.pointsPerUnit - 612) < 0.01)
    #expect(abs(units.height * Calibration.pointsPerUnit - 792) < 0.01)
}

// MARK: - The box a page is shown as

/// US Letter, the format the overflow is shown on.
private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

private func marks(from left: Double, to right: Double) -> RMPage {
    RMPage(
        strokes: [
            Stroke(
                tool: .fineliner1,
                color: .black,
                thicknessScale: 1,
                points: [
                    StrokePoint(x: Float(left), y: 100, width: 2, pressure: 1),
                    StrokePoint(x: Float(right), y: 200, width: 2, pressure: 1),
                ]
            )
        ],
        skippedBlocks: 0
    )
}

@Test("A page whose marks stay on it is shown as the page it was")
func boxHoldsWhenNothingRunsOffTheSheet() {
    let units = AnnotationGeometry.units(of: letter.size)
    let box = AnnotationGeometry.box(
        PageRenderer.contentBounds(
            of: marks(from: 0, to: 100),
            pageSize: units,
            edge: AnnotatedPDFRenderer.markEdge
        ),
        on: letter
    )

    // Every ordinary document goes through this, so an imported PDF has to
    // come back out at the size it went in at.
    #expect(abs(box.minX - letter.minX) < 0.01)
    #expect(abs(box.minY - letter.minY) < 0.01)
    #expect(abs(box.width - letter.width) < 0.01)
    #expect(abs(box.height - letter.height) < 0.01)
}

@Test("A page written in the margins is shown wider, as the tablet shows it")
func boxGrowsAroundMarksWrittenOffTheSheet() {
    let units = AnnotationGeometry.units(of: letter.size)
    // A US Letter test page annotated in both margins
    // comes out of the tablet's app as /MediaBox [-207.95 0 858.65 792]. These
    // are the same two overflows in `.rm` units, less the 40 units of margin
    // `contentBounds` leaves along a side that grew.
    let page = marks(from: -units.width / 2 - 615, to: units.width / 2 + 735)

    let bounds = PageRenderer.contentBounds(of: page, pageSize: units, edge: AnnotatedPDFRenderer.markEdge)
    let box = AnnotationGeometry.box(bounds, on: letter)

    // Within a couple of points of the export, and that is as fine as the
    // comparison goes: the margin along a grown side is chosen by eye, and
    // the format keeps coordinates as 32-bit floats.
    #expect(abs(box.minX - -207.95) < 2, "the sheet grew to the left")
    #expect(abs(box.maxX - 858.65) < 2, "and to the right")
    #expect(box.minY == letter.minY, "nothing was written past the bottom")
    #expect(abs(box.height - letter.height) < 0.01, "so the height is the page's own")
}

@Test("A page that does not stand at the origin grows around where it stands")
func boxFollowsASheetWithAnOffsetOrigin() {
    // The overlay hands over the page's own media box, and a scanner's page
    // need not begin at zero. Growing around the origin instead of around the
    // page would move the whole sheet.
    let offset = CGRect(x: 20, y: 30, width: 612, height: 792)
    let units = AnnotationGeometry.units(of: offset.size)
    let page = marks(from: -units.width / 2 - 615, to: 0)

    let bounds = PageRenderer.contentBounds(of: page, pageSize: units, edge: AnnotatedPDFRenderer.markEdge)
    let box = AnnotationGeometry.box(bounds, on: offset)

    #expect(abs(box.minX - (20 - 207.95)) < 2)
    #expect(abs(box.maxX - offset.maxX) < 0.01, "nothing ran off the right, so that edge holds")
    #expect(abs(box.minY - offset.minY) < 0.01)
}

/// One page drawn the way the renderer draws it, as a file.
private func drawnPage(source: CGPDFPage?, marks: RMPage?, sheet: CGSize) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: sheet)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    AnnotatedPDFRenderer.drawPage(source: source, marks: marks, sheet: sheet, into: context)
    context.closePDF()
    return url
}

/// A page of an imported file: a grey square at a known place on the sheet.
private func importedPage(sheet: CGSize, square: CGRect) throws -> (URL, CGPDFPage) {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: sheet)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(square)
    context.endPDFPage()
    context.closePDF()
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    return (url, try #require(document.page(at: 1)))
}

/// The dark pixels of a rectangle of the page, in the page's own coordinates.
///
/// Against the tablet's own export: assuming the wrong one
/// twice gives two different answers: `drawPDFPage` draws at the page's own
/// coordinates and pays no attention to where its box begins. PDFKit's
/// `PDFPage.draw(with:to:)` is the one that puts the corner of the box at the
/// origin — mixing the two up is what made a throwaway probe agree with a
/// wrong fix.
private func darkPixels(of page: CGPDFPage, in rectangle: CGRect) throws -> Int {
    let width = Int(rectangle.width), height = Int(rectangle.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: -rectangle.minX, y: -rectangle.minY)
    context.drawPDFPage(page)
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    return stride(from: 0, to: width * height * 4, by: 4).count { Int(buffer[$0]) < 200 }
}

@Test("Marks written in the margins are on the page, and the sheet has not moved")
func drawnPageKeepsTheImportedSheetWhereItWas() throws {
    let sheet = CGSize(width: 612, height: 792)
    let units = AnnotationGeometry.units(of: sheet)
    let square = CGRect(x: 5, y: 700, width: 40, height: 40)
    let (imported, source) = try importedPage(sheet: sheet, square: square)
    // One stroke off the left edge and one off the right, as on the reference
    // test page.
    let page = marks(from: -units.width / 2 - 615, to: units.width / 2 + 735)

    let url = try drawnPage(source: source, marks: page, sheet: sheet)
    defer {
        try? FileManager.default.removeItem(at: imported)
        try? FileManager.default.removeItem(at: url)
    }

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawn = try #require(document.page(at: 1))
    let box = drawn.getBoxRect(.mediaBox)
    #expect(abs(box.width - 1066.6) < 4, "as wide as the tablet's own export")
    #expect(drawn.getBoxRect(.artBox) == CGRect(origin: .zero, size: sheet), "the imported sheet")

    // Both margins carry ink — the whole point of growing the box.
    #expect(try darkPixels(of: drawn, in: CGRect(x: box.minX, y: 0, width: 150, height: 792)) > 0)
    #expect(try darkPixels(of: drawn, in: CGRect(x: sheet.width + 60, y: 0, width: 150, height: 792)) > 0)

    // And the imported page has not moved on its own sheet. This is the other
    // way it goes wrong, and it looks entirely plausible while it does: a
    // translation to "match" the new box slides the whole document sideways
    // by the width of the growth.
    #expect(try darkPixels(of: drawn, in: square) > 1000)
    #expect(
        try darkPixels(of: drawn, in: square.offsetBy(dx: -box.minX, dy: 0)) < 100,
        "nothing stands where a sliding page would have put it"
    )
}

@Test("A page nobody wrote in the margins of comes out the size it went in at")
func drawnPageWithoutOverflowKeepsItsSheet() throws {
    let sheet = CGSize(width: 612, height: 792)
    let square = CGRect(x: 5, y: 700, width: 40, height: 40)
    let (imported, source) = try importedPage(sheet: sheet, square: square)

    let url = try drawnPage(source: source, marks: marks(from: 0, to: 100), sheet: sheet)
    defer {
        try? FileManager.default.removeItem(at: imported)
        try? FileManager.default.removeItem(at: url)
    }

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawn = try #require(document.page(at: 1))

    // The ordinary document, which is every document: it must come out at the
    // size it went in at, with its content where it was.
    #expect(abs(drawn.getBoxRect(.mediaBox).width - sheet.width) < 0.01)
    #expect(abs(drawn.getBoxRect(.mediaBox).minX) < 0.01)
    #expect(try darkPixels(of: drawn, in: square) > 1000)
}

// Hiding the source PDF is the user's own edit, written into the scene info
// block of the page. Drawing the page anyway shows what they put away — the
// marks have to come out on a blank sheet of the same size, as the tablet
// shows them.
@Test("A hidden source page is left out, and the sheet keeps its size")
func hiddenSourcePageIsNotDrawn() throws {
    let sheet = CGSize(width: 612, height: 792)
    let square = CGRect(x: 5, y: 700, width: 40, height: 40)
    let (imported, source) = try importedPage(sheet: sheet, square: square)
    let hidden = RMPage(
        strokes: [
            Stroke(
                tool: .fineliner1,
                color: .black,
                thicknessScale: 4,
                points: [
                    StrokePoint(x: 0, y: 100, width: 40, pressure: 200),
                    StrokePoint(x: 100, y: 200, width: 40, pressure: 200),
                ]
            )
        ],
        skippedBlocks: 0,
        rootDocumentVisible: false
    )

    let url = try drawnPage(source: source, marks: hidden, sheet: sheet)
    defer {
        try? FileManager.default.removeItem(at: imported)
        try? FileManager.default.removeItem(at: url)
    }

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawn = try #require(document.page(at: 1))

    #expect(abs(drawn.getBoxRect(.mediaBox).width - sheet.width) < 0.01,
            "hiding changes what is drawn, not the geometry")
    #expect(try darkPixels(of: drawn, in: square) == 0, "the imported page is not on the sheet")
    // The marks still are — the only dark thing left on the sheet.
    #expect(
        try darkPixels(of: drawn, in: CGRect(origin: .zero, size: sheet)) > 0,
        "the user's marks stay"
    )
}

/// A tiny PNG: the top half one colour, the bottom half another — enough to
/// see both that the image lands and that it lands the right way up.
private func testPNG(size: Int = 8) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    // The bitmap counts y up: the bottom half is white, the top black.
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

// A capture is the page: the tablet rasterises everything it grabs, and a
// page of captures carries not one stroke. Without the image items read, such
// a page would come out blank.
@Test("An image is drawn inside its quad and the right way up")
func imageIsDrawnInItsQuad() throws {
    let sheet = CGSize(width: 612, height: 792)
    // A quad around the sheet's centre: page units count x from the middle.
    let quad = RMPage(
        strokes: [],
        skippedBlocks: 0,
        images: [
            PageImage(
                file: "img.png",
                vertices: [
                    PageImage.Vertex(x: -100, y: 200, u: 0, v: 0),
                    PageImage.Vertex(x: 100, y: 200, u: 1, v: 0),
                    PageImage.Vertex(x: 100, y: 400, u: 1, v: 1),
                    PageImage.Vertex(x: -100, y: 400, u: 0, v: 1),
                ],
                strokesBefore: 0
            )
        ]
    )
    let assets = ["img.png": try testPNG()]

    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: sheet)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    AnnotatedPDFRenderer.drawPage(
        source: nil, marks: quad, sheet: sheet, into: context, images: PageRenderer.PageImages(bytes: assets)
    )
    context.closePDF()
    defer { try? FileManager.default.removeItem(at: url) }

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawn = try #require(document.page(at: 1))

    // The quad in points: x 274…338, y 665…729 (PDF counts y up). The image
    // top (v = 0) is the black half and stands at the page's smaller y —
    // the higher PDF y.
    #expect(try darkPixels(of: drawn, in: CGRect(x: 280, y: 706, width: 50, height: 18)) > 0,
            "the top half is black and lands at the top")
    #expect(try darkPixels(of: drawn, in: CGRect(x: 280, y: 670, width: 50, height: 18)) == 0,
            "the bottom half is white")
    #expect(try darkPixels(of: drawn, in: CGRect(x: 10, y: 10, width: 60, height: 60)) == 0,
            "nothing outside the quad")
}

/// A PNG of noise, and a large one for its byte count: the header patch below
/// only convinces ImageIO of a big picture if the file carries enough data to
/// plausibly hold one, and noise is what refuses to compress.
private func noisePNG(size: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: size * size * 4)
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    for index in 0..<(size * size * 4) {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        buffer[index] = UInt8(state & 0xFF)
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// The same PNG with other dimensions written into its header.
///
/// The ceiling is read off the header before a single row is unpacked, which
/// is the whole point of it — so this is the honest way to reach it. Making a
/// real image of that many pixels would cost the test the very allocation the
/// ceiling exists to prevent.
private func declaring(_ png: Data, width: UInt32, height: UInt32) -> Data {
    var bytes = [UInt8](png)
    // IHDR: eight bytes of signature, a four-byte length, the four-byte type,
    // then the width and the height, big-endian.
    for (offset, shift) in [24, 16, 8, 0].enumerated() {
        bytes[16 + offset] = UInt8((width >> UInt32(shift)) & 0xFF)
        bytes[20 + offset] = UInt8((height >> UInt32(shift)) & 0xFF)
    }
    // The chunk's CRC covers its type and its data, and a PNG reader that
    // finds a stale one stops there — which would refuse the file for the
    // wrong reason and let this test pass without touching the ceiling.
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        table[index] = value
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes[12..<29] { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    crc ^= 0xFFFF_FFFF
    for (offset, shift) in [24, 16, 8, 0].enumerated() {
        bytes[29 + offset] = UInt8((crc >> UInt32(shift)) & 0xFF)
    }
    return Data(bytes)
}

/// The page `imageIsDrawnInItsQuad` uses, with the attachment named.
private func pageShowingAnImage(named file: String) -> RMPage {
    RMPage(
        strokes: [],
        skippedBlocks: 0,
        images: [
            PageImage(
                file: file,
                vertices: [
                    PageImage.Vertex(x: -100, y: 200, u: 0, v: 0),
                    PageImage.Vertex(x: 100, y: 200, u: 1, v: 0),
                    PageImage.Vertex(x: 100, y: 400, u: 1, v: 1),
                    PageImage.Vertex(x: -100, y: 400, u: 0, v: 1),
                ],
                strokesBefore: 0
            )
        ]
    )
}

private func inkOfPageShowing(_ assets: [String: Data], file: String) throws -> Int {
    let sheet = CGSize(width: 612, height: 792)
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: sheet)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    AnnotatedPDFRenderer.drawPage(
        source: nil,
        marks: pageShowingAnImage(named: file),
        sheet: sheet,
        into: context,
        images: PageRenderer.PageImages(bytes: assets)
    )
    context.closePDF()
    defer { try? FileManager.default.removeItem(at: url) }

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawn = try #require(document.page(at: 1))
    // The quad in points: x 274…338, y 665…729.
    return try darkPixels(of: drawn, in: CGRect(x: 274, y: 665, width: 64, height: 64))
}

// Compression is why there is a ceiling at all: a few tens of kilobytes of
// header can claim a picture that costs gigabytes to unpack, and the drawing
// may run in a process that is killed for memory long before that. So one
// attachment would take the whole render down rather than leave a hole on
// one page.
@Test("An image past the ceiling leaves a hole, and an ordinary one still draws")
func anOversizedImageIsRefusedRatherThanUnpacked() throws {
    let ordinary = try noisePNG(size: 128)
    // 8001 × 8000 is 64 008 000 pixels — eight thousand past the ceiling, and
    // the smallest overshoot that says the comparison is the one being tested.
    let oversized = declaring(ordinary, width: 8001, height: 8000)
    #expect(8001 * 8000 > PageRenderer.maximumImagePixels)

    // The bytes have to be a picture ImageIO will hand over, or the hole below
    // would prove nothing but that the file was broken.
    let decoded = try #require(
        CGDataProvider(data: oversized as CFData).flatMap {
            CGImage(pngDataProviderSource: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    )
    #expect(decoded.width == 8001 && decoded.height == 8000)

    #expect(
        try inkOfPageShowing(["img.png": oversized], file: "img.png") == 0,
        "a picture past the ceiling has to leave a hole, not a drawing"
    )
    // The refusal has to be the ceiling's doing and not the drawing's: the
    // same bytes under an honest header land on the page.
    #expect(
        try inkOfPageShowing(["img.png": ordinary], file: "img.png") > 0,
        "an ordinary attachment still has to be drawn"
    )
}

// The pixel ceiling guards the unpacking; this one guards the holding.
// Attachments are gathered into a dictionary before a single page is drawn, so
// what has to fit is their sum rather than each on its own.
@Test("The two ceilings are known ones, and they are not the same number")
func theImageCeilingsAreWhatTheyWereMeasuredAt() {
    // 64 megapixels is around 256 MB unpacked and about sixteen times the
    // tablet's own panel: a capture or an insertion cannot reach it.
    #expect(PageRenderer.maximumImagePixels == 64_000_000)
    #expect(PageRenderer.maximumAssetBytes == 256 << 20)
}

// MARK: - The marker

/// One rectangle of a marker, in the order the block writes them.
struct GlyphRect {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// A `.rm` file of one glyph block — the marker over the text of a PDF.
///
/// Built byte by byte rather than taken from a live page: a real block holds
/// the highlighted text, which is the user's document. The text here is
/// whatever the test hands in, under 128 bytes so its count fits one byte.
func glyphPage(rectangles: [GlyphRect], colorID: UInt32, text: String = "marked words") -> Data {
    var body = Data()
    func tag(_ index: Int, _ kind: UInt8) { body.append(UInt8(index << 4) | kind) }
    func crdt(_ index: Int) { tag(index, 0xF); body.append(0); body.append(0) }
    func uint32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) } }

    crdt(1); crdt(2); crdt(3); crdt(4)          // parent, item, left, right
    tag(5, 0x4); uint32(0)                       // deleted length

    var value = Data()
    do {
        var inner = Data()
        func itag(_ index: Int, _ kind: UInt8) { inner.append(UInt8(index << 4) | kind) }
        inner.append(0x02)                       // value type
        itag(4, 0x4); withUnsafeBytes(of: colorID.littleEndian) { inner.append(contentsOf: $0) }
        let words = Array(text.utf8)
        // The string as the tablet writes one: a count of characters, an
        // encoding marker, then the bytes.
        itag(5, 0xC); withUnsafeBytes(of: UInt32(words.count + 2).littleEndian) { inner.append(contentsOf: $0) }
        inner.append(UInt8(words.count))
        inner.append(0x01)
        inner.append(contentsOf: words)
        var rects = Data()
        rects.append(UInt8(rectangles.count))    // varuint count
        for rectangle in rectangles {
            for component in [rectangle.x, rectangle.y, rectangle.width, rectangle.height] {
                withUnsafeBytes(of: component.bitPattern.littleEndian) { rects.append(contentsOf: $0) }
            }
        }
        itag(6, 0xC); withUnsafeBytes(of: UInt32(rects.count).littleEndian) { inner.append(contentsOf: $0) }
        inner.append(rects)
        value = inner
    }
    tag(6, 0xC); uint32(UInt32(value.count)); body.append(value)

    var file = Data(RMParser.header.utf8)
    withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
    file.append(contentsOf: [0, 1, 1, 0x03])     // unknown, min, current, type
    file.append(body)
    return file
}

@Test("The marker is read from the glyph block, not from the strokes")
func glyphBlockCarriesTheHighlight() throws {
    // On a live page, the stroke recorded beside a
    // highlight is degenerate — two points at one x — while these rectangles
    // are the band the tablet's own export draws.
    let page = try RMParser.parsePage(
        glyphPage(
            rectangles: [
                GlyphRect(x: 54, y: 1455, width: 795, height: 39),
                GlyphRect(x: 51, y: 1501, width: 798, height: 38),
            ],
            colorID: 3
        )
    )

    #expect(page.highlights.count == 1)
    let highlight = try #require(page.highlights.first)
    #expect(highlight.rectangles.count == 2)
    #expect(highlight.color == .yellow)
    #expect(abs(highlight.rectangles[0].minX - 54) < 0.01)
    #expect(abs(highlight.rectangles[0].maxX - 849) < 0.01)
    // The words travel too: they are the only record of what was marked
    // once the page under the band is a scan.
    #expect(highlight.text == "marked words")
}

@Test("An opaque black in the colour field is not a colour")
func blackHighlightColourIsIgnored() {
    // A live yellow highlight carries `argb = ff000000`. Believe it and the
    // multiply blots out everything under the band.
    let black = Highlight(rectangles: [.zero], color: .yellow, argb: 0xFF00_0000)
    let real = Highlight(rectangles: [.zero], color: .yellow, argb: 0xFFFF_8800)

    #expect(black.rgb == PenColor.yellow.textHighlightRGB)
    #expect(abs(real.rgb.red - 1) < 0.01 && abs(real.rgb.green - 0.533) < 0.01)
}

@Test("The marker's yellow is not the pen's yellow")
func highlightYellowDiffersFromThePen() {
    // The pen's is a stroke colour: multiplied over text it comes out
    // greener and darker than the tablet's band.
    #expect(PenColor.yellow.textHighlightRGB != PenColor.yellow.rgb)
    #expect(PenColor.yellow.textHighlightRGB.blue > PenColor.yellow.rgb.blue)
}

@Test("A highlight over text and a stroke of the highlighter are different yellows")
func highlighterYellowIsNotTheMultipliedYellow() {
    // Two ways of laying colour down, two colours. Over text the band
    // multiplies, and its yellow is bent to survive that; a stroke darkens,
    // and its yellow lands exactly as the tablet's export writes it —
    // (254, 253, 96).
    let band = PenColor.yellow.highlightRGB
    #expect(abs(band.red - 254.0 / 255) < 0.001)
    #expect(abs(band.green - 253.0 / 255) < 0.001)
    #expect(abs(band.blue - 96.0 / 255) < 0.001)
    #expect(band.blue != PenColor.yellow.textHighlightRGB.blue)

    // The pen's green is far darker than the highlighter's band.
    #expect(PenColor.green.highlightRGB.green > PenColor.green.rgb.green * 1.3)
}

// The pen's nine — read off the tablet's export and
// shared by seven tools, the marker included. These indexes carry no `argb`,
// so the table is the only thing saying what colour they are.
@Test("The pen palette matches the tablet's export byte for byte")
func penPaletteMatchesTheMeasuredExport() {
    let measured: [(PenColor, (Double, Double, Double))] = [
        (.black, (0, 0, 0)),
        (.gray, (144, 144, 144)),
        (.white, (255, 255, 255)),
        (.blue, (48, 74, 224)),
        (.red, (194, 49, 50)),
        (.green2, (145, 218, 113)),
        (.yellow2, (250, 231, 25)),
        (.cyan, (116, 210, 232)),
        (.magenta, (192, 127, 210)),
    ]
    for (color, bytes) in measured {
        let rgb = color.rgb
        #expect(abs(rgb.red - bytes.0 / 255) < 0.001, "\(color) red")
        #expect(abs(rgb.green - bytes.1 / 255) < 0.001, "\(color) green")
        #expect(abs(rgb.blue - bytes.2 / 255) < 0.001, "\(color) blue")
    }
    // The pairs are distinct: 4 and 3 are the highlighter's indexes, and
    // their pen values are not the tablet's 10 and 13.
    #expect(PenColor.green.rgb != PenColor.green2.rgb)
    #expect(PenColor.yellow.rgb != PenColor.yellow2.rgb)
}
