// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// The marks of one page as PDF drawing operators.
///
/// The same drawing as `PageRenderer.draw`, written out rather than performed:
/// an overlay appends its content to what the page already has, and content is
/// operators. The two must agree — a filled contour vs a stroked line follows
/// the tool, not whether width changes, and a text-highlight band is a
/// rectangle multiplied over the page — so a change to how marks look has to
/// be made in both places.
enum MarkContentStream {
    struct Result: Sendable {
        let content: Data
        /// The graphics states the content refers to by name. Built as they are
        /// needed rather than chosen from a fixed few: a stroke's opacity comes
        /// out of the file, so how many there are is a property of the page.
        let states: [PDFOverlayWriter.GraphicsState]
        /// The stencils the content paints through, one a grained stroke.
        let images: [PDFOverlayWriter.ImageMask]
    }

    /// `nil` when the page holds something this cannot express, and then the
    /// document goes to the renderer that redraws it. Typed text is the case
    /// that exists: drawing it means embedding a font, and a font is a good
    /// deal more than a path.
    static func build(_ page: RMPage, mediaBox: CGRect) -> Result? {
        guard page.text == nil else { return nil }
        // Tool 6 is an operation, not a mark. `PageRenderer.draw` subtracts its
        // band from every stroke laid down before it, and operators appended to
        // a page cannot cut what the page already carries. Drawn without that
        // subtraction the page comes out with the ink the user rubbed out —
        // and nothing here fails, so nothing falls back. Hence the refusal.
        //
        // Tool 8 is deliberately not a reason to refuse: it takes no ink off,
        // and both paths merely skip it, so refusing would cost the document
        // its links to save nothing.
        guard !page.strokes.contains(where: { $0.tool == .eraser }) else { return nil }
        let scale = Calibration.pointsPerUnit

        func x(_ value: Double) -> String {
            PDFWriter.number(mediaBox.minX + value * scale + mediaBox.width / 2)
        }
        func y(_ value: Double) -> String {
            PDFWriter.number(mediaBox.maxY - value * scale)
        }
        func colour(_ rgb: (red: Double, green: Double, blue: Double)) -> String {
            "\(PDFWriter.number(rgb.red)) \(PDFWriter.number(rgb.green)) \(PDFWriter.number(rgb.blue))"
        }

        var out = "1 J 1 j\n"
        var states: [PDFOverlayWriter.GraphicsState] = []
        var images: [PDFOverlayWriter.ImageMask] = []

        /// The name of the state for this way of laying ink down, made once and
        /// then shared. `nil` means the page's own state will do.
        func state(blendMode: String?, alpha: Double) -> String? {
            guard blendMode != nil || alpha < 1 else { return nil }
            if let found = states.first(where: { $0.blendMode == blendMode && $0.alpha == alpha }) {
                return found.name
            }
            let made = PDFOverlayWriter.GraphicsState(
                name: "RMGs\(states.count)",
                blendMode: blendMode,
                alpha: alpha
            )
            states.append(made)
            return made.name
        }

        // The marker goes under the handwriting, as it does on the tablet.
        for highlight in page.highlights {
            for rectangle in highlight.rectangles {
                // A rectangle arrives counted from the top of the page; the
                // operator wants its lower left corner.
                let height = rectangle.height * scale
                let bottom = mediaBox.maxY - rectangle.minY * scale - height
                let name = state(blendMode: "Multiply", alpha: 1)
                out += "q \(name.map { "/\($0) gs " } ?? "")\(colour(highlight.rgb)) rg "
                out += "\(x(rectangle.minX)) \(PDFWriter.number(bottom)) "
                out += "\(PDFWriter.number(rectangle.width * scale)) \(PDFWriter.number(height)) re f Q\n"
            }
        }

        func contour(of stroke: Stroke) {
            for element in StrokeOutline.elements(of: stroke) {
                switch element {
                case .move(let point):
                    out += "\(x(Double(point.x))) \(y(Double(point.y))) m\n"
                case .line(let point):
                    out += "\(x(Double(point.x))) \(y(Double(point.y))) l\n"
                case .curve(let control1, let control2, let to):
                    out += "\(x(Double(control1.x))) \(y(Double(control1.y))) "
                    out += "\(x(Double(control2.x))) \(y(Double(control2.y))) "
                    out += "\(x(Double(to.x))) \(y(Double(to.y))) c\n"
                case .close:
                    out += "h\n"
                }
            }
        }

        // The eraser is not a drawing: draw it and the page fills with lines
        // exactly where the user was rubbing them out.
        let drawn = page.strokes.map(\.drawn).filter { $0.tool?.isEraser != true && $0.points.count > 1 }
        var index = 0
        while index < drawn.count {
            let stroke = drawn[index]
            index += 1

            // The pieces the eraser left of one shader stroke, as
            // `PageRenderer` draws them: one stroke, not deepening where they
            // meet. A transparency layer there, one fill here — every contour
            // runs the same way round, so the non-zero rule fills their union
            // once, the same reason one stroke's overlapping turns take one
            // `f`.
            if let source = PageRenderer.sharedLayerKey(of: stroke) {
                var pieces = [stroke]
                while index < drawn.count, PageRenderer.sharedLayerKey(of: drawn[index]) == source {
                    pieces.append(drawn[index])
                    index += 1
                }
                let name = state(blendMode: stroke.blend.darkens ? "Darken" : nil, alpha: stroke.alpha)
                out += "q "
                if let name { out += "/\(name) gs " }
                out += "\(colour(stroke.rgb)) rg\n"
                for piece in pieces { contour(of: piece) }
                out += "f Q\n"
                continue
            }

            let name = state(
                blendMode: stroke.blend.darkens ? "Darken" : nil,
                alpha: stroke.alpha
            )
            out += "q "
            if let name { out += "/\(name) gs " }

            if !stroke.isStroked {
                // A filled contour, as the tablet draws seven tools of nine.
                // One `f` for the whole stroke: its pieces overlap where it
                // turns, and a fill each would darken every overlap of a
                // translucent tool.
                out += "\(colour(stroke.rgb)) rg\n"
                contour(of: stroke)
                let grain = stroke.grain
                if grain != .solid,
                   let box = StrokeGrainMask.box(of: stroke),
                   let bits = StrokeGrainMask.bits(for: stroke, grain: grain, in: box) {
                    // The pencils, the same way the renderer draws them: the
                    // contour is the clip, and the grain is a stencil painted
                    // through it in the stroke's colour. `cm` maps the unit
                    // square onto the stencil's box; the box is stated in
                    // whole units from the top, the stream counts from the
                    // bottom, so its lower edge is the box's far side.
                    let mask = PDFOverlayWriter.ImageMask(
                        name: "RMIm\(images.count)",
                        width: bits.width,
                        height: bits.height,
                        bits: Data(bits.data)
                    )
                    images.append(mask)
                    out += "W n\n"
                    out += "\(PDFWriter.number(box.width * scale)) 0 0 \(PDFWriter.number(box.height * scale)) "
                    out += "\(x(box.minX)) \(y(box.maxY)) cm /\(mask.name) Do Q\n"
                } else {
                    out += "f Q\n"
                }
            } else {
                // The join as a PDF's `j`: 0 a mitre, cut back to a bevel
                // past the limit `M` sets, 1 round.
                let join = stroke.tool?.lineJoin == .miter
                    ? "0 j \(PDFWriter.number(PenTool.lineMiterLimit)) M" : "1 j"
                out += "\(stroke.end.pdfLineCap) J \(join) \(colour(stroke.rgb)) RG \(PDFWriter.number(stroke.lineWidth * scale)) w\n"
                for (position, point) in stroke.points.enumerated() {
                    out += "\(x(Double(point.x))) \(y(Double(point.y))) \(position == 0 ? "m" : "l")\n"
                }
                out += "S Q\n"
            }
        }

        return Result(content: Data(out.utf8), states: states, images: images)
    }
}
