## Layout

Modeled on c3c's `test/`: harness code in `aro_cc/test/src/`, integration cases in
`aro_cc/test/test_suite/`, C frontend unit tests in `aro_cc/test/<area>/`,
and shared backend and C3 frontend unit tests in `aro_cc/test/unit/`.

| Path | Contents | Targets |
|---|---|---|
| `src/test_suite/` | c3c-style suite runner | `//aro_cc/test/src/test_suite:test_suite_runner`, `:test_suite_runner_tests` |
| `src/records/` | record-layout runner | `//aro_cc/test/src/records:record_regression`, `:record_runner_tests` |
| `src/gcc/` | GCC testsuite harness, `baseline.json` (known non-PASS cases) | `//aro_cc/test/src/gcc:gcc_testsuite_*` |
| `src/cli/` | driver/CLI, native backend, library-consumer and runfiles tests | `//aro_cc/test/src/cli:*` |
| `src/probes/` | in-process probes (`pp_probe`, `ir_probe`, `assembly_probe`) and their regressions | `//aro_cc/test/src/probes:*` |
| `src/manifest/` | Aro `/** manifest: */` runner (used by `assembly_regression`) and shared child-process/path helpers | `//aro_cc/test/src/manifest:runner_lib`, `:runner_tests` |
| `src/fuzz/` | fuzz replay and AFL shim (`main.c`) | `//aro_cc/test/src/fuzz:replay_test`, `:afl_fuzz` |
| `src/lib/` | shared harness library (process, fs, JSON, tar, runfiles) | `//aro_cc/test/src/lib:harness_lib` |
| `test_suite/<area>/` | integration cases (self-contained `.c` / `.ct`, `_support/` include trees) | `//aro_cc/test/test_suite:test_suite_<area>`, `:all` |
| `<area>/` | C frontend unit tests; `data/` holds their vectors and fixtures | `//aro_cc/test/<area>:<name>`, `//aro_cc/test/<area>:all` |
| `unit/backend/`, `unit/c3/` | Shared backend and C3 frontend unit tests | `//aro_cc/test/unit/<area>:all` |
| `records/` | record-layout corpus | `//aro_cc/test/src/records:record_regression` |
| `regression/<area>/` | probe data: `assembly/`, `ir/` scenarios, `preprocessor/` fixture tree | `//aro_cc/test/src/probes:*` |
| `native/` | backend CLI sources | `//aro_cc/test/src/cli:native_backend_cli_integration` |
| `gcc/` | GCC C testsuite copy (GPL-3.0+, `gcc/SOURCE`) | `//aro_cc/test/src/gcc:gcc_testsuite_*` |
| `portability/` | runfiles path containing a space | `//aro_cc/test/src/cli:runfiles_portability_integration` |
| `fuzz/corpus/` | fuzz inputs | `//aro_cc/test/src/fuzz:replay_test` |

Unit areas are `backend`, `builtins`, `driver`, `lexer`, `parser`,
`preprocessor`, `tree`, `types` and `values`. Add a unit test as
`aro_cc/test/<area>/<name>_tests.c3`, one `c3_test` line in that area's
`BUILD.bazel`, and the target in its `all` suite. Single fixture files are
addressable as `//aro_cc/test:<path>`; directories have filegroups
(`//aro_cc/test:record_fixtures`, `//aro_cc/test:regression_<area>_fixtures`, …).

The checked-in identifier, x86 encoding and record-vector tables retain their
upstream source attribution. Their one-off import generators have been removed.

## Integration test suite

`aro_cc/test/test_suite/<area>/` holds the integration cases, one self-contained file
per case, in the style of c3c's `aro_cc/test/test_suite`. `//aro_cc/test/src/test_suite:test_suite_runner`
discovers cases recursively, runs them on worker threads with the production
`aro_cc`, and prints a progress bar, a box per failure and a summary line.
Each area is one Bazel target (`//aro_cc/test/test_suite:test_suite_<area>`;
`//aro_cc/test/test_suite:all` runs every area):

```sh
bazel test //aro_cc/test/test_suite:test_suite_preprocessor
bazel build //:aro_cc //aro_cc/test/src/test_suite:test_suite_runner
bazel-bin/aro_cc/test/src/test_suite/test_suite_runner bazel-bin/aro_cc/aro_cc aro_cc/test/test_suite            # whole tree
bazel-bin/aro_cc/test/src/test_suite/test_suite_runner bazel-bin/aro_cc/aro_cc "aro_cc/test/test_suite/lexer/latin1.c"
bazel-bin/aro_cc/test/src/test_suite/test_suite_runner bazel-bin/aro_cc/aro_cc aro_cc/test/test_suite -s         # only #skip cases
```

Options: `-s`/`--skipped` (run only skipped cases), `--threads N`,
`--no-terminal`, `--cc PATH` (needed by `run` cases), `--support DIR`
(default: the nearest `_support/`), `--failures FILE` (write
`<path>\t<reason>` per failed case). `ARO_C3_OPT` (default `-O1`) and
`ARO_C3_FLAGS` apply to `run` cases.

