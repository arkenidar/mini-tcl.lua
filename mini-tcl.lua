-- mini-tcl.lua — a small TCL interpreter in portable Lua (5.1 through 5.4).
--
-- Usage:
--   lua mini-tcl.lua                 interactive REPL
--   lua mini-tcl.lua script.tcl ...  run a script; extra args become $argv
-- (or the same via the self-contained C binary that embeds this file)

-- ===== Result codes (TCL-style) ==============================================
-- Every evaluation returns (code, value). Control-flow commands return their
-- own code; loops and procs intercept the codes they handle.

-- numbering matches real TCL so [catch] returns standard codes
local OK, ERROR, RETURN, BREAK, CONTINUE = 0, 1, 2, 3, 4

local Tcl = {
    globals = {},     -- global variable frame (string -> string)
    commands = {},    -- command name -> function(args, frame) -> code, value
}

local unpackf = table.unpack or unpack  -- Lua 5.1 compatibility

local function tclError(msg)
    return ERROR, msg
end

-- ===== Number/boolean helpers ================================================

local function toNumber(s)
    local n = tonumber(s)
    if n == nil then
        error("expected number but got \"" .. tostring(s) .. "\"", 0)
    end
    return n
end

local function numToStr(n)
    if math.floor(n) == n and n == n and n ~= math.huge and n ~= -math.huge then
        return string.format("%d", n)
    end
    return tostring(n)
end

local function isTrue(v)
    local n = tonumber(v)
    if n ~= nil then return n ~= 0 end
    local s = string.lower(tostring(v))
    if s == "true" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "no" or s == "off" then return false end
    error("expected boolean value but got \"" .. tostring(v) .. "\"", 0)
end

-- ===== List helpers ==========================================================
-- TCL lists are strings. Elements with spaces/braces are brace-quoted.

