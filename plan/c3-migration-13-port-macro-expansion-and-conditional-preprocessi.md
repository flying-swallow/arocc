---
title: 'C3 migration 13 [Preprocessor]: port macro expansion and conditional preprocessing'
state: complete
depends_on:
- c3-migration-03-port-the-fixture-runner-and-add-differential-gat
- c3-migration-05-port-diagnostic-state-and-rendering
- c3-migration-06-port-language-modes-unicode-tables-and-tokenizer
- c3-migration-11-port-numeric-and-text-literal-decoding
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Implement the in-memory preprocessor in new src/c3/preprocessor.c3, hideset.c3, pp_expression.c3, tokens.c3 and test/c3/preprocessor_tests.c3; wire explicit Bazel sources. Port Preprocessor.zig init/deinit, define/defineFn, collectMacroFuncArguments, expandMacroExhaustive, stringify, pasteTokens, expandVaOpt, conditional directive dispatch/skip, line/error/warning directives and prettyPrintTokens. Preserve Hideset.zig union/intersection and Tree.zig Token/TokenWithExpansionLocs ownership, expansion flags, bounded location chains and generated-buffer offsets; tokens belong in a shared module so AST integration need not be a prerequisite. Port Preprocessor/Parser.zig's signed/unsigned intmax expression rules, precedence and short-circuit diagnostics using the value primitives; preserve its current 64-bit intmax restriction explicitly. Port relevant Preprocessor/Diagnostic.zig records to the diagnostic API. File lookup and target builtin macro providers get explicit interfaces completed by later tickets; they must return an unsupported error until implemented, not silently succeed.
Add test/migration/pp_probe.c3 with a narrow in-memory preprocessing CLI for the migration runner, plus a curated fixture list. Run bazel test //test/c3:preprocessor_tests and //test/migration:macro_regression. Include recursive call non-expanded parens.c and nested #ifs.c, self/mutual recursion, nested function arguments, empty arguments/placemarkers, variadics/__VA_OPT__, stringify escaping, invalid paste, inactive branches and unterminated conditionals. Compare tokens, expansion locations, rendered output and diagnostics to the frozen reference. Negative tests must terminate and free token expansions. This step does not need a full C parser or production CLI

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Create the shared `src/c3/tokens.c3` (Token, TokenWithExpansionLocs, expansion flags, location chains) and the preprocessor struct/provider interfaces in `preprocessor.c3`. File lookup and builtin-macro providers return `unsupported`.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **13.1 `hideset`**: owns `src/c3/hideset.c3`. Hideset union/intersection with ownership tests.
- **13.2 `pp-expr`**: owns `src/c3/pp_expression.c3`. Preprocessor/Parser.zig: signed/unsigned intmax rules, precedence, short-circuit diagnostics, explicit 64-bit intmax limit.
- **13.3 `expansion`**: owns `src/c3/macro_expand.c3`. define/defineFn, collectMacroFuncArguments, expandMacroExhaustive, __VA_OPT__, placemarkers, recursion blocking.
- **13.4 `stringify-paste`**: owns `src/c3/macro_paste.c3`. stringify escaping, pasteTokens, invalid paste diagnostics, generated-buffer offsets.
- **13.5 `directives`**: owns `src/c3/pp_directives.c3`. Conditional dispatch/skip, #line/#error/#warning, unterminated conditionals; Preprocessor/Diagnostic.zig records.
- **13.6 `probe`**: owns `src/c3/pp_print.c3`, `test/migration/pp_probe.c3`, macro fixture list. prettyPrintTokens, in-memory probe CLI, curated fixture list for `macro_regression`.

**Stage 2: integrator (1 agent, serial).** Assemble the preprocessor main loop, write `test/c3/preprocessor_tests.c3`, register targets, run `//test/c3:preprocessor_tests` and `//test/migration:macro_regression`, and check that negative tests free their expansions.

## Completion notes

- Ported across `tokens.c3`, `preprocessor.c3`, `pp_diagnostics.c3`, `hideset.c3`, `pp_expression.c3`, `macro_expand.c3`, `macro_paste.c3`, `pp_directives.c3` and `pp_print.c3`. The unit test targets are `hideset_tests`, `pp_expression_tests`, `macro_expand_tests` (+ `macro_expand_manual_tests`), `macro_paste_tests`, `pp_directives_tests`, `pp_print_tests` and `pp_contract_tests`.
- `//test/migration:macro_regression` runs 61 `test/cases` expand fixtures through `test/migration/pp_probe` in normal fixture mode. All 61 pass. It uses the fixtures' own goldens; no Zig executable was run.
- `#include`, `#include_next`, `#embed`, `#pragma` and builtin macros report an explicit "not supported yet by the C3 port" error until plans 14 and 15 replace the providers.
