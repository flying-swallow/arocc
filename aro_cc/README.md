# C frontend

This directory owns the C pipeline under `aro::frontend::c`: preprocessing,
parsing, literal semantics, attributes, pragmas, C types and AST, constant
evaluation, record layout, and AST-to-IR lowering. It also owns the current
C compilation context, diagnostics, include handling, and command-line driver.
Checked-in C builtin tables use `aro::frontend::c::builtin_defs`.

The CLI and Bazel target names are unchanged. `aro::api` remains the public
facade; consumers importing individual C modules must use the new namespace.

Shared source locations, numeric primitives, value interning, utilities,
targets, toolchains, and backend code retain their existing namespaces and
locations. Legacy Zig reference sources remain under `src/aro`.

This is an ownership and namespace boundary. Backend modules still depend on
C compilation, diagnostics, and typed constant operations. A backend that
builds independently of the C frontend needs a subsequent interface refactor;
new language frontends should not treat those C services as generic APIs.

Sources remain explicitly listed in the frontend Bazel library. Identifier-table
regeneration writes here. Builtin tables are maintained directly as C3 enums;
compile-time macros expand their lookup arrays, metadata and tag declarations.
Distribution packaging preserves the C namespace and directory layout.
