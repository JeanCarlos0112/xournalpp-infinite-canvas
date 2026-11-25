-- lua5.4 tests/test_pdf_extension.lua — PDF pages: extension layer, styles, auto-grow, fit.
local DIR = (arg and arg[0] or ""):match("^(.*[/\\])") or "./"
local MAIN = DIR .. "../InfiniteCanvas/main.lua"
-- layers[i] = { name=, strokes={} }; index 1 = bottom
local page = { pageWidth = 595.28, pageHeight = 841.89, pageTypeFormat = "pdf", pageTypeConfig = "",
               pdfBackgroundPageNo = 1, currentLayer = 1, layers = { [0] = {}, { name = "Camada 1", strokes = {} } } }
local timers, gesture, dialogs = {}, nil, {}
package.preload["LuaGObject"] = function()
  local Gtk = { PropagationPhase = { CAPTURE = 1 },
    Window = { list_toplevels = function() local w = {}; function w:is_visible() return true end; function w:get_title() return "Xournal++" end; function w:get_allocated_width() return 1 end; function w:get_allocated_height() return 1 end; return { w } end },
    GestureDrag = { new = function() gesture = { set_button = function() end, set_propagation_phase = function() end }; return gesture end } }
  return { GLib = { PRIORITY_DEFAULT = 0, get_language_names = function() return { "pt_BR" } end,
                    timeout_add = function(_, ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end },
           require = function() return Gtk end }
end
local function run() local keep = {}; for _, t in ipairs(timers) do if t.ms < 1000 then if t.fn() then keep[#keep+1] = t end else keep[#keep+1] = t end end; timers = keep end
local function cur() return page.layers[page.currentLayer] end
local function nlayers() return #page.layers end
app = { getDocumentStructure = function() return { currentPage = 1, pages = { page }, xoppFilename = "t.xopp" } end,
  changeCurrentPageBackground = function() error("o fundo PDF nao pode ser trocado") end,
  setPageSize = function(w, h) page.pageWidth, page.pageHeight = w, h end,
  getStrokes = function() return cur().strokes end, getImages = function() return {} end, getTexts = function() return {} end,
  openDialog = function(m) dialogs[#dialogs + 1] = m end, registerUi = function() end,
  setCurrentLayer = function(i) assert(i >= 1 and i <= nlayers(), "layer " .. i); page.currentLayer = i end,
  setCurrentLayerName = function(n) cur().name = n end,
  activateAction = function(a)
    if a == "layer-delete" then table.remove(page.layers, page.currentLayer); page.currentLayer = math.max(1, page.currentLayer - 1); return end
    assert(a == "layer-new-below-current"); table.insert(page.layers, page.currentLayer, { name = "", strokes = {} }) end,
  layerAction = function() error("layerAction (obsoleto) nao deve ser usado") end,
  addStrokes = function(t) for _, s in ipairs(t.strokes) do table.insert(cur().strokes, s) end end }
dofile(MAIN); initUi(); run()
local function ext() for i = 1, nlayers() do local l = page.layers[i]; if l.name == "Extensão do PDF" then return l, i end end end
local function count(l, color) local n = 0; for _, s in ipairs(l.strokes) do if (s.color & 0xFFFFFF) == color then n = n + 1 end end; return n end
local function tags(l, v) local n = 0; for _, s in ipairs(l.strokes) do if s.color == 0xFFFFFF and math.abs(s.width - (0.21 + v / 100)) < 1e-9 then n = n + 1 end end; return n end
local refreshes = 0; app.refreshPage = function() refreshes = refreshes + 1 end

local user = page.layers[1]
user.strokes[1] = { x = {100, 400}, y = {100, 400}, width = 1.5 }

-- PDF sem marca: não cresce
gesture.on_drag_end(); run(); assert(page.pageWidth == 595.28)

-- Ctrl+Shift+N marca: cria camada de extensão no fundo, sem mudar o tamanho
infiniteCanvas_make()
local e, ei = ext(); assert(e and ei == 1 and nlayers() == 2, "camada criada")
assert(page.currentLayer == 2 and cur() == user, "camada do usuario restaurada")
assert(dialogs[#dialogs]:find("cresce sozinha"))
assert(tags(e, 4) == 2, "tag lisa + auto")

-- escrevendo na borda direita: cresce, PDF intacto, área nova pintada de branco
user.strokes[2] = { x = {590}, y = {300}, width = 1.5 }
gesture.on_drag_end(); run()
assert(math.abs(page.pageWidth - 795.28) < 0.01, page.pageWidth)
e = ext(); assert(nlayers() == 2 and cur() == user)
local r; for _, s in ipairs(e.strokes) do if s.fill == 255 and s.x[1] > 1 then r = s end end
assert(math.abs(r.x[1] - 595.28) < 0.01 and math.abs(r.x[2] - 795.28) < 0.01, "retangulo direito")

-- abaixo
user.strokes[3] = { x = {100}, y = {838}, width = 1.5 }
gesture.on_drag_end(); run(); assert(page.pageHeight > 841.89, page.pageHeight)

-- estilo pautado e pontilhado
infiniteCanvas_extLined(); e = ext()
assert(tags(e, 5) == 2 and count(e, 0x40a0ff) > 5, "pautada")
for _, s in ipairs(e.strokes) do if s.color == 0x40a0ff then assert(s.y[1] <= page.pageHeight - 60 and (s.y[1] - 80) % 24 == 0) end end
infiniteCanvas_extDotted(); e = ext()
assert(tags(e, 6) == 2 and count(e, 0xbdbdbd) > 50 and count(e, 0x40a0ff) == 0, "pontilhada")
assert(nlayers() == 2 and cur() == user)
-- repetir o mesmo estilo não redesenha (nem empilha), mas repinta
local before, r0 = e, refreshes
for _ = 1, 20 do infiniteCanvas_extDotted() end
assert(ext() == before and nlayers() == 2 and refreshes == r0 + 20, "sem redesenho repetido")
-- alternar estilos várias vezes nunca empilha camadas
for _ = 1, 10 do infiniteCanvas_extBlank(); infiniteCanvas_extLined(); infiniteCanvas_extDotted() end
assert(nlayers() == 2 and cur() == user and tags(ext(), 6) == 2)
-- arquivo da primeira versão de teste (tag na cor) ainda é reconhecido
for _, s in ipairs(ext().strokes) do if s.color == 0xFFFFFF and s.fill then s.color, s.width = 0xFFFFF6, 0.1 end end
infiniteCanvas_extDotted(); assert(nlayers() == 2, "tag antiga reconhecida")
infiniteCanvas_extLined(); assert(nlayers() == 2 and tags(ext(), 5) == 2, "tag antiga convertida")
infiniteCanvas_extDotted()

-- ajustar ao conteúdo: encolhe, nunca abaixo do PDF, camada redesenhada
user.strokes[2], user.strokes[3] = nil, nil
infiniteCanvas_fit()
assert(page.pageWidth == 595.28 and page.pageHeight == 841.89, page.pageWidth .. "x" .. page.pageHeight)
e = ext(); assert(e and count(e, 0xbdbdbd) == 0, "sem area extra: so as tags (pagina marcada)")
-- informações persistem: tamanho original do PDF lido da camada
infiniteCanvas_expandRight(); e = ext()
assert(page.pageWidth > 595.28 and count(e, 0xbdbdbd) > 0)

-- desmarcar e ajustar: camada some
infiniteCanvas_make(); assert(dialogs[#dialogs]:find("não cresce"))
infiniteCanvas_fit(); assert(page.pageWidth == 595.28 and not ext() and nlayers() == 1 and cur() == user, "camada removida")

-- pageExtent ignora a camada: PDF não marcado, expandir à direita e ajustar volta ao PDF
infiniteCanvas_expandRight(); assert(ext() and page.pageWidth > 595.28)
infiniteCanvas_fit(); assert(page.pageWidth == 595.28 and not ext())
print("OK")
