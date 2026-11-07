// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation

/// A page's ink written as PDF operators in CoreGraphics' place.
///
/// CoreGraphics prints every coordinate of a page through `vsnprintf` and
/// deflates the page on the thread that draws it, and both are most of what
/// exporting a written notebook costs; the printing also takes the C
/// library's global locale lock, so pages drawn side by side wait on one
/// another. Ink — the fills, lines and pencil grain of `PageRenderer.drawStroke`
/// — is simple enough to write ourselves, so it is written here, on whichever
/// task prepares the page, and CoreGraphics keeps the rest: templates, text,
/// pictures, layers.
///
/// What CoreGraphics does with the same calls, operator for operator, so
/// that the page paints what it would have painted, to the pixel:
///
/// - Paths are kept in device space: a point is `fma(a, x, c·y) + tx`,
///   `fma(b, x, d·y) + ty`. Fills and clips print those device coordinates.
/// - A line prints `q <transform> cm`, then each device point mapped back
///   through `CGAffineTransform.inverted()`, so a coordinate can come back
///   one rounding away from the one drawn; then `S Q`.
/// - A quadratic segment (an erased outline has them) becomes the cubic
///   CoreGraphics derives from the device points.
/// - A grain mask is drawn under its path clip at the perceptual intent,
///   its image matrix the rectangle concatenated onto the transform with
///   the translation fused: `fma(a, x, tx)`.
/// - Colours are in sRGB through an ICC-based space; the alpha goes to `/ca`
///   for a fill and `/CA` for a line, the blend mode to `/BM`.
/// - Every number goes through `QuartzNumber`, CoreGraphics' own printing:
///   a coordinate or a colour as it prints those, an alpha as it prints that
///   into a graphics state — to four places.
///
/// Graphics state is set where it changes, as CoreGraphics sets it; only its
/// order and the `q`/`Q` nesting differ, and neither changes what is painted.
/// Every arithmetic step above is held against CoreGraphics' own output in
/// the tests, and only the transforms a page is drawn under — a scale and a
/// translation — are taken: `init` declines any other.
///
/// Not `Sendable`: one task writes one page. What it made leaves as `Ink`,
/// deflated as it is written (`StreamingFlate`).
final class InkStream {
    /// A grain mask the content paints through: its bits — one a pixel,
    /// rows padded to a byte — deflated, and the dimensions it was drawn
    /// with. Deflated where it is drawn, so that a page of pencil holds its
    /// masks at the size they go into the file rather than their own.
    ///
    /// The digest is the bits' alone, because that is how CoreGraphics keys
    /// an image: two masks of one page or one document with the same bytes
    /// are one image, drawn with the dimensions the first was drawn with
    /// (`InkUpdate`).
    struct Mask: Sendable {
        let digest: SHA256.Digest
        let width: Int
        let height: Int
        /// The deflated bits, in pieces (`StreamingFlate`).
        let deflated: [Data]
    }

    /// What a page's ink comes to: its operators, deflated, and the
    /// resources they name, by index — `/RMIg<i>` is `states[i]`,
    /// `/RMIx<i>` is `masks[i]`, `/RMIc` the sRGB colour space when
    /// `usesColorSpace`.
    struct Ink: Sendable {
        /// Deflated, in pieces (`StreamingFlate`).
        let content: [Data]
        /// The entries of each graphics state, `/ca 0.5` and the like.
        let states: [String]
        let masks: [Mask]
        let usesColorSpace: Bool
    }

    /// The prefixes of the names the content gives its resources. CoreGraphics
    /// names its own `/Cs1`, `/Gs1`, `/Im1`, `/Fm1`, `/TT1`; these cannot meet
    /// them on a page the two share.
    static let colorSpaceName = "RMIc"
    static let statePrefix = "RMIg"
    static let maskPrefix = "RMIx"

    private let transform: CGAffineTransform
    private let inverse: CGAffineTransform
    /// The operators not yet handed to `deflated`, a few kilobytes at most.
    private var content: [UInt8] = []
    private let deflated = StreamingFlate()
    private var written = 0
    private var states: [String] = []
    private var stateIndex: [String: Int] = [:]
    private var masks: [Mask] = []
    private var maskIndex: [SHA256.Digest: Int] = [:]
    private var usesColorSpace = false

    /// The graphics state in effect outside `q`/`Q`, from PDF's initial one:
    /// the page's own drawing is wrapped apart, so the ink starts there.
    private var fillColor: (Double, Double, Double)?
    private var strokeColor: (Double, Double, Double)?
    private var fillAlpha = 1.0
    private var strokeAlpha = 1.0
    private var darkens = false
    private var lineWidth = 1.0
    private var lineCap: Int32 = 0
    private var lineJoin: Int32 = 0
    private var miterLimit = 10.0

