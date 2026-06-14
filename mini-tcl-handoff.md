# Handoff: mini-tcl as a Cross-Platform Scriptable 2D Runtime

**Audience:** Claude Code (or any future agent/session working on `arkenidar/mini-tcl.lua`, `arkenidar/zuil`, `arkenidar/zig-sdl-gui`, or related Pang/Clay/LuaPang work).

**Purpose:** This is a design-conversation distillation, not a spec. It captures the *reasoning* behind a set of architectural decisions so that implementation work doesn't have to rediscover the "why." Treat it as pre-research / pre-design context — useful before writing code, especially for the SDL3 canvas bridge, the cross-platform loop model, and the build-system dependency choices.

**Author's context (for calibration):** Dario Cangialosi (`arkenidar`), independent developer, 15+ years, strong DHTML5/zero-dependency aesthetic across all his projects. He values motivated explanations — *why*, not just *what* — and iterates via small verified code samples. He has a long-running family of minimal-language projects (RESM/BBJJ, Pang/PN-Lang, Clay, LuaPang/pangea) built around the recurring discovery that **deferred evaluation via stored token positions** (`word_index` / `phrase_length`) is a sufficient primitive for control flow.

---

## 1. The repo this is grounded in: `arkenidar/mini-tcl.lua`

Current state (as of this conversation):

- A working **TCL-subset interpreter written in portable Lua**, targeting Lua 5.1 through 5.4 (byte-identical transcripts across PUC-Rio 5.x and LuaJIT).
- Coverage: full control flow (`if/while/for/foreach/break/continue`), `proc` with defaults and `args` varargs, `catch`/`error`, `expr` with `**`, ternary `?:`, math functions, `global` scoping, non-trivial string/list commands (`string match` with glob, `lindex end-N`).
- **Distribution model**: `mini-tcl.lua` → `bin2c` → `mini_tcl_script.h` → compiled with `main.c` + `minilua.h` (an amalgamated single-header PUC-Rio Lua, from edubart/minilua) → a **single native executable** linking only `libc`/`libm`. Zero runtime dependencies.
- **Embedding mode**: `MINI_TCL_EMBED = true; local tcl = dofile("mini-tcl.lua")` exposes `tcl.evalScript(code, tcl.globals)` and, critically, an **open command registry** `tcl.commands["name"] = function(words, frame) -> code, value`.
- **Web target**: same `mini-tcl.lua` runs under Fengari (Lua-in-JS) for a browser REPL, with GitHub Actions CI running a `smoke.tcl` vs `smoke.expected` transcript diff across Lua 5.1/LuaJIT/embedded.
- A real bug was found and fixed during development: variable shadowing in `parseOr/parseAnd/parseComp/parseAdd/parseMul` (`local right, pos = ...` shadowed the outer `pos`, silently breaking left-associative chains like `1+2+3`). Fix: declare `right` first, then `right, pos = ...`. This validated that the interpreter's *deferred-execution* architecture (TCL braces ≈ Pang's `word_index`) is sound — the bug was in expression-chaining, not in the core evaluation model.

**Key takeaway for any future work on this repo:** the core is small and correct. The interesting design space is entirely in *what gets registered into `Tcl.commands`* and *how the host program drives the interpreter's lifecycle* — not in the interpreter itself.

---

## 2. The central architectural decision: an open, swappable command registry

`Tcl.commands` is a plain Lua table: `name -> function(words, frame) -> (code, value)`. This is **TCL's original design philosophy** (Ousterhout): the language itself does almost nothing — it's a command dispatch bus. Tk is a plugin. Expect is a plugin. Everything is a plugin.

This has two consequences that matter for any extension work:

1. **The interpreter core never needs to change** to add graphics, audio, input, filesystem, or networking. New capabilities are pure additions to the registry, done either from Lua (host-side bridge file) or from C (via `lua_pushcfunction` + `lua_setglobal`, then a thin Lua shim registers the TCL command name).

2. **The host *language* (L1, the syntax/parser/eval layer — currently TCL via `mini-tcl.lua`) is separable from everything above it.** The registry doesn't know or care whether the thing calling `Tcl.commands["canvas.line"]` is a TCL `proc` body, a Pang phrase, or a Clay `!canvas.line #4 ...` invocation. This is the load-bearing abstraction for the long-term Pang/Clay vision (see §6).

