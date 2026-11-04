--!strict
-- CoriolisBytecodeVM: independent stack-bytecode VM for Roblox Luau.
-- Frontend dependency: existing LuauVM.lua (lexer/parser only).
-- The AST is discarded after compilation; runtime executes numeric opcodes only.

local Frontend = require(script.Parent:WaitForChild("LuauVM"))
local Parser = Frontend._Parser
local Lexer = Frontend._Lexer

local Coriolis = {}
Coriolis.VERSION = 1

local OP = {
  PUSH=1, GET=2, DECL=3, SET=4, POP=5, DUP=6,
  INDEX=7, SETINDEX=8, NEWTABLE=9, TABLESET=10,
  BIN=11, UN=12, JMP=13, JFALSE=14, JTRUE=15,
  CLOSURE=16, CALL=17, METHODCALL=18, RETURN=19,
  VARARG=20, HALT=21, TMPSTORE=22, TMPLOAD=23,
}
Coriolis.OPCODES = OP

local function pack(...) return { n=select("#", ...), ... } end
local function truth(v) return v ~= nil and v ~= false end
local function ins(code, op, a, b, c, line)
  code[#code+1] = {op, a, b, c, line}
  return #code
end
local function patch(code, at, target) code[at][2] = target end

local Compiler = {}
Compiler.__index = Compiler
function Compiler.new()
  return setmetatable({protos={}, loops={}}, Compiler)
end
function Compiler:compileFunction(node, name)
  local proto = {name=name or "chunk", params=node.params or {}, vararg=node.isVararg or false, code={}, constants={}}
  self.protos[#self.protos+1] = proto
  local previous = self.current
  self.current = proto
  if node.body and node.body.body then self:statements(node.body.body) end
  if #proto.code == 0 or proto.code[#proto.code][1] ~= OP.RETURN then ins(proto.code, OP.RETURN, 0, nil, nil, node.line) end
  self.current = previous
  return #self.protos
end
function Compiler:emit(op,a,b,c,line) return ins(self.current.code,op,a,b,c,line) end
function Compiler:expr(n)
  local t=n.type
  if t=="Number" or t=="String" or t=="Bool" then self:emit(OP.PUSH,n.value,nil,nil,n.line)
  elseif t=="Nil" then self:emit(OP.PUSH,nil,nil,nil,n.line)
  elseif t=="Name" then self:emit(OP.GET,n.name,nil,nil,n.line)
  elseif t=="Paren" then self:expr(n.expr)
  elseif t=="Index" then self:expr(n.object); self:expr(n.key); self:emit(OP.INDEX,nil,nil,nil,n.line)
  elseif t=="BinOp" then
    if n.op=="and" or n.op=="or" then
      self:expr(n.left); self:emit(OP.DUP); local j=self:emit(n.op=="and" and OP.JFALSE or OP.JTRUE,0); self:emit(OP.POP); self:expr(n.right); patch(self.current.code,j,#self.current.code+1)
    else self:expr(n.left); self:expr(n.right); self:emit(OP.BIN,n.op,nil,nil,n.line) end
  elseif t=="UnOp" then self:expr(n.operand); self:emit(OP.UN,n.op,nil,nil,n.line)
  elseif t=="Table" then
    self:emit(OP.NEWTABLE)
    local arrayIndex=1
    for _,f in ipairs(n.fields) do
      if f.kind=="positional" then self:emit(OP.DUP); self:emit(OP.PUSH,arrayIndex); self:expr(f.value); self:emit(OP.TABLESET,nil,nil,nil,n.line); arrayIndex=arrayIndex+1
      elseif f.kind=="named" then self:emit(OP.DUP); self:emit(OP.PUSH,f.key); self:expr(f.value); self:emit(OP.TABLESET,nil,nil,nil,n.line)
      else self:emit(OP.DUP); self:expr(f.key); self:expr(f.value); self:emit(OP.TABLESET,nil,nil,nil,n.line) end
    end
  elseif t=="Function" then
    local id=self:compileFunction(n,"function@"..tostring(n.line or 0)); self:emit(OP.CLOSURE,id,nil,nil,n.line)
  elseif t=="Call" then
    self:expr(n.func); for _,a in ipairs(n.args) do self:expr(a) end; self:emit(OP.CALL,#n.args,nil,nil,n.line)
  elseif t=="MethodCall" then
    self:expr(n.object); for _,a in ipairs(n.args) do self:expr(a) end; self:emit(OP.METHODCALL,n.method,#n.args,nil,n.line)
  elseif t=="Vararg" then self:emit(OP.VARARG,1,nil,nil,n.line)
  else error(("Coriolis compiler: unsupported expression '%s' at line %s"):format(tostring(t),tostring(n.line)),0) end
end
function Compiler:statements(list)
  for _,s in ipairs(list) do self:statement(s) end
end
function Compiler:statement(s)
  local t=s.type
  if t=="Local" then
    for i,name in ipairs(s.names) do
      if s.values[i] then self:expr(s.values[i]) else self:emit(OP.PUSH,nil) end
      self:emit(OP.DECL,name,nil,nil,s.line)
    end
    for i=#s.names+1,#(s.values or {}) do self:expr(s.values[i]); self:emit(OP.POP) end
  elseif t=="LocalFunction" then
    self:emit(OP.PUSH,nil); self:emit(OP.DECL,s.name); local id=self:compileFunction(s.func,s.name); self:emit(OP.CLOSURE,id); self:emit(OP.SET,s.name); self:emit(OP.POP)
  elseif t=="Assign" then
    -- Spill RHS values to frame temporaries, then commit destinations in reverse order.
    -- This supports parallel assignment; indexed-target evaluation order is a documented limitation of this prototype.
    local count=#s.targets
    for i=1,count do
      if s.values[i] then self:expr(s.values[i]) else self:emit(OP.PUSH,nil) end
      self:emit(OP.TMPSTORE,i)
    end
    for i=count,1,-1 do
      local target=s.targets[i]
      if target.type=="Name" then self:emit(OP.TMPLOAD,i); self:emit(OP.SET,target.name); self:emit(OP.POP)
      elseif target.type=="Index" then self:expr(target.object); self:expr(target.key); self:emit(OP.TMPLOAD,i); self:emit(OP.SETINDEX); self:emit(OP.POP)
      else error("Coriolis compiler: unsupported assignment target",0) end
    end
  elseif t=="ExprStat" then self:expr(s.expr); self:emit(OP.POP)
  elseif t=="Return" then
    for _,e in ipairs(s.args) do self:expr(e) end
    self:emit(OP.RETURN,#s.args,nil,nil,s.line)
  elseif t=="If" then
    local ends={}
    for _,cl in ipairs(s.clauses) do
      self:expr(cl.cond); local jf=self:emit(OP.JFALSE,0); self:statements(cl.body.body); ends[#ends+1]=self:emit(OP.JMP,0); patch(self.current.code,jf,#self.current.code+1)
    end
    if s.elseBody then self:statements(s.elseBody.body) end
    for _,j in ipairs(ends) do patch(self.current.code,j,#self.current.code+1) end
  elseif t=="Do" then self:statements(s.body.body)
  elseif t=="While" then
    local start=#self.current.code+1; self:expr(s.cond); local out=self:emit(OP.JFALSE,0); local loop={breaks={},continues={},start=start}; self.loops[#self.loops+1]=loop
    self:statements(s.body.body); for _,j in ipairs(loop.continues) do patch(self.current.code,j,start) end; self:emit(OP.JMP,start); local finish=#self.current.code+1; patch(self.current.code,out,finish); for _,j in ipairs(loop.breaks) do patch(self.current.code,j,finish) end; self.loops[#self.loops]=nil
  elseif t=="Break" or t=="Continue" then
    local loop=self.loops[#self.loops]; if not loop then error(t.." outside loop",0) end
    local j=self:emit(OP.JMP,0); if t=="Break" then loop.breaks[#loop.breaks+1]=j else loop.continues[#loop.continues+1]=j end
  else error(("Coriolis compiler: unsupported statement '%s' at line %s"):format(tostring(t),tostring(s.line)),0) end
end

function Coriolis.Compile(source)
  assert(type(source)=="string","source must be a string")
  local tokens=Lexer.new(source):tokenize()
  local ast=Parser.new(tokens):parseChunk()
  local c=Compiler.new()
  local rootId=c:compileFunction({params={},isVararg=true,body=ast},"<chunk>")
  return {magic="CORIOLIS",version=Coriolis.VERSION,entry=rootId,prototypes=c.protos}
end

local function newEnv(parent, globals)
  return {cells={},parent=parent,globals=globals}
end
local function findCell(env,name)
  local e=env
  while e do if e.cells[name] then return e.cells[name],e end; e=e.parent end
end
local function bin(op,a,b)
  if op=="+" then return a+b elseif op=="-" then return a-b elseif op=="*" then return a*b elseif op=="/" then return a/b elseif op=="%" then return a%b elseif op=="^" then return a^b elseif op==".." then return a..b elseif op=="==" then return a==b elseif op=="~=" then return a~=b elseif op=="<" then return a<b elseif op==">" then return a>b elseif op=="<=" then return a<=b elseif op==">=" then return a>=b end
  error("unknown Coriolis binary opcode: "..tostring(op),0)
end
local function run(program, protoId, closureEnv, args)
  local proto=program.prototypes[protoId]; assert(proto,"invalid function prototype")
  local env=newEnv(closureEnv, closureEnv and closureEnv.globals or {})
  for i,name in ipairs(proto.params) do env.cells[name]={value=args[i]} end
  local varargs={n=math.max(0,args.n-#proto.params)}; for i=1,varargs.n do varargs[i]=args[#proto.params+i] end
  env.cells["..."]={value=varargs}
  local stack,temps,pc={}, {},1
  local function push(v) stack[#stack+1]=v end
  local function pop() local n=#stack; local v=stack[n]; stack[n]=nil; return v end
  while pc<=#proto.code do
    local insn=proto.code[pc]; local op,a,b,c,line=insn[1],insn[2],insn[3],insn[4],insn[5]; pc=pc+1
    if op==OP.PUSH then push(a)
    elseif op==OP.GET then local cell=findCell(env,a); if cell then push(cell.value) else push(env.globals[a]) end
    elseif op==OP.DECL then env.cells[a]={value=pop()}
    elseif op==OP.SET then local v=pop(); local cell=findCell(env,a); if cell then cell.value=v else env.globals[a]=v end; push(v)
    elseif op==OP.POP then pop()
    elseif op==OP.DUP then push(stack[#stack])
    elseif op==OP.INDEX then local k=pop(); local obj=pop(); push(obj[k])
    elseif op==OP.SETINDEX then local v=pop(); local k=pop(); local obj=pop(); obj[k]=v; push(v)
    elseif op==OP.NEWTABLE then push({})
    elseif op==OP.TABLESET then local v=pop(); local k=pop(); local obj=pop(); if a=="array" then obj[#obj+1]=v else obj[k]=v end; push(obj)
    elseif op==OP.BIN then local y=pop(); local x=pop(); push(bin(a,x,y))
    elseif op==OP.UN then local x=pop(); if a=="not" then push(not truth(x)) elseif a=="-" then push(-x) elseif a=="#" then push(#x) end
    elseif op==OP.JMP then pc=a
    elseif op==OP.JFALSE then if not truth(pop()) then pc=a end
    elseif op==OP.JTRUE then if truth(pop()) then pc=a end
    elseif op==OP.CLOSURE then local id=a; push(function(...) return run(program,id,env,pack(...)) end)
    elseif op==OP.CALL then local callArgs={n=a}; for i=a,1,-1 do callArgs[i]=pop() end; local fn=pop(); local result=pack(fn(table.unpack(callArgs,1,callArgs.n))); push(result[1])
    elseif op==OP.METHODCALL then local callArgs={n=a+1}; for i=a,1,-1 do callArgs[i+1]=pop() end; local obj=pop(); callArgs[1]=obj; local fn=obj[b]; local result=pack(fn(table.unpack(callArgs,1,callArgs.n))); push(result[1])
    elseif op==OP.VARARG then push(varargs[a])
    elseif op==OP.TMPSTORE then temps[a]=pop()
    elseif op==OP.TMPLOAD then push(temps[a])
    elseif op==OP.RETURN then local out={n=a}; for i=a,1,-1 do out[i]=pop() end; return table.unpack(out,1,out.n)
    elseif op==OP.HALT then return
    else error("invalid Coriolis opcode "..tostring(op).." at pc "..tostring(pc-1),0) end
  end
end

function Coriolis.Execute(program, globals, ...)
  assert(type(program)=="table" and program.magic=="CORIOLIS" and program.version==Coriolis.VERSION,"invalid Coriolis program")
  local hostGlobals=globals or (getfenv and getfenv(0)) or _G
  local root=newEnv(nil,hostGlobals)
  return run(program,program.entry,root,pack(...))
end
function Coriolis.Run(source, globals, ...)
  return Coriolis.Execute(Coriolis.Compile(source),globals,...)
end
function Coriolis.RunSafe(source, globals, ...)
  return pcall(Coriolis.Run,source,globals,...)
end
return Coriolis
