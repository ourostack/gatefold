import CoreTransferable
import OuroHX
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An unzipped EPUB: how Apple Books keeps the books its owner added, on a Mac. Declared in Info.plist.
    static let epubFolder = UTType(importedAs: "org.idpf.epub-folder", conformingTo: .package)
    /// What Files, the share sheet and a drop may hand Gatefold. A folder stands for the books inside it.
    static let bookTypes: [UTType] = [.epub, .epubFolder, .folder]
}

/// A book dropped on the shelf. The system's copy goes away when the drop ends, so it is kept in a
/// folder of its own under tmp until the import has taken it.
struct IncomingBook: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .epub) { IncomingBook(url: try keep($0.file)) }
        FileRepresentation(importedContentType: .epubFolder) { IncomingBook(url: try keep($0.file)) }
    }

    static func keep(_ file: URL) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "Incoming/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }
}

/// What the shelf says once books have come in: a toast, with Read when it was one book.
struct ArrivalWords: Equatable {
    var message: String
    var description: String?
    /// The one book that came in, to open from the toast.
    var bookID: String?

    init?(_ result: LibraryStore.ImportResult) {
        let added = result.added.count, here = result.alreadyHere.count
        guard added + here > 0 else { return nil }
        if let book = result.single {
            bookID = book.id
            if result.linkedToCloud == 1 {
                message = "“\(book.title)” is on this \(Self.device) now"
                description = "Your place still syncs with your e-reader."
            } else if added == 1 {
                message = "“\(book.title)” is on your shelf"
            } else {
                message = "“\(book.title)” was already on your shelf"
            }
            return
        }
        message = added == 0 ? "Those books were already on your shelf" : (added == 1 ? "1 book added" : "\(added) books added")
        if added > 0, here > 0 { description = here == 1 ? "1 was already here." : "\(here) were already here." }
    }

    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

/// How to bring books over from Apple Books, as far as Apple allows: there is no way in for another app,
/// so this says honestly what a person can do and what stays behind.
struct AppleBooksGuide: View {
    var onChooseFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Books you added to Apple Books yourself, without DRM, can come along. Books bought in Apple's Book Store stay in Apple Books: they're locked so only it can open them.")
                .font(.subheadline)
                .foregroundStyle(Color.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            OuroItemGroup("On a Mac", variant: .outline) {
                OuroItem("Drag the book out of Books", description: "Open Books, then drag the book from your library into iCloud Drive in a Finder window.", systemImage: "laptopcomputer")
                OuroItem("Pick it here", description: "Tap Choose from Files below and find it in iCloud Drive.", systemImage: "folder")
            }
            OuroItemGroup("Still have the file?", variant: .outline) {
                OuroItem("Open it in Gatefold", description: "From Mail, Safari, Files or wherever you got it, tap Share, then Gatefold.", systemImage: "square.and.arrow.up")
            }
            OuroButton("Choose from Files", systemImage: "folder", size: .lg, fullWidth: true, action: onChooseFiles)
                .accessibilityIdentifier("appleBooks.chooseFiles")
        }
        .accessibilityIdentifier("appleBooks.guide")
    }
}
