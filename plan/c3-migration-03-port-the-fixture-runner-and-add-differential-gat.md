---
title: 'C3 migration 03 [Build & validation]: Port the fixture runner and add differential gates'
state: complete
depends_on:
- c3-migration-01-freeze-the-zig-reference-and-regression-inventor
- c3-migration-02-add-a-standalone-bazel-and-c3c-build-foundation
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19fa0-ccda-7ca2-9580-7ffc778d71ec
---

Add test/migration/runner.c3, runner_tests.c3, BUILD.bazel and per-stage case manifests; update test/README.MD with Bazel commands. Port Case, caseFromFile, trailingLines and runCaseExtra from test/runner.zig, preserving the actual behavior: source directory CWD, -fno-color-diagnostics, syntax flags -fsyntax-only --verbose-ast, expansion flags -E -P, args/environment handling, ordered diagnostic substring checks and exact AST/expanded output. expand_partial currently checks an expected-file suffix; follow the implementation rather than the README's conflicting description. compare_output remains explicitly counted as unsupported until separately implemented. Keep fixtures and expected files unchanged. Add modes that run a supplied Zig reference or C3 executable and report exit status, signal/crash, stdout, stderr, selected count, pass/fail and known skip counts. Treat a nonzero exit, signal, fatal diagnostic, or incomplete selected-case execution as a gate failure unless that exact case outcome is explicitly expected; do not let a final passed-count or non-matching `fatal error:` text mask a dying compiler. Compare complete outcomes to the baseline rather than silently accepting any nonzero exit. Capture child stdout and stderr through pipes (then write any logs after collection), never redirect stderr directly to a regular file, so diagnostics cannot be overwritten/garbled. Normalize only documented environmental paths/time inputs, never substantive diagnostics/AST. Support explicit per-stage case lists, fail on nonexistent entries or empty selection, and add a full-corpus mode rejecting unclassified cases. All fixtures/includes/AST files are Bazel data; writable files go in test temp directories. Acceptance: bazel test //test/migration:runner_tests tests all manifest kinds, malformed manifests, args/env and space-containing paths, absent goldens, mismatches, crashes and failure propagation using small fake child programs. Run //test/migration:reference_regression against the working reference and reconcile counts with baseline. Future port tickets add named parity targets through this harness.
