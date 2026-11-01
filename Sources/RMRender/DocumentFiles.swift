// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// One file a document is made of, as a renderer needs to see it.
///
/// Not the cloud's index entry, and that is the point: an index belongs to the
/// protocol — it has a schema version, a type field, a subfile count and a
/// generation to lose a race to. A renderer needs three facts and no more,
/// and asking for them by a type of its own is what keeps drawing free of the
/// protocol. The caller maps one onto the other, in about a dozen lines.
public struct DocumentFile: Sendable, Hashable {
    /// The blob's SHA-256 — its address in the content-addressed storage.
    public let hash: String
    /// The name the bytes are asked for under. It carries the path inside the
    /// document — `"<uuid>/<page>.rm"` — and the fetch uses it as given.
    public let name: String
    /// What the index says the file weighs, for a progress bar drawn before a
    /// byte has arrived.
    public let size: Int64

    public init(hash: String, name: String, size: Int64) {
        self.hash = hash
        self.name = name
        self.size = size
    }

    /// The last component of the name: `"<uuid>/<page>.rm"` → `"<page>.rm"`.
    public var fileName: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// The extension of that name, empty when it has none. Taken from the
    /// last component on purpose: a dot in a folder's name is not ours.
    public var fileExtension: String {
        let name = fileName
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// The last component without its extension — a page's own UUID, which is
    /// what `.content` names its pages by.
    public var fileBaseName: String {
        let name = fileName
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }
}

/// The files of one document.
public struct DocumentFiles: Sendable, Hashable {
    public let files: [DocumentFile]

    public init(files: [DocumentFile]) {
        self.files = files
    }

    /// The first file with that extension — `.content`, `.pagedata`.
    public func file(withExtension ext: String) -> DocumentFile? {
        files.first { $0.fileExtension == ext }
    }
}
