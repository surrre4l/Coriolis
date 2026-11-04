# Coriolis v2.1.0

Coriolis is a custom Luau source compiler and register-based Proto VM intended for legitimate Roblox Studio workflows. Its Proto format is Coriolis-specific; it is **not** Roblox's native Luau bytecode.

## Current implementation status

| Component | Status |
|---|---|
| Lexer / Parser | Existing uploaded modules retained |
| ASTCompiler | Existing compiler retained; terminology corrected |
| Assembler | Existing assembler retained |
| LuauVM | Register-based VM selected as canonical runtime |
| BytecodeVerifier | Existing verifier retained and hardened for malformed metadata; removed an invalid `OP.PCALL` entry that referenced a nonexistent opcode |
| Encoder | Added Proto-to-Luau source encoder |
| Obfuscator | Added compile → verify → encode orchestration |
| Roblox Studio runtime | ModuleScript deployment model documented |
| Web UI | Responsive editor UI included |
| Render Web Service | UI/API shell included; compiler adapter is intentionally disabled (503) until a real Luau-host bridge is implemented and tested |
| Automated tests | 28 cases included; **not executed in this environment** |

This package is an integration baseline, not a claim of complete Luau compatibility or completed Render-side compilation.

## Roblox Studio installation

1. Create a Folder or Rojo package named `Coriolis` in `ReplicatedStorage` or `ServerStorage`.
2. Put every `.lua` file from `engine/` into that package as a ModuleScript. `init.lua` is the package facade when using Rojo's `init.lua` convention.
3. Require `engine.Obfuscator` from a trusted server-side Script or Studio plugin.
4. Call `Obfuscator.protect(source)`. It returns `true, protectedSource, proto` or `false, errorMessage`.
5. Place the generated Script/ModuleScript beside `LuauVM` and `BytecodeVerifier`, because generated code requires those sibling modules.

Example:

```lua
local Obfuscator = require(game:GetService("ReplicatedStorage").Coriolis.Obfuscator)
local ok, outputOrError = Obfuscator.protect([[
    local total = 1 + 2
    print(total)
]])

if not ok then
    warn(outputOrError)
    return
end

print(outputOrError)
```

`Encoder.encode(proto)` is also available after a successful compiler and verifier pass.

## Pipeline

`Luau source → Parser (Lexer internally) → ASTCompiler (Assembler) → BytecodeVerifier → Encoder → protected Luau output`

The generated output validates the serialized Proto before loading it into `LuauVM`. The runtime dependencies are the Coriolis `LuauVM` and `BytecodeVerifier` ModuleScripts.

## Integrity model

- Structural verification checks opcode membership, operand shape/ranges, jump bounds, prototype metadata, and upvalue descriptor shape.
- A deterministic rolling checksum detects accidental or unsophisticated edits to the emitted Proto literal.
- The checksum is **not cryptographic**, is not a digital signature, and cannot prevent a determined attacker from modifying both code and check.
- Do not treat obfuscation as a substitute for server-side authorization, secret management, or validating RemoteEvent/RemoteFunction input.
- No executor globals, hook APIs, traceback traps, anti-debugging sabotage, or decryption command are used.

## Compatibility and known limitations

The parser accepts a wider Luau-like surface than the bytecode compiler. Acceptance by the parser does not mean compilation support.

The checked-in AST compiler's own test suite explicitly marks these constructs unsupported:
- Floor division (`//`) and compound floor division (`//=`).
- Bare `return ...`.
- A trailing multi-value call argument in an expression list.

The compiler is not a complete implementation of all Luau features. Type syntax is erased by the parser before code generation. Roblox-specific APIs are host globals and must be available in the execution environment. The VM only exposes globals supplied in its environment; generated output uses the current script environment where `getfenv(0)` is available and falls back to `_G`.

The uploaded `LuauVM.lua.txt` is a separate AST interpreter with its own parser/serializer, not the register VM. `CoriolisBytecodeVM.lua` is a second independent prototype with a different instruction representation. Both are preserved under `reference/` for review and are not mixed into the canonical pipeline.

## Tests

Open `tests/ASTCompiler.spec.lua` in Roblox Studio and run:

```lua
require(path.to.Coriolis.tests.ASTCompiler.spec).run()
```

The suite reports a PASS/FAIL line for each case. It covers arithmetic, locals/globals, branches, loops, tables, strings/interpolation, functions, closures, varargs, multiple returns, and expected unsupported cases. It does not establish Roblox runtime behavior until run in Studio. Add integration tests for actual generated Script execution before production use.

## Web interface / Render

`public/index.html` provides the responsive editor, upload, output, copy, and download controls. `server/index.js` serves it and exposes `/api/health` and `/api/protect`.

**Important:** `/api/protect` currently returns HTTP 503 by design. Node.js does not execute Luau, and the uploaded engine is a Roblox ModuleScript tree using `script.Parent` module resolution. A production Render compiler needs a real Luau execution host plus a tested module loader/adapter that invokes these exact engine files. The included Render service is therefore a UI shell, not a functioning hosted compiler. Do not advertise web protection as working until that adapter exists and the full test suite passes against it.

## Watermark

Every generated output begins with the exact comment watermark:

`This Script is Protected by Coriolis v2.1.0`
