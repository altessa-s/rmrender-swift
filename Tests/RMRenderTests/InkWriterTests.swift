// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import RMRender
import RMLines
import Synchronization
import Testing

// The ink this package writes in CoreGraphics' place (`InkStream`, appended
// by `InkUpdate`) against CoreGraphics itself: the same geometry printed the
// same way, and pages painting exactly what CoreGraphics' own pages paint.

/// What the tests read out of PDFs and draw them into.
enum InkTesting {
    /// The decoded content of page 1 of a PDF CoreGraphics draws with `draw`.
    static func pageContent(width: Double, height: Double, draw: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return try content(of: data as Data, page: 1)
    }

    /// The decoded content streams of a page, one after another.
    static func content(of pdf: Data, page number: Int) throws -> Data {
        let file = try PDFFile(bytes: pdf)
        let page = try file.pages()[number - 1]
        var out = Data()
        var contents = try file.resolve(page.dictionary["Contents"])
        if case .stream = contents { contents = .array([page.dictionary["Contents"] ?? .null]) }
        for item in contents.arrayValue ?? [] {
            if case .stream(let dictionary, let bytes) = try file.resolve(item) {
                out.append(try file.decode(dictionary, bytes))
                out.append(10)
            }
        }
        return out
    }

    /// One raster at a time. CoreGraphics draws a page with image masks
    /// differently while it draws another beside it — the same file came out
    /// with a thousand pixels changed in fifteen of twenty-four rasters taken
    /// side by side, and in none taken one by one — so the pixels compared
    /// here are drawn one after another.
    private static let rasterLock = Mutex(())