    /// A writer for ink drawn under `transform`, the context's transform at
    /// the moment the ink would have been drawn — or `nil` where that is a
    /// transform this writer does not take: anything with a turn or a skew,
    /// or one that is not invertible.
    init?(transform: CGAffineTransform) {
        let parts = [transform.a, transform.d, transform.tx, transform.ty]
        guard transform.b == 0, transform.c == 0, transform.a != 0, transform.d != 0,
              parts.allSatisfy(\.isFinite)
        else { return nil }
        self.transform = transform
        inverse = transform.inverted()
        guard [inverse.a, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite) else { return nil }
    }

    /// Whether nothing has been written.
    var isEmpty: Bool { written == 0 && content.isEmpty }

    /// What has been written, once nothing more is to be: `nil` where
    /// nothing was, or where it could not be deflated.
    func finish() -> Ink? {
        flush()
        guard written > 0, let operators = deflated.finish() else { return nil }
        return Ink(content: operators, states: states, masks: masks, usesColorSpace: usesColorSpace)
    }

    /// The operators made so far handed to the deflater.
    private func flush() {
        written += content.count
        content.withUnsafeBytes { deflated.append($0) }
        content.removeAll(keepingCapacity: true)
    }

    // MARK: - Marks

    /// `path` filled, nonzero, in an opaque colour at `alpha`: what
    /// `addPath` and `fillPath(using: .winding)` paint.
    func fill(_ path: CGPath, red: Double, green: Double, blue: Double, alpha: Double, darkens: Bool) {
        guard !path.isEmpty else { return }
        setFillColor(red, green, blue)
        setState(fill: alpha, stroke: strokeAlpha, darkens: darkens)
        devicePath(path)
        put("f\n")
    }

    /// The polyline through `points`, stroked: what `move`, `addLine` and
    /// `strokePath` paint with the line state given.
    func stroke(
        _ points: [CGPoint],
        width: Double,
        cap: CGLineCap,
        join: CGLineJoin,
        miterLimit: Double,
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        darkens: Bool
    ) {
        guard points.count > 1 else { return }
        setLine(width: width, cap: cap, join: join, miterLimit: miterLimit)
        setStrokeColor(red, green, blue)
        setState(fill: fillAlpha, stroke: alpha, darkens: darkens)
        put("q ")
        for value in [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty] {
            number(value)
        }
        put("cm\n")
        for (index, point) in points.enumerated() {
            let back = Self.map(inverse, Self.map(transform, point))
            number(back.x)
            number(back.y)
            put(index == 0 ? "m\n" : "l\n")
        }
        put("S\nQ\n")
    }

    /// `mask` painted in an opaque colour at `alpha` through the clip of
    /// `clip`, into `rectangle`: what `addPath`, `clip` and
    /// `draw(_:in:)` of an image mask paint. Nothing where `clip` has no
    /// elements, as `StrokePaint.draw` paints nothing there.
    func mask(
        _ bits: StrokeGrainMask.Bits,
        in rectangle: CGRect,
        clip: CGPath,
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        darkens: Bool
    ) {
        // A contour of nothing — one an eraser took away entirely — paints
        // nothing. `W n` wants a path, and without one the whole mask would
        // be drawn; nor is the mask named, so it does not go into the file.
        guard !clip.isEmpty else { return }
        let name = maskName(bits)
        put("q\n")
        devicePath(clip)
        put("W n\n")
        put("/Perceptual ri\n")
        // Inside `q`: the colour and the state end at its `Q`, so what is
        // tracked outside it stays as it was.
        let outside = (fillColor, fillAlpha, darkens: self.darkens)
        setFillColor(red, green, blue)
        setState(fill: alpha, stroke: strokeAlpha, darkens: darkens)
        fillColor = outside.0
        fillAlpha = outside.1
        self.darkens = outside.darkens

        let t = transform
        let x = Double(rectangle.minX), y = Double(rectangle.minY)
        let width = Double(rectangle.width), height = Double(rectangle.height)
        put("q ")
        number((Double(t.c) * 0).addingProduct(Double(t.a), width))
        number((Double(t.d) * 0).addingProduct(Double(t.b), width))
        number((Double(t.c) * height).addingProduct(Double(t.a), 0))
        number((Double(t.d) * height).addingProduct(Double(t.b), 0))
        number(Double(t.tx).addingProduct(Double(t.a), x).addingProduct(Double(t.c), y))
        number(Double(t.ty).addingProduct(Double(t.b), x).addingProduct(Double(t.d), y))
        put("cm\n/\(name) Do\nQ\nQ\n")
    }

    // MARK: - State

    private func setFillColor(_ red: Double, _ green: Double, _ blue: Double) {
        if let fillColor, fillColor == (red, green, blue) { return }
        usesColorSpace = true
        put("/\(Self.colorSpaceName) cs ")
        number(red)
        number(green)
        number(blue)
        put("sc\n")
        fillColor = (red, green, blue)
    }

