-- Browser glue: loads mini-tcl.lua in embed mode under fengari and exposes
-- minitclEval(line) -> output string to JavaScript.
-- Expects js.global.MINITCL_SOURCE to hold the mini-tcl.lua source text.

local js = require "js"

local src = js.global.MINITCL_SOURCE
if type(src) ~= "string" then
    error("MINITCL_SOURCE not set")
end

MINI_TCL_EMBED = true
local chunk = assert((loadstring or load)(src, "@mini-tcl.lua"))
local tcl = chunk()

-- capture interpreter output instead of writing to stdout
local buf = {}
local function emit(s) buf[#buf + 1] = s end

_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    emit(table.concat(parts, "\t") .. "\n")
end
io.write = function(...)
    for i = 1, select("#", ...) do emit(tostring(select(i, ...))) end
end

-- commands that make no sense in a web page
local function unavailable(name)
    tcl.commands[name] = function()
        return tcl.codes.ERROR, "\"" .. name .. "\" is not available in the browser REPL"
    end
end
unavailable("exit")
unavailable("source")

js.global.minitclEval = function(_, line)
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
