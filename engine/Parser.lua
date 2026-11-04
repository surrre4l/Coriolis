--!nonstrict
--[[
	Parser.lua
	Recursive-descent parser for Luau source producing an AST for the LuauVM code generator.
	Pairs with Lexer.lua. It does not compile; it resolves scopes so a code generator does not
	have to.

	Every node: { kind, line, col, endLine, endCol } (end is exclusive).

	Runtime nodes
	  Chunk{body, isVararg=true, params={}, paramVars={}, numparams=0, upvalues}
	  Statements: Local{names, vars, attribs={}, types, exprs, multi}, Assign{targets, exprs, multi},
	    CompoundAssign{target, op, expr}, CallStat{call}, Do{body}, If{clauses={{cond,body}}, elseBody},
	    While{cond, body}, Repeat{body, cond}, NumericFor{var, loopVar, start, stop, step, body},
	    GenericFor{names, loopVars, exprs, body, multi}, FunctionDecl{path, isMethod, root, body},
	    LocalFunction{name, localVar, body}, Return{exprs, multi}, Break, Continue
	  Expressions: Nil, True, False, Number{value,raw}, String{value}, InterpString{strings, exprs},
	    Vararg, Name, DotIndex{base,name}, BracketIndex{base,index}, Call{base,args,multi},
	    MethodCall{base,method,args,multi}, Function, Table{fields, arrayCount, multi},
	    Unop{op,expr}, Binop{op,lhs,rhs}, IfExpr{clauses={{cond,expr}}, elseExpr}, Paren{expr}
	Type-only nodes (never emit code): TypeAlias (statement), TypeAssert{expr,typ} (evaluates to
	  `expr`, truncated to ONE value), and everything in the type fields: Local.types,
	  Function.generics/genericInfo/paramTypes/varargType/returnType, GenericFor.types, NumericFor.varType.
	  Parser.eraseTypes(chunk) strips all of them in place.

	Scope information
	  Var{name, id, declKind="local"|"param"|"self"|"for"|"function", level, captured, assigned, line, col}
	    `level` is the function nesting depth (1 = chunk). `captured` is true when a nested function
	    references it (the code generator needs CLOSE for such locals). `assigned` is true when it is
	    written after its declaration.
	  Name{name, resolution="local"|"upvalue"|"global"|"type", var, upvalueIndex}
	    "type" is a reference inside typeof(...) in a type annotation; it creates no capture.
	    upvalueIndex is 0-based into the enclosing Function.upvalues (matches OP.GETUPVAL/SETUPVAL).
	  Function.upvalues[i] = { name, var, kind="local"|"upval", index, parentIndex }
	    kind "local": captures `var` from the immediately enclosing function (register known to the
	    code generator); kind "upval": passes through the enclosing function's upvalue `parentIndex`
	    (0-based). `index` is this entry's own 0-based position. Maps onto Assembler:addUpval(kind, ...).
	  Every block array (a `body`) carries `.scope = { vars = {Var...}, hasCaptured }` listing the
	  locals declared directly in it (parameters and loop variables come first). hasCaptured tells
	  the code generator whether to emit CLOSE when the block (or a loop iteration) ends.

	`multi` flags: the last expression of the list is an unparenthesised call or `...`, so it expands
	to all of its values (CALL c=0 / VARARG b=0). Parser.isMultiValue(node) tests one node.

	Errors are raised as strings: "Parse error at line L col C (near <token>): message".
]]

local Lexer = require(script.Parent.Lexer)

local Parser = {}
Parser.__index = Parser

local MAX_DEPTH = 500

