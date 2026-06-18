-- Headless harness for the Tk essence: loads the real core + canvas.lua + tk.lua
-- under a *mock* canvas backend, so the widget/geometry/dispatch logic runs with
-- zero SDL/display dependency and can be transcript-diffed across Lua versions.
--
-- Usage: lua tests/tk-headless.lua tests/tk-layout.tcl
-- Run from the repository root.

-- A mock backend: drawing is a no-op (we assert via winfo + variables, which is
-- robust), the window is a fixed 400x300, and input comes from a scripted queue.
local EVENTS = {}
local TEXTS = {}      -- glyphs drawn this frame; reset on clear (frame start)
local function noop() end
_G.sdl_color, _G.sdl_present = noop, noop
_G.sdl_pixel, _G.sdl_line, _G.sdl_rect, _G.sdl_fill = noop, noop, noop, noop
function _G.sdl_clear() TEXTS = {} end
function _G.sdl_text(_, _, s) TEXTS[#TEXTS + 1] = tostring(s) end
function _G.sdl_ticks() return 0 end
function _G.sdl_size() return 400, 300 end
function _G.sdl_loop_start() end          -- never block in the test
function _G.sdl_poll_event() return table.remove(EVENTS, 1) or "" end

-- Resolve the repo root from this script's own path, so it runs from anywhere.
local here = (arg[0] or ""):match("(.*[/\\])") or "./"
local root = here .. ".." .. package.config:sub(1, 1)

-- Load the interpreter core (embed mode) then the two bridge files.
_G.MINI_TCL_EMBED = true
local tcl = dofile(root .. "mini-tcl.lua")
dofile(root .. "canvas.lua")
dofile(root .. "tk.lua")

-- A tiny TCL command to feed the input queue: `event mouse down 200 10`.
tcl.commands["event"] = function(words)
    local parts = {}
    for i = 2, #words do parts[#parts + 1] = tostring(words[i]) end
    EVENTS[#EVENTS + 1] = table.concat(parts, " ")
    return tcl.codes.OK, ""
end

-- `drawntext`: the glyph strings drawn in the most recent frame, "|"-joined.
-- Lets the scenario assert what was actually rendered (e.g. a -textvariable).
tcl.commands["drawntext"] = function()
    return tcl.codes.OK, table.concat(TEXTS, "|")
end

local path = arg[1] or error("usage: lua tests/tk-headless.lua script.tcl")
local f = assert(io.open(path, "r"))
local src = f:read("*a"); f:close()

local code, val = tcl.evalScript(src, tcl.globals)
if code == tcl.codes.ERROR then
    io.stderr:write("tk-headless: " .. tostring(val) .. "\n")
    os.exit(1)
end
