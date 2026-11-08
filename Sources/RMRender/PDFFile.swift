// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation

/// A value of the PDF object language.
///
/// Strings keep the bytes they were written with, delimiters and all: we never
/// make one up, and a string that goes through a decode and an encode comes
/// back different often enough — escapes, encodings, binary payloads — that
/// passing the source bytes along is both simpler and safer.
public indirect enum PDFObject: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    /// A literal or hexadecimal string, exactly as it appears in the file.
    case string(Data)
    case name(String)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    case reference(number: Int, generation: Int)
    /// A stream: its dictionary, and its bytes as stored — still encoded.
    case stream(dictionary: [String: PDFObject], data: Data)

    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        // A real is truncated the way PDF truncates, and refused when it will
        // not fit. The scanner takes `nan`, `inf` and twenty digits of number
        // from a file that says so, and `Int(_: Double)` traps on all three —
        // a trap in the reader kills the whole host process, where a `nil`
        // here is a value every caller already knows how to do without.
        case .real(let value): Int(exactly: value.rounded(.towardZero))
        default: nil
        }
    }

    var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    public var nameValue: String? {
        if case .name(let value) = self { return value }
        return nil
    }

    public var arrayValue: [PDFObject]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var dictionaryValue: [String: PDFObject]? {
        switch self {
        case .dictionary(let value): value
        case .stream(let value, _): value
        default: nil
        }
    }
}

/// What the reader refuses to work with.
///
/// Every case means "hand this document to the renderer that redraws it"
/// rather than "the document is broken": the overlay is there to keep a
/// document's links, and it must never become the reason one does not open.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PDFReadError: Error, Sendable, Equatable {
    case notAPDF
    case encrypted
    /// Never thrown: the reader reads cross-reference streams. The case
    /// stays in the frozen set so that an exhaustive `switch` over it
    /// compiles.
    case crossReferenceStream
    /// The file does not hold together, or holds something the reader does
    /// not take — a page `/UserUnit` other than 1 among them, since nothing
    /// written onto such a page would be scaled by it.
    case malformed(String)
}

/// What every copy of one `PDFFile` shares: the object streams already
/// unpacked, and what is left of the file's decoding budget.
///
/// A reference type behind a lock, because `PDFFile` is a value that is
/// copied and read from more than one task. Decoding happens outside the
/// lock; two tasks that unpack the same stream at once both pay for it, and
/// the second result is the one kept.
final class PDFDecodeState: @unchecked Sendable {
    /// The most one file may decode to, over all its streams together. A
    /// stream of a few kilobytes inflates to the 64 MB a single stream is
    /// allowed; without a total, a file of a few hundred of them is gigabytes
    /// of work.
    static let budget = 256 * 1024 * 1024

    private let lock = NSLock()
    private var remaining: Int
    private var streams: [Int: Result<PDFObjectStream, any Error>] = [:]
    private var count = 0

    init(budget: Int = PDFDecodeState.budget) {
        remaining = budget
    }

    /// How many streams have been decoded so far.
    var decodes: Int { lock.withLock { count } }

    /// `PDFStreamCodec.decode`, charged to the file's budget. A decode that
    /// fails is charged what it was allowed, since that is what it may have
    /// cost.
    func decode(_ dictionary: [String: PDFObject], _ bytes: Data) throws -> Data {
        let allowance = lock.withLock { () -> Int in
            count += 1
            return min(PDFStreamCodec.limit, remaining)
        }
        guard allowance > 0 else {
            throw PDFReadError.malformed("the file decodes to more than the reader will hold")
        }
        let data: Data
        do {
            data = try PDFStreamCodec.decode(dictionary, bytes, limit: allowance)
        } catch {
            lock.withLock { remaining -= allowance }
            throw error
        }
        try lock.withLock {
            guard data.count <= remaining else {
                remaining = 0
                throw PDFReadError.malformed("the file decodes to more than the reader will hold")
            }
            remaining -= data.count
        }
        return data
    }

    /// The object stream with this number, unpacked by `load` the first time
    /// it is asked for. A failure is kept as well: a broken stream is not
    /// worth decoding again for every object it claims to hold.
    func objectStream(_ number: Int, load: () throws -> PDFObjectStream) throws -> PDFObjectStream {
        if let known = lock.withLock({ streams[number] }) { return try known.get() }
        let result = Result { try load() }
        lock.withLock { streams[number] = result }
        return try result.get()
    }
}

/// An object stream, decoded, with its index read.
struct PDFObjectStream: Sendable {
    /// The decoded bytes, indexed from zero.
    let data: Data
    /// Where the first object begins.
    let first: Int
    /// Each packed object's number and its offset from `first`, in the
    /// stream's own order; the offsets rise strictly.
    let entries: [(number: Int, offset: Int)]
}

