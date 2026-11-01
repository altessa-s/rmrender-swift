// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// How a tool's ink is broken into grain — black where the ink sits and
/// paper between.
///
/// Neither is an opacity. Thinning a solid band to the same share of ink
/// gives the right weight and the wrong picture — the eye reads the darkest
/// spot, and an exported PDF's darkest spot is full black.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum StrokeGrain: Sendable, Hashable {
    /// Ink laid whole.
    case solid
    /// The first pencil: the generated `pencil%d[-light|-hard].png` tiles,
    /// one texel to a unit, two of them over every unit; the family by
    /// pressure (`Calibration.stampFamily`), the pair by the 64-unit cell
    /// of the page (`StrokeGrainMask.tileVariants`).
    case stamp
    /// The second pencil and the mechanical pencil: white noise keyed to the
    /// place on the page, its density by pressure
    /// (`Calibration.noiseDensity`).
    case noise
    /// The brush: a band that opens with pressure, and noise inside it whose
    /// density opens with pressure too (`Calibration.brushDensity`).
    case bristle
    /// The second ballpoint: hairlines along the stroke, filling in with
    /// pressure and thinning with speed. See `StrokeStreak`.
    case streak
    /// The first ballpoint: skips of the ball under a light touch, hidden
    /// by a broad line. See `StrokeScratch`.
    case scratch
}
