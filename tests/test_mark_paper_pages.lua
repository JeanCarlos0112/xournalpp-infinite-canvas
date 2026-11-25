-- Run from the repository root or anywhere: lua5.4 tests/test_mark_paper_pages.lua
-- Uses a mocked Xournal++ Lua API (no Xournal++ needed).
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
local page = { pageWidth = 595.28, pageHeight = 841.89, pageTypeFormat = "lined", pageTypeConfig = "", pdfBackgroundPageNo = 0, currentLayer = 1, layers = { [0] = {}, {} } }
local strokes, timers, gesture, dialogs = {}, {}, nil, {}
package.preload["LuaGObject"] = function()
  local Gtk = { PropagationPhase = { CAPTURE = 1 },
    Window = { list_toplevels = function() local w = {}; function w:is_visible() return true end; function w:get_title() return "Xournal++" end; function w:get_allocated_width() return 1 end; function w:get_allocated_height() return 1 end; return { w } end },
    GestureDrag = { new = function() gesture = { set_button = function() end, set_propagation_phase = function() end }; return gesture end } }
  return { GLib = { PRIORITY_DEFAULT = 0, get_language_names = function() return { "pt_BR" } end,
                    timeout_add = function(_, ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end },
           require = function() return Gtk end }
end
local function run() local keep = {}; for _, t in ipairs(timers) do if t.ms < 1000 then if t.fn() then keep[#keep+1] = t end else keep[#keep+1] = t end end; timers = keep end
app = { getDocumentStructure = function() return { currentPage = 1, pages = { page }, xoppFilename = "" } end,
  changeCurrentPageBackground = function(f, c) page.pageTypeFormat = f; page.pageTypeConfig = c or "" end,
  setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
  getStrokes = function() return strokes end, openDialog = function(m) dialogs[#dialogs + 1] = m end,
  registerUi = function() end }
dofile(MAIN); initUi(); run()

-- pautada sem marca: não cresce
strokes[1] = { x = {100, 500}, y = {600, 700}, width = 1.5 }
gesture.on_drag_end(); run(); assert(page.pageHeight == 841.89, "sem marca nao cresce")

-- Ctrl+Shift+N marca, mantém fundo e tamanho
infiniteCanvas_make()
assert(page.pageTypeFormat == "lined" and page.pageTypeConfig == "icanvas=1", page.pageTypeConfig)
assert(page.pageWidth == 595.28 and page.pageHeight == 841.89 and dialogs[#dialogs]:find("cresce sozinha"))

-- escrita normal no meio da folha (até x=500, y=700) não dispara mais
gesture.on_drag_end(); run(); assert(page.pageWidth == 595.28 and page.pageHeight == 841.89, "nao cresce no meio")
-- escrevendo na última linha antes do rodapé (y ~ 770) cresce para baixo, alinhado às linhas
strokes[2] = { x = {100, 300}, y = {790, 800}, width = 1.5 }
gesture.on_drag_end(); run()
print("cresceu para:", page.pageWidth, page.pageHeight)
assert((page.pageHeight - 141) % 24 == 0 and page.pageHeight == 1101 and page.pageWidth == 595.28, page.pageHeight)
-- e para a direita
strokes[3] = { x = {591}, y = {300}, width = 1.5 }
gesture.on_drag_end(); run(); assert(math.abs(page.pageWidth - 795.28) < 0.01, page.pageWidth)

-- ajustar: largura volta para o papel, altura alinhada às linhas
infiniteCanvas_fit(); print("ajustado:", page.pageWidth, page.pageHeight)
assert(math.abs(page.pageWidth - 595.28) < 0.01 and (page.pageHeight - 141) % 24 == 0)

-- com r1 personalizado, a marca convive com a configuração
infiniteCanvas_make(); assert(page.pageTypeConfig == "" and dialogs[#dialogs]:find("não cresce"))
page.pageTypeConfig = "r1=30"; infiniteCanvas_make(); assert(page.pageTypeConfig == "r1=30,icanvas=1", page.pageTypeConfig)
infiniteCanvas_expandDown(); assert((page.pageHeight - 141) % 30 == 0, page.pageHeight)

-- página lisa vira canvas pontilhado marcado e crescido
page.pageTypeFormat, page.pageTypeConfig, page.pageWidth, page.pageHeight = "plain", "", 595.28, 841.89
strokes = {}
infiniteCanvas_make(); assert(page.pageTypeFormat == "dotted" and page.pageTypeConfig == "icanvas=1" and page.pageWidth == 1200)
-- pontilhado antigo sem marca continua crescendo (compatibilidade)
page.pageTypeConfig = ""; strokes[1] = { x = {1150}, y = {100}, width = 2 }
gesture.on_drag_end(); run(); assert(page.pageWidth == 2000, page.pageWidth)
print("OK")
