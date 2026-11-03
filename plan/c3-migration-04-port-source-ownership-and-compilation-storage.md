---
title: 'C3 migration 04 [Core runtime]: Port source ownership and compilation storage'
state: waiting
depends_on:
- c3-migration-02-add-a-standalone-bazel-and-c3c-build-foundation
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19f98-b90f-7d20-a857-cb32debe7887
---

Add src/c3/source.c3, string_interner.c3, compilation.c3 and test/c3/source_tests.c3; register //test/c3:source_tests. Port src/aro/Source.zig and StringInterner.zig plus Compilation.zig init/deinit, getSource, addSourceFromOwnedBuffer/addSourceFromBuffer and alias storage. Retain stable source/string IDs and generated/unused/empty sentinels, owned zero-terminated source buffers, borrowed interner key lifetime, source kinds, and original splice offsets. Establish the shared C3 allocation/fault conventions and a minimal compilation context extendable by later tickets; keep source normalization diagnostics as structured pending events until diagnostic rendering lands. Reproduce BOM stripping, CR/CRLF normalization, repeated backslash-newline splices, location expansion and Unicode display widths, including invalid UTF8. Port the exhaustive carriage-return and BOM tests at Compilation.zig:2899 onward, add intern stability, source aliases and repeated create/destroy tests with tracked allocations or equivalent. No lexer, filesystem search or full Compilation implementation yet. Acceptance: bazel test //test/c3:source_tests in dbg and opt, normalized bytes/location assertions and no dangling slices after container growth. Keep Zig originals unchanged

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
