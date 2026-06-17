-- WebAssembly glue: drives mini-tcl.lua (loaded in embed mode) under emscripten
-- and exposes a plain Lua function minitcl_eval(line) -> output string.
--
-- Unlike docs/glue.lua this has no fengari `js` module: the host is the C
-- wrapper in main-wasm.c, which calls _G.minitcl_eval and hands the returned
-- string back to JavaScript. Expects embed-mode mini-tcl.lua to have already run
-- (it sets the global `minitcl`).

local tcl = rawget(_G, "minitcl")
if type(tcl) ~= "table" then
    error("minitcl table not set; load mini-tcl.lua in embed mode first")
end

-- Capture interpreter output instead of writing to stdout.
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

-- Commands that make no sense in a sandboxed browser page.
local function unavailable(name)
    tcl.commands[name] = function()
        return tcl.codes.ERROR, "\"" .. name .. "\" is not available in the WebAssembly REPL"
    end
end
unavailable("exit")
unavailable("source")

_G.minitcl_eval = function(line)
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