    /// Page `number` of `pdf` drawn at `scale` onto white sRGB, its pixels.
    static func raster(_ pdf: Data, page number: Int, scale: Double) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        try rasterLock.withLock { _ in try unlockedRaster(pdf, page: number, scale: scale) }
    }

    private static func unlockedRaster(
        _ pdf: Data, page number: Int, scale: Double
    ) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let document = try #require(CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init))
        let page = try #require(document.page(at: number))
        let box = page.getBoxRect(.mediaBox)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (width, height, Array(UnsafeBufferPointer(start: buffer, count: width * height * 4)))
    }

    /// How many pixels of page `number` differ between `a` and `b` at
    /// `scale`; -1 where the pages are not the same size.
    static func differingPixels(_ a: Data, _ b: Data, page number: Int, scale: Double) throws -> Int {
        let first = try raster(a, page: number, scale: scale), second = try raster(b, page: number, scale: scale)
        guard first.width == second.width, first.height == second.height else { return -1 }
        var differing = 0
        for index in stride(from: 0, to: first.pixels.count, by: 4)
        where first.pixels[index..<index + 4] != second.pixels[index..<index + 4] {
            differing += 1
        }
        return differing
    }

    /// The pages as develop drew them: every mark by CoreGraphics, into one
    /// context, the way `PageRenderer.PDFPages` drew a page before any of its
    /// ink was written apart.
    static func allCoreGraphics(
        pages: [RMPage], pageSize: CGSize, paper: PaperSize = .a4, assets: [String: Data] = [:]
    ) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let paperSize = paper.points(forCanvas: pageSize)
        var box = CGRect(origin: .zero, size: paperSize)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let scale = paperSize.width / pageSize.width
        for page in pages {
            let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
            let bounds = PageRenderer.contentBounds(of: page, pageSize: pageSize, edge: .ribbon, geometry: geometry)
            let sheet = PageRenderer.grownSheet(from: bounds, floor: paperSize, scale: scale)
            var media = CGRect(origin: .zero, size: sheet)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.saveGState()
            context.concatenate(PageRenderer.placement(of: bounds, on: sheet, scale: scale))
            PageRenderer.draw(
                page, in: context, pageSize: pageSize, bounds: bounds, images: PageRenderer.PageImages(bytes: assets),
                geometry: geometry, templateIsArtifact: true
            )
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The overlay of page `index` as `AnnotatedPDFRenderer` draws a native
    /// one on a sheet standing at `sheet`: CoreGraphics' share and the
    /// written ink (`AnnotatedPDFRenderer.nativeShares`) — or, `writesInk`
    /// off, all of it drawn by CoreGraphics, as develop drew it.
    static func nativeOverlay(
        _ marks: RMPage, index: Int = 0, sheet: CGRect, images: PageRenderer.PageImages = PageRenderer.PageImages(),
        writesInk: Bool = true
    ) throws -> PDFOverlayWriter.Overlay {
        let units = AnnotationGeometry.units(of: sheet.size)
        let geometry = marks.text.map { TextGeometry($0, pageSize: units) }
        let bounds = PageRenderer.contentBounds(
            of: marks, pageSize: units, edge: AnnotatedPDFRenderer.markEdge, geometry: geometry
        )
        let grown = AnnotationGeometry.box(bounds, on: sheet)
        let shares = try AnnotatedPDFRenderer.nativeShares(
            marks, drawingBox: sheet, mediaBox: grown, units: units, bounds: bounds, geometry: geometry, images: images,
            writesInk: writesInk
        )
        return PDFOverlayWriter.Overlay(
            pageIndex: index, content: InkForm.content(native: shares.pdf != nil, ink: shares.ink != nil), states: [],
            box: grown, formPDF: shares.pdf, ink: shares.ink
        )
    }

    /// `overlays` written onto a PDF of `pages` blank pages of `sheet`.
    static func overlaid(_ overlays: [PDFOverlayWriter.Overlay], pages: Int = 1, sheet: CGRect) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-ink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "original.pdf"), output = folder.appending(path: "overlaid.pdf")
        var box = sheet
        let context = try #require(CGContext(original as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        try PDFOverlayWriter().write(original: original, overlays: overlays, to: output)
        return try Data(contentsOf: output)
    }

    /// `pdf` with what CoreGraphics makes up afresh each time — the dates
    /// and the identifier — written over, so that two renders can be
    /// compared to the byte.
    static func normalized(_ pdf: Data) -> Data {
        var text = [UInt8](pdf)
        for key in ["/CreationDate", "/ModDate"] {
            let pattern = Array(key.utf8)
            var index = 0
            while let found = find(pattern, in: text, from: index) {
                // CoreGraphics breaks its lines anywhere, between a key and
                // its value too.
                var end = found + pattern.count
                while end < text.count, text[end] == UInt8(ascii: " ") || text[end] == 10 || text[end] == UInt8(ascii: "(") {
                    end += 1
                }
                while end < text.count, text[end] != UInt8(ascii: ")") {
                    text[end] = UInt8(ascii: "0")
                    end += 1
                }
                index = end
            }
        }
        let pattern = Array("/ID [".utf8)
        var index = 0
        while let found = find(pattern, in: text, from: index) {
            var end = found + pattern.count
            while end < text.count, text[end] != UInt8(ascii: "]") {
                if ![UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: " "), 10].contains(text[end]) {
                    text[end] = UInt8(ascii: "0")
                }
                end += 1
            }
            index = end
        }
        return Data(text)
    }

    private static func find(_ pattern: [UInt8], in text: [UInt8], from start: Int) -> Int? {
        guard pattern.count <= text.count else { return nil }
        var index = start
        while index + pattern.count <= text.count {
            if text[index] == pattern[0], Array(text[index..<index + pattern.count]) == pattern { return index }
            index += 1
        }
        return nil
    }
}

