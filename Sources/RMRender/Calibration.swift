// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

// Every number here matches exported PDFs, and they are kept in one place.
// They change when the exporter's fonts or layout change, or when a font
// file in the package is replaced. Why the numbers
// are what they are, how each was taken, how to recalibrate them, and what
// does not belong in this file is written down beside the numbers
// themselves.

/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum Calibration {

    // MARK: - Unit and sheet

    /// One `.rm` unit in typographic points — a constant, the scale of the
    /// `cm` matrix an exported PDF opens its content stream with.
    public static let pointsPerUnit: CGFloat = 0.317180616

    // MARK: - Ink

    /// Which of the first pencil's tile families a point of a given
    /// pressure lays down: `-light` below 0.6 of full pressure, the plain
    /// family below 0.85, `-hard` from there up.
    ///
    /// Two tiles lie over every unit (`StrokeGrainMask.tileVariants`), so the
    /// families come out at about a quarter, three quarters and nine tenths
    /// ink. The light family reaching past half pressure matches exported
    /// PDFs, where a band drawn at half pressure carries about a quarter
    /// ink.
    static func stampFamily(pressure: Double) -> GrainTextures.Family {
        if pressure < 0.6 { return .light }
        if pressure < 0.85 { return .base }
        return .hard
    }

    /// How much of a band of the second pencil, or of the mechanical pencil,
    /// is graphite, by pressure. Their grain is not a texture but noise keyed
    /// to the place on the page: the same band drawn with either tool comes
    /// out of the export pixel for pixel the same, and nothing in it repeats
    /// at the texture's period.
    ///
    /// Measured on the export of a row whose pressure walks from 0 to 255,
    /// rasterised at one pixel to a unit and read in sixteen bins as the
    /// mean weight of ink inside the row — the edge rows left out, since
    /// they are the band's own antialiasing and not grain — with the flat
    /// rows at nothing, half and full pressure as the fixed points. Weight
    /// rather than a count of dark pixels: the export traces its spots into
    /// polygons, and a threshold reads the grey rim of a traced spot either
    /// way. At full pressure the pencil is all but solid. Not a curve anyone
    /// chose: the rise is steep around half pressure and flat on either
    /// side, and a smooth fit would soften both, so the table is the
    /// measurement itself. Brush and marker bands are not modulated this
    /// way and stay solid.
    static let noiseDensityByPressure: [(pressure: Double, density: Double)] = [
        (0.00, 0.010), (0.09, 0.020), (0.16, 0.060), (0.22, 0.090),
        (0.28, 0.200), (0.34, 0.230), (0.41, 0.230), (0.47, 0.350),
        (0.50, 0.460), (0.53, 0.560), (0.59, 0.590), (0.66, 0.680),
        (0.72, 0.820), (0.78, 0.840), (0.84, 0.890), (0.91, 0.960),
        (1.00, 0.980),
    ]

    /// How wide the export draws a tool's band against the width the file
    /// carries, where the two differ.
    ///
    /// Read off an exported notebook — a marker stroke comes out 0.74 of
    /// `width / 4` thick — and the corpus alike: the three marker
    /// rows of `Fixture 13` at 0.70…0.76 of their widths, the brush rows at
    /// 0.70…0.72, and the brush at three thickness settings of one width
    /// (`Fixture 14`) all at 0.73, so the setting is not what narrows it.
    /// The second pencil and the mechanical pencil come out at 0.69 of the
    /// band they would otherwise get — the twelve spokes of `Fixture 36`
    /// read 0.71 at half pressure, 0.67 at full and 0.69 at twice the
    /// width, the same at every angle and with the `direction` byte at 0,
    /// 128 or 255, while the ballpoint spokes beside them read 1.00; the
    /// narrowing by pressure the band already carries matches the export
    /// too (0.70 from full to half on both sides). The stroked tools and the
    /// ballpoint come out at their widths.
    static func drawnWidthScale(for tool: PenTool?) -> Double {
        switch tool {
        case .marker2: 0.74
        case .paintbrush2: 0.72
        case .pencil2, .mechanicalPencil2: 0.69
        default: 1
        }
    }

    /// How much of its width the brush opens at a given pressure, and how
    /// much of that band is ink.
    ///
    /// Measured on the export of a row whose pressure walks from 0 to 255:
    /// nothing at all below a fifth of full pressure, one unit of a six-unit
    /// row at 0.22, then the band opens to its full drawn width by 0.45,
    /// and the ink inside it goes from a third to solid over the same
    /// stretch. An exported notebook agrees: brush strokes at
    /// pressure 64 carry a tenth of the ink a solid band would.
    static let brushWidthByPressure: [(pressure: Double, share: Double)] = [
        (0.00, 0.00), (0.19, 0.00), (0.22, 0.23), (0.28, 0.45),
        (0.34, 0.68), (0.41, 0.90), (0.47, 1.00), (1.00, 1.00),
    ]

    static let brushDensityByPressure: [(pressure: Double, density: Double)] = [
        (0.00, 0.00), (0.19, 0.00), (0.22, 0.33), (0.28, 0.39),
        (0.34, 0.60), (0.41, 0.78), (0.47, 0.92), (0.53, 1.00),
        (1.00, 1.00),
    ]

    static func brushWidthShare(pressure: Double) -> Double {
        interpolate(brushWidthByPressure.map { ($0.pressure, $0.share) }, at: pressure)
    }

    static func brushDensity(pressure: Double) -> Double {
        interpolate(brushDensityByPressure.map { ($0.pressure, $0.density) }, at: pressure)
    }

    /// The pencil's table read between its points.
    static func noiseDensity(pressure: Double) -> Double {
        interpolate(noiseDensityByPressure.map { ($0.pressure, $0.density) }, at: pressure)
    }

    /// A table of `(x, y)` in rising `x`, read between its points and held
    /// flat past either end.
    private static func interpolate(_ table: [(Double, Double)], at x: Double) -> Double {
        guard let first = table.first, let last = table.last else { return 1 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (below, above) in zip(table, table.dropFirst()) where x < above.0 {
            let span = above.0 - below.0
            let share = span > 0 ? (x - below.0) / span : 0
            return below.1 + (above.1 - below.1) * share
        }
        return last.1
    }

    // MARK: - Marks we draw ourselves

    /// The tick inside a filled checkbox, as shares of the box side counted
    /// from the bottom-left corner.
    ///
    /// Fitted by eye against the export rather than read off it directly: the
    /// export sets the tick in a glyph of a face we do not carry, so pictures
    /// are compared, not coordinates. Shares rather than points, because the
    /// box grows with the size and the tick must grow with it.
    static let checkboxTick: [(x: Double, y: Double)] = [
        (0.22, 0.50), (0.48, 0.26), (0.82, 0.76),
    ]

    /// How far the dash of a partly ticked checkbox stands in from each side,
    /// as a share of the box side. Fitted by eye against an exported page,
    /// as the tick above is.
    static let checkboxDashInset = 0.25

    /// The strike-through of a ticked item: height above the line start and
    /// thickness, both as shares of the size. Fitted by eye against the
    /// export, shares for the same reason as the tick above.
    static let strikeHeight = 0.3
    static let strikeWeight = 0.065

    // MARK: - Template background

    /// The colour and the width of a template line, used wherever a template
    /// does not set `strokeColor` or `strokeWidth` itself, which in practice
    /// means most of a background; both match exported PDFs.
    public static let templateStroke = (red: 0.752941, green: 0.752941, blue: 0.752941)
    static let templateStrokeWidth = 0.5

    // MARK: - Face widths

    /// How much our substitute has to be stretched to set as wide as the face
    /// an export names.
    ///
    /// Not a nicety. The format counts the coordinates of handwriting anchored
    /// to a line from the **end of that line**, so a face of the wrong width
    /// moves the writing; and a width that is off by a per cent flips a wrap
    /// point, which moves it by a word.
    ///
    /// Keyed by the **exported** face rather than by ours, and that is what
    /// makes recalibration a copy: a measuring pass prints these very names
    /// and these very numbers, because it reads them out of `/BaseFont`. Which
    /// of our cuts stands in for which of theirs is said once, in
    /// `EmbeddedFonts.font(size:face:bold:italic:)`.
    ///
    /// The multiplier trues the corpus **on average**; the per-glyph residue
    /// is carried by the `*GlyphShare` tables below and applied as kerning,
    /// so the kerning comes first and the multiplier picks up what remains.
    /// No number here is borrowed from a neighbouring cut or retuned on a
    /// single alphabet.
    static let fontStretch: [String: [Double: Double]] = [
        // The 36-point keys are not Medium's: bold inside a subheading is
        // set in an ExtraBold, bold italic in ExtraBoldItalic,
        // italic in the plain RegularItalic — which is why those cuts key to
        // the Bold/Italic rows here rather than to the Medium one.
        "reMarkableSans-Regular": [32: 0.9687],
        // The bold and italic rows are read off the faces of `Fixture 02…05`
        // exported from a Move — 12…24 lines a number — exports that carry
        // the face marks.
        "reMarkableSans-Bold": [32: 0.9528, 36: 0.9711],
        "reMarkableSans-RegularItalic": [32: 1.0364, 36: 1.0333],
        "reMarkableSans-Medium": [36: 0.9764],
        "reMarkableSerifSmall-Regular": [46: 1.1445, 64: 1.1425],
        "reMarkableSerifSmall-Bold": [46: 1.0967, 64: 1.0966],
        "reMarkableSerifSmall-RegularItalic": [46: 1.1172, 64: 1.1177],
        // A 1.0 is the absence of a correction: same family as the export's,
        // and tuning it by hundredths would tune it to rounding noise. Every
        // size is written out all the same, so that "nearest" cannot lend one
        // key's number to another.
        //
        // A single number covers every size. An apparent spread — 0.9962,
        // 0.9861, 0.9992 — traces to Devanagari lines counted under this key:
        // an export cannot state their widths, and the mis-count falls
        // differently on each size. With those lines excluded, all four keys
        // land on the same 0.9983, which is what a face differing from ours
        // only in being a variable instance should do.
        "NotoSans-Regular": [32: 0.9983, 46: 0.9983, 64: 0.9983],
        // The 36 of the bold rows is the export's ExtraBold, set where a
        // subheading carries bold, and wider than our Bold by a per cent or
        // two; at 32, 46 and 64 the Bold is the same cut on both sides.
        "NotoSans-Bold": [32: 1.0, 36: 1.0123, 46: 1.0, 64: 1.0],
        "NotoSans-Medium": [36: 0.9983],
        "NotoSans-Light": [64: 0.9983],
        // Korean, the ideographs and Thai carry their own files, which is why
        // the correction here is 1.0: a macOS-supplied glyph would need
        // 1.0634 to reach the exported width, but the packaged Noto file needs
        // no correction at all — four cuts checked separately land on 0.9999,
        // 0.9997, 0.9998 and 0.9999. A 1.0 is the absence of a correction,
        // and this is one.
        "NotoSansKR-Regular": [32: 1.0, 46: 1.0, 64: 1.0],
        "NotoSansKR-Medium": [36: 1.0],
        "NotoSansKR-Bold": [32: 1.0],
        "NotoSansKR-Light": [64: 1.0],
        // Japanese the same, a fifth of a per cent under: the ideographs are
        // full-width in any face, so only the kana can differ.
        "NotoSansJP-Regular": [32: 0.9986, 46: 0.9986, 64: 0.9986],
        "NotoSansJP-Medium": [36: 0.9986],
        "NotoSansJP-Bold": [32: 0.9986],
        "NotoSansJP-Light": [64: 0.9986],
        // Thai needs no correction either: four cuts land on
        // 0.9992…1.0000. A tone mark is set by stepping back over its
        // consonant, so a measurement must not take every step as a width —
        // that counts the step twice and reads a per cent too wide.
        "NotoSansThaiLooped-Regular": [32: 1.0, 46: 1.0, 64: 1.0],
        "NotoSansThaiLooped-Medium": [36: 1.0],
        "NotoSansThaiLooped-Bold": [32: 1.0, 36: 1.0139, 46: 1.0, 64: 1.0],
        "NotoSansThaiLooped-Light": [64: 1.0],
        // Hebrew is set exactly as we set it: four cuts on 0.9998…1.0000,
        // six one-line paragraphs of `Fixture 10` within three hundredths
        // of a per cent of each other. A right-to-left line must be read
        // from the right ends — the export sets one as a piece per word,
        // the spaces between them in reMarkable Sans, and a ruler that drops
        // those pieces and grows every piece rightwards measures a line
        // three to six per cent short that was never drawn.
        "NotoSansHebrew-Regular": [32: 1.0, 46: 1.0, 64: 1.0],
        "NotoSansHebrew-Medium": [36: 1.0],
        "NotoSansHebrew-Bold": [32: 1.0, 36: 1.0194, 46: 1.0, 64: 1.0],
        "NotoSansHebrew-Light": [64: 1.0],
        // Arabic can only be measured from the corpus text — an export names
        // joined forms, and a line rebuilt out of them is not Arabic — and
        // ten one-line paragraphs of `Fixture 10` read 1.0009 with the pen
        // followed wherever it went: a hundredth over, nine of the ten lines
        // within two hundredths of each other. No correction.
        "NotoSansArabic-Regular": [32: 1.0],
        "NotoSansArabic-Medium": [36: 1.0],
        // The bold of Arabic and Devanagari, read off the one-line bold rows of
        // `Fixture 37` (Paper Pro): Arabic Bold sets half a per cent
        // narrower in the export at every size, its ExtraBold — the bold of
        // a subheading — two and a third per cent wider, like the others'.
        "NotoSansArabic-Bold": [32: 0.9950, 36: 1.0237, 46: 0.9950, 64: 0.9950],
        "NotoSansArabic-Light": [64: 1.0],
        // Devanagari needs no correction either, provided its spaces are left
        // alone (`TextGeometry.apply`) and the level-one heading takes the
        // Light instance the export takes (`EmbeddedFonts.nonLatin`): the
        // body lines of `Fixture 10` read 0.9994 against the plain face.
        // Without the first, the Noto space correction would show up here as
        // a per cent and a third of stretch. Lines heavy with conjuncts stay
        // apart — up to 2.5% at 32, 7…10% at 64 — which is shaping, not
        // width. Every size written out, as for the other faces.
        "NotoSansDevanagari-Regular": [32: 1.0, 46: 1.0, 64: 1.0],
        "NotoSansDevanagari-Medium": [36: 1.0],
        "NotoSansDevanagari-Bold": [32: 1.0, 36: 1.0230, 46: 1.0, 64: 1.0],
        "NotoSansDevanagari-Light": [64: 1.0],
    ]

    /// The correction inside a Noto run, as a share of the size.
    ///
    /// One entry, and it is the space. Read off a pair of lines of the same
    /// letters differing only in their gaps (`Fixture 10`, the last four
    /// paragraphs): the export advances 7.92 units for a space at 32, our
    /// face 8.67 — a tenth of a space each time, and on a line of seven
    /// words half a letter, which is enough to move a wrap. The letters of the
    /// same run need nothing: the same pair measures them at 1.0029 and
    /// 0.9954.
    ///
    /// Nothing else belongs here. The per-glyph tables of the Latin cuts are
    /// deliberately kept out of Noto runs — there the export sets Noto itself
    /// and its digits are tabular, so a correction meant for another face is
    /// harm.
    static let notoGlyphShare: [Character: Double] = [" ": -0.0234]

    /// The per-glyph correction to the substitute behind
    /// `reMarkableSans-Regular`, as shares of the size — what has to be added
    /// to our glyph's advance to reach the exported one.
    ///
    /// One multiplier per face trues a line on average, while wrap points are
    /// set by individual letters; the correction is taken as the residue
    /// **after** `fontStretch` and is applied on top of the multiplier as
    /// kerning. A glyph is included once it has ten occurrences and a residue
    /// of at least a hundredth of the size.
    ///
    /// Applied **only in sans runs** (regular, not bold, not italic): in a
    /// Cyrillic context the export sets digits and punctuation in a Noto run,
    /// where they are tabular and the correction would be harm. Run
    /// boundaries — `TextGeometry.notoRanges`.
    static let sansGlyphShare: [Character: Double] = [
        "1": -0.1313, "€": 0.1217, "C": 0.0890, "ß": 0.0785,
        "c": 0.0732, "č": 0.0731, "0": 0.0567, ",": -0.0470,
        "g": -0.0468, "r": -0.0453, ".": -0.0447, "8": 0.0426,
        "—": -0.0417, "m": -0.0391, ")": 0.0376, "š": 0.0364,
        "s": 0.0354, "-": 0.0343, "6": 0.0325, "P": 0.0321,
        "(": 0.0320, "/": 0.0295, "ó": -0.0255, "ö": -0.0242,
        "4": 0.0235, "2": 0.0229, "5": 0.0216, "l": 0.0187,
        "3": 0.0186, "o": -0.0181, "»": 0.0173, "v": 0.0171,
        "h": -0.0163, "y": 0.0162, "u": -0.0159, "ü": -0.0159,
        "ú": -0.0159, " ": -0.0153, "n": -0.0144,
    ]

    /// The same per-glyph corrections for the serif — upright and italic
    /// separately: the faces differ and so do their residues. The shares
    /// agree across sizes to thousandths, so one table serves every size.
    static let serifGlyphShare: [Character: Double] = [
        "»": -0.2912, "T": -0.2255, "”": -0.1635, "“": -0.1616,
        "—": -0.1590, "V": -0.1403, "G": -0.1224, "L": -0.1217,
        "æ": 0.1206, "K": -0.1171, "„": -0.1038, "Q": -0.1003,
        "ş": 0.0862, "ś": 0.0842, "Z": -0.0842, "ß": 0.0831,
        "š": 0.0828, "s": 0.0821, ".": -0.0800, ",": -0.0670,
        "à": 0.0648, "ă": 0.0648, "â": 0.0648, "å": 0.0647,
        "ā": 0.0645, "á": 0.0641, "(": -0.0640, "ą": 0.0639,
        "a": 0.0632, "ä": 0.0621, "ę": 0.0609, "'": -0.0603,
        "ź": 0.0598, "e": 0.0587, "ž": 0.0586, "ż": 0.0565,
        "ë": 0.0548, "z": 0.0548, "é": 0.0544, "ł": -0.0532,
        "P": -0.0524, "ê": 0.0488, "w": -0.0445, "f": -0.0435,
        ")": -0.0432, "ű": -0.0379, "ü": -0.0364, "u": -0.0361,
        "ú": -0.0355, "ū": -0.0355, "i": -0.0333, "í": -0.0332,
        "ï": -0.0331, "î": -0.0331, "ī": -0.0331, "ı": -0.0331,
        ":": -0.0293, "g": 0.0277, "l": -0.0275, "đ": 0.0266,
        "d": 0.0265, "-": 0.0259, "ď": 0.0257, "ý": -0.0245,
        "t": -0.0242, "r": -0.0239, "n": -0.0219, "ć": 0.0197,
        "ń": -0.0197, "ň": -0.0196, "č": 0.0192, "ç": 0.0186,
        "b": 0.0174, "c": 0.0172, "ť": -0.0164, "v": -0.0126,
        "m": -0.0125, "j": -0.0115, "o": 0.0110, "ø": 0.0105,
    ]

    /// Bold and bold italic of the sans carry their own tables: the exported
    /// bold differs from ours letter by letter, not uniformly.
    static let sansBoldGlyphShare: [Character: Double] = [
        "0": 0.0835, "č": 0.0735, "c": 0.0735, "P": 0.0649, "š": 0.0507,
        "s": 0.0500, "2": 0.0483, "g": -0.0386, "r": -0.0245, ",": -0.0245,
        "m": -0.0232, ".": -0.0218, "o": -0.0213, "k": -0.0211,
        " ": -0.0197, "y": 0.0194, "l": 0.0166, "u": -0.0160, "T": 0.0156,
        "h": -0.0151, "n": -0.0131, "j": -0.0120, "t": -0.0117,
        "i": -0.0115, "ž": 0.0112, "ó": -0.0104, "ö": -0.0100, "v": 0.0078,
        "p": -0.0051, "b": 0.0017, "w": 0.0012, "d": -0.0006,
    ]

    /// The italic sans and the bold serif, read off the faces of `Fixture 02…05`
    /// exported from a Move, exports that carry the face marks. The rule is
    /// the one above: ten
    /// occurrences and a hundredth of the size.
    /// The medium of the plain subheading, off the eight lines `Fixture 04`
    /// sets in it: three glyphs clear the ten occurrences the rule asks
    /// for, the rest wait for more lines.
    static let sansMediumGlyphShare: [Character: Double] = [
        "r": -0.0317, "o": -0.0271, " ": -0.0245,
    ]

    static let sansItalicGlyphShare: [Character: Double] = [
        "c": 0.0674, "g": -0.0534, "r": -0.0511, "s": 0.0495, "m": -0.0419,
        " ": -0.0324, "e": 0.0323, "o": -0.0220, "i": -0.0171,
        "u": -0.0167, "n": -0.0162, "h": -0.0158, "t": 0.0130,
    ]

    static let serifBoldGlyphShare: [Character: Double] = [
        "s": 0.0703, "r": -0.0638, "e": 0.0596, "a": 0.0563, "f": -0.0509,
        "i": -0.0472, "t": -0.0458, "c": 0.0435, "o": 0.0412, " ": -0.0410,
        ",": -0.0404, "l": -0.0362, "p": 0.0239, "q": 0.0237, "k": -0.0189,
        "m": 0.0144, "n": -0.0129,
    ]

    static let serifItalicGlyphShare: [Character: Double] = [
        "»": -0.3413, "K": -0.1838, "T": -0.1778, "æ": 0.1750,
        "V": -0.1654, "L": -0.1312, "Z": -0.1290, "o": 0.1022,
        "—": -0.1010, "ó": 0.1004, "ö": 0.1003, "ø": 0.1003,
        "ő": 0.1001, "ô": 0.0997, "”": -0.0992, "õ": 0.0991,
        "“": -0.0935, "G": -0.0910, "„": -0.0835, "ş": 0.0822,
        "š": 0.0796, "ś": 0.0772, "p": 0.0726, "ł": -0.0721,
        "f": -0.0709, "s": 0.0702, "l": -0.0696, "ç": 0.0693,
        "ć": 0.0679, "č": 0.0675, "c": 0.0624, "ą": 0.0613,
        ".": -0.0612, ",": -0.0593, "k": -0.0587, "ı": -0.0576,
        "i": -0.0569, "r": -0.0569, "ę": 0.0551, "ê": 0.0517,
        "ï": -0.0509, "î": -0.0509, "ī": -0.0509, "(": -0.0504,
        "í": -0.0503, "ë": 0.0496, "é": 0.0486, "e": 0.0485,
        "P": -0.0484, "ķ": -0.0457, "b": 0.0421, "ľ": -0.0386,
        "'": -0.0372, "j": -0.0365, "Q": -0.0318, "m": -0.0318,
        "ż": -0.0302, "z": -0.0293, "ž": -0.0288, "ź": -0.0286,
        "t": -0.0269, "x": -0.0262, ";": 0.0256, ")": -0.0251,
        "g": 0.0197, "à": 0.0189, "-": 0.0187, "n": -0.0168,
        "â": 0.0168, "q": 0.0153, "ă": 0.0152, "d": -0.0150,
        "!": -0.0147, "å": 0.0146, "á": 0.0139, "ä": 0.0131,
        "ú": 0.0115, "ū": 0.0115, "ā": 0.0112, "h": 0.0107,
        " ": -0.0106,
    ]

    /// The stretch for one of the exported faces at one size.
    ///
    /// A size not in the table takes the nearest one it does hold — the
    /// format sets no in-between sizes, and the nearest beats a bare 1.0. A
    /// tie goes to the smaller size: Swift's dictionary order is not
    /// guaranteed, and without a deterministic tie-break the same page could
    /// set with either neighbour, so a cached page and a freshly drawn one
    /// would differ.
    ///
    /// A face with no calibration of its own sets unstretched rather than
    /// borrowing from a neighbour, whose correction would be wrong for it.
    static func fontStretch(forTabletFace face: String, size: Double) -> Double {
        guard let measured = fontStretch[face] else { return 1 }
        return nearest(in: measured, to: size) ?? 1
    }

    /// The value at the nearest size present in the table; a tie goes to the smaller key.
    ///
    /// A separate function so the rule can be exercised on arbitrary key
    /// sets: bucket layout depends on them, and within one process it is
    /// fixed — the hash seed is per process. `CalibrationTests` therefore
    /// checks the tie with several key sets rather than one call repeated.
    static func nearest(in measured: [Double: Double], to size: Double) -> Double? {
        measured.min { left, right in
            let (toLeft, toRight) = (abs(left.key - size), abs(right.key - size))
            return toLeft == toRight ? left.key < right.key : toLeft < toRight
        }?.value
    }
}

// MARK: - List markers

public extension Calibration {
    /// The glyph a list item is marked with at each nesting level:
    /// filled, hollow, then a dash. Glyphs of the main face rather than drawn
    /// shapes, so they grow with the size like any letter; the shape follows
    /// the level, not the style value.
    static func listBullet(level: Int) -> String {
        switch level {
        case 1: "\u{2022}"
        case 2: "\u{25E6}"
        default: "\u{2013}"
        }
    }

    /// How an item is numbered at each level: digits, letters, roman.
    /// The format has exactly three levels and each counts on its own — an
    /// item after a nested block continues its level rather than restarting.
    internal static func listNumbering(level: Int) -> ListNumbering {
        switch level {
        case 1: .decimal
        case 2: .letter
        default: .roman
        }
    }
}

// MARK: - Tools

// Which tool draws how is not chosen either: both properties match an
// exported PDF of a page drawn with all nine tools.

public extension PenTool {
    /// How a stroke of this tool is laid over what is already on the
    /// page.
    ///
    /// An exported PDF declares three graphics states and no more:
    /// `Normal` at full opacity for the pens, `Darken` at full opacity, and
    /// `Darken` at a quarter. Two of the tools on the page it was taken from
    /// are translucent, so the two darkening states belong to them.
    var blend: StrokeBlend {
        switch self {
        case .highlighter1, .highlighter2: .darken
        case .shader: .darkenFaint
        default: .normal
        }
    }

    /// Whether this tool is drawn by stroking a line rather than by filling
    /// a contour around it.
    ///
    /// Two tools of nine, and a width that stands still is not what decides
    /// it: the mechanical pencil's width is just as constant and the export
    /// fills it all the same.
    var isStroked: Bool {
        switch self {
        case .fineliner1, .fineliner2, .highlighter1, .highlighter2: true
        default: false
        }
    }

    /// How this tool's ink breaks into grain.
    ///
    /// Exported PDFs show three tools as black spots with paper between —
    /// the two pencils and the mechanical pencil — the brush opening with
    /// pressure, and both ballpoints thinning under a light touch. The first
    /// pencil lays the generated tiles, the second pencil and the mechanical
    /// pencil lay noise keyed to the place on the page (their bands match in
    /// exported PDFs), and the ballpoints lay grains of their own
    /// (`StrokeScratch`, `StrokeStreak`). The marker's band comes out solid.
    var grain: StrokeGrain {
        switch self {
        case .pencil1: .stamp
        case .pencil2, .mechanicalPencil2: .noise
        case .paintbrush2: .bristle
        case .ballpoint1: .scratch
        case .ballpoint2: .streak
        default: .solid
        }
    }
}

// MARK: - Typed text metrics

/// The measurements of typed text, in `.rm` units.
///
/// Read out of the content stream of an exported PDF rather than out
/// of the document: `.content` carries `textScale: 1`, an empty `fontName`
/// and a `lineHeight` of 100 where the real steps are 69.55 and 45.55. None
/// of the three is a size or a step.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TypeMetrics {
    /// The step down to a new paragraph after an ordinary one.
    public static let paragraphStep = 69.55

    /// The step down from one paragraph's baseline to the next one's.
    ///
    /// Both paragraphs decide it, the way they do in an editor: the descent
    /// of the last line above, plus the room its paragraph leaves behind,
    /// plus the room the one below asks for, plus the ascent of the new
    /// line. The split into the four parts is solved from transitions read
    /// off exported PDFs rather than assumed.
    public static func step(
        from previous: ParagraphFormat?,
        to next: ParagraphFormat?,
        // The new line's text: the body steps by the height of its script
        // (`bodyLineHeight`); with no text the height stays Latin.
        text: String = "",
        // The last line of the previous paragraph: its script decides the
        // lower half of the step. Without it — Latin.
        previousText: String = ""
    ) -> Double {
        descent(of: previous, text: previousText)
            + spaceAfter(previous) + spaceBefore(next)
            + ascent(of: next, text: text)
    }

    /// The rise of a line above its baseline — the upper half of the step
    /// between paragraphs. `0.925 × size` for Latin, plus a per-script boost;
    /// the split of the line height into ascent and descent matches exported
    /// PDFs.
    static func ascent(of format: ParagraphFormat?, text: String) -> Double {
        let size: Double = switch format?.style {
        case .heading: 64
        case .subheading: format?.hasFurtherFields == true ? 46 : 36
        default: 32
        }
        let base = 0.925 * size
        let latin = lineHeight(of: format, text: "")
        let full = lineHeight(of: format, text: text)
        let delta = full - latin
        guard delta > 0 else { return base }

        // Boosts read off an export are exact numbers; pairs without one take
        // the script's share of the height delta (r from pairs read off the
        // same script).
        let script = dominantScript(of: text)
        let emphasised = format?.hasFurtherFields == true
        let boost: Double? = switch (format?.style, script) {
        case (.heading, .noto): 9.22
        case (.heading, .cjk): 15.05
        case (.heading, .arabic): 28.74
        case (.heading, .thai): 20.80
        case (.subheading, .noto) where emphasised: 6.62
        case (.subheading, .cjk) where emphasised: 10.81
        case (.subheading, .arabic) where emphasised: 20.66
        case (.subheading, .thai) where emphasised: 14.95
        case (.subheading, .cjk): 8.45
        case (.subheading, .thai): 11.70
        case (nil, .noto), (.basic, .noto), (.plain, .noto): 4.61
        // Read off `Fixture 10`, where every paragraph is one line and the
        // steps in and out of the Arabic block are pure transitions:
        // Cyrillic → Arabic 85.30 and Arabic → Devanagari 89.80 split the
        // 75.55 box as 43.96 above the baseline and 31.59 below, and both
        // steps come back exactly.
        case (nil, .arabic), (.basic, .arabic), (.plain, .arabic): 14.36
        default: nil
        }
        let share: Double = switch script {
        case .arabic: 0.48
        case .cjk: 0.875
        default: 0.768
        }
        return base + (boost ?? share * delta)
    }

    static func descent(of format: ParagraphFormat?, text: String) -> Double {
        lineHeight(of: format, text: text) - ascent(of: format, text: text)
    }

    private enum DominantScript { case latin, noto, cjk, thai, arabic }

    /// The script that decided the line's height — same priority as in the
    /// height tables: the tallest box wins.
    private static func dominantScript(of text: String) -> DominantScript {
        var found = DominantScript.latin
        for scalar in text.unicodeScalars {
            let point = Int(scalar.value)
            if ScriptClass.isArabic(point) {
                return .arabic
            }
            if ScriptClass.isThai(point) {
                found = .thai
            } else if found != .thai, ScriptClass.isCJK(point) {
                found = .cjk
            } else if found == .latin,
                      ScriptClass.isHebrew(point) || ScriptClass.isTall(point) {
                found = .noto
            }
        }
        return found
    }

    /// How tall one line of the paragraph is — the step to its own continuation
    /// when it wraps.
    ///
    /// Not a share of the size: a subheading of 36 wraps tighter than a body
    /// of 32. Read off exported PDFs, per style.
    public static func lineHeight(of format: ParagraphFormat?) -> Double {
        switch format?.style {
        case .heading: 76.00
        case .subheading: format?.hasFurtherFields == true ? 55.00 : 43.00
        default: wrapStep
        }
    }

    /// The same height, decided by the line's own text: a line carrying a
    /// taller script is taller in every style, with heights per style and
    /// script.
    public static func lineHeight(of format: ParagraphFormat?, text: String) -> Double {
        switch format?.style {
        case .heading:
            return scriptLineHeight(
                of: text, latin: 76.00, noto: 88.00, cjk: 93.00, thai: 103.00, arabic: 136.00
            )
        case .subheading where format?.hasFurtherFields == true:
            return scriptLineHeight(
                of: text, latin: 55.00, noto: 63.00, cjk: 67.00, thai: 74.00, arabic: 98.00
            )
        case .subheading:
            // The one style where Hebrew departs from Cyrillic (49 vs 50).
            return scriptLineHeight(
                of: text, latin: 43.00, noto: 50.00, cjk: 53.00, thai: 58.00,
                arabic: 77.00, hebrew: 49.00
            )
        default: return bodyLineHeight(of: text)
        }
    }

    /// The tallest script of the line decides its height; the numbers are
    /// per style, taken from exported PDFs, and do not scale with the
    /// size.
    private static func scriptLineHeight(
        of text: String,
        latin: Double,
        noto: Double,
        cjk: Double,
        thai: Double,
        arabic: Double,
        hebrew: Double? = nil
    ) -> Double {
        var height = latin
        for scalar in text.unicodeScalars {
            let point = Int(scalar.value)
            if ScriptClass.isArabic(point) {
                height = max(height, arabic)
            } else if ScriptClass.isThai(point) {
                height = max(height, thai)
            } else if ScriptClass.isCJK(point) {
                height = max(height, cjk)
            } else if ScriptClass.isHebrew(point) {
                height = max(height, hebrew ?? noto)
            } else if ScriptClass.isTall(point) {
                height = max(height, noto)
            }
        }
        return height
    }

    /// The height of one body line, decided by its scripts: the format gives
    /// a line the box of the tallest face on it, and the faces differ.
    static func bodyLineHeight(of line: some StringProtocol) -> Double {
        var height = wrapStep
        for scalar in line.unicodeScalars {
            let point = Int(scalar.value)
            if ScriptClass.isArabic(point) {
                // The same box as Cyrillic — the Arabic face is taller only
                // in how the box splits around the baseline (`ascent`).
                // A paragraph of it steps 99.55 to the next, which is this
                // plus the 24.00 every paragraph leaves under itself. The
                // step *into* an Arabic paragraph from a Cyrillic one (61.30)
                // is a transition, not a wrap, and does not belong here.
                height = max(height, 75.55)
            } else if ScriptClass.isThai(point) {
                height = max(height, 59.55)
            } else if ScriptClass.isCJK(point) {
                height = max(height, 54.55)
            } else if ScriptClass.isTall(point)
                // Hebrew steps the Cyrillic way in the body, although in the
                // subheading it sits one unit below Cyrillic.
                || ScriptClass.isHebrew(point) {
                height = max(height, 51.55)
            }
        }
        return height
    }

    /// The room a paragraph leaves under itself: exactly 24.00 for every
    /// style — all the per-style difference is in what a paragraph asks for
    /// above itself (`spaceBefore`).
    static func spaceAfter(_ format: ParagraphFormat?) -> Double {
        24.00
    }

    /// The room a paragraph asks for above itself.
    private static func spaceBefore(_ format: ParagraphFormat?) -> Double {
        switch format?.style {
        case .heading: 64.00
        case .subheading: format?.hasFurtherFields == true ? 32.00 : 16.00
        default: 0
        }
    }

    /// The type size a paragraph is set in.
    public static func size(of format: ParagraphFormat?) -> Double {
        switch format?.style {
        case .heading: heading1
        case .subheading: format?.hasFurtherFields == true ? heading2 : heading3
        default: body
        }
    }

    /// How far a list item's text stands to the right of the margin.
    public static let listIndent = 48.0
    /// How far in front of its own text a number stands, counted to the end
    /// of the number: it is set right-aligned, so a two-digit one grows to
    /// the left rather than into the text.
    static let markerGap = 21.5
    /// How far in front of its text a bullet stands. A bullet is a glyph
    /// rather than a drawn shape, so it is set from the left like any letter.
    static let bulletGap = 28.0
    /// The same for a checkbox, which is drawn; the box is square.
    static let checkboxGap = 41.33
    static let checkboxSide = 26.67
    /// How far the box dips below the baseline of its own line: kept wholly
    /// above it, the box reads as lifted off the line.
    static let checkboxDrop = 1.74
    /// The border thickness: the export draws it as a fill between an outer
    /// and an inner contour, exactly 2.5 apart.
    static let checkboxStroke = 2.5
    /// The step down to the continuation of a paragraph too long for one
    /// line.
    static let wrapStep = 45.55

    /// How far in from the origin the text is laid out, on both axes: the
    /// origin the file gives is the corner of a box, and the text sits four
    /// units inside it. The same four turns up in the vertical — see
    /// `firstBaselineDrop`.
    public static let textInset = 4.0

    /// Where the first baseline sits below the top of the text box:
    /// `4 + 0.925 × size` — the inset above plus the exported face's ascent.
    ///
    /// A share of the size rather than what our fonts answer: the layout is
    /// the format's, and the face is a substitute for one we may not ship —
    /// letting our files decide would move the baselines to suit them.
    public static func firstBaselineDrop(size: Double) -> Double {
        textInset + 0.925 * size
    }

    /// The same drop, decided by the first line's script: the ascent is the
    /// tallest face's — `4 + 1.069 × size` for a Cyrillic first line (Noto
    /// Sans's own ascent) against the Latin `4 + 0.925 × size`.
    public static func firstBaselineDrop(size: Double, text: String) -> Double {
        let noto = text.unicodeScalars.contains { scalar in
            ScriptClass.isCyrillicOrGreek(Int(scalar.value))
        }
        return textInset + (noto ? 1.069 : 0.925) * size
    }

    /// Ordinary text, in reMarkableSans.
    public static let body = 32.0
    /// An emphasised paragraph — `{1: 3, 2: 2, 3: 3}`, the record that goes on
    /// past its first field, and a serif face rather than a bold one.
    public static let heading2 = 46.0
    /// A subheading — the bare `{1: 3}`. Smaller than the emphasised
    /// paragraph, not larger, and the one face of the three that is neither
    /// the plain sans nor the serif: the export names `reMarkableSans-Medium`
    /// for it.
    public static let heading3 = 36.0
    /// A heading — `{1: 2}`, the same serif at twice the body.
    public static let heading1 = 64.0
}

