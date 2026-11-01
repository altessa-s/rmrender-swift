// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreText
import Foundation
import RMMarks
import RMLines
import Synchronization

/// The typefaces typed text is set in.
///
/// Carried in the package rather than taken from the machine. The tablet sets
/// its text in reMarkable Sans and reMarkable Serif Small — faces drawn for
/// it by Letters from Sweden and not ours to ship — so the substitutes are
/// open families under the SIL Open Font License, their licence texts beside
/// them: Noto Sans and EB Garamond. Noto Sans is also what the tablet itself
/// substitutes for scripts its own faces lack, so choosing it makes those
/// runs converge by construction; the remaining width difference is absorbed
/// by `Calibration.fontStretch`. `cut(face:bold:italic:)` states which family
/// stands for which face.
///
/// The sans italics for Latin are real Noto cuts: a shear stands in for an
/// italic badly, the letterforms of a real italic differ. The serif is the
/// **variable** EB Garamond — a variable file answers with its default
/// instance unless the weight axis is pinned, so the weight is named in
/// `cut` (400/700) and pinned onto the descriptor in `font`.
///
/// Scripts none of these cover fall through to CoreText's system cascade.
enum EmbeddedFonts {
    /// The body of typed text and the items of its lists.
    static func body(size: Double) -> CTFont {
        font(size: size, face: .sans)
    }

    /// The heavier face of the same family.
    static func bold(size: Double) -> CTFont {
        font(size: size, face: .sans, bold: true)
    }

    /// The weight between the two — what a subheading is set in.
    static func medium(size: Double) -> CTFont {
        font(size: size, face: .sansMedium)
    }

    /// What the tablet sets its emphasised paragraphs and headings in: a serif
    /// face rather than a bold one.
    static func serif(size: Double) -> CTFont {
        font(size: size, face: .serif)
    }

    /// The cut for one stretch of text.
    ///
    /// Bold is Bold rather than the family's Medium — taken from the tablet's
    /// own exports rather than chosen: they name `reMarkableSans-Bold` for
    /// bold markup, and Medium is what the tablet uses for subheadings
    /// instead.
    static func font(
        size: Double,
        face: TypeFace,
        bold: Bool = false,
        italic: Bool = false
    ) -> CTFont {
        let cut = cut(face: face, bold: bold, italic: italic)
        return font(
            resource: cut.resource,
            fallback: cut.fallback,
            size: size,
            width: Calibration.fontStretch(forTabletFace: cut.tablet, size: size),
            weight: cut.weight,
            // Bold italic is the bold cut sheared: the tablet's exports name
            // `reMarkableSans-Bold` and `reMarkableSerifSmall-Bold` for it and
            // slant the matrix, so its widths are the bold's — a real bold
            // italic cut wrapped a heading a line apart from the tablet.
            slant: bold && italic ? syntheticItalicSlant : 0
        )
    }

    /// The cut for a script reMarkable Sans does not know.
    ///
    /// The tablet substitutes **Noto Sans** there, and we carry the same
    /// family, so the widths agree by construction. A cascade list cannot do
    /// this: a face that covers Cyrillic itself never triggers the fallback,
    /// so the family has to be named explicitly.
    ///
    /// There is deliberately no italic cut here: the tablet's exports name no
    /// slanted Noto faces and **synthesise** italics by shearing the text matrix —
    /// we do the same with the same value (`nonLatin(italic:)`), and a shear
    /// changes no advance. A real italic cut would: its widths differ from
    /// the upright's. Bold for these scripts the tablet synthesises by
    /// double-printing; we set a real `NotoSans-Bold` instead, which matches
    /// the tablet's double within 0.4% in width. Serif-style italics go to
    /// **NotoSans-Light** with the shear — the tablet imitates the thin
    /// serif italic with the light weight.
    ///
    /// A script that comes out of a file of its own, and so needs a width of
    /// its own.
    ///
    /// The tablet sets Hebrew from `NotoSansHebrew`, not from `NotoSans`, and
    /// it sets it narrower than our cut does — read off the corpus, four
    /// per cent by size. That correction cannot ride on the Noto cut: one cut
    /// serves every script the substitute covers, and squeezing it would
    /// squeeze the others. So the script travels with the request, and the
    /// stretch is keyed by both.
    ///
    /// Korean, the ideographs and Thai are here for the same reason. Their
    /// glyphs come from `NotoSansKR`, `NotoSansJP` and `NotoSansThaiLooped`,
    /// the families the tablet's exports name, and with those Korean needs no
    /// correction at all. The keys stay separate all the same: one number
    /// cannot be right for Latin and wrong for Hangul at once, so if a file
    /// ever sets a script differently, only a key of its own can correct it.
    enum NotoScript: String, CaseIterable {
        case general
        case hebrew
        case devanagari
        case arabic
        case korean
        case japanese
        case thai

