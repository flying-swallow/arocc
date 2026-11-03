---
title: 'C3 migration 14 [Preprocessor]: port predefined macros and builtin preprocessor queries'
state: waiting
depends_on:
- c3-migration-07-replace-zig-target-metadata-with-explicit-c3-tar
- c3-migration-08-port-type-representation-and-qualified-type-oper
- c3-migration-12-generate-builtin-definitions-and-decode-builtin
- c3-migration-13-port-macro-expansion-and-conditional-preprocessi
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/predefined_macros.c3 and test/c3/predefined_macro_tests.c3; extend preprocessor.c3 providers and migration pp_probe and fixture list. Translate Compilation.zig generateSystemDefines, generateBuiltinMacros, writeBuiltinMacros and floating limit macro helpers using explicit Target metadata and named TypeStore types. Cover all target branches inventoried in the Zig baseline, language standard/emulation, endian/width/float/ABI/CPU feature defines, hosted/freestanding and system-defines modes. Port Preprocessor.zig addBuiltinMacros and expandBuiltinMacro: deterministic clock/source epoch, FILE/LINE/COUNTER/base file/include level and has-attribute/feature/extension/builtin/target queries. Preserve prefix replacement and invalid SOURCE_DATE_EPOCH diagnostics. Include filesystem query dispatch contracts; include/embed answers are supplied by the file-services step, not fabricated here.
Run bazel test //test/c3:predefined_macro_tests and //test/migration:predefined_macro_regression. Generate differential macro inventories for representative supported target/ABI/feature combinations, all language modes, and boundary floating values from the pinned Zig executable. Fix clock, source path and version inputs so only deliberately documented version text differs. Assert target selection changes results independent of the host, and invalid/unsupported targets fail explicitly. Extend the probe's documented options only as needed; don't implement Driver here

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
