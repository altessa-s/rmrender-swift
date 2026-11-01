// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import PDFKit
import RMLines
@testable import RMRender
import Testing

// Appending marks to a document instead of redrawing it. What these guard is
// the promise the approach exists for: the original's bytes stay as they are,
// and with them everything redrawing lost — links first of all.

/// A PDF of blank pages written by Quartz — the same shape of file that comes
/// out of a printer or a scanner.
private func makeDocument(pages: Int, size: CGSize = CGSize(width: 200, height: 300)) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: size)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw RenderError.pdfContextUnavailable
    }
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func overlay(_ text: String, page: Int = 0) -> PDFOverlayWriter.Overlay {
    PDFOverlayWriter.Overlay(
        pageIndex: page,
        content: Data(text.utf8),
        states: []
    )
}

/// The dark pixels of one page, drawn by CoreGraphics rather than by PDFKit.
///
/// On purpose: a mark only PDFKit can see is a mark other PDF readers will
/// not show, and PDF annotations fail in exactly that way.
private func ink(_ url: URL, page: Int) throws -> Int {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A page whose box does not begin at zero draws in its own coordinates,
    // and CoreGraphics does not move them for us: without this the part of a
    // grown page that lies left of the original sheet falls off the bitmap.
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(pdfPage)
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    return stride(from: 0, to: width * height * 4, by: 4).count { Int(buffer[$0]) < 128 }
}

@Test("The original's bytes are still there, and the update comes after them")
func overlayAppendsRatherThanRewrites() throws {
    let original = try makeDocument(pages: 3)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    try PDFOverlayWriter().write(
        original: original,
        overlays: [overlay("0 0 0 RG 4 w 20 20 m 180 280 l S\n")],
        to: output
    )

    let before = try Data(contentsOf: original)
    let after = try Data(contentsOf: output)
    #expect(after.count > before.count)
    #expect(after.prefix(before.count) == before)
    // Two ends of file: the original's, and the one this update wrote.
    #expect(after.ranges(of: Data("%%EOF".utf8)).count == 2)
}

@Test("The document still opens, with the same pages")
func overlayLeavesAReadableDocument() throws {
    let original = try makeDocument(pages: 3)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    try PDFOverlayWriter().write(original: original, overlays: [overlay("")], to: output)

    let provider = try #require(CGDataProvider(url: output as CFURL))
    let document = try #require(CGPDFDocument(provider))
    #expect(document.numberOfPages == 3)
}

@Test("What was drawn shows up, and only on the page it was meant for")
func overlayDrawsWhereItSays() throws {
    let original = try makeDocument(pages: 2)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    try PDFOverlayWriter().write(
        original: original,
        overlays: [overlay("0 0 0 RG 10 w 20 150 m 180 150 l S\n")],
        to: output
    )

    #expect(try ink(output, page: 1) > (try ink(original, page: 1)))
    #expect(try ink(output, page: 2) == (try ink(original, page: 2)))
}

@Test("A mark written off the sheet is shown, and the original sheet is still on record")
func overlayGrowsThePageAroundMarksOutsideIt() throws {
    let original = try makeDocument(pages: 1)
    let clipped = original.deletingPathExtension().appendingPathExtension("clipped.pdf")
    let grown = original.deletingPathExtension().appendingPathExtension("grown.pdf")
    defer {
        for url in [original, clipped, grown] { try? FileManager.default.removeItem(at: url) }
    }

    // A stroke entirely to the left of the page — where the pen goes when the
    // tablet lets it off the sheet.
    let mark = "0 0 0 RG 10 w -50 100 m -10 200 l S\n"
    let box = CGRect(x: -60, y: 0, width: 260, height: 300)

    try PDFOverlayWriter().write(original: original, overlays: [overlay(mark)], to: clipped)
    try PDFOverlayWriter().write(
        original: original,
        overlays: [PDFOverlayWriter.Overlay(pageIndex: 0, content: Data(mark.utf8), states: [], box: box)],
        to: grown
    )

    // The one difference between the two files is the box, and it is the
    // difference between ink no reader shows and ink every reader shows.
    #expect(try ink(clipped, page: 1) == (try ink(original, page: 1)))
    #expect(try ink(grown, page: 1) > (try ink(original, page: 1)))

    let pages = try PDFFile(url: grown).pages()
    let page = try #require(pages.first)
    #expect(page.mediaBox == box)
    // A reader shows the crop box where there is one, so leaving an old one
    // behind would crop the marks straight back off.
    #expect(page.cropBox == box)
    let art = page.dictionary["ArtBox"]?.arrayValue?.compactMap(\.doubleValue)
    #expect(art == [0, 0, 200, 300], "the imported sheet's original bounds")
}

