/* Interactive mini-tcl REPL.
 *
 * Backend priority: the real PUC-Rio Lua compiled to WebAssembly (emcc) first;
 * if that module is missing or fails to start, fall back to fengari (Lua in
 * JavaScript). Both expose the same evalLine(text) -> output-string interface,
 * so the rest of the page doesn't care which one is running. */
(async function () {
    "use strict";

    const output = document.getElementById("repl-output");
    const input = document.getElementById("repl-input");
    const form = document.getElementById("repl-form");

    function append(text, cls) {
        const span = document.createElement("span");
        span.className = cls;
        span.textContent = text;
        output.appendChild(span);
        output.scrollTop = output.scrollHeight;
    }

    function loadScript(src) {
        return new Promise(function (resolve, reject) {
            const s = document.createElement("script");
            s.src = src;
            s.onload = function () { resolve(); };
            s.onerror = function () { reject(new Error("failed to load " + src)); };
            document.head.appendChild(s);
        });
    }

    // Backend 1: WebAssembly (real PUC-Rio Lua via emcc).
    async function setupWasm() {
        await loadScript("./minitcl-wasm.js");
        if (typeof window.createMiniTcl !== "function") {
            throw new Error("createMiniTcl not defined");
        }
        const Module = await window.createMiniTcl();
        const evalFn = Module.cwrap("mini_tcl_eval", "string", ["string"]);
        return {
            evalLine: function (line) { return evalFn(line); },
            label: "real PUC-Rio Lua via WebAssembly",
        };
    }

    // Backend 2: fengari (Lua VM in JavaScript), loaded on demand.
    async function setupFengari() {
        if (typeof window.fengari === "undefined") {
            await loadScript("https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.min.js");
        }
        const [srcResp, glueResp] = await Promise.all([
            fetch("./mini-tcl.lua"),
            fetch("./glue.lua"),
        ]);
        if (!srcResp.ok) throw new Error("fetching mini-tcl.lua: HTTP " + srcResp.status);
        if (!glueResp.ok) throw new Error("fetching glue.lua: HTTP " + glueResp.status);
        window.MINITCL_SOURCE = await srcResp.text();
        const glue = await glueResp.text();
        window.fengari.load(glue, "@glue.lua")();
        return {
            evalLine: function (line) { return window.minitclEval(line); },
            label: "Lua in JavaScript via fengari",
        };
    }

    let backend;
    try {
        backend = await setupWasm();
    } catch (wasmErr) {
        try {
            backend = await setupFengari();
            append("WebAssembly unavailable (" + wasmErr + "); using fengari fallback.\n", "banner");
        } catch (fengariErr) {
            append("failed to start the REPL: " + fengariErr + "\n", "error");
            return;
        }
    }

    try {
        const selfTest = backend.evalLine("expr {6 * 7}");
        if (selfTest.trim() !== "42") {
            throw new Error("self-test failed: " + selfTest);
        }
        append("mini-tcl ready (" + backend.label + ") — try:  puts [expr {6 * 7}]\n", "banner");
    } catch (e) {
        append("failed to start the REPL: " + e + "\n", "error");
        return;
    }

    const history = [];
    let histPos = 0;

    form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        const line = input.value;
        if (!line.trim()) return;
        history.push(line);
        histPos = history.length;
        append("% " + line + "\n", "echo");
        let res;
        try {
            res = backend.evalLine(line);
        } catch (e) {
            res = "error: " + e + "\n";
        }
        if (res) append(res, "result");
        input.value = "";
    });

    input.addEventListener("keydown", function (ev) {
        if (ev.key === "ArrowUp") {
            if (histPos > 0) { histPos--; input.value = history[histPos]; }
            ev.preventDefault();
        } else if (ev.key === "ArrowDown") {
            if (histPos < history.length - 1) {
                histPos++; input.value = history[histPos];
            } else {
                histPos = history.length; input.value = "";
            }
            ev.preventDefault();
        }
    });
})();
