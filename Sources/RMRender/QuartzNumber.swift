// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A number as CoreGraphics' PDF writer prints it into a content stream.
///
/// Apart from `PDFWriter.number`, which an overlay's own operators are
/// written with and which stays as it is: the ink this package writes in
/// CoreGraphics' place (`InkStream`) has to paint what CoreGraphics' own
/// operators paint, to the pixel, and the surest way there is the same
/// coordinate printed the same way. CoreGraphics prints through `vsnprintf`,
/// which takes the C library's global locale lock for every number — the
/// lock that serialized pages drawn side by side — and this prints the same
/// text in integers.
///
/// What it prints, decision for decision (macOS 27):
/// - not a number as `0`, an infinity as the end of the 32-bit range;
/// - within 1e-6 of a 32-bit integer, that integer;
/// - a magnitude from 1 to 1e7 as `%0.7g`; above 1e7 as `%0.0f`;
/// - below 1e-6, `0`;
/// - otherwise as `%0.*f`, the places found the way CoreGraphics finds
///   them: the first power of ten lifting the magnitude to 1 (at most 10⁶),
///   then up to six more until it lies within 1e-5 of an integer. The
///   multiplier is a 32-bit integer that wraps past 10⁹, and so does this
///   one.
///
/// Held against the text CoreGraphics itself printed, value by value, in the
/// tests.
enum QuartzNumber {
    /// Powers of ten up to 10¹², all exact in a double.
    private static let powers: [Double] = [1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12]

