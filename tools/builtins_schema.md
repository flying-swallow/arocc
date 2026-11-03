# Builtin definitions: record schema and generated-table contract (plan 12)

Owner: plan 12 stage 0 (contract). Stage-1 agents implement against it. Changes
go through the integrator.

Zig reference: `build/generate_def.zig`, `build.zig` (`generateDef`, 19 inputs),
`src/aro/Builtins.zig`, `src/aro/Builtins/TypeDescription.zig`,
`src/aro/Builtins/properties.zig`.

## Files and owners

| File | Owner | Role |
|---|---|---|
| `src/c3/builtin_properties.c3` | 12.4 lookup-props | Enums (Header, Language, FormatKind, AttributeField, BuiltinGroup), `Attributes` bitstruct, `BuiltinTag`, `BuiltinRecord`, name lookups. Imports only std. |
| `src/c3/builtins.c3` | 12.4 lookup-props | `Builtins` cache, `from_name`, per-group lookup, arch search order, table wiring. |
| `src/c3/builtin_type_description.c3` | 12.3 type-desc | Component/type iterators; `create_type` / `create_builtin` build types through `TypeStore` directly. |
| `tools/generate_def_schema.c3` | stage 0 (frozen) | `DefEntry`, `DefFile`, `DefDiag`, parse faults. |
| `tools/generate_def_parse.c3` | 12.1 def-parser | `parse_def`. |
| `tools/generate_def.c3` | 12.2 table-gen | `emit_table`. |
| `tools/generate_def_main.c3` | 12.2 table-gen | CLI `main` (done in stage 0). |
| `tools/builtins.bzl` | 12.2 table-gen | `builtin_defs` rule (done in stage 0). |
| `test/c3/generate_def_tests.c3` | stage 0, extendable | Contract checks for the shared types. |
| `test/c3/builtins_tests.c3` | stage 2 integrator | Acceptance tests. |

The plan gives "`tools/generate_def.c3`" to both def-parser and table-gen. The
contract splits it into the files above, so the two agents never edit the same
file. All `tools/generate_def*.c3` files declare `module generate_def;`, except
`generate_def_main.c3` (`module generate_def_main;`), which is separate so
unit tests can link the parser and emitter without a second `main`.

## Build graph

```
src/aro/Builtins/<group>.def --(//tools:generate_def, one action per file)--> bazel-bin/builtin_defs/<group>.c3
//:builtin_defs (19 outputs) ----------------------------------------------> listed in //:aro_c3_lib srcs
//tools:generate_def = generate_def_main.c3 + //tools:generate_def_lib
//tools:generate_def_lib = generate_def{,_parse,_schema}.c3 + //:src/c3/builtin_properties.c3
```

The generator never depends on `aro_c3_lib`, because that would be a cycle.
`builtin_properties.c3` is compiled into both, and it therefore imports
nothing but std.

CLI: `generate_def <input.def> <output.c3> <group>`. `<group>` is a
`BuiltinGroup.def_name` (the .def basename). On success it exits 0. On error it
prints `<input>:<line>: error: <FAULT>: <detail>` to stderr, exits 1, and
writes nothing.

Per-file actions mean that editing one `.def` reruns only that group's
generation (plus the C3 compiles that consume `aro_c3_lib`).

## Input grammar (`.def`)

The file is processed line by line. A line is split on `\r`/`\n`, then
trimmed of spaces and tabs.

```
line          := empty | comment | name | property
comment       := '#' <anything>                      (includes commented-out properties)
name          := ident                               ident = [A-Za-z_][A-Za-z0-9_]*
property      := '.' pname ws? '=' ws? pvalue
pname         := 'param_str' | 'attributes' | 'header' | 'language' | 'features'
pvalue        := string                              for param_str, features
               | '.' ident                           for header, language
               | '.{' ws? (field (ws? ',' ws? field)* ws? ','?)? ws? '}'   for attributes
field         := '.' fname ws? '=' ws? fvalue
fname         := ident | '@"' ident '"'              ('@"const"', '@"noreturn"' appear in the tree)
fvalue        := 'true' | 'false'                    for BOOL fields
               | '.' ident                           for format_kind (FormatKind.name)
               | [0-9]+ (0..31)                      for format_string_position
string        := '"' [^"\\ and control chars]* '"'   (no escapes; none occur)
```

Semantics and rejections. Each one is a fault in `generate_def_schema.c3`, with
`DefDiag` set:

- A `name` line starts a new builtin. The `property` lines that follow it
  attach to that builtin.
