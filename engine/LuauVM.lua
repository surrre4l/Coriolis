--!strict
--[[
	LuauVM.lua
	A register-based bytecode virtual machine written in Luau, intended to
	execute "protected" logic that has been compiled to custom bytecode
	rather than shipped as readable Luau source.

	This is the VM CORE. It does not parse Luau syntax - it executes an
	already-built Chunk (see Bytecode.lua for the instruction format and
	Assembler.lua for a programmatic way to build chunks).

	Design:
	  - Register-based (like real Luau), per-call-frame register window.
	  - Instructions are plain tables: { op = OP.XXX, a, b, c }
	  - Closures capture upvalues by reference (a 1-element table "cell").
	  - Host functions (regular Luau functions) can be exposed to protected
	    code via an environment table passed into VM.new / VM.run.
]]

local VM = {}
VM.__index = VM

----------------------------------------------------------------------
-- Opcode table (shared contract with Assembler.lua / Bytecode.lua)
----------------------------------------------------------------------

local OP = {
	LOADK     = 1,  -- R[a] = K[b]
	LOADBOOL  = 2,  -- R[a] = (b ~= 0)
	LOADNIL   = 3,  -- R[a..b] = nil
	MOVE      = 4,  -- R[a] = R[b]

	GETUPVAL  = 5,  -- R[a] = Upval[b]
	SETUPVAL  = 6,  -- Upval[b] = R[a]
	GETGLOBAL = 7,  -- R[a] = Env[K[b]]
	SETGLOBAL = 8,  -- Env[K[b]] = R[a]

	NEWTABLE  = 9,  -- R[a] = {}
	GETTABLE  = 10, -- R[a] = R[b][RK[c]]
	SETTABLE  = 11, -- R[a][RK[b]] = RK[c]
	GETFIELD  = 12, -- R[a] = R[b][K[c]]   (string key fast path)
	SETFIELD  = 13, -- R[a][K[b]] = RK[c]

	ADD = 14, SUB = 15, MUL = 16, DIV = 17, MOD = 18, POW = 19, UNM = 20,
	CONCAT = 21,

	EQ = 22, LT = 23, LE = 24, NOT = 25,

	JMP  = 26, -- pc += a
	TEST = 27, -- if not (R[a] <=> c) then pc += b
	TESTSET = 28, -- if (R[b] <=> c) then R[a]=R[b] else pc+=1 ; next must be JMP

	CALL = 29, -- R[a..a+c-2] = R[a](R[a+1..a+b-1])   b=nargs+1,c=nresults+1 (0=multi)
	RETURN = 30, -- return R[a..a+b-2]                 (0=multi to top)
	TAILCALL = 31,

	CLOSURE = 32, -- R[a] = make closure from Protos[b], capturing per UpvalDesc
	VARARG  = 33, -- R[a..] = varargs

	LEN = 34,     -- R[a] = #R[b]
	FORPREP = 35, -- numeric for setup; a=base register (idx,limit,step)
	FORLOOP = 36, -- numeric for loop increment + branch

	SETLIST = 37, -- R[a][b+i] = R[a+i] for i=1..c  (array init)
	SELF    = 38, -- R[a+1]=R[b]; R[a]=R[b][K[c]]    (method call sugar)
}
VM.OP = OP

local OPNAMES = {}
for name, code in pairs(OP) do OPNAMES[code] = name end
VM.OPNAMES = OPNAMES

----------------------------------------------------------------------
-- Internal types
----------------------------------------------------------------------

type Instr = { op: number, a: any, b: any, c: any }

type Proto = {
	code: { Instr },
	consts: { any },
	numparams: number,
	isVararg: boolean,
	maxStack: number,
	upvals: { { kind: "local" | "upval", index: number } }, -- how this proto's upvalues are captured from its PARENT frame
	protos: { Proto }, -- nested function prototypes (for CLOSURE)
	name: string?,
}
VM.Proto = nil :: Proto? -- type export marker only

type Cell = { [1]: any } -- a boxed upvalue

type Closure = {
	proto: Proto,
	upvals: { Cell },
}

