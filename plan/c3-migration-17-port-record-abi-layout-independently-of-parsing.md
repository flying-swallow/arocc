---
title: 'C3 migration 17 [Types & ABI]: port record ABI layout independently of parsing'
state: waiting
depends_on:
- c3-migration-16-port-ast-storage-attributes-and-symbol-scopes
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/record_layout.c3 and test/c3/record_layout_tests.c3. Port src/aro/record_layout.zig compute, checked alignment arithmetic, SysVContext, MinGW rules, MsvcContext and msvcPragmaPack. Consume explicit target policies, TypeStore records/field types and AttributeMap alignment/packed metadata, with source diagnostics at the caller boundary. Preserve distinct size, field alignment, pointer alignment, required alignment and bit offsets. Do not use host C3 sizeof/alignment to infer target C layouts; retain original MIT attribution.
Exercise hand-built records so no parser is required: ordinary/nested structs and unions, empty records, flexible arrays, packed/aligned combinations, zero/nonzero/unnamed bitfields, adjacent storage units and overflow. Use named regression examples corresponding to record_layout's references to records 0023/0028/0029/0056/0057/0068. Add target-parametrized reference vectors collected with the frozen Zig tool (development-only export helper under test/migration if needed). Run bazel test //test/c3:record_layout_tests for SysV, MinGW and MSVC target families, verifying every layout field, not just sizeof. Full test/records source parsing is a later integration gate

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the layout input/output records: target policy, field list from TypeStore, AttributeMap metadata, and the result fields for size, field/pointer/required alignment and bit offsets.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **17.1 `sysv`**: owns `src/c3/record_layout.c3` (compute + SysV). compute entry, checked alignment arithmetic, SysVContext, bitfield storage units.
- **17.2 `mingw`**: owns `src/c3/record_layout_mingw.c3`. MinGW-specific rules.
- **17.3 `msvc`**: owns `src/c3/record_layout_msvc.c3`. MsvcContext and msvcPragmaPack.
- **17.4 `vectors`**: owns `test/migration/layout_probe.zig`, `test/c3/data/record_layout/*`. Target-parametrized reference vectors including records 0023/0028/0029/0056/0057/0068.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/record_layout_tests.c3` with hand-built records checking every layout field for each family, register the target, and keep the MIT attribution.
