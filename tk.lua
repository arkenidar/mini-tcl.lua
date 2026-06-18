-- tk.lua — a Tk essence for mini-tcl.
--
-- A minimal but authentic Tk widget toolkit layered purely on the interpreter's
-- open command registry. It never touches SDL or JS: it draws through the
-- canvas.* commands (from canvas.lua) and reads input through tcl.poll_event, so
-- the same TCL script runs on every backend that canvas.lua supports.
--
-- Authentic Tk surface:
--   frame/label/button/entry/checkbutton/scale/canvas  (creation)
--   pack / grid                                          (geometry)
--   bind / focus / winfo / wm / update                  (control)
-- Each widget path (".b") also becomes a command: ".b configure -text X",
-- ".b cget -text", ".b invoke" — reproduced with the same registry trick proc
-- uses to register a command from within a command.

local tcl     = minitcl
local OK      = tcl.codes.OK
local ERR     = tcl.codes.ERROR
local cmds    = tcl.commands
local ev      = tcl.evalScript
local globals = tcl.globals

-- ---- drawing helpers (route through canvas.* so a mock backend can record) --
local function c_call(name, a, b, c, d)
    local fn = cmds[name]
    if not fn then return end
    fn({ name, a and tostring(a), b and tostring(b),
         c and tostring(c), d and tostring(d) }, globals)
end

local NAMED = {
    white="255 255 255", black="0 0 0", red="220 60 60", green="60 200 90",
    blue="80 140 240", gray="128 128 128", grey="128 128 128",
    yellow="230 210 60", orange="235 150 60", cyan="60 200 220",
    ["dark gray"]="64 64 64", ["light gray"]="200 200 200",
}
local function rgb(spec)
    spec = tostring(spec or "")
    if NAMED[spec] then spec = NAMED[spec] end
    local r, g, b = spec:match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
    return tonumber(r) or 128, tonumber(g) or 128, tonumber(b) or 128
end

local function color(spec) local r, g, b = rgb(spec); c_call("canvas.color", r, g, b) end
local function color3(r, g, b) c_call("canvas.color", r, g, b) end
local function fill(x, y, w, h) c_call("canvas.fill", x, y, w, h) end
local function rect(x, y, w, h) c_call("canvas.rect", x, y, w, h) end
local function line(a, b, c, d) c_call("canvas.line", a, b, c, d) end
local function text(x, y, s)
    local fn = cmds["canvas.text"]; if fn then fn({ "canvas.text", tostring(x), tostring(y), tostring(s) }, globals) end
end

local function win_size()
    local fn = cmds["canvas.size"]
    if fn then
        local _, s = fn({ "canvas.size" }, globals)
        local w, h = tostring(s):match("(%d+)%s+(%d+)")
        if w then return tonumber(w), tonumber(h) end
    end
    return 640, 480
end

local function num(x) return tonumber(x) or 0 end
local function truthy(v)
    v = tostring(v or "")
    return v == "1" or v == "true" or v == "yes" or v == "on" or (tonumber(v) or 0) ~= 0
end

-- ---- widget store ----------------------------------------------------------
local CHARW, CHARH = 8, 16
local W, order = {}, {}
local bindings = {}
local focus = nil
local root = { class = "toplevel", path = ".", opts = { title = "mini-tk" },
               children = {}, geom = { x = 0, y = 0, w = 640, h = 480 } }
W["."] = root

local function parent_of(path)
    if path == "." then return nil end
    local dot = path:find("%.[^.]*$")
    if not dot or dot == 1 then return "." end
    return path:sub(1, dot - 1)
end

local function parse_opts(words, start, opts)
    local i = start
    while words[i] do
        local k = tostring(words[i]):gsub("^%-", "")
        opts[k] = words[i + 1]
        i = i + 2
    end
end

local function text_w(s) return #tostring(s) * CHARW end