type Frame = {
	closure: Closure,
	regs: { any },
	pc: number,
	varargs: { any },
	openUpvals: { [number]: Cell }, -- register index -> cell, for upvalues captured from THIS frame while it's alive
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function isRK(x: any): boolean
	-- Convention used by this VM's assembler: negative numbers encode a
	-- constant index (as -(k+1)); non-negative encode a register index.
	return type(x) == "number" and x < 0
end

local function rkIndex(x: number): number
	return -x - 1 -- converts the encoded negative back to 0-based const index
end

----------------------------------------------------------------------
-- VM object
----------------------------------------------------------------------

function VM.new(env: { [string]: any }?)
	local self = setmetatable({}, VM)
	self.env = env or {}
	return self
end

-- Wrap a Proto (top-level chunk) into a callable Luau function.
function VM:load(proto: Proto, name: string?): (...any) -> ...any
	local topClosure: Closure = { proto = proto, upvals = {} }
	return function(...)
		return self:callClosure(topClosure, { ... })
	end
end

function VM:callClosure(closure: Closure, args: { any }): ...any
	local proto = closure.proto
	local regs = table.create(math.max(proto.maxStack, proto.numparams + 1))
	local nparams = proto.numparams

	for i = 1, nparams do
		regs[i - 1] = args[i]
	end

	local varargs = {}
	if proto.isVararg then
		for i = nparams + 1, #args do
			varargs[#varargs + 1] = args[i]
		end
	end

	local frame: Frame = {
		closure = closure,
		regs = regs,
		pc = 1,
		varargs = varargs,
		openUpvals = {},
	}

	return self:execute(frame)
end

-- Resolve a register-or-constant operand.
local function RK(frame: Frame, consts: { any }, x: any): any
	if isRK(x) then
		return consts[rkIndex(x) + 1]
	else
		return frame.regs[x]
	end
end

function VM:execute(frame: Frame): ...any
	local closure = frame.closure
	local proto = closure.proto
	local code = proto.code
	local consts = proto.consts
	local regs = frame.regs
	local env = self.env

	while true do
		local instr = code[frame.pc]
		if instr == nil then
			return -- fell off the end with no explicit RETURN
		end
		frame.pc += 1

		local op = instr.op
		local a, b, c = instr.a, instr.b, instr.c

		if op == OP.LOADK then
			regs[a] = consts[b + 1]

		elseif op == OP.LOADBOOL then
			regs[a] = (b ~= 0)

		elseif op == OP.LOADNIL then
			for i = a, b do regs[i] = nil end

		elseif op == OP.MOVE then
			regs[a] = regs[b]

		elseif op == OP.GETUPVAL then
			regs[a] = closure.upvals[b + 1][1]

		elseif op == OP.SETUPVAL then
			closure.upvals[b + 1][1] = regs[a]

		elseif op == OP.GETGLOBAL then
			regs[a] = env[consts[b + 1]]

		elseif op == OP.SETGLOBAL then
			env[consts[b + 1]] = regs[a]

		elseif op == OP.NEWTABLE then
			regs[a] = {}

		elseif op == OP.GETTABLE then
			regs[a] = regs[b][RK(frame, consts, c)]

		elseif op == OP.SETTABLE then
			regs[a][RK(frame, consts, b)] = RK(frame, consts, c)

		elseif op == OP.GETFIELD then
			regs[a] = regs[b][consts[c + 1]]

		elseif op == OP.SETFIELD then
			regs[a][consts[b + 1]] = RK(frame, consts, c)

		elseif op == OP.ADD then
			regs[a] = RK(frame, consts, b) + RK(frame, consts, c)
		elseif op == OP.SUB then
			regs[a] = RK(frame, consts, b) - RK(frame, consts, c)
		elseif op == OP.MUL then
			regs[a] = RK(frame, consts, b) * RK(frame, consts, c)
		elseif op == OP.DIV then
			regs[a] = RK(frame, consts, b) / RK(frame, consts, c)
		elseif op == OP.MOD then
			regs[a] = RK(frame, consts, b) % RK(frame, consts, c)
		elseif op == OP.POW then
			regs[a] = RK(frame, consts, b) ^ RK(frame, consts, c)
		elseif op == OP.UNM then
			regs[a] = -RK(frame, consts, b)
		elseif op == OP.CONCAT then
			local s = ""
			for i = b, c do s = s .. tostring(regs[i]) end
			regs[a] = s

		elseif op == OP.EQ then
			local eq = RK(frame, consts, a) == RK(frame, consts, b)
			if eq ~= (c ~= 0) then frame.pc += 1 end

		elseif op == OP.LT then
			local lt = RK(frame, consts, a) < RK(frame, consts, b)
			if lt ~= (c ~= 0) then frame.pc += 1 end

		elseif op == OP.LE then
			local le = RK(frame, consts, a) <= RK(frame, consts, b)
			if le ~= (c ~= 0) then frame.pc += 1 end

		elseif op == OP.NOT then
			regs[a] = not regs[b]

		elseif op == OP.JMP then
			frame.pc += a

		elseif op == OP.TEST then
			local v = regs[a]
			local truthy = v ~= nil and v ~= false
			if truthy ~= (c ~= 0) then
				frame.pc += b
			end

		elseif op == OP.TESTSET then
			local v = regs[b]
			local truthy = v ~= nil and v ~= false
			if truthy == (c ~= 0) then
				regs[a] = v
			else
				frame.pc += 1 -- skip the following JMP
			end

		elseif op == OP.LEN then
			regs[a] = #regs[b]

		elseif op == OP.CLOSURE then
			local childProto = proto.protos[b + 1]
			local upvals = table.create(#childProto.upvals)
			for i, desc in ipairs(childProto.upvals) do
				if desc.kind == "local" then
					-- capture (or reuse) an open cell for a register of THIS frame
					local reg = desc.index
					local cell = frame.openUpvals[reg]
					if not cell then
						cell = { regs[reg] }
						frame.openUpvals[reg] = cell
						-- Note: this simplified VM does not "close" upvalues on
						-- scope exit the way real Lua does; cells stay boxed and
						-- are read/written through GETUPVAL/SETUPVAL consistently,
						-- which is sufficient for closures that don't rely on
						-- block-scoped re-capture per loop iteration. See README
						-- for the documented limitation + workaround pattern.
					end
					upvals[i] = cell
				else -- "upval": pass parent's upvalue cell straight through
					upvals[i] = closure.upvals[desc.index]
				end
			end
			regs[a] = { proto = childProto, upvals = upvals } :: Closure

		elseif op == OP.VARARG then
			if b == 0 then
				for i, v in ipairs(frame.varargs) do regs[a + i - 1] = v end
			else
				for i = 1, b - 1 do regs[a + i - 1] = frame.varargs[i] end
			end

		elseif op == OP.SELF then
			local obj = regs[b]
			regs[a + 1] = obj
			regs[a] = obj[consts[c + 1]]

		elseif op == OP.SETLIST then
			local t = regs[a]
			for i = 1, c do
				t[b + i] = regs[a + i]
			end

		elseif op == OP.FORPREP then
			local idx, limit, step = regs[a], regs[a + 1], regs[a + 2]
			regs[a] = idx - step
			frame.pc += b

		elseif op == OP.FORLOOP then
			local idx = regs[a] + regs[a + 2]
			regs[a] = idx
			local limit, step = regs[a + 1], regs[a + 2]
			local continue_ = (step > 0 and idx <= limit) or (step <= 0 and idx >= limit)
			if continue_ then
				regs[a + 3] = idx
				frame.pc += b
			end

		elseif op == OP.CALL then
			local fn = regs[a]
			local nargs = b - 1
			local args
			if b == 0 then
				-- multi: args run from a+1 to top-of-registers marker in `c`-less form (simplified: use c as count)
				args = {}
				for i = a + 1, c do args[#args + 1] = regs[i] end
			else
				args = table.create(nargs)
				for i = 1, nargs do args[i] = regs[a + i] end
			end

			local results = { self:callAny(fn, args) }

			if c == 0 then
				for i, v in ipairs(results) do regs[a + i - 1] = v end
				frame._multiTop = a + #results - 1
			else
				local nres = c - 1
				for i = 1, nres do regs[a + i - 1] = results[i] end
			end

		elseif op == OP.TAILCALL then
			local fn = regs[a]
			local nargs = b - 1
			local args = table.create(nargs)
			for i = 1, nargs do args[i] = regs[a + i] end
			return self:callAny(fn, args)

		elseif op == OP.RETURN then
			if b == 0 then
				local out = {}
				for i = a, (frame._multiTop or a - 1) do out[#out + 1] = regs[i] end
				return table.unpack(out)
			elseif b == 1 then
				return
			else
				local out = table.create(b - 1)
				for i = 1, b - 1 do out[i] = regs[a + i - 1] end
				return table.unpack(out)
			end

		else
			error(("LuauVM: unknown opcode %s"):format(tostring(op)))
		end
	end
end

-- Call either a VM Closure or a plain host Luau function uniformly.
function VM:callAny(fn: any, args: { any }): ...any
	if type(fn) == "table" and fn.proto ~= nil and fn.upvals ~= nil then
		return self:callClosure(fn :: Closure, args)
	elseif type(fn) == "function" then
		return fn(table.unpack(args))
	else
		error("LuauVM: attempt to call a " .. type(fn) .. " value")
	end
end

return VM