/// A PDF file opened for reading: its objects, its page tree, its trailer.
///
/// Mapped rather than read: a reader's book runs to hundreds of megabytes, and
/// this type exists precisely so that one need not be held in memory.
public struct PDFFile: Sendable {
    public let bytes: Data
    /// Uncompressed object number to its offset. Packed objects are resolved by
    /// `object(_:)` through their container. Newer sections win, which is
    /// what makes an already incrementally updated file read correctly.
    public let offsets: [Int: Int]
    /// Generations of the live objects in the newest revision.
    public let generations: [Int: Int]
    private let compressed: [Int: (stream: Int, index: Int)]
    public let trailer: [String: PDFObject]
    /// The highest object number any section names, free entries included.
    /// An update numbers its new objects past it, so that no number the file
    /// has ever used — and that an old reference may still say — comes back
    /// meaning something else.
    let highestObjectNumber: Int
    let state: PDFDecodeState
    /// Where the file's newest cross-reference section begins. An incremental
    /// update has to name it as its `/Prev`, or a reader stops at the update
    /// and sees a document of the few objects it changed.
    var usesCrossReferenceStreams: Bool { !compressed.isEmpty || trailer["XRefStm"] != nil || trailer["Type"] != nil }
    let lastCrossReference: Int

    /// How many cross-reference rows the reader parses over all sections
    /// together. The count of distinct objects is bounded separately; this
    /// bounds the work, which a chain of sections that repeat the same
    /// numbers multiplies.
    static let crossReferenceRowLimit = 2_000_000

    /// How many references a stream's `/Length` may pass through before it
    /// reaches its number. The walk is a loop, not a recursion, so this
    /// bounds work rather than the stack.
    private static let lengthHopLimit = 8

    /// The file at `url`, mapped: its pages are read in as the reader comes
    /// to them and are the file's own, clean, so the system takes them back
    /// under pressure rather than counting them against the process. A book
    /// of three hundred megabytes costs about what its cross-reference does.
    ///
    /// Always mapped, not "mapped if safe": the hint leaves the choice to
    /// Foundation, which reads the whole file into memory wherever it judges
    /// a mapping unsafe — and that is the very book an extension is killed
    /// for. The mapping lives as long as `bytes` or any slice of it does,
    /// which is as long as the `PDFFile` and the objects read out of it.
    /// What a mapping cannot survive is the file shrinking under it, and the
    /// renderers read only files that are theirs or the cache's for the
    /// length of the render.
    public init(url: URL) throws {
        try self.init(bytes: try Data(contentsOf: url, options: .alwaysMapped))
    }

    /// Bytes already in hand, read where they lie — nothing is mapped or
    /// copied. For a file on disk, `init(url:)`.
    public init(bytes: Data) throws {
        guard bytes.starts(with: Array("%PDF-".utf8)) else { throw PDFReadError.notAPDF }
        self.bytes = bytes
        let state = PDFDecodeState()
        self.state = state

        var offsets: [Int: Int] = [:]
        var generations: [Int: Int] = [:]
        var compressed: [Int: (stream: Int, index: Int)] = [:]
        var objects: Set<Int> = []
        var trailer: [String: PDFObject] = [:]
        var highest = 0
        var rowBudget = PDFFile.crossReferenceRowLimit
        let newest = try PDFFile.lastStartxref(in: bytes)
        lastCrossReference = newest
        var next: Int? = newest
        var seen: Set<Int> = []

        // Newest section first, so an object met again is an older version of
        // itself and must not overwrite what is already known.
        while let start = next {
            guard seen.count < 256, !seen.contains(start) else {
                throw PDFReadError.malformed("the cross-reference sections form a loop")
            }
            seen.insert(start)
            let section = try PDFFile.readSection(bytes: bytes, at: start, state: state, rowBudget: rowBudget)
            rowBudget -= section.rows
            guard objects.count + section.numbers.count <= 1_000_000 else {
                throw PDFReadError.malformed("xref object limit")
            }
            highest = max(highest, section.numbers.max() ?? 0)
            for number in section.numbers where objects.insert(number).inserted {
                offsets[number] = section.offsets[number]
                generations[number] = section.generations[number]
                compressed[number] = section.compressed[number]
            }
            for (key, value) in section.trailer where trailer[key] == nil {
                trailer[key] = value
            }
            // `/Prev` is an offset of the same kind `startxref` carries, and
            // it is checked the same way. Passed on unchecked, a negative one
            // reads before the first byte of the file and one near `Int.max`
            // overflows the arithmetic inside the scanner — and a file that
            // stops the chain silently is a file read as the handful of
            // objects its newest update changed.
            if let previous = section.trailer["Prev"] {
                guard let offset = PDFFile.crossReferenceOffset(previous, in: bytes) else {
                    throw PDFReadError.malformed("a /Prev that does not point into the file")
                }
                next = offset
            } else {
                next = nil
            }
        }

        guard trailer["Encrypt"] == nil else { throw PDFReadError.encrypted }
        guard trailer["Root"] != nil else { throw PDFReadError.malformed("the trailer has no /Root") }
        self.offsets = offsets
        self.generations = generations
        self.compressed = compressed
        self.trailer = trailer
        self.highestObjectNumber = highest
    }

    /// How many streams this file has decoded so far, its copies included.
    var decodeCount: Int { state.decodes }

    /// A stream's bytes decoded, charged to this file's budget.
    func decode(_ dictionary: [String: PDFObject], _ data: Data) throws -> Data {
        try state.decode(dictionary, data)
    }

