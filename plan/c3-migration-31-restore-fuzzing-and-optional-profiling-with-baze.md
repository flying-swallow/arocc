---
title: 'C3 migration 31 [Developer tooling]: restore fuzzing and optional profiling with Bazel'
state: waiting
depends_on:
- c3-migration-22-complete-builtin-expressions-and-gate-full-front
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add test/fuzz/fuzz_lib.c3 implementing the existing compile_c_buf C ABI from test/fuzz/fuzz_lib.zig, preserving isolated per-input compilation, bounded allocation behavior, ignored diagnostics and preprocess/parse/tree traversal. Reuse test/fuzz/main.c's AFL persistent harness through a declared optional AFL/C toolchain; validate signed length bounds before slicing. Add a standalone C3 replay runner for deterministic corpus tests without AFL. Add src/c3/tracy.c3 mirroring src/aro/tracy.zig's disabled no-op path and optional C ABI bindings/zones/allocation/callstack flags; wire corresponding build options and preserve licensing. Keep optional native profiling/fuzz dependencies out of default builds.
Add test/fuzz/BUILD.bazel, regression seeds and test/c3/profiling_tests.c3. Run bazel test //test/fuzz:replay_test //test/c3:profiling_tests with valid/malformed fixtures, embedded NUL, recursive macros, deep declarations and repeated inputs; enforce bounded execution and verify state/allocator reset. Build //test/fuzz:afl_fuzz when the declared AFL toolchain is present, and perform a bounded smoke run recording seed/time budget. Demonstrate actual instrumentation capability on C3 code with the pinned compiler; if unsupported, report that limitation rather than claiming the C harness alone gives full coverage. Default CI must still run replay. Test enabled profiling with a small declared stub C client validating ABI/linkage, plus disabled builds requiring no Tracy library

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the replay runner interface and the build flags for fuzz/tracy (default off).

**Stage 1: parallel agents (start together after stage 0 merges).**
- **31.1 `fuzz-lib`**: owns `test/fuzz/fuzz_lib.c3`, replay runner. compile_c_buf ABI, signed length checks, per-input isolation.
- **31.2 `afl`**: owns `test/fuzz/BUILD.bazel` AFL toolchain. Optional `afl_fuzz` target, bounded smoke run, instrumentation capability report.
- **31.3 `tracy`**: owns `src/c3/tracy.c3`, build options. Disabled no-op path, optional bindings, zones/alloc/callstack.
- **31.4 `profiling-tests`**: owns `test/c3/profiling_tests.c3`, stub C client. Enabled ABI/link check and disabled builds without Tracy.
- **31.5 `seeds`**: owns regression seeds. Corpus: NUL bytes, recursive macros, deep declarations, repeated inputs.

**Stage 2: integrator (1 agent, serial).** Run `//test/fuzz:replay_test` and `//test/c3:profiling_tests`, and make sure default CI runs replay.