        /// The script of one character. Hebrew is its own block plus the
        /// presentation forms; everything else falls under the general
        /// Noto key until its own numbers stand on enough lines.
        static func of(_ scalar: Unicode.Scalar) -> NotoScript {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: .hebrew
            case 0x0900...0x097F: .devanagari
            // The letters and, after them, the joined forms an export names
            // instead of letters.
            case 0x0600...0x06FF, 0xFB50...0xFEFF: .arabic
            // Hangul: the syllables, the jamo they decompose to, and the
            // compatibility block a keyboard produces.
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: .korean
            // Kana and the ideographs. One case for Japanese and Chinese
            // both, because the tablet sets them from one file: an export of
            // Chinese names `NotoSansJP` as readily as an export of Japanese.
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: .japanese
            case 0x0E00...0x0E7F: .thai
            default: .general
            }
        }
    }

    static func nonLatinCut(
        face: TypeFace,
        bold: Bool,
        italic: Bool = false,
        script: NotoScript = .general
    ) -> (resource: String, fallback: String, tablet: String) {
        let cut: (resource: String, fallback: String, tablet: String) =
            switch (face, bold, italic) {
            case (.serif, false, true): ("NotoSans-Light", "Helvetica-Light", "NotoSans-Light")
            case (.sansMedium, false, _): ("NotoSans-Medium", "Helvetica-Bold", "NotoSans-Medium")
            case (_, true, _): ("NotoSans-Bold", "Helvetica-Bold", "NotoSans-Bold")
            case (_, false, _): ("NotoSans-Regular", "Helvetica", "NotoSans-Regular")
            }
        guard script != .general else { return cut }
        // The file stays the Noto cut — these scripts arrive through the
        // cascade — and only the key changes, because only the width does. The
        // names are the ones the tablet's own exports put in `/BaseFont`,
        // which is what the stretch table is keyed by.
        let family = switch script {
        case .hebrew: "NotoSansHebrew-"
        case .devanagari: "NotoSansDevanagari-"
        case .arabic: "NotoSansArabic-"
        case .korean: "NotoSansKR-"
        case .japanese: "NotoSansJP-"
        case .thai: "NotoSansThaiLooped-"
        case .general: ""
        }
        return (
            cut.resource,
            cut.fallback,
            cut.tablet.replacingOccurrences(of: "NotoSans-", with: family)
        )
    }

    /// The shear the tablet synthesises italics with where no italic cut
    /// exists: `c = 0.3` in its exports' text matrix, one value for every
    /// Noto script. A shear changes no widths.
    static let syntheticItalicSlant = 0.3

    /// The same family as a ready-made font.
    ///
    /// Italic here is a synthesised shear, as on the tablet: its exports name
    /// no italic Noto cuts for non-Latin and slant the matrix instead.
    static func nonLatin(
        size: Double,
        face: TypeFace,
        bold: Bool,
        italic: Bool = false,
        script: NotoScript = .general
    ) -> CTFont {
        // The light weight of the serif italic belongs to the level-one
        // heading only: at 46 (an emphasised paragraph) the tablet slants
        // the plain Regular.
        let light = italic && size >= 64
        let cut = nonLatinCut(face: face, bold: bold, italic: light, script: script)
        // The cascade weight is pinned per branch: the tablet instantiates
        // real bold and medium for RTL too, and its light is a real 300 for
        // the four scripts whose width follows the weight.
        // Devanagari in a level-one heading is the one place the tablet
        // takes a lighter instance — its export names the face
        // `NotoSans-Light` on the regular heading too — and the Light of
        // Noto Sans Devanagari sets narrower: at 400 the lines read 0.9274
        // of the tablet's, at 300 the four without conjuncts 0.9994.
        // The light branch is a real 300 for the scripts whose width follows
        // the weight — Hebrew and Thai read 0.975 of the tablet's Light at
        // 400 — and Devanagari takes it on the plain heading as well.
        let lightDevanagari = script == .devanagari && size >= 64 && !bold
        let lightWeighted = (light || lightDevanagari)
            && [.hebrew, .thai, .arabic, .devanagari].contains(script)
        let cascadeWeight: Double = bold ? 700 : (face == .sansMedium ? 500 : (lightWeighted ? 300 : 400))
        return font(
            resource: cut.resource,
            fallback: cut.fallback,
            size: size,
            width: Calibration.fontStretch(forTabletFace: cut.tablet, size: size),
            slant: italic ? syntheticItalicSlant : 0,
            cascade: nonLatinCascade,
            cascadeWeight: cascadeWeight
        )
    }

    /// A cut named in one place: the file, the stand-in, the tablet face it
    /// substitutes for, and the variable-font weight that file needs (the
    /// static cuts carry none).
    struct Cut {
        let resource: String
        let fallback: String
        let tablet: String
        let weight: Double?

        /// Positional on purpose: the table below states twelve of these, and
        /// four labels on every row would bury the values they label.
        init(_ resource: String, _ fallback: String, _ tablet: String, _ weight: Double? = nil) {
            self.resource = resource
            self.fallback = fallback
            self.tablet = tablet
            self.weight = weight
        }
    }

    /// Which file we carry, what stands in when the bundle lacks it, and
    /// **which tablet face** it substitutes for.
    ///
    /// The third is the key into `Calibration.fontStretch`, and it lives here
    /// rather than there: the file in the package and the face it substitutes
    /// change together, so they are stated on one line.
    ///
    /// Split out of `font` for the tests: the file must exist in the bundle
    /// and the tablet face must have a row in the stretch table — otherwise a
    /// renamed font or a typo silently sends the coefficient to 1.0, visible
    /// only as a wrong wrap on someone's page.
    static func cut(
        face: TypeFace,
        bold: Bool,
        italic: Bool
    ) -> Cut {
        switch (face, bold, italic) {
        case (.sans, false, false):
            Cut("NotoSans-Regular", "Helvetica", "reMarkableSans-Regular")
        case (.sans, true, false):
            Cut("NotoSans-Bold", "Helvetica-Bold", "reMarkableSans-Bold")
        case (.sans, false, true):
            Cut("NotoSans-Italic", "Helvetica-Oblique", "reMarkableSans-RegularItalic")
        case (.sans, true, true):
            Cut("NotoSans-Bold", "Helvetica-Bold", "reMarkableSans-Bold")
        // The tablet drops Medium the moment a subheading carries a style:
        // bold inside one is set in ExtraBold, italic in plain RegularItalic,
        // bold italic in ExtraBoldItalic. The 36-point rows of the Bold and
        // italic keys hold those measurements — keying these cuts to "Medium"
        // would stretch them by the wrong face's number.
        case (.sansMedium, false, false):
            Cut("NotoSans-Medium", "Helvetica-Bold", "reMarkableSans-Medium")
        case (.sansMedium, false, true):
            Cut("NotoSans-Italic", "Helvetica-Oblique", "reMarkableSans-RegularItalic")
        case (.sansMedium, true, false):
            Cut("NotoSans-Bold", "Helvetica-Bold", "reMarkableSans-Bold")
        case (.sansMedium, true, true):
            Cut("NotoSans-Bold", "Helvetica-Bold", "reMarkableSans-Bold")
        case (.serif, false, false):
            Cut("EBGaramond-VariableFont_wght", "Georgia", "reMarkableSerifSmall-Regular", 400)
        case (.serif, true, false):
            Cut("EBGaramond-VariableFont_wght", "Georgia-Bold", "reMarkableSerifSmall-Bold", 700)
        case (.serif, false, true):
            Cut("EBGaramond-Italic-VariableFont_wght", "Georgia-Italic", "reMarkableSerifSmall-RegularItalic", 400)
        case (.serif, true, true):
            Cut("EBGaramond-VariableFont_wght", "Georgia-Bold", "reMarkableSerifSmall-Bold", 700)
        }
    }

    /// Descriptors are made once. Reading a 200 KB file three times a page
    /// would be a file system call per paragraph on a five-hundred-page
    /// notebook.
    private static let cache = Mutex<[String: CTFontDescriptor]>([:])

    /// The files behind the substitute face: the scripts Noto Sans itself
    /// does not cover, each in a variable Noto file. Right-to-left scripts
    /// travel in variable NotoSansArabic and NotoSansHebrew; the variable
    /// instances match the tablet's widths where the static cuts do not.
    /// They attach as a cascade on the Noto font rather than as a separate
    /// run branch: CoreText takes the glyphs NotoSans lacks from the
    /// cascade, with our widths instead of the system's.
    ///
    /// Devanagari needs its file for more than width: without it the script
    /// falls through to whatever macOS offers, and its vowel signs come out
    /// as letters of their own — 58 units of advance where the tablet gives
    /// a mark 0.06…15.5.
    ///
    /// Korean, the ideographs and Thai cost the package twenty megabytes
    /// between them — the price of setting them as the tablet does rather
    /// than as macOS happens to. Left to the system, Apple's Korean face sets
    /// six and a half per cent narrower than the tablet's, which is a word
    /// and a half on a line of forty.
    private static let nonLatinCascade = [
        "NotoSansArabic-Variable",
        "NotoSansHebrew-Variable",
        "NotoSansDevanagari-Variable",
        "NotoSansKR-Variable",
        "NotoSansJP-Variable",
        "NotoSansThaiLooped-Variable",
    ]

    private static func font(
        resource: String,
        fallback: String,
        size: Double,
        width: Double,
        weight: Double? = nil,
        slant: Double = 0,
        cascade: [String] = [],
        cascadeWeight: Double = 400
    ) -> CTFont {
        // The stretch alone: the size comes as the size, or CoreText multiplies
        // one by the other and sets a body of 32 at 384. The slant rides in
        // the same matrix — a shear moves no advance, so the widths the
        // layout measures are the upright ones.
        var matrix = CGAffineTransform(a: width, b: 0, c: slant, d: 1, tx: 0, ty: 0)
        guard var descriptor = descriptor(for: resource) else {
            // The resource is missing — a broken build rather than anything
            // the user did. A system face is wrong in the details and right in
            // the only thing that matters here: the page still comes out with
            // its text on it.
            RMRenderLog.pageError("render: the embedded font \(resource) is missing")
            return CTFontCreateWithName(fallback as CFString, size, &matrix)
        }
        if let weight {
            // Pin the weight axis of a variable file: left unpinned it answers
            // with its default instance whatever weight was asked for.
            descriptor = CTFontDescriptorCreateCopyWithVariation(
                descriptor, 0x77676874 as CFNumber, weight  // 'wght'
            )
        }
        if !cascade.isEmpty {
            let descriptors = cascade.compactMap { resource -> CTFontDescriptor? in
                guard let base = self.descriptor(for: resource) else { return nil }
                // Pin the weight axis: the cascade files are variable, and
                // unpinned they answer with the default instance whatever
                // weight is asked for.
                return CTFontDescriptorCreateCopyWithVariation(
                    base, 0x77676874 as CFNumber, cascadeWeight  // 'wght'
                )
            }
            if descriptors.count != cascade.count {
                RMRenderLog.pageError("render: a cascade font is missing from the bundle")
            }
            descriptor = CTFontDescriptorCreateCopyWithAttributes(
                descriptor,
                [kCTFontCascadeListAttribute: descriptors] as CFDictionary
            )
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, &matrix)
    }

    /// Whether a typeface actually travels with the package.
    ///
    /// Asked by the calibration tests: a missing file does not break the
    /// drawing — the layout falls back to a system face — but every width is
    /// calibrated against ours, so the check has to be somebody's. It lives here
    /// because `Bundle.module` belongs to this package alone, and a test that
    /// reached for it directly could not tell whose resources it was asking
    /// about once there were two packages carrying some.
    public static func ships(font resource: String) -> Bool {
        Bundle.module.url(forResource: resource, withExtension: "ttf", subdirectory: "Fonts") != nil
    }

    private static func descriptor(for resource: String) -> CTFontDescriptor? {
        cache.withLock { cached in
            if let descriptor = cached[resource] { return descriptor }
            guard let url = Bundle.module.url(
                forResource: resource,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ),
                let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                let first = descriptors.first
            else { return nil }
            cached[resource] = first
            return first
        }
    }
}
