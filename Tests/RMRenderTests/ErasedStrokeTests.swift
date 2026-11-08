// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import RMLines
import Testing

// A stroke an eraser took away whole paints nothing — on a bitmap, in a
// notebook's PDF, in a redraw and in an overlay, whether CoreGraphics draws
// its ink or the writer writes it. The pencils were the ones that did not:
// what the eraser left of the contour is the clip of the grain, and a clip of
// nothing is no clip in CoreGraphics, so the whole rectangle of the grain came
// out where the stroke had been rubbed out.

private let canvas = CGSize(width: 1404, height: 1872)
private let sheet = CGSize(width: 612, height: 792)
/// The PDFs are compared a pixel to a point: a mask's texel is still a
/// pixel or more, and there are some hundreds of pages to draw.
private let rasterScale = 1.0

/// The grained tools: the ones painted through a mask under a clip.
private let grained = PenTool.allCases.filter { !$0.isEraser && $0.grain != .solid }

/// A band across the page at `depth`, `from` and `to` in `.rm` units.
private func band(_ tool: PenTool, from: Float = -200, to: Float = 200, at depth: Float = 600, width: Float = 30) -> Stroke {
    Stroke(
        tool: tool, color: .black, thicknessScale: 2,
        points: stride(from: from, through: to, by: 4).map { StrokePoint(x: $0, y: depth, width: width, pressure: 200) }
    )
}

/// An eraser over `band` from `from` to `to`, far wider than the band.
private func eraser(from: Float = -320, to: Float = 320, at depth: Float = 600) -> Stroke {
    band(.eraser, from: from, to: to, at: depth, width: 400)
}

/// What stays on every page: a line the erasers never reach, so that the
/// pages compared have the same bounds and something on them.
private let witness = band(.fineliner2, from: -600, to: 600, at: 1500, width: 10)

private func page(_ strokes: [Stroke]) -> RMPage { RMPage(strokes: strokes, skippedBlocks: 0) }

/// A bitmap's pixels as sRGB bytes, however `PageRenderer` laid them out.
private func pixels(_ image: CGImage) throws -> [UInt8] {
    let width = image.width, height = image.height
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    return Array(UnsafeBufferPointer(start: buffer, count: width * height * 4))
}

/// How many pixels of a raster are not white. Through buffers rather than
/// slices: the rasters are large, and a debug build is slow at slices.
private func inked(_ pixels: [UInt8]) -> Int {
    pixels.withUnsafeBufferPointer { p in
        stride(from: 0, to: p.count, by: 4).count { p[$0] & p[$0 + 1] & p[$0 + 2] != 255 }
    }
}

/// How many pixels differ between two rasters of one size; -1 where the
/// sizes differ.
private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return -1 }
    return a.withUnsafeBytes { first in
        b.withUnsafeBytes { second in
            zip(first.bindMemory(to: UInt32.self), second.bindMemory(to: UInt32.self)).count { $0 != $1 }
        }
    }
}

/// The ways a page is painted, each as the pixels of the one page it makes:
/// a bitmap; then, written apart and drawn all by CoreGraphics, one after
/// the other, a notebook's PDF, a redraw over nothing and an overlay's
/// native form.
private func renders(of marks: RMPage) throws -> [(name: String, pixels: [UInt8])] {
    let bitmap = try pixels(PageRenderer.image(page: marks, pageSize: canvas))
    let notebook = try PageRenderer.pdf(pages: [marks], pageSize: canvas)
    let allCoreGraphics = try InkTesting.allCoreGraphics(pages: [marks], pageSize: canvas)
    var out = [
        ("bitmap", bitmap),
        ("notebook written", try InkTesting.raster(notebook, page: 1, scale: rasterScale).pixels),
        ("notebook by CoreGraphics", try InkTesting.raster(allCoreGraphics, page: 1, scale: rasterScale).pixels),
    ]
    for writesInk in [true, false] {
        let redrawn = try redraw(marks, writesInk: writesInk)
        out.append(("redraw \(writesInk ? "written" : "by CoreGraphics")", try InkTesting.raster(redrawn, page: 1, scale: rasterScale).pixels))
    }
    for writesInk in [true, false] {
        let form = try overlay(marks, writesInk: writesInk)
        out.append(("overlay \(writesInk ? "written" : "by CoreGraphics")", try InkTesting.raster(form, page: 1, scale: rasterScale).pixels))
    }
    return out
}

