-- Run from the repository root or anywhere: lua5.4 tests/test_bottom_margin.lua
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
local function run() local keep = {}; for _, t in ipairs(timers) do if t.ms < 1000 then if t.fn() then keep[#keep+1] = t end else keep[#keep+1] = t end end; timers = keep end
app = { getDocumentStructure = function() return { currentPage = 1, pages = { page }, xoppFilename = "nota.xopp" } end,
  changeCurrentPageBackground = function(f, c) page.pageTypeFormat = f; page.pageTypeConfig = c or "" end,
  setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
  getStrokes = function() return strokes end, openDialog = function() end, registerUi = function() end }
dofile(MAIN); initUi(); run()
local H0 = page.pageHeight
local function write(xs, ys) strokes[#strokes + 1] = { x = xs, y = ys, width = 1.5 }; gesture.on_drag_end(); run() end
infiniteCanvas_make()
-- última linha da A4 fica em y=776. Caso 1: escrevendo na última linha ("posição = 5·mod8 = 5")
write({100, 140, 180}, {760, 774, 762})          -- letras na linha
write({150, 152, 149}, {774, 786, 789})          -- cedilha do "ç" descendo abaixo da linha
write({300, 310, 305}, {758, 788, 790})          -- "g" com descendente
assert(page.pageHeight == H0, "escrever na última linha NÃO cresce: " .. page.pageHeight)
-- escrevendo até perto (mas não encostando) na direita
write({400, 580}, {700, 705})
assert(page.pageWidth == 595.27559, "não alarga a 14 pt da borda: " .. page.pageWidth)
-- Caso 3: começou a escrever na margem, abaixo da última linha
write({400, 410, 405}, {790, 800, 805})
print("cresceu para baixo:", page.pageHeight)
assert(page.pageHeight == 1101 and page.pageWidth == 595.27559)
-- agora escrever na (nova) última linha também não cresce de novo
local lastLine = 80 + math.floor((page.pageHeight - 140) / 24) * 24
write({100, 300}, {lastLine - 14, lastLine - 2})
assert(page.pageHeight == 1101, "nova última linha não cresce")
-- encostando na borda direita
write({500, 591}, {300, 300})
print("direita:", page.pageWidth); assert(math.abs(page.pageWidth - 795.28) < 0.01)
print("OK")
