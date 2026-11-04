--!nonstrict
-- Place this folder under a ModuleScript/package in Roblox Studio.
-- Require individual modules directly; this init is a convenience facade.
return {
    Lexer = require(script.Lexer),
    Parser = require(script.Parser),
    ASTCompiler = require(script.ASTCompiler),
    Assembler = require(script.Assembler),
    BytecodeVerifier = require(script.BytecodeVerifier),
    LuauVM = require(script.LuauVM),
    Encoder = require(script.Encoder),
    Obfuscator = require(script.Obfuscator),
}
