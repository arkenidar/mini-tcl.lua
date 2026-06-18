/* SDL3 host for mini-tcl: injects the sdl_* drawing/input globals that the
 * guarded canvas.lua bridge and tk.lua toolkit build on, then drives the
 * blocking desktop event loop. The interpreter core (mini-tcl.lua) never sees
 * SDL — all platform code lives here and in the two guarded Lua bridge files.
 *
 * Build modes (see Makefile): mode 1 embeds minilua.h (-DUSE_MINILUA), modes 2
 * and 3 link a real liblua. main-sdl.c itself is identical across all three.
 */
#ifdef USE_MINILUA
#define LUA_IMPL
#include "minilua.h"
#else
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#endif

#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mini_tcl_script.h"   /* the frozen interpreter core */
#include "canvas_bridge.h"     /* canvas.lua: canvas.* + canvas.loop */
#include "tk_bridge.h"         /* tk.lua: the Tk essence */

static SDL_Window   *g_win;
static SDL_Renderer *g_ren;
static int g_running = 1;

/* ---- input event queue ----------------------------------------------------
 * SDL events are polled in the C loop and pushed here as text tokens; the Lua
 * side drains them via sdl_poll_event(). Keeping dispatch in Lua means the web
 * backend only has to supply an equivalent js_poll_event. */
#define EVQ_CAP 256
#define EVQ_TOK 96
static char g_evq[EVQ_CAP][EVQ_TOK];
static int  g_evq_head, g_evq_tail;

static void evq_push(const char *s)
{
    int next = (g_evq_tail + 1) % EVQ_CAP;
    if (next == g_evq_head) return;          /* full: drop (back-pressure) */
    SDL_strlcpy(g_evq[g_evq_tail], s, EVQ_TOK);
    g_evq_tail = next;
}

static const char *evq_pop(void)
{
    if (g_evq_head == g_evq_tail) return "";
    const char *s = g_evq[g_evq_head];
    g_evq_head = (g_evq_head + 1) % EVQ_CAP;
    return s;
}

/* ---- sdl_* drawing primitives (registered as Lua globals) ----------------- */

static int l_sdl_color(lua_State *L)
{
    SDL_SetRenderDrawColor(g_ren,
        (Uint8)luaL_checkinteger(L, 1), (Uint8)luaL_checkinteger(L, 2),
        (Uint8)luaL_checkinteger(L, 3),
        (Uint8)luaL_optinteger(L, 4, 255));
    return 0;
}

static int l_sdl_clear(lua_State *L)
{
    (void)L;
    SDL_RenderClear(g_ren);
    return 0;
}

static int l_sdl_present(lua_State *L)
{
    (void)L;
    SDL_RenderPresent(g_ren);
    return 0;
}

static int l_sdl_pixel(lua_State *L)
{
    SDL_RenderPoint(g_ren,
        (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2));
    return 0;
}

static int l_sdl_line(lua_State *L)
{
    SDL_RenderLine(g_ren,
        (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
        (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4));
    return 0;
}

static int l_sdl_rect(lua_State *L)   /* outline */
{
    SDL_FRect r = { (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
                    (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4) };
    SDL_RenderRect(g_ren, &r);
    return 0;
}

static int l_sdl_fill(lua_State *L)   /* filled */
{
    SDL_FRect r = { (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
                    (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4) };
    SDL_RenderFillRect(g_ren, &r);
    return 0;
}

static int l_sdl_text(lua_State *L)   /* built-in 8x8 debug font, no deps */
{
    SDL_RenderDebugText(g_ren,
        (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2),
        luaL_checkstring(L, 3));
    return 0;
}

static int l_sdl_ticks(lua_State *L)
{
    lua_pushnumber(L, (lua_Number)SDL_GetTicks());
    return 1;
}

static int l_sdl_size(lua_State *L)   /* current drawable size: w, h */
{
    int w = 0, h = 0;
    SDL_GetWindowSize(g_win, &w, &h);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    return 2;
}

static int l_sdl_poll_event(lua_State *L)
{
    lua_pushstring(L, evq_pop());
    return 1;
}

/* Translate one SDL event into a queued text token. */
static void pump_sdl_events(void)
{
    SDL_Event e;
    char buf[EVQ_TOK];
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
        case SDL_EVENT_QUIT:
            g_running = 0;
            evq_push("quit");
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            SDL_snprintf(buf, sizeof buf, "mouse down %d %d",
                         (int)e.button.x, (int)e.button.y);
            evq_push(buf);
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            SDL_snprintf(buf, sizeof buf, "mouse up %d %d",
                         (int)e.button.x, (int)e.button.y);
            evq_push(buf);
            break;
        case SDL_EVENT_MOUSE_MOTION:
            SDL_snprintf(buf, sizeof buf, "mouse move %d %d",
                         (int)e.motion.x, (int)e.motion.y);
            evq_push(buf);
            break;
        case SDL_EVENT_KEY_DOWN:
            SDL_snprintf(buf, sizeof buf, "key %s",
                         SDL_GetKeyName(e.key.key));
            evq_push(buf);
            break;
        case SDL_EVENT_TEXT_INPUT:
            SDL_snprintf(buf, sizeof buf, "text %s", e.text.text);
            evq_push(buf);
            break;
        default:
            break;
        }
    }
}

/* The blocking desktop loop. Called from C after the user script has built its
 * UI and registered a per-frame body in the Lua global __canvas_loop_body
 * (a Lua function set by tk.lua, or a TCL string set by canvas.loop). */
static int run_loop(lua_State *L)
{
    while (g_running) {
        pump_sdl_events();

        lua_getglobal(L, "__canvas_loop_body");
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                fprintf(stderr, "loop error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
                break;
            }
        } else if (lua_isstring(L, -1)) {
            /* TCL string body: minitcl.evalScript(body, minitcl.globals) */
            const char *body = lua_tostring(L, -1);
            lua_getglobal(L, "minitcl");
            lua_getfield(L, -1, "evalScript");
            lua_pushstring(L, body);
            lua_getfield(L, -3, "globals");
            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                fprintf(stderr, "loop error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
                break;
            }
            lua_pop(L, 1);   /* minitcl */
            lua_pop(L, 1);   /* the string */
        } else {
            lua_pop(L, 1);
            break;           /* no loop registered: nothing to drive */
        }

        SDL_Delay(16);       /* ~60 fps */
    }
    return 0;
}

