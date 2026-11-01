// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks

/// What a PDF this package writes says about itself: the host's credit
/// (`RMRenderIdentity`) as its creator, and the person as its author where
/// one is named. Nothing
/// else — a title in the document would travel with the file after the
/// file was renamed, and the producer is Quartz's own to fill in.
enum PDFDocumentInfo {
    /// Built per call: a `CFDictionary` is not `Sendable`, and one held
    /// in a static is shared mutable state through its toll-free bridge.
    static func dictionary(author: String?) -> CFDictionary {
        var info: [String: Any] = [kCGPDFContextCreator as String: RMRenderIdentity.credit]
        if let author, !author.isEmpty { info[kCGPDFContextAuthor as String] = author }
        return info as CFDictionary
    }
}
