// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The Unicode ranges the layout classifies scalars by.
///
/// One home for the numbers: the same ranges decide line heights, ascent
/// splits, the first-baseline drop and the writing direction, and a typo in
/// one hand-copied range silently moves one script in one style. Every
/// predicate takes the scalar's code point.
///
/// The classes are the layout's, not Unicode's: they mirror which font an
/// export sets a script in, so e.g. `isTall` lists exactly the scripts set
/// in a Noto face.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum ScriptClass {
    /// Arabic and its presentation forms — the tallest line box of all.
    static func isArabic(_ point: Int) -> Bool {
        (0x0600...0x07BF).contains(point)
            || (0xFB50...0xFDFF).contains(point)
            || (0xFE70...0xFEFF).contains(point)
    }

    static func isHebrew(_ point: Int) -> Bool {
        (0x0590...0x05FF).contains(point)
    }

    static func isThai(_ point: Int) -> Bool {
        (0x0E00...0x0E7F).contains(point)
    }

    /// CJK ideographs, kana and Hangul (syllables and jamo).
    static func isCJK(_ point: Int) -> Bool {
        (0x2E80...0x9FFF).contains(point)
            || (0xAC00...0xD7AF).contains(point)
            || (0x1100...0x11FF).contains(point)
    }

    static func isCyrillicOrGreek(_ point: Int) -> Bool {
        (0x0400...0x052F).contains(point)
            || (0x0370...0x03FF).contains(point)
            || (0x1F00...0x1FFF).contains(point)
    }

    /// The scripts that lift a line to the Noto height — exactly those an
    /// export sets in a Noto face: Cyrillic and Greek, Devanagari, and Latin
    /// with stacked diacritics (Vietnamese). Scripts without such a face
    /// (Armenian, Georgian) fall into the sans and keep the Latin heights.
    static func isTall(_ point: Int) -> Bool {
        isCyrillicOrGreek(point)
            || (0x0900...0x097F).contains(point)                      // Devanagari
            || (0x1E00...0x1EFF).contains(point)                      // Vietnamese
            || (0x0300...0x036F).contains(point)
    }

    /// Strong right-to-left: Hebrew and Arabic with their presentation
    /// forms. Wider than `isArabic` — 0xFB1D picks up the Hebrew
    /// presentation block, which sets direction but not the Arabic height.
    public static func isStrongRightToLeft(_ point: Int) -> Bool {
        (0x0590...0x05FF).contains(point)
            || (0x0600...0x07BF).contains(point)
            || (0xFB1D...0xFDFF).contains(point)
            || (0xFE70...0xFEFF).contains(point)
    }
}
