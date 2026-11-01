// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import Foundation
import zlib

/// Bounded decoding for cross-reference/object streams and imported PDF operators.
enum PDFStreamCodec {
    static let limit = 64 * 1024 * 1024

    static func decode(_ dictionary: [String: PDFObject], _ bytes: Data) throws -> Data {
        guard let filter = dictionary["Filter"] else { return bytes }
        let filters: [PDFObject]
        if case .array(let values) = filter { filters = values } else { filters = [filter] }
        guard filters.count == 1, case .name("FlateDecode") = filters[0] else {
            throw PDFReadError.malformed("unsupported PDF stream filter")
        }
        var capacity = min(limit, max(1024, bytes.count))
        var decoded = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: capacity)
            var count = uLongf(capacity)
            let status = bytes.withUnsafeBytes { input in
                uncompress(&buffer, &count, input.bindMemory(to: UInt8.self).baseAddress, uLong(bytes.count))
            }
            if status == Z_OK {
                decoded = Data(buffer.prefix(Int(count)))
                break
            }
            guard status == Z_BUF_ERROR, capacity < limit else {
                throw PDFReadError.malformed("invalid or oversized Flate stream")
            }
            capacity = min(limit, capacity * 2)
        }
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
        guard bits == 8, columns > 0, colors > 0, colors <= limit, columns <= limit / colors else {
            throw PDFReadError.malformed("unsupported predictor dimensions")
        }
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
        let input = [UInt8](decoded)
        result = []
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
}
