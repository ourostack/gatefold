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
      // Two pages on screen. The reader sets the count where it lays a page out, but a chapter's own web
      // view (a turn or jump into it) can run before it has: then the layout says, from its columns.
      function twoPages() {
        if (window.gatefoldColumns) { return window.gatefoldColumns === 2; }
        const cs = getComputedStyle(document.documentElement);
        const count = parseInt(cs.columnCount, 10), width = parseFloat(cs.columnWidth);
        // Readium sets the count (1 or 2); a width alone counts only when the count is left to it.
        if (!isNaN(count)) { return count === 2; }
        return width > 0 && width <= window.innerWidth / 2 + 1;
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
          const two = twoPages();
          const r = fx ? first(w / 2, w) : first(0, two ? w / 2 : w);
          if (!r) { return null; }
          const node = r.startContainer, text = node.textContent;
          let start = r.startOffset;
          while (start > 0 && !/\s/.test(text[start - 1])) { start--; }
          // A word hyphenated across the page turn ("her Lady-" | "ship would"): its start is on the
          // page before, and a place there reopens a page early. The place is the page's first whole word.
          if (start < r.startOffset) {
            const x0 = fx ? w / 2 : 0;
            const head = document.createRange();
            head.setStart(node, start);
            head.setEnd(node, start + 1);
            const at = head.getBoundingClientRect();
            if (at.right <= x0 + 1 || at.bottom <= 0) {
              let next = r.startOffset;
              while (next < text.length && !/\s/.test(text[next])) { next++; }
              while (next < text.length && /\s/.test(text[next])) { next++; }
              start = next < text.length ? next : r.startOffset;
            }
          }
          let highlight = text.substr(start, 64);
          // The page's words run on past this text node (a quotation mark before "<i>Plover</i>"): a
          // mark alone matches the chapter's first quotation, pages back. Take the words that follow,
          // within his paragraph: the next one's words would be glued on ("bank.Marrow").
          if (highlight.length < 64) {
            const blockOf = (n) => {
              let e = n.parentElement;
              while (e && e !== document.body && getComputedStyle(e).display.startsWith('inline')) { e = e.parentElement; }
              return e;
            };
            const block = blockOf(node);
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            walker.currentNode = node;
            while (highlight.length < 64 && walker.nextNode()) {
              if (blockOf(walker.currentNode) !== block) { break; }
              highlight += walker.currentNode.data;
            }
            highlight = highlight.substr(0, 64);
          }
          if (!norm(highlight)) { return null; }
          return { highlight: highlight, before: text.substr(Math.max(0, start - 32), Math.min(32, start)), heading: headingBefore(node), contents: contentsBefore(node, ids) };
        },
        // The page on screen as one read of the web view, for a jump's landing (`JumpLanding`): where it
        // starts and ends in its document, as progressions, and which document that is. The start sits
        // two pixels early: Readium adds a pixel before rounding a jump down to its page, so a place
        // within a pixel of a page's end opens the next page. Right-to-left scrolls
        // count from the right, so the offset is taken whole. Null until the document has loaded.
        pageRange: function () {
          if (document.readyState !== "complete") { return null; }
          const se = document.scrollingElement;
          var s = 0, e = 1;
          if (se.scrollWidth > window.innerWidth + 1) {
            const l = Math.abs(se.scrollLeft);
            s = Math.max(0, (l - 2) / se.scrollWidth); e = Math.min(1, (l + window.innerWidth) / se.scrollWidth);
          } else if (se.scrollHeight > window.innerHeight + 1) {
            const t = se.scrollTop;
            s = Math.max(0, (t - 2) / se.scrollHeight); e = Math.min(1, (t + window.innerHeight) / se.scrollHeight);
          }
          return JSON.stringify({ s: s, e: e, doc: location.pathname });
        },
        // Where the page ends in the resource, as a progression (paginated and scrolled).
        pageEnd: function () {
          const se = document.scrollingElement;
          if (se.scrollWidth > window.innerWidth + 1) { return Math.min(1, (se.scrollLeft + window.innerWidth) / se.scrollWidth); }
          if (se.scrollHeight > window.innerHeight + 1) { return Math.min(1, (se.scrollTop + window.innerHeight) / se.scrollHeight); }
          return 1;
        },
        // The chapter's columns and the screen's place in them, for page numbers (`ScreenPageGeometry`).
        geometry: function () {
          const se = document.scrollingElement;
          return JSON.stringify({ w: se.scrollWidth, l: se.scrollLeft, v: window.innerWidth,
            verso: !!document.getElementById("gatefold-verso"), pinned: !!document.getElementById("gatefold-pin"),
            // Which chapter these columns are: the navigator's location can move on before its web view does.
            doc: location.pathname });
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
        // Where the element `id` (or old-style `name`) starts in this resource, as the progression that
        // puts its page on screen (paginated). Null until the resource has loaded and is laid out in
        // columns (a long file still one screen wide would give a place in the wrong layout); -1 once it
        // is, and there is no such element.
        progressionOfId: function (id) {
          if (document.readyState !== "complete") { return null; }
          const se = document.scrollingElement;
          const columns = se.scrollWidth > window.innerWidth + 1;
          if (!columns && se.scrollHeight > window.innerHeight + 1) { return null; }
          const el = document.getElementById(id) || document.getElementsByName(id)[0];
          if (!el) { return -1; }
          // Not in columns: only an element on the first screen is at the file's start. One past it is a
          // file not laid out yet (CI, run 42852464361: a jump took 0 for an anchor 0.79 into its file).
          if (!columns) {
            const r = el.getBoundingClientRect();
            const onScreen = r.width + r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < window.innerWidth && r.top < window.innerHeight;
            return onScreen ? 0 : null;
          }
          const rect = el.getBoundingClientRect();
          return Math.max(0, Math.min(1, (rect.left + Math.abs(se.scrollLeft)) / se.scrollWidth));
        },
        // Which page of the spread `quote` starts on: 0 left, 1 right, -1 before the spread, 2 after it.
        sideOf: function (quote) {
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
            const left = range.getBoundingClientRect().left, w = window.innerWidth;
            if (left < 0) { return -1; }
            if (left >= w) { return 2; }
            return left >= w / 2 ? 1 : 0;
          }
          return null;
        },
        // A blank verso before the file's first page, which moves every page one side over, so a
        // spread can keep the reader's sentence on its left page. Returns 1 when the verso is in.
        toggleVerso: function () {
          const old = document.getElementById("gatefold-verso");
          if (old) { old.remove(); return 0; }
          const d = document.createElement("div");
          d.id = "gatefold-verso";
          d.setAttribute("aria-hidden", "true");
          d.style.cssText = "height:1px;margin:0;padding:0;break-after:column;-webkit-column-break-after:always;";
          document.body.insertBefore(d, document.body.firstChild);
          return 1;
        },
        removeVerso: function () {
          let removed = 0;
          const old = document.getElementById("gatefold-verso");
          if (old) { old.remove(); removed = 1; }
          const pin = document.getElementById("gatefold-pin");
          if (pin) { const parent = pin.parentNode; pin.remove(); if (parent) { parent.normalize(); } removed = 1; }
          return removed;
        },
        // Starts a new column at `quote`, so on an unfold the reader's words open the left page instead
        // of sitting halfway down it. Only when they would be more than two lines down. Returns 1 when
        // a break went in.
        pinToTop: function (quote) {
          if (document.getElementById("gatefold-pin")) { return 0; }
          const words = norm(quote).split(" ").slice(0, 8).map(function (w) { return w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); });
          if (!words.length || !words[0]) { return null; }
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nodes = []; let text = "";
          while (walker.nextNode()) { nodes.push([walker.currentNode, text.length]); text += walker.currentNode.data; }
          const m = new RegExp(words.join("\\s+")).exec(text);
          if (!m) { return null; }
          for (const [node, start] of nodes) {
            if (start + node.data.length <= m.index) { continue; }
            const offset = m.index - start;
            const range = document.createRange();
            range.setStart(node, offset);
            range.setEnd(node, Math.min(node.data.length, offset + 1));
            const rect = range.getBoundingClientRect();
            const w = window.innerWidth;
            if (rect.left < 0 || rect.left >= w) { return 0; }
            // The column's own first line, whatever the page's top margin (the folded Duo clears its camera).
            const x0 = rect.left >= w / 2 ? w / 2 : 0;
            const head = first(x0, x0 + w / 2);
            if (!head) { return 0; }
            const top = head.getBoundingClientRect().top;
            const line = parseFloat(getComputedStyle(node.parentElement || document.body).lineHeight) || 24;
            if (rect.top - top <= line * 2.2) { return 0; }
            const rest = offset > 0 ? node.splitText(offset) : node;
            const pin = document.createElement("span");
            pin.id = "gatefold-pin";
            pin.setAttribute("aria-hidden", "true");
            pin.style.cssText = "display:block;height:0;margin:0;padding:0;break-before:column;-webkit-column-break-before:always;";
            rest.parentNode.insertBefore(pin, rest);
            return 1;
          }
          return null;
        },
        // How many pages the script reads the screen as.
        pages: function () { return twoPages() ? 2 : 1; },
        // UI tests (gatefold#303): how many columns of text are on screen, from the laid-out lines themselves.
        // A line that crosses the middle is one column; lines on both sides with none across are two.
        columns: function () {
          const w = window.innerWidth, h = window.innerHeight, mid = w / 2;
          let left = 0, right = 0, across = 0;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!norm(node.data)) { continue; }
            range.selectNodeContents(node);
            for (const r of range.getClientRects()) {
              if (r.width < 1 || r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) { continue; }
              if (r.left < mid - 8 && r.right > mid + 8) { across += 1; } else if (r.left >= mid - 8) { right += 1; } else { left += 1; }
            }
          }
          const css = parseInt(getComputedStyle(document.documentElement).columnCount, 10);
          const shown = across > 0 ? 1 : (left > 0 && right > 0 ? 2 : (left + right > 0 ? 1 : 0));
          return "columns " + shown + " css " + (isNaN(css) ? "auto" : css) + " lines " + across + "/" + left + "/" + right + " view " + Math.round(w);
        },
        // All the text on screen, whitespace collapsed. A spread is read page by page: from the left
        // page's first words to the right page's last. Scanned across both pages at once, a left page
        // opening with a picture (whose caption is never a place) started at the right page's first
        // line, and his words on the left page read as off screen (Real unfold, #58).
        visibleText: function () {
          const w = window.innerWidth;
          const two = twoPages();
          const a = two ? (first(0, w / 2) || first(w / 2, w)) : first(0, w);
          const b = two ? (last(w / 2, w) || last(0, w / 2)) : last(0, w);
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
    static let columns = "window.gatefold ? window.gatefold.columns() : null"

    static func progressionOf(_ quote: String) -> String {
        let q = (try? JSONEncoder().encode(quote)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "window.gatefold ? window.gatefold.progressionOf(\(q)) : null"
    }

    static func progressionOfId(_ id: String) -> String {
        let q = (try? JSONEncoder().encode(id)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "window.gatefold ? window.gatefold.progressionOfId(\(q)) : null"
    }

    static let pageEnd = "window.gatefold ? window.gatefold.pageEnd() : null"
    static let pageRange = "window.gatefold ? window.gatefold.pageRange() : null"
    static let geometry = "window.gatefold ? window.gatefold.geometry() : null"

    static func sideOf(_ quote: String) -> String {
        let q = (try? JSONEncoder().encode(quote)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "window.gatefold ? window.gatefold.sideOf(\(q)) : null"
    }

    static let toggleVerso = "window.gatefold ? window.gatefold.toggleVerso() : null"

    static func pinToTop(_ quote: String) -> String {
        let q = (try? JSONEncoder().encode(quote)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "window.gatefold ? window.gatefold.pinToTop(\(q)) : null"
    }
    static let removeVerso = "window.gatefold ? window.gatefold.removeVerso() : null"

    static func setColumns(_ n: Int) -> String { "window.gatefoldColumns = \(n); true" }

    /// "CHAPTER XIX." reads as "Chapter XIX": shouting headings are softened, numerals kept.
    static func tidyHeading(_ s: String) -> String { Headings.tidy(s) }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
