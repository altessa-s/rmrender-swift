// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
@testable import RMRender
import Testing

// Pens, tapers, the two point formats, and the eraser as ink.

@Test("A stroke of changing width is drawn as a contour, at the width the file gives")
func outlineFollowsTheWidth() throws {
    // A straight line along x, thin at the start and thick at the end: 8 → 40
    // raw, which is 2 → 10 units.
    let tapering = Stroke(
        tool: .ballpoint2,
        color: .black,
        thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 8, pressure: 1),
            StrokePoint(x: 100, y: 0, width: 40, pressure: 1),
        ]
    )
    #expect(tapering.hasVaryingWidth)

    let elements = StrokeOutline.elements(of: tapering)
    // The band, then a round cap at each end.
    let band = elements.prefix(5)
    let corners: [CGPoint] = band.compactMap {
        switch $0 {
        case .move(let point), .line(let point): point
        default: nil
        }
    }
    #expect(corners.count == 4)
    // Both corners at the thin end are one unit off the line, and both at the
    // thick end are five. Half of 2 and half of 10.
    let atStart = corners.filter { abs($0.x) < 0.01 }.map { abs(Double($0.y)) }.sorted()
    let atEnd = corners.filter { abs($0.x - 100) < 0.01 }.map { abs(Double($0.y)) }.sorted()
    #expect(atStart == [1, 1])
    #expect(atEnd == [5, 5])
}

// The tablet samples faster than a hand moves, so a stroke arrives with runs of
// points on one line at one width. A band each draws the same shape out of five
// times the operators, and on a page of an imported PDF those operators are
// written into the document.
@Test("Points that lie on one line share a band, and a bend does not")
func outlineJoinsWhatLiesStraight() {
    func bands(_ points: [StrokePoint]) -> Int {
        StrokeOutline.elements(of: Stroke(
            tool: .pencil2,
            color: .black,
            thicknessScale: 1,
            points: points
        )).count { element in
            if case .close = element { return true } else { return false }
        }
    }

    // Twenty points on one line at a width that grows evenly: one band, and
    // the two round ends.
    let straight = (0...20).map { step in
        StrokePoint(x: Float(step) * 10, y: 0, width: 16 + Float(step), pressure: 1)
    }
    #expect(bands(straight) == 3, "one band and the two round ends")

    // The same points with one pushed well off the line: it cannot be stood
    // in for, so the run breaks around it.
    var bent = straight
    bent[10] = StrokePoint(x: 100, y: 40, width: bent[10].width, pressure: 1)
    #expect(bands(bent) > bands(straight))
}

@Test("Two tools are stroked and the rest are filled, as on the tablet")
func onlyTwoToolsAreStroked() {
    func steady(_ tool: PenTool?) -> Stroke {
        Stroke(
            tool: tool,
            color: .black,
            thicknessScale: 1,
            points: [
                StrokePoint(x: 0, y: 0, width: 8, pressure: 1),
                StrokePoint(x: 50, y: 50, width: 8, pressure: 1),
            ]
        )
    }

    #expect(steady(.fineliner2).isStroked)
    #expect(steady(.highlighter2).isStroked)
    #expect(steady(.fineliner2).lineWidth == 2)
    // A width that stands still is not what decides it: the mechanical pencil's
    // is just as constant and the tablet fills it — two stroked operators
    // against 247 fills in an export of a page carrying all nine tools.
    #expect(!steady(.mechanicalPencil2).hasVaryingWidth)
    #expect(!steady(.mechanicalPencil2).isStroked)
    #expect(!steady(.pencil2).isStroked)
    // An unknown tool has only its widths to go by, and a stroked line is
    // cheaper for a width that does not change.
    #expect(steady(nil).isStroked)
}

// The tablet lays down less ink than a solid band of the file's width — 0.56 of
// it for the brush, 0.64 for the pencil — and thinning the opacity by exactly
// that much made the weight right and the picture wrong: the tablet's grain is
// black spots with white gaps, so the darkest pixel of its pencil is 0, while a
// thinned band never got past 92. A stroke is drawn solid; grain is undone work
// rather than approximated work.
@Test("A stroke is drawn at the weight its colour says, not thinned for grain")
func grainIsNotApproximatedByOpacity() {
    func stroke(_ tool: PenTool, argb: UInt32? = nil) -> Stroke {
        Stroke(
            tool: tool,
            color: .black,
            thicknessScale: 1,
            points: [StrokePoint(x: 0, y: 0, width: 8, pressure: 1)],
            argb: argb
        )
    }

    #expect(stroke(.pencil2).alpha == 1, "a pencil is black where it touches the page")
    #expect(stroke(.paintbrush2).alpha == 1)
    #expect(stroke(.marker2).alpha == 1)
    // What the file states is still honoured: the shader's own quarter.
    #expect(abs(stroke(.shader, argb: 0x4021_1E1C).alpha - 0.251) < 0.005)
    #expect(stroke(.highlighter2).alpha == 1)
}

