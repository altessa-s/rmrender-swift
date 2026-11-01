// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// How a stroke ends.
///
/// A pen with a round tip leaves a round end: the tip's footprint is a disc,
/// and the last disc it laid is the end of the line. The highlighters have a
/// flat chisel tip held across the line, and their band stops where the pen
/// lifted. So every tool ends round except the two highlighters, which end
/// flat.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum StrokeEnd: Sendable, Hashable {
    /// A half disc of half the width's radius about the last point.
    case round
    /// Half the width further on, cut square.
    case square
    /// Cut at the last point.
    case butt

    /// The cap as the line-drawing APIs name it, for a stroked line.
    var lineCap: CGLineCap {
        switch self {
        case .round: .round
        case .square: .square
        case .butt: .butt
        }
    }

    /// The same as a PDF's `J` operand.
    var pdfLineCap: Int {
        switch self {
        case .butt: 0
        case .round: 1
        case .square: 2
        }
    }

    /// The largest distance, in units, that a polygon standing in for an arc
    /// may fall inside the true arc: a tenth of a unit, about a thirtieth of
    /// a typographic point.
    static let chordTolerance = 0.1

    /// The most chords one arc is cut into, however wide the stroke.
    static let maximumArcSteps = 64

    /// How many equal chords an arc of `radius` sweeping `sweep` radians
    /// needs so that no chord falls more than `chordTolerance` inside it.
    ///
    /// A chord spanning the angle `a` sags `radius · (1 − cos(a / 2))` below
    /// the arc, so the widest angle allowed is
    /// `aMax = 2 · acos(1 − chordTolerance / radius)` and the count is
    /// `ceil(|sweep| / aMax)`, held to `1…maximumArcSteps`. A radius no
    /// larger than the tolerance takes a single chord.
    static func arcSteps(radius: Double, sweep: Double) -> Int {
        guard radius.isFinite, sweep.isFinite, radius > chordTolerance else { return 1 }
        let widest = 2 * acos(1 - chordTolerance / radius)
        let steps = (abs(sweep) / widest).rounded(.up)
        guard steps.isFinite else { return maximumArcSteps }
        return min(max(Int(steps), 1), maximumArcSteps)
    }

    /// The points of an arc about `centre`: `steps + 1` of them, from the
    /// angle `start` through `start + sweep`, every one exactly `radius`
    /// from the centre. Angles in radians, measured from `+x` towards `+y`.
    static func arc(centre: CGPoint, radius: Double, start: Double, sweep: Double, steps: Int) -> [CGPoint] {
        let count = max(steps, 1)
        return (0...count).map { index in
            let angle = start + sweep * Double(index) / Double(count)
            return CGPoint(
                x: Double(centre.x) + cos(angle) * radius,
                y: Double(centre.y) + sin(angle) * radius
            )
        }
    }

    /// The round cap as a polygon: a half disc about `centre` facing
    /// `outward` (a unit vector), from one rim of the stroke round the front
    /// to the other.
    ///
    /// Parameters, for a port: the rims lie at `heading ± π/2`, where
    /// `heading = atan2(outward)`; the arc runs from `heading + π/2` through
    /// `−π` of sweep in `max(2, arcSteps(radius, π))` equal chords. Every
    /// corner lies on the circle of `radius`, so the polygon never reaches
    /// past it. `nil` for a radius that is not positive or not a number.
    static func roundCap(centre: CGPoint, radius: Double, outward: CGVector) -> [CGPoint]? {
        guard radius.isFinite, radius > 0, outward.dx.isFinite, outward.dy.isFinite,
              outward.dx != 0 || outward.dy != 0
        else { return nil }
        let heading = atan2(Double(outward.dy), Double(outward.dx))
        let steps = max(2, arcSteps(radius: radius, sweep: Double.pi))
        return arc(centre: centre, radius: radius, start: heading + Double.pi / 2, sweep: -Double.pi, steps: steps)
    }

    /// The square cap: the band carried half its width further on.
    static func square(centre: CGPoint, radius: Double, outward: CGVector) -> [CGPoint]? {
        guard radius.isFinite, radius > 0, outward.dx.isFinite, outward.dy.isFinite else { return nil }
        let x = Double(centre.x), y = Double(centre.y)
        let ox = Double(outward.dx) * radius, oy = Double(outward.dy) * radius
        // The rims: the outward direction turned a quarter each way.
        let rx = -oy, ry = ox
        return [
            CGPoint(x: x + rx, y: y + ry),
            CGPoint(x: x + rx + ox, y: y + ry + oy),
            CGPoint(x: x - rx + ox, y: y - ry + oy),
            CGPoint(x: x - rx, y: y - ry),
        ]
    }

    /// Whether `point` lies inside the convex `polygon`, edges included.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let cross = Double(b.x - a.x) * Double(point.y - a.y) - Double(b.y - a.y) * Double(point.x - a.x)
            if abs(cross) < 1e-9 { continue }
            let side = cross > 0 ? 1 : -1
            if sign == 0 { sign = side } else if side != sign { return false }
        }
        return true
    }
}

public extension PenTool {
    /// How a line of this tool joins its segments.
    ///
    /// A round tip turns a corner round. A chisel turns it sharp: the
    /// highlighters meet at a mitre, cut back to a bevel past
    /// `StrokeEnd`'s miter limit (`lineMiterLimit`).
    internal var lineJoin: CGLineJoin { isHighlighter ? .miter : .round }

    /// The longest a mitre may reach, as a multiple of the line's half
    /// width, before the corner is bevelled instead: 2, which mitres a turn
    /// of up to 120° (`1 / cos(θ / 2) ≤ 2`) and bevels a sharper one. The
    /// same number as the `miterLimit` of a stroked line and a PDF's `M`
    /// operand, which measure the mitre against the full width the same way.
    internal static var lineMiterLimit: Double { 2 }

    /// How this tool's strokes end: flat for the chisel-tipped highlighters,
    /// round for every other tip.
    var end: StrokeEnd { isHighlighter ? .butt : .round }
}

public extension Stroke {
    /// How the stroke ends. A tool we have never seen ends round, as most do.
    ///
    /// A flat end needs a direction to be cut across, and a tap that never
    /// moved has none: cut flat it would leave nothing at all. It ends
    /// square instead — the chisel's own footprint, a square of the width.
    var end: StrokeEnd {
        let end = tool?.end ?? .round
        guard end == .butt, let first = points.first else { return end }
        return points.contains { $0.x != first.x || $0.y != first.y } ? end : .square
    }
}
