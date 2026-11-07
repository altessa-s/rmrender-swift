// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// What both renderers do the same way, in one place.
///
/// `NotebookRenderer` and `AnnotatedPDFRenderer` are deliberately separate —
/// what each puts on a page is a product decision of its own — but how they
/// get off the actor, how many pages they keep in flight, and how they put the
/// finished pages back into document order is not a decision either of them
/// owns. One shared symbol says "the same as the other one, for the same
/// reason" better than a comment in each could.
enum RenderWork {
    /// Why a page's marks did not make it into the drawing, as both
    /// renderers tally it: each cause reaches the caller through a callback
    /// of its own.
    enum PageLoss: Sendable {
        /// An older `.rm` generation, by its number.
        case unsupported(version: Int)
        /// Bytes that arrived and did not parse.
        case unreadable
        /// Bytes that never arrived, and what the fetch failed with.
        case unfetched(any Error)
    }

    /// How many pages are in flight at once: a notebook must not turn into
    /// fifty parallel connections.
    static let pageConcurrency = 8

    /// How many runs of an overlay's typed pages — units of more than one
    /// page, drawn into one PDF each (`NativeBatch`) — are in the window at
    /// once; each counts against `pageConcurrency` too, and pages alone keep
    /// the whole of it.
    ///
    /// A run is the heavy unit: a context and its ink drawn for up to 32
    /// pages, held until the run is handed over. With all eight of the
    /// window allowed to be runs, a thousand pages of typed text peaked at
    /// 91–95 MB; at four, 71–73 MB in the same 2.7 s, and a thousand pages
    /// set in letters of their own went from 102 to 81 MB for 2.7 → 4.0 s,
    /// still no slower than drawing every page alone. At three or fewer
    /// every book of text was slower, up to four times at one, for another
    /// 5–8 MB a run. A book without typed text has no runs, and is drawn as
    /// it was.
    static let runConcurrency = 4

    /// How many pages a drawing that writes their ink (`InkStream`) keeps
    /// in flight: one a core, and never fewer than `pageConcurrency`.
    ///
    /// Writing a page's ink is most of what drawing it costs, and it is done
    /// where the page is fetched and parsed. Pages are handed to the drawing
    /// in their order, so one slow page holds back the window behind it; at
    /// eight pages a notebook written full kept half of fourteen cores busy,
    /// and took twice as long as at one a core. The pages fetched here were
    /// fetched once already to be measured, out of the caller's cache where
    /// it keeps one.
    static let inkConcurrency = max(pageConcurrency, ProcessInfo.processInfo.activeProcessorCount)

    /// Heavy, actor-free computation, run so that cancelling the caller
    /// cancels it too.
    ///
    /// Parsing and drawing are pure computation and take real time on a large
    /// notebook, so they belong off the actor in a detached task — that much
    /// is the concurrency rule. But a detached task inherits nothing,
    /// cancellation included, and `await task.value` is not itself a
    /// cancellation point: without the handler below, a render the caller has
    /// cancelled would run to its last page regardless, and the caller would
    /// stay parked until it did. `cancel()` only raises the flag; the work
    /// has to ask, which `PageRenderer.pdf` does between pages.
    ///
    /// A caller cancelled already is answered `CancellationError` and the
    /// work is never started. The handler alone does not cover it: it is
    /// installed after the task exists, and a task that exists may run.
    /// On a loaded machine the caller's thread can be put aside for the
    /// moment between the two, and a short drawing finishes inside that
    /// moment, unasked — a render cancelled before it began came back whole.
    static func detached<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// The same for work that waits on something as it goes — a drawing that
    /// fetches and parses its next pages while it draws this one. Named apart
    /// rather than overloaded: a closure that does not wait would fit either,
    /// and which one it took would be the compiler's guess. A caller
    /// cancelled already is refused the same way.
    static func detachedWaiting<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Whether a failure is the caller having stopped waiting rather than
    /// something gone wrong with the one thing asked for.
    ///
    /// A page whose bytes would not arrive costs that page and no more (see
    /// the renderers' `onUnfetched`); a cancelled render costs the render,
    /// and has to. The two can look alike from inside a fetch: a transport
    /// cancelled under a cancelled task answers with an error of its own
    /// rather than `CancellationError`. So the task is asked as well — once
    /// it is cancelled, whatever failed is the cancellation's doing.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// `jobs` run at most `limit` at a time, and each answer is handed to
    /// `consume` in the order the jobs were given and let go once it has
    /// been — a drawing that takes pages as they are parsed and holds no
    /// more of them than the window.
    ///
    /// The window counts the answers waiting their turn as well as the jobs
    /// still running: a new job starts only when an answer has been consumed,
    /// so a slow page holds back what comes after it rather than letting
    /// finished ones pile up behind it. At most `limit` answers exist at once,
    /// and the one `consume` is working on.
    ///
    /// `consume` runs on the calling task, one answer at a time, while the
    /// next jobs go on in the background: what it touches — a `CGContext`,
    /// a file being written — is never shared. A failure, of a job or of
    /// `consume`, ends the run the way `boundedConcurrentMap` ends one.
    static func boundedConcurrentForEach<Job: Sendable, Out: Sendable>(
        _ jobs: [Job],
        limit: Int = RenderWork.pageConcurrency,
        _ transform: @escaping @Sendable (Job) async throws -> Out,
        consume: (_ position: Int, _ value: Out) throws -> Void
    ) async throws {
        try await boundedConcurrentForEach(
            jobs, limit: limit, heavy: [], heavyLimit: limit, transform, consume: consume
        )
    }