Each case is written to a per-worker directory that also holds a copy of
`aro_cc/test/test_suite/_support/` (`include/`, `embed/`, `frameworks/`), and the
compiler runs there with the case's basename, so `-Iinclude` and diagnostics
such as `name.c:3:5: error: ...` keep their usual form.

### Case format

A `.c` case is one translation unit. A `.ct` case may also contain extra input
files and an expected stdout section. Directives are `// #key: value` comments.

Header directives sit on their own line and are removed from the written
file:

| Directive | Meaning |
|---|---|
| `// #kind: K` | `syntax` (default: `-fsyntax-only --verbose-ast`), `syntax_ignore_errors`, `expand` / `expand_partial` / `expand_error` (`-E -P`), `run` (compile with `-c`, link with `--cc`, run) |
| `// #opt: ARGS` | compiler arguments, split on spaces; repeatable |
| `// #env: K=V ...` | child environment overrides |
| `// #exit: N` | expected exit status (the program's for `run`; required there) |
| `// #skip: REASON` | known failure; not run unless `-s` is given |
| `// #todo: NOTE` | informational |
| `// #error: TEXT` (also `#warning`, `#note`, `#fatal`) | a diagnostic anywhere (another file, the command line, no location); `TEXT` is a substring of `location: message` |
| `// #file: NAME` | `.ct` only: the following lines are another input file (written, not passed) |
| `// #expect: stdout` | `.ct` only: the rest of the section is the expected stdout: exact for `syntax` (AST) and `expand`, a suffix for `expand_partial`, the program output for `run` |

Trailing directives follow code on the line they describe and are removed
from the written line, so the compiled bytes equal the case's code:

```c
// #kind: expand_error
// #opt: -std=c23
#ifdef FOO
#elifdef // #error@9: macro name missing
#endif
int x = y; // #error: use of undeclared identifier 'y' // #note@5: here
```

`#error@9` also pins the column. Diagnostics are matched as a set: every
`file:line:col: kind: message` line on stderr must match a distinct
expectation (same file, line, kind and column if given; message substring),
and every expectation must be matched. Unless `#exit` is given, a nonzero
exit fails a case that expects no error. Comments that only look like
directives (`// #if ...`, `// #error "x"`) are ordinary code.

## C3 and Bazel test commands

The integration and record runners are implemented in C3. `C3C` overrides the
C3 compiler used by Bazel actions. Set a writable Bazel output root if the
default location is unavailable. Run these commands from the repository root:

```sh
C3C=/path/to/c3c
BAZEL=bazel
BAZEL_ROOT=/path/to/writable/bazel-root

env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //aro_cc/test:regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt //aro_cc/test:regression
```

Each `c3_test` target is built with `c3c compile-test` and run through a small
launcher (`aro_cc/tools/c3_test_launcher.sh.tpl`) that maps Bazel test options onto
the C3 test runner and disables ANSI colors in `test.log`:

```sh
# Run only tests whose name contains "generic" (--test-filter).
bazel test //aro_cc/test/parser:parser_expression_tests --test_filter=generic
# Pass runner flags through: show output, skip leak checks, log level.
bazel test //aro_cc/test/parser:parser_expression_tests --test_output=all \
  --test_arg=--test-show-output --test_arg=--test-noleak
# Run the test binary directly with the same launcher.
bazel run //aro_cc/test/parser:parser_expression_tests -- --test-filter generic
```

The public suites are `//aro_cc/test:unit`, `//aro_cc/test:integration`, `//aro_cc/test:records`,
and their aggregate `//aro_cc/test:regression`. Run one suite directly to focus a
configuration. Bazel's recursive `//aro_cc/test/...` pattern also discovers the
separate replay target, so it is not the default full-suite command. Replay
and AFL targets are opt-in:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //aro_cc/test/src/fuzz:replay_test
# AFLplusplus is needed only for this target; AFL_CC names afl-clang-fast.
env C3C="$C3C" AFL_CC=/path/to/afl-clang-fast "$BAZEL" --output_user_root="$BAZEL_ROOT" test \
  --action_env=AFL_CC //aro_cc/test/src/fuzz:afl_fuzz
```

The profiling feature tests are part of `//aro_cc/test:unit`. The enabled variant
defines the Tracy feature flags and links the local profiling stub, so it does
not require an external Tracy client library.

The runner unit tests are part of `//aro_cc/test:unit`; they can also be run alone:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //aro_cc/test/src/manifest:runner_tests
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt //aro_cc/test/src/manifest:runner_tests
```

The manifest runner (`//aro_cc/test/src/manifest:runner_lib`, a port of the former
`aro_cc/test/runner.zig`) reads Aro's `/** manifest: */` case format with `ast/` and
`expanded/` goldens. Its only current suite is
`//aro_cc/test/src/probes:assembly_regression`, driven by the case list
`aro_cc/test/regression/assembly/cases.txt` (`name.c [result=pass|fail|unsupported]
[exit=N] [signal=N] [fatal]`; `//` starts a comment line).

## GCC testsuite