/// Random numbers for the marks: a generator of its own, so that a failure
/// can be had again.
struct Marks {
    var random: SplitMix64

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(random.next() >> 11) / 9_007_199_254_740_992.0
    }

    mutating func below(_ count: Int) -> Int { Int(random.next() % UInt64(count)) }

    /// A wandering line of `count` points from near `(x, y)`.
    mutating func points(count: Int, x: Double, y: Double) -> [StrokePoint] {
        var current = (x: x, y: y)
        return (0..<count).map { _ in
            current.x += uniform(-4, 14)
            current.y += uniform(-12, 12)
            return StrokePoint(
                x: Float(current.x), y: Float(current.y),
                width: Float(uniform(4, 60)), pressure: Float(uniform(0.05, 1)), speed: Float(uniform(0, 200))
            )
        }
    }

    /// Every tool, erasers and shaders among them.
    static let allTools: [PenTool] = [
        .paintbrush1, .pencil1, .ballpoint1, .marker1, .fineliner1, .highlighter1, .mechanicalPencil1,
        .paintbrush2, .mechanicalPencil2, .pencil2, .ballpoint2, .marker2, .fineliner2, .highlighter2,
        .caligraphy, .shader, .eraser, .eraserArea,
    ]

    /// A page of `count` strokes of `tools`; `pictures` places images among
    /// the strokes as well, `text` typed text with handwriting anchored to it
    /// and a marker over it, `blankText` a text block of the lines given, as
    /// the tablet writes on a page nobody typed on, `highlights` that many
    /// highlights of a few bands each, as the marker leaves over a PDF's text.
    mutating func page(
        strokes count: Int, tools: [PenTool] = allTools, pictures: Bool = false, text: Bool = false,
        blankText: [String]? = nil, template: String? = nil, highlights bands: Int = 0
    ) -> RMPage {
        let colors: [PenColor] = [.black, .gray, .blue, .red, .yellow, .green]
        var strokes: [Stroke] = []
        for index in 0..<count {
            let tool = tools[below(tools.count)]
            let points = self.points(count: 3 + below(30), x: uniform(-650, 500), y: uniform(50, 1800))
            let argb: UInt32? = index.isMultiple(of: 4) ? UInt32(below(256)) << 24 | UInt32(random.next() & 0xFF_FFFF) : nil
            strokes.append(
                Stroke(tool: tool, color: colors[below(colors.count)], thicknessScale: uniform(0.5, 3), points: points, argb: argb)
            )
        }
        var images: [PageImage] = []
        if pictures {
            images.append(
                PageImage(
                    file: "picture.png",
                    vertices: [
                        .init(x: -300, y: 300, u: 0, v: 0), .init(x: 100, y: 300, u: 1, v: 0),
                        .init(x: 100, y: 600, u: 1, v: 1), .init(x: -300, y: 600, u: 0, v: 1),
                    ],
                    strokesBefore: count / 2
                )
            )
        }
        var highlights: [Highlight] = []
        var block: TextBlock?
        if text {
            block = typedText(["Typed text the ink is written over", "and a second paragraph of it", "a third"])
            for paragraph in 0..<3 {
                strokes.append(
                    Stroke(
                        tool: .fineliner2, color: .blue, thicknessScale: 1,
                        points: self.points(count: 6, x: 0, y: 0),
                        anchor: TextAnchor(paragraph: paragraph, offset: 3)
                    )
                )
            }
            highlights.append(Highlight(rectangles: [CGRect(x: -500, y: 280, width: 600, height: 50)], color: .yellow))
        } else if let blankText {
            block = typedText(blankText)
        }
        let markers: [PenColor] = [.yellow, .yellow, .green, .pink, .highlighterBlue, .highlighterOrange, .gray]
        for index in 0..<bands {
            let top = uniform(0, 1700)
            let rectangles = (0..<(1 + below(3))).map { line in
                CGRect(x: uniform(-650, 200), y: top + Double(line) * 53.4, width: uniform(40, 900), height: 44.9)
            }
            // The file's own colour on some, as a live page carries one.
            let argb: UInt32? = index % 3 == 1 ? 0xFF00_0000 | UInt32(random.next() & 0xFF_FFFF) : nil
            highlights.append(Highlight(rectangles: rectangles, color: markers[below(markers.count)], argb: argb))
        }
        return RMPage(
            strokes: strokes, skippedBlocks: 0, templateName: template, text: block, highlights: highlights, images: images
        )
    }
}

@Test("A context's transform is worked out the same on a bitmap as on a PDF page")
func contextTransformIsThePDFContexts() throws {
    var marks = Marks(random: SplitMix64(seed: 7))
    for _ in 0..<500 {
        let placement = CGAffineTransform(translationX: marks.uniform(-300, 300), y: marks.uniform(-900, 900))
            .scaledBy(x: marks.uniform(0.05, 2), y: marks.uniform(0.05, 2))
        let scale = marks.uniform(0.1, 1.5)
        let pdf = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: pdf as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.saveGState()
        context.concatenate(placement)
        #expect(context.ctm == PageRenderer.contextTransform { $0.concatenate(placement) })
        context.restoreGState()
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        #expect(context.ctm == PageRenderer.contextTransform { $0.scaleBy(x: scale, y: scale) })
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
    }
}

