-- canvas.lua — guarded drawing bridge for mini-tcl.
--
-- Registers canvas.* commands into the interpreter's open registry. The core
-- (mini-tcl.lua) never references SDL or JS; this file is the only place that
-- branches on which host globals are present:
--
--   * desktop / Android (SDL3) : sdl_* C functions from main-sdl.c
--   * web (Fengari/WASM)        : js_*  functions from canvas-web.js  (future)
--
-- The same TCL `canvas.*` vocabulary works on every backend. Loaded by the host
-- after the core, in MINI_TCL_EMBED mode, so `minitcl` is available.

local tcl = minitcl
local OK = tcl.codes.OK
local cmds = tcl.commands

local function num(x) return tonumber(x) or 0 end

-- Build the canvas.* command set from a backend's primitive functions. Both
-- branches below supply the same `b` table, so the registrations are shared.
local function install(b)
    cmds["canvas.color"] = function(w)
        b.color(num(w[2]), num(w[3]), num(w[4]), w[5] and num(w[5]) or 255)
        return OK, ""
    end
    cmds["canvas.clear"]   = function() b.clear();   return OK, "" end
    cmds["canvas.present"] = function() b.present(); return OK, "" end
    cmds["canvas.pixel"] = function(w)
        b.pixel(num(w[2]), num(w[3])); return OK, ""
    end
    cmds["canvas.line"] = function(w)
        b.line(num(w[2]), num(w[3]), num(w[4]), num(w[5])); return OK, ""
    end
    cmds["canvas.rect"] = function(w)
        b.rect(num(w[2]), num(w[3]), num(w[4]), num(w[5])); return OK, ""
    end
    cmds["canvas.fill"] = function(w)
        b.fill(num(w[2]), num(w[3]), num(w[4]), num(w[5])); return OK, ""
    end
    cmds["canvas.text"] = function(w)
        b.text(num(w[2]), num(w[3]), tostring(w[4] or "")); return OK, ""
    end
    cmds["canvas.ticks"] = function() return OK, tostring(b.ticks()) end
    cmds["canvas.size"] = function()
        local cw, ch = b.size(); return OK, cw .. " " .. ch
    end

    -- canvas.loop {body}: does not loop here. It records the per-frame body and
    -- asks the host to drive the actual loop (blocking on desktop, rAF on web).
    cmds["canvas.loop"] = function(w)
        _G.__canvas_loop_body = w[2] or ""
        b.loop_start()
        return OK, ""
    end

    -- expose the raw primitives + input poll to tk.lua / embedders.
    tcl.canvas = b
    tcl.poll_event = b.poll
end

if type(sdl_line) == "function" then
    -- desktop and Android share this branch (identical SDL3 C signatures).
    install({
        color   = sdl_color,
        clear   = sdl_clear,
        present = sdl_present,
        pixel   = sdl_pixel,
        line    = sdl_line,
        rect    = sdl_rect,
        fill    = sdl_fill,
        text    = sdl_text,
        ticks   = sdl_ticks,
        size    = sdl_size,
        poll    = sdl_poll_event,
        loop_start = sdl_loop_start,
    })

elseif type(js_canvas_line) == "function" then
    -- web (Fengari/WASM): js_* globals from canvas-web.js. present is a no-op
    -- (the browser presents on its own); loop is driven by requestAnimationFrame.
    install({
        color   = js_canvas_color,
        clear   = js_canvas_clear,
        present = function() end,
        pixel   = js_canvas_pixel,
        line    = js_canvas_line,
        rect    = js_canvas_rect,
        fill    = js_canvas_fill,
        text    = js_canvas_text,
        ticks   = js_canvas_ticks,
        size    = js_canvas_size,
        poll    = js_poll_event,
        loop_start = js_loop_start,
    })
end
