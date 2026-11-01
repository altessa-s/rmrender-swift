// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Synchronization

/// Where the renderer's diagnostics go.
///
/// This package draws what was parsed and does nothing else: it has no logger of
/// its own, no opinion about files or the system log, and no dependency on the
/// host that hands it a page. What it does have is a set of lines worth saying
/// out loud — a page it could not draw, a template it could not find, a font it
/// could not embed. Every one of them is something missing from a PDF somebody
/// is about to read, and the kind of thing found months later because nothing
/// ever said it.
///
/// So the lines go to whatever the host installed, and nowhere at all until it
/// does. Not called is the supported state — a fixture test wants no log — and
/// the default is silence rather than `print`, because a library that writes to
/// a terminal nobody is watching is a library that has to be worked around.
///
/// Nothing here is ever a secret: every value in every message is a count, a
/// size, a template name or a page number. The user's writing, their document
/// names and the recognised text do not reach a sink, so the host is free to
/// install one that writes a file and keep it.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum RMRenderLog {
    /// What the line is about, so that a host can route it: the two channels
    /// are the drawing of somebody's page, and a template or font the renderer
    /// was asked for and could not honour.
    @frozen
    public enum Channel: Sendable {
        case page
        case template
    }

    /// How much the line matters. Two levels and not five: something is missing
    /// from the picture (`error`), or the renderer took a path worth knowing
    /// about and carried on (`debug`).
    @frozen
    public enum Level: Sendable {
        case debug
        case error
    }

    /// What a host installs. Called on whichever thread did the drawing — the
    /// renderer is called from wherever the work is, and a sink that touches
    /// shared state must say so itself.
    public typealias Sink = @Sendable (Channel, Level, String) -> Void

    /// Name the sink for this process. Once, at its start, from the composition
    /// root; a later call replaces the earlier one.
    public static func install(_ sink: @escaping Sink) {
        installed.withLock { $0 = sink }
    }

    /// Go back to silence. For a test that installed a sink and must not leave
    /// it behind for the next one.
    public static func silence() {
        installed.withLock { $0 = nil }
    }

    // MARK: - What the renderer calls

    static func pageError(_ message: @autoclosure () -> String) {
        write(.page, .error, message)
    }

    static func pageDebug(_ message: @autoclosure () -> String) {
        write(.page, .debug, message)
    }

    static func templateError(_ message: @autoclosure () -> String) {
        write(.template, .error, message)
    }

    /// The message is built behind an autoclosure and the closure is read under
    /// the lock: with no sink installed nothing is interpolated at all, which is
    /// what makes a line on a per-page path free.
    private static func write(_ channel: Channel, _ level: Level, _ message: () -> String) {
        guard let sink = installed.withLock({ $0 }) else { return }
        sink(channel, level, message())
    }

    private static let installed = Mutex<Sink?>(nil)
}
