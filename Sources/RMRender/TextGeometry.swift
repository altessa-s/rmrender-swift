// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
import RMLines

/// Where typed text lands on the page.
///
/// One walk, and two jobs read from it: drawing the text, and placing the
/// handwriting anchored to it. The layout has to do both — only it knows the
/// font and the column width, so only it knows how many lines a paragraph
/// takes and where each one sits.
///
/// Not `Sendable`, and it does not need to be: it is built and read inside one
/// synchronous draw, out of a `TextBlock` that is a value.
struct TextGeometry {
    /// One visual line: the stretch of the paragraph it takes and the baseline
    /// it sits on.
    struct Line {
        let range: CFRange
        /// In the page's own coordinates — y downwards, the way the file counts
        /// it.
        let baseline: Double
    }

    struct Paragraph {
        let number: Int
        let format: ParagraphFormat?
        /// How the item's checkbox is shown, for an item of a checkbox list:
        /// an item with nested items takes its state from them, which the
        /// style alone does not say.
        let checkbox: CheckboxState?
        let size: Double
        let face: TypeFace
        /// How far right of the margin the text stands. An item of a list is
        /// indented; everything else starts at the margin.
        let indent: Double
        /// What a numbered item calls itself. The file carries the style and
        /// never the number, so the items count themselves.
        let ordinal: Int
        /// How deep an item of a list is nested, counting from one.
        let level: Int
        /// The baseline of the first visual line — where a list marker sits too.
        let baseline: Double
        /// The origin handwriting anchored to this paragraph counts its own
        /// coordinates from: the text's own origin advanced past everything
        /// standing above. On the first paragraph it is that origin exactly —
        /// the same flat, one-step-apart value the parser assigns to every
        /// paragraph.
        let anchorOrigin: Double
        /// Whether the paragraph runs right-to-left — decided by its first
        /// strong character, as Unicode prescribes.
        let isRightToLeft: Bool
        /// Absent on a paragraph with no characters — an empty line still takes
        /// its step, and an empty item of a list still gets its marker.
        let typesetter: CTTypesetter?
        let lines: [Line]
        /// The paragraph as it reads. Kept because an anchor names a character
        /// of it, and finding that character takes the string itself: the file
        /// counts characters, CoreText counts UTF-16.
        let text: String
    }

    let paragraphs: [Paragraph]
    /// Where the text starts horizontally, the inset included.
    let left: Double
    /// The width of the column a line is set in. Needed beyond wrapping:
    /// right-to-left text measures everything from it.
    let column: Double

