/* Self-contained launcher: runs the embedded mini-tcl.lua script
 * with a bundled PUC-Rio Lua interpreter (minilua.h).
 */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static UINT prev_out_cp, prev_in_cp;
static void restore_console_cp(void)
{
    if (prev_out_cp) SetConsoleOutputCP(prev_out_cp);
    if (prev_in_cp)  SetConsoleCP(prev_in_cp);
}
#endif

#define LUA_IMPL
#include "minilua.h"

#include <stdio.h>
#include <stdlib.h>

#include "mini_tcl_script.h"

int main(int argc, char **argv)
{
    int i;
    lua_State *L;

#ifdef _WIN32
    /* The source is UTF-8 (e.g. the em-dash in the banner, and whatever a TCL
     * script puts). Switch the console to UTF-8 so those bytes render instead
     * of garbling under the legacy OEM code page, and restore it on exit. */
    prev_out_cp = GetConsoleOutputCP();
    prev_in_cp  = GetConsoleCP();
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    atexit(restore_console_cp);
#endif

    L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "cannot create Lua state: not enough memory\n");
        return EXIT_FAILURE;
    }
    luaL_openlibs(L);

    /* Global 'arg' table, as the standalone interpreter builds it:
     * arg[0] is the script (here: this executable), arg[1..n] the arguments. */
    lua_createtable(L, argc - 1, 1);
    for (i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    if (luaL_loadbuffer(L, (const char *)mini_tcl_script,
                        mini_tcl_script_len, "@mini-tcl.lua") != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }

    /* Pass the arguments to the chunk as varargs ('...') too. */
    for (i = 1; i < argc; i++)
        lua_pushstring(L, argv[i]);

    if (lua_pcall(L, argc - 1, 0, 0) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return EXIT_FAILURE;
    }

    lua_close(L);
    return EXIT_SUCCESS;
}
