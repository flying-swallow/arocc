---
title: 'C3 migration 13 [Preprocessor]: port macro expansion and conditional preprocessing'
state: waiting
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
