// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation

/// The grain masks a document has drawn, in drawing order, and the
/// dimensions each was first drawn with.
///
/// CoreGraphics keys an image of a PDF on its bytes alone: a mask drawn with
/// the bytes of one drawn earlier in the document is the earlier one,
/// dimensions and all — a mask of 26 by 16 drawn after one of 30 by 16 with
/// the same 64 bytes comes out 30 wide. A page whose ink is partly written
/// apart (`InkStream`) has two writers drawing masks into one document, and
/// each would know only its own; this is what both consult, in the order the
/// masks are drawn, so that each mask gets the dimensions it would have had
/// had CoreGraphics drawn them all.
///
/// Not `Sendable`: the drawing that keeps it goes a page at a time.
final class InkMaskLedger {
    private var first: [SHA256.Digest: (width: Int, height: Int)] = [:]

    /// How many masks were drawn with dimensions other than their own: the
    /// bytes had been seen before with others. A drawing that shares one
    /// document between pages that were each a document of their own
    /// (`NativeBatch`) asks this to know when sharing changed a page.
    private(set) var resized = 0

    /// The dimensions a mask of `digest` is drawn with: the first ones seen
    /// with its bytes, which are these when it is the first.
    func dimensions(of digest: SHA256.Digest, width: Int, height: Int) -> (width: Int, height: Int) {
        if let known = first[digest] {
            if known != (width, height) { resized += 1 }
            return known
        }
        first[digest] = (width, height)
        return (width, height)
    }

    /// Whether any of `masks` would be drawn with dimensions other than its
    /// own, were it drawn now — asked without drawing it.
    func wouldResize(_ masks: [InkStream.Mask]) -> Bool {
        masks.contains { mask in first[mask.digest].map { $0 != (mask.width, mask.height) } ?? false }
    }

    /// The mask CoreGraphics is to draw for `bits`: the same bytes with the
    /// dimensions first seen with them.
    func drawn(_ bits: StrokeGrainMask.Bits) -> StrokeGrainMask.Bits {
        let digest = SHA256.hash(data: bits.data)
        let size = dimensions(of: digest, width: bits.width, height: bits.height)
        guard size != (bits.width, bits.height) else { return bits }
        return StrokeGrainMask.Bits(
            width: size.width, height: size.height, bytesPerRow: (size.width + 7) / 8, data: bits.data
        )
    }
}

/// Where a PDF goes: a file or memory, written first by CoreGraphics through
/// a consumer of ours, then by `InkUpdate`, which appends to what
/// CoreGraphics wrote.
///
/// Not `Sendable`: one drawing writes one PDF.
final class PDFSink {
    private enum Target {
        case memory(CFMutableData)
        case file(FileHandle, URL)
    }

    private let target: Target
    /// Bytes made and not yet handed to the file.
    private var pending: [UInt8] = []
    /// How many bytes have been written, pending ones included.
    private(set) var count = 0
    /// The first failure to write: a consumer cannot throw, so it is kept for
    /// `flush` to.
    private var failure: (any Error)?

    /// A PDF in `data`.
    init(data: CFMutableData) {
        target = .memory(data)
    }

