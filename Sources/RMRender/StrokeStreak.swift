// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// The second ballpoint's grain: hairlines that run along the stroke.
///
/// A ballpoint pressed lightly does not lay an even film: the ball rolls on
/// a thin rim of ink, and the paper's tooth catches it in fine threads that
/// follow the direction of travel. So the grain is laid in the stroke's own
/// frame rather than the page's — `s`, the length drawn so far, and `t`, the
/// signed offset across the line — and it is long along `s` and one unit
/// thin across `t`.
///
/// The algorithm, for a port. All lengths in page units.
///
/// 1. **Frame.** `run[i]` is the length of the polyline up to point `i`.
///    For each step `a → b` of length `L > 0`, direction `d = (b − a) / L`,
///    every unit whose centre `c` lies within the step's capsule —
///    `τ = clamp(((c − a)·d) / L, 0, 1)`, `q = a + τ·L·d`,
///    `|c − q| ≤ h(τ)`, `h(τ)` the half width interpolated from `a` to `b` —
///    has `s = run[a] + (c − a)·d` and `t = cross(d, c − a)`. A stroke that
///    never moves is one disc about its first point with `d = (1, 0)`.
/// 2. **Noise** (`hairNoise`): the hair is the track `k = floor(t / hairWidth)`;
///    along it, value noise of wavelength `hairLength` whose lattice is
///    shifted by a per-track phase — `x = s / hairLength + phase(k)`,
///    `i = floor(x)`, `f = x − i`, `g = f²(3 − 2f)`,
///    `n = lerp(H(k, i), H(k, i + 1), g)`, with
///    `H(k, i) = GrainHash.unit(k, i, salt)` and
///    `phase(k) = GrainHash.unit(k, phaseRow, salt)`.
/// 3. **Threshold** (`threshold`): with `p` and `v` the pressure and speed
///    interpolated along the step at `τ`, the unit is ink where
///    `n < threshold(p, v)`, or wherever the threshold reaches 1. A unit any
///    step inks stays ink.
///
/// The contour still decides the edge — the mask is drawn clipped to it —
/// so the capsules only have to cover the stroke, not to shape it.
enum StrokeStreak {
    /// Across the stroke, one hair per unit.
    static let hairWidth = 1.0
    /// Along it, the noise turns over every 40 units: hairs a few tens of
    /// units long, about the length of one stroke of a letter.
    static let hairLength = 40.0
    /// The hash salt of the hairs, and the lattice row their phases are
    /// read from — a row no `i` reaches, being far off any page.
    static let salt: UInt64 = 0x6861_6972_6C69_6E65
    static let phaseRow: Int64 = -(1 << 40)

    /// The share of the noise's range that is ink: `T(p, v) = P(p) · V(v)`.
    ///
    /// - `P(p) = 0.55 + 0.45 · smoothstep(0, 0.5, p)`, `p` the pressure as a
    ///   share of full: a feather touch leaves a little over half the line,
    ///   and the line is whole from half pressure up.
    /// - `V(v) = 1 − 0.15 · smoothstep(24, 160, v)`, `v` the point's raw
    ///   `speed` field: a quick flick thins the ink by up to a seventh,
    ///   which is what puts hairs into a fast stroke pressed firmly.
    ///
    /// `smoothstep(e0, e1, x) = u²(3 − 2u)`, `u = clamp((x − e0) / (e1 − e0), 0, 1)`.
    /// The result lies in `[0.4675, 1]`; at 1 every unit is ink.
    static func threshold(pressure: Double, speed: Double) -> Double {
        let p = pressure.isFinite ? min(max(pressure, 0), 1) : 0
        let v = speed.isFinite ? speed : 0
        return (0.55 + 0.45 * smoothstep(0, 0.5, p)) * (1 - 0.15 * smoothstep(24, 160, v))
    }

    /// The hair noise at `(s, t)`, in `[0, 1)`, as described above.
    /// Deterministic: the same `(s, t)` answers the same on every run. A
    /// coordinate that is not a number answers 1, which no threshold is below.
    static func hairNoise(s: Double, t: Double) -> Double {
        guard s.isFinite, t.isFinite else { return 1 }
        let track = GrainHash.floor(t / hairWidth)
        let x = s / hairLength + GrainHash.unit(track, phaseRow, salt: salt)
        let i = GrainHash.floor(x)
        let f = min(max(x - Double(i), 0), 1)
        let g = f * f * (3 - 2 * f)
        let left = GrainHash.unit(track, i, salt: salt)
        let right = GrainHash.unit(track, i &+ 1, salt: salt)
        return left + (right - left) * g
    }