    /// The same, with a second, narrower bound on the jobs `heavy` marks —
    /// one flag a job, by position; a job past its end is not heavy — as
    /// holding more than the rest: at most `heavyLimit` of them are in the
    /// window at once, running or waiting their turn, and each counts
    /// against `limit` as well.
    ///
    /// Jobs still start in the order they were given: a heavy job that
    /// finds its bound reached waits for a heavy one to be consumed, and the
    /// jobs after it wait with it. So what is held stays a window over the
    /// list, and the answers reach `consume` in the same order as ever.
    static func boundedConcurrentForEach<Job: Sendable, Out: Sendable>(
        _ jobs: [Job],
        limit: Int,
        heavy: [Bool],
        heavyLimit: Int,
        _ transform: @escaping @Sendable (Job) async throws -> Out,
        consume: (_ position: Int, _ value: Out) throws -> Void
    ) async throws {
        let limit = max(1, limit), heavyLimit = max(1, heavyLimit)
        let heavy = jobs.indices.map { heavy.indices.contains($0) && heavy[$0] }
        try await withThrowingTaskGroup(of: (position: Int, value: Out).self) { group in
            var next = 0
            var inFlight = 0
            var heavyInFlight = 0
            func fill() {
                while next < jobs.count, inFlight < limit, !heavy[next] || heavyInFlight < heavyLimit {
                    let position = next
                    let job = jobs[position]
                    next += 1
                    inFlight += 1
                    if heavy[position] { heavyInFlight += 1 }
                    group.addTask { (position, try await transform(job)) }
                }
            }
            fill()

            var waiting: [Int: Out] = [:]
            for position in jobs.indices {
                while waiting[position] == nil {
                    // Every position below `next` is running or waiting, and
                    // this one is below it: the window stops short only while
                    // something before it is in flight, and the oldest of that
                    // is this one. So the group cannot run dry here.
                    guard let finished = try await group.next() else { return }
                    waiting[finished.position] = finished.value
                }
                guard let value = waiting.removeValue(forKey: position) else { continue }
                try consume(position, value)
                inFlight -= 1
                if heavy[position] { heavyInFlight -= 1 }
                fill()
            }
        }
    }

    /// `jobs` run at most `limit` at a time, and the answers come back in the
    /// order the jobs were given.
    ///
    /// The order is the whole reason this is not a plain `map` over a task
    /// group: a page of a document is where it is, and a PDF assembled in the
    /// order the blobs happened to land is a shuffled document. So results are
    /// written into a pre-sized array by the position the job came in at,
    /// rather than sorted afterwards by a field the job would then have to
    /// carry.
    ///
    /// `async throws` rather than `rethrows`: what throws here is
    /// `group.next()`, not a call to `transform`, and the compiler will not
    /// take the promise. The first failure ends the whole run — the group
    /// cancels its remaining children on the way out, and cancellation reaches
    /// the jobs through the ordinary path, without a check of ours.
    ///
    /// `onCompleted` is handed the number of finished jobs, once per job, and
    /// stays non-escaping so that a caller may pass a progress callback that is
    /// itself non-escaping.
    static func boundedConcurrentMap<Job: Sendable, Out: Sendable>(
        _ jobs: [Job],
        limit: Int = RenderWork.pageConcurrency,
        onCompleted: (Int) -> Void = { _ in },
        _ transform: @escaping @Sendable (Job) async throws -> Out
    ) async throws -> [Out] {
        var slots: [Out?] = Array(repeating: nil, count: jobs.count)
        try await withThrowingTaskGroup(of: (position: Int, value: Out).self) { group in
            var next = 0
            func addNext() -> Bool {
                guard next < jobs.count else { return false }
                let position = next
                let job = jobs[position]
                next += 1
                group.addTask { (position, try await transform(job)) }
                return true
            }

            // A ceiling below one would prime nothing, leave the group empty
            // and hand back a document of holes — the caller's number is
            // trusted only as far as it means anything.
            for _ in 0..<max(1, limit) where addNext() {}

            var done = 0
            while let finished = try await group.next() {
                slots[finished.position] = finished.value
                done += 1
                onCompleted(done)
                _ = addNext()
            }
        }
        // Every position is added exactly once and every added job either fills
        // its slot or throws out of the group above, so nothing is dropped here.
        return slots.compactMap { $0 }
    }
}
