// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import RMLines
@testable import RMRender
import Testing

// Typed text, handwriting anchors, right-to-left, every paragraph kind.

// A list nested under another carries a style value of its own — 11 under a
// numbered list, 8 under checkboxes — and `tag 3` says how deep: the high half
// of the byte is the family, the low half the level.
@Test("The nesting level is read from tag 3, and the first level does not carry it")
func nestedListLevelIsReadFromTheThirdField() {
    #expect(ParagraphFormat(style: .numbered).level == 1)
    #expect(ParagraphFormat(style: .checkbox).level == 1)
    #expect(ParagraphFormat(raw: 11, second: 3, third: 33).level == 2)
    #expect(ParagraphFormat(raw: 11, second: 3, third: 34).level == 3)
    #expect(ParagraphFormat(raw: 8, second: 3, third: 17).level == 2)
    #expect(ParagraphFormat(raw: 8, second: 3, third: 18).level == 3)
    // Both new values are list items, or their text would keep the margin.
    #expect(ParagraphFormat(raw: 11, second: 3, third: 33).style == .numberedNested)
    #expect(ParagraphFormat(raw: 8, second: 3, third: 17).style?.isListItem == true)
    // A style we do not know is kept rather than dropped: the value itself is
    // what says where to look next.
    #expect(ParagraphFormat(raw: 99).style == nil)
    #expect(ParagraphFormat(raw: 99).raw == 99)
}

// The tablet numbers three levels three ways, and each level counts on its own:
// `1, 2, a, b, i, ii, 3` — the three follows the two.
// The tablet sets a bullet as a glyph, not a drawn shape, and the glyph
// depends on the level.
@Test("The bullet marker changes with the level: dot, circle, dash")
func bulletMarkerFollowsTheLevel() {
    #expect(PageRenderer.ListMarker.bullet(level: 1) == "\u{2022}")
    #expect(PageRenderer.ListMarker.bullet(level: 2) == "\u{25E6}")
    #expect(PageRenderer.ListMarker.bullet(level: 3) == "\u{2013}")
    // Value 5 is the nested bullet, not a "filled" one: one family.
    #expect(ParagraphStyle.bulletNested.listFamily == .bullet)
    #expect(ParagraphStyle.bullet.listFamily == .bullet)
    #expect(ParagraphStyle.checkboxNested.listFamily == .checkbox)
    #expect(ParagraphStyle.numberedNested.listFamily == .numbered)
    #expect(ParagraphStyle.heading.listFamily == nil)
    // The nested bullet's level is read where the other families read it:
    // the high half of tag 3 is simply nought for a bullet.
    #expect(ParagraphFormat(raw: 5, second: 3, third: 1).level == 2)
    #expect(ParagraphFormat(raw: 5, second: 3, third: 2).level == 3)
}

@Test("Numbering depends on the level: decimal, letters, roman")
func nestedListNumbersByLevel() {
    #expect(PageRenderer.ListMarker.label(ordinal: 1, level: 1) == "1.")
    #expect(PageRenderer.ListMarker.label(ordinal: 2, level: 2) == "b.")
    #expect(PageRenderer.ListMarker.label(ordinal: 2, level: 3) == "ii.")
    #expect(PageRenderer.ListMarker.label(ordinal: 4, level: 3) == "iv.")
    #expect(PageRenderer.ListMarker.label(ordinal: 27, level: 2) == "aa.")
}

@Test("A nested item indents one more list step")
func nestedListItemIndentsByLevel() throws {
    let text = TextBlock(
        originX: -576,
        originY: 234,
        lines: ["один", "два", "три"],
        formats: [
            0: ParagraphFormat(style: .numbered),
            1: ParagraphFormat(raw: 11, second: 3, third: 33),
            2: ParagraphFormat(raw: 11, second: 3, third: 34),
        ],
        columnWidth: 1152
    )
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    // Paragraphs start at 238, first-level items at 286, then 48 more each.
    #expect(abs(geometry.paragraphs[0].indent - 48) < 0.01)
    #expect(abs(geometry.paragraphs[1].indent - 96) < 0.01)
    #expect(abs(geometry.paragraphs[2].indent - 144) < 0.01)
    // Each level counts on its own.
    #expect(geometry.paragraphs.map(\.ordinal) == [1, 1, 1])
}

// Weak characters — digits, punctuation, spaces — have no script of their
// own and take it from their strong neighbours, the way the tablet does: its
// exports carry the digits of a Russian line in the Noto run (tabular, 18.30
// each) and the digits of an English line in the reMarkableSans run
// (proportional, the one at 13.44).
@Test("Weak characters inherit the script of their strong neighbours")
func weakCharactersFollowTheirContext() {
    func ranges(_ string: String) -> [NSRange] {
        TextGeometry.notoRanges(of: string, in: NSRange(location: 0, length: (string as NSString).length))
    }
    // A Russian line takes its punctuation and digits along.
    #expect(ranges("Привет, мир: 123.") == [NSRange(location: 0, length: 17)])
    // A Latin line gives Noto nothing.
    #expect(ranges("Hello, world: 123.") == [])
    // Digits between the two scripts follow the strong character before them.
    let mixed = ranges("Привет 123 hello")
    #expect(mixed == [NSRange(location: 0, length: 11)], "\(mixed)")
    // Weak characters before the first strong one take its script.
    #expect(ranges("«Привет»") == [NSRange(location: 0, length: 8)])
    #expect(ranges("123") == [])
    // Everything reMarkableSans has not got goes to the Noto branch — CJK
    // included: a fallback cascaded off the stretched sans would inherit
    // its multiplier.
    #expect(ranges("日本語です") == [NSRange(location: 0, length: 5)])
    // Right-to-left scripts ride the Noto branch too: the package carries
    // NotoSansArabic and NotoSansHebrew — the faces the tablet's exports
    // name — cascaded onto the Noto font, so the widths are the tablet's
    // rather than a system fallback's.
    #expect(ranges("שלום") == [NSRange(location: 0, length: 4)])
    #expect(ranges("مرحبا") == [NSRange(location: 0, length: 5)])
}

// The tablet's exports carry no italic cuts for the Noto scripts and
// synthesise the slant with the text matrix — `c = 0.3`, one value for every script, read
// off the tablet's exports. We slant by the same amount in the font's own
// matrix; a shear moves no advance, so the layout cannot drift.
@Test("The noto-branch italic is synthesised like the tablet's and moves no widths")
func syntheticItalicSlantsWithoutMovingWidths() {
    let upright = EmbeddedFonts.nonLatin(size: 32, face: .sans, bold: false)
    let slanted = EmbeddedFonts.nonLatin(size: 32, face: .sans, bold: false, italic: true)
    #expect(abs(CTFontGetMatrix(slanted).c - EmbeddedFonts.syntheticItalicSlant) < 0.001)
    #expect(CTFontGetMatrix(upright).c == 0)

    // The widths are the upright ones: the tablet's slanted runs carry the
    // very same advances, which is what keeps the wraps in step. Half a unit
    // over a sixteen-character line is CoreText's own rounding of the
    // transformed metrics — 0.19 — not a drift of the layout.
    let straight = PageRenderer.textWidth("Проверка наклона", size: 32, face: .sans)
    let attributed = NSMutableAttributedString(string: "Проверка наклона")
    TextGeometry.apply(
        size: 32, face: .sans, bold: false, italic: true,
        to: attributed, range: NSRange(location: 0, length: attributed.length)
    )
    let slantedWidth = CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(attributed), nil, nil, nil
    )
    #expect(abs(straight - slantedWidth) < 0.5)
}

// The digit `1` is the largest single miss of the substitute face: Noto sets
// it tabular at 17.64 where reMarkable Sans is proportional at 13.44.
// The per-glyph correction kerns it to the tablet's width — but only in a
// sans run: in a Noto run the tablet's digits are tabular too, and the
// correction would be a harm (`Calibration.sansGlyphShare`).
@Test("The per-glyph correction brings a digit to the tablet width — in sans runs only")
func glyphCorrectionAppliesInSansRunsOnly() {
    let corrected = PageRenderer.textWidth("1", size: 32, face: .sans)
    #expect(abs(corrected - 13.44) < 0.35, "\(corrected)")

    // The same digit in a Cyrillic context stays tabular: the noto run has
    // no kern, so two strings of equal composition differ by the correction.
    let inSans = PageRenderer.textWidth("a 1", size: 32, face: .sans)
    let inNoto = PageRenderer.textWidth("я 1", size: 32, face: .sans)
    let letterA = PageRenderer.textWidth("a", size: 32, face: .sans)
    let letterYa = PageRenderer.textWidth("я", size: 32, face: .sans)
    // Subtract the letters; what is left is space + digit in each context.
    let sansTail = inSans - letterA
    let notoTail = inNoto - letterYa
    #expect(notoTail - sansTail > 3, "in a Cyrillic context the digit is wider: \(notoTail) vs \(sansTail)")
}

