// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import Foundation
@testable import RMRender
import Testing

// `PDFWriter.number` works in integers and must write what the formatter it
// replaced wrote, to the byte: an overlay written twice from one document has
// to come out the same file. `PDFWriter.formatted` is that formatter, kept.

/// The numbers worth naming: signs, ties, the edges of the whole-number path,
/// the edges of a double.
private let namedValues: [Double] = [
    0, -0.0, 0.5, -0.5, 1.5, 2.5, 0.00001, -0.00001, 0.00005, -0.00005, 0.00015, 0.00025,
    // Exact ties at four places: 0.03125 is 312.5 ten-thousandths.
    0.03125, 0.09375, -0.03125, 1.03125, 0.15625, 0.21875,
    // Exact ties at ten places.
    0.00000000005, 1.0 / 1024 / 1024 / 1024 / 1024 / 2,
    1e15, -1e15, 1e15 + 0.5, 1e15 - 0.5, 4503599627370495.5, 4503599627370496, 9007199254740993,
    1e16, 1e20, -1e20, 1.5e30, 1e300, -1e300, 0.1, 0.2, 0.3, 1.0 / 3, -2.0 / 3, 612.0001, 791.99995,
    Double.leastNonzeroMagnitude, -Double.leastNonzeroMagnitude, Double.leastNormalMagnitude,
    Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, Double.ulpOfOne,
    .nan, .infinity, -.infinity,
]

private func reference(_ value: Double, places: Int) -> String {
    guard value.isFinite else { return "0" }
    if value == value.rounded(), abs(value) < 1e15 { return "\(Int(value))" }
    return PDFWriter.formatted(value, places: places)
}

@Test("Named numbers are written as the formatter wrote them, at every number of places")
func namedNumbersMatchTheFormatter() {
    for places in 1...18 {
        for value in namedValues + namedValues.map({ $0 * 3 }) + namedValues.map({ $0 / 7 }) {
            #expect(PDFWriter.number(value, places: places) == reference(value, places: places),
                    "\(value) at \(places) places")
        }
    }
}

@Test("A random sweep of every magnitude is written as the formatter wrote it")
func randomNumbersMatchTheFormatter() {
    var random = SplitMix64(seed: 0x5EED_0F_D16175)
    var mismatches: [String] = []
    for round in 0..<400_000 {
        let value: Double
        switch round % 4 {
        case 0:
            // Any bit pattern at all: subnormals, huge, negative.
            value = Double(bitPattern: random.next())
        case 1:
            // Page coordinates: what an overlay actually writes.
            value = (Double(random.next() >> 11) / Double(1 << 53) - 0.5) * 4000
        case 2:
            // Near a tie at four places: a whole number of half
            // ten-thousandths, give or take an ulp.
            let halves = Double(Int64(bitPattern: random.next()) % 20_000_000) + 0.5
            value = (halves / 10_000).nextUp
        default:
            // Short binary fractions: exact ties at many places.
            value = Double(Int64(bitPattern: random.next()) % 1_000_000) / Double(1 << (random.next() % 40))
        }
        let places = [4, 4, 10, Int(random.next() % 18) + 1][round % 4]
        let fast = PDFWriter.number(value, places: places)
        let slow = reference(value, places: places)
        if fast != slow, mismatches.count < 10 { mismatches.append("\(value) @\(places): \(fast) vs \(slow)") }
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
}

@Test("Coordinates at four places take the integer path, not the formatter")
func coordinatesTakeTheIntegerPath() {
    // The point of the integers is the coordinates: if they fell back to the
    // formatter, the output would be the same and the time with it.
    var random = SplitMix64(seed: 42)
    var taken = 0
    for _ in 0..<100_000 {
        let value = (Double(random.next() >> 11) / Double(1 << 53) - 0.25) * 3000
        if PDFWriter.fixedPoint(value, places: 4) != nil { taken += 1 }
    }
    #expect(taken > 99_000)
}