Layered view:

```
L1  language (parser/eval)      mini-tcl.lua today; swappable for Pang/Clay later
L2  command registry            Tcl.commands — open table, no fixed binding
L3  modules                      canvas / audio / input / filesystem / net — independent of each other
L4  user script                  same script, same API, platform-transparent
```

---

## 3. The SDL3 canvas bridge — proposed design

**Goal:** give TCL scripts access to a drawing surface. Three targets: desktop (Windows & Debian laptop), web (Fengari + Canvas2D), and possibly Android (SDL3 port / Termux).

### 3.1 Injection point

In `main.c`, between `luaL_openlibs(L)` and the `lua_pcall` that runs the embedded script: register C functions as Lua globals (`sdl_line`, `sdl_color`, `sdl_clear`, `sdl_present`, `sdl_pixel`, `sdl_rect`, `sdl_fill`, `sdl_ticks`, ...). Each is a thin `lua_CFunction` wrapping one SDL3 call (`SDL_RenderLine`, `SDL_SetRenderDrawColor`, `SDL_RenderClear`, `SDL_RenderPresent`, `SDL_RenderPoint`, `SDL_RenderRect`, `SDL_RenderFillRect`, `SDL_GetTicks`).

### 3.2 The bridge file — runtime guard pattern

A Lua file (appended to `mini-tcl.lua` or `source`d separately) registers TCL commands **conditionally**, based on which globals exist at runtime:

```lua
if type(sdl_line) == "function" then
    -- desktop or Android (SDL3): same Lua code for both
    Tcl.commands["canvas.line"] = function(w, f)
        sdl_line(tonumber(w[2]), tonumber(w[3]), tonumber(w[4]), tonumber(w[5]))
        return 0, ""
    end
    -- ... canvas.color, canvas.clear, canvas.present, canvas.fill, canvas.ticks

elseif type(js_canvas_line) == "function" then
    -- Fengari/web: js_* globals injected by canvas-web.js
    Tcl.commands["canvas.line"] = function(w, f)
        js_canvas_line(w[2], w[3], w[4], w[5])
        return 0, ""
    end
    -- canvas.present is a no-op here — the browser presents on its own
end
```

**Why this matters:** `mini-tcl.lua` itself never branches on platform. The branching lives in this one guarded block, driven entirely by *which globals happen to be present* — which is determined by which `main-*.c` (or `canvas-web.js`) injected them. Desktop and Android share a branch because the SDL3 Android port exposes the same C function signatures.

### 3.3 The loop ownership problem

This is the crux of cross-platform portability and deserves careful attention before implementation:

| Platform | Loop model |
|---|---|
| Desktop (SDL3) | C owns a blocking `while(running) { poll events; eval TCL frame body; present; delay }` |
| Web (Fengari) | JS owns the loop via `requestAnimationFrame`; a blocking Lua loop would hang the tab |
| Android (SDL3) | SDL3 callback model — `SDL_AppIterate` is called by the Java thread each frame; no blocking main loop allowed |

**Resolution — LÖVE pattern, adapted:** TCL scripts define `canvas.load`, `canvas.update`, `canvas.draw` as `proc`s. The host (C or JS) calls these at the right times. Concretely, `canvas.loop { body }` doesn't loop — it stashes the body string into a Lua global (`__canvas_loop_body`) and calls a host-provided `sdl_loop_start()` / `js_loop_start()` which then drives the actual loop (blocking `while` in C, `requestAnimationFrame` recursion in JS, `SDL_AppIterate` in the Android callback model). The TCL-visible API is identical across all three; only the host-side driver differs.

Example TCL script that should run unmodified on all three targets:

```tcl
proc canvas.draw {} {
    canvas.color 80 160 255
    set t [expr {[canvas.ticks] / 400.0}]
    canvas.fill [expr {320 + 200*cos($t)}] [expr {240 + 160*sin($t)}] 8 8
}
```

---

## 4. Dependency policy: PUC-Rio Lua 5.4, not LuaJIT; `minilua.h` as one option among several

This was an explicit, motivated decision and should be treated as a constraint for any build-system work:

