// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines

// What a stroke becomes when it is drawn — how it is laid over the page, how
// wide its line is, where it stands once its anchor is spent. None of it is in
// the file: the file carries a raw width, a palette index and a tool number,
// and every number below is that turned into ink. It lives here rather than
// beside the parser: a package that says it does not draw has no business
// holding the ratios drawing is made of.

/// How a stroke is laid over what is already on the page.
///
/// Read out of the graphics states of an exported PDF rather than
/// chosen:
///
/// ```
///   /FXE1  BM Normal,  ca 1          the ordinary pens — the marker included
///   /FXE2  BM Darken,  ca 1          the highlighter
///   /FXE3  BM Darken,  ca .25098     the shader
/// ```
///
/// Darken, not an alpha: an alpha lightens the text under the band instead
/// of leaving it be. The marker does not darken at all: `marker2` draws
/// opaquely with the pen's own palette.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum StrokeBlend: Sendable, Hashable {
    case normal
    case darken
    /// `Darken` at a quarter — the shader's state. The
    /// shader's own `argb` carries `0x40` in its alpha byte, which is the
    /// 0.251 of this very graphics state.
    case darkenFaint

    public var alpha: Double {
        switch self {
        case .normal, .darken: 1
        case .darkenFaint: InkScale.faintAlpha
        }
    }

    /// Whether the stroke darkens what is under it rather than covering it.
    public var darkens: Bool { self != .normal }
}

public extension Stroke {
    /// The anchor is spent in the moving: a placed stroke stands in the sheet's
    /// coordinates like any other, and placing it a second time would move it
    /// twice.
    func placed(x: Double, y: Double) -> Stroke {
        Stroke(
            tool: tool,
            color: color,
            thicknessScale: thicknessScale,
            points: points.map {
                StrokePoint(
                    x: $0.x + Float(x),
                    y: $0.y + Float(y),
                    width: $0.width,
                    pressure: $0.pressure,
                    speed: $0.speed
                )
            },
            argb: argb,
            id: id,
            sourceId: sourceId
        )
    }

    /// The line width to draw with, in page units.
    ///
    /// The file's width divided by `InkScale.unitsPerRawWidth`, and nothing
    /// else.
    ///
    /// `thicknessScale` has no business here: it is the number of the setting
    /// in the pen's menu — 1, 2 or 3 — and not a multiplier. Whatever it does to
    /// the line is already in `width`.
    ///
    /// The average is a single number for a stroke whose width is not one:
    /// see `hasVaryingWidth`, and `StrokePoint.lineWidth` for the width taken
    /// point by point.
    var lineWidth: Double {
        guard !points.isEmpty else { return InkScale.minimumStrokeWidth }
        let average = Double(points.reduce(Float(0)) { $0 + $1.width }) / Double(points.count)
        return Self.clamp(average / InkScale.unitsPerRawWidth)
    }

    /// Whether the width changes along the stroke.
    ///
    /// It does for five tools of nine and stands still for four — fineliner,
    /// highlighter (always 120), mechanical pencil and marker — checked on
    /// straight lines and on curves that turn right round. Constant width is
    /// not a stroked path: the pencil and the marker stay filled
    /// (`PenTool.isStroked`).
    var hasVaryingWidth: Bool {
        guard let first = points.first?.width else { return false }
        return points.contains { $0.width != first }
    }

    /// A width held between the two bounds of `InkScale`. A NaN out of a
    /// float32 is not a thin stroke but no width at all, so it takes the floor
    /// rather than the ceiling.
    ///
    /// Internal on purpose. It was internal in the package it came from, and
    /// a member of a `public extension` is public unless it says otherwise —
    /// which would have made a rounding helper part of the API by accident.
    internal static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return InkScale.minimumStrokeWidth }
        return min(
            max(width, InkScale.minimumStrokeWidth),
            InkScale.maximumStrokeWidth
        )
    }
}

public extension Stroke {
    /// The stroke with the widths an exported PDF draws, where they are
    /// not the widths the file carries.
    ///
    /// Two tools differ. The marker comes out at 0.74 of its width. The
    /// brush comes out at 0.72 of its width when pressed, and narrower the
    /// lighter the touch — nothing at all below a fifth of full pressure,
    /// whatever the file says: its width field does not carry the pressure
    /// the way a ballpoint's does, and the export draws from the pressure.
    /// Every other tool draws at its width and is handed back as it is.
    var drawn: Stroke {
        let scale = Calibration.drawnWidthScale(for: tool)
        guard scale != 1 else { return self }
        let bristle = tool?.grain == .bristle
        return Stroke(
            tool: tool,
            color: color,
            thicknessScale: thicknessScale,
            points: points.map { point in
                let opening = bristle ? Calibration.brushWidthShare(pressure: point.pressureShare) : 1
                return StrokePoint(
                    x: point.x,
                    y: point.y,
                    width: point.width * Float(scale * opening),
                    pressure: point.pressure,
                    speed: point.speed
                )
            },
            argb: argb,
            anchor: anchor,
            id: id,
            sourceId: sourceId
        )
    }
}

public extension StrokePoint {
    /// The width at this point, in page units.
    ///
    /// The one place the file's number becomes a thickness. The same ratio as
    /// `Stroke.lineWidth`, only not averaged away: the
    /// file may say 18 at the start of a stroke and 27 at its end, and the
    /// average would say 21.4 at both.
    var lineWidth: Double { Stroke.clamp(Double(width) / InkScale.unitsPerRawWidth) }

    /// The pressure as a share of full, `0…1`.
    ///
    /// The file carries it as a byte — version two of the point writes the
    /// byte itself, version one a fraction the parser scales back up — and
    /// the drawing reads that byte back as `pressure / 255`. Held
    /// to the range: a value the file lies about is a pressure it never
    /// measured, not a texture it never had.
    var pressureShare: Double {
        guard pressure.isFinite else { return 0 }
        return min(max(Double(pressure) / 255, 0), 1)
    }
}