@Test("A link the original had is a link the document still has")
func overlayKeepsLinks() throws {
    let original = try makeDocument(pages: 2)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    // The link is put in by PDFKit, as a publisher's tool would.
    let document = try #require(PDFDocument(url: original))
    let link = PDFAnnotation(
        bounds: CGRect(x: 20, y: 40, width: 100, height: 20),
        forType: .link,
        withProperties: nil
    )
    link.url = URL(string: "https://example.org")
    try #require(document.page(at: 0)).addAnnotation(link)
    #expect(document.write(to: original))

    try PDFOverlayWriter().write(
        original: original,
        overlays: [overlay("0 0 0 RG 2 w 20 20 m 180 280 l S\n")],
        to: output
    )

    let written = try #require(PDFDocument(url: output))
    let annotations = try #require(written.page(at: 0)).annotations
    #expect(annotations.count == 1)
    #expect(annotations.first?.url?.absoluteString == "https://example.org")
}

@Test("A page that is not there is refused rather than guessed at")
func overlayRefusesAMissingPage() throws {
    let original = try makeDocument(pages: 1)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    #expect(throws: PDFOverlayWriter.OverlayError.noSuchPage(4)) {
        try PDFOverlayWriter().write(original: original, overlays: [overlay("", page: 4)], to: output)
    }
}

@Test("The reader finds the pages, the trailer and the boxes")
func readerWalksTheDocument() throws {
    let original = try makeDocument(pages: 4, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: original) }

    let file = try PDFFile(url: original)
    let pages = try file.pages()

    #expect(pages.count == 4)
    #expect(file.trailer["Root"] != nil)
    #expect(pages.first?.mediaBox == CGRect(x: 0, y: 0, width: 320, height: 240))
    #expect(pages.allSatisfy { $0.rotation == 0 })
}

@Test("An update of an update reads as the newest of the three")
func readerFollowsTheChainOfUpdates() throws {
    let original = try makeDocument(pages: 2)
    let once = original.deletingPathExtension().appendingPathExtension("1.pdf")
    let twice = original.deletingPathExtension().appendingPathExtension("2.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: once)
        try? FileManager.default.removeItem(at: twice)
    }

    try PDFOverlayWriter().write(original: original, overlays: [overlay("")], to: once)
    try PDFOverlayWriter().write(original: once, overlays: [overlay("")], to: twice)

    let file = try PDFFile(url: twice)
    #expect(try file.pages().count == 2)
    let provider = try #require(CGDataProvider(url: twice as CFURL))
    #expect(CGPDFDocument(provider)?.numberOfPages == 2)
}

@Test("Typed text is handed back rather than half-drawn")
func markContentRefusesTypedText() throws {
    let page = RMPage(
        strokes: [],
        skippedBlocks: 0,
        text: TextBlock(originX: 0, originY: 0, lines: ["Typed"])
    )
    #expect(MarkContentStream.build(page, mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
}

// An overlay appends its operators to a page that already carries its own
// drawing, and appended operators cannot cut what is already there. The
// redrawing path subtracts an eraser's band out of every stroke laid down
// before it, so a page holding one has to go that way round — otherwise it
// comes out carrying the ink the user rubbed out, and nothing fails to say so.
@Test("A page somebody rubbed out is handed back rather than drawn as if they had not")
func markContentRefusesTheEraser() {
    let box = CGRect(x: 0, y: 0, width: 400, height: 600)
    let ink = Stroke(
        tool: .fineliner1,
        color: .black,
        thicknessScale: 2,
        points: [
            StrokePoint(x: 0, y: 0, width: 6, pressure: 1),
            StrokePoint(x: 40, y: 0, width: 6, pressure: 1),
        ]
    )
    let eraser = Stroke(
        tool: .eraser,
        color: .black,
        thicknessScale: 2,
        points: [
            StrokePoint(x: 20, y: -10, width: 30, pressure: 1),
            StrokePoint(x: 20, y: 10, width: 30, pressure: 1),
        ]
    )

    #expect(
        MarkContentStream.build(RMPage(strokes: [ink, eraser], skippedBlocks: 0), mediaBox: box) == nil
    )
    // The refusal has to be the eraser's doing rather than the page's: the
    // same page without it is still worth appending to.
    #expect(MarkContentStream.build(RMPage(strokes: [ink], skippedBlocks: 0), mediaBox: box) != nil)
}

