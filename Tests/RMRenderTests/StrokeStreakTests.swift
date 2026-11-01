// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import RMLines
@testable import RMRender
import Testing

// The ballpoints' grains, checked by what they must do rather than by what
// they happen to draw: deterministic, in range, filling in with pressure,
// thinning with speed, following the stroke, and bounded in their work.

@Test("The lattice hash is deterministic, in range and salted")
func grainHashBehaves() {
    for (x, y) in [(Int64(0), Int64(0)), (-1, 7), (1 << 40, -(1 << 40)), (123_456, 654_321)] {
        let value = GrainHash.unit(x, y, salt: 1)
        #expect(value == GrainHash.unit(x, y, salt: 1))
        #expect(value >= 0 && value < 1)
    }
    // Different salts, different patterns.
    let same = (0..<256).count { GrainHash.unit(Int64($0), 3, salt: 1) == GrainHash.unit(Int64($0), 3, salt: 2) }
    #expect(same == 0)
    // Floors that cannot trap.
    #expect(GrainHash.floor(-0.5) == -1)
    #expect(GrainHash.floor(.nan) == 0)
    #expect(GrainHash.floor(.infinity) == 1 << 62)
    #expect(GrainHash.floor(-1e300) == -(1 << 62))
}

@Test("The hair noise is deterministic, in range, centred and smooth along the stroke")
func hairNoiseStatistics() throws {
    var values: [Double] = []
    for i in 0..<400 {
        for j in 0..<40 {
            let s = Double(i) * 1.37, t = Double(j) - 20.5
            let value = StrokeStreak.hairNoise(s: s, t: t)
            #expect(value == StrokeStreak.hairNoise(s: s, t: t))
            values.append(value)
        }
    }
    #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
    let mean = values.reduce(0, +) / Double(values.count)
    #expect(abs(mean - 0.5) < 0.05, "mean \(mean)")
    let low = try #require(values.min()), high = try #require(values.max())
    #expect(low < 0.1 && high > 0.9, "range \(low)...\(high)")

    // Along a hair a step of a unit moves the noise by little; across, the
    // next hair is unrelated.
    var along = 0.0, across = 0.0
    for i in 0..<500 {
        let s = Double(i) * 3.1
        along += abs(StrokeStreak.hairNoise(s: s, t: 0.5) - StrokeStreak.hairNoise(s: s + 1, t: 0.5))
        across += abs(StrokeStreak.hairNoise(s: s, t: 0.5) - StrokeStreak.hairNoise(s: s, t: 1.5))
    }
    #expect(along / 500 < 0.06, "along \(along / 500)")
    #expect(across / 500 > 0.2, "across \(across / 500)")
    // Not a place: the top of the range, which no threshold is below.
    #expect(StrokeStreak.hairNoise(s: .nan, t: 0) == 1)
}

@Test("The ink threshold rises with pressure, falls with speed and stays in range")
func streakThreshold() {
    var previous = -1.0
    for step in 0...255 {
        let value = StrokeStreak.threshold(pressure: Double(step) / 255, speed: 0)
        #expect(value >= previous)
        #expect(value > 0.4 && value <= 1)
        previous = value
    }
    #expect(StrokeStreak.threshold(pressure: 0.5, speed: 0) == 1, "whole from half pressure")
    #expect(StrokeStreak.threshold(pressure: 0, speed: 0) < 0.6, "a feather touch is hairs")
    previous = 2
    for speed in stride(from: 0.0, through: 400, by: 4) {
        let value = StrokeStreak.threshold(pressure: 1, speed: speed)
        #expect(value <= previous)
        previous = value
    }
    #expect(StrokeStreak.threshold(pressure: 1, speed: 400) < 0.9, "a fast stroke thins")
    #expect(StrokeStreak.threshold(pressure: .nan, speed: .nan) > 0.4)
}

private func line(pressure: Float, speed: Float = 0, reversed: Bool = false) -> Stroke {
    var points = (0...100).map {
        StrokePoint(x: Float(-300 + 6 * $0), y: 0, width: 48, pressure: pressure, speed: speed)
    }
    if reversed { points.reverse() }
    return Stroke(tool: .ballpoint2, color: .black, thicknessScale: 1, points: points)
}

private func inkShare(_ stroke: Stroke) -> (share: Double, ink: [Bool]) {
    let box = CGRect(x: -290, y: -6, width: 580, height: 12)
    let ink = StrokeStreak.ink(of: stroke, in: box, width: 580, height: 12)
    return (Double(ink.count { $0 }) / Double(ink.count), ink)
}

