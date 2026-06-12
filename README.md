# mini-tcl

[![CI](https://github.com/arkenidar/mini-tcl.lua/actions/workflows/ci.yml/badge.svg)](https://github.com/arkenidar/mini-tcl.lua/actions/workflows/ci.yml)

A small TCL interpreter written in portable Lua (5.1 – 5.5), distributable as a
**single self-contained native executable** with no runtime dependencies: the
Lua script is embedded into a C program that bundles a complete PUC-Rio Lua
interpreter via [minilua.h](https://github.com/edubart/minilua).

**Try it in your browser:** <https://arkenidar.github.io/mini-tcl.lua/> — an
interactive REPL running the very same `mini-tcl.lua` via
[fengari](https://fengari.io/) (Lua in JavaScript).

## Quick start

```sh
make          # downloads minilua.h on first build, then compiles
./mini-tcl    # interactive REPL
```

```tcl
% set x 5
5
% puts [expr {$x * 2}]
10
% proc square {n} {return [expr {$n * $n}]}
% puts [square 9]
81
```

Run a script file (extra arguments become `$argv`):

```sh
./mini-tcl script.tcl one two
```

Inside the script: `$argv0` is the script path, `$argv` the argument list,
`$argc` the argument count.

The interpreter also runs directly under any Lua:

```sh
lua mini-tcl.lua              # REPL
lua mini-tcl.lua script.tcl   # script mode
```

## Build targets (Makefile)

| Target         | Effect                                                          |
| -------------- | --------------------------------------------------------------- |
| `make`         | Build `./mini-tcl` (dynamic, links only libc + libm)            |
| `make static`  | Build `./mini-tcl-static`, a fully static Linux binary          |
| `make windows` | Cross-build `./mini-tcl.exe` (needs mingw-w64)                  |
| `make test`    | Build and run the smoke-test suite                              |
| `make install` | Install stripped binary to `$(PREFIX)/bin` (default /usr/local) |
| `make dist`    | Source tarball `mini-tcl-$(VERSION).tar.gz`                     |
| `make clean`   | Remove build artifacts (keeps `minilua.h`)                      |

### CMake (optional alternative)

```sh
cmake -B build
cmake --build build
ctest --test-dir build      # run the test suite
cmake --install build      # honors -DCMAKE_INSTALL_PREFIX
```

Static build: `cmake -B build -DSTATIC=ON`. Windows cross-build:
`cmake -B build -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc`.

## How the self-contained binary works

1. `bin2c` (a tiny bundled C tool) converts `mini-tcl.lua` into a C byte array
   (`mini_tcl_script.h`).
2. `main.c` defines `LUA_IMPL` and includes `minilua.h` — a one-file
   amalgamation of the complete PUC-Rio Lua interpreter — then loads and runs
   the embedded script. Command-line arguments are passed exactly as the
   standalone `lua` binary would (global `arg` table + chunk varargs).
3. The result links against nothing but libc and libm (`-lm`).

## Language reference

### Commands

| Command | Forms |
| --- | --- |
| `puts` | `puts ?-nonewline? string` |
| `set` | `set name ?value?` |
| `unset` | `unset name ?name ...?` |
| `append` | `append name ?value ...?` |
| `incr` | `incr name ?delta?` |
| `expr` | `expr arg ?arg ...?` |
| `if` | `if cond ?then? body ?elseif cond body ...? ?else body?` |
| `while` | `while cond body` |
| `for` | `for start cond next body` |
| `foreach` | `foreach varList list body` (multiple loop vars supported) |
| `break` / `continue` | loop control |
| `proc` | `proc name params body` — default values `{name default}`, trailing `args` collects varargs |
| `return` | `return ?value?` |
| `global` | `global name ?name ...?` — link proc-local names to globals |
| `eval` | `eval arg ?arg ...?` |
| `catch` | `catch script ?msgVar?` — returns TCL result code (0 ok, 1 error, ...) |
| `error` | `error message` |
| `source` | `source file.tcl` |
| `exit` | `exit ?status?` |
| `info` | `info exists name`, `info commands` |

### String and list commands

`string` subcommands: `length index range tolower toupper trim trimleft
trimright reverse repeat equal compare first last match` (glob-style `*?`).

Lists: `list`, `llength`, `lindex` (supports `end`, `end-N`), `lappend`,
`lrange`, `split`, `join`. List elements containing spaces are brace-quoted
automatically, TCL-style.

### expr

Operators by precedence: `**` (right-assoc), `* / %`, `+ -`,
`< > <= >= eq ne`, `== !=`, `&&`, `||`, `?:` ternary; unary `- + !`;
parentheses. `==`/`!=` compare numerically when both sides are numbers,
as strings otherwise; `eq`/`ne` always compare as strings.

Functions: `abs sqrt sin cos tan asin acos atan exp log floor ceil round
min max pow fmod int double rand srand`.

Substitution works inside expressions, so both `expr $x + 1` and
`expr {$x + 1}` (preferred) behave as expected, including nested
`[command]` calls.

### Syntax

Standard TCL word rules: `{braces}` are verbatim (nestable, no substitution),
`"quotes"` allow `$var`, `[command]` and backslash substitution, `;` separates
commands, `#` at command position starts a comment (so `;#` works as a
trailing comment), `\` at end of line continues a command.

## Embedding

Hosts (such as the browser REPL) can load the interpreter without starting
the CLI:

```lua
MINI_TCL_EMBED = true
local tcl = dofile("mini-tcl.lua")
local code, value = tcl.evalScript('expr {6 * 7}', tcl.globals)
-- code == tcl.codes.OK, value == "42"
```

## Tests

`make test` (or `ctest` with the CMake build) runs `tests/run-tests.sh`:
a full script-mode transcript diff (`tests/smoke.tcl` vs
`tests/smoke.expected`) plus REPL pipe checks. The same transcript is
byte-identical under the embedded Lua, PUC Lua 5.1 and LuaJIT.

## License

This project is released into the public domain under the
[Unlicense](LICENSE). The bundled/downloaded `minilua.h` (and Lua itself)
are MIT-licensed — see their headers.
