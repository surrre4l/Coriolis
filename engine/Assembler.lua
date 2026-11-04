--!strict
--[[
	Assembler.lua
	A small builder API for constructing LuauVM bytecode "Proto" chunks by
	hand / programmatically, without needing a full source-level compiler.

	Usage pattern:

		local Asm = require(script.Parent.Assembler)
		local VM  = require(script.Parent.LuauVM)

		local b = Asm.new({ numparams = 1, isVararg = false })
		local r0 = 0 -- register holding the single parameter
		local k0 = b:k(10)
		b:emit(VM.OP.ADD, 1, r0, k0 * -1 - 1) -- hand-encoding RK is error-prone;
		                                       -- prefer b:constRK(value) below.

	Prefer the helper methods (below) over raw emit() + manual RK encoding;
	they exist specifically to make hand/programmatic assembly less error
	prone, which matters a lot once you're generating bytecode from a
	higher-level description (e.g. a minimal custom DSL or a transform over
	your existing Luau AST).
]]

local VM = require(script.Parent.LuauVM)
local OP = VM.OP

local Assembler = {}
Assembler.__index = Assembler

export type BuilderOpts = {
	numparams: number?,
	isVararg: boolean?,
	name: string?,
}

function Assembler.new(opts: BuilderOpts?)
	opts = opts or {}
	local self = setmetatable({}, Assembler)
	self.code = {}
	self.consts = {}
	self.constIndex = {} -- value -> index, for de-duping simple constants
	self.protos = {}
	self.upvals = {}
	self.numparams = opts.numparams or 0
	self.isVararg = opts.isVararg or false
	self.maxStack = (opts.numparams or 0) + 1
	self.name = opts.name
	return self
end

function Assembler:reserve(reg: number)
	if reg + 1 > self.maxStack then
		self.maxStack = reg + 1
	end
end

-- Register (or reuse) a constant; returns its 0-based const index.
function Assembler:k(value: any): number
	local existing = self.constIndex[value]
	if existing then return existing end
	self.consts[#self.consts + 1] = value
	local idx = #self.consts - 1
	self.constIndex[value] = idx
	return idx
end

-- Encode a constant as an RK operand (negative-indexed).
function Assembler:constRK(value: any): number
	return -(self:k(value)) - 1
end

-- Encode a register as an RK operand (identity; registers are >= 0).
function Assembler:regRK(reg: number): number
	return reg
end

function Assembler:emit(op: number, a: any, b: any, c: any): number
	self.code[#self.code + 1] = { op = op, a = a, b = b, c = c }
	return #self.code -- 1-based index of the instruction just emitted
end

-- Patch the `a`/`b` fields of a previously emitted jump-style instruction,
-- useful for back-patching forward jumps once the target is known.
function Assembler:patch(instrIndex: number, field: "a" | "b", value: number)
	self.code[instrIndex][field] = value
end

function Assembler:here(): number
	return #self.code + 1
end

function Assembler:addProto(childProto): number
	self.protos[#self.protos + 1] = childProto
	return #self.protos - 1
end

-- Declare that this proto captures an upvalue; `kind` is "local" (capture a
-- register from the immediately enclosing frame) or "upval" (pass through
-- the enclosing closure's own upvalue). `index` is the register or upvalue
-- index in the ENCLOSING scope.
function Assembler:addUpval(kind: "local" | "upval", index: number): number
	self.upvals[#self.upvals + 1] = { kind = kind, index = index }
	return #self.upvals - 1
end

function Assembler:build()
	return {
		code = self.code,
		consts = self.consts,
		numparams = self.numparams,
		isVararg = self.isVararg,
		maxStack = self.maxStack,
		upvals = self.upvals,
		protos = self.protos,
		name = self.name,
	}
end

return Assembler
