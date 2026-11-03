---
title: 'C3 migration 22: complete builtin expressions and gate full frontend parity'
state: waiting
depends_on:
- c3-migration-21-port-initializers-function-bodies-and-statement
- c3-migration-12-generate-builtin-definitions-and-decode-builtin
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/parser_builtin.c3 and builtin_eval.c3; complete specialized builtin dispatch in expression/call parsing using Builtins.zig signatures and Builtins/eval.zig constant evaluation. Follow Parser.zig builtinBitCast/shufflevector/convertvector/chooseExpr/offsetofExpr and builtin call argument rules, varargs, overflow, type compatibility and constant predicates. Use target types and Value semantics, preserving unimplemented behavior where present. Audit the Parser/Tree/Compilation baseline inventory against C3 entries, close remaining frontend-only gaps and remove migration-only unsupported callbacks introduced in staged parsing. The feature-query tables from src/aro/features.zig must agree with reference behavior across options, including existing advertised-but-incomplete features.
Add test/migration/record_runner.c3 by porting test/record_runner.zig: MAPPING expansion, CPU/ABI/emulation flags, global exclusions, invalid-target rules and separate parse/layout/extra/offset expected-failure classification. Stage all test/records data in Bazel runfiles. Extend frontend_probe to accept necessary syntax test options without duplicating the future production driver. Add //test/migration:frontend_regression and :record_regression covering the entire frozen syntax/expansion inventory, and //test/c3:builtin_expression_tests. Run these plus all prior C3 tests. Counts must reconcile to baseline; preserve explicit known failures and flag unexpected passes for review rather than silently changing them. A green subset cannot satisfy this gate. Diagnostic and AST differences must be fixed or individually justified with evidence; no bulk golden regeneration. CLI-only coverage is owned by the later Driver ticket

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Produce the gap audit: compare the Parser/Tree/Compilation baseline inventory with the C3 entries and list every remaining unsupported callback.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **22.1 `builtin-parse`**: owns `src/c3/parser_builtin.c3`. bitCast/shufflevector/convertvector/chooseExpr/offsetof, builtin call argument rules, overflow builtins.
- **22.2 `builtin-eval`**: owns `src/c3/builtin_eval.c3`. Builtins/eval.zig constant evaluation and constant predicates.
- **22.3 `features`**: owns `src/c3/features.c3`. features.zig tables, matching the reference across options (including incomplete features it advertises).
- **22.4 `record-runner`**: owns `test/migration/record_runner.c3`. Port record_runner.zig: MAPPING expansion, flags, exclusions, failure classes; stage test/records in runfiles.
- **22.5 `gap-close`**: owns files named in the audit. Close the frontend gaps from the audit and remove migration-only unsupported callbacks.

**Stage 2: integrator (1 agent, serial).** Add `frontend_regression`, `record_regression` and `builtin_expression_tests`. Split reconciliation by fixture category, one parallel triage agent per category, each fixing or justifying its own diffs (no bulk golden regeneration). One agent then confirms the counts match the baseline.
