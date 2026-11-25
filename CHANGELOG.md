# Changelog

## 1.1.0 — 2026-11-24

### Added

- **Growing lined and other paper pages.** <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd> on a lined, ruled, graph or staves page no longer turns it into a dotted canvas. It keeps the paper (lines, margin, size) and marks the page to grow by itself; pressing it again removes the mark.
  - The mark is `icanvas=1` in the page's background config. Xournal++ saves it in the `.xopp` file and ignores keys it doesn't know, so the paper looks exactly the same and the page keeps growing after the file is reopened.
  - A marked paper page grows **downwards only when you start writing in the bottom margin, below the last line**. Writing on the last line, including descenders such as *g* or *ç*, does not trigger it. The plugin compares each new stroke's vertical centre with the last line.
  - It grows by 10 lines at a time (`paperGrowLines`), always ending on a whole line followed by the paper's footer.
  - It grows **to the right** by 200 pt (`paperGrowX`) only when a stroke gets within 8 pt of the right edge (`paperEdgeMargin`).
  - Only strokes written after the page was marked count. Writing that was already on the page never makes it grow, and a click without drawing doesn't either.
- `tests/`: automated tests that run with plain Lua 5.4 against a mocked Xournal++ API (`sh tests/run_all.sh`).

### Changed

- **Fit page to content** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>J</kbd>) was rewritten.
  - **Height:** the page ends 40 pt below the last stroke (`fitPadding`, was 300 pt). The old minimum of 800 pt is gone, so a page that was expanded downwards can now shrink back.
  - **Lined/ruled paper:** the page ends one free line below the last stroke, followed by the full 60 pt footer, instead of cutting through the footer. Custom line spacing (`r1`) is respected.
  - **Width of a dotted canvas:** trimmed to the content, as before.
  - **Width of paper pages:** follows the page's paper instead of being recalculated as "content + 300 pt", which used to widen pages that already had the right width. The width is chosen in this order:
    1. the page's original width, if the plugin resized it during this session;
    2. the current width, if it already is a paper width (A5, A4, A3, Letter, Legal or Tabloid, portrait or landscape);
    3. the smallest paper width that holds the content, taken from the other pages of the document and the page template in Xournal++'s settings (both orientations), and otherwise from the standard sizes.

    A page whose content already fits is never widened. US Letter pages stay Letter.
  - Fit on an empty page does nothing (it used to reset the page to 1200 × 1600 pt).
- Manual expand (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd> / <kbd>M</kbd>) uses the paper-sized steps on paper pages. Downward expansion on lined paper is aligned to the lines.
- Page sizes keep two decimals (595.28 pt instead of 595 pt), and a dimension that doesn't change is left untouched.
- `onlyDottedPages` was replaced by `autoGrowDotted`. `minWidth` and `minHeight` are now 300 and 200 pt.

### Fixed

- Fit page to content widened lined pages that already had the correct width.
- Fit page to content left the page ending inside the footer of lined paper.
- Marking a page whose existing writing touched its edges made it grow immediately, by 800 pt in each direction.
- Writing on the last line of a marked lined page made it grow on every stroke.

### Testing

- Automated: 6 test files in `tests/` covering dotted canvases, language detection, PDF pages, fit on lined/plain/dotted pages, paper-width selection (A4, Letter, landscape template, custom narrow pages), marking/unmarking, existing writing near the edges, descenders on the last line, writing in the bottom margin and right-edge growth.
- Manual, on Windows 11 with Xournal++ 1.3.4:
  - fit on a two-page lined A4 document (the already-fitted page stayed the same, the other page was fitted);
  - marking a lined page;
  - writing on the last line (no growth), writing in the bottom margin (growth).
- Not tested yet: Linux and macOS.

## 1.0.0 — 2026-11-18

First release. A plain page becomes a dotted canvas that grows to the right and downwards on pen-up, using a capture-phase `GtkGestureDrag` through LuaGObject. Includes fit page to content, manual expand actions, a toggle for auto-grow, zoom preservation, PDF-page protection and English/Portuguese UI.
