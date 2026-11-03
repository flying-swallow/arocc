---
title: 'C3 migration 20: port attribute semantics and parser pragma integration'
state: waiting
depends_on:
- c3-migration-19-port-declarations-declarators-and-aggregate-type
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/attribute_wip.c3, attribute_diagnostics.c3 and parser_attribute.c3; connect parser_declaration.c3, parser.c3 and pragma callbacks. Follow Attribute/Wip.zig state/restore, parsed arguments, applyTypeAttrs/applyDeclAttrs/applyStmtAttrs and individual validation functions; port Attribute/Diagnostic.zig. Translate Parser.zig attribute/attributeSpecifier variants and keyword attributes: GNU, C23 namespaces, declspec, availability and type attributes. Preserve recognized-but-ignored/unimplemented behavior and warnings from the reference; do not promote these to implemented semantics. Implement packed/aligned/vector/calling-convention/nullability effects, declaration attributes and statement application hooks, ensuring attributes attach to the correct declaration/type and do not leak between declarators. Wire GCC diagnostic push/pop/replay and pragma pack at source token positions, using the previously tested pragma state machines. Cross-check predefined __has_attribute queries against the same name tables.
Run bazel test //test/c3:attribute_tests //test/migration:attribute_regression. Include anonymous attributed field, attributed anonymous record, c23 attributes, non string attribute, malformed/unknown names, contradictory alignment, pack labels/push/pop and diagnostic restoration across translation units. Compare AST attribute dumps, resulting type/layout properties and ordered diagnostics to Zig. Statement-only cases get direct application tests now and full-source coverage with the statement step

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