    /// An offset that names a cross-reference section, or `nil` when the file
    /// names a place that is not in it.
    ///
    /// The one check for `startxref` and for `/Prev` both: a section that is
    /// not there has to be refused before anything indexes with it.
    private static func crossReferenceOffset(_ object: PDFObject, in bytes: Data) -> Int? {
        guard let offset = object.intValue, offset > 0, offset < bytes.count else { return nil }
        return offset
    }

    /// The place in `bytes` an offset of the file names.
    ///
    /// Offsets are counted from the first byte of the file, which is
    /// `startIndex` and not necessarily zero: `bytes` may be a slice, and the
    /// initialiser is public enough for one to arrive. The bound and the
    /// arithmetic have to agree about which end they count from, and a
    /// negative offset — a table that writes `-000000001` — has to be refused
    /// before it becomes an index at all.
    private static func place(in bytes: Data, at offset: Int) -> Data.Index? {
        // `count` is the distance from `startIndex` to `endIndex`, so this
        // bound is the one that makes the addition below both safe and inside
        // the file. Adding first and comparing after would overflow on the
        // offsets a broken table carries.
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes.startIndex + offset
    }

    /// The offset the file's last `startxref` points at.
    private static func lastStartxref(in bytes: Data) throws -> Int {
        guard let keyword = bytes.suffix(2048).lastRange(of: Data("startxref".utf8)) else {
            throw PDFReadError.malformed("no startxref")
        }
        var scanner = PDFScanner(bytes: bytes, index: keyword.upperBound)
        guard let object = try scanner.nextObject(),
              let offset = PDFFile.crossReferenceOffset(object, in: bytes)
        else {
            throw PDFReadError.malformed("startxref does not point into the file")
        }
        return offset
    }

    private struct Section {
        let numbers: Set<Int>
        let generations: [Int: Int]
        let offsets: [Int: Int]
        let trailer: [String: PDFObject]
        var compressed: [Int: (stream: Int, index: Int)] = [:]
        /// The rows parsed to read it, a hybrid section's stream included.
        var rows: Int
    }

    /// The highest object number a file may name. The format writes them in
    /// ten digits, so nothing real comes near; the bound is here so that
    /// `first + row` below is arithmetic that cannot overflow.
    static let objectNumberLimit = Int(UInt32.max)

    /// How deep a page tree may go. A real one is a few levels — a balanced
    /// tree of a hundred thousand pages is five. The walk keeps its own stack
    /// and so cannot overflow the thread's, but a chain of thousands of
    /// `/Pages` nodes is no document anybody wrote, and refusing it is what
    /// sends such a file down the redraw.
    private static let pageTreeDepthLimit = 256

    /// One cross-reference section: the table, and the trailer after it.
    ///
    /// - Parameter rowBudget: how many rows the file may still parse.
    private static func readSection(bytes: Data, at start: Int, state: PDFDecodeState, rowBudget: Int) throws -> Section {
        guard let place = PDFFile.place(in: bytes, at: start) else {
            throw PDFReadError.malformed("a cross-reference section outside the file")
        }
        var scanner = PDFScanner(bytes: bytes, index: place)
        guard scanner.readKeyword("xref") else {
            return try readStreamSection(bytes: bytes, at: start, state: state, rowBudget: rowBudget)
        }

        var offsets: [Int: Int] = [:]
        var generations: [Int: Int] = [:]
        var numbers: Set<Int> = []
        while true {
            scanner.skipWhitespace()
            if scanner.readKeyword("trailer") { break }
            guard case .integer(let first)? = try scanner.nextObject(),
                  case .integer(let count)? = try scanner.nextObject(),
                  first >= 0, count >= 0,
                  first <= PDFFile.objectNumberLimit,
                  count <= PDFFile.objectNumberLimit - first, count <= rowBudget - numbers.count
            else {
                throw PDFReadError.malformed("a cross-reference subsection without its heading")
            }
            for row in 0..<count {
                guard case .integer(let offset)? = try scanner.nextObject(),
                      case .integer(let generation)? = try scanner.nextObject(),
                      (0...65535).contains(generation),
                      let kind = scanner.readKeywordCharacter()
                else {
                    throw PDFReadError.malformed("a cross-reference row could not be read")
                }
                // `f` is a free entry: the object is not there at all, and the
                // number in it is the next free one rather than a place.
                guard numbers.insert(first + row).inserted,
                      kind == UInt8(ascii: "n") || kind == UInt8(ascii: "f") else {
                    throw PDFReadError.malformed("duplicate or invalid cross-reference row")
                }
                if kind == UInt8(ascii: "n") {
                    offsets[first + row] = offset
                    generations[first + row] = generation
                }
            }
        }

        guard case .dictionary(let trailer)? = try scanner.nextObject() else {
            throw PDFReadError.malformed("the trailer is not a dictionary")
        }
        var compressed: [Int: (stream: Int, index: Int)] = [:]
        var rows = numbers.count
        if let hybrid = trailer["XRefStm"] {
            guard let offset = crossReferenceOffset(hybrid, in: bytes), offset != start else {
                throw PDFReadError.malformed("invalid hybrid xref offset")
            }
            let extra = try readStreamSection(bytes: bytes, at: offset, state: state, rowBudget: rowBudget - rows)
            guard extra.trailer["Encrypt"] == nil else { throw PDFReadError.encrypted }
            rows += extra.rows
            // The table is read first and the stream after it: the stream
            // speaks only for the numbers the table has no object for, which
            // are the ones a hybrid writer leaves free or out of the table so
            // that an older reader skips them.
            for number in extra.numbers where offsets[number] == nil {
                numbers.insert(number)
                generations[number] = extra.generations[number]
                offsets[number] = extra.offsets[number]
                compressed[number] = extra.compressed[number]
            }
        }
        return Section(
            numbers: numbers, generations: generations, offsets: offsets, trailer: trailer,
            compressed: compressed, rows: rows
        )
    }

