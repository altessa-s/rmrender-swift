// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Compression
import CoreGraphics
import CryptoKit
import Foundation

/// Writing PDF objects back out.
///
/// Only what an incremental update needs: dictionaries copied from the file
/// with a key or two changed. Strings pass through as the bytes they came in
/// as — see `PDFObject.string`.
enum PDFWriter {
    static func bytes(of object: PDFObject) -> Data {
        var out = Data()
        append(object, to: &out)
        return out
    }

    /// `data` as a zlib stream, the way `/FlateDecode` wants it: the two
    /// header bytes, the deflate blocks, the Adler-32 of the input. The
    /// system encoder gives the blocks alone; the rest is wrapped here.
    /// Falls back to a stored block when the encoder declines, so that a
    /// stream is always a valid zlib stream.
    static func flate(_ data: Data) -> Data {
        var out = Data([0x78, 0x9C])
        let capacity = data.count + data.count / 100 + 64
        var encoded = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(&encoded, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        if written > 0 {
            out.append(contentsOf: encoded[0..<written])
        } else {
            // Stored blocks: uncompressed, each with its length and the
            // one's complement of it, the last one flagged final. A block
            // holds 65535 bytes at most, so the input is cut to fit.
            let blockSize = 65535
            var start = 0
            repeat {
                let end = min(start + blockSize, data.count)
                let length = UInt16(end - start)
                out.append(end == data.count ? 0x01 : 0x00)
                out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
                out.append(contentsOf: [UInt8(~length & 0xFF), UInt8(~length >> 8)])
                out.append(data[data.startIndex + start..<data.startIndex + end])
                start = end
            } while start < data.count
        }
        // Reduced every 5552 bytes rather than every byte: the most that
        // can be summed before `b` would overflow 32 bits. Every page of an
        // overlay passes through here, so the per-byte division showed.
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var start = 0
            while start < buffer.count {
                let end = min(start + 5552, buffer.count)
                for byte in buffer[start..<end] {
                    a += UInt32(byte)
                    b += a
                }
                a %= 65521
                b %= 65521
                start = end
            }
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF)])
        out.append(contentsOf: [UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    static func append(_ object: PDFObject, to out: inout Data) {
        switch object {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .boolean(let value):
            out.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .integer(let value):
            out.append(contentsOf: Array("\(value)".utf8))
        case .real(let value):
            out.append(contentsOf: Array(number(value, places: 10).utf8))
        case .string(let raw):
            out.append(raw)
        case .name(let name):
            out.append(contentsOf: Array(("/" + escaped(name)).utf8))
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for item in items {
                append(item, to: &out)
                out.append(UInt8(ascii: " "))
            }
            out.append(UInt8(ascii: "]"))
        case .dictionary(let entries):
            appendDictionary(entries, to: &out)
        case .reference(let number, let generation):
            out.append(contentsOf: Array("\(number) \(generation) R".utf8))
        case .stream(let dictionary, let data):
            appendDictionary(dictionary, to: &out)
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(data)
            out.append(contentsOf: Array("\nendstream".utf8))
        }
    }

    private static func appendDictionary(_ entries: [String: PDFObject], to out: inout Data) {
        out.append(contentsOf: Array("<<".utf8))
        // Sorted so that the same input gives the same bytes: a render that
        // changes for no reason invalidates every copy already downloaded.
        for key in entries.keys.sorted() {
            out.append(contentsOf: Array(("/" + escaped(key) + " ").utf8))
            append(entries[key] ?? .null, to: &out)
            out.append(UInt8(ascii: " "))
        }
        out.append(contentsOf: Array(">>".utf8))
    }

    /// A name with the bytes a name may not carry written as `#xx`.
    ///
    /// The reader keeps a name's bytes one per scalar (`PDFScanner.nameString`),
    /// so a scalar below 256 is the byte itself. A scalar above it is no byte
    /// the reader made; it comes from a name given here as text, and is
    /// written as its UTF-8.
    private static func escaped(_ name: String) -> String {
        var bytes: [UInt8] = []
        for scalar in name.unicodeScalars {
            if scalar.value < 256 {
                bytes.append(UInt8(scalar.value))
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        var out = ""
        for byte in bytes {
            let allowed = byte > 0x20 && byte < 0x7F && !Array("()<>[]{}/%#".utf8).contains(byte)
            out += allowed ? String(UnicodeScalar(byte)) : String(format: "#%02x", byte)
        }
        return out
    }

    /// A number the way PDF wants it: no exponent, no trailing noise.
    ///
    /// Worked out in integers where that is safe rather than through
    /// `String(format:)`: every coordinate of an overlay passes through here,
    /// and a locale built and a format string read per number was a good part
    /// of the time a marked book took to write. The text has to stay the
    /// formatter's to the byte — an overlay written twice from one document is
    /// the same file — so the integers answer only where they cannot differ
    /// from it (`fixedPoint`), and the rest goes to the formatter as before.
    static func number(_ value: Double, places: Int = 4) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return "\(Int(value))" }
        return fixedPoint(value, places: places) ?? formatted(value, places: places)
    }

    /// The text as it was first written: the localized `%f`, its trailing
    /// zeros cut. What `fixedPoint` declines comes here, and the tests hold
    /// the one against the other.
    ///
    /// Not the C library's `%f`, which rounds the exact binary value: with a
    /// locale, Foundation rounds the shortest decimal that names the double,
    /// half to even. 1234.56775 is a hair below the half in binary, and the
    /// two disagree on it — `…5677` from the C library, `…5678` here.
    static func formatted(_ value: Double, places: Int) -> String {
        var text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Ten to the power of the index, for the places `fixedPoint` takes.
    private static let decimalPowers: [UInt128] = (0...18).map { power in
        (0..<power).reduce(UInt128(1)) { product, _ in product * 10 }
    }

    /// `value` rounded to `places` decimals, or `nil` where the answer might
    /// not be `formatted`'s.
    ///
    /// A finite double is `m · 2^e` with `m` below 2^53, so `value · 10^places`
    /// is the integer `m · 10^places` shifted right by `-e`, exact in 128 bits,
    /// and the bits shifted out say which way it rounds. That is the exact
    /// value's rounding; `formatted` rounds the shortest decimal naming the
    /// double instead, which lies within half a unit in the last place of it.
    /// Nor is it quite that: held against millions of values, the formatter
    /// behaves as if it rounded a decimal of fifteen significant digits at
    /// times — `-0.0021588807691127476` comes out `…1128` at sixteen places.
    /// So the integers answer only where no such decimal can round otherwise:
    /// thirteen digits at most, and the value further from a half of the
    /// last of them than a unit of the double and a unit of the fourteenth
    /// digit together. A coordinate at four places is that, nearly always;
    /// what is not goes to the formatter.
    static func fixedPoint(_ value: Double, places: Int) -> String? {
        // Nought places is left to the formatter: its trailing-zero cut eats
        // the integer's own zeros there ("20" comes out "2"), and that is its
        // text to keep, not this function's to imitate.
        guard places >= 1, places < decimalPowers.count else { return nil }
        let bits = value.bitPattern
        let biased = Int((bits >> 52) & 0x7FF)
        // From 2^52 up a double is a whole number of sixteen digits or more.
        guard biased < 1075 else { return nil }
        let fraction = bits & ((1 << 52) - 1)
        let significand = UInt128(biased == 0 ? fraction : fraction | (1 << 52))
        let shift = 1075 - max(biased, 1)
        // So small that nothing of it is left at any number of places, and
        // whether `-0` or `0` comes out of that is the formatter's to say.
        guard shift < 113 else { return nil }
        let scale = decimalPowers[places]
        // Below 2^113: the significand is under 2^53 and the scale under 2^60.
        let product = significand * scale
        var scaled = product >> shift
        let remainder = product & ((1 << shift) - 1)
        let half = UInt128(1) << (shift - 1)
        // Thirteen digits at most, so that a decimal of fourteen significant
        // digits still reaches past the last of them.
        guard scaled < decimalPowers[13] else { return nil }
        var length = 1
        while scaled >= decimalPowers[length] { length += 1 }
        // How far from the half the value has to stand: a unit in the last
        // place of the double — `scale`, here — and the most a decimal of
        // fourteen significant digits can stand from the value, in the units
        // of the shift.
        let approximation = (UInt128(1) << shift) / decimalPowers[14 - length]
        let fromHalf = remainder > half ? remainder - half : half - remainder
        guard fromHalf > scale + approximation else { return nil }
        if remainder > half { scaled += 1 }

        // Under 10^13, so an ordinary integer from here on.
        let narrow = UInt64(scaled), narrowScale = UInt64(scale)
        var text = value.sign == .minus ? "-" : ""
        text += String(narrow / narrowScale)
        var decimals = narrow % narrowScale
        guard decimals != 0 else { return text }
        // The decimals with their leading zeros and without their trailing
        // ones: "0.0500" is "0.05".
        var digits = places
        while decimals.isMultiple(of: 10) {
            decimals /= 10
            digits -= 1
        }
        let written = String(decimals)
        text += "."
        text += String(repeating: "0", count: digits - written.count)
        text += written
        return text
    }
}

/// Marks put onto a document without rebuilding it.
///
/// A PDF may be changed by appending to it: the original bytes stay where they
/// are, new objects go after them, and a new cross-reference section says what
/// the file now means. A reader follows the newest section and sees the
/// changed pages; everything not mentioned — links, outline, metadata, text —
/// is the original's own and is never touched.
///
/// That is the whole reason this exists. Redrawing a document into a new PDF
/// costs its links: for example, a live book with 624 annotations and 84
/// links came out with none.
public struct PDFOverlayWriter: Sendable {
    /// One way of laying ink over what a page already has.
    ///
    /// Named rather than numbered because the content stream refers to it by
    /// name, and carried as a list rather than as a handful of flags: a stroke's
    /// opacity comes out of the file (the alpha byte of `argb`), so how many
    /// states a page needs is a property of that page.
    public struct GraphicsState: Sendable, Hashable {
        /// The name the content stream says, without the slash.
        public let name: String
        /// The PDF blend mode, or `nil` for the ordinary one.
        public let blendMode: String?
        public let alpha: Double

        public init(name: String, blendMode: String?, alpha: Double) {
            self.name = name
            self.blendMode = blendMode
            self.alpha = alpha
        }
    }

    /// A stencil the content paints through: one bit a pixel, rows padded
    /// to a byte, nought where the colour goes — the grain of a pencil.
    ///
    /// An operator stream cannot carry pixels; they go into an object of
    /// their own that the stream names, and the writer is the one place
    /// that makes objects.
    public struct ImageMask: Sendable, Hashable {
        /// The name the content stream says, without the slash.
        public let name: String
        public let width: Int
        public let height: Int
        public let bits: Data

        public init(name: String, width: Int, height: Int, bits: Data) {
            self.name = name
            self.width = width
            self.height = height
            self.bits = bits
        }
    }

    /// What a graphics state says, without the name it is said by: the key
    /// one object is shared under, whatever each page happens to call it.
    private struct StateAppearance: Hashable {
        let blendMode: String?
        let alpha: Double
    }

    /// What goes onto one page.
    public struct Overlay: Sendable {
        /// The page of the original, counted from zero.
        public let pageIndex: Int
        /// Content stream operators, in the page's own coordinates.
        public let content: Data
        /// The states the content refers to by name.
        public let states: [GraphicsState]
        /// The stencils the content paints through, by name.
        public let images: [ImageMask]
        /// The rectangle the page is to be shown as, or `nil` to leave the
        /// original's alone.
        ///
        /// Marks that run off the sheet are drawn outside the page's box, and
        /// a reader shows the box: without this the ink is in the file and
        /// invisible. Nothing in the page's own coordinates moves — what
        /// changes is only which part of them counts as the page.
        public let box: CGRect?
        /// A one-page PDF imported as the RMNative Form in this overlay.
        public let formPDF: Data?
        /// The page's written ink, imported as the `InkForm.name` Form.
        let ink: InkForm?

        public init(
            pageIndex: Int,
            content: Data,
            states: [GraphicsState],
            images: [ImageMask] = [],
            box: CGRect? = nil,
            formPDF: Data? = nil
        ) {
            self.init(
                pageIndex: pageIndex, content: content, states: states, images: images, box: box, formPDF: formPDF,
                ink: nil
            )
        }

        init(
            pageIndex: Int,
            content: Data,
            states: [GraphicsState],
            images: [ImageMask] = [],
            box: CGRect? = nil,
            formPDF: Data? = nil,
            ink: InkForm?
        ) {
            self.pageIndex = pageIndex
            self.content = content
            self.states = states
            self.images = images
            self.box = box
            self.formPDF = formPDF
            self.ink = ink
        }
    }

    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum OverlayError: Error, Sendable, Equatable {
        /// The page a mark belongs to is not in the original.
        case noSuchPage(Int)
        /// Never thrown: the overlay is placed in the page's own coordinates
        /// and the page keeps its `/Rotate`. The case stays in the frozen set
        /// so that an exhaustive `switch` over it compiles.
        case rotatedPage(Int)
    }

    public init() {}

    /// Copy the original and append the marks to the copy.
    ///
    /// The copy comes first because on APFS it costs nothing: the bytes are
    /// shared until one of the two files is written to, and the only writing
    /// here is at the end.
    public func write(original: URL, overlays: [Overlay], to output: URL) throws {
        let file = try PDFFile(url: original)
        try write(file: file, pages: try file.pages(), original: original, overlays: overlays, to: output)
    }

    /// The same, for a caller that has already read the file: the page tree of
    /// a five-hundred-page book is not worth walking twice, and the caller has
    /// to walk it anyway to know whether the overlay applies at all.
    ///
    /// A certified original — `/Perms` in its catalog — is refused with
    /// `RenderError.unsupportedFormat` before anything is written: an
    /// incremental update breaks the certification. `AnnotatedPDFRenderer`
    /// makes the same check itself and draws such a document afresh instead.
    public func write(
        file: PDFFile,
        pages: [PDFFile.Page],
        original: URL,
        overlays: [Overlay],
        to output: URL
    ) throws {
        var remaining = overlays.makeIterator()
        try write(
            file: file,
            pages: pages,
            original: original,
            pageIndices: overlays.map(\.pageIndex),
            to: output
        ) { _ in
            // Asked for once per index and in their order, so the list
            // cannot run out before the indices do.
            guard let overlay = remaining.next() else {
                throw PDFReadError.malformed("fewer overlays than pages")
            }
            return overlay
        }
    }

    /// The same, a page at a time: `overlay` is asked for the marks of each
    /// page in `pageIndices`, once and in that order, and what it hands back
    /// is written out before the next page is asked for. A book's worth of
    /// marks is never in memory at once — one page of it is, and the
    /// cross-reference — where collecting them first took a fully marked
    /// book of two thousand pages to 2.9 GB, the size of the extension that
    /// does it.
    ///
    /// What can be refused from what is known up front — a certified
    /// original, a page index the original does not have, a `/Size` past
    /// what the format counts — is refused before anything is written. What
    /// fails later — `overlay` throwing, a page that does not hold together,
    /// an overlay for a page other than the one asked for — stops the write
    /// where it is: the half-written copy is removed and `output` is left as
    /// it was.
    public func write(
        file: PDFFile,
        pages: [PDFFile.Page],
        original: URL,
        pageIndices: [Int],
        to output: URL,
        overlay make: (_ pageIndex: Int) throws -> Overlay
    ) throws {
        let revision = try Revision(
            writer: self, file: file, pages: pages, original: original, pageIndices: pageIndices, output: output
        )
        do {
            for pageIndex in pageIndices {
                try revision.append(try make(pageIndex))
            }
            try revision.finish()
        } catch {
            revision.abandon()
            throw error
        }
    }

    /// The same, with the pages made side by side: `overlay` is asked for up
    /// to `limit` pages at once, each is prepared — deflated, its native
    /// drawing read — on the task that made it, and they are appended in
    /// the order of `pageIndices`. The file is the one `write(…overlay:)`
    /// makes from the same overlays, to the byte.
    ///
    /// A page waiting its turn counts against `limit` as one being made
    /// does (`RenderWork.boundedConcurrentForEach`), so what is held is at
    /// most `limit` prepared pages, whatever the length of the book. The
    /// first failure — of `overlay`, of preparing a page, of writing one —
    /// ends the run, cancels the pages still being made, and leaves `output`
    /// as it was, as cancelling the caller does.
    func writeConcurrently(
        file: PDFFile,
        pages: [PDFFile.Page],
        original: URL,
        pageIndices: [Int],
        to output: URL,
        limit: Int = RenderWork.pageConcurrency,
        overlay make: @escaping @Sendable (_ pageIndex: Int) async throws -> Overlay
    ) async throws {
        try await writeConcurrently(
            file: file, pages: pages, original: original, units: pageIndices.map { [$0] }, to: output, limit: limit
        ) { unit in
            OverlayBatch(overlays: [try await make(unit[0])])
        }
    }

    /// The same, with the pages made a run at a time: `units` are runs of
    /// page indices, in order, and `batch` is asked for the overlays of each
    /// unit — up to `limit` units at once — and hands back one overlay per
    /// page of it, in its order. The pages are appended in the order of the
    /// runs, as they would be from `units` flattened.
    ///
    /// What a run is for: the pages of one share one PDF of native drawings
    /// (`OverlayBatch.drawing`), read once for all of them, so that what
    /// they have in common — a typeface above all — is one object in that
    /// PDF and is written once. A unit counts against `limit` as one,
    /// whatever its length; a unit of more than one page — a run — counts
    /// against `runLimit` as well (`RenderWork.runConcurrency`), so what is
    /// held is at most `runLimit` runs and the rest of the window in pages
    /// alone; the caller keeps the runs short. Everything else is
    /// `writeConcurrently(…overlay:)`'s: a failure anywhere ends the write,
    /// cancels what is still being made and leaves `output` as it was.
    func writeConcurrently(
        file: PDFFile,
        pages: [PDFFile.Page],
        original: URL,
        units: [[Int]],
        to output: URL,
        limit: Int = RenderWork.pageConcurrency,
        runLimit: Int = RenderWork.runConcurrency,
        batch make: @escaping @Sendable (_ pageIndices: [Int]) async throws -> OverlayBatch
    ) async throws {
        let revision = try Revision(
            writer: self, file: file, pages: pages, original: original, pageIndices: units.flatMap { $0 },
            output: output
        )
        do {
            try await RenderWork.boundedConcurrentForEach(
                units, limit: limit, heavy: units.map { $0.count > 1 }, heavyLimit: runLimit
            ) { unit in
                let batch = try await make(unit)
                guard batch.overlays.count == unit.count else {
                    batch.discard()
                    throw PDFReadError.malformed("\(batch.overlays.count) overlays for a run of \(unit.count) pages")
                }
                return try prepare(batch)
            } consume: { _, prepared in
                for page in prepared { try revision.append(page) }
            }
            try revision.finish()
        } catch {
            revision.abandon()
            throw error
        }
    }

    /// The overlays of a run of pages, and the PDF whose pages are the
    /// native drawings of some of them.
    struct OverlayBatch: Sendable {
        let overlays: [Overlay]
        /// For each overlay, the page of `drawing` that is its native Form,
        /// counting from nought; `nil` for an overlay with none, or with its
        /// own (`Overlay.formPDF`).
        let drawingPages: [Int?]
        /// A file the batch owns: removed once it is read (`prepare`), or
        /// by `discard`.
        let drawing: URL?

        init(overlays: [Overlay], drawingPages: [Int?]? = nil, drawing: URL? = nil) {
            self.overlays = overlays
            self.drawingPages = drawingPages ?? overlays.map { _ in nil }
            self.drawing = drawing
        }

        /// The file let go unread.
        func discard() {
            if let drawing { try? FileManager.default.removeItem(at: drawing) }
        }
    }

    /// An incremental update being written: begun, handed the overlays one
    /// page at a time, then finished or abandoned.
    ///
    /// The loops above in pieces: `write(…overlay:)` drives it with a `for`,
    /// `writeConcurrently` with pages made side by side and handed over in
    /// order. The checks, the bytes and the order of the objects are the
    /// same either way: the objects are numbered and placed here, as each
    /// page is appended, and nowhere else.
    ///
    /// Written to the file as it is made: objects are gathered into a buffer
    /// of about a megabyte and the buffer goes to the file, so what is held is
    /// that and the offsets, whatever the length of the book. Not `Sendable`:
    /// one task writes one update.
    final class Revision {
        private let writer: PDFOverlayWriter
        private let file: PDFFile
        private let pages: [PDFFile.Page]
        private let pageIndices: [Int]
        private let output: URL
        private let temporary: URL
        private let handle: FileHandle
        /// How many of `pageIndices` have been written.
        private var written = 0
        /// Bytes already in the file, and those made but not yet written to
        /// it: an object's offset is their sum at the moment it begins.
        private var flushed: Int
        private var pending = Data()
        private var newOffsets: [Int: Int] = [:]
        private var newGenerations: [Int: Int] = [:]
        private var nextNumber: Int
        private var openState = 0
        private var closeState = 0
        private var stateObjects: [StateAppearance: Int] = [:]
        /// The native drawings' objects already in the update, by what
        /// they say (`PreparedPage.Native.fingerprints`): the number each
        /// was written under, and not its bytes, so that what is held grows
        /// by a few dozen bytes an object whatever the size of the object.
        private var sharedObjects: [SHA256.Digest: Int] = [:]

        /// What can be refused from what is known up front is refused here,
        /// before anything is written — see `write(file:…overlay:)`.
        init(
            writer: PDFOverlayWriter,
            file: PDFFile,
            pages: [PDFFile.Page],
            original: URL,
            pageIndices: [Int],
            output: URL
        ) throws {
            let root = try file.resolve(file.trailer["Root"]).dictionaryValue
            guard root?["Perms"] == nil else {
                throw RenderError.unsupportedFormat("a certified PDF (/Perms) takes no incremental update")
            }
            for pageIndex in pageIndices {
                guard pageIndex >= 0, pageIndex < pages.count else {
                    throw OverlayError.noSuchPage(pageIndex)
                }
            }
            // `/Size` is the file's own word, and a word past any object number
            // the format can write is refused rather than counted on from: every
            // object this update adds is one more than the last, and one more
            // than `Int.max` is a trap. The offsets are bounded where they are
            // read (`PDFFile.objectNumberLimit`).
            let size = file.trailer["Size"]?.intValue ?? 1
            guard size <= PDFFile.objectNumberLimit else {
                throw PDFReadError.malformed("a trailer /Size of \(size)")
            }

            let temporary = output.deletingLastPathComponent()
                .appendingPathComponent(".rmrender-\(UUID().uuidString).pdf")
            let handle: FileHandle
            do {
                // File to file, never through memory: `copyItem` is
                // `copyfile(3)`, a clone on APFS and a copy in chunks
                // elsewhere. Read into `Data` and written back, the original
                // would be in the process twice over — once mapped, once
                // dirty — on exactly the book this is all for.
                try FileManager.default.copyItem(at: original, to: temporary)
                handle = try FileHandle(forWritingTo: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            do {
                // Every offset written below counts from the end of the file
                // that was read. A copy of another length — the original
                // replaced between the read and now — would put each of them
                // in the wrong place.
                guard try handle.seekToEnd() == UInt64(file.bytes.count) else {
                    throw PDFReadError.malformed("the original changed after it was read")
                }
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            self.writer = writer
            self.file = file
            self.pages = pages
            self.pageIndices = pageIndices
            self.output = output
            self.temporary = temporary
            self.handle = handle
            flushed = file.bytes.count
            // Past every number any section names, free ones included: a number
            // freed in one revision may still be what an older object refers to,
            // and a new object under it would answer that reference.
            nextNumber = max(file.highestObjectNumber + 1, file.trailer["Size"]?.intValue ?? 1)

            if file.bytes.last != 0x0A {
                pending.append(0x0A)
            }
            // The wrapper. A page's own content may leave the graphics state
            // changed — a stray `cm`, an unbalanced `q` — and our marks would
            // inherit it. A `q` before and a `Q` after cost two tiny objects and
            // make the page's own drawing none of our business.
            openState = emit(writer.stream("q\n"))
            closeState = emit(writer.stream("Q\n"))
        }

        private func position() -> Int { flushed + pending.count }

        private func flush() throws {
            guard !pending.isEmpty else { return }
            try handle.write(contentsOf: pending)
            flushed += pending.count
            pending.removeAll(keepingCapacity: true)
        }

        private func emit(_ object: PDFObject, number: Int? = nil) -> Int {
            let assigned = number ?? nextNumber
            if number == nil { nextNumber += 1 }
            newOffsets[assigned] = position()
            let generation = number.flatMap { file.generations[$0] } ?? 0
            newGenerations[assigned] = generation
            pending.append(contentsOf: Array("\(assigned) \(generation) obj\n".utf8))
            PDFWriter.append(object, to: &pending)
            pending.append(contentsOf: Array("\nendobj\n".utf8))
            return assigned
        }

        /// One object per distinct state, however many pages ask for it — and
        /// the name a page calls it by is that page's own. The content stream
        /// numbers its states afresh on every page, so `/RMGs0` is the marker's
        /// multiply on one page and a stroke's quarter opacity on the next; one
        /// table of names for the whole document handed the second page the
        /// first page's state, and a translucent stroke came out multiplied at
        /// full opacity with nothing to say so. So the object is shared by what
        /// it says, and the names are resolved page by page, the way the
        /// stencils already are.
        private func stateObject(for state: GraphicsState) -> Int {
            let appearance = StateAppearance(blendMode: state.blendMode, alpha: state.alpha)
            if let number = stateObjects[appearance] { return number }
            var dictionary: [String: PDFObject] = ["Type": .name("ExtGState")]
            if let mode = state.blendMode { dictionary["BM"] = .name(mode) }
            dictionary["ca"] = .real(state.alpha)
            dictionary["CA"] = .real(state.alpha)
            let number = emit(.dictionary(dictionary))
            stateObjects[appearance] = number
            return number
        }

        /// A native drawing's objects and its Form written out, and the
        /// number of the Form.
        ///
        /// An object some page before this one already wrote — the same
        /// bytes, referring to the same things — is not written again: the
        /// page refers to the one in the file. CoreGraphics draws every page
        /// into a PDF of its own and puts into each everything that page
        /// uses, so a picture on fifty pages came out fifty times over, and
        /// so did the colour profiles, and a typeface wherever two pages set
        /// the same letters in it. What is shared is only what the drawing
        /// refers to — pictures, typefaces, profiles — never the page or the
        /// Form that draws it; such a resource is read for what it says, not
        /// for which object it is, so two that say the same thing can be one
        /// (the exception, a layer, is never shared — see `fingerprint`).
        ///
        /// The rest are numbered from here, as they would have been
        /// numbered had the PDF been read now: the numbers after the last
        /// one made, in the order the reading reached the objects, and the
        /// Form the one after those. Which objects are shared depends only
        /// on the pages before, appended in the order of `pageIndices`, so
        /// the numbers are the same however the pages were made.
        private func emit(native: PreparedPage.Native) -> Int {
            var numbers = [Int](repeating: 0, count: native.objects.count)
            var fresh = [Bool](repeating: false, count: native.objects.count)
            for (local, fingerprint) in native.fingerprints.enumerated() {
                if let fingerprint, let number = sharedObjects[fingerprint] {
                    numbers[local] = number
                    continue
                }
                numbers[local] = nextNumber
                nextNumber += 1
                fresh[local] = true
                if let fingerprint { sharedObjects[fingerprint] = numbers[local] }
            }
            for object in native.objects where fresh[object.number] {
                _ = emit(PDFOverlayWriter.renumbered(object.object, to: numbers), number: numbers[object.number])
            }
            return emit(PDFOverlayWriter.renumbered(native.form, to: numbers))
        }

        /// The overlay of the next page of `pageIndices`, written out.
        func append(_ overlay: Overlay) throws {
            try append(try writer.prepare(overlay))
        }

        /// The same, for a page made ready apart from the update — see
        /// `PreparedPage`.
        func append(_ prepared: PreparedPage) throws {
            guard written < pageIndices.count else {
                throw PDFReadError.malformed("an overlay for page \(prepared.pageIndex) past the pages asked for")
            }
            let pageIndex = pageIndices[written]
            guard prepared.pageIndex == pageIndex else {
                throw PDFReadError.malformed("an overlay for page \(prepared.pageIndex) where \(pageIndex) was asked for")
            }
            written += 1
            let page = pages[pageIndex]

            // The states by the names this page's content says them. Two
            // pages may both say `/RMGs0` and mean different things by it;
            // each gets the object for what it meant.
            var states: [String: PDFObject] = [:]
            for state in prepared.states {
                states[state.name] = .reference(number: stateObject(for: state), generation: 0)
            }

            // The stencils are the page's own: a stroke's grain is drawn
            // once, on the page it is on. Named per page as the content
            // names them; two pages may both say `/RMIm0` and mean their
            // own.
            var stencils: [String: PDFObject] = [:]
            for stencil in prepared.stencils {
                stencils[stencil.name] = .reference(number: emit(stencil.object), generation: 0)
            }

            var dictionary = page.dictionary
            if let box = prepared.box {
                // Written onto the page itself even where the original left
                // the box to the page tree to say: a value inherited from the
                // parent would go on applying to every other page too.
                dictionary["MediaBox"] = writer.rectangle(box)
                // The crop box is what a reader actually shows, and a page
                // that declares none takes the media box. Leaving an old one
                // behind would crop the marks back off. An intentional crop smaller
                // than the sheet remains the user's chosen visible area.
                if let crop = page.cropBox, crop != page.mediaBox {
                    dictionary["CropBox"] = writer.rectangle(crop)
                } else {
                    dictionary["CropBox"] = writer.rectangle(box)
                }
                // The sheet's original extent, kept the way the tablet's own
                // export keeps it: once the media box has grown, nothing else
                // in the file says which part of it is the imported page.
                if let sheet = page.mediaBox { dictionary["ArtBox"] = writer.rectangle(sheet) }
            }
            // Scope overlay names inside a Form: the source may already use
            // any of the names emitted by MarkContentStream or a public caller.
            var resources = try file.resolve(page.resources).dictionaryValue ?? [:]
            var scoped = resources
            var scopedStates = try file.resolve(resources["ExtGState"]).dictionaryValue ?? [:]
            var scopedObjects = try file.resolve(resources["XObject"]).dictionaryValue ?? [:]
            scopedStates.merge(states) { _, added in added }
            scopedObjects.merge(stencils) { _, added in added }
            if let native = prepared.native {
                let form = emit(native: native)
                scopedObjects["RMNative"] = .reference(number: form, generation: 0)
            }
            if let ink = prepared.ink {
                let form = emit(native: ink)
                scopedObjects[InkForm.name] = .reference(number: form, generation: 0)
            }

            scoped["ExtGState"] = .dictionary(scopedStates)
            scoped["XObject"] = .dictionary(scopedObjects)
            let form = emit(writer.stream([
                "Type": .name("XObject"), "Subtype": .name("Form"),
                "BBox": writer.rectangle(prepared.box ?? page.mediaBox ?? .zero),
                "Resources": .dictionary(scoped),
                "Filter": .name("FlateDecode"),
            ], prepared.content))
            var objects = try file.resolve(resources["XObject"]).dictionaryValue ?? [:]
            var name = "RMOverlay"
            while objects[name] != nil { name += "_" }
            objects[name] = .reference(number: form, generation: 0)
            resources["XObject"] = .dictionary(objects)
            let marks = emit(writer.stream("q /\(name) Do Q\n"))
            dictionary["Contents"] = .array(
                [.reference(number: openState, generation: 0)]
                    + (try writer.contentsList(of: page.dictionary["Contents"], in: file))
                    + [
                        .reference(number: closeState, generation: 0),
                        .reference(number: marks, generation: 0),
                    ]
            )
            dictionary["Resources"] = .dictionary(resources)
            // The same object number: an incremental update replaces a page by
            // writing it again, and the newest cross-reference wins.
            _ = emit(.dictionary(dictionary), number: page.number)
            if pending.count >= 1 << 20 { try flush() }
        }

        /// The cross-reference and the trailer, and the copy put where it
        /// belongs. Every page asked for has to have been appended.
        func finish() throws {
            guard written == pageIndices.count else {
                throw PDFReadError.malformed("fewer overlays than pages")
            }
            let crossReference = position()
            if file.usesCrossReferenceStreams {
                let number = nextNumber
                nextNumber += 1
                newOffsets[number] = crossReference
                newGenerations[number] = 0
                let sorted = newOffsets.keys.sorted()
                var index: [PDFObject] = []
                var rows = Data()
                for id in sorted {
                    index += [.integer(id), .integer(1)]
                    rows.append(1)
                    let offset = UInt64(newOffsets[id] ?? 0)
                    for shift in stride(from: 56, through: 0, by: -8) { rows.append(UInt8(truncatingIfNeeded: offset >> shift)) }
                    let generation = newGenerations[id] ?? 0
                    rows.append(UInt8(truncatingIfNeeded: generation >> 8))
                    rows.append(UInt8(truncatingIfNeeded: generation))
                }
                var dictionary: [String: PDFObject] = [
                    "Type": .name("XRef"), "Size": .integer(nextNumber), "Prev": .integer(file.lastCrossReference),
                    "W": .array([.integer(1), .integer(8), .integer(2)]), "Index": .array(index),
                ]
                for key in ["Root", "Info", "ID"] { dictionary[key] = file.trailer[key] }
                if file.trailer["XRefStm"] != nil { dictionary.removeValue(forKey: "Prev") }
                _ = emit(writer.stream(dictionary, rows), number: number)
                if file.trailer["XRefStm"] != nil {
                    let tableOffset = position()
                    pending.append(writer.crossReferenceTable(newOffsets, generations: newGenerations))
                    pending.append(writer.trailer(of: file, size: nextNumber, crossReference: tableOffset, hybrid: crossReference))
                } else {
                    pending.append(Data("startxref\n\(crossReference)\n%%EOF\n".utf8))
                }
            } else {
                pending.append(writer.crossReferenceTable(newOffsets, generations: newGenerations))
                pending.append(writer.trailer(of: file, size: nextNumber, crossReference: crossReference))
            }
            try flush()
            try handle.close()
            // POSIX rename replaces an existing destination atomically on its volume.
            guard rename(temporary.path, output.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
        }

        /// The half-written copy removed, `output` left as it was.
        func abandon() {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// One page's overlay with everything worked out that does not depend
    /// on where in the update it lands: its streams deflated and a native
    /// drawing's objects read out of the PDF they came in.
    ///
    /// Deflating is most of what writing an overlay costs — a sample of a
    /// fully marked book spent the writing task in `longest_match` — and it
    /// needs nothing of the update. So it is done here, on as many pages at
    /// once as the caller likes, and `Revision.append` is left only what
    /// has to be done in order: numbering the objects and placing them.
    /// The bytes are the ones appending the overlay itself gives.
    ///
    /// Holds the deflated streams, not the overlay's own bytes: what waits
    /// its turn is the size it will be in the file.
    struct PreparedPage: Sendable {
        /// A native drawing's objects, numbered from nought in the order
        /// the reading reached them and referring to one another by those
        /// numbers; `form` is the Form that draws them.
        struct Native: Sendable {
            let objects: [(number: Int, object: PDFObject)]
            let form: PDFObject
            /// What each object says, by its number: see `fingerprint`.
            /// Worked out here, beside the reading, so that the update is
            /// left only looking them up.
            let fingerprints: [SHA256.Digest?]
        }

        let pageIndex: Int
        let states: [GraphicsState]
        /// The stencil image objects, by the names the content says them.
        let stencils: [(name: String, object: PDFObject)]
        let box: CGRect?
        let native: Native?
        /// The page's written ink as a Form and the objects it names, made
        /// as a native drawing's are and shared the same way (`inkForm`).
        let ink: Native?
        /// The overlay's operators, deflated.
        let content: Data
    }

    /// `overlay` made ready to append — see `PreparedPage`. Touches nothing
    /// but the overlay, so pages may be prepared side by side.
    func prepare(_ overlay: Overlay) throws -> PreparedPage {
        try prepare(overlay, native: try overlay.formPDF.map(native))
    }

    /// The overlays of a run made ready to append, the PDF of their native
    /// drawings read once for all of them and removed. Each page's native
    /// drawing comes out as it would from a PDF of that page alone, numbered
    /// for that page (`native(page:of:)`); what pages of one PDF share are
    /// the same objects in each, and alike in their fingerprints, so the
    /// update writes them once.
    func prepare(_ batch: OverlayBatch) throws -> [PreparedPage] {
        defer { batch.discard() }
        let drawing = try batch.drawing.map { try PDFFile(url: $0) }
        let drawn = try drawing?.pages() ?? []
        return try zip(batch.overlays, batch.drawingPages).map { overlay, page in
            guard let page else { return try prepare(overlay) }
            guard let drawing, drawn.indices.contains(page) else {
                throw PDFReadError.malformed("overlay PDF has no page \(page)")
            }
            return try prepare(overlay, native: try native(page: drawn[page], of: drawing))
        }
    }

    private func prepare(_ overlay: Overlay, native: PreparedPage.Native?) throws -> PreparedPage {
        let stencils = overlay.images.map { image in
            (
                name: image.name,
                object: stream(
                    [
                        "Type": .name("XObject"),
                        "Subtype": .name("Image"),
                        "ImageMask": .boolean(true),
                        "Width": .integer(image.width),
                        "Height": .integer(image.height),
                        "BitsPerComponent": .integer(1),
                        "Filter": .name("FlateDecode"),
                    ],
                    PDFWriter.flate(image.bits)
                )
            )
        }
        // Deflated, like the stencils: the operators are text — numbers and
        // a letter, point after point — and written as they stand they made
        // a fully marked book of 2,000 pages a file of 1.7 GB, three times
        // what drawing it afresh comes to.
        return PreparedPage(
            pageIndex: overlay.pageIndex,
            states: overlay.states,
            stencils: stencils,
            box: overlay.box,
            native: native,
            ink: try overlay.ink.map(inkForm),
            content: PDFWriter.flate(overlay.content)
        )
    }

    /// A page's written ink as a Form and the objects it names, numbered
    /// from nought as a native drawing's are: the profile and the colour
    /// space where the ink is coloured, then its graphics states, then its
    /// masks — each after what it refers to — and the Form that names them.
    ///
    /// Every object is the one `InkUpdate` writes for the same ink, and the
    /// content is the ink's own stream, deflated as it was written: nothing
    /// is inflated or deflated again.
    private func inkForm(_ form: InkForm) throws -> PreparedPage.Native {
        func reference(_ number: Int) -> PDFObject { .reference(number: number, generation: 0) }
        var objects: [(number: Int, object: PDFObject)] = []
        func add(_ object: PDFObject) -> Int {
            objects.append((number: objects.count, object: object))
            return objects.count - 1
        }
        var resources: [String: PDFObject] = [:]
        if form.ink.usesColorSpace {
            guard let profile = InkForm.deflatedProfile else { throw RenderError.pdfContextUnavailable }
            let icc = add(stream(
                ["N": .integer(3), "Alternate": .name("DeviceRGB"), "Filter": .name("FlateDecode")], profile
            ))
            let space = add(.array([.name("ICCBased"), reference(icc)]))
            resources["ColorSpace"] = .dictionary([InkStream.colorSpaceName: reference(space)])
        }
        var states: [String: PDFObject] = [:]
        for (index, entries) in form.ink.states.enumerated() {
            var dictionary: [String: PDFObject] = ["Type": .name("ExtGState")]
            // `/ca 0.5`, `/BM /Darken`: a key and its value, as `InkStream`
            // says them.
            let tokens = entries.split(separator: " ")
            for pair in stride(from: 0, to: tokens.count - 1, by: 2) where tokens[pair].hasPrefix("/") {
                let value = tokens[pair + 1]
                guard value.hasPrefix("/") || Double(value) != nil else {
                    throw PDFReadError.malformed("an ink state of \(entries)")
                }
                dictionary[String(tokens[pair].dropFirst())] = value.hasPrefix("/")
                    ? .name(String(value.dropFirst())) : .real(Double(value) ?? 0)
            }
            states["\(InkStream.statePrefix)\(index)"] = reference(add(.dictionary(dictionary)))
        }
        if !states.isEmpty { resources["ExtGState"] = .dictionary(states) }
        var masks: [String: PDFObject] = [:]
        for (index, (mask, size)) in zip(form.ink.masks, form.sizes).enumerated() {
            let image = stream(
                [
                    "Type": .name("XObject"), "Subtype": .name("Image"),
                    "Width": .integer(size.width), "Height": .integer(size.height),
                    "ImageMask": .boolean(true), "BitsPerComponent": .integer(1), "Filter": .name("FlateDecode"),
                ],
                mask.deflated.reduce(into: Data()) { $0.append($1) }
            )
            masks["\(InkStream.maskPrefix)\(index)"] = reference(add(image))
        }
        // The transparency groups after all they name, each a Form of its
        // own blending in the space CoreGraphics' layers blend in.
        var objectNames = masks
        if !form.ink.groups.isEmpty {
            guard let profile = InkForm.deflatedGroupProfile else { throw RenderError.pdfContextUnavailable }
            let icc = add(stream(
                ["N": .integer(3), "Alternate": .name("DeviceRGB"), "Filter": .name("FlateDecode")], profile
            ))
            let space = reference(add(.array([.name("ICCBased"), reference(icc)])))
            let named = (resources["ColorSpace"]?.dictionaryValue ?? [:]).merging(states) { first, _ in first }
                .merging(masks) { first, _ in first }
            for (index, group) in form.ink.groups.enumerated() {
                let operators = group.content.reduce(into: Data()) { $0.append($1) }
                let dictionary = PreparedInk.groupDictionary(group, length: operators.count, space: space) {
                    named[$0] ?? .null
                }
                objectNames["\(InkStream.groupPrefix)\(index)"] = reference(add(stream(dictionary, operators)))
            }
        }
        if !objectNames.isEmpty { resources["XObject"] = .dictionary(objectNames) }
        let content = stream(
            [
                "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": rectangle(form.box),
                "Resources": .dictionary(resources), "Filter": .name("FlateDecode"),
            ],
            form.ink.content.reduce(into: Data()) { $0.append($1) }
        )
        var fingerprints = [SHA256.Digest?](repeating: nil, count: objects.count)
        for object in objects {
            fingerprints[object.number] = Self.fingerprint(object.object, known: fingerprints)
        }
        return PreparedPage.Native(objects: objects, form: content, fingerprints: fingerprints)
    }

    /// A one-page PDF as a Form and the objects it needs, numbered from
    /// nought: each object takes the next number when a reference to it is
    /// first reached, and is listed once all it refers to has been.
    ///
    /// A dictionary's entries are walked in the order of their keys — the
    /// order `PDFWriter` writes them in — and not in the dictionary's own:
    /// that is its hash seed's, a new one every run, and the numbers came
    /// out differently each time the same document was written. A copy
    /// already downloaded is invalidated by a file that changes for no
    /// reason.
    func native(_ pdf: Data) throws -> PreparedPage.Native {
        let source = try PDFFile(bytes: pdf)
        let imported = try source.pages()
        guard imported.count == 1, let first = imported.first else {
            throw PDFReadError.malformed("overlay PDF must have one page")
        }
        return try native(page: first, of: source)
    }

    /// The same for the page `first` of `source`, which may have others:
    /// only what this page refers to is read, and numbered as above.
    private func native(page first: PDFFile.Page, of source: PDFFile) throws -> PreparedPage.Native {
        var mapped: [Int: Int] = [:]
        var objects: [(number: Int, object: PDFObject)] = []
        func copy(_ value: PDFObject, depth: Int = 0) throws -> PDFObject {
            guard depth < 128 else { throw PDFReadError.malformed("overlay resource depth") }
            switch value {
            case .reference(let number, let generation):
                guard source.generations[number] == generation else {
                    throw PDFReadError.malformed("overlay resource generation")
                }
                if let assigned = mapped[number] { return .reference(number: assigned, generation: 0) }
                let assigned = mapped.count
                mapped[number] = assigned
                let cloned = try copy(source.object(number), depth: depth + 1)
                objects.append((number: assigned, object: cloned))
                return .reference(number: assigned, generation: 0)
            case .array(let values): return .array(try values.map { try copy($0, depth: depth + 1) })
            case .dictionary(let values): return .dictionary(try copy(entries: values, depth: depth))
            case .stream(var dictionary, let data):
                dictionary["Length"] = .integer(data.count)
                return .stream(dictionary: try copy(entries: dictionary, depth: depth), data: data)
            default: return value
            }
        }
        func copy(entries: [String: PDFObject], depth: Int) throws -> [String: PDFObject] {
            var copied: [String: PDFObject] = [:]
            for key in entries.keys.sorted() {
                copied[key] = try copy(entries[key] ?? .null, depth: depth + 1)
            }
            return copied
        }
        // Decoded and deflated again, not taken as it stands: CoreGraphics
        // deflates a page loosely, and a book of typed text came out 2.8%
        // larger for its streams copied whole. What CoreGraphics draws of a
        // page is its text and its pictures' placing, a few kilobytes; the
        // ink, which is the bulk of a page of handwriting, is a Form of its
        // own and is not touched here (`InkForm`).
        var content = Data()
        func appendContent(_ value: PDFObject?, depth: Int = 0) throws {
            guard depth < 128 else { throw PDFReadError.malformed("overlay content depth") }
            let resolved = try source.resolve(value)
            if case .array(let values) = resolved {
                for value in values { try appendContent(value, depth: depth + 1) }
            } else if case .stream(let dictionary, let bytes) = resolved {
                content.append(try source.decode(dictionary, bytes))
                content.append(10)
            } else if case .null = resolved { } else {
                throw PDFReadError.malformed("overlay content is not a stream")
            }
        }
        try appendContent(first.dictionary["Contents"])
        let form = stream([
            "Type": .name("XObject"), "Subtype": .name("Form"),
            "BBox": rectangle(first.mediaBox ?? .zero),
            "Resources": try copy(source.resolve(first.resources)),
            "Filter": .name("FlateDecode"),
        ], PDFWriter.flate(content))
        // In the order they are listed: an object comes after everything it
        // refers to, so what it refers to has its fingerprint already.
        var fingerprints = [SHA256.Digest?](repeating: nil, count: objects.count)
        for object in objects {
            fingerprints[object.number] = Self.fingerprint(object.object, known: fingerprints)
        }
        return PreparedPage.Native(objects: objects, form: form, fingerprints: fingerprints)
    }

    /// What a native drawing's object says, down to what it refers to: the
    /// SHA-256 of its bytes as `PDFWriter` writes them, with every reference
    /// written as the fingerprint of the object it names rather than as its
    /// number. Two objects of two drawings with one fingerprint say the same
    /// thing, and so do all the objects they refer to.
    ///
    /// `nil` for an object that refers to one with no fingerprint: one not
    /// listed before it, which only a cycle makes. `nil` too for a layer
    /// (`/OCG`, `/OCMD`): a layer is the object itself — two alike are two
    /// layers a reader shows and hides apart — and CoreGraphics draws none,
    /// but a caller's drawing may carry them. Such an object is written on
    /// every page that has it, as it always was, and so is all that refers
    /// to it.
    static func fingerprint(_ object: PDFObject, known: [SHA256.Digest?]) -> SHA256.Digest? {
        var unshareable = false
        func resolved(_ value: PDFObject) -> PDFObject {
            switch value {
            case .dictionary(let entries) where ["OCG", "OCMD"].contains(entries["Type"]?.nameValue):
                unshareable = true
                return .null
            case .reference(let number, _):
                guard known.indices.contains(number), let digest = known[number] else {
                    unshareable = true
                    return .null
                }
                // An `R` and the digest's 32 bytes: no string, name, number
                // or keyword the writer makes begins with an `R`, and the
                // digest is always as long, so this reads as nothing else.
                return .string(Data("R".utf8) + Data(digest))
            case .array(let items):
                return .array(items.map(resolved))
            case .dictionary(let entries):
                return .dictionary(entries.mapValues(resolved))
            case .stream:
                // Only ever an object of its own, never inside another; one
                // that is would carry its numbers into the bytes unturned.
                unshareable = true
                return .null
            default:
                return value
            }
        }
        var hasher = SHA256()
        if case .stream(let dictionary, let data) = object {
            let text = PDFWriter.bytes(of: resolved(.dictionary(dictionary)))
            guard !unshareable else { return nil }
            // The bytes hashed as they are, not copied in after the text: a
            // picture's stream is megabytes.
            hasher.update(data: Data("S".utf8) + text)
            hasher.update(data: data)
        } else {
            let text = PDFWriter.bytes(of: resolved(object))
            guard !unshareable else { return nil }
            hasher.update(data: Data("O".utf8) + text)
        }
        return hasher.finalize()
    }

    /// `object` with every reference in it turned from a prepared native
    /// drawing's number into the update's: `numbers[n]` for `n`. Every
    /// reference in such an object is one `native` made, so all of them move.
    static func renumbered(_ object: PDFObject, to numbers: [Int]) -> PDFObject {
        switch object {
        case .reference(let number, let generation):
            return .reference(number: numbers[number], generation: generation)
        case .array(let items):
            return .array(items.map { renumbered($0, to: numbers) })
        case .dictionary(let entries):
            return .dictionary(entries.mapValues { renumbered($0, to: numbers) })
        case .stream(let dictionary, let data):
            return .stream(dictionary: dictionary.mapValues { renumbered($0, to: numbers) }, data: data)
        default:
            return object
        }
    }

    /// A box the way PDF writes one: lower left corner, then upper right.
    private func rectangle(_ box: CGRect) -> PDFObject {
        .array([.real(box.minX), .real(box.minY), .real(box.maxX), .real(box.maxY)])
    }

    /// A stream object with its length filled in.
    private func stream(_ text: String) -> PDFObject {
        stream(Data(text.utf8))
    }

    private func stream(_ data: Data) -> PDFObject {
        .stream(dictionary: ["Length": .integer(data.count)], data: data)
    }

    /// The same for a stream whose dictionary says more than its length.
    private func stream(_ dictionary: [String: PDFObject], _ data: Data) -> PDFObject {
        var entries = dictionary
        entries["Length"] = .integer(data.count)
        return .stream(dictionary: entries, data: data)
    }

    /// `/Contents` is one stream, an array of them, or a reference to either.
    ///
    /// The reference to an array is the case worth the resolving: wrapped
    /// as-is it would make an array holding an array, which is not a thing
    /// `/Contents` may be, and the page's own drawing would go missing while
    /// our marks stayed. The streams themselves are left as references —
    /// nothing is copied here.
    private func contentsList(of object: PDFObject?, in file: PDFFile) throws -> [PDFObject] {
        guard let object else { return [] }
        if case .null = try file.resolve(object) { return [] }
        if case .array(let items) = object { return items }
        if case .reference = object,
           case .array(let items) = try file.resolve(object) {
            return items
        }
        return [object]
    }

    /// The new cross-reference section: the objects this update changed,
    /// grouped into runs of consecutive numbers.
    func crossReferenceTable(_ offsets: [Int: Int], generations: [Int: Int]) -> Data {
        var out = Array("xref\n".utf8)
        // Walked by index: taking each number off the front of the array
        // moved all the rest every time, and a book's update is thousands.
        let numbers = offsets.keys.sorted()
        out.reserveCapacity(out.count + numbers.count * 20)
        var start = 0
        while start < numbers.count {
            var end = start + 1
            while end < numbers.count, numbers[end] == numbers[end - 1] + 1 {
                end += 1
            }
            let run = numbers[start..<end]
            start = end
            out.append(contentsOf: "\(run[run.startIndex]) \(run.count)\n".utf8)
            for number in run {
                // Twenty bytes a row, exactly: offset, generation, kind.
                // Padded here rather than by `String(format:)`, which read
                // its format afresh for every object of the update.
                Self.appendPadded(offsets[number] ?? 0, width: 10, to: &out)
                out.append(UInt8(ascii: " "))
                Self.appendPadded(generations[number] ?? 0, width: 5, to: &out)
                out.append(contentsOf: " n \n".utf8)
            }
        }
        return Data(out)
    }

    /// `value` in decimal, at least `width` characters, zeros after any
    /// sign: what `%0*ld` writes.
    static func appendPadded(_ value: Int, width: Int, to out: inout [UInt8]) {
        let digits = String(value.magnitude).utf8
        if value < 0 { out.append(UInt8(ascii: "-")) }
        let zeros = width - digits.count - (value < 0 ? 1 : 0)
        if zeros > 0 { out.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: zeros)) }
        out.append(contentsOf: digits)
    }

    private func trailer(of file: PDFFile, size: Int, crossReference: Int, hybrid: Int? = nil) -> Data {
        var entries: [String: PDFObject] = [
            "Size": .integer(size),
            "Prev": .integer(file.lastCrossReference),
        ]
        if let hybrid { entries["XRefStm"] = .integer(hybrid) }
        // What identifies the document is carried over as it stands: /Root
        // says which catalogue to read, /Info and /ID are what the file says
        // about itself, and rewriting either would be a change we did not mean
        // to make.
        for key in ["Root", "Info", "ID"] {
            if let value = file.trailer[key] { entries[key] = value }
        }
        var out = Data("trailer\n".utf8)
        PDFWriter.append(.dictionary(entries), to: &out)
        out.append(contentsOf: Array("\nstartxref\n\(crossReference)\n%%EOF\n".utf8))
        return out
    }
}
