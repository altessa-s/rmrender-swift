#!/usr/bin/env python3
# Copyright 2026 ALTESSA SOLUTIONS INC.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file.
"""Generate RMRender's original grain assets; Python standard library only.

Every pixel comes from the code below; no images or tables are read.
The stable integer PRNG and toroidal sampling make the tiles reproducible
and periodic. Run with --check to verify committed PNGs without writing.
"""

import argparse
from pathlib import Path
import struct
import zlib

SIDE = 64
MASK = (1 << 64) - 1


class Random:
    """SplitMix64 with seeds belonging to this asset set."""

    def __init__(self, seed):
        self.state = seed

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK
        return value ^ (value >> 31)


def pencil(variant, coverage):
    rng = Random(0x534C415445_1000 + variant)
    noise = [rng.next() >> 48 for _ in range(SIDE * SIDE)]
    # A small isotropic grain, with individual specks retained. Every sample
    # wraps at the edge; the threshold fixes density without copying a mask.
    scores = []
    for y in range(SIDE):
        for x in range(SIDE):
            score = 0
            for dx, dy, weight in ((0, 0, 24), (-1, 0, 2), (1, 0, 2),
                                   (0, -1, 2), (0, 1, 2), (-1, -1, 1),
                                   (-1, 1, 1), (1, -1, 1), (1, 1, 1)):
                score += weight * noise[((y + dy) % SIDE) * SIDE + (x + dx) % SIDE]
            scores.append(score)
    count = (SIDE * SIDE * coverage + 50) // 100
    black = set(sorted(range(len(scores)), key=lambda i: (scores[i], i))[:count])
    return bytes(0 if i in black else 255 for i in range(SIDE * SIDE))


def marker(variant):
    rng = Random(0x534C415445_2000 + variant)
    paper = set()
    # Short, one-texel breaks in otherwise solid ink. Independent variants
    # let overlapping segments close the breaks as the band grows wider.
    directions = ((1, 0), (0, 1), (1, 1), (1, -1))
    count = SIDE * SIDE * 9 // 100
    while len(paper) < count:
        x, y = rng.next() % SIDE, rng.next() % SIDE
        dx, dy = directions[rng.next() % len(directions)]
        for _ in range(2 + rng.next() % 5):
            paper.add(y * SIDE + x)
            if len(paper) == count:
                break
            x, y = (x + dx) % SIDE, (y + dy) % SIDE
    return bytes(255 if i in paper else 0 for i in range(SIDE * SIDE))


def png(pixels):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))

    rows = b''.join(b'\0' + pixels[y * SIDE:(y + 1) * SIDE] for y in range(SIDE))
    # Stored DEFLATE blocks avoid compressed-byte changes between zlib versions.
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', SIDE, SIDE, 8, 0, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, level=0)) + chunk(b'IEND', b''))


def assets():
    for variant in range(4):
        for suffix, density in (('-light', 14), ('', 50), ('-hard', 66)):
            yield f'pencil{variant}{suffix}.png', pencil(variant, density)
        yield f'marker{variant}.png', marker(variant)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Sources/RMRender/Grain')
    args = parser.parse_args()
    failures = []
    if not args.check:
        args.output.mkdir(parents=True, exist_ok=True)
    for name, pixels in assets():
        path, data = args.output / name, png(pixels)
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                failures.append(name)
        else:
            path.write_bytes(data)
    if failures:
        parser.exit(1, 'Missing or changed grain assets: ' + ', '.join(failures) + '\n')
    print('16 grain assets verified' if args.check else '16 grain assets generated')


if __name__ == '__main__':
    main()