// Cyrillic inside the serif styles is Noto Sans on the tablet, not a serif:
// the tablet sets the Russian of a heading and of an emphasised paragraph in
// NotoSans-Regular, with only the Latin stretches of the same lines in
// reMarkableSerifSmall. Our EB Garamond covers Cyrillic, so without an
// explicit substitution nothing would swap it out.
@Test("Serif-paragraph Cyrillic is set in Noto, and its lines are taller than Latin")
func serifCyrillicGoesToNotoAndLinesGrow() {
    // The substitution: a Cyrillic stretch under the serif face measures as
    // Noto (the same width the sans branch gives it), not as Garamond.
    let asSerif = PageRenderer.textWidth("Проверка", size: 46, face: .serif)
    let asSans = PageRenderer.textWidth("Проверка", size: 46, face: .sans)
    #expect(abs(asSerif - asSans) < 0.5, "\(asSerif) vs \(asSans)")

    // The heights: 88.00 for a Cyrillic heading against the Latin
    // 76.00, and 63.00 against 55.00 for an emphasised paragraph.
    let heading = ParagraphFormat(style: .heading)
    let emphasised = ParagraphFormat(style: .subheading, hasFurtherFields: true)
    #expect(TypeMetrics.lineHeight(of: heading, text: "Заголовок") == 88.00)
    #expect(TypeMetrics.lineHeight(of: heading, text: "Heading") == 76.00)
    #expect(TypeMetrics.lineHeight(of: emphasised, text: "Выделенный") == 63.00)
    #expect(TypeMetrics.lineHeight(of: emphasised, text: "Emphasised") == 55.00)
    // An emphasised paragraph over a Cyrillic body line steps 72.03 — the
    // ascent model gives 72.04.
    let step = TypeMetrics.step(
        from: emphasised, to: nil,
        text: "русское тело", previousText: "русский выделенный"
    )
    #expect(abs(step - 72.03) < 0.05, "\(step)")

    // The heading heights per script, from H1.pdf: the paragraph
    // model reproduces 176.00 / 181.00 / 224.00 exactly.
    #expect(TypeMetrics.lineHeight(of: heading, text: "עברית") == 88.00)
    #expect(TypeMetrics.lineHeight(of: heading, text: "日本語") == 93.00)
    #expect(TypeMetrics.lineHeight(of: heading, text: "ไทย") == 103.00)
    #expect(TypeMetrics.lineHeight(of: heading, text: "العربية") == 136.00)
    #expect(abs(TypeMetrics.step(
        from: heading, to: heading, text: "日本語", previousText: "日本語"
    ) - 181.00) < 0.05)
    #expect(abs(TypeMetrics.step(
        from: heading, to: heading, text: "العربية", previousText: "العربية"
    ) - 224.00) < 0.05)
    // The cross-style seam the full-height step misses by 18: a Latin body line
    // over an Arabic subheading. The tablet steps 105.41; the split model lands
    // within a fifth of a unit, where the full-height step gives 123.25.
    let seam = TypeMetrics.step(
        from: nil, to: ParagraphFormat(style: .subheading, hasFurtherFields: false),
        text: "العربية", previousText: "latin body"
    )
    #expect(abs(seam - 105.41) < 0.5, "\(seam)")

    // The italic of a serif style is a weight of its own: the tablet sets it
    // NotoSans-Light and slants — so do we.
    let cut = EmbeddedFonts.nonLatinCut(face: .serif, bold: false, italic: true)
    #expect(cut.resource == "NotoSans-Light")
    let light = EmbeddedFonts.nonLatin(size: 64, face: .serif, bold: false, italic: true)
    #expect(abs(CTFontGetMatrix(light).c - EmbeddedFonts.syntheticItalicSlant) < 0.001)
    // The Light file is really in the bundle: a fallback would answer with
    // Helvetica and the widths would drift without a word.
    #expect(
        PageRenderer.textWidth("Проверка", size: 64, face: .serif, italic: true)
            < PageRenderer.textWidth("Проверка", size: 64, face: .serif),
        "the light cut sets narrower than the regular"
    )
}

// The horizontal the file declares wins over the one the layout arrives at:
// where the two agree nothing changes, and where the caret is ambiguous — the
// boundary of two writing directions — only the file knows the answer. The
// vertical stays the layout's: the file does not carry one.
@Test("The anchor horizontal from the file wins over the computed one; the vertical stays ours")
func fileOriginXWinsOverTheComputedOne() throws {
    let text = typedText(["hello world", "second"])
    let computed = try placedPoint(anchoredStroke(to: 1, offset: 2), on: text)
    let declared = try placedPoint(
        anchoredStroke(to: 1, offset: 2, originX: -244.0625), on: text
    )
    #expect(abs(Double(declared.x) - -244.0625) < 0.001)
    #expect(declared.x != computed.x)
    #expect(declared.y == computed.y, "the file carries no vertical — it is computed")
}

// Handwriting anchored to typed text is counted from its paragraph, and the
// parser cannot say where that paragraph lands: one too long for a line takes
// more than one step, and how much more takes a font and a column width. A
// flat step per paragraph would answer wrong: everything anchored below a
// wrapped paragraph would stand that paragraph's overflow too high.
@Test("Handwriting anchored below a wrapped paragraph goes down with it")
func anchoredStrokeFollowsAWrappedParagraph() throws {
    let long = String(repeating: "abcdefghij ", count: 24)
    let short = typedText(["one", "two", "three"])
    let wrapped = typedText([long, "two", "three"])

    let extra = TextGeometry(wrapped, pageSize: PageRenderer.defaultPageSize)
        .paragraphs[0].lines.count - 1
    #expect(extra > 0, "the fixture has to wrap for this test to say anything")

    let stroke = anchoredStroke(to: 2)
    let onShort = try placedPoint(stroke, on: short)
    let onWrapped = try placedPoint(stroke, on: wrapped)

    // A wrapped line down for every line the paragraph above took, and not one
    // paragraph step whatever it took.
    #expect(
        abs(Double(onWrapped.y - onShort.y) - Double(extra) * TypeMetrics.wrapStep) < 0.01,
        "\(onWrapped.y) against \(onShort.y)"
    )
}

// The pen, not the corner of a box: against the tablet's export,
// handwriting fastened to a line counts from that line's **baseline**
// and from the margin plus what stands typed before it. Counting from the top of
// the paragraph's box puts it an ascent too high — 63.2 units on a heading of 64.
@Test("An anchor counts from the baseline of its line, not from the top of the box")
func anchorCountsFromTheBaseline() throws {
    let text = typedText(["one", "two", "three", "four"])
    for paragraph in 0..<4 {
        let point = try placedPoint(anchoredStroke(to: paragraph), on: text)
        // At the start of a line the pen is at the margin: the origin plus the
        // four units the text is inset by.
        #expect(abs(Double(point.x) - (text.originX + TypeMetrics.textInset)) < 0.01)
        let expected = text.originY
            + TypeMetrics.firstBaselineDrop(size: TypeMetrics.body)
            + Double(paragraph) * TypeMetrics.paragraphStep
        #expect(abs(Double(point.y) - expected) < 0.01, "paragraph \(paragraph)")
    }
}

// The anchor names a character, and a character of a wrapped paragraph stands on
// one of its visual lines — the fourth of four on the page this test checks
// against. Answering with the paragraph instead puts the handwriting three
// wrapped lines too high and a whole line's worth of text too far left.
@Test("An anchor at the end of a wrapped paragraph lands on its last line, at its end")
func anchorFollowsTheCharacterToItsVisualLine() throws {
    let long = String(repeating: "abcdefghij ", count: 24)
    let text = typedText([long])
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    let paragraph = geometry.paragraphs[0]
    #expect(paragraph.lines.count > 1, "the fixture has to wrap for this test to say anything")

    let start = try placedPoint(anchoredStroke(to: 0, offset: 0), on: text)
    let end = try placedPoint(anchoredStroke(to: 0, offset: long.count), on: text)

    // Down by the wrapped lines the paragraph took, and right by the text
    // standing on the last of them.
    let lastBaseline = try #require(paragraph.lines.last?.baseline)
    #expect(abs(Double(end.y) - lastBaseline) < 0.01)
    #expect(
        abs(Double(end.y - start.y)
            - Double(paragraph.lines.count - 1) * TypeMetrics.wrapStep) < 0.01
    )
    #expect(Double(end.x) > Double(start.x) + 100, "the pen ends far along the last line")
}