@Test("A second ballpoint is hairs at a light touch and whole at a firm one")
func streakFillsWithPressure() {
    #expect(line(pressure: 1).grain == .streak)
    #expect(inkShare(line(pressure: 255)).share == 1)
    let light = inkShare(line(pressure: 32)).share
    let lighter = inkShare(line(pressure: 0)).share
    #expect(light > 0.5 && light < 0.85, "share \(light)")
    #expect(lighter < light)
    // Speed thins even a firm line.
    let fast = inkShare(line(pressure: 255, speed: 200)).share
    #expect(fast < 0.98 && fast > 0.7, "fast \(fast)")
}

@Test("The hairs run along the stroke, and drawing it the other way lays others")
func streakFollowsTheStroke() {
    let forward = inkShare(line(pressure: 32)).ink
    var along = 0, across = 0, pairs = 0
    for row in 0..<11 {
        for column in 0..<579 {
            let here = forward[row * 580 + column]
            along += here == forward[row * 580 + column + 1] ? 1 : 0
            across += here == forward[(row + 1) * 580 + column] ? 1 : 0
            pairs += 1
        }
    }
    #expect(Double(along) / Double(pairs) > 0.9)
    #expect(Double(across) < Double(along))
    #expect(inkShare(line(pressure: 32, reversed: true)).ink != forward)
}

@Test("The grain mask of a second ballpoint is built from the hairs")
func streakMask() throws {
    let stroke = line(pressure: 32)
    let box = try #require(StrokeGrainMask.box(of: stroke))
    let bits = try #require(StrokeGrainMask.bits(for: stroke, grain: .streak, in: box))
    #expect(bits.width == Int(box.width) * StrokeGrainMask.texelPixels)
    // Some paper, some ink.
    #expect(bits.data.contains { $0 != 0xFF })
    #expect(bits.data.contains { $0 != 0x00 })
}

@Test("Placing and drawing a stroke keep its points' speed, which its grain reads")
func streakSpeedSurvivesPlacement() {
    let stroke = Stroke(
        tool: .ballpoint2, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: 0, y: 0, width: 24, pressure: 255, speed: 120),
            StrokePoint(x: 60, y: 0, width: 24, pressure: 255, speed: 120),
        ]
    )
    #expect(stroke.placed(x: 10, y: 20).points.allSatisfy { $0.speed == 120 })
    #expect(stroke.drawn.points.allSatisfy { $0.speed == 120 })
}

@Test("A second ballpoint that never moved is a dot of its width")
func streakDot() {
    let still = StrokePoint(x: 20, y: 20, width: 48, pressure: 255)
    let dot = Stroke(tool: .ballpoint2, color: .black, thicknessScale: 1, points: [still, still])
    let ink = StrokeStreak.ink(of: dot, in: CGRect(x: 0, y: 0, width: 40, height: 40), width: 40, height: 40)
    // A disc of radius 6: about 113 units, all of them ink at full pressure.
    let count = ink.count { $0 }
    #expect(count > 100 && count < 130, "\(count) units")
    #expect(ink[20 * 40 + 20])
}

@Test("Coordinates that are no place, or far off the box, draw nothing and do not trap")
func streakSurvivesBrokenGeometry() {
    let box = CGRect(x: 0, y: 0, width: 40, height: 40)
    for broken: Float in [.nan, .infinity, -.infinity, 1e30, -1e30] {
        let stroke = Stroke(
            tool: .ballpoint2, color: .black, thicknessScale: 1,
            points: [
                StrokePoint(x: 20, y: 20, width: 24, pressure: 255),
                StrokePoint(x: broken, y: 20, width: 24, pressure: 255),
                StrokePoint(x: 20, y: broken, width: 24, pressure: 255),
            ]
        )
        let ink = StrokeStreak.ink(of: stroke, in: box, width: 40, height: 40)
        #expect(ink.count == 1600)
    }
    // A box no page has is refused before anything is allocated.
    let huge = CGRect(x: 0, y: 0, width: 1e9, height: 10)
    #expect(StrokeGrainMask.bits(for: line(pressure: 255), grain: .streak, in: huge) == nil)
}

@Test("A long diagonal costs what lies in the box, and inks only there")
func streakLongDiagonalIsClipped() {
    let stroke = Stroke(
        tool: .ballpoint2, color: .black, thicknessScale: 1,
        points: [
            StrokePoint(x: -4000, y: -4000, width: 96, pressure: 255),
            StrokePoint(x: 4000, y: 4000, width: 96, pressure: 255),
        ]
    )
    let clock = ContinuousClock()
    var ink: [Bool] = []
    let elapsed = clock.measure {
        ink = StrokeStreak.ink(of: stroke, in: CGRect(x: -10, y: -10, width: 20, height: 20), width: 20, height: 20)
    }
    #expect(elapsed < .milliseconds(200))
    // The band is 24 units wide along the diagonal: the box's corners off it
    // are paper, its centre ink.
    #expect(ink[10 * 20 + 10])
    #expect(!ink[0 * 20 + 19])
    #expect(!ink[19 * 20 + 0])
}

