--!nonstrict
--[[
	ASTCompiler.spec.lua
	Test suite for ASTCompiler.lua: Parse -> Compile -> Verify -> Execute -> assert.

	This is written as a plain Luau ModuleScript returning a `run()` function,
	matching the `require(script.Parent.X)` convention used by every other file
	in this set (Lexer/Parser/Assembler/LuauVM/BytecodeVerifier all assume a
	Roblox-style ModuleScript tree, not a standalone `lua` CLI). Drop it next
	to the other five files and run it from a Script via:

		require(path.to.ASTCompiler.spec).run()

	It prints a PASS/FAIL line per case and returns false if anything failed.

	IMPORTANT, READ BEFORE TRUSTING THIS: this file was written by inspecting
	Lexer.lua/Parser.lua/LuauVM.lua/Assembler.lua/BytecodeVerifier.lua and
	reasoning through ASTCompiler.lua's output by hand, instruction by
	instruction, for each case below. It has NOT been executed -- this
	sandbox has no Luau/Lua interpreter and no network access to fetch one
	(checked: no system `lua`, apt has no interpreter package reachable,
	npm/pip registries are unreachable). Run this yourself and tell me what
	fails; do not take "the compiler is correct" as demonstrated until this
	suite has actually been run against your real files.
]]

local Lexer = require(script.Parent.Parent.engine.Lexer)
local Parser = require(script.Parent.Parent.engine.Parser)
local ASTCompiler = require(script.Parent.Parent.engine.ASTCompiler)
local Verifier = require(script.Parent.Parent.engine.BytecodeVerifier)
local VM = require(script.Parent.Parent.engine.LuauVM)
local Encoder = require(script.Parent.Parent.engine.Encoder)

local function runSource(src, env)
	local ok, chunk = pcall(Parser.parse, src)
	if not ok then
		return false, "parse error: " .. tostring(chunk)
	end

	local cok, proto = ASTCompiler.compile(chunk)
	if not cok then
		return false, "compile error: " .. tostring(proto)
	end

	local vok, verr = Verifier.verify(proto)
	if not vok then
		return false, "verifier rejected output: " .. tostring(verr)
	end

	local vm = VM.new(env or {})
	local fn = vm:load(proto, "test")
	local results = { pcall(fn) }
	local runOk = table.remove(results, 1)
	if not runOk then
		return false, "runtime error: " .. tostring(results[1])
	end
	return true, results
end

local cases = {}
local function case(name, fn)
	cases[#cases + 1] = { name = name, fn = fn }
end

local function expectEq(actual, expected, msg)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(msg or "mismatch", tostring(expected), tostring(actual)), 2)
	end
end

----------------------------------------------------------------------

case("local variables", function()
	local ok, results = runSource([[
		local a = 1
		local b = a + 2
		return b
	]])
	assert(ok, results)
	expectEq(results[1], 3)
end)

case("global variables", function()
	local env = {}
	local ok, results = runSource([[
		x = 10
		y = x + 5
		return y
	]], env)
	assert(ok, results)
	expectEq(results[1], 15)
	expectEq(env.x, 10)
end)

case("arithmetic", function()
	local ok, results = runSource([[
		return 2 + 3 * 4 - 1, 10 / 4, 2 ^ 10, 7 % 3
	]])
	assert(ok, results)
	expectEq(results[1], 13)
	expectEq(results[2], 2.5)
	expectEq(results[3], 1024)
	expectEq(results[4], 1)
end)

case("comparisons", function()
	local ok, results = runSource([[
		return 1 == 1, 1 ~= 2, 1 < 2, 2 <= 2, 3 > 2, 2 >= 3
	]])
	assert(ok, results)
	expectEq(results[1], true)
	expectEq(results[2], true)
	expectEq(results[3], true)
	expectEq(results[4], true)
	expectEq(results[5], true)
	expectEq(results[6], false)
end)

case("boolean short-circuiting", function()
	local env = { calls = {} }
	env.mark = function(tag, v) table.insert(env.calls, tag); return v end
	local ok, results = runSource([[
		local a = false and mark("rhs_and", true)
		local b = true or mark("rhs_or", true)
		local c = true and mark("rhs_and2", 5)
		return a, b, c, #calls
	]], env)
	assert(ok, results)
	expectEq(results[1], false)
	expectEq(results[2], true)
	expectEq(results[3], 5)
	expectEq(results[4], 1) -- only "rhs_and2" should have run
end)

