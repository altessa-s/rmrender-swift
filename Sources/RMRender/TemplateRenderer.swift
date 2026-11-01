// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
import RMMarks

/// What drawing a template could not do.
///
/// Gathered rather than logged where it happens: a grid repeats its cell over
/// the whole sheet, so one name the evaluator does not know would otherwise
/// write the same line into the log hundreds of times. Collected by text and
/// written once, when the page is done.
///
/// Falling back and drawing something stays the behaviour — a page with the
/// ruling slightly wrong beats a blank one. The fallback is not silent,
/// though: a failed expression and an absent field are distinct events, and
/// each leaves a trace — without that distinction, an unknown name such as
/// `textWidth` could leave every label of a planner uncentred and say so
/// nowhere.
final class TemplateProblems {
    private(set) var messages: Set<String> = []

    func note(_ message: String) {
        messages.insert(message)
    }
}

/// Drawing a page's template.
///
/// A template is not a picture but a description: groups with repeats, paths
/// and labels whose coordinates are given by expressions. Here it is turned
/// into drawing commands.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TemplateRenderer {
    // The template line colour and width match the tablet's exports — `Calibration`.
    private static let defaultStroke = Calibration.templateStroke
    private static let defaultStrokeWidth = Calibration.templateStrokeWidth

    /// Draw the template in a context whose origin is at the bottom left
    /// corner. Inside, the system is flipped: a template counts top to
    /// bottom.
    ///
    /// `size` is the page's dimensions: the template works out its insets
    /// from them, and they must not be touched, otherwise the ruling slides
    /// out of place. `extent` is the area the repeats have to fill. Usually
    /// the two match, but on a page written below the edge the sheet grows
    /// downwards, and the template has to grow with it — in the tablet's
    /// export the ruling runs to the very bottom of the grown canvas.
    public static func draw(
        _ template: Template,
        in context: CGContext,
        size: CGSize,
        extent: CGSize? = nil
    ) {
        let problems = drawReportingProblems(template, in: context, size: size, extent: extent)
        for message in problems.messages.sorted() {
            RMRenderLog.templateError("template \(template.name): \(message)")
        }
    }

    /// The drawing itself, handing back what it could not do rather than
    /// logging it. Split out so that a test can read the complaints: a log
    /// line nobody can assert on is barely better than silence.
    @discardableResult
    static func drawReportingProblems(
        _ template: Template,
        in context: CGContext,
        size: CGSize,
        extent: CGSize? = nil
    ) -> TemplateProblems {
        let extent = extent ?? size

        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        var environment: [String: Double] = [
            "templateWidth": size.width,
            "templateHeight": size.height,
            "parentWidth": size.width,
            "parentHeight": size.height,
            // The "sheet" is a square whose side is the canvas height, centred
            // across the width; `paperOriginX` is its left edge, negative
            // because the square is wider than the canvas (matches a probe
            // template exported from two models).
            //
            // A constant offset such as `width / 2 - 613.2` cannot stand in for
            // it: it agrees with the formula only modulo the isometric cell, and
            // only on some sheets. The two differ by `height / 2 - 613.2`, which
            // is 7.99 cells on Pro and 1.99 on Move — but 5.53 on the 1404×1872
            // sheet that is `PageRenderer.defaultPageSize`, where the constant
            // would put the grid half a cell out.
            "paperOriginX": Double(size.width - size.height) / 2,
            // The top of that square sits on the top of the canvas.
            "paperOriginY": 0,
        ]

        let problems = TemplateProblems()

        // The constants are evaluated in order: the next one may refer to the
        // previous.
        for pair in template.constants ?? [] {
            for (name, value) in pair {
                environment[name] = number(value, in: environment, "constant \(name)", problems) ?? 0
            }
        }

        for item in template.items {
            draw(
                item,
                in: context,
                origin: .zero,
                environment: environment,
                size: size,
                extent: extent,
                problems: problems
            )
        }

        return problems
    }

    // MARK: - Items

    private static func draw(
        _ item: TemplateItem,
        in context: CGContext,
        origin: CGPoint,
        environment: [String: Double],
        size: CGSize,
        extent: CGSize,
        problems: TemplateProblems
    ) {
        switch item {
        case .group(let group):
            draw(
                group,
                in: context,
                origin: origin,
                environment: environment,
                size: size,
                extent: extent,
                problems: problems
            )
        case .path(let path):
            draw(path, in: context, origin: origin, environment: environment, problems: problems)
        case .text(let text):
            draw(text, in: context, origin: origin, environment: environment, problems: problems)
        }
    }

    private static func draw(
        _ group: TemplateItem.Group,
        in context: CGContext,
        origin: CGPoint,
        environment: [String: Double],
        size: CGSize,
        extent: CGSize,
        problems: TemplateProblems
    ) {
        let box = frame(of: group.boundingBox, in: environment, "boundingBox", problems)
        let width = box.width > 0 ? box.width : (environment["parentWidth"] ?? size.width)
        let height = box.height > 0 ? box.height : (environment["parentHeight"] ?? size.height)

        var childEnvironment = environment
        childEnvironment["parentWidth"] = width
        childEnvironment["parentHeight"] = height

        let start = CGPoint(x: origin.x + box.origin.x, y: origin.y + box.origin.y)
        // The repeats are counted over the sheet rather than the page: that
        // is exactly what carries the template down to the bottom of a grown
        // sheet.
        let rows = repetitions(
            group.repeat?.rows,
            step: height,
            from: start.y,
            extent: extent.height,
            in: environment,
            "repeat.rows",
            problems
        )
        let columns = repetitions(
            group.repeat?.columns,
            step: width,
            from: start.x,
            extent: extent.width,
            in: environment,
            "repeat.columns",
            problems
        )

        for row in 0..<rows.count {
            for column in 0..<columns.count {
                let cell = CGPoint(
                    x: start.x + Double(column) * width * columns.direction,
                    y: start.y + Double(row) * height * rows.direction
                )
                for child in group.children {
                    draw(
                        child,
                        in: context,
                        origin: cell,
                        environment: childEnvironment,
                        size: size,
                        extent: extent,
                        problems: problems
                    )
                }
            }
        }
    }

    private static func draw(
        _ path: TemplateItem.Path,
        in context: CGContext,
        origin: CGPoint,
        environment: [String: Double],
        problems: TemplateProblems
    ) {
        guard let cgPath = buildPath(path.data, origin: origin, environment: environment, problems: problems)
        else { return }

        context.saveGState()
        defer { context.restoreGState() }

        context.addPath(cgPath)
        let fill = path.fillColor.flatMap({ color(from: $0, "fillColor", problems) })
        if let fill {
            context.setFillColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha)
            // Filled and nothing more only where the path says nothing about a
            // stroke. A dot template may state both — a black fill and a
            // width — and filling alone would draw it with under half the ink
            // the tablet's export carries.
            if path.strokeWidth == nil, path.strokeColor == nil {
                context.fillPath()
                return
            }
        }

        // A path stating its own width is drawn in black; one that says
        // nothing takes the template grey. This matches exported PDFs rather
        // than following from the format: a path that states a `strokeWidth`
        // and no colour comes back black in an export, while one that states
        // neither comes back at the grey. Drawn at the grey instead, such a
        // ruling matches the export to the pixel in geometry and misses only
        // in tone — 192 of 255 where the export averages 38.
        let black = RGBA(0, 0, 0, 1)
        let grey = RGBA(defaultStroke.red, defaultStroke.green, defaultStroke.blue, 1)
        let stroke = path.strokeColor.flatMap({ color(from: $0, "strokeColor", problems) })
            ?? (path.strokeWidth != nil ? black : grey)
        context.setStrokeColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: stroke.alpha)
        context.setLineWidth(
            resolve(path.strokeWidth, in: environment, "strokeWidth", problems) ?? defaultStrokeWidth
        )
        // A square cap rather than a break at the end point: the tablet's
        // exports carry the same `2 J`. A template may lay out
        // vertical margins as segments up to `parentHeight - 1` and repeats
        // them every `parentHeight`, so a gap of one unit is left between
        // segments; the cap covers half a line width of it from either side.
        // The gap is not closed entirely in the reference either — there it
        // is fractions of a typographic point, and to the eye the line is
        // continuous.
        context.setLineCap(.square)
        // Both, where the path asked for both: `strokePath` alone would throw
        // the fill away, and the two together are what a dot is.
        context.drawPath(using: fill == nil ? .stroke : .fillStroke)
    }

    private static func draw(
        _ text: TemplateItem.Text,
        in context: CGContext,
        origin: CGPoint,
        environment: [String: Double],
        problems: TemplateProblems
    ) {
        let fontSize = resolve(text.fontSize, in: environment, "fontSize", problems) ?? 24

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        // The keys come from CoreText rather than AppKit: the package builds
        // without it, and there is no reason to drag in a UI framework for
        // the sake of two constants.
        let attributed = NSAttributedString(
            string: text.text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                // Black, not the rule colour, as in the tablet's export of a
                // landscape week planner: on that page the
                // rules rasterise to 192 — `Calibration.templateStroke`,
                // #C0C0C0, exactly as the export gives it — while "Sunday",
                // "TIME" and "WEEK NUMBER:" have a core of 0. Both numbers
                // come out of one file through one rasteriser, so the
                // difference is in the page and not in the drawing of it.
                // The grey is read off a ruled template, which has no text,
                // and the labels inherit it for want of a reading of their
                // own.
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    srgbRed: 0,
                    green: 0,
                    blue: 0,
                    alpha: 1
                ),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)

        // `textWidth` is the width of this very label, and it is known only
        // once the label is laid out — hence the position is resolved after
        // the line, not before. Templates centre labels with it — a week
        // planner might place a day name at `6.5 * templateWidth / 7 -
        // textWidth / 2`. Without the name the whole expression fails to
        // resolve and falls back to zero, stacking every such label on the
        // left edge.
        var environment = environment
        environment["textWidth"] = CTLineGetTypographicBounds(line, nil, nil, nil)
        let position = frame(of: text.position, in: environment, "position", problems).origin

        context.saveGState()
        defer { context.restoreGState() }

        // The context is flipped for the sake of template coordinates — the
        // label would have to be read in a mirror, so the flip is undone
        // here.
        context.translateBy(x: origin.x + position.x, y: origin.y + position.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    // MARK: - Resolving values

    /// A value, or `nil` with the reason written down. The two ways of getting
    /// nothing are told apart by the caller: an absent field never reaches
    /// here.
    private static func number(
        _ value: TemplateValue,
        in environment: [String: Double],
        _ what: String,
        _ problems: TemplateProblems
    ) -> Double? {
        do {
            return try value.resolved(in: environment)
        } catch {
            problems.note("\(what): \(error)")
            return nil
        }
    }

    private static func resolve(
        _ value: TemplateValue?,
        in environment: [String: Double],
        _ what: String,
        _ problems: TemplateProblems
    ) -> Double? {
        guard let value else { return nil }
        return number(value, in: environment, what, problems)
    }

    private static func frame(
        of box: TemplateBox?,
        in environment: [String: Double],
        _ what: String,
        _ problems: TemplateProblems
    ) -> CGRect {
        guard let box else { return .zero }
        return CGRect(
            x: resolve(box.x, in: environment, "\(what).x", problems) ?? 0,
            y: resolve(box.y, in: environment, "\(what).y", problems) ?? 0,
            width: resolve(box.width, in: environment, "\(what).width", problems) ?? 0,
            height: resolve(box.height, in: environment, "\(what).height", problems) ?? 0
        )
    }

    /// The most times a group is repeated in one direction.
    ///
    /// A repeat is a cell, and a ruling's step is typically whole units on a
    /// canvas 2160 of them tall — some two thousand rows at the outside. Ten thousand is five times that: room for any sheet this
    /// package draws on, and past it a ruling is a solid fill nobody meant
    /// and a render that never comes back.
    static let maximumRepeats = 10_000

    /// A repeat count a template asked for, made into one that can be
    /// counted to.
    ///
    /// `Int(_:)` traps on a value it cannot hold — not a number, infinite, or
    /// past the range of the type — and every one of those arrives here from
    /// a file: `JSONDecoder` reads `1e400` as infinity, and an expression
    /// comes to whatever the environment makes of it. A template is data, and
    /// `TemplateProblems` is the promise that bad data is written down rather
    /// than allowed to take the process down. Not a finite number is one
    /// repeat, the same fallback a bad expression takes; anything else is
    /// truncated the way `Int(_:)` truncates and held between one and
    /// `maximumRepeats`.
    static func repeatCount(_ value: Double) -> Int {
        guard value.isFinite else { return 1 }
        return Int(min(max(value.rounded(.towardZero), 1), Double(maximumRepeats)))
    }

    /// How many times to repeat a group, and in which direction.
    ///
    /// The value is either a number, a direction (`down`, `up`, `right`,
    /// `infinite`), or an expression giving a count.
    private static func repetitions(
        _ value: TemplateValue?,
        step: Double,
        from start: Double,
        extent: Double,
        in environment: [String: Double],
        _ what: String,
        _ problems: TemplateProblems
    ) -> (count: Int, direction: Double) {
        guard let value, step > 0 else { return (1, 1) }

        switch value {
        case .number(let count):
            return (repeatCount(count), 1)
        case .expression(let source):
            switch source {
            case "down", "infinite", "right":
                return (repeatCount(ceil((extent - start) / step)), 1)
            case "up", "left":
                return (repeatCount(ceil(start / step) + 1), -1)
            default:
                do {
                    let count = try TemplateExpression.compiled(source).value(in: environment)
                    return (repeatCount(count), 1)
                } catch {
                    // Falling back to a single repeat draws the cell once
                    // where a grid was asked for — very visible, and worth
                    // saying out loud.
                    problems.note("\(what) \"\(source)\": \(error)")
                    return (1, 1)
                }
            }
        }
    }

    private static func buildPath(
        _ tokens: [TemplatePathToken],
        origin: CGPoint,
        environment: [String: Double],
        problems: TemplateProblems
    ) -> CGPath? {
        let path = CGMutablePath()
        var numbers: [Double] = []
        var command: String?
        var started = false

        func flush() {
            guard let current = command else { return }
            switch current {
            case "M" where numbers.count >= 2:
                path.move(to: CGPoint(x: origin.x + numbers[0], y: origin.y + numbers[1]))
                started = true
            case "L" where numbers.count >= 2 && started:
                path.addLine(to: CGPoint(x: origin.x + numbers[0], y: origin.y + numbers[1]))
            case "C" where numbers.count >= 6 && started:
                path.addCurve(
                    to: CGPoint(x: origin.x + numbers[4], y: origin.y + numbers[5]),
                    control1: CGPoint(x: origin.x + numbers[0], y: origin.y + numbers[1]),
                    control2: CGPoint(x: origin.x + numbers[2], y: origin.y + numbers[3])
                )
            case "Z":
                if started { path.closeSubpath() }
            default:
                // Either a command outside the four the template format
                // uses, or one of those four with too few coordinates to draw
                // it.
                // Both are recorded here rather than dropped silently.
                problems.note("path command \"\(current)\" with \(numbers.count) coordinates was not drawn")
            }
            numbers.removeAll()
        }

        for token in tokens {
            switch token {
            case .command(let next):
                flush()
                command = next
                if next == "Z" { flush() }
            case .value(let value):
                numbers.append(number(value, in: environment, "path coordinate", problems) ?? 0)
            }
        }
        flush()

        return path.isEmpty ? nil : path
    }

    /// A colour as the drawing takes it: four components in 0…1, in the order
    /// `CGContext` names them.
    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        /// Positional on purpose: the table of named colours below reads as a
        /// table only while the four numbers stay four numbers.
        init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// A colour from a string: `#RRGGBB`, `#RRGGBBAA`, or a plain name.
    ///
    /// `nil` is not "no colour" but "this string was not understood", and the
    /// difference shows: a fill that fails to parse falls through to the
    /// stroke branch, and the shape comes out outlined instead of filled.
    private static func color(
        from text: String,
        _ what: String,
        _ problems: TemplateProblems
    ) -> RGBA? {
        switch text.lowercased() {
        case "black": return RGBA(0, 0, 0, 1)
        case "white": return RGBA(1, 1, 1, 1)
        case "gray", "grey": return RGBA(0.5, 0.5, 0.5, 1)
        case "lightgray", "lightgrey": return RGBA(0.8, 0.8, 0.8, 1)
        default: break
        }

        var hex = text
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else {
            problems.note("\(what) \"\(text)\" is not a colour")
            return nil
        }

        if hex.count == 6 {
            return RGBA(
                Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255,
                1
            )
        }
        return RGBA(
            Double((value >> 24) & 0xFF) / 255,
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
