import Foundation
import GatefoldCore

/// The app's own code behind each action in actions/gatefold.actions.mts. Set once at launch; every door (a button,
/// Siri, Shortcuts and an agent) calls the same handler.
@MainActor
enum ActionHandlers {
    struct Refused: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func bind(to app: AppModel) {
        ListBooksAction.perform = { input in
            let query = (input.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = app.library.books.filter { book in
                query.isEmpty || book.title.lowercased().contains(query) || book.author.lowercased().contains(query)
            }
            let lines = matches.map { "\($0.title) by \($0.author), \($0.id)" }
            return ListBooksOutput(books: lines.joined(separator: "\n"), count: matches.count)
        }

        OpenBookAction.perform = { input in
            let wanted = input.book.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let book = app.library.books.first(where: { $0.id == wanted || $0.title.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw Refused(message: "No book in the library is called \(wanted).")
            }
            guard book.isOnDevice else {
                throw Refused(message: "\(book.title) isn't on this device yet.")
            }
            guard app.activeReader == nil else {
                throw Refused(message: "Close the book on screen first, then ask again.")
            }
            app.openBookID = book.id
            return OpenBookOutput(summary: "Opening \(book.title).")
        }

        SyncReadingPlaceAction.perform = { _ in
            await app.sendPlaceNow()
            return SyncReadingPlaceOutput(summary: "Sent the reading place.")
        }
    }
}
