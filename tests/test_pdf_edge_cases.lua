-- lua5.4 tests/test_pdf_edge_cases.lua — edge cases of PDF pages and the extension layer.
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


local function reset(w, h, nUser)
  page.pageWidth, page.pageHeight, page.layers, page.currentLayer = w, h, { [0] = {} }, nUser
  for i = 1, nUser do page.layers[i] = { name = "Camada " .. i, strokes = {} } end
end

-- 1. várias camadas do usuário, escrevendo na do topo: a extensão vai para o fundo
--    e o usuário continua na mesma camada (agora deslocada)
reset(841.89, 595.28, 3)
local top = page.layers[3]
infiniteCanvas_make()
local e, ei = ext(); assert(ei == 1 and nlayers() == 4 and cur() == top, "camada do usuario mantida")
-- escrevendo numa camada do meio, o crescimento também acontece
page.currentLayer = 3; local mid = cur(); mid.strokes[1] = { x = {838}, y = {100}, width = 1 }
gesture.on_drag_end(); run(); assert(page.pageWidth > 841.89 and cur() == mid and nlayers() == 4)

-- 2. o conteúdo de outras camadas conta no ajuste; a extensão nunca conta
top.strokes[1] = { x = {900}, y = {650}, width = 1 }
mid.strokes[1] = nil
infiniteCanvas_fit(); assert(page.pageWidth >= 900 and page.pageHeight >= 650, page.pageWidth .. "x" .. page.pageHeight)
top.strokes[1] = nil
infiniteCanvas_fit(); assert(page.pageWidth == 841.89 and page.pageHeight == 595.28, "volta ao PDF (paisagem)")

-- 3. a extensão nunca corta o PDF: expansão manual e ajuste em página sem nada
reset(595.28, 841.89, 1)
infiniteCanvas_fit(); assert(page.pageWidth == 595.28 and not ext(), "pagina vazia: nada muda")
infiniteCanvas_expandDown(); assert(page.pageHeight > 841.89 and ext())
infiniteCanvas_fit(); assert(page.pageHeight == 841.89 and not ext())

-- 4. estilo escolhido vale para PDFs estendidos depois
infiniteCanvas_expandRight(); infiniteCanvas_extLined()
infiniteCanvas_fit(); assert(not ext())
infiniteCanvas_expandRight(); e = ext()
local lines = 0; for _, s in ipairs(e.strokes) do if s.color == 0x40a0ff then lines = lines + 1 end end
assert(lines > 0, "pautada lembrada na sessao")
infiniteCanvas_extBlank(); infiniteCanvas_fit()

-- 5. linhas da pautada respeitam o rodapé; pontos ficam dentro da área nova
page.pageWidth, page.pageHeight = 595.28, 841.89
infiniteCanvas_expandDown(); infiniteCanvas_expandRight(); infiniteCanvas_extDotted(); e = ext()
for _, s in ipairs(e.strokes) do
  if s.color == 0xbdbdbd then
    local x, y = s.x[1], s.y[1]
    assert(x <= page.pageWidth and y <= page.pageHeight and (x >= 595.28 or y >= 841.89), "ponto fora da extensao")
  end
end
infiniteCanvas_extLined(); e = ext()
for _, s in ipairs(e.strokes) do if s.color == 0x40a0ff then assert(s.y[1] <= page.pageHeight - 60) end end

-- 6. uma faixa minúscula (< 0,5 pt) não gera padrão, mas o retângulo existe
infiniteCanvas_fit(); page.pageWidth = 595.5; infiniteCanvas_make()
infiniteCanvas_extDotted(); e = ext()
for _, s in ipairs(e.strokes) do if s.color == 0xbdbdbd then assert(s.y[1] >= 841.89, "sem pontos na faixa estreita") end end
infiniteCanvas_make()

-- 7. um retângulo branco do próprio usuário não é confundido com a extensão
reset(595.28, 841.89, 1)
cur().strokes[1] = { x = {10, 50, 50, 10, 10}, y = {0, 0, 40, 40, 0}, width = 0.8, color = 0xFFFFFF, fill = 255 }
assert(not ext())
infiniteCanvas_extDotted(); assert(dialogs[#dialogs] and nlayers() >= 1)
local found = 0; for i = 1, nlayers() do if page.layers[i].name == "Extensão do PDF" then found = found + 1 end end
assert(found <= 1)

-- 8. página sem PDF: as opções de extensão só avisam
page.pageTypeFormat, page.pdfBackgroundPageNo = "lined", 0
local nd = #dialogs; infiniteCanvas_extDotted(); assert(#dialogs == nd + 1 and dialogs[#dialogs]:find("PDF"))
print("OK")
