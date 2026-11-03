---
title: 'C3 migration 12 [Builtin definitions]: Generate builtin definitions and decode builtin signatures'
state: waiting
depends_on:
- c3-migration-08-port-type-representation-and-qualified-type-oper
- c3-migration-05-port-diagnostic-state-and-rendering
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add tools/generate_def.c3, a declared Bazel generation rule in tools/builtins.bzl, src/c3/builtins.c3, builtin_type_description.c3 and builtin_properties.c3 plus //test/c3:builtins_tests. Source: build/generate_def.zig parsing/sorting/name lookup generation, all .def inputs enumerated in build.zig, Builtins.zig, Builtins/TypeDescription.zig and properties.zig. Keep .def inputs as source of truth; they contain Zig-style property/header expressions, so explicitly parse the supported grammar into language-neutral records rather than copying it as C3 or evaluating arbitrary text. Generate deterministic name/tag/property tables for all 19 groups and stage outputs through the build rule's generated inputs. Stable semantic lookup matters; DAFSA byte-for-byte reproduction is unnecessary. Port type-description iterators and build C3 types directly rather than constructing an undefined Parser as the Zig implementation does. Preserve language/header/feature restrictions and unknown-name handling. Acceptance: bazel test //test/c3:builtins_tests checks round trips for every definition, duplicate/property errors, representative signatures per architecture and target gating; regeneration yields identical bytes twice and a changed .def invalidates the Bazel action. Builtin expression evaluation and custom type checks belong to parser integration later

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the language-neutral record schema for parsed `.def` entries (name, signature string, attributes, header, language, feature, target) and the generated-table layout.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **12.1 `def-parser`**: owns `tools/generate_def.c3` (parsing). Parse the supported `.def` grammar, including Zig-style property/header expressions, into records; reject unknown syntax and duplicates.
- **12.2 `table-gen`**: owns `tools/generate_def.c3` (emit), `tools/builtins.bzl`. Deterministic, sorted name/tag/property tables for all 19 groups; Bazel rule with declared `.def` inputs and generated outputs.
- **12.3 `type-desc`**: owns `src/c3/builtin_type_description.c3`. TypeDescription iterators that build C3 types directly, with no fake Parser.
- **12.4 `lookup-props`**: owns `src/c3/builtins.c3`, `src/c3/builtin_properties.c3`. Name lookup, properties, language/header/feature/target gating, unknown-name handling.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/builtins_tests.c3` (round trip every definition, determinism ×2, `.def` change invalidates the action), register `//test/c3:builtins_tests`.