// The step out of a paragraph belongs to that paragraph, and the anchoring
// reads it where the drawing reads it: a heading leaves 115.36 behind it where
// an ordinary paragraph leaves 69.55.
@Test("A heading pushes the handwriting under it as far as it pushes the text")
func anchoredStrokeTakesTheStepOfTheParagraphAbove() throws {
    let plain = typedText(["Head", "text"])
    let heading = typedText(["Head", "text"], formats: [0: ParagraphFormat(style: .heading)])

    let underPlain = try placedPoint(anchoredStroke(to: 1), on: plain)
    let underHeading = try placedPoint(anchoredStroke(to: 1), on: heading)

    // Two contributions, and both belong to the paragraph above: the step it
    // leaves behind, and the deeper first baseline its own size takes.
    let expected = TypeMetrics.step(from: ParagraphFormat(style: .heading), to: nil)
        - TypeMetrics.paragraphStep
        + TypeMetrics.firstBaselineDrop(size: TypeMetrics.heading1)
        - TypeMetrics.firstBaselineDrop(size: TypeMetrics.body)
    #expect(abs(Double(underHeading.y - underPlain.y) - expected) < 0.01)
}

// A stroke that is not anchored is at the sheet's coordinates already, and one
// that has been placed is too: the anchor is spent in the moving, or a second
// pass would move it twice.
@Test("Only the anchored strokes are moved, and only once")
func placingLeavesTheRestAlone() throws {
    let text = typedText(["one", "two"])
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)

    let free = Stroke(
        tool: .ballpoint2,
        color: .black,
        thicknessScale: 2,
        points: [StrokePoint(x: 10, y: 20, width: 8, pressure: 100)]
    )
    let placed = try #require(geometry.placing([free, anchoredStroke(to: 1)]).last)

    #expect(geometry.placing([free]).first?.points.first == free.points.first)
    #expect(placed.anchor == nil, "a placed stroke stands in the sheet's coordinates like any other")
    #expect(geometry.placing([placed]).first?.points.first == placed.points.first)
}

// A typed list is text plus a marker the text does not contain: the bullets
// and the checkboxes live in the styles of the paragraphs, and a page whose
// styles are dropped comes out as a list with nothing in front of its items.
// That is exactly what a live notebook looked like.
@Test("A bullet and a checkbox are drawn, and an empty item still gets one")
func rendersListMarkers() throws {
    let plain = try PageRenderer.pdf(pages: [typedPage(lines: ["one", "two"])])
    let marked = try PageRenderer.pdf(
        pages: [typedPage(lines: ["one", "two"], styles: [0: .bullet, 1: .checkbox])]
    )
    // An item with no text of its own — three of those stood in the live page.
    let empty = try PageRenderer.pdf(pages: [typedPage(lines: [""], styles: [0: .checkbox])])

    #expect(marked.count > plain.count, "the markers add drawing that plain text does not have")
    #expect(try ink(in: empty) > 0, "an empty checkbox is still a checkbox")
}

// A done item is not merely a ticked box: the tablet fills the box and strikes
// the text through — against its own export, an outlined
// box with a dark tick alone reads as "half done".
@Test("A ticked item is filled in and struck through")
func rendersCheckedItem() throws {
    let unchecked = try PageRenderer.pdf(
        pages: [typedPage(lines: ["done"], styles: [0: .checkbox])]
    )
    let checked = try PageRenderer.pdf(
        pages: [typedPage(lines: ["done"], styles: [0: .checkboxChecked])]
    )

    // The filled box and the rule through the text: more ink either way.
    #expect(try ink(in: checked) > (try ink(in: unchecked)))
}

// The numbers of a numbered list are not in the file at all — the tablet
// counts the items, and a run is broken by anything that is not one of them.
@Test("Numbered items count themselves, and the count starts again after a break")
func numbersRestartAfterANonItem() throws {
    let pdf = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["one", "two", "text", "again"],
                styles: [0: .numbered, 1: .numbered, 3: .numbered]
            )
        ]
    )
    let text = try #require(PDFDocument(data: pdf)?.page(at: 0)?.string)

    #expect(text.contains("1."))
    #expect(text.contains("2."))
    // The plain paragraph between them starts the count over.
    #expect(text.components(separatedBy: "1.").count - 1 == 2, "two runs, each starting at one")
}

// The faces have to come out of the package, not off the machine: a font
// found by name is a font that may be missing, renamed or a different cut, and
// then the same notebook looks different on two Macs. The fallback exists, but
// reaching it means the build is broken.
@Test("Typed text is set in the faces we carry")
func usesTheEmbeddedFaces() throws {
    let body = CTFontCopyPostScriptName(EmbeddedFonts.body(size: 20)) as String
    let bold = CTFontCopyPostScriptName(EmbeddedFonts.bold(size: 20)) as String
    let serif = CTFontCopyPostScriptName(EmbeddedFonts.serif(size: 20)) as String

    #expect(body.contains("NotoSans"), "got \(body)")
    #expect(serif.contains("EBGaramond"), "got \(serif)")
    // By weight rather than by name: a test that reads the spelling of a cut
    // would fail on a renaming that changes nothing.
    #expect(bold.contains("NotoSans"), "got \(bold)")
    let traits = try #require(CTFontCopyTraits(EmbeddedFonts.bold(size: 20)) as? [String: Any])
    let weight = traits[kCTFontWeightTrait as String] as? Double ?? 0
    // The tablet's own export names `reMarkableSans-Bold` for a bold stretch,
    // so a middle weight will not do: 0.4 is what a real Bold answers.
    #expect(weight > 0.3, "the bold face is bold: \(weight)")
}

// A list leaves no gap behind it. On the tablet's own export of a page
// with a list of seven items, the step from the last item to the
// ordinary paragraph below is 69.55, the same as any other. Doubling that step
// would put a phantom blank line under every list — the blank
// line in that document is an empty paragraph the document itself carries, and
// an empty paragraph is a line like any other.
@Test("Ordinary text after a list starts one step lower, not two")
func listLeavesNoGapBehindIt() throws {
    let withList = try PageRenderer.pdf(
        pages: [typedPage(lines: ["item", "text"], styles: [0: .bullet])]
    )
    let withoutList = try PageRenderer.pdf(pages: [typedPage(lines: ["item", "text"])])

    // By the lowest ink rather than by the height: the marker of the first item
    // is drawn above its baseline and makes the block taller by itself, while
    // the question here is only where the *second* line stands.
    #expect(abs((try lowestInk(in: withList)) - (try lowestInk(in: withoutList))) <= 1)
}

// The step belongs to the paragraph left behind, and a heading leaves more room
// than an ordinary line. On the export: 115.36 after a heading, 85.75
// after an emphasised paragraph, 63.30 after a subheading — and no formula on
// the two type sizes fits, since 36 above 32 leaves less room than 32 above 32.
@Test("The step out of a paragraph depends on the paragraph, not on the size")
func stepDependsOnTheParagraphAbove() throws {
    let plain = ParagraphFormat(style: .plain)
    let item = ParagraphFormat(style: .bullet)
    let heading = ParagraphFormat(style: .heading)
    let subheading = ParagraphFormat(style: .subheading)
    let emphasis = ParagraphFormat(style: .subheading, hasFurtherFields: true)
    func step(_ from: ParagraphFormat?, _ to: ParagraphFormat?) -> Double {
        TypeMetrics.step(from: from, to: to)
    }
    // Within two hundredths rather than exactly: the ascent-split model
    // rebuilds the gaps as round numbers (24 below every
    // paragraph; 64/32/16 above the display styles), and the exported steps
    // are reproduced to the rounding of 0.925 × size.
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.02 }

    // Every transition the exports carry, and every one of them exact. Ten
    // numbers against eight unknowns — the table is solved, not fitted.
    #expect(close(step(nil, nil), TypeMetrics.paragraphStep))
    #expect(close(step(plain, plain), 69.55))
    #expect(close(step(item, plain), 69.55))
    // The pair that rules out one number per paragraph: the same heading
    // above leaves 70.41 or 115.36 depending on what stands below it.
    #expect(close(step(heading, plain), 70.41))
    #expect(close(step(heading, heading), 164.00))
    #expect(close(step(heading, emphasis), 115.36))
    #expect(close(step(emphasis, subheading), 85.75))
    #expect(close(step(emphasis, item), 66.05))
    #expect(close(step(subheading, emphasis), 108.25))
    #expect(close(step(item, heading), 163.14))
    #expect(close(step(item, emphasis), 114.50))
    // The subheading leaves less room than an ordinary paragraph does — which
    // is what rules out any formula on the type sizes alone.
    #expect(close(step(subheading, plain), 63.30))

    // The line a paragraph wraps to is its own height, and it is not a share of
    // the size: a subheading of 36 wraps tighter than a body of 32.
    #expect(TypeMetrics.lineHeight(of: plain) == 45.55)
    #expect(TypeMetrics.lineHeight(of: subheading) == 43.00)
    #expect(TypeMetrics.lineHeight(of: emphasis) == 55.00)
    #expect(TypeMetrics.lineHeight(of: heading) == 76.00)

    // Which shows on the page: a heading pushes what follows it further down.
    let afterHeading = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["Head", "text"],
                formats: [0: ParagraphFormat(style: .heading)]
            )
        ]
    )
    let withoutHeading = try PageRenderer.pdf(pages: [typedPage(lines: ["Head", "text"])])
    #expect(try inkHeight(in: afterHeading) > inkHeight(in: withoutHeading))
}

