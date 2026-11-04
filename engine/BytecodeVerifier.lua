--!strict
--[[
	BytecodeVerifier.lua
	Validates a Proto chunk BEFORE it's handed to LuauVM:load, so malformed
	bytecode (a bug in whatever produced it) or tampered bytecode (someone
	hex-edited the blob) fails loudly instead of running with corrupted
	registers/jumps, or being silently trusted.

	Two layers:
	  1. verify(proto)         - structural validation: every opcode is
	     known, every operand is in range for that opcode's register
	     window / constant table / jump target, recursively for nested
	     protos. Returns (true) or (false, reason).
	  2. sign(proto, key) / check(proto, key, signature) - a lightweight
	     keyed rolling checksum over the chunk's serialized shape, so a chunk that
	     passes structural validation but was still swapped for a
	     DIFFERENT valid chunk (e.g. an attacker's own bytecode, correctly
	     formed) can be rejected because it doesn't match the signature
	     you generated at build time.

	Neither layer tries to prove the bytecode is SAFE in a sandboxing
	sense (that's what the `env` allowlist in LuauVM:installStdlib is for)
	- this is about integrity: is this the exact chunk you built, in a
	shape the VM can execute without index-out-of-bounds surprises.
]]

local VM = require(script.Parent.LuauVM)
local OP = VM.OP
local OPNAMES = VM.OPNAMES

local Verifier = {}

----------------------------------------------------------------------
-- 1. Structural verification
----------------------------------------------------------------------

local function isRegOrK(x: any): boolean
	return type(x) == "number"
end

-- Per-opcode operand shape: what `a`/`b`/`c` are allowed to mean, so we can
-- range-check them against the proto's actual register/constant/proto
-- counts instead of trusting the instruction blindly.
type OperandKind = "reg" | "rk" | "const" | "proto" | "upval" | "jump" | "raw" | "none"

local SHAPE: { [number]: { a: OperandKind, b: OperandKind, c: OperandKind } } = {
	[OP.LOADK]     = { a = "reg", b = "const", c = "none" },
	[OP.LOADBOOL]  = { a = "reg", b = "raw",   c = "none" },
	[OP.LOADNIL]   = { a = "reg", b = "reg",   c = "none" },
	[OP.MOVE]      = { a = "reg", b = "reg",   c = "none" },
	[OP.GETUPVAL]  = { a = "reg", b = "upval", c = "none" },
	[OP.SETUPVAL]  = { a = "reg", b = "upval", c = "none" },
	[OP.GETGLOBAL] = { a = "reg", b = "const", c = "none" },
	[OP.SETGLOBAL] = { a = "reg", b = "const", c = "none" },
	[OP.NEWTABLE]  = { a = "reg", b = "none",  c = "none" },
	[OP.GETTABLE]  = { a = "reg", b = "reg",   c = "rk" },
	[OP.SETTABLE]  = { a = "reg", b = "rk",    c = "rk" },
	[OP.GETFIELD]  = { a = "reg", b = "reg",   c = "const" },
	[OP.SETFIELD]  = { a = "reg", b = "const", c = "rk" },
	[OP.ADD] = { a = "reg", b = "rk", c = "rk" },
	[OP.SUB] = { a = "reg", b = "rk", c = "rk" },
	[OP.MUL] = { a = "reg", b = "rk", c = "rk" },
	[OP.DIV] = { a = "reg", b = "rk", c = "rk" },
	[OP.MOD] = { a = "reg", b = "rk", c = "rk" },
	[OP.POW] = { a = "reg", b = "rk", c = "rk" },
	[OP.UNM] = { a = "reg", b = "rk", c = "none" },
	[OP.CONCAT] = { a = "reg", b = "reg", c = "reg" },
	[OP.EQ] = { a = "rk", b = "rk", c = "raw" },
	[OP.LT] = { a = "rk", b = "rk", c = "raw" },
	[OP.LE] = { a = "rk", b = "rk", c = "raw" },
	[OP.NOT] = { a = "reg", b = "reg", c = "none" },
	[OP.JMP] = { a = "jump", b = "none", c = "none" },
	[OP.TEST] = { a = "reg", b = "jump", c = "raw" },
	[OP.TESTSET] = { a = "reg", b = "reg", c = "raw" },
	[OP.CALL] = { a = "reg", b = "raw", c = "raw" },
	[OP.RETURN] = { a = "reg", b = "raw", c = "none" },
	[OP.TAILCALL] = { a = "reg", b = "raw", c = "none" },
	[OP.CLOSURE] = { a = "reg", b = "proto", c = "none" },
	[OP.VARARG] = { a = "reg", b = "raw", c = "none" },
	[OP.LEN] = { a = "reg", b = "reg", c = "none" },
	[OP.FORPREP] = { a = "reg", b = "jump", c = "none" },
	[OP.FORLOOP] = { a = "reg", b = "jump", c = "none" },
	[OP.SETLIST] = { a = "reg", b = "raw", c = "raw" },
	[OP.SELF] = { a = "reg", b = "reg", c = "const" },
	[OP.CLOSE] = { a = "reg", b = "none", c = "none" },
}

local function checkOperand(kind: OperandKind, v: any, proto, instrIdx: number): (boolean, string?)
	if kind == "none" then
		return true
	elseif kind == "raw" then
		if v ~= nil and type(v) ~= "number" then
			return false, ("instr %d: raw operand must be number or nil, got %s"):format(instrIdx, type(v))
		end
		return true
	elseif kind == "reg" then
		if type(v) ~= "number" or v < 0 or v >= proto.maxStack then
			return false, ("instr %d: register operand %s out of range [0,%d)"):format(instrIdx, tostring(v), proto.maxStack)
		end
		return true
	elseif kind == "const" then
		if type(v) ~= "number" or v < 0 or v >= #proto.consts then
			return false, ("instr %d: const index %s out of range [0,%d)"):format(instrIdx, tostring(v), #proto.consts)
		end
		return true
	elseif kind == "rk" then
		if type(v) ~= "number" then
			return false, ("instr %d: RK operand must be a number, got %s"):format(instrIdx, type(v))
		end
		if v < 0 then
			local kidx = -v - 1
			if kidx < 0 or kidx >= #proto.consts then
				return false, ("instr %d: RK const index %d out of range [0,%d)"):format(instrIdx, kidx, #proto.consts)
			end
		else
			if v >= proto.maxStack then
				return false, ("instr %d: RK register %d out of range [0,%d)"):format(instrIdx, v, proto.maxStack)
			end
		end
		return true
	elseif kind == "proto" then
		if type(v) ~= "number" or v < 0 or v >= #proto.protos then
			return false, ("instr %d: child proto index %s out of range [0,%d)"):format(instrIdx, tostring(v), #proto.protos)
		end
		return true
	elseif kind == "upval" then
		if type(v) ~= "number" or v < 0 or v >= #proto.upvals then
			return false, ("instr %d: upval index %s out of range [0,%d)"):format(instrIdx, tostring(v), #proto.upvals)
		end
		return true
	elseif kind == "jump" then
		if type(v) ~= "number" then
			return false, ("instr %d: jump offset must be a number, got %s"):format(instrIdx, type(v))
		end
		return true
	end
	return true
end

-- Validate one proto (and recursively, its children). Returns (true) or
-- (false, reason).
function Verifier.verify(proto, _seen: { [any]: boolean }?): (boolean, string?)
	if type(proto) ~= "table" then
		return false, "proto is not a table"
	end
	for name, code in pairs(OP) do
		if type(code) ~= "number" or OPNAMES[code] ~= name then
			return false, ("LuauVM opcode mapping mismatch for %s"):format(tostring(name))
		end
	end
	local seen = _seen or {}
	if seen[proto] then
		return false, "cyclic proto graph (a proto references itself as a child)"
	end
	seen[proto] = true
	if type(proto.code) ~= "table" then
		return false, "proto.code missing or not a table"
	end
	if type(proto.consts) ~= "table" then
		return false, "proto.consts missing or not a table"
	end
	if type(proto.maxStack) ~= "number" or proto.maxStack < 1 or proto.maxStack % 1 ~= 0 then
		return false, "proto.maxStack missing or invalid (expected positive integer)"
	end
	if type(proto.numparams) ~= "number" or proto.numparams < 0 or proto.numparams % 1 ~= 0 or proto.numparams > proto.maxStack then
		return false, "proto.numparams invalid or exceeds maxStack"
	end
	if type(proto.upvals) ~= "table" or type(proto.protos) ~= "table" then
		return false, "proto.upvals and proto.protos must be tables"
	end
	if type(proto.isVararg) ~= "boolean" then
		return false, "proto.isVararg must be boolean"
	end

	for i, desc in ipairs(proto.upvals) do
		if type(desc) ~= "table" or (desc.kind ~= "local" and desc.kind ~= "upval")
			or type(desc.index) ~= "number" or desc.index < 0 or desc.index % 1 ~= 0 then
			return false, ("upvalue descriptor %d is malformed"):format(i)
		end
	end

	local codeLen = #proto.code

	for i, instr in ipairs(proto.code) do
		if type(instr) ~= "table" or type(instr.op) ~= "number" then
			return false, ("instr %d: malformed instruction (missing op)"):format(i)
		end
		local shape = SHAPE[instr.op]
		if not shape then
			return false, ("instr %d: unknown opcode %s"):format(i, tostring(instr.op))
		end

		local ok, reason = checkOperand(shape.a, instr.a, proto, i)
		if not ok then return false, reason end
		ok, reason = checkOperand(shape.b, instr.b, proto, i)
		if not ok then return false, reason end
		ok, reason = checkOperand(shape.c, instr.c, proto, i)
		if not ok then return false, reason end

		local function integerField(field, value, minimum)
			if type(value) ~= "number" or value % 1 ~= 0 or value < minimum then
				return false, ("instr %d: %s must be an integer >= %d"):format(i, field, minimum)
			end
			return true
		end
		if instr.op == OP.LOADBOOL and instr.b ~= 0 and instr.b ~= 1 then
			return false, ("instr %d: LOADBOOL b must be 0 or 1"):format(i)
		end
		if (instr.op == OP.TEST or instr.op == OP.EQ or instr.op == OP.LT or instr.op == OP.LE)
			and instr.c ~= 0 and instr.c ~= 1 then
			return false, ("instr %d: branch/comparison flag must be 0 or 1"):format(i)
		end
		if instr.op == OP.LOADNIL and instr.a > instr.b then
			return false, ("instr %d: LOADNIL register range is reversed"):format(i)
		end
		if instr.op == OP.CONCAT and instr.b > instr.c then
			return false, ("instr %d: CONCAT register range is reversed"):format(i)
		end
		if instr.op == OP.FORPREP or instr.op == OP.FORLOOP then
			if instr.a + 3 >= proto.maxStack then
				return false, ("instr %d: numeric-for register window exceeds maxStack"):format(i)
			end
		end
		if instr.op == OP.SELF and instr.a + 1 >= proto.maxStack then
			return false, ("instr %d: SELF register window exceeds maxStack"):format(i)
		end
		if instr.op == OP.SETLIST and (instr.c < 0 or instr.c % 1 ~= 0 or instr.a + instr.c >= proto.maxStack) then
			return false, ("instr %d: SETLIST register window is invalid"):format(i)
		end
		if instr.op == OP.CALL or instr.op == OP.RETURN or instr.op == OP.TAILCALL or instr.op == OP.VARARG then
			local field = (instr.op == OP.CALL or instr.op == OP.RETURN or instr.op == OP.TAILCALL) and "b" or "b"
			local good, why = integerField(field, instr.b, 0)
			if not good then return false, why end
			if instr.op == OP.CALL then
				good, why = integerField("c", instr.c, 0)
				if not good then return false, why end
			end
		end

		-- Jump targets must land inside the code array (pc is 1-based and
		-- checked against the instruction AFTER the jump instruction, same
		-- as the VM's own `frame.pc += offset` after incrementing past it).
		if shape.a == "jump" or shape.b == "jump" then
			local offsetField = (shape.a == "jump") and instr.a or instr.b
			local fromPc = i + 1 -- VM has already advanced pc past this instr
			local target = fromPc + offsetField
			if target < 1 or target > codeLen + 1 then
				return false, ("instr %d: jump target pc=%d out of bounds [1,%d]"):format(i, target, codeLen + 1)
			end
		end
	end

	for childIndex, child in ipairs(proto.protos or {}) do
		if type(child) ~= "table" then
			return false, ("child proto %d is not a table"):format(childIndex - 1)
		end
		for upIndex, desc in ipairs(child.upvals or {}) do
			local limit = desc.kind == "local" and proto.maxStack or #proto.upvals
			if desc.index >= limit then
				return false, ("child proto %d upvalue %d captures outside its parent"):format(childIndex - 1, upIndex - 1)
			end
		end
		local ok, reason = Verifier.verify(child, seen)
		if not ok then return false, reason end
	end

	seen[proto] = nil
	return true
end

----------------------------------------------------------------------
-- 2. Checksum / signature (tamper detection)
----------------------------------------------------------------------

-- A simple, dependency-free rolling checksum over a deterministic Proto
-- serialization. This is NOT cryptographically secure and the key is not a
-- secret once shipped in client-visible source. It is useful for detecting
-- accidental changes and unsophisticated edits, not a determined attacker.
local function serialize(value: any, parts: { string })
	local t = type(value)
	if t == "table" then
		parts[#parts + 1] = "{"
		-- stable order: array part first, then sorted string keys
		local n = 0
		for i, v in ipairs(value) do
			n = i
			serialize(v, parts)
			parts[#parts + 1] = ","
		end
		local keys = {}
		for k in pairs(value) do
			if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = tostring(k)
			parts[#parts + 1] = "="
			serialize(value[k], parts)
			parts[#parts + 1] = ","
		end
		parts[#parts + 1] = "}"
	elseif t == "string" then
		parts[#parts + 1] = ("%q"):format(value)
	else
		parts[#parts + 1] = tostring(value)
	end
end

local function rollingHash(str: string, key: number): number
	local h = key % 4294967296
	for i = 1, #str do
		h = (h * 131 + string.byte(str, i)) % 4294967296
	end
	return h
end

-- Returns a numeric signature for `proto`, salted with `key`.
function Verifier.sign(proto, key: number): number
	local parts = {}
	serialize(proto, parts)
	return rollingHash(table.concat(parts), key)
end

-- Verifies `proto` against a previously computed `signature`, using the
-- same `key`. Call this (then Verifier.verify) before VM:load in
-- production, so a tampered OR substituted-but-valid chunk is rejected.
function Verifier.check(proto, key: number, signature: number): boolean
	return Verifier.sign(proto, key) == signature
end

return Verifier
