# Record layout fixtures

The `.c` files in `test/records` exercise arocc's record layout for structs,
unions, and related types. The files derive from [mahkoh/repr-c](https://github.com/mahkoh/repr-c);
the generation code lives in the
[arocc-test-gen fork](https://github.com/TwoClocks/repr-c/tree/arocc-test-gen/repr/arocc).
They are derivative works under GPLv3; each file includes its SPDX identifier.
The C3 implementation is `test/src/records/record_runner.c3`. It is a port of the former Zig `test/record_runner.zig`.

## Fixture structure

A fixture declares the type under test and then related records that probe its
alignment, packed layout, required alignment, and size. For example, an
`X_extra_alignment` record places a `char` before `X`; `X_extra_packed` places
the type in a packed record; `X_extra_required_alignment` embeds that packed
record after a `char`; and `X_extra_size` uses a byte array sized from
`sizeof(X)`. The fixture's `_Static_assert`s check `sizeof`, `_Alignof`, and,
for records with multiple members, starting bit offsets where available.

Each group of assertions is selected by a preprocessor define such as `ONE`,
`TWO`, or `THREE`. Groups are mutually exclusive. `MSVC` selects the
Microsoft-specific source variants; otherwise the fixture uses the GCC-like
variants. `SKIP_OFFSETS` omits checks that use the non-standard
`__builtin_bitoffsetof` builtin.

The test file's first mapping comment for each group has this form:

```c
// MAPPING|THREE|aarch64-generic-windows-msvc:Msvc|thumb-baseline-windows-msvc:Msvc|END
```

`MAPPING` marks the record mapping, `THREE` names the define, and each
`target:Compiler` entry identifies a target/compiler-emulation pair. `END`
terminates the target list. A second `repr` comment records the original
`repr-c` target mapping for reference; the C3 runner ignores it.

The target field is `Arch-CpuModel-OS-ABI`. The C3 port builds the `-target`
triple from `Arch-OS-ABI`, passes `CpuModel` to `-mcpu`, and translates the
compiler tag to arocc's `--emulate` option. It does not launch external GCC,
Clang, or MSVC compiler executables.

## Running the record suite

The record regression runs every mapping tuple. Set `C3C` to the C3 compiler
used for Bazel build actions and run from the repository root:

```sh
C3C=/path/to/c3c
BAZEL=bazel
BAZEL_ROOT=/path/to/writable/bazel-root

env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg \
  //test/src/records:record_runner_tests //test/src/records:record_regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt \
  //test/src/records:record_runner_tests //test/src/records:record_regression
```

There is no runner option to filter a single target or define. To reproduce a
tuple, copy its fixture path, group define, and target from the `MAPPING`
comment, then invoke the compiler with the port's arguments. This mapping in
`test/records/0001_test.c` is a concrete example:

```sh
/absolute/path/to/arocc test/records/0001_test.c \
  -fsyntax-only -fno-color-diagnostics -target x86_64-linux-gnu \
  -mcpu x86_64 --verbose-ast -D ONE --emulate=gcc
```

For an MSVC ABI the port adds `-DMSVC`; if the mapping uses Clang emulation it
also adds `-fms-extensions`. Use `--emulate=clang`, `--emulate=gcc`, or
`--emulate=msvc` according to the mapping's compiler tag.

## Interpreting the record report

- `selected` is the number of parsed mapping tuples. `executed` counts tuples
  for which the compiler started; it includes a process that later crashes.
- `passed` counts tuples with no parse, layout, extra-layout, or bit-offset
  failure class detected.
- `expected failures` counts tuples whose observed diagnostic classes exactly
  match the source-derived expectation. Those tuples are also counted in
  `skipped`; an expected failure is not a pass.
- `invalid targets` counts supported target descriptions that the port
  intentionally does not invoke. Currently it includes x86 and ARM on iOS or
  macOS. These tuples are neither passes nor failures. A target that cannot be
  parsed is a runner failure instead.
- `failures` includes mismatched diagnostic classes, an unexpected pass for a
  tuple that should fail, and runner errors. `crashes` is reported separately
  and is also a failure. `unexpected passes` is a subset of failures.
- `excluded` counts global test exclusions. The current exclusion set is empty.

The current frozen record inventory selects 9,353 tuples: 9,009 execute, 9,007
pass, 2 match expected failures and are counted as skipped, and 344 are
invalid targets. A zero `failures` count means the run matched the port's
expectations; skipped expected failures and unexecuted invalid targets do not
count as passing coverage.
