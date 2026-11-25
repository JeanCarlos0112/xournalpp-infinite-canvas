-- Run from the repository root or anywhere: lua5.4 tests/test_existing_writing.lua
-- Uses a mocked Xournal++ Lua API (no Xournal++ needed).
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
local page = { pageWidth = 595.27559, pageHeight = 841.88976, pageTypeFormat = "lined", pageTypeConfig = "", pdfBackgroundPageNo = 0, currentLayer = 1, layers = { [0] = {}, {} } }
local strokes, timers, gesture = {}, {}, nil
package.preload["LuaGObject"] = function()
  local Gtk = { PropagationPhase = { CAPTURE = 1 },
    Window = { list_toplevels = function() local w = {}; function w:is_visible() return true end; function w:get_title() return "Xournal++" end; function w:get_allocated_width() return 1 end; function w:get_allocated_height() return 1 end; return { w } end },
    GestureDrag = { new = function() gesture = { set_button = function() end, set_propagation_phase = function() end }; return gesture end } }
  return { GLib = { PRIORITY_DEFAULT = 0, get_language_names = function() return { "pt_BR" } end,
                    timeout_add = function(_, ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end }, require = function() return Gtk end }
end
local function run(maxMs) local keep = {}; for _, t in ipairs(timers) do if t.ms <= (maxMs or 1e9) then if t.fn() then keep[#keep+1] = t end else keep[#keep+1] = t end end; timers = keep end
local now = 1000; os.time = function() return now end
app = { getDocumentStructure = function() return { currentPage = 1, pages = { page }, xoppFilename = "nota.xopp" } end,
  changeCurrentPageBackground = function(f, c) page.pageTypeFormat = f; page.pageTypeConfig = c or "" end,
  setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
  getStrokes = function() return strokes end, openDialog = function() end, registerUi = function() end }
dofile(MAIN); initUi(); run(500)
-- escrita existente encostada na borda (como no seu arquivo)
for i = 1, 458 do strokes[i] = { x = {80, 593.3 - 1}, y = {100 + i, 789}, width = 2 } end
infiniteCanvas_make()                         -- marca
now = now + 10; run()                          -- checagem de segurança
gesture.on_drag_end(); run(500)                -- clique sem traço novo
assert(page.pageWidth == 595.27559 and page.pageHeight == 841.88976, "conteúdo antigo não faz crescer")
-- traço novo no meio da folha
strokes[#strokes + 1] = { x = {100, 400}, y = {300, 320}, width = 2 }
gesture.on_drag_end(); run(500)
assert(page.pageWidth == 595.27559 and page.pageHeight == 841.88976, "meio da folha não cresce")
-- traço novo encostando na borda direita -> +200
strokes[#strokes + 1] = { x = {400, 590}, y = {500, 500}, width = 2 }
gesture.on_drag_end(); run(500); print("direita:", page.pageWidth, page.pageHeight)
assert(math.abs(page.pageWidth - 795.28) < 0.01 and page.pageHeight == 841.88976)
-- traço novo na última linha -> +10 linhas, alinhado
strokes[#strokes + 1] = { x = {100, 300}, y = {790, 800}, width = 2 }
gesture.on_drag_end(); run(500); print("baixo:", page.pageWidth, page.pageHeight)
assert((page.pageHeight - 141) % 24 == 0 and page.pageHeight > 841.88976 and page.pageHeight <= 841.88976 + 240 + 24)
print("OK")