// The items of a list stand 48 units to the right of the margin — on
// the export, paragraphs begin at 238 and every item at 286. A whole line
// step would be half again too far.
@Test("A list item is indented by the known amount")
func listIndentIsMeasured() throws {
    #expect(TypeMetrics.listIndent == 48)
    let item = try PageRenderer.pdf(pages: [typedPage(lines: ["item"], styles: [0: .bullet])])
    let plain = try PageRenderer.pdf(pages: [typedPage(lines: ["item"])])
    // The bullet sits at the margin and the text moves right of it, so the ink
    // of the two spans a different width.
    #expect(try ink(in: item) != (try ink(in: plain)))
}

// Two steps, not one. The tablet moves 45.55 units to the continuation of a
// paragraph and 69.55 to a new one — read off the baselines of its own
// export. One step of 70 for both puts a wrapped line 53% too far down, and a
// paragraph of three lines nearly a whole line out of place.
@Test("A wrapped line sits closer than a new paragraph")
func wrapStepIsShorterThanTheParagraphStep() throws {
    // Two visual lines either way: once by wrapping one paragraph, once as two
    // paragraphs of the same words.
    let half = String(repeating: "abcdefghij ", count: 6)
    let wrapped = try PageRenderer.pdf(pages: [typedPage(lines: [half + half])])
    let separate = try PageRenderer.pdf(pages: [typedPage(lines: [half, half])])

    let wrappedHeight = try inkHeight(in: wrapped)
    let separateHeight = try inkHeight(in: separate)

    #expect(wrappedHeight < separateHeight)
    // The difference is the difference between the steps — 24 units, and a
    // unit of `.rm` comes to 0.424 pt on a sheet this wide.
    let expected = (TypeMetrics.paragraphStep - TypeMetrics.wrapStep)
        * (PaperSize.a4.points().width / PageRenderer.defaultPageSize.width)
    #expect(abs(Double(separateHeight - wrappedHeight) - expected) < 3, "\(expected)")
}

// The origin the file gives is the top of the first line, not its baseline.
// Against the tablet's own export of a typed page, the
// block starts at 234 and the first baseline stands at 267.59. Drawing the
// first line straight at the origin puts the whole block 10.6 pt too high.
@Test("The first line stands a baseline below the origin, not on it")
func firstBaselineSitsBelowTheOrigin() throws {
    let pdf = try PageRenderer.pdf(pages: [typedPage(lines: ["Ag"])])
    let image = try raster(pdf)
    let firstRow = (0..<image.height).first { row in
        (0..<image.width).contains { image.dark[row * image.width + $0] }
    }
    let top = try #require(firstRow)

    // `typedPage` starts its text at y 300 of a 1404 × 1872 page, and the sheet
    // is A4 wide, so a unit comes to 0.424 pt. Rows are counted from the top,
    // and the page maps onto them one for one after the scale.
    let scale = Double(PaperSize.a4.points().width / PageRenderer.defaultPageSize.width)
    let baseline = (300 + TypeMetrics.firstBaselineDrop(size: TypeMetrics.body)) * scale
    // A capital A stands above its baseline by the cap height, about 0.7 of the
    // size, so the ink begins that much higher up.
    let capHeight = TypeMetrics.body * 0.7 * scale
    #expect(
        abs(Double(top) - (baseline - capHeight)) < 5,
        "ink starts at row \(top), the baseline is reckoned at \(baseline)"
    )
    // And plainly: the ink must not begin at the origin itself, which is where
    // it would begin without the drop.
    #expect(Double(top) > 300 * scale - capHeight, "the ink starts below the origin, not at it")
}

// The third level of heading, the one `tag 1` alone cannot see: an emphasised
// paragraph is set at 46 units and one whose style record goes on at 36.
@Test("A subheading is smaller than an emphasised paragraph")
func subheadingIsSetSmaller() throws {
    let emphasis = try PageRenderer.pdf(
        pages: [typedPage(lines: ["Ag"], formats: [0: ParagraphFormat(style: .subheading)])]
    )
    let subheading = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["Ag"],
                formats: [0: ParagraphFormat(style: .subheading, hasFurtherFields: true)]
            )
        ]
    )
    let heading = try PageRenderer.pdf(
        pages: [typedPage(lines: ["Ag"], formats: [0: ParagraphFormat(style: .heading)])]
    )

    // The bare `{1: 3}` is the smaller of the two: 36 against 46.
    #expect(try inkHeight(in: emphasis) < (try inkHeight(in: subheading)))
    #expect(try inkHeight(in: subheading) < (try inkHeight(in: heading)))
}

// Bold and italic live on the characters; drawn as plain text, an accent
// inside a note would disappear without a word.
@Test("A bold stretch is drawn heavier and an italic one leans")
func drawsFaces() throws {
    let plain = try PageRenderer.pdf(pages: [typedPage(lines: ["one two three"])])
    let bold = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["one two three"],
                faces: [0: [FaceRun(range: 4..<7, bold: true, italic: false)]]
            )
        ]
    )
    let italic = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["one two three"],
                faces: [0: [FaceRun(range: 4..<7, bold: false, italic: true)]]
            )
        ]
    )

    #expect(try ink(in: bold) > (try ink(in: plain)), "a heavier face puts down more ink")
    // Pixel by pixel rather than by their number: a leaning glyph covers about
    // as much of the paper as an upright one, and on this line the two counts
    // came out equal to the pixel.
    #expect(try raster(italic).dark != (try raster(plain).dark), "a leaning face is not the upright one")
}

// Every weight and slope is a cut of its own in the package, not a trick played
// on the regular one. A test by trait rather than by file name: a renaming that
// changes nothing must not fail, and a shear that leaves the traits untouched
// must not pass.
@Test("Bold and italic are cuts of their own, in both families")
func facesAreRealCuts() {
    func traits(_ font: CTFont) -> (weight: Double, slant: Double, matrix: CGAffineTransform) {
        let all = CTFontCopyTraits(font) as NSDictionary
        return (
            weight: all[kCTFontWeightTrait as String] as? Double ?? 0,
            slant: all[kCTFontSlantTrait as String] as? Double ?? 0,
            matrix: CTFontGetMatrix(font)
        )
    }

    for face in [TypeFace.sans, .sansMedium, .serif] {
        let serif = face == .serif
        let plain = traits(EmbeddedFonts.font(size: 32, face: face))
        let bold = traits(EmbeddedFonts.font(size: 32, face: face, bold: true))
        let italic = traits(EmbeddedFonts.font(size: 32, face: face, italic: true))
        let both = traits(EmbeddedFonts.font(size: 32, face: face, bold: true, italic: true))

        // A subheading's own face is already a weight above the body, so only
        // the other two start from nothing.
        if face == .sansMedium {
            #expect(plain.weight > 0.1 && plain.weight < bold.weight, "face: \(face)")
        } else {
            #expect(plain.weight == 0, "face: \(face)")
        }
        #expect(bold.weight > 0.1, "serif: \(serif), got \(bold.weight)")
        #expect(plain.slant == 0, "serif: \(serif)")
        // Drawn, not sheared: the slope is a property of the face, and the
        // font matrix stays the identity it was. CoreText reports the slope on
        // a scale of its own — both cuts answer 0.069, not the tangent of
        // their eleven and twelve degrees — so the test asks whether it leans,
        // not by how much.
        #expect(italic.slant > 0.05, "serif: \(serif), got \(italic.slant)")
        #expect(italic.matrix.c == 0, "serif: \(serif) — the shear is gone")
        // Bold italic is the bold cut sheared, the way the tablet sets it —
        // its exports name the bold face for it — so its widths are the
        // bold's and the lean is in the matrix.
        #expect(both.weight == bold.weight, "serif: \(serif)")
        #expect(abs(both.matrix.c - EmbeddedFonts.syntheticItalicSlant) < 0.001, "serif: \(serif) — bold italic leans by the matrix")
    }

    // The names the two families are actually made of, so that a wrong file in
    // the folder is a failure and not a surprise on someone's page.
    let names = [false, true].flatMap { serif -> [String] in
        [(false, false), (true, false), (false, true), (true, true)].map { bold, italic in
            CTFontCopyPostScriptName(
                EmbeddedFonts.font(size: 32, face: serif ? .serif : .sans, bold: bold, italic: italic)
            ) as String
        }
    }
    #expect(names.prefix(4).allSatisfy { $0.contains("NotoSans") }, "got \(names)")
    #expect(names.suffix(4).allSatisfy { $0.contains("EBGaramond") }, "got \(names)")
    // Six files, not eight: bold italic shares the bold's.
    #expect(Set(names).count == 6, "six cuts, not one repeated: \(names)")
    #expect(names[1] == names[3] && names[5] == names[7], "bold italic is the bold's file: \(names)")
}

