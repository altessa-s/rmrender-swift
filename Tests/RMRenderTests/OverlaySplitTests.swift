// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import RMLines
import Testing

// A native page of an overlay in its two shares (`InkForm`): CoreGraphics
// draws the text and the pictures and the strokes up to the last of them,
// the ink writer the rest, and the overlay imports each as a Form of its own.
// What these guard: that a page whose text layer sets nothing is its ink
// alone, that the rule saying so is never wrong the unsafe way, and that
// either way every page paints what CoreGraphics drawing all of it paints.

// MARK: - What CoreGraphics' share paints

/// Whether a PDF's page `number` holds an operator that paints: a stroke or
/// a fill, text, an XObject, a shading or an inline image. A page that does
/// not scan counts as painting.
private func paints(_ pdf: Data, page number: Int = 1) throws -> Bool {
    let document = try #require(CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init))
    let page = try #require(document.page(at: number))
    let table = try #require(CGPDFOperatorTableCreate())
    defer { CGPDFOperatorTableRelease(table) }
    for name in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "sh", "Do", "Tj", "TJ", "'", "\"", "BI", "EI", "d0", "d1"] {
        CGPDFOperatorTableSetCallback(table, name) { _, info in
            info?.assumingMemoryBound(to: Bool.self).pointee = true
        }
    }
    let content = CGPDFContentStreamCreateWithPage(page)
    defer { CGPDFContentStreamRelease(content) }
    var painted = false
    return withUnsafeMutablePointer(to: &painted) { flag in
        let scanner = CGPDFScannerCreate(content, table, flag)
        defer { CGPDFScannerRelease(scanner) }
        return !CGPDFScannerScan(scanner) || flag.pointee
    }
}

/// `marks` drawn by CoreGraphics alone, every stroke of them, as the native
/// share of an overlay page draws them, into a PDF of one page.
private func drawnByCoreGraphics(_ marks: RMPage) throws -> Data {
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let units = AnnotationGeometry.units(of: sheet.size)
    let geometry = marks.text.map { TextGeometry($0, pageSize: units) }
    let bounds = PageRenderer.contentBounds(of: marks, pageSize: units, edge: AnnotatedPDFRenderer.markEdge, geometry: geometry)
    let shares = try AnnotatedPDFRenderer.nativeShares(
        marks, drawingBox: sheet, mediaBox: AnnotationGeometry.box(bounds, on: sheet), units: units, bounds: bounds,
        geometry: geometry, images: PageRenderer.PageImages(bytes: ["picture.png": testPicture()]), writesInk: false
    )
    return try #require(shares.pdf)
}

/// Text blocks the tablet writes on a page nobody typed on.
private let blankBlocks: [[String]] = [[""], ["", ""], ["", "", ""]]

@Test("A text layer the overlay calls blank sets nothing CoreGraphics paints, and what it does not call blank does")
func blankTextLayersPaintNothing() throws {
    for lines in blankBlocks {
        let marks = RMPage(strokes: [], skippedBlocks: 0, text: typedText(lines))
        #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(marks, split: 0), "\(lines)")
        #expect(try !paints(try drawnByCoreGraphics(marks)), "\(lines)")
    }
    // And the scan sees what does paint: a letter; a space, a tab or a line
    // break, which CoreText sets a glyph for; a list's marker on a line of
    // no text, a checkbox.
    let painting: [TextBlock] = [
        typedText(["a"]), typedText(["", "."]), typedText(["   "]), typedText(["\t"]), typedText(["\n"]),
        typedText([" \r\n ", "\r"]),
        typedText([""], formats: [0: ParagraphFormat(style: .bullet)]),
        typedText(["", ""], formats: [1: ParagraphFormat(style: .numbered)]),
        typedText([" "], formats: [0: ParagraphFormat(style: .checkbox)]),
    ]
    for block in painting {
        let marks = RMPage(strokes: [], skippedBlocks: 0, text: block)
        #expect(AnnotatedPDFRenderer.coreGraphicsPaints(marks, split: 0), "\(block.lines)")
        #expect(try paints(try drawnByCoreGraphics(marks)), "\(block.lines)")
    }
}

@Test("CoreGraphics' share is blank only with nothing before the split, no picture, no highlight it draws and no template")
func coreGraphicsShareRule() {
    _ = FixtureTemplates.installed
    let blank = typedText([""])
    let stroke = Stroke(tool: .fineliner2, color: .black, thicknessScale: 1, points: [
        StrokePoint(x: 0, y: 100, width: 8, pressure: 1), StrokePoint(x: 40, y: 120, width: 8, pressure: 1),
    ])
    #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [stroke], skippedBlocks: 0, text: blank), split: 0))
    #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [stroke], skippedBlocks: 0), split: 0))
    #expect(AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [stroke], skippedBlocks: 0, text: blank), split: 1))
    let picture = PageImage(
        file: "picture.png",
        vertices: [
            .init(x: 0, y: 0, u: 0, v: 0), .init(x: 10, y: 0, u: 1, v: 0), .init(x: 10, y: 10, u: 1, v: 1),
            .init(x: 0, y: 10, u: 0, v: 1),
        ],
        strokesBefore: 1
    )
    #expect(AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [], skippedBlocks: 0, images: [picture]), split: 0))
    let highlight = Highlight(rectangles: [CGRect(x: 0, y: 0, width: 50, height: 10)], color: .yellow)
    #expect(AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [], skippedBlocks: 0, highlights: [highlight]), split: 0))
    // Unless the highlights are written with the ink.
    #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(
        RMPage(strokes: [], skippedBlocks: 0, text: blank, highlights: [highlight]), split: 0, writtenHighlights: true
    ))
    #expect(AnnotatedPDFRenderer.coreGraphicsPaints(
        RMPage(strokes: [], skippedBlocks: 0, highlights: [highlight], images: [picture]), split: 0, writtenHighlights: true
    ))
    #expect(AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [], skippedBlocks: 0, templateName: "Fixture Lines"), split: 0))
    // A template the page hides, or one nobody has, is not drawn.
    #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(
        RMPage(strokes: [], skippedBlocks: 0, templateName: "Fixture Lines", backgroundVisible: false), split: 0
    ))
    #expect(!AnnotatedPDFRenderer.coreGraphicsPaints(RMPage(strokes: [], skippedBlocks: 0, templateName: "No such"), split: 0))
}

