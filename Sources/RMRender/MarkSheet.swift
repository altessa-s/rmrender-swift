// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import RMMarks
/// The marked blocks of one page as a single picture: the strips stacked
/// with a rule between them, and where each of them came from.
///
/// One picture instead of one per mark. What is read inside it comes back
/// through the strips: a word's box is first brought into the strip it
/// stands in, then onto the page (`PageBox.within`), and
/// from there it meets the bands like any other reading.
public struct MarkSheet: Sendable {
    /// Where a strip came from and where it landed — `RMMarks`', because
    /// the arithmetic that brings a word back to the page is written
    /// there, once, for every caller that stacks pictures.
    public typealias Strip = MarkStrip

    public let picture: CGImage
    /// In the order the blocks were given.
    public let strips: [Strip]
    /// The blocks as pictures of their own, one per strip, in the same
    /// order — for a reader that takes a picture at a time rather than
    /// one sheet, and for one that answers with words and no places.
    public let pieces: [CGImage]

    public init(picture: CGImage, strips: [Strip], pieces: [CGImage] = []) {
        self.picture = picture
        self.strips = strips
        self.pieces = pieces
    }
}
