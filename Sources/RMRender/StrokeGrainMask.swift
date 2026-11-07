// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// The grain of one stroke as an image mask: one texel to a unit, painted
/// where there is ink, clear where the paper shows.
///
/// Built over the stroke's box. For every grain but the second ballpoint's,
/// the stroke is first drawn into a byte map, segment by segment, each
/// segment carrying its pressure; a byte of nought is outside the stroke.
/// Then every unit inside is decided by the grain's rule — the tiles, a hash
/// of the unit's place, or `StrokeScratch` — and the mask is drawn by the
/// renderer clipped to the stroke's own contour, so that the edge stays
/// where the contour puts it. The second ballpoint decides its units in the
/// stroke's own frame (`StrokeStreak`).
///
/// Texel to unit, not to point or pixel: that is the scale exported PDFs
/// show grain at, and the scale the tiles were made for. The mask itself is
/// finer than the texel: a reader resamples an image to its own grid, and a
/// texel of one pixel comes back as a grey smudge; at two pixels a texel the
/// smudge is its edge only.
enum StrokeGrainMask {
    /// Mask pixels to a texel, each way.
    static let texelPixels = 2

    /// The mask as bits: one a pixel, rows padded to a byte, set where the
    /// paper shows — an image mask paints where its sample is nought, in a
    /// PDF and in CoreGraphics alike, so the same bytes serve both.
    struct Bits: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: [UInt8]
    }

    /// The whole units the stroke covers, in page coordinates, with a unit
    /// to spare on every side for the round of a cap.
    static func box(of stroke: Stroke) -> CGRect? {
        guard let first = stroke.points.first else { return nil }
        var minX = Double(first.x), maxX = minX, minY = Double(first.y), maxY = minY
        for point in stroke.points {
            let half = point.lineWidth / 2 + 1
            minX = min(minX, Double(point.x) - half)
            maxX = max(maxX, Double(point.x) + half)
            minY = min(minY, Double(point.y) - half)
            maxY = max(maxY, Double(point.y) + half)
        }
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { return nil }
        let box = CGRect(
            x: floor(minX),
            y: floor(minY),
            width: ceil(maxX) - floor(minX),
            height: ceil(maxY) - floor(minY)
        )
        guard box.width >= 1, box.height >= 1 else { return nil }
        return box
    }

    /// The mask over `box` as an image, or `nil` when there is nothing to
    /// build it from.
    static func image(for stroke: Stroke, grain: StrokeGrain, in box: CGRect) -> CGImage? {
        bits(for: stroke, grain: grain, in: box).flatMap(image(of:))
    }

    /// The mask `bits` say, as an image.
    static func image(of bits: Bits) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bits.data) as CFData) else { return nil }
        return CGImage(
            maskWidth: bits.width,
            height: bits.height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bits.bytesPerRow,
            provider: provider,
            decode: nil,
            shouldInterpolate: false
        )
    }

    /// The mask over `box`, or `nil` when there is nothing to build it from.
    static func bits(for stroke: Stroke, grain: StrokeGrain, in box: CGRect) -> Bits? {
        guard grain != .solid, stroke.points.count > 1 else { return nil }
        // A box is a page's worth of units at most. Checked as a double,
        // before `Int(_:)` — which traps on what is not a number or too
        // big — and before a map of its area is allocated.
        let side = Double(StrokeStreak.maximumSide)
        guard box.width.isFinite, box.height.isFinite,
              box.width >= 1, box.height >= 1, box.width <= side, box.height <= side,
              box.width * box.height <= Double(StrokeStreak.maximumUnits)
        else { return nil }
        let width = Int(box.width), height = Int(box.height)
        if grain == .streak {
            let ink = StrokeStreak.ink(of: stroke, in: box, width: width, height: height)
            guard ink.count == width * height else { return nil }
            return bits(width: width, height: height) { _, _, index in ink[index] }
        }
        guard let map = pressureMap(of: stroke, in: box, width: width, height: height) else { return nil }
        let textures = GrainTextures.shared
        let originX = Int(box.minX), originY = Int(box.minY)
        // The rule for one unit, chosen once: whether the unit at `(x, y)`
        // under the pressure `step` is ink.
        let isInk: (_ x: Int, _ y: Int, _ step: Int) -> Bool
        switch grain {
        case .solid, .streak:
            return nil
        case .stamp:
            isInk = { x, y, step in
                let family = familyByStep[step]
                let pair = tileVariants(x: x, y: y, salt: stampSalt)
                return textures.isInk(family: family, variant: pair.first, x: x, y: y)
                    || textures.isInk(family: family, variant: pair.second, x: x, y: y)
            }
        case .noise:
            isInk = { x, y, step in placeNoise(x: x, y: y) < densityByStep[step] }
        case .bristle:
            isInk = { x, y, step in placeNoise(x: x, y: y) < bristleDensityByStep[step] }
        case .scratch:
            let drawnWidth = stroke.lineWidth
            isInk = { x, y, step in
                StrokeScratch.isInk(
                    x: x, y: y, pressure: Double(step) / Double(pressureSteps - 1),
                    width: drawnWidth, textures: textures
                )
            }
        }
        return bits(width: width, height: height) { column, row, index in
            let byte = map[index]
            return byte != 0 && isInk(originX + column, originY + row, Int(byte) - 1)
        }
    }

    /// The hash salts of the first pencil's tile pairs and of the noise of
    /// the second pencil and the brush.
    static let stampSalt: UInt64 = 0x7374_616D_7074_696C
    static let noiseSalt: UInt64 = 0x6772_6170_6869_7465

    /// Which two of the four tile variants lay the unit at `(x, y)`.
    ///
    /// The page is cut into cells of 64 units, a tile's side, aligned with
    /// the tiles; every cell takes two different variants, so that neighbouring
    /// cells do not repeat one picture and every unit has two tiles over it:
    ///
    /// ```
    /// h      = GrainHash.hash(floor(x / 64), floor(y / 64), salt)
    /// first  = h & 3
    /// second = (first + 1 + (h >> 2) % 3) & 3
    /// ```
    ///
    /// A grain that wants one tile takes `first`.
    static func tileVariants(x: Int, y: Int, salt: UInt64) -> (first: Int, second: Int) {
        let cellX = Int64(x >> 6), cellY = Int64(y >> 6)
        let hash = GrainHash.hash(cellX, cellY, salt: salt)
        let first = Int(hash & 3)
        let second = (first + 1 + Int((hash >> 2) % 3)) & 3
        return (first, second)
    }

    /// A number in `[0, 1)` fixed by the unit's place on the page:
    /// `GrainHash.unit(x, y, noiseSalt)`. The same unit answers the same
    /// whoever draws over it, which is what makes two pencils' bands agree
    /// and a page render the same twice.
    static func placeNoise(x: Int, y: Int) -> Double {
        GrainHash.unit(Int64(x), Int64(y), salt: noiseSalt)
    }

    /// The mask of a box `width` by `height` units, a unit ink where `isInk`
    /// says so.
    private static func bits(
        width: Int,
        height: Int,
        isInk: (_ column: Int, _ row: Int, _ index: Int) -> Bool
    ) -> Bits {
        // One bit a pixel, set where the paper shows: an image mask paints
        // where its sample is nought. Starts all paper, and every inked
        // texel clears its square of bits.
        let maskWidth = width * texelPixels, maskHeight = height * texelPixels
        let bytesPerRow = (maskWidth + 7) / 8
        var mask = [UInt8](repeating: 0xFF, count: bytesPerRow * maskHeight)
        for row in 0..<height {
            for column in 0..<width {
                guard isInk(column, row, row * width + column) else { continue }
                for pixelRow in (row * texelPixels)..<((row + 1) * texelPixels) {
                    for pixelColumn in (column * texelPixels)..<((column + 1) * texelPixels) {
                        mask[pixelRow * bytesPerRow + (pixelColumn >> 3)] &= ~(0x80 >> UInt8(pixelColumn & 7))
                    }
                }
            }
        }
        return Bits(width: maskWidth, height: maskHeight, bytesPerRow: bytesPerRow, data: mask)
    }

    /// How finely a byte of the map holds the pressure: nought is outside
    /// the stroke, the rest the steps from no pressure to full.
    private static let pressureSteps = 254

    /// The calibration read once per step rather than once per unit: a
    /// stroke's box is tens of thousands of units, and the tables do not
    /// change between them.
    private static let densityByStep: [Double] = (0..<pressureSteps).map {
        Calibration.noiseDensity(pressure: Double($0) / Double(pressureSteps - 1))
    }
    private static let bristleDensityByStep: [Double] = (0..<pressureSteps).map {
        Calibration.brushDensity(pressure: Double($0) / Double(pressureSteps - 1))
    }
    private static let familyByStep: [GrainTextures.Family] = (0..<pressureSteps).map {
        Calibration.stampFamily(pressure: Double($0) / Double(pressureSteps - 1))
    }

    /// The stroke drawn into a byte a unit: nought outside, and inside the
    /// pressure of the segment that covers it.
    ///
    /// For a port: segment `i` runs from point `i` to point `i + 1` and
    /// carries `byte = 1 + round(p · 253)`, `p` the mean of its two ends'
    /// pressures as shares of full. It covers every unit whose centre lies
    /// within `max(w₀, w₁) / 2 + 1` of the segment — a capsule a unit wider
    /// on each side than the stroke there: the contour is clipped
    /// separately, so a byte past the edge costs nothing, while a unit the
    /// capsule missed would come out as paper. Segments are laid in order,
    /// and a later one overwrites an earlier one where they overlap.
    private static func pressureMap(of stroke: Stroke, in box: CGRect, width: Int, height: Int) -> [UInt8]? {
        guard box.minX.isFinite, box.minY.isFinite else { return nil }
        var map = [UInt8](repeating: 0, count: width * height)
        let originX = Double(box.minX), originY = Double(box.minY)
        let points = stroke.points
        for index in 0..<(points.count - 1) {
            let from = points[index], to = points[index + 1]
            let pressure = (from.pressureShare + to.pressureShare) / 2
            let byte = UInt8(1 + Int((pressure * Double(pressureSteps - 1)).rounded()))
            let radius = max(from.lineWidth, to.lineWidth) / 2 + 1
            let ax = Double(from.x), ay = Double(from.y)
            let ex = Double(to.x) - ax, ey = Double(to.y) - ay
            let squared = ex * ex + ey * ey
            guard ax.isFinite, ay.isFinite, squared.isFinite,
                  let rows = cells(min(ay, ay + ey) - radius - originY, max(ay, ay + ey) + radius - originY, count: height),
                  let columns = cells(min(ax, ax + ex) - radius - originX, max(ax, ax + ex) + radius - originX, count: width)
            else { continue }
            for row in rows {
                let cy = originY + Double(row) + 0.5 - ay
                for column in columns {
                    let cx = originX + Double(column) + 0.5 - ax
                    let tau = squared > 0 ? min(max((cx * ex + cy * ey) / squared, 0), 1) : 0
                    let qx = cx - ex * tau, qy = cy - ey * tau
                    if qx * qx + qy * qy <= radius * radius { map[row * width + column] = byte }
                }
            }
        }
        return map
    }

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
