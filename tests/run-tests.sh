#!/bin/sh
# Smoke tests for mini-tcl. Usage: tests/run-tests.sh [path-to-binary]
BIN=${1:-./mini-tcl}
DIR=$(dirname "$0")
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
fail=0

# 1. script mode: full output must match the expected transcript
# (strip CR so the Windows binary's CRLF stdout still matches the LF fixture)
"$BIN" "$DIR/smoke.tcl" one two 2>&1 | tr -d '\r' >"$TMP"
if diff -u "$DIR/smoke.expected" "$TMP"; then
    echo "PASS script mode"
else
    echo "FAIL script mode (diff above)"
    fail=1
fi

# 2. REPL mode: pipe commands, check computed results appear
out=$(printf 'set x 21\nputs [expr {$x * 2}]\nproc sq {n} {return [expr {$n*$n}]}\nputs [sq 7]\nexit\n' | "$BIN")
case "$out" in
    *42*) echo "PASS repl expr" ;;
    *) echo "FAIL repl expr: $out"; fail=1 ;;
esac
case "$out" in
    *49*) echo "PASS repl proc" ;;
    *) echo "FAIL repl proc: $out"; fail=1 ;;
esac

# 3. REPL multi-line continuation (unbalanced braces)
out=$(printf 'foreach i {1 2 3} {\nputs "i=$i"\n}\nexit\n' | "$BIN")
case "$out" in
    *"i=1"*"i=2"*"i=3"*) echo "PASS repl continuation" ;;
    *) echo "FAIL repl continuation: $out"; fail=1 ;;
esac

# 4. script-mode error goes to stderr with exit code 1
if printf '' | "$BIN" /nonexistent.tcl 2>/dev/null; then
    echo "FAIL missing-file exit code"
    fail=1
else
    echo "PASS missing-file exit code"
fi

# 5. Tk essence: headless (mock canvas backend) transcript diff. Loads the core
#    plus canvas.lua + tk.lua under a Lua interpreter, so it needs a `lua` on
#    PATH (independent of $BIN). Skips cleanly if none is available.
LUA=""
for c in lua lua5.4 lua5.3 lua5.2 lua5.1 luajit; do
    if command -v "$c" >/dev/null 2>&1; then LUA=$c; break; fi
done
if [ -n "$LUA" ]; then
    "$LUA" "$DIR/tk-headless.lua" "$DIR/tk-layout.tcl" 2>&1 | tr -d '\r' >"$TMP"
    if diff -u "$DIR/tk-layout.expected" "$TMP"; then
        echo "PASS tk essence ($LUA)"
    else
        echo "FAIL tk essence (diff above)"
        fail=1
    fi
else
    echo "SKIP tk essence (no lua interpreter on PATH)"
fi

if [ "$fail" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
    exit 1
fi
