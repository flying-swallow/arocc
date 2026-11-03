---
title: 'C3 migration 19: port declarations, declarators and aggregate type parsing'
state: waiting
depends_on:
- c3-migration-18-establish-parser-context-and-typed-expression-se
- c3-migration-15-port-includes-embed-pragma-lifecycle-and-depende
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/parser_declaration.c3 and type_builder.c3; extend parser.c3/type-name callbacks and diagnostic tables. Follow Parser.zig rootItem/decl/declSpec/storageClassSpec/typeSpec/typeQual/declarator/directDeclarator/paramDecls/typeName, recordSpec/recordDecl and enumSpec; port TypeStore.zig Builder.finish/finishQuals/combine and SymbolStack declaration/redeclaration checks. Preserve nested abstract/function-pointer declarators, typedef ambiguity, qualifiers, array bounds/VLA types, function prototypes/old-style declarations, tags/forward completion, enum values, anonymous members, bitfield validation, static assertions and language-specific auto/typeof/_BitInt behavior already supported by the reference. Call the independent layout module on completed records. Supply minimal attribute parse hooks that explicitly report not-yet-supported forms; full attribute semantics are the next scoped ticket. Scalar initializers can use expression coercion; aggregate initialization and function bodies are the statement/initializer step.
Add test/migration/frontend_probe.c3 with the baseline syntax-only/verbose-AST protocol and an explicit supported-fixture list. It is a test adapter, not the production Driver. Run bazel test //test/c3:parser_declaration_tests //test/migration:declaration_regression. Test complex declarator precedence, forward/self-referential records, duplicate typedefs, invalid bitfields and enums, inference cycles, invalid storage classes and malformed-input recovery. Differential checks compare AST, diagnostics and exit status; deferred constructs must remain listed as pending, never newly skipped in the original suite

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Settle the declaration entrypoint signatures that replace the stubs from 18, and the attribute parse hook signatures (which report unsupported for now).

**Stage 1: parallel agents (start together after stage 0 merges).**
- **19.1 `specifiers`**: owns `src/c3/parser_declaration.c3` (specifiers), `src/c3/type_builder.c3`. declSpec/storageClassSpec/typeSpec/typeQual; Builder.finish/finishQuals/combine; auto/typeof/_BitInt.
- **19.2 `declarators`**: owns `src/c3/parser_declarator.c3`. declarator/directDeclarator/paramDecls/typeName, abstract and function-pointer nesting, VLAs, old-style declarations.
- **19.3 `records-enums`**: owns `src/c3/parser_record.c3`. recordSpec/recordDecl/enumSpec, anonymous members, bitfield validation, layout calls on completion.
- **19.4 `decl-root`**: owns `src/c3/parser_declaration.c3` (rootItem/decl). rootItem/decl, typedef ambiguity, redeclaration checks, static assertions, scalar initializers.
- **19.5 `probe`**: owns `test/migration/frontend_probe.c3`, declaration fixture list. Syntax-only/verbose-AST probe and the supported/pending fixture lists.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/parser_declaration_tests.c3`, register targets, run `declaration_regression`, and keep deferred constructs listed as pending.