    init(_ text: TextBlock, pageSize: CGSize) {
        // How wide the column is, in the page's own units. The file says so
        // outright, and that is the number to take: working it out from the
        // origin holds only while the column is centred on the sheet, and the
        // field asks for no such assumption.
        let column = text.columnWidth ?? (text.originX < 0 ? -2 * text.originX : pageSize.width)
        // What a line may actually take. The column is the width of the
        // **box**, and the text stands four units inside it — on both sides,
        // not only on the left; wrapping at the full width would let a line
        // run past the box's own right edge.
        let usable = max(column - 2 * TypeMetrics.textInset, TypeMetrics.body)
        self.column = usable
        // The text sits four units in from the origin the file gives — read off
        // the tablet's own exports, where a paragraph whose origin is 234
        // begins at 238.
        left = text.originX + TypeMetrics.textInset

        var laid: [Paragraph] = []
        // The baseline of the line being laid out, and the top of the box the
        // paragraph occupies. They move together — the difference between them
        // is the drop of the very first line — and they are kept apart because
        // they answer different questions: one is where the letters sit, the
        // other is where the file counts handwriting from.
        var baseline = text.originY
        var origin = text.originY
        var started = false
        // A counter per level of nesting. A run is broken by anything that is
        // not a list item, and going back up a level starts the level below
        // from one again — the tablet numbers `1, 2, a, b, i, ii, 3`, where the
        // three follows the two.
        var ordinals: [Int: Int] = [:]
        // And which family held that level last. A run of one family breaks a
        // run of another: seen on the tablet's export of
        //
        //     • apple   • pear   1. first   2. second   • plum   1. first again
        //
        // where the tablet writes 1. and 2. after the bullets, and 1. again
        // after the plum. Counting by level alone would make those 3., 4. and
        // 6. — the bullets would quietly advance the numbered run, and nothing
        // in the file could say otherwise: the ordinal is not stored in it at
        // all.
        var families: [Int: ListFamily] = [:]
        var previous: ParagraphFormat?
        var previousText = ""

        for (number, paragraph) in text.lines.enumerated() {
            let format = text.formats[number]
            let style = format?.style
            let level = format?.level ?? 1
            // A level of nesting is a whole indent, the same 48 units again.
            let indent = style?.isListItem == true
                ? TypeMetrics.listIndent * Double(level)
                : 0
            var ordinal = 0
            if style?.isListItem == true {
                ordinals = ordinals.filter { $0.key <= level }
                families = families.filter { $0.key <= level }
                // Coming back up a level keeps the count below it — the
                // tablet numbers `1, 2, a, b, i, ii, 3` — but only while the
                // family holds. Change of family, fresh count.
                if families[level] != style?.listFamily {
                    families[level] = style?.listFamily
                    ordinals[level] = 0
                }
                ordinal = (ordinals[level] ?? 0) + 1
                ordinals[level] = ordinal
            } else {
                ordinals = [:]
                families = [:]
            }
            let (size, face) = Self.face(for: format)

            if !started {
                // The origin is the corner of a box: the text sits four units
                // inside it, and the first baseline an ascent below that.
                baseline += TypeMetrics.firstBaselineDrop(size: size, text: paragraph)
            } else {
                // Both paragraphs decide the step — the line about to be set
                // and the room the one above leaves; there is no extra gap on
                // leaving a list. The text rides along because the body's
                // line height depends on its scripts.
                let step = TypeMetrics.step(
                    from: previous, to: format,
                    text: paragraph, previousText: previousText
                )
                baseline += step
                origin += step
            }
            started = true
            previous = format
            previousText = paragraph

            let anchorOrigin = origin
            let firstBaseline = baseline

            var typesetter: CTTypesetter?
            var lines: [Line] = []
            let rightToLeft = Self.isRightToLeft(paragraph)
            if !paragraph.isEmpty {
                let attributed = Self.attributed(
                    paragraph,
                    size: size,
                    face: face,
                    runs: text.faces[number] ?? [],
                    rightToLeft: rightToLeft
                )
                let made = CTTypesetterCreateWithAttributedString(attributed)
                typesetter = made
                let length = attributed.length
                let storage = attributed.string as NSString
                var start = 0
                while start < length {
                    let count = CTTypesetterSuggestLineBreak(made, start, usable - indent)
                    // A width too small for even one character would spin here
                    // forever; one character a line is ugly but finite.
                    let taken = Self.keepingHangulWords(
                        max(count, 1), from: start, in: storage
                    )
                    if !lines.isEmpty {
                        // A wrapped continuation stands closer than a new
                        // paragraph: it is a line, not a paragraph, and asks
                        // for no space above it. The height is the new line's
                        // own — it depends on the line's scripts
                        // (`TypeMetrics.lineHeight(of:text:)`).
                        let step = TypeMetrics.lineHeight(
                            of: format,
                            text: storage.substring(with: NSRange(location: start, length: taken))
                        )
                        baseline += step
                        origin += step
                    }
                    lines.append(
                        Line(range: CFRange(location: start, length: taken), baseline: baseline)
                    )
                    start += taken
                }
            }

            laid.append(
                Paragraph(
                    number: number,
                    format: format,
                    checkbox: text.checkboxState(ofLine: number),
                    size: size,
                    face: face,
                    indent: indent,
                    ordinal: ordinal,
                    level: level,
                    baseline: firstBaseline,
                    anchorOrigin: anchorOrigin,
                    isRightToLeft: rightToLeft,
                    typesetter: typesetter,
                    lines: lines,
                    text: paragraph
                )
            )
        }
        paragraphs = laid
    }