    private static func readStreamSection(bytes: Data, at start: Int, state: PDFDecodeState, rowBudget: Int) throws -> Section {
        guard let place = place(in: bytes, at: start) else { throw PDFReadError.malformed("xref stream offset") }
        var scanner = PDFScanner(bytes: bytes, index: place)
        guard let number = try scanner.nextObject()?.integerValue, number > 0, number <= objectNumberLimit,
              let generation = try scanner.nextObject()?.integerValue, (0...65535).contains(generation),
              scanner.readKeyword("obj"),
              case .stream(let dictionary, let raw) = try scanner.nextObject(), scanner.readKeyword("endobj"),
              case .name("XRef") = dictionary["Type"],
              let size = dictionary["Size"]?.integerValue, size > 0, size <= objectNumberLimit,
              case .array(let fields) = dictionary["W"], fields.count == 3 else {
            throw PDFReadError.malformed("invalid xref stream")
        }
        let widths = fields.compactMap(\.integerValue)
        guard widths.count == 3, widths.allSatisfy({ (0...8).contains($0) }), widths.reduce(0, +) > 0 else {
            throw PDFReadError.malformed("xref field widths")
        }
        let rowWidth = widths.reduce(0, +)
        // A predictor works on rows, and the rows of this stream are the
        // entries: a `/Columns` of anything else is a stream that does not
        // decode to the table it claims to be.
        var parameters = dictionary["DecodeParms"]
        if case .array(let values) = parameters, values.count == 1 { parameters = values[0] }
        if case .dictionary(let options) = parameters, (options["Predictor"]?.integerValue ?? 1) > 1 {
            guard options["Columns"]?.integerValue == rowWidth, (options["Colors"]?.integerValue ?? 1) == 1 else {
                throw PDFReadError.malformed("xref predictor columns")
            }
        }
        var indices = [0, size]
        if let index = dictionary["Index"] {
            guard case .array(let values) = index else { throw PDFReadError.malformed("xref Index") }
            indices = values.compactMap(\.integerValue)
            guard indices.count == values.count else { throw PDFReadError.malformed("xref Index values") }
        }
        guard indices.count.isMultiple(of: 2), !indices.isEmpty else { throw PDFReadError.malformed("xref Index pairs") }
        let data = [UInt8](try state.decode(dictionary, raw))
        var cursor = 0
        var offsets: [Int: Int] = [:], generations: [Int: Int] = [:]
        var compressed: [Int: (stream: Int, index: Int)] = [:]
        var numbers: Set<Int> = []
        func field(_ width: Int, default fallback: Int = 0) throws -> Int {
            if width == 0 { return fallback }
            guard width <= data.count - cursor else { throw PDFReadError.malformed("short xref stream") }
            var value: UInt64 = 0
            for _ in 0..<width { value = (value << 8) | UInt64(data[cursor]); cursor += 1 }
            guard value <= Int.max else { throw PDFReadError.malformed("xref field overflow") }
            return Int(value)
        }
        for i in stride(from: 0, to: indices.count, by: 2) {
            let first = indices[i], count = indices[i + 1]
            guard first >= 0, count >= 0, first <= size, count <= size - first,
                  count <= rowBudget - numbers.count,
                  count <= (data.count - cursor) / rowWidth else {
                throw PDFReadError.malformed("xref range")
            }
            for id in first..<(first + count) {
                guard numbers.insert(id).inserted else { throw PDFReadError.malformed("duplicate xref entry") }
                let kind = try field(widths[0], default: 1), value = try field(widths[1]), extra = try field(widths[2])
                switch kind {
                case 0: guard extra <= 65535 else { throw PDFReadError.malformed("xref free generation") }
                case 1:
                    guard value > 0, value < bytes.count, extra <= 65535 else { throw PDFReadError.malformed("xref object offset") }
                    offsets[id] = value; generations[id] = extra
                case 2:
                    guard value > 0, value < size else { throw PDFReadError.malformed("object stream number") }
                    compressed[id] = (value, extra); generations[id] = 0
                default: throw PDFReadError.malformed("unknown xref entry type")
                }
            }
        }
        guard cursor == data.count else { throw PDFReadError.malformed("xref trailing data") }
        return Section(
            numbers: numbers, generations: generations, offsets: offsets, trailer: dictionary,
            compressed: compressed, rows: numbers.count
        )
    }