/// The paints of `count` random marks of every kind the writer takes, near
/// `(x, y)` in a page of `.rm` size: fills, fills an eraser cut (quadratic
/// segments and all), masks — some of one another's bytes in other
/// dimensions — and lines of every cap and join, translucent and darkening.
private func randomPaints(_ marks: inout Marks, count: Int) -> [PageRenderer.StrokePaint] {
    let eraser = CGMutablePath()
    eraser.addEllipse(in: CGRect(x: 300, y: 600, width: 500, height: 300))
    eraser.addRect(CGRect(x: 100, y: 1200, width: 1200, height: 80))
    var masks: [StrokeGrainMask.Bits] = []
    var paints: [PageRenderer.StrokePaint] = []
    for index in 0..<count {
        let x = marks.uniform(0, 1300), y = marks.uniform(0, 1800)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y))
        for step in 1..<10 {
            let end = CGPoint(x: x + Double(step) * marks.uniform(3, 30), y: y + marks.uniform(-40, 40))
            if step.isMultiple(of: 4) {
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: x + marks.uniform(0, 90), y: y + marks.uniform(-30, 30)),
                    control2: CGPoint(x: x + marks.uniform(0, 90), y: y + marks.uniform(-30, 30))
                )
            } else {
                path.addLine(to: end)
            }
        }
        path.closeSubpath()
        let red = marks.uniform(0, 1), green = marks.uniform(0, 1), blue = marks.uniform(0, 1)
        let alpha = index.isMultiple(of: 5) ? marks.uniform(0.2, 0.9) : 1
        let darkens = index % 3 == 1
        let shape: PageRenderer.StrokePaint.Shape
        switch index % 6 {
        case 0:
            shape = .fill(path)
        case 1, 5:
            // Masks of shared bytes but other dimensions follow one another.
            let width = 10 + (index % 4) * 2
            var bits: [UInt8]
            if index % 9 == 1, let previous = masks.last, previous.data.count == 2 * 16 {
                bits = previous.data
            } else {
                bits = (0..<(2 * 16)).map { _ in UInt8(truncatingIfNeeded: marks.random.next()) }
            }
            let mask = StrokeGrainMask.Bits(width: width, height: 16, bytesPerRow: 2, data: bits)
            masks.append(mask)
            let clip = index % 6 == 5 ? path.subtracting(eraser) : path
            shape = .mask(clip: clip, bits: mask, rectangle: CGRect(x: x, y: y - 20, width: 60, height: 40))
        case 2:
            let points = (0..<10).map { _ in CGPoint(x: x + marks.uniform(0, 200), y: y + marks.uniform(-60, 60)) }
            let caps: [CGLineCap] = [.butt, .round, .square], joins: [CGLineJoin] = [.miter, .round, .bevel]
            shape = .line(points: points, width: marks.uniform(0.5, 30), cap: caps[index % 3], join: joins[(index / 6) % 3])
        case 3:
            shape = .fill(path.subtracting(eraser))
        default:
            shape = .fill(path.copy(strokingWithWidth: marks.uniform(1, 20), lineCap: .round, lineJoin: .round, miterLimit: 2)
                .subtracting(eraser))
        }
        paints.append(
            PageRenderer.StrokePaint(
                shape: shape, red: red, green: green, blue: blue, alpha: alpha, darkens: darkens, inSharedLayer: false
            )
        )
    }
    return paints
}

