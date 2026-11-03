---
title: 'C3 migration 16 [AST & parser]: port AST storage, attributes and symbol scopes'
state: waiting
depends_on:
- c3-migration-08-port-type-representation-and-qualified-type-oper
- c3-migration-10-preserve-floating-and-complex-constant-semantics
- c3-migration-13-port-macro-expansion-and-conditional-preprocessi
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/tree.c3, attribute.c3, attribute_map.c3 and symbol_stack.c3 plus test/c3/{tree,attribute_map,symbol_stack}_tests.c3. Translate Tree.zig Node families, stable indices, optional indices, extra arrays, roots, type/value/attribute associations, addNode/setNode/get, lvalue queries, source-aware write and dump. Reuse shared tokens from preprocessing rather than a second token model. Port Attribute.zig Args/Syntax/Namespaced and Attribute/Map.zig compact storage and alignment queries. Port SymbolStack.zig reusable active scopes with separate ordinary/tag namespaces, shadowing and declaration lookup, routing parser-specific errors through a diagnostic context instead of requiring a complete Parser. Keep ownership explicit: token/source lifetime is held by compilation/preprocessor, while tree storage is released by tree deinit. No codegen dependency is necessary to create or inspect a tree.
Run bazel test //test/c3:tree_tests //test/c3:attribute_map_tests //test/c3:symbol_stack_tests. Construct each supported node/attribute family and verify readback, indexed collections, reference stability through growth, scope reuse and shadowing, type/value lookup and destruction. Compare representative constructed-tree dumps and type spellings to reference outputs, including declarations, casts and anonymous records. Record a mapping of Zig node/attribute tags to C3 representations so later parser work cannot silently omit tags

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Write the Zig→C3 node and attribute tag mapping table (checked in) and the `tree.c3` core types: Node index, OptIndex, tag enum and extra-array layout.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **16.1 `tree-storage`**: owns `src/c3/tree.c3` (storage). addNode/setNode/get, extra arrays, roots, type/value/attribute associations, stability under growth.
- **16.2 `decl-nodes`**: owns `src/c3/tree_decl.c3`. Declaration/type/record node families: encode and decode.
- **16.3 `expr-stmt-nodes`**: owns `src/c3/tree_expr.c3`. Expression and statement node families: encode and decode, lvalue queries.
- **16.4 `dump`**: owns `src/c3/tree_dump.c3`. Source-aware write and dump matching reference formatting.
- **16.5 `attributes`**: owns `src/c3/attribute.c3`, `src/c3/attribute_map.c3`. Args/Syntax/Namespaced, compact map storage, alignment queries.
- **16.6 `symbols`**: owns `src/c3/symbol_stack.c3`. Reusable scopes, ordinary/tag namespaces, shadowing, lookup, diagnostics via context.

**Stage 2: integrator (1 agent, serial).** Write the three test files, register targets, compare constructed-tree dumps to reference output, and check that the mapping table covers every Zig tag.
