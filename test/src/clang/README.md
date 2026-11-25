# Clang C frontend compatibility worklist

The snapshot in `test/clang` is independent of the original LLVM checkout.
Its `SOURCE.json` records the commit, areas, inventory, and SHA-256 hashes;
`LICENSE.TXT` retains Apache-2.0 WITH LLVM-exception terms. Upstream inputs are
unchanged. Non-C primary tests are excluded; Inputs trees and other support
files are retained. No installed Clang, lit, or FileCheck is required.

Run a subset:

```
bazel run //test/src/clang:clang_testsuite_run -- --suite Sema --filter 'vla.c' --out /tmp/clang-results
bazel test //test/src/clang:clang_testsuite_lexer --test_output=errors
```

`clang_testsuite` aggregates all five manual, sharded suite targets. These are
compatibility worklists and can fail. The normally registered
`clang_testsuite_tests` checks the harness itself. Each logical RUN command
has its own stable `area/file.c#N` result. Live progress uses the GCC runner format, for example `[    1/1] FAIL clang:Sema/vla.c#1 ... (0.01s)`. The `#N` identifies the logical RUN command within that file. Failed commands and example files for unsupported groups also appear in the Markdown summary. Reports contain commands, captured
output, exit codes, and unsupported reasons. Reports are `results.jsonl` and
`summary.md`, placed in `--out` or Bazel's undeclared outputs directory.

Direct cc1 commands disable implicit system include paths (`-nostdlibinc`) but
keep Aro's builtin headers, like lit's `%clang_cc1`. Macro-backtrace notes
(`expanded from ...`) are not counted, matching clang `-verify`.

The C3 runner supports direct `%clang_cc1`/`%clang` syntax checks, `not`, C
standards, defines, includes, target selection, warning flags, verification
prefixes, exact diagnostic counts, absolute/relative source lines, notes,
no-diagnostics, and explicit severity exclusions. It compares severity,
source file, line, and count, not wording or regex content. Unknown compiler
options are unsupported; flags are never silently dropped. Ordinary syntax
checks use the process exit status. Signals and timeouts always fail.

Pipelines, FileCheck, AST/IR checks, generated inputs, unknown substitutions,
unsupported annotation forms, `not` combined with `-verify`, and XFAIL conditions are unsupported. Feature
handling currently recognizes system-linux, system-windows, and
x86-registered-target; unknown conditions are unsupported, known unmet
requirements skip. Unknown diagnostic locations, including external-file
and wildcard locations, are unsupported. Diagnostics in other files cause a
mismatch rather than being silently ignored. Headers are not independently
executed. The shell is never used to execute upstream RUN comments.

Refresh or verify the snapshot:

```
python3 tools/import_clang_tests/import_clang_tests.py /path/to/llvm-project
python3 tools/import_clang_tests/import_clang_tests.py /path/to/llvm-project --check
```

The importer uses Python's standard library and Git only; test execution is
implemented in C3. Refreshes overwrite snapshot files and report stale prior
inventory entries under `--check`; remove obsolete entries explicitly when
updating to a different upstream revision. The runner reuses the GCC
runner's Tcl-like word splitter and small string helpers, compiled with its
main disabled, while verification and command translation are Clang-specific.
