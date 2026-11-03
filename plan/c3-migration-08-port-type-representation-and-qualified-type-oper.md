---
title: 'C3 migration 08 [Types & ABI]: Port type representation and qualified type operations'
state: waiting
depends_on:
- c3-migration-07-replace-zig-target-metadata-with-explicit-c3-tar
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a1a1dc-3140-7cf3-9e54-62aece9a8227
---

Add src/c3/type_store.c3 and test/c3/type_store_tests.c3; extend compilation storage and register //test/c3:type_store_tests. Follow src/aro/TypeStore.zig Repr/Index/QualType/Type, put/putExtra/set, base/get/childType, equality, promotions, rank, decay, sizeofOrNull/alignof and type printing. Preserve invalid/auto/incomplete distinctions, qualifiers, attributed wrappers, arrays/VLAs/functions/pointers, atomic/vector/complex/_BitInt types and mutable completion of forward record/enum declarations. Use stable indexed handles and explicit tagged records instead of exposing C3 pointers as type identity. Port initNamedTypes/generateVaListType against explicit C3 target data; store record layout results but defer layout computation and parser-coupled Builder specifier diagnostics to their own steps. Add necessary attribute metadata slots without implementing parser syntax. Acceptance: bazel test //test/c3:type_store_tests covering canonical builtins, qualified equality, recursive declarations, array/function decay, integer promotions, ABI-specific named/va_list types, incomplete size behavior and type-print goldens; force container growth to verify handle stability. Do not use host sizeof for C target layout

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Write `src/c3/type_store.c3` skeleton: `Repr`/`Index`/`QualType`/`Type` tagged records, stable handle types, signatures for put/putExtra/set/base/get/childType, empty attribute-metadata and record-layout-result slots. Compiles, functions return `unsupported` faults.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **08.1 `storage`**: owns `src/c3/type_store.c3` (storage functions only). put/putExtra/set/base/get/childType, extra arrays, mutable completion of forward record/enum declarations, handle stability under forced growth.
- **08.2 `relations`**: owns `src/c3/type_store_relations.c3`. Qualified equality, integer promotions, rank, array/function decay, usual arithmetic conversions; invalid/auto/incomplete distinctions.
- **08.3 `size-align`**: owns `src/c3/type_store_layout.c3`. sizeofOrNull/alignof from explicit target data (never host sizeof); incomplete/VLA/_BitInt/vector/complex sizes; reads stored record-layout results.
- **08.4 `printing`**: owns `src/c3/type_print.c3`. Type printing including qualifiers, attributed wrappers, function/pointer/array nesting.
- **08.5 `named-types`**: owns `src/c3/type_store_named.c3`. initNamedTypes and generateVaListType per ABI using target_data.c3.
- **08.6 `vectors`**: owns `test/migration/type_probe.zig`, `test/c3/data/type_store/*`. Dev-only pinned-Zig probe that dumps type-print strings, sizes/aligns and named/va_list types per target; check in generated goldens.

**Stage 2: integrator (1 agent, serial).** Extend compilation storage, write `test/c3/type_store_tests.c3` from the goldens, register `//test/c3:type_store_tests` in BUILD.bazel/project.json, run dbg+opt.
