## Layout

Modeled on c3c's `test/`: harness code in `test/src/`, integration cases in
`test/test_suite/`, C3 unit tests in `test/unit/`. Everything is C3; no Python,
shell or Zig runtime is needed.

| Path | Contents | Targets |
|---|---|---|
| `src/test_suite/` | c3c-style suite runner | `//test/src/test_suite:test_suite_runner`, `:test_suite_runner_tests` |
| `src/records/` | record-layout runner | `//test/src/records:record_regression`, `:record_runner_tests` |
| `src/gcc/` | GCC testsuite harness, `baseline.json` (known non-PASS cases) | `//test/src/gcc:gcc_testsuite_*` |
| `src/cli/` | driver/CLI, native backend, library-consumer and runfiles tests | `//test/src/cli:*` |
| `src/probes/` | in-process probes (`pp_probe`, `ir_probe`, `assembly_probe`) and their regressions | `//test/src/probes:*` |
| `src/manifest/` | Aro `/** manifest: */` runner (used by `assembly_regression`) and shared child-process/path helpers | `//test/src/manifest:runner_lib`, `:runner_tests` |
| `src/fuzz/` | fuzz replay and AFL shim (`main.c`) | `//test/src/fuzz:replay_test`, `:afl_fuzz` |
| `src/lib/` | shared harness library (process, fs, JSON, tar, runfiles) | `//test/src/lib:harness_lib` |
| `test_suite/<area>/` | integration cases (self-contained `.c` / `.ct`, `_support/` include trees) | `//test/test_suite:test_suite_<area>`, `:all` |
| `unit/<area>/` | C3 unit tests; `data/` holds their vectors and fixtures | `//test/unit/<area>:<name>`, `//test/unit/<area>:all` |
| `records/` | record-layout corpus | `//test/src/records:record_regression` |
| `regression/<area>/` | probe data: `assembly/`, `ir/` scenarios, `preprocessor/` fixture tree | `//test/src/probes:*` |
| `native/` | backend CLI sources | `//test/src/cli:native_backend_cli_integration` |
| `gcc/` | GCC C testsuite copy (GPL-3.0+, `gcc/SOURCE`) | `//test/src/gcc:gcc_testsuite_*` |
| `portability/` | runfiles path containing a space | `//test/src/cli:runfiles_portability_integration` |
| `fuzz/corpus/` | fuzz inputs | `//test/src/fuzz:replay_test` |

Unit areas are `backend`, `builtins`, `driver`, `lexer`, `parser`,
`preprocessor`, `tree`, `types` and `values`. Add a unit test as
`test/unit/<area>/<name>_tests.c3`, one `c3_test` line in that area's
`BUILD.bazel`, and the target in its `all` suite. Single fixture files are
addressable as `//test:<path>`; directories have filegroups
(`//test:record_fixtures`, `//test:regression_<area>_fixtures`, …).

Code generators that keep checked-in tables in sync live in `//tools`
(`gen_identifier_tables`, `gen_x86_encodings`, `gen_target_record_vectors`).

## Integration test suite

`test/test_suite/<area>/` holds the integration cases, one self-contained file
per case, in the style of c3c's `test/test_suite`. `//test/src/test_suite:test_suite_runner`
discovers cases recursively, runs them on worker threads with the production
`aro_c3`, and prints a progress bar, a box per failure and a summary line.
Each area is one Bazel target (`//test/test_suite:test_suite_<area>`;
`//test/test_suite:all` runs every area):

```sh
bazel test //test/test_suite:test_suite_preprocessor
bazel build //:aro_c3 //test/src/test_suite:test_suite_runner
bazel-bin/test/src/test_suite/test_suite_runner bazel-bin/aro_c3 test/test_suite            # whole tree
bazel-bin/test/src/test_suite/test_suite_runner bazel-bin/aro_c3 "test/test_suite/lexer/latin1.c"
bazel-bin/test/src/test_suite/test_suite_runner bazel-bin/aro_c3 test/test_suite -s         # only #skip cases
```

Options: `-s`/`--skipped` (run only skipped cases), `--threads N`,
`--no-terminal`, `--cc PATH` (needed by `run` cases), `--support DIR`
(default: the nearest `_support/`), `--failures FILE` (write
`<path>\t<reason>` per failed case). `ARO_C3_OPT` (default `-O1`) and
`ARO_C3_FLAGS` apply to `run` cases.

Each case is written to a per-worker directory that also holds a copy of
`test/test_suite/_support/` (`include/`, `embed/`, `frameworks/`), and the
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

