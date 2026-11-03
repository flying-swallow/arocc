---
title: 'C3 migration 25 [Driver & toolchains]: port command-line parsing and the frontend executable'
state: waiting
depends_on:
- c3-migration-24-port-toolchain-include-paths-and-linker-command
- c3-migration-22-complete-builtin-expressions-and-gate-full-front
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/driver.c3, driver_options.c3 and codegen_options.c3; replace app/aro_c3/main.c3 (the initial smoke executable's //:aro_c3 entry) with the real frontend, while keeping reusable driver modules under src/c3. Port Driver.zig parseArgs/parseTarget/getPICMode, usage/version, frontend portions of main/processSource, dependency filenames/output handling/diagnostic statistics and src/main.zig lifetime/error setup. Translate backend/CodeGenOptions.zig option values even before backend execution is connected. Preserve option ordering, attached/separate arguments, -D/-U, environment, -target/-mcpu, language/emulation, warnings, macro dumps, stdin, multiple files, -E/-P/-fsyntax-only/--verbose-ast and exit status. Delegate include/link discovery to Toolchain, not the test probe. Expose backend invocation interfaces with explicit unavailable failures until the backend integration ticket; never emit an empty successful object.
Add test/c3/driver_options_tests.c3 and test/migration/cli_tests.c3 with fake child tools and temp outputs. Run bazel test //test/c3:driver_options_tests //test/migration:cli_tests and rerun full frontend/record regression using the real executable instead of frontend_probe. Check help/version, unknown/missing arguments, target/PIC combinations, output failures, dependency escaping, multiple translation-unit state reset and stdout/stderr/status parity. Refactor test adapter argument handling to reuse the driver where practical; preserve the direct library tests.

List test/c3/driver_options_tests.c3 explicitly in project.json for its //test/c3 target: c3c does not expand `dir/*.c3` source entries. Keep `src/c3/**` for the library sources so the app-only `fn main` cannot enter aro_c3_lib or build_smoke.