// The opacity is in the file wherever the file carries a colour of its own: the
// alpha byte of `argb`. A live shader stroke carries
// `0x40211e1c`, and `0x40` is 0.251, exactly the `ca` of the graphics state the
// tablet's own export gives that very stroke.
@Test("The opacity comes from the file when the file states it")
func alphaComesFromTheFile() {
    func stroke(tool: PenTool, argb: UInt32?) -> Stroke {
        Stroke(
            tool: tool,
            color: .highlight,
            thicknessScale: 1,
            points: [StrokePoint(x: 0, y: 0, width: 8, pressure: 1)],
            argb: argb
        )
    }

    #expect(abs(stroke(tool: .shader, argb: 0x4021_1E1C).alpha - 0x40 / 255.0) < 0.001)
    // With no colour of its own the tool's blend answers, which is one number
    // for every stroke of that tool.
    #expect(stroke(tool: .shader, argb: nil).alpha == StrokeBlend.darkenFaint.alpha)
    #expect(stroke(tool: .fineliner2, argb: nil).alpha == 1)
    // A tool with no calibration entry gets what its own file says rather than what
    // its family's entry carries.
    #expect(abs(stroke(tool: .ballpoint2, argb: 0x8000_0000).alpha - 128 / 255.0) < 0.001)
    // Nought means "nothing said" and not "invisible": this very field arrives
    // as an opaque black on a yellow highlight over the text of a PDF.
    #expect(stroke(tool: .fineliner2, argb: 0x00FF_8800).alpha == 1)
}

@Test("The taper reaches the paper")
func taperIsVisible() throws {
    // The first ballpoint: its ink is solid, so the ink measures the shape —
    // the second one's streaks would thin the edge rows by chance.
    func page(from: UInt16, to: UInt16) -> RMPage {
        RMPage(
            strokes: [
                Stroke(
                    tool: .ballpoint1,
                    color: .black,
                    thicknessScale: 1,
                    points: (0...20).map { step in
                        StrokePoint(
                            x: Float(step) * 40,
                            y: 900,
                            width: Float(from) + Float(to - from) * Float(step) / 20,
                            pressure: 1
                        )
                    }
                )
            ],
            skippedBlocks: 0
        )
    }
    // 8 → 88 raw is 2 → 22 units. Its average is 12, which is what a single
    // averaged width would draw from end to end — and a stroke of the same
    // area is not the same stroke.
    let tapering = try PageRenderer.pdf(pages: [page(from: 8, to: 88)])
    let averaged = try PageRenderer.pdf(pages: [page(from: 48, to: 48)])
    let thick = try PageRenderer.pdf(pages: [page(from: 88, to: 88)])

    #expect(try raster(tapering).dark != (try raster(averaged).dark))
    // The line is horizontal, so its ink is as tall as it is thick. The thick
    // end is as thick as the file says — 22 units, not the 12 of the average.
    #expect(try inkHeight(in: tapering) > (try inkHeight(in: averaged)))
    #expect(abs((try inkHeight(in: tapering)) - (try inkHeight(in: thick))) <= 1)
    // And the thin end really is thin: a stroke thick all the way puts down
    // half again as much ink.
    #expect(try ink(in: tapering) < (try ink(in: thick)))
}

@Test("The eraser is not drawn")
func eraserIsNotDrawn() throws {
    let eraser = try RMParser.parsePage(makePage(tool: UInt32(PenTool.eraser.rawValue)))
    let stroke = try #require(eraser.strokes.first)

    #expect(stroke.tool?.isEraser == true)
    // The stroke parses, but it must not appear on the page: a PDF with an
    // erased stroke has to weigh less than one with a drawn stroke.
    let withEraser = try PageRenderer.pdf(pages: [eraser])
    let withInk = try PageRenderer.pdf(pages: [try RMParser.parsePage(makePage())])
    #expect(withEraser.count < withInk.count)
}

