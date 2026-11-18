--[[
  InfiniteCanvas — a Xournal++ plugin (tested on Xournal++ 1.3.4)
  https://github.com/JeanCarlos0112/xournalpp-infinite-canvas

  Turns the current page into a dotted "canvas" that grows to the right and
  downwards as you write near its edges. The page starts small and only grows
  when needed, so exports stay compact (use "Fit page to content" before
  exporting to trim the empty space).

  Shortcuts (also in the Plugin menu):
    Ctrl+Shift+N  New canvas: turn the current page into a dotted canvas
    Ctrl+Shift+B  Expand downwards now
    Ctrl+Shift+M  Expand to the right now ("more width")
    Ctrl+Shift+J  Fit the page to its content (shrinks or grows, plus padding)
    Ctrl+Shift+U  Toggle auto-grow

  How auto-grow works:
    The Lua API has no events ("stroke finished") and no timers. The plugin uses
    LuaGObject (the lgi fork bundled with Xournal++ 1.3) to listen to GTK: a
    capture-phase GtkGestureDrag on the main window reports when the pen/mouse
    is lifted; ~120 ms later the plugin checks whether the content got close
    to the right/bottom edge and enlarges the page if so. The gesture never
    claims the event sequence, so Xournal++ input is untouched.
    Fallbacks: periodic polling if GTK can't be reached; manual shortcuts if
    LuaGObject is missing.

  Limitations (Lua API):
    * Grows only to the right and downwards (existing strokes can't be moved).
    * Each resize is an undo step: Ctrl+Z undoes the growth before the stroke.
    * Auto-grow looks at the current layer (the one you are writing on).

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
  minWidth         = 600,   -- minimum size for "fit page to content"
  minHeight        = 800,
  edgeMargin       = 200,   -- content closer than this to an edge => grow
  growStep         = 800,   -- how much to grow each time (pt)
  fitPadding       = 300,   -- padding kept by "fit page to content"
  background       = "dotted",
  autoGrow         = true,  -- auto-grow starts enabled
  onlyDottedPages  = true,  -- auto-grow only touches dotted pages
  autoGrowPdfPages = false, -- experimental: also auto-grow pages with a PDF
                            -- background (the PDF is not stretched; the new
                            -- area is left unpainted)
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
    pdf_page    = "This page has a PDF background, so it was not turned into a dotted canvas "
               .. "(that would remove the PDF).\n\nUse Ctrl+Shift+M / Ctrl+Shift+B to add space "
               .. "beside or below the PDF.",
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
    pdf_page    = "Esta página tem fundo de PDF, então não foi transformada em canvas pontilhado "
               .. "(isso apagaria o PDF).\n\nUse Ctrl+Shift+M / Ctrl+Shift+B para abrir espaço "
               .. "ao lado ou abaixo do PDF.",
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

local function isCanvasPage(page)
  if hasPdfBackground(page) then return CONFIG.autoGrowPdfPages end
  if not CONFIG.onlyDottedPages then return true end
  local fmt = tostring(page.pageTypeFormat or "")
  return fmt == "dotted" or fmt == ":dotted"
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
local function pageExtent()
  local page = currentPage()
  local cur = page and page.currentLayer or 0
  local n = page and #page.layers or 0
  if not app.setCurrentLayer or n <= 1 or cur < 1 then
    return layerExtent()
  end
  local e = newExtent()
  for i = 1, n do
    if pcall(app.setCurrentLayer, i, false) then layerExtent(e) end
  end
  pcall(app.setCurrentLayer, cur, false)
  return e
end

local function setSize(w, h)
  if not app.setPageSize then
    notify(T.no_setsize)
    return false
  end
  local page = currentPage()
  local widthChanged = page and math.floor(w + 0.5) ~= math.floor(page.pageWidth + 0.5)
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

  app.setPageSize(math.floor(w + 0.5), math.floor(h + 0.5))

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
local function growIfNeeded(page, maxX, maxY)
  local w, h = page.pageWidth, page.pageHeight
  local newW, newH = w, h
  while maxX > newW - CONFIG.edgeMargin do newW = newW + CONFIG.growStep end
  while maxY > newH - CONFIG.edgeMargin do newH = newH + CONFIG.growStep end
  if newW ~= w or newH ~= h then
    return setSize(newW, newH), newW, newH
  end
  return false, w, h
end

----------------------------------------------------------------------
-- Auto-grow check
----------------------------------------------------------------------
local function autoCheck(reason)
  if state.busy or not CONFIG.autoGrow then return end
  state.busy = true
  local ok, err = pcall(function()
    local page = currentPage()
    if not page or not isCanvasPage(page) then return end
    if reason == "safety" and os.time() - state.lastPenUp < 3 then
      return -- the pen hook is working; nothing to do
    end
    local e = layerExtent()
    if e.count == 0 then return end
    if reason ~= "pen" then
      if e.sig == state.lastSig then return end
    end
    state.lastSig = e.sig
    local grew, w, h = growIfNeeded(page, e.maxX, e.maxY)
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
    -- changing the background would drop the PDF
    notify(T.pdf_page)
    return
  end
  app.changeCurrentPageBackground(CONFIG.background)
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
  setSize(page.pageWidth, page.pageHeight + CONFIG.growStep)
  state.lastSig = nil
end

function infiniteCanvas_expandRight()
  local page = currentPage()
  setSize(page.pageWidth + CONFIG.growStep, page.pageHeight)
  state.lastSig = nil
end

function infiniteCanvas_fit()
  local e = pageExtent()
  if e.count == 0 then
    setSize(CONFIG.initialWidth, CONFIG.initialHeight)
  else
    setSize(math.max(CONFIG.minWidth, e.maxX + CONFIG.fitPadding),
            math.max(CONFIG.minHeight, e.maxY + CONFIG.fitPadding))
  end
  state.lastSig = nil
end

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

  local dir = pluginDir()
  log("---- initUi (%s; language %s; folder via %s: %s)", _VERSION, lang, PLUGIN_DIR_HOW, tostring(dir))
  -- The hook only acts on canvas pages, so it can stay on from startup.
  if CONFIG.autoGrow then
    local ok, err = pcall(installAutoHooks)
    if not ok then log("installAutoHooks failed: %s", tostring(err)) end
  end
end
