// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks

/// The size of the sheet a notebook is served on.
///
/// This is not taste but geography: in Europe A4 is expected, in America US
/// Letter. The third option is the exact physical size of the tablet's
/// screen, for those who need a one-to-one match.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PaperSize: String, Sendable, CaseIterable {
    case a4
    case letter
    case tablet

    /// The sheet in points for a page whose canvas is `canvas`.
    ///
    /// A4 and Letter are standards: the canvas does not affect them, the
    /// page fits into them. The "as tablet" sheet does depend on it, and
    /// that is the point: the page declares its own canvas in the scene
    /// block, and every model's differs — one written-down size would be
    /// right for exactly one of them.
    ///
    /// Hence the default: the ten-inch canvas, for callers who ask for A4
    /// or Letter and do not care about the canvas — `PageRenderer` passes
    /// the real one.
    public func points(forCanvas canvas: CGSize = PageRenderer.defaultPageSize) -> CGSize {
        let sheet: CGSize = switch self {
        // The two standard sheets in points, upright. Written out rather
        // than read off a host's paper setting: these are facts
        // about paper, not a preference, and a renderer that has to ask its
        // host for the size of A4 is a renderer bound to one host.
        case .a4: CGSize(width: 595.276, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .tablet: AnnotationGeometry.sheet(forScene: canvas)
        }
        // The standard sheets are upright by definition, and a page on its
        // side laid on an upright sheet is not so much wrong as tiny: it
        // scales down to a band across the middle, with the rest of the paper
        // left blank. So the sheet turns with the page. The "as tablet" sheet
        // is the canvas itself and has turned already.
        guard canvas.width > canvas.height, sheet.height > sheet.width else { return sheet }
        return CGSize(width: sheet.height, height: sheet.width)
    }
}