// Tool 8 is not tool 6. It takes no ink off, and both paths merely skip it,
// so refusing a page for it would cost the document its links and its
// outline to save nothing at all.
@Test("The area eraser takes no ink off, and so costs the document nothing")
func markContentKeepsTheAreaEraser() throws {
    let ink = Stroke(
        tool: .fineliner1,
        color: .black,
        thicknessScale: 2,
        points: [
            StrokePoint(x: 0, y: 0, width: 6, pressure: 1),
            StrokePoint(x: 40, y: 0, width: 6, pressure: 1),
        ]
    )
    let area = Stroke(
        tool: .eraserArea,
        color: .black,
        thicknessScale: 2,
        points: [
            StrokePoint(x: 20, y: -10, width: 30, pressure: 1),
            StrokePoint(x: 20, y: 10, width: 30, pressure: 1),
        ]
    )
    let built = try #require(
        MarkContentStream.build(
            RMPage(strokes: [ink, area], skippedBlocks: 0),
            mediaBox: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    )

    // Skipped rather than drawn: one stroke reaches the page, and it is the ink.
    let text = String(decoding: built.content, as: UTF8.self)
    #expect(text.components(separatedBy: " m\n").count - 1 == 1)
}

/// The weight of ink on one page — every pixel's darkness summed — drawn at
/// three pixels to the point, which is close to a pixel to a unit: at a pixel
/// to the point a grained band is a grey no threshold reads fairly.
private func inkWeight(_ url: URL, page: Int) throws -> Double {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = pdfPage.getBoxRect(.mediaBox)
    let scale = 3
    let width = Int(box.width) * scale, height = Int(box.height) * scale
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(pdfPage)
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    var weight = 0.0
    for index in stride(from: 0, to: width * height * 4, by: 4) {
        weight += Double(255 - Int(buffer[index])) / 255
    }
    return weight
}

// The pencil goes onto an imported page the same way it goes onto a notebook
// page: as grain. Weighed against a solid band of the same shape, the export's
// share at half pressure, and the document is still an update rather than a
// redraw — its first bytes are the original's.
@Test("A pencil on an imported page is grained, and the page keeps its original")
func overlayPaintsThePencilAsGrain() throws {
    func band(_ tool: PenTool) -> Stroke {
        Stroke(
            tool: tool,
            color: .black,
            thicknessScale: 1,
            points: stride(from: Float(-200), through: 200, by: 6).map {
                StrokePoint(x: $0, y: 300, width: 96, pressure: 128)
            }
        )
    }
    let box = CGRect(x: 0, y: 0, width: 200, height: 300)
    func weight(of tool: PenTool) throws -> Double {
        let original = try makeDocument(pages: 1, size: box.size)
        defer { try? FileManager.default.removeItem(at: original) }
        let built = try #require(
            MarkContentStream.build(RMPage(strokes: [band(tool)], skippedBlocks: 0), mediaBox: box)
        )
        let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try PDFOverlayWriter().write(
            original: original,
            overlays: [
                PDFOverlayWriter.Overlay(
                    pageIndex: 0,
                    content: built.content,
                    states: built.states,
                    images: built.images
                ),
            ],
            to: output
        )
        let originalBytes = try Data(contentsOf: original)
        let written = try Data(contentsOf: output)
        #expect(written.prefix(originalBytes.count) == originalBytes)
        // A stencil is a stream object, and a stream states its length.
        let update = String(decoding: written.dropFirst(originalBytes.count), as: UTF8.self)
        if tool.grain != .solid {
            let stencil = try #require(update.range(of: "/ImageMask true"))
            // The keys are written sorted, so the length stands after the
            // mask flag and before the stream's bytes.
            let streamStart = try #require(update.range(of: "stream", range: stencil.upperBound..<update.endIndex))
            #expect(update[stencil.upperBound..<streamStart.lowerBound].contains("/Length"))
        }
        return try inkWeight(output, page: 1) - inkWeight(original, page: 1)
    }
    let solid = try weight(of: .ballpoint2)
    let grained = try weight(of: .pencil2)
    #expect(solid > 1000)
    // Half pressure is 0.46 of the band ink, and the pencil's band is
    // drawn at 0.69 of the ballpoint's: a third of the solid stroke.
    let share = grained / solid
    #expect(share > 0.26 && share < 0.40, "grain over solid: \(share)")
}