/// How much ink a page leaves on a bitmap of its own — for the questions a
/// PDF cannot answer directly, like whether something was taken off.
private func inkWeight(of page: RMPage, pageSize: CGSize = CGSize(width: 400, height: 400)) throws -> Double {
    let width = Int(pageSize.width), height = Int(pageSize.height)
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: pageSize))
    PageRenderer.draw(
        page, in: context, pageSize: pageSize, bounds: CGRect(origin: .zero, size: pageSize)
    )
    let image = try #require(context.makeImage())
    let data = try #require(image.dataProvider?.data as Data?)
    var ink = 0.0
    for pixel in stride(from: 0, to: data.count, by: 4) {
        ink += Double(255 - data[pixel])
    }
    return ink / (255 * Double(width * height))
}

/// A stroke straight across the page at a stated depth.
private func band(
    tool: PenTool, from: Float, to: Float, at depth: Float, width: Float = 40
) -> Stroke {
    Stroke(
        tool: tool,
        color: .black,
        thicknessScale: 2,
        points: stride(from: from, through: to, by: 4).map {
            StrokePoint(x: $0, y: depth, width: width, pressure: 200)
        }
    )
}

@Test("The eraser takes ink off, and only what was drawn before it")
func theEraserErases() throws {
    // On a Move export of `Fixture 13`: the page whose black band is
    // crossed by an eraser comes back with the ink under the eraser gone,
    // while the page with the area eraser comes back whole.
    let ink = band(tool: .fineliner2, from: -160, to: 160, at: 100)
    let rubber = band(tool: .eraser, from: -160, to: -40, at: 100, width: 60)
    let area = band(tool: .eraserArea, from: -160, to: -40, at: 100, width: 60)

    let plain = try inkWeight(of: RMPage(strokes: [ink], skippedBlocks: 0))
    let erased = try inkWeight(of: RMPage(strokes: [ink, rubber], skippedBlocks: 0))
    let byArea = try inkWeight(of: RMPage(strokes: [ink, area], skippedBlocks: 0))
    // Drawn after the eraser rather than before it: nothing has happened to it.
    let after = try inkWeight(of: RMPage(strokes: [rubber, ink], skippedBlocks: 0))

    #expect(plain > 0.01, "the control page drew nothing")
    #expect(erased < plain * 0.65, "the eraser took nothing off: \(erased) of \(plain)")
    #expect(erased > plain * 0.35, "the eraser took off more than it covers: \(erased)")
    #expect(abs(byArea - plain) < plain * 0.02, "the area eraser took ink off")
    #expect(abs(after - plain) < plain * 0.02, "an eraser erased a stroke drawn after it")
}
// MARK: - Curves, and the two point formats

/// Samples of a quadratic Bézier, with the width, the speed and the pressure
/// moving along it the way a hand moves them: the pen bears down through the
/// middle of a sweep and lifts at both ends.
///
/// The tablet writes no curve — it samples the pen fast enough that the
/// polyline is the curve — so a fixture of a curved stroke is a fixture of its
/// samples. The widths are kept multiples of four so that point format one,
/// which stores a quarter of the width as a float32, round-trips exactly.
private func bezierSamples(
    from start: (x: Double, y: Double),
    control: (x: Double, y: Double),
    to end: (x: Double, y: Double),
    count: Int
) -> [StrokeSample] {
    (0..<count).map { step in
        let t = Double(step) / Double(count - 1)
        let rest = 1 - t
        let swell = sin(Double.pi * t)
        return StrokeSample(
            x: Float(rest * rest * start.x + 2 * rest * t * control.x + t * t * end.x),
            y: Float(rest * rest * start.y + 2 * rest * t * control.y + t * t * end.y),
            width: UInt16(8 + 4 * (6 * swell).rounded()),
            // Fast where the hand is not pressing, slow at the top of the arc.
            speed: UInt16(40 + (160 * (1 - swell)).rounded()),
            direction: UInt8((255 * t).rounded()),
            pressure: UInt8(60 + (150 * swell).rounded())
        )
    }
}

/// The same widths along a straight line: whatever the band-joining makes of
/// a changing width it makes of both, so a difference in the count of bands is
/// the bend and nothing else.
private func straightened(_ curve: [StrokeSample]) -> [StrokeSample] {
    curve.enumerated().map { index, sample in
        var straight = sample
        straight.x = Float(index) * 10
        straight.y = 0
        return straight
    }
}

/// The arc every test below is built on: a sweep of 21 samples, about 200
/// units across and 80 deep — a stroke that could not be told from a line by
/// its endpoints alone.
private let sweep = bezierSamples(
    from: (x: 0, y: 0), control: (x: 100, y: -160), to: (x: 200, y: 0), count: 21
)

