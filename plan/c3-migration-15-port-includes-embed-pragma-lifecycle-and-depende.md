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


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the include-search, dependency-recorder and pragma-handler interfaces used by the preprocessor and Compilation.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **15.1 `search`**: owns `src/c3/include_search.c3`. initSearchPath, removeDuplicateSearchPaths, findInclude/findEmbed, quote/system/after/framework ordering, include_next, MS behavior.
- **15.2 `pp-include`**: owns `src/c3/pp_include.c3`. Preprocessor include/embed, include-guard detection, source reuse, max nesting, file errors, embed limits.
- **15.3 `depfile`**: owns `src/c3/dep_file.c3`, `test/c3/dep_file_tests.c3`. Deduplication, Make/NMake quoting, wrapping, stdin exclusion; byte-for-byte tests.
- **15.4 `pragmas`**: owns `src/c3/pragma.c3`, `src/c3/pragmas/{gcc,once,message}.c3`. Pragma callbacks, GCC diagnostic save/reset, once lifetime, message.
- **15.5 `pack`**: owns `src/c3/pragmas/pack.c3`. Pack state machine and parser callback adapter interface, tested standalone.
- **15.6 `fixtures`**: owns temp-dir fixtures, `test/c3/{include,pragma}_tests.c3`. Runfiles-only include trees (no host include paths), cycle/missing/line-marker/pragma-EOF cases, repeated-TU leak tests.

**Stage 2: integrator (1 agent, serial).** Connect pp_probe, register the three test targets, run `//test/migration:preprocessor_regression` over the full preprocessing categories, and keep remaining skips visible.
