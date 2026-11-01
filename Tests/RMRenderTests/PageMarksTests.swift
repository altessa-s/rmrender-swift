// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks
import RMLines
@testable import RMRender
import Testing

// Where the marker went, answered in fractions of the page as drawn. Every
// test here puts the answer against the pixels of the very bitmap a reading
// is taken from: the band is only worth anything if it lands on the ink it
// was drawn over, and the sheet moves under a page written past its edge.

/// A quarter of the tablet's canvas. The geometry does not care how big
/// the page is — a band is fractions of whatever it is drawn on — and a
/// page of ten million pixels, rendered half a dozen times over, starves
/// the tests that run beside it of the processor they are timed against.
private let canvas = CGSize(width: 351, height: 468)

/// The marker as the tablet writes it: one drag, raw width 120, which is
/// the only width this tool ever reports.
private func marked(from left: Float, to right: Float, at depth: Float) -> Stroke {
    Stroke(
        tool: .highlighter2,
        color: .yellow,
        thicknessScale: 1,
        points: [
            StrokePoint(x: left, y: depth, width: 120, pressure: 1),
            StrokePoint(x: right, y: depth, width: 120, pressure: 1),
        ]
    )
}

/// A stroke of the pen, for a page that has to carry something besides its
/// mark.
private func written(from left: Float, to right: Float, at depth: Float) -> Stroke {
    Stroke(
        tool: .fineliner1,
        color: .black,
        thicknessScale: 1,
        points: [
            StrokePoint(x: left, y: depth, width: 8, pressure: 1),
            StrokePoint(x: right, y: depth, width: 8, pressure: 1),
        ]
    )
}

/// The pixels that carry a colour, as fractions of the picture, counted
/// from its top left. Colour rather than darkness: the pen is black and the
/// marker is not, so this finds the band and nothing else.
private func colouredBox(of image: CGImage) -> PageBox? {
    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            guard max(red, max(green, blue)) - min(red, min(green, blue)) > 40 else { continue }
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
        }
    }
    guard right >= 0 else { return nil }
    return PageBox(
        x0: Double(left) / Double(width), y0: Double(top) / Double(height),
        x1: Double(right + 1) / Double(width), y1: Double(bottom + 1) / Double(height)
    )
}

/// How many pixels carry a colour — the mark and nothing else, since the
/// pen is black.
private func coloured(_ image: CGImage) -> Int {
    let width = image.width, height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return 0 }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    return stride(from: 0, to: width * height * 4, by: 4).count { offset in
        let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
        return max(red, max(green, blue)) - min(red, min(green, blue)) > 40
    }
}

/// How far two boxes stand apart, as a fraction of the picture.
private func apart(_ one: PageBox, _ other: PageBox) -> Double {
    max(
        max(abs(one.x0 - other.x0), abs(one.x1 - other.x1)),
        max(abs(one.y0 - other.y0), abs(one.y1 - other.y1))
    )
}

@Test("A band lands on the pixels of the mark it was taken from")
func bandLandsOnItsOwnPixels() throws {
    let page = RMPage(
        strokes: [written(from: -75, to: 75, at: 100), marked(from: -50, to: 50, at: 100)],
        skippedBlocks: 0
    )
    let bands = PageMarks.bands(of: page, pageSize: canvas)
    #expect(bands.count == 1)
    let band = try #require(bands.first)
    let drawn = try #require(colouredBox(of: try PageRenderer.image(page: page, pageSize: canvas)))
    // Within a pixel of the sheet: the band is the ribbon the renderer
    // lays, and the two are read off the same widths.
    #expect(apart(band.box, drawn) < 0.002, "band \(band.box) against the pixels \(drawn)")
}

