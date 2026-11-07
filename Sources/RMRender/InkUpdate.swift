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
    /// The transparency groups the content paints (`InkStream.Group`).
    let groups: [InkStream.Group]
    let usesColorSpace: Bool

    /// What `stream` wrote, or `nil` for a page with none.
    init?(_ stream: InkStream) {
        guard let ink = stream.finish() else { return nil }
        content = ink.content
        states = ink.states
        masks = ink.masks
        groups = ink.groups
        usesColorSpace = ink.usesColorSpace
    }

    /// The colour space a transparency group blends in, as CoreGraphics
    /// writes a layer's: the Generic RGB profile — not sRGB, which the
    /// colours are in. Named by its string: Swift does not offer the
    /// constant, deprecated in favour of sRGB for drawing, though it is what
    /// CoreGraphics' layers still blend in. Held against a layer CoreGraphics
    /// wrote in the tests. Resolved once, the first time it is asked for;
    /// where it is not to be had, no group is written
    /// (`InkStream.groupsAvailable`).
    static let groupProfile: Data? = CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString)?.copyICCData() as Data?

    /// A group's Form dictionary, ahead of its deflated operators: its box,
    /// the group — isolated, non-knockout, in the colour space `space` — and
    /// the resources it names, `resource` giving the object of each by the
    /// name the operators say it by.
    static func groupDictionary(
        _ group: InkStream.Group, length: Int, space: PDFObject, resource: (String) -> PDFObject
    ) -> [String: PDFObject] {
        var resources: [String: PDFObject] = [:]
        if group.usesColorSpace {
            resources["ColorSpace"] = .dictionary([InkStream.colorSpaceName: resource(InkStream.colorSpaceName)])
        }
        func names(_ prefix: String, _ indices: [Int]) -> PDFObject {
            .dictionary(Dictionary(uniqueKeysWithValues: indices.map { ("\(prefix)\($0)", resource("\(prefix)\($0)")) }))
        }
        if !group.states.isEmpty { resources["ExtGState"] = names(InkStream.statePrefix, group.states) }
        if !group.masks.isEmpty { resources["XObject"] = names(InkStream.maskPrefix, group.masks) }
        return [
            "Type": .name("XObject"), "Subtype": .name("Form"), "FormType": .integer(1),
            // The text CoreGraphics prints, as it stands: `.string` is
            // written as it is given.
            "BBox": .array(group.box.map { .string(Data($0.utf8)) }),
            "Group": .dictionary([
                "S": .name("Transparency"), "CS": space, "I": .boolean(true), "K": .boolean(false),
            ]),
            "Resources": .dictionary(resources),
            "Length": .integer(length), "Filter": .name("FlateDecode"),
        ]
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
/// A page may also start with a template drawn once for the document and
/// shared by every page that draws it alike (`share`): a Form ahead of
/// CoreGraphics' drawing of the page, which then leaves the template out.
///
/// Everything is decided by the order the pages are appended in, so the
/// bytes are the same however the ink was made.
///
/// Not `Sendable`: one drawing appends to one update.
final class InkUpdate {
    /// The masks the document has drawn, CoreGraphics' and the writer's
    /// alike; CoreGraphics' half is handed it where it draws.
    let masks = InkMaskLedger()

    /// The name a page's resources give its shared template, apart from
    /// CoreGraphics' names and the ink's (`InkStream`).
    static let templateName = "RMIt"

    private struct PageRecord {
        let index: Int
        /// The ink's content stream, where the page has ink.
        let content: Int?
        let states: [Int]
        let masks: [Int]
        /// The ink's transparency groups, by the index of their Forms
        /// among the spooled objects.
        let groups: [Int]
        let usesColorSpace: Bool
        /// The shared template the page starts with, by its index in
        /// `templates`.
        let template: Int?
    }

    /// A group's Form as it is spooled: its operators, and what its
    /// dictionary is made of once the objects are numbered — the group
    /// without its operators, its length, and the spooled object of each
    /// resource it names, by the name.
    private struct GroupForm {
        let group: InkStream.Group
        let length: Int
        let objects: [String: Int]
    }

    private let spool = Spool()
    private var pages: [PageRecord] = []
    private var stateObjects: [String: Int] = [:]
    private var maskObjects: [SHA256.Digest: Int] = [:]
    private var usesColorSpace = false
    /// The groups' Forms, by their index among the spooled objects: their
    /// dictionaries name objects numbered only once the update is.
    private var groupForms: [Int: GroupForm] = [:]
    /// The shared templates, in the order they were first drawn: the Form
    /// of each and the objects it names, numbered from nought.
    private var templates: [PDFOverlayWriter.PreparedPage.Native] = []

    /// A template drawn once — CoreGraphics' drawing of it alone on a page,
    /// as `PDFOverlayWriter.native` reads one — to be shared by the pages
    /// appended with its index.
    func share(_ template: PDFOverlayWriter.PreparedPage.Native) -> Int {
        templates.append(template)
        return templates.count - 1
    }

    /// The ink of the page at `index` — counted from nought, in the order
    /// CoreGraphics drew the pages — after everything CoreGraphics drew
    /// on it. Pages are appended in their order.
    func append(_ ink: PreparedInk, page index: Int) throws {
        try append(ink, template: nil, page: index)
    }

    /// The same for a page that may have no ink, and may start with the
    /// shared template `template` (`share`), drawn before everything
    /// CoreGraphics drew on it. A page with neither is left as it is.
    func append(_ ink: PreparedInk?, template: Int?, page index: Int) throws {
        if let last = pages.last, last.index >= index {
            throw PDFReadError.malformed("ink for page \(index) after page \(last.index)")
        }
        if let template, !templates.indices.contains(template) {
            throw PDFReadError.malformed("page \(index) shares no template \(template)")
        }
        guard let ink else {
            if let template {
                pages.append(
                    PageRecord(
                        index: index, content: nil, states: [], masks: [], groups: [], usesColorSpace: false,
                        template: template
                    )
                )
            }
            return
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
        // A group's operators alone: its dictionary is written around them
        // when the update is (`finish`).
        let groups = try ink.groups.map { group in
            let number = try spool.add(group.content)
            var objects: [String: Int] = [:]
            for index in group.states { objects["\(InkStream.statePrefix)\(index)"] = states[index] }
            for index in group.masks { objects["\(InkStream.maskPrefix)\(index)"] = masks[index] }
            groupForms[number] = GroupForm(
                group: InkStream.Group(
                    content: [], box: group.box, states: group.states, masks: group.masks,
                    usesColorSpace: group.usesColorSpace
                ),
                length: group.content.reduce(0) { $0 + $1.count }, objects: objects
            )
            return number
        }
        let length = ink.content.reduce(0) { $0 + $1.count }
        let content = try spool.add(
            [Data("<< /Length \(length) /Filter /FlateDecode >>\nstream\n".utf8)] + ink.content
                + [Data("\nendstream".utf8)]
        )
        usesColorSpace = usesColorSpace || ink.usesColorSpace
        pages.append(
            PageRecord(
                index: index, content: content, states: states, masks: masks, groups: groups,
                usesColorSpace: ink.usesColorSpace, template: template
            )
        )
    }

    /// The update appended to the document CoreGraphics finished writing
    /// into `sink`. Nothing is appended to a document without ink or a
    /// shared template.
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
        var next = start + 2
        func reserve(_ wanted: Bool) -> Int? {
            guard wanted else { return nil }
            next += 1
            return next - 1
        }
        let profile = reserve(usesColorSpace), space = reserve(usesColorSpace)
        let groupProfile = reserve(!groupForms.isEmpty), groupSpace = reserve(!groupForms.isEmpty)
        let numbers = Numbers(
            open: start, close: start + 1, profile: profile, space: space, groupProfile: groupProfile,
            groupSpace: groupSpace, first: next
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
        if let profile = numbers.groupProfile, let space = numbers.groupSpace {
            // The profile CoreGraphics' transparency layers blend in.
            guard let icc = PreparedInk.groupProfile else { throw RenderError.pdfContextUnavailable }
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
            if let form = groupForms[index], let space = numbers.groupSpace {
                let dictionary = PreparedInk.groupDictionary(
                    form.group, length: form.length, space: .reference(number: space, generation: 0)
                ) { name in
                    if name == InkStream.colorSpaceName, let colors = numbers.space {
                        return .reference(number: colors, generation: 0)
                    }
                    return form.objects[name].map { .reference(number: numbers.first + $0, generation: 0) } ?? .null
                }
                sink.write(PDFWriter.bytes(of: .dictionary(dictionary)))
                sink.write("\nstream\n")
                sink.write(body)
                sink.write("\nendstream")
            } else {
                sink.write(body)
            }
            end()
            if index.isMultiple(of: 64) { try sink.flush() }
        }
        // The shared templates after the spooled objects: each one's objects,
        // its Form, and the stream that draws it, `/RMIt Do`.
        next = numbers.first + spool.count
        var invocations: [(form: Int, stream: Int)] = []
        for template in templates {
            let renumbering = template.objects.indices.map { next + $0 }
            next += template.objects.count
            for object in template.objects {
                begin(renumbering[object.number])
                sink.write(PDFWriter.bytes(of: PDFOverlayWriter.renumbered(object.object, to: renumbering)))
                end()
            }
            let form = next, stream = next + 1
            next += 2
            begin(form)
            sink.write(PDFWriter.bytes(of: PDFOverlayWriter.renumbered(template.form, to: renumbering)))
            end()
            let text = "/\(Self.templateName) Do\n"
            begin(stream)
            sink.write("<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream")
            end()
            invocations.append((form, stream))
        }

        for record in pages {
            let page = basePages[record.index]
            begin(page.number, generation: base.generations[page.number] ?? 0)
            let template = record.template.map { invocations[$0] }
            sink.write(
                PDFWriter.bytes(of: .dictionary(try extended(page, record, template: template, in: base, numbers: numbers)))
            )
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
    /// the colour space and its profile where any ink is coloured, the space
    /// transparency groups blend in and its profile where any ink has a
    /// group, and the first of the spooled objects, which follow one another
    /// from it.
    private struct Numbers {
        let open: Int
        let close: Int
        let profile: Int?
        let space: Int?
        let groupProfile: Int?
        let groupSpace: Int?
        let first: Int
    }

    /// The page CoreGraphics wrote: its shared template, where it has one,
    /// then its own content, then the ink, where it has any.
    private func extended(
        _ page: PDFFile.Page, _ record: PageRecord, template: (form: Int, stream: Int)?, in base: PDFFile,
        numbers: Numbers
    ) throws -> [String: PDFObject] {
        func reference(_ number: Int) -> PDFObject { .reference(number: number, generation: 0) }
        let first = numbers.first
        var dictionary = page.dictionary
        let own = try Self.contents(of: page.dictionary["Contents"], in: base)
        let drawn = record.content.map { [reference(numbers.open)] + own + [reference(numbers.close), reference(first + $0)] }
        // The template is drawn first, as CoreGraphics drew it, and a Form
        // leaves the graphics state as it found it: what CoreGraphics drew
        // after it starts where it started.
        dictionary["Contents"] = .array((template.map { [reference($0.stream)] } ?? []) + (drawn ?? own))
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
        try add(
            "XObject",
            record.masks.enumerated().map { ("\(InkStream.maskPrefix)\($0.offset)", first + $0.element) }
                + record.groups.enumerated().map { ("\(InkStream.groupPrefix)\($0.offset)", first + $0.element) }
                + (template.map { [(Self.templateName, $0.form)] } ?? [])
        )
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
