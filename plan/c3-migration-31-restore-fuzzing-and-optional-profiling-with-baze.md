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