@Test("A band holds its place on a sheet grown by writing past the page")
func bandHoldsOnAGrownSheet() throws {
    let mark = marked(from: -50, to: 50, at: 100)
    let plain = RMPage(strokes: [mark], skippedBlocks: 0)
    // The same mark, on a page whose pen ran well below the bottom edge and
    // to the left of it: the sheet grows both ways, and a band divided by
    // the page size instead of by the sheet would slide off the ink.
    let grown = RMPage(
        strokes: [mark, written(from: -225, to: -200, at: 600)], skippedBlocks: 0
    )

    let onPlain = try #require(PageMarks.bands(of: plain, pageSize: canvas).first)
    let onGrown = try #require(PageMarks.bands(of: grown, pageSize: canvas).first)
    #expect(apart(onPlain.box, onGrown.box) > 0.01, "the sheet grew, so the fractions must have moved")

    let drawn = try #require(colouredBox(of: try PageRenderer.image(page: grown, pageSize: canvas)))
    #expect(apart(onGrown.box, drawn) < 0.002, "band \(onGrown.box) against the pixels \(drawn)")
}

@Test("A band lands on its pixels of a page marked over an imported PDF")
func bandLandsOnTheFlattenedPage() throws {
    let sheet = CGSize(width: 612, height: 792)
    let units = AnnotationGeometry.units(of: sheet)
    // In the page's own coordinates, whose origin is the middle of the top
    // edge: a drag across the upper half of a US Letter sheet.
    let page = RMPage(
        strokes: [marked(from: Float(-units.width / 4), to: Float(units.width / 4), at: 200)],
        skippedBlocks: 0
    )
    let band = try #require(PageMarks.bands(of: page, sheet: sheet).first)

    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    var box = CGRect(origin: .zero, size: sheet)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    AnnotatedPDFRenderer.drawPage(source: nil, marks: page, sheet: sheet, into: context)
    context.closePDF()

    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let drawnPage = try #require(document.page(at: 1))
    let media = drawnPage.getBoxRect(.mediaBox)
    let bitmap = try #require(
        CGContext(
            data: nil, width: Int(media.width), height: Int(media.height), bitsPerComponent: 8,
            bytesPerRow: Int(media.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: media.width, height: media.height))
    // The media box is where the page's own coordinates begin, and
    // `drawPDFPage` pays no attention to it.
    bitmap.translateBy(x: -media.minX, y: -media.minY)
    bitmap.drawPDFPage(drawnPage)
    let picture = try #require(bitmap.makeImage())
    let drawn = try #require(colouredBox(of: picture))
    #expect(apart(band.box, drawn) < 0.004, "band \(band.box) against the pixels \(drawn)")
}

@Test("A page with no marker has no bands, and the pen is not one")
func penIsNotAMark() {
    let page = RMPage(strokes: [written(from: -75, to: 75, at: 100)], skippedBlocks: 0)
    #expect(PageMarks.bands(of: page, pageSize: canvas).isEmpty)
}

@Test("A sheet holds every block's pixels and says where each came from")
func sheetHoldsItsBlocks() throws {
    let page = RMPage(
        strokes: [
            marked(from: -75, to: 75, at: 75),
            written(from: -75, to: 75, at: 75),
            marked(from: -25, to: 25, at: 225),
            written(from: -25, to: 25, at: 225),
        ],
        skippedBlocks: 0
    )
    let picture = try PageRenderer.image(page: page, pageSize: canvas)
    let bands = PageMarks.bands(of: page, pageSize: canvas)
    #expect(bands.count == 2)
    let sheet = try #require(PageMarks.sheet(of: bands.map(\.box), from: picture))

    #expect(sheet.strips.count == 2)
    #expect(sheet.picture.height < picture.height, "a sheet of two marks is less than the page")
    // Every coloured pixel of both marks is on the sheet: a mark read with
    // a letter of itself missing is a mark misread.
    #expect(coloured(sheet.picture) == coloured(picture))
    // The strips stand apart, in the order the blocks were given, and each
    // says where on the page it came from.
    let first = try #require(sheet.strips.first), last = try #require(sheet.strips.last)
    #expect(first.inSheet.y1 <= last.inSheet.y0, "a rule stands between them")
    #expect(first.onPage == bands[0].box && last.onPage == bands[1].box)
    // A box read inside a strip comes back to the page: the whole of the
    // first strip is the first block.
    let whole = PageBox(x0: 0, y0: 0, x1: 1, y1: 1).within(first.onPage)
    #expect(whole == first.onPage)
}

