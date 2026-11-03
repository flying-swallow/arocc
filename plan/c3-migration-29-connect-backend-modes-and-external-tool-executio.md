---
title: 'C3 migration 29 [Driver & toolchains]: connect backend modes and external tool execution'
state: waiting
depends_on:
- c3-migration-25-port-command-line-parsing-and-the-frontend-execu
- c3-migration-27-port-elf-object-serialization-without-zig-stdlib
- c3-migration-28-port-the-existing-x86-64-assembly-data-emitter
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Complete src/c3/driver.c3 backend portions following Driver.zig processSource/invokeAssembler/invokeLinker/getRandomFilename/exitWithCleanup. Connect CodeGen IR dump/render/object writing and the x86-64 assembly emitter, preserving the reference's x86-64 ELF guard, -S/-c/link behavior, output naming, verbose linker args, subprocess status/diagnostics and temporary file cleanup. Use structured argv and the tested Toolchain paths; preserve input object files and clean only temporaries created by this invocation. Keep unsupported codegen diagnostics visible. No new function lowering or linker implementation is in scope.
Extend test/migration/cli_tests.c3 and add //test/migration:backend_cli_regression. Use fake assembler/linker processes for argv, inherited I/O, failure/signal handling, paths with spaces and cleanup tests; test frontend errors prevent subprocess launches. Compare supported data-only compile/assembly paths and unsupported function/target paths with the frozen Zig executable. On native Linux x86-64, assemble a supported data-only object and link it with a tiny separately compiled C consumer to verify emitted symbol contents; declare the external C toolchain. Run bazel test //test/migration:cli_tests //test/migration:backend_cli_regression and all frontend regressions. Document pre-existing experimental failures separately from migration failures.


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the structured argv and temp-file ownership model for one driver invocation.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **29.1 `subprocess`**: owns `src/c3/driver_exec.c3`. invokeAssembler/invokeLinker, inherited I/O, status/signal diagnostics.
- **29.2 `tempfiles`**: owns `src/c3/driver_tempfiles.c3`. getRandomFilename, exitWithCleanup, removes only temporaries this invocation created.
- **29.3 `modes`**: owns `src/c3/driver.c3` backend section. -S/-c/link modes, x86-64 ELF guard, output naming, IR dump/object/asm wiring.
- **29.4 `tests`**: owns `test/migration/cli_tests.c3` extensions. Fake assembler/linker, paths with spaces, frontend errors prevent launches.
- **29.5 `native`**: owns `backend_cli_regression` target. Zig differential plus a native Linux x86-64 assemble+link check with a declared C toolchain.

**Stage 2: integrator (1 agent, serial).** Run all CLI and frontend regressions, and document pre-existing experimental failures separately from migration failures.