    /// The object with this number, parsed.
    public func object(_ number: Int) throws -> PDFObject {
        if let location = compressed[number] { return try packedObject(number, at: location) }
        return try plainObject(number) { try self.streamLength($0, packed: true) }
    }

    /// An object stored at an offset of its own.
    ///
    /// - Parameter lengths: how a stream's `/Length` that is not a number is
    ///   resolved, or `nil` to refuse one.
    private func plainObject(_ number: Int, lengths: (@Sendable (PDFObject) throws -> Int)?) throws -> PDFObject {
        guard let offset = offsets[number],
              let place = PDFFile.place(in: bytes, at: offset)
        else { return .null }
        var scanner = PDFScanner(bytes: bytes, index: place)
        scanner.lengthResolver = lengths
        guard case .integer(let stated)? = try scanner.nextObject(),
              case .integer(let generation)? = try scanner.nextObject(),
              generation == generations[number],
              scanner.readKeyword("obj")
        else {
            throw PDFReadError.malformed("object \(number) is not where the table says")
        }
        guard stated == number else {
            throw PDFReadError.malformed("object \(number) calls itself \(stated)")
        }
        let value = try scanner.nextObject() ?? .null
        guard scanner.readKeyword("endobj") else {
            throw PDFReadError.malformed("object \(number) has no endobj terminator")
        }
        return value
    }

    /// A stream's `/Length`, followed to its number.
    ///
    /// The objects on the way are parsed with no resolver of their own: a
    /// length is a number, and an object that needs a stream's length to be
    /// read is not one. That is what keeps the resolution from re-entering
    /// the parser — a chain that did re-enter it, each object nested in the
    /// arrays the parser allows, multiplied the two depths and ran the
    /// thread's stack out.
    ///
    /// - Parameter packed: whether the length may sit in an object stream.
    ///   It may not for an object stream's own length, which would need
    ///   another object stream unpacked to unpack this one.
    private func streamLength(_ value: PDFObject, packed: Bool) throws -> Int {
        var value = value
        for _ in 0...PDFFile.lengthHopLimit {
            if case .integer(let length) = value, length >= 0 { return length }
            guard case .reference(let number, let generation) = value else { break }
            guard generations[number] == generation else {
                throw PDFReadError.malformed("invalid stream length reference generation")
            }
            if let location = compressed[number] {
                guard packed else {
                    throw PDFReadError.malformed("an object stream whose length is packed in an object stream")
                }
                value = try packedObject(number, at: location)
            } else {
                value = try plainObject(number, lengths: nil)
            }
        }
        throw PDFReadError.malformed("stream length must resolve to a nonnegative integer")
    }

    /// An object packed in an object stream.
    private func packedObject(_ number: Int, at location: (stream: Int, index: Int)) throws -> PDFObject {
        let container = try objectStream(location.stream)
        guard location.index >= 0, location.index < container.entries.count,
              container.entries[location.index].number == number else {
            throw PDFReadError.malformed("object stream index mismatch")
        }
        let start = container.first + container.entries[location.index].offset
        let end = location.index + 1 < container.entries.count
            ? container.first + container.entries[location.index + 1].offset
            : container.data.count
        var scanner = PDFScanner(bytes: container.data[start..<end], index: start)
        guard let value = try scanner.nextObject() else { throw PDFReadError.malformed("empty compressed object") }
        scanner.skipWhitespace()
        guard scanner.index == end else { throw PDFReadError.malformed("compressed object trailing data") }
        return value
    }

    /// An object stream, decoded and indexed once for the life of the file.
    private func objectStream(_ number: Int) throws -> PDFObjectStream {
        try state.objectStream(number) {
            // An object stream is never itself packed: one that were would
            // need another unpacked to be found, and so on down.
            guard compressed[number] == nil else {
                throw PDFReadError.malformed("an object stream inside an object stream")
            }
            guard case .stream(let dictionary, let raw) = try plainObject(number, lengths: {
                      try self.streamLength($0, packed: false)
                  }),
                  case .name("ObjStm") = dictionary["Type"],
                  let count = dictionary["N"]?.integerValue, count > 0, count <= 1_000_000,
                  let first = dictionary["First"]?.integerValue, first >= 0 else {
                throw PDFReadError.malformed("invalid object stream")
            }
            let data = try state.decode(dictionary, raw)
            guard first <= data.count else { throw PDFReadError.malformed("object stream header length") }
            var header = PDFScanner(bytes: data, index: 0)
            var entries: [(number: Int, offset: Int)] = []
            entries.reserveCapacity(min(count, data.count / 4))
            var seen: Set<Int> = []
            for _ in 0..<count {
                guard let id = try header.nextObject()?.integerValue, id > 0, id <= Self.objectNumberLimit,
                      seen.insert(id).inserted, let offset = try header.nextObject()?.integerValue,
                      offset >= 0, offset < data.count - first,
                      entries.last.map({ offset > $0.offset }) ?? true else {
                    throw PDFReadError.malformed("invalid object stream index")
                }
                entries.append((id, offset))
            }
            guard header.index <= first else { throw PDFReadError.malformed("object stream index mismatch") }
            return PDFObjectStream(data: data, first: first, entries: entries)
        }
    }

