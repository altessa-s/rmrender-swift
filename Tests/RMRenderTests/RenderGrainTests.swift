// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
@testable import RMRender
import Testing

// The grain of the pencils: black spots with paper between, at the share of
// ink the tablet's export shows for the pressure, and the same spots every
// time the page is drawn.

/// A horizontal band of one tool, sampled every six units the way the corpus
/// draws its rows, 24 units wide. `x` is counted from the middle of the sheet,
/// as the page counts it: on a sheet 800 wide, −300 is the pixel column 100.
/// `pressure` is the file's byte, 0…255.
private func band(_ tool: PenTool, pressure: Float, y: Float = 200, from: Float = -300, to: Float = 300) -> Stroke {
    Stroke(
        tool: tool,
        color: .black,
        thicknessScale: 1,
        points: stride(from: from, through: to, by: 6).map { StrokePoint(x: $0, y: y, width: 96, pressure: pressure) }
    )
}

private let sheet = CGSize(width: 800, height: 400)

/// The page drawn at one pixel to a unit, as the red channel: 0 is black.
private func raster(_ strokes: [Stroke]) throws -> (width: Int, height: Int, red: [UInt8]) {
    let page = RMPage(strokes: strokes, skippedBlocks: 0)
    let image = try PageRenderer.image(page: page, pageSize: sheet, scale: 1)
    let data = try #require(image.dataProvider?.data as Data?)
    var red = [UInt8](repeating: 255, count: image.width * image.height)
    for row in 0..<image.height {
        for column in 0..<image.width {
            red[row * image.width + column] = data[row * image.bytesPerRow + column * 4]
        }
    }
    return (image.width, image.height, red)
}

/// The share of dark pixels inside a box, counted from the top-left as the
/// page counts.
private func share(
    of raster: (width: Int, height: Int, red: [UInt8]),
    x: ClosedRange<Int>,
    y: ClosedRange<Int>
) -> Double {
    var dark = 0, all = 0
    for row in y {
        for column in x {
            all += 1
            if raster.red[row * raster.width + column] < 128 { dark += 1 }
        }
    }
    return Double(dark) / Double(all)
}

/// Well inside the band: six units either side of its middle, away from
/// both ends. The band is drawn at 0.69 of its 24 — 16.6 wide — the way
/// the tablet draws the second pencil, so the window stops short of its
/// edges.
private let inside = (x: 130...670, y: 194...206)

@Test("The twelve pencil tiles travel with the package")
func grainTilesShip() {
    for variant in 0..<4 {
        for suffix in ["", "-light", "-hard"] {
            #expect(GrainTextures.ships("pencil\(variant)\(suffix)"), "pencil\(variant)\(suffix)")
        }
    }
}

// The export's own row at full pressure is all but solid, 0.98 of it ink; at
// half, 0.46; at none, a scattering of single spots. The tolerance is the
// noise of a hash over a band of eleven thousand units.
@Test("The second pencil is noise at the density the pressure sets")
func noiseFollowsThePressure() throws {
    let full = try raster([band(.pencil2, pressure: 255)])
    let fullShare = share(of: full, x: inside.x, y: inside.y)
    #expect(fullShare > 0.95 && fullShare < 0.995, "full pressure: \(fullShare)")

    let half = try raster([band(.pencil2, pressure: 128)])
    let halfShare = share(of: half, x: inside.x, y: inside.y)
    #expect(halfShare > 0.40 && halfShare < 0.52, "half pressure: \(halfShare)")

    let none = try raster([band(.pencil2, pressure: 0)])
    let noneShare = share(of: none, x: inside.x, y: inside.y)
    #expect(noneShare > 0 && noneShare < 0.04, "no pressure: \(noneShare)")

    // What is there is black, not grey — the whole point of a grain over a
    // thinned band.
    #expect(inside.y.contains { row in inside.x.contains { full.red[row * full.width + $0] == 0 } })
}

@Test("The mechanical pencil lays the same spots as the second pencil")
func mechanicalPencilSharesTheNoise() throws {
    let pencil = try raster([band(.pencil2, pressure: 128)])
    let mechanical = try raster([band(.mechanicalPencil2, pressure: 128)])
    #expect(pencil.red == mechanical.red)
}

// Half pressure is the `-light` family, whose tiles are about a seventh ink
// and lie two to a unit — exported PDFs carry about 0.23 there; full
// pressure is `-hard`, near seven tenths a tile and near nine tenths two of
// them.
@Test("The first pencil tiles the stamp texture its pressure names")
func stampFollowsThePressure() throws {
    let light = try raster([band(.pencil1, pressure: 128)])
    let lightShare = share(of: light, x: inside.x, y: inside.y)
    #expect(lightShare > 0.16 && lightShare < 0.34, "half pressure: \(lightShare)")

    let hard = try raster([band(.pencil1, pressure: 255)])
    let hardShare = share(of: hard, x: inside.x, y: inside.y)
    #expect(hardShare > 0.78 && hardShare < 0.95, "full pressure: \(hardShare)")

    // The first pencil ends round: its first point stands at column 100,
    // the cap reaches half the width — 12 — before it, and nothing further.
    let cap = share(of: hard, x: 92...98, y: 197...203)
    #expect(cap > 0.5, "end cap: \(cap)")
    let beyond = share(of: hard, x: 78...86, y: 190...210)
    #expect(beyond < 0.01, "past the cap: \(beyond)")

    // The tile repeats at its side: the band's row 64 units on is the same
    // row, up to the pair of variants each cell of the page takes.
    var same = 0, all = 0
    for row in inside.y {
        for column in 130...600 {
            all += 1
            if hard.red[row * hard.width + column] == hard.red[row * hard.width + column + 64] { same += 1 }
        }
    }
    #expect(Double(same) / Double(all) > 0.7, "period of 64: \(Double(same) / Double(all))")
}

