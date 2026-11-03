---
title: 'C3 migration 18 [AST & parser]: establish parser context and typed expression semantics'
state: waiting
depends_on:
- c3-migration-11-port-numeric-and-text-literal-decoding
- c3-migration-16-port-ast-storage-attributes-and-symbol-scopes
- c3-migration-17-port-record-abi-layout-independently-of-parsing
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/parser.c3, parser_expression.c3, parser_result.c3, parser_diagnostics.c3 and test/c3/parser_expression_tests.c3. Start from Parser.zig parse lifecycle, token utilities/error recovery, Result conversions/coercions, expr/assignExpr/constExpr/integerConstExpr, binaryExpr/unExpr/suffixExpr/primaryExpr/fieldAccess/callExpr and genericSelection. Translate Parser/Diagnostic.zig messages required by these paths, preserving language-version suppression and macro source locations. Reuse literal, type, value, scope and AST modules. Implement operators, promotion/decay, lvalue rules, pointer arithmetic, constant folding and unavailable-value semantics, explicit/implicit cast kinds, calls/member access and _Generic. Retain checks even in unevaluated/short-circuited branches where the reference does; avoid host arithmetic UB.
C's expression/declaration grammar is mutually recursive. Define a shared parser context and explicit type-name/compound-body entry interfaces now, testing those integration points with synthetic type/symbol bindings; declaration and statement tickets replace temporary unsupported entrypoints before full-file acceptance. Unsupported syntax must diagnose rather than succeed. This step's acceptance is expression entry tests, not a claim of full fixture parity.
Run bazel test //test/c3:parser_expression_tests with preprocessed expressions and seeded symbols/types; compare typed ASTs, cast kinds, values and diagnostics against reference expression wrappers. Cover signedness/overflow, complex/floating conversions, function pointers, arrays, qualifiers, null pointers, bitfield lvalues, short-circuiting, bad calls and malformed recovery. Keep builtin-special forms and statement expressions for their named later steps, tracking explicit remaining entrypoints

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
