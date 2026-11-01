// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines

// How typed text is set: which face a paragraph takes and what its list items
// are numbered with. Both are answers about drawing — the file says a
// paragraph is a heading or a numbered item, and these say what that looks
// like on the page.

/// Which face a paragraph is set in.
///
/// As the tablet's exports name them: the body in `reMarkableSans-Regular`,
/// a heading and an emphasised paragraph in `reMarkableSerifSmall-Regular`,
/// and a subheading in `reMarkableSans-Medium` — a weight between the two,
/// which is why it cannot be spelled as "sans or serif".
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TypeFace: Sendable, Hashable {
    case sans
    case sansMedium
    case serif
}

/// What a list item is numbered with. Which level uses which —
/// `Calibration`.
enum ListNumbering: Sendable, Hashable {
    case decimal
    case letter
    case roman
}
