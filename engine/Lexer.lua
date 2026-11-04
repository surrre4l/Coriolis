--!nonstrict
--[[
	Lexer.lua
	Tokenizer for Luau source text, feeding Parser.lua.

	Token: { type, value, line, col, pos, endPos, endLine, endCol }
	  type     "Name" | "Number" | "String" | "InterpString" | "Keyword" | "Symbol" | "Eof"
	  line/col 1-based start position
	  pos      1-based byte offset of the first character; endPos is the last character (inclusive)
	  endLine/endCol  position just after the token (exclusive)
	  Number tokens also carry `raw` (source text).
	  InterpString value = { strings = {...}, exprs = {rawSrc...}, tokens = {{Token...}...} }
	    #strings == #exprs + 1; tokens[i] is the already-lexed expression i, terminated by an
	    Eof token, with positions in the original source.

	`type`, `export`, `continue` and `typeof` are NOT keywords in Luau; they are lexed as
	Names and the parser treats them contextually.

	Errors are raised as strings: "Lexer error at line L col C: message".
]]

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {}
for _, w in ipairs({
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if",
	"in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}) do
	KEYWORDS[w] = true
end
Lexer.KEYWORDS = KEYWORDS

local function set(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

local SYMBOLS = {
	[3] = set({ "...", "..=", "//=" }),
	[2] = set({ "==", "~=", "<=", ">=", "..", "::", "->", "+=", "-=", "*=", "/=", "%=", "^=", "//" }),
	[1] = set({ "+", "-", "*", "/", "%", "^", "#", "<", ">", "=", "(", ")", "{", "}",
		"[", "]", ";", ":", ",", ".", "&", "|", "?", "@" }),
}

local SIMPLE_ESCAPES = {
	a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
	["\\"] = "\\", ['"'] = '"', ["'"] = "'",
}

local function isDigit(c) return c ~= "" and c >= "0" and c <= "9" end
local function isHexDigit(c)
	return isDigit(c) or (c ~= "" and ((c >= "a" and c <= "f") or (c >= "A" and c <= "F")))
end
local function isAlpha(c)
	return c ~= "" and ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_")
end
local function isAlnum(c) return isAlpha(c) or isDigit(c) end
local function isSpace(c)
	return c == " " or c == "\t" or c == "\r" or c == "\n" or c == "\f" or c == "\v"
end

function Lexer.new(src)
	local self = setmetatable({}, Lexer)
	self.src = src
	self.pos = 1
	self.len = #src
	self.line = 1
	self.col = 1
	if string.sub(src, 1, 3) == "\239\187\191" then
		self.pos = 4
	end
	return self
end

function Lexer:peekChar(offset)
	local p = self.pos + (offset or 0)
	if p > self.len then return "" end
	return string.sub(self.src, p, p)
end

function Lexer:advance()
	local c = self:peekChar()
	self.pos = self.pos + 1
	if c == "\n" then
		self.line = self.line + 1
		self.col = 1
	else
		self.col = self.col + 1
	end
	return c
end

function Lexer:errorAt(line, col, msg)
	error(("Lexer error at line %d col %d: %s"):format(line, col, msg), 0)
end

function Lexer:error(msg)
	self:errorAt(self.line, self.col, msg)
end

function Lexer:token(ttype, value, startPos, line, col)
	return {
		type = ttype, value = value, line = line, col = col,
		pos = startPos, endPos = self.pos - 1, endLine = self.line, endCol = self.col,
	}
end

-- Consumes up to and including the closing bracket. The opener (`[==[`) must already be
-- consumed. Returns the body with the first newline dropped and CR/CRLF normalised to LF.
function Lexer:readLongBracket(level, startLine, startCol, what)
	if self:peekChar() == "\r" then self:advance() end
	if self:peekChar() == "\n" then self:advance() end
	local closer = "]" .. string.rep("=", level) .. "]"
	local found = string.find(self.src, closer, self.pos, true)
	if not found then
		self:errorAt(startLine, startCol, "unterminated long " .. what .. " (expected closing " .. closer .. ")")
	end
	local body = string.sub(self.src, self.pos, found - 1)
	local stop = found + #closer
	while self.pos < stop do self:advance() end
	body = (string.gsub(body, "\r\n", "\n"))
	body = (string.gsub(body, "\r", "\n"))
	return body
end

-- At a `[`: returns the level of a `[=*[` opener without consuming, else nil.
function Lexer:tryLongBracketLevel()
	if self:peekChar() ~= "[" then return nil end
	local p = 1
	while self:peekChar(p) == "=" do p = p + 1 end
	if self:peekChar(p) == "[" then return p - 1 end
	return nil
end

function Lexer:skipOpener(level)
	for _ = 1, level + 2 do self:advance() end
end

function Lexer:skipWhitespaceAndComments()
	while true do
		local c = self:peekChar()
		if isSpace(c) then
			self:advance()
		elseif c == "-" and self:peekChar(1) == "-" then
			local line, col = self.line, self.col
			self:advance(); self:advance()
			local level = self:tryLongBracketLevel()
			if level then
				self:skipOpener(level)
				self:readLongBracket(level, line, col, "comment")
			else
				while self:peekChar() ~= "" and self:peekChar() ~= "\n" do
					self:advance()
				end
			end
		else
			break
		end
	end
end

-- Positioned at a backslash. Appends the decoded text to buf.
function Lexer:readEscape(buf, interp)
	local line, col = self.line, self.col
	self:advance()
	local e = self:peekChar()
	if e == "" then
		self:errorAt(line, col, "unterminated string")
	elseif e == "x" then
		self:advance()
		local h1, h2 = self:peekChar(), self:peekChar(1)
		if not (isHexDigit(h1) and isHexDigit(h2)) then
			self:errorAt(line, col, "invalid escape sequence '\\x' (expected two hex digits)")
		end
		self:advance(); self:advance()
		buf[#buf + 1] = string.char(tonumber(h1 .. h2, 16))
	elseif e == "z" then
		self:advance()
		while isSpace(self:peekChar()) do self:advance() end
	elseif e == "u" then
		self:advance()
		if self:peekChar() ~= "{" then
			self:errorAt(line, col, "invalid escape sequence '\\u' (expected '{')")
		end
		self:advance()
		local hex = ""
		while isHexDigit(self:peekChar()) do hex = hex .. self:advance() end
		if hex == "" or self:peekChar() ~= "}" then
			self:errorAt(line, col, "invalid unicode escape (expected hex digits then '}')")
		end
		self:advance()
		local cp = tonumber(hex, 16)
		if #hex > 8 or cp > 0x10FFFF then
			self:errorAt(line, col, "unicode escape out of range (max \\u{10FFFF})")
		end
		buf[#buf + 1] = utf8.char(cp)
	elseif isDigit(e) then
		local digits = self:advance()
		for _ = 1, 2 do
			if isDigit(self:peekChar()) then digits = digits .. self:advance() end
		end
		local n = tonumber(digits)
		if n > 255 then
			self:errorAt(line, col, "decimal escape '\\" .. digits .. "' too large (max \\255)")
		end
		buf[#buf + 1] = string.char(n)
	elseif e == "\r" then
		self:advance()
		if self:peekChar() == "\n" then self:advance() end
		buf[#buf + 1] = "\n"
	elseif e == "\n" then
		self:advance()
		buf[#buf + 1] = "\n"
	elseif SIMPLE_ESCAPES[e] then
		self:advance()
		buf[#buf + 1] = SIMPLE_ESCAPES[e]
	elseif interp and (e == "{" or e == "`") then
		self:advance()
		buf[#buf + 1] = e
	else
		self:errorAt(line, col, "invalid escape sequence '\\" .. e .. "'")
	end
end

function Lexer:readQuotedString(quote, startLine, startCol)
	local buf = {}
	while true do
		local c = self:peekChar()
		if c == "" or c == "\n" or c == "\r" then
			self:errorAt(startLine, startCol, "unterminated string")
		elseif c == quote then
			self:advance()
			break
		elseif c == "\\" then
			self:readEscape(buf, false)
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return table.concat(buf)
end

-- Scans a backtick string. Each `{expr}` is lexed in place, so the expression tokens keep
-- their real positions and nested strings/comments/braces are handled by the normal lexer.
function Lexer:readInterpString(startLine, startCol)
	local strings, exprs, tokenLists = {}, {}, {}
	local buf = {}
	while true do
		local c = self:peekChar()
		if c == "" then
			self:errorAt(startLine, startCol, "unterminated interpolated string")
		elseif c == "`" then
			self:advance()
			strings[#strings + 1] = table.concat(buf)
			break
		elseif c == "\\" then
			self:readEscape(buf, true)
		elseif c == "\r" then
			self:advance()
			if self:peekChar() == "\n" then self:advance() end
			buf[#buf + 1] = "\n"
		elseif c == "{" then
			local braceLine, braceCol = self.line, self.col
			self:advance()
			if self:peekChar() == "{" then
				self:errorAt(braceLine, braceCol,
					"double braces are not permitted in interpolated strings; use \\{ for a literal brace")
			end
			strings[#strings + 1] = table.concat(buf)
			buf = {}
			local exprStart = self.pos
			local toks, depth = {}, 0
			local closer
			while true do
				local tok = self:next()
				if tok.type == "Eof" then
					self:errorAt(startLine, startCol, "unterminated interpolated string expression")
				end
				if tok.type == "Symbol" and tok.value == "{" then
					depth = depth + 1
				elseif tok.type == "Symbol" and tok.value == "}" then
					if depth == 0 then closer = tok; break end
					depth = depth - 1
				end
				toks[#toks + 1] = tok
			end
			if #toks == 0 then
				self:errorAt(braceLine, braceCol, "empty expression in interpolated string")
			end
			toks[#toks + 1] = {
				type = "Eof", line = closer.line, col = closer.col, pos = closer.pos,
				endPos = closer.pos - 1, endLine = closer.line, endCol = closer.col,
			}
			exprs[#exprs + 1] = string.sub(self.src, exprStart, closer.pos - 1)
			tokenLists[#tokenLists + 1] = toks
		else
			buf[#buf + 1] = self:advance()
		end
	end
	return { strings = strings, exprs = exprs, tokens = tokenLists }
end

-- Returns (value, rawText). Hex/binary values are accumulated as doubles so large literals
-- behave like Luau (no 64-bit integer wraparound). Hex floats are not Luau syntax.
function Lexer:readNumber()
	local start, line, col = self.pos, self.line, self.col
	local value
	local c, c1 = self:peekChar(), self:peekChar(1)
	if c == "0" and (c1 == "x" or c1 == "X") then
		self:advance(); self:advance()
		local acc, n = 0.0, 0
		while true do
			local d = self:peekChar()
			if d == "_" then
				self:advance()
			elseif isHexDigit(d) then
				acc = acc * 16.0 + tonumber(d, 16)
				n = n + 1
				self:advance()
			else
				break
			end
		end
		if n == 0 then self:errorAt(line, col, "malformed number (no digits after '0x')") end
		value = acc
	elseif c == "0" and (c1 == "b" or c1 == "B") then
		self:advance(); self:advance()
		local acc, n = 0.0, 0
		while true do
			local d = self:peekChar()
			if d == "_" then
				self:advance()
			elseif d == "0" or d == "1" then
				acc = acc * 2.0 + tonumber(d)
				n = n + 1
				self:advance()
			else
				break
			end
		end
		if n == 0 then self:errorAt(line, col, "malformed number (no digits after '0b')") end
		value = acc
	else
		while isDigit(self:peekChar()) or self:peekChar() == "_" do self:advance() end
		if self:peekChar() == "." then
			self:advance()
			while isDigit(self:peekChar()) or self:peekChar() == "_" do self:advance() end
		end
		if self:peekChar() == "e" or self:peekChar() == "E" then
			self:advance()
			if self:peekChar() == "+" or self:peekChar() == "-" then self:advance() end
			local nd = 0
			while isDigit(self:peekChar()) do self:advance(); nd = nd + 1 end
			if nd == 0 then self:errorAt(line, col, "malformed number (exponent has no digits)") end
		end
		value = tonumber((string.gsub(string.sub(self.src, start, self.pos - 1), "_", "")))
	end
	local nxt = self:peekChar()
	if isAlnum(nxt) or nxt == "." then
		local junkEnd = self.pos
		while isAlnum(self:peekChar(junkEnd - self.pos)) or self:peekChar(junkEnd - self.pos) == "." do
			junkEnd = junkEnd + 1
		end
		self:errorAt(line, col, "malformed number '" .. string.sub(self.src, start, junkEnd - 1) .. "'")
	end
	if value == nil then self:errorAt(line, col, "malformed number") end
	return value, string.sub(self.src, start, self.pos - 1)
end

function Lexer:next()
	self:skipWhitespaceAndComments()
	local startPos, line, col = self.pos, self.line, self.col
	local c = self:peekChar()

	if c == "" then
		return self:token("Eof", nil, startPos, line, col)
	end

	if isAlpha(c) then
		while isAlnum(self:peekChar()) do self:advance() end
		local word = string.sub(self.src, startPos, self.pos - 1)
		if KEYWORDS[word] then
			return self:token("Keyword", word, startPos, line, col)
		end
		return self:token("Name", word, startPos, line, col)
	end

	if isDigit(c) or (c == "." and isDigit(self:peekChar(1))) then
		local value, raw = self:readNumber()
		local tok = self:token("Number", value, startPos, line, col)
		tok.raw = raw
		return tok
	end

	if c == '"' or c == "'" then
		self:advance()
		local s = self:readQuotedString(c, line, col)
		return self:token("String", s, startPos, line, col)
	end

	if c == "`" then
		self:advance()
		local parts = self:readInterpString(line, col)
		return self:token("InterpString", parts, startPos, line, col)
	end

	if c == "[" then
		local level = self:tryLongBracketLevel()
		if level then
			self:skipOpener(level)
			local s = self:readLongBracket(level, line, col, "string")
			return self:token("String", s, startPos, line, col)
		elseif self:peekChar(1) == "=" then
			self:errorAt(line, col, "invalid long string delimiter (expected '[' after '[=')")
		end
	end

	for len = 3, 1, -1 do
		local candidate = string.sub(self.src, self.pos, self.pos + len - 1)
		if #candidate == len and SYMBOLS[len][candidate] then
			for _ = 1, len do self:advance() end
			return self:token("Symbol", candidate, startPos, line, col)
		end
	end

	local b = string.byte(c)
	local shown = (b >= 32 and b < 127) and ("'" .. c .. "'") or ("byte " .. b)
	self:errorAt(line, col, "unexpected character " .. shown)
end

-- Tokenizes the whole source; the last token is always Eof.
function Lexer.tokenize(src)
	local lx = Lexer.new(src)
	local tokens = {}
	while true do
		local tok = lx:next()
		tokens[#tokens + 1] = tok
		if tok.type == "Eof" then break end
	end
	return tokens
end

return Lexer
