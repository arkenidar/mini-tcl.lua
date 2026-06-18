-- Headless harness for the *web* backend: like tk-headless.lua, but it defines
-- the js_canvas_* / js_poll_event globals (and deliberately NOT sdl_line) so
-- canvas.lua selects its `elseif type(js_canvas_line) == "function"` branch.
-- Running the same scenario through the web wiring must yield the same
-- transcript as the SDL path — proving "same script, unmodified, on web".
--
-- Usage: lua tests/tk-web-headless.lua tests/tk-layout.tcl  (from the repo root)

local EVENTS = {}
local TEXTS = {}      -- glyphs drawn this frame; reset on clear (frame start)
local function noop() end
_G.js_canvas_color, _G.js_canvas_present = noop, noop
_G.js_canvas_pixel, _G.js_canvas_line, _G.js_canvas_rect, _G.js_canvas_fill = noop, noop, noop, noop
function _G.js_canvas_clear() TEXTS = {} end
function _G.js_canvas_text(_, _, s) TEXTS[#TEXTS + 1] = tostring(s) end
function _G.js_canvas_ticks() return 0 end
function _G.js_canvas_size() return 400, 300 end   -- web size() returns two values
function _G.js_loop_start() end                    -- rAF in the browser; no-op here
function _G.js_poll_event() return table.remove(EVENTS, 1) or "" end

-- Resolve the repo root from this script's own path, so it runs from anywhere.
local here = (arg[0] or ""):match("(.*[/\\])") or "./"
local root = here .. ".." .. package.config:sub(1, 1)

_G.MINI_TCL_EMBED = true
local tcl = dofile(root .. "mini-tcl.lua")
dofile(root .. "canvas.lua")
dofile(root .. "tk.lua")

tcl.commands["event"] = function(words)
    local parts = {}
    for i = 2, #words do parts[#parts + 1] = tostring(words[i]) end
    EVENTS[#EVENTS + 1] = table.concat(parts, " ")
    return tcl.codes.OK, ""
end

tcl.commands["drawntext"] = function()
    return tcl.codes.OK, table.concat(TEXTS, "|")
end

local path = arg[1] or error("usage: lua tests/tk-web-headless.lua script.tcl")
local f = assert(io.open(path, "r"))
local src = f:read("*a"); f:close()

local code, val = tcl.evalScript(src, tcl.globals)
if code == tcl.codes.ERROR then
    io.stderr:write("tk-web-headless: " .. tostring(val) .. "\n")
    os.exit(1)
end
