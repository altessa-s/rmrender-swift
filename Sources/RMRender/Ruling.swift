// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// Where a template's rules lie down the page.
///
/// Measured off the template by `TemplateScan`, which is why it is this
/// package's type and not the host's: the renderer is the only thing that can
/// say where the lines actually fall. A host with a ruling type of its own in
/// its domain can map this onto it at the seam; the two may hold the same
/// three numbers and still mean different things — this one is read off a
/// picture.
@frozen
public struct Ruling: Sendable, Hashable {
    /// The topmost rule, counted from the top of the page.
    public var first: Double
    /// The distance from one rule to the next.
    public var pitch: Double
    /// A margin line the writing starts after, where the template draws one.
    public var leftMargin: Double?

    public init(first: Double, pitch: Double, leftMargin: Double? = nil) {
        self.first = first
        self.pitch = pitch
        self.leftMargin = leftMargin
    }
}
