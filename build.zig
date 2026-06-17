// Zig build driver, kept in parity with the Makefile and CMakeLists.txt.
//
//   zig build wasm                          # build docs/minitcl-wasm.{js,wasm}
//   zig build wasm -Demcc=/abs/path/to/emcc # point at an out-of-PATH emcc
//
// emcc (and node, for the smoke test) must be reachable, e.g. via
// `source /path/to/emsdk_env.sh`. The wasm step regenerates the embedded
// headers with bin2c and then runs the same emcc command the other two build
// systems use.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const emcc = b.option([]const u8, "emcc", "Path to the emcc compiler") orelse "emcc";
    const cc = b.option([]const u8, "cc", "C compiler used to build bin2c") orelse "cc";

    const build_bin2c = b.addSystemCommand(&.{ cc, "-O2", "-o", "bin2c", "bin2c.c" });

    const gen_script = b.addSystemCommand(&.{ "sh", "-c", "./bin2c mini-tcl.lua mini_tcl_script > mini_tcl_script.h" });
    gen_script.step.dependOn(&build_bin2c.step);

    const gen_glue = b.addSystemCommand(&.{ "sh", "-c", "./bin2c wasm-glue.lua wasm_glue > wasm_glue.h" });
    gen_glue.step.dependOn(&build_bin2c.step);

    // main-wasm.c defines LUA_IMPL and #includes minilua.h itself.
    const emcc_cmd = b.addSystemCommand(&.{
        emcc,                          "-O2",                          "-sASSERTIONS=1",
        "main-wasm.c",                 "-o",                           "docs/minitcl-wasm.js",
        "-sMODULARIZE=1",              "-sEXPORT_NAME=createMiniTcl",   "-sENVIRONMENT=web,node",
        "-sALLOW_MEMORY_GROWTH=1",     "-sEXPORTED_RUNTIME_METHODS=cwrap,UTF8ToString",
        "-sEXPORTED_FUNCTIONS=_mini_tcl_eval,_malloc,_free",
    });
    emcc_cmd.step.dependOn(&gen_script.step);
    emcc_cmd.step.dependOn(&gen_glue.step);

    const wasm_step = b.step("wasm", "Build the WebAssembly module (docs/minitcl-wasm.{js,wasm})");
    wasm_step.dependOn(&emcc_cmd.step);
}