@Test("A stroke becomes a path, and the marker asks for multiplication")
func markContentWritesOperators() throws {
    let stroke = Stroke(
        tool: .fineliner1,
        color: .black,
        thicknessScale: 2,
        points: [
            StrokePoint(x: 0, y: 0, width: 6, pressure: 1),
            StrokePoint(x: 10, y: 10, width: 6, pressure: 1),
        ]
    )
    let highlight = Highlight(rectangles: [CGRect(x: 0, y: 0, width: 40, height: 10)], color: .yellow)
    let page = RMPage(strokes: [stroke], skippedBlocks: 0, highlights: [highlight])

    let built = try #require(
        MarkContentStream.build(page, mediaBox: CGRect(x: 0, y: 0, width: 400, height: 600))
    )
    let text = String(decoding: built.content, as: UTF8.self)

    #expect(text.contains(" m\n"))
    #expect(text.contains(" l\n"))
    #expect(text.contains("S Q"))
    #expect(text.contains("re f Q"))
    // One state, for the multiplied band of the marker; a fineliner covers the
    // page rather than darkening it, so it asks for none.
    #expect(built.states.map(\.blendMode) == ["Multiply"])
    #expect(built.states.allSatisfy { $0.alpha == 1 })
    #expect(text.contains("/\(built.states[0].name) gs"))
}

// The two places that draw marks have to agree, so a stroke whose width
// changes is a filled contour here as well as in the renderer.
@Test("A stroke of changing width is filled here too, and what it costs is known")
func markContentFillsAVaryingStroke() throws {
    // An arc rather than a straight line, and a width that grows: the shape a
    // hand actually makes, sampled the way the tablet samples it.
    var points: [StrokePoint] = []
    for step in 0...199 {
        let angle = Double(step) / 199 * Double.pi
        points.append(
            StrokePoint(
                x: Float(200 + 180 * cos(angle)),
                y: Float(500 + 180 * sin(angle)),
                width: Float(8 + step % 40),
                pressure: 1
            )
        )
    }
    // The first brush rather than a pencil or a ballpoint: all are filled,
    // but those are grained, and a grained page is handed back rather than
    // written.
    let stroke = Stroke(tool: .paintbrush1, color: .black, thicknessScale: 2, points: points)
    let built = try #require(
        MarkContentStream.build(
            RMPage(strokes: [stroke], skippedBlocks: 0),
            mediaBox: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    )
    let text = String(decoding: built.content, as: UTF8.self)

    // The ends are fans of straight segments — corners, not curves.
    #expect(text.contains(" l\n"), "the ends are polygons")
    #expect(text.contains("h\n"))
    // One fill for the whole stroke. Its pieces overlap where it turns, and a
    // fill each would darken every overlap of a translucent tool.
    let fills = text.components(separatedBy: "f Q").count - 1
    #expect(fills == 1, "one fill, not \(fills)")
    #expect(!text.contains(" w\n"), "a contour has no line width")
    // What the shape costs in a document, and the reason the runs of points
    // that lie on one line are joined: this arc comes to about five kilobytes,
    // which is what a polyline of two hundred points costs. Without the
    // joining it is sixteen, and a book with marks on two hundred pages would
    // have grown by that factor.
    #expect(built.content.count < 12_000, "the contour costs \(built.content.count) bytes")
}

// The states an overlay carries are built for the page rather than chosen from a
// fixed few, because a stroke's opacity comes out of the file: the shader of a
// live page states its own quarter in the alpha byte of `argb`, and no fixed
// state could hold a number nobody has seen yet.
@Test("A stroke of any opacity gets a state of its own")
func markContentBuildsTheStatesItNeeds() throws {
    let shader = Stroke(
        tool: .shader,
        color: .highlight,
        thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 12, pressure: 1),
            StrokePoint(x: 40, y: 10, width: 16, pressure: 1),
        ],
        argb: 0x4021_1E1C
    )
    let built = try #require(
        MarkContentStream.build(
            RMPage(strokes: [shader], skippedBlocks: 0),
            mediaBox: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    )
    let state = try #require(built.states.first)

    #expect(built.states.count == 1)
    #expect(state.blendMode == "Darken")
    #expect(abs(state.alpha - 0x40 / 255.0) < 0.001, "the opacity the file states")
    #expect(String(decoding: built.content, as: UTF8.self).contains("/\(state.name) gs"))
}