env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //test:regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt //test:regression
```

Each `c3_test` target is built with `c3c compile-test` and run through a small
launcher (`tools/c3_test_launcher.sh.tpl`) that maps Bazel test options onto
the C3 test runner and disables ANSI colors in `test.log`:

```sh
# Run only tests whose name contains "generic" (--test-filter).
bazel test //test/unit/parser:parser_expression_tests --test_filter=generic
# Pass runner flags through: show output, skip leak checks, log level.
bazel test //test/unit/parser:parser_expression_tests --test_output=all \
  --test_arg=--test-show-output --test_arg=--test-noleak
# Run the test binary directly with the same launcher.
bazel run //test/unit/parser:parser_expression_tests -- --test-filter generic
```

The public suites are `//test:unit`, `//test:integration`, `//test:records`,
and their aggregate `//test:regression`. Run one suite directly to focus a
configuration. Bazel's recursive `//test/...` pattern also discovers the
separate replay target, so it is not the default full-suite command. Replay
and AFL targets are opt-in:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //test/src/fuzz:replay_test
# AFLplusplus is needed only for this target; AFL_CC names afl-clang-fast.
env C3C="$C3C" AFL_CC=/path/to/afl-clang-fast "$BAZEL" --output_user_root="$BAZEL_ROOT" test \
  --action_env=AFL_CC //test/src/fuzz:afl_fuzz
```

The profiling feature tests are part of `//test:unit`. The enabled variant
defines the Tracy feature flags and links the local profiling stub, so it does
not require an external Tracy client library.

The runner unit tests are part of `//test:unit`; they can also be run alone:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //test/src/manifest:runner_tests
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt //test/src/manifest:runner_tests
```

The manifest runner (`//test/src/manifest:runner_lib`, a port of the former
`test/runner.zig`) reads Aro's `/** manifest: */` case format with `ast/` and
`expanded/` goldens. Its only current suite is
`//test/src/probes:assembly_regression`, driven by the case list
`test/regression/assembly/cases.txt` (`name.c [result=pass|fail|unsupported]
[exit=N] [signal=N] [fatal]`; `//` starts a comment line).

## GCC testsuite

`test/gcc/` is a copy of the GCC C testsuite files the harness uses (top-level
`gcc.c-torture/{compile,execute,execute/ieee}` and `gcc.dg`, plus files they
include). It is GPL-3.0-or-later test input; `test/gcc/SOURCE` records the GCC
commit.

`//test/src/gcc` (`gcc_testsuite.c3`) treats GCC's expectations as golden:
torture `compile` cases must compile cleanly, torture `execute`/`ieee` cases must
build, link and exit 0, and `gcc.dg` cases must report an error/warning on every
`dg-error`/`dg-warning` line (message text is not compared) and no other errors.
Panics and signals are CRASH, backend `TODO` errors UNSUPPORTED, and unknown
effective targets SKIP (with the reason).

```sh
bazel test //test/src/gcc:gcc_testsuite          # 4 sharded suites, part of //...
bazel run //test/src/gcc:gcc_testsuite_update_baseline
# ad-hoc subset from the repo root (no baseline update outside `bazel run`):
bazel-bin/test/src/gcc/gcc_testsuite_update_baseline --suite dg --filter 'pr1*' --out /tmp/aro-gcc
bazel test //test/src/gcc:gcc_testsuite_tests   # directive parser checks
```

The targets are gated by `test/src/gcc/baseline.json`: only a new
non-PASS result (or a status change such as FAIL -> CRASH) fails; flips to or from
TIMEOUT are reported but not gated. Each test's undeclared outputs hold
`summary.md` (the worklist: crashes first, then failure groups) and
`results.jsonl` (one record per case with the command and output).
`--zig-arocc <binary>` adds an informational differential run against Zig arocc.

## Record layout fixtures

See [record_readme.md](record_readme.md) for the fixture format, target/define
reproduction, and record report interpretation.

`//test/src/records:record_regression` runs the C3 record runner against
`test/records`. The runner parses every `// MAPPING|...` comment and executes
each supported target/define tuple. Run the focused record targets with:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg \
  //test/src/records:record_runner_tests //test/src/records:record_regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt \
  //test/src/records:record_runner_tests //test/src/records:record_regression
```

The record port currently runs the full mapping inventory; it has no CLI option
to filter by one target or define. To reproduce one mapping, take its source
file, define, and target from a `MAPPING` comment and invoke the compiler with
the same options the port constructs. For example, the `ONE` mapping in
`test/records/0001_test.c` includes `x86_64-x86_64-linux-gnu:Gcc`:

```sh
/absolute/path/to/arocc test/records/0001_test.c \
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