@Test("A box past the budget is refused before its maps are allocated")
func streakRefusesAnOversizedBox() {
    let side = StrokeStreak.maximumSide
    let tall = StrokeStreak.maximumUnits / side + 1
    let stroke = line(pressure: 255)
    #expect(StrokeStreak.ink(of: stroke, in: CGRect(x: 0, y: 0, width: side, height: tall), width: side, height: tall).isEmpty)
    let box = CGRect(x: 0, y: 0, width: Double(side), height: Double(tall))
    #expect(StrokeGrainMask.bits(for: stroke, grain: .streak, in: box) == nil)
    // At the budget itself it is drawn.
    let fits = StrokeStreak.maximumUnits / side
    #expect(StrokeStreak.ink(of: stroke, in: CGRect(x: -300, y: -6, width: side, height: fits), width: side, height: fits).count == side * fits)
}

// The first ballpoint: the ball's skips under a light touch.

@Test("Every tile cell lays two different variants, and the page reaches all four")
func tileVariantsArePairs() {
    #expect(GrainTextures.ships("marker0") && GrainTextures.ships("marker3"))
    var seen = Set<Int>()
    for cellY in -8..<8 {
        for cellX in -8..<8 {
            let pair = StrokeGrainMask.tileVariants(x: cellX * 64, y: cellY * 64, salt: 9)
            #expect(pair.first != pair.second)
            #expect((0..<4).contains(pair.first) && (0..<4).contains(pair.second))
            // One choice for the whole cell.
            let corner = StrokeGrainMask.tileVariants(x: cellX * 64 + 63, y: cellY * 64 + 63, salt: 9)
            #expect(corner == pair)
            seen.insert(pair.first)
        }
    }
    #expect(seen.count == 4)
}

@Test("The ball skips less as it is pressed and as the line widens, and not at all when firm")
func scratchSkipShare() {
    var previous = 2.0
    for step in 0...255 {
        let share = StrokeScratch.skipShare(pressure: Double(step) / 255, width: 2)
        #expect(share <= previous && share >= 0 && share <= 1)
        previous = share
    }
    #expect(StrokeScratch.skipShare(pressure: 0.85, width: 2) == 0)
    #expect(StrokeScratch.skipShare(pressure: 0.3, width: 24) < StrokeScratch.skipShare(pressure: 0.3, width: 6))
    #expect(StrokeScratch.skipShare(pressure: .nan, width: .nan) <= 1)
}

/// The share of paper the first ballpoint leaves over a 256-unit square.
private func scratchPaper(pressure: Double, width: Double) -> Double {
    let textures = GrainTextures.shared
    var paper = 0
    for y in 0..<256 {
        for x in 0..<256 where !StrokeScratch.isInk(x: x, y: y, pressure: pressure, width: width, textures: textures) {
            paper += 1
        }
    }
    return Double(paper) / 65536
}

@Test("A light first ballpoint shows skips in a thin band and closes them in a thick one")
func scratchByWidthAndPressure() {
    #expect(StrokePoint(x: 0, y: 0, width: 4, pressure: 1).pressureShare < StrokeScratch.lightPressure)
    let thin = scratchPaper(pressure: 0.5, width: 6)
    let thick = scratchPaper(pressure: 0.5, width: 24)
    // Exported PDFs of a ballpoint at half pressure: 4.6 % paper at a width
    // of 6, 0.9 % at 24.
    #expect(thin > 0.02 && thin < 0.08, "thin \(thin)")
    #expect(thick < thin && thick < 0.02, "thick \(thick)")
    #expect(scratchPaper(pressure: 0.9, width: 6) == 0)
}

@Test("The first ballpoint's mask has paper at a light touch and none at a firm one")
func scratchMask() throws {
    func stroke(_ pressure: Float) -> Stroke {
        Stroke(
            tool: .ballpoint1, color: .black, thicknessScale: 1,
            points: (0...100).map { StrokePoint(x: Float(-300 + 6 * $0), y: 500, width: 24, pressure: pressure) }
        )
    }
    #expect(stroke(1).grain == .scratch)
    let light = stroke(40), firm = stroke(255)
    let box = try #require(StrokeGrainMask.box(of: light))
    let lightBits = try #require(StrokeGrainMask.bits(for: light, grain: .scratch, in: box))
    let firmBits = try #require(StrokeGrainMask.bits(for: firm, grain: .scratch, in: box))
    // Paper inside the band: the middle row of the mask.
    let row = lightBits.height / 2
    let middle = lightBits.data[(row * lightBits.bytesPerRow + 8)..<((row + 1) * lightBits.bytesPerRow - 8)]
    #expect(middle.contains { $0 != 0 }, "a light line skips somewhere")
    let firmMiddle = firmBits.data[(row * firmBits.bytesPerRow + 8)..<((row + 1) * firmBits.bytesPerRow - 8)]
    #expect(firmMiddle.allSatisfy { $0 == 0 }, "a firm line is whole")
}
