-- Run from the repository root or anywhere: lua5.4 tests/test_fit_paper_width.lua
-- Uses a mocked Xournal++ Lua API (no Xournal++ needed).
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
local cfgDir = DIR .. "fixtures/template-a4-landscape"
local pages = { { pageWidth = 700, pageHeight = 2400, pageTypeFormat = "lined", pageTypeConfig = "", pdfBackgroundPageNo = 0, currentLayer = 1, layers = { [0] = {}, {} } } }
local cur = 1
local strokes, texts = {}, {}
app = { getDocumentStructure = function() return { currentPage = cur, pages = pages, xoppFilename = "/x/teste.xopp" } end,
  setPageSize = function(w, h) pages[cur].pageWidth, pages[cur].pageHeight = w, h end,
  getStrokes = function() return strokes end, getTexts = function() return texts end,
  getFolder = function() return cfgDir end,
  registerUi = function() end, openDialog = function() end }
package.preload["LuaGObject"] = function() error("x") end
dofile(MAIN); initUi()
local P = function() return pages[cur] end
strokes[1] = { x = {30, 430}, y = {300, 1100}, width = 1.5 }

-- 1) seu caso: página já esticada (700) por versão antiga, modelo = A4 deitado -> 595.28
infiniteCanvas_fit(); print("1)", P().pageWidth, P().pageHeight)
assert(math.abs(P().pageWidth - 595.28) < 0.01 and P().pageHeight == 1197)

-- 2) Carta: modelo Carta, página Carta intacta (612) -> mantém 612
cfgDir = DIR .. "fixtures/template-letter"; P().pageWidth = 612; infiniteCanvas_fit(); print("2)", P().pageWidth)
assert(P().pageWidth == 612)

-- 3) Carta esticada pelo plugin nesta sessão: lembra o original
infiniteCanvas_expandRight(); assert(P().pageWidth == 812, P().pageWidth)
infiniteCanvas_fit(); print("3)", P().pageWidth); assert(P().pageWidth == 612)

-- 4) Carta esticada antes (sem memória), modelo Carta -> 612 (não vira A4)
pages[2] = { pageWidth = 900, pageHeight = 2000, pageTypeFormat = "lined", pageTypeConfig = "", pdfBackgroundPageNo = 0, currentLayer = 1, layers = { [0] = {}, {} } }
cur = 2; infiniteCanvas_fit(); print("4)", P().pageWidth); assert(P().pageWidth == 612)

-- 5) conteúdo passa de qualquer papel que caiba -> próximo papel ou conteúdo+folga
strokes[2] = { x = {700}, y = {400}, width = 2 }
cur = 1; P().pageWidth = 595.28; cfgDir = DIR .. "fixtures/template-a4-landscape"
infiniteCanvas_fit(); print("5)", P().pageWidth); assert(math.abs(P().pageWidth - 841.89) < 0.01)
-- 6) sem modelo/outras páginas de papel -> conteúdo + folga
cfgDir = "/nao/existe"; pages[2].pageWidth = 900; P().pageWidth = 1000
strokes[2] = { x = {950}, y = {400}, width = 2 }
infiniteCanvas_fit(); print("6)", P().pageWidth); assert(P().pageWidth == 1000)
print("OK")
