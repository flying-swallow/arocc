# Builtin C3 tables

The 19 modules in `aro_cc/src/builtin_defs/` are compiled directly into the C
frontend. They were converted from the original `.def` inputs; the parser,
generator and input files have been removed. Edit the C3 tables directly.

Each module declares `aro::frontend::c::builtin_defs::<group>` and imports
`builtin_properties`, which defines the shared record, attributes and expansion macros.

## Table layout and maintenance

Each `Builtin` enum entry stores the exact builtin name and its `BuiltinRecord`:
signature (`param_str`), language, required header, attribute bits, and target
feature expression. Entries must remain in ascending bytewise name order for
binary lookup. Enum ordinals supply the builtin indices.

Use `TAG_` plus the uppercased builtin name as the enum identifier. Names that
collide after uppercasing use distinct `COLLISION_` identifiers instead, preserving
the previous omission of ambiguous public tags.

The shared constant macros derive parallel name/record arrays and shortest/longest
name lengths from the enum; the count comes from `Builtin::values.len`. Private
global arrays give the expanded lookup slices static storage. `$expand` invokes
`@builtin_tags` to declare a public `const BuiltinTag` for each `TAG_` entry,
using its enum ordinal and the module's `GROUP`. No numeric indices are maintained
in the table sources.

When editing a table, update only the enum rows. Preserve group ordinals and keep
the common va-copy and va-end indices in `builtin_properties.c3` synchronized when
changing the common table's ordering. Attribute bits follow `Attributes`; the
default `eval_args` bit is `0x10000`. Empty features mean no feature requirement.

The runtime uses binary search over names. Signature decoding is implemented in
`builtin_type_description.c3`; architecture search order and feature/language
gating are implemented in `builtins.c3`.

## Validation

`//aro_cc/test/builtins:all` covers table counts, ordering, lookup round trips,
properties, signatures, target gating and builtin expressions/calls. Preprocessor
builtin integration tests cover usage through the compiler pipeline. No runtime
`.def` files or regeneration checks are required.
