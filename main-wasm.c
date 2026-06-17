/* WebAssembly entry point: exposes the embedded mini-tcl.lua interpreter
 * (real PUC-Rio Lua via minilua.h) to the browser as a single eval function,
 * instead of running the blocking CLI REPL that main.c does.
 *
 * Build with emcc; see the `wasm` targets in the Makefile / CMakeLists.txt /
 * build.zig. JavaScript calls mini_tcl_eval(line) via cwrap and reads the
 * returned string with UTF8ToString.
 */
#define LUA_IMPL
#include "minilua.h"

#include <emscripten.h>
#include <stdlib.h>
#include <string.h>

#include "mini_tcl_script.h"   /* mini_tcl_script[]  / mini_tcl_script_len  */
#include "wasm_glue.h"         /* wasm_glue[]        / wasm_glue_len        */

static lua_State *g_L;          /* persistent interpreter state */
static char      *g_out;        /* reused output buffer, valid until next call */

/* Run an embedded Lua chunk; returns 0 on success, leaving any error message on
 * the Lua stack for the caller to report. */
static int run_chunk(lua_State *L, const unsigned char *src, size_t len,
                     const char *name)
{
    if (luaL_loadbuffer(L, (const char *)src, len, name) != LUA_OK)
        return -1;
    if (lua_pcall(L, 0, 0, 0) != LUA_OK)
        return -1;
    return 0;
}

/* Lazily build the interpreter: load mini-tcl.lua in embed mode (defines the
 * global `minitcl`), then the wasm glue (installs output capture and the global
 * minitcl_eval). Returns NULL on success or a static error string. */
static const char *ensure_init(void)
{
    if (g_L)
        return NULL;

    g_L = luaL_newstate();
    if (!g_L)
        return "cannot create Lua state: out of memory";
    luaL_openlibs(g_L);

    lua_pushboolean(g_L, 1);
    lua_setglobal(g_L, "MINI_TCL_EMBED");

    if (run_chunk(g_L, mini_tcl_script, mini_tcl_script_len, "@mini-tcl.lua") != 0
        || run_chunk(g_L, wasm_glue, wasm_glue_len, "@wasm-glue.lua") != 0) {
        const char *msg = lua_tostring(g_L, -1);
        static char err[512];
        snprintf(err, sizeof err, "init failed: %s", msg ? msg : "unknown error");
        lua_close(g_L);
        g_L = NULL;
        return err;
    }
    return NULL;
}

/* Evaluate one line of TCL and return the captured output. The returned pointer
 * stays valid only until the next call; JS copies it immediately. */
EMSCRIPTEN_KEEPALIVE
const char *mini_tcl_eval(const char *line)
{
    const char *err = ensure_init();
    if (err)
        return err;

    lua_getglobal(g_L, "minitcl_eval");
    lua_pushstring(g_L, line ? line : "");
    if (lua_pcall(g_L, 1, 1, 0) != LUA_OK) {
        const char *msg = lua_tostring(g_L, -1);
        static char err2[512];
        snprintf(err2, sizeof err2, "error: %s\n", msg ? msg : "unknown error");
        lua_pop(g_L, 1);
        return err2;
    }

    const char *result = lua_tostring(g_L, -1);
    size_t n = result ? strlen(result) : 0;
    char *grown = realloc(g_out, n + 1);
    if (grown) {
        g_out = grown;
        memcpy(g_out, result ? result : "", n);
        g_out[n] = '\0';
    }
    lua_pop(g_L, 1);
    return g_out ? g_out : "";
}