**Avoid LuaJIT as a hard dependency** because:
- LuaJIT 2.x is effectively frozen on a Lua 5.1-era API; LuaJIT 3 is not stable. Depending on it means depending on a 2013-era API surface.
- LuaJIT's FFI (used extensively in `zig-sdl-gui` for SDL3 bindings) is a powerful but non-standard extension. PUC-Rio Lua has no FFI — the canonical alternative is registering C functions via `lua_pushcfunction`, which is more verbose but universally portable.
- Portability: LuaJIT has partial aarch64 support and no RISC-V. PUC-Rio Lua compiles anywhere a C compiler exists — including Termux on any chip.

**Prefer PUC-Rio Lua 5.4** because:
- Stable C API (`lua.h`/`lauxlib.h`/`lualib.h`) for years, mostly back-compatible to 5.3.
- Available as a system package everywhere (`apt install liblua5.4-dev`).
- `minilua.h` **is** an amalgamated PUC-Rio Lua 5.4 — so it's 100% API-compatible with "real" Lua 5.4. Using it is not a divergent dependency, it's a packaging choice.

**Build system should support three Lua-linking modes without changing application code**, switched by a single `#ifdef`:

```c
#ifdef USE_MINILUA
  #define LUA_IMPL
  #include "minilua.h"      /* mode 1: embedded, zero deps */
#else
  #include <lua.h>
  #include <lauxlib.h>
  #include <lualib.h>       /* mode 2: system liblua5.4, or mode 3: lua/ built from source */
#endif
```

```makefile
mini-tcl-sdl:        # mode 1 — minilua.h embedded
	$(CC) -DLUA_IMPL -include minilua.h -o $@ main-sdl.c $(SDL_LIBS)

mini-tcl-sdl-system: # mode 2 — system package
	$(CC) -o $@ main-sdl.c $(SDL_LIBS) -llua5.4

mini-tcl-sdl-src:     # mode 3 — vendored Lua source, full control
	$(CC) -Ilua/src -o $@ main-sdl.c $(SDL_LIBS) lua/liblua.a -lm
```

`main.c` itself is identical across all three modes. This matters for `zuil` too, see §7.

---

## 5. Inspirations and what to take from each (with sources read during this session)

- **LÖVE** (love2d.org): Lua + SDL + `load/update/draw`, single-binary distribution across desktop/mobile, thin C runtime, "everything else is script." This is the primary structural template for the canvas runtime described above.
- **TCL/Tk** (tcl-lang.org): command-bus philosophy, the reason tkinter exists, and the historical precedent for "minimal syntax → maximal extensibility." Also: Tk's `canvas` widget exists but is secondary/static — the project here deliberately targets a pixel/vector drawing surface with a render loop instead, which Tk was never designed for.
- **Antirez / Jim Tcl / Redis RESP**: independent validation that "verb + arguments, trivially parseable" syntax is a durable design choice for both languages and protocols — relevant if `mini-tcl.lua`'s command syntax is ever exposed as a wire protocol (ties into zuil's Phase 3, see §7).
- **Nebula Device (Radon Labs)**: historical proof that Tcl-as-embedded-scripting-layer for a game engine works exactly because "the engine *is* the set of Tcl commands" — i.e., the registry pattern in §2 is not novel, it's the proven shape.
- **Processing / p5.js**: the "remove friction" lesson — single binary, no install, write 20 lines, see a picture. This is the *distribution* goal, distinct from the *architecture* goal.

---

## 6. The Pang / Clay / LuaPang long-term vision

This section is explicitly **pre-research** — none of it should block or complicate the mini-tcl/SDL3 work, but it explains *why* the registry-based architecture (§2) is being treated as load-bearing rather than incidental.

- **Pang / PN-Lang**: Dario's long-running Polish-notation language with deferred execution. The `pang-000.lua` → `pang-004.lua` ladder already implements FizzBuzz, meaning `while`, `if`, variables, and arithmetic work. The uniform mechanism is `phrase_length`, which walks the flat token stream by arity — `if`/`while`/`proc`/`define_word` all defer their bodies via stored token indices, the same trick as TCL's braces.
- **Clay**: a sigil-based prefix language (`@` directives, `:` binding, `$` dereference, `!` invocation, `#` arity), Python-style indentation, strict typing with no coercion. Reached Milestone M1 as a JS interpreter (`arkenidar/clay-js`). Clay's `#` arity sigil was separately identified (in a QBE-compilation exploration) as effectively *a stack-effect type system*, which is relevant if Clay is ever compiled rather than interpreted.
- **pangea-js**: a separate downstream branch (LuaPang → TypescriptPang → TypescriptStructure) with infix notation, parens, `$N` sugar, and a token-rewriting pipeline (`tokenizeCode → expandArgShorthand → normalizeWordToken`). This pipeline is the natural place to "desugar" higher-level syntax (e.g., Python/Clay-style indentation → `do...end`) before evaluation — a pattern that could apply equally to a future Pang-hosted version of the canvas API.

