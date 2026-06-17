// Smoke test for the emscripten build, mirroring the fengari self-test in
// docs/repl.js. Loads docs/minitcl-wasm.js under node and checks that the real
// PUC-Rio Lua interpreter evaluates a trivial TCL expression.
//
//   node tests/wasm-smoke.mjs            # expects docs/minitcl-wasm.js to exist
//
// Exits non-zero on any mismatch so CI fails loudly.

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const modulePath = join(here, "..", "docs", "minitcl-wasm.js");

const { default: createMiniTcl } = await import(modulePath);
const Module = await createMiniTcl();
const evalLine = Module.cwrap("mini_tcl_eval", "string", ["string"]);

let failures = 0;
function check(input, expected) {
    const got = evalLine(input).trim();
    if (got !== expected) {
        console.error(`FAIL: ${input}\n  expected: ${JSON.stringify(expected)}\n  got:      ${JSON.stringify(got)}`);
        failures++;
    } else {
        console.log(`ok: ${input} => ${got}`);
    }
}

check("expr {6 * 7}", "42");
check("puts [expr {6 * 7}]", "42");
check("set x 5; puts [expr {$x * 2}]", "10");
check("proc square {n} {return [expr {$n*$n}]}; puts [square 9]", "81");

if (failures) {
    console.error(`\n${failures} check(s) failed`);
    process.exit(1);
}
console.log("\nall wasm smoke checks passed");
