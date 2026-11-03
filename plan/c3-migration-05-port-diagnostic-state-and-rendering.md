---
title: 'C3 migration 05 [Core runtime]: Port diagnostic state and rendering'
state: complete
depends_on:
- c3-migration-04-port-source-ownership-and-compilation-storage
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19fa9-2335-7680-af86-7f09e2f48c25
---

Add src/c3/diagnostics.c3 and test/c3/diagnostics_tests.c3, register //test/c3:diagnostics_tests and connect source normalization events. Follow src/aro/Diagnostics.zig Message/Option/State, effectiveKind, set, add/addWithLocation and Message.write. Replace comptime formatting/reflection with explicit C3 message templates and argument handling, preserving warning groups, -w/-Werror/-Wfatal-errors/pedantic precedence, system-header suppression, hidden notes and macro-backtrace limits. Support ignore, collected-list and writer output with well-defined ownership and fatal-error propagation. Source locations use the source module, never host byte columns for UTF8 text. This ticket owns core machinery; phase-specific message tables are ported with their callers. Acceptance: bazel test //test/c3:diagnostics_tests with ordered multi-message goldens for Unicode/spliced locations, macro backtrace truncation, warnings disabled then promoted, unknown options, color off and color reset; allocation cleanup on error and output failures. Preserve diagnostic text and option suffixes so existing fixture expectations remain usable

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