// MARK: - Pages in two shares paint as CoreGraphics drawing them whole

/// The scales the pages are held against CoreGraphics at.
private let scales: [Double] = [1, 1.5, 3.25]

@Test("A page whose text layer sets nothing is its ink alone, and paints as CoreGraphics drawing it all does")
func blankTextPagesAreTheirInkAlone() throws {
    var marks = Marks(random: SplitMix64(seed: 0xB1A2))
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let images = PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    // Every tool but the shader, whose cut pieces share a layer only
    // CoreGraphics draws: the eraser, the pencils' grain and translucent
    // ink are all the writer's.
    let tools = Marks.allTools.filter { $0 != .shader }
    var written: [PDFOverlayWriter.Overlay] = [], whole: [PDFOverlayWriter.Overlay] = []
    for (index, lines) in blankBlocks.enumerated() {
        let page = marks.page(strokes: 30, tools: tools, blankText: lines)
        let overlay = try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images)
        #expect(overlay.formPDF == nil, "page \(index): CoreGraphics drew a share of it")
        #expect(overlay.ink != nil, "page \(index)")
        written.append(overlay)
        whole.append(try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images, writesInk: false))
    }
    let writtenPDF = try InkTesting.overlaid(written, pages: blankBlocks.count, sheet: sheet)
    let wholePDF = try InkTesting.overlaid(whole, pages: blankBlocks.count, sheet: sheet)
    #expect(!String(decoding: writtenPDF, as: UTF8.self).contains("/RMNative"))
    for page in 1...blankBlocks.count {
        for scale in scales {
            #expect(try InkTesting.differingPixels(wholePDF, writtenPDF, page: page, scale: scale) == 0, "page \(page) at \(scale)")
        }
    }
}

@Test("A page in two shares paints as CoreGraphics drawing it all does, at every scale")
func pagesInTwoSharesPaintAsCoreGraphicsDoes() throws {
    var marks = Marks(random: SplitMix64(seed: 0x5717))
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let images = PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    let count = 8
    var written: [PDFOverlayWriter.Overlay] = [], whole: [PDFOverlayWriter.Overlay] = []
    var both = 0
    for index in 0..<count {
        // Typed text, pictures and shaders, and blank text layers with them:
        // pages CoreGraphics has a share of, and most of them ink after it.
        let page = index.isMultiple(of: 2)
            ? marks.page(strokes: 40, pictures: index.isMultiple(of: 4), text: true)
            : marks.page(strokes: 40, pictures: index.isMultiple(of: 3), blankText: [""])
        let overlay = try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images)
        if overlay.formPDF != nil, overlay.ink != nil { both += 1 }
        written.append(overlay)
        whole.append(try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images, writesInk: false))
    }
    #expect(both >= count / 2, "\(both) pages in two shares")
    let writtenPDF = try InkTesting.overlaid(written, pages: count, sheet: sheet)
    let wholePDF = try InkTesting.overlaid(whole, pages: count, sheet: sheet)
    for page in 1...count {
        for scale in scales {
            #expect(try InkTesting.differingPixels(wholePDF, writtenPDF, page: page, scale: scale) == 0, "page \(page) at \(scale)")
        }
    }
}

@Test("The ink goes into the update as it was written, a Form of its own beside CoreGraphics' share")
func inkIsImportedAsWritten() throws {
    var marks = Marks(random: SplitMix64(seed: 0x1D7))
    let sheet = CGRect(x: 0, y: 0, width: 612, height: 792)
    let page = marks.page(strokes: 30, pictures: true, text: true)
    let overlay = try InkTesting.nativeOverlay(
        page, sheet: sheet, images: PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    )
    let native = try #require(overlay.formPDF)
    let ink = try #require(overlay.ink)
    let file = try PDFFile(bytes: try InkTesting.overlaid([overlay], sheet: sheet))
    var forms: [String: Data] = [:]
    for number in file.offsets.keys {
        guard case .stream(let dictionary, let bytes) = try file.object(number),
              dictionary["Subtype"]?.nameValue == "Form" else { continue }
        let resources = try file.resolve(dictionary["Resources"]).dictionaryValue ?? [:]
        let objects = try file.resolve(resources["XObject"]).dictionaryValue ?? [:]
        if objects["RMNative"] != nil { forms["overlay"] = bytes }
        if resources["ColorSpace"].flatMap({ try? file.resolve($0).dictionaryValue?[InkStream.colorSpaceName] }) != nil,
           resources["Font"] == nil {
            forms["ink"] = bytes
        } else if resources["Font"] != nil {
            forms["native"] = bytes
        }
    }
    // The ink's stream as it was written, and CoreGraphics' share of the
    // page the operators it drew.
    #expect(try forms["native"].map { try PDFStreamCodec.decode(["Filter": .name("FlateDecode")], $0) }
        == InkTesting.content(of: native, page: 1))
    #expect(forms["ink"] == ink.ink.content.reduce(into: Data()) { $0.append($1) })
    #expect(try forms["overlay"].map { try PDFStreamCodec.decode(["Filter": .name("FlateDecode")], $0) }
        == Data("q /RMNative Do /RMInk Do Q\n".utf8))
}