@Test("A band's air is a share of its height, twice that at the sides, and never off the page")
func airAroundABand() {
    let band = PageBox(x0: 0.4, y0: 0.5, x1: 0.6, y1: 0.6)
    let air = PageMarks.around(band)
    #expect(air.y0 == 0.5 - 0.06 && air.y1 == 0.6 + 0.06, "six hundredths: a tenth of the band, above and below")
    #expect(air.x0 == 0.4 - 0.12 && air.x1 == 0.6 + 0.12, "twice that at the sides")
    // A band at the edge keeps what there is.
    let edge = PageMarks.around(PageBox(x0: 0, y0: 0, x1: 0.1, y1: 0.1))
    #expect(edge.x0 == 0 && edge.y0 == 0)
}

@Test("A word read in a strip comes back to the page it was cut from")
func wordComesBackFromAStrip() {
    // A strip cut out of the middle of a page, and a word in the middle
    // of the strip: brought into the strip and then onto the page, it
    // stands where it started.
    let strip = PageBox(x0: 0.2, y0: 0.4, x1: 0.8, y1: 0.5)
    let word = PageBox(x0: 0.35, y0: 0.42, x1: 0.5, y1: 0.46)
    let inStrip = word.inside(strip)
    // A quarter along the strip, a fifth down it — to the last place a
    // double keeps.
    #expect(abs(inStrip.x0 - 0.25) < 0.0001 && abs(inStrip.y0 - 0.2) < 0.0001)
    let back = inStrip.within(strip)
    #expect(abs(back.x0 - word.x0) < 0.0001 && abs(back.y1 - word.y1) < 0.0001)
}

@Test("A highlight the tablet spelled out comes back with its words and its place")
func highlightKeepsItsWordsAndPlace() throws {
    // The marker over the text of an imported PDF: no stroke, a glyph
    // range with the words already in it.
    let page = try RMParser.parsePage(
        makeHighlightPage(
            rectangles: [HighlightRect(x: -50, y: 100, width: 100, height: 10)],
            text: "под маркером"
        )
    )
    let found = PageMarks.highlights(of: page, pageSize: canvas)
    #expect(found.count == 1)
    let highlight = try #require(found.first)
    #expect(highlight.text == "под маркером")
    #expect(PageMarks.bands(of: page, pageSize: canvas).isEmpty, "a glyph range is no stroke")

    // The band lands on the pixels the renderer draws for it.
    let picture = try PageRenderer.image(page: page, pageSize: canvas)
    let drawn = try #require(colouredBox(of: picture))
    #expect(apart(highlight.band.box, drawn) < 0.002, "band \(highlight.band.box) against \(drawn)")
    #expect(highlight.band.color != 0, "the marker's own palette, not the pen's")
}

// A band names the item it was measured off, so an edit made later can
// find that item on the page. The stroke is copied twice on the way — widened
// to the width the export draws, and moved off its anchor — and neither copy
// may drop the name.

@Test func aBandNamesTheStrokeItWasMeasuredOff() {
    let id = SceneItemID(author: 2, counter: 117)
    let stroke = marked(from: -300, to: 300, at: 400)
    let named = Stroke(
        tool: stroke.tool, color: stroke.color, thicknessScale: stroke.thicknessScale,
        points: stroke.points, argb: stroke.argb, id: id
    )
    let page = RMPage(strokes: [named, written(from: -300, to: 300, at: 600)], skippedBlocks: 0)
    let bands = PageMarks.bands(of: page)
    #expect(bands.map(\.item) == ["2:117"])
}

@Test func theCopiesOfAStrokeKeepItsName() {
    let id = SceneItemID(author: 1, counter: 42)
    let stroke = Stroke(
        tool: .highlighter2, color: .yellow, thicknessScale: 1,
        points: [StrokePoint(x: 0, y: 0, width: 120, pressure: 1)], id: id
    )
    #expect(stroke.drawn.id == id)
    #expect(stroke.placed(x: 10, y: 20).id == id)
}

@Test func aSpelledHighlightNamesItsItem() {
    let highlight = Highlight(
        rectangles: [CGRect(x: -200, y: 300, width: 400, height: 40)],
        color: .yellow,
        text: "marked words",
        id: SceneItemID(author: 2, counter: 9)
    )
    let page = RMPage(strokes: [], skippedBlocks: 0, highlights: [highlight])
    #expect(PageMarks.highlights(of: page).map(\.band.item) == ["2:9"])
}
