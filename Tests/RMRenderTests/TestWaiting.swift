// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

// A test's own waiting. Copied rather than shared: a helper for making a
// cancellation land at a chosen moment is two dozen lines, and a package that
// depends on another repository's test bundle to run its own suite is a package
// that cannot be checked out on its own.

/// A place two tasks meet: the code under test stops at the gate, and the test
/// lets it through — after learning that it has arrived, if that is what the
/// test is about.
///
/// Written down once rather than per test file, because every copy exists
/// against the same trap: cancel after a delay and hope. A race that may or may
/// not have happened proves nothing, least of all in the tests that check a
/// cancellation arrives at all.
///
/// Deliberately without the deadline `until` carries. What opens a gate is the
/// test itself, so a run parked here is a test that forgot to open it — a
/// mistake in the waiting code, not a condition that never came true.
///
/// The wait to pass is not cancellable on purpose: the tasks held here are the
/// ones the test then cancels, and a gate that let them out on cancellation
/// would release them before the thing under test could happen.
actor Gate {
    private var isOpen = false
    private var arrivals = 0
    private var waitingToPass: [CheckedContinuation<Void, Never>] = []
    private var waitingForArrival: [CheckedContinuation<Void, Never>] = []

    /// Called from the code under test: stop here until the gate opens, and let
    /// the test know something is standing at it.
    func stopHere() async {
        arrivals += 1
        for watcher in waitingForArrival { watcher.resume() }
        waitingForArrival = []
        guard !isOpen else { return }
        await withCheckedContinuation { waitingToPass.append($0) }
    }

    /// Called from the test: return once somebody is standing at the gate.
    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { waitingForArrival.append($0) }
    }

    /// Called from the test: let everybody through, those here now and those
    /// arriving later.
    func open() {
        isOpen = true
        for waiter in waitingToPass { waiter.resume() }
        waitingToPass = []
    }
}
