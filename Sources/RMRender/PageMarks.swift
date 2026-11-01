// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import RMMarks
import RMLines

/// Where the marker went on a page, for a caller that has to find out what
/// is written under it.
///
/// Apart from `RMPage.highlights`, and the difference is the whole reason
/// this exists. Run over the text of an imported PDF, the marker writes a
/// glyph range: the words copied out of the text layer, with ready-made
/// rectangles. Run over handwriting — or over a scan, which has no text
/// layer to snap to — it writes an ordinary stroke, and then the band is
/// the only record that anything was marked at all. What it says has to be
/// read off the pixels.
///
/// The bands come out in the frame the page is *drawn* in, not in the
/// page's own coordinates, because that frame is the one a reading was
/// taken in. A sheet grows under ink written past the page edge, and a
/// band divided by the page size instead would sit beside the words it
/// covers on exactly the pages where the writing ran over.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PageMarks {
    /// The bands of a notebook page, in the frame `PageRenderer.image`
    /// draws it in.
    public static func bands(
        of page: RMPage,
        pageSize: CGSize = PageRenderer.defaultPageSize
    ) -> [MarkBand] {
        bands(of: page, pageSize: pageSize, in: notebookFrame(of: page, pageSize: pageSize))
    }

    /// The part of a notebook page's own space its bitmap shows.
    ///
    /// The bitmap is the grown sheet, and the content is put on it by the
    /// placement; read the placement back and the sheet says which part of
    /// the page each pixel stands on.
    private static func notebookFrame(of page: RMPage, pageSize: CGSize) -> CGRect {
        let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
        let bounds = PageRenderer.contentBounds(
            of: page, pageSize: pageSize, edge: .uncut, geometry: geometry
        )
        let sheet = PageRenderer.grownSheet(from: bounds, floor: pageSize, scale: 1)
        let placement = PageRenderer.placement(of: bounds, on: sheet, scale: 1)
        return CGRect(origin: .zero, size: sheet).applying(placement.inverted())
    }

    /// The passages the tablet spelled out of a text layer, with the band
    /// over each, in the frame `PageRenderer.image` draws the page in.
    ///
    /// The same places as the bands above, from the other kind of mark:
    /// a marker run over the text of an imported PDF writes a glyph range
    /// — the words and their rectangles — instead of a stroke, so these
    /// cost no reading at all. A highlight the file left without words is
    /// left out: it is a place with nothing to say.
    public static func highlights(
        of page: RMPage,
        pageSize: CGSize = PageRenderer.defaultPageSize
    ) -> [MarkedHighlight] {
        highlights(of: page, pageSize: pageSize, in: notebookFrame(of: page, pageSize: pageSize))
    }

    /// The same for a page marked over an imported PDF.
    public static func highlights(of page: RMPage, sheet: CGSize) -> [MarkedHighlight] {
        let units = AnnotationGeometry.units(of: sheet)
        return highlights(of: page, pageSize: units, in: pdfFrame(of: page, sheet: sheet))
    }

    private static func highlights(
        of page: RMPage, pageSize: CGSize, in frame: CGRect
    ) -> [MarkedHighlight] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        return page.highlights.compactMap { highlight in
            guard let text = highlight.text, !text.isEmpty else { return nil }
            // A highlight states its rectangles in the page's own
            // coordinates, the way a stroke states its points: from the
            // middle sideways and from the top down.
            let rectangles = highlight.rectangles.map { rectangle -> CGRect in
                let upper = PageRenderer.convert(
                    x: rectangle.minX, y: rectangle.minY, pageSize: pageSize
                )
                let lower = PageRenderer.convert(
                    x: rectangle.maxX, y: rectangle.maxY, pageSize: pageSize
                )
                return CGRect(
                    x: upper.x, y: lower.y, width: lower.x - upper.x, height: upper.y - lower.y
                )
            }
            guard let first = rectangles.first else { return nil }
            let band = rectangles.dropFirst().reduce(first) { $0.union($1) }
            let (red, green, blue) = highlight.rgb
            let color = UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
            return MarkedHighlight(
                text: text,
                band: MarkBand(box: box(of: band, in: frame), color: color, item: highlight.id?.description)
            )
        }
    }

    /// The bands of a page marked over an imported PDF, in the frame the
    /// flattened page is rasterised in — its media box, which is the sheet
    /// grown around whatever was marked past its edges.
    public static func bands(of page: RMPage, sheet: CGSize) -> [MarkBand] {
        let units = AnnotationGeometry.units(of: sheet)
        return bands(of: page, pageSize: units, in: pdfFrame(of: page, sheet: sheet))
    }

    /// The part of a marked page's own space the flattened page shows: its
    /// media box, brought back to `.rm` units.
    ///
    /// The marks are drawn onto the page at `pointsPerUnit` with nothing
    /// translated — a media box beginning left of zero moves the page's
    /// edges, not its coordinates — so dividing by that unit is the whole
    /// of the conversion back.
    private static func pdfFrame(of page: RMPage, sheet: CGSize) -> CGRect {
        let units = AnnotationGeometry.units(of: sheet)
        let bounds = PageRenderer.contentBounds(
            of: page, pageSize: units, edge: AnnotatedPDFRenderer.markEdge
        )
        let box = AnnotationGeometry.box(bounds, on: CGRect(origin: .zero, size: sheet))
        return CGRect(
            x: box.minX / Calibration.pointsPerUnit,
            y: box.minY / Calibration.pointsPerUnit,
            width: box.width / Calibration.pointsPerUnit,
            height: box.height / Calibration.pointsPerUnit
        )
    }

    /// The marked blocks of a page cut out and stacked into one picture,
    /// a solid rule between them.
    ///
    /// For a reader that would otherwise be asked once per band: on a live
    /// page of seven marks the stack is a third of the page's pixels and
    /// one call instead of seven, and it reads no worse — measured against
    /// both the page and the separate cuts. The rule is drawn rather than
    /// left as blank paper because a wide blank is read as the end of a
    /// column, while a line of ink is read as a border and never as a
    /// word.
    ///
    /// `blocks` are boxes of the page — what `MarkedText.blocks` gathers
    /// out of the passages, so the picture holds the text and not the
    /// band, which hangs over the letters. The margin is a couple of
    /// pixels: the block is already cut where the reader stopped.
    public static func sheet(
        of blocks: [PageBox], from page: CGImage, margin: Int = 2, rule: Int = 10
    ) -> MarkSheet? {
        let width = Double(page.width), height = Double(page.height)
        var cuts: [(picture: CGImage, block: PageBox)] = []
        for block in blocks {
            let rect = CGRect(
                x: block.x0 * width - Double(margin), y: block.y0 * height - Double(margin),
                width: (block.x1 - block.x0) * width + Double(margin) * 2,
                height: (block.y1 - block.y0) * height + Double(margin) * 2
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            guard rect.width >= 2, rect.height >= 2, let cut = page.cropping(to: rect) else { continue }
            cuts.append((cut, block))
        }
        guard !cuts.isEmpty else { return nil }

        let sheetWidth = cuts.map(\.picture.width).max() ?? 1
        let sheetHeight = cuts.reduce(rule) { $0 + $1.picture.height + rule }
        guard let context = CGContext(
            data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
            bytesPerRow: sheetWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        var strips: [MarkSheet.Strip] = []
        var top = rule
        for cut in cuts {
            // The sheet is drawn from the bottom up, as every context is;
            // the strips are counted from the top, as every box is.
            context.draw(
                cut.picture,
                in: CGRect(
                    x: 0, y: sheetHeight - top - cut.picture.height,
                    width: cut.picture.width, height: cut.picture.height
                )
            )
            strips.append(
                MarkSheet.Strip(
                    onPage: cut.block,
                    inSheet: PageBox(
                        x0: 0, y0: Double(top) / Double(sheetHeight),
                        x1: Double(cut.picture.width) / Double(sheetWidth),
                        y1: Double(top + cut.picture.height) / Double(sheetHeight)
                    )
                )
            )
            top += cut.picture.height
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(
                CGRect(x: 0, y: sheetHeight - top - rule, width: sheetWidth, height: rule)
            )
            top += rule
        }
        guard let picture = context.makeImage() else { return nil }
        return MarkSheet(picture: picture, strips: strips, pieces: cuts.map(\.picture))
    }

    /// The band with the air a reader needs around it, as fractions of
    /// the page, for a caller stitching several of them into one picture.
    ///
    /// `margin` is a share of the band's own height, taken above and
    /// below: a line read with nothing over or under it loses the
    /// ascenders and descenders an engine tells letters apart by. To the
    /// sides it is taken twice over, because a band that stops in the
    /// middle of a word would otherwise hand the engine half a word — a
    /// live band cut a seven-letter word to its first five. Air to the sides
    /// costs nothing: what the picture is read for is put against the band
    /// afterwards, and a word the band does not touch is dropped there.
    public static func around(
        _ box: PageBox, margin: Double = 0.6
    ) -> PageBox {
        let air = (box.y1 - box.y0) * margin
        let sides = air * 2
        return PageBox(
            x0: max(0, box.x0 - sides), y0: max(0, box.y0 - air),
            x1: min(1, box.x1 + sides), y1: min(1, box.y1 + air)
        )
    }

    /// One stroke, one band. The marker is dragged along a line and lifted,
    /// so a mark over two lines is two strokes; joining them here would
    /// hand back a passage the reader never marked as one.
    private static func bands(of page: RMPage, pageSize: CGSize, in frame: CGRect) -> [MarkBand] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        return PageRenderer.placedStrokes(of: page, pageSize: pageSize).compactMap { stroke in
            guard stroke.tool?.isHighlighter == true,
                  let ribbon = ribbon(of: stroke, pageSize: pageSize)
            else { return nil }
            // The colour as the tool draws it: the marker's own palette,
            // or the explicit one newer files write beside the stroke.
            let (red, green, blue) = stroke.rgb
            let color = UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
            return MarkBand(box: box(of: ribbon, in: frame), color: color, item: stroke.id?.description)
        }
    }

    /// The band as it is drawn: the width the pen lays around the points it
    /// went through. The points alone are a line of no height — a drag
    /// along a line of text is exactly that — and a band of no height
    /// overlaps nothing.
    private static func ribbon(of stroke: Stroke, pageSize: CGSize) -> CGRect? {
        // A highlighter ends flat: the box stops where its ink
        // does, not half a width past the last point in every direction.
        if stroke.end != .round, stroke.points.count > 1 {
            let line = CGMutablePath()
            var widest = 0.0
            for (index, point) in stroke.points.enumerated() {
                let location = PageRenderer.convert(point, pageSize: pageSize)
                if index == 0 { line.move(to: location) } else { line.addLine(to: location) }
                widest = max(widest, PageRenderer.InkEdge.uncut.halfWidth(at: point))
            }
            let box = line.copy(
                strokingWithWidth: widest * 2, lineCap: stroke.end.lineCap, lineJoin: .round, miterLimit: 10
            ).boundingBoxOfPath
            if !box.isNull, box.width.isFinite, box.height.isFinite { return box }
        }
        var band: CGRect?
        for point in stroke.points {
            let location = PageRenderer.convert(point, pageSize: pageSize)
            let half = PageRenderer.InkEdge.uncut.halfWidth(at: point)
            let around = CGRect(
                x: location.x - half, y: location.y - half, width: half * 2, height: half * 2
            )
            band = band.map { $0.union(around) } ?? around
        }
        return band
    }

    /// A rectangle of the page's own coordinates as fractions of the frame.
    /// The page counts upwards from its foot and a box counts downwards
    /// from its head, so the vertical turns over here.
    ///
    /// Held inside the picture: a mark drawn to the very edge of a page
    /// whose sheet follows the centreline of the ink can stand a hair
    /// outside it, and a fraction outside the picture is not a place — it
    /// would widen every line box it is compared against.
    private static func box(of rect: CGRect, in frame: CGRect) -> PageBox {
        PageBox(
            x0: held((rect.minX - frame.minX) / frame.width),
            y0: held((frame.maxY - rect.maxY) / frame.height),
            x1: held((rect.maxX - frame.minX) / frame.width),
            y1: held((frame.maxY - rect.minY) / frame.height)
        )
    }

    private static func held(_ fraction: CGFloat) -> Double {
        Double(min(max(fraction, 0), 1))
    }
}
