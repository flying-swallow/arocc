---
title: 'C3 migration 28 [Code generation]: port the existing x86-64 assembly data emitter'
state: waiting
depends_on:
- c3-migration-22-complete-builtin-expressions-and-gate-full-front
- c3-migration-25-port-command-line-parsing-and-the-frontend-execu
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/backend/assembly.c3 and assembly_x86_64.c3; expose genAsm dispatch equivalent to src/assembly_backend.zig. Port backend/Assembly.zig owned text/data buffers and write behavior plus assembly_backend/x86_64.zig serializeInt/serializeFloat/emitSingleValue/genDecls/genVar. Preserve linkage, common/tentative storage, TLS/data sections, alignment, debug file directives and zero fill. Serialize floating bit representations from the C3 numeric layer, including padded f80 and f128, without host-memory assumptions. genFn currently emits TODO Codegen functions and aggregates also fail: retain these limitations with clear error tests. Non-x86-64 dispatch must not claim support.
Add test/c3/assembly_tests.c3 and a migration fixture list covering supported data-only translation units. Run bazel test //test/c3:assembly_tests //test/migration:assembly_regression. Compare assembly text to Zig for integer/floating globals, tentative arrays, static/common/TLS declarations and option combinations, and expected failure for functions/aggregates. On the native supported CI host, assemble data-only output using a declared assembler and inspect symbol/section data. This tests the existing emitter rather than adding a new function code generator

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