- A property before any name is `ORPHAN_PROPERTY`.
- A name that repeats in the file is `DUPLICATE_NAME`.
- A property, or an attribute field, given twice on one builtin is
  `DUPLICATE_PROPERTY`.
- `pname` outside the list is `UNKNOWN_PROPERTY`.
- These are `UNKNOWN_VALUE`: an unknown header, language, attribute field or
  format kind; a value of the wrong kind; or a position greater than 31.
- A builtin without `param_str` is `MISSING_PARAM_STR`, because Zig has no
  default for it.
- `.features` in a group where `has_features == false` (common, mips, ve,
  xcore) is `FEATURES_NOT_ALLOWED`. This is a compile error in Zig, because
  those groups use `BuiltinBase`.
- Lines starting with `const ` / `pub const ` are `SYNTAX_ERROR`. Zig pastes
  them through as headers, but no `.def` file uses them, and the plan forbids
  copying arbitrary text. Every other unmatched line is also `SYNTAX_ERROR`.
- More than 65535 builtins is `TOO_MANY_BUILTINS`.
- Defaults for omitted properties come from `builtin_properties::RECORD_DEFAULT`:
  `language = ALL_LANGUAGES`, `header = NONE`, `features = ""`, and
  `attributes = ATTRIBUTES_DEFAULT` (only `eval_args` set). Fields given inside
  `.attributes = .{...}` are applied on top of `ATTRIBUTES_DEFAULT` with
  `Attributes.with_field`. Zig's struct-literal semantics work the same way.
- `param_str` contents are not checked by the generator. The integrator test
  runs every one through `TypeIterator`.

Observed in the tree, as of this commit: 13,552 builtins across 19 files. All
property values are as above. `format_kind` and `format_string_position` never
appear, but they are supported.

## Record schema (language-neutral)

One parsed entry is `generate_def::DefEntry`:

| Field | Type | Meaning |
|---|---|---|
| `name` | `String` | Builtin name, borrowed from the input |
| `record.param_str` | `String` | Signature in TypeDescription syntax |
| `record.language` | `Language` | Default `ALL_LANGUAGES` |
| `record.header` | `Header` | Default `NONE` |
| `record.attributes` | `Attributes` (bitstruct : uint) | Default `ATTRIBUTES_DEFAULT` |
| `record.features` | `String` | `""` = none (Zig `null`); otherwise the raw feature expression `a,b` / `(a|b),(c|d)` |
| `line` | `uint` | 1-based line of the name |

`Attributes` bits follow the Zig packed struct order, starting at the LSB:

| Bits | Field |
|---|---|
| 0 | noreturn |
| 1 | pure |
| 2 | is_const (Zig `const`) |
| 3 | custom_typecheck |
| 4 | allow_type_mismatch |
| 5 | lib_function_with_builtin_prefix |
| 6 | lib_function_without_prefix |
| 7 | returns_twice |
| 8..10 | format_kind |
| 11..15 | format_string_position |
| 16 | eval_args |
| 17 | const_without_errno_and_fp_exceptions |
| 18 | const_without_fp_exceptions |
| 19 | const_evaluable |

## Generated table layout

There is one file per group, `<group>.c3`, with the following exact layout. Indentation is one tab.
Lines end in `\n`, and the file ends after the last `\n`.

```c3
// Autogenerated by tools/generate_def.c3 from <group>.def, do not edit.
module aro::builtin_defs::<group>;
import aro::builtin_properties;

const BuiltinGroup GROUP = <GROUP>;
const ushort COUNT = <n>;
const usz SHORTEST_NAME = <min name len, 0 if n == 0>;
const usz LONGEST_NAME = <max name len, 0 if n == 0>;

const String[] NAMES = {
	"<name 0>",
	...
};

const BuiltinRecord[] RECORDS = {
	{ "<param_str>", <LANGUAGE>, <HEADER>, (Attributes)0x<5 lowercase hex digits>, "<features>" },
	...
};

const BuiltinTag TAG_<NAME UPPERCASED> = { .group = <GROUP>, .index = <i> };
...
```

- **Order and tags.** Entries are sorted bytewise ascending by name, like
  Zig's `std.mem.lessThan(u8)`. The position `i` is the tag index. This
  equals the Zig DAFSA unique index minus 1, so `BuiltinTag.index` values
  match Zig `@intFromEnum(tag)`. `NAMES[i]` and `RECORDS[i]` describe the same
  builtin.
- **Field values.** `<LANGUAGE>` and `<HEADER>` are the C3 enum constant names,
  for example `ALL_MS_LANGUAGES` or `ARM_ACLE`. `<GROUP>` is the
  `BuiltinGroup` constant name.