// The simplest stroke fixture is two points on a straight line at one
// width. That is the one shape the drawing has nothing to do with:
// no bend to break a band, no taper to draw, and two samples cannot show a
// field being read off the wrong offset — with a stride wrong by a field the
// second point simply falls off the end.
@Test("A curved stroke keeps every sample's place, width and pressure")
func parsesACurvedStroke() throws {
    let page = try RMParser.parsePage(
        makePage(tool: UInt32(PenTool.ballpoint2.rawValue), points: sweep)
    )
    let stroke = try #require(page.strokes.first)

    #expect(stroke.points.count == sweep.count)
    for (read, written) in zip(stroke.points, sweep) {
        #expect(read.x == written.x)
        #expect(read.y == written.y)
        #expect(read.width == Float(written.width))
        #expect(read.pressure == Float(written.pressure))
    }

    // The fixture really is a curve: the middle of it stands far off the chord
    // between its ends, so nothing here can pass by treating it as a line.
    let first = try #require(stroke.points.first)
    let last = try #require(stroke.points.last)
    let span = Double(last.x - first.x)
    let sag = stroke.points.map { point -> Double in
        let along = Double(point.x - first.x) / span
        return abs(Double(point.y - first.y) - along * Double(last.y - first.y))
    }.max()
    #expect(try #require(sag) > 50, "the fixture has to bend for these tests to say anything")

    // And it really tapers: widest in the middle, thin at both ends.
    #expect(stroke.hasVaryingWidth)
    let widest = try #require(stroke.points.map(\.width).max())
    #expect(widest > first.width)
    #expect(widest > last.width)
    #expect(first.width == last.width, "the sweep is symmetrical")
}

// A run of samples on one line is drawn as a single band, and that shortcut is
// worth a test only against something that must not take it. The straight
// fixtures could never fail this: they have no bend to break the run.
@Test("A bend costs bands, and a straight run of the same widths does not")
func aCurveIsNotCollapsedIntoOneBand() throws {
    func closures(_ samples: [StrokeSample]) throws -> Int {
        let page = try RMParser.parsePage(
            makePage(tool: UInt32(PenTool.ballpoint2.rawValue), points: samples)
        )
        return StrokeOutline.elements(of: try #require(page.strokes.first)).count { element in
            if case .close = element { return true } else { return false }
        }
    }

    let curved = try closures(sweep)
    let straight = try closures(straightened(sweep))
    #expect(curved > straight, "\(curved) bands against \(straight)")
    // The straight one is not free either: the width swells and falls back,
    // which no single interpolated band stands in for.
    #expect(straight > 2, "a band and its two round ends at the very least")
}

// Version one of the point format spells all six fields as float32 — the width
// in quarters, the pressure as a fraction of 255 — and version two packs them
// into uint16 and bytes. The other fixtures in this file are version two, so
// without this test the older branch of `parsePoint` would have nothing
// reading it at all: a field swapped there would go unnoticed.
@Test("The same curve reads the same through either point format")
func bothPointFormatsReadTheSameCurve() throws {
    func parse(_ version: UInt8) throws -> Stroke {
        let page = try RMParser.parsePage(
            makePage(tool: UInt32(PenTool.ballpoint2.rawValue), points: sweep, pointVersion: version)
        )
        return try #require(page.strokes.first)
    }

    let two = try parse(2)
    let one = try parse(1)

    #expect(one.points.count == two.points.count)
    for (old, new) in zip(one.points, two.points) {
        #expect(old.x == new.x)
        #expect(old.y == new.y)
        #expect(old.width == new.width, "version one carries a quarter of the width")
        #expect(abs(old.pressure - new.pressure) < 0.01, "and the pressure as a fraction")
    }
    // The two really are different bytes: 0x18 a point against 0x0E.
    let older = makePage(points: sweep, pointVersion: 1)
    let newer = makePage(points: sweep, pointVersion: 2)
    #expect(older.count - newer.count == sweep.count * (0x18 - 0x0E))

    // A version we have never seen loses the stroke and not the page: the
    // stride would be a guess, and a guessed stride draws nonsense.
    let unknown = try RMParser.parsePage(makePage(points: sweep, pointVersion: 3))
    #expect(unknown.strokes.isEmpty)
}

