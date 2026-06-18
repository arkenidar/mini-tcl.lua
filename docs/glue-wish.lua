-- wish glue (fengari): loads the interpreter core + canvas.lua + tk.lua,
-- wires canvas.lua's web backend to the JS canvas functions defined by wish.js,
-- exposes evalTk(line) to the page, and starts the render loop.
--
-- Expects these JS globals to be set before loading: MINITCL_SOURCE,
-- MINITCL_CANVAS_SOURCE, MINITCL_TK_SOURCE (the three .lua source texts), and
-- the window.js_canvas_* / js_poll_event / MiniTk functions from wish.js.

local js = require "js"
local g = js.global
local load = loadstring or load

local function source(name)
    local s = g[name]
    if type(s) ~= "string" then error(name .. " not set") end
    return s
end

-- Lua-global wrappers around the JS canvas functions. canvas.lua's web branch
-- guards on `type(js_canvas_line) == "function"`, and a raw JS proxy is not a Lua
-- function — so we wrap each one.
--
-- Fengari calling convention: when Lua calls a JS function, the FIRST Lua
-- argument becomes JS `this` and the rest become the JS arguments. So for a
-- plain window function we pass `g` (the global) as the receiver, and the real
-- arguments follow; for a method we use `:` so the object is the receiver.
-- (Window/height return floats, so size() floors to ints for clean parsing.)
_G.js_canvas_color = function(r, gn, b, a) g.js_canvas_color(g, r, gn, b, a) end
_G.js_canvas_clear = function() g.js_canvas_clear(g) end
_G.js_canvas_pixel = function(x, y) g.js_canvas_pixel(g, x, y) end
_G.js_canvas_line  = function(a, b, c, d) g.js_canvas_line(g, a, b, c, d) end
_G.js_canvas_rect  = function(x, y, w, h) g.js_canvas_rect(g, x, y, w, h) end
_G.js_canvas_fill  = function(x, y, w, h) g.js_canvas_fill(g, x, y, w, h) end
_G.js_canvas_text  = function(x, y, s) g.js_canvas_text(g, x, y, s) end
_G.js_canvas_ticks = function() return g.js_canvas_ticks(g) end
_G.js_canvas_size  = function()
    return math.floor(g.js_canvas_width(g)), math.floor(g.js_canvas_height(g))
end
_G.js_poll_event   = function() return g.js_poll_event(g) end
_G.js_loop_start   = function() g.MiniTk:start(_G.__canvas_loop_body) end

-- Capture interpreter output (puts) instead of writing to a (nonexistent) stdout.
local buf = {}
local function emit(s) buf[#buf + 1] = s end
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    emit(table.concat(parts, "\t") .. "\n")
end
if not _G.io then _G.io = {} end
io.write = function(...)
    for i = 1, select("#", ...) do emit(tostring(select(i, ...))) end
end

-- Load core (embed mode -> returns Tcl table, sets _G.minitcl), then the bridges.
_G.MINI_TCL_EMBED = true
local tcl = assert(load(source("MINITCL_SOURCE"), "@mini-tcl.lua"))()
assert(load(source("MINITCL_CANVAS_SOURCE"), "@canvas.lua"))()  -- activates web branch
assert(load(source("MINITCL_TK_SOURCE"), "@tk.lua"))()          -- sets __canvas_loop_body

-- Commands that make no sense in a web page.
local function unavailable(name)
    tcl.commands[name] = function()
        return tcl.codes.ERROR, "\"" .. name .. "\" is not available in the browser"
    end
end
unavailable("exit")
unavailable("source")

-- Evaluate one REPL line; return captured output (+ value/error), wish-style.
g.evalTk = function(_, line)
    buf = {}
    local code, val = tcl.evalScript(tostring(line), tcl.globals)
    local out = table.concat(buf)
    if code == tcl.codes.ERROR then
        out = out .. "error: " .. tostring(val) .. "\n"
    elseif code ~= tcl.codes.OK then
        out = out .. "error: invoked \"break\"/\"continue\" outside of a loop\n"
    elseif val ~= nil and val ~= "" then
        out = out .. tostring(val) .. "\n"
    end
    return out
end

-- Start the render/event loop (the browser drives it via requestAnimationFrame).
-- `:` so MiniTk is the JS receiver and the loop body is the first real argument.
g.MiniTk:start(_G.__canvas_loop_body)