/* sdl_loop_start(): canvas.loop / tk call this once the body is registered. */
static int l_sdl_loop_start(lua_State *L)
{
    return run_loop(L);
}

static void reg(lua_State *L, const char *name, lua_CFunction fn)
{
    lua_pushcfunction(L, fn);
    lua_setglobal(L, name);
}

static int load_chunk(lua_State *L, const unsigned char *buf, size_t len,
                      const char *name)
{
    if (luaL_loadbuffer(L, (const char *)buf, len, name) != LUA_OK ||
        lua_pcall(L, 0, 0, 0) != LUA_OK) {
        fprintf(stderr, "%s: %s\n", name, lua_tostring(L, -1));
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return EXIT_FAILURE;
    }
    if (!SDL_CreateWindowAndRenderer("mini-tcl/tk", 640, 480,
                                     SDL_WINDOW_RESIZABLE, &g_win, &g_ren)) {
        fprintf(stderr, "SDL_CreateWindowAndRenderer: %s\n", SDL_GetError());
        return EXIT_FAILURE;
    }
    SDL_StartTextInput(g_win);   /* deliver SDL_EVENT_TEXT_INPUT for entries */

    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "cannot create Lua state\n"); return EXIT_FAILURE; }
    luaL_openlibs(L);

    /* Inject the host contract before loading any Lua. */
    reg(L, "sdl_color",      l_sdl_color);
    reg(L, "sdl_clear",      l_sdl_clear);
    reg(L, "sdl_present",    l_sdl_present);
    reg(L, "sdl_pixel",      l_sdl_pixel);
    reg(L, "sdl_line",       l_sdl_line);
    reg(L, "sdl_rect",       l_sdl_rect);
    reg(L, "sdl_fill",       l_sdl_fill);
    reg(L, "sdl_text",       l_sdl_text);
    reg(L, "sdl_ticks",      l_sdl_ticks);
    reg(L, "sdl_size",       l_sdl_size);
    reg(L, "sdl_poll_event", l_sdl_poll_event);
    reg(L, "sdl_loop_start", l_sdl_loop_start);

    /* Embed mode: the core returns the Tcl table and sets _G.minitcl. */
    lua_pushboolean(L, 1);
    lua_setglobal(L, "MINI_TCL_EMBED");

    /* arg table, as the standalone interpreter builds it. */
    lua_createtable(L, argc - 1, 1);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    if (!load_chunk(L, mini_tcl_script, mini_tcl_script_len, "@mini-tcl.lua") ||
        !load_chunk(L, canvas_bridge,   canvas_bridge_len,   "@canvas.lua")  ||
        !load_chunk(L, tk_bridge,       tk_bridge_len,       "@tk.lua")) {
        lua_close(L);
        return EXIT_FAILURE;
    }

    if (argc < 2) {
        fprintf(stderr, "usage: %s script.tcl\n", argv[0]);
        lua_close(L);
        return EXIT_FAILURE;
    }

    /* Run the user script via minitcl.evalScript(src, minitcl.globals). */
    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return EXIT_FAILURE; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *src = (char *)malloc(n + 1);
    if (fread(src, 1, n, f) != (size_t)n) { /* short read tolerated below */ }
    src[n] = 0;
    fclose(f);

    lua_getglobal(L, "minitcl");
    lua_getfield(L, -1, "evalScript");
    lua_pushstring(L, src);
    lua_getfield(L, -3, "globals");
    free(src);
    if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
        fprintf(stderr, "mini-tcl: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }
    /* evalScript returns (code, value); a TCL ERROR is reported as value. */
    if (lua_isnumber(L, -2) && (int)lua_tointeger(L, -2) == 1) {
        fprintf(stderr, "mini-tcl: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }
    lua_pop(L, 2);

    /* If the script built a UI (tk set a loop body) but never blocked in the
     * loop itself, drive it now — this is wish's implicit mainloop. */
    lua_getglobal(L, "__canvas_loop_body");
    int have_loop = !lua_isnil(L, -1);
    lua_pop(L, 1);
    if (have_loop && g_running)
        run_loop(L);

    lua_close(L);
    SDL_DestroyRenderer(g_ren);
    SDL_DestroyWindow(g_win);
    SDL_Quit();
    return EXIT_SUCCESS;
}