// Two bands of a wide stroke meeting at a gentle turn: cut square to their
// own directions they leave a wedge open on the outer side, from the rim to
// the middle — a white sliver on every bend of a shader band. The join fills
// it, and reaches no further than the rim.
@Test("A gentle turn leaves no wedge open on the outer side of a wide band")
func gentleTurnIsJoined() throws {
    // Three points 60 units apart, turning by six degrees, 44 units wide.
    let turn = 6 * Double.pi / 180
    let stroke = Stroke(
        tool: .shader,
        color: .black,
        thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 176, pressure: 1),
            StrokePoint(x: 60, y: 0, width: 176, pressure: 1),
            StrokePoint(x: 60 + Float(60 * cos(turn)), y: Float(60 * sin(turn)), width: 176, pressure: 1),
        ]
    )
    let path = CGMutablePath()
    for element in StrokeOutline.elements(of: stroke) {
        switch element {
        case .move(let point): path.move(to: point)
        case .line(let point): path.addLine(to: point)
        case .curve(let control1, let control2, let to):
            path.addCurve(to: to, control1: control1, control2: control2)
        case .close: path.closeSubpath()
        }
    }
    // The outer side of the turn is below the joint (y grows downward on the
    // page and the stroke turns up). A point a unit inside the rim on the
    // bisector, and points either side of it along the rim, are all ink.
    for x in stride(from: 58.0, through: 62.0, by: 1) {
        #expect(path.contains(CGPoint(x: x, y: -20.5), using: .winding), "x \(x)")
    }
    // And the join does not reach past the rim.
    #expect(!path.contains(CGPoint(x: 60, y: -23), using: .winding))
}

// A wide stroke sampled closely round a tight hook: the bands between the
// samples are a few units long and overlap heavily on the inside of the
// turn. Wound alike, they add up rather than cancel: every point of the
// centre line, and the whole of the band's middle, is ink.
@Test("A tight hook of a wide stroke has no holes")
func tightHookHasNoHoles() throws {
    var points: [StrokePoint] = []
    for step in 0...40 {
        let angle = Double(step) / 40 * Double.pi * 1.5
        points.append(StrokePoint(x: Float(15 * cos(angle)), y: Float(15 * sin(angle)), width: 160, pressure: 1))
    }
    let path = CGMutablePath()
    for element in StrokeOutline.elements(of: Stroke(tool: .shader, color: .black, thicknessScale: 1, points: points)) {
        switch element {
        case .move(let point): path.move(to: point)
        case .line(let point): path.addLine(to: point)
        case .curve(let control1, let control2, let to):
            path.addCurve(to: to, control1: control1, control2: control2)
        case .close: path.closeSubpath()
        }
    }
    for point in points {
        for (dx, dy) in [(0.0, 0.0), (8.0, 0.0), (-8.0, 0.0), (0.0, 8.0), (0.0, -8.0)] {
            let probe = CGPoint(x: Double(point.x) + dx, y: Double(point.y) + dy)
            #expect(path.contains(probe, using: .winding), "\(probe)")
        }
    }
}

// Shader strokes crossing. Two strokes that merely cross deepen where they
// meet, as in the tablet's own export (an SVG of a live page: `opacity 0.4`
// alone, `0.57` where two meet). The pieces an eraser left of one stroke share
// a `sourceId` and are drawn as one — no deeper where they meet.
private func shaderBand(from: Float, to: Float, source: SceneItemID?) -> Stroke {
    Stroke(
        tool: .shader, color: .highlight, thicknessScale: 1,
        points: stride(from: from, through: to, by: 20).map { StrokePoint(x: $0, y: 500, width: 176, pressure: 1) },
        argb: 0x4021_1E1C,
        sourceId: source
    )
}

private func greys(of page: RMPage, at xs: [Int]) throws -> [UInt8] {
    let image = try PageRenderer.image(page: page, grayscale: true)
    let width = image.width
    var pixels = [UInt8](repeating: 0, count: width * image.height)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
    let middle = Int(PageRenderer.defaultPageSize.width) / 2
    return xs.map { pixels[500 * width + middle + $0] }
}

@Test("Two shader strokes that merely cross deepen where they meet")
func crossingShaderStrokesDeepen() throws {
    let page = RMPage(strokes: [shaderBand(from: -300, to: 100, source: nil),
                                shaderBand(from: -100, to: 300, source: nil)], skippedBlocks: 0)
    let grey = try greys(of: page, at: [-200, 0])
    #expect(grey[0] < 250, "the band is drawn at all: \(grey[0])")
    #expect(Int(grey[0]) - Int(grey[1]) > 5, "alone \(grey[0]), crossing \(grey[1])")
}

@Test("The pieces of one erased shader stroke are no darker where they meet")
func piecesOfOneShaderStrokeShareALayer() throws {
    let source = SceneItemID(author: 1, counter: 17)
    let page = RMPage(strokes: [shaderBand(from: -300, to: 100, source: source),
                                shaderBand(from: -100, to: 300, source: source)], skippedBlocks: 0)
    let grey = try greys(of: page, at: [-200, 0])
    #expect(abs(Int(grey[1]) - Int(grey[0])) <= 1, "alone \(grey[0]), crossing \(grey[1])")
}

