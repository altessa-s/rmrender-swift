// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics

/// The size a notebook's pages are drawn at, and which way round they
/// stand — what the render decides before it draws, handed out on its own
/// so that a page written to match the document is the same size as the
/// document.
public struct PageGeometry: Sendable, Hashable {
    /// The canvas in the tablet's own units, turned when the document is
    /// landscape.
    public let pageSize: CGSize
    public let isLandscape: Bool

    public init(pageSize: CGSize, isLandscape: Bool) {
        self.pageSize = pageSize
        self.isLandscape = isLandscape
    }
}
