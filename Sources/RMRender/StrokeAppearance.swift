// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines

/// What a stroke looks like on the page.
///
/// These answers do not sit on the format's own types: that would make
/// reading a file reach into drawing one. Every one of them needs the
/// palette and the tool behaviour, both matched to exported PDFs. The file says which tool and which colour index; what that
/// comes out as belongs here.
public extension Stroke {
    /// The colour to draw with: the explicit one from the file, otherwise the
    /// palette index — read as the tool itself reads it.
    var rgb: (red: Double, green: Double, blue: Double) {
        if let argb {
            return (
                red: Double((argb >> 16) & 0xFF) / 255,
                green: Double((argb >> 8) & 0xFF) / 255,
                blue: Double(argb & 0xFF) / 255
            )
        }
        // The highlighter has a palette of its own on the same indexes — the
        // marker does not: it draws with the pen's palette, opaquely.
        // Answering the highlighter with the pen's palette would put a green
        // three times too dark on the page.
        return blend.darkens ? color.highlightRGB : color.rgb
    }

    /// How the stroke is laid over what is under it. A stroke of an unknown
    /// tool is drawn plainly: covering the page is the reversible mistake,
    /// darkening it is not.
    var blend: StrokeBlend { tool?.blend ?? .normal }

    /// How opaque the stroke is.
    ///
    /// The file says so itself where it carries an explicit colour: the alpha
    /// byte of `argb`. For example, the shader of a live page carries
    /// `0x40211e1c`, and `0x40` is 0.251, exactly the `ca` of the graphics
    /// state an exported PDF gives that very stroke. Reading it here
    /// means a tool we have never seen gets its own opacity rather than the
    /// one its family was calibrated against.
    ///
    /// Nought is read as "nothing said" rather than as "invisible": a stroke
    /// that was drawn is meant to be seen, and this field is known to arrive
    /// empty — a highlight over the text of a PDF carries `ff000000`, black
    /// and opaque, where the band is yellow.
    var alpha: Double {
        if let argb {
            let value = Double((argb >> 24) & 0xFF) / 255
            if value > 0 { return value }
        }
        // Index 8 sets not only a colour but an opacity: with the
        // highlighter it draws black at a quarter, which over white paper
        // reads as grey — hence the name `grayOverlap`. Taking the colour
        // without the opacity would put solid black where an export gives
        // light grey.
        if blend.darkens, color == .grayOverlap { return InkScale.faintAlpha }
        return blend.alpha
    }

    /// Whether to stroke a line of one width or to fill a contour.
    ///
    /// The tool decides, as it does in an export. An unknown tool falls back
    /// to its widths: a contour is what a changing width needs, and a stroked
    /// line is cheaper for one that does not change.
    var isStroked: Bool { tool?.isStroked ?? !hasVaryingWidth }

    /// Whether the ink is laid solid or broken into grain, and which grain.
    /// A tool we have never seen draws solid: grain is a fact about a tool
    /// that was measured, not a default.
    var grain: StrokeGrain { tool?.grain ?? .solid }
}

/// The same for a band of text highlight: the file's own colour when it holds
/// one, the palette matched to exported PDFs otherwise.
public extension Highlight {
    /// The colour to draw with.
    ///
    /// The explicit field is taken only when it holds a colour: a yellow
    /// highlight from a live page carries
    /// `argb = ff000000` — opaque black — while an exported PDF paints it
    /// yellow. Trusting that field would multiply the page by
    /// black and blot out everything under the band.
    var rgb: (red: Double, green: Double, blue: Double) {
        if let argb, argb & 0x00FF_FFFF != 0 {
            return (
                red: Double((argb >> 16) & 0xFF) / 255,
                green: Double((argb >> 8) & 0xFF) / 255,
                blue: Double(argb & 0xFF) / 255
            )
        }
        return color.textHighlightRGB
    }
}
