---
title: 'C3 migration 15 [Preprocessor]: port includes, embed, pragma lifecycle and dependency files'
state: waiting
depends_on:
- c3-migration-14-port-predefined-macros-and-builtin-preprocessor
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/include_search.c3, dep_file.c3, pragma.c3, pragmas/{gcc,once,message,pack}.c3 and corresponding test/c3 tests; connect Compilation storage, preprocessor and pp_probe. Follow Compilation.zig initSearchPath/removeDuplicateSearchPaths/FindInclude/findInclude/findEmbed and Preprocessor.zig include/embed/findIncludeGuard/pragma. Preserve quote/normal/system/after/framework ordering, include_next, MS search behavior, source reuse, maximum nesting, file errors and embed limit/dependency behavior. Port DepFile.zig deduplication, Make/NMake quoting, wrapping and stdin exclusion. Port Pragma.zig callbacks and the four existing handlers, including GCC diagnostic state save/reset between preprocessing and parsing and once state lifetime. Implement pack as a tested state machine and a parser callback adapter interface; full parser wiring belongs to parser integration. Preserve pragma tokens and expansion-control decisions.
Add temp-directory fixtures and explicit runfiles (never depend on sibling project or incidental host include paths). Run bazel test //test/c3:include_tests //test/c3:pragma_tests //test/c3:dep_file_tests and //test/migration:preprocessor_regression. The latter runs the full baseline's preprocessing categories through the probe, including include/framework/embed, builtin file queries, missing files, include cycles, line markers and pragma EOF. Test repeated translation units to catch leaked state and byte-for-byte dependency output. Any remaining baseline skip stays visible and unchanged. Syntax-dependent pragma effects are deferred explicitly to parser tests, not counted as passing here

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
