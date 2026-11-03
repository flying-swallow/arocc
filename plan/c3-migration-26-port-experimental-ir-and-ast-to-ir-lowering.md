---
title: 'C3 migration 26 [Code generation]: port experimental IR and AST-to-IR lowering'
state: waiting
depends_on:
- c3-migration-22-complete-builtin-expressions-and-gate-full-front
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/backend/ir.c3, ir_renderer.c3 and codegen.c3 with test/c3/ir_tests.c3. Port backend/Ir.zig declarations, Builder function/block lifecycle, references/instruction payloads, labels/phi/calls/allocations and textual dump using the existing C3 value/type interner. Translate aro/CodeGen.zig genIr/genType/genFn/genVar and implemented node lowering, including cached records, symbol scopes, branch/loop/switch state and diagnostics. Preserve current TODO/fatal boundaries for union/complex/atomic/block/VLA/bitfield lowering and other unsupported nodes. Port backend/Ir/x86/Renderer.zig's current function-lowering failure as an explicit tested failure; this migration does not implement machine instruction lowering. Keep object-emission interface separate until the object step lands.
Run bazel test //test/c3:ir_tests. Test Builder ownership across multiple functions, stable references, block terminators and phi operands, and differential IR dumps from representative supported ASTs. Include negative tests for each existing unsupported family. Expose a test-only IR probe if the old CLI aborts after dumping IR, comparing the dump independently from its expected backend failure. Do not require hello-world executable output: this source's x86 Renderer currently reports TODO implement lowering functions

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Settle the IR data model (refs, instruction payloads, blocks) on top of the existing C3 value/type interner.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **26.1 `ir-builder`**: owns `src/c3/backend/ir.c3`. Declarations, Builder function/block lifecycle, labels/phi/calls/allocations.
- **26.2 `renderer`**: owns `src/c3/backend/ir_renderer.c3`. Textual dump; x86 Renderer's explicit lowering failure.
- **26.3 `codegen-decls`**: owns `src/c3/codegen.c3` (genIr/genType/genFn/genVar). Top-level lowering, cached records, symbol scopes.
- **26.4 `codegen-nodes`**: owns `src/c3/codegen_nodes.c3`. Node lowering for expressions and branch/loop/switch, plus explicit TODO failures for unsupported families.
- **26.5 `probe`**: owns IR probe + goldens. Test-only IR dump probe and reference dumps.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/ir_tests.c3` including negative tests for each unsupported family, and register the target.
