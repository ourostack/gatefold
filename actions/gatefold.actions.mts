// What Gatefold does for a person or an agent, declared once. `scripts/ouro-actions.sh generate` writes every door from
// this file into actions/generated: the App Intents and SwiftUI buttons (OuroActions.swift, compiled into the app)
// and the agent doors. CI fails when they drift. Never edit what is generated; change this file and run the script.
import { defineAction, defineActions, field } from "../tools/ouro-actions/ouro-actions.mts";

export const listBooks = defineAction({
  id: "list_books",
  consent: "read",
  label: "List Books",
  description: "See the books in your Gatefold library.",
  agent: "Lists the books in the library with their title, author and whether each is on this device. Changes nothing.",
  input: {
    query: field.string({ label: "Search", description: "Words to match against titles and authors; leave it out to list everything.", optional: true }),
  },
  output: {
    books: field.string({ label: "Books", description: "One line per book: its title, two spaces, then its id. Empty when none match.", returned: true }),
    count: field.integer({ label: "Count", description: "How many books match.", min: 0 }),
  },
  cli: "list",
});

export const openBook = defineAction({
  id: "open_book",
  consent: "write",
  label: "Open Book",
  description: "Open a book in Gatefold at the place you left it.",
  agent: "Opens a book from the library in Gatefold, at the reading place kept for it, so the person sees it. Changes no text. Fails when the book is not on this device.",
  input: {
    book: field.string({ label: "Book", description: "The book: its title as list_books shows it, or its id.", ask: "Which book?" }),
  },
  output: {
    summary: field.string({ label: "Summary", description: "What happened, in a sentence." }),
  },
  opensApp: true,
  cli: "open",
});

export const syncReadingPlace = defineAction({
  id: "sync_reading_place",
  consent: "write",
  label: "Sync Reading Place",
  description: "Send your reading place to your other devices now.",
  agent: "Sends the reading place of every book whose place is still waiting to be sent, now rather than later. Returns when the sending finishes.",
  input: {},
  output: {
    summary: field.string({ label: "Summary", description: "What happened, in a sentence." }),
  },
  cli: "sync",
});

export default defineActions("gatefold", [listBooks, openBook, syncReadingPlace], { tool: "gatefold" });
