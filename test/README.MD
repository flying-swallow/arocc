## Layout

`test/` holds fixtures only (one Bazel package, `//test`). Test code lives in
`src/tests` (unit tests), `src/tests/migration` (C3 runners, probes, regression
and native drivers) and `src/tests/fuzz`.

| Path | Contents | Used by |
|---|---|---|
| `cases/` | integration corpus (manifest-driven `.c` cases, goldens) | `test/runner.zig`, `//src/tests/migration:frontend_regression`, … |
| `records/` | record-layout corpus | `test/record_runner.zig`, `//src/tests/migration:record_regression` |
| `unit/` | number/float/literal vectors, `profiling_stub.c` | `//src/tests:*_vector_tests`, `literal_tests`, `profiling_*_tests` |
| `regression/<area>/` | `cases.txt` (+ `fixtures/`) per area | `//src/tests/migration:<area>_regression` |
| `native/` | native IR backend cases, backend CLI sources | `//src/tests/migration:native_*` |
| `reference/` | `baseline.json`, reference-gate results and logs | `//src/tests/migration:reference_regression`, `run_reference_gate.py` |
| `portability/` | runfiles path containing a space | `//src/tests/migration:runfiles_portability_integration` |
| `fuzz/` | fuzz corpus, `main.c`, `fuzz_lib.zig` | `//src/tests/fuzz:*`, `build.zig` |
| `zig/` | Zig reference probes (`*_probe.zig`, `bigint_vectors.zig`) | vector regeneration |
| `runner.zig`, `record_runner.zig` | Zig reference harness | `build.zig` |

Single fixture files are addressable as `//test:<path>`; directories have
filegroups (`//test:test_cases`, `//test:regression_<area>_fixtures`, …).

## Integration fixtures

The C fixtures under `test/cases` drive the integration runner. A case is a
`.c` file with a `/** manifest: ... */` comment, preferably near the bottom.
The runner starts the compiler in the case file's directory and passes the
case's basename, so includes and golden files resolve from that directory.

### Manifest

The first manifest line is the test kind. Following lines contain `key = value`
options; a blank line ends the options and starts the expected diagnostic or
output data. Diagnostic lines are checked in order as substrings of compiler
diagnostics. Output goldens are compared byte for byte, without normalization.

#### Test kinds

Six kinds are recognized:

- `syntax`: run with `-fsyntax-only --verbose-ast`, check diagnostics, and
  compare stdout with `test/cases/ast/<case>.c` when that file exists. The AST
  golden is optional.
- `syntax_ignore_errors`: use the same compiler flags and optional AST golden,
  but do not compare diagnostics.
- `expand_error`: run with `-E -P` and check diagnostics; no expansion golden
  is required.
- `expand`: run with `-E -P`, check diagnostics, and compare stdout exactly
  with `test/cases/expanded/<case>.c`.
- `expand_partial`: run with `-E -P`, check diagnostics, and require stdout to
  end with the exact bytes in `test/cases/expanded/<case>.c`. This is a suffix
  match, not a full-output comparison; the expected file must exist.
- `compare_output`: recognized by the manifest parser, but not implemented by
  either runner. It is reported as `unsupported`; the compiler is not run for
  that case.

#### Options

- `skip = reason`: record a reason for a check omitted by the fixture. Multiple
  `skip` lines are allowed.
- `args = ...`: pass compiler arguments. The current parser splits this value
  on spaces.
- `env = KEY=VALUE ...`: set child environment variables. Entries are split
  on spaces; overrides replace matching inherited variables.

Example:

```c
/** manifest:
syntax
args = -Iinclude -Wfoo
skip = thing is broken
env = MYENV=1

foo.c: 1:4: error: something went wrong
*/
```

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
bazel test //src/tests:parser_expression_tests --test_filter=generic
# Pass runner flags through: show output, skip leak checks, log level.
bazel test //src/tests:parser_expression_tests --test_output=all \
  --test_arg=--test-show-output --test_arg=--test-noleak
# Run the test binary directly with the same launcher.
bazel run //src/tests:parser_expression_tests -- --test-filter generic
```

The public suites are `//test:unit`, `//test:integration`, `//test:records`,
and their aggregate `//test:regression`. Run one suite directly to focus a
configuration. Bazel's recursive `//test/...` pattern also discovers the
separate replay target, so it is not the default full-suite command. Replay
and AFL targets are opt-in:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //src/tests/fuzz:replay_test
# AFLplusplus is needed only for this target; AFL_CC names afl-clang-fast.
env C3C="$C3C" AFL_CC=/path/to/afl-clang-fast "$BAZEL" --output_user_root="$BAZEL_ROOT" test \
  --action_env=AFL_CC //src/tests/fuzz:afl_fuzz
```

The profiling feature tests are part of `//test:unit`. The enabled variant
defines the Tracy feature flags and links the local profiling stub, so it does
not require an external Tracy client library.

The runner unit tests are part of `//test:unit`; they can also be run alone:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg //src/tests/migration:runner_tests
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt //src/tests/migration:runner_tests
```

The manual reference comparison needs a reference compiler executable. An
optional `ARO_REFERENCE_CASES_DIR` points it at a frozen fixture directory:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test \
  //src/tests/migration:reference_regression \
  --test_env=ARO_REFERENCE_EXE=/absolute/path/to/reference/arocc \
  --test_env=ARO_REFERENCE_CASES_DIR=/path/to/frozen-worktree/test/cases
```

To run selected fixtures with a compiler executable, write their filenames to
a case list and run the CLI. The compiler executable is a separate override
from `C3C`: pass it as `<arocc-exe>` or set `ARO_RUNNER_EXE` when omitting that
positional argument.

