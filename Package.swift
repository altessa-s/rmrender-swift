// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// Drawing reMarkable notebooks: pages into PDF or bitmaps, annotations over an
// imported PDF, page templates, embedded fonts and pencil grain — and, for a
// caller that needs to know what a highlighter covered, where its bands lie on
// the page as drawn.
//
// It does not parse and it does not know any sync protocol. Two dependencies,
// both of them vocabulary: `RMLines` for the page it is handed, `RMMarks` for
// the bands and boxes it answers with. Where its diagnostics go and what a PDF
// credits as its creator are installed by the host (`RMRenderLog`,
// `RMRenderIdentity`); page templates come from a bundled set of its own
// unless the host installs another source (`TemplateStore`).
import PackageDescription

let package = Package(
    name: "RMRender",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RMRender", targets: ["RMRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/altessa-s/rmlines-swift.git", from: "1.0.1"),
        .package(url: "https://github.com/altessa-s/rmmarks-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "RMRender",
            dependencies: [
                .product(name: "RMLines", package: "rmlines-swift"),
                .product(name: "RMMarks", package: "rmmarks-swift"),
            ],
            // The typefaces typed text is set in, the stamp textures the
            // pencil is grained with, and the page templates drawn under the
            // ink. The typefaces are under the SIL Open Font License, whose
            // text lies beside them; the grain and the templates are generated
            // by the scripts in `Scripts/`.
            resources: [.copy("Fonts"), .copy("Grain"), .copy("Templates")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMRenderTests",
            dependencies: [
                "RMRender",
                .product(name: "RMLines", package: "rmlines-swift"),
                .product(name: "RMMarks", package: "rmmarks-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