@Test("A marker stroke asks for Darken rather than for an alpha")
func markContentDarkensTheMarker() throws {
    // The tablet's own export declares `BM /Darken` at full opacity for it.
    // An alpha in its place lightens the text under the band, which is the
    // one thing a highlight must not do.
    let marker = Stroke(
        tool: .highlighter2,
        color: .yellow,
        thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 120, pressure: 1),
            StrokePoint(x: 40, y: 0, width: 120, pressure: 1),
        ]
    )
    let built = try #require(
        MarkContentStream.build(
            RMPage(strokes: [marker], skippedBlocks: 0),
            mediaBox: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    )
    let text = String(decoding: built.content, as: UTF8.self)

    let darken = try #require(built.states.first { $0.blendMode == "Darken" })
    #expect(darken.alpha == 1, "the marker darkens at full opacity")
    #expect(text.contains("/\(darken.name) gs"))
    // 120 / 4 = 30 units of `.rm`, and no ceiling on the way: one there
    // would cut every marker stroke by a fifth.
    #expect(text.contains(PDFWriter.number(30 * Calibration.pointsPerUnit) + " w"))
}

// The content stream numbers its states afresh on every page — `RMGs0` is
// whatever a page asked for first. Were the writer to gather one table of
// names for the whole document, two pages that both said `/RMGs0` and meant
// different things by it would get the first page's: a translucent stroke on
// the second page would come out multiplied at full opacity, and nothing
// would fail to say so.
@Test("Two pages that call different states by one name each get their own")
func overlayKeepsGraphicsStateNamesPerPage() throws {
    let original = try makeDocument(pages: 2)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    // Page one carries the marker, and its state is the one `MarkContentStream`
    // builds for a highlight; page two carries a stroke at 0.6 and no blend
    // mode, under the name the stream gives the first state of any page.
    let highlight = Highlight(rectangles: [CGRect(x: 0, y: 0, width: 40, height: 10)], color: .yellow)
    let marked = try #require(
        MarkContentStream.build(
            RMPage(strokes: [], skippedBlocks: 0, highlights: [highlight]),
            mediaBox: CGRect(x: 0, y: 0, width: 200, height: 300)
        )
    )
    let marker = try #require(marked.states.first)
    #expect(marker.name == "RMGs0")
    #expect(marker.blendMode == "Multiply")
    let translucent = PDFOverlayWriter.GraphicsState(name: marker.name, blendMode: nil, alpha: 0.6)

    try PDFOverlayWriter().write(
        original: original,
        overlays: [
            PDFOverlayWriter.Overlay(pageIndex: 0, content: marked.content, states: marked.states),
            PDFOverlayWriter.Overlay(
                pageIndex: 1,
                content: Data("q /\(translucent.name) gs 0 0 0 RG 10 w 20 150 m 180 150 l S Q\n".utf8),
                states: [translucent]
            ),
        ],
        to: output
    )

    let file = try PDFFile(url: output)
    let pages = try file.pages()
    func state(onPage index: Int) throws -> [String: PDFObject] {
        let resources = try #require(try file.resolve(pages[index].resources).dictionaryValue)
        let objects = try #require(try file.resolve(resources["XObject"]).dictionaryValue)
        let form = try #require(try file.resolve(objects["RMOverlay"]).dictionaryValue)
        let scoped = try #require(try file.resolve(form["Resources"]).dictionaryValue)
        let states = try #require(try file.resolve(scoped["ExtGState"]).dictionaryValue)
        return try #require(try file.resolve(states[marker.name]).dictionaryValue)
    }

    let first = try state(onPage: 0)
    #expect(first["BM"]?.nameValue == "Multiply")
    #expect(first["ca"]?.doubleValue == 1)

    let second = try state(onPage: 1)
    #expect(second["BM"] == nil, "the stroke asked for no blend mode and was given the marker's")
    #expect(second["ca"]?.doubleValue == 0.6, "the stroke's own opacity, not the marker's")
}