    /// `u²(3 − 2u)`, `u = clamp((x − edge0) / (edge1 − edge0), 0, 1)`.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let u = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Whether each unit of `box` is ink, row by row from the top.
    ///
    /// Work is bounded by the box: every capsule is clipped to it before a
    /// unit is visited, so a long diagonal costs the units of the box it
    /// passes over, not its whole length.
    static func ink(of stroke: Stroke, in box: CGRect, width: Int, height: Int) -> [Bool] {
        guard width > 0, height > 0, width <= maximumSide, height <= maximumSide,
              width * height <= maximumUnits,
              box.minX.isFinite, box.minY.isFinite
        else { return [] }
        var ink = [Bool](repeating: false, count: width * height)
        // Points that are not numbers draw nothing; a stroke made only of
        // them is paper.
        let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite && $0.lineWidth.isFinite }
        guard let first = points.first else { return ink }
        let originX = Double(box.minX), originY = Double(box.minY)

        // One capsule from `a` to `b`, its ink decided unit by unit.
        func lay(_ a: StrokePoint, _ b: StrokePoint, run: Double) {
            let ax = Double(a.x), ay = Double(a.y)
            let ex = Double(b.x) - ax, ey = Double(b.y) - ay
            let length = (ex * ex + ey * ey).squareRoot()
            guard length.isFinite else { return }
            let (dx, dy) = length > 0 ? (ex / length, ey / length) : (1.0, 0.0)
            let h0 = a.lineWidth / 2, h1 = b.lineWidth / 2
            let reach = max(h0, h1)
            guard let rows = cells(min(ay, ay + ey) - reach - originY, max(ay, ay + ey) + reach - originY, count: height),
                  let columns = cells(min(ax, ax + ex) - reach - originX, max(ax, ax + ex) + reach - originX, count: width)
            else { return }
            let p0 = a.pressureShare, p1 = b.pressureShare
            let v0 = Double(a.speed), v1 = Double(b.speed)
            for row in rows {
                let cy = originY + Double(row) + 0.5 - ay
                for column in columns {
                    let cell = row * width + column
                    guard !ink[cell] else { continue }
                    let cx = originX + Double(column) + 0.5 - ax
                    let along = cx * dx + cy * dy
                    let tau = length > 0 ? min(max(along / length, 0), 1) : 0
                    let qx = cx - dx * tau * length, qy = cy - dy * tau * length
                    let half = h0 + (h1 - h0) * tau
                    guard qx * qx + qy * qy <= half * half else { continue }
                    let limit = threshold(pressure: p0 + (p1 - p0) * tau, speed: v0 + (v1 - v0) * tau)
                    if limit >= 1 || hairNoise(s: run + along, t: dx * cy - dy * cx) < limit {
                        ink[cell] = true
                    }
                }
            }
        }

        var run = 0.0, moved = false
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0, length.isFinite else { continue }
            moved = true
            lay(a, b, run: run)
            run += length
        }
        if !moved { lay(first, first, run: 0) }
        return ink
    }

    /// The longest side of a box this draws, in units: a sheet is under
    /// two thousand, and a box past this is a broken file, not a page.
    static let maximumSide = 1 << 14

    /// The most units a box may hold: the square a wide text column turns a
    /// sheet into, 2808 units a side, fits; a box past it is refused before
    /// anything is allocated.
    static let maximumUnits = 1 << 23

    /// The cells whose centres fall in `[low, high]`, within `count`;
    /// clamped while still a double, before `Int(_:)`.
    private static func cells(_ low: Double, _ high: Double, count: Int) -> ClosedRange<Int>? {
        guard low.isFinite, high.isFinite, low <= high else { return nil }
        let first = max((low - 0.5).rounded(.up), 0)
        let last = min((high - 0.5).rounded(.down), Double(count - 1))
        guard first <= last else { return nil }
        return Int(first)...Int(last)
    }
}
