--[[
  InfiniteCanvas 1.1.0 — a Xournal++ plugin (tested on Xournal++ 1.3.4)
  https://github.com/JeanCarlos0112/xournalpp-infinite-canvas

  Makes pages grow to the right and downwards as you write near their edges.
  Two kinds of growing pages:
    * Free canvas (dotted): a plain page becomes a dotted canvas that starts
      small and grows in big steps when you write near its edges.
    * Marked paper page (lined, ruled, graph, staves...): the paper is kept
      (lines, margins, size); the page only grows when you start writing in
      its bottom margin (below the last line) or touch its right edge, in
      small paper-like steps. The mark ("icanvas=1" in the page background
      config) is saved in the .xopp file.

  Shortcuts (also in the Plugin menu):
    Ctrl+Shift+N  Plain page: turn it into a dotted canvas.
                  Lined/graph/... page: mark it to grow by itself (press again to unmark).
    Ctrl+Shift+B  Expand downwards now
    Ctrl+Shift+M  Expand to the right now ("more width")
    Ctrl+Shift+J  Fit the page to its content (see infiniteCanvas_fit)
    Ctrl+Shift+U  Toggle auto-grow

  How auto-grow works:
    The Lua API has no events ("stroke finished") and no timers. The plugin uses
    LuaGObject (the lgi fork bundled with Xournal++ 1.3) to listen to GTK: a
    capture-phase GtkGestureDrag on the main window reports when the pen/mouse
    is lifted; ~120 ms later the plugin checks the page and enlarges it if
    needed. The gesture never claims the event sequence, so Xournal++ input is
    untouched. Fallbacks: periodic polling if GTK can't be reached; manual
    shortcuts if LuaGObject is missing.
    On marked paper pages only strokes written after the page was marked (or
    first seen in this session) count, so existing writing never triggers
    growth.

  Limitations (Lua API):
    * Grows only to the right and downwards (existing strokes can't be moved).
    * Each resize is an undo step: Ctrl+Z undoes the growth before the stroke.
    * Auto-grow looks at the current layer (the one you are writing on).
    * "Strokes already seen" is remembered per session only: after reopening a
      file, the first stroke on a marked page is treated as new.

  View behaviour:
    * When the width grows, "Zoom > Fit" is switched off so your handwriting
      doesn't shrink after every growth (set CONFIG.keepZoom = false to disable).
    * When a page becomes a canvas, the view scrolls back to its left edge.

  Units: points (1/72 inch), same as the API.
  License: MIT.
]]

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------
local CONFIG = {
  initialWidth     = 1200,  -- initial canvas size (pt)
  initialHeight    = 1600,
  minWidth         = 300,   -- minimum size for "fit page to content"
  minHeight        = 200,
  edgeMargin       = 200,   -- content closer than this to an edge => grow
  paperEdgeMargin  = 8,     -- same, for paper pages marked with Ctrl+Shift+N (lined,
                            -- graph...): the stroke has to (almost) touch the edge. On
                            -- ruled paper the page grows downwards only when you start
                            -- writing in the bottom margin, below the last line
  growStep         = 800,   -- how much a free (dotted) canvas grows each time (pt)
  paperGrowX       = 200,   -- how much a marked paper page grows to the right (pt)
  paperGrowLines   = 10,    -- ...and downwards, in lines on ruled/lined paper
  paperGrowY       = 240,   -- ...and downwards on other paper (graph...) (pt)
  fitPadding       = 40,    -- space kept below/right of the last stroke by "fit page to content"
  -- regular (non-canvas) pages keep their paper width when fitted; see paperWidthFor()
  background       = "dotted",
  autoGrow         = true,  -- auto-grow starts enabled
  autoGrowDotted   = false, -- true: every dotted page auto-grows. false: only
                            -- pages marked with Ctrl+Shift+N (marker saved in
                            -- the file), so a dotted page template stays normal
  autoGrowPdfPages = false, -- auto-grow every PDF page, not only the ones marked
                            -- with Ctrl+Shift+N
  pdfExtensionStyle = "blank", -- look of the area added to a PDF page:
                            -- "blank", "lined" or "dotted" (also in the Plugin menu)
  keepZoom         = true,  -- keep the zoom when the width grows
  penUpDelayMs     = 120,   -- wait after pen-up (stroke already stored)
  pollIntervalMs   = 1500,  -- polling interval when GTK can't be reached
  safetyPollMs     = 3000,  -- safety-net poll while the pen hook is active (0 = off)
  language         = "auto", -- "auto", "en" or "pt"
  debugLog         = false, -- write debug.log in the plugin folder
}

----------------------------------------------------------------------
-- Debug log
----------------------------------------------------------------------
-- Finds the plugin folder. On Windows Xournal++ runs with C:\Windows\System32
-- as working directory, so relative paths are useless.
local PLUGIN_DIR, PLUGIN_DIR_HOW = nil, "?"
local function pluginDir()
  if PLUGIN_DIR then return PLUGIN_DIR end
  -- 1) this chunk's file name (the anonymous function lives in this file;
  --    pcall(debug.getinfo, 1) would inspect pcall itself)
  local ok, info = pcall(function() return debug.getinfo(1, "S") end)
  local src = (ok and info and info.source) or ""
  local dir = src:match("^@(.*[/\\])")
  if dir then PLUGIN_DIR, PLUGIN_DIR_HOW = dir, "debug.getinfo" return dir end
  -- 2) Xournal++ adds the plugin folder to package.path
  for entry in (package.path or ""):gmatch("[^;]+") do
    if entry:find("InfiniteCanvas", 1, true) then
      dir = entry:match("^(.*[/\\])")
      if dir then PLUGIN_DIR, PLUGIN_DIR_HOW = dir, "package.path" return dir end
    end
  end
  -- 3) Xournal++ config folder
  if app and app.getFolder then
    local okF, cfg = pcall(app.getFolder, "config")
    if okF and type(cfg) == "string" and cfg ~= "" then
      PLUGIN_DIR, PLUGIN_DIR_HOW = cfg .. "/plugins/InfiniteCanvas/", "app.getFolder"
      return PLUGIN_DIR
    end
  end
  PLUGIN_DIR, PLUGIN_DIR_HOW = "", "none"
  return PLUGIN_DIR