-- Caption to display: -textvariable (live) wins over a static -text, matching Tk
-- for label/button/checkbutton/radiobutton.
local function shown_text(k)
    local v = k.opts.textvariable
    if v and v ~= "" then return tostring(globals[v] or "") end
    return tostring(k.opts.text or "")
end

-- ---- requested (natural) size ---------------------------------------------
local function req_size(k)
    local o = k.opts
    if k.class == "label" then return text_w(shown_text(k)) + 12, CHARH + 8
    elseif k.class == "button" then return text_w(shown_text(k)) + 20, CHARH + 12
    elseif k.class == "entry" then return num(o.width) * CHARW + 10, CHARH + 10
    elseif k.class == "checkbutton" then return 22 + text_w(shown_text(k)), CHARH + 8
    elseif k.class == "scale" then
        if o.orient == "vertical" then return 28, num(o.length) end
        return num(o.length), 28
    elseif k.class == "canvas" then return num(o.width), num(o.height)
    elseif k.class == "frame" or k.class == "toplevel" then
        return math.max(num(o.width), 20), math.max(num(o.height), 20)
    end
    return 40, 20
end

-- ---- layout (pack + grid) --------------------------------------------------
local layout_children, pack_children, grid_children

function layout_children(parent)
    local mgr
    for _, cp in ipairs(parent.children) do
        local k = W[cp]
        if k and k.manager then mgr = k.manager; break end
    end
    if mgr == "pack" then pack_children(parent)
    elseif mgr == "grid" then grid_children(parent) end
end