@Test("A stretch past the end of its line is dropped, not drawn wrongly")
func aFaceOutsideTheLineIsIgnored() throws {
    // The file counts characters and the string counts UTF-16; a range that
    // does not fit is a range we have misread, and drawing it would put the
    // attribute on the wrong word or ask for bytes that are not there.
    let pdf = try PageRenderer.pdf(
        pages: [
            typedPage(
                lines: ["short"],
                faces: [0: [FaceRun(range: 3..<99, bold: true, italic: false)]]
            )
        ]
    )
    #expect(try ink(in: pdf) > 0, "the line is still drawn")
}

// The width the file declares beats the width worked out from the origin: the
// derivation holds only while the column is centred on the sheet.
@Test("A declared column wraps the text the origin would have let through")
func declaredColumnWidthWraps() throws {
    let line = String(repeating: "abcdefghij ", count: 5)
    let wide = try PageRenderer.pdf(pages: [typedPage(lines: [line])])
    let narrow = try PageRenderer.pdf(pages: [typedPage(lines: [line], columnWidth: 300)])

    #expect(try inkHeight(in: narrow) > (try inkHeight(in: wide)))
}

// A paragraph wider than the column is wrapped by the tablet; without wrapping
// it would run off the sheet here: a 163-character paragraph would be cut in
// the middle of a word, with everything after it lost.
@Test("A long paragraph is wrapped instead of running off the sheet")
func wrapsLongParagraphs() throws {
    let long = String(repeating: "abcdefghij ", count: 40)
    let pdf = try PageRenderer.pdf(pages: [typedPage(lines: [long])])
    let provider = try #require(CGDataProvider(data: pdf as CFData))
    let document = try #require(CGPDFDocument(provider))
    let page = try #require(document.page(at: 1))
    let text = try #require(PDFDocument(data: pdf)?.page(at: 0)?.string)

    // Everything typed is on the sheet: nothing was clipped at the edge.
    #expect(text.filter { !$0.isWhitespace }.count == long.filter { !$0.isWhitespace }.count)
    // And it took more than one line to get there.
    #expect(text.split(separator: "\n").count > 1)
    #expect(page.getBoxRect(.mediaBox).width > 0)
}

@Test("Typed text reaches the PDF")
func rendersTypedText() throws {
    // The regression this guards: parsing text only to position the handwriting
    // anchored to it, without drawing the text itself, renders a
    // notebook typed rather than written to an empty sheet.
    let pdf = try PageRenderer.pdf(pages: [typedPage(lines: ["Typed line", "Second line"])])

    // The text operators themselves sit in the content stream, which
    // CoreGraphics may compress — so looking for `BT` in the bytes proves
    // nothing either way. The font resource, on the other hand, is written
    // into the PDF's object table in the clear, and it appears only if
    // something was actually set in type.
    let content = String(decoding: pdf, as: UTF8.self)
    #expect(content.contains("/Font"), "a page with text must carry a font resource")

    // And the same page without the text must not: otherwise the assertion
    // above would hold for a blank sheet too.
    let blank = try PageRenderer.pdf(pages: [RMPage(strokes: [], skippedBlocks: 0)])
    #expect(!String(decoding: blank, as: UTF8.self).contains("/Font"))
    #expect(pdf.count > blank.count)
}

@Test("A page of text alone does not count as empty")
func typedTextWidensTheSheet() {
    // Bounds computed from strokes alone — of which there are none — would
    // leave text past the page edge cut off.
    let page = typedPage(lines: Array(repeating: "line", count: 40))
    let bounds = PageRenderer.contentBounds(of: page, pageSize: PageRenderer.defaultPageSize, edge: .ribbon)

    // Forty lines at a step of 70 run well past the height of a page.
    #expect(bounds.height > PageRenderer.defaultPageSize.height)
}

@Test("A width less its rightmost glyph leaves the glyph off, never a mark")
func widthLessTheRightmostGlyph() {
    // "Hi" less the "i" is "H" — to the kerning of the pair.
    let hi = PageRenderer.textWidth("Hi", size: 32, face: .sans, lessRightmostGlyph: true)
    let h = PageRenderer.textWidth("H", size: 32, face: .sans)
    #expect(abs(hi - h) < 0.5, "\(hi) vs \(h)")
    // A Thai consonant with its mark: the mark reaches farthest right by
    // origin, but it is the consonant that goes.
    let marked = PageRenderer.textWidth("ต์", size: 32, face: .sans, lessRightmostGlyph: true)
    #expect(marked < 1, "\(marked)")
}

@Test("Korean wraps at spaces, not between syllables")
func koreanWrapsAtSpaces() throws {
    // Two sentences of the corpus, long enough to wrap twice at the body
    // size. The tablet breaks Hangul at spaces like Latin; CoreText alone
    // breaks it between syllables like the ideographs.
    let sentence = "키스의 고유조건은 입술끼리 만나야 하고 특별한 기술은 필요치 않다. "
        + "나는 유리를 먹을 수 있어요. 그래도 아프지 않아요."
    let page = typedPage(lines: [sentence])
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    let paragraph = try #require(geometry.paragraphs.first)
    #expect(paragraph.lines.count >= 2, "the sentence must wrap for the rule to matter")
    let storage = sentence as NSString
    for line in paragraph.lines.dropLast() {
        let last = storage.character(at: line.range.location + line.range.length - 1)
        #expect(last == 0x20, "a line ends on a space, not inside a word")
    }
}

@Test("A sheet grown by text keeps the tablet's room under the last line")
func typedTextKeepsAFootBelowItsFrame() throws {
    let page = typedPage(lines: Array(repeating: "line", count: 40))
    let text = try #require(page.text)
    let frame = try #require(TextGeometry(text, pageSize: PageRenderer.defaultPageSize).frameBottom)
    let bounds = PageRenderer.contentBounds(
        of: page, pageSize: PageRenderer.defaultPageSize, edge: .ribbon
    )
    // The frame — last baseline, its descent and the paragraph's room below
    // — plus the foot, in the page's own units counted from the top.
    let bottom = Double(PageRenderer.defaultPageSize.height - bounds.minY)
    #expect(abs(bottom - (frame + PageRenderer.InkEdge.textFoot)) < 0.01, "\(bottom) vs \(frame)")
}