/// A one-page PDF of `paints` under `transform`: the first `split` drawn by
/// CoreGraphics, the rest written apart and appended — or all of them by
/// CoreGraphics where `split` is `nil`.
private func page(
    _ paints: [PageRenderer.StrokePaint], transform: CGAffineTransform, split: Int?, size: CGSize
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
    for paint in paints.prefix(split ?? paints.count) { paint.draw(in: context, masks: split == nil ? nil : update.masks) }
    context.restoreGState()
    context.endPDFPage()
    if let split {
        let placed = try #require(PageRenderer.contextTransform { $0.concatenate(transform) })
        let stream = try #require(InkStream(transform: placed))
        for paint in paints.dropFirst(split) { paint.write(into: stream) }
        try update.append(try #require(PreparedInk(stream)), page: 0)
    }
    context.closePDF()
    try update.finish(into: sink)
    try sink.close()
    return data as Data
}

@Test("Written ink paints what CoreGraphics paints, mark for mark and pixel for pixel", arguments: [false, true])
func writtenInkPaintsWhatCoreGraphicsPaints(mixed: Bool) throws {
    var marks = Marks(random: SplitMix64(seed: mixed ? 0x5EED_0001 : 0x5EED_0002))
    let paints = randomPaints(&marks, count: 120)
    let size = CGSize(width: 445.33216129, height: 593.7762345)
    for transform in [
        CGAffineTransform(translationX: 1.5, y: -7.25).scaledBy(x: 0.317180616, y: 0.317180616),
        CGAffineTransform(scaleX: 0.3171806167400881, y: 0.3171806167400881),
    ] {
        let native = try page(paints, transform: transform, split: nil, size: size)
        // Mixed: CoreGraphics draws a share first, masks among it, as it does
        // a page's marks before its last picture.
        let written = try page(paints, transform: transform, split: mixed ? 40 : 0, size: size)
        let content = String(decoding: try InkTesting.content(of: written, page: 1), as: UTF8.self)
        #expect(content.contains("/RMIx") && content.contains("/RMIg") && content.contains("/RMIc"))
        for scale in [1, 2.5, 6.25] {
            let differing = try InkTesting.differingPixels(native, written, page: 1, scale: scale)
            #expect(differing == 0, "scale \(scale)")
        }
    }
}

/// The path-drawing operators of a content stream with their operands, in
/// order: the geometry, without the state around it.
private func geometry(_ content: Data) -> [String] {
    let tokens = String(decoding: content, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
    var operands: [Substring] = []
    var out: [String] = []
    for token in tokens {
        if let first = token.first, first.isNumber || first == "-" || first == "." {
            operands.append(token)
            continue
        }
        if ["m", "l", "c", "h", "cm"].contains(token) {
            out.append((operands + [token]).joined(separator: " "))
        }
        operands = []
    }
    return out
}

@Test("Written ink prints every coordinate CoreGraphics prints, to the character")
func writtenInkPrintsCoreGraphicsGeometry() throws {
    var marks = Marks(random: SplitMix64(seed: 0x6E0_3E7))
    let paints = randomPaints(&marks, count: 300)
    let size = CGSize(width: 445.33216129, height: 593.7762345)
    let transform = CGAffineTransform(translationX: 1.5, y: -7.25).scaledBy(x: 0.317180616, y: 0.317180616)
    let native = try InkTesting.content(of: try page(paints, transform: transform, split: nil, size: size), page: 1)
    let written = try InkTesting.content(of: try page(paints, transform: transform, split: 0, size: size), page: 1)
    let expected = geometry(native), actual = geometry(written)
    #expect(actual.count == expected.count)
    let first = expected.indices.first { $0 < actual.count && expected[$0] != actual[$0] }
    #expect(first == nil, "\(first.map { "\(expected[$0]) written as \(actual[$0])" } ?? "")")
}

@Test("A mask drawn with the bytes of an earlier one takes its dimensions, as CoreGraphics gives them")
func masksTakeTheDimensionsFirstSeen() throws {
    let ledger = InkMaskLedger()
    let bits = StrokeGrainMask.Bits(width: 30, height: 16, bytesPerRow: 4, data: [UInt8](repeating: 0x5A, count: 64))
    let narrower = StrokeGrainMask.Bits(width: 26, height: 16, bytesPerRow: 4, data: bits.data)
    #expect(ledger.drawn(bits).width == 30)
    #expect(ledger.drawn(narrower).width == 30)
    let other = StrokeGrainMask.Bits(width: 26, height: 16, bytesPerRow: 4, data: [UInt8](repeating: 0x5B, count: 64))
    #expect(ledger.drawn(other).width == 26)
}

private let notebookPageSize = CGSize(width: 1404, height: 1872)

/// Random notebook pages: strokes of every tool on templates, pictures on
/// some, highlights on others — what the writer leaves to CoreGraphics and
/// what it takes. A highlighted page of every other three carries no shader,
/// whose cut pieces only CoreGraphics draws, so that its bands are written.
private func randomNotebook(seed: UInt64, pages: Int) -> (pages: [RMPage], assets: [String: Data]) {
    // The fixtures' templates, the source every test that draws one installs:
    // tests run side by side, and one that drew the bundled set would draw
    // whichever source happened to be installed when it got there.
    _ = FixtureTemplates.installed
    var marks = Marks(random: SplitMix64(seed: seed))
    let templates = [nil, "Fixture Grid", "Fixture Lines", "Fixture Dots", "Fixture Week", "Fixture Sketch Guide"]
    let notebook = (0..<pages).map { index in
        marks.page(
            strokes: 20 + marks.below(40), tools: index % 6 == 2 ? Marks.allTools.filter { $0 != .shader } : Marks.allTools,
            pictures: index % 4 == 3, text: index % 3 == 1, template: templates[index % templates.count],
            highlights: index % 3 == 2 ? 3 : 0
        )
    }
    return (notebook, ["picture.png": testPicture()])
}

/// A small opaque picture.
func testPicture() -> Data {
    let size = 16
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for index in 0..<(size * size) {
        pixels[index * 4] = UInt8(index % 256)
        pixels[index * 4 + 1] = UInt8((index * 7) % 256)
        pixels[index * 4 + 2] = 128
        pixels[index * 4 + 3] = 255
    }
    let data = NSMutableData()
    guard let context = CGContext(
        data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Test("A notebook whose ink is written apart paints every page as CoreGraphics drawing it all does")
func notebookPagesPaintAsCoreGraphicsDoes() throws {
    let notebook = randomNotebook(seed: 0xB00C, pages: 12)
    let written = try PageRenderer.pdf(pages: notebook.pages, pageSize: notebookPageSize, assets: notebook.assets)
    let native = try InkTesting.allCoreGraphics(pages: notebook.pages, pageSize: notebookPageSize, assets: notebook.assets)
    // Ink was written apart, and is not where CoreGraphics put the rest.
    #expect(try PDFFile(bytes: written).pages().count == notebook.pages.count)
    #expect(String(decoding: try InkTesting.content(of: written, page: 1), as: UTF8.self).contains("/RMIc"))
    for number in 1...notebook.pages.count {
        for scale in [1.0, 2.5] {
            #expect(try InkTesting.differingPixels(native, written, page: number, scale: scale) == 0, "page \(number) at \(scale)")
        }
    }
    // A reader that is not CoreGraphics opens it as well.
    #expect(PDFDocument(data: written)?.pageCount == notebook.pages.count)
}

@Test("Pages prepared side by side make the file pages prepared one by one make")
func preparedSideBySideIsTheSameFile() async throws {
    let notebook = randomNotebook(seed: 0xCAFE, pages: 16)
    let sequential = try PageRenderer.pdf(pages: notebook.pages, pageSize: notebookPageSize, assets: notebook.assets)
    let data = try #require(CFDataCreateMutable(nil, 0))
    let output = try PageRenderer.PDFPages(sink: PDFSink(data: data), pageSize: notebookPageSize, paper: .a4, author: nil)
    let sheets = output.sheets
    let pages = notebook.pages
    let images = PageRenderer.PageImages(bytes: notebook.assets)
    try await RenderWork.boundedConcurrentForEach(Array(pages.indices), limit: 6) { position in
        sheets.prepare(pages[position])
    } consume: { _, prepared in
        try output.draw(prepared, images: images)
    }
    try output.close()
    #expect(InkTesting.normalized(data as Data) == InkTesting.normalized(sequential))
}

/// The `.rm` of a page of random marks of every tool, typed text on some,
/// a picture on others and highlights on every other one, as the tablet
/// writes one. Every fourth page carries no shader, so that its highlights
/// are written with its ink.
private func randomMarks(_ marks: inout Marks, index: Int) throws -> Data {
    let tools: [PenTool] = [
        .paintbrush2, .mechanicalPencil2, .pencil2, .ballpoint2, .marker2, .fineliner2, .highlighter2,
        .caligraphy, .pencil1, .ballpoint1, .eraser,
    ] + (index.isMultiple(of: 4) ? [] : [.shader])
    let colors: [PenColor] = [.black, .gray, .blue, .red, .yellow, .green]
    let strokes = (0..<(15 + marks.below(25))).map { _ in
        var x = marks.uniform(-650, 500), y = marks.uniform(50, 1800)
        let points = (0..<(3 + marks.below(25))).map { _ in
            x += marks.uniform(-4, 14)
            y += marks.uniform(-12, 12)
            return RMPageDraft.Point(
                x: Float(x), y: Float(y), speed: UInt16(marks.below(200)), width: UInt16(8 + marks.below(100)),
                direction: UInt8(marks.below(256)), pressure: UInt8(marks.below(256))
            )
        }
        let tool = tools[marks.below(tools.count)]
        return RMPageDraft.Stroke(
            tool: tool, color: colors[marks.below(colors.count)],
            argb: tool == .shader ? 0x4000_00FF | UInt32(marks.below(0xFFFF)) << 8 : nil,
            thickness: Double(1 + marks.below(3)), points: points
        )
    }
    let paragraphs: [RMPageDraft.Paragraph] = index % 3 == 1
        ? [.init("Typed text the marks are written over", style: 1), .init("and more of it", style: 1)] : []
    let images: [RMPageDraft.Image] = index % 4 == 3
        ? [.init(file: "picture.png", key: (0..<16).map { UInt8($0) }, x: -200, y: 400, width: 300, height: 200)] : []
    var page = try RMWriter.page(
        RMPageDraft(
            author: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)),
            sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
            column: .init(.medium), paragraphs: paragraphs, strokes: strokes, images: images
        )
    )
    if index.isMultiple(of: 2) {
        for band in 0..<3 {
            let top = marks.uniform(100, 1600)
            let rectangles = (0..<(1 + marks.below(3))).map { line in
                HighlightRect(x: marks.uniform(-600, 100), y: top + Double(line) * 53.4, width: marks.uniform(80, 800), height: 44.9)
            }
            page.append(contentsOf: highlightBlock(
                rectangles: rectangles, color: UInt32([3, 4, 5, 9][band]), argb: band == 2 ? 0xFFFB_E84C : nil,
                item: UInt64(5000 + band)
            ))
        }
    }
    return page
}

/// Blobs out of a dictionary, by name.
private struct NamedBlobs: PageBlobs {
    let files: [String: Data]
    let folder: URL

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        guard let bytes = files[name] else { throw RenderError.malformedPage(name) }
        return bytes
    }

    func file(
        hash: String, name: String, owner: String?, size: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        let url = folder.appending(path: name.replacingOccurrences(of: "/", with: "_"))
        try files[name]?.write(to: url)
        return BlobFile(url: url, isTemporary: false)
    }
}

@Test("A redrawn document paints every page as CoreGraphics drawing all its marks does")
func redrawnPagesPaintAsCoreGraphicsDoes() async throws {
    let pages = 8
    let originalData = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: originalData as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let original = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for index in 0..<pages {
        original.beginPDFPage(nil)
        original.setFillColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        original.fill(CGRect(x: 40 + Double(index), y: 60, width: 300, height: 200))
        original.endPDFPage()
    }
    original.closePDF()
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-ink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    var marks = Marks(random: SplitMix64(seed: 0xD0C5))
    var files: [String: Data] = ["doc.pdf": originalData as Data, "doc/p0/picture.png": testPicture()]
    var records: [String] = []
    for index in 0..<pages {
        files["doc/p\(index).rm"] = try randomMarks(&marks, index: index)
        records.append(#"{"id": "p\#(index)", "redir": {"timestamp": "1:2", "value": \#(index)}}"#)
    }
    files["doc.content"] = Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
    let index = DocumentFiles(files: files.map { DocumentFile(hash: $0.key, name: $0.key, size: Int64($0.value.count)) })
    let output = folder.appending(path: "redrawn.pdf")
    try await AnnotatedPDFRenderer(blobs: NamedBlobs(files: files, folder: folder)).renderPDF(
        documentID: "doc", index: index, to: output, allowOverlay: false
    )
    let written = try Data(contentsOf: output)

    // The same pages as develop drew them: every mark by CoreGraphics.
    let document = try #require(CGDataProvider(data: originalData as CFData).flatMap(CGPDFDocument.init))
    let reference = NSMutableData()
    let referenceConsumer = try #require(CGDataConsumer(data: reference as CFMutableData))
    let context = try #require(CGContext(consumer: referenceConsumer, mediaBox: &box, nil))
    let images = PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    var writtenHighlights = 0
    for page in 0..<pages {
        let parsed = try RMParser.parsePage(try #require(files["doc/p\(page).rm"]))
        let units = AnnotationGeometry.units(of: CGSize(width: 612, height: 792))
        let geometry = parsed.text.map { TextGeometry($0, pageSize: units) }
        if PageRenderer.writtenInk(of: parsed, pageSize: units, geometry: geometry, place: { _ in }).highlights {
            writtenHighlights += 1
        }
        AnnotatedPDFRenderer.drawPage(
            source: document.page(at: page + 1), marks: parsed, sheet: CGSize(width: 612, height: 792), into: context,
            images: images
        )
    }
    context.closePDF()
    let native = reference as Data
    #expect(String(decoding: try InkTesting.content(of: written, page: 1), as: UTF8.self).contains("/RMIc"))
    // Highlights among them, written with the ink of the pages that let them.
    #expect(writtenHighlights >= 2)
    for page in 1...pages {
        #expect(try InkTesting.differingPixels(native, written, page: page, scale: 1.5) == 0, "page \(page)")
    }
}

@Test("An overlay's native pages paint as CoreGraphics drawing all their marks does")
func overlayNativePagesPaintAsCoreGraphicsDoes() throws {
    let pages = 6
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-ink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appending(path: "original.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(original as CFURL, mediaBox: &box, nil))
    for index in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        context.fill(CGRect(x: 40 + Double(index), y: 60, width: 300, height: 200))
        context.endPDFPage()
    }
    context.closePDF()

    var marks = Marks(random: SplitMix64(seed: 0x0E41))
    let images = PageRenderer.PageImages(bytes: ["picture.png": testPicture()])
    let sheet = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
    var written: [PDFOverlayWriter.Overlay] = [], native: [PDFOverlayWriter.Overlay] = []
    for index in 0..<pages {
        // Typed text on every page, so that every overlay is a native one.
        let page = marks.page(strokes: 30, pictures: index.isMultiple(of: 2), text: true)
        for writesInk in [true, false] {
            let overlay = try InkTesting.nativeOverlay(page, index: index, sheet: sheet, images: images, writesInk: writesInk)
            if writesInk { written.append(overlay) } else { native.append(overlay) }
        }
    }
    let writtenURL = folder.appending(path: "written.pdf"), nativeURL = folder.appending(path: "native.pdf")
    try PDFOverlayWriter().write(original: original, overlays: written, to: writtenURL)
    try PDFOverlayWriter().write(original: original, overlays: native, to: nativeURL)
    let writtenPDF = try Data(contentsOf: writtenURL), nativePDF = try Data(contentsOf: nativeURL)
    #expect(String(decoding: writtenPDF, as: UTF8.self).contains("/RMIc"))
    for page in 1...pages {
        #expect(try InkTesting.differingPixels(nativePDF, writtenPDF, page: page, scale: 1.5) == 0, "page \(page)")
    }
}

/// Where the process `inkIsTheSameInEveryProcess` starts writes its PDF.
private let inkOutputKey = "RMRENDER_TEST_INK_OUTPUT"

/// Whether this process was started by `swift test`, whose runner can be
/// started again with a filter of its own.
private let inkRunnerCanBeRestarted = CommandLine.arguments.first?.hasSuffix("swiftpm-testing-helper") == true
    && CommandLine.arguments.contains("--test-bundle-path")

private func writeCrossProcessInk(to output: URL) throws {
    let notebook = randomNotebook(seed: 0xD15C, pages: 14)
    try PageRenderer.pdf(pages: notebook.pages, pageSize: notebookPageSize, assets: notebook.assets, to: output)
}

@Test(
    "The other half of the test below: writes the notebook where the process that started it says",
    .enabled(if: ProcessInfo.processInfo.environment[inkOutputKey] != nil)
)
func writeInkForAnotherProcess() throws {
    try writeCrossProcessInk(to: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[inkOutputKey])))
}

@Test(
    "Written ink is the same bytes whichever process writes it, and whatever its hash seed",
    .enabled(if: inkRunnerCanBeRestarted)
)
func inkIsTheSameInEveryProcess() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-ink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let here = folder.appending(path: "here.pdf")
    try writeCrossProcessInk(to: here)

    // The runner started again, asked for the test above alone: twice with
    // a hash seed of its own each time, once with the fixed one.
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
        arguments.removeSubrange(filter...(filter + 1))
    }
    arguments += ["--filter", "writeInkForAnotherProcess"]
    // A run under a sanitizer carries its runtime beside the test bundle, and
    // a process started from here has to be handed it again.
    var sanitizers: [String] = []
    if let bundle = arguments.firstIndex(of: "--test-bundle-path").map({ arguments[$0 + 1] }) {
        let frameworks = URL(fileURLWithPath: bundle).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        sanitizers = names.filter { $0.hasPrefix("libclang_rt.") && $0.hasSuffix("_osx_dynamic.dylib") }
            .sorted().map { frameworks.appending(path: $0).path }
    }
    var written: [Data] = []
    for (run, deterministic) in [false, false, true].enumerated() {
        let output = folder.appending(path: "process\(run).pdf")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" }
        environment[inkOutputKey] = output.path
        if !sanitizers.isEmpty { environment["DYLD_INSERT_LIBRARIES"] = sanitizers.joined(separator: ":") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.environment = environment
        let log = folder.appending(path: "process\(run).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        try logHandle.close()
        try #require(
            process.terminationStatus == 0,
            "run \(run): \(String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self).suffix(2000))"
        )
        written.append(try Data(contentsOf: output))
    }

    // CoreGraphics dates its documents and names them afresh; the rest is
    // the same file.
    let expected = InkTesting.normalized(try Data(contentsOf: here))
    #expect(String(decoding: expected, as: UTF8.self).contains("/RMIc"))
    for (run, bytes) in written.enumerated() {
        #expect(InkTesting.normalized(bytes) == expected, "run \(run)")
    }
}