case("if statements", function()
	local ok, results = runSource([[
		local function classify(n)
			if n < 0 then
				return "neg"
			elseif n == 0 then
				return "zero"
			else
				return "pos"
			end
		end
		return classify(-1), classify(0), classify(5)
	]])
	assert(ok, results)
	expectEq(results[1], "neg")
	expectEq(results[2], "zero")
	expectEq(results[3], "pos")
end)

case("while loops", function()
	local ok, results = runSource([[
		local i = 0
		local sum = 0
		while i < 5 do
			i = i + 1
			sum = sum + i
		end
		return sum
	]])
	assert(ok, results)
	expectEq(results[1], 15)
end)

case("repeat loops", function()
	local ok, results = runSource([[
		local i = 0
		repeat
			i = i + 1
		until i >= 5
		return i
	]])
	assert(ok, results)
	expectEq(results[1], 5)
end)

case("numeric for loops", function()
	local ok, results = runSource([[
		local sum = 0
		for i = 1, 10 do
			sum = sum + i
		end
		local sum2 = 0
		for i = 10, 1, -2 do
			sum2 = sum2 + i
		end
		return sum, sum2
	]])
	assert(ok, results)
	expectEq(results[1], 55)
	expectEq(results[2], 30) -- 10+8+6+4+2
end)

case("generic for loops", function()
	local env = {}
	local ok, results = runSource([[
		local t = {10, 20, 30}
		local sum = 0
		for i, v in ipairs(t) do
			sum = sum + v
		end
		return sum
	]], env)
	assert(ok, results)
	expectEq(results[1], 60)
end)

case("tables", function()
	local ok, results = runSource([[
		local t = {1, 2, 3, x = 10, [100] = "hundred"}
		return t[1], t[2], t[3], t.x, t[100], #t
	]])
	assert(ok, results)
	expectEq(results[1], 1)
	expectEq(results[2], 2)
	expectEq(results[3], 3)
	expectEq(results[4], 10)
	expectEq(results[5], "hundred")
	expectEq(results[6], 3)
end)

case("functions", function()
	local ok, results = runSource([[
		local function add(a, b)
			return a + b
		end
		return add(3, 4)
	]])
	assert(ok, results)
	expectEq(results[1], 7)
end)

case("nested functions and upvalues", function()
	local ok, results = runSource([[
		local function makeCounter()
			local count = 0
			local function increment()
				count = count + 1
				return count
			end
			return increment
		end
		local c1 = makeCounter()
		local c2 = makeCounter()
		local a1 = c1()
		local a2 = c1()
		local b1 = c2()
		return a1, a2, b1
	]])
	assert(ok, results)
	expectEq(results[1], 1)
	expectEq(results[2], 2)
	expectEq(results[3], 1) -- independent closure, own `count`
end)

case("loop-per-iteration upvalue capture", function()
	-- classic closure-in-loop trap: each closure must see its OWN i.
	local ok, results = runSource([[
		local fns = {}
		for i = 1, 3 do
			fns[i] = function() return i end
		end
		return fns[1](), fns[2](), fns[3]()
	]])
	assert(ok, results)
	expectEq(results[1], 1)
	expectEq(results[2], 2)
	expectEq(results[3], 3)
end)

case("multiple returns", function()
	local ok, results = runSource([[
		local function three()
			return 1, 2, 3
		end
		local a, b, c = three()
		local x, y = three()
		return a, b, c, x, y
	]])
	assert(ok, results)
	expectEq(results[1], 1)
	expectEq(results[2], 2)
	expectEq(results[3], 3)
	expectEq(results[4], 1)
	expectEq(results[5], 2) -- extra 3rd value from three() correctly discarded
end)

case("varargs", function()
	local ok, results = runSource([[
		local function sum(...)
			local a, b, c = ...
			return (a or 0) + (b or 0) + (c or 0)
		end
		return sum(1, 2, 3), sum(5)
	]])
	assert(ok, results)
	expectEq(results[1], 6)
	expectEq(results[2], 5)
end)

case("method calls", function()
	local ok, results = runSource([[
		local obj = { value = 10 }
		function obj:getValue()
			return self.value
		end
		function obj:add(n)
			self.value = self.value + n
			return self.value
		end
		local v1 = obj:getValue()
		local v2 = obj:add(5)
		return v1, v2
	]])
	assert(ok, results)
	expectEq(results[1], 10)
	expectEq(results[2], 15)
end)

