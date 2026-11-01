// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Synchronization

/// What a rendered PDF names as its creator.
///
/// One string, and the only thing this package needs from the identity of the
/// host around it. Settable rather than compiled in, because a PDF that
/// credits a library nobody has heard of is a PDF somebody has to explain, and
/// because only the host knows its own name.
///
/// Set from a composition root, beside the diagnostics sink. Left alone, the
/// credit is this package's own name — honest, if unhelpful.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum RMRenderIdentity {
    public static var credit: String {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    private static let stored = Mutex("RMRender")
}
