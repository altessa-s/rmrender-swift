// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
@testable import RMRender
import Testing

// The measurements and what leans on them must agree.
//
// Separate from the render suite: those check what is drawn, these check that
// the numbers are in place. A miss in this linkage breaks neither the build
// nor the drawing: the coefficient silently becomes 1.0, visible only as a
// wrap in the wrong place on a page no test has.

/// All twelve combinations of family and cut typed text can be set in:
/// three families by two flags.
private let allCuts: [(face: TypeFace, bold: Bool, italic: Bool)] = {
    var cuts: [(TypeFace, Bool, Bool)] = []
    for face in [TypeFace.sans, .sansMedium, .serif] {
        for bold in [false, true] {
            for italic in [false, true] {
                cuts.append((face, bold, italic))
            }
        }
    }
    return cuts
}()

/// The cuts for scripts reMarkable Sans does not know: there the tablet's
/// face is known and we carry the same one. The serif italic is a weight of
/// its own — the tablet sets it in NotoSans-Light.
private let allNonLatinCuts: [(face: TypeFace, bold: Bool, italic: Bool)] = [
    (.sans, false, false), (.sans, true, false),
    (.sansMedium, false, false), (.sansMedium, true, false),
    (.serif, false, true),
]

private func namedCuts() -> [(resource: String, fallback: String, tablet: String)] {
    allCuts.map {
        let cut = EmbeddedFonts.cut(face: $0.face, bold: $0.bold, italic: $0.italic)
        return (cut.resource, cut.fallback, cut.tablet)
    } + allNonLatinCuts.flatMap { cut in
        // Every script the substitute sets from a file of its own asks for a
        // width of its own, and the table has to hold a row for each.
        EmbeddedFonts.NotoScript.allCases.map {
            EmbeddedFonts.nonLatinCut(
                face: cut.face, bold: cut.bold, italic: cut.italic, script: $0
            )
        }
    }
}

@Test("Every cut knows its tablet face, and that face is known")
func everyCutHasAMeasuredStretch() {
    for named in namedCuts() {
        #expect(
            Calibration.fontStretch[named.tablet] != nil,
            "\(named.tablet) is unmeasured — the stretch goes to 1.0 without a signal"
        )
    }
}

@Test("The stretch table has no rows nobody asks for")
func noOrphanRowsInTheTable() {
    let used = Set(namedCuts().map(\.tablet))
    // A row nobody asks for is the trace of a rename: the cut in
    // `EmbeddedFonts` got a new name while the measurement stayed under the
    // old one, looking current.
    #expect(Set(Calibration.fontStretch.keys).subtracting(used).isEmpty)
}

@Test("Every cut's file ships in the package")
func everyCutShipsItsFile() {
    for named in namedCuts() {
        // This check is why the triple is split out of `font`. A missing
        // file does not break the drawing — it falls back to a system face —
        // but the stretch has been computed for ours, and the widths drift.
        #expect(
            EmbeddedFonts.ships(font: named.resource),
            "\(named.resource).ttf is missing from the package"
        )
    }
}

@Test("A size outside the table takes the nearest known one, not 1.0")
func anUnmeasuredSizeTakesTheNearestMeasured() throws {
    // The serif has 46 and 64 known. The tablet sets no size between
    // them, but the nearest is closer to the truth than an unstretched face.
    //
    // Checked against the table itself rather than a literal written here:
    // the numbers change on every recalibration, the rule does not.
    let serif = "reMarkableSerifSmall-Regular"
    let sizes = try #require(Calibration.fontStretch[serif])
    #expect(Calibration.fontStretch(forTabletFace: serif, size: 48) == sizes[46])
    #expect(Calibration.fontStretch(forTabletFace: serif, size: 60) == sizes[64])
    // A face absent from the table sets as-is, not with a neighbour's
    // number: borrowing is what the calibration rules forbid.
    #expect(Calibration.fontStretch(forTabletFace: "reMarkableSans-Thin", size: 32) == 1)
}

@Test("Subheading styles stand on their own measurements, not a neighbour's")
func subheadingCutsResolveToTheirOwnRows() throws {
    // Bold inside a subheading is the tablet's ExtraBold, and its
    // measurement lives under the 36 key of the corresponding bold face.
    // Lose that key and `nearest` silently sends the subheading to the 32
    // number — a different physical face — visible only as a moved wrap.
    // The upright Medium must have its own 36 key for the same reason. The
    // italic needs no check: its 32 and 36 are one font folded into one
    // key, where `nearest` works as intended.
    for face in ["reMarkableSans-Bold", "reMarkableSans-Medium"] {
        let sizes = try #require(Calibration.fontStretch[face])
        #expect(sizes[36] != nil, "\(face): key 36 lost — the subheading takes a foreign size")
    }
}

@Test("Exactly midway between two sizes the tie goes to the smaller")
func aTieBetweenTwoSizesGoesToTheSmaller() throws {
    // Which of the two neighbours is truer is not known. The rule exists
    // for repeatability, not accuracy: `min` over one distance returns
    // whatever the dictionary walk meets first, and Swift does not promise
    // that order — the same page could set one way or the other, and the
    // handwriting anchored to a line would move with the width, so a cached
    // page would disagree with a freshly drawn one.
    //
    // Several independent cases on purpose: the hash order is seeded per
    // process, so a broken rule could still answer one case correctly in a
    // given run. Checked through the table, not against a literal: the
    // check is that the tie went to the smaller size, not that the
    // coefficient equals some number.
    for (face, tie, smaller) in [
        ("reMarkableSerifSmall-Regular", 55.0, 46.0),
        ("reMarkableSerifSmall-Bold", 55.0, 46.0),
        ("reMarkableSans-Bold", 34.0, 32.0),
        ("reMarkableSans-RegularItalic", 34.0, 32.0),
    ] {
        let sizes = try #require(Calibration.fontStretch[face])
        #expect(Calibration.fontStretch(forTabletFace: face, size: tie) == sizes[smaller], "\(face)")
    }
    // Different keys — different bucket layouts, that is three more walk
    // orders rather than the same four again.
    #expect(Calibration.nearest(in: [1: 0.1, 3: 0.3], to: 2) == 0.1)
    #expect(Calibration.nearest(in: [10: 0.1, 20: 0.2], to: 15) == 0.1)
    #expect(Calibration.nearest(in: [100: 0.1, 200: 0.2], to: 150) == 0.1)
}