end

local function log(fmt, ...)
  if not CONFIG.debugLog then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  local f = io.open(pluginDir() .. "debug.log", "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S  "), msg, "\n")
    f:close()
  end
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local state = {
  busy         = false,
  pendingCheck = false,
  lastSig      = nil,
  lastPenUp    = 0,    -- os.time() of the last pen-up
  pollId       = nil,
  gesture      = nil,  -- must stay referenced (GTK3 widgets don't own controllers)
  hookMode     = "none",  -- "pen", "polling", "waiting" or "none"
  warned       = false,
  original     = {}, -- page key -> {w, h} before the plugin first resized it
  base         = {}, -- page+layer key -> stroke count already seen (paper pages)
}

local GI = { tried = false }

----------------------------------------------------------------------
-- LuaGObject loading
----------------------------------------------------------------------
local function loadGI()
  if GI.tried then return GI.GLib ~= nil end
  GI.tried = true
  for _, name in ipairs({ "LuaGObject", "lgi" }) do
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
      GI.name = name
      local okG, GLib = pcall(function() return mod.GLib end)
      if okG and GLib then GI.GLib = GLib end
      local okT, Gtk = pcall(mod.require, "Gtk", "3.0")
      if okT and Gtk then GI.Gtk = Gtk else log("Gtk 3.0 unavailable: %s", tostring(Gtk)) end
      log("module '%s' loaded (GLib=%s, Gtk=%s)", name, tostring(GI.GLib ~= nil), tostring(GI.Gtk ~= nil))
      return GI.GLib ~= nil
    end
    log("require('%s') failed: %s", name, tostring(mod))
  end
  return false
end

----------------------------------------------------------------------
-- Translations (English by default, Portuguese when the system is in pt)
----------------------------------------------------------------------
local STRINGS = {
  en = {
    menu_make   = "Infinite Canvas: turn current page into a canvas",
    menu_down   = "Infinite Canvas: expand downwards",
    menu_right  = "Infinite Canvas: expand to the right",
    menu_fit    = "Infinite Canvas: fit page to content",
    menu_toggle = "Infinite Canvas: toggle auto-grow",
    auto_on     = "Auto-grow: ON",
    auto_off    = "Auto-grow: OFF",
    no_gi_make  = "Canvas created.\n\nAuto-grow needs LuaGObject (bundled with Xournal++ 1.3), "
               .. "which was not found.\nUse Ctrl+Shift+B / Ctrl+Shift+M to expand.",
    no_gi_toggle = "Could not enable auto-grow (LuaGObject not found).\n"
               .. "Use Ctrl+Shift+B / Ctrl+Shift+M to expand.",
    no_setsize  = "This Xournal++ version has no app.setPageSize.\nPlease update Xournal++.",
    marked      = "This page will now grow by itself as you write near its right or bottom edge.\n\n"
               .. "Its paper (lines, margins, size) was kept. Press Ctrl+Shift+N again to turn this off.",
    unmarked    = "This page no longer grows by itself.",
    pdf_marked  = "This PDF page will now grow by itself as you write near its right or bottom edge.\n\n"
               .. "The PDF is not touched: the added area is drawn on a layer of its own (\"PDF extension\"), "
               .. "blank by default. Change it to lined or dotted in the Plugin menu. "
               .. "Press Ctrl+Shift+N again to turn growing off.",
    pdf_unmarked = "This PDF page no longer grows by itself.",
    pdf_only    = "This option is for pages with a PDF background.",
    ext_layer   = "PDF extension",
    menu_ext_blank  = "Infinite Canvas: PDF extension blank",
    menu_ext_lined  = "Infinite Canvas: PDF extension lined",
    menu_ext_dotted = "Infinite Canvas: PDF extension dotted",
  },
  pt = {
    menu_make   = "Canvas infinito: transformar página atual em canvas",
    menu_down   = "Canvas infinito: expandir para baixo",
    menu_right  = "Canvas infinito: expandir para a direita",
    menu_fit    = "Canvas infinito: ajustar página ao conteúdo",
    menu_toggle = "Canvas infinito: ligar/desligar crescimento automático",
    auto_on     = "Crescimento automático: LIGADO",
    auto_off    = "Crescimento automático: DESLIGADO",
    no_gi_make  = "Canvas criado.\n\nO crescimento automático precisa do LuaGObject (vem com o "
               .. "Xournal++ 1.3), que não foi encontrado.\nUse Ctrl+Shift+B / Ctrl+Shift+M para expandir.",
    no_gi_toggle = "Não foi possível ligar o crescimento automático (LuaGObject não encontrado).\n"
               .. "Use Ctrl+Shift+B / Ctrl+Shift+M para expandir.",
    no_setsize  = "Esta versão do Xournal++ não tem app.setPageSize.\nAtualize o Xournal++.",
    marked      = "Esta página agora cresce sozinha quando você escreve perto da borda direita ou de baixo.\n\n"
               .. "O papel (linhas, margens, tamanho) foi mantido. Aperte Ctrl+Shift+N de novo para desligar.",
    unmarked    = "Esta página não cresce mais sozinha.",
    pdf_marked  = "Esta página de PDF agora cresce sozinha quando você escreve perto da borda direita ou de baixo.\n\n"
               .. "O PDF não é alterado: a área nova fica numa camada própria (\"Extensão do PDF\"), "
               .. "lisa por padrão. Troque para pautada ou pontilhada no menu Plugin. "
               .. "Aperte Ctrl+Shift+N de novo para desligar.",
    pdf_unmarked = "Esta página de PDF não cresce mais sozinha.",
    pdf_only    = "Esta opção é para páginas com fundo de PDF.",
    ext_layer   = "Extensão do PDF",
    menu_ext_blank  = "Canvas infinito: extensão do PDF lisa",
    menu_ext_lined  = "Canvas infinito: extensão do PDF pautada",
    menu_ext_dotted = "Canvas infinito: extensão do PDF pontilhada",
  },
}

local T = STRINGS.en

local function detectLanguage()
  if CONFIG.language == "en" or CONFIG.language == "pt" then return CONFIG.language end
  local names = {}
  -- GLib knows the UI language on every platform (on Windows it reads the
  -- system locale; Xournal++ also exports its own language setting there).
  if loadGI() and GI.GLib.get_language_names then
    local ok, list = pcall(GI.GLib.get_language_names)
    if ok and type(list) == "table" then
      for _, n in ipairs(list) do names[#names + 1] = n end
    end
  end
  for _, var in ipairs({ "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG" }) do
    local v = os.getenv(var)
    if v and v ~= "" then names[#names + 1] = v end
  end
  for _, n in ipairs(names) do
    local code = tostring(n):lower()
    if code:match("^pt") then return "pt" end
    if code:match("^en") or code == "c" then return "en" end
  end
  return "en"
end

----------------------------------------------------------------------
-- Xournal++ API helpers
----------------------------------------------------------------------
local function notify(msg)
  if app.openDialog then
    app.openDialog(msg, { "OK" }, "", false)
  else
    print("[InfiniteCanvas] " .. msg)
  end
end

local function currentPage()
  local doc = app.getDocumentStructure()
  return doc.pages[doc.currentPage], doc.currentPage
end

local function hasPdfBackground(page)
  return (tonumber(page.pdfBackgroundPageNo) or 0) > 0
end

-- Pages marked with Ctrl+Shift+N carry "icanvas=1" in their background config.
-- Xournal++ saves the config in the .xopp and ignores keys it doesn't know.
local MARK_KEY = "icanvas"

local function pageFormat(page)
  return (tostring(page.pageTypeFormat or ""):gsub("^:", ""))
end

local function hasMark(page)
  for k, v in tostring(page.pageTypeConfig or ""):gmatch("([^,=]+)=([^,]*)") do
    if k == MARK_KEY and v == "1" then return true end
  end
  return false
end

local function configWithMark(config, on)
  local parts = {}
  for item in tostring(config or ""):gmatch("[^,]+") do
    if not item:match("^" .. MARK_KEY .. "=") then parts[#parts + 1] = item end
  end
  if on then parts[#parts + 1] = MARK_KEY .. "=1" end
  return table.concat(parts, ",")
end

-- Free canvas (dotted/plain): no paper layout, so its width can be trimmed freely.
local function isFreeCanvas(page)
  local fmt = pageFormat(page)
  return fmt == "dotted" or fmt == "plain"
end

local pdfIsMarked -- defined with the PDF extension code below

-- Standard sheets (A5, A4, A3, Letter, Legal, Tabloid), either orientation.
local PAPER_SIZES = { {419.53, 595.28}, {595.28, 841.89}, {841.89, 1190.55},
                      {612, 792}, {612, 1008}, {792, 1224} }

local function isPaperSize(w, h)
  for _, p in ipairs(PAPER_SIZES) do
    if (math.abs(w - p[1]) < 1 and math.abs(h - p[2]) < 1)
       or (math.abs(w - p[2]) < 1 and math.abs(h - p[1]) < 1) then return true end
  end
  return false
end

local function isCanvasPage(page)
  if hasPdfBackground(page) then return CONFIG.autoGrowPdfPages or pdfIsMarked() end
  if hasMark(page) then return true end
  if pageFormat(page) ~= "dotted" then return false end
  if CONFIG.autoGrowDotted then return true end
  -- canvases made by version 1.0 have no mark; a dotted page that isn't a
  -- standard sheet (and wasn't one before the plugin resized it in this
  -- session) is one of them. Dotted pages from a template stay normal.
  if isPaperSize(page.pageWidth, page.pageHeight) then return false end
  local key = state.pageKey and state.pageKey()
  local orig = key and state.original[key]
  return not (orig and isPaperSize(orig.w, orig.h))
end

-- Ruled/lined paper (Xournal++ 1.3): lines at 80 + i * spacing, no lines in
-- the last 60 pt (footer). Spacing defaults to 24 pt, config key "r1".
local RULED_HEADER, RULED_FOOTER, RULED_SPACING = 80, 60, 24

local function ruledSpacing(page)
  local fmt = pageFormat(page)
  if fmt ~= "ruled" and fmt ~= "lined" then return nil end
  local sp = tonumber(tostring(page.pageTypeConfig or ""):match("r1=([%d%.]+)")) or RULED_SPACING
  if sp <= 0 then sp = RULED_SPACING end
  return sp
end

-- Height of a ruled page that has n lines below the header, plus the footer.
local function ruledHeight(spacing, n)
  return RULED_HEADER + n * spacing + RULED_FOOTER + 1
end

-- Rounds a height up so a ruled page ends on a whole line + footer.
local function snapHeight(page, h)
  local sp = ruledSpacing(page)
  if not sp then return h end
  return ruledHeight(sp, math.max(0, math.ceil((h - RULED_HEADER - RULED_FOOTER - 1) / sp)))
end

local function newExtent()
  return { maxX = 0, maxY = 0, count = 0, points = 0 }
end

local function add(e, x, y)
  if x > e.maxX then e.maxX = x end
  if y > e.maxY then e.maxY = y end
end

local function getList(fnName)
  local fn = app[fnName]
  if not fn then return {} end
  local ok, res = pcall(fn, "layer")
  if ok and type(res) == "table" then return res end
  return {}
end

-- Bottom-right extent of the content of the current layer.
local function layerExtent(e)
  e = e or newExtent()

  for _, s in ipairs(getList("getStrokes")) do
    local xs, ys, ps = s.x or {}, s.y or {}, s.pressure
    local w = s.width or 1
    for i = 1, #xs do
      -- with pressure, pressure[i] is the stroke width at that point
      local half = ((ps and ps[i]) and math.max(w, ps[i]) or w) / 2
      add(e, xs[i] + half, (ys[i] or 0) + half)
    end
    e.count = e.count + 1
    e.points = e.points + #xs
  end

  for _, img in ipairs(getList("getImages")) do
    add(e, (img.x or 0) + (img.width or 0), (img.y or 0) + (img.height or 0))
    e.count = e.count + 1
  end

  for _, t in ipairs(getList("getTexts")) do
    local tw, th = t.width, t.height
    if not tw or not th then
      -- older versions don't report the text box: estimate from the font size
      local size = (type(t.font) == "table" and t.font.size) or 12
      local lines, longest = 0, 0
      for line in ((t.text or "") .. "\n"):gmatch("(.-)\n") do
        lines = lines + 1
        if #line > longest then longest = #line end
      end
      tw, th = longest * size * 0.6, lines * size * 1.3
    end
    add(e, (t.x or 0) + tw, (t.y or 0) + th)
    e.count = e.count + 1
  end

  e.sig = string.format("%d:%d:%.1f:%.1f", e.count, e.points, e.maxX, e.maxY)
  return e
end

-- Extent over all layers of the page (used by the manual actions).
local isExtensionLayer

-- PDF extension layer: white rectangles over the area added to a PDF page
-- (plus lines or dots). The rectangles are pure white; their border width
-- is the tag: 0.21 + 0.01 * (style index (0 blank, 1 lined, 2 dotted) + 4 if
-- the page is marked to grow by itself). The right rectangle starts at the
-- PDF width and the bottom one at the PDF height, so the original PDF size
-- is stored too.
local EXT_WHITE, EXT_W0 = 0xFFFFFF, 0.21
local EXT_STYLES = { "blank", "lined", "dotted" }

local function decodeTag(color, width)
  local c = (tonumber(color) or 0) & 0xFFFFFF
  local v
  if c == EXT_WHITE then
    local w = tonumber(width) or 0
    v = math.floor((w - EXT_W0) * 100 + 0.5)
    if math.abs(w - (EXT_W0 + v / 100)) > 0.002 then return nil end
  elseif c >= 0xFFFFF0 and c <= 0xFFFFF7 then
    v = c - 0xFFFFF0 -- tag of the first test build (slightly tinted)
  end
  if not v or v < 0 or v > 7 then return nil end
  return EXT_STYLES[(v % 4) + 1], v >= 4
end

-- Reads the tag rectangles of the current layer; nil if it isn't the extension layer.
local function readExtension()
  local info
  for _, s in ipairs(getList("getStrokes")) do
    local style, auto = decodeTag(s.color, s.width)
    if style and s.x and #s.x >= 4 then -- (fill is not reported by every version)
      info = info or { style = style, auto = auto }
      local minX, minY = math.huge, math.huge
      for i = 1, #s.x do
        if s.x[i] < minX then minX = s.x[i] end
        if s.y[i] < minY then minY = s.y[i] end
      end
      local maxX, maxY = -math.huge, -math.huge
      for i = 1, #s.x do
        if s.x[i] > maxX then maxX = s.x[i] end
        if s.y[i] > maxY then maxY = s.y[i] end
      end
      info.size = info.size or { w = 0, h = 0 }
      info.size.w = math.max(info.size.w, maxX)
      info.size.h = math.max(info.size.h, maxY)
      if minY < 0.01 and minX > 0.01 then info.pdfW = minX end   -- right rectangle
      if minX < 0.01 and minY > 0.01 then info.pdfH = minY end   -- bottom rectangle
    end
  end
  return info
end

isExtensionLayer = function() return readExtension() ~= nil end

local function pageExtent()
  local page = currentPage()
  local cur = page and page.currentLayer or 0
  local n = page and #page.layers or 0
  if not app.setCurrentLayer or n <= 1 or cur < 1 then
    return layerExtent()
  end
  local e = newExtent()
  for i = 1, n do
    if pcall(app.setCurrentLayer, i, false) and not isExtensionLayer() then layerExtent(e) end
  end
  pcall(app.setCurrentLayer, cur, false)
  return e
end

-- Finds the extension layer of the current page: {index, style, auto, pdfW, pdfH} or nil.
local function findExtLayer()
  local page = currentPage()
  if not page or not app.setCurrentLayer then return nil end
  local cur, n = page.currentLayer, #page.layers
  local found
  for i = 1, n do
    if pcall(app.setCurrentLayer, i, false) then
      local info = readExtension()
      if info then info.index = i; found = info; break end
    end
  end
  pcall(app.setCurrentLayer, cur, false)
  return found
end

local function pageKeyNow()
  local doc = app.getDocumentStructure()
  return tostring(doc.xoppFilename or "") .. "#" .. tostring(doc.currentPage)
end

-- Is the current PDF page marked to grow? Cached per page for the session.
pdfIsMarked = function()
  state.pdfMark = state.pdfMark or {}
  local key = pageKeyNow()
  if state.pdfMark[key] == nil then
    local ext = findExtLayer()
    state.pdfMark[key] = ext and ext.auto or false
  end
  return state.pdfMark[key]
end

local function rectStroke(x0, y0, x1, y1, tag)
  return { x = { x0, x1, x1, x0, x0 }, y = { y0, y0, y1, y1, y0 },
           width = EXT_W0 + tag / 100, color = EXT_WHITE, fill = 255, tool = "pen" }
end

-- addStrokes and layer changes don't repaint the page by themselves
local function repaint()
  if app.refreshPage then pcall(app.refreshPage) end
end

-- Lines/dots like Xournal++'s own lined (80 + i*24, 60 pt footer) and dotted
-- (14.17 pt grid, 1.5 pt dots) paper, limited to one area of the extension.
local function patternStrokes(style, x0, y0, x1, y1, pageH, out)
  if x1 - x0 < 0.5 or y1 - y0 < 0.5 then return end
  if style == "lined" then
    local i = math.max(0, math.ceil((y0 - 80) / 24))
    while 80 + i * 24 <= math.min(y1, pageH - 60) do
      local y = 80 + i * 24
      out[#out + 1] = { x = { x0, x1 }, y = { y, y }, width = 0.5, color = 0x40a0ff, tool = "pen" }
      i = i + 1
    end
  elseif style == "dotted" then
    local step, r = 14.17, 0.75
    for gx = math.max(1, math.ceil(x0 / step)), math.floor((x1 - r) / step) do
      for gy = math.max(1, math.ceil(y0 / step)), math.floor((y1 - r) / step) do
        local x, y = gx * step, gy * step
        out[#out + 1] = { x = { x, x }, y = { y, y }, width = 1.5, color = 0xbdbdbd, tool = "pen" }
      end
    end
  end
end

-- Deletes and redraws the extension layer of the current PDF page for its
-- current size. info = {pdfW, pdfH, style, auto}. The layer is removed when
-- the page has no extension and isn't marked.
local function refreshExtension(info, force)
  local page = currentPage()
  local userLayer = page.currentLayer
  local old = findExtLayer()
  if old and not force and old.style == info.style and old.auto == info.auto
     and old.size and math.abs(old.size.w - page.pageWidth) < 0.01
     and math.abs(old.size.h - page.pageHeight) < 0.01 then
    repaint() -- already drawn like this: nothing to redo
    return
  end
  if old then
    pcall(app.setCurrentLayer, old.index, false)
    if not pcall(app.activateAction, "layer-delete") then app.layerAction("ACTION_DELETE_LAYER") end
    if userLayer > old.index then userLayer = userLayer - 1 end
    page = currentPage()
  end
  local W, H = page.pageWidth, page.pageHeight
  local extended = W > info.pdfW + 0.01 or H > info.pdfH + 0.01
  if extended or info.auto then
    pcall(app.setCurrentLayer, 1, false)
    app.activateAction("layer-new-below-current")
    pcall(app.setCurrentLayer, 1, false) -- the new layer is the bottom one
    if app.setCurrentLayerName then pcall(app.setCurrentLayerName, T.ext_layer) end
    local idx = 0
    for i, st in ipairs(EXT_STYLES) do if st == info.style then idx = i - 1 end end
    local tag = idx + (info.auto and 4 or 0)
    local strokes = { rectStroke(info.pdfW, 0, math.max(W, info.pdfW), H, tag),
                      rectStroke(0, info.pdfH, W, math.max(H, info.pdfH), tag) }
    patternStrokes(info.style, info.pdfW, 0, W, H, H, strokes)          -- beside the PDF
    patternStrokes(info.style, 0, info.pdfH, info.pdfW, H, H, strokes)  -- below the PDF
    app.addStrokes({ strokes = strokes, allowUndoRedoAction = "grouped" })
    userLayer = userLayer + 1
  end
  pcall(app.setCurrentLayer, math.max(1, userLayer), false)
  repaint()
  state.pdfMark = state.pdfMark or {}
  state.pdfMark[pageKeyNow()] = info.auto and true or false
  log("PDF extension: %s, pdf %.0fx%.0f, page %.0fx%.0f, auto=%s", info.style, info.pdfW, info.pdfH, W, H, tostring(info.auto))
end

-- Extension info of the current PDF page, or the defaults for a page that has none.
local function pdfInfo(page)
  local ext = findExtLayer()
  if ext then
    ext.pdfW = ext.pdfW or page.pageWidth
    ext.pdfH = ext.pdfH or page.pageHeight
    return ext
  end
  return { pdfW = page.pageWidth, pdfH = page.pageHeight, style = CONFIG.pdfExtensionStyle, auto = false }
end

local function setSize(w, h)
  if not app.setPageSize then
    notify(T.no_setsize)
    return false
  end
  local page = currentPage()
  local pdf = page and hasPdfBackground(page) and pdfInfo(page) or nil
  if pdf then
    -- never crop the PDF itself
    w = math.max(w, pdf.pdfW)
    h = math.max(h, pdf.pdfH)
  end
  local widthChanged = page and math.abs(w - page.pageWidth) > 0.01
  local zoom = nil
  if CONFIG.keepZoom and widthChanged then
    -- With "Zoom > Fit" on, Xournal++ re-fits the zoom when the width changes
    -- (handwriting shrinks and the view jumps). Turn the mode off first.
    if app.getActionState and app.changeActionState then
      local okS, fit = pcall(app.getActionState, "zoom-fit")
      if okS and fit == true then
        pcall(app.changeActionState, "zoom-fit", false)
        log("'zoom-fit' turned off to keep the zoom")
      end
    end
    if app.getZoom then
      local ok, z = pcall(app.getZoom)
      if ok and type(z) == "number" and z > 0 then zoom = z end
    end
  end

  if page then
    local key = state.pageKey and state.pageKey()
    if key and not state.original[key] then
      state.original[key] = { w = page.pageWidth, h = page.pageHeight }
    end
  end
  local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
  if page and math.abs(w - page.pageWidth) < 0.01 then w = page.pageWidth else w = r2(w) end
  if page and math.abs(h - page.pageHeight) < 0.01 then h = page.pageHeight else h = r2(h) end
  app.setPageSize(w, h)
  if pdf then pcall(refreshExtension, pdf) end

  if zoom and app.setZoom then
    pcall(app.setZoom, zoom)
    -- the layout may re-fit after the relayout: check again shortly after
    if GI.GLib then
      GI.GLib.timeout_add(GI.GLib.PRIORITY_DEFAULT, 60, function()
        local ok, z = pcall(app.getZoom)
        if ok and type(z) == "number" and math.abs(z - zoom) > 1e-6 then
          pcall(app.setZoom, zoom)
        end
        return false
      end)
    end
  end
  return true
end

-- Grows in whole steps until the margin is free again.
-- Returns (changed?, newWidth, newHeight).
local function growIfNeeded(page, maxX, maxY, below)
  local w, h = page.pageWidth, page.pageHeight
  local newW, newH = w, h
  local marginX, marginY = CONFIG.edgeMargin, CONFIG.edgeMargin
  if not isFreeCanvas(page) then
    marginX = CONFIG.paperEdgeMargin
    local sp = ruledSpacing(page)
    marginY = sp and (RULED_FOOTER + sp) or CONFIG.paperEdgeMargin
  end
  local stepX, stepY = CONFIG.growStep, CONFIG.growStep
  if not isFreeCanvas(page) then
    stepX = CONFIG.paperGrowX
    local sp = ruledSpacing(page)
    stepY = sp and (CONFIG.paperGrowLines * sp) or CONFIG.paperGrowY
  end
  while maxX > newW - marginX do newW = newW + stepX end
  if below ~= nil and ruledSpacing(page) and not isFreeCanvas(page) then
    -- ruled paper: grow only when writing started below the last line
    if below then newH = newH + stepY end
  else
    while maxY > newH - marginY do newH = newH + stepY end
  end
  if newH ~= h then newH = snapHeight(page, newH) end
  if newW ~= w or newH ~= h then
    return setSize(newW, newH), newW, newH
  end
  return false, w, h
end

----------------------------------------------------------------------
-- Auto-grow check
----------------------------------------------------------------------
local function baseKey()
  local doc = app.getDocumentStructure()
  local page = doc.pages[doc.currentPage]
  return tostring(doc.xoppFilename or "") .. "#" .. tostring(doc.currentPage) .. "#L" .. tostring(page and page.currentLayer)
end

-- Remembers how many strokes the current layer has, so later checks only
-- look at strokes written after this moment.
local function setBaseline()
  state.base[baseKey()] = #getList("getStrokes")
end

-- Extent of the strokes added since the last look, or nil if none.
-- When the page was never seen and a pen was just lifted, the last stroke
-- is taken as the new one.
local function newStrokesExtent(justDrew, belowY)
  local strokes = getList("getStrokes")
  local key, n = baseKey(), #strokes
  local base = state.base[key]
  if base == nil then base = justDrew and math.max(0, n - 1) or n end
  if base > n then base = n end -- strokes were erased
  state.base[key] = n
  if n == base then return nil end
  local e = newExtent()
  e.below = false
  for i = base + 1, n do
    local s = strokes[i]
    local xs, ys, ps = s.x or {}, s.y or {}, s.pressure
    local w = s.width or 1
    local minY, maxY = math.huge, -math.huge
    for j = 1, #xs do
      local half = ((ps and ps[j]) and math.max(w, ps[j]) or w) / 2
      local y = ys[j] or 0
      add(e, xs[j] + half, y + half)
      if y < minY then minY = y end
      if y > maxY then maxY = y end
    end
    -- the stroke's vertical centre decides: descenders of the last line stay
    -- above it, writing in the bottom margin goes below it
    if belowY and #xs > 0 and (minY + maxY) / 2 > belowY then e.below = true end
    e.count = e.count + 1
  end
  return e
end

local function autoCheck(reason)
  if state.busy or not CONFIG.autoGrow then return end
  state.busy = true
  local ok, err = pcall(function()
    local page = currentPage()
    if not page or not isCanvasPage(page) then return end
    if reason == "safety" and os.time() - state.lastPenUp < 3 then
      return -- the pen hook is working; nothing to do
    end
    local e
    if isFreeCanvas(page) then
      e = layerExtent()
      if e.count == 0 then return end
      if reason ~= "pen" and e.sig == state.lastSig then return end
      state.lastSig = e.sig
    else
      -- paper page: only strokes written since we last looked count, so
      -- writing that was already there never makes the page grow
      local sp = ruledSpacing(page)
      local belowY
      if sp then
        local lastLine = RULED_HEADER + math.floor((page.pageHeight - RULED_HEADER - RULED_FOOTER) / sp) * sp
        belowY = lastLine + sp / 4
      end
      e = newStrokesExtent(reason == "pen", belowY)
      if not e then return end
    end
    local grew, w, h = growIfNeeded(page, e.maxX, e.maxY, e.below)
    if grew then
      log("grew (%s): %dx%d -> %dx%d  [content up to %.0f,%.0f; %d elements]",
          reason, page.pageWidth, page.pageHeight, w, h, e.maxX, e.maxY, e.count)
    end
  end)
  state.busy = false
  if not ok then log("check failed (%s): %s", reason, tostring(err)) end
end

----------------------------------------------------------------------
-- GTK hooks
----------------------------------------------------------------------
local function timeout(ms, fn)
  return GI.GLib.timeout_add(GI.GLib.PRIORITY_DEFAULT, ms, fn)
end

local function schedulePenUpCheck()
  state.lastPenUp = os.time()
  if state.pendingCheck then return end
  state.pendingCheck = true
  timeout(CONFIG.penUpDelayMs, function()
    state.pendingCheck = false
    autoCheck("pen")
    return false -- run once
  end)
end

local function findMainWindow()
  local Gtk = GI.Gtk
  local ok, list = pcall(Gtk.Window.list_toplevels)
  if not ok or type(list) ~= "table" then return nil end
  local best, bestScore = nil, 0
  for _, w in ipairs(list) do
    local okV, visible = pcall(w.is_visible, w)
    if okV and visible then
      local okT, title = pcall(w.get_title, w)
      title = (okT and title) or ""
      local okW, ww = pcall(w.get_allocated_width, w)
      local okH, hh = pcall(w.get_allocated_height, w)
      local score = ((okW and ww) or 0) * ((okH and hh) or 0)
      if title:find("Xournal", 1, true) then score = score + 1e12 end
      if score > bestScore then best, bestScore = w, score end
    end
  end
  return best
end

local function attachPenUpHook(win)
  local Gtk = GI.Gtk
  local g = Gtk.GestureDrag.new(win)
  g:set_button(0) -- any button / pen
  g:set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
  -- We never claim the sequence: Xournal++ still receives every event.
  g.on_drag_end = function() schedulePenUpCheck() end
  state.gesture = g
  state.hookMode = "pen"
  local okT, title = pcall(win.get_title, win)
  log("pen hook installed on window '%s'", tostring(okT and title or "?"))

  -- Safety net: if some tablet driver doesn't produce the release event, a
  -- slow check still makes the page grow.
  if CONFIG.safetyPollMs and CONFIG.safetyPollMs > 0 then
    timeout(CONFIG.safetyPollMs, function()
      autoCheck("safety")
      return true
    end)
  end
end

local function startPolling()
  if state.pollId then return end
  state.hookMode = "polling"
  state.pollId = timeout(CONFIG.pollIntervalMs, function()
    autoCheck("polling")
    return true
  end)
  log("polling every %d ms", CONFIG.pollIntervalMs)
end

-- Installs the hook once the main window exists (retries for ~30 s).
local function installAutoHooks()
  if state.hookMode ~= "none" then return true end
  if not loadGI() then return false end
  if not GI.Gtk then
    startPolling()
    return true
  end
  local tries = 0
  state.hookMode = "waiting"
  timeout(500, function()
    tries = tries + 1
    local okF, win = pcall(findMainWindow)
    if okF and win then
      local okA, err = pcall(attachPenUpHook, win)
      if okA then return false end
      log("could not install the pen hook: %s", tostring(err))
      state.hookMode = "none"
      startPolling()
      return false
    end
    if tries >= 60 then
      log("main window not found; falling back to polling")
      state.hookMode = "none"
      startPolling()
      return false
    end
    return true
  end)
  return true
end

----------------------------------------------------------------------
-- Actions (global callbacks required by registerUi)
----------------------------------------------------------------------
function infiniteCanvas_make()
  local page, pageNo = currentPage()
  if hasPdfBackground(page) then
    -- the PDF background is never changed: mark/unmark the page instead
    local info = pdfInfo(page)
    info.auto = not info.auto
    refreshExtension(info)
    setBaseline()
    if info.auto and CONFIG.autoGrow then installAutoHooks() end
    notify(info.auto and T.pdf_marked or T.pdf_unmarked)
    return
  end
  local fmt = pageFormat(page)
  if not isFreeCanvas(page) then
    -- ruled, lined, graph, staves...: keep the paper, just mark/unmark it
    local on = not hasMark(page)
    app.changeCurrentPageBackground(fmt, configWithMark(page.pageTypeConfig, on))
    setBaseline() -- what is already written never triggers growth
    state.lastSig = nil
    log("page %s %s", tostring(pageNo), on and "marked" or "unmarked")
    if on and CONFIG.autoGrow then installAutoHooks() end
    notify(on and T.marked or T.unmarked)
    return
  end
  if fmt == "dotted" and hasMark(page) then
    -- marked dotted canvas: unmark it (size and background stay)
    app.changeCurrentPageBackground(fmt, configWithMark(page.pageTypeConfig, false))
    state.lastSig = nil
    log("page %s unmarked", tostring(pageNo))
    notify(T.unmarked)
    return
  end
  app.changeCurrentPageBackground(CONFIG.background, configWithMark(fmt == "dotted" and page.pageTypeConfig or "", true))
  local e = pageExtent()
  local w = math.max(CONFIG.initialWidth, page.pageWidth, e.maxX + CONFIG.edgeMargin)
  local h = math.max(CONFIG.initialHeight, page.pageHeight, e.maxY + CONFIG.edgeMargin)
  local widened = w > page.pageWidth
  if w ~= page.pageWidth or h ~= page.pageHeight then setSize(w, h) end

  -- When the page starts needing a horizontal scrollbar, Xournal++ centres the
  -- view; scroll back to the left edge (keeping the vertical position).
  if widened and app.scrollToPos then
    local function toLeft() pcall(app.scrollToPos, -1e6, 0, true) end
    toLeft()
    if GI.GLib then
      GI.GLib.timeout_add(GI.GLib.PRIORITY_DEFAULT, 100, function() toLeft() return false end)
    end
  end
  state.lastSig = nil
  log("page %s became a canvas (%dx%d)", tostring(pageNo), math.floor(w), math.floor(h))

  if CONFIG.autoGrow and not installAutoHooks() and not state.warned then
    state.warned = true
    notify(T.no_gi_make)
  end
end

function infiniteCanvas_expandDown()
  local page = currentPage()
  local step = CONFIG.growStep
  if not isFreeCanvas(page) then
    local sp = ruledSpacing(page)
    step = sp and (CONFIG.paperGrowLines * sp) or CONFIG.paperGrowY
  end
  setSize(page.pageWidth, snapHeight(page, page.pageHeight + step))
  state.lastSig = nil
end

function infiniteCanvas_expandRight()
  local page = currentPage()
  setSize(page.pageWidth + (isFreeCanvas(page) and CONFIG.growStep or CONFIG.paperGrowX), page.pageHeight)
  state.lastSig = nil
end

-- Paper widths (pt) in both orientations: A5, A4, A3, Letter, Legal, Tabloid.
local PAPER_WIDTHS = { 419.53, 595.28, 841.89, 1190.55, 612, 792, 1008, 1224 }

local function isPaperWidth(w)
  for _, pw in ipairs(PAPER_WIDTHS) do
    if math.abs(w - pw) <= 1 then return true end
  end
  return false
end

local function pageKeyOf(doc)
  return tostring(doc.xoppFilename or "") .. "#" .. tostring(doc.currentPage)
end
state.pageKey = function() return pageKeyOf(app.getDocumentStructure()) end

-- Width and height of the default page template (Journal > Page Template),
-- read from Xournal++'s settings.xml.
local function templateSize()
  if not app.getFolder then return nil end
  local ok, cfg = pcall(app.getFolder, "config")
  if not ok or type(cfg) ~= "string" then return nil end
  local f = io.open(cfg .. "/settings.xml", "r")
  if not f then return nil end
  local xml = f:read("*a"); f:close()
  local tpl = xml:match('name="pageTemplate"%s+value="([^"]*)"') or ""
  local w, h = tpl:match("size=([%d%.]+)x([%d%.]+)")
  if w then return tonumber(w), tonumber(h) end
  return nil
end

-- The width a regular page should have after "fit page to content":
-- its original width if the plugin resized it in this session, its current
-- width if that is already a paper width, otherwise the smallest paper width
-- (other pages of the document, page template in both orientations) that
-- holds the content.
local function paperWidthFor(page, contentRight)
  local key = state.pageKey()
  local orig = state.original[key]
  if orig and isPaperWidth(orig.w) and orig.w >= contentRight then return orig.w end
  if isPaperWidth(page.pageWidth) and page.pageWidth >= contentRight then return page.pageWidth end
  local candidates = {}
  local doc = app.getDocumentStructure()
  for i, p in ipairs(doc.pages) do
    if i ~= doc.currentPage and isPaperWidth(p.pageWidth) then candidates[#candidates + 1] = p.pageWidth end
  end
  local tw, th = templateSize()
  if tw then candidates[#candidates + 1] = tw; candidates[#candidates + 1] = th end
  local best
  for _, c in ipairs(candidates) do
    if c >= contentRight and (not best or c < best) then best = c end
  end
  if not best then -- nothing known: smallest standard paper width that fits
    for _, c in ipairs(PAPER_WIDTHS) do
      if c >= contentRight and (not best or c < best) then best = c end
    end
  end
  return best
end

local function ruledFitHeight(page, maxY)
  local spacing = ruledSpacing(page)
  if not spacing then return nil end
  -- line index just below the content, plus one free line
  return ruledHeight(spacing, math.max(0, math.ceil((maxY - RULED_HEADER) / spacing)) + 1)
end

function infiniteCanvas_fit()
  local page = currentPage()
  local e = pageExtent()
  if e.count == 0 then
    -- empty PDF page: drop the extension and go back to the PDF's own size
    if hasPdfBackground(page) then
      local info = pdfInfo(page)
      if page.pageWidth > info.pdfW + 0.01 or page.pageHeight > info.pdfH + 0.01 then
        setSize(info.pdfW, info.pdfH)
      end
    end
    return -- empty page: nothing to fit to
  end
  local pad = CONFIG.fitPadding
  local canvas = isFreeCanvas(page) and isCanvasPage(page) and not hasPdfBackground(page)

  -- height: end just below the content; on ruled/lined paper, end on a full
  -- line followed by the paper's footer instead of cutting through it
  local h = ruledFitHeight(page, e.maxY) or (e.maxY + pad)
  h = math.max(CONFIG.minHeight, h)

  -- width: canvas pages are trimmed to the content; regular pages too, but
  -- never narrower than a normal sheet (or than they already are)
  local w
  if hasPdfBackground(page) then
    w = e.maxX + pad   -- setSize keeps at least the PDF size
    h = math.max(CONFIG.minHeight, e.maxY + pad)
  elseif canvas then
    w = math.max(CONFIG.minWidth, e.maxX + pad)
  else
    w = paperWidthFor(page, e.maxX) or (e.maxX + pad)
    -- never widen a page whose content already fits (custom narrow pages)
    if page.pageWidth >= e.maxX and w > page.pageWidth then w = page.pageWidth end
  end
  setSize(w, h)
  state.lastSig = nil
  log("fit: %dx%d -> %dx%d", page.pageWidth, page.pageHeight, math.floor(w), math.floor(h))
end

local function setExtensionStyle(style)
  local page = currentPage()
  if not hasPdfBackground(page) then notify(T.pdf_only) return end
  local info = pdfInfo(page)
  info.style = style
  CONFIG.pdfExtensionStyle = style -- also used for PDF pages extended later this session
  refreshExtension(info)
end

function infiniteCanvas_extBlank() setExtensionStyle("blank") end
function infiniteCanvas_extLined() setExtensionStyle("lined") end
function infiniteCanvas_extDotted() setExtensionStyle("dotted") end

function infiniteCanvas_toggleAuto()
  CONFIG.autoGrow = not CONFIG.autoGrow
  if CONFIG.autoGrow then
    if installAutoHooks() then
      notify(T.auto_on)
    else
      CONFIG.autoGrow = false
      notify(T.no_gi_toggle)
    end
  else
    notify(T.auto_off)
  end
  log("autoGrow = %s", tostring(CONFIG.autoGrow))
end

----------------------------------------------------------------------
-- UI registration
----------------------------------------------------------------------
function initUi()
  local lang = detectLanguage()
  T = STRINGS[lang] or STRINGS.en

  -- Ctrl+Shift (not Ctrl+Alt): on Windows Ctrl+Alt acts as AltGr, and on
  -- layouts such as Brazilian ABNT2 AltGr+C / AltGr+E type characters, so
  -- the shortcut never fires. These letters are free in Xournal++ 1.3
  -- (Ctrl+Shift+C belongs to the bundled LayerActions plugin).
  app.registerUi({ menu = T.menu_make, callback = "infiniteCanvas_make",
                   accelerator = "<Control><Shift>n",
                   toolbarId = "INFINITE_CANVAS_MAKE", iconName = "view-grid-symbolic" })
  app.registerUi({ menu = T.menu_down, callback = "infiniteCanvas_expandDown",
                   accelerator = "<Control><Shift>b",
                   toolbarId = "INFINITE_CANVAS_DOWN", iconName = "go-down" })
  app.registerUi({ menu = T.menu_right, callback = "infiniteCanvas_expandRight",
                   accelerator = "<Control><Shift>m",
                   toolbarId = "INFINITE_CANVAS_RIGHT", iconName = "go-next" })
  app.registerUi({ menu = T.menu_fit, callback = "infiniteCanvas_fit",
                   accelerator = "<Control><Shift>j" })
  app.registerUi({ menu = T.menu_toggle, callback = "infiniteCanvas_toggleAuto",
                   accelerator = "<Control><Shift>u" })
  app.registerUi({ menu = T.menu_ext_blank, callback = "infiniteCanvas_extBlank" })
  app.registerUi({ menu = T.menu_ext_lined, callback = "infiniteCanvas_extLined" })
  app.registerUi({ menu = T.menu_ext_dotted, callback = "infiniteCanvas_extDotted" })

  local dir = pluginDir()
  log("---- initUi (%s; language %s; folder via %s: %s)", _VERSION, lang, PLUGIN_DIR_HOW, tostring(dir))
  -- The hook only acts on canvas pages, so it can stay on from startup.
  if CONFIG.autoGrow then
    local ok, err = pcall(installAutoHooks)
    if not ok then log("installAutoHooks failed: %s", tostring(err)) end
  end
end
