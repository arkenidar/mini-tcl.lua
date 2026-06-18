/* wish — interactive Tcl/Tk shell in the browser.
 *
 * Runs the real mini-tcl.lua + canvas.lua + tk.lua under fengari (Lua in JS).
 * This file is the web canvas backend: it defines the window.js_canvas_* drawing
 * functions that canvas.lua's web branch calls, queues input events for
 * js_poll_event, and drives the per-frame loop with requestAnimationFrame. Type a
 * Tk command in the REPL and the widget appears/updates live on the canvas. */
(function () {
    "use strict";

    var canvas = document.getElementById("wish-canvas");
    var ctx = canvas.getContext("2d");
    ctx.font = "13px monospace";
    ctx.textBaseline = "top";

    // ---- drawing primitives (called from Lua via canvas.lua's web branch) ----
    window.js_canvas_color = function (r, g, b, a) {
        var s = "rgba(" + (r | 0) + "," + (g | 0) + "," + (b | 0) + "," +
                (a === undefined ? 1 : a / 255) + ")";
        ctx.fillStyle = s;
        ctx.strokeStyle = s;
    };
    window.js_canvas_clear = function () { ctx.fillRect(0, 0, canvas.width, canvas.height); };
    window.js_canvas_present = function () { /* the browser presents on its own */ };
    window.js_canvas_pixel = function (x, y) { ctx.fillRect(x, y, 1, 1); };
    window.js_canvas_line = function (x1, y1, x2, y2) {
        ctx.beginPath();
        ctx.moveTo(x1 + 0.5, y1 + 0.5);
        ctx.lineTo(x2 + 0.5, y2 + 0.5);
        ctx.stroke();
    };
    window.js_canvas_rect = function (x, y, w, h) { ctx.strokeRect(x + 0.5, y + 0.5, w, h); };
    window.js_canvas_fill = function (x, y, w, h) { ctx.fillRect(x, y, w, h); };
    window.js_canvas_text = function (x, y, s) { ctx.fillText(s, x, y); };
    window.js_canvas_ticks = function () { return performance.now(); };
    window.js_canvas_width = function () { return canvas.width; };
    window.js_canvas_height = function () { return canvas.height; };

    // ---- input queue (drained by js_poll_event each frame) -------------------
    var evq = [];
    function pos(e) {
        var r = canvas.getBoundingClientRect();
        var x = (e.clientX - r.left) * (canvas.width / r.width);
        var y = (e.clientY - r.top) * (canvas.height / r.height);
        return Math.round(x) + " " + Math.round(y);
    }
    canvas.addEventListener("mousedown", function (e) { canvas.focus(); evq.push("mouse down " + pos(e)); });
    canvas.addEventListener("mouseup", function (e) { evq.push("mouse up " + pos(e)); });
    canvas.addEventListener("mousemove", function (e) { evq.push("mouse move " + pos(e)); });

    var KEYMAP = { Enter: "Return", " ": "space", Escape: "Escape", Tab: "Tab",
                   ArrowLeft: "Left", ArrowRight: "Right", ArrowUp: "Up", ArrowDown: "Down" };
    canvas.addEventListener("keydown", function (e) {
        if (e.key === "Backspace") { evq.push("key Backspace"); e.preventDefault(); }
        else if (KEYMAP[e.key]) { evq.push("key " + KEYMAP[e.key]); e.preventDefault(); }
        else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
            evq.push("text " + e.key);     // printable character
        }
    });
    window.js_poll_event = function () { return evq.shift() || ""; };

    // ---- the render/event loop, driven by the browser ------------------------
    var loopFn = null, running = false;
    window.MiniTk = {
        start: function (fn) {
            loopFn = fn;
            if (running) return;
            running = true;
            function tick() {
                try { loopFn(); } catch (err) { console.error("tk loop:", err); running = false; return; }
                requestAnimationFrame(tick);
            }
            requestAnimationFrame(tick);
        }
    };

    // ---- bootstrap: load fengari + the Lua sources, then wire the REPL --------
    var output = document.getElementById("repl-output");
    var input = document.getElementById("repl-input");
    var form = document.getElementById("repl-form");

    function append(text, cls) {
        var span = document.createElement("span");
        span.className = cls;
        span.textContent = text;
        output.appendChild(span);
        output.scrollTop = output.scrollHeight;
    }
    function loadScript(src) {
        return new Promise(function (resolve, reject) {
            var s = document.createElement("script");
            s.src = src;
            s.onload = resolve;
            s.onerror = function () { reject(new Error("failed to load " + src)); };
            document.head.appendChild(s);
        });
    }

    (async function () {
        try {
            if (typeof window.fengari === "undefined") {
                await loadScript("https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.min.js");
            }
            var files = await Promise.all([
                fetch("./mini-tcl.lua"), fetch("./canvas.lua"),
                fetch("./tk.lua"), fetch("./glue-wish.lua"),
            ]);
            for (var i = 0; i < files.length; i++) {
                if (!files[i].ok) throw new Error("HTTP " + files[i].status + " fetching a .lua source");
            }
            window.MINITCL_SOURCE = await files[0].text();
            window.MINITCL_CANVAS_SOURCE = await files[1].text();
            window.MINITCL_TK_SOURCE = await files[2].text();
            var glue = await files[3].text();
            window.fengari.load(glue, "@glue-wish.lua")();   // defines evalTk, starts loop
            append("mini-tk ready (Lua via fengari). Try the commands below, one per line.\n", "banner");
        } catch (e) {
            append("failed to start mini-tk: " + e + "\n", "error");
            return;
        }

        var history = [], histPos = 0;
        form.addEventListener("submit", function (ev) {
            ev.preventDefault();
            var line = input.value;
            if (!line.trim()) return;
            history.push(line); histPos = history.length;
            append("% " + line + "\n", "echo");
            var res;
            try { res = window.evalTk(line); }
            catch (e) { res = "error: " + e + "\n"; }
            if (res) append(res, "result");
            input.value = "";
            canvas.focus();   // keep keyboard going to the widgets
        });
        input.addEventListener("keydown", function (ev) {
            if (ev.key === "ArrowUp") {
                if (histPos > 0) { histPos--; input.value = history[histPos]; }
                ev.preventDefault();
            } else if (ev.key === "ArrowDown") {
                if (histPos < history.length - 1) { histPos++; input.value = history[histPos]; }
                else { histPos = history.length; input.value = ""; }
                ev.preventDefault();
            }
        });
    })();
})();
