// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// SplitMix64 (Steele, Lea and Flood, 2014): a 64-bit generator whose every
/// output is its counter run through a fixed avalanche finaliser.
///
/// The grain needs randomness that is the same on every run and every
/// platform — a page drawn twice must come out the same — and nothing a
/// cryptographer would care about. This is small, fast and fully specified by
/// the published constants below. All arithmetic is on unsigned 64-bit
/// integers and wraps.
struct SplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next value of the sequence: `state += 0x9E3779B97F4A7C15`, then
    /// `mix(state)`.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    /// A value below `bound`, which must be positive. The modulo bias is at
    /// most `bound / 2⁶⁴` — nothing at the sizes the grain asks for.
    mutating func next(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// The finaliser on its own: a bijective hash of 64 bits in which every
    /// input bit affects every output bit.
    ///
    /// ```
    /// z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    /// z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    /// return z ^ (z >> 31)
    /// ```
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A hash of an integer lattice point: the one source of randomness every
/// grain draws from.
///
/// ```
/// hash(x, y, salt) = mix(mix(u64(x) + salt) ^ u64(y))
/// unit(x, y, salt) = (hash(x, y, salt) >> 11) * 2^-53          in [0, 1)
/// ```
///
/// `mix` is `SplitMix64.mix`; `u64` reinterprets a signed 64-bit integer's
/// two's-complement bits, and `+` wraps. Each grain passes its own `salt`,
/// so two grains laid over the same unit do not repeat each other.
enum GrainHash {
    static func hash(_ x: Int64, _ y: Int64, salt: UInt64) -> UInt64 {
        SplitMix64.mix(SplitMix64.mix(UInt64(bitPattern: x) &+ salt) ^ UInt64(bitPattern: y))
    }

    /// The hash as a number in `[0, 1)`: its top 53 bits over `2⁵³`.
    static func unit(_ x: Int64, _ y: Int64, salt: UInt64) -> Double {
        Double(hash(x, y, salt: salt) >> 11) * 0x1p-53
    }

    /// `floor(value)` as a 64-bit integer, held to `±2⁶²` so that a
    /// coordinate that is no place on any page cannot trap the conversion.
    /// Not a number reads as nought.
    static func floor(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        let floored = value.rounded(.down)
        if floored >= 0x1p62 { return 1 << 62 }
        if floored <= -0x1p62 { return -(1 << 62) }
        return Int64(floored)
    }
}