    /// The value itself: a reference is followed, anything else is returned.
    public func resolve(_ object: PDFObject?) throws -> PDFObject {
        guard let object else { return .null }
        guard case .reference(let number, let generation) = object else { return object }
        guard generations[number] == generation else {
            throw PDFReadError.malformed("reference to a missing object or wrong generation")
        }
        return try self.object(number)
    }

    /// A page, with what it inherits from the tree above it.
    public struct Page: Sendable {
        public let number: Int
        public let dictionary: [String: PDFObject]
        /// `/Resources`, `/MediaBox` and `/Rotate` are inheritable: a page may
        /// carry none of them and take its parent's. Resolved here once, so
        /// that nothing downstream has to know the rule.
        public let resources: PDFObject?
        public let mediaBox: CGRect?
        /// What a reader actually shows, when the page says. Inheritable like
        /// the media box, and different from it often enough in scanned books
        /// that the difference has to be visible to the caller: marks are
        /// placed against one box, and a reader crops to the other.
        public let cropBox: CGRect?
        public let rotation: Int
    }

    /// The pages, in the document's own order.
    public func pages() throws -> [Page] {
        guard let root = try resolve(trailer["Root"]).dictionaryValue,
              let pagesRoot = root["Pages"]
        else { throw PDFReadError.malformed("the catalogue has no page tree") }

        var pages: [Page] = []
        var visited: Set<Int> = []

        // A node still to visit, with what it inherits from the nodes above.
        struct Pending {
            let node: PDFObject
            let resources: PDFObject?
            let mediaBox: CGRect?
            let cropBox: CGRect?
            let rotation: Int
            let depth: Int
        }

        // Walked with a stack of its own rather than by recursion: a frame
        // of this walk is kilobytes in a debug build, and a file that chains
        // a few hundred `/Pages` nodes one inside the next ran the recursion
        // off the end of a cooperative thread's stack — a crash, not an error
        // a `try?` can catch. Kids go on in reverse, so they come off in the
        // document's order.
        var pending = [Pending(node: pagesRoot, resources: nil, mediaBox: nil, cropBox: nil, rotation: 0, depth: 0)]
        while let next = pending.popLast() {
            guard next.depth < PDFFile.pageTreeDepthLimit else {
                throw PDFReadError.malformed("the page tree runs deeper than \(PDFFile.pageTreeDepthLimit) levels")
            }
            guard case .reference(let number, _) = next.node else {
                throw PDFReadError.malformed("the page tree holds something other than references")
            }
            guard !visited.contains(number) else {
                throw PDFReadError.malformed("the page tree loops at object \(number)")
            }
            visited.insert(number)

            guard let dictionary = try resolve(next.node).dictionaryValue else {
                throw PDFReadError.malformed("object \(number) in the page tree is not a dictionary")
            }
            if let unit = dictionary["UserUnit"], try resolve(unit).doubleValue != 1 {
                throw PDFReadError.malformed("a /UserUnit other than 1")
            }
            let ownResources = dictionary["Resources"] ?? next.resources
            let ownBox = try rectangle(dictionary["MediaBox"]) ?? next.mediaBox
            let ownCrop = try rectangle(dictionary["CropBox"]) ?? next.cropBox
            let ownRotation = try resolve(dictionary["Rotate"]).intValue ?? next.rotation

            if dictionary["Type"]?.nameValue != "Page", dictionary["Kids"] != nil {
                guard let kids = try resolve(dictionary["Kids"]).arrayValue else {
                    throw PDFReadError.malformed("/Kids is not an array")
                }
                pending.append(contentsOf: kids.reversed().map {
                    Pending(
                        node: $0,
                        resources: ownResources,
                        mediaBox: ownBox,
                        cropBox: ownCrop,
                        rotation: ownRotation,
                        depth: next.depth + 1
                    )
                })
                continue
            }
            pages.append(
                Page(
                    number: number,
                    dictionary: dictionary,
                    resources: ownResources,
                    mediaBox: ownBox,
                    cropBox: ownCrop,
                    rotation: ownRotation
                )
            )
        }
        return pages
    }

    /// A rectangle written as four numbers, read the way a media box is: the
    /// two opposite corners may come in any order.
    public func rectangle(_ object: PDFObject?) throws -> CGRect? {
        guard let values = try resolve(object).arrayValue, values.count == 4 else { return nil }
        let numbers = try values.map { value -> Double in
            // Finite as well as a number: `[0 0 nan 1e400]` parses, and a
            // `CGRect` of infinities is not refused anywhere downstream — it
            // is drawn, and what comes out is a blank page nobody can explain.
            guard let number = try resolve(value).doubleValue, number.isFinite else {
                throw PDFReadError.malformed("a rectangle with something other than numbers in it")
            }
            return number
        }
        return CGRect(
            x: min(numbers[0], numbers[2]),
            y: min(numbers[1], numbers[3]),
            width: abs(numbers[2] - numbers[0]),
            height: abs(numbers[3] - numbers[1])
        )
    }
}

