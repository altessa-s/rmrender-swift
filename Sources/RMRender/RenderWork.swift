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
    /// How many pages are in flight at once: a notebook must not turn into
    /// fifty parallel connections.
    static let pageConcurrency = 8

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
    static func detached<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let work = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
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
