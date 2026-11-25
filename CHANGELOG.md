# Changelog

## 1.2.1 — 2026-11-24

### Fixed

- **Dotted pages no longer grow unless you ask.** Until now every dotted page was treated as an infinite canvas. If Xournal++'s default page template is dotted, a new notebook already opened growing. Now a dotted page grows only after you mark it with <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd>, the same as lined pages. The plugin never changes the page template itself.
  - Canvases created by version 1.0, which have no mark, keep growing. They are recognised because they don't have a standard sheet size (A5, A4, A3, Letter, Legal, Tabloid). A dotted A4 page from a template is left alone.
  - <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd> on a marked dotted canvas now unmarks it, keeping its size and dots. Before, it did nothing.

### Changed

- `autoGrowDotted` now defaults to `false`. Set it to `true` for the old behaviour, where every dotted page grows.

### Testing

- `test_mark_paper_pages.lua` covers three new cases:
  - a dotted A4 template page in a fresh session, which must not grow;
  - an unmarked 1200 × 1600 canvas from 1.0, which keeps growing;
  - unmarking and re-marking a dotted canvas.
- All 8 test files pass.

## 1.2.0 — 2026-11-24

### Added

- **Growing PDF pages.** <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd> on a page with a PDF background no longer refuses. It marks the page to grow by itself, and pressing it again removes the mark. The PDF itself is never changed, stretched or cropped.
  - The area added beside or below the PDF is painted on a layer of its own at the bottom of the page, named **"PDF extension"** ("Extensão do PDF" in Portuguese). Your own layers stay above it and the layer you were writing on stays selected.
  - The extension is **blank (white)** by default. It can be switched to **lined** (same lines as Xournal++'s lined paper: 24 pt spacing, 60 pt footer) or **dotted** (same grid as the dotted canvas) with three new items in the Plugin menu. The choice is kept for the page and used for PDF pages extended later in the same session.
  - A marked PDF page grows in paper-like steps: 200 pt to the right, 240 pt downwards, when a stroke gets within 8 pt of the edge. Writing that was already on the page doesn't make it grow.
  - The mark, the style and the original PDF size are stored in the extension layer itself, so everything survives saving and reopening the `.xopp` file. The layer is printed and exported like any other layer, so the extension is white (or lined/dotted) in exported PDFs too.
- New option `pdfExtensionStyle` (`"blank"`, `"lined"` or `"dotted"`).
- `tests/test_pdf_extension.lua` and `tests/test_pdf_edge_cases.lua`.

### Changed

- **Fit page to content** on PDF pages shrinks the page to the content but never below the PDF's own size, and redraws the extension layer for the new size. When nothing is left outside the PDF, the layer is removed (unless the page is marked). On a PDF page with nothing written, fit goes back to the PDF's size.
- Manual expand (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd> / <kbd>M</kbd>) on a PDF page now paints the new area instead of leaving it grey.
- Fit and auto-grow ignore the extension layer when measuring the content.
- `autoGrowPdfPages` now means "grow every PDF page, marked or not".

### Fixed

- The area added to a PDF page was left unpainted (grey).
- Choosing the extension style the page already has no longer redraws it. Switching styles many times never stacks extension layers.
- The page is repainted after every change to the extension. Without this Xournal++ showed the new area grey, or only partly drawn, until you wrote over it.

### Testing

- Automated: 8 test files in `tests/`, all passing. New ones cover:
  - marking and unmarking PDF pages;
  - growing to the right and downwards;
  - the three styles: lines above the footer, dots only inside the new area, nothing drawn on a strip narrower than 0.5 pt;
  - repeating the same style and alternating styles, with no stacked layers;
  - files from the first test build;
  - documents with several layers: the extension goes to the bottom, the user's layer stays selected, and content on every layer counts for fit;
  - landscape PDFs and empty PDF pages;
  - a white rectangle drawn by the user, which is not mistaken for the extension;
  - the style items on pages without a PDF.
- Manual, on Windows 11 with Xournal++ 1.3.4: on a PDF page, marking it, auto-grow, and the three styles. Found and fixed during that test: the tinted colour, missing repaint and stacked redraws.
- Not tested yet: Linux and macOS; undo/redo across many extension redraws.

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
