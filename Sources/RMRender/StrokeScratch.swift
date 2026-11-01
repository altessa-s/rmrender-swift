// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import RMLines

/// The first ballpoint's grain: a ball that skips under a light touch.
///
/// Pressed lightly, a ballpoint leaves short skips where the ball lost
/// contact; pressed firmly, it lays a solid line. A narrow line shows the
/// skips, a wide one hides them — the neighbouring passes of a broad line
/// fill one another's gaps. The shapes of the skips are the generated
/// `marker%d.png` tiles (white scratches on black, one texel to a unit,
/// laid on the page with `StrokeGrainMask.tileVariants`), and how many of
/// a tile's scratches open is decided here.
///
/// The rule, for a port. A unit `(x, y)` inside the stroke, carrying the
/// pressure `p` (a share of full) of the stroke there, in a stroke whose
/// mean drawn width is `w` units, is paper exactly when
///
/// ```
/// tile(variant(x, y), x, y) is a scratch          (white texel)
/// and GrainHash.unit(x, y, salt) < skipShare(p, w)
/// ```
///
/// and ink otherwise.
enum StrokeScratch {
    /// The hash salt of the skips.
    static let salt: UInt64 = 0x6261_6C6C_736B_6970

    /// The pressure, as a share of full, below which the ball skips as much
    /// as it ever does, and the one from which it no longer skips.
    static let lightPressure = 0.5
    static let firmPressure = 0.85

    /// The width, in units, up to which every scratch the pressure opens
    /// shows; a wider line shows `closingWidth / w` of them.
    static let closingWidth = 3.0

    /// The share of a tile's scratches that open:
    ///
    /// ```
    /// skipShare(p, w) = (1 − smoothstep(lightPressure, firmPressure, p)) · min(1, closingWidth / w)
    /// ```
    ///
    /// One at a light touch on a hairline, nought from `firmPressure` up.
    /// With the tiles' scratches a tenth of their area, a light line six
    /// units wide comes out about 4.5 % paper, twelve wide 2.3 %, twenty-four
    /// wide 1.1 % — the shares exported PDFs show.
    static func skipShare(pressure: Double, width: Double) -> Double {
        let p = pressure.isFinite ? pressure : 0
        let closing = width.isFinite && width > closingWidth ? closingWidth / width : 1
        return (1 - StrokeStreak.smoothstep(lightPressure, firmPressure, p)) * closing
    }

    /// Whether the unit at `(x, y)` is ink under the rule above.
    static func isInk(x: Int, y: Int, pressure: Double, width: Double, textures: GrainTextures) -> Bool {
        let share = skipShare(pressure: pressure, width: width)
        guard share > 0 else { return true }
        let variant = StrokeGrainMask.tileVariants(x: x, y: y, salt: salt).first
        if textures.isMarkerInk(variant: variant, x: x, y: y) { return true }
        return GrainHash.unit(Int64(x), Int64(y), salt: salt) >= share
    }
}
