// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import Testing

// `QuartzNumber` prints what CoreGraphics prints, so that ink written in its
// place paints what its own operators paint. Held three ways: against the
// text CoreGraphics printed for a table of values, against CoreGraphics'
// decisions replayed through the C library's printf, and against a live
// CGPDFContext.

/// CoreGraphics' number printing, decision for decision, through
/// `vsnprintf` as CoreGraphics prints: the reference the integers must equal.
private func reference(_ value: Double) -> String {
    func printf(_ format: String, _ arguments: any CVarArg...) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let count = withVaList(arguments) { vsnprintf(&buffer, buffer.count, format, $0) }
        return String(decoding: buffer[0..<Int(count)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    if value.isNaN { return "0" }
    if value.isInfinite { return value > 0 ? "2147483647" : "-2147483648" }
    if value >= -2_147_483_648.0, value <= 2_147_483_647.0 {
        let nearest = value < 0 ? ceil(value - 0.5) : floor(value + 0.5)
        if abs(value - nearest) < 1e-6 { return printf("%d", Int32(nearest)) }
    }
    let magnitude = abs(value)
    if magnitude >= 1 { return magnitude > 1e7 ? printf("%0.0f", value) : printf("%0.7g", value) }
    if magnitude < 1e-6 { return "0" }
    var leading: Int32 = 0, extra: Int32 = 0
    var multiplier: UInt32 = 1
    while !(magnitude * Double(multiplier) >= 1) {
        multiplier &*= 10
        leading += 1
        if leading == 6 { break }
    }
    while true {
        let lifted = magnitude * Double(multiplier)
        if abs(lifted - lifted.rounded()) < 1e-5 { break }
        multiplier &*= 10
        extra += 1
        if extra == 6 { break }
    }
    return printf("%0.*f", leading + extra, value)
}

@Test("Numbers print as CoreGraphics printed them")
func quartzNumbersMatchTheReferenceTable() {
    var mismatches: [String] = []
    for (value, text) in quartzNumberReference where QuartzNumber.text(value) != text {
        mismatches.append("\(value): \(QuartzNumber.text(value)), CoreGraphics \(text)")
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
}

@Test("Edges and random values print as CoreGraphics' decisions do through printf")
func quartzNumbersMatchPrintf() {
    var values: [Double] = [
        0, -0.0, 1, -1, 0.5, 1e-6, 9.99999e-7, 1.5e-6, 1e-5, 1.25e-5, 0.30000001, 0.9999999, 0.99999995,
        9_999_999.4, 9_999_999.5, 1e7, 10_000_000.5, 10_000_001.5, 2_147_483_647, 2_147_483_647.5,
        -2_147_483_648, -2_147_483_649, 4_503_599_627_370_495.5, 1e15, 1e20, 1e300, -1e300,
        .infinity, -.infinity, .nan, 5e-324, 123.456049, 123.45605, 0.0012697600570558986,
    ]
    for power in -12...12 {
        for digit in 1..<10 {
            let value = Double(digit) * pow(10, Double(power))
            values += [value, -value, value.nextDown, value.nextUp]
        }
    }
    var random = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
    func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(random.next() >> 11) / 9_007_199_254_740_992.0
    }
    for _ in 0..<200_000 {
        values.append(uniform(-2000, 2000))
        values.append((random.next() & 1 == 1 ? 1 : -1) * pow(10, uniform(-8, 9)))
        // An exact tie at the seventh significant digit.
        let tie = (Double(1_000_000 + random.next() % 9_000_000) + 0.5) * pow(10, Double(Int(random.next() % 13)) - 12)
        values.append(tie)
    }
    for _ in 0..<100_000 { values.append(Double(bitPattern: random.next())) }
    var mismatches: [String] = []
    for value in values where QuartzNumber.text(value) != reference(value) {
        if mismatches.count < 10 { mismatches.append("\(value): \(QuartzNumber.text(value)) vs \(reference(value))") }
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
}

@Test("Numbers print as a live CGPDFContext prints them")
func quartzNumbersMatchALiveContext() throws {
    var random = SplitMix64(seed: 0x243F_6A88_85A3_08D3)
    func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(random.next() >> 11) / 9_007_199_254_740_992.0
    }
    let count = 20000
    let values: [Double] = (0..<count).map { index in
        switch index % 4 {
        case 0: uniform(-2000, 2000)
        case 1: (random.next() & 1 == 1 ? 1 : -1) * pow(10, uniform(-8, 9))
        case 2: (Double(1_000_000 + random.next() % 9_000_000) + 0.5) * pow(10, Double(Int(random.next() % 10)) - 9)
        default: (uniform(-1e6, 1e6)).rounded() / 1e4
        }
    }
    // Each value the x of a triangle's first corner, its y the index plus
    // a quarter, so that the text can be found again by what follows it.
    let content = try InkTesting.pageContent(width: 612, height: 792) { context in
        for (index, value) in values.enumerated() {
            context.move(to: CGPoint(x: value, y: Double(index) + 0.25))
            context.addLine(to: CGPoint(x: 1, y: 2))
            context.addLine(to: CGPoint(x: 3, y: 1))
            context.closePath()
            context.fillPath()
        }
    }
    let tokens = String(decoding: content, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
    var checked = 0
    var mismatches: [String] = []
    for position in tokens.indices.dropFirst().dropLast() where tokens[position + 1] == "m" {
        let token = tokens[position]
        guard token.hasSuffix(".25"), let index = Int(token.dropLast(3)), index < count else { continue }
        let printed = String(tokens[position - 1])
        if QuartzNumber.text(values[index]) != printed, mismatches.count < 10 {
            mismatches.append("\(values[index]): CoreGraphics \(printed), ours \(QuartzNumber.text(values[index]))")
        }
        checked += 1
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
    // CoreGraphics drops degenerate triangles; most values are compared.
    #expect(checked > count * 9 / 10)
}

@Test("Alphas print as CoreGraphics prints them into a graphics state")
func quartzAlphasMatchALiveContext() throws {
    var random = SplitMix64(seed: 0xA1FA)
    var alphas = (1..<255).map { Double($0) / 255 }
    for _ in 0..<1500 { alphas.append(Double(random.next() >> 11) / 9_007_199_254_740_992.0) }
    // Ties at the fourth place, and the values about them.
    for step in stride(from: 5, to: 10_000, by: 97) {
        let tie = (Double(step) + 0.5) / 10_000
        alphas += [tie, tie.nextUp, tie.nextDown]
    }
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    for alpha in alphas {
        context.saveGState()
        context.setAlpha(alpha)
        context.fill(CGRect(x: 10, y: 10, width: 5, height: 5))
        context.restoreGState()
    }
    context.endPDFPage()
    context.closePDF()
    let pdf = data as Data
    let file = try PDFFile(bytes: pdf)
    let page = try #require(try file.pages().first)
    let states = try #require(try file.resolve(try file.resolve(page.resources).dictionaryValue?["ExtGState"]).dictionaryValue)
    // Each state's `/ca` as CoreGraphics wrote it, by the state's name.
    var printed: [String: String] = [:]
    for (name, reference) in states {
        guard case .reference(let number, _) = reference, let offset = file.offsets[number] else { continue }
        let text = String(decoding: pdf[offset..<min(offset + 200, pdf.count)], as: UTF8.self)
        guard let range = text.range(of: "/ca ") else { continue }
        printed[name] = String(text[range.upperBound...].prefix { $0 != " " && $0 != ">" })
    }
    let content = String(decoding: try InkTesting.content(of: pdf, page: 1), as: UTF8.self)
    let used = content.split(whereSeparator: { $0 == " " || $0 == "\n" })
    var names: [String] = []
    for (index, token) in used.enumerated() where token == "gs" { names.append(String(used[index - 1].dropFirst())) }
    #expect(names.count == alphas.count)
    var mismatches: [String] = []
    for (alpha, name) in zip(alphas, names) where printed[name] != QuartzNumber.alphaText(alpha) {
        if mismatches.count < 10 { mismatches.append("\(alpha): CoreGraphics \(printed[name] ?? "-"), ours \(QuartzNumber.alphaText(alpha))") }
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
}
