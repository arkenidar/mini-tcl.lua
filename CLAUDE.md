# CLAUDE.md — mini-tcl.lua (SDL3 canvas bridge)

> Condensed, actionable version. Full reasoning/context: `mini-tcl-handoff.md` (same conversation). Read that first if anything here seems under-motivated — it isn't arbitrary.

## What this repo is

`mini-tcl.lua` — a TCL-subset interpreter in portable Lua (5.1–5.4), shipped as a single zero-dependency native binary via `minilua.h` (amalgamated PUC-Rio Lua). Also runs under Fengari for a web REPL. CI does transcript-diff smoke testing across Lua versions.

**The core is done and correct.** Don't touch the interpreter itself. All extension work happens via the open command registry:

```lua
Tcl.commands["name"] = function(words, frame) -> code, value
```

## Current task: SDL3 canvas bridge

Give TCL scripts a drawing surface. Targets: desktop (Windows + Debian), web (Fengari+Canvas2D), maybe Android (SDL3).

### Hard constraints

- **No LuaJIT dependency.** PUC-Rio Lua 5.4 only (`minilua.h` is PUC-Rio 5.4 amalgamated — use it, but treat it as one of three interchangeable linking modes, not the only path). No FFI — register C functions via `lua_pushcfunction`/`lua_setglobal`.
- **`mini-tcl.lua` core must not branch on platform.** All platform-specific behavior lives in (a) which `main-*.c` injects which globals, and (b) one guarded bridge block in Lua.
- **Same TCL script must run unmodified on all targets.**

### Build modes (pick via `#ifdef`, `main.c` unchanged otherwise)

```c
#ifdef USE_MINILUA
  #define LUA_IMPL
  #include "minilua.h"          // mode 1: embedded, zero deps (default)
#else
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>           // mode 2: system liblua5.4, or mode 3: vendored lua/
#endif
```

```makefile
mini-tcl-sdl:        # mode 1
	$(CC) -DLUA_IMPL -include minilua.h -o $@ main-sdl.c $(SDL_LIBS)
mini-tcl-sdl-system: # mode 2
	$(CC) -o $@ main-sdl.c $(SDL_LIBS) -llua5.4
mini-tcl-sdl-src:    # mode 3
	$(CC) -Ilua/src -o $@ main-sdl.c $(SDL_LIBS) lua/liblua.a -lm
```

### C-side injection (in `main-sdl.c`, before `lua_pcall`)

Register as `lua_CFunction` globals: `sdl_color`, `sdl_clear`, `sdl_present`, `sdl_pixel`, `sdl_line`, `sdl_rect`, `sdl_fill`, `sdl_ticks`. Each is a thin wrapper:

```c
static int l_sdl_line(lua_State *L) {
    SDL_RenderLine(g_ren,
        (float)luaL_checknumber(L,1), (float)luaL_checknumber(L,2),
        (float)luaL_checknumber(L,3), (float)luaL_checknumber(L,4));
    return 0;
}
// lua_pushcfunction(L, l_sdl_line); lua_setglobal(L, "sdl_line");
```

### Lua-side bridge (guarded by runtime presence of globals)

```lua
if type(sdl_line) == "function" then
    -- desktop AND Android share this branch (same SDL3 C signatures)
    Tcl.commands["canvas.line"] = function(w, f)
        sdl_line(tonumber(w[2]), tonumber(w[3]), tonumber(w[4]), tonumber(w[5]))
        return 0, ""
    end
    -- ditto: canvas.color, canvas.clear, canvas.present, canvas.fill, canvas.ticks

elseif type(js_canvas_line) == "function" then
    -- Fengari/web: js_* globals from canvas-web.js
    Tcl.commands["canvas.line"] = function(w, f)
        js_canvas_line(w[2], w[3], w[4], w[5]); return 0, ""
    end
    -- canvas.present is a no-op on web (browser presents on its own)
end
```

### Loop model — LÖVE pattern (load/update/draw)

The loop ownership differs per platform and **cannot be unified in TCL**:

| Platform | Who drives the loop |
|---|---|
| Desktop SDL3 | C: blocking `while(running){poll; eval; present; delay}` |
| Web/Fengari | JS: `requestAnimationFrame` (blocking Lua loop hangs the tab) |
| Android SDL3 | `SDL_AppIterate` callback (no blocking main loop) |

Resolution: `canvas.loop { body }` doesn't loop itself — it stores the body in `__canvas_loop_body` and calls host-provided `sdl_loop_start()` / `js_loop_start()`, which drives the actual loop per-platform. TCL script is identical everywhere:

```tcl
proc canvas.draw {} {
    canvas.color 80 160 255
    set t [expr {[canvas.ticks] / 400.0}]
    canvas.fill [expr {320 + 200*cos($t)}] [expr {240 + 160*sin($t)}] 8 8
}
```

## Build/implement order

1. Validate the 3-mode `#ifdef` with a no-op `main.c` on Windows (MinGW) + Debian. De-risks everything else.
2. `main-sdl.c`, desktop only: init SDL3, register `sdl_*` C functions, load `mini_tcl_script.h`, run a **static** script (`canvas.line ...; canvas.present`, no loop). Confirm it draws.
3. Bridge Lua file with the `if sdl_line` guard. Test with the same static script via TCL.
4. Add `canvas.loop`/`load`/`update`/`draw` — desktop blocking loop first.
5. Only then: web bridge (Fengari + `canvas-web.js`), Android SDL3, zuil integration.

## Things explicitly NOT to do

- Don't add LuaJIT FFI bindings to mini-tcl's core (that's fine in `zig-sdl-gui`, not here).
- Don't make `mini-tcl.lua` aware of SDL, JS, or platform at all — only the bridge file and `main-*.c` know.
- Don't build the web or Android backend before the desktop static-draw path is verified.
- Don't block this work on Pang/Clay — the registry pattern already makes them swap-in-compatible later (see full handoff §6).

## Possible future link to `zuil`

`zuil` already has a dual-implementation contract (`include/zuil.h`, C/Zig behind `-Dimpl`) and a serializable command-buffer model. mini-tcl's `Tcl.commands` registry and zuil's command buffers are structurally the same idea at different layers — a zuil widget could plausibly be exposed as `Tcl.commands["zuil.button"]`, making mini-tcl-with-canvas a scripting console for zuil apps (LÖVE-for-zuil). Not blocking; see full handoff §7 if this becomes relevant.