@Test("A shader layer is keyed by source and closes at anything else")
func shaderLayerKeys() {
    let source = SceneItemID(author: 1, counter: 17)
    #expect(PageRenderer.sharedLayerKey(of: shaderBand(from: 0, to: 40, source: source)) == source)
    #expect(PageRenderer.sharedLayerKey(of: shaderBand(from: 0, to: 40, source: nil)) == nil)
    let pen = Stroke(tool: .fineliner2, color: .black, thicknessScale: 1,
                     points: [StrokePoint(x: 0, y: 0, width: 4, pressure: 1), StrokePoint(x: 10, y: 0, width: 4, pressure: 1)],
                     sourceId: source)
    #expect(PageRenderer.sharedLayerKey(of: pen) == nil)
}

@Test("An eraser that touches only the mitred corner of a highlighter still erases it")
func eraserReachesAMitredCorner() throws {
    // A first highlighter, drawn black, turning by 110° at (40, 250): its
    // mitre reaches about 1.74 half widths out, to x ≈ 68.6 — further along
    // x than half the width past the corner, which is all a disc reaches.
    let turn = 110 * Double.pi / 180
    let marker = Stroke(
        tool: .highlighter1, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: -100, y: 250, width: 160, pressure: 255),
            StrokePoint(x: 40, y: 250, width: 160, pressure: 255),
            StrokePoint(x: 40 + Float(100 * cos(turn)), y: 250 + Float(100 * sin(turn)), width: 160, pressure: 255),
        ],
        argb: 0xFF00_0000
    )
    #expect(marker.tool?.lineJoin == .miter)
    // An eraser inside that mitre and nowhere else: its own ends reach 62,
    // past the 61 a disc-sized box stops at.
    let rubber = Stroke(
        tool: .eraser, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: 64, y: 233, width: 16, pressure: 255),
            StrokePoint(x: 65, y: 233, width: 16, pressure: 255),
        ]
    )
    let plain = try inkWeight(of: RMPage(strokes: [marker], skippedBlocks: 0))
    let erased = try inkWeight(of: RMPage(strokes: [marker, rubber], skippedBlocks: 0))
    #expect(erased < plain, "the corner was left whole: \(erased) of \(plain)")
}

@Test("A sharp turn is rounded on its outer side, and the join cuts no hole")
func sharpTurnIsRounded() {
    // A right angle at (100, 0), half width 10: a quarter disc on the outer
    // side.
    let stroke = Stroke(
        tool: .paintbrush1, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 80, pressure: 255),
            StrokePoint(x: 100, y: 0, width: 80, pressure: 255),
            StrokePoint(x: 100, y: 100, width: 80, pressure: 255),
        ]
    )
    let path = CGMutablePath()
    for element in StrokeOutline.elements(of: stroke) {
        switch element {
        case let .move(point): path.move(to: point)
        case let .line(point): path.addLine(to: point)
        case let .curve(one, two, to): path.addCurve(to: to, control1: one, control2: two)
        case .close: path.closeSubpath()
        }
    }
    // The outer corner of the turn, inside the join's reach.
    #expect(path.contains(CGPoint(x: 105, y: -5), using: .winding))
    // Past the join's reach at the corner: paper.
    #expect(!path.contains(CGPoint(x: 109, y: -9), using: .winding))
    // The bands themselves, and the turn's inside, are whole.
    #expect(path.contains(CGPoint(x: 50, y: 0), using: .winding))
    #expect(path.contains(CGPoint(x: 100, y: 50), using: .winding))
    #expect(path.contains(CGPoint(x: 95, y: 5), using: .winding))
}

@Test("A point repeated at a new width before a turn still gets the turn's join")
func repeatedPointKeepsTheJoin() {
    let stroke = Stroke(
        tool: .paintbrush1, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 80, pressure: 255),
            StrokePoint(x: 100, y: 0, width: 80, pressure: 255),
            StrokePoint(x: 100, y: 0, width: 160, pressure: 255),
            StrokePoint(x: 100, y: 100, width: 160, pressure: 255),
        ]
    )
    let path = CGMutablePath()
    for element in StrokeOutline.elements(of: stroke) {
        switch element {
        case let .move(point): path.move(to: point)
        case let .line(point): path.addLine(to: point)
        case let .curve(one, two, to): path.addCurve(to: to, control1: one, control2: two)
        case .close: path.closeSubpath()
        }
    }
    // The outer corner of the turn at (100, 0), half width 20 there: inside
    // the join, outside both bands.
    #expect(path.contains(CGPoint(x: 112, y: -12), using: .winding))
}

