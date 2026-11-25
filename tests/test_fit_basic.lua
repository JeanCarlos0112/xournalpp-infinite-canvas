-- Run from the repository root or anywhere: lua5.4 tests/test_fit_basic.lua
-- Uses a mocked Xournal++ Lua API (no Xournal++ needed).
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
local page = { pageWidth = 700, pageHeight = 2400, pageTypeFormat = "lined", pageTypeConfig = "", pdfBackgroundPageNo = 0,
               currentLayer = 1, layers = { [0] = {}, {} } }
local strokes, texts = {}, {}
app = { getDocumentStructure = function() return { currentPage = 1, pages = { page } } end,
  setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
  getStrokes = function() return strokes end, getTexts = function() return texts end,
  registerUi = function() end, openDialog = function() end }
package.preload["LuaGObject"] = function() error("x") end
dofile(MAIN); initUi()
strokes[1] = { x = {30, 430}, y = {300, 1100}, width = 1.5 }
infiniteCanvas_fit()
-- conteúdo até 1100.75 -> linha i=43 em 80+43*24=1112 (abaixo do conteúdo), +1 linha livre = 1136, +60 rodapé +1
print("pautado:", page.pageWidth, page.pageHeight)
assert(math.abs(page.pageWidth - 595.28) < 0.01 and page.pageHeight == 1197)
local lastLine = 80 + math.floor((page.pageHeight - 60 - 80) / 24) * 24
assert(lastLine >= 1100.75 + 24, "sobra uma linha livre abaixo do conteúdo")
infiniteCanvas_fit(); assert(page.pageHeight == 1197, "estável")
page.pageTypeConfig = "r1=30"; infiniteCanvas_fit(); print("r1=30:", page.pageHeight)
assert(page.pageHeight == 80 + (math.ceil((1100.75-80)/30)+1)*30 + 61)
-- página comum mais estreita que A4 não alarga
page.pageTypeFormat = "plain"; page.pageWidth = 500; infiniteCanvas_fit(); assert(page.pageWidth == 500, page.pageWidth)
assert(math.abs(page.pageHeight - 1140.75) < 0.01, page.pageHeight)
-- conteúdo passando da borda alarga
strokes[2] = { x = {640}, y = {500}, width = 2 }; infiniteCanvas_fit(); assert(page.pageWidth == 792, page.pageWidth)
-- canvas pontilhado recorta
page.pageTypeFormat = "dotted"; page.pageWidth = 2000; infiniteCanvas_fit(); assert(math.abs(page.pageWidth - 681) < 1, page.pageWidth)
print("OK")
