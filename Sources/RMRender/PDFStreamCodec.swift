// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import Foundation
import zlib

/// Bounded decoding for cross-reference/object streams and imported PDF operators.
///
/// What comes back always starts at index zero, whatever `bytes` was a slice
/// of: callers index the result with offsets the stream itself states.
enum PDFStreamCodec {
    /// The most one stream may decode to.
    static let limit = 64 * 1024 * 1024

    /// The widest predictor row, in bytes. A cross-reference stream's row is
    /// at most 24 bytes; nothing this codec is asked to decode has rows
    /// anywhere near this, and the bound keeps a hostile `/Columns` from
    /// sizing a buffer.
    static let predictorWidthLimit = 1 << 16

    /// Output is grown a piece at a time, so a stream costs what it decodes
    /// to rather than what the limit allows.
    private static let chunk = 64 * 1024

    static func decode(_ dictionary: [String: PDFObject], _ bytes: Data, limit: Int = PDFStreamCodec.limit) throws -> Data {
        guard let filter = dictionary["Filter"] else {
            guard bytes.count <= limit else { throw PDFReadError.malformed("oversized PDF stream") }
            return bytes.startIndex == 0 ? bytes : Data(bytes)
        }
        let filters: [PDFObject]
        if case .array(let values) = filter { filters = values } else { filters = [filter] }
        guard filters.count == 1, case .name("FlateDecode") = filters[0] else {
            throw PDFReadError.malformed("unsupported PDF stream filter")
        }
        let decoded = try inflated(bytes, limit: limit)
        var params = dictionary["DecodeParms"]
        if case .array(let values) = params {
            guard values.count == 1 else { throw PDFReadError.malformed("invalid DecodeParms array") }
            params = values.first
        }
        if params == nil || params == .null { return decoded }
        guard case .dictionary(let options) = params else { throw PDFReadError.malformed("invalid DecodeParms") }
        for key in ["Predictor", "Columns", "Colors", "BitsPerComponent"] where options[key] != nil {
            guard options[key]?.integerValue != nil else { throw PDFReadError.malformed("noninteger predictor parameter") }
        }
        let predictor = options["Predictor"]?.integerValue ?? 1
        if predictor == 1 { return decoded }
        let columns = options["Columns"]?.integerValue ?? 1
        let colors = options["Colors"]?.integerValue ?? 1
        let bits = options["BitsPerComponent"]?.integerValue ?? 8
        guard bits == 8, columns > 0, colors > 0, colors <= predictorWidthLimit,
              columns <= predictorWidthLimit / colors else {
            throw PDFReadError.malformed("unsupported predictor dimensions")
        }
        guard !decoded.isEmpty else { throw PDFReadError.malformed("a predictor over no data") }
        let width = columns * colors
        var result = [UInt8](decoded)
        if predictor == 2 {
            guard result.count.isMultiple(of: width) else { throw PDFReadError.malformed("TIFF predictor length") }
            for row in stride(from: 0, to: result.count, by: width) {
                for x in colors..<width { result[row + x] &+= result[row + x - colors] }
            }
            return Data(result)
        }
        guard (10...15).contains(predictor), decoded.count.isMultiple(of: width + 1) else {
            throw PDFReadError.malformed("PNG predictor length")
        }
        let input = result
        result = []
        result.reserveCapacity(input.count / (width + 1) * width)
        var previous = [UInt8](repeating: 0, count: width)
        for offset in stride(from: 0, to: input.count, by: width + 1) {
            let kind = input[offset]
            guard kind <= 4 else { throw PDFReadError.malformed("PNG predictor kind") }
            var row = Array(input[(offset + 1)...(offset + width)])
            for x in 0..<width {
                let left = x >= colors ? Int(row[x - colors]) : 0
                let up = Int(previous[x])
                let upperLeft = x >= colors ? Int(previous[x - colors]) : 0
                var prediction = 0
                switch kind {
                case 1: prediction = left
                case 2: prediction = up
                case 3: prediction = (left + up) / 2
                case 4:
                    let value = left + up - upperLeft
                    let a = abs(value - left), b = abs(value - up), c = abs(value - upperLeft)
                    prediction = a <= b && a <= c ? left : b <= c ? up : upperLeft
                default: break
                }
                row[x] &+= UInt8(prediction)
            }
            result.append(contentsOf: row)
            previous = row
        }
        return Data(result)
    }

    /// A zlib stream inflated into a buffer that grows with the output and
    /// stops at `limit`. A stream that ends early, or carries a bad checksum,
    /// is refused.
    private static func inflated(_ bytes: Data, limit: Int) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= Int(UInt32.max) else {
            throw PDFReadError.malformed("invalid or oversized Flate stream")
        }
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PDFReadError.malformed("invalid or oversized Flate stream")
        }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        return try bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                // `Z_BUF_ERROR` is zlib saying it can make no progress: the
                // input ran out before the stream ended.
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw PDFReadError.malformed("invalid or oversized Flate stream")
                }
                let produced = chunk - Int(stream.avail_out)
                guard produced <= limit - output.count else {
                    throw PDFReadError.malformed("invalid or oversized Flate stream")
                }
                output.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { return output }
            }
        }
    }
}