    /// `value` as text, for a test or a dictionary; the drawing appends.
    static func text(_ value: Double) -> String {
        var out: [UInt8] = []
        append(value, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// An alpha as CoreGraphics prints it into a graphics state dictionary
    /// — `/ca 0.251` for 64/255 — which is not how it prints a coordinate:
    /// four places, the value times ten thousand rounded as a double, the
    /// trailing zeros and a bare point dropped. Held against CoreGraphics'
    /// own dictionaries in the tests.
    static func alphaText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let magnitude = abs(value)
        guard magnitude < 1e9 else { return String(format: "%.4f", value) }
        // The product rounded, halves away from nought — not the exact
        // value: 0.01995 is a hair below the half in binary, and prints 0.02.
        var rounded = UInt64((magnitude * 1e4).rounded())
        var out: [UInt8] = []
        if value < 0, rounded != 0 { out.append(UInt8(ascii: "-")) }
        digits(rounded / 10_000, to: &out)
        rounded %= 10_000
        if rounded != 0 {
            var places = 4
            while rounded.isMultiple(of: 10) {
                rounded /= 10
                places -= 1
            }
            out.append(UInt8(ascii: "."))
            digits(rounded, width: places, to: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Appends `value` as CoreGraphics prints it.
    static func append(_ value: Double, to out: inout [UInt8]) {
        if value.isNaN {
            out.append(UInt8(ascii: "0"))
            return
        }
        if value.isInfinite {
            out.append(contentsOf: value > 0 ? Array("2147483647".utf8) : Array("-2147483648".utf8))
            return
        }
        if value >= -2_147_483_648.0, value <= 2_147_483_647.0 {
            let nearest = value < 0 ? (value - 0.5).rounded(.up) : (value + 0.5).rounded(.down)
            if abs(value - nearest) < 1e-6 {
                let whole = Int64(nearest)
                if whole < 0 { out.append(UInt8(ascii: "-")) }
                digits(whole.magnitude, to: &out)
                return
            }
        }
        let magnitude = abs(value)
        if magnitude >= 1 {
            if magnitude <= 1e7 {
                significant(value, magnitude: magnitude, to: &out)
                return
            }
            // `%0.0f`: the integer nearest, ties to even.
            if value < 0 { out.append(UInt8(ascii: "-")) }
            if magnitude < 4_503_599_627_370_496.0 {
                digits(scaled(magnitude, by: 1), to: &out)
            } else if magnitude < 18_446_744_073_709_551_616.0 {
                // From 2^52 a double is an integer already.
                digits(UInt64(magnitude), to: &out)
            } else {
                // Past 2^64: digits only, so no locale radix can appear.
                out.append(contentsOf: Array(String(format: "%.0f", magnitude).utf8))
            }
            return
        }
        if magnitude < 1e-6 {
            out.append(UInt8(ascii: "0"))
            return
        }
        var multiplier: UInt32 = 1
        var leading = 0, extra = 0
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
        fixed(value, magnitude: magnitude, places: leading + extra, to: &out)
    }

    /// Ten to the power of the index, as integers, for the digits.
    private static let integerPowers: [UInt64] = (0...19).map { power in
        (0..<power).reduce(UInt64(1)) { product, _ in product &* 10 }
    }

    /// The decimal digits of `value`, none wasted.
    private static func digits(_ value: UInt64, to out: inout [UInt8]) {
        var width = 1
        while width < 20, value >= integerPowers[width] { width += 1 }
        digits(value, width: width, to: &out)
    }

    /// `value` in exactly `width` digits, zeros in front: `value` is below
    /// ten to the `width`. Written a digit at a time from the top, so that
    /// nothing is allocated for a number — a page prints hundreds of
    /// thousands of them.
    private static func digits(_ value: UInt64, width: Int, to out: inout [UInt8]) {
        var rest = value
        for place in stride(from: width - 1, through: 0, by: -1) {
            let power = integerPowers[place]
            let digit = rest / power
            out.append(UInt8(ascii: "0") + UInt8(truncatingIfNeeded: digit))
            rest -= digit * power
        }
    }

    /// The integer nearest `value · scale`, ties to even, from the exact
    /// product: `scale` a power of ten up to 10¹² and the product below 2^52.
    private static func scaled(_ value: Double, by scale: Double) -> UInt64 {
        let high = value * scale
        let low = (-high).addingProduct(value, scale)
        let whole = high.rounded(.down)
        // Both terms are multiples of an ulp of `high`, which exceeds twice
        // `low`: the sign of the exact remainder less a half is that of
        // `difference` unless `difference` is nought.
        let difference = (high - whole) - 0.5
        var result = UInt64(whole)
        if difference > 0 || (difference == 0 && (low > 0 || (low == 0 && result & 1 == 1))) {
            result += 1
        }
        return result
    }

    /// `%0.7g` of `value`, whose magnitude lies in [1, 1e7]: seven
    /// significant digits, trailing zeros of the fraction dropped.
    private static func significant(_ value: Double, magnitude: Double, to out: inout [UInt8]) {
        let exponent = magnitude < 1e1 ? 0
            : magnitude < 1e2 ? 1
            : magnitude < 1e3 ? 2
            : magnitude < 1e4 ? 3
            : magnitude < 1e5 ? 4
            : magnitude < 1e6 ? 5 : 6
        let rounded = scaled(magnitude, by: powers[6 - exponent])
        if value < 0 { out.append(UInt8(ascii: "-")) }
        if rounded >= 10_000_000 {
            // Rounded up to the next power of ten.
            if exponent == 6 {
                out.append(contentsOf: Array("1e+07".utf8))
                return
            }
            out.append(UInt8(ascii: "1"))
            out.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: exponent + 1))
            return
        }
        // Seven digits: `exponent + 1` before the point, the rest after
        // it with their trailing zeros dropped.
        let fractionPlaces = 6 - exponent
        let unit = integerPowers[fractionPlaces]
        digits(rounded / unit, to: &out)
        var fraction = rounded % unit
        guard fraction != 0 else { return }
        var places = fractionPlaces
        while fraction.isMultiple(of: 10) {
            fraction /= 10
            places -= 1
        }
        out.append(UInt8(ascii: "."))
        digits(fraction, width: places, to: &out)
    }

    /// `%0.*f` of `value`, whose magnitude is below 1, at `places` (1 to 12).
    private static func fixed(_ value: Double, magnitude: Double, places: Int, to out: inout [UInt8]) {
        var rounded = scaled(magnitude, by: powers[places])
        let unit = UInt64(powers[places])
        if value < 0 { out.append(UInt8(ascii: "-")) }
        if rounded >= unit {
            out.append(UInt8(ascii: "1"))
            rounded -= unit
        } else {
            out.append(UInt8(ascii: "0"))
        }
        out.append(UInt8(ascii: "."))
        digits(rounded, width: places, to: &out)
    }
}
