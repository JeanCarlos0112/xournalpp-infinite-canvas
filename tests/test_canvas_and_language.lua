-- Run from the repository root or anywhere: lua5.4 tests/test_canvas_and_language.lua
-- Uses a mocked Xournal++ Lua API (no Xournal++ needed).
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
-- Testes da versão comunitária: idioma, proteção de PDF, auto em PDF opcional
local function fresh(langNames, opts)
  opts = opts or {}
  local page = { pageWidth = 595, pageHeight = 842, pageTypeFormat = opts.fmt or "plain",
                 pdfBackgroundPageNo = opts.pdf or 0,
                 currentLayer = 1, layers = { [0] = {isVisible=true}, {isVisible=true} } }
  local strokes, timers, gesture, menus, dialogs = {}, {}, nil, {}, {}
  package.loaded["LuaGObject"] = nil
  package.preload["LuaGObject"] = function()
    local Gtk = {
      PropagationPhase = { CAPTURE = 1 },
      Window = { list_toplevels = function()
        local w = {}
        function w:is_visible() return true end
        function w:get_title() return "x - Xournal++" end
        function w:get_allocated_width() return 100 end
        function w:get_allocated_height() return 100 end
        return { w }
      end },
      GestureDrag = { new = function() gesture = { set_button = function() end, set_propagation_phase = function() end }; return gesture end },
    }
    return { GLib = { PRIORITY_DEFAULT = 0,
                      get_language_names = function() return langNames end,
                      timeout_add = function(_, ms, fn) timers[#timers+1] = { ms = ms, fn = fn } end },
             require = function() return Gtk end }
  end
  app = {
    getDocumentStructure = function() return { currentPage = 1, pages = { page } } end,
    changeCurrentPageBackground = function(bg) page.pageTypeFormat = bg end,
    setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
    getStrokes = function() return strokes end,
    openDialog = function(m) dialogs[#dialogs+1] = m end,
    registerUi = function(o) menus[#menus+1] = o.menu; assert(not o.accelerator:find("Alt")) end,
  }
  local run = function(maxMs)
    local keep = {}
    for _, t in ipairs(timers) do
      if t.ms <= (maxMs or 1e9) then if t.fn() then keep[#keep+1] = t end else keep[#keep+1] = t end
    end
    timers = keep
  end
  dofile(MAIN)
  initUi(); run(500)
  return { page = page, strokes = strokes, menus = menus, dialogs = dialogs, run = run,
           penUp = function() gesture.on_drag_end() end }
end

-- idioma
local en = fresh({ "en_US.UTF-8", "en_US", "en", "C" })
assert(en.menus[1]:find("^Infinite Canvas"), en.menus[1])
local pt = fresh({ "pt_BR", "pt", "C" })
assert(pt.menus[1]:find("^Canvas infinito"), pt.menus[1])
local other = fresh({ "de_DE", "de", "C" })
assert(other.menus[1]:find("^Infinite Canvas"), "fallback inglês")
print("idioma: OK  (" .. pt.menus[1] .. ")")

-- página com PDF: make não troca o fundo e avisa
local pdf = fresh({ "pt_BR" }, { pdf = 1, fmt = "pdf" })
infiniteCanvas_make()
assert(pdf.page.pageTypeFormat == "pdf", "fundo do PDF preservado")
assert(pdf.page.pageWidth == 595, "não redimensiona no make")
assert(#pdf.dialogs == 1 and pdf.dialogs[1]:find("PDF"), "avisou")
-- auto não cresce PDF por padrão
pdf.strokes[1] = { x = {590}, y = {100}, width = 2 }
pdf.penUp(); pdf.run(500)
assert(pdf.page.pageWidth == 595, "auto ignora PDF por padrão")
-- manual funciona em PDF
infiniteCanvas_expandRight()
assert(math.abs(pdf.page.pageWidth - 795) < 0.01 and pdf.page.pageTypeFormat == "pdf", pdf.page.pageWidth)
print("PDF: OK")

-- canvas normal continua crescendo
local c = fresh({ "en" }, { fmt = "plain" })
infiniteCanvas_make()
assert(c.page.pageTypeFormat == "dotted" and c.page.pageWidth == 1200)
c.strokes[1] = { x = {1100}, y = {100}, width = 2 }
c.penUp(); c.run(500)
assert(c.page.pageWidth == 2000, "cresceu: " .. c.page.pageWidth)
print("canvas: OK")
print("TODOS OS TESTES PASSARAM")
