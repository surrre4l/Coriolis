--!nonstrict
-- Produces Roblox Studio Luau source. Generated code expects LuauVM and
-- BytecodeVerifier ModuleScripts beside the generated Script/ModuleScript.
local Encoder = {}
local function quote(s)
    return '"' .. (string.gsub(s, '[%z\1-\31\\"]', function(c)
        local map = { ['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n',
            ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
        return map[c] or string.format("\\%03d", string.byte(c))
    end)) .. '"'
end
local function literal(v, seen)
    local t = type(v)
    if t == "nil" then return "nil"
    elseif t == "boolean" or t == "number" then
        if t == "number" and (v ~= v or v == math.huge or v == -math.huge) then
            error("non-finite numeric constant is not encodable")
        end
        return tostring(v)
    elseif t == "string" then return quote(v)
    elseif t == "table" then
        if seen[v] then error("cyclic table in Proto") end
        seen[v] = true
        local parts = {}
        for k, value in pairs(v) do
            local key
            if type(k) == "number" and k >= 1 and k % 1 == 0 then key = "[" .. k .. "]"
            elseif type(k) == "string" then key = "[" .. quote(k) .. "]"
            else error("unsupported Proto table key type: " .. type(k)) end
            parts[#parts+1] = key .. "=" .. literal(value, seen)
        end
        seen[v] = nil
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("unsupported Proto value type: " .. t)
end
function Encoder.encode(proto, opts)
    opts = opts or {}
    local payload = literal(proto, {})
    local signature = opts.signature
    local signatureKey = opts.signatureKey or 0
    assert(type(signature) == "number", "Encoder requires a verifier signature for the Proto")
    local watermark = opts.watermark or "This Script is Protected by Coriolis v2.1.0"
    return table.concat({
        "-- " .. watermark,
        "local __CoriolisVM = require(script.Parent:WaitForChild('LuauVM'))",
        "local __CoriolisVerifier = require(script.Parent:WaitForChild('BytecodeVerifier'))",
        "local __proto = " .. payload,
        "local __signature = " .. tostring(signature),
        "local __signatureKey = " .. tostring(signatureKey),
        "if not __CoriolisVerifier.check(__proto, __signatureKey, __signature) then error('Coriolis integrity check failed', 0) end",
        "local __ok, __why = __CoriolisVerifier.verify(__proto)",
        "if not __ok then error('Coriolis Proto rejected: '..tostring(__why), 0) end",
        "local __env = (getfenv and getfenv(0)) or _G",
        "local __vm = __CoriolisVM.new(__env)",
        "return __vm:load(__proto, " .. quote(proto.name or "CoriolisProtectedChunk") .. ")()",
        "",
    }, "\n")
end
return Encoder
