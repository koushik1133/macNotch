import AppKit
import Foundation
import UniformTypeIdentifiers

/// Drawer geometry for the file-drop strip (the drawer's content area on the
/// default 540×115 drawer: 540 + 2×16 flare − 2×(16 + 16) padding = 508 wide,
/// 115 − 38 header − 8 bottom padding = 69 tall).
enum FileDropLayout {
    static let stripSize = CGSize(width: 508, height: 69)
    /// The floating shelf that appears under the closed notch (or at the
    /// pointer, after a shake) during a drag.
    static let zoneSize = CGSize(width: 444, height: 76)
    /// Gap between the pointer and the shelf summoned at it.
    static let pointerGap: CGFloat = 26
    /// Gap between the hardware notch and the shelf.
    static let zoneGap: CGFloat = 6
    /// The pointer must be this close to the notch (horizontally from the
    /// screen's mid-line, vertically from the top edge) for the shelf to show.
    static let proximity = CGSize(width: 320, height: 230)
}

/// One dropped file.
struct FileDropItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var url: URL
    var size: Int64
    var kind: FileDropKind
    /// True for files SparkV staged itself (dropped image data, text), which
    /// have no folder of their own the user would recognise.
    var isStaged: Bool

    init(url: URL, isStaged: Bool = false) {
        id = UUID()
        self.url = url
        size = FileDropOps.fileSize(url)
        kind = FileDropKind(url)
        self.isStaged = isStaged
    }

    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension }
}

enum FileDropKind: String, Sendable, Equatable {
    case image, pdf, document, folder, other

    init(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
           (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true {
            self = .folder
            return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
            ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type else { self = .other; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .html)
                    || ["docx", "doc", "odt", "pages", "md", "markdown", "csv", "tsv", "xlsx", "pptx", "key", "numbers", "rtfd", "json"]
                        .contains(url.pathExtension.lowercased()) {
            self = .document
        } else { self = .other }
    }
}

/// Every action the strip offers, in strip order.
enum FileDropAction: String, CaseIterable, Identifiable, Sendable {
    case rename, compress, convert, space, airDrop, tray, reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rename: "Rename"
        case .compress: "Compress"
        case .convert: "Convert"
        case .space: "Space"
        case .airDrop: "AirDrop"
        case .tray: "Tray"
        case .reveal: "Reveal"
        }
    }

    var systemImage: String {
        switch self {
        case .rename: "character.cursor.ibeam"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.triangle.2.circlepath"
        case .space: "square.stack.3d.up.fill"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .tray: "tray.and.arrow.down.fill"
        case .reveal: "folder"
        }
    }

    var help: String {
        switch self {
        case .rename: "Rename: on-device AI suggests a name from the content"
        case .compress: "Compress: smaller images and PDFs, a .zip for everything else"
        case .convert: "Convert: open in the converter to pick a format"
        case .space: "Send to a Space (or let the agents file it)"
        case .airDrop: "Send with AirDrop"
        case .tray: "Keep in the Tray"
        case .reveal: "Show in Finder"
        }
    }
}

/// What dropping on one of the shelf's buckets does right away
/// (Dropover-style "instant actions").
enum FileDropInstant: String, CaseIterable, Identifiable, Sendable {
    /// Keep the files and open the action strip.
    case actions
    /// Keep them on the Tray (the drawer stays closed).
    case tray
    case compress
    /// Let the Spaces agents file it.
    case space
    case airDrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actions: "Actions"
        case .tray: "Tray"
        case .compress: "Compress"
        case .space: "To Space"
        case .airDrop: "AirDrop"
        }
    }

    var systemImage: String {
        switch self {
        case .actions: "bolt.fill"
        case .tray: FileDropAction.tray.systemImage
        case .compress: FileDropAction.compress.systemImage
        case .space: FileDropAction.space.systemImage
        case .airDrop: FileDropAction.airDrop.systemImage
        }
    }
}

/// How a finished action can be taken back.
enum FileDropUndo: Equatable, Sendable {
    /// Files renamed in place: move each `to` back to `from`.
    case renamed([FileDropRename])
    /// New files SparkV wrote (compressed copies, archives): Undo moves them
    /// to the Trash. The originals were never touched.
    case created([URL])
}

struct FileDropRename: Equatable, Sendable {
    let itemID: UUID
    let from: URL
    let to: URL
}

/// A finished action, shown in the strip with draggable outputs.
struct FileDropResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    var action: FileDropAction
    var headline: String
    var detail: String
    /// Files to drag out / reveal (renamed files, compressed copies…).
    var outputs: [URL]
    var undo: FileDropUndo?
    /// Compress made per-file copies of media: offer a single .zip instead.
    var offersZip = false
}

/// What the strip shows.
enum FileDropMode: Equatable, Sendable {
    /// Nothing dropped yet.
    case empty
    /// Files staged; the action row.
    case actions
    /// Rename editor for `items[index]`.
    case renaming(index: Int)
    /// Space chips.
    case pickingSpace
    /// An action is running.
    case working(String)
    case done(FileDropResult)
}

/// A one-line note in the strip (errors, "already small"…).
struct FileDropNote: Equatable, Sendable {
    enum Tone: Sendable { case info, warning }
    var text: String
    var tone: Tone
}

/// Per-item rename state while the rename editor is open.
struct FileDropRenameDraft: Equatable, Sendable {
    var suggestion: String?
    /// Where the suggestion came from ("On-device AI", "From the text"…).
    var source: String?
    var isSuggesting: Bool
}

/// User preferences (UserDefaults, read by the controller).
enum FileDropSettings {
    static let enabledKey = "fileDrop.enabled"
    static let nameStyleKey = "fileDrop.nameStyle"
    static let zoneKey = "fileDrop.showShelf"

    enum NameStyle: String, CaseIterable, Identifiable, Sendable {
        /// "Acme Invoice 4411 2024-03-12"
        case words
        /// "acme-invoice-4411-2024-03-12"
        case kebab
        /// "Acme_Invoice_4411_2024-03-12"
        case snake

        var id: String { rawValue }
        var title: String {
            switch self {
            case .words: "Words with spaces"
            case .kebab: "kebab-case"
            case .snake: "Snake_Case"
            }
        }
    }
}
