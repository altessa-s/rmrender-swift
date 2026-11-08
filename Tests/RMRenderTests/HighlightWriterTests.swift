// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
@testable import RMRender
import RMLines
import Testing

// The highlighter's bands written in CoreGraphics' place (`InkStream.highlight`):
// the rectangles printed as CoreGraphics prints them, and pages painting what
// CoreGraphics drawing the bands paints — over a template, over typed text,
// at every scale, in every colour.

/// A band of a highlight: a rectangle in user space and its colour.
private struct Band {
    let rectangle: CGRect
    let red: Double
    let green: Double
    let blue: Double
}

/// Random bands near the page, some standing on their heads (a negative
/// width or height), some of no width, some far off it.
private func randomBands(_ marks: inout Marks, count: Int) -> [Band] {
    let palette: [(Double, Double, Double)] = [
        PenColor.yellow.textHighlightRGB, (1, 0.5, 0.2), (0.6, 0.9, 1), (0.8, 1, 0.6), (1, 0.75, 0.9),
    ]
    return (0..<count).map { index in
        var width = marks.uniform(-50, 900), height = marks.uniform(20, 70)
        if index.isMultiple(of: 7) { height = -height }
        if index.isMultiple(of: 11) { width = 0 }
        let x = index.isMultiple(of: 13) ? marks.uniform(-5000, 5000) : marks.uniform(-700, 700)
        let rgb = index.isMultiple(of: 3)
            ? (marks.uniform(0, 1), marks.uniform(0, 1), marks.uniform(0, 1)) : palette[marks.below(palette.count)]
        return Band(
            rectangle: CGRect(x: x, y: marks.uniform(-100, 1900), width: width, height: height),
            red: rgb.0, green: rgb.1, blue: rgb.2
        )
    }
}