**The convergence point with mini-tcl:** when Pang (or Clay) reaches "sufficient" — meaning it can call a command with multiple numeric arguments, loop without breaking control flow, and define procedure-like blocks — the *only* required change to reuse the entire canvas/audio/input module layer (§2, L3) is to populate `Pang.commands` (or `Clay.commands`) instead of `Tcl.commands`, using the same `function(words, frame) -> code, value` signature. **Building the canvas runtime in TCL now is simultaneously a proving ground for what Pang/Clay's calling convention needs to support.** For example, `canvas.line 10 20 100 200` in TCL directly informs whether Clay's `!canvas.line #4 10 20 100 200` (explicit arity sigil) maps cleanly onto the same registry call — it does, by design, since both reduce to `words = {"canvas.line","10","20","100","200"}`.

**Open design question (not yet resolved):** for Python/Clay-style indented blocks in LuaPang, indentation would be surface sugar desugared to `do...end` in a pre-pass, keeping the evaluator ignorant of indentation. This requires (a) a new pre-pass stage LuaPang currently lacks, and (b) a tokenizer that preserves line/indent structure without breaking on newlines inside string literals. The remaining design knob is *which column rule starts a block* — Clay's `:`-then-indent convention, or bare indentation (Python-style). This is independent of the mini-tcl/SDL3 work but should reuse whatever lessons the canvas API's calling conventions teach.

---

## 7. Connection to `arkenidar/zuil`

`zuil` (the umbilical-ready, immediate-mode declarative UI framework) is architecturally a sibling project with overlapping concerns, and recent decisions there are directly relevant:

- **`include/zuil.h` is the contract**, with two interchangeable implementations behind it — `src/zuil.c` (C) and `src/zuil.zig` (Zig) — selected at build time via `-Dimpl` (default `c`). The stated rationale: the pinned Zig *dev* toolchain is the project's most fragile dependency (build-API churn between snapshots); a C core compiles with **any** C compiler (gcc / NDK clang / emcc — gcc verified end-to-end through LuaJIT FFI). If Zig ever becomes unusable, `build.zig` degrades to a convenience, not a dependency.
- Both implementations are smoke-gated across desktop (LuaJIT + ctypes), WASM (Node smoke test), and Android (arm64 link + symbol check), plus a web/WASM variant with DWARF debug info for both C and Zig sources.
- zuil's architecture already embraces: immediate-mode declarative UI, **serializable command buffers**, single-pass deterministic layout, Lua hot-reload, and a Phase 3 "umbilical" split between server-side logic and client-side rendering — explicitly compared to NeWS (ship behavior, not pixels) and Elm's architecture (state is one value, events are data, `update`/`view` are pure functions).
- A prior exploration sketched **ZUIL bindings as sugar over a traces/observables kernel** — "small primitive, rich surface," the same recurring move as Pang's `phrase_length` and TCL's command dispatch.

**Why this matters for mini-tcl work:**

1. **The dual-implementation pattern (`-Dimpl c|zig` behind a single header contract) is directly transferable** to mini-tcl's SDL3 bridge: `main.c` (or a `main-sdl.c`) could itself be the "contract," with the Lua-linking mode (§4) as the swappable-implementation axis, and potentially a Zig-based SDL3 binding as an alternative to the C one — *if* that's ever desired. Given Dario's stated LuaJIT-FFI-via-Zig comfort in `zig-sdl-gui`, but the explicit *non*-dependence on LuaJIT for mini-tcl's core, the safe default is: **C core + PUC-Rio Lua always works; a Zig/LuaJIT-FFI variant could be an optional, non-blocking alternative build**, exactly mirroring zuil's "Zig is convenience, not dependency" stance.