/// A reader of the PDF object language.
///
/// Deliberately small: enough to walk a page tree and copy dictionaries
/// across, not an implementation of the whole format.
struct PDFScanner: Sendable {
    /// Installed only by the file reader; a standalone scanner has no object table.
    var lengthResolver: (@Sendable (PDFObject) throws -> Int)?
    private let bytes: Data
    public private(set) var index: Data.Index

    public init(bytes: Data, index: Data.Index) {
        self.bytes = bytes
        self.index = index
    }

    private static let whitespace: Set<UInt8> = [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20]
    private static let delimiters: Set<UInt8> = Set(Array("()<>[]{}/%".utf8))

    /// How deeply arrays and dictionaries may nest before the reader refuses.
    ///
    /// The reader recurses, and a file that is nothing but opening brackets
    /// runs the stack out at around eight hundred of them, on the
    /// half-megabyte stack the cooperative pool gives the thread rendering
    /// runs on. That is a trap rather than an error, and no caller can catch
    /// it. Acrobat's own limit is 28, so this one is loose enough that no
    /// document a reader wrote will meet it.
    private static let nestingLimit = 64

    /// The byte under the cursor.
    ///
    /// Both ends are checked, not just the far one: the index comes from a
    /// place in the file, and a file that names a place before its own first
    /// byte is a file, not a crash.
    private var current: UInt8? {
        index >= bytes.startIndex && index < bytes.endIndex ? bytes[index] : nil
    }

    mutating func skipWhitespace() {
        while let byte = current {
            if PDFScanner.whitespace.contains(byte) {
                index += 1
            } else if byte == UInt8(ascii: "%") {
                while let byte = current, byte != 0x0A, byte != 0x0D { index += 1 }
            } else {
                return
            }
        }
    }

    /// Read a bare keyword if it is what comes next.
    ///
    /// The keyword has to end where a token ends. Matching a prefix would read
    /// `1 0 RG` — a colour, three tokens — as the reference `1 0 R` followed
    /// by nothing, and the object after it would be lost.
    public mutating func readKeyword(_ keyword: String) -> Bool {
        skipWhitespace()
        let wanted = Array(keyword.utf8)
        // Counted from the end rather than added to the index: an index that a
        // broken offset put near `Int.max` overflows `index + wanted.count`,
        // and an overflow traps where the answer wanted was "no, that keyword
        // is not here". Counted by hand rather than with `distance(from:to:)`,
        // which is no safer: `Data.distance` traps on an index
        // outside the collection instead of returning a negative number.
        guard index >= bytes.startIndex, bytes.endIndex - index >= wanted.count else {
            return false
        }
        for (offset, byte) in wanted.enumerated() where bytes[index + offset] != byte { return false }
        let after = index + wanted.count
        if after < bytes.endIndex {
            let next = bytes[after]
            guard PDFScanner.whitespace.contains(next) || PDFScanner.delimiters.contains(next) else {
                return false
            }
        }
        index = after
        return true
    }

    /// One letter of a cross-reference row: `n` or `f`.
    mutating func readKeywordCharacter() -> UInt8? {
        skipWhitespace()
        guard let byte = current else { return nil }
        index += 1
        return byte
    }

    /// The next object, or `nil` when what comes next is not one.
    public mutating func nextObject() throws -> PDFObject? {
        try nextObject(depth: 0)
    }

    /// - Parameter depth: how many arrays and dictionaries this object is
    ///   already inside. Carried rather than counted from the stack because
    ///   the stack is the thing being protected.
    private mutating func nextObject(depth: Int) throws -> PDFObject? {
        skipWhitespace()
        guard let byte = current else { return nil }

        switch byte {
        case UInt8(ascii: "/"):
            return .name(readName())
        case UInt8(ascii: "("):
            return .string(readLiteralString())
        case UInt8(ascii: "["):
            guard depth < PDFScanner.nestingLimit else {
                throw PDFReadError.malformed("arrays nested deeper than the reader will go")
            }
            index += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                if current == UInt8(ascii: "]") { index += 1; break }
                guard let item = try nextObject(depth: depth + 1) else {
                    throw PDFReadError.malformed("an array without its closing bracket")
                }
                items.append(item)
            }
            return .array(items)
        case UInt8(ascii: "<"):
            if index + 1 < bytes.endIndex, bytes[index + 1] == UInt8(ascii: "<") {
                return try readDictionaryOrStream(depth: depth)
            }
            return .string(readHexString())
        default:
            break
        }

        let start = index
        let token = readToken()
        switch token {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "null": return .null
        case "": throw PDFReadError.malformed("an unreadable byte where an object should be")
        default: break
        }