/// A page of marks redrawn on a sheet of its own, as `AnnotatedPDFRenderer`
/// redraws one: its ink written apart and appended, or all of it drawn by
/// CoreGraphics.
private func redraw(_ marks: RMPage, writesInk: Bool) throws -> Data {
    let data = try #require(CFDataCreateMutable(nil, 0))
    let sink = PDFSink(data: data)
    var box = CGRect(origin: .zero, size: sheet)
    let consumer = try #require(sink.consumer())
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let update = InkUpdate()
    let units = AnnotationGeometry.units(of: sheet)
    let written = writesInk
        ? PageRenderer.writtenInk(of: marks, pageSize: units, geometry: nil) {
            $0.scaleBy(x: Calibration.pointsPerUnit, y: Calibration.pointsPerUnit)
        }
        : (split: marks.strokes.count, highlights: false, ink: nil)
    AnnotatedPDFRenderer.drawPage(
        source: nil, marks: marks, sheet: sheet, into: context, inkSplit: written.split,
        writtenHighlights: written.highlights, masks: writesInk ? update.masks : nil
    )
    context.closePDF()
    if let ink = written.ink { try update.append(ink, page: 0) }
    try update.finish(into: sink)
    try sink.close()
    return data as Data
}

/// A page of marks as an overlay writes it natively, onto a blank page.
private func overlay(_ marks: RMPage, writesInk: Bool) throws -> Data {
    let drawing = CGRect(origin: .zero, size: sheet)
    return try InkTesting.overlaid([InkTesting.nativeOverlay(marks, sheet: drawing, writesInk: writesInk)], sheet: drawing)
}

@Test("A stroke an eraser took away whole paints nothing, whichever way the page is painted")
func whollyErasedStrokePaintsNothing() throws {
    let without = try renders(of: page([witness, eraser()]))
    for tool in PenTool.allCases where !tool.isEraser {
        for (index, render) in try renders(of: page([witness, band(tool), eraser()])).enumerated() {
            #expect(inked(render.pixels) > 0, "\(tool), \(render.name): the witness is not on the page")
            #expect(differing(render.pixels, without[index].pixels) == 0, "\(tool), \(render.name)")
        }
    }
}

@Test("A pencil an eraser took away whole paints nothing on a page of its own")
func whollyErasedPencilAlonePaintsNothing() throws {
    for tool in grained {
        for render in try renders(of: page([band(tool), eraser()])) {
            #expect(inked(render.pixels) == 0, "\(tool), \(render.name)")
        }
    }
}

@Test("Two erasers that take a pencil away between them leave nothing of it")
func pencilErasedByTwoErasersPaintsNothing() throws {
    let without = try renders(of: page([witness]))
    for tool in grained {
        let halves = page([witness, band(tool), eraser(from: -320, to: 10), eraser(from: -10, to: 320)])
        for (index, render) in try renders(of: halves).enumerated() {
            #expect(differing(render.pixels, without[index].pixels) == 0, "\(tool), \(render.name)")
        }
    }
}

@Test("A pencil an eraser took part of still paints the rest, written as CoreGraphics draws it")
func partlyErasedPencilPaintsTheRest() throws {
    for tool in grained {
        let whole = try renders(of: page([band(tool)]))
        let partly = try renders(of: page([band(tool), eraser(from: -320, to: 0)]))
        for (index, render) in partly.enumerated() {
            let left = inked(render.pixels), all = inked(whole[index].pixels)
            #expect(left > all / 4, "\(tool), \(render.name): \(left) of \(all) left")
            #expect(left < all * 3 / 4, "\(tool), \(render.name): \(left) of \(all) left")
        }
        // The written ink is CoreGraphics' own, to the pixel, in each of the
        // three that write it.
        for (written, native) in [(1, 2), (3, 4), (5, 6)] {
            #expect(differing(partly[written].pixels, partly[native].pixels) == 0, "\(tool), \(partly[written].name)")
        }
    }
}

