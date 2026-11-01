// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import ImageIO
import RMMarks

/// Original procedural stamp textures for the first pencil: twelve tiles
/// of 64 × 64, three families of four variants, black
/// where the pencil leaves graphite and white where the paper shows.
///
/// `Scripts/generate-grain.py` generates all 16 grain PNGs procedurally;
/// rerunning it reproduces them.
///
/// Loaded once and kept — a page of pencil asks for them at every stroke —
/// and kept as bytes rather than images, because they are read texel by
/// texel while a mask is built, never drawn as pictures.
final class GrainTextures: Sendable {
    /// The three densities of one pencil, told apart by pressure.
    enum Family: Int, CaseIterable, Sendable {
        case light, base, hard

        /// The resource's suffix: `pencil0-light`, `pencil0`, `pencil0-hard`.
        var suffix: String {
            switch self {
            case .light: "-light"
            case .base: ""
            case .hard: "-hard"
            }
        }
    }

    /// A tile's side, in texels; one texel is one unit on the page.
    static let side = 64
    /// The variants of each family. Which of them lie over a unit is a hash
    /// of the 64-unit cell of the page it falls in
    /// (`StrokeGrainMask.tileVariants`), so that the repeat of a tile does
    /// not read.
    static let variants = 4

    static let shared = GrainTextures()

    /// `tiles[family][variant]`, row by row from the top, non-zero where
    /// there is ink.
    private let tiles: [[[UInt8]]]

    /// The first ballpoint's four generated `marker%1.png` tiles:
    /// black nearly everywhere, white scratches between —
    /// non-zero where there is ink.
    private let markers: [[UInt8]]

    private init() {
        markers = (0..<Self.variants).map { variant in
            let resource = "marker\(variant)"
            if let texels = Self.load(resource) { return texels }
            // Missing, the ballpoint draws solid: the scratches are a few
            // units in a hundred, the line itself is the point.
            RMRenderLog.templateError("grain texture \(resource) is missing; the ballpoint draws solid")
            return [UInt8](repeating: 1, count: Self.side * Self.side)
        }
        tiles = Family.allCases.map { family in
            (0..<Self.variants).map { variant in
                let resource = "pencil\(variant)\(family.suffix)"
                if let texels = Self.load(resource) { return texels }
                // A missing tile draws the pencil solid rather than blank:
                // a band of nothing would hide the user's writing, and the
                // solid band is the picture this renderer drew before the
                // textures came.
                RMRenderLog.templateError("grain texture \(resource) is missing; the pencil draws solid")
                return [UInt8](repeating: 1, count: Self.side * Self.side)
            }
        }
    }

    /// Whether the texel at `(x, y)` of the page is graphite. Any integer
    /// will do: the tile repeats across the whole plane, negative
    /// coordinates included.
    func isInk(family: Family, variant: Int, x: Int, y: Int) -> Bool {
        let row = y & (Self.side - 1)
        let column = x & (Self.side - 1)
        return tiles[family.rawValue][variant & (Self.variants - 1)][row * Self.side + column] != 0
    }

    /// Whether the first ballpoint's tile `variant` is ink at `(x, y)`.
    func isMarkerInk(variant: Int, x: Int, y: Int) -> Bool {
        markers[variant & (Self.variants - 1)][(y & (Self.side - 1)) * Self.side + (x & (Self.side - 1))] != 0
    }

    /// Whether a tile actually travels with the package. Asked by the tests:
    /// a missing file does not break the drawing, so the check has to be
    /// somebody's, and `Bundle.module` belongs to this package alone.
    static func ships(_ resource: String) -> Bool {
        Bundle.module.url(forResource: resource, withExtension: "png", subdirectory: "Grain") != nil
    }

    private static func load(_ resource: String) -> [UInt8]? {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "png", subdirectory: "Grain"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == side, image.height == side
        else { return nil }
        var gray = [UInt8](repeating: 0, count: side * side)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // The bitmap's rows run from the top while the context counts from
        // the bottom, so the texture reads top-down as the file has it. The
        // tiles are two-valued, black and white; the middle is the threshold
        // the export's own vectoriser uses.
        return gray.map { $0 < 128 ? 1 : 0 }
    }
}