@Test("Erasing one end of a stroked line leaves its far corner as it was drawn")
func erasingKeepsTheCorners() throws {
    // A fineliner with a right-angled corner; an eraser at its far end.
    let line = Stroke(
        tool: .fineliner2, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: -120, y: 100, width: 64, pressure: 255),
            StrokePoint(x: 0, y: 100, width: 64, pressure: 255),
            StrokePoint(x: 0, y: 300, width: 64, pressure: 255),
        ]
    )
    let rubber = Stroke(
        tool: .eraser, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: -2, y: 290, width: 40, pressure: 255),
            StrokePoint(x: 2, y: 296, width: 40, pressure: 255),
        ]
    )
    let size = CGSize(width: 400, height: 400)
    func dark(_ page: RMPage) throws -> [Bool] {
        let image = try PageRenderer.image(page: page, pageSize: size, inkOnly: true)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<(width * height)).map { bytes[$0 * 4] < 128 }
    }
    let plain = try dark(RMPage(strokes: [line], skippedBlocks: 0))
    let erased = try dark(RMPage(strokes: [line, rubber], skippedBlocks: 0))
    // The corner's neighbourhood: (0, 100) on the page is (200, 100) on a
    // sheet 400 wide.
    var differ = 0, ink = 0
    for y in 80...120 {
        for x in 180...220 {
            if plain[y * 400 + x] { ink += 1 }
            if plain[y * 400 + x] != erased[y * 400 + x] { differ += 1 }
        }
    }
    #expect(ink > 100, "the corner is not where the test looks: \(ink) inked")
    #expect(differ == 0, "\(differ) pixels of the corner changed")
}

// MARK: - Properties of the outline

/// Every corner of a stroke's outline, its curves' end points included.
private func corners(of stroke: Stroke) -> [CGPoint] {
    StrokeOutline.elements(of: stroke).compactMap { element in
        switch element {
        case let .move(point), let .line(point): point
        case let .curve(_, _, to): to
        case .close: nil
        }
    }
}