case("break and continue", function()
	local ok, results = runSource([[
		local sum = 0
		for i = 1, 10 do
			if i == 5 then
				break
			end
			sum = sum + i
		end

		local sum2 = 0
		for i = 1, 5 do
			if i % 2 == 0 then
				continue
			end
			sum2 = sum2 + i
		end
		return sum, sum2
	]])
	assert(ok, results)
	expectEq(results[1], 10) -- 1+2+3+4
	expectEq(results[2], 9)  -- 1+3+5
end)

case("nested scopes and shadowing", function()
	local ok, results = runSource([[
		local x = 1
		do
			local x = 2
			do
				local x = 3
			end
		end
		local function f()
			local x = 100
			return x
		end
		return x, f()
	]])
	assert(ok, results)
	expectEq(results[1], 1)
	expectEq(results[2], 100)
end)

case("string concatenation and interpolation", function()
	local ok, results = runSource([[
		local a = "hello"
		local b = "world"
		local c = a .. " " .. b
		local n = 5
		local d = `n is {n}, c is {c}`
		return c, d
	]])
	assert(ok, results)
	expectEq(results[1], "hello world")
	expectEq(results[2], "n is 5, c is hello world")
end)

case("interpolated string with non-top-of-stack destination register", function()
	-- regression test for the CONCAT-contiguity bug found and fixed during
	-- development: `b`'s register is reserved before `a`'s initializer (an
	-- InterpString) is compiled.
	local ok, results = runSource([[
		local x = 7
		local a, b = `val={x}`, 99
		return a, b
	]])
	assert(ok, results)
	expectEq(results[1], "val=7")
	expectEq(results[2], 99)
end)

case("compound assignment", function()
	local ok, results = runSource([[
		local x = 10
		x += 5
		x -= 2
		x *= 3
		local t = {n = 1}
		t.n += 10
		local s = "a"
		s ..= "b"
		return x, t.n, s
	]])
	assert(ok, results)
	expectEq(results[1], 39) -- ((10+5-2)*3)
	expectEq(results[2], 11)
	expectEq(results[3], "ab")
end)

case("unsupported: floor division is rejected", function()
	local ok, results = runSource([[
		return 7 // 2
	]])
	assert(not ok, "expected a compile error for '//'")
end)

case("unsupported: bare 'return ...' is rejected", function()
	local ok, results = runSource([[
		local function f(...)
			return ...
		end
		return f(1, 2, 3)
	]])
	assert(not ok, "expected a compile error for bare 'return ...'")
end)

case("unsupported: trailing multi-value call argument is rejected", function()
	local ok, results = runSource([[
		local function three() return 1, 2, 3 end
		local function f(a, b, c) return a + b + c end
		return f(three())
	]])
	assert(not ok, "expected a compile error for f(three()) forwarding all results")
end)


case("invalid source reports a parse error", function()
	local ok, err = runSource("local =")
	assert(not ok, "expected invalid source to fail")
	assert(string.find(tostring(err), "error", 1, true), "expected a meaningful parse/compile error")
end)

case("corrupted Proto is rejected", function()
	local bad = {
		code = { { op = 999, a = 0, b = 0, c = 0 } },
		consts = {}, numparams = 0, isVararg = false, maxStack = 1,
		upvals = {}, protos = {},
	}
	local ok, reason = Verifier.verify(bad)
	assert(not ok, "expected unknown opcode to be rejected")
	assert(string.find(tostring(reason), "unknown opcode", 1, true), "expected opcode error")
end)

case("encoder inserts the exact automatic watermark", function()
	local ok, proto = ASTCompiler.compileSource("return 42")
	assert(ok, proto)
	local output = Encoder.encode(proto, {
		watermark = "This Script is Protected by Coriolis v2.1.0",
		signature = Verifier.sign(proto, 0),
		signatureKey = 0,
	})
	assert(string.find(output, "This Script is Protected by Coriolis v2.1.0", 1, true))
	assert(string.find(output, "BytecodeVerifier", 1, true))
end)

----------------------------------------------------------------------

local function run()
	local passed, failed = 0, 0
	for _, c in ipairs(cases) do
		local ok, err = pcall(c.fn)
		if ok then
			passed = passed + 1
			print("PASS: " .. c.name)
		else
			failed = failed + 1
			print("FAIL: " .. c.name .. " -- " .. tostring(err))
		end
	end
	print(("%d passed, %d failed (of %d)"):format(passed, failed, #cases))
	return failed == 0
end

return { run = run }