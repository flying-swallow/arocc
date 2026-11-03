---
title: 'C3 migration 21 [AST & parser]: port initializers, function bodies and statement control flow'
state: waiting
depends_on:
- c3-migration-20-port-attribute-semantics-and-parser-pragma-integ
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/init_list.c3, parser_initializer.c3 and parser_statement.c3; complete parser function definition/body entrypoints. Port InitList.zig sparse index tree and Parser.zig initializer/initializerItem/convertInitList/coerceArrayInit, designation and brace elision, compound literals, stmt/selectionHeader/labeledStmt/compoundStmt/returnStmt, function state and label resolution. Preserve aggregate zero fill, inferred array bounds, duplicate/overriding initializer diagnostics, union selection, scalar coercion, VLA restrictions, declaration scopes and tentative definitions. Port loops/switch ranges/case checking, goto/computed goto, return conversion, GNU statement expressions and GNU asm operands/labels/constraints. Preserve the existing explicit TODO for MSVC assembly, not a fake success. Connect declaration and expression entrypoints to real implementations and apply statement attributes.
Add test/c3/{init_list,parser_statement}_tests.c3 and extend frontend_probe fixture selection. Run bazel test //test/c3:init_list_tests //test/c3:parser_statement_tests //test/migration:statement_regression. Compare full typed ASTs and diagnostics for nested/designated initializers, sparse high indices, strings, duplicate cases/labels, break/continue scope, bad returns, malformed braces and asm. Include cast kinds.c and function-body fixtures previously deferred. Test repeated malformed then valid translation units in one process to prove scopes and temporary state unwind correctly. No production backend is required

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the function-state record (labels, scopes, return type) and the real compound-body entrypoint that replaces the stub.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **21.1 `init-list`**: owns `src/c3/init_list.c3`, `test/c3/init_list_tests.c3`. Sparse index tree, high indices, overriding entries.
- **21.2 `initializers`**: owns `src/c3/parser_initializer.c3`. initializer/initializerItem/convertInitList/coerceArrayInit, designators, brace elision, compound literals, zero fill, inferred bounds.
- **21.3 `control-flow`**: owns `src/c3/parser_statement.c3`. stmt/selectionHeader/labeled/compound/return, loops, switch ranges/case checks, goto/computed goto, label resolution.
- **21.4 `gnu-asm`**: owns `src/c3/parser_asm.c3`. GNU statement expressions, GNU asm operands/labels/constraints, explicit MSVC asm TODO.
- **21.5 `fn-defs`**: owns `parser.c3`/`parser_declaration.c3` edits. Function definitions/bodies, tentative definitions, statement attributes, removing temporary stubs.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/parser_statement_tests.c3`, extend frontend_probe selection, run `statement_regression`, and add the repeated malformed→valid TU test.
