// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation

/// The bytes of a document's attachments, by file name, gathered under one
/// budget.
///
/// Written once and shared, so that the two callers cannot drift apart. A
/// notebook and an imported document both draw pages whose images live in
/// separate blobs, and both must decide the same three things: which
/// attachments the pages ask for, how many bytes may be held at once, and what
/// to say when one of them does not arrive. Two copies would easily agree on
/// the first two and disagree on the third — one saying nothing when a
/// download failed, so that a page came out with a hole in it that nothing in
/// the log could account for, while the other named the very same hole when
/// the cause was a size limit instead.
///
/// The budget is a running sum and not a per-file ceiling: the attachments are
/// held together while the pages are drawn, so it is their total that has to
/// fit. See `PageRenderer.maximumAssetBytes`.
///
/// Nothing here throws. An attachment that is missing, refused or
/// undecodable costs its own image and nothing else — the page is still
/// drawn, with a hole where the picture stood — and `holes` counts what was
/// lost, so that a caller can say so.
enum PageAssets {
    /// The attachments the drawing can use, decoded. One whose bytes do not
    /// decode as an image — torn, neither PNG nor JPEG, or past
    /// `PageRenderer.maximumImagePixels` — is taken out and named in the log,
    /// so that its page is drawn with the same hole a missing one leaves.
    ///
    /// The decoded image is what is kept, not the bytes: the check is the
    /// decode, and the drawing takes the image it made rather than decoding
    /// the bytes a second time on every page that shows them. A decoded
    /// image is its header and its bytes until it is drawn — the pixels are
    /// unpacked there, and not held after — so keeping it costs what keeping
    /// the bytes did.
    static func decoded(_ assets: [String: Data], channel: String) -> [String: CGImage] {
        var kept: [String: CGImage] = [:]
        for name in assets.keys.sorted() {
            guard let data = assets[name] else { continue }
            guard let image = PageRenderer.decodeImage(data) else {
                RMRenderLog.pageError(
                    """
                    \(channel): an attachment of \(data.count) bytes does not \
                    decode as an image — a hole where its image stood
                    """
                )
                continue
            }
            kept[name] = image
        }
        return kept
    }

    /// How many pages name an image the drawing does not hold, and how many
    /// distinct attachments those images are. A page is the files its images
    /// name (`RMPage.images`), so that a caller can count without keeping
    /// the pages themselves.
    static func holes(in pages: [[String]], available: Set<String>) -> (pages: Int, images: Int) {
        var missing: Set<String> = []
        var pagesWithHoles = 0
        for files in pages {
            let lost = files.filter { !available.contains($0) }
            guard !lost.isEmpty else { continue }
            pagesWithHoles += 1
            missing.formUnion(lost)
        }
        return (pagesWithHoles, missing.count)
    }

    /// - Parameters:
    ///   - wanted: the attachments the pages' images name.
    ///   - index: the document's files, which state each blob's size before
    ///     it is fetched — that is what lets the budget refuse one early.
    ///   - channel: how this caller's lines are spelled in the log, so a
    ///     reader can tell a notebook's holes from an imported document's.
    ///   - fetch: the bytes for one entry. Each caller reaches them its own
    ///     way — one straight from the blob store, one through a cache — and
    ///     that difference is the only one between the two.
    static func gather(
        _ wanted: Set<String>,
        index: DocumentFiles,
        channel: String,
        fetch: (DocumentFile) async throws -> Data
    ) async -> [String: Data] {
        guard !wanted.isEmpty else { return [:] }

        var assets: [String: Data] = [:]
        var held = 0
        for entry in index.files {
            let name = entry.fileName
            guard wanted.contains(name), assets[name] == nil else { continue }
            // Refused before it is fetched, on the size the index states, so a
            // document that cannot fit costs nothing to find out about. Put as
            // what is left rather than as a sum: the size is the index's word,
            // and `held` plus a size near `Int64.max` is a trap.
            guard entry.size >= 0, entry.size <= Int64(PageRenderer.maximumAssetBytes - held) else {
                RMRenderLog.pageError(
                    """
                    \(channel): an attachment of \(entry.size) bytes is past \
                    what one document may hold — a hole where its image stood
                    """
                )
                continue
            }
            do {
                let data = try await fetch(entry)
                // Weighed again on what arrived: the stated size is the
                // index's word, and an attachment that said nought and
                // brought a gigabyte would otherwise be held to the end of
                // the render. Dropped here, it costs the moment it took.
                guard data.count <= PageRenderer.maximumAssetBytes - held else {
                    RMRenderLog.pageError(
                        """
                        \(channel): an attachment stated at \(entry.size) bytes arrived \
                        as \(data.count) — past what one document may hold, a hole where its image stood
                        """
                    )
                    continue
                }
                held += data.count
                assets[name] = data
            } catch {
                // The same hole the guard above refuses to make, arrived at the
                // other way, and said out loud for the same reason.
                RMRenderLog.pageError(
                    "\(channel): attachment failed to download — its image is a hole"
                )
            }
        }
        // Counted rather than inferred from the lines above: an attachment the
        // index never listed at all is named nowhere else, and it leaves the
        // same hole as one that was refused or failed to arrive.
        if assets.count != wanted.count {
            RMRenderLog.pageError(
                """
                \(channel): \(wanted.count - assets.count) of \
                \(wanted.count) attachments did not arrive
                """
            )
        }
        return assets
    }
}