`aro_cc/test/gcc/` is a copy of the GCC C testsuite files the harness uses (top-level
`gcc.c-torture/{compile,execute,execute/ieee}` and `gcc.dg`, plus files they
include). It is GPL-3.0-or-later test input; `aro_cc/test/gcc/SOURCE` records the GCC
commit.

`//aro_cc/test/src/gcc` (`gcc_testsuite.c3`) treats GCC's expectations as golden:
torture `compile` cases must compile cleanly, torture `execute`/`ieee` cases must
build, link and exit 0, and `gcc.dg` cases must report an error/warning on every
`dg-error`/`dg-warning` line (message text is not compared) and no other errors.
Panics and signals are CRASH, backend `TODO` errors UNSUPPORTED, and unknown
effective targets SKIP (with the reason).

```sh
bazel test //aro_cc/test/src/gcc:gcc_testsuite          # 4 sharded suites, part of //...
bazel run //aro_cc/test/src/gcc:gcc_testsuite_update_baseline
# ad-hoc subset from the repo root (no baseline update outside `bazel run`):
bazel-bin/aro_cc/test/src/gcc/gcc_testsuite_update_baseline --suite dg --filter 'pr1*' --out /tmp/aro-gcc
bazel test //aro_cc/test/src/gcc:gcc_testsuite_tests   # directive parser checks
```

The targets are gated by `aro_cc/test/src/gcc/baseline.json`: only a new
non-PASS result (or a status change such as FAIL -> CRASH) fails; flips to or from
TIMEOUT are reported but not gated. Each test's undeclared outputs hold
`summary.md` (the worklist: crashes first, then failure groups) and
`results.jsonl` (one record per case with the command and output).
`--zig-arocc <binary>` adds an informational differential run against Zig arocc.

## Record layout fixtures

See [record_readme.md](record_readme.md) for the fixture format, target/define
reproduction, and record report interpretation.

`//aro_cc/test/src/records:record_regression` runs the C3 record runner against
`aro_cc/test/records`. The runner parses every `// MAPPING|...` comment and executes
each supported target/define tuple. Run the focused record targets with:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg \
  //aro_cc/test/src/records:record_runner_tests //aro_cc/test/src/records:record_regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt \
  //aro_cc/test/src/records:record_runner_tests //aro_cc/test/src/records:record_regression
```

The record port currently runs the full mapping inventory; it has no CLI option
to filter by one target or define. To reproduce one mapping, take its source
file, define, and target from a `MAPPING` comment and invoke the compiler with
the same options the port constructs. For example, the `ONE` mapping in
`aro_cc/test/records/0001_test.c` includes `x86_64-x86_64-linux-gnu:Gcc`:

```sh
/absolute/path/to/arocc aro_cc/test/records/0001_test.c \
  -fsyntax-only -fno-color-diagnostics -target x86_64-linux-gnu \
  -mcpu x86_64 --verbose-ast -D ONE --emulate=gcc
```

A mapping target is `Arch-CpuModel-OS-ABI:Compiler`. The port forms
`Arch-OS-ABI` for `-target`, passes `CpuModel` to `-mcpu`, and maps `Gcc`,
`Clang`, or `Msvc` to `--emulate=gcc`, `--emulate=clang`, or `--emulate=msvc`.
For an MSVC ABI it also passes `-DMSVC`; with Clang emulation it additionally
passes `-fms-extensions`. These compiler tags select arocc's emulation mode;
they do not launch those external compilers.

Record fixture files are generated from the repr-c test data and retain its
GPLv3 license; each file carries its SPDX identifier. Each record is followed
by alignment, packed, required-alignment, and size variants. English-numbered
preprocessor groups select mutually exclusive assertion sets with `-D ONE`,
`-D TWO`, and so on. `MSVC` selects the Microsoft layout extensions, while
`SKIP_OFFSETS` omits non-standard `__builtin_bitoffsetof` assertions.

The first `MAPPING` comment for a group is used by the runner: it lists the
define followed by target/compiler tuples and ends at `END`. A second `repr`
mapping comment is informational and is not consumed by the C3 runner.

### Reading record reports

- `selected` counts mapping tuples parsed from the fixture files. `executed`
  counts tuples for which the compiler was started, including a process that
  later crashes.
- `passed` counts tuples with no diagnostics classified as a failure.
- `expected failures` counts tuples whose diagnostics exactly match the
  source-derived expected failure classes. These are also included in
  `skipped`; they are recognized expected failures, not passes.
- `invalid targets` counts targets the port recognizes but deliberately does
  not invoke, currently x86 or ARM targets for iOS or macOS. They are neither
  passes nor compiler failures.
- `failures` includes unexpected diagnostic classes, an unexpected pass where
  failure was expected, invalid mapping/compiler data, and other runner
  errors. `crashes` is also reported separately and is included in failures.
  `unexpected passes` is a subset of failures.

The frozen record regression currently selects 9,353 tuples: 9,009 execute,
9,007 pass, 2 match expected failures and are counted as skipped, and 344 are
invalid targets. A zero failure count does not turn expected-failure or
invalid-target tuples into passing coverage.
