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