// MARK: - Ink palettes

// Three palettes over one set of indexes, and that is not duplication: the
// same index paints differently depending on the tool. They are
// `switch`es rather than dictionaries on purpose — a new `PenColor` case
// then breaks the build here instead of silently falling into `default`.

public extension PenColor {
    /// The sRGB components. Returned as numbers rather than a `CGColor`: a
    /// domain type has to stay `Sendable`.
    ///
    /// The nine indexes the pen offers — `0 1 2 6 7 10 11 12 13` — are
    /// taken from exported PDFs and shared by seven tools of
    /// nine, the marker included. These indexes carry no `argb` fallback, so
    /// a wrong row here is silently the wrong colour on the page.
    ///
    /// `green` (4) and `yellow` (3) are the *highlighter's* indexes: the pen
    /// never shows them, and their values here remain picks not read off any
    /// export, kept for the day a file carries them on an opaque tool.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .black: (0, 0, 0)
        case .gray: (144.0 / 255, 144.0 / 255, 144.0 / 255)
        case .grayOverlap: (0.5, 0.5, 0.5)
        case .white: (1, 1, 1)
        case .yellow, .highlight: (0.98, 0.87, 0.16)
        case .yellow2: (250.0 / 255, 231.0 / 255, 25.0 / 255)
        case .green: (0.16, 0.72, 0.35)
        case .green2: (145.0 / 255, 218.0 / 255, 113.0 / 255)
        case .pink: (0.95, 0.44, 0.7)
        case .blue: (48.0 / 255, 74.0 / 255, 224.0 / 255)
        case .red: (194.0 / 255, 49.0 / 255, 50.0 / 255)
        case .cyan: (116.0 / 255, 210.0 / 255, 232.0 / 255)
        case .magenta: (192.0 / 255, 127.0 / 255, 210.0 / 255)
        // The highlighter's blue and orange under their own indexes, as
        // newer files write them — the same colours other files spell as
        // `9` plus `argb` (`0xFFBEEAFE`, `0xFFFFC38C`).
        case .highlighterBlue: (190.0 / 255, 234.0 / 255, 254.0 / 255)
        case .highlighterOrange: (255.0 / 255, 195.0 / 255, 140.0 / 255)
        }
    }

    /// The same index as a highlight over the text of a PDF paints it, which
    /// is not how the pen paints it.
    ///
    /// The yellow is calibrated against the **result of the multiply** rather
    /// than copied out of the export: the multiply happens in a linear space,
    /// and the sRGB value that looks right renders wrong.
    ///
    /// Not the same as `highlightRGB`, and deliberately so: a highlight over
    /// text multiplies, a stroke of the marker darkens, and a colour bent to
    /// survive a multiply is wrong where nothing multiplies.
    ///
    /// Only yellow is taken from an export — the first highlight colour
    /// offered. The rest fall back to the pen's palette.
    internal var textHighlightRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow, .yellow2, .highlight: (1, 0.996, 0.356)
        default: rgb
        }
    }

    /// The same index as the highlighter draws it.
    ///
    /// The highlighter, not the marker: `marker2` draws opaquely with the
    /// pen's palette. Taken literally out of an exported PDF, because the
    /// highlighter darkens rather than multiplies and a darkened colour lands
    /// as it is. Index 9 carries an explicit `argb` in the file instead — see
    /// `Stroke.rgb`.
    ///
    /// The rest of the palette, not read off any export, falls back to the
    /// pen's — a colour off by a little beats one invented.
    internal var highlightRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .yellow, .yellow2, .highlight: (254.0 / 255, 253.0 / 255, 96.0 / 255)
        case .green, .green2: (169.0 / 255, 250.0 / 255, 92.0 / 255)
        case .pink: (255.0 / 255, 85.0 / 255, 207.0 / 255)
        // Black with the highlighter, grey with the pen.
        case .grayOverlap: (0, 0, 0)
        default: rgb
        }
    }
}