        if let integer = Int(token) {
            // `<n> <g> R` is a reference; anything else is a plain number.
            //
            // Looked at as two bare tokens rather than parsed: parsing the
            // generation means calling this function again, and in a run of
            // numbers that are not references — a font's `/Widths`, a few
            // hundred of them in a row — every number pays for a look at the
            // next one, and the recursion is as deep as the run is long. A
            // chain of real references stays three deep, which is why the
            // documents that work never showed it.
            var lookahead = self
            if let generation = Int(lookahead.peekToken()),
               generation >= 0,
               lookahead.readKeyword("R") {
                index = lookahead.index
                return .reference(number: integer, generation: generation)
            }
            return .integer(integer)
        }
        if let real = Double(token) { return .real(real) }
        // A keyword we do not know — `obj`, `endobj`, `stream`. The caller
        // asked for an object and there is none here; the token stays unread.
        index = start
        return nil
    }

    /// The next bare token, with nothing made of it. The one way to look
    /// ahead that does not go back through `nextObject`.
    private mutating func peekToken() -> String {
        skipWhitespace()
        return readToken()
    }

    private mutating func readToken() -> String {
        var token: [UInt8] = []
        while let byte = current,
              !PDFScanner.whitespace.contains(byte),
              !PDFScanner.delimiters.contains(byte) {
            token.append(byte)
            index += 1
        }
        return String(decoding: token, as: UTF8.self)
    }

    private mutating func readName() -> String {
        index += 1
        var name: [UInt8] = []
        while let byte = current,
              !PDFScanner.whitespace.contains(byte),
              !PDFScanner.delimiters.contains(byte) {
            // `#` escapes a byte as two hexadecimal digits.
            if byte == UInt8(ascii: "#"), index + 2 < bytes.endIndex,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                name.append(value)
                index += 3
                continue
            }
            name.append(byte)
            index += 1
        }
        return PDFScanner.nameString(name)
    }

    /// A name's bytes as a string, one character per byte (ISO Latin-1).
    ///
    /// A name is bytes, not text: `/F#e9` and a Shift-JIS font name are
    /// names a document may use, and decoding them as UTF-8 replaces what is
    /// not UTF-8 with U+FFFD — a different name, written back as one the
    /// content stream does not use. Latin-1 maps every byte to a scalar of
    /// the same value and back, so `PDFWriter` writes the bytes that came in.
    static func nameString(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    /// The bytes of a literal string, brackets and all: nesting and escapes
    /// are honoured only as far as finding where it ends.
    private mutating func readLiteralString() -> Data {
        let start = index
        index += 1
        var depth = 1
        while let byte = current {
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte == UInt8(ascii: "(") { depth += 1 }
            if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { index += 1; break }
            }
            index += 1
        }
        return bytes[start..<min(index, bytes.endIndex)]
    }

    private mutating func readHexString() -> Data {
        let start = index
        index += 1
        while let byte = current, byte != UInt8(ascii: ">") { index += 1 }
        if current != nil { index += 1 }
        return bytes[start..<min(index, bytes.endIndex)]
    }

    private mutating func readDictionaryOrStream(depth: Int) throws -> PDFObject {
        guard depth < PDFScanner.nestingLimit else {
            throw PDFReadError.malformed("dictionaries nested deeper than the reader will go")
        }
        index += 2
        var entries: [String: PDFObject] = [:]
        while true {
            skipWhitespace()
            if current == UInt8(ascii: ">"), index + 1 < bytes.endIndex,
               bytes[index + 1] == UInt8(ascii: ">") {
                index += 2
                break
            }
            guard current == UInt8(ascii: "/") else {
                throw PDFReadError.malformed("a dictionary key that is not a name")
            }
            let key = readName()
            guard let value = try nextObject(depth: depth + 1) else {
                throw PDFReadError.malformed("the key /\(key) without a value")
            }
            guard entries[key] == nil else {
                throw PDFReadError.malformed("duplicate dictionary key /\(key)")
            }
            entries[key] = value
        }

        let saved = index
        guard readKeyword("stream") else {
            index = saved
            return .dictionary(entries)
        }
        // Consume only the stream's required line ending, never payload whitespace.
        guard current == 0x0D || current == 0x0A else {
            throw PDFReadError.malformed("stream keyword has no line ending")
        }
        if current == 0x0D { index += 1 }
        if current == 0x0A { index += 1 }
        let start = index
        let length: Int
        if let value = entries["Length"], let lengthResolver {
            length = try lengthResolver(value)
        } else if case .integer(let direct)? = entries["Length"], direct >= 0 {
            length = direct
        } else {
            throw PDFReadError.malformed("stream length must be a nonnegative integer")
        }
        // The addition itself is the hazard — `/Length 9223372036854775807`
        // overflows on the way to being compared with the end of the file.
        let (end, overflowed) = start.addingReportingOverflow(length)
        guard !overflowed, end <= bytes.endIndex else {
            throw PDFReadError.malformed("a stream that runs past the end of the file")
        }
        index = end
        guard readKeyword("endstream") else {
            throw PDFReadError.malformed("stream length does not end at endstream")
        }
        return .stream(dictionary: entries, data: bytes[start..<end])
    }
}

extension Data {
    /// The last occurrence of a pattern. `range(of:options:.backwards)` wants
    /// a contiguous copy, and this runs over a mapped file of hundreds of
    /// megabytes.
    func lastRange(of pattern: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        var index = endIndex - pattern.count
        while index >= startIndex {
            if self[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index..<(index + pattern.count)
            }
            index -= 1
        }
        return nil
    }
}