@Test("Cyrillic survives the way to the PDF")
func rendersCyrillic() throws {
    // Half of this library is in Russian. Drawing through `showText` would
    // put it through a single-byte encoding and turn it into question marks;
    // this is what keeps the renderer on CoreText.
    let pdf = try PageRenderer.pdf(pages: [typedPage(lines: ["Кириллица"])])
    #expect(String(decoding: pdf, as: UTF8.self).contains("/Font"))
    // The same line in Latin gives a file of comparable size. Cyrillic
    // falling out of the encoding would show up as a page with the font
    // resource present and nothing drawn through it.
    let latin = try PageRenderer.pdf(pages: [typedPage(lines: ["Kirillitsa"])])
    #expect(Double(pdf.count) > Double(latin.count) * 0.5)
}
@Test("An anchor to the first character puts the pen at the text edge, not past the first letter")
func anchorToTheFirstCharacterStandsAtTheMargin() throws {
    let page = typedPage(lines: ["Wide opening glyph"])
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)

    // The edge of the set text: origin plus inset — where the tablet
    // starts an anchor to character 1.
    let margin = text.originX + TypeMetrics.textInset
    let first = geometry.pen(at: TextAnchor(paragraph: 0, offset: 1))
    #expect(abs(first.x - margin) < 0.001, "\(first.x) vs the edge \(margin)")

    // Zero is the start-of-paragraph sentinel, not a character: it gives
    // the same edge.
    #expect(geometry.pen(at: TextAnchor(paragraph: 0, offset: 0)).x == first.x)

    // The second character stands off the edge by the width of the first —
    // a `W`, one of the widest letters.
    let second = geometry.pen(at: TextAnchor(paragraph: 0, offset: 2))
    let firstGlyph = PageRenderer.textWidth("W", size: TypeMetrics.body, face: .sans)
    #expect(abs(second.x - margin - firstGlyph) < 0.5, "\(second.x - margin) vs \(firstGlyph)")
}

// A character on a line boundary belongs to the line that begins there:
// the pen stands before the character, so the line is the one the character
// lies in.
@Test("An anchor to the first character of a new line takes that line, not the previous one")
func anchorAtALineBreakTakesTheLineThatBegins() throws {
    // A paragraph guaranteed to wrap: one word repeated many times.
    let page = typedPage(lines: [String(repeating: "wrap ", count: 60)])
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    let paragraph = try #require(geometry.paragraphs.first)
    try #require(paragraph.lines.count > 1, "the paragraph must wrap or the test is empty")

    // The first character of the second visual line. In the file's count it
    // is one greater than in ours.
    let firstOfSecond = paragraph.lines[1].range.location
    let pen = geometry.pen(at: TextAnchor(paragraph: 0, offset: firstOfSecond + 1))

    #expect(pen.y == paragraph.lines[1].baseline, "the pen must stand on the second line")
    // And at its left edge: before the line's first character.
    let margin = text.originX + TypeMetrics.textInset
    #expect(abs(pen.x - margin) < 0.001, "\(pen.x) vs the edge \(margin)")

    // And the last character of the first line stays on it.
    let lastOfFirst = geometry.pen(at: TextAnchor(paragraph: 0, offset: firstOfSecond))
    #expect(lastOfFirst.y == paragraph.lines[0].baseline)
}

// "After the text" and a paragraph's newline come out of RMLines one past the
// letters: the character the pen would stand before is the one that would
// come next. Without `anchor_origin_x` the pen is computed, and it has to
// land after the last letter, not before it.
@Test("An anchor one past the letters puts the pen after the text")
func anchorPastTheLettersStandsAfterTheText() throws {
    let words = "abc"
    let page = typedPage(lines: [words])
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)

    // Measured against the caret before the last letter rather than the
    // string's width: the caret offsets leave out the tracking `textWidth`
    // adds, and what matters is which side of the `c` the pen is on.
    let count = words.unicodeScalars.count
    let beforeLast = geometry.pen(at: TextAnchor(paragraph: 0, offset: count))
    let end = geometry.pen(at: TextAnchor(paragraph: 0, offset: count + 1))
    let last = PageRenderer.textWidth("c", size: TypeMetrics.body, face: .sans)
    #expect(end.x - beforeLast.x > last * 0.8, "\(end.x - beforeLast.x) vs \(last)")

    // On a wrapped paragraph the end is on the last line, not the first.
    let wrapped = typedPage(lines: [String(repeating: "wrap ", count: 60) + "end"])
    let wrappedText = try #require(wrapped.text)
    let wrappedGeometry = TextGeometry(wrappedText, pageSize: PageRenderer.defaultPageSize)
    let paragraph = try #require(wrappedGeometry.paragraphs.first)
    try #require(paragraph.lines.count > 1, "the paragraph must wrap or the test is empty")
    let letters = paragraph.text.unicodeScalars.count
    let pen = wrappedGeometry.pen(at: TextAnchor(paragraph: 0, offset: letters + 1))
    #expect(pen.y == paragraph.lines[paragraph.lines.count - 1].baseline)
}

// MARK: - Right-to-left text with handwriting on both sides

/// "السلام عليكم" — "peace be upon you", the everyday Arabic greeting.
///
/// Chosen for what it is made of rather than for what it says: two words,
/// twelve scalars, letters that join in all four positional forms, and not one
/// combining mark. Without marks the file's scalar count is plainly the count
/// of the letters, so a miscount here cannot hide behind a diacritic the way
/// it does in `charactersAreNumberedInScalars` — that fixture tests the
/// counting, this one tests the direction. Every scalar of it answers
/// `ScriptClass.isStrongRightToLeft`.
private let arabicGreeting = "السلام عليكم"

/// A page of one right-to-left paragraph with handwriting fastened on both
/// sides of it.
///
/// The two anchors are the ends of the same line, and in Arabic those ends are
/// swapped: the first character stands at the **right** margin and the last at
/// the left. One stroke hangs off each, running away from the text — the red
/// one to the right of its pen, the green one to the left — so the pair
/// brackets the column and a direction read backwards puts both on one side.
private func arabicFlankedPage(declaredOriginX: (right: Float, left: Float)? = nil) -> Data {
    let header = RMParser.header.utf8.count
    let scalars = UInt64(arabicGreeting.unicodeScalars.count)
    let firstCharacter: (author: UInt8, counter: UInt64) = (1, 10)
    let lastCharacter: (author: UInt8, counter: UInt64) = (1, 10 + scalars - 1)
    // A node per anchor: one tree node cannot hold two different characters.
    let rightNode: (author: UInt8, counter: UInt64) = (1, 1)
    let leftNode: (author: UInt8, counter: UInt64) = (1, 2)

    let text = makeTextPage(
        records: [TextRecord(id: firstCharacter, left: (0, 0), text: arabicGreeting)],
        origin: (-576, 200),
        columnWidth: 1152
    )
    let rightHand = makePage(
        color: UInt32(PenColor.red.rawValue),
        points: [StrokeSample(x: 90, y: -20), StrokeSample(x: 120, y: 20)],
        parent: rightNode, item: (1, 101), left: (0, 0)
    )
    let leftHand = makePage(
        color: UInt32(PenColor.green.rawValue),
        points: [StrokeSample(x: -120, y: -20), StrokeSample(x: -90, y: 20)],
        parent: leftNode, item: (1, 102), left: (1, 101)
    )

    var bytes: [UInt8] = Array(text.prefix(header))
    bytes += anchorNode(character: firstCharacter, originX: declaredOriginX?.right, node: rightNode)
    bytes += anchorNode(character: lastCharacter, originX: declaredOriginX?.left, node: leftNode)
    bytes += Array(text.dropFirst(header))
    bytes += Array(rightHand.dropFirst(header))
    bytes += Array(leftHand.dropFirst(header))
    return Data(bytes)
}

// Two anchors on one page, and each has to find its own character. A single
// anchored stroke — all the other fixtures carry — cannot show a node's
// anchor leaking into its neighbour, and on a right-to-left line the leak is
// invisible in y: both ends share the baseline and differ only in x.
@Test("Two anchors on one Arabic line are read apart, each with its own character")
func arabicPageCarriesAnAnchorAtEitherEnd() throws {
    let page = try RMParser.parsePage(arabicFlankedPage())
    let text = try #require(page.text)

    #expect(text.lines == [arabicGreeting])
    #expect(text.columnWidth == 1152)
    #expect(page.anchoredStrokes == 2)
    #expect(page.strokes.count == 2)
    #expect(page.strokes.allSatisfy { $0.anchor?.paragraph == 0 })
    // The file numbers characters from one: the first is offset 1, the last
    // is offset twelve — the count of the greeting's scalars.
    #expect(
        page.strokes.compactMap { $0.anchor?.offset }.sorted()
            == [1, arabicGreeting.unicodeScalars.count]
    )
    #expect(page.strokes.allSatisfy { $0.anchor?.originX == nil }, "no tag 10 in this file")

    // With tag 10 present each node keeps its own horizontal — the pair is
    // what shows they are not being shared.
    let declared = try RMParser.parsePage(
        arabicFlankedPage(declaredOriginX: (right: 572, left: 401.5))
    )
    let byOffset = Dictionary(
        uniqueKeysWithValues: declared.strokes.compactMap { stroke in
            stroke.anchor.map { ($0.offset, $0.originX) }
        }
    )
    #expect(byOffset[1] == 572)
    #expect(byOffset[arabicGreeting.unicodeScalars.count] == 401.5)
}

