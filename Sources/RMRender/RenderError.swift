// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The errors of drawing: a context that would not open, a template that would
/// not read, a document without the PDF it is written on.
///
/// Told apart from `RMLines.ParseError` by which side of the boundary the
/// failure is on. That one is a `.rm` file that would not read; this one is
/// everything the drawing brings with it — and neither belongs in the other.
///
/// The cases are spelled to read well in a message written for a person.
/// Inside this package the name resolves here, and a
/// parse error keeps its own — both are seen, and the two do not merge.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum RenderError: Error, Sendable, Equatable {
    /// CoreGraphics would not give a PDF context. No drawing is possible at
    /// all, and there is nothing to fall back to.
    case pdfContextUnavailable
    /// CoreGraphics would not give a bitmap context, or the finished bitmap
    /// would not yield an image. OCR cannot run without a page picture.
    case bitmapContextUnavailable
    /// A document that cannot be drawn as it stands: an annotated PDF without
    /// its original, a PDF that will not open, a template expression that does
    /// not parse.
    case malformedPage(String)
    /// A template item of a kind this renderer does not know.
    case unsupportedFormat(String)
}
