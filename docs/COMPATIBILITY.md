# Compatibility and verification notes

The source suite documents the supported test cases and expected unsupported cases. The parser and compiler are not equivalent to the full Roblox Luau compiler.

## VM contract

Canonical VM: `engine/LuauVM.lua`

- Register-based instructions `{ op, a, b, c }`
- 0-based register and constant operands in the Proto model
- Negative RK values encode constants as `-(constantIndex + 1)`
- Nested closures use `protos` and upvalue descriptors
- `Assembler.lua` and `BytecodeVerifier.lua` import the opcode table from this VM

The VM is a custom interpreter. It does not load or execute official Roblox Luau bytecode.

## Review findings

1. The uploaded verifier declared `[OP.PCALL]` even though `LuauVM.OP` has no `PCALL` member. In Luau, a nil table key in a table constructor can prevent the verifier module from loading. The invalid shape entry was removed. Ordinary `pcall` remains a host function callable through the VM environment.
2. The compiler's comments called the custom Proto format `ProtoVM`; comments were corrected to distinguish it from official Luau bytecode and the canonical runtime name.
3. The second uploaded `LuauVM.lua.txt` is a separate AST interpreter and includes a second lexer/parser plus blob serialization. It is not compatible with the register Proto contract, so it is retained as a reference only.
4. `CoriolisBytecodeVM.lua` is a separate experimental compiler/VM with another opcode representation. It is retained as a reference only.
5. `obscuraat.txt` contains executor-specific environment access (`getgenv`), environment mutation, anti-inspection behavior, and obfuscated runtime checks. It is not included in the legitimate Studio integrity path.

## What the verifier does not prove

Structural validation does not sandbox arbitrary host functions or establish semantic correctness. A rolling hash is not a cryptographic signature. Treat all user-supplied source as untrusted and expose only a deliberate environment allowlist when executing untrusted code.