local function listToTable(s)
    local items = {}
    local i, len = 1, #s
    while i <= len do
        local c = s:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == '{' then
            local depth, j = 1, i + 1
            while j <= len and depth > 0 do
                local cj = s:sub(j, j)
                if cj == '{' then depth = depth + 1
                elseif cj == '}' then depth = depth - 1 end
                j = j + 1
            end
            if depth ~= 0 then error("unmatched open brace in list", 0) end
            items[#items + 1] = s:sub(i + 1, j - 2)
            i = j
        elseif c == '"' then
            local j = i + 1
            local buf = {}
            while j <= len do
                local cj = s:sub(j, j)
                if cj == '\\' and j < len then
                    buf[#buf + 1] = s:sub(j + 1, j + 1)
                    j = j + 2
                elseif cj == '"' then
                    j = j + 1
                    break
                else
                    buf[#buf + 1] = cj
                    j = j + 1
                end
            end
            items[#items + 1] = table.concat(buf)
            i = j
        else
            local j = i
            while j <= len and not s:sub(j, j):match("%s") do j = j + 1 end
            items[#items + 1] = s:sub(i, j - 1)
            i = j
        end
    end
    return items
end

local function listElement(s)
    if s == "" then return "{}" end
    if s:match("[%s{}\"%[%]$\\;]") then
        -- brace-quote unless braces are unbalanced; then escape
        local depth = 0
        for k = 1, #s do
            local c = s:sub(k, k)
            if c == '{' then depth = depth + 1
            elseif c == '}' then depth = depth - 1 end
            if depth < 0 then break end
        end
        if depth == 0 then return "{" .. s .. "}" end
        return (s:gsub("[%s{}\"%[%]$\\;]", "\\%0"))
    end
    return s
end

local function tableToList(t)
    local out = {}
    for _, v in ipairs(t) do out[#out + 1] = listElement(v) end
    return table.concat(out, " ")
end

-- ===== Parser ================================================================
-- Words: bare, "double quoted" (with substitution), {braced} (verbatim).
-- Substitutions: $name, ${name}, [script]. Commands end at newline or ';'.
-- '#' at command position starts a comment to end of line.

local BACKSLASH_MAP = {
    a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
}

-- forward declaration
local evalScript

-- Read $var or ${var} starting after the '$'. Returns value, nextIndex.
local function substVar(s, i, frame)
    local len = #s
    if i <= len and s:sub(i, i) == '{' then
        local j = s:find('}', i + 1, true)
        if not j then error("missing close-brace for variable name", 0) end
        local name = s:sub(i + 1, j - 1)
        local v = frame[name]
        if v == nil then error("can't read \"" .. name .. "\": no such variable", 0) end
        return v, j + 1
    end
    local j = i
    while j <= len and s:sub(j, j):match("[%w_]") do j = j + 1 end
    if j == i then return "$", i end  -- lone '$' is literal
    local name = s:sub(i, j - 1)
    local v = frame[name]
    if v == nil then error("can't read \"" .. name .. "\": no such variable", 0) end
    return v, j
end

-- Read a [command] substitution starting after the '['. Returns value, nextIndex.
local function substBracket(s, i, frame)
    local depth, start, len = 1, i, #s
    while i <= len do
        local c = s:sub(i, i)
        if c == '[' then depth = depth + 1
        elseif c == ']' then
            depth = depth - 1
            if depth == 0 then break end
        end
        i = i + 1
    end
    if depth ~= 0 then error("missing close-bracket", 0) end
    local code, val = evalScript(s:sub(start, i - 1), frame)
    if code == ERROR then error(val, 0) end
    if code ~= OK and code ~= RETURN then
        error("invalid command result code in bracket substitution", 0)
    end
    return val, i + 1
end

-- Read one word starting at non-space position i.
-- Returns word, nextIndex (next index points at the delimiter or past it for quotes).
local function readWord(s, i, frame)
    local len = #s
    local c = s:sub(i, i)

    if c == '{' then
        local depth, j = 1, i + 1
        while j <= len do
            local cj = s:sub(j, j)
            if cj == '\\' then
                j = j + 2
            elseif cj == '{' then
                depth = depth + 1; j = j + 1
            elseif cj == '}' then
                depth = depth - 1
                if depth == 0 then
                    local body = s:sub(i + 1, j - 1)
                    -- backslash-newline continuation inside braces
                    body = body:gsub("\\\n%s*", " ")
                    return body, j + 1
                end
                j = j + 1
            else
                j = j + 1
            end
        end
        error("missing close-brace", 0)
    end

    local buf = {}
    local quoted = false
    if c == '"' then
        quoted = true
        i = i + 1
    end

    while i <= len do
        c = s:sub(i, i)
        if quoted and c == '"' then
            return table.concat(buf), i + 1
        elseif not quoted and (c == ' ' or c == '\t' or c == '\n' or c == ';') then
            return table.concat(buf), i
        elseif c == '\\' then
            i = i + 1
            if i > len then
                buf[#buf + 1] = '\\'
                break
            end
            local ec = s:sub(i, i)
            if ec == '\n' then
                buf[#buf + 1] = ' '
                -- swallow following indent
                i = i + 1
                while i <= len and s:sub(i, i):match("[ \t]") do i = i + 1 end
            else
                buf[#buf + 1] = BACKSLASH_MAP[ec] or ec
                i = i + 1
            end
        elseif c == '$' then
            local v, ni = substVar(s, i + 1, frame)
            buf[#buf + 1] = v
            i = ni
        elseif c == '[' then
            local v, ni = substBracket(s, i + 1, frame)
            buf[#buf + 1] = v
            i = ni
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    if quoted then error("missing close-quote", 0) end
    return table.concat(buf), i
end

-- Parse and run one command starting at i. Returns code, value, nextIndex.
local function evalCommand(s, i, frame)
    local len = #s
    local words = {}
    while true do
        while i <= len and (s:sub(i, i) == ' ' or s:sub(i, i) == '\t') do i = i + 1 end
        if i > len then break end
        local c = s:sub(i, i)
        if c == '\n' or c == ';' then
            i = i + 1
            break
        end
        if c == '\\' and s:sub(i + 1, i + 1) == '\n' then
            i = i + 2  -- line continuation between words
        elseif c == '#' and #words == 0 then
            while i <= len and s:sub(i, i) ~= '\n' do i = i + 1 end
        else
            local w, ni = readWord(s, i, frame)
            words[#words + 1] = w
            i = ni
        end
    end

    if #words == 0 then return OK, "", i end

    local cmd = Tcl.commands[words[1]]
    if not cmd then
        return ERROR, "invalid command name \"" .. words[1] .. "\"", i
    end
    local code, val = cmd(words, frame)
    return code, val or "", i
end

-- Evaluate a script (sequence of commands). Returns code, value.
evalScript = function(s, frame)
    local i, len = 1, #s
    local code, val = OK, ""
    while i <= len do
        local ok, c, v, ni = pcall(evalCommand, s, i, frame)
        if not ok then
            return ERROR, tostring(c)
        end
        code, val, i = c, v, ni
        if code ~= OK then return code, val end
    end
    return code, val
end

Tcl.evalScript = evalScript

-- ===== expr evaluator ========================================================
-- Operates on the (already word-assembled) expression string; performs its own
-- $var and [cmd] substitution so `expr {$x < 10}` works.

local Expr = {}

function Expr.tokenize(s, frame)
    local t, i, len = {}, 1, #s
    local function push(kind, v) t[#t + 1] = { kind = kind, v = v } end
    while i <= len do
        local c = s:sub(i, i)
        local two = s:sub(i, i + 1)
        if c:match("%s") then
            i = i + 1
        elseif c:match("%d") or (c == '.' and s:sub(i + 1, i + 1):match("%d")) then
            local j = i
            while j <= len and s:sub(j, j):match("[%w%.xXa-fA-F]") do j = j + 1 end
            local n = tonumber(s:sub(i, j - 1))
            if not n then error("invalid number in expression", 0) end
            push("num", n)
            i = j
        elseif c == '$' then
            local v, ni = substVar(s, i + 1, frame)
            local n = tonumber(v)
            if n then push("num", n) else push("str", v) end
            i = ni
        elseif c == '[' then
            local v, ni = substBracket(s, i + 1, frame)
            local n = tonumber(v)
            if n then push("num", n) else push("str", v) end
            i = ni
        elseif c == '"' then
            local w, ni = readWord(s, i, frame)
            local n = tonumber(w)
            if n then push("num", n) else push("str", w) end
            i = ni
        elseif c == '{' then
            local w, ni = readWord(s, i, frame)
            local n = tonumber(w)
            if n then push("num", n) else push("str", w) end
            i = ni
        elseif c:match("[%a_]") then
            local j = i
            while j <= len and s:sub(j, j):match("[%w_]") do j = j + 1 end
            push("name", s:sub(i, j - 1))
            i = j
        elseif two == "==" or two == "!=" or two == "<=" or two == ">="
            or two == "&&" or two == "||" or two == "**" then
            push("op", two)
            i = i + 2
        elseif c:match("[%+%-%*/%%<>!%(%),%?:]") then
            push("op", c)
            i = i + 1
        else
            error("unexpected character '" .. c .. "' in expression", 0)
        end
    end
    return t
end

local MATH_FUNCS = {
    abs = math.abs, sqrt = math.sqrt, sin = math.sin, cos = math.cos,
    tan = math.tan, exp = math.exp, log = math.log, floor = math.floor,
    ceil = math.ceil, atan = math.atan, asin = math.asin, acos = math.acos,
    round = function(x) return math.floor(x + 0.5) end,
    min = math.min, max = math.max,
    pow = function(a, b) return a ^ b end,
    fmod = math.fmod,
    int = function(x) return x >= 0 and math.floor(x) or math.ceil(x) end,
    double = function(x) return x end,
    rand = function() return math.random() end,
    srand = function(seed) math.randomseed(seed); return seed end,
}

-- Pratt-style recursive descent over the token list.
function Expr.eval(s, frame)
    local toks = Expr.tokenize(s, frame)
    local pos = 1

    local function peek() return toks[pos] end
    local function isOp(op)
        local t = toks[pos]
        return t and t.kind == "op" and t.v == op
    end
    local function expectOp(op)
        if not isOp(op) then error("expected '" .. op .. "' in expression", 0) end
        pos = pos + 1
    end

    local parseTernary

    local function parsePrimary()
        local t = peek()
        if not t then error("premature end of expression", 0) end
        if t.kind == "num" or t.kind == "str" then
            pos = pos + 1
            return t.v
        end
        if t.kind == "name" then
            local name = t.v
            pos = pos + 1
            if name == "eq" or name == "ne" or name == "in" then
                error("operator '" .. name .. "' out of place", 0)
            end
            local fn = MATH_FUNCS[name]
            if not fn then error("unknown function \"" .. name .. "\"", 0) end
            expectOp("(")
            local args = {}
            if not isOp(")") then
                args[#args + 1] = parseTernary()
                while isOp(",") do
                    pos = pos + 1
                    args[#args + 1] = parseTernary()
                end
            end
            expectOp(")")
            return fn(unpackf(args))
        end
        if isOp("(") then
            pos = pos + 1
            local v = parseTernary()
            expectOp(")")
            return v
        end
        if isOp("-") then pos = pos + 1; return -toNumber(parsePrimary()) end
        if isOp("+") then pos = pos + 1; return toNumber(parsePrimary()) end
        if isOp("!") then
            pos = pos + 1
            return isTrue(parsePrimary()) and 0 or 1
        end
        error("syntax error in expression", 0)
    end

    local function parsePower()
        local left = parsePrimary()
        if isOp("**") then
            pos = pos + 1
            return toNumber(left) ^ toNumber(parsePower())  -- right assoc
        end
        return left
    end

    local function parseMul()
        local left = parsePower()
        while isOp("*") or isOp("/") or isOp("%") do
            local op = peek().v
            pos = pos + 1
            local right = parsePower()
            local a, b = toNumber(left), toNumber(right)
            if op == "*" then left = a * b
            elseif op == "/" then left = a / b
            else left = a % b end
        end
        return left
    end

    local function parseAdd()
        local left = parseMul()
        while isOp("+") or isOp("-") do
            local op = peek().v
            pos = pos + 1
            local right = parseMul()
            local a, b = toNumber(left), toNumber(right)
            if op == "+" then left = a + b else left = a - b end
        end
        return left
    end

    local function parseComp()
        local left = parseAdd()
        while true do
            local t = peek()
            local op
            if t and t.kind == "op" and (t.v == "<" or t.v == ">" or t.v == "<=" or t.v == ">=") then
                op = t.v
            elseif t and t.kind == "name" and (t.v == "eq" or t.v == "ne") then
                op = t.v
            else
                break
            end
            pos = pos + 1
            local right = parseAdd()
            if op == "eq" then
                left = (tostring(left) == tostring(right)) and 1 or 0
            elseif op == "ne" then
                left = (tostring(left) ~= tostring(right)) and 1 or 0
            else
                local a, b = toNumber(left), toNumber(right)
                if op == "<" then left = (a < b) and 1 or 0
                elseif op == ">" then left = (a > b) and 1 or 0
                elseif op == "<=" then left = (a <= b) and 1 or 0
                else left = (a >= b) and 1 or 0 end
            end
        end
        return left
    end

    local function parseEq()
        local left = parseComp()
        while isOp("==") or isOp("!=") do
            local op = peek().v
            pos = pos + 1
            local right = parseComp()
            local a, b = tonumber(left), tonumber(right)
            local equal
            if a ~= nil and b ~= nil then
                equal = (a == b)
            else
                equal = (tostring(left) == tostring(right))
            end
            if op == "==" then left = equal and 1 or 0
            else left = equal and 0 or 1 end
        end
        return left
    end

    local function parseAnd()
        local left = parseEq()
        while isOp("&&") do
            pos = pos + 1
            local right = parseEq()
            left = (isTrue(left) and isTrue(right)) and 1 or 0
        end
        return left
    end

    local function parseOr()
        local left = parseAnd()
        while isOp("||") do
            pos = pos + 1
            local right = parseAnd()
            left = (isTrue(left) or isTrue(right)) and 1 or 0
        end
        return left
    end

    parseTernary = function()
        local cond = parseOr()
        if isOp("?") then
            pos = pos + 1
            local a = parseTernary()
            expectOp(":")
            local b = parseTernary()
            return isTrue(cond) and a or b
        end
        return cond
    end

    local v = parseTernary()
    if pos <= #toks then error("extra tokens at end of expression", 0) end
    if type(v) == "number" then return numToStr(v) end
    return tostring(v)
end

local function evalExprWords(words, frame, first)
    local parts = {}
    for k = first, #words do parts[#parts + 1] = words[k] end
    return Expr.eval(table.concat(parts, " "), frame)
end

-- ===== Commands ==============================================================

local cmds = Tcl.commands

local function wrongArgs(usage)
    return ERROR, "wrong # args: should be \"" .. usage .. "\""
end

cmds["puts"] = function(words, frame)
    local i, nonewline = 2, false
    if words[i] == "-nonewline" then
        nonewline = true
        i = i + 1
    end
    if #words ~= i then return wrongArgs("puts ?-nonewline? string") end
    io.write(words[i])
    if not nonewline then io.write("\n") end
    return OK, ""
end

cmds["set"] = function(words, frame)
    if #words == 2 then
        local v = frame[words[2]]
        if v == nil then
            return ERROR, "can't read \"" .. words[2] .. "\": no such variable"
        end
        return OK, v
    elseif #words == 3 then
        frame[words[2]] = words[3]
        return OK, words[3]
    end
    return wrongArgs("set varName ?newValue?")
end

cmds["unset"] = function(words, frame)
    for k = 2, #words do
        frame[words[k]] = nil
    end
    return OK, ""
end

cmds["append"] = function(words, frame)
    if #words < 2 then return wrongArgs("append varName ?value value ...?") end
    local name = words[2]
    local v = frame[name] or ""
    for k = 3, #words do v = v .. words[k] end
    frame[name] = v
    return OK, v
end

cmds["incr"] = function(words, frame)
    if #words ~= 2 and #words ~= 3 then return wrongArgs("incr varName ?increment?") end
    local name = words[2]
    local cur = frame[name]
    if cur == nil then cur = "0" end
    local ok, n = pcall(toNumber, cur)
    if not ok then return ERROR, n end
    local delta = 1
    if #words == 3 then
        local ok2, d = pcall(toNumber, words[3])
        if not ok2 then return ERROR, d end
        delta = d
    end
    local v = numToStr(n + delta)
    frame[name] = v
    return OK, v
end

cmds["expr"] = function(words, frame)
    if #words < 2 then return wrongArgs("expr arg ?arg ...?") end
    local ok, res = pcall(evalExprWords, words, frame, 2)
    if not ok then return ERROR, tostring(res) end
    return OK, res
end

cmds["if"] = function(words, frame)
    local i = 2
    while i <= #words do
        local cond = words[i]
        i = i + 1
        if words[i] == "then" then i = i + 1 end
        local body = words[i]
        if body == nil then return ERROR, "wrong # args: no script following \"if\" condition" end
        i = i + 1
        local ok, condVal = pcall(Expr.eval, cond, frame)
        if not ok then return ERROR, tostring(condVal) end
        if isTrue(condVal) then
            return evalScript(body, frame)
        end
        local kw = words[i]
        if kw == nil then return OK, "" end
        if kw == "elseif" then
            i = i + 1
        elseif kw == "else" then
            local elseBody = words[i + 1]
            if elseBody == nil then return ERROR, "wrong # args: no script following \"else\"" end
            return evalScript(elseBody, frame)
        else
            return ERROR, "invalid \"if\" syntax: expected \"elseif\" or \"else\" but got \"" .. kw .. "\""
        end
    end
    return OK, ""
end

cmds["while"] = function(words, frame)
    if #words ~= 3 then return wrongArgs("while test command") end
    local cond, body = words[2], words[3]
    local result = ""
    while true do
        local ok, condVal = pcall(Expr.eval, cond, frame)
        if not ok then return ERROR, tostring(condVal) end
        if not isTrue(condVal) then break end
        local code, val = evalScript(body, frame)
        if code == BREAK then break end
        if code ~= OK and code ~= CONTINUE then return code, val end
        result = val
    end
    return OK, ""
end

cmds["for"] = function(words, frame)
    if #words ~= 5 then return wrongArgs("for start test next command") end
    local start, test, nextS, body = words[2], words[3], words[4], words[5]
    local code, val = evalScript(start, frame)
    if code ~= OK then return code, val end
    while true do
        local ok, condVal = pcall(Expr.eval, test, frame)
        if not ok then return ERROR, tostring(condVal) end
        if not isTrue(condVal) then break end
        code, val = evalScript(body, frame)
        if code == BREAK then break end
        if code ~= OK and code ~= CONTINUE then return code, val end
        code, val = evalScript(nextS, frame)
        if code ~= OK then return code, val end
    end
    return OK, ""
end

cmds["foreach"] = function(words, frame)
    if #words ~= 4 then return wrongArgs("foreach varList list command") end
    local okv, varNames = pcall(listToTable, words[2])
    if not okv then return ERROR, tostring(varNames) end
    local okl, items = pcall(listToTable, words[3])
    if not okl then return ERROR, tostring(items) end
    if #varNames == 0 then return ERROR, "foreach varlist is empty" end
    local body = words[4]
    local i = 1
    while i <= #items do
        for k, name in ipairs(varNames) do
            frame[name] = items[i + k - 1] or ""
        end
        i = i + #varNames
        local code, val = evalScript(body, frame)
        if code == BREAK then break end
        if code ~= OK and code ~= CONTINUE then return code, val end
    end
    return OK, ""
end

cmds["break"] = function(words, frame)
    if #words ~= 1 then return wrongArgs("break") end
    return BREAK, ""
end

cmds["continue"] = function(words, frame)
    if #words ~= 1 then return wrongArgs("continue") end
    return CONTINUE, ""
end

cmds["return"] = function(words, frame)
    if #words > 2 then return wrongArgs("return ?value?") end
    return RETURN, words[2] or ""
end

cmds["proc"] = function(words, frame)
    if #words ~= 4 then return wrongArgs("proc name args body") end
    local name, argSpec, body = words[2], words[3], words[4]
    local okp, params = pcall(listToTable, argSpec)
    if not okp then return ERROR, tostring(params) end
    Tcl.commands[name] = function(callWords, callerFrame)
        local localFrame = {}
        local nParams = #params
        for idx, p in ipairs(params) do
            local spec = listToTable(p)
            local pname, default = spec[1], spec[2]
            if pname == "args" and idx == nParams then
                local rest = {}
                for k = idx + 1, #callWords do rest[#rest + 1] = callWords[k] end
                localFrame["args"] = tableToList(rest)
            else
                local v = callWords[idx + 1]
                if v == nil then v = default end
                if v == nil then
                    return ERROR, "wrong # args: should be \"" .. name .. " "
                        .. table.concat(params, " ") .. "\""
                end
                localFrame[pname] = v
            end
        end
        if params[nParams] ~= "args" and #callWords - 1 > nParams then
            return ERROR, "wrong # args: should be \"" .. name .. " "
                .. table.concat(params, " ") .. "\""
        end
        local code, val = evalScript(body, localFrame)
        if code == RETURN or code == OK then return OK, val end
        if code == ERROR then return ERROR, val end
        return ERROR, "invoked \"" .. (code == BREAK and "break" or "continue")
            .. "\" outside of a loop"
    end
    return OK, ""
end

cmds["global"] = function(words, frame)
    if frame == Tcl.globals then return OK, "" end
    for k = 2, #words do
        local name = words[k]
        -- proxy reads/writes for this name to the global frame via metatable
        local mt = getmetatable(frame)
        if not mt then
            mt = { linked = {} }
            mt.__index = function(t, key)
                if mt.linked[key] then return Tcl.globals[key] end
                return nil
            end
            mt.__newindex = function(t, key, value)
                if mt.linked[key] then
                    Tcl.globals[key] = value
                else
                    rawset(t, key, value)
                end
            end
            setmetatable(frame, mt)
        end
        rawset(frame, name, nil)
        mt.linked[name] = true
    end
    return OK, ""
end

cmds["eval"] = function(words, frame)
    if #words < 2 then return wrongArgs("eval arg ?arg ...?") end
    local parts = {}
    for k = 2, #words do parts[#parts + 1] = words[k] end
    return evalScript(table.concat(parts, " "), frame)
end

cmds["catch"] = function(words, frame)
    if #words ~= 2 and #words ~= 3 then return wrongArgs("catch script ?varName?") end
    local code, val = evalScript(words[2], frame)
    if #words == 3 then
        frame[words[3]] = val
    end
    return OK, numToStr(code)
end

cmds["error"] = function(words, frame)
    if #words ~= 2 then return wrongArgs("error message") end
    return ERROR, words[2]
end

cmds["exit"] = function(words, frame)
    local status = 0
    if words[2] then
        local ok, n = pcall(toNumber, words[2])
        if ok then status = n end
    end
    os.exit(status)
end

cmds["source"] = function(words, frame)
    if #words ~= 2 then return wrongArgs("source fileName") end
    local f, err = io.open(words[2], "r")
    if not f then return ERROR, "couldn't read file \"" .. words[2] .. "\": " .. tostring(err) end
    local content = f:read("*a")
    f:close()
    local code, val = evalScript(content, frame)
    if code == RETURN then return OK, val end
    return code, val
end

-- ----- string ----------------------------------------------------------------

local stringSub = {}

stringSub["length"] = function(a) return numToStr(#a[1]) end
stringSub["toupper"] = function(a) return string.upper(a[1]) end
stringSub["tolower"] = function(a) return string.lower(a[1]) end
stringSub["trim"] = function(a) return (a[1]:gsub("^%s+", ""):gsub("%s+$", "")) end
stringSub["trimleft"] = function(a) return (a[1]:gsub("^%s+", "")) end
stringSub["trimright"] = function(a) return (a[1]:gsub("%s+$", "")) end
stringSub["reverse"] = function(a) return a[1]:reverse() end

stringSub["index"] = function(a)
    local s, i = a[1], a[2]
    if i == nil then error("wrong # args: should be \"string index string charIndex\"", 0) end
    local n
    if i == "end" then n = #s - 1
    elseif i:match("^end%-%d+$") then n = #s - 1 - tonumber(i:match("%d+"))
    else n = toNumber(i) end
    if n < 0 or n >= #s then return "" end
    return s:sub(n + 1, n + 1)
end

stringSub["range"] = function(a)
    local s, first, last = a[1], a[2], a[3]
    if last == nil then error("wrong # args: should be \"string range string first last\"", 0) end
    local function idx(x)
        if x == "end" then return #s - 1 end
        local m = x:match("^end%-(%d+)$")
        if m then return #s - 1 - tonumber(m) end
        return toNumber(x)
    end
    local f, l = math.max(0, idx(first)), math.min(#s - 1, idx(last))
    if f > l then return "" end
    return s:sub(f + 1, l + 1)
end

stringSub["repeat"] = function(a)
    local s, count = a[1], a[2]
    if count == nil then error("wrong # args: should be \"string repeat string count\"", 0) end
    return string.rep(s, toNumber(count))
end

stringSub["equal"] = function(a)
    if a[2] == nil then error("wrong # args: should be \"string equal string1 string2\"", 0) end
    return (a[1] == a[2]) and "1" or "0"
end

stringSub["compare"] = function(a)
    if a[2] == nil then error("wrong # args: should be \"string compare string1 string2\"", 0) end
    if a[1] < a[2] then return "-1" elseif a[1] > a[2] then return "1" end
    return "0"
end

stringSub["first"] = function(a)
    local needle, hay = a[1], a[2]
    if hay == nil then error("wrong # args: should be \"string first needleString haystackString\"", 0) end
    local pos = hay:find(needle, 1, true)
    return numToStr((pos or 0) - 1)
end

stringSub["last"] = function(a)
    local needle, hay = a[1], a[2]
    if hay == nil then error("wrong # args: should be \"string last needleString haystackString\"", 0) end
    local found = -1
    local from = 1
    while true do
        local pos = hay:find(needle, from, true)
        if not pos then break end
        found = pos - 1
        from = pos + 1
    end
    return numToStr(found)
end

stringSub["match"] = function(a)
    local pattern, s = a[1], a[2]
    if s == nil then error("wrong # args: should be \"string match pattern string\"", 0) end
    -- translate glob to Lua pattern
    local lp = pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".")
    return s:match("^" .. lp .. "$") and "1" or "0"
end

cmds["string"] = function(words, frame)
    if #words < 3 then return wrongArgs("string subcommand string ?arg ...?") end
    local sub = stringSub[words[2]]
    if not sub then
        return ERROR, "unknown or unsupported \"string\" subcommand \"" .. words[2] .. "\""
    end
    local args = {}
    for k = 3, #words do args[#args + 1] = words[k] end
    local ok, res = pcall(sub, args)
    if not ok then return ERROR, tostring(res) end
    return OK, res
end

-- ----- lists ------------------------------------------------------------------

cmds["list"] = function(words, frame)
    local t = {}
    for k = 2, #words do t[#t + 1] = words[k] end
    return OK, tableToList(t)
end

cmds["llength"] = function(words, frame)
    if #words ~= 2 then return wrongArgs("llength list") end
    local ok, t = pcall(listToTable, words[2])
    if not ok then return ERROR, tostring(t) end
    return OK, numToStr(#t)
end

cmds["lindex"] = function(words, frame)
    if #words ~= 3 then return wrongArgs("lindex list index") end
    local ok, t = pcall(listToTable, words[2])
    if not ok then return ERROR, tostring(t) end
    local i = words[3]
    local n
    if i == "end" then n = #t - 1
    elseif i:match("^end%-%d+$") then n = #t - 1 - tonumber(i:match("%d+"))
    else
        local ok2, num = pcall(toNumber, i)
        if not ok2 then return ERROR, num end
        n = num
    end
    return OK, t[n + 1] or ""
end

cmds["lappend"] = function(words, frame)
    if #words < 2 then return wrongArgs("lappend varName ?value value ...?") end
    local name = words[2]
    local cur = frame[name] or ""
    local parts = {}
    if cur ~= "" then parts[#parts + 1] = cur end
    for k = 3, #words do parts[#parts + 1] = listElement(words[k]) end
    local v = table.concat(parts, " ")
    frame[name] = v
    return OK, v
end

cmds["lrange"] = function(words, frame)
    if #words ~= 4 then return wrongArgs("lrange list first last") end
    local ok, t = pcall(listToTable, words[2])
    if not ok then return ERROR, tostring(t) end
    local function idx(x)
        if x == "end" then return #t - 1 end
        local m = x:match("^end%-(%d+)$")
        if m then return #t - 1 - tonumber(m) end
        return toNumber(x)
    end
    local okf, f = pcall(idx, words[3]); if not okf then return ERROR, f end
    local okl, l = pcall(idx, words[4]); if not okl then return ERROR, l end
    f = math.max(0, f)
    l = math.min(#t - 1, l)
    local out = {}
    for k = f + 1, l + 1 do out[#out + 1] = t[k] end
    return OK, tableToList(out)
end

cmds["split"] = function(words, frame)
    if #words ~= 2 and #words ~= 3 then return wrongArgs("split string ?splitChars?") end
    local s = words[2]
    local seps = words[3]
    local out = {}
    if seps == "" then
        for k = 1, #s do out[#out + 1] = s:sub(k, k) end
    else
        seps = seps or " \t\n\r"
        local sepClass = "[" .. seps:gsub("[%^%]%%%-]", "%%%0") .. "]"
        local start = 1
        while true do
            local pos = s:find(sepClass, start)
            if not pos then
                out[#out + 1] = s:sub(start)
                break
            end
            out[#out + 1] = s:sub(start, pos - 1)
            start = pos + 1
        end
    end
    return OK, tableToList(out)
end

cmds["join"] = function(words, frame)
    if #words ~= 2 and #words ~= 3 then return wrongArgs("join list ?joinString?") end
    local ok, t = pcall(listToTable, words[2])
    if not ok then return ERROR, tostring(t) end
    return OK, table.concat(t, words[3] or " ")
end

-- ----- info -------------------------------------------------------------------

cmds["info"] = function(words, frame)
    local sub = words[2]
    if sub == "exists" then
        if #words ~= 3 then return wrongArgs("info exists varName") end
        return OK, (frame[words[3]] ~= nil) and "1" or "0"
    elseif sub == "commands" then
        local names = {}
        for name in pairs(Tcl.commands) do names[#names + 1] = name end
        table.sort(names)
        return OK, tableToList(names)
    end
    return ERROR, "unknown or unsupported \"info\" subcommand \"" .. tostring(sub) .. "\""
end

-- ===== Entry point: script mode or REPL ======================================

local CODE_NAME = {
    [RETURN] = nil, [BREAK] = "break", [CONTINUE] = "continue",
}

local function runScriptFile(path, scriptArgs)
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("mini-tcl: couldn't read file \"" .. path .. "\": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    local content = f:read("*a")
    f:close()

    Tcl.globals["argv0"] = path
    Tcl.globals["argv"] = tableToList(scriptArgs)
    Tcl.globals["argc"] = numToStr(#scriptArgs)

    local code, val = evalScript(content, Tcl.globals)
    if code == ERROR then
        io.stderr:write("mini-tcl: " .. tostring(val) .. "\n")
        os.exit(1)
    elseif CODE_NAME[code] then
        io.stderr:write("mini-tcl: invoked \"" .. CODE_NAME[code] .. "\" outside of a loop\n")
        os.exit(1)
    end
end

-- True while braces/brackets/quotes are unbalanced (needs more input lines).
local function needsMoreInput(s)
    local depth, bracket = 0, 0
    local inQuote = false
    local i, len = 1, #s
    while i <= len do
        local c = s:sub(i, i)
        if c == '\\' then
            i = i + 1
        elseif inQuote then
            if c == '"' then inQuote = false end
        elseif c == '"' then inQuote = true
        elseif c == '{' then depth = depth + 1
        elseif c == '}' then depth = depth - 1
        elseif c == '[' then bracket = bracket + 1
        elseif c == ']' then bracket = bracket - 1
        end
        i = i + 1
    end
    return depth > 0 or bracket > 0 or inQuote or s:sub(-1) == '\\'
end

local function repl()
    local lua_version = _VERSION or "Lua"
    print("mini-tcl (" .. lua_version .. ") — type 'exit' to quit")
    while true do
        io.write("% ")
        io.output():flush()
        local line = io.read("*l")
        if line == nil then break end

        while needsMoreInput(line) do
            io.write("> ")
            io.output():flush()
            local more = io.read("*l")
            if more == nil then break end
            if line:sub(-1) == '\\' then
                line = line:sub(1, -2) .. "\n" .. more
            else
                line = line .. "\n" .. more
            end
        end

        if line:match("%S") then
            local code, val = evalScript(line, Tcl.globals)
            if code == ERROR then
                print("error: " .. tostring(val))
            elseif CODE_NAME[code] then
                print("error: invoked \"" .. CODE_NAME[code] .. "\" outside of a loop")
            elseif val ~= "" then
                print(val)
            end
        end
    end
end

-- Embedding hook: a host (e.g. the browser REPL via fengari) sets the global
-- MINI_TCL_EMBED before loading this file to get the interpreter table instead
-- of the CLI behavior. Drive it with: minitcl.evalScript(line, minitcl.globals)
if rawget(_G, "MINI_TCL_EMBED") then
    Tcl.codes = { OK = OK, ERROR = ERROR, RETURN = RETURN,
                  BREAK = BREAK, CONTINUE = CONTINUE }
    _G.minitcl = Tcl
    return Tcl
end

local cliArgs = arg or {}
if cliArgs[1] then
    local scriptArgs = {}
    for k = 2, #cliArgs do scriptArgs[#scriptArgs + 1] = cliArgs[k] end
    runScriptFile(cliArgs[1], scriptArgs)
else
    repl()
end