    private func setStrokeColor(_ red: Double, _ green: Double, _ blue: Double) {
        if let strokeColor, strokeColor == (red, green, blue) { return }
        usesColorSpace = true
        put("/\(Self.colorSpaceName) CS ")
        number(red)
        number(green)
        number(blue)
        put("SC\n")
        strokeColor = (red, green, blue)
    }

    /// The fill alpha, the line alpha and the blend mode moved to the values
    /// given, a graphics state for each that changes.
    private func setState(fill: Double, stroke: Double, darkens: Bool) {
        if fill != fillAlpha {
            useState("/ca " + QuartzNumber.alphaText(fill))
            fillAlpha = fill
        }
        if stroke != strokeAlpha {
            useState("/CA " + QuartzNumber.alphaText(stroke))
            strokeAlpha = stroke
        }
        if darkens != self.darkens {
            useState(darkens ? "/BM /Darken" : "/BM /Normal")
            self.darkens = darkens
        }
    }

    private func useState(_ entries: String) {
        let index: Int
        if let known = stateIndex[entries] {
            index = known
        } else {
            index = states.count
            states.append(entries)
            stateIndex[entries] = index
        }
        put("/\(Self.statePrefix)\(index) gs\n")
    }

    /// Width, cap, join and miter limit, as CoreGraphics sets them for a line.
    private func setLine(width: Double, cap: CGLineCap, join: CGLineJoin, miterLimit limit: Double) {
        if width != lineWidth {
            number(width)
            put("w\n")
            lineWidth = width
        }
        let capCode: Int32 = cap == .round ? 1 : cap == .square ? 2 : 0
        if capCode != lineCap {
            put("\(capCode) J\n")
            lineCap = capCode
        }
        let joinCode: Int32 = join == .round ? 1 : join == .bevel ? 2 : 0
        if joinCode != lineJoin {
            put("\(joinCode) j\n")
            lineJoin = joinCode
        }
        if limit != miterLimit {
            number(limit)
            put("M\n")
            miterLimit = limit
        }
    }

    /// The name of a mask, the same for every mask of the page with its bits.
    private func maskName(_ bits: StrokeGrainMask.Bits) -> String {
        let data = Data(bits.data)
        let digest = SHA256.hash(data: data)
        let index: Int
        if let known = maskIndex[digest] {
            index = known
        } else {
            index = masks.count
            let deflated = StreamingFlate.deflate(data) ?? [PDFWriter.flate(data)]
            masks.append(Mask(digest: digest, width: bits.width, height: bits.height, deflated: deflated))
            maskIndex[digest] = index
        }
        return "\(Self.maskPrefix)\(index)"
    }

    // MARK: - Paths

    /// A user-space point in device space, as CoreGraphics maps a path's.
    static func map(_ t: CGAffineTransform, _ point: CGPoint) -> CGPoint {
        let x = Double(point.x), y = Double(point.y)
        return CGPoint(
            x: (Double(t.c) * y).addingProduct(Double(t.a), x) + Double(t.tx),
            y: (Double(t.d) * y).addingProduct(Double(t.b), x) + Double(t.ty)
        )
    }

    /// `path`, a user-space path, written in device space.
    private func devicePath(_ path: CGPath) {
        var start = CGPoint.zero, now = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                let point = Self.map(transform, points[0])
                coordinates(point)
                put("m\n")
                start = point
                now = point
            case .addLineToPoint:
                let point = Self.map(transform, points[0])
                coordinates(point)
                put("l\n")
                now = point
            case .addQuadCurveToPoint:
                let control = Self.map(transform, points[0]), end = Self.map(transform, points[1])
                let first = CGPoint(
                    x: Double(now.x).addingProduct(Double(control.x), 2) / 3,
                    y: Double(now.y).addingProduct(Double(control.y), 2) / 3
                )
                let second = CGPoint(
                    x: Double(end.x).addingProduct(Double(control.x), 2) / 3,
                    y: Double(end.y).addingProduct(Double(control.y), 2) / 3
                )
                coordinates(first)
                coordinates(second)
                coordinates(end)
                put("c\n")
                now = end
            case .addCurveToPoint:
                let end = Self.map(transform, points[2])
                coordinates(Self.map(transform, points[0]))
                coordinates(Self.map(transform, points[1]))
                coordinates(end)
                put("c\n")
                now = end
            case .closeSubpath:
                put("h\n")
                now = start
            @unknown default:
                break
            }
        }
    }

    // MARK: - Text

    private func put(_ text: String) {
        content.append(contentsOf: text.utf8)
        if content.count >= 1 << 16 { flush() }
    }

    /// A number as CoreGraphics prints it, and the space after it.
    private func number(_ value: Double) {
        QuartzNumber.append(value, to: &content)
        content.append(UInt8(ascii: " "))
    }

    private func coordinates(_ point: CGPoint) {
        number(Double(point.x))
        number(Double(point.y))
    }
}