2. **zuil's command-buffer thesis and mini-tcl's command-registry are the same idea at different layers.** zuil's command buffers are *serializable UI descriptions* sent across a process/network boundary; mini-tcl's `Tcl.commands` registry is *the dispatch table that executes* such commands. A TCL (or future Pang/Clay) script driving `canvas.*` commands is structurally identical to a zuil widget tree being replayed from a command buffer. If zuil's Phase 3 ("fetch a UI template, execute it locally") and mini-tcl's canvas scripting ever meet, the natural integration point is: **a zuil widget could itself be implemented as a `Tcl.commands["zuil.button"]`-style entry**, making mini-tcl a *scripting layer for zuil* in the same sense that LÖVE is "Lua for SDL" — i.e., mini-tcl-with-canvas could become the embeddable scripting console for zuil applications, not just a standalone graphics toy.

3. **Antirez/RESP precedent (§5) + zuil's NeWS comparison**: both point toward the same conclusion — if mini-tcl's command syntax (`canvas.line 10 20 100 200`) is ever serialized over a wire (zuil Phase 3's "umbilical"), it is *already* in a wire-friendly verb+arguments form. No additional serialization layer is needed; the TCL word-list **is** the command buffer entry.

---

## 8. Concrete next steps (suggested, not prescriptive)

In rough dependency order:

1. **Confirm the build-mode `#ifdef` (§4)** works with a trivial `main.c` that does nothing but `luaL_newstate`/`luaL_openlibs`/`lua_close` under all three Lua-linking modes, on both Windows (MinGW) and Debian. This de-risks everything downstream.
2. **Write `main-sdl.c`** (desktop only first): SDL3 init, register `sdl_color/clear/present/pixel/line/rect/fill/ticks` as `lua_CFunction`s, load `mini_tcl_script.h`, run a script. No loop yet — just confirm a static drawing script (`canvas.line ...; canvas.present`) produces a window with output.
3. **Write the bridge Lua file** (§3.2) with the `if type(sdl_line) == "function"` guard, registering `canvas.*` TCL commands. Test with a static script.
4. **Add `canvas.loop`/`load`/`update`/`draw`** (§3.3) — desktop blocking loop first, since it's the simplest model. Defer web/Fengari and Android until the TCL-facing API is validated.
5. **Only then** consider: web canvas bridge (`canvas-web.js` + Fengari globals), Android SDL3 port, and any zuil integration (§7.2/7.3).
6. **Pang/Clay convergence (§6)** is independent and should not block 1–5. If/when Pang reaches a sufficient calling convention, revisit whether `Tcl.commands` vs `Pang.commands` requires any registry changes — by design, it shouldn't.

---

## 9. Source conversations this is distilled from

For full reasoning traces (architecture diagrams, code snippets, multilingual summaries), these Claude.ai conversations are the primary sources:

- `https://claude.ai/chat/9482d1d6-913e-40a8-8ca5-3c90a5927bb5` — "Tcl interpreter embedded in Lua": the bug fix, LuaPang vs minitcl comparison, string-literal history, pangea-js pipeline, indentation desugaring question.
- `https://claude.ai/chat/e4233b3f-0a7f-4fa7-944c-977a7c80a97c` and `https://claude.ai/chat/a3aca505-c3cf-44d2-9913-c2fa7e9c8701` — zuil architecture, command buffers, dual C/Zig implementation, Phase 3 umbilical design.
- `https://claude.ai/chat/b5291859-cae8-4c8c-b503-805e34b4f178` — "Evaluating Tkinter and TCL": GUI lineage lessons (Dear ImGui, React, Elm, NeWS, X11, Smalltalk Morphic) applied to ZUIL.
- `https://claude.ai/chat/704c6b3f-c5e3-4982-9170-4f25b09a8855` — Nebula Device / Antirez / Jim Tcl factoids.
- `https://claude.ai/chat/07072130-5b9d-4fd8-adae-e9132ac19c23` — Clay-on-QBE exploration (arity sigil as stack-effect type system; relevant only if Clay compilation is revisited).
- The current conversation (this one) — the SDL3 canvas bridge design, the cross-platform loop-ownership analysis, the PUC-Rio-vs-LuaJIT dependency decision, and the multilingual elevator pitch.

---

*End of handoff. This document is intentionally narrative/explanatory rather than a checklist — per the author's stated preference, motivations are kept alongside conclusions so that future sessions can disagree with a conclusion without losing the reasoning that produced it.*