    /// Where the text's frame ends: the last baseline, the descent of the
    /// box that line's script gets, and the room every paragraph leaves
    /// under itself. What the sheet has to be tall enough to hold — a
    /// wrapped paragraph takes more depth than one step, so only the layout
    /// knows how deep the text really runs.
    var frameBottom: Double? {
        guard let paragraph = paragraphs.last else { return nil }
        let line = paragraph.lines.last
        let text = line.map {
            (paragraph.text as NSString).substring(
                with: NSRange(location: $0.range.location, length: $0.range.length)
            )
        } ?? ""
        return (line?.baseline ?? paragraph.baseline)
            + TypeMetrics.descent(of: paragraph.format, text: text)
            + TypeMetrics.spaceAfter(paragraph.format)
    }

    /// The handwriting anchored to the text, moved to where that text turned
    /// out to land. Everything else is handed back untouched: its coordinates
    /// are the sheet's already.
    func placing(_ strokes: [Stroke]) -> [Stroke] {
        guard strokes.contains(where: { $0.anchor != nil }) else { return strokes }
        // One anchor typically serves many strokes, and resolving each one
        // costs a line to typeset — hence the cache.
        var known: [TextAnchor: (x: Double, y: Double)] = [:]
        return strokes.map { stroke in
            guard let anchor = stroke.anchor else { return stroke }
            let pen: (x: Double, y: Double)
            if let cached = known[anchor] {
                pen = cached
            } else {
                pen = self.pen(at: anchor)
                known[anchor] = pen
            }
            return stroke.placed(x: pen.x, y: pen.y)
        }
    }

    /// The images fastened to the text, moved the same way — an anchored
    /// image counts its vertices from the pen exactly as anchored handwriting
    /// counts its points.
    func placing(_ images: [PageImage]) -> [PageImage] {
        guard images.contains(where: { $0.anchor != nil }) else { return images }
        return images.map { image in
            guard let anchor = image.anchor else { return image }
            let pen = pen(at: anchor)
            return PageImage(
                file: image.file,
                vertices: image.vertices.map {
                    PageImage.Vertex(x: $0.x + pen.x, y: $0.y + pen.y, u: $0.u, v: $0.v)
                },
                strokesBefore: image.strokesBefore
            )
        }
    }

    /// Where the pen stood at an anchor: the position just before the
    /// anchored character on the visual line it fell on, and that line's
    /// baseline. Both numbers come from the laid-out text and neither can be
    /// had without it.
    func pen(at anchor: TextAnchor) -> (x: Double, y: Double) {
        guard let paragraph = self.paragraph(anchor.paragraph) else {
            return (x: anchor.originX ?? left, y: paragraphs.first?.baseline ?? 0)
        }
        // From `left` — the same place the letters start from, inset
        // included.
        let margin = self.margin(of: paragraph, line: nil)
        // A paragraph of no characters has no line to measure along, and the
        // pen stands at its margin. An empty item of a list is exactly this.
        guard let typesetter = paragraph.typesetter, !paragraph.lines.isEmpty else {
            return (x: anchor.originX ?? margin, y: paragraph.baseline)
        }

        // The file numbers characters from one, and the anchor names the
        // character the pen stands *before* — hence `offset − 1` in our
        // zero-based count. Zero is not a character but the start-of-
        // paragraph sentinel, and the clamp keeps it in place.
        //
        // The file counts Unicode scalars; CoreText counts UTF-16. For "abc"
        // the two agree and for an emoji they do not, and the difference
        // lands the handwriting a word away.
        let scalars = paragraph.text.unicodeScalars
        // Compared before it is lowered: `TextAnchor` is public, and one
        // below `Int.min` is a trap rather than a clamp.
        let clamped = anchor.offset > 0 ? min(anchor.offset - 1, scalars.count) : 0
        let index = scalars.index(scalars.startIndex, offsetBy: clamped)
        let utf16 = index.utf16Offset(in: paragraph.text)

        // The pen's line is the one that **contains** the named character.
        // Strict inequality: the pen stands before the character, so a
        // character on a line boundary belongs to the line that starts
        // there, not the one that ends.
        let visual = paragraph.lines.first { utf16 < $0.range.location + $0.range.length }
            ?? paragraph.lines[paragraph.lines.count - 1]
        // The horizontal lies in the file — `anchor_origin_x`, tag 10 of the
        // tree node — and when present it wins: at a boundary between
        // writing directions the caret is ambiguous and a computed position
        // can land in the wrong run. The computed path remains as the
        // fallback for files without tag 10.
        if let originX = anchor.originX { return (x: originX, y: visual.baseline) }
        let line = CTTypesetterCreateLine(typesetter, visual.range)
        let along = CTLineGetOffsetForStringIndex(line, utf16, nil)
        return (x: self.margin(of: paragraph, line: line) + Double(along), y: visual.baseline)
    }