// An Arabic line is laid out from the right margin leftwards, and everything
// fastened to it inherits that: handwriting hung on the start of the line
// belongs to the right of the text, and handwriting hung on its end to the
// left. Laid out left-to-right the two swap sides — and nothing else about the
// page changes, which is why this needs an assertion of its own.
@Test("An Arabic line runs from the right margin, and its handwriting flanks it on both sides")
func arabicLineRunsRightToLeftAndItsStrokesFlankIt() throws {
    #expect(TextGeometry.isRightToLeft(arabicGreeting))
    #expect(!TextGeometry.isRightToLeft("peace be upon you"))

    let page = try RMParser.parsePage(arabicFlankedPage())
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    let paragraph = try #require(geometry.paragraphs.first)

    #expect(paragraph.isRightToLeft)
    #expect(paragraph.lines.count == 1, "the greeting is short — it must not wrap")

    let start = geometry.pen(at: TextAnchor(paragraph: 0, offset: 1))
    let end = geometry.pen(at: TextAnchor(paragraph: 0, offset: arabicGreeting.unicodeScalars.count))
    let rightMargin = geometry.left + geometry.column
    // The pen starts at the right margin — the left one is where a Latin
    // paragraph would start — and walks left as the text goes on.
    #expect(abs(start.x - rightMargin) < 0.5, "\(start.x) vs the right margin \(rightMargin)")
    #expect(end.x < start.x - 100, "the pen moved left, not right: \(end.x) vs \(start.x)")
    #expect(end.y == start.y, "one line, one baseline")

    // The strokes land on either side of the writing rather than both on one.
    let placed = geometry.placing(page.strokes)
    #expect(placed.allSatisfy { $0.anchor == nil }, "the anchor is spent in the moving")
    let right = try #require(placed.first { $0.color == .red })
    let left = try #require(placed.first { $0.color == .green })
    let rightmostOfLeft = try #require(left.points.map(\.x).max())
    let leftmostOfRight = try #require(right.points.map(\.x).min())

    let written = PageRenderer.textWidth(arabicGreeting, size: TypeMetrics.body, face: .sans)
    #expect(written > 0)
    #expect(
        Double(leftmostOfRight) > rightMargin,
        "the stroke on the start of the line is right of the text: \(leftmostOfRight)"
    )
    #expect(
        Double(rightmostOfLeft) < rightMargin - written,
        "the stroke on the end of the line is left of the text: \(rightmostOfLeft)"
    )
    // Both are fastened to the same single line, so they share its baseline.
    #expect(right.points.map(\.y) == left.points.map(\.y))
}

// MARK: - One page of every paragraph kind

/// Where a paragraph's style record hangs: on the newline that ends the
/// paragraph **before** it, with (0, 0) for the first, which has none. The
/// characters are numbered in Unicode scalars and the newline is one of them.
///
/// Worked out here rather than written down per fixture: a page of seventeen
/// paragraphs needs seventeen keys, and one hand-counted wrong silently moves
/// a style onto its neighbour — which is a bug this file already has a test
/// for and would rather not reproduce in its own fixtures.
private func styleRecords(
    lines: [String],
    firstCharacter: (author: UInt8, counter: UInt64),
    formats: [Int: ParagraphFormat]
) -> [StyleRecord] {
    var keys: [Int: (author: UInt8, counter: UInt64)] = [0: (0, 0)]
    var index = 0
    for (number, line) in lines.enumerated().dropLast() {
        index += line.unicodeScalars.count
        keys[number + 1] = (firstCharacter.author, firstCharacter.counter + UInt64(index))
        index += 1                                        // the newline itself
    }
    return lines.indices.compactMap { number in
        guard let format = formats[number], let key = keys[number] else { return nil }
        return StyleRecord(
            key: key,
            style: format.raw,
            second: format.second,
            third: format.third
        )
    }
}

/// The paragraphs of `mixedStylePage`, in the order they stand on the page.
///
/// Interleaved rather than grouped, because the grouping is what hides the
/// defects: a numbered run has to start again after the text that breaks it, a
/// nested item has to hold the indent of its own level whatever kind of
/// paragraph stands above it, and the three levels of heading have to survive
/// standing next to one another.
private let mixedStyleLines = [
    "Chapter",              // 0  heading, level 1
    "Section",              // 1  subheading with the further fields, level 2
    "Note",                 // 2  bare subheading, level 3
    "Plain body text.",     // 3  no style record at all
    "First bullet",         // 4
    "Nested bullet",        // 5
    "Second bullet",        // 6
    "Between the lists.",   // 7  breaks the run, so the numbering starts at one
    "Step one",             // 8
    "Step two",             // 9
    "Sub step",             // 10
    "Deeper sub step",      // 11
    "Step three",           // 12 the three follows the two, past the nesting
    "A task",               // 13
    "A done task",          // 14
    "A nested task",        // 15
    "Closing remark.",      // 16
]

/// The style record each of those paragraphs carries.
///
/// Paragraph 3 is missing on purpose: an ordinary body paragraph is written
/// with no record at all, and reading "absent" as anything other than plain
/// text would show up right here, in the middle of the styled ones.
///
/// The `tag 3` values are the format's own encoding — the family in the high
/// half of the byte, the depth in the low half (`ParagraphFormat.level`).
private let mixedStyleFormats: [Int: ParagraphFormat] = [
    0: ParagraphFormat(style: .heading),
    1: ParagraphFormat(style: .subheading, hasFurtherFields: true),
    2: ParagraphFormat(style: .subheading, hasFurtherFields: false),
    4: ParagraphFormat(style: .bullet),
    5: ParagraphFormat(raw: 5, second: 3, third: 0x01),    // bullet, level 2
    6: ParagraphFormat(style: .bullet),
    7: ParagraphFormat(style: .plain),
    8: ParagraphFormat(style: .numbered),
    9: ParagraphFormat(style: .numbered),
    10: ParagraphFormat(raw: 11, second: 3, third: 0x21),  // numbered, level 2
    11: ParagraphFormat(raw: 11, second: 3, third: 0x22),  // numbered, level 3
    12: ParagraphFormat(style: .numbered),
    13: ParagraphFormat(style: .checkbox),
    14: ParagraphFormat(style: .checkboxChecked),
    15: ParagraphFormat(raw: 8, second: 3, third: 0x11),   // checkbox, level 2
    16: ParagraphFormat(style: .plain),
]

/// One typed page carrying every paragraph kind the format tells apart.
private func mixedStylePage(lines: [String] = mixedStyleLines) -> Data {
    let firstCharacter: (author: UInt8, counter: UInt64) = (1, 10)
    return makeTextPage(
        records: [
            TextRecord(id: firstCharacter, left: (0, 0), text: lines.joined(separator: "\n")),
        ],
        styles: styleRecords(
            lines: lines, firstCharacter: firstCharacter, formats: mixedStyleFormats
        ),
        origin: (-576, 200),
        columnWidth: 1152
    )
}

// Every style this file has been tested with so far stood alone on a page of
// two or three lines. A live typed page is not like that: the kinds sit next
// to each other, and each one's record is keyed by the newline of the one
// above — so a style read one paragraph out lands on its neighbour and every
// paragraph after it, and on a page of one style that is invisible.
@Test("A page of mixed paragraph kinds reads each style onto its own paragraph")
func mixedStylePageReadsEveryKind() throws {
    let page = try RMParser.parsePage(mixedStylePage())
    let text = try #require(page.text)

    #expect(text.lines == mixedStyleLines)
    #expect(text.formats == mixedStyleFormats, "every record on its own paragraph, none shifted")
    // Spelled out for the three that are not simply their `tag 1`: the levels
    // of heading, which share a value, and the depth of a nested item.
    #expect(text.formats[0]?.headingLevel == 1)
    #expect(text.formats[1]?.headingLevel == 2)
    #expect(text.formats[2]?.headingLevel == 3)
    #expect(text.formats[3] == nil, "a body paragraph carries no record")
    #expect(text.formats[5]?.level == 2)
    #expect(text.formats[11]?.level == 3)
    #expect(text.formats[15]?.style == .checkboxNested)
    #expect(text.formats[16]?.style == .plain)

    // Sixteen style records added nothing unread: the same lines with no
    // records at all leave exactly as much behind. (Not nought — the text
    // block counts itself as skipped even when it is read.)
    let bare = try RMParser.parsePage(
        makeTextPage(
            records: [
                TextRecord(id: (1, 10), left: (0, 0), text: mixedStyleLines.joined(separator: "\n")),
            ],
            origin: (-576, 200),
            columnWidth: 1152
        )
    )
    #expect(page.skippedBlocks == bare.skippedBlocks)
}