/// A page of `size` under `transform`: `background` drawn by CoreGraphics,
/// then `bands` — by CoreGraphics as `PageRenderer.draw` draws a highlight,
/// or, `written`, by the ink writer and appended after CoreGraphics' share.
private func highlightPage(
    _ bands: [Band], transform: CGAffineTransform, size: CGSize, written: Bool,
    background: (CGContext) -> Void = { _ in }
) throws -> Data {
    let data = try #require(CFDataCreateMutable(nil, 0))
    let sink = PDFSink(data: data)
    var box = CGRect(origin: .zero, size: size)
    let consumer = try #require(sink.consumer())
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let update = InkUpdate()
    context.beginPDFPage(nil)
    context.saveGState()
    context.concatenate(transform)
    background(context)
    if !written {
        context.saveGState()
        context.setBlendMode(.multiply)
        for band in bands {
            context.setFillColor(red: band.red, green: band.green, blue: band.blue, alpha: 1)
            context.fill(band.rectangle)
        }
        context.restoreGState()
    }
    context.restoreGState()
    context.endPDFPage()
    if written {
        let placed = try #require(PageRenderer.contextTransform { $0.concatenate(transform) })
        let stream = try #require(InkStream(transform: placed))
        for band in bands { stream.highlight(band.rectangle, red: band.red, green: band.green, blue: band.blue) }
        try update.append(try #require(PreparedInk(stream)), page: 0)
    }
    context.closePDF()
    try update.finish(into: sink)
    try sink.close()
    return data as Data
}

/// The operands of every `re` of a content stream, in order.
private func rectangles(_ content: Data) -> [String] {
    let tokens = String(decoding: content, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
    return tokens.indices.compactMap { index in
        tokens[index] == "re" && index >= 4 ? tokens[(index - 4)..<index].joined(separator: " ") : nil
    }
}

/// The transforms pages are drawn under: a notebook's placements, an
/// overlay's, a redraw's scale, and a few that a grown sheet could make.
private let transforms: [CGAffineTransform] = [
    CGAffineTransform(translationX: 1.5, y: -7.25).scaledBy(x: 0.317180616, y: 0.317180616),
    CGAffineTransform(scaleX: 0.3171806167400881, y: 0.3171806167400881),
    CGAffineTransform(translationX: 222.66608, y: 841.89).scaledBy(x: 0.4235033, y: 0.4235033),
    CGAffineTransform(translationX: -13.0625, y: 401.123).scaledBy(x: 0.2, y: 0.2),
    CGAffineTransform(translationX: 306, y: 396).scaledBy(x: 0.43589743589743585, y: 0.43589743589743585),
]

@Test("Written highlights print every rectangle CoreGraphics prints, to the character")
func writtenHighlightsPrintCoreGraphicsRectangles() throws {
    var marks = Marks(random: SplitMix64(seed: 0x4816_1167))
    let size = CGSize(width: 445.33216129, height: 593.7762345)
    for transform in transforms {
        let bands = randomBands(&marks, count: 400)
        let native = try InkTesting.content(of: try highlightPage(bands, transform: transform, size: size, written: false), page: 1)
        let pdf = try highlightPage(bands, transform: transform, size: size, written: true)
        let written = try InkTesting.content(of: pdf, page: 1)
        let expected = rectangles(native), actual = rectangles(written)
        #expect(actual.count == bands.count && expected.count == bands.count)
        let first = expected.indices.first { $0 < actual.count && expected[$0] != actual[$0] }
        #expect(first == nil, "\(first.map { "\(expected[$0]) written as \(actual[$0])" } ?? "")")
        // Multiplied, as CoreGraphics multiplies them, in sRGB, at full alpha:
        // one graphics state, and it says nothing of an alpha.
        #expect(String(decoding: written, as: UTF8.self).contains("/RMIg0 gs"))
        #expect(!String(decoding: written, as: UTF8.self).contains("/RMIg1 gs"))
        #expect(String(decoding: pdf, as: UTF8.self).contains("<< /Type /ExtGState /BM /Multiply >>"))
        #expect(String(decoding: written, as: UTF8.self).contains("/RMIc cs"))
    }
}

/// What a band lands on: a template, typed text, and ink of every kind —
/// translucent, darkening — drawn by CoreGraphics as `PageRenderer.draw`
/// draws a page.
private func backdrop(_ marks: inout Marks, template: String?) -> (CGContext) -> Void {
    _ = FixtureTemplates.installed
    let page = marks.page(strokes: 25, text: true, template: template)
    let pageSize = notebookSize
    return { context in
        let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
        let bounds = PageRenderer.contentBounds(of: page, pageSize: pageSize, edge: .ribbon, geometry: geometry)
        PageRenderer.draw(page, in: context, pageSize: pageSize, bounds: bounds, geometry: geometry)
    }
}

private let notebookSize = CGSize(width: 1404, height: 1872)

@Test(
    "Written highlights paint what CoreGraphics paints over a template, typed text and ink, at every scale",
    arguments: [nil, "Fixture Grid", "Fixture Week", "Fixture Dots"]
)
func writtenHighlightsPaintWhatCoreGraphicsPaints(template: String?) throws {
    var marks = Marks(random: SplitMix64(seed: 0x4816_0000 ^ UInt64(template?.count ?? 0)))
    let size = CGSize(width: 445.33216129, height: 593.7762345)
    for transform in transforms.prefix(3) {
        let background = backdrop(&marks, template: template)
        let bands = randomBands(&marks, count: 60)
        let native = try highlightPage(bands, transform: transform, size: size, written: false, background: background)
        let written = try highlightPage(bands, transform: transform, size: size, written: true, background: background)
        for scale in [1, 2.5, 6.25] {
            #expect(try InkTesting.differingPixels(native, written, page: 1, scale: scale) == 0, "scale \(scale)")
        }
    }
}

@Test("A notebook page's highlights are written with its ink where nothing CoreGraphics draws comes after them, and paint the same")
func notebookHighlightsAreWrittenWherePossible() throws {
    _ = FixtureTemplates.installed
    var marks = Marks(random: SplitMix64(seed: 0x4816_B00C))
    let noShader = Marks.allTools.filter { $0 != .shader }
    let templates = [nil, "Fixture Grid", "Fixture Lines", "Fixture Week"]
    let pages = (0..<12).map { index in
        // Bands alone; bands over typed text with ink; bands with a picture,
        // or with a shader cut by the eraser — those stay CoreGraphics'.
        switch index % 4 {
        case 0: marks.page(strokes: 0, template: templates[index % 4], highlights: 4)
        case 1: marks.page(strokes: 30, tools: noShader, text: true, template: templates[index % 4], highlights: 3)
        case 2: marks.page(strokes: 30, tools: noShader, pictures: true, template: templates[index % 4], highlights: 3)
        default: marks.page(strokes: 30, template: templates[index % 4], highlights: 3)
        }
    }
    let assets = ["picture.png": testPicture()]
    var written = 0
    for (index, page) in pages.enumerated() {
        let geometry = page.text.map { TextGeometry($0, pageSize: notebookSize) }
        let ink = PageRenderer.writtenInk(of: page, pageSize: notebookSize, geometry: geometry) { _ in }
        if ink.highlights {
            written += 1
            #expect(ink.split == 0 && page.images.isEmpty)
        }
        // Bands alone stay CoreGraphics', which draws the page anyway —
        // unless they would spare it the page.
        if index.isMultiple(of: 4) {
            #expect(!ink.highlights && ink.ink == nil)
            #expect(PageRenderer.writtenInk(
                of: page, pageSize: notebookSize, geometry: geometry, highlightsAlone: true
            ) { _ in }.highlights)
        }
    }
    #expect(written >= 3)
    let pdf = try PageRenderer.pdf(pages: pages, pageSize: notebookSize, assets: assets)
    let native = try InkTesting.allCoreGraphics(pages: pages, pageSize: notebookSize, assets: assets)
    for number in 1...pages.count {
        for scale in [1, 2.5] {
            #expect(try InkTesting.differingPixels(native, pdf, page: number, scale: scale) == 0, "page \(number) at \(scale)")
        }
    }
}

