--!nonstrict
-- Coriolis v2.1.0 orchestration layer. Roblox Studio ModuleScript.
local Parser = require(script.Parent.Parser)
local ASTCompiler = require(script.Parent.ASTCompiler)
local Verifier = require(script.Parent.BytecodeVerifier)
local Encoder = require(script.Parent.Encoder)

local Obfuscator = {}
Obfuscator.VERSION = "2.1.0"
Obfuscator.WATERMARK = "This Script is Protected by Coriolis v2.1.0"

function Obfuscator.compile(source, opts)
    if type(source) ~= "string" then
        return false, "Input error: source must be a string"
    end
    opts = opts or {}
    local ok, protoOrError = ASTCompiler.compileSource(source, { name = opts.name or "CoriolisProtectedChunk" })
    if not ok then return false, tostring(protoOrError) end
    local valid, verifyError = Verifier.verify(protoOrError)
    if not valid then return false, "Bytecode verification failed: " .. tostring(verifyError) end
    return true, protoOrError
end

function Obfuscator.protect(source, opts)
    local ok, protoOrError = Obfuscator.compile(source, opts)
    if not ok then return false, protoOrError end
    local encoded, outputOrError = pcall(Encoder.encode, protoOrError, {
        watermark = Obfuscator.WATERMARK,
        signatureKey = 0,
        signature = Verifier.sign(protoOrError, 0),
    })
    if not encoded then return false, "Encoding error: " .. tostring(outputOrError) end
    return true, outputOrError, protoOrError
end

return Obfuscator