local BINOP_PRIORITY = {
	["or"] = { 1, 1 }, ["and"] = { 2, 2 },
	["=="] = { 3, 3 }, ["~="] = { 3, 3 },
	["<"] = { 3, 3 }, ["<="] = { 3, 3 }, [">"] = { 3, 3 }, [">="] = { 3, 3 },
	[".."] = { 9, 8 },
	["+"] = { 10, 10 }, ["-"] = { 10, 10 },
	["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
	["^"] = { 14, 13 },
}
local UNARY_PRIORITY = 12
local COMPOUND_OPS = {
	["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/",
	["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = "..",
}
local BLOCK_END_KEYWORDS = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true }
local KNOWN_ATTRIBUTES = { native = true, checked = true, deprecated = true }
local NOT_CONTINUE_FOLLOWERS = {
	["="] = true, [","] = true, ["."] = true, [":"] = true, ["["] = true, ["("] = true, ["{"] = true,
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function describe(t)
	if t.type == "Eof" then return "<eof>" end
	if t.type == "Name" then return "name '" .. t.value .. "'" end
	if t.type == "Keyword" or t.type == "Symbol" then return "'" .. t.value .. "'" end
	if t.type == "Number" then return "number " .. (t.raw or tostring(t.value)) end
	if t.type == "String" then
		local s = (string.gsub(t.value, "\n", "\\n"))
		if #s > 20 then s = string.sub(s, 1, 17) .. "..." end
		return 'string "' .. s .. '"'
	end
	if t.type == "InterpString" then return "interpolated string" end
	return tostring(t.type)
end

local function isMultiValue(node)
	local k = node.kind
	return k == "Call" or k == "MethodCall" or k == "Vararg"
end
Parser.isMultiValue = isMultiValue

local function lastMulti(list)
	return #list > 0 and isMultiValue(list[#list]) or false
end

local function isPackish(node)
	return node.kind == "TupleType" or node.kind == "GenericPackType"
end

----------------------------------------------------------------------
-- Construction / token helpers
----------------------------------------------------------------------

function Parser.new(tokens)
	local self = setmetatable({}, Parser)
	self.tokens = tokens
	self.pos = 1
	self.prev = nil
	self.depth = 0
	self.funcs = {}
	self.scope = nil
	self.varCounter = 0
	self.typeofDepth = 0
	return self
end

function Parser.fromSource(src)
	return Parser.new(Lexer.tokenize(src))
end

function Parser.parse(src)
	return Parser.fromSource(src):parseChunk()
end

function Parser:cur()
	return self.tokens[self.pos]
end

function Parser:peek(n)
	local i = self.pos + (n or 1)
	if i > #self.tokens then i = #self.tokens end
	return self.tokens[i]
end

function Parser:advance()
	local t = self.tokens[self.pos]
	if self.pos < #self.tokens then self.pos = self.pos + 1 end
	self.prev = t
	return t
end

function Parser:isKeyword(w)
	local t = self.tokens[self.pos]
	return t.type == "Keyword" and t.value == w
end

function Parser:isSymbol(s)
	local t = self.tokens[self.pos]
	return t.type == "Symbol" and t.value == s
end

function Parser:error(msg, tok)
	local t = tok or self:cur()
	error(("Parse error at line %d col %d (near %s): %s"):format(t.line, t.col, describe(t), msg), 0)
end

function Parser:errorAtNode(node, msg)
	error(("Parse error at line %d col %d: %s"):format(node.line, node.col, msg), 0)
end

function Parser:expectKeyword(w)
	if not self:isKeyword(w) then
		self:error("expected '" .. w .. "'")
	end
	return self:advance()
end

function Parser:expectSymbol(s)
	if not self:isSymbol(s) then
		self:error("expected '" .. s .. "'")
	end
	return self:advance()
end

function Parser:expectMatch(word, openerWord, openerTok)
	if self:isKeyword(word) then return self:advance() end
	self:error(("expected '%s' (to close '%s' at line %d)"):format(word, openerWord, openerTok.line))
end

function Parser:expectSymbolMatch(sym, openerSym, openerTok)
	if self:isSymbol(sym) then return self:advance() end
	self:error(("expected '%s' (to close '%s' at line %d)"):format(sym, openerSym, openerTok.line))
end

function Parser:expectName(what)
	local t = self:cur()
	if t.type ~= "Name" then
		self:error("expected " .. (what or "a name"))
	end
	self:advance()
	return t.value
end

function Parser:enter()
	self.depth = self.depth + 1
	if self.depth > MAX_DEPTH then
		self:error("exceeded allowed recursion depth (" .. MAX_DEPTH .. ")")
	end
end

function Parser:leave()
	self.depth = self.depth - 1
end

-- Sets start from a token and end from the last consumed token.
function Parser:finish(node, startTok)
	node.line, node.col = startTok.line, startTok.col
	local p = self.prev
	node.endLine, node.endCol = p.endLine, p.endCol
	return node
end

-- Same, with the start taken from an existing node.
function Parser:finishFrom(node, first)
	node.line, node.col = first.line, first.col
	local p = self.prev
	node.endLine, node.endCol = p.endLine, p.endCol
	return node
end

----------------------------------------------------------------------
-- Scopes, variables, upvalues
----------------------------------------------------------------------

function Parser:pushFunction(node, isVararg)
	local fs = { node = node, upvalMap = {}, loopDepth = 0, isVararg = isVararg }
	self.funcs[#self.funcs + 1] = fs
	return fs
end

function Parser:popFunction()
	self.funcs[#self.funcs] = nil
end

function Parser:curFunc()
	return self.funcs[#self.funcs]
end

function Parser:pushScope()
	local s = { info = { vars = {}, hasCaptured = false }, map = {}, parent = self.scope }
	self.scope = s
	return s
end

function Parser:popScope()
	local s = self.scope
	for _, v in ipairs(s.info.vars) do
		if v.captured then s.info.hasCaptured = true end
	end
	self.scope = s.parent
	return s.info
end

function Parser:declare(name, tok, declKind)
	self.varCounter = self.varCounter + 1
	local v = {
		name = name, id = self.varCounter, declKind = declKind, level = #self.funcs,
		captured = false, assigned = false, line = tok.line, col = tok.col,
	}
	local s = self.scope
	s.map[name] = v
	s.info.vars[#s.info.vars + 1] = v
	return v
end

-- Index (0-based) of `var` in the upvalue list of the function at `level`, creating the
-- capture chain through every intermediate function as needed.
function Parser:upvalueFor(level, var)
	local fs = self.funcs[level]
	local existing = fs.upvalMap[var]
	if existing ~= nil then return existing end
	local list = fs.node.upvalues
	local entry = { name = var.name, var = var, index = #list }
	if var.level == level - 1 then
		entry.kind = "local"
	else
		entry.kind = "upval"
		entry.parentIndex = self:upvalueFor(level - 1, var)
	end
	list[#list + 1] = entry
	fs.upvalMap[var] = entry.index
	return entry.index
end

function Parser:resolve(name)
	local var
	local s = self.scope
	while s do
		var = s.map[name]
		if var then break end
		s = s.parent
	end
	local node = { kind = "Name", name = name }
	if not var then
		node.resolution = "global"
		return node
	end
	node.var = var
	if self.typeofDepth > 0 then
		node.resolution = "type"
		return node
	end
	local level = #self.funcs
	if var.level == level then
		node.resolution = "local"
	else
		node.resolution = "upvalue"
		var.captured = true
		node.upvalueIndex = self:upvalueFor(level, var)
	end
	return node
end

----------------------------------------------------------------------
-- Entry point / blocks
----------------------------------------------------------------------

function Parser:parseChunk()
	local node = {
		kind = "Chunk", isVararg = true, params = {}, paramVars = {}, numparams = 0, upvalues = {},
	}
	self:pushFunction(node, true)
	local body = self:parseBlock()
	local t = self:cur()
	if t.type ~= "Eof" then
		if t.type == "Keyword" and BLOCK_END_KEYWORDS[t.value] then
			self:error("unexpected '" .. t.value .. "' (no open block to close)")
		end
		self:error("unexpected token after end of chunk")
	end
	self:popFunction()
	node.body = body
	node.line, node.col = 1, 1
	node.endLine, node.endCol = t.endLine, t.endCol
	return node
end

-- `setup` runs inside the new scope before any statement (declare params/loop vars there);
-- `tail` runs after the last statement, still inside the scope (repeat's `until` condition).
function Parser:parseBlock(setup, tail)
	self:enter()
	self:pushScope()
	if setup then setup() end
	local stats = {}
	while true do
		local t = self:cur()
		if t.type == "Eof" then break end
		if t.type == "Keyword" and BLOCK_END_KEYWORDS[t.value] then break end
		if self:isKeyword("return") then
			stats[#stats + 1] = self:parseReturn()
			local n = self:cur()
			if not (n.type == "Eof" or (n.type == "Keyword" and BLOCK_END_KEYWORDS[n.value])) then
				self:error("'return' must be the last statement in a block")
			end
			break
		end
		local stat = self:parseStatement()
		if stat ~= nil then stats[#stats + 1] = stat end
	end
	if tail then tail() end
	stats.scope = self:popScope()
	self:leave()
	return stats
end

function Parser:parseLoopBody(setup, tail)
	local fs = self:curFunc()
	fs.loopDepth = fs.loopDepth + 1
	local body = self:parseBlock(setup, tail)
	fs.loopDepth = fs.loopDepth - 1
	return body
end

----------------------------------------------------------------------
-- Statements
----------------------------------------------------------------------

function Parser:parseAttributes()
	local first = self:cur()
	local attrs = {}
	while self:isSymbol("@") do
		self:advance()
		local function one()
			local tok = self:cur()
			local name = self:expectName("an attribute name")
			if not KNOWN_ATTRIBUTES[name] then
				self:error("unknown attribute '@" .. name .. "'", tok)
			end
			attrs[#attrs + 1] = name
		end
		if self:isSymbol("[") then
			self:advance()
			one()
			while self:isSymbol(",") do self:advance(); one() end
			self:expectSymbol("]")
		else
			one()
		end
	end
	return attrs, first
end

function Parser:isContinueStatement()
	local n = self:peek()
	if n.type == "String" or n.type == "InterpString" then return false end
	if n.type == "Symbol" and (NOT_CONTINUE_FOLLOWERS[n.value] or COMPOUND_OPS[n.value]) then
		return false
	end
	return true
end

function Parser:parseStatement()
	local t = self:cur()
	if t.type == "Symbol" then
		if t.value == ";" then
			self:advance()
			return nil
		elseif t.value == "@" then
			local attrs, atTok = self:parseAttributes()
			if self:isKeyword("function") then
				return self:parseFunctionStat(atTok, attrs)
			elseif self:isKeyword("local") and self:peek().type == "Keyword" and self:peek().value == "function" then
				return self:parseLocal(atTok, attrs)
			end
			self:error("expected 'function' after attributes")
		end
	elseif t.type == "Keyword" then
		local v = t.value
		if v == "if" then return self:parseIf()
		elseif v == "while" then return self:parseWhile()
		elseif v == "do" then
			self:advance()
			local body = self:parseBlock()
			self:expectMatch("end", "do", t)
			return self:finish({ kind = "Do", body = body }, t)
		elseif v == "for" then return self:parseFor()
		elseif v == "repeat" then return self:parseRepeat()
		elseif v == "function" then return self:parseFunctionStat(t, nil)
		elseif v == "local" then return self:parseLocal(t, nil)
		elseif v == "break" then
			if self:curFunc().loopDepth == 0 then
				self:error("'break' must be inside a loop")
			end
			self:advance()
			return self:finish({ kind = "Break" }, t)
		end
	elseif t.type == "Name" then
		if t.value == "type" then
			local n = self:peek()
			if n.type == "Name" then
				return self:parseTypeAlias(false, t)
			elseif n.type == "Keyword" and n.value == "function" then
				self:error("type functions are not supported")
			end
		elseif t.value == "export" then
			local n = self:peek()
			if n.type == "Name" and n.value == "type" then
				local after = self:peek(2)
				if after.type == "Keyword" and after.value == "function" then
					self:error("type functions are not supported", after)
				end
				self:advance()
				return self:parseTypeAlias(true, t)
			end
		elseif t.value == "continue" and self:isContinueStatement() then
			if self:curFunc().loopDepth == 0 then
				self:error("'continue' must be inside a loop")
			end
			self:advance()
			return self:finish({ kind = "Continue" }, t)
		end
	end
	return self:parseExprStatement()
end

function Parser:parseReturn()
	local startTok = self:expectKeyword("return")
	local exprs = {}
	local t = self:cur()
	local atEnd = t.type == "Eof" or self:isSymbol(";")
		or (t.type == "Keyword" and BLOCK_END_KEYWORDS[t.value])
	if not atEnd then
		exprs = self:parseExprList()
	end
	if self:isSymbol(";") then self:advance() end
	return self:finish({ kind = "Return", exprs = exprs, multi = lastMulti(exprs) }, startTok)
end

function Parser:parseIf()
	local startTok = self:expectKeyword("if")
	local clauses = {}
	local cond = self:parseExpr()
	self:expectKeyword("then")
	clauses[1] = { cond = cond, body = self:parseBlock() }
	while self:isKeyword("elseif") do
		self:advance()
		local c = self:parseExpr()
		self:expectKeyword("then")
		clauses[#clauses + 1] = { cond = c, body = self:parseBlock() }
	end
	local elseBody = nil
	if self:isKeyword("else") then
		self:advance()
		elseBody = self:parseBlock()
	end
	self:expectMatch("end", "if", startTok)
	return self:finish({ kind = "If", clauses = clauses, elseBody = elseBody }, startTok)
end

function Parser:parseWhile()
	local startTok = self:expectKeyword("while")
	local cond = self:parseExpr()
	self:expectKeyword("do")
	local body = self:parseLoopBody()
	self:expectMatch("end", "while", startTok)
	return self:finish({ kind = "While", cond = cond, body = body }, startTok)
end

function Parser:parseRepeat()
	local startTok = self:expectKeyword("repeat")
	local cond
	local body = self:parseLoopBody(nil, function()
		self:expectMatch("until", "repeat", startTok)
		cond = self:parseExpr()
	end)
	return self:finish({ kind = "Repeat", body = body, cond = cond }, startTok)
end

function Parser:parseFor()
	local startTok = self:expectKeyword("for")
	local nameToks = { self:cur() }
	local names = { self:expectName("a loop variable name") }
	local types = {}
	if self:isSymbol(":") then
		self:advance()
		types[1] = self:parseType()
	end

	if self:isSymbol("=") then
		self:advance()
		local startExpr = self:parseExpr()
		self:expectSymbol(",")
		local stopExpr = self:parseExpr()
		local stepExpr = nil
		if self:isSymbol(",") then
			self:advance()
			stepExpr = self:parseExpr()
		end
		self:expectKeyword("do")
		local loopVar
		local body = self:parseLoopBody(function()
			loopVar = self:declare(names[1], nameToks[1], "for")
		end)
		self:expectMatch("end", "for", startTok)
		return self:finish({
			kind = "NumericFor", var = names[1], varType = types[1], loopVar = loopVar,
			start = startExpr, stop = stopExpr, step = stepExpr, body = body,
		}, startTok)
	end

	while self:isSymbol(",") do
		self:advance()
		nameToks[#nameToks + 1] = self:cur()
		names[#names + 1] = self:expectName("a loop variable name")
		if self:isSymbol(":") then
			self:advance()
			types[#names] = self:parseType()
		end
	end
	if not self:isKeyword("in") then
		self:error("expected '=' or 'in' after for-loop variable")
	end
	self:advance()
	local exprs = self:parseExprList()
	self:expectKeyword("do")
	local loopVars = {}
	local body = self:parseLoopBody(function()
		for i, n in ipairs(names) do
			loopVars[i] = self:declare(n, nameToks[i], "for")
		end
	end)
	self:expectMatch("end", "for", startTok)
	return self:finish({
		kind = "GenericFor", names = names, types = types, loopVars = loopVars,
		exprs = exprs, multi = lastMulti(exprs), body = body,
	}, startTok)
end

function Parser:parseFunctionStat(startTok, attrs)
	local fnTok = self:expectKeyword("function")
	local rootTok = self:cur()
	local rootName = self:expectName("a function name")
	local root = self:finish(self:resolve(rootName), rootTok)
	local path = { rootName }
	local isMethod = false
	while self:isSymbol(".") do
		self:advance()
		path[#path + 1] = self:expectName("a field name")
	end
	if self:isSymbol(":") then
		self:advance()
		path[#path + 1] = self:expectName("a method name")
		isMethod = true
	end
	if #path == 1 and root.var then root.var.assigned = true end
	local display
	if isMethod then
		display = table.concat(path, ".", 1, #path - 1) .. ":" .. path[#path]
	else
		display = table.concat(path, ".")
	end
	local body = self:parseFunctionBody(isMethod, fnTok, display, attrs)
	return self:finish({
		kind = "FunctionDecl", path = path, isMethod = isMethod, root = root, body = body,
	}, startTok)
end

function Parser:parseLocal(startTok, attrs)
	self:expectKeyword("local")
	if self:isKeyword("function") then
		local fnTok = self:advance()
		local nameTok = self:cur()
		local name = self:expectName("a function name")
		local v = self:declare(name, nameTok, "function")
		local body = self:parseFunctionBody(false, fnTok, name, attrs)
		return self:finish({ kind = "LocalFunction", name = name, localVar = v, body = body }, startTok)
	end
	if attrs and #attrs > 0 then
		self:error("expected 'function' after attributes")
	end

	local names, nameToks, types = {}, {}, {}
	while true do
		nameToks[#nameToks + 1] = self:cur()
		names[#names + 1] = self:expectName("a variable name")
		if self:isSymbol("<") then
			self:error("variable attributes such as '<const>' and '<close>' are not Luau syntax")
		end
		if self:isSymbol(":") then
			self:advance()
			types[#names] = self:parseType()
		end
		if self:isSymbol(",") then self:advance() else break end
	end

	local exprs = {}
	if self:isSymbol("=") then
		self:advance()
		exprs = self:parseExprList()
	end
	-- Declared only after the initialisers are parsed: `local x = x` reads the outer x.
	local vars = {}
	for i, n in ipairs(names) do
		vars[i] = self:declare(n, nameToks[i], "local")
	end
	return self:finish({
		kind = "Local", names = names, vars = vars, attribs = {}, types = types,
		exprs = exprs, multi = lastMulti(exprs),
	}, startTok)
end

function Parser:parseTypeAlias(isExport, startTok)
	self:advance() -- the `type` name token
	local name = self:expectName("a type alias name")
	local generics, genericInfo
	if self:isSymbol("<") then
		generics, genericInfo = self:parseGenericParamList(true)
	end
	self:expectSymbol("=")
	local typ = self:parseType()
	return self:finish({
		kind = "TypeAlias", name = name, generics = generics, genericInfo = genericInfo,
		typ = typ, export = isExport,
	}, startTok)
end

function Parser:checkAssignable(node)
	local k = node.kind
	if k ~= "Name" and k ~= "DotIndex" and k ~= "BracketIndex" then
		self:errorAtNode(node, "cannot assign to this expression")
	end
	if k == "Name" and node.var and node.resolution ~= "type" then
		node.var.assigned = true
	end
end

-- Assignment, compound assignment, or a call used as a statement.
function Parser:parseExprStatement()
	local startTok = self:cur()
	local first = self:parseSuffixedExpr()

	if self:isSymbol("=") or self:isSymbol(",") then
		local targets = { first }
		while self:isSymbol(",") do
			self:advance()
			targets[#targets + 1] = self:parseSuffixedExpr()
		end
		if not self:isSymbol("=") then
			self:error("expected '=' in assignment")
		end
		for _, target in ipairs(targets) do self:checkAssignable(target) end
		self:advance()
		local exprs = self:parseExprList()
		return self:finish({ kind = "Assign", targets = targets, exprs = exprs, multi = lastMulti(exprs) }, startTok)
	end

	local t = self:cur()
	if t.type == "Symbol" and COMPOUND_OPS[t.value] then
		self:checkAssignable(first)
		local op = COMPOUND_OPS[t.value]
		self:advance()
		local rhs = self:parseExpr()
		return self:finish({ kind = "CompoundAssign", target = first, op = op, expr = rhs }, startTok)
	end

	if first.kind ~= "Call" and first.kind ~= "MethodCall" then
		self:error("incomplete statement: expected an assignment or a function call", startTok)
	end
	return self:finish({ kind = "CallStat", call = first }, startTok)
end

----------------------------------------------------------------------
-- Function bodies, table constructors, expression lists
----------------------------------------------------------------------

function Parser:parseExprList()
	local list = { self:parseExpr() }
	while self:isSymbol(",") do
		self:advance()
		list[#list + 1] = self:parseExpr()
	end
	return list
end

function Parser:parseVarargAnnotation()
	local t = self:cur()
	if t.type == "Name" then
		local n = self:peek()
		if n.type == "Symbol" and n.value == "..." then
			self:advance(); self:advance()
			return self:finish({ kind = "GenericPackType", name = t.value }, t)
		end
	end
	return self:parseType()
end

-- Called after the `function` keyword (or its name) has been consumed. `startTok` is the
-- `function` token, used for source locations.
function Parser:parseFunctionBody(isMethod, startTok, name, attrs)
	startTok = startTok or self.prev
	local generics, genericInfo
	if self:isSymbol("<") then
		generics, genericInfo = self:parseGenericParamList(false)
	end
	self:expectSymbol("(")
	local params, paramToks, paramTypes = {}, {}, {}
	local isVararg, varargType = false, nil
	if isMethod then
		params[1] = "self"
		paramToks[1] = startTok
	end
	if not self:isSymbol(")") then
		while true do
			if self:isSymbol("...") then
				self:advance()
				isVararg = true
				if self:isSymbol(":") then
					self:advance()
					varargType = self:parseVarargAnnotation()
				end
				break
			end
			paramToks[#params + 1] = self:cur()
			params[#params + 1] = self:expectName("a parameter name")
			if self:isSymbol(":") then
				self:advance()
				paramTypes[#params] = self:parseType()
			end
			if self:isSymbol(",") then self:advance() else break end
		end
	end
	self:expectSymbol(")")
	local returnType = nil
	if self:isSymbol(":") then
		self:advance()
		returnType = self:parseReturnType()
	end

	local node = {
		kind = "Function", name = name, attributes = attrs, isMethod = isMethod,
		generics = generics, genericInfo = genericInfo,
		params = params, paramTypes = paramTypes, numparams = #params,
		isVararg = isVararg, varargType = varargType, returnType = returnType,
		upvalues = {}, paramVars = {},
	}
	self:pushFunction(node, isVararg)
	node.body = self:parseBlock(function()
		for i, p in ipairs(params) do
			node.paramVars[i] = self:declare(p, paramToks[i], (isMethod and i == 1) and "self" or "param")
		end
	end)
	self:popFunction()
	self:expectMatch("end", "function", startTok)
	return self:finish(node, startTok)
end

function Parser:parseTableConstructor()
	local startTok = self:expectSymbol("{")
	local fields = {}
	local arrayCount = 0
	while not self:isSymbol("}") do
		local fieldTok = self:cur()
		local field
		if self:isSymbol("[") then
			self:advance()
			local keyExpr = self:parseExpr()
			self:expectSymbol("]")
			self:expectSymbol("=")
			field = { type = "indexed", key = keyExpr, value = self:parseExpr() }
		elseif fieldTok.type == "Name" and self:peek().type == "Symbol" and self:peek().value == "=" then
			self:advance(); self:advance()
			field = { type = "named", key = fieldTok.value, value = self:parseExpr() }
		else
			arrayCount = arrayCount + 1
			field = { type = "item", value = self:parseExpr(), index = arrayCount }
		end
		self:finish(field, fieldTok)
		fields[#fields + 1] = field
		if self:isSymbol(",") or self:isSymbol(";") then
			self:advance()
		else
			break
		end
	end
	self:expectSymbolMatch("}", "{", startTok)
	local last = fields[#fields]
	return self:finish({
		kind = "Table", fields = fields, arrayCount = arrayCount,
		multi = last ~= nil and last.type == "item" and isMultiValue(last.value),
	}, startTok)
end

----------------------------------------------------------------------
-- Expressions (precedence climbing)
----------------------------------------------------------------------

function Parser:parseExpr()
	return self:parseSubExpr(0)
end

function Parser:parseSubExpr(limit)
	self:enter()
	local node
	local t = self:cur()
	if (t.type == "Symbol" and (t.value == "-" or t.value == "#")) or (t.type == "Keyword" and t.value == "not") then
		self:advance()
		local operand = self:parseSubExpr(UNARY_PRIORITY)
		node = self:finish({ kind = "Unop", op = t.value, expr = operand }, t)
	else
		node = self:parseSimpleExpr()
	end

	while true do
		local ct = self:cur()
		local opName
		if ct.type == "Symbol" and BINOP_PRIORITY[ct.value] then
			opName = ct.value
		elseif ct.type == "Keyword" and (ct.value == "and" or ct.value == "or") then
			opName = ct.value
		end
		if not opName then break end
		local pri = BINOP_PRIORITY[opName]
		if pri[1] <= limit then break end
		self:advance()
		local rhs = self:parseSubExpr(pri[2])
		node = self:finishFrom({ kind = "Binop", op = opName, lhs = node, rhs = rhs }, node)
	end
	self:leave()
	return node
end

function Parser:parseSimpleExpr()
	local node = self:parseSimpleExprInner()
	if self:isSymbol("::") then
		self:advance()
		local typ = self:parseType()
		node = self:finishFrom({ kind = "TypeAssert", expr = node, typ = typ }, node)
	end
	return node
end

function Parser:parseSimpleExprInner()
	local t = self:cur()
	local tt, tv = t.type, t.value
	if tt == "Number" then
		self:advance()
		return self:finish({ kind = "Number", value = tv, raw = t.raw }, t)
	elseif tt == "String" then
		self:advance()
		return self:finish({ kind = "String", value = tv }, t)
	elseif tt == "InterpString" then
		return self:parseInterpString()
	elseif tt == "Keyword" then
		if tv == "nil" then self:advance(); return self:finish({ kind = "Nil" }, t)
		elseif tv == "true" then self:advance(); return self:finish({ kind = "True" }, t)
		elseif tv == "false" then self:advance(); return self:finish({ kind = "False" }, t)
		elseif tv == "function" then
			self:advance()
			return self:parseFunctionBody(false, t, nil, nil)
		elseif tv == "if" then
			return self:parseIfExpr()
		end
	elseif tt == "Symbol" then
		if tv == "..." then
			if not self:curFunc().isVararg then
				self:error("cannot use '...' outside a vararg function")
			end
			self:advance()
			return self:finish({ kind = "Vararg" }, t)
		elseif tv == "{" then
			return self:parseTableConstructor()
		elseif tv == "@" then
			local attrs, atTok = self:parseAttributes()
			local fnTok = self:expectKeyword("function")
			local fn = self:parseFunctionBody(false, fnTok, nil, attrs)
			return self:finish(fn, atTok)
		end
	end
	return self:parseSuffixedExpr()
end

function Parser:parseInterpString()
	local t = self:advance()
	local parts = t.value
	local exprs = {}
	for i, list in ipairs(parts.tokens) do
		local saveTokens, savePos, savePrev = self.tokens, self.pos, self.prev
		self.tokens, self.pos = list, 1
		exprs[i] = self:parseExpr()
		if self:cur().type ~= "Eof" then
			self:error("unexpected token in interpolated string expression")
		end
		self.tokens, self.pos, self.prev = saveTokens, savePos, savePrev
	end
	return self:finish({ kind = "InterpString", strings = parts.strings, exprs = exprs }, t)
end

function Parser:parseIfExpr()
	local startTok = self:expectKeyword("if")
	local clauses = {}
	local cond = self:parseExpr()
	self:expectKeyword("then")
	clauses[1] = { cond = cond, expr = self:parseExpr() }
	while self:isKeyword("elseif") do
		self:advance()
		local c = self:parseExpr()
		self:expectKeyword("then")
		clauses[#clauses + 1] = { cond = c, expr = self:parseExpr() }
	end
	if not self:isKeyword("else") then
		self:error("expected 'else' (an if-expression must have an else branch)")
	end
	self:advance()
	local elseExpr = self:parseExpr()
	return self:finish({ kind = "IfExpr", clauses = clauses, elseExpr = elseExpr }, startTok)
end

function Parser:parsePrimaryExpr()
	local t = self:cur()
	if t.type == "Symbol" and t.value == "(" then
		self:advance()
		local inner = self:parseExpr()
		self:expectSymbolMatch(")", "(", t)
		return self:finish({ kind = "Paren", expr = inner }, t)
	elseif t.type == "Name" then
		self:advance()
		return self:finish(self:resolve(t.value), t)
	elseif t.type == "InterpString" then
		self:error("interpolated strings cannot be called or indexed directly; wrap them in parentheses")
	end
	self:error("unexpected token in expression")
end

-- Returns the argument list of a call (after the callee).
function Parser:parseArgs()
	local t = self:cur()
	if t.type == "Symbol" and t.value == "(" then
		self:advance()
		local args = {}
		if not self:isSymbol(")") then
			args = self:parseExprList()
		end
		self:expectSymbolMatch(")", "(", t)
		return args
	elseif t.type == "Symbol" and t.value == "{" then
		return { self:parseTableConstructor() }
	elseif t.type == "String" then
		self:advance()
		return { self:finish({ kind = "String", value = t.value }, t) }
	end
	self:error("expected function arguments")
end

function Parser:parseSuffixedExpr()
	local node = self:parsePrimaryExpr()
	while true do
		local t = self:cur()
		if t.type == "Symbol" and t.value == "." then
			self:advance()
			local name = self:expectName("a field name")
			node = self:finishFrom({ kind = "DotIndex", base = node, name = name }, node)
		elseif t.type == "Symbol" and t.value == "[" then
			self:advance()
			local idx = self:parseExpr()
			self:expectSymbolMatch("]", "[", t)
			node = self:finishFrom({ kind = "BracketIndex", base = node, index = idx }, node)
		elseif t.type == "Symbol" and t.value == ":" then
			self:advance()
			local method = self:expectName("a method name")
			local args = self:parseArgs()
			node = self:finishFrom({
				kind = "MethodCall", base = node, method = method, args = args, multi = lastMulti(args),
			}, node)
		elseif (t.type == "Symbol" and (t.value == "(" or t.value == "{")) or t.type == "String" then
			if t.value == "(" and t.type == "Symbol" and t.line > self.prev.endLine then
				self:error("ambiguous syntax: this looks like an argument list for a function call, "
					.. "but could also start a new statement; use ';' to separate statements")
			end
			local args = self:parseArgs()
			node = self:finishFrom({ kind = "Call", base = node, args = args, multi = lastMulti(args) }, node)
		elseif t.type == "InterpString" then
			self:error("interpolated strings cannot be used as call arguments; wrap them in parentheses")
		else
			break
		end
	end
	return node
end

----------------------------------------------------------------------
-- Types (type-only syntax; never produces runtime behaviour)
----------------------------------------------------------------------

function Parser:expectCloseAngle()
	if self:isSymbol(">") then return self:advance() end
	if self:isSymbol(">=") then
		-- `Foo<T>= x`: split the token so the `>` closes the list and `=` stays.
		local t = self:cur()
		self.tokens[self.pos] = {
			type = "Symbol", value = "=", line = t.line, col = t.col + 1,
			pos = t.pos + 1, endPos = t.endPos, endLine = t.endLine, endCol = t.endCol,
		}
		self.prev = {
			type = "Symbol", value = ">", line = t.line, col = t.col,
			pos = t.pos, endPos = t.pos, endLine = t.line, endCol = t.col + 1,
		}
		return self.prev
	end
	self:error("expected '>'")
end

-- Returns names (array of strings) and info ({name, isPack, default}).
function Parser:parseGenericParamList(allowDefaults)
	self:expectSymbol("<")
	local names, info = {}, {}
	while true do
		local name = self:expectName("a generic parameter name")
		local isPack = false
		if self:isSymbol("...") then
			self:advance()
			isPack = true
		end
		local default
		if self:isSymbol("=") then
			if not allowDefaults then
				self:error("default types are only allowed in type alias declarations")
			end
			self:advance()
			default = self:parseTypeArg()
		end
		names[#names + 1] = name
		info[#info + 1] = { name = name, isPack = isPack, default = default }
		if self:isSymbol(",") then self:advance() else break end
	end
	self:expectCloseAngle()
	return names, info
end

function Parser:parseTypeArg()
	if self:isSymbol("...") then
		local t = self:advance()
		local inner = self:parseType()
		return self:finish({ kind = "TupleType", types = {}, variadic = inner }, t)
	end
	return self:parseType(true)
end

function Parser:parseReturnType()
	if self:isSymbol("...") then
		return self:parseTypeArg()
	end
	return self:parseType(true)
end

-- allowPack: a type pack (`(A, B)`, `T...`) is acceptable here (return types, generic arguments).
function Parser:parseType(allowPack)
	self:enter()
	local startTok = self:cur()
	local mode
	if self:isSymbol("|") or self:isSymbol("&") then
		mode = self:advance().value
	end
	local t = self:parseTypeSuffixed(allowPack and mode == nil)
	while self:isSymbol("|") or self:isSymbol("&") do
		local op = self:cur().value
		if mode and mode ~= op then
			self:error("mixing union and intersection types is not allowed; add parentheses")
		end
		if isPackish(t) then
			self:error("a type pack cannot be an operand of '" .. op .. "'")
		end
		mode = op
		self:advance()
		local rhs = self:parseTypeSuffixed(false)
		t = self:finish({
			kind = op == "|" and "UnionType" or "IntersectionType", left = t, right = rhs,
		}, startTok)
	end
	self:leave()
	return t
end

function Parser:parseTypeSuffixed(allowPack)
	local startTok = self:cur()
	local t = self:parseTypePrimary(allowPack)
	while self:isSymbol("?") do
		if isPackish(t) then
			self:error("a type pack cannot be optional")
		end
		self:advance()
		t = self:finish({ kind = "OptionalType", base = t }, startTok)
	end
	return t
end

function Parser:parseParenType(allowPack)
	local startTok = self:expectSymbol("(")
	local params, names, variadic = {}, {}, nil
	if not self:isSymbol(")") then
		while true do
			if self:isSymbol("...") then
				self:advance()
				variadic = self:parseType()
				break
			end
			local t = self:cur()
			if t.type == "Name" and self:peek().type == "Symbol" and self:peek().value == ":" then
				names[#params + 1] = t.value
				self:advance(); self:advance()
			end
			params[#params + 1] = self:parseType(true)
			if self:isSymbol(",") then self:advance() else break end
		end
	end
	self:expectSymbol(")")
	local last = params[#params]
	if last and last.kind == "GenericPackType" and not variadic then
		variadic = table.remove(params)
	end
	for _, p in ipairs(params) do
		if p.kind == "GenericPackType" then
			self:errorAtNode(p, "a generic type pack must be the last element of a type list")
		end
	end

	if self:isSymbol("->") then
		self:advance()
		local ret = self:parseReturnType()
		return self:finish({
			kind = "FunctionType", params = params, paramNames = names,
			variadic = variadic, returnType = ret,
		}, startTok)
	end
	if next(names) ~= nil then
		self:error("expected '->' after a parenthesised list of named parameters")
	end
	if #params == 1 and not variadic and not isPackish(params[1]) then
		return self:finish({ kind = "ParenType", inner = params[1] }, startTok)
	end
	if not allowPack then
		self:error("expected '->' after a parenthesised type list (type packs are only valid as return types and generic arguments)")
	end
	return self:finish({ kind = "TupleType", types = params, variadic = variadic }, startTok)
end

function Parser:parseTableType()
	local startTok = self:expectSymbol("{")
	local entries = {}
	while not self:isSymbol("}") do
		local t = self:cur()
		local access
		if t.type == "Name" and (t.value == "read" or t.value == "write") then
			local n = self:peek()
			if n.type == "Name" or (n.type == "Symbol" and n.value == "[") then
				access = t.value
				self:advance()
			end
		end
		local e
		local ct = self:cur()
		if self:isSymbol("[") then
			self:advance()
			local keyType = self:parseType()
			self:expectSymbol("]")
			self:expectSymbol(":")
			e = { kind = "indexer", keyType = keyType, valueType = self:parseType(), access = access }
		elseif ct.type == "Name" and self:peek().type == "Symbol" and self:peek().value == ":" then
			self:advance(); self:advance()
			e = { kind = "prop", name = ct.value, valueType = self:parseType(), access = access }
		else
			if access then self:error("expected a property name after '" .. access .. "'") end
			e = { kind = "array", valueType = self:parseType() }
			self:finish(e, ct)
			if #entries > 0 then
				self:errorAtNode(e, "an array type must be the only entry of a table type")
			end
			entries[1] = e
			if not self:isSymbol("}") then
				self:error("an array type must be the only entry of a table type")
			end
			break
		end
		self:finish(e, ct)
		entries[#entries + 1] = e
		if self:isSymbol(",") or self:isSymbol(";") then self:advance() else break end
	end
	self:expectSymbolMatch("}", "{", startTok)
	return self:finish({ kind = "TableType", entries = entries }, startTok)
end

function Parser:parseTypePrimary(allowPack)
	local t = self:cur()
	local tt, tv = t.type, t.value

	if tt == "Keyword" then
		if tv == "nil" then
			self:advance(); return self:finish({ kind = "NilType" }, t)
		elseif tv == "true" or tv == "false" then
			self:advance(); return self:finish({ kind = "BooleanType", value = tv == "true" }, t)
		end
	elseif tt == "String" then
		self:advance()
		return self:finish({ kind = "StringType", value = tv }, t)
	elseif tt == "Symbol" then
		if tv == "(" then
			return self:parseParenType(allowPack)
		elseif tv == "{" then
			return self:parseTableType()
		elseif tv == "<" then
			local generics, info = self:parseGenericParamList(false)
			if not self:isSymbol("(") then
				self:error("expected '(' after generic parameters of a function type")
			end
			local fn = self:parseParenType(false)
			if fn.kind ~= "FunctionType" then
				self:errorAtNode(fn, "generic parameters are only allowed on function types")
			end
			fn.generics, fn.genericInfo = generics, info
			return self:finishFrom(fn, t)
		end
	elseif tt == "Name" then
		local n = self:peek()
		if tv == "typeof" and n.type == "Symbol" and n.value == "(" then
			self:advance(); self:advance()
			self.typeofDepth = self.typeofDepth + 1
			local expr = self:parseExpr()
			self.typeofDepth = self.typeofDepth - 1
			self:expectSymbolMatch(")", "(", n)
			return self:finish({ kind = "TypeofType", expr = expr }, t)
		end
		if n.type == "Symbol" and n.value == "..." then
			if not allowPack then
				self:error("a generic type pack is not allowed here", n)
			end
			self:advance(); self:advance()
			return self:finish({ kind = "GenericPackType", name = tv }, t)
		end
		self:advance()
		local path = { tv }
		while self:isSymbol(".") do
			self:advance()
			path[#path + 1] = self:expectName("a type name")
		end
		local generics = nil
		if self:isSymbol("<") then
			self:advance()
			generics = {}
			if not self:isSymbol(">") then
				while true do
					generics[#generics + 1] = self:parseTypeArg()
					if self:isSymbol(",") then self:advance() else break end
				end
			end
			self:expectCloseAngle()
		end
		return self:finish({ kind = "TypeRef", path = path, generics = generics }, t)
	end
	self:error("expected a type")
end

----------------------------------------------------------------------
-- Type erasure
----------------------------------------------------------------------

local TYPE_FIELDS = {
	types = true, paramTypes = true, returnType = true, varargType = true,
	generics = true, genericInfo = true, varType = true, typ = true,
}
local NO_DESCEND = {
	var = true, vars = true, loopVar = true, loopVars = true, paramVars = true,
	localVar = true, scope = true, upvalues = true,
}

local function erase(node)
	if type(node) ~= "table" then return node end
	if node.kind == "TypeAssert" then
		local inner = erase(node.expr)
		if isMultiValue(inner) then
			-- `f() :: T` yields exactly one value, like a parenthesised call.
			return {
				kind = "Paren", expr = inner, line = node.line, col = node.col,
				endLine = node.endLine, endCol = node.endCol,
			}
		end
		return inner
	end
	if rawget(node, 1) ~= nil then
		local n, w = #node, 0
		for i = 1, n do
			local s = node[i]
			if not (type(s) == "table" and s.kind == "TypeAlias") then
				w = w + 1
				node[w] = erase(s)
			end
		end
		for i = w + 1, n do node[i] = nil end
		return node
	end
	for k in pairs(node) do
		if TYPE_FIELDS[k] then node[k] = nil end
	end
	for k, v in pairs(node) do
		if not NO_DESCEND[k] and type(v) == "table" then
			node[k] = erase(v)
		end
	end
	return node
end

-- Removes every type-only construct in place (TypeAlias statements, annotations, generics) and
-- replaces TypeAssert with its operand. Scope data (Var/upvalues) is left untouched.
function Parser.eraseTypes(chunk)
	return erase(chunk)
end

return Parser