- **Tag constants.** One `TAG_` constant is emitted per name, in index order,
  with ASCII letters uppercased. A name whose uppercased form collides with
  another name in the same group gets **no** constant. Today that is
  `_Exit`/`_exit` in common and 8 pairs in ve, such as
  `__builtin_ve_vl_andm_MMM`/`..._mmm`. Code must reach those names with
  `builtins::tag_from_name`. Tags compare with `==`, and `switch` works on
  them (`case common::TAG___BUILTIN_VA_START:`).
- **Empty groups.** An empty table still emits all of the above, with empty
  braces. (All 19 real groups are non-empty.)
- **Determinism.** The output depends only on the parsed entries and the
  basename. It contains no paths, timestamps or hash order, so regenerating
  gives identical bytes.

The layout was checked at full scale. With the real generated tables
(13,552 builtins, about 41k lines), an uncontended c3c compile of
`aro_c3_lib` plus a small test takes about 2.0 s at -O0 and 1.6 s at -O2,
against about 1.7 s with empty tables (stage 2 measurement). The
uppercase-collision counts above (1 pair in common, 8 in ve, none elsewhere)
were verified against the generated tables by `//test/c3:builtins_tests`.

## Runtime API

`aro::builtins` (`builtins.c3`):

- `group_names(g)`, `group_records(g)`, `group_shortest_name(g)` and
  `group_longest_name(g)` are already wired to the generated modules.
- `tag_from_name(g, name) -> BuiltinTag?` does a binary search over `NAMES`.
  It returns `UNKNOWN_BUILTIN` on a miss. Name lengths outside
  [SHORTEST, LONGEST] fail fast.
- `name_from_tag(tag)` and `record_from_tag(tag)` read the tables directly.
- `from_name_in_group(g, name)` is Zig `fromNameExtra`.
- `from_name(comp, name)` searches `COMMON`, then `groups_for_arch(comp.target.cpu.arch)`.
  `groups_for_arch` mirrors the Zig switch:
  - aarch64/aarch64_be: AARCH64, AARCH64_NEON, NEON
  - arm/armeb/thumb/thumbeb: ARM, NEON
  - x86_64: X86_64, X86
  - x86: X86
  - one group each: amdgcn, bpfeb/bpfel, hexagon, loongarch32/64, mips*, nvptx*, powerpc*, riscv32/64(be), s390x, ve, wasm32/64, xcore
  - any other arch: none
- `Builtins.init/free`, `get_or_create(comp, name) -> Expanded?` and
  `lookup(name)` are the cache. Keys are the static `NAMES` strings.
  `get_or_create` uses `builtin_type_description::create_builtin`.
- Gating: Zig's `getOrCreate` checks neither features (it has a `TODO`) nor
  language, and the C3 port matches it. `language_allows` is provided for
  later parser use, and `FromName.features` keeps the raw expression. The
  Zig fallback `features = "neon"` for groups without a features field can
  never trigger, because neon has the field. Do not port it.

`aro::builtin_type_description`:

- `component_iterator` / `ComponentIterator.next/peek` and
  `type_iterator` / `TypeIterator.next` return `END` when done and
  `MALFORMED` on bad syntax (Zig hits `unreachable` there).
- `TypeDescription` holds up to 4 prefixes and 4 suffixes by value.
- `create_type(comp, desc, it)` and `create_builtin(comp, param_str)` port
  `createType` / `createBuiltin` / `specForSize`. They put types into
  `comp.type_store` directly, using `type_store::type_*` constructors and the
  `QualType` constants. They do not use a Parser or Builder.

## Acceptance split (plan 12)

Parser faults are covered by `//test/c3:def_parse_tests`, emitter layout by
`//test/c3:def_emit_tests`, regeneration determinism (parse + emit twice, and
equality with the Bazel `GenerateDef` outputs) by
`//test/c3:builtin_defs_regen_tests`. The integrator's `//test/c3:builtins_tests`
covers:

- every definition round-trips, i.e. name, then tag, then name and record,
  and every `.def` entry (re-read at test time) matches its generated record;
- per-group counts and uppercase-collision counts;
- `create_builtin` gives a function type for every definition on a
  representative target of its group;
- representative signatures per architecture;
- target gating (every name on every arch) and unknown names.

A changed `.def` invalidating only its own `GenerateDef` action is a manual
check (Bazel execution log), recorded in the plan 12 completion notes.

Not in scope: evaluating builtin expressions and custom type checks. Both
belong to parser integration.