    /// A PDF in the file at `url`, which is created, or emptied.
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RenderError.pdfContextUnavailable
        }
        target = .file(try FileHandle(forWritingTo: url), url)
    }

    /// A consumer CoreGraphics writes into this sink through.
    func consumer() -> CGDataConsumer? {
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { info, bytes, count in
                guard let info else { return 0 }
                Unmanaged<PDFSink>.fromOpaque(info).takeUnretainedValue()
                    .write(UnsafeRawBufferPointer(start: bytes, count: count))
                return count
            },
            releaseConsumer: { info in
                guard let info else { return }
                Unmanaged<PDFSink>.fromOpaque(info).release()
            }
        )
        let info = Unmanaged.passRetained(self).toOpaque()
        guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else {
            Unmanaged<PDFSink>.fromOpaque(info).release()
            return nil
        }
        return consumer
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        count += bytes.count
        switch target {
        case .memory(let data):
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            CFDataAppendBytes(data, base, bytes.count)
        case .file:
            pending.append(contentsOf: bytes)
            if pending.count >= 1 << 20 { flushPending() }
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    private func flushPending() {
        guard case .file(let handle, _) = target, !pending.isEmpty else { return }
        do {
            if failure == nil { try handle.write(contentsOf: pending) }
        } catch {
            failure = error
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// Everything written so far handed on, or the first failure to.
    func flush() throws {
        flushPending()
        if let failure { throw failure }
    }

    /// What has been written, read back as a PDF: the file mapped, or a copy
    /// of the bytes in memory — which `write` may move as it grows.
    func written() throws -> PDFFile {
        try flush()
        switch target {
        case .memory(let data):
            return try PDFFile(bytes: Data(data as Data))
        case .file(_, let url):
            return try PDFFile(url: url)
        }
    }

    /// The file closed, once everything is in it.
    func close() throws {
        try flush()
        if case .file(let handle, _) = target { try handle.close() }
    }
}

/// A page's ink made ready to append, deflated on whichever task wrote it.
struct PreparedInk: Sendable {
    /// Deflated, in pieces.
    let content: [Data]
    let states: [String]
    /// Deflated already, as the writer made them.
    let masks: [InkStream.Mask]
    let usesColorSpace: Bool

    /// What `stream` wrote, or `nil` for a page with none.
    init?(_ stream: InkStream) {
        guard let ink = stream.finish() else { return nil }
        content = ink.content
        states = ink.states
        masks = ink.masks
        usesColorSpace = ink.usesColorSpace
    }
}

/// The ink of a document's pages, appended to the PDF CoreGraphics drew the
/// rest of them into, as an incremental update.
///
/// The pages are drawn in order, each by CoreGraphics up to its ink and the
/// ink written apart (`InkStream`), side by side and ahead of the drawing.
/// What is written here goes into a spool as the pages are handed over, in
/// their order — memory first, a file once it is large — because the
/// objects of the update can only be numbered once CoreGraphics has closed
/// its document. `finish` then appends the spooled objects to that
/// document, numbered from its end, and each page with ink again, its own
/// drawing wrapped in `q`/`Q` and the ink after it, so that the ink starts
/// from PDF's initial graphics state as it would have on a page of its own.
///
/// Everything is decided by the order the pages are appended in, so the
/// bytes are the same however the ink was made.
///
/// Not `Sendable`: one drawing appends to one update.
final class InkUpdate {
    /// The masks the document has drawn, CoreGraphics' and the writer's
    /// alike; CoreGraphics' half is handed it where it draws.
    let masks = InkMaskLedger()

    private struct PageRecord {
        let index: Int
        let content: Int
        let states: [Int]
        let masks: [Int]
        let usesColorSpace: Bool
    }

    private let spool = Spool()
    private var pages: [PageRecord] = []
    private var stateObjects: [String: Int] = [:]
    private var maskObjects: [SHA256.Digest: Int] = [:]
    private var usesColorSpace = false

    /// The ink of the page at `index` — counted from nought, in the order
    /// CoreGraphics drew the pages — after everything CoreGraphics drew
    /// on it. Pages are appended in their order.
    func append(_ ink: PreparedInk, page index: Int) throws {
        if let last = pages.last, last.index >= index {
            throw PDFReadError.malformed("ink for page \(index) after page \(last.index)")
        }
        let states = try ink.states.map { entries in
            if let known = stateObjects[entries] { return known }
            let number = try spool.add([Data("<< /Type /ExtGState \(entries) >>".utf8)])
            stateObjects[entries] = number
            return number
        }
        let masks = try ink.masks.map { mask in
            if let known = maskObjects[mask.digest] { return known }
            let size = self.masks.dimensions(of: mask.digest, width: mask.width, height: mask.height)
            let length = mask.deflated.reduce(0) { $0 + $1.count }
            let head = Data(
                """
                << /Type /XObject /Subtype /Image /Width \(size.width) /Height \(size.height) \
                /ImageMask true /BitsPerComponent 1 /Length \(length) /Filter /FlateDecode >>
                stream

                """.utf8
            )
            let number = try spool.add([head] + mask.deflated + [Data("\nendstream".utf8)])
            maskObjects[mask.digest] = number
            return number
        }
        let length = ink.content.reduce(0) { $0 + $1.count }
        let content = try spool.add(
            [Data("<< /Length \(length) /Filter /FlateDecode >>\nstream\n".utf8)] + ink.content
                + [Data("\nendstream".utf8)]
        )
        usesColorSpace = usesColorSpace || ink.usesColorSpace
        pages.append(
            PageRecord(index: index, content: content, states: states, masks: masks, usesColorSpace: ink.usesColorSpace)
        )
    }

    /// The update appended to the document CoreGraphics finished writing
    /// into `sink`. Nothing is appended to a document without ink.
    func finish(into sink: PDFSink) throws {
        defer { spool.discard() }
        guard !pages.isEmpty else { return }
        let base = try sink.written()
        guard !base.usesCrossReferenceStreams else {
            throw PDFReadError.malformed("CoreGraphics wrote a cross-reference stream")
        }
        let basePages = try base.pages()
        guard let lastPage = pages.last, lastPage.index < basePages.count else {
            throw PDFReadError.malformed("ink for a page CoreGraphics did not draw")
        }
        let start = max(base.highestObjectNumber + 1, base.trailer["Size"]?.intValue ?? 1)
        let numbers = Numbers(
            open: start, close: start + 1,
            profile: usesColorSpace ? start + 2 : nil, space: usesColorSpace ? start + 3 : nil,
            first: usesColorSpace ? start + 4 : start + 2
        )
        var offsets: [Int: Int] = [:]
        var generations: [Int: Int] = [:]

        func begin(_ number: Int, generation: Int = 0) {
            offsets[number] = sink.count
            generations[number] = generation
            sink.write("\(number) \(generation) obj\n")
        }
        func end() { sink.write("\nendobj\n") }

        if base.bytes.last != 0x0A { sink.write("\n") }
        // A page's own drawing may leave its graphics state changed, and the
        // ink must start from PDF's initial one, as it would have.
        for (number, text) in [(numbers.open, "q\n"), (numbers.close, "Q\n")] {
            begin(number)
            sink.write("<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream")
            end()
        }
        if let profile = numbers.profile, let space = numbers.space {
            // The profile CoreGraphics paints its RGB colours through: sRGB's.
            guard let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else {
                throw RenderError.pdfContextUnavailable
            }
            let deflated = PDFWriter.flate(icc)
            begin(profile)
            sink.write("<< /N 3 /Alternate /DeviceRGB /Length \(deflated.count) /Filter /FlateDecode >>\nstream\n")
            sink.write(deflated)
            sink.write("\nendstream")
            end()
            begin(space)
            sink.write("[ /ICCBased \(profile) 0 R ]")
            end()
        }
        try spool.copy { index, body in
            begin(numbers.first + index)
            sink.write(body)
            end()
            if index.isMultiple(of: 64) { try sink.flush() }
        }

        for record in pages {
            let page = basePages[record.index]
            begin(page.number, generation: base.generations[page.number] ?? 0)
            sink.write(PDFWriter.bytes(of: .dictionary(try extended(page, record, in: base, numbers: numbers))))
            end()
        }
        let table = sink.count
        sink.write(PDFOverlayWriter().crossReferenceTable(offsets, generations: generations))
        var trailer: [String: PDFObject] = [
            "Size": .integer(max(start, (offsets.keys.max() ?? 0) + 1)),
            "Prev": .integer(base.lastCrossReference),
        ]
        // What identifies the document is CoreGraphics' word, carried over.
        for key in ["Root", "Info", "ID"] {
            if let value = base.trailer[key] { trailer[key] = value }
        }
        var text = Data("trailer\n".utf8)
        PDFWriter.append(.dictionary(trailer), to: &text)
        text.append(contentsOf: Array("\nstartxref\n\(table)\n%%EOF\n".utf8))
        sink.write(text)
        try sink.flush()
    }

    /// The numbers of the update's own objects: the wrapper's two streams,
    /// the colour space and its profile where any ink is coloured, and the
    /// first of the spooled objects, which follow one another from it.
    private struct Numbers {
        let open: Int
        let close: Int
        let profile: Int?
        let space: Int?
        let first: Int
    }

    /// The page CoreGraphics wrote, drawing its own content, then the ink.
    private func extended(
        _ page: PDFFile.Page, _ record: PageRecord, in base: PDFFile, numbers: Numbers
    ) throws -> [String: PDFObject] {
        func reference(_ number: Int) -> PDFObject { .reference(number: number, generation: 0) }
        let first = numbers.first
        var dictionary = page.dictionary
        dictionary["Contents"] = .array(
            [reference(numbers.open)] + (try Self.contents(of: page.dictionary["Contents"], in: base))
                + [reference(numbers.close), reference(first + record.content)]
        )
        var resources = try base.resolve(page.resources).dictionaryValue ?? [:]
        func add(_ key: String, _ entries: [(name: String, number: Int)]) throws {
            guard !entries.isEmpty else { return }
            var existing = try base.resolve(resources[key]).dictionaryValue ?? [:]
            for entry in entries {
                // The names are the writer's own; one CoreGraphics also used
                // would hand its object to the ink.
                guard existing[entry.name] == nil else {
                    throw PDFReadError.malformed("the resource name \(entry.name) is taken")
                }
                existing[entry.name] = reference(entry.number)
            }
            resources[key] = .dictionary(existing)
        }
        if record.usesColorSpace, let space = numbers.space { try add("ColorSpace", [(InkStream.colorSpaceName, space)]) }
        try add("ExtGState", record.states.enumerated().map { ("\(InkStream.statePrefix)\($0.offset)", first + $0.element) })
        try add("XObject", record.masks.enumerated().map { ("\(InkStream.maskPrefix)\($0.offset)", first + $0.element) })
        dictionary["Resources"] = .dictionary(resources)
        return dictionary
    }

    /// `/Contents` as a list: one stream, an array of them, or a reference to
    /// either; the streams left as the references they are.
    private static func contents(of object: PDFObject?, in file: PDFFile) throws -> [PDFObject] {
        guard let object else { return [] }
        if case .null = try file.resolve(object) { return [] }
        if case .array(let items) = object { return items }
        if case .reference = object, case .array(let items) = try file.resolve(object) { return items }
        return [object]
    }

    /// The bodies of the update's objects as they are added, in memory until
    /// they are many, then in a file of their own.
    private final class Spool {
        private static let memoryLimit = 8 << 20
        /// Room for the limit set aside once and reused: grown a step at a
        /// time and dropped at every spill, the buffer left a trail of freed
        /// blocks the size of each step that the process kept, more of them
        /// the longer the document.
        private var memory: [UInt8] = []
        private var file: (handle: FileHandle, url: URL)?
        private var lengths: [Int] = []

        var count: Int { lengths.count }

        /// A body of `pieces` added; its index among the bodies.
        func add(_ pieces: [Data]) throws -> Int {
            if memory.capacity == 0 { memory.reserveCapacity(Self.memoryLimit + (1 << 20)) }
            var length = 0
            for piece in pieces {
                memory.append(contentsOf: piece)
                length += piece.count
            }
            lengths.append(length)
            if memory.count >= Self.memoryLimit {
                if file == nil {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(".rmrender-ink-\(UUID().uuidString)")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw RenderError.pdfContextUnavailable
                    }
                    file = (try FileHandle(forUpdating: url), url)
                }
                try file?.handle.write(contentsOf: memory)
                memory.removeAll(keepingCapacity: true)
            }
            return lengths.count - 1
        }

        /// Every body, in order, handed to `body`.
        func copy(_ body: (Int, Data) throws -> Void) throws {
            var index = 0
            if let file {
                try file.handle.seek(toOffset: 0)
                // What has been read and not yet handed on starts at `cursor`.
                var held = Data()
                var cursor = 0
                while index < lengths.count {
                    let length = lengths[index]
                    if held.count - cursor < length {
                        held = Data(held[cursor...])
                        cursor = 0
                        while held.count < length {
                            // In a pool of its own: what `FileHandle` reads is
                            // let go when a pool drains, and the thread this
                            // runs on drains none until the render is over —
                            // the whole spool, read back, stood in memory.
                            let read = try autoreleasepool {
                                try file.handle.read(upToCount: max(1 << 20, length - held.count))
                            }
                            guard let read, !read.isEmpty else { break }
                            held.append(read)
                        }
                        // The file holds whole bodies; the rest are in memory.
                        guard held.count >= length else { break }
                    }
                    try body(index, held[cursor..<cursor + length])
                    cursor += length
                    index += 1
                }
            }
            var offset = memory.startIndex
            while index < lengths.count {
                let length = lengths[index]
                try body(index, Data(memory[offset..<offset + length]))
                offset += length
                index += 1
            }
        }

        func discard() {
            if let file {
                try? file.handle.close()
                try? FileManager.default.removeItem(at: file.url)
            }
            file = nil
            memory = []
        }

        deinit { discard() }
    }
}
