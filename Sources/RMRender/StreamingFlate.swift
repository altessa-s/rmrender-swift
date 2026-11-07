// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Compression
import Foundation
import zlib

/// A zlib stream made a piece at a time, the way `/FlateDecode` wants it:
/// the two header bytes, the deflate blocks of the system encoder, the
/// Adler-32 of the input — what `PDFWriter.flate` makes in one go.
///
/// For operators written as they come (`InkStream`): a page written full is
/// megabytes of them, and pages are written side by side, so holding each
/// page's whole text until it was deflated was most of what a render held.
/// Here the text is handed over as it grows and only its deflated form is
/// kept.
///
/// Not `Sendable`: one writer feeds one stream.
final class StreamingFlate {
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    /// Whether the encoder was set up, so that it is torn down.
    private let initialized: Bool
    /// Set up, and not failed since.
    private var ready: Bool
    /// What has been made, in pieces of about `pieceSize`: one growing
    /// buffer a page left a trail of freed blocks of every size behind it,
    /// and with a page on every core those stayed with the process.
    private var pieces: [Data] = []
    private var piece = Data([0x78, 0x9C])
    private static let pieceSize = 1 << 16
    private var checksum = adler32(0, nil, 0)
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var finished = false

    init() {
        initialized = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        ready = initialized
    }

    deinit {
        if initialized { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    /// `bytes` added to the stream.
    func append(_ bytes: UnsafeRawBufferPointer) {
        guard ready, !finished, !bytes.isEmpty, let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        checksum = adler32(checksum, base, uInt(bytes.count))
        stream.pointee.src_ptr = base
        stream.pointee.src_size = bytes.count
        run(finalizing: false)
    }

    /// The finished stream in pieces, or `nil` where the encoder failed.
    /// Nothing may be appended after it.
    func finish() -> [Data]? {
        guard ready, !finished else { return nil }
        finished = true
        stream.pointee.src_size = 0
        run(finalizing: true)
        guard ready else { return nil }
        piece.append(contentsOf: [UInt8(checksum >> 24 & 0xFF), UInt8(checksum >> 16 & 0xFF)])
        piece.append(contentsOf: [UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)])
        return pieces + [piece]
    }

    /// `data` deflated in one go, in pieces; `nil` where the encoder failed.
    static func deflate(_ data: Data) -> [Data]? {
        let flate = StreamingFlate()
        data.withUnsafeBytes { flate.append($0) }
        return flate.finish()
    }

    /// The input handed in so far deflated into `output`; failure leaves the
    /// stream not `ready`.
    private func run(finalizing: Bool) {
        let flags = finalizing ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        buffer.withUnsafeMutableBufferPointer { out in
            guard let destination = out.baseAddress else { return }
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = out.count
                let status = compression_stream_process(stream, flags)
                let produced = out.count - stream.pointee.dst_size
                if produced > 0 {
                    if piece.count + produced > Self.pieceSize, !piece.isEmpty {
                        pieces.append(piece)
                        piece = Data(capacity: Self.pieceSize)
                    }
                    piece.append(destination, count: produced)
                }
                guard status != COMPRESSION_STATUS_ERROR else {
                    ready = false
                    return
                }
                if finalizing {
                    if status == COMPRESSION_STATUS_END { return }
                } else if stream.pointee.src_size == 0, stream.pointee.dst_size > 0 {
                    return
                }
            }
        }
    }
}