/// A PDF written by hand, with the two shapes Quartz never produces: the page
/// points at its contents through a reference to an *array*, and it is cropped
/// to less than its media box. Both are ordinary in books and scans, and either
/// one mishandled goes wrong quietly.
private func makeHandwrittenDocument() throws -> URL {
    var body = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = [0]
    func emit(_ number: Int, _ text: String) {
        offsets.append(body.count)
        body.append(contentsOf: Array("\(number) 0 obj\n\(text)\nendobj\n".utf8))
    }
    let stream = "0 0 0 RG 4 w 20 20 m 180 180 l S"
    emit(1, "<< /Type /Catalog /Pages 2 0 R >>")
    emit(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200] >>")
    emit(3, "<< /Type /Page /Parent 2 0 R /CropBox [10 10 190 190] /Contents 4 0 R >>")
    emit(4, "[5 0 R]")
    emit(5, "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")

    let startxref = body.count
    body.append(contentsOf: Array("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() {
        body.append(contentsOf: Array(String(format: "%010d 00000 n \n", offset).utf8))
    }
    body.append(contentsOf: Array("""
    trailer
    << /Size \(offsets.count) /Root 1 0 R >>
    startxref
    \(startxref)
    %%EOF

    """.utf8))

    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    try body.write(to: url)
    return url
}

@Test("A page cropped to less than its sheet says so")
func readerSeesTheCropBox() throws {
    let original = try makeHandwrittenDocument()
    defer { try? FileManager.default.removeItem(at: original) }

    let page = try #require(try PDFFile(url: original).pages().first)
    #expect(page.mediaBox == CGRect(x: 0, y: 0, width: 200, height: 200))
    #expect(page.cropBox == CGRect(x: 10, y: 10, width: 180, height: 180))
}

@Test("Contents behind a reference to an array keep the page's own drawing")
func overlayUnwrapsAnIndirectContentsArray() throws {
    let original = try makeHandwrittenDocument()
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }

    try PDFOverlayWriter().write(
        original: original,
        overlays: [overlay("0 0 0 RG 8 w 20 180 m 180 20 l S\n")],
        to: output
    )

    // Every entry of the new `/Contents` has to be a stream. An array wrapped
    // inside an array reads as no content at all, and the page's own drawing
    // would vanish while our marks stayed.
    let file = try PDFFile(url: output)
    let page = try #require(try file.pages().first)
    let contents = try #require(try file.resolve(page.dictionary["Contents"]).arrayValue)
    for entry in contents {
        guard case .stream = try file.resolve(entry) else {
            Issue.record("an entry of /Contents that is not a stream: \(entry)")
            return
        }
    }
    // Both drawings are there: the page's own diagonal and ours.
    #expect(try ink(output, page: 1) > (try ink(original, page: 1)))
}

@Test("A colour is not read as a reference")
func scannerDoesNotMistakeColoursForReferences() throws {
    // `1 0 RG` is three tokens of a content stream. Matching `R` by prefix
    // turned it into the reference `1 0 R` and swallowed the rest.
    var scanner = PDFScanner(bytes: Data("1 0 RG".utf8), index: 0)
    #expect(try scanner.nextObject() == .integer(1))

    var reference = PDFScanner(bytes: Data("1 0 R".utf8), index: 0)
    #expect(try reference.nextObject() == .reference(number: 1, generation: 0))
}

@Test("Numbers go out the way PDF wants them, without exponents")
func numbersAreWrittenPlainly() {
    #expect(PDFWriter.number(3) == "3")
    #expect(PDFWriter.number(0.5) == "0.5")
    #expect(PDFWriter.number(0.00001) == "0")
    #expect(PDFWriter.number(-2.25) == "-2.25")
}

// The pieces an eraser left of one shader stroke go onto a PDF as one fill,
// the way the renderer draws them in one layer: a fill each would deepen
// where they meet. Two shader strokes that merely cross stay two fills, as on
// the tablet.
@Test("An overlay fills the pieces of one erased shader stroke once")
func overlayFillsShaderPiecesOnce() throws {
    func shader(_ from: Float, _ to: Float, source: SceneItemID?) -> Stroke {
        Stroke(
            tool: .shader, color: .highlight, thicknessScale: 1,
            points: stride(from: from, through: to, by: 20).map { StrokePoint(x: $0, y: 500, width: 176, pressure: 1) },
            argb: 0x4021_1E1C, sourceId: source
        )
    }
    let box = CGRect(x: 0, y: 0, width: 612, height: 792)
    func fills(_ strokes: [Stroke]) throws -> Int {
        let built = try #require(MarkContentStream.build(RMPage(strokes: strokes, skippedBlocks: 0), mediaBox: box))
        return String(decoding: built.content, as: UTF8.self).components(separatedBy: "f Q").count - 1
    }
    let source = SceneItemID(author: 1, counter: 17)
    #expect(try fills([shader(-300, 100, source: source), shader(-100, 300, source: source)]) == 1)
    #expect(try fills([shader(-300, 100, source: nil), shader(-100, 300, source: nil)]) == 2)
}