function pack_children(parent)
    local g = parent.geom
    local kids = {}
    for _, cp in ipairs(parent.children) do
        local k = W[cp]
        if k and k.manager == "pack" then kids[#kids + 1] = k end
    end
    -- leftover space distributed equally among expanders, per packing axis
    local usedV, usedH, expV, expH = 0, 0, 0, 0
    for _, k in ipairs(kids) do
        local po = k.packopts
        local rw, rh = req_size(k)
        if po.side == "top" or po.side == "bottom" then
            usedV = usedV + rh + 2 * num(po.pady)
            if truthy(po.expand) then expV = expV + 1 end
        else
            usedH = usedH + rw + 2 * num(po.padx)
            if truthy(po.expand) then expH = expH + 1 end
        end
    end
    local extraV = expV > 0 and math.max(0, g.h - usedV) / expV or 0
    local extraH = expH > 0 and math.max(0, g.w - usedH) / expH or 0

    local x0, y0, x1, y1 = g.x, g.y, g.x + g.w, g.y + g.h
    for _, k in ipairs(kids) do
        local po = k.packopts
        local rw, rh = req_size(k)
        local px, py = num(po.padx), num(po.pady)
        local side = po.side
        local parcel
        if side == "top" or side == "bottom" then
            local strip = rh + 2 * py + (truthy(po.expand) and extraV or 0)
            local sy = (side == "top") and y0 or (y1 - strip)
            parcel = { x = x0, y = sy, w = x1 - x0, h = strip }
            if side == "top" then y0 = y0 + strip else y1 = y1 - strip end
        else
            local strip = rw + 2 * px + (truthy(po.expand) and extraH or 0)
            local sx = (side == "left") and x0 or (x1 - strip)
            parcel = { x = sx, y = y0, w = strip, h = y1 - y0 }
            if side == "left" then x0 = x0 + strip else x1 = x1 - strip end
        end
        local fillo = po.fill or "none"
        local cw = (fillo == "x" or fillo == "both") and (parcel.w - 2 * px) or rw
        local ch = (fillo == "y" or fillo == "both") and (parcel.h - 2 * py) or rh
        k.geom = {
            x = parcel.x + (parcel.w - cw) / 2,
            y = parcel.y + (parcel.h - ch) / 2,
            w = cw, h = ch,
        }
        if #k.children > 0 then layout_children(k) end
    end
end

function grid_children(parent)
    local g = parent.geom
    local kids = {}
    for _, cp in ipairs(parent.children) do
        local k = W[cp]
        if k and k.manager == "grid" then kids[#kids + 1] = k end
    end
    local colw, rowh = {}, {}
    local maxc, maxr = 0, 0
    for _, k in ipairs(kids) do
        local go = k.gridopts
        local rw, rh = req_size(k)
        local c, r = num(go.column), num(go.row)
        local cs = math.max(1, num(go.columnspan))
        if cs == 1 then colw[c] = math.max(colw[c] or 0, rw) end
        rowh[r] = math.max(rowh[r] or 0, rh)
        maxc = math.max(maxc, c + cs - 1)
        maxr = math.max(maxr, r)
    end
    for c = 0, maxc do colw[c] = colw[c] or 40 end
    for r = 0, maxr do rowh[r] = rowh[r] or 20 end
    local colx, acc = {}, g.x
    for c = 0, maxc do colx[c] = acc; acc = acc + colw[c] + 6 end
    local rowy; acc = g.y; rowy = {}
    for r = 0, maxr do rowy[r] = acc; acc = acc + rowh[r] + 6 end

    for _, k in ipairs(kids) do
        local go = k.gridopts
        local rw, rh = req_size(k)
        local c, r = num(go.column), num(go.row)
        local cs = math.max(1, num(go.columnspan))
        local cellw = 0
        for cc = c, c + cs - 1 do cellw = cellw + (colw[cc] or 40) + 6 end
        cellw = cellw - 6
        local cellh = rowh[r]
        local st = go.sticky or ""
        local ww = (st:find("e") and st:find("w")) and cellw or rw
        local hh = (st:find("n") and st:find("s")) and cellh or rh
        local gx = st:find("w") and colx[c]
            or (st:find("e") and (colx[c] + cellw - ww) or (colx[c] + (cellw - ww) / 2))
        local gy = st:find("n") and rowy[r]
            or (st:find("s") and (rowy[r] + cellh - hh) or (rowy[r] + (cellh - hh) / 2))
        k.geom = { x = gx, y = gy, w = ww, h = hh }
        if #k.children > 0 then layout_children(k) end
    end
end

local function relayout()
    local w, h = win_size()
    root.geom = { x = 0, y = 0, w = w, h = h }
    layout_children(root)
end

-- ---- rendering -------------------------------------------------------------
local function entry_value(k)
    local v = k.opts.textvariable
    if v and v ~= "" then return tostring(globals[v] or "") end
    return tostring(k.opts.text or "")
end

local function draw_canvas_items(k)
    local g = k.geom
    for _, it in ipairs(k.items or {}) do
        color(it.fill or "200 200 200")
        if it.kind == "rectangle" then
            fill(g.x + it.x1, g.y + it.y1, it.x2 - it.x1, it.y2 - it.y1)
        elseif it.kind == "line" then
            line(g.x + it.x1, g.y + it.y1, g.x + it.x2, g.y + it.y2)
        elseif it.kind == "text" then
            text(g.x + it.x1, g.y + it.y1, it.text)
        end
    end
end

local function draw_widget(k)
    local g, o = k.geom, k.opts
    if k.class == "frame" or k.class == "toplevel" then
        color(o.background or "40 40 40"); fill(g.x, g.y, g.w, g.h)
    elseif k.class == "label" then
        color(o.background or "40 40 40"); fill(g.x, g.y, g.w, g.h)
        color(o.foreground or "220 220 220")
        text(g.x + 6, g.y + (g.h - CHARH) / 2, shown_text(k))
    elseif k.class == "button" then
        color(o.background or "90 90 90"); fill(g.x, g.y, g.w, g.h)
        color3(230, 230, 230); rect(g.x, g.y, g.w, g.h)
        color(o.foreground or "240 240 240")
        text(g.x + 10, g.y + (g.h - CHARH) / 2, shown_text(k))
    elseif k.class == "entry" then
        color(o.background or "20 20 20"); fill(g.x, g.y, g.w, g.h)
        color3(120, 120, 120); rect(g.x, g.y, g.w, g.h)
        local val = entry_value(k)
        color(o.foreground or "240 240 240")
        text(g.x + 5, g.y + (g.h - CHARH) / 2, val)
        if focus == k.path then
            local cx = g.x + 5 + text_w(val)
            color3(240, 240, 240); line(cx, g.y + 4, cx, g.y + g.h - 4)
        end
    elseif k.class == "checkbutton" then
        color(o.background or "40 40 40"); fill(g.x, g.y, g.w, g.h)
        local bx, by = g.x + 2, g.y + (g.h - 14) / 2
        color3(200, 200, 200); rect(bx, by, 14, 14)
        if o.variable and o.variable ~= "" and truthy(globals[o.variable]) then
            color3(80, 200, 120); fill(bx + 3, by + 3, 8, 8)
        end
        color(o.foreground or "220 220 220")
        text(g.x + 20, g.y + (g.h - CHARH) / 2, shown_text(k))
    elseif k.class == "scale" then
        color3(60, 60, 60); fill(g.x, g.y + g.h / 2 - 2, g.w, 4)
        local val = (o.variable and o.variable ~= "") and num(globals[o.variable]) or num(o.from)
        local span = math.max(1, num(o.to) - num(o.from))
        local frac = (val - num(o.from)) / span
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local kx = g.x + frac * (g.w - 12)
        color3(200, 200, 200); fill(kx, g.y + g.h / 2 - 8, 12, 16)
    elseif k.class == "canvas" then
        color(o.background or "0 0 0"); fill(g.x, g.y, g.w, g.h)
        draw_canvas_items(k)
    end
end

local function draw_all()
    color3(30, 30, 30)
    if cmds["canvas.clear"] then cmds["canvas.clear"]({ "canvas.clear" }, globals) end
    color(root.opts.background or "40 40 40"); fill(0, 0, root.geom.w, root.geom.h)
    for _, p in ipairs(order) do
        local k = W[p]; if k then draw_widget(k) end
    end
    if cmds["canvas.present"] then cmds["canvas.present"]({ "canvas.present" }, globals) end
end

-- ---- event dispatch --------------------------------------------------------
local mouse = { x = 0, y = 0, drag = nil }

local function hit(k, x, y)
    local g = k.geom
    return x >= g.x and x < g.x + g.w and y >= g.y and y < g.y + g.h
end

local function widget_at(x, y)
    for i = #order, 1, -1 do
        local k = W[order[i]]
        if k and hit(k, x, y) then return k end
    end
    return nil
end

local function fire(k, event)
    local b = bindings[k.path]
    if b and b[event] then ev(b[event], globals) end
end

local function set_scale(k, x)
    if k.opts.variable and k.opts.variable ~= "" then
        local g = k.geom
        local frac = (x - g.x) / math.max(1, g.w - 12)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local val = num(k.opts.from) + frac * (num(k.opts.to) - num(k.opts.from))
        globals[k.opts.variable] = tostring(math.floor(val + 0.5))
        fire(k, "<Motion>")
    end
end

local function handle(tok)
    local p = {}
    for w in tok:gmatch("%S+") do p[#p + 1] = w end
    local kind = p[1]
    if kind == "quit" then
        _G.__tk_running = false
    elseif kind == "mouse" then
        local act, x, y = p[2], num(p[3]), num(p[4])
        mouse.x, mouse.y = x, y
        if act == "down" then
            local k = widget_at(x, y)
            if k then
                if k.class == "entry" then focus = k.path
                elseif k.class == "checkbutton" and k.opts.variable ~= "" then
                    globals[k.opts.variable] = truthy(globals[k.opts.variable]) and "0" or "1"
                elseif k.class == "scale" then mouse.drag = k; set_scale(k, x) end
                mouse.press = k.path
                fire(k, "<Button-1>")
            else focus = nil end
        elseif act == "up" then
            local k = widget_at(x, y)
            if k then
                if k.class == "button" and k.path == mouse.press
                    and k.opts.command and k.opts.command ~= "" then
                    ev(k.opts.command, globals)
                end
                fire(k, "<ButtonRelease-1>")
            end
            mouse.drag, mouse.press = nil, nil
        elseif act == "move" then
            if mouse.drag then set_scale(mouse.drag, x) end
            local k = widget_at(x, y)
            if k then fire(k, "<Motion>") end
        end
    elseif kind == "text" then
        if focus then
            local k = W[focus]
            local s = tok:sub(6)
            local var = k.opts.textvariable
            if var and var ~= "" then globals[var] = (globals[var] or "") .. s
            else k.opts.text = (k.opts.text or "") .. s end
            fire(k, "<Key>")
        end
    elseif kind == "key" then
        local key = p[2]
        if focus and (key == "Backspace" or key == "BackSpace") then
            local k = W[focus]
            local var = k.opts.textvariable
            if var and var ~= "" then
                globals[var] = tostring(globals[var] or ""):sub(1, -2)
            else k.opts.text = tostring(k.opts.text or ""):sub(1, -2) end
        end
        if focus then fire(W[focus], "<Key>") end
    end
end

local function pump_events()
    local poll = tcl.poll_event
    if not poll then return end
    while true do
        local tok = poll()
        if not tok or tok == "" then break end
        handle(tok)
    end
end

local function frame_step()
    pump_events()
    relayout()
    draw_all()
end

-- ---- per-widget command ----------------------------------------------------
local function canvas_sub(k, words)
    local sub = words[2]
    if sub == "create" then
        local kind = words[3]
        k.items = k.items or {}
        local it = { kind = kind, id = (#k.items + 1) }
        if kind == "text" then
            it.x1, it.y1 = num(words[4]), num(words[5])
            local o = {}; parse_opts(words, 6, o)
            it.text = o.text or ""; it.fill = o.fill
        else
            it.x1, it.y1 = num(words[4]), num(words[5])
            it.x2, it.y2 = num(words[6]), num(words[7])
            local o = {}; parse_opts(words, 8, o)
            it.fill = o.fill
        end
        k.items[#k.items + 1] = it
        return OK, tostring(it.id)
    elseif sub == "delete" then
        k.items = {}
        return OK, ""
    end
    return OK, ""
end

local function register_widget_command(path)
    cmds[path] = function(words)
        local k = W[path]
        if not k then return ERR, "bad window path name \"" .. path .. "\"" end
        local sub = words[2]
        if sub == "configure" or sub == "config" or sub == "conf" then
            parse_opts(words, 3, k.opts); return OK, ""
        elseif sub == "cget" then
            local key = tostring(words[3] or ""):gsub("^%-", "")
            return OK, tostring(k.opts[key] or "")
        elseif sub == "invoke" then
            if k.opts.command and k.opts.command ~= "" then return ev(k.opts.command, globals) end
            return OK, ""
        elseif k.class == "canvas" then
            return canvas_sub(k, words)
        end
        return OK, ""
    end
end

-- ---- creation commands -----------------------------------------------------
local function maker(class, defaults)
    return function(words)
        local path = words[2]
        if not path then return ERR, "wrong # args: should be \"" .. class .. " pathName ?-option value ...?\"" end
        local k = { class = class, path = path, opts = {}, children = {},
                    geom = { x = 0, y = 0, w = 0, h = 0 } }
        for dk, dv in pairs(defaults) do k.opts[dk] = dv end
        parse_opts(words, 3, k.opts)
        W[path] = k
        order[#order + 1] = path
        k.parent = parent_of(path)
        if k.parent and W[k.parent] then table.insert(W[k.parent].children, path) end
        register_widget_command(path)
        return OK, path
    end
end

cmds["frame"]       = maker("frame", { background = "40 40 40", width = 0, height = 0, relief = "flat" })
cmds["label"]       = maker("label", { text = "", background = "40 40 40", foreground = "220 220 220" })
cmds["button"]      = maker("button", { text = "", command = "", background = "90 90 90", foreground = "240 240 240", relief = "raised" })
cmds["entry"]       = maker("entry", { textvariable = "", text = "", background = "20 20 20", foreground = "240 240 240", width = 15 })
cmds["checkbutton"] = maker("checkbutton", { text = "", variable = "", background = "40 40 40", foreground = "220 220 220" })
cmds["scale"]       = maker("scale", { from = 0, to = 100, variable = "", length = 120, orient = "horizontal" })
cmds["canvas"]      = maker("canvas", { background = "0 0 0", width = 200, height = 120 })

-- ---- geometry commands -----------------------------------------------------
cmds["pack"] = function(words)
    local paths, i = {}, 2
    while words[i] and tostring(words[i]):sub(1, 1) ~= "-" do
        paths[#paths + 1] = words[i]; i = i + 1
    end
    local po = { side = "top", fill = "none", expand = "0", padx = "0", pady = "0" }
    parse_opts(words, i, po)
    for _, p in ipairs(paths) do
        local k = W[p]
        if k then
            k.manager = "pack"
            k.packopts = {}
            for ok, ov in pairs(po) do k.packopts[ok] = ov end
        end
    end
    return OK, ""
end

cmds["grid"] = function(words)
    local p = words[2]
    local go = { row = "0", column = "0", sticky = "", columnspan = "1", rowspan = "1", padx = "0", pady = "0" }
    parse_opts(words, 3, go)
    local k = W[p]
    if k then k.manager = "grid"; k.gridopts = go end
    return OK, ""
end

-- ---- control commands ------------------------------------------------------
cmds["bind"] = function(words)
    local path, event, script = words[2], words[3], words[4]
    if not path then return OK, "" end
    bindings[path] = bindings[path] or {}
    if script == nil then return OK, bindings[path][event] or "" end
    bindings[path][event] = script
    return OK, ""
end

cmds["focus"] = function(words)
    if words[2] then focus = words[2]; return OK, "" end
    return OK, focus or ""
end

cmds["winfo"] = function(words)
    local q, path = words[2], words[3]
    local k = W[path]
    if q == "exists" then return OK, k and "1" or "0" end
    if not k then return ERR, "bad window path name \"" .. tostring(path) .. "\"" end
    local g = k.geom
    if q == "x" then return OK, tostring(math.floor(g.x + 0.5))
    elseif q == "y" then return OK, tostring(math.floor(g.y + 0.5))
    elseif q == "width" then return OK, tostring(math.floor(g.w + 0.5))
    elseif q == "height" then return OK, tostring(math.floor(g.h + 0.5))
    elseif q == "class" then return OK, k.class end
    return OK, ""
end

cmds["wm"] = function(words)
    local sub, path = words[2], words[3]
    local k = W[path] or root
    if sub == "title" then
        if words[4] then k.opts.title = words[4]; return OK, "" end
        return OK, k.opts.title or ""
    elseif sub == "geometry" then
        local geo = words[4]
        if geo then
            local w, h = tostring(geo):match("(%d+)x(%d+)")
            if w then root.geom.w, root.geom.h = tonumber(w), tonumber(h) end
        end
        return OK, ""
    end
    return OK, ""
end

-- `update` / `tkwait` / `mainloop`: re-layout + redraw + drain events. Works
-- headless (no backend) too, so the same script is testable off-screen.
cmds["update"] = function() frame_step(); return OK, "" end
cmds["tkwait"] = function() frame_step(); return OK, "" end

-- The host drives the real loop. tk publishes the per-frame body as a Lua
-- function so main-sdl.c's run_loop calls update+draw at ~60fps; the C launcher
-- starts the loop after the user script (wish's implicit mainloop).
_G.__tk_running = true
_G.__canvas_loop_body = frame_step

-- expose internals for headless tests / embedders
tcl.tk = { widgets = W, step = frame_step, layout = relayout, draw = draw_all,
           events = pump_events }
