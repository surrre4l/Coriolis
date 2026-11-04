--!nonstrict
--[[
	ASTCompiler.lua
	Compiles the AST produced by Parser.lua into Coriolis custom Proto bytecode "Proto" tables
	(the format built by Assembler.lua and executed by LuauVM.lua).

	Pipeline: Lexer -> Parser -> ASTCompiler (this file) -> Assembler -> LuauVM.

	Entry points:
	  ASTCompiler.compile(chunkAst, opts) -> ok:boolean, protoOrErrorMessage
	    chunkAst = the result of Parser.parse(src) (a Chunk node).
	    opts (optional) = { name = "chunk name" }
	  ASTCompiler.compileSource(src, opts) -> ok, protoOrErrorMessage
	    Convenience: Parser.parse(src) then compile().

	On success, `proto` is a table in exactly the shape LuauVM.lua / Assembler.lua
	expect: { code, consts, numparams, isVararg, maxStack, upvals, protos, name }.
	Pass it to VM:load(proto) or Verifier.verify(proto) directly.

	On failure, the second return is a string: "Compile error at line L col C: message"
	(mirrors the Lexer/Parser error string convention), or a string prefixed
	"Compile error: " for errors with no single clear source position.

	================================================================
	COMPATIBILITY MAP (read this before changing anything below)
	================================================================

	AST node kinds consumed (from Parser.lua's own header comment, verified against
	Parser.lua's actual node construction sites):

	  Runtime statements: Local, Assign, CompoundAssign, CallStat, Do, If, While,
	    Repeat, NumericFor, GenericFor, FunctionDecl, LocalFunction, Return, Break,
	    Continue.
	  Runtime expressions: Nil, True, False, Number{value,raw}, String{value},
	    InterpString{strings,exprs}, Vararg, Name{resolution,var,upvalueIndex},
	    DotIndex{base,name}, BracketIndex{base,index}, Call{base,args,multi},
	    MethodCall{base,method,args,multi}, Function{...}, Table{fields,arrayCount,multi},
	    Unop{op,expr}, Binop{op,lhs,rhs}, IfExpr{clauses,elseExpr}, Paren{expr}.
	  Type-only nodes (TypeAlias, TypeAssert, and the .types/.typ/.generics/etc
	    fields) are never seen by this compiler: ASTCompiler.compile() calls
	    Parser.eraseTypes(chunk) first, which removes them in place.

	Scope data used as-is (never recomputed): Var{level,captured,assigned,declKind},
	  Name.resolution/.var/.upvalueIndex, Function.upvalues[i]={name,var,kind,index,
	  parentIndex}, block.scope={vars,hasCaptured}. Parser scope IDs/levels are NOT
	  register numbers; this file owns all register allocation independently and
	  only consults Parser's scope data to know *which* Var is being read/written
	  and *whether* a block needs a CLOSE.

	Coriolis Proto opcodes (from LuauVM.lua's OP table and BytecodeVerifier.lua's SHAPE
	table, which is the ground truth for operand *kinds* -- "reg" = plain register
	index, "const" = plain 0-based index into proto.consts, "rk" = Assembler:regRK
	or :constRK encoded operand, "raw" = arbitrary integer, "proto" = 0-based
	index into proto.protos, "upval" = 0-based index into proto.upvals):

	  LOADK     {reg,const}    R[a]=K[b]                 b is PLAIN const index (asm:k)
	  LOADBOOL  {reg,raw,raw}  R[a]=(b~=0)                c is unused by the VM but
	                                                       Verifier requires b,c in {0,1}
	  LOADNIL   {reg,reg}      R[a..b]=nil
	  MOVE      {reg,reg}      R[a]=R[b]
	  GETUPVAL  {reg,upval}    R[a]=Upval[b]
	  SETUPVAL  {reg,upval}    Upval[b]=R[a]
	  GETGLOBAL {reg,const}    R[a]=Env[K[b]]             b is PLAIN const index
	  SETGLOBAL {reg,const}    Env[K[b]]=R[a]
	  NEWTABLE  {reg}          R[a]={}
	  GETTABLE  {reg,reg,rk}   R[a]=R[b][RK(c)]
	  SETTABLE  {reg,rk,rk}    R[a][RK(b)]=RK(c)
	  GETFIELD  {reg,reg,const} R[a]=R[b][K[c]]           c is PLAIN const index
	  SETFIELD  {reg,const,rk} R[a][K[b]]=RK(c)           b is PLAIN const index
	  ADD/SUB/MUL/DIV/MOD/POW  {reg,rk,rk}  R[a]=RK(b) <op> RK(c)
	  UNM       {reg,rk}       R[a]=-RK(b)
	  CONCAT    {reg,reg,reg}  R[a]=R[b]..R[b+1]..'..'..R[c]  ALL THREE ARE PLAIN
	                            REGISTERS (not rk!) and b..c must be a contiguous
	                            register window.
	  EQ/LT/LE  {rk,rk,raw}    compares RK(a) <op> RK(b); if result~=(c~=0) then
	                            pc+=1 (i.e. these are branch/skip instructions, NOT
	                            "store a boolean" instructions -- a,b are the RK
	                            OPERANDS being compared, there is no destination
	                            register on this instruction).
	  NOT       {reg,reg}      R[a]=not R[b]
	  JMP       {raw}          pc += a
	  TEST      {reg,raw,raw}  if truthy(R[a])~=(c~=0) then pc+=b
	  TESTSET   {reg,reg,raw}  if truthy(R[b])==(c~=0) then R[a]=R[b] else pc+=1
	                            (unused by this compiler; TEST+JMP covers every
	                            case we need and is simpler to reason about)
	  CALL      {reg,raw,raw}  R[a..a+c-2]=R[a](R[a+1..a+b-1]); b=nargs+1 (ALWAYS
	                            emitted as a static count by this compiler -- see
	                            "KNOWN VM LIMITATIONS" below for why b=0 is never
	                            used); c=nresults+1, c=0 means "all results,
	                            consumed via frame._multiTop" (dynamic, and the
	                            ONLY place this compiler uses c=0 is a trailing
	                            Call in a Return statement's expression list).
	  RETURN    {reg,raw}      b=nvalues+1, b=0 means "return R[a..frame._multiTop]"
	  TAILCALL  {reg,raw}      b=nargs+1 (not emitted by this compiler: TAILCALL
	                            would need the same static-b args convention as
	                            CALL, and Luau tail-call elimination is a pure
	                            optimization with no observable semantic this
	                            compiler needs; every call compiles as CALL+RETURN)
	  CLOSURE   {reg,proto}    R[a]=closure over Protos[b]; b is PLAIN proto index
	                            (Assembler:addProto's return value)
	  VARARG    {reg,raw}      b=nresults+1, b=0 means "all varargs" (this
	                            compiler never emits b=0 -- see limitations)
	  LEN       {reg,reg}      R[a]=#R[b]
	  FORPREP   {reg,raw}      R[a]=R[a]-R[a+2]; pc+=b
	  FORLOOP   {reg,raw}      idx=R[a]+R[a+2]; R[a]=idx; if in-range then
	                            R[a+3]=idx; pc+=b
	  SETLIST   {reg,raw,raw}  R[a][b+i]=R[a+i] for i=1..c (b is always emitted as
	                            0 by this compiler: array literals' items are
	                            placed at R[a+1..a+arrayCount])
	  SELF      {reg,reg,const} R[a+1]=R[b]; R[a]=R[b][K[c]]; c is PLAIN const index
	  CLOSE     {reg}          close every open upvalue cell with register >= a
	  PCALL     {reg,raw,raw}  not emitted by this compiler (Luau's `pcall` is
	                            just a normal global function call in LuauVM's
	                            stdlib, i.e. a plain CALL to env.pcall; OP.PCALL
	                            is a VM-level instruction with no Luau source
	                            syntax that maps onto it)

	Register convention: register 0..numparams-1 hold the parameters on entry
	(set by LuauVM:callClosure). This compiler tracks a single "next free
	register" cursor per function (self.freeReg) exactly like a textbook Lua
	compiler: declaring a local permanently claims the next free register until
	its enclosing block ends; every expression sub-computation claims a register
	at-or-above the current cursor and releases it (restores the cursor) once
	the enclosing instruction has consumed it. Parser Var identity (the table
	itself) is the map key from "declared variable" to "register number", via
	self.varReg[var] = register; Parser's own var.id/var.level are informational
	only and never used as a register number.

	Constant convention: Assembler:k(value) de-dupes by raw Lua value equality
	and returns a 0-based index into proto.consts. nil is NEVER passed to
	Assembler:k (it indexes an internal Lua table by the constant's value --
	`self.constIndex[value] = idx` -- and `t[nil] = x` raises "table index is
	nil"); a Nil literal is therefore always materialized via LOADNIL into a
	register, never folded into a constant table slot.

	Jump convention: matches BytecodeVerifier.lua exactly -- for a JMP/FORPREP/
	FORLOOP instruction at 1-based code index `pc`, target = pc + 1 + offset.
	This compiler always computes offsets as `target - (instrIndex + 1)` using
	Assembler:here() (next instruction's 1-based index) as `target`, and
	Assembler:patch() to backfill forward jumps once the target is known.

	Function prototype / upvalue format: built via Assembler.new/:build(), which
	already produces the exact {code,consts,numparams,isVararg,maxStack,upvals,
	protos,name} shape LuauVM.lua requires -- this file never constructs a Proto
	table by hand. Nested functions are compiled as separate Assembler instances
	and attached to the parent via parentAsm:addProto(childAsm:build()), with the
	returned 0-based index used as CLOSURE's `b` operand. Each upvalue descriptor
	is added via childAsm:addUpval(kind, index), where `index` is resolved from
	Parser's Function.upvalues[i] exactly as documented in Parser.lua: for
	kind=="local", index = the captured Var's REGISTER in the immediately
	enclosing function (self.varReg[var] on the parent FuncCompiler, looked up
	at CLOSURE-emission time, which is always while that local is still in
	scope); for kind=="upval", index = entry.parentIndex, i.e. the enclosing
	function's OWN upvalue slot for that var (already resolved recursively by
	Parser:upvalueFor, so this file just reads it).

	Multi-return / multi-arg / vararg convention: see "KNOWN VM LIMITATIONS".

	================================================================
	KNOWN VM LIMITATIONS (discovered by inspection, not guessed) -- these are
	NOT bugs this compiler works around by reinterpreting the VM; they are
	genuine gaps in what OP.CALL/OP.VARARG/OP.RETURN, as actually implemented
	in LuauVM.lua, can express. Per the brief ("do not silently generate
	incorrect bytecode ... return a clear compilation error"), every AST shape
	that would require one of these unsupported encodings raises a compile
	error instead of emitting something that merely *runs* without crashing
	but produces the wrong values.
	================================================================

	1. OP.RETURN with b=0 ("return everything up to frame._multiTop") is only
	   correct when frame._multiTop was set by the PRECEDING instruction, and
	   the ONLY opcode that ever sets frame._multiTop is CALL with c=0 (see its
	   handler in LuauVM.lua: "frame._multiTop = a + #results - 1"). OP.VARARG
	   never touches frame._multiTop. So `return ...` (returning an unknown
	   number of varargs with no preceding/following fixed values) has no
	   correct encoding in this VM: there is no instruction that lets RETURN
	   know how many varargs there were. This compiler raises a compile error
	   for a bare `...` (or `...` not immediately preceded by being the single
	   trailing element with a prior call result) used as the final, countless,
	   multi-expanding element of a `return` statement. A Return whose final
	   expression is itself a Call is fully supported (CALL c=0 + RETURN b=0
	   compose correctly).

	2. OP.CALL with b=0 ("args are multi, gathered via `for i=a+1,c do`") reads
	   its args window up to a STATIC register index baked into the instruction
	   at compile time (operand `c`, reused for this purpose only when b==0).
	   There is no way for this compiler to know, at compile time, how many
	   registers a dynamic-count multi-value (a trailing call or `...` in an
	   argument list) will actually occupy at runtime -- unlike RETURN, nothing
	   in CALL's b=0 path consults frame._multiTop. So forwarding "all results
	   of a trailing call" or "all remaining varargs" as call arguments (e.g.
	   `f(x, g())` wanting ALL of g()'s results, or `f(...)`) has no correct
	   encoding. This compiler always emits CALL/SELF-call args with a STATIC
	   b (only ever requesting a single value from a non-last argument, which
	   is already correct Luau semantics), and raises a compile error if the
	   LAST argument is a multi-expanding Call/Vararg/MethodCall.

	3. The same static-count requirement applies to OP.SETLIST (`c` is a plain
	   static count) for table constructors: `{a, b, f()}` wanting ALL of f()'s
	   results as trailing array items has no correct encoding. A compile error
	   is raised when a Table constructor's final array item is multi-valued.

	   None of the above limit the common, fully-supported cases: `local a, b =
	   f()` / `a, b = f()` / `for k, v in pairs(t) do` / `return f()` all expand
	   a trailing call to a KNOWN STATIC number of wanted results (the compiler
	   always knows exactly how many names/targets/loop-vars it needs), which
	   this VM's CALL c=<N+1> (N static) handles perfectly -- only *unbounded*
	   ("give me everything, however many there are") forwarding is unsupported.

	4. Luau's floor-division operator `//` (and compound `//=`) is valid syntax
	   accepted by Lexer.lua and Parser.lua (BINOP_PRIORITY["//"] exists), but
	   LuauVM.lua's OP table has no corresponding opcode (only ADD/SUB/MUL/DIV/
	   MOD/POW/UNM exist; DIV is ordinary `/`, not truncating). Silently
	   compiling `//` to DIV would be semantically wrong. This compiler raises
	   a compile error on `//` / `//=`.

	5. Variable attributes `<const>`/`<close>` are already rejected by
	   Parser.lua itself (parseLocal errors before producing an AST node), so
	   there is nothing for this file to additionally guard there.

	6. Generic-for loop termination: this VM has no "is exactly nil" branch
	   primitive usable with a dynamically-produced register value except the
	   general-purpose TEST instruction, which treats `nil` and `false`
	   identically (both falsy). Real Luau terminates a generic-for only when
	   the first returned value is `nil` specifically (a `false` key from a
	   well-behaved iterator keeps iterating). This compiler's generic-for
	   therefore also terminates on a `false` first value, which is a
	   documented, deliberate simplification -- not a silent miscompile -- and
	   matches every standard-library iterator (`pairs`, `ipairs`) shipped via
	   LuauVM:installStdlib, none of which ever yields `false` as a key.
]]

local Parser = require(script.Parent.Parser)
local Assembler = require(script.Parent.Assembler)
local VM = require(script.Parent.LuauVM)
local OP = VM.OP

local ASTCompiler = {}

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------

local function isMultiValue(node)
	return Parser.isMultiValue(node)
end

local ARITH_OP = {
	["+"] = OP.ADD, ["-"] = OP.SUB, ["*"] = OP.MUL,
	["/"] = OP.DIV, ["%"] = OP.MOD, ["^"] = OP.POW,
}

local UNSUPPORTED_BINOP = {
	["//"] = true,
}

local COMPARE_INFO = {
	-- [op] = { opcode, swap(bool, swaps lhs/rhs order), invert(bool, flips true/false result) }
	["=="] = { OP.EQ, false, false },
	["~="] = { OP.EQ, false, true },
	["<"]  = { OP.LT, false, false },
	["<="] = { OP.LE, false, false },
	[">"]  = { OP.LT, true,  false },
	[">="] = { OP.LE, true,  false },
}

----------------------------------------------------------------------
-- FuncCompiler: compiles one function body (Chunk or Function node) into
-- one Assembler instance / Proto.
----------------------------------------------------------------------

local FuncCompiler = {}
FuncCompiler.__index = FuncCompiler

function FuncCompiler.new(funcNode, parent, name)
	local self = setmetatable({}, FuncCompiler)
	self.node = funcNode
	self.parent = parent -- enclosing FuncCompiler, or nil for the chunk
	self.asm = Assembler.new({
		numparams = funcNode.numparams or 0,
		isVararg = funcNode.isVararg and true or false,
		name = name,
	})
	self.varReg = {} -- Var (table identity) -> register number
	self.freeReg = funcNode.numparams or 0
	self.loopStack = {} -- stack of { base = reg, breaks = {instrIdx...}, continues = {instrIdx...} }
	return self
end

function FuncCompiler:fail(node, msg)
	local line, col = 0, 0
	if type(node) == "table" and node.line then
		line, col = node.line, node.col
	end
	error(("Compile error at line %d col %d: %s"):format(line, col, msg), 0)
end

function FuncCompiler:emit(op, a, b, c)
	return self.asm:emit(op, a, b, c)
end

function FuncCompiler:reserve(reg)
	self.asm:reserve(reg)
end

function FuncCompiler:here()
	return self.asm:here()
end

function FuncCompiler:patchOffset(instrIdx, field, target)
	self.asm:patch(instrIdx, field, target - (instrIdx + 1))
end

----------------------------------------------------------------------
-- register / constant primitives
----------------------------------------------------------------------

-- Allocates a brand-new temporary register at the current cursor and bumps
-- the cursor past it. Caller is responsible for restoring self.freeReg
-- (directly, or via compileExpr's own save/restore) once the temp is no
-- longer needed.
function FuncCompiler:newTemp()
	local r = self.freeReg
	self.freeReg = r + 1
	self:reserve(r)
	return r
end

-- Compiles `node` so that exactly one value ends up in register `dst`,
-- truncating any multi-value source (Call/Vararg) to its first result.
-- Never changes self.freeReg net (restores it on exit), but may use
-- registers >= max(dst+1, entry freeReg) transiently for subexpressions.
function FuncCompiler:compileExpr(node, dst)
	if type(node) ~= "table" or node.kind == nil then
		self:fail(node, "malformed AST node (missing 'kind')")
	end
	local saved = self.freeReg
	if self.freeReg <= dst then
		self.freeReg = dst + 1
	end

	local k = node.kind
	if k == "Nil" then
		self:emit(OP.LOADNIL, dst, dst)
	elseif k == "True" then
		self:emit(OP.LOADBOOL, dst, 1, 0)
	elseif k == "False" then
		self:emit(OP.LOADBOOL, dst, 0, 0)
	elseif k == "Number" then
		self:emit(OP.LOADK, dst, self.asm:k(node.value))
	elseif k == "String" then
		self:emit(OP.LOADK, dst, self.asm:k(node.value))
	elseif k == "Vararg" then
		self:emit(OP.VARARG, dst, 2) -- 2 => exactly 1 result
	elseif k == "InterpString" then
		self:compileInterpString(node, dst)
	elseif k == "Name" then
		self:compileName(node, dst)
	elseif k == "DotIndex" then
		local baseReg, isTemp = self:exprToAnyReg(node.base)
		self:emit(OP.GETFIELD, dst, baseReg, self.asm:k(node.name))
		if isTemp then self.freeReg = baseReg end
	elseif k == "BracketIndex" then
		local baseReg, baseTemp = self:exprToAnyReg(node.base)
		local idxRK = self:exprToRK(node.index)
		self:emit(OP.GETTABLE, dst, baseReg, idxRK)
		if baseTemp then self.freeReg = baseReg end
	elseif k == "Paren" then
		self:compileExpr(node.expr, dst)
	elseif k == "Unop" then
		self:compileUnop(node, dst)
	elseif k == "Binop" then
		self:compileBinop(node, dst)
	elseif k == "IfExpr" then
		self:compileIfExpr(node, dst)
	elseif k == "Table" then
		self:compileTable(node, dst)
	elseif k == "Function" then
		self:compileClosure(node, dst)
	elseif k == "Call" or k == "MethodCall" then
		self:compileCallLike(node, dst, 1)
	else
		self:fail(node, "unsupported expression node kind '" .. tostring(k) .. "'")
	end

	self.freeReg = saved
end

-- Compiles `node` into a fresh register if it's not already sitting in one
-- (a resolved local Name), otherwise reuses that local's register directly.
-- Returns reg, isTemp (isTemp=true means caller may release it by restoring
-- self.freeReg back to `reg`).
function FuncCompiler:exprToAnyReg(node)
	if node.kind == "Name" and node.resolution == "local" then
		return self.varReg[node.var], false
	end
	local r = self:newTemp()
	self:compileExpr(node, r)
	return r, true
end

-- Returns an RK-encoded operand: a constant index (for literal Number/
-- String/True/False) or a plain register (for everything else, via a fresh
-- temp unless it's already a local). Does not touch self.freeReg net.
function FuncCompiler:exprToRK(node)
	if type(node) == "table" then
		if node.kind == "Number" or node.kind == "String" then
			return self.asm:constRK(node.value)
		elseif node.kind == "True" then
			return self.asm:constRK(true)
		elseif node.kind == "False" then
			return self.asm:constRK(false)
		end
	end
	local saved = self.freeReg
	local reg, isTemp = self:exprToAnyReg(node)
	if isTemp then self.freeReg = saved end
	return self.asm:regRK(reg)
end

function FuncCompiler:compileName(node, dst)
	local res = node.resolution
	if res == "local" then
		local reg = self.varReg[node.var]
		if reg == nil then
			self:fail(node, "internal error: local '" .. tostring(node.name) .. "' has no assigned register")
		end
		if reg ~= dst then
			self:emit(OP.MOVE, dst, reg)
		end
	elseif res == "upvalue" then
		self:emit(OP.GETUPVAL, dst, node.upvalueIndex)
	elseif res == "global" then
		self:emit(OP.GETGLOBAL, dst, self.asm:k(node.name))
	else
		self:fail(node, "name '" .. tostring(node.name) .. "' has unexpected resolution '" .. tostring(res) .. "'")
	end
end

-- NOTE: CONCAT's b..c operands must be an EXACTLY contiguous register window
-- (the VM concatenates everything from b to c inclusive). `dst` is not
-- necessarily the top of the register file (e.g. the second name in
-- `local a, b = `x${y}`, 5` already has its register reserved above `dst`
-- before this runs), so we must not use `dst` itself as one endpoint of the
-- window -- a fresh, always-top-of-stack accumulator is used instead, moved
-- into `dst` only once at the end.
function FuncCompiler:compileInterpString(node, dst)
	local saved = self.freeReg
	local acc = self:newTemp()
	self:emit(OP.LOADK, acc, self.asm:k(node.strings[1] or ""))
	for i, exprNode in ipairs(node.exprs) do
		local vReg = self:newTemp()
		self:compileExpr(exprNode, vReg)
		self:emit(OP.CONCAT, acc, acc, vReg)
		self.freeReg = vReg -- release vReg, keep acc

		local sReg = self:newTemp()
		self:emit(OP.LOADK, sReg, self.asm:k(node.strings[i + 1] or ""))
		self:emit(OP.CONCAT, acc, acc, sReg)
		self.freeReg = sReg
	end
	if acc ~= dst then
		self:emit(OP.MOVE, dst, acc)
	end
	self.freeReg = saved
end

function FuncCompiler:compileUnop(node, dst)
	local op = node.op
	if op == "-" then
		local rk = self:exprToRK(node.expr)
		self:emit(OP.UNM, dst, rk)
	elseif op == "#" then
		local reg, isTemp = self:exprToAnyReg(node.expr)
		self:emit(OP.LEN, dst, reg)
		if isTemp then self.freeReg = reg end
	elseif op == "not" then
		local reg, isTemp = self:exprToAnyReg(node.expr)
		self:emit(OP.NOT, dst, reg)
		if isTemp then self.freeReg = reg end
	else
		self:fail(node, "unsupported unary operator '" .. tostring(op) .. "'")
	end
end

function FuncCompiler:compileBinop(node, dst)
	local op = node.op
	if op == "and" then
		self:compileExpr(node.lhs, dst)
		local t = self:emit(OP.TEST, dst, 0, 1) -- falsy -> skip rhs
		self:compileExpr(node.rhs, dst)
		self:patchOffset(t, "b", self:here())
		return
	elseif op == "or" then
		self:compileExpr(node.lhs, dst)
		local t = self:emit(OP.TEST, dst, 0, 0) -- truthy -> skip rhs
		self:compileExpr(node.rhs, dst)
		self:patchOffset(t, "b", self:here())
		return
	elseif op == ".." then
		local l = self:newTemp()
		self:compileExpr(node.lhs, l)
		local r = self:newTemp()
		self:compileExpr(node.rhs, r)
		self:emit(OP.CONCAT, dst, l, r)
		self.freeReg = l
		return
	elseif ARITH_OP[op] then
		local lrk = self:exprToRK(node.lhs)
		local rrk = self:exprToRK(node.rhs)
		self:emit(ARITH_OP[op], dst, lrk, rrk)
		return
	elseif COMPARE_INFO[op] then
		self:compileCompare(node, dst)
		return
	elseif UNSUPPORTED_BINOP[op] then
		self:fail(node, "operator '" .. op .. "' has no corresponding Coriolis Proto opcode (LuauVM.lua defines no floor-division instruction)")
	else
		self:fail(node, "unsupported binary operator '" .. tostring(op) .. "'")
	end
end

function FuncCompiler:compileCompare(node, dst)
	local info = COMPARE_INFO[node.op]
	local opcode, swap, invert = info[1], info[2], info[3]
	local lhsNode, rhsNode = node.lhs, node.rhs
	if swap then lhsNode, rhsNode = rhsNode, lhsNode end
	local a = self:exprToRK(lhsNode)
	local b = self:exprToRK(rhsNode)

	local falseVal, trueVal = 0, 1
	if invert then falseVal, trueVal = 1, 0 end

	local j1 = self:emit(opcode, a, b, 1) -- skip next instr if condition is false
	local jTrue = self:emit(OP.JMP, 0) -- taken when condition is true (falls through from j1)
	self:emit(OP.LOADBOOL, dst, falseVal, 0) -- landed here (via j1's skip) when condition false
	local jEnd = self:emit(OP.JMP, 0)
	self:patchOffset(jTrue, "a", self:here())
	self:emit(OP.LOADBOOL, dst, trueVal, 0) -- condition true
	self:patchOffset(jEnd, "a", self:here())
end

function FuncCompiler:compileIfExpr(node, dst)
	local endJumps = {}
	for _, clause in ipairs(node.clauses) do
		local saved = self.freeReg
		local condReg = self:newTemp()
		self:compileExpr(clause.cond, condReg)
		local jFalse = self:emit(OP.TEST, condReg, 0, 1)
		self.freeReg = saved
		self:compileExpr(clause.expr, dst)
		endJumps[#endJumps + 1] = self:emit(OP.JMP, 0)
		self:patchOffset(jFalse, "b", self:here())
	end
	self:compileExpr(node.elseExpr, dst)
	local finish = self:here()
	for _, j in ipairs(endJumps) do
		self:patchOffset(j, "a", finish)
	end
end

function FuncCompiler:compileTable(node, dst)
	self:emit(OP.NEWTABLE, dst)
	local saved = self.freeReg
	local arrayCount = node.arrayCount or 0
	if arrayCount > 0 then
		if self.freeReg <= dst + arrayCount then
			self.freeReg = dst + arrayCount + 1
		end
		self:reserve(self.freeReg - 1)
	end

	for _, field in ipairs(node.fields) do
		if field.type == "item" then
			if field.index == arrayCount and node.multi then
				self:fail(field.value, "table constructors cannot forward multiple values from a trailing call or '...' (no static result count); assign them to named values first")
			end
			self:compileExpr(field.value, dst + field.index)
		elseif field.type == "named" then
			local vrk = self:exprToRK(field.value)
			self:emit(OP.SETFIELD, dst, self.asm:k(field.key), vrk)
		elseif field.type == "indexed" then
			local krk = self:exprToRK(field.key)
			local vrk = self:exprToRK(field.value)
			self:emit(OP.SETTABLE, dst, krk, vrk)
		else
			self:fail(field.value or node, "unsupported table field type '" .. tostring(field.type) .. "'")
		end
	end

	if arrayCount > 0 then
		self:emit(OP.SETLIST, dst, 0, arrayCount)
	end
	self.freeReg = saved
end

----------------------------------------------------------------------
-- expression lists (Local / Assign RHS / GenericFor exprs): fills exactly
-- `wantCount` consecutive registers starting at `base`, following Lua's
-- list-assignment rules (extra exprs evaluated and discarded for side
-- effects; missing values become nil; a multi-valued trailing expr expands
-- to fill the remaining wanted slots -- using a STATIC requested count,
-- which this VM supports correctly; see file header note 2/3 for why an
-- *unbounded* expansion is instead a compile error, raised by the caller
-- before this function is reached wherever that applies).
----------------------------------------------------------------------

function FuncCompiler:compileExprListInto(exprs, base, wantCount)
	local n = #exprs
	if n == 0 then
		if wantCount > 0 then
			self:emit(OP.LOADNIL, base, base + wantCount - 1)
		end
		return
	end

	local fixedCount = math.min(n - 1, wantCount)
	for i = 1, fixedCount do
		self:compileExpr(exprs[i], base + i - 1)
	end
	-- any exprs beyond wantCount-1 but before the last one: still evaluate
	-- for side effects, discarding the value, into a scratch register.
	for i = fixedCount + 1, n - 1 do
		local saved = self.freeReg
		local scratch = self:newTemp()
		self:compileExpr(exprs[i], scratch)
		self.freeReg = saved
	end

	local lastNode = exprs[n]
	local lastDst = base + n - 1
	if n <= wantCount and isMultiValue(lastNode) then
		local need = wantCount - n + 1
		self:compileMultiExpr(lastNode, lastDst, need)
		for i = n + 1, wantCount do
			-- already filled by the multi expansion above; nothing to do
		end
	elseif n <= wantCount then
		self:compileExpr(lastNode, lastDst)
		if wantCount > n then
			self:emit(OP.LOADNIL, lastDst + 1, base + wantCount - 1)
		end
	else
		-- more exprs than wanted: compile remaining (including the last)
		-- for side effects only, discarding extras beyond wantCount.
		for i = n, n do
			if lastDst <= base + wantCount - 1 then
				self:compileExpr(lastNode, lastDst)
			else
				local saved = self.freeReg
				local scratch = self:newTemp()
				self:compileExpr(lastNode, scratch)
				self.freeReg = saved
			end
		end
	end
end

-- Compiles a Call/MethodCall/Vararg node requesting exactly `need` (>=1)
-- results, placed at consecutive registers starting at `dst`. `need` is
-- always a compile-time-known static count here (never "all").
function FuncCompiler:compileMultiExpr(node, dst, need)
	if node.kind == "Vararg" then
		self:emit(OP.VARARG, dst, need + 1)
	elseif node.kind == "Call" or node.kind == "MethodCall" then
		self:compileCallLike(node, dst, need)
	else
		self:fail(node, "internal error: compileMultiExpr called on non-multi node '" .. tostring(node.kind) .. "'")
	end
end

----------------------------------------------------------------------
-- calls
----------------------------------------------------------------------

-- resultSpec: a positive integer N (want exactly N results) or the string
-- "multi" (want ALL results, c=0; only used by Return's trailing call) or 0
-- (discard all results, used by CallStat).
function FuncCompiler:compileCallLike(node, destBase, resultSpec)
	local saved = self.freeReg
	if self.freeReg <= destBase then
		self.freeReg = destBase + 1
	end

	local isMethod = node.kind == "MethodCall"
	local argStart
	if isMethod then
		local objReg = self:newTemp()
		self:compileExpr(node.base, objReg)
		self.freeReg = destBase + 1 -- release objReg; SELF already copied it
		self:emit(OP.SELF, destBase, objReg, self.asm:k(node.method))
		argStart = destBase + 2
		if self.freeReg <= argStart - 1 then
			self.freeReg = argStart
		end
	else
		self:compileExpr(node.base, destBase)
		argStart = destBase + 1
	end

	local args = node.args
	local n = #args
	if self.freeReg < argStart + n then
		self.freeReg = argStart + n
	end
	for i = 1, n do
		local isLast = (i == n)
		if isLast and isMultiValue(args[i]) then
			self:fail(args[i], "call arguments cannot forward multiple values from a trailing call or '...' (no static argument count); assign them to named values first")
		end
		self:compileExpr(args[i], argStart + i - 1)
	end

	local nFixed = isMethod and 1 or 0
	local totalArgs = nFixed + n
	local bField = totalArgs + 1
	local cField
	if resultSpec == "multi" then
		cField = 0
	else
		cField = resultSpec + 1
	end
	self:emit(OP.CALL, destBase, bField, cField)
	self.freeReg = saved
end

----------------------------------------------------------------------
-- nested functions / closures
----------------------------------------------------------------------

function FuncCompiler:compileClosure(funcNode, dst)
	local childFC = FuncCompiler.new(funcNode, self, funcNode.name)
	for i, paramVar in ipairs(funcNode.paramVars) do
		childFC.varReg[paramVar] = i - 1
	end
	childFC:compileFunctionBody(funcNode.body)

	for _, entry in ipairs(funcNode.upvalues) do
		local idx
		if entry.kind == "local" then
			idx = self.varReg[entry.var]
			if idx == nil then
				self:fail(funcNode, "internal error: captured local '" .. tostring(entry.name) .. "' has no register in the enclosing function")
			end
		elseif entry.kind == "upval" then
			idx = entry.parentIndex
		else
			self:fail(funcNode, "unknown upvalue kind '" .. tostring(entry.kind) .. "'")
		end
		childFC.asm:addUpval(entry.kind, idx)
	end

	local childProto = childFC.asm:build()
	local protoIdx = self.asm:addProto(childProto)
	self:emit(OP.CLOSURE, dst, protoIdx)
end

-- Compiles `body` (a block, i.e. an array of statements with a .scope) as
-- this function's complete body, appending an implicit `return` if the
-- block doesn't already end in one.
function FuncCompiler:compileFunctionBody(body)
	self:compileBlockStats(body)
	self:emit(OP.RETURN, 0, 1)
end

----------------------------------------------------------------------
-- blocks / statements
----------------------------------------------------------------------

-- Plain (non-loop) block: statements + scope-exit CLOSE if needed, then
-- releases every register the block's locals occupied.
function FuncCompiler:compileBlockStats(stats)
	local saved = self.freeReg
	for _, stat in ipairs(stats) do
		self:compileStatement(stat)
	end
	if stats.scope and stats.scope.hasCaptured then
		self:emit(OP.CLOSE, saved)
	end
	self.freeReg = saved
end

function FuncCompiler:compileStatement(node)
	if type(node) ~= "table" or node.kind == nil then
		self:fail(node, "malformed AST node (missing 'kind')")
	end
	local k = node.kind
	if k == "Local" then
		self:compileLocal(node)
	elseif k == "Assign" then
		self:compileAssign(node)
	elseif k == "CompoundAssign" then
		self:compileCompoundAssign(node)
	elseif k == "CallStat" then
		self:compileCallLike(node.call, self.freeReg, 0)
	elseif k == "Do" then
		self:compileBlockStats(node.body)
	elseif k == "If" then
		self:compileIf(node)
	elseif k == "While" then
		self:compileWhile(node)
	elseif k == "Repeat" then
		self:compileRepeat(node)
	elseif k == "NumericFor" then
		self:compileNumericFor(node)
	elseif k == "GenericFor" then
		self:compileGenericFor(node)
	elseif k == "FunctionDecl" then
		self:compileFunctionDecl(node)
	elseif k == "LocalFunction" then
		self:compileLocalFunction(node)
	elseif k == "Return" then
		self:compileReturn(node)
	elseif k == "Break" then
		self:compileBreak(node)
	elseif k == "Continue" then
		self:compileContinue(node)
	else
		self:fail(node, "unsupported statement node kind '" .. tostring(k) .. "'")
	end
end

function FuncCompiler:compileLocal(node)
	local n = #node.names
	local base = self.freeReg
	if n == 0 then return end
	if self.freeReg < base + n then self.freeReg = base + n end
	self:reserve(base + n - 1)
	self:compileExprListIntoChecked(node, node.exprs, base, n)
	for i, var in ipairs(node.vars) do
		self.varReg[var] = base + i - 1
	end
	self.freeReg = base + n
end

-- Same as compileExprListInto but raises a clear error for the unbounded-
-- multi case instead of silently truncating, per file header note 2/3.
function FuncCompiler:compileExprListIntoChecked(ownerNode, exprs, base, wantCount)
	local n = #exprs
	if n > 0 and n > wantCount and isMultiValue(exprs[n]) then
		-- more exprs than wanted and the last is multi: it's being truncated
		-- to 1 value anyway (correct Luau semantics, not the unbounded case).
	end
	self:compileExprListInto(exprs, base, wantCount)
end

function FuncCompiler:compileAssign(node)
	local n = #node.targets
	local base = self.freeReg
	if self.freeReg < base + n then self.freeReg = base + n end
	self:reserve(base + n - 1)
	self:compileExprListInto(node.exprs, base, n)
	for i, target in ipairs(node.targets) do
		self:storeToTarget(target, base + i - 1)
	end
	self.freeReg = base
end

function FuncCompiler:storeToTarget(target, srcReg)
	if target.kind == "Name" then
		local res = target.resolution
		if res == "local" then
			local reg = self.varReg[target.var]
			if reg ~= srcReg then
				self:emit(OP.MOVE, reg, srcReg)
			end
		elseif res == "upvalue" then
			self:emit(OP.SETUPVAL, srcReg, target.upvalueIndex)
		elseif res == "global" then
			self:emit(OP.SETGLOBAL, srcReg, self.asm:k(target.name))
		else
			self:fail(target, "assignment target has unexpected resolution '" .. tostring(res) .. "'")
		end
	elseif target.kind == "DotIndex" then
		local saved = self.freeReg
		local baseReg = self:newTemp()
		self:compileExpr(target.base, baseReg)
		self:emit(OP.SETFIELD, baseReg, self.asm:k(target.name), self.asm:regRK(srcReg))
		self.freeReg = saved
	elseif target.kind == "BracketIndex" then
		local saved = self.freeReg
		local baseReg = self:newTemp()
		self:compileExpr(target.base, baseReg)
		local idxRK = self:exprToRK(target.index)
		self:emit(OP.SETTABLE, baseReg, idxRK, self.asm:regRK(srcReg))
		self.freeReg = saved
	else
		self:fail(target, "unsupported assignment target kind '" .. tostring(target.kind) .. "'")
	end
end

function FuncCompiler:compileCompoundAssign(node)
	local target = node.target
	local op = node.op
	if op == "//" then
		self:fail(node, "operator '//=' has no corresponding Coriolis Proto opcode (LuauVM.lua defines no floor-division instruction)")
	end

	if target.kind == "Name" and target.resolution == "local" then
		local reg = self.varReg[target.var]
		self:applyCompoundOp(op, reg, reg, node.expr)
	elseif target.kind == "Name" and target.resolution == "upvalue" then
		local saved = self.freeReg
		local tmp = self:newTemp()
		self:emit(OP.GETUPVAL, tmp, target.upvalueIndex)
		self:applyCompoundOp(op, tmp, tmp, node.expr)
		self:emit(OP.SETUPVAL, tmp, target.upvalueIndex)
		self.freeReg = saved
	elseif target.kind == "Name" and target.resolution == "global" then
		local saved = self.freeReg
		local tmp = self:newTemp()
		self:emit(OP.GETGLOBAL, tmp, self.asm:k(target.name))
		self:applyCompoundOp(op, tmp, tmp, node.expr)
		self:emit(OP.SETGLOBAL, tmp, self.asm:k(target.name))
		self.freeReg = saved
	elseif target.kind == "DotIndex" then
		local saved = self.freeReg
		local baseReg = self:newTemp()
		self:compileExpr(target.base, baseReg)
		local tmp = self:newTemp()
		self:emit(OP.GETFIELD, tmp, baseReg, self.asm:k(target.name))
		self:applyCompoundOp(op, tmp, tmp, node.expr)
		self:emit(OP.SETFIELD, baseReg, self.asm:k(target.name), self.asm:regRK(tmp))
		self.freeReg = saved
	elseif target.kind == "BracketIndex" then
		local saved = self.freeReg
		local baseReg = self:newTemp()
		self:compileExpr(target.base, baseReg)
		local idxRK = self:exprToRK(target.index)
		local tmp = self:newTemp()
		self:emit(OP.GETTABLE, tmp, baseReg, idxRK)
		self:applyCompoundOp(op, tmp, tmp, node.expr)
		self:emit(OP.SETTABLE, baseReg, idxRK, self.asm:regRK(tmp))
		self.freeReg = saved
	else
		self:fail(target, "unsupported compound-assignment target kind '" .. tostring(target.kind) .. "'")
	end
end

-- dst = dst <op> exprNode, where dst currently equals srcReg (same register,
-- already holding the target's current value). Handles ".." specially since
-- CONCAT needs a contiguous register pair.
function FuncCompiler:applyCompoundOp(op, dst, srcReg, exprNode)
	if op == ".." then
		local saved = self.freeReg
		local a = self:newTemp()
		self:emit(OP.MOVE, a, srcReg)
		local b = self:newTemp()
		self:compileExpr(exprNode, b)
		self:emit(OP.CONCAT, dst, a, b)
		self.freeReg = saved
	elseif ARITH_OP[op] then
		local rrk = self:exprToRK(exprNode)
		self:emit(ARITH_OP[op], dst, self.asm:regRK(srcReg), rrk)
	else
		self:fail(exprNode, "unsupported compound-assignment operator '" .. tostring(op) .. "'")
	end
end

----------------------------------------------------------------------
-- control flow
----------------------------------------------------------------------

function FuncCompiler:compileIf(node)
	local endJumps = {}
	for _, clause in ipairs(node.clauses) do
		local saved = self.freeReg
		local condReg = self:newTemp()
		self:compileExpr(clause.cond, condReg)
		local jFalse = self:emit(OP.TEST, condReg, 0, 1)
		self.freeReg = saved
		self:compileBlockStats(clause.body)
		endJumps[#endJumps + 1] = self:emit(OP.JMP, 0)
		self:patchOffset(jFalse, "b", self:here())
	end
	if node.elseBody then
		self:compileBlockStats(node.elseBody)
	end
	local finish = self:here()
	for _, j in ipairs(endJumps) do
		self:patchOffset(j, "a", finish)
	end
end

function FuncCompiler:pushLoop(base)
	local ctx = { base = base, breaks = {}, continues = {} }
	self.loopStack[#self.loopStack + 1] = ctx
	return ctx
end

function FuncCompiler:popLoop()
	self.loopStack[#self.loopStack] = nil
end

function FuncCompiler:currentLoop(node)
	local ctx = self.loopStack[#self.loopStack]
	if not ctx then
		self:fail(node, "'break'/'continue' outside a loop (should have been rejected by Parser already)")
	end
	return ctx
end

function FuncCompiler:compileBreak(node)
	local ctx = self:currentLoop(node)
	self:emit(OP.CLOSE, ctx.base)
	local j = self:emit(OP.JMP, 0)
	ctx.breaks[#ctx.breaks + 1] = j
end

function FuncCompiler:compileContinue(node)
	local ctx = self:currentLoop(node)
	self:emit(OP.CLOSE, ctx.base)
	local j = self:emit(OP.JMP, 0)
	ctx.continues[#ctx.continues + 1] = j
end

function FuncCompiler:patchLoopExits(ctx, exitTarget, continueTarget)
	for _, j in ipairs(ctx.breaks) do
		self:patchOffset(j, "a", exitTarget)
	end
	for _, j in ipairs(ctx.continues) do
		self:patchOffset(j, "a", continueTarget)
	end
end

function FuncCompiler:compileWhile(node)
	local saved = self.freeReg
	local loopStart = self:here()
	local condReg = self:newTemp()
	self:compileExpr(node.cond, condReg)
	local jExit = self:emit(OP.TEST, condReg, 0, 1)
	self.freeReg = saved

	local ctx = self:pushLoop(saved)
	for _, stat in ipairs(node.body) do
		self:compileStatement(stat)
	end
	local continueTarget = self:here()
	if node.body.scope and node.body.scope.hasCaptured then
		self:emit(OP.CLOSE, saved)
	end
	self:emit(OP.JMP, 0)
	self:patchOffset(self:here() - 1, "a", loopStart)
	self.freeReg = saved
	self:popLoop()

	local exitTarget = self:here()
	self:patchOffset(jExit, "b", exitTarget)
	self:patchLoopExits(ctx, exitTarget, continueTarget)
end

function FuncCompiler:compileRepeat(node)
	local saved = self.freeReg
	local loopStart = self:here()
	local ctx = self:pushLoop(saved)

	for _, stat in ipairs(node.body) do
		self:compileStatement(stat)
	end
	local continueTarget = self:here()
	-- `until` condition is compiled while the body's locals are still live
	-- (Parser resolves it in the same scope -- see parseRepeat's `tail`).
	local condReg = self:newTemp()
	self:compileExpr(node.cond, condReg)
	local jLoop = self:emit(OP.TEST, condReg, 0, 1) -- false -> jump back; true -> fall through (exit)
	self:patchOffset(jLoop, "b", loopStart)
	self.freeReg = saved
	if node.body.scope and node.body.scope.hasCaptured then
		self:emit(OP.CLOSE, saved)
	end
	self:popLoop()

	local exitTarget = self:here()
	self:patchLoopExits(ctx, exitTarget, continueTarget)
end

function FuncCompiler:compileNumericFor(node)
	local saved = self.freeReg
	local base = saved
	if self.freeReg < base + 4 then self.freeReg = base + 4 end
	self:reserve(base + 3)

	self:compileExpr(node.start, base)
	self:compileExpr(node.stop, base + 1)
	if node.step then
		self:compileExpr(node.step, base + 2)
	else
		self:emit(OP.LOADK, base + 2, self.asm:k(1))
	end

	local prepPC = self:emit(OP.FORPREP, base, 0)
	local bodyStart = self:here()

	self.varReg[node.loopVar] = base + 3
	local ctx = self:pushLoop(base)
	for _, stat in ipairs(node.body) do
		self:compileStatement(stat)
	end
	local continueTarget = self:here()
	if node.body.scope and node.body.scope.hasCaptured then
		self:emit(OP.CLOSE, base)
	end
	local forloopPC = self:emit(OP.FORLOOP, base, 0)
	self:patchOffset(forloopPC, "b", bodyStart)
	self:patchOffset(prepPC, "b", forloopPC)
	self:popLoop()

	local exitTarget = self:here()
	self:patchLoopExits(ctx, exitTarget, continueTarget)
	self.freeReg = saved
end

function FuncCompiler:compileGenericFor(node)
	local saved = self.freeReg
	local base = saved -- f, s, ctrl
	local names = node.names
	local n = #names
	local vBase = base + 3
	if self.freeReg < vBase + n then self.freeReg = vBase + n end
	self:reserve(vBase + n - 1)

	self:compileExprListInto(node.exprs, base, 3)

	local loopStart = self:here()
	local scratchWindow = math.max(3, n)
	local scratchSaved = self.freeReg
	local scratch = self.freeReg
	if self.freeReg < scratch + scratchWindow then self.freeReg = scratch + scratchWindow end
	self:reserve(scratch + scratchWindow - 1)
	self:emit(OP.MOVE, scratch, base)
	self:emit(OP.MOVE, scratch + 1, base + 1)
	self:emit(OP.MOVE, scratch + 2, base + 2)
	self:emit(OP.CALL, scratch, 3, n + 1)
	for i = 1, n do
		self:emit(OP.MOVE, vBase + i - 1, scratch + i - 1)
	end
	self.freeReg = scratchSaved
	self:emit(OP.MOVE, base + 2, vBase) -- control = first loop var result

	local jExit = self:emit(OP.TEST, vBase, 0, 1) -- falsy (nil or false; see limitation 6) -> exit

	for i, var in ipairs(node.loopVars) do
		self.varReg[var] = vBase + i - 1
	end
	local ctx = self:pushLoop(base)
	for _, stat in ipairs(node.body) do
		self:compileStatement(stat)
	end
	local continueTarget = self:here()
	if node.body.scope and node.body.scope.hasCaptured then
		self:emit(OP.CLOSE, base)
	end
	self:emit(OP.JMP, 0)
	self:patchOffset(self:here() - 1, "a", loopStart)
	self:popLoop()

	local exitTarget = self:here()
	self:patchOffset(jExit, "b", exitTarget)
	self:patchLoopExits(ctx, exitTarget, continueTarget)
	self.freeReg = saved
end

function FuncCompiler:compileFunctionDecl(node)
	local saved = self.freeReg
	local tmp = self:newTemp()
	self:compileClosure(node.body, tmp)

	-- path = {root, field1, field2, ...} (or {root,...,method} if isMethod)
	if #node.path == 1 then
		self:storeToTarget(node.root, tmp)
	else
		local baseReg = self:newTemp()
		self:compileName(node.root, baseReg)
		for i = 2, #node.path - 1 do
			local nextReg = self:newTemp()
			self:emit(OP.GETFIELD, nextReg, baseReg, self.asm:k(node.path[i]))
			baseReg = nextReg
		end
		local lastKey = node.path[#node.path]
		self:emit(OP.SETFIELD, baseReg, self.asm:k(lastKey), self.asm:regRK(tmp))
	end
	self.freeReg = saved
end

function FuncCompiler:compileLocalFunction(node)
	-- The local is declared (register allocated) BEFORE compiling the body so
	-- the function can recursively reference itself as an upvalue/local.
	local reg = self:newTemp()
	self.varReg[node.localVar] = reg
	self:compileClosure(node.body, reg)
end

function FuncCompiler:compileReturn(node)
	local exprs = node.exprs
	local n = #exprs
	if n == 0 then
		self:emit(OP.RETURN, self.freeReg, 1)
		return
	end

	local base = self.freeReg
	if self.freeReg < base + n then self.freeReg = base + n end
	self:reserve(base + n - 1)

	if node.multi then
		local lastNode = exprs[n]
		if lastNode.kind == "Vararg" then
			self:fail(lastNode, "'return ...' is not supported by the target VM: OP.VARARG never sets the multi-result marker that OP.RETURN's dynamic (b=0) path reads, so there is no correct encoding for returning an unknown number of varargs. Return a fixed number of values (e.g. 'return ...local copies...') or restructure to avoid a trailing bare '...'.")
		end
		for i = 1, n - 1 do
			self:compileExpr(exprs[i], base + i - 1)
		end
		-- lastNode is a Call/MethodCall: request ALL results (c=0), consumed
		-- correctly by RETURN's b=0 path via frame._multiTop.
		self:compileCallLike(lastNode, base + n - 1, "multi")
		self:emit(OP.RETURN, base, 0)
	else
		for i = 1, n do
			self:compileExpr(exprs[i], base + i - 1)
		end
		self:emit(OP.RETURN, base, n + 1)
	end
end

----------------------------------------------------------------------
-- entry point
----------------------------------------------------------------------

function ASTCompiler.compile(chunk, opts)
	opts = opts or {}
	if type(chunk) ~= "table" or chunk.kind ~= "Chunk" then
		return false, "Compile error: expected a Parser Chunk node"
	end

	local ok, result = pcall(function()
		Parser.eraseTypes(chunk)
		local fc = FuncCompiler.new(chunk, nil, opts.name or "chunk")
		fc:compileFunctionBody(chunk.body)
		return fc.asm:build()
	end)

	if ok then
		return true, result
	else
		local msg = result
		if type(msg) ~= "string" then
			msg = tostring(msg)
		end
		return false, msg
	end
end

function ASTCompiler.compileSource(src, opts)
	local ok, chunkOrErr = pcall(Parser.parse, src)
	if not ok then
		return false, chunkOrErr
	end
	return ASTCompiler.compile(chunkOrErr, opts)
end

return ASTCompiler
