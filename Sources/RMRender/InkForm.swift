// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation

/// A page's written ink as a Form of its own, drawn beside CoreGraphics'
/// share of the page rather than appended to it.
///
/// A native page of an overlay was one PDF: CoreGraphics drew it up to its
/// ink, the ink was appended to that PDF (`InkUpdate`), and the overlay read
/// the page back, inflating both halves and deflating them again as one
/// stream — on a page of handwriting, megabytes of ink inflated to be
/// deflated again. The ink is deflated already, as it was written
/// (`InkStream`), so here it goes into the update as it stands, a Form of its
/// own, and CoreGraphics' share — the text, the pictures' placing — as
/// another; the overlay draws one and then the other,
/// `/RMNative Do /RMInk Do`. Each Form starts from the graphics state the
/// overlay hands it and is clipped to the same box, which is what the ink
/// after CoreGraphics' `Q` started from and was clipped to on the one page —
/// so the page paints what it painted. Its resources are its own, so their
/// names cannot meet CoreGraphics'. A page whose share CoreGraphics would not
/// paint at all is the ink Form alone, and CoreGraphics does not draw it.
///
/// The objects the Form names are the ones `InkUpdate` writes, to the byte,
/// so the update shares them between pages as it shares the native
/// drawings' (`PDFOverlayWriter.fingerprint`).
struct InkForm: Sendable {
    /// The dimensions a mask is drawn with.
    struct Size: Sendable, Equatable {
        let width: Int
        let height: Int
    }

    let ink: PreparedInk
    /// What each of `ink.masks` is drawn with: the dimensions `masks` gave
    /// it (`InkMaskLedger`), as `InkUpdate.append` gives them.
    let sizes: [Size]
    /// The Form's box: the box of the page CoreGraphics draws its share on.
    let box: CGRect

    /// `ink` on a page of `box`, its masks drawn through `masks` — the
    /// ledger CoreGraphics' share of the page was drawn through, after it was.
    init(_ ink: PreparedInk, box: CGRect, masks: InkMaskLedger) {
        self.ink = ink
        self.box = box
        sizes = ink.masks.map { mask in
            let size = masks.dimensions(of: mask.digest, width: mask.width, height: mask.height)
            return Size(width: size.width, height: size.height)
        }
    }

    /// The sRGB profile the ink's colours are painted through, deflated:
    /// what `InkUpdate` writes once a document, made once a process here,
    /// since every page carries a copy for the update to merge.
    static let deflatedProfile: Data? = (CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        .map(PDFWriter.flate)

    /// The profile the ink's transparency groups blend in, deflated, the
    /// same way (`PreparedInk.groupProfile`).
    static let deflatedGroupProfile: Data? = PreparedInk.groupProfile.map(PDFWriter.flate)

    /// The content stream an overlay draws its native Forms with: CoreGraphics'
    /// share where there is one, then the ink where there is any.
    static func content(native: Bool, ink: Bool) -> Data {
        let forms = (native ? ["/RMNative Do"] : []) + (ink ? ["/\(name) Do"] : [])
        return forms.isEmpty ? Data() : Data("q \(forms.joined(separator: " ")) Q\n".utf8)
    }

    /// The name the overlay's content gives the ink's Form.
    static let name = "RMInk"
}
