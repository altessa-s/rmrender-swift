// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// The shape of a stroke whose width changes along it.
///
/// The file gives a width at every point, and most tools change it: a thick
/// ballpoint line runs 18 → 27 over one stroke, and the average would say
/// 21.4 at both ends. One width for the whole stroke would make handwriting
/// flatter and deader than it is, and lose the thin start of every stroke.
///
/// Exported PDFs answer this the same way: nearly every stroke is a filled
/// contour rather than a stroked line — two tools of nine are stroked
/// (fineliner and highlighter). A still width is not what decides that: the
/// mechanical pencil's width is just as constant and the export fills it all
/// the same.
///
/// Built in the page's own coordinates, so that both places that draw marks —
/// the renderer and the content stream of an overlay — can convert it with the
/// transform each already has. That conversion is a translation and a flip,
/// and an affine transform maps straight edges to straight edges and circles
/// to circles, so the shape survives it.
enum StrokeOutline {
    enum Element: Sendable, Hashable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(control1: CGPoint, control2: CGPoint, to: CGPoint)
        case close
    }

    /// The constant that turns four Béziers into a circle.
    private static let circleControl = 0.5522847498307933

    /// The stroke as one contour, to be filled with the nonzero rule.
    ///
    /// The construction, for a port:
    ///
    /// 1. Runs of points that lie on one line at a steadily changing width
    ///    are merged (`anchors`), and every remaining step from one anchor to
    ///    the next becomes a **band**: a quad whose ends are cut square to the
    ///    step, each end as wide as the file says at that point —
    ///    `from ± n·w₀/2`, `to ± n·w₁/2`, `n` the step's left normal.
    /// 2. At every anchor between two bands the outer side of the turn is
    ///    filled by a **join** (`join`): a circular sector for a round tip,
    ///    a mitre cut back to a bevel past `PenTool.lineMiterLimit` for a
    ///    chisel. The inner side lies under the bands already.
    /// 3. Each end gets the tool's **cap** (`StrokeEnd`); a stroke that never
    ///    moves is a disc.
    ///
    /// **One fill, not one per piece.** The pieces overlap where the stroke
    /// turns, and every one of them is wound the same way round, so filling
    /// them together paints each spot once. Filling them one at a time
    /// would darken every overlap of a translucent tool and leave a lattice
    /// of seams down the middle of a shader stroke.
    static func elements(of stroke: Stroke) -> [Element] {
        let points = stroke.points
        guard points.count > 1 else { return [] }

        var out: [Element] = []
        let anchors = anchors(of: points)
        out.reserveCapacity(anchors.count * 8)
        let mitred = stroke.tool?.lineJoin == .miter

        let bands = anchors.count - 1
        let directions = (0..<bands).map { index in
            StrokeDirection(from: points[anchors[index]].location, to: points[anchors[index + 1]].location)
        }
        // The direction the stroke last moved in: a point repeated at a new
        // width is a band of no length, and the turn across it is still a
        // turn.
        var incoming: StrokeDirection?
        for index in 0..<bands {
            let head = anchors[index], tail = anchors[index + 1]
            guard let direction = directions[index] else { continue }
            let from = points[head].location, to = points[tail].location
            let fromHalf = points[head].lineWidth / 2, toHalf = points[tail].lineWidth / 2
            let normal = direction.turnedRight
            out.append(contentsOf: polygon([
                from.moved(normal, by: fromHalf),
                to.moved(normal, by: toHalf),
                to.moved(normal, by: -toHalf),
                from.moved(normal, by: -fromHalf),
            ]))
            if let before = incoming {
                out.append(contentsOf: polygon(join(at: from, radius: fromHalf, from: before, to: direction, mitred: mitred)))
            }
            incoming = direction
        }
        guard let first = points.first, let last = points.last else { return out }

        // A stroke that goes nowhere has no direction to end in, and is the
        // dot it is.
        let start = directions.compactMap { $0 }.first, finish = directions.compactMap { $0 }.last
        guard let start, let finish else {
            out.append(contentsOf: disc(at: first.location, radius: first.lineWidth / 2))
            out.append(contentsOf: disc(at: last.location, radius: last.lineWidth / 2))
            return out
        }
        out.append(contentsOf: cap(stroke.end, at: first.location, radius: first.lineWidth / 2,
                                   outward: CGVector(dx: -start.dx, dy: -start.dy)))
        out.append(contentsOf: cap(stroke.end, at: last.location, radius: last.lineWidth / 2,
                                   outward: CGVector(dx: finish.dx, dy: finish.dy)))
        return out
    }

    /// The smallest turn, in radians, that gets a join at all. Below it the
    /// outer gap between two bands is under a millionth of their width.
    private static let leastTurn = 1e-6

    /// The join on the outer side of a turn at `centre`, as the corners of a
    /// polygon, or none for a turn too slight to open a gap.
    ///
    /// With `θ` the turn between the two directions, `s` the side the turn
    /// opens on (`+1` when `cross(before, after) < 0`, else `−1`), and
    /// `n₀ = s·normal(before)`, `n₁ = s·normal(after)` the two outer rims:
    ///
    /// - round: the sector `centre, centre + r·n₀, …arc…, centre + r·n₁`,
    ///   the arc cut into `StrokeEnd.arcSteps(r, θ)` chords;
    /// - mitred: `centre, centre + r·n₀, tip, centre + r·n₁`, where the tip
    ///   is `centre + r / cos(θ/2) · bisector(n₀, n₁)`, as long as
    ///   `1 / cos(θ/2) ≤ PenTool.lineMiterLimit`; past it the tip is dropped
    ///   and the join is the bevel `centre, centre + r·n₀, centre + r·n₁`.
    private static func join(
        at centre: CGPoint, radius: Double, from before: StrokeDirection, to after: StrokeDirection, mitred: Bool
    ) -> [CGPoint] {
        guard radius > 0, radius.isFinite else { return [] }
        let turn = before.angle(to: after)
        guard turn >= leastTurn else { return [] }
        // The outer side is the one the stroke turns away from.
        let cross = before.dx * after.dy - before.dy * after.dx
        let side = cross < 0 ? 1.0 : -1.0
        let rimBefore = CGVector(dx: before.turnedRight.dx * side, dy: before.turnedRight.dy * side)
        let rimAfter = CGVector(dx: after.turnedRight.dx * side, dy: after.turnedRight.dy * side)
        func rim(_ vector: CGVector, _ length: Double) -> CGPoint {
            CGPoint(x: Double(centre.x) + Double(vector.dx) * length, y: Double(centre.y) + Double(vector.dy) * length)
        }
        if mitred {
            let reach = 1 / cos(turn / 2)
            guard reach.isFinite, reach <= PenTool.lineMiterLimit else {
                return [centre, rim(rimBefore, radius), rim(rimAfter, radius)]
            }
            let mx = Double(rimBefore.dx + rimAfter.dx), my = Double(rimBefore.dy + rimAfter.dy)
            let length = (mx * mx + my * my).squareRoot()
            guard length > 0 else { return [centre, rim(rimBefore, radius), rim(rimAfter, radius)] }
            let tip = rim(CGVector(dx: mx / length, dy: my / length), radius * reach)
            return [centre, rim(rimBefore, radius), tip, rim(rimAfter, radius)]
        }
        let startAngle = atan2(Double(rimBefore.dy), Double(rimBefore.dx))
        // The sweep runs from one rim to the other the short way round, which
        // is the way the stroke turned.
        let sweep = cross < 0 ? -turn : turn
        let arc = StrokeEnd.arc(
            centre: centre, radius: radius, start: startAngle, sweep: sweep,
            steps: StrokeEnd.arcSteps(radius: radius, sweep: turn)
        )
        return [centre] + arc
    }

    /// The corners turned to wind the way the bands do, so that the nonzero
    /// rule adds them rather than cutting them out: a band of a stroke
    /// heading along x runs along its `+y` rim first, which is a negative
    /// area in these coordinates.
    private static func wound(_ corners: [CGPoint]) -> [CGPoint] {
        var area = 0.0
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            area += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return area > 0 ? corners.reversed() : corners
    }

    /// A closed polygon, wound the bands' way.
    private static func polygon(_ corners: [CGPoint]) -> [Element] {
        let corners = wound(corners)
        guard let head = corners.first, corners.count >= 3 else { return [] }
        return [.move(head)] + corners.dropFirst().map { .line($0) } + [.close]
    }

    /// One end of a stroke, as a contour wound the way the bands are.
    private static func cap(_ end: StrokeEnd, at centre: CGPoint, radius: Double, outward: CGVector) -> [Element] {
        let corners: [CGPoint]? = switch end {
        case .round: StrokeEnd.roundCap(centre: centre, radius: radius, outward: outward)
        case .square: StrokeEnd.square(centre: centre, radius: radius, outward: outward)
        case .butt: nil
        }
        guard let corners else { return [] }
        return polygon(corners)
    }

    /// The points that need a band of their own.
    ///
    /// The tablet samples faster than a hand moves, so a stroke arrives with
    /// runs of points that lie on one line at one width. A band each would
    /// draw the same shape out of five times the operators: on a page of an
    /// imported PDF the marks are written out as text, and a two-hundred-point
    /// stroke would grow from 16 to 65 kilobytes when it zigzags. Runs are joined
    /// while every point between the ends stays within a tenth of a unit of
    /// the line and a quarter of a unit of the width — a hundredth of a
    /// typographic point, which no paper and no screen can show.
    private static func anchors(of points: [StrokePoint]) -> [Int] {
        var anchors = [0]
        var head = 0
        var tail = 1
        while tail < points.count {
            if tail + 1 < points.count,
               tail - head < longestRun,
               fits(points, from: head, to: tail + 1) {
                tail += 1
                continue
            }
            anchors.append(tail)
            head = tail
            tail += 1
        }
        return anchors
    }

    /// How many points one band may swallow. A ceiling rather than a
    /// judgement: without it the search is quadratic on a straight line drawn
    /// with a thousand samples.
    private static let longestRun = 24
    /// How far a point may sit off the band that stands in for it.
    private static let positionTolerance = 0.1
    /// And how far its width may be off the width interpolated for it. Wider
    /// than the position tolerance because an edge a quarter of a unit out is
    /// harder to see than a bend of the same size.
    private static let widthTolerance = 0.25

    /// Whether one band from `from` to `to` stands in for every point between.
    private static func fits(_ points: [StrokePoint], from: Int, to: Int) -> Bool {
        let start = points[from].location
        let end = points[to].location
        guard let along = StrokeDirection(from: start, to: end) else { return false }
        let normal = along.turnedRight
        let span = Double(end.x - start.x) * along.dx + Double(end.y - start.y) * along.dy
        guard span > 0 else { return false }

        let startWidth = points[from].lineWidth
        let endWidth = points[to].lineWidth
        for index in (from + 1)..<to {
            let point = points[index].location
            let dx = Double(point.x - start.x), dy = Double(point.y - start.y)
            // How far off the line, and how far along it.
            if abs(dx * normal.dx + dy * normal.dy) > positionTolerance { return false }
            let travelled = (dx * along.dx + dy * along.dy) / span
            let expected = startWidth + (endWidth - startWidth) * min(max(travelled, 0), 1)
            if abs(points[index].lineWidth - expected) > widthTolerance { return false }
        }
        return true
    }

    /// A circle drawn clockwise — the same way round as the bands above, so
    /// that the nonzero rule counts them together rather than against each
    /// other. Wound the other way, a disc would punch a hole in the band it
    /// sits on.
    private static func disc(at centre: CGPoint, radius: Double) -> [Element] {
        guard radius > 0 else { return [] }
        let pull = radius * circleControl
        let x = Double(centre.x), y = Double(centre.y)
        return [
            .move(CGPoint(x: x + radius, y: y)),
            .curve(
                control1: CGPoint(x: x + radius, y: y - pull),
                control2: CGPoint(x: x + pull, y: y - radius),
                to: CGPoint(x: x, y: y - radius)
            ),
            .curve(
                control1: CGPoint(x: x - pull, y: y - radius),
                control2: CGPoint(x: x - radius, y: y - pull),
                to: CGPoint(x: x - radius, y: y)
            ),
            .curve(
                control1: CGPoint(x: x - radius, y: y + pull),
                control2: CGPoint(x: x - pull, y: y + radius),
                to: CGPoint(x: x, y: y + radius)
            ),
            .curve(
                control1: CGPoint(x: x + pull, y: y + radius),
                control2: CGPoint(x: x + radius, y: y + pull),
                to: CGPoint(x: x + radius, y: y)
            ),
            .close,
        ]
    }
}

/// A direction of unit length.
///
/// A type of its own because a step of no length has no direction, and two
/// points of a stroke are sometimes one and the same point — the tablet
/// samples faster than a hand moves.
struct StrokeDirection {
    let dx: Double
    let dy: Double

    init?(from: CGPoint, to: CGPoint) {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        self.dx = dx / length
        self.dy = dy / length
    }

    private init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    /// The perpendicular: a quarter turn, always the same way, which is what
    /// keeps every band of a stroke wound alike.
    var turnedRight: StrokeDirection { StrokeDirection(dx: -dy, dy: dx) }

    /// The angle between two directions, from nought to π.
    func angle(to other: StrokeDirection) -> Double {
        acos(min(max(dx * other.dx + dy * other.dy, -1), 1))
    }
}

extension CGPoint {
    func moved(_ direction: StrokeDirection, by distance: Double) -> CGPoint {
        CGPoint(x: Double(x) + direction.dx * distance, y: Double(y) + direction.dy * distance)
    }

    func distance(to other: CGPoint) -> Double {
        let dx = Double(other.x - x), dy = Double(other.y - y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

extension StrokePoint {
    var location: CGPoint { CGPoint(x: Double(x), y: Double(y)) }
}
