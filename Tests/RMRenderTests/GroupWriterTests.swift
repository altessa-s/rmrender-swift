// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import RMLines
import Testing

// The transparency layers of the ink — the pieces an eraser left of one
// shader stroke — written as groups in CoreGraphics' place
// (`InkStream.beginGroup`), against the layers CoreGraphics itself makes.

/// A mark of a page and the layer it is drawn in, `0` for none: a change
/// of layer closes the one open and opens the next, as `PageRenderer.draw`
/// does.
private struct Member {
    let layer: Int
    let paint: PageRenderer.StrokePaint
}

/// The alpha and the blend of each layer.
private struct Layer {
    let alpha: Double
    let darkens: Bool
}

/// A one-page PDF of `members` under `transform` on a page of `box`: drawn
/// by CoreGraphics, layers and all — or, `written`, written apart and
/// appended, CoreGraphics drawing nothing but the page. `crop` gives the
/// page a crop box as well.
private func groupPage(
    _ members: [Member], layers: [Int: Layer], transform: CGAffineTransform, box: CGRect, crop: CGRect? = nil,
    written: Bool
) throws -> Data {
    let data = try #require(CFDataCreateMutable(nil, 0))
    let sink = PDFSink(data: data)
    var media = box
    let consumer = try #require(sink.consumer())
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    let update = InkUpdate()
    var info: [String: Any] = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
    if var crop {
        info[kCGPDFContextCropBox as String] = Data(bytes: &crop, count: MemoryLayout<CGRect>.size)
    }
    context.beginPDFPage(info as CFDictionary)
    if !written {
        context.saveGState()
        context.concatenate(transform)
        var open = 0
        for member in members {
            if member.layer != open {
                if open != 0 {
                    context.endTransparencyLayer()
                    context.restoreGState()
                }
                if let layer = layers[member.layer] {
                    context.saveGState()
                    context.setBlendMode(layer.darkens ? .darken : .normal)
                    context.setAlpha(layer.alpha)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                open = member.layer
            }
            member.paint.draw(in: context)
        }
        if open != 0 {
            context.endTransparencyLayer()
            context.restoreGState()
        }
        context.restoreGState()
    }
    context.endPDFPage()
    if written {
        let placed = try #require(PageRenderer.contextTransform { $0.concatenate(transform) })
        let stream = try #require(InkStream(transform: placed, box: box))
        var open = 0
        for member in members {
            if member.layer != open {
                if open != 0 { stream.endGroup() }
                if let layer = layers[member.layer] { stream.beginGroup(alpha: layer.alpha, darkens: layer.darkens) }
                open = member.layer
            }
            member.paint.write(into: stream)
        }
        if open != 0 { stream.endGroup() }
        try update.append(try #require(PreparedInk(stream)), page: 0)
    }
    context.closePDF()
    try update.finish(into: sink)
    try sink.close()
    return data as Data
}

private func paint(
    _ shape: PageRenderer.StrokePaint.Shape, _ rgb: (Double, Double, Double), alpha: Double = 1, darkens: Bool = false,
    layer: Int = 0
) -> Member {
    Member(
        layer: layer,
        paint: PageRenderer.StrokePaint(
            shape: shape, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha, darkens: darkens, inSharedLayer: layer != 0
        )
    )
}

/// Layers of every kind of member — lines of each join, grain masks, erased
/// fills and an erased mask — over ink they blend with; one interrupted and
/// taken up again under the same key, two side by side, one off the page,
/// one partly off it, one erased away; translucent ink, then a layer of its
/// alpha and blend, then opaque ink, which must not take the layer's alpha.
/// `alpha` and `darkens` are the first layers'.
private func groupedMarks(alpha: Double, darkens: Bool) -> (members: [Member], layers: [Int: Layer]) {
    func path(_ points: [(Double, Double)], closed: Bool = true) -> CGMutablePath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        if closed { path.closeSubpath() }
        return path
    }
    let under = path([(-500, 200), (400, 200), (400, 900), (-500, 900)])
    let swipe: [CGPoint] = [(-600, 300.25), (-300, 260), (0, 420), (350.5, 330), (200, 520)].map { CGPoint(x: $0.0, y: $0.1) }
    let corner: [CGPoint] = [(-400, 700), (-100, 600), (-380, 560)].map { CGPoint(x: $0.0, y: $0.1) }
    let box = CGMutablePath()
    box.move(to: CGPoint(x: -100, y: 750))
    box.addCurve(to: CGPoint(x: 250, y: 760), control1: CGPoint(x: 50, y: 640), control2: CGPoint(x: 150, y: 900))
    box.addLine(to: CGPoint(x: 250, y: 980))
    box.addLine(to: CGPoint(x: -100, y: 980))
    box.closeSubpath()
    let cut = path([(-50, 280), (60, 280), (60, 1000), (-50, 1000)])
    let ellipse = CGPath(ellipseIn: CGRect(x: -300, y: 450, width: 500, height: 260), transform: nil)
    let bits = StrokeGrainMask.Bits(
        width: 40, height: 16, bytesPerRow: 5, data: (0..<80).map { UInt8(truncatingIfNeeded: $0 * 53 + 7) }
    )
    let grain = CGRect(x: -120, y: 700, width: 400, height: 300)

    var members: [Member] = [
        paint(.fill(under), (0.2, 0.5, 0.8)),
        paint(.line(points: swipe, width: 3, cap: .round, join: .round), (0.1, 0.1, 0.1)),
        // Layer 1: lines of each join, a mask and erased members.
        paint(.line(points: swipe, width: 40, cap: .round, join: .round), (0.95, 0.85, 0.1), layer: 1),
        paint(.line(points: corner, width: 18, cap: .butt, join: .miter), (0.9, 0.3, 0.2), layer: 1),
        paint(.line(points: corner, width: 6, cap: .square, join: .bevel), (0.3, 0.9, 0.2), layer: 1),
        paint(.mask(clip: box, bits: bits, rectangle: grain), (0.5, 0.1, 0.6), layer: 1),
        paint(.mask(clip: box.subtracting(cut), bits: bits, rectangle: grain), (0.1, 0.6, 0.6), layer: 1),
        paint(.fill(ellipse.subtracting(cut)), (0.9, 0.5, 0.1), layer: 1),
        // Ink between, then the same key again: a layer of its own.
        paint(.line(points: corner, width: 2, cap: .butt, join: .miter), (0, 0, 0), alpha: 0.5),
        paint(.fill(box), (0.2, 0.8, 0.4), layer: 1),
        // Layers 2 and 3 one after the other, members overlapping inside.
        paint(.fill(under), (0.8, 0.2, 0.2), layer: 2),
        paint(.fill(box), (0.2, 0.2, 0.8), layer: 2),
        paint(.line(points: swipe, width: 60, cap: .round, join: .round), (0.7, 0.7, 0.1), layer: 3),
        // Translucent ink, a layer of its alpha and blend, opaque ink.
        paint(.fill(box), (0.6, 0.3, 0.1), alpha: 0.3, darkens: true),
        paint(.fill(under), (0.6, 0.3, 0.1), layer: 7),
        paint(.mask(clip: box, bits: bits, rectangle: grain), (0.3, 0.3, 0.3)),
        paint(.line(points: corner, width: 5, cap: .round, join: .round), (0.3, 0.3, 0.3)),
        paint(.fill(ellipse), (0.1, 0.4, 0.3)),
    ]
    // Off the page, partly off it, erased away.
    let away = [CGPoint(x: -6000, y: 300), CGPoint(x: -5500, y: 320)]
    let edge = [CGPoint(x: 500, y: 1700), CGPoint(x: 900, y: 2100)]
    members.append(paint(.line(points: away, width: 60, cap: .round, join: .round), (0.7, 0.7, 0.1), layer: 4))
    members.append(paint(.line(points: edge, width: 60, cap: .round, join: .round), (0.7, 0.7, 0.1), layer: 5))
    members.append(paint(.fill(path([(0, 290), (10, 290), (10, 295)]).subtracting(cut)), (0.7, 0.7, 0.1), layer: 6))
    var layers: [Int: Layer] = [:]
    for key in [1, 2, 3, 4, 5, 6] { layers[key] = Layer(alpha: alpha, darkens: darkens) }
    layers[7] = Layer(alpha: 0.3, darkens: true)
    return (members, layers)
}

/// The tablet's page placed as the notebook places it, on a box whose
/// origin is not the page's.
private let tabletTransform = CGAffineTransform(translationX: 306, y: -8.5).scaledBy(x: 0.4358974358974359, y: 0.4358974358974359)

private func count(_ needle: String, in pdf: Data) -> Int {
    String(decoding: pdf, as: UTF8.self).components(separatedBy: needle).count - 1
}

@Test(
    "Written layers paint what CoreGraphics' transparency layers paint, for each blend and a range of alphas",
    arguments: [false, true], [0, 0.25, 0.6, 1]
)
func layersPaintAsCoreGraphicsLayers(darkens: Bool, alpha: Double) throws {
    let marks = groupedMarks(alpha: alpha, darkens: darkens)
    for box in [CGRect(x: 0, y: 0, width: 612, height: 816), CGRect(x: -40, y: -25.5, width: 652, height: 860)] {
        let native = try groupPage(marks.members, layers: marks.layers, transform: tabletTransform, box: box, written: false)
        let written = try groupPage(marks.members, layers: marks.layers, transform: tabletTransform, box: box, written: true)
        // Written, not drawn: no Form of CoreGraphics', and as many groups
        // as it wrote layers — none for those off the page or erased away.
        #expect(count("/Fm", in: written) == 0)
        #expect(count("/S /Transparency", in: native) == count("/S /Transparency", in: written))
        #expect(count("/S /Transparency", in: written) == 6)
        for scale in [1, 2.5, 6.25] {
            let differing = try InkTesting.differingPixels(native, written, page: 1, scale: scale)
            #expect(differing == 0, "box \(box) scale \(scale)")
        }
    }
}

@Test("A layer is clipped to the media box, not the crop box")
func layersClipToTheMediaBox() throws {
    let marks = groupedMarks(alpha: 0.4, darkens: true)
    let box = CGRect(x: 0, y: 0, width: 612, height: 816), crop = CGRect(x: 100, y: 120, width: 300, height: 400)
    let native = try groupPage(
        marks.members, layers: marks.layers, transform: tabletTransform, box: box, crop: crop, written: false
    )
    let written = try groupPage(
        marks.members, layers: marks.layers, transform: tabletTransform, box: box, crop: crop, written: true
    )
    for scale in [1, 2.5] {
        #expect(try InkTesting.differingPixels(native, written, page: 1, scale: scale) == 0, "scale \(scale)")
    }
}

@Test("A layer's alpha ends with it: opaque ink after a translucent layer is opaque", arguments: [false, true])
func layerAlphaEndsWithTheLayer(translucentBefore: Bool) throws {
    let left = CGPath(rect: CGRect(x: -600, y: 100, width: 400, height: 400), transform: nil)
    let right = CGPath(rect: CGRect(x: 100, y: 100, width: 400, height: 400), transform: nil)
    let members = [
        paint(.fill(left), (0.6, 0.3, 0.1), alpha: translucentBefore ? 0.3 : 1, darkens: translucentBefore),
        paint(.fill(left), (0.6, 0.3, 0.1), layer: 1),
        paint(.fill(right), (0.1, 0.1, 0.1)),
    ]
    let layers = [1: Layer(alpha: 0.3, darkens: true)]
    let box = CGRect(x: 0, y: 0, width: 612, height: 816)
    let written = try groupPage(members, layers: layers, transform: tabletTransform, box: box, written: true)
    let native = try groupPage(members, layers: layers, transform: tabletTransform, box: box, written: false)
    // The group painted inside `q`/`Q`, its alpha and blend ending there.
    let content = String(decoding: try InkTesting.content(of: written, page: 1), as: UTF8.self)
    let painted = try #require(content.range(of: "/RMIf0 Do\nQ\n"))
    let opened = try #require(content.range(of: "q\n", options: .backwards, range: content.startIndex..<painted.lowerBound))
    let between = content[opened.upperBound..<painted.lowerBound]
    #expect(between.allSatisfy { !"cfSmlre".contains($0) }, "\(between)")
    if !translucentBefore { #expect(between.contains("gs")) }
    // The opaque square, well inside it: as dark as drawn, not at 0.3.
    let raster = try InkTesting.raster(written, page: 1, scale: 1)
    let x = Int((300 * tabletTransform.a + tabletTransform.tx).rounded())
    let y = raster.height - Int((300 * tabletTransform.d + tabletTransform.ty).rounded())
    let index = (y * raster.width + x) * 4
    #expect(raster.pixels[index] < 40, "\(raster.pixels[index])")
    #expect(try InkTesting.differingPixels(native, written, page: 1, scale: 2) == 0)
}

@Test("A group blends in the profile CoreGraphics' layers blend in: Generic RGB, byte for byte")
func groupsBlendInCoreGraphicsProfile() throws {
    let marks = groupedMarks(alpha: 0.5, darkens: true)
    let box = CGRect(x: 0, y: 0, width: 612, height: 816)
    let native = try groupPage(marks.members, layers: marks.layers, transform: tabletTransform, box: box, written: false)
    let written = try groupPage(marks.members, layers: marks.layers, transform: tabletTransform, box: box, written: true)
    func profiles(_ pdf: Data) throws -> Set<Data> {
        let file = try PDFFile(bytes: pdf)
        var found: Set<Data> = []
        for number in file.offsets.keys {
            guard case .stream(let dictionary, _) = try file.object(number),
                  let group = try file.resolve(dictionary["Group"]).dictionaryValue,
                  let space = try file.resolve(group["CS"]).arrayValue, space.count == 2,
                  case .stream(let profile, let bytes) = try file.resolve(space[1])
            else { continue }
            found.insert(try file.decode(profile, bytes))
        }
        return found
    }
    let expected = try #require(PreparedInk.groupProfile)
    #expect(try profiles(native) == [expected])
    #expect(try profiles(written) == [expected])
    // Not the profile the colours are in.
    #expect(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? != expected)
}

// MARK: - Boxes

/// A random path about `(x, y)`: lines and curves, closed where asked.
private func randomPath(_ marks: inout Marks, x: Double, y: Double, spread: Double, closed: Bool) -> CGMutablePath {
    let path = CGMutablePath()
    var current = CGPoint(x: x + marks.uniform(-spread, spread) / 2, y: y + marks.uniform(-spread, spread) / 2)
    path.move(to: current)
    for _ in 0...marks.below(4) {
        let next = CGPoint(x: current.x + marks.uniform(-spread, spread) / 2, y: current.y + marks.uniform(-spread, spread) / 2)
        if marks.below(2) == 0 {
            path.addLine(to: next)
        } else {
            path.addCurve(
                to: next,
                control1: CGPoint(x: current.x + marks.uniform(-spread, spread), y: current.y + marks.uniform(-spread, spread)),
                control2: CGPoint(x: next.x + marks.uniform(-spread, spread), y: next.y + marks.uniform(-spread, spread))
            )
        }
        current = next
    }
    if closed { path.closeSubpath() }
    return path
}

/// The points of `path`, in order: a polyline through them.
private func points(of path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = []
    path.applyWithBlock { element in
        let count = switch element.pointee.type {
        case .moveToPoint, .addLineToPoint: 1
        case .addQuadCurveToPoint: 2
        case .addCurveToPoint: 3
        default: 0
        }
        for index in 0..<count { points.append(element.pointee.points[index]) }
    }
    return points
}

/// The numbers of the first `/BBox` of `pdf`, as printed; empty where it
/// has none.
private func firstBox(_ pdf: Data) -> [String] {
    let text = String(decoding: pdf, as: UTF8.self)
    guard let start = text.range(of: "/BBox ["), let end = text.range(of: "]", range: start.upperBound..<text.endIndex)
    else { return [] }
    return text[start.upperBound..<end.lowerBound].split(separator: " ").map(String.init)
}

@Test("A group's box is printed as CoreGraphics prints its layer's, for random layers of every kind of member")
func groupBoxesAreCoreGraphics() throws {
    var marks = Marks(random: SplitMix64(seed: 0x6B0C5))
    let scales = [0.4358974358974359, 1, 0.75, 2.5, 0.3333333333333333]
    let bits = StrokeGrainMask.Bits(
        width: 64, height: 8, bytesPerRow: 8, data: (0..<64).map { _ in UInt8(truncatingIfNeeded: marks.random.next()) }
    )
    var compared = 0, missing = 0
    for round in 0..<300 {
        let scale = scales[round % scales.count]
        let box = CGRect(x: 0, y: 0, width: 1404 * scale, height: 1872 * scale)
        let transform = CGAffineTransform(translationX: 702 * scale, y: 0).scaledBy(x: scale, y: scale)
        let x = marks.uniform(-400, 400), y = marks.uniform(300, 1500)
        let spread = marks.below(5) == 0 ? 2000 : marks.uniform(30, 500)
        var members: [(draw: (CGContext) -> Void, write: (InkStream) -> Void)] = []
        for _ in 0...marks.below(4) {
            let kind = marks.below(5)
            let rgb = (marks.uniform(0, 1), marks.uniform(0, 1), marks.uniform(0, 1))
            let stroked = kind == 0
            let outline = randomPath(&marks, x: x, y: y, spread: spread, closed: !stroked)
            let shape: CGPath = kind >= 3
                ? outline.subtracting(randomPath(&marks, x: x, y: y, spread: spread, closed: true)) : outline
            if stroked {
                let width = marks.uniform(0.5, 40), limit = marks.below(2) == 0 ? 10 : marks.uniform(1, 6)
                let cap = [CGLineCap.butt, .round, .square][marks.below(3)]
                let join = [CGLineJoin.miter, .round, .bevel][marks.below(3)]
                let line = points(of: outline)
                members.append((
                    draw: { context in
                        context.saveGState()
                        context.setStrokeColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
                        context.setLineWidth(width)
                        context.setLineCap(cap)
                        context.setLineJoin(join)
                        context.setMiterLimit(limit)
                        context.addLines(between: line)
                        context.strokePath()
                        context.restoreGState()
                    },
                    write: { stream in
                        stream.stroke(
                            line, width: width, cap: cap, join: join, miterLimit: limit, red: rgb.0, green: rgb.1,
                            blue: rgb.2, alpha: 1, darkens: false
                        )
                    }
                ))
            } else {
                let rectangle = CGRect(
                    x: x + marks.uniform(-spread, spread) * 0.6, y: y + marks.uniform(-spread, spread) * 0.6,
                    width: marks.uniform(10, spread), height: marks.uniform(10, spread)
                )
                let member = PageRenderer.StrokePaint(
                    shape: kind == 2 || kind == 4 ? .mask(clip: shape, bits: bits, rectangle: rectangle) : .fill(shape),
                    red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1, darkens: false, inSharedLayer: true
                )
                members.append((draw: { member.draw(in: $0) }, write: { member.write(into: $0) }))
            }
        }

        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var media = box
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.concatenate(transform)
        context.saveGState()
        context.setBlendMode(.darken)
        context.setAlpha(0.5)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for member in members { member.draw(context) }
        context.endTransparencyLayer()
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        let placed = try #require(PageRenderer.contextTransform { $0.concatenate(transform) })
        let stream = try #require(InkStream(transform: placed, box: box))
        stream.beginGroup(alpha: 0.5, darkens: true)
        for member in members { member.write(stream) }
        stream.endGroup()
        let expected = firstBox(data as Data)
        let written = stream.finish()?.groups.first?.box ?? []
        #expect(written == expected, "round \(round): CoreGraphics \(expected), written \(written)")
        if expected.isEmpty { missing += 1 } else { compared += 1 }
    }
    // Both kinds came up: layers that reach the page, and some that miss it.
    #expect(compared > 200)
    #expect(missing > 0)
}