// A stroke running down the page, pressing harder as it goes: the map that
// carries the pressure counts its rows the way the page does, or the dense
// end would come out at the top.
@Test("The pressure lands on the unit it was written at")
func pressureIsNotUpsideDown() throws {
    let points = stride(from: Float(50), through: 350, by: 6).map { y in
        StrokePoint(x: 0, y: y, width: 96, pressure: (y - 50) / 300 * 255)
    }
    let stroke = Stroke(tool: .pencil2, color: .black, thicknessScale: 1, points: points)
    let image = try raster([stroke])
    // Six units either side of the middle: the band is 24 drawn at 0.69.
    let top = share(of: image, x: 394...406, y: 70...130)
    let bottom = share(of: image, x: 394...406, y: 270...330)
    #expect(top < 0.2, "light end: \(top)")
    #expect(bottom > 0.8, "heavy end: \(bottom)")
}

@Test("A page of pencil draws the same twice")
func grainIsRepeatable() throws {
    let strokes = [band(.pencil2, pressure: 180), band(.pencil1, pressure: 200, y: 300)]
    #expect(try raster(strokes).red == raster(strokes).red)
}

@Test("A tool without grain is still a solid band")
func solidToolsStaySolid() throws {
    let ballpoint = try raster([band(.ballpoint2, pressure: 128)])
    #expect(share(of: ballpoint, x: inside.x, y: inside.y) > 0.99)
}

// The overlay draws the same picture the renderer does: the contour becomes
// the clip and the grain a stencil painted through it, one object a stroke.
@Test("The overlay paints a grained stroke through a stencil of its own")
func markContentPaintsGrainThroughAStencil() throws {
    let box = CGRect(x: 0, y: 0, width: 300, height: 300)
    func stream(_ tool: PenTool) throws -> MarkContentStream.Result {
        try #require(
            MarkContentStream.build(RMPage(strokes: [band(tool, pressure: 128)], skippedBlocks: 0), mediaBox: box)
        )
    }
    let pencil = try stream(.pencil2)
    let text = String(decoding: pencil.content, as: UTF8.self)
    #expect(pencil.images.count == 1)
    #expect(text.contains("W n\n"))
    #expect(text.contains("cm /\(pencil.images[0].name) Do Q"))
    #expect(!text.contains("f Q"))
    // The stencil is the stroke's box at two pixels a unit: 600 units long
    // and 24 wide drawn at 0.69 — 16.6 — plus half the drawn width for the
    // round of each cap and a unit of margin either side, whole texels.
    #expect(pencil.images[0].width == 620 * StrokeGrainMask.texelPixels)
    #expect(pencil.images[0].height == 20 * StrokeGrainMask.texelPixels)
    #expect(pencil.images[0].bits.count == (pencil.images[0].width + 7) / 8 * pencil.images[0].height)

    let stamped = try stream(.pencil1)
    #expect(stamped.images.count == 1)

    let streaked = try stream(.ballpoint2)
    #expect(streaked.images.count == 1)

    let scratched = try stream(.ballpoint1)
    #expect(scratched.images.count == 1)

    let brush = try stream(.paintbrush1)
    #expect(brush.images.isEmpty)
    #expect(String(decoding: brush.content, as: UTF8.self).contains("f Q"))
}

// The export draws the marker at 0.74 of the width the file carries, read
// off a notebook written on the tablet; the band is solid inside.
@Test("The marker is drawn narrower than its width, and solid")
func markerIsNarrowedAndSolid() throws {
    let image = try raster([band(.marker2, pressure: 128)])
    // 24 units in the file become 17.8 drawn: rows within ±8 are ink, rows
    // beyond ±10 are paper.
    #expect(share(of: image, x: inside.x, y: 193...207) > 0.99)
    #expect(share(of: image, x: inside.x, y: 210...214) < 0.01)
    #expect(share(of: image, x: inside.x, y: 186...190) < 0.01)
}

// The brush opens with pressure: nothing below a fifth of full, a scatter
// of dots in a narrow band at a quarter — a tenth of a solid band's ink, as
// on a notebook written on the tablet — and a solid band at 0.72 of its
// width once pressed.
@Test("The brush opens with pressure")
func brushOpensWithPressure() throws {
    let solid = try raster([band(.ballpoint2, pressure: 128)])
    let solidInk = share(of: solid, x: inside.x, y: 176...224)

    let untouched = try raster([band(.paintbrush2, pressure: 40)])
    #expect(share(of: untouched, x: inside.x, y: 176...224) == 0)

    let light = try raster([band(.paintbrush2, pressure: 64)])
    let lightInk = share(of: light, x: inside.x, y: 176...224)
    #expect(lightInk / solidInk > 0.04 && lightInk / solidInk < 0.18, "light: \(lightInk / solidInk)")
    // Narrow: nothing beyond four units from the middle.
    #expect(share(of: light, x: inside.x, y: 205...224) < 0.01)
    #expect(share(of: light, x: inside.x, y: 176...195) < 0.01)

    let pressed = try raster([band(.paintbrush2, pressure: 255)])
    #expect(share(of: pressed, x: inside.x, y: 193...207) > 0.99)
    #expect(share(of: pressed, x: inside.x, y: 210...214) < 0.01)
}
