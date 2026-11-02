import GatefoldCore
import Foundation

/// JavaScript run in the book's web view. Readium's own first-visible locator returns a whole block
/// element, whose start is often on the previous page (the drift in Readium #645). These helpers find
/// the first *character* on screen instead, and the text that's visible, so the anchor is exact.
enum ReaderJS {
    static let install = #"""
    (function () {
      if (window.gatefold) { return true; }
      const norm = (s) => (s || "").replace(/\s+/g, " ").trim();
      function caret(x, y) {
        const r = document.caretRangeFromPoint(x, y);
        if (!r || !r.startContainer || r.startContainer.nodeType !== Node.TEXT_NODE) { return null; }
        if (!norm(r.startContainer.textContent)) { return null; }
        // A picture's caption floats with the picture, which a reflow can push to a later page:
        // the place is the running text.
        const el = r.startContainer.parentElement;
        if (el && el.closest("figure, figcaption, .caption, .figcenter, .figleft, .figright, .pagenum")) { return null; }
        return r;
      }
      // Scan a column from its top-left for the first character.
      function first(x0, x1) {
        const h = window.innerHeight;
        for (let y = 6; y < h - 6; y += 10) {
          for (let x = x0 + 4; x < x1 - 4; x += 14) {
            const r = caret(x, y);
            if (r) { return r; }
          }
        }
        return null;
      }
      // And from the bottom-right for the last.
      function last(x0, x1) {
        const h = window.innerHeight;
        for (let y = h - 6; y > 6; y -= 10) {
          for (let x = x1 - 4; x > x0 + 4; x -= 14) {
            const r = caret(x, y);
            if (r) { return r; }
          }
        }
        return null;
      }
      // The last heading at or before a node: the chapter the reader is actually in.
      function headingBefore(node) {
        let found = null;
        for (const h of document.querySelectorAll("h1,h2,h3,h4")) {
          if (h.contains(node) || (h.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING)) { found = h; } else { break; }
        }
        // Illustrated editions put the picture's caption inside the heading; keep only the heading's own words.
        let t = "";
        if (found) {
          const copy = found.cloneNode(true);
          copy.querySelectorAll(".caption, figcaption, img, svg, sup, .pagenum").forEach(function (e) { e.remove(); });
          t = norm(copy.textContent);
        }
        return t && t.length <= 80 ? t : null;
      }
      // Of the contents' anchors (element ids) in this file, the last one at or above `node`.
      function contentsBefore(node, ids) {
        let found = null;
        for (const id of ids || []) {
          const el = document.getElementById(id);
          if (!el) { continue; }
          const above = el.contains(node) || (el.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING);
          if (above && (!found || (found.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING))) { found = el; }
        }
        return found ? found.id : null;
      }
      window.gatefold = {
        // The first visible words of the column starting at fraction `fx` of the viewport, and the
        // contents anchor (of `ids`) above them.
        anchor: function (fx, ids) {
          const w = window.innerWidth;
          const two = window.gatefoldColumns === 2;
          const r = fx ? first(w / 2, w) : first(0, two ? w / 2 : w);
          if (!r) { return null; }
          const node = r.startContainer, text = node.textContent;
          let start = r.startOffset;
          while (start > 0 && !/\s/.test(text[start - 1])) { start--; }
          const highlight = text.substr(start, 64);
          if (!norm(highlight)) { return null; }
          return { highlight: highlight, before: text.substr(Math.max(0, start - 32), Math.min(32, start)), heading: headingBefore(node), contents: contentsBefore(node, ids) };
        },
        // Where the page ends in the resource, as a progression (paginated and scrolled).
        pageEnd: function () {
          const se = document.scrollingElement;
          if (se.scrollWidth > window.innerWidth + 1) { return Math.min(1, (se.scrollLeft + window.innerWidth) / se.scrollWidth); }
          if (se.scrollHeight > window.innerHeight + 1) { return Math.min(1, (se.scrollTop + window.innerHeight) / se.scrollHeight); }
          return 1;
        },
        // Where words are in this resource, as the progression that puts their page on screen
        // (paginated). Whitespace may differ from the book file's, so words match across any run of it.
        progressionOf: function (quote) {
          const words = norm(quote).split(" ").slice(0, 8).map(function (w) { return w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); });
          if (!words.length || !words[0]) { return null; }
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nodes = []; let text = "";
          while (walker.nextNode()) { nodes.push([walker.currentNode, text.length]); text += walker.currentNode.data; }
          const m = new RegExp(words.join("\\s+")).exec(text);
          if (!m) { return null; }
          for (const [node, start] of nodes) {
            if (start + node.data.length <= m.index) { continue; }
            const range = document.createRange();
            const offset = m.index - start;
            range.setStart(node, offset);
            range.setEnd(node, Math.min(node.data.length, offset + 1));
            const se = document.scrollingElement, rect = range.getBoundingClientRect();
            if (se.scrollWidth <= window.innerWidth + 1) { return Math.max(0, Math.min(1, (rect.top + se.scrollTop) / se.scrollHeight)); }
            return Math.max(0, Math.min(1, (rect.left + se.scrollLeft) / se.scrollWidth));
          }
          return null;
        },
        // All the text on screen, whitespace collapsed.
        visibleText: function () {
          const w = window.innerWidth;
          const a = first(0, w), b = last(0, w);
          if (!a || !b) { return null; }
          const range = document.createRange();
          try {
            range.setStart(a.startContainer, a.startOffset);
            range.setEnd(b.startContainer, b.startOffset);
          } catch (e) { return null; }
          const text = norm(range.toString());
          return text ? text : null;
        },
      };
      return true;
    })();
    """#

    static func anchor(column: Int, contentsAnchors: [String] = []) -> String {
        let ids = (try? JSONEncoder().encode(contentsAnchors)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "JSON.stringify(window.gatefold ? window.gatefold.anchor(\(column == 1 ? "0.5" : "0"), \(ids)) : null)"
    }

    static let visibleText = "window.gatefold ? window.gatefold.visibleText() : null"

    static func progressionOf(_ quote: String) -> String {
        let q = (try? JSONEncoder().encode(quote)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "window.gatefold ? window.gatefold.progressionOf(\(q)) : null"
    }

    static let pageEnd = "window.gatefold ? window.gatefold.pageEnd() : null"

    static func setColumns(_ n: Int) -> String { "window.gatefoldColumns = \(n); true" }

    /// "CHAPTER XIX." reads as "Chapter XIX": shouting headings are softened, numerals kept.
    static func tidyHeading(_ s: String) -> String { Headings.tidy(s) }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