```sh
cat > /tmp/focused-cases.txt <<'EOF'
unknown pragmas.c
EOF

env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" run -c dbg //src/tests/migration:runner -- \
  --cases /tmp/focused-cases.txt /absolute/path/to/arocc test/cases
```

Use an absolute compiler path where possible. The runner does not search
`PATH`; relative compiler paths resolve against the runner's working directory.
A focused list may contain one or more `.c` basenames, including names with
spaces. Lines beginning with `//` are comments; `#` is not a comment marker
because names such as `#pragma pack msvc.c` are valid. For example:

```text
// stage: preprocessor
#elifndef.c
#embed.c result=fail exit=1
hello world.c result=unsupported
crashy case.c result=fail signal=11
missing include.c exit=1 fatal
```

The filename extends through the first `.c` followed by whitespace or end of
line. The result, exit, signal, and fatal fields are expectations used by
`--gate`; omitted fields default to `result=pass exit=0 signal=0` with no fatal
diagnostic. Without `--gate`, the runner checks each fixture's manifest
diagnostics and goldens while preserving the legacy runner's behavior of
accepting any child exit status. Add `--log /tmp/outcomes.tsv` to save per-case
result, exit, signal, fatal-diagnostic, byte-count, and gate columns after the
cases run.

For `--gate`, provide `--cases FILE --gate`; the default expected result is
`result=pass exit=0 signal=0` with no fatal diagnostic. Case-list entries can
override `result` (`pass`, `fail`, or `unsupported`), `exit`, `signal`, and
`fatal`. Gate mode checks the complete outcome against that expectation. Use
`--all` with `--cases` to require a full corpus classification: missing files,
an empty selection, or unlisted corpus files are configuration errors. A case
list by itself can intentionally select only a subset.

### Reading integration reports

- `passed` counts cases whose implemented checks completed successfully.
  `failed` includes fixture mismatches, malformed manifests, spawn errors, and
  crashes. Child nonzero exits are shown separately and do not alone fail a
  fixture in non-gate mode.
- `unsupported (compare_output)` counts cases the runner did not execute. They
  are not passes, even when the suite prints `RESULT: PASS`.
- `known skips` counts `skip =` annotations from cases that reached PASS after
  the implemented checks ran. The annotated check did not run; the annotation
  is not a passing result for that omitted check.
- In gate mode, `gate mismatches` compares each whole outcome with its case-list
  expectation. An expected `unsupported` outcome can match the gate while still
  remaining unsupported and unexecuted.
- `RESULT: ERROR` means selection or configuration was invalid. Check
  `selected`, `executed`, `unsupported`, and `known skips` before treating a
  `RESULT: PASS` as evidence of coverage; unsupported cases and skipped checks
  never count as executed passing coverage.

## Record layout fixtures

See [record_readme.md](record_readme.md) for the fixture format, target/define
reproduction, and record report interpretation.

`//src/tests/migration:record_regression` runs the C3 record runner against
`test/records`. The runner parses every `// MAPPING|...` comment and executes
each supported target/define tuple. Run the focused record targets with:

```sh
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c dbg \
  //src/tests/migration:record_runner_tests //src/tests/migration:record_regression
env C3C="$C3C" "$BAZEL" --output_user_root="$BAZEL_ROOT" test -c opt \
  //src/tests/migration:record_runner_tests //src/tests/migration:record_regression
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

## Legacy/reference Zig workflows

The Zig runner and build commands below are retained only as legacy/reference
workflows. Use the C3 and Bazel commands above for the current suite.

The pinned Zig reference gate can be reproduced with:

```sh
# Legacy/reference Zig gate; not the current C3/Bazel suite.
python3 src/tests/migration/run_reference_gate.py \
  --source-tree /path/to/frozen-worktree \
  --zig /path/to/zig-0.18.0-dev.828+9da287565
```

This helper runs the historical `build`, `test-unit`, `test-integration`,
`test-record`, and `test-fmt` Zig commands and writes its results to
`test/reference/reference-results.json`. The C3 Bazel target
`//src/tests/migration:reference_regression` is a separate, manual target requiring
`ARO_REFERENCE_EXE`; it is not a Zig invocation.

### Legacy/reference Zig fuzzing with AFLplusplus

Fuzz testing requires [AFLplusplus](https://github.com/AFLplusplus/AFLplusplus).
The existing Zig fuzz target can be built and run as follows:

```sh-session
# Legacy/reference Zig commands.
zig build fuzz
afl-fuzz -i test/cases -o test/fuzz-output -- ./zig-out/bin/arofuzz
```

A Dockerfile is provided to make it easier to get started with fuzzing. It
requires build args `ZIG_VERSION` and `ZIG_PUBKEY`. `ZIG_VERSION` is the Zig
release filename without `.tar.xz`; `ZIG_PUBKEY` is the minisign public key
from the Zig download page. `USER_ID` and `GROUP_ID` can match file ownership
with the host. Please read
[AFLplusplus' common-sense risks](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/fuzzing_in_depth.md#0-common-sense-risks)
before running the fuzzer.

The legacy/reference Docker workflow is:

```sh-session
docker build -t aro-fuzz \
    --build-arg ZIG_VERSION=zig-linux-x86_64-0.12.0-dev.1595+70d8baaec \
    --build-arg ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U \
    --build-arg USER_ID=$(id -u ${USER}) \
    --build-arg GROUP_ID=$(id -g ${USER}) \
    test/docker/fuzz
docker run --rm -it -v $PWD:/arocc -w /arocc --mount type=tmpfs,destination=/ramdisk -e AFL_TMPDIR=/ramdisk aro-fuzz
```

The old Zig fuzz-test command is also retained for reference:

```sh-session
# Legacy/reference Zig command.
zig build test-unit --fuzz
```
