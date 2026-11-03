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
