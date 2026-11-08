// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Synchronization

/// The bytes of a render's pages, kept from the measuring for the drawing.
///
/// A PDF export reads every page twice: once to measure the document — the
/// sheet, the attachments, the tallies, all known before the first page is
/// drawn — and once to draw it, a window at a time, so that the parsed pages
/// are never all held at once. Asking `PageBlobs` a second time costs nothing
/// where the caller keeps a cache, and a second download of every page where
/// it does not. So the measuring puts each page's bytes here as it reads
/// them, and the drawing takes them back from here rather than from the
/// caller: each page is fetched once a render, whatever stands behind
/// `PageBlobs`.
///
/// The bytes are what a page costs unparsed — a tenth to a half of what it
/// costs parsed — and a long notebook still has hundreds of megabytes of
/// them. The first megabyte is held in memory; the rest go to a file
/// of the spool's own in the system's temporary directory, written as they
/// come and read back a page at a time, where the system holds them rather
/// than the process. The file is unlinked the moment it is opened: nothing
/// is left behind, however the render ends — finished, failed, cancelled,
/// or the process killed — and the space is the system's again once the
/// spool is let go.
///
/// A page the spool could not keep — the file would not open, the disk is
/// full — is simply not there to take back, and the drawing asks
/// `PageBlobs` for it as it did before the spool: a second fetch of that
/// page rather than a failed render.
final class PageSpool: Sendable {
    /// Where the bytes go: memory up to `memoryBudget`, then a file in
    /// `directory`.
    struct Configuration: Sendable {
        var memoryBudget: Int
        var directory: URL

        /// One megabyte in memory: a short notebook never touches the disk,
        /// and a long one adds no more than that to what the drawing holds.
        ///
        /// Small on purpose. Measured over books of 2,000 pages, uncached
        /// and cached alike, the file costs no time against memory — the
        /// pages written to it are read back before the system has let them
        /// go — while every megabyte of budget is a megabyte more at the
        /// peak: 8 MB of it added 5–10 MB, 32 MB added 25–40.
        static var standard: Configuration {
            Configuration(memoryBudget: 1 << 20, directory: FileManager.default.temporaryDirectory)
        }
    }

    private enum Place {
        case memory(Data)
        case file(offset: Int64, count: Int)
    }

    private struct State {
        var places: [Int: Place] = [:]
        var memoryBytes = 0
        /// The file, once one is wanted; `nil` until then.
        var descriptor: Int32?
        /// The file would not open: nothing more goes to it.
        var fileRefused = false
        /// Bytes reserved in the file so far — written, or being written.
        var fileLength: Int64 = 0
    }

    private let configuration: Configuration
    private let state = Mutex(State())

    init(_ configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    deinit {
        if let descriptor = state.withLock({ $0.descriptor }) { close(descriptor) }
    }

    /// Keeps `data` as the bytes of the page at `position`. A page put twice
    /// keeps the bytes it was put with last.
    func put(_ data: Data, at position: Int) {
        enum Decision {
            case kept
            case write(descriptor: Int32, offset: Int64)
            case dropped
        }
        let decision = state.withLock { state -> Decision in
            if case .memory(let old)? = state.places.removeValue(forKey: position) {
                state.memoryBytes -= old.count
            }
            if state.memoryBytes + data.count <= configuration.memoryBudget {
                state.places[position] = .memory(data)
                state.memoryBytes += data.count
                return .kept
            }
            guard let descriptor = Self.file(&state, in: configuration.directory) else { return .dropped }
            let offset = state.fileLength
            state.fileLength += Int64(data.count)
            return .write(descriptor: descriptor, offset: offset)
        }
        // Written outside the lock: each page writes a range of its own, and
        // a page of the measuring does not wait for another's write.
        guard case .write(let descriptor, let offset) = decision, Self.write(data, to: descriptor, at: offset) else {
            return
        }
        state.withLock { $0.places[position] = .file(offset: offset, count: data.count) }
    }

    /// The bytes put for the page at `position`, or `nil` where the spool
    /// kept none.
    func data(at position: Int) -> Data? {
        let found = state.withLock { state -> (place: Place, descriptor: Int32?)? in
            state.places[position].map { ($0, state.descriptor) }
        }
        switch found {
        case nil:
            return nil
        case (.memory(let data), _)?:
            return data
        case (.file(let offset, let count), let descriptor?)?:
            return Self.read(count, from: descriptor, at: offset)
        case (.file, nil)?:
            return nil
        }
    }

    /// How many bytes are held in memory, and how many went to the file.
    var footprint: (memory: Int, file: Int64) {
        state.withLock { ($0.memoryBytes, $0.fileLength) }
    }

    /// The spool's file, opened the first time it is wanted and unlinked
    /// at once, so that it lives exactly as long as the descriptor does.
    private static func file(_ state: inout State, in directory: URL) -> Int32? {
        if let descriptor = state.descriptor { return descriptor }
        guard !state.fileRefused else { return nil }
        let path = directory.appendingPathComponent(".rmrender-spool-\(UUID().uuidString)").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            state.fileRefused = true
            RMRenderLog.pageError("render: the page spool did not open (errno \(errno)) — pages are fetched again to be drawn")
            return nil
        }
        unlink(path)
        state.descriptor = descriptor
        return descriptor
    }

    private static func write(_ data: Data, to descriptor: Int32, at offset: Int64) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return buffer.isEmpty }
            var done = 0
            while done < buffer.count {
                let written = pwrite(descriptor, base + done, buffer.count - done, off_t(offset) + off_t(done))
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                done += written
            }
            return true
        }
    }

    private static func read(_ count: Int, from descriptor: Int32, at offset: Int64) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return count == 0 }
            var done = 0
            while done < count {
                let got = pread(descriptor, base + done, count - done, off_t(offset) + off_t(done))
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { return false }
                done += got
            }
            return true
        }
        return complete ? data : nil
    }
}