// The three sizes and the three faces are decided by the style record, and two
// of the kinds share their `tag 1`. Laid out together the sizes have to come
// out in the order the tablet sets them — a heading over a section over a
// note — and the body has to stay the body between them.
@Test("Mixed styles lay out at the size and in the face each kind is set in")
func mixedStyleFacesAndSizes() throws {
    let page = try RMParser.parsePage(mixedStylePage())
    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)

    #expect(geometry.paragraphs.count == mixedStyleLines.count)
    #expect(geometry.paragraphs.map(\.text) == mixedStyleLines, "the order survives the layout")

    #expect(geometry.paragraphs[0].size == TypeMetrics.heading1)
    #expect(geometry.paragraphs[0].face == .serif)
    #expect(geometry.paragraphs[1].size == TypeMetrics.heading2)
    #expect(geometry.paragraphs[1].face == .serif)
    // The bare `{1: 3}` is neither serif nor the plain sans: the tablet's own
    // export names reMarkableSans-Medium for it.
    #expect(geometry.paragraphs[2].size == TypeMetrics.heading3)
    #expect(geometry.paragraphs[2].face == .sansMedium)
    #expect(geometry.paragraphs[3].size == TypeMetrics.body)
    #expect(geometry.paragraphs[3].face == .sans)
    // A list item is body text with a marker, not a style of its own.
    #expect(geometry.paragraphs[8].size == TypeMetrics.body)
    #expect(geometry.paragraphs[8].face == .sans)

    // Nothing overlaps and nothing goes back up the page: every paragraph
    // sits below the one before it.
    let baselines = geometry.paragraphs.map(\.baseline)
    #expect(zip(baselines, baselines.dropFirst()).allSatisfy { $0 < $1 })
    // And the heading leaves more room behind it than a body paragraph does.
    #expect(baselines[1] - baselines[0] > baselines[9] - baselines[8])
    #expect(abs((baselines[9] - baselines[8]) - TypeMetrics.paragraphStep) < 0.01)
}

// Numbering and indenting are both worked out from the run of paragraphs, not
// from any one of them, and both are where a mixed page differs from a page of
// one list: the count has to survive a nested item and start again after the
// text that breaks the run.
@Test("Mixed lists number themselves per level and indent by their depth")
func mixedStyleListsCountAndIndent() throws {
    let page = try RMParser.parsePage(mixedStylePage())
    let geometry = TextGeometry(try #require(page.text), pageSize: PageRenderer.defaultPageSize)
    let indents = geometry.paragraphs.map(\.indent)
    let ordinals = geometry.paragraphs.map(\.ordinal)

    // Nothing that is not a list item is indented — the headings and the two
    // body paragraphs included.
    for number in [0, 1, 2, 3, 7, 16] {
        #expect(indents[number] == 0, "paragraph \(number) is not a list item")
        #expect(ordinals[number] == 0)
    }
    // One list step per level of nesting.
    #expect(indents[4] == TypeMetrics.listIndent)
    #expect(indents[5] == 2 * TypeMetrics.listIndent)
    #expect(indents[11] == 3 * TypeMetrics.listIndent)
    #expect(indents[15] == 2 * TypeMetrics.listIndent)

    // The numbered run: 1, 2, then a nested a. and i., then the three that
    // follows the two.
    #expect(ordinals[8] == 1, "the text above broke the bullet run")
    #expect(ordinals[9] == 2)
    #expect(ordinals[10] == 1, "the second level counts on its own")
    #expect(ordinals[11] == 1, "and so does the third")
    #expect(ordinals[12] == 3, "the outer level picked up where it left off")
    #expect(PageRenderer.ListMarker.label(ordinal: ordinals[10], level: 2) == "a.")
    #expect(PageRenderer.ListMarker.label(ordinal: ordinals[11], level: 3) == "i.")
    // The bullets before the break count on their own level too.
    #expect(ordinals[4] == 1)
    #expect(ordinals[6] == 2)
    #expect(PageRenderer.ListMarker.bullet(level: geometry.paragraphs[5].level) == "\u{25E6}")
}

// The whole page has to reach the paper, not merely parse: the markers, the
// three sizes and the indents are all drawing that the same lines without
// their styles do not have.
@Test("A page of mixed paragraph kinds is drawn with more on it than the bare lines")
func mixedStylePageReachesThePDF() throws {
    let styled = try RMParser.parsePage(mixedStylePage())
    let bare = try RMParser.parsePage(
        makeTextPage(
            records: [
                TextRecord(id: (1, 10), left: (0, 0), text: mixedStyleLines.joined(separator: "\n")),
            ],
            origin: (-576, 200),
            columnWidth: 1152
        )
    )

    let withStyles = try PageRenderer.pdf(pages: [styled])
    let withoutStyles = try PageRenderer.pdf(pages: [bare])
    #expect(withStyles.prefix(4) == Data("%PDF".utf8))
    #expect(try ink(in: withStyles) > ink(in: withoutStyles), "markers and bigger type put more on the page")
}

@Test("A numbered list starts again after a run of another family")
func numberingRestartsWhenTheFamilyChanges() throws {
    // The page from the tablet, exported from its own app:
    //
    //     • apple   • pear   1. first   2. second   • plum   1. first again
    //
    // The tablet writes 1. and 2. after the two bullets, and 1. again after
    // the plum. Counting by level alone — which is what this did — advanced
    // the numbered run through the bullets and produced 3., 4. and 6.
    //
    // Worth spelling out because nothing in the file could have settled it:
    // the ordinal is not stored there at all, so the only authority is what
    // the tablet draws.
    let lines = ["apple", "pear", "first", "second", "plum", "first again"]
    let styles: [ParagraphStyle] = [.bullet, .bullet, .numbered, .numbered, .bullet, .numbered]
    let formats = Dictionary(
        uniqueKeysWithValues: styles.enumerated().map {
            ($0.offset, ParagraphFormat(raw: $0.element.rawValue, second: nil, third: nil))
        }
    )
    let page = try RMParser.parsePage(
        makeTextPage(
            records: [TextRecord(id: (1, 10), left: (0, 0), text: lines.joined(separator: "\n"))],
            styles: styleRecords(lines: lines, firstCharacter: (1, 10), formats: formats)
        )
    )

    let text = try #require(page.text)
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    let ordinals = geometry.paragraphs.map(\.ordinal)

    // The bullets count too — they simply do not show it — so only the
    // numbered positions are what the user reads.
    #expect(ordinals[2] == 1, "the first numbered item after bullets starts at one, got \(ordinals[2])")
    #expect(ordinals[3] == 2, "and the second follows it, got \(ordinals[3])")
    #expect(ordinals[5] == 1, "a bullet between numbered runs breaks the count, got \(ordinals[5])")
}

@Test("A column wider than a Move's sheet takes the square sheet, the way the tablet exports it")
func wideColumnSquaresTheSheet() {
    // Automatic reflow on a Move: a 936 column from −370 on an 820 canvas.
    // The tablet's export of that page is 1458 wide, the column's origin
    // 359 units in from the left.
    let move = CGSize(width: 820.2954545454545, height: 1458.3030303030303)
    let text = TextBlock(originX: -370, originY: 234, lines: ["wide"], columnWidth: 936)
    let page = RMPage(strokes: [], skippedBlocks: 0, text: text)
    let bounds = PageRenderer.contentBounds(of: page, pageSize: move, edge: .ribbon)
    #expect(abs(bounds.width - move.height) < 0.01, "\(bounds.width)")
    let origin = Double(move.width / 2) - 370 - Double(bounds.minX)
    #expect(abs(origin - 359.15) < 0.01, "\(origin)")

    // The same column narrowed to fit leaves the sheet as it was.
    let fitting = TextBlock(originX: -370, originY: 234, lines: ["narrow"], columnWidth: 740)
    let fits = PageRenderer.contentBounds(
        of: RMPage(strokes: [], skippedBlocks: 0, text: fitting), pageSize: move, edge: .ribbon
    )
    #expect(abs(fits.width - move.width) < 0.01, "\(fits.width)")
}
