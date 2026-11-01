// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Where a renderer gets the bytes of a document's files.
///
/// A document renderer never holds a network client or a blob cache and
/// fetches for itself: that would tie drawing to the protocol and to the
/// local index — two layers a package about ink has no business knowing, and
/// the one thing that would keep this package from standing on its own. What
/// is left is the only question a renderer actually asks: *give me the bytes
/// of this file*. Where they come from — the network, a cache, a folder of
/// fixtures — belongs to whoever calls.
public protocol PageBlobs: Sendable {
    /// A small file of the document: a page, `.content`, an attachment.
    ///
    /// - Parameters:
    ///   - hash: the blob's SHA-256, which is its address in the storage.
    ///   - name: the name the bytes are asked for under.
    ///   - owner: the document the bytes belong to, when the caller keeps a
    ///     cache that has to know whose they are; `nil` when nothing is kept.
    func data(hash: String, name: String, owner: String?) async throws -> Data

    /// The same, as a file on disk.
    ///
    /// A reader's PDF runs to hundreds of megabytes and the render may run in
    /// a process that is killed for memory, so the big ones are never held in
    /// one piece: `CGDataProvider(url:)` maps the file, and only the pages
    /// actually drawn are paged in.
    func file(
        hash: String,
        name: String,
        owner: String?,
        size: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile
}

/// A file handed to a renderer, and who has to clean it up.
public struct BlobFile: Sendable {
    public let url: URL
    /// `true` when the file is a temporary made for this call: a cached file
    /// belongs to the cache and must outlive the render.
    public let isTemporary: Bool

    public init(url: URL, isTemporary: Bool) {
        self.url = url
        self.isTemporary = isTemporary
    }
}
