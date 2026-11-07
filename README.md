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

## Annotated PDFs

`AnnotatedPDFRenderer` first tries an **incremental update**: the marks are
appended to the original file, so its links, outline and text stay as they
were. Strokes become PDF operators; typed text, images
and erased strokes are drawn by the same `PageRenderer` as a fresh export and
imported as a Form. The Forms of pages with typed text are drawn 32 pages of
the document at a time into one PDF, so a typeface is embedded once for each
such run rather than once a page, and a picture, profile or typeface that
several pages carry alike is written into the update once. Quarter-turn page rotations, shifted origins and
a `CropBox` are kept, and ink that runs past the page grows the box shown.

When the update cannot be made — a page added, removed or reordered on the
tablet, a hidden source page, or an encrypted file — the document is **drawn
afresh**. A fresh export keeps URI and in-document links and the outline,
remapped through the new page order, but not other annotations, forms or
signatures.

A **certified** document (one whose catalog carries `/Perms`) takes no
incremental update, since appending to it would break the certification. With
marks on it, it is drawn afresh by default: links and the outline are kept, the
certification is not, and the `onCertificationDropped` callback is called.
Pass `refuseCertified: true` to have such a document refused with
`RenderError.unsupportedFormat` instead. A certified document without marks
goes out unchanged, certification included.

An image whose attachment is missing, too large or not a decodable PNG or JPEG
leaves a **hole**: the page is drawn without it, the export goes on, and
`onMissingImages` reports how many pages lost an image and how many
attachments are missing (`NotebookRenderer` has the same callback).
`PageRenderer`, which is handed its attachments, draws the same hole and logs
it.

A page whose bytes **do not arrive** — `PageBlobs` failing with anything other
than a cancellation — is handled as `unfetchedPages:` says, on every document
renderer (`NotebookRenderer.renderPDF`, `renderImages`, `parsed`,
`renderInkImages`, and `AnnotatedPDFRenderer.renderPDF`):

| `UnfetchedPagePolicy` | Notebook page | Annotated page | `onUnfetched` |
|---|---|---|---|
| `.placeholder` (default) | a plain white sheet of the page's size, "Rendering error" in the middle | the original page, the same label over it | called |
| `.blank` | a blank sheet on its template, as a page that does not parse | the original page without its marks | called |
| `.strict` | the render throws `PageFetchError(page:pageID:underlying:)` and writes no output | the same | not called |

The label is dark grey on a light rounded box, sized to the page's width and
set in Noto Sans, the face typed text is set in. On an annotated document taken
the incremental way it is written into the update as a native Form, so the
original's links and outline stay. Bitmaps carry it too — which a text
recogniser will read, so an OCR caller wants `.blank` or `.strict`; ink-only
bitmaps (`renderInkImages`) never show it. `parsed` keeps such pages as blank
sheets in `ParsedNotebook.unfetched` and leaves the look to
`renderImages(_:unfetchedPages:)`.

`onUnfetched` is told separately from `onUnreadable`: a page that arrived and
does not parse is drawn as it always was, whatever the policy, because it will
not parse on the next try either. Cancelling a render still ends it with the
cancellation, under every policy, and a missing or unopenable original or an
output that cannot be written is still an error.

A page with a `/UserUnit` other than 1 is refused with
`RenderError.unsupportedFormat`.

The reader handles cross-reference tables and streams, hybrid files, packed
objects and indirect stream lengths, with bounded decompression and checks on
generations, references and byte ranges. Output is written to a temporary file
and moved into place when complete.

## How the ink is written

CoreGraphics prints every coordinate of a page through `vsnprintf`, which
takes the C library's global locale lock, and deflates each page on the
thread that draws it — most of what exporting a written page costs, and the
reason pages drawn side by side do not draw faster. So a PDF's **ink** — the
fills, lines, pencil grain and erased outlines after the last thing only
CoreGraphics draws on the page (a picture, a shader layer) — is written by the
package itself, on the tasks that parse the pages, while CoreGraphics draws the
rest one page at a time: templates, typed text, pictures, the original page of
an annotated PDF. The written ink is appended as an incremental update over
CoreGraphics' document once it is closed, each page's own drawing wrapped so
that the ink starts from the initial graphics state.

The writer emits the operators CoreGraphics would, with the same numbers
computed by the same floating-point steps and printed the way CoreGraphics
prints them, in the same sRGB colour space and with the same graphics states
and image masks, so a page paints exactly what CoreGraphics drawing all of it
paints; the tests hold the two against each other pixel for pixel. It applies
to notebook exports, redrawn annotated PDFs, and the native pages of an
annotated PDF's overlay. The bytes do not depend on how many pages were
prepared at once.

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
