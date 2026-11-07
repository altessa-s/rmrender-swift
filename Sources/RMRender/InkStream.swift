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
/// task prepares the page — with the highlights' bands, where nothing
/// CoreGraphics draws comes after them, and with the transparency layers
/// the pieces of an erased shader stroke are drawn in — and CoreGraphics
/// keeps the rest: templates, text, pictures.
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
/// - A highlight's band is a rectangle, `re`, mapped as `CGRect.applying`
///   maps it, filled at full alpha with `/BM /Multiply`.
/// - A transparency layer — the pieces an eraser left of one shader stroke
///   (`PageRenderer.sharedLayerKey`) — is a Form of its own, a group as
///   CoreGraphics writes one (`beginGroup`).
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

    /// A transparency group the content paints, `/RMIf<i>`: a Form of its
    /// own, its operators deflated, and the resources of the page's ink it
    /// names — by their indices in `Ink`, under the names the page gives
    /// them.
    struct Group: Sendable {
        /// Deflated, in pieces (`StreamingFlate`).
        let content: [Data]
        /// The Form's box, as CoreGraphics prints it: the lower left corner,
        /// then the upper right (`beginGroup`).
        let box: [String]
        /// The graphics states it names, by index, in order.
        let states: [Int]
        /// The masks it names, by index, in order.
        let masks: [Int]
        let usesColorSpace: Bool
    }

    /// What a page's ink comes to: its operators, deflated, and the
    /// resources they name, by index — `/RMIg<i>` is `states[i]`,
    /// `/RMIx<i>` is `masks[i]`, `/RMIf<i>` is `groups[i]`, `/RMIc` the sRGB
    /// colour space when `usesColorSpace`. A group's own operators name
    /// states, masks and the colour space the same way; every group blends
    /// in the Generic RGB space (`InkUpdate`).
    struct Ink: Sendable {
        /// Deflated, in pieces (`StreamingFlate`).
        let content: [Data]
        /// The entries of each graphics state, `/ca 0.5` and the like.
        let states: [String]
        let masks: [Mask]
        let groups: [Group]
        let usesColorSpace: Bool
    }

    /// The prefixes of the names the content gives its resources. CoreGraphics
    /// names its own `/Cs1`, `/Gs1`, `/Im1`, `/Fm1`, `/TT1`; these cannot meet
    /// them on a page the two share.
    static let colorSpaceName = "RMIc"
    static let statePrefix = "RMIg"
    static let maskPrefix = "RMIx"
    static let groupPrefix = "RMIf"

    private let transform: CGAffineTransform
    private let inverse: CGAffineTransform
    /// The page's box, which a transparency layer is clipped to; `nil`
    /// where it is not known, and then the writer takes no layer.
    private let box: CGRect?
    /// The operators not yet handed to `deflated`, a few kilobytes at most:
    /// the page's, or the open group's.
    private var content: [UInt8] = []
    private var deflated = StreamingFlate()
    private var written = 0
    private var states: [String] = []
    private var stateIndex: [String: Int] = [:]
    private var masks: [Mask] = []
    private var maskIndex: [SHA256.Digest: Int] = [:]
    private var groups: [Group] = []
    private var usesColorSpace = false
    /// Set where a group's operators could not be deflated: the ink is then
    /// not to be had at all.
    private var failed = false

    /// The graphics state in effect outside `q`/`Q`, from PDF's initial one:
    /// the page's own drawing is wrapped apart, so the ink starts there.
    private var fillColor: (Double, Double, Double)?
    private var strokeColor: (Double, Double, Double)?
    private var fillAlpha = 1.0
    private var strokeAlpha = 1.0
    private var blend = Blend.normal
    private var lineWidth = 1.0
    private var lineCap: Int32 = 0
    private var lineJoin: Int32 = 0
    private var miterLimit = 10.0

    /// The transparency group being written, while one is open.
    private var group: OpenGroup?

    /// A writer for ink drawn under `transform`, the context's transform at
    /// the moment the ink would have been drawn, on a page of `box` — or
    /// `nil` where that is a transform this writer does not take: anything
    /// with a turn or a skew, or one that is not invertible. Without a box,
    /// or with one that is not finite, it takes no transparency layer
    /// (`takesGroups`).
    init?(transform: CGAffineTransform, box: CGRect? = nil) {
        let parts = [transform.a, transform.d, transform.tx, transform.ty]
        guard transform.b == 0, transform.c == 0, transform.a != 0, transform.d != 0,
              parts.allSatisfy(\.isFinite)
        else { return nil }
        self.transform = transform
        inverse = transform.inverted()
        guard [inverse.a, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite) else { return nil }
        self.box = Self.layerBox(box)
    }

    /// `box` where a layer can be clipped to it: given, and finite — and
    /// where a group can be written at all (`groupsAvailable`).
    static func layerBox(_ box: CGRect?) -> CGRect? {
        guard groupsAvailable, let box, !box.isNull,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite)
        else { return nil }
        return box
    }

    /// Whether transparency groups can be written: whether the profile they
    /// blend in is to be had (`PreparedInk.groupProfile`, resolved once a
    /// process). Where it is not, no writer takes a layer, on any route, and
    /// the layers are CoreGraphics' as they always were: the page comes out
    /// the same, more slowly.
    static var groupsAvailable: Bool { !groupProfileWithheld && PreparedInk.groupProfile != nil }

    /// Set by a test, for the work it does inside `withValue`, to stand for
    /// a system on which the group profile does not resolve.
    @TaskLocal static var groupProfileWithheld = false

    /// Whether nothing has been written: a group that could not be
    /// deflated was.
    var isEmpty: Bool { written == 0 && content.isEmpty && group == nil && !failed }

    /// Whether the writer writes transparency layers (`beginGroup`): where
    /// it knows the box of the page they are clipped to.
    var takesGroups: Bool { box != nil }

    /// What has been written, once nothing more is to be: `nil` where
    /// nothing was, or where it could not be deflated. A group still open
    /// is closed first.
    func finish() -> Ink? {
        if group != nil { endGroup() }
        flush()
        guard !failed, written > 0, let operators = deflated.finish() else { return nil }
        return Ink(content: operators, states: states, masks: masks, groups: groups, usesColorSpace: usesColorSpace)
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
        setState(fill: alpha, stroke: strokeAlpha, blend: darkens ? .darken : .normal)
        devicePath(path)
        put("f\n")
        if group != nil { addMember(deviceCopy(of: path).boundingBoxOfPath) }
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
        setState(fill: fillAlpha, stroke: alpha, blend: darkens ? .darken : .normal)
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
        if group != nil {
            // What CoreGraphics records of a line in a layer: the line's
            // bounds in device space, grown on every side by its width — by
            // half the miter limit of it where the joins are mitred and that
            // is more.
            let line = CGMutablePath()
            line.addLines(between: points.map { Self.map(transform, $0) })
            let grow = width * (join == .miter ? max(miterLimit / 2, 1) : 1) * Double(transform.a)
            addMember(line.boundingBoxOfPath.insetBy(dx: -grow, dy: -grow))
        }
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
        let outside = (fillColor, fillAlpha, blend)
        setFillColor(red, green, blue)
        setState(fill: alpha, stroke: strokeAlpha, blend: darkens ? .darken : .normal)
        fillColor = outside.0
        fillAlpha = outside.1
        blend = outside.2

        let t = transform
        let x = Double(rectangle.minX), y = Double(rectangle.minY)
        let width = Double(rectangle.width), height = Double(rectangle.height)
        let matrix = [
            (Double(t.c) * 0).addingProduct(Double(t.a), width),
            (Double(t.d) * 0).addingProduct(Double(t.b), width),
            (Double(t.c) * height).addingProduct(Double(t.a), 0),
            (Double(t.d) * height).addingProduct(Double(t.b), 0),
            Double(t.tx).addingProduct(Double(t.a), x).addingProduct(Double(t.c), y),
            Double(t.ty).addingProduct(Double(t.b), x).addingProduct(Double(t.d), y),
        ]
        put("q ")
        for value in matrix { number(value) }
        put("cm\n/\(name) Do\nQ\nQ\n")
        if group != nil {
            // What CoreGraphics records of a mask in a layer: the image's
            // rectangle in device space, within the bounds of the clip's
            // points — its control points, not the curve's.
            let image = CGRect(x: matrix[4], y: matrix[5], width: matrix[0], height: matrix[3]).standardized
            addMember(image.intersection(deviceCopy(of: clip).boundingBox))
        }
    }

    /// A band of a text highlight: `rectangle` filled in an opaque colour,
    /// multiplied onto what is under it — what `setBlendMode(.multiply)`,
    /// `setFillColor` and `fill(_:)` of a rectangle paint at a context's
    /// full alpha. CoreGraphics writes a rectangle as one, `re`, its corners
    /// in device space: the rectangle mapped through the transform and
    /// standardized, as `CGRect.applying` maps it.
    func highlight(_ rectangle: CGRect, red: Double, green: Double, blue: Double) {
        setFillColor(red, green, blue)
        setState(fill: 1, stroke: strokeAlpha, blend: .multiply)
        let device = rectangle.applying(transform)
        number(Double(device.minX))
        number(Double(device.minY))
        number(Double(device.width))
        number(Double(device.height))
        put("re f\n")
    }

    // MARK: - Groups

    /// The page's writing set aside while a group is written in its place,
    /// and what the group has come to so far.
    private struct OpenGroup {
        let content: [UInt8]
        let deflated: StreamingFlate
        let written: Int
        let tracked: Tracked
        let alpha: Double
        let darkens: Bool
        /// The union of what CoreGraphics records of each member.
        var box = CGRect.null
        var states: Set<Int> = []
        var masks: Set<Int> = []
        var usesColorSpace = false
    }

    /// A transparency layer opened as `PageRenderer.draw` opens one — the
    /// blend and the alpha given, `beginTransparencyLayer` — and
    /// written as CoreGraphics writes it: what is drawn until `endGroup`
    /// goes into a Form of its own, an isolated, non-knockout group blending
    /// in Generic RGB, clipped inside to the page's box — not its crop box —
    /// and drawn there as on the page, its alpha and blend mode starting
    /// from their initial values; `endGroup` paints it. Nothing where the
    /// writer takes no layer (`takesGroups`).
    func beginGroup(alpha: Double, darkens: Bool) {
        guard let box else { return }
        if group != nil { endGroup() }
        group = OpenGroup(
            content: content, deflated: deflated, written: written, tracked: tracked, alpha: alpha, darkens: darkens
        )
        content = []
        deflated = StreamingFlate()
        written = 0
        // A group starts from the state where it is painted, less its alpha
        // and blend mode: the rest is set again, as CoreGraphics sets it.
        tracked = Tracked(
            fillColor: nil, strokeColor: nil, fillAlpha: 1, strokeAlpha: 1, blend: .normal,
            lineWidth: .nan, lineCap: -1, lineJoin: -1, miterLimit: .nan
        )
        put("q\n")
        number(Double(box.minX))
        number(Double(box.minY))
        number(Double(box.width))
        number(Double(box.height))
        put("re\nW n\n")
    }

    /// The open group closed and painted, as `endTransparencyLayer` paints
    /// a layer: the Form inside `q`/`Q` under the layer's alpha and blend
    /// mode, which end at its `Q` — left set after it, CoreGraphics'
    /// renderer takes a later `ca 1` for set already, and paints the opaque
    /// ink after the group at the group's alpha.
    ///
    /// Its box is the union of what CoreGraphics records of each member
    /// (`fill`, `stroke`, `mask`), printed as CoreGraphics prints it; a group
    /// whose box misses the page's — off the page, or erased away — is not
    /// written at all, as CoreGraphics writes no such layer.
    func endGroup() {
        guard let open = group else { return }
        put("Q\n")
        flush()
        let operators = deflated.finish()
        content = open.content
        deflated = open.deflated
        written = open.written
        tracked = open.tracked
        group = nil
        guard let operators else {
            failed = true
            return
        }
        guard let box, open.box.intersects(box) else { return }
        let index = groups.count
        groups.append(Group(
            content: operators,
            box: [open.box.minX, open.box.minY, open.box.maxX, open.box.maxY].map { QuartzNumber.text(Double($0)) },
            states: open.states.sorted(), masks: open.masks.sorted(), usesColorSpace: open.usesColorSpace
        ))
        put("q\n")
        let outside = (fillAlpha, blend)
        setState(fill: open.alpha, stroke: strokeAlpha, blend: open.darkens ? .darken : .normal)
        fillAlpha = outside.0
        blend = outside.1
        put("/\(Self.groupPrefix)\(index) Do\nQ\n")
    }

    /// A member's rectangle added to the open group's box.
    private func addMember(_ rectangle: CGRect) {
        guard let box = group?.box else { return }
        group?.box = box.union(rectangle)
    }

    /// The graphics state tracked outside `q`/`Q`, as one value: set aside
    /// while a group is written.
    private struct Tracked {
        let fillColor: (Double, Double, Double)?
        let strokeColor: (Double, Double, Double)?
        let fillAlpha: Double
        let strokeAlpha: Double
        let blend: Blend
        let lineWidth: Double
        let lineCap: Int32
        let lineJoin: Int32
        let miterLimit: Double
    }

    private var tracked: Tracked {
        get {
            Tracked(
                fillColor: fillColor, strokeColor: strokeColor, fillAlpha: fillAlpha, strokeAlpha: strokeAlpha,
                blend: blend, lineWidth: lineWidth, lineCap: lineCap, lineJoin: lineJoin, miterLimit: miterLimit
            )
        }
        set {
            fillColor = newValue.fillColor
            strokeColor = newValue.strokeColor
            fillAlpha = newValue.fillAlpha
            strokeAlpha = newValue.strokeAlpha
            blend = newValue.blend
            lineWidth = newValue.lineWidth
            lineCap = newValue.lineCap
            lineJoin = newValue.lineJoin
            miterLimit = newValue.miterLimit
        }
    }

    // MARK: - State

    /// The blend modes the ink is painted with, as a graphics state names
    /// them.
    private enum Blend: String {
        case normal = "Normal"
        case darken = "Darken"
        case multiply = "Multiply"
    }

    private func setFillColor(_ red: Double, _ green: Double, _ blue: Double) {
        if let fillColor, fillColor == (red, green, blue) { return }
        usesColorSpace = true
        group?.usesColorSpace = true
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
        group?.usesColorSpace = true
        put("/\(Self.colorSpaceName) CS ")
        number(red)
        number(green)
        number(blue)
        put("SC\n")
        strokeColor = (red, green, blue)
    }

    /// The fill alpha, the line alpha and the blend mode moved to the values
    /// given, a graphics state for each that changes.
    private func setState(fill: Double, stroke: Double, blend: Blend) {
        if fill != fillAlpha {
            useState("/ca " + QuartzNumber.alphaText(fill))
            fillAlpha = fill
        }
        if stroke != strokeAlpha {
            useState("/CA " + QuartzNumber.alphaText(stroke))
            strokeAlpha = stroke
        }
        if blend != self.blend {
            useState("/BM /" + blend.rawValue)
            self.blend = blend
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
        group?.states.insert(index)
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
        group?.masks.insert(index)
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

    /// `path`, a user-space path, in device space as CoreGraphics keeps it:
    /// a quadratic segment as it is.
    private func deviceCopy(of path: CGPath) -> CGPath {
        let device = CGMutablePath()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                device.move(to: Self.map(transform, points[0]))
            case .addLineToPoint:
                device.addLine(to: Self.map(transform, points[0]))
            case .addQuadCurveToPoint:
                device.addQuadCurve(to: Self.map(transform, points[1]), control: Self.map(transform, points[0]))
            case .addCurveToPoint:
                device.addCurve(
                    to: Self.map(transform, points[2]), control1: Self.map(transform, points[0]),
                    control2: Self.map(transform, points[1])
                )
            case .closeSubpath:
                device.closeSubpath()
            @unknown default:
                break
            }
        }
        return device
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
