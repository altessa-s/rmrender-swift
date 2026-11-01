// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

#if RMRENDER_FRAMEWORK
import Foundation

/// `Bundle.module`, for the build that has no SwiftPM to generate it.
///
/// Typefaces, grain tiles and templates are addressed through `Bundle.module`
/// everywhere in this package, and that property is written by SwiftPM — it does not
/// exist when the same sources are compiled as a framework by `project.yml`,
/// which is how the `.xcframework` is made. So the framework
/// build defines it here, as its own bundle, and `RMRENDER_FRAMEWORK` is set in
/// exactly one place: the framework target's compilation conditions.
///
/// The paths match by construction. SwiftPM copies `Fonts`, `Grain` and
/// `Templates` into a resource bundle with those names kept; the framework
/// target copies the same three folders into `Resources/`, so
/// `url(forResource:withExtension:subdirectory:)` finds the same file either
/// way. That is what makes the shim invisible to every caller.
private final class BundleToken {}

extension Bundle {
    static let module = Bundle(for: BundleToken.self)
}
#endif