/// An original of `count` pages of `sheet` with text and colour on them,
/// for the bands to multiply.
private func printedOriginal(pages count: Int, sheet: CGRect, at url: URL) throws {
    var box = sheet
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for index in 0..<count {
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        context.fill(CGRect(x: 40 + Double(index), y: 60, width: 300, height: 200))
        for line in 0..<40 {
            let text = NSAttributedString(
                string: "Line \(line) of page \(index + 1): the quick brown fox jumps over the lazy dog",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            context.textPosition = CGPoint(x: 54, y: 740 - Double(line) * 17)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
}

@Test("An overlay page of highlights over a blank text layer is its ink alone, and paints as CoreGraphics drawing it does")
func overlayHighlightPagesAreTheirInkAlone() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-highlight-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let original = folder.appending(path: "original.pdf")
    let count = 8
    try printedOriginal(pages: count, sheet: sheet, at: original)

    var marks = Marks(random: SplitMix64(seed: 0x4816_0E41))
    let noShader = Marks.allTools.filter { $0 != .shader }
    let images = PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    var written: [PDFOverlayWriter.Overlay] = [], whole: [PDFOverlayWriter.Overlay] = []
    var alone = 0
    for index in 0..<count {
        let page: RMPage
        switch index % 4 {
        // Bands over a blank text layer, with ink and without: the ink alone.
        case 0: page = marks.page(strokes: 0, blankText: [""], highlights: 4)
        case 1: page = marks.page(strokes: 25, tools: noShader, blankText: ["", ""], highlights: 3)
        // Bands over typed text: CoreGraphics sets the text, the bands are
        // written after it.
        case 2: page = marks.page(strokes: 25, tools: noShader, text: true, highlights: 2)
        // Bands under a picture: CoreGraphics' all of them.
        default: page = marks.page(strokes: 25, tools: noShader, pictures: true, blankText: [""], highlights: 2)
        }
        let overlay = try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images)
        if index % 4 < 2 {
            #expect(overlay.formPDF == nil, "page \(index): CoreGraphics drew a share of it")
            #expect(overlay.ink != nil, "page \(index)")
            alone += 1
        } else {
            #expect(overlay.formPDF != nil, "page \(index)")
        }
        written.append(overlay)
        whole.append(try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images, writesInk: false))
    }
    #expect(alone == count / 2)
    let writtenURL = folder.appending(path: "written.pdf"), wholeURL = folder.appending(path: "whole.pdf")
    try PDFOverlayWriter().write(original: original, overlays: written, to: writtenURL)
    try PDFOverlayWriter().write(original: original, overlays: whole, to: wholeURL)
    let writtenPDF = try Data(contentsOf: writtenURL), wholePDF = try Data(contentsOf: wholeURL)
    for page in 1...count {
        for scale in [1, 1.5, 3.25] {
            #expect(try InkTesting.differingPixels(wholePDF, writtenPDF, page: page, scale: scale) == 0, "page \(page) at \(scale)")
        }
    }
}

@Test("A highlight with a rectangle that is not finite stays CoreGraphics'")
func unfiniteHighlightsStayCoreGraphics() {
    let bands = [
        Highlight(rectangles: [CGRect(x: 0, y: 0, width: 50, height: 10)], color: .yellow),
        Highlight(rectangles: [CGRect(x: 0, y: Double.infinity, width: 50, height: 10)], color: .yellow),
    ]
    let page = RMPage(strokes: [], skippedBlocks: 0, highlights: bands)
    #expect(!PageRenderer.writesHighlights(of: page, split: 0, images: []))
    #expect(PageRenderer.writtenInk(of: page, pageSize: notebookSize, geometry: nil, highlightsAlone: true) { _ in }.ink == nil)
    let finite = RMPage(strokes: [], skippedBlocks: 0, highlights: [bands[0]])
    #expect(PageRenderer.writesHighlights(of: finite, split: 0, images: []))
    #expect(!PageRenderer.writesHighlights(of: finite, split: 1, images: []))
    #expect(PageRenderer.writtenInk(of: finite, pageSize: notebookSize, geometry: nil, highlightsAlone: true) { _ in }.ink != nil)
}
