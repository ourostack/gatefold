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
        const t = found ? norm(found.textContent) : "";
        return t && t.length <= 80 ? t : null;
      }
      window.gatefold = {
        // The first visible words of the column starting at fraction `fx` of the viewport.
        anchor: function (fx) {
          const w = window.innerWidth;
          const two = window.gatefoldColumns === 2;
          const r = fx ? first(w / 2, w) : first(0, two ? w / 2 : w);
          if (!r) { return null; }
          const node = r.startContainer, text = node.textContent;
          let start = r.startOffset;
          while (start > 0 && !/\s/.test(text[start - 1])) { start--; }
          const highlight = text.substr(start, 64);
          if (!norm(highlight)) { return null; }
          return { highlight: highlight, before: text.substr(Math.max(0, start - 32), Math.min(32, start)), heading: headingBefore(node) };
        },
        // Where the page ends in the resource, as a progression (paginated and scrolled).
        pageEnd: function () {
          const se = document.scrollingElement;
          if (se.scrollWidth > window.innerWidth + 1) { return Math.min(1, (se.scrollLeft + window.innerWidth) / se.scrollWidth); }
          if (se.scrollHeight > window.innerHeight + 1) { return Math.min(1, (se.scrollTop + window.innerHeight) / se.scrollHeight); }
          return 1;
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

    static func anchor(column: Int) -> String {
        "JSON.stringify(window.gatefold ? window.gatefold.anchor(\(column == 1 ? "0.5" : "0")) : null)"
    }

    static let visibleText = "window.gatefold ? window.gatefold.visibleText() : null"

    static let pageEnd = "window.gatefold ? window.gatefold.pageEnd() : null"

    static func setColumns(_ n: Int) -> String { "window.gatefoldColumns = \(n); true" }

    /// "CHAPTER XIX." reads as "Chapter XIX": shouting headings are softened, numerals kept.
    static func tidyHeading(_ s: String) -> String {
        var t = normalize(s)
        while let last = t.last, ".:".contains(last) { t.removeLast() }
        guard t == t.uppercased(), t != t.lowercased() else { return t }
        return t.split(separator: " ").map { word in
            word.allSatisfy { "IVXLCDM".contains($0) } ? String(word) : word.capitalized
        }.joined(separator: " ")
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
