// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines

/// A notebook fetched and parsed, everything short of drawing it: the pages
/// in the order the user sees them, the sheet they were written on, their
/// attachments. A value, so the one parse can be handed to every consumer
/// — the bitmaps for recognition, the handwriting alone, the typed text and
/// the highlights, the PDF — rather than each fetching and parsing the same
/// pages again.
public struct ParsedNotebook: Sendable {
    public let pages: [RMPage]
    public let pageSize: CGSize
    public let assets: [String: Data]
    /// The positions of pages that did not parse, or are of an older
    /// generation: they stand in `pages` as blank sheets so the numbering
    /// holds, and a reader that must not pass over an unread page can tell
    /// them from pages nobody wrote on.
    public let unreadable: Set<Int>
    /// The document's own name for each page of `pages`, in step with it —
    /// the `.rm` file it was read from — for an edit made to that file
    /// later. `nil` for a page with no file behind it: one never drawn on.
    public let pageIDs: [String?]
    /// How many pages the document has before `maximumPages` cut it —
    /// `pages.count` where nothing was cut, more where something was, and
    /// zero for a document with no page at all, which still comes back as
    /// the one blank sheet that stands for it.
    public let documentPageCount: Int
    /// The units of work a bar counts — the pages and the assembly.
    let total: Int
    /// `assets` as the images the check decoded them into, so drawing a
    /// page does not decode them again (`PageRenderer.PageImages`).
    let images: [String: CGImage]
}
