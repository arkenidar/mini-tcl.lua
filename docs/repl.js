/* Interactive mini-tcl REPL backed by fengari (Lua in the browser). */
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

    try {
        const [srcResp, glueResp] = await Promise.all([
            fetch("./mini-tcl.lua"),
            fetch("./glue.lua"),
        ]);
        if (!srcResp.ok) throw new Error("fetching mini-tcl.lua: HTTP " + srcResp.status);
        if (!glueResp.ok) throw new Error("fetching glue.lua: HTTP " + glueResp.status);
        window.MINITCL_SOURCE = await srcResp.text();
        const glue = await glueResp.text();

        fengari.load(glue, "@glue.lua")();

        const selfTest = window.minitclEval("expr {6 * 7}");
        if (selfTest.trim() !== "42") {
            throw new Error("self-test failed: " + selfTest);
        }
        append("mini-tcl ready — try:  puts [expr {6 * 7}]\n", "banner");
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
            res = window.minitclEval(line);
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
