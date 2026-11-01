# RMRender

[![CI](https://github.com/altessa-s/rmrender-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/altessa-s/rmrender-swift/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Drawing reMarkable notebooks: pages parsed by
**[rmlines-swift](https://github.com/altessa-s/rmlines-swift)** into PDF or
`CGImage`, annotations written over an imported PDF, page templates under the
ink, typed text set in open fonts, and pencil and ballpoint grain — and, for a
caller that needs to know what a highlighter covered, where its bands lie on
the page as drawn.

It does not parse and it does not fetch. Bytes arrive through `PageBlobs`, a
document is `DocumentFiles` — a hash, a name and a size per file — and what a
page refers to by name (its template) comes from a bundled set of the
package's own, or from a source the host installs.

Part of **[Slate Drive](https://slatedrive.app)**
([repository](https://github.com/altessa-s/slatedrive)), the macOS app that
puts a reMarkable library on the Mac.

## What it renders

- **Notebooks** (`NotebookRenderer`) into a PDF on A4, US Letter or the
  tablet's own canvas, or into one `CGImage` per page (RGBA or 8-bit grey).
  Page order comes from `.content`; a missing or unreadable page list falls
  back to the index order. Pages written below the edge grow the sheet.
- **Annotated PDFs** (`AnnotatedPDFRenderer`): the imported PDF with the marks
  over it. Where it can, the ink is written as an incremental update, so the
  original's links, outline and text survive; otherwise the pages are redrawn.
- **Single pages** (`PageRenderer`): parsed `RMPage`s into a PDF in memory or
  on disk, or into a bitmap; `inkOnly` draws the handwriting alone.
- **Highlights** (`PageMarks`): where a highlighter went, as `RMMarks` bands in
  fractions of the frame the page is drawn in, so they can be matched against
  text recognised from the same pixels.
- **Templates** (`TemplateRenderer`): the JSON template format — groups,
  repeats, paths and labels whose coordinates are expressions — drawn under
  the ink. `TemplateScan` measures which templates are evenly ruled and where
  their lines fall (`RuledTemplate`, `Ruling`).

Strokes are drawn per tool: the pens' widths and pressure curves, the
highlighter's darken blend, pencil grain from stamp textures, ballpoint grain
from value noise, round and square caps and joins. Eraser strokes are not
drawn.

The stroke model is this package's own. Its widths, colours, opacities and
blends are fitted to the PDF and SVG exports of the reMarkable apps and live
in `Calibration`; caps, joins and grain are drawn by algorithms of its own. A
rendered page therefore matches an export closely but not exactly, and can
differ visibly from the same page on the tablet's screen — in the texture of
pencil and ballpoint grain, at the ends of strokes and at sharp corners.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/altessa-s/rmrender-swift.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [.product(name: "RMRender", package: "rmrender-swift")]
    ),
]
```

`RMLines` and `RMMarks` come with it. Requires Swift 6.3, macOS 15 or iOS 18:
the drawing uses CoreGraphics, CoreText and PDFKit.

## Usage

### Pages you have already parsed

```swift
import RMLines
import RMRender

let page = try RMParser.parsePage(rmData)

let pdf: Data = try PageRenderer.pdf(pages: [page], paper: .a4)
try PageRenderer.pdf(pages: [page], paper: .letter, to: outputURL)
let image: CGImage = try PageRenderer.image(page: page, scale: 2)
```

### Whole documents

The renderer asks for bytes and never fetches them itself. Implement
`PageBlobs` over wherever the files are — a folder, a cache, the network:

```swift
struct FolderBlobs: PageBlobs {
    let root: URL

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        try Data(contentsOf: root.appending(path: name))
    }

    func file(
        hash: String, name: String, owner: String?, size: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        BlobFile(url: root.appending(path: name), isTemporary: false)
    }
}

let files = DocumentFiles(files: [
    DocumentFile(hash: "…", name: "\(id).content", size: 1_204),
    DocumentFile(hash: "…", name: "\(id)/\(pageID).rm", size: 48_311),
])

let renderer = NotebookRenderer(blobs: FolderBlobs(root: folder))
try await renderer.renderPDF(documentID: id, index: files, to: outputURL, paper: .a4)

let images = try await renderer.renderImages(documentID: id, index: files, grayscale: true)

// A PDF with ink over it: the `.pdf` is one of the document's files.
try await AnnotatedPDFRenderer(blobs: FolderBlobs(root: folder))
    .renderPDF(documentID: id, index: files, to: outputURL)
```

Every document renderer takes `maximumPages:` to cap the output, and reports
progress, the page count before the cap, and pages it could not draw through
callbacks.

### Templates

A page names its template (`"P Lines medium"`), and the name is looked up in
the `TemplateSource` that `TemplateStore.shared` draws from. By default that
is `BundledTemplates`: 65 templates of this package's own — lined, squared and
dotted paper, checklists, day and week planners, storyboards, staves,
tablature and chord boxes, isometric and perspective guides — filed under the
names the tablet gives its templates, so a page that names one is drawn with a
background. Their spacings and insets are the tablet's, so the ruling falls
where the handwriting was laid along it; the drawings are original. On a
sheet under 1000 units on a side — the small tablet's, or a page written in a
phone app — they lay themselves out to fit: rulings start higher, wide layouts
shrink or drop to fewer columns, and planners stack their days. Any name the
source does not know leaves the page on blank paper.

```swift
// Your own templates instead of the bundled set:
TemplateStore.install(TemplateDirectory(url: templatesFolder))

// Your own first, the bundled set for every name yours do not cover:
TemplateStore.install(LayeredTemplates([TemplateDirectory(url: templatesFolder), BundledTemplates()]))

// Or any source of your own:
struct MyTemplates: TemplateSource {
    func templateNames() -> [String] { ["Squares"] }
    func templateData(named name: String) -> Data? { name == "Squares" ? squaresJSON : nil }
}
TemplateStore.install(MyTemplates())

// No templates at all — every page on blank paper:
TemplateStore.install(nil)

// Templates a hand can be written along, measured for a page size:
let ruled = TemplateStore.shared.ruledTemplates(pageSize: PageRenderer.defaultPageSize)
```

A `TemplateStore(source:)` can also be made on its own, to parse or measure
templates without changing what the renderer draws.

#### The tablet's own templates

To draw pages on exactly the paper the tablet shows, point the store at the
tablet's own `.template` files. They are reMarkable's and are not part of
this package; copy them from a tablet you own, for your own use, and do not
redistribute them with your application.

The tablet keeps them in `/usr/share/remarkable/templates`. With the tablet
connected over USB and SSH access enabled in its settings, copy them across:

```sh
mkdir -p ~/remarkable-templates
scp 'root@10.11.99.1:/usr/share/remarkable/templates/*.template' ~/remarkable-templates/
```

Then install them ahead of the bundled set, so the tablet's drawing is used
wherever a file exists and the bundled one fills in for any name it lacks:

```swift
let tablet = URL(filePath: NSString(string: "~/remarkable-templates").expandingTildeInPath)
TemplateStore.install(LayeredTemplates([TemplateDirectory(url: tablet), BundledTemplates()]))
```

`TemplateDirectory` reads every `<name>.template` in the folder and looks a
page's template up by that file name.

The bundled files in `Sources/RMRender/Templates` are generated by
`Scripts/generate-templates.py`, using the Python standard library only and
reading no other templates:

```sh
python3 Scripts/generate-templates.py          # regenerate
python3 Scripts/generate-templates.py --check  # verify the committed files (CI runs this)
```

### Diagnostics and identity

```swift
RMRenderLog.install { channel, level, message in logger.log("\(message)") }
RMRenderIdentity.credit = "My App"   // the PDF's creator
```

Nothing is logged until a sink is installed, and no message carries the
user's writing or document names.

## Grain

`Sources/RMRender/Grain` holds sixteen 64 × 64 two-valued PNGs: twelve pencil
stamp textures (`pencil0…3`, with `-light` and `-hard` families) and four
ballpoint scratch tiles (`marker0…3`). They are procedurally generated by
`Scripts/generate-grain.py` from fixed SplitMix64 seeds, using the Python
standard library only and reading no images or other inputs:

```sh
python3 Scripts/generate-grain.py          # regenerate
python3 Scripts/generate-grain.py --check  # verify the committed files (CI runs this)
```

The pencil tiles are clustered specks ranked to 14 %, 50 % and 66 % ink for
the light, base and hard families; the ballpoint tiles are short scratches
over 9 % of an otherwise solid tile. Both wrap on both axes. Which tiles lie
where, the pencils' noise and the second ballpoint's hairlines all come from
one integer hash of the unit's place (SplitMix64's finaliser), so every run on
every platform draws the same page.

## Fonts

Typed text is set in **Noto Sans** (with Noto Sans JP, KR, Thai Looped,
Arabic, Hebrew and Devanagari for those scripts) and **EB Garamond**, embedded
in the PDFs it writes. They are under the SIL Open Font License; each family's
licence file lies beside it in `Sources/RMRender/Fonts`. The CJK files are most
of the package's size.

## PDF tagging

Off by default:

```sh
swift build -Xswiftc -DRMRENDER_PDF_TAGGING
```

With it on, a template's ruling is drawn inside an artifact mark, so a reader
that reflows, extracts or searches the page leaves the lines and dots out. The
drawing is identical either way. It is behind a flag because
`CGContext.beginNonStructuralMarkedContentSequence` needs the macOS 27 SDK,
and `#available` does not spare the compiler from resolving the symbol.

## Building the xcframework

```sh
brew install xcodegen
Scripts/build-xcframework.sh                        # -> build/RMRender.xcframework
RMRENDER_VERSION=1.2.0 Scripts/build-xcframework.sh # stamp a version
```

`Package.swift` is the real project; `project.yml` declares the same sources
once more as a framework target, because SwiftPM cannot produce a framework.
The script generates that project with XcodeGen, archives it for macOS (arm64,
x86_64), iOS (arm64) and the iOS Simulator (arm64, x86_64), checks that each is
a dynamic framework with every slice, and wraps them. `RMLines` and `RMMarks`
resolve from their public repositories. `BundleModule.swift` provides
`Bundle.module` for that build under `RMRENDER_FRAMEWORK`.

Pushing a tag (`1.2.0` or `v1.2.0`) runs the tests, builds the framework and
publishes it as a release with its checksum.

## Tests

```sh
swift test
```

Strokes and their outlines, sheets and their growth, typed text and its
faces, templates (the bundled set, and synthetic fixtures written in the
tests), grain, the overlay written over an imported PDF, highlight bands, and
hostile input — malformed page lists, absurd sizes, truncated or lying PDFs.

## See also

- **[rmlines-swift](https://github.com/altessa-s/rmlines-swift)** — the `.rm`
  v6 page format, read and written; what this package draws.
- **[rmlines-lib](https://github.com/altessa-s/rmlines-lib)** — the same page
  format as a portable C23 library.
- **[rmlines-go](https://github.com/altessa-s/rmlines-go)** — the same page
  format in Go.
- **[rmmarks-swift](https://github.com/altessa-s/rmmarks-swift)** — the
  vocabulary of highlight bands and boxes this package answers with.
- **[rmmarks-lib](https://github.com/altessa-s/rmmarks-lib)** — the same as a
  portable C23 library.
- **[rmmarks-go](https://github.com/altessa-s/rmmarks-go)** — the same in Go.
- **[rmdoc-swift](https://github.com/altessa-s/rmdoc-swift)** — the `.rmdoc`
  container, packed and unpacked.
- **[rmdoc-lib](https://github.com/altessa-s/rmdoc-lib)** — the same container
  as a portable C23 library.
- **[rmdoc-go](https://github.com/altessa-s/rmdoc-go)** — the same container in
  Go.

## Acknowledgements

reMarkable does not publish its file formats. This package is built on openly
available information and on the research of third-party developers who
documented them.

## License

MIT — see [LICENSE](LICENSE), which covers the bundled templates and grain
too. The bundled fonts are under the SIL Open Font License; their licence
texts are in `Sources/RMRender/Fonts`.

reMarkable is a trademark of reMarkable AS. This project is not affiliated
with, endorsed by or sponsored by reMarkable AS.