@Test("A pencil drawn after the eraser is left alone")
func pencilAfterTheEraserIsDrawn() throws {
    for tool in grained {
        let before = try renders(of: page([band(tool)]))
        for (index, render) in try renders(of: page([eraser(), band(tool)])).enumerated() {
            #expect(differing(render.pixels, before[index].pixels) == 0, "\(tool), \(render.name)")
        }
    }
}

/// A one-page PDF of `paints` under a page's transform: drawn by
/// CoreGraphics, or written apart and appended.
private func paintedPage(_ paints: [PageRenderer.StrokePaint], written: Bool) throws -> Data {
    let data = try #require(CFDataCreateMutable(nil, 0))
    let sink = PDFSink(data: data)
    var box = CGRect(origin: .zero, size: CGSize(width: 200, height: 200))
    let consumer = try #require(sink.consumer())
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    let transform = CGAffineTransform(translationX: 1.5, y: -2.25).scaledBy(x: 0.75, y: 0.75)
    let update = InkUpdate()
    context.beginPDFPage(nil)
    context.saveGState()
    context.concatenate(transform)
    if !written { for paint in paints { paint.draw(in: context) } }
    context.restoreGState()
    context.endPDFPage()
    if written {
        let placed = try #require(PageRenderer.contextTransform { $0.concatenate(transform) })
        let stream = try #require(InkStream(transform: placed))
        for paint in paints { paint.write(into: stream) }
        try update.append(try #require(PreparedInk(stream)), page: 0)
    }
    context.closePDF()
    try update.finish(into: sink)
    try sink.close()
    return data as Data
}

@Test("A grain mask paints nothing under a clip of nothing, or of no area, drawn or written")
func maskUnderAnEmptyClipPaintsNothing() throws {
    func mask(_ clip: CGPath, fill: UInt8) -> PageRenderer.StrokePaint {
        let bits = StrokeGrainMask.Bits(width: 16, height: 16, bytesPerRow: 2, data: [UInt8](repeating: fill, count: 32))
        return PageRenderer.StrokePaint(
            shape: .mask(clip: clip, bits: bits, rectangle: CGRect(x: 10, y: 10, width: 180, height: 180)),
            red: 0.2, green: 0.1, blue: 0.6, alpha: 1, darkens: false, inSharedLayer: false
        )
    }
    // No elements: what an eraser leaves of a contour it took away whole.
    let nothing = CGMutablePath()
    // Elements, but no area: these clip everything away, and always did.
    let moveOnly = CGMutablePath()
    moveOnly.move(to: CGPoint(x: 50, y: 50))
    let flat = CGMutablePath()
    flat.addLines(between: [CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 100), CGPoint(x: 20, y: 100)])
    flat.closeSubpath()
    // And a clip of some area, so that there is something to see.
    let square = CGPath(rect: CGRect(x: 60, y: 60, width: 40, height: 40), transform: nil)

    let erased = [mask(nothing, fill: 0x00), mask(moveOnly, fill: 0x11), mask(flat, fill: 0x22), mask(square, fill: 0x33)]
    let kept = [mask(square, fill: 0x33)]
    let reference = try InkTesting.raster(try paintedPage(kept, written: false), page: 1, scale: 2).pixels
    #expect(inked(reference) > 0)
    for written in [false, true] {
        let drawn = try InkTesting.raster(try paintedPage(erased, written: written), page: 1, scale: 2).pixels
        #expect(differing(drawn, reference) == 0, written ? "written" : "by CoreGraphics")
    }

    // Nor is the mask of nothing put into the file.
    let stream = try #require(InkStream(transform: .identity))
    mask(nothing, fill: 0).write(into: stream)
    #expect(stream.isEmpty, "a mask of nothing was written, or named")
}