@Test("A round cap stays on its circle and in front of its end")
func roundCapStaysInBounds() throws {
    for radius in [0.3, 1, 2.5, 6, 12, 44, 300] {
        for heading in stride(from: 0.0, to: 2 * Double.pi, by: 0.7) {
            let outward = CGVector(dx: cos(heading), dy: sin(heading))
            let centre = CGPoint(x: 10, y: -5)
            let cap = try #require(StrokeEnd.roundCap(centre: centre, radius: radius, outward: outward))
            #expect(cap.count >= 3)
            for corner in cap {
                let dx = Double(corner.x - centre.x), dy = Double(corner.y - centre.y)
                #expect(abs((dx * dx + dy * dy).squareRoot() - radius) < 1e-9 * max(radius, 1))
                // Never behind the end: the band covers that side.
                #expect(dx * Double(outward.dx) + dy * Double(outward.dy) > -1e-9 * max(radius, 1))
            }
            // And no chord falls further inside the circle than the tolerance.
            for (a, b) in zip(cap, cap.dropFirst()) {
                let mx = Double(a.x + b.x) / 2 - Double(centre.x), my = Double(a.y + b.y) / 2 - Double(centre.y)
                let sag = radius - (mx * mx + my * my).squareRoot()
                #expect(sag <= max(StrokeEnd.chordTolerance, radius) + 1e-9)
                if radius > StrokeEnd.chordTolerance * 4 { #expect(sag <= StrokeEnd.chordTolerance + 1e-9) }
            }
        }
    }
    #expect(StrokeEnd.roundCap(centre: .zero, radius: 0, outward: CGVector(dx: 1, dy: 0)) == nil)
    #expect(StrokeEnd.roundCap(centre: .zero, radius: .nan, outward: CGVector(dx: 1, dy: 0)) == nil)
}

@Test("No join spikes past the miter limit, and a round join past the rim")
func joinsHaveNoSpikes() {
    // A zigzag whose turns run from barely there to a hairpin.
    var points: [StrokePoint] = [StrokePoint(x: 0, y: 0, width: 80, pressure: 255)]
    var heading = 0.0, x = 0.0, y = 0.0
    for (index, turn) in [5.0, 30, 60, 90, 119, 121, 150, 175, 179.5].enumerated() {
        x += 120 * cos(heading)
        y += 120 * sin(heading)
        points.append(StrokePoint(x: Float(x), y: Float(y), width: 80, pressure: 255))
        heading += (index.isMultiple(of: 2) ? 1 : -1) * turn * Double.pi / 180
    }
    x += 120 * cos(heading)
    y += 120 * sin(heading)
    points.append(StrokePoint(x: Float(x), y: Float(y), width: 80, pressure: 255))
    let half = 10.0

    func farthest(_ tool: PenTool) -> Double {
        // The distance from each corner of the outline to the nearest point
        // of the centre line, the largest of them.
        corners(of: Stroke(tool: tool, color: .black, thicknessScale: 1, points: points)).map { corner in
            zip(points, points.dropFirst()).map { a, b in
                let ax = Double(a.x), ay = Double(a.y)
                let ex = Double(b.x) - ax, ey = Double(b.y) - ay
                let cx = Double(corner.x) - ax, cy = Double(corner.y) - ay
                let tau = min(max((cx * ex + cy * ey) / (ex * ex + ey * ey), 0), 1)
                let qx = cx - ex * tau, qy = cy - ey * tau
                return (qx * qx + qy * qy).squareRoot()
            }.min() ?? 0
        }.max() ?? 0
    }
    // Round: nothing past the rim.
    #expect(farthest(.paintbrush1) <= half + 1e-6)
    // Mitred: nothing past the limit; and the limit is reached at all, or
    // the test proves nothing about mitres.
    let mitred = farthest(.highlighter1)
    #expect(mitred <= half * PenTool.lineMiterLimit + 1e-6, "\(mitred)")
    #expect(mitred > half * 1.5, "\(mitred)")
}

@Test("Every tool that draws lays an outline around its points")
func everyToolHasAnOutline() {
    let points = (0...20).map { step in
        StrokePoint(x: Float(step) * 10, y: Float(step % 3) * 4, width: 24 + Float(step), pressure: Float(step) * 12)
    }
    for tool in PenTool.allCases where !tool.isEraser {
        let stroke = Stroke(tool: tool, color: .black, thicknessScale: 1, points: points).drawn
        let outline = corners(of: stroke)
        if tool.grain == .bristle, stroke.points.allSatisfy({ $0.width == 0 }) { continue }
        #expect(!outline.isEmpty, "\(tool)")
        // Ends: round, except the flat chisel of the highlighters.
        #expect(stroke.end == (tool.isHighlighter ? .butt : .round), "\(tool)")
    }
}

@Test("The highlighter and the shader are translucent over what lies beneath")
func highlighterIsTranslucent() throws {
    // Black text under a band: still black where the band crosses it.
    let text = Stroke(tool: .fineliner2, color: .black, thicknessScale: 1, points: [
        StrokePoint(x: -100, y: 200, width: 16, pressure: 255), StrokePoint(x: 100, y: 200, width: 16, pressure: 255),
    ])
    for (tool, argb) in [(PenTool.highlighter2, UInt32?.none), (.highlighter1, nil), (.shader, 0x4021_1E1C)] {
        let band = Stroke(tool: tool, color: .yellow, thicknessScale: 1, points: [
            StrokePoint(x: 0, y: 150, width: 120, pressure: 255), StrokePoint(x: 0, y: 250, width: 120, pressure: 255),
        ], argb: argb)
        #expect(band.blend.darkens, "\(tool)")
        let over = try inkWeight(of: RMPage(strokes: [text, band], skippedBlocks: 0))
        let bandAlone = try inkWeight(of: RMPage(strokes: [band], skippedBlocks: 0))
        let textAlone = try inkWeight(of: RMPage(strokes: [text], skippedBlocks: 0))
        // Nothing of the text is lost under the band.
        #expect(over >= max(bandAlone, textAlone) - 1e-9, "\(tool)")
    }
}

@Test("The brush's drawn width grows with pressure")
func brushWidthGrowsWithPressure() {
    var previous = -1.0
    for pressure in stride(from: Float(0), through: 255, by: 5) {
        let stroke = Stroke(tool: .paintbrush2, color: .black, thicknessScale: 1, points: [
            StrokePoint(x: 0, y: 0, width: 64, pressure: pressure), StrokePoint(x: 10, y: 0, width: 64, pressure: pressure),
        ]).drawn
        let width = Double(stroke.points[0].width)
        #expect(width >= previous)
        previous = width
    }
    #expect(previous > 0)
}

@Test("A highlighter tap that never moved still leaves its footprint")
func highlighterTapIsVisible() throws {
    let still = StrokePoint(x: 0, y: 200, width: 120, pressure: 255)
    let tap = Stroke(tool: .highlighter2, color: .black, thicknessScale: 1, points: [still, still], argb: 0xFF00_0000)
    #expect(tap.end == .square)
    #expect(try inkWeight(of: RMPage(strokes: [tap], skippedBlocks: 0)) > 0.004)
}
