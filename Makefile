CC       ?= cc
CFLAGS   ?= -O2 -Wall
LDLIBS    = -lm
TARGET    = mini-tcl
VERSION  ?= 0.2.1
PREFIX   ?= /usr/local
MINGW_CC ?= x86_64-w64-mingw32-gcc
EMCC     ?= emcc
MINILUA_URL = https://raw.githubusercontent.com/edubart/minilua/main/minilua.h

# Emscripten output: a browser module exposing mini_tcl_eval(line). Lands in
# docs/ so the GitHub Pages REPL can load it next to repl.js.
WASM_OUT   = docs/minitcl-wasm.js
EMCC_OPT  ?= -O2
EMCC_FLAGS = $(EMCC_OPT) -sASSERTIONS=1 \
             -sMODULARIZE=1 -sEXPORT_NAME=createMiniTcl \
             -sENVIRONMENT=web,node -sALLOW_MEMORY_GROWTH=1 \
             -sEXPORTED_RUNTIME_METHODS=cwrap,UTF8ToString \
             -sEXPORTED_FUNCTIONS=_mini_tcl_eval,_malloc,_free

DIST_FILES = Makefile bin2c.c main.c main-sdl.c mini-tcl.lua canvas.lua tk.lua \
             minilua.h tests/smoke.tcl tests/smoke.expected tests/run-tests.sh \
             tests/tk-headless.lua tests/tk-layout.tcl tests/tk-layout.expected \
             examples/tk-demo.tcl examples/canvas-demo.tcl

all: $(TARGET)

$(TARGET): main.c mini_tcl_script.h minilua.h
	$(CC) $(CFLAGS) -o $@ main.c $(LDLIBS)

mini_tcl_script.h: mini-tcl.lua bin2c
	./bin2c mini-tcl.lua mini_tcl_script > $@

wasm_glue.h: wasm-glue.lua bin2c
	./bin2c wasm-glue.lua wasm_glue > $@

canvas_bridge.h: canvas.lua bin2c
	./bin2c canvas.lua canvas_bridge > $@

tk_bridge.h: tk.lua bin2c
	./bin2c tk.lua tk_bridge > $@

bin2c: bin2c.c
	$(CC) $(CFLAGS) -o $@ bin2c.c

# WebAssembly build (requires emscripten; emcc + node must be on PATH, e.g.
# `source /path/to/emsdk_env.sh`). Produces docs/minitcl-wasm.{js,wasm}.
wasm: $(WASM_OUT)
$(WASM_OUT): main-wasm.c mini_tcl_script.h wasm_glue.h minilua.h
	$(EMCC) $(EMCC_FLAGS) main-wasm.c -o $@

# Debug build: full DWARF embedded in the .wasm and no optimization, so a
# DWARF-aware debugger can set breakpoints in main-wasm.c / minilua.h. Overwrites
# the same docs/minitcl-wasm.* the page loads; rebuild with `make wasm` for
# release (the -g .wasm is large and unoptimized).
# EMCC_FLAGS already carries -sASSERTIONS=1; this adds full DWARF, no opt, and
# SAFE_HEAP bounds/alignment checks on top.
wasm-debug: mini_tcl_script.h wasm_glue.h minilua.h
	$(EMCC) $(EMCC_FLAGS) -O0 -g -sSAFE_HEAP=1 main-wasm.c -o $(WASM_OUT)

# --- SDL3 canvas/Tk binary (main-sdl.c) -------------------------------------
# Three interchangeable Lua linking modes; main-sdl.c is identical across them.
# The generated *_bridge.h headers embed canvas.lua and tk.lua next to the core.
SDL_GEN  = mini_tcl_script.h canvas_bridge.h tk_bridge.h
SDL_LIBS = $(shell pkg-config --cflags --libs sdl3)

# mode 1: embed minilua.h, zero external Lua dependency (default).
mini-tcl-sdl: main-sdl.c $(SDL_GEN) minilua.h
	$(CC) $(CFLAGS) -DUSE_MINILUA -o $@ main-sdl.c $(SDL_LIBS) $(LDLIBS)

# mode 2: link the system liblua5.4 (needs liblua5.4-dev; pkg-config name lua-5.4).
mini-tcl-sdl-system: main-sdl.c $(SDL_GEN)
	$(CC) $(CFLAGS) $(shell pkg-config --cflags lua-5.4) -o $@ main-sdl.c \
	      $(SDL_LIBS) $(shell pkg-config --libs lua-5.4) $(LDLIBS)

# mode 3: link a vendored lua/ source tree built to lua/liblua.a.
mini-tcl-sdl-src: main-sdl.c $(SDL_GEN) lua/liblua.a
	$(CC) $(CFLAGS) -Ilua/src -o $@ main-sdl.c $(SDL_LIBS) lua/liblua.a $(LDLIBS)

# Fetched once, then kept in the repo so offline builds work.
minilua.h:
	curl -fsSL -o $@ $(MINILUA_URL) || wget -qO $@ $(MINILUA_URL)

# Fully static Linux binary (no runtime .so dependencies at all).
static: mini-tcl-static
mini-tcl-static: main.c mini_tcl_script.h minilua.h
	$(CC) $(CFLAGS) -static -o $@ main.c $(LDLIBS)

# Windows cross-build (requires mingw-w64).
windows: $(TARGET).exe
$(TARGET).exe: main.c mini_tcl_script.h minilua.h
	$(MINGW_CC) $(CFLAGS) -o $@ main.c $(LDLIBS)

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	sh tests/run-tests.sh ./$(TARGET)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -s -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)

dist: minilua.h
	mkdir -p $(TARGET)-$(VERSION)/tests $(TARGET)-$(VERSION)/examples
	cp Makefile bin2c.c main.c main-sdl.c mini-tcl.lua canvas.lua tk.lua minilua.h \
	   $(TARGET)-$(VERSION)/
	cp tests/smoke.tcl tests/smoke.expected tests/run-tests.sh \
	   tests/tk-headless.lua tests/tk-layout.tcl tests/tk-layout.expected \
	   $(TARGET)-$(VERSION)/tests/
	cp examples/tk-demo.tcl examples/canvas-demo.tcl $(TARGET)-$(VERSION)/examples/
	tar czf $(TARGET)-$(VERSION).tar.gz $(TARGET)-$(VERSION)
	rm -rf $(TARGET)-$(VERSION)

clean:
	rm -f $(TARGET) $(TARGET).exe mini-tcl-static bin2c mini_tcl_script.h \
	      wasm_glue.h canvas_bridge.h tk_bridge.h \
	      mini-tcl-sdl mini-tcl-sdl-system mini-tcl-sdl-src \
	      docs/minitcl-wasm.js docs/minitcl-wasm.wasm \
	      $(TARGET)-*.tar.gz

.PHONY: all static windows wasm wasm-debug sdl run test install uninstall dist clean
sdl: mini-tcl-sdl