    /// Where a paragraph's line starts.
    ///
    /// Left-to-right text starts at the left margin and the line's width does
    /// not matter. Right-to-left text is flush with the right margin, so its
    /// start depends on how much the line took. The offset along the line is
    /// CoreText's: the base direction is set in the paragraph style, so the
    /// first character's offset in an Arabic line equals the line's width and
    /// the pen lands on the right margin.
    func margin(of paragraph: Paragraph, line: CTLine?) -> Double {
        // The margin the script starts from: left for Latin, right for
        // Arabic.
        let start = paragraph.isRightToLeft
            ? left + column - paragraph.indent
            : left + paragraph.indent
        guard paragraph.isRightToLeft, let line else { return start }

        // The line is placed by its own first character's offset rather than
        // by its typographic width: the width counts trailing spaces, which
        // in right-to-left text hang off the *visual* left end and would push
        // the right edge off the margin by a space.
        let first = CTLineGetStringRange(line).location
        let along = CTLineGetOffsetForStringIndex(line, first, nil)
        return start - Double(along)
    }

    /// The paragraph an anchor names.
    ///
    /// The number comes from the very lines this geometry was built over, so it
    /// is in range; out of range it is clamped to the last paragraph rather than
    /// refused, for the same reason the end-of-text sentinel is clamped: a
    /// stroke left where the parser found it lands at the top of the page, on
    /// top of whatever is drawn there, and that reads as a drawing bug rather
    /// than as a paragraph nobody could find.
    private func paragraph(_ number: Int) -> Paragraph? {
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs[min(max(number, 0), paragraphs.count - 1)]
    }

    /// The face and the size a paragraph is set in, read off the tablet's own
    /// exports: the body in reMarkableSans at 32, an emphasised paragraph in
    /// reMarkableSerifSmall at 46, a heading in the same serif at 64, a
    /// subheading in the sans Medium at 36. The last two share `tag 1` and
    /// are told apart by whether the style record goes on past its first
    /// field.
    static func face(for format: ParagraphFormat?) -> (size: Double, face: TypeFace) {
        switch format?.style {
        case .heading: (TypeMetrics.heading1, .serif)
        // The bare `{1: 3}` is the subheading and the record that goes on is
        // the emphasised paragraph — an export carrying both sets the record
        // that goes on at 46 and the bare one at 36. A subheading is neither
        // the plain sans nor the serif: the export names
        // `reMarkableSans-Medium` for it.
        case .subheading: format?.hasFurtherFields == true
            ? (TypeMetrics.heading2, .serif)
            : (TypeMetrics.heading3, .sansMedium)
        default: (TypeMetrics.body, .sans)
        }
    }

    /// Whether a paragraph runs right-to-left — decided by its first strong
    /// character, as Unicode prescribes and as the tablet lays it out: an
    /// Arabic paragraph is flush right, a Latin one flush left.
    static func isRightToLeft(_ paragraph: String) -> Bool {
        for unit in paragraph.unicodeScalars {
            let point = Int(unit.value)
            if ScriptClass.isStrongRightToLeft(point) {
                return true
            }
            // Strong left-to-right: any other alphabetic character. Digits,
            // punctuation and spaces carry no direction; the first strong
            // character decides for the whole paragraph.
            if unit.properties.isAlphabetic { return false }
        }
        return false
    }

    private static func attributed(
        _ paragraph: String,
        size: Double,
        face: TypeFace,
        runs: [FaceRun],
        rightToLeft: Bool
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: paragraph)
        // The base direction is set in the paragraph style: with it CoreText
        // orders the runs itself, and offsets along the line start from the
        // edge the script actually starts at.
        var direction: CTWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        // The pointer must outlive the call, so the value is kept alive
        // explicitly: `&direction` inside the setting initializer would point
        // at a temporary copy.
        let style = withUnsafeMutablePointer(to: &direction) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .baseWritingDirection,
                valueSize: MemoryLayout<CTWritingDirection>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        attributed.addAttribute(
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
            value: style,
            range: NSRange(location: 0, length: attributed.length)
        )
        apply(size: size, face: face, bold: false, italic: false,
              to: attributed, range: NSRange(location: 0, length: attributed.length))
        for run in runs {
            guard let range = Self.range(run.range, in: paragraph) else { continue }
            apply(size: size, face: face, bold: run.bold, italic: run.italic,
                  to: attributed, range: range)
        }
        return attributed
    }

    /// The attributes of one stretch of a line, with non-Latin handed to
    /// Noto Sans.
    ///
    /// The tablet sets everything reMarkableSans lacks in Noto, and we carry
    /// the same family, so the widths agree by construction. This applies
    /// under the serif too: only the Latin of a serif paragraph stays serif —
    /// EB Garamond covers Cyrillic, so without the explicit hand-off the
    /// substitution would never fire.
    static func apply(
        size: Double,
        face: TypeFace,
        bold: Bool,
        italic: Bool,
        to attributed: NSMutableAttributedString,
        range: NSRange
    ) {
        attributed.addAttributes(
            attributes(size: size, face: face, bold: bold, italic: italic), range: range
        )
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        let notoSubranges = notoRanges(of: attributed.string, in: range)
        // A Noto run is not one thing: the scripts inside it come out of
        // different files, and Hebrew is set narrower than the rest
        // (`EmbeddedFonts.NotoScript`). One font for the whole run would tune
        // Hebrew by Latin's widths, or the other way about.
        for sub in notoSubranges {
            for (script, part) in scriptRuns(of: attributed.string, in: sub) {
                attributed.addAttribute(
                    key,
                    value: EmbeddedFonts.nonLatin(
                        size: size, face: face, bold: bold, italic: italic, script: script
                    ),
                    range: part
                )
            }
        }
        // The per-glyph width correction, one table per cut, and only
        // outside Noto runs: there the tablet sets Noto itself, the digits
        // are tabular, and the correction would be harm.
        let corrections: [Character: Double]? = switch (face, bold, italic) {
        case (.sans, false, false): Calibration.sansGlyphShare
        case (.sans, true, false): Calibration.sansBoldGlyphShare
        case (.sans, true, true): Calibration.sansBoldGlyphShare
        case (.sans, false, true): Calibration.sansItalicGlyphShare
        case (.sansMedium, false, false): Calibration.sansMediumGlyphShare
        case (.serif, false, false): Calibration.serifGlyphShare
        case (.serif, true, _): Calibration.serifBoldGlyphShare
        case (.serif, false, true): Calibration.serifItalicGlyphShare
        default: nil
        }
        // Inside the Noto runs, the one correction that belongs there — and
        // not in Devanagari: there the tablet's space is the face's own
        // 0.26 em (8.31 at 32, read off the export's tab glyphs), while a
        // Cyrillic or Hebrew line gets the narrower 7.92 the correction
        // reproduces. Applied to Devanagari it would have to be undone by a
        // multiplier of 1.0131 on the whole face.
        for sub in notoSubranges {
            for (script, part) in scriptRuns(of: attributed.string, in: sub) where script != .devanagari {
                kernGlyphs(
                    of: attributed, in: part, excluding: [], size: size,
                    table: Calibration.notoGlyphShare
                )
            }
        }
        guard let corrections else { return }
        kernGlyphs(of: attributed, in: range, excluding: notoSubranges, size: size, table: corrections)
    }

    /// The per-glyph width correction, delivered as kerning: the extra after
    /// a glyph brings its advance to the tablet's. Set on every character in
    /// the table outside Noto runs — wrapping and anchor positions are
    /// computed from this very string.
    private static func kernGlyphs(
        of attributed: NSMutableAttributedString,
        in range: NSRange,
        excluding notoSubranges: [NSRange],
        size: Double,
        table: [Character: Double]
    ) {
        let text = attributed.string as NSString
        let key = NSAttributedString.Key(kCTKernAttributeName as String)
        var excluded = notoSubranges.makeIterator()
        var noto = excluded.next()
        for index in range.location..<(range.location + range.length) {
            while let current = noto, index >= current.location + current.length {
                noto = excluded.next()
            }
            if let current = noto, index >= current.location { continue }
            let unit = text.character(at: index)
            guard let scalar = UnicodeScalar(UInt32(unit)) else { continue }
            guard let share = table[Character(scalar)] else { continue }
            attributed.addAttribute(
                key, value: share * size, range: NSRange(location: index, length: 1)
            )
        }
    }

    /// The break moved back to the last space when it fell inside a Korean
    /// word.
    ///
    /// CoreText breaks Hangul between any two syllables, the way it breaks
    /// the ideographs; the tablet breaks it at spaces, the way it breaks
    /// Latin, so a Korean heading the tablet wraps as whole phrases would
    /// otherwise come out with words cut through. A word too long for the
    /// line still breaks inside itself: there is no space to go back to.
    static func keepingHangulWords(_ count: Int, from start: Int, in text: NSString) -> Int {
        let end = start + count
        guard end < text.length,
              isHangul(text.character(at: end - 1)), isHangul(text.character(at: end))
        else { return count }
        var index = end - 1
        while index > start {
            if text.character(at: index) == 0x20 { return index - start + 1 }
            index -= 1
        }
        return count
    }

    private static func isHangul(_ unit: unichar) -> Bool {
        (0xAC00...0xD7A3).contains(unit) || (0x1100...0x11FF).contains(unit)
            || (0x3130...0x318F).contains(unit)
    }

    /// The stretches of a line set in Noto Sans, as contiguous **runs by
    /// context**.
    ///
    /// Anything reMarkableSans does not cover goes to Noto; Latin stays with
    /// the substitute face (`EmbeddedFonts`). Weak characters — digits,
    /// punctuation, spaces — have no script of their own and inherit it from
    /// the neighbouring strong ones: from the previous, and before the first
    /// strong one, from the next. The tablet segments its runs the same way,
    /// and a character cannot be assigned without its context.
    static func notoRanges(of string: String, in range: NSRange) -> [NSRange] {
        let text = string as NSString
        let length = range.length
        guard length > 0 else { return [] }

        // Each unit's script: `true` — Noto, `false` — other strong,
        // `nil` — weak, inherits from a neighbour.
        var isNoto = [Bool?](repeating: nil, count: length)
        for offset in 0..<length {
            let point = Int(text.character(at: range.location + offset))
            guard let scalar = UnicodeScalar(UInt32(point)),
                  scalar.properties.isAlphabetic || (0x3040...0x30FF).contains(point)
            else { continue }
            isNoto[offset] = !isLatin(point)
        }

        // Before the first strong character — its script; after it weak ones
        // inherit from the previous. A line with no strong characters stays
        // wholly "other".
        if let firstStrong = isNoto.compactMap({ $0 }).first {
            var current = firstStrong
            for offset in 0..<length {
                if let strong = isNoto[offset] { current = strong } else { isNoto[offset] = current }
            }
        }

        var found: [NSRange] = []
        var start: Int?
        for offset in 0..<length {
            let noto = isNoto[offset] == true
            if noto, start == nil { start = range.location + offset }
            if !noto, let begun = start {
                found.append(NSRange(location: begun, length: range.location + offset - begun))
                start = nil
            }
        }
        if let begun = start {
            found.append(NSRange(location: begun, length: range.location + length - begun))
        }
        return found
    }

    /// One Noto run split into the scripts it is made of, in order.
    ///
    /// Weak characters — spaces, digits, punctuation — carry on the script of
    /// what came before them, as they do when the runs are chosen in the
    /// first place: a full stop after a Hebrew word belongs to that word.
    static func scriptRuns(
        of string: String,
        in range: NSRange
    ) -> [(script: EmbeddedFonts.NotoScript, range: NSRange)] {
        let text = string as NSString
        var runs: [(EmbeddedFonts.NotoScript, NSRange)] = []
        var current: EmbeddedFonts.NotoScript?
        var start = range.location
        for index in range.location..<(range.location + range.length) {
            guard let scalar = UnicodeScalar(UInt32(text.character(at: index))),
                  scalar.properties.isAlphabetic
            else { continue }
            let script = EmbeddedFonts.NotoScript.of(scalar)
            guard let running = current else { current = script; continue }
            guard script != running else { continue }
            runs.append((running, NSRange(location: start, length: index - start)))
            current = script
            start = index
        }
        let tail = range.location + range.length - start
        if tail > 0 { runs.append((current ?? .general, NSRange(location: start, length: tail))) }
        return runs
    }

    /// Latin is what reMarkableSans covers: the substitute face with its own
    /// multiplier stands for it. Every other alphabetic script the tablet
    /// sets in the Noto family.
    private static func isLatin(_ point: Int) -> Bool {
        (0x41...0x5A).contains(point) || (0x61...0x7A).contains(point)
            || (0xC0...0x24F).contains(point)                // Latin with diacritics
            || (0x1E00...0x1EFF).contains(point)             // Latin Extended Additional
    }

    /// The attributes of one stretch of a line.
    ///
    /// Every combination of face, weight and slope is a file of its own in the
    /// package, so nothing here is faked — see `EmbeddedFonts`.
    static func attributes(
        size: Double,
        face: TypeFace,
        bold: Bool = false,
        italic: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        // CoreText's own attribute names, not AppKit's: this package has no UI
        // framework to borrow `.font` from.
        [
            NSAttributedString.Key(kCTFontAttributeName as String):
                EmbeddedFonts.font(size: size, face: face, bold: bold, italic: italic),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                PageRenderer.inkColour,
        ]
    }

    /// A stretch counted in Unicode scalars, the way the file numbers them.
    ///
    /// The file marks a face on scalars; `NSAttributedString` addresses
    /// UTF-16. For "abc" the two agree and for an emoji they do not, and the
    /// difference lands as an attribute on the wrong word or as a crash on a
    /// range past the end.
    private static func range(_ characters: Range<Int>, in line: String) -> NSRange? {
        let scalars = line.unicodeScalars
        guard characters.lowerBound >= 0, characters.upperBound <= scalars.count else { return nil }
        guard let start = scalars.index(
            scalars.startIndex,
            offsetBy: characters.lowerBound,
            limitedBy: scalars.endIndex
        ),
            let end = scalars.index(start, offsetBy: characters.count, limitedBy: scalars.endIndex)
        else { return nil }
        return NSRange(start..<end, in: line)
    }
}
