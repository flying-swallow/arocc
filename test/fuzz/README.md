# C3 fuzz harness

`main.c` is the persistent AFL++ shared-memory entrypoint. `fuzz_lib.c3`
exposes the C ABI function it calls. `replay_test` runs the same entrypoint on
the checked-in deterministic corpus without AFL. The seeds cover valid and
malformed C, recursive macros, a 100-level parenthesized declarator, and an
embedded NUL. The replay test repeats each input and revisits valid input after
malformed/stress cases.

| Seed | Bytes | SHA-256 |
| --- | ---: | --- |
| `corpus/valid.c` | 132 | `8fa71473d7c635cdc9e2d0244f5e2c42cc56f4141da2dd2ae047f907c0ecd5d2` |
| `corpus/malformed.c` | 63 | `2082224ba924bfccfa1068f7348f599278521492ebee48b00d8c635b9e938abd` |
| `corpus/recursive_macro.c` | 37 | `479bc8926c4cc8e14dabdcffbfcc2cae288c2ee5f35c37f3dedea0cae70e6ee3` |
| `corpus/deep_declaration.c` | 202 | `a4c9a09c1d86a87ec7455bd9ec29b6c2ad2857d6b538dd9a33d81141097c2cc8` |
| `corpus/embedded_nul.bin` | 31 | `6d184f48f44ecbd933e79221e94e01f2a7c62d2f59d449ea6e35151c74e3f123` |

## Replay checks

Use the pinned local compiler explicitly when running Bazel:

```sh
C3C=/home/michaelpollind/opt/c3/c3c bazel --batch --output_user_root=/tmp/arocc-fuzz-bazel-dbg-final test --experimental_collect_system_network_usage=false -c dbg //src/tests/fuzz:replay_test --test_output=errors
C3C=/home/michaelpollind/opt/c3/c3c bazel --batch --output_user_root=/tmp/arocc-fuzz-bazel-opt-final test --experimental_collect_system_network_usage=false -c opt //src/tests/fuzz:replay_test --test_output=errors
```

The compiler used for this work is C3 0.8.6 pre-release, Git revision
`61d33ae1dce61f80dd81660db2f9910208c74284` (LLVM 22.1.8). The replay target
exercises only this C3 implementation; it is not executable parity evidence
against the preserved Zig source.

On 2026-11-12 UTC (2026-11-11 America/Los_Angeles), the debug and optimized commands both analyzed
`//src/tests/fuzz:replay_test`, then failed while compiling the C3 library. The
pinned compiler reported syntax errors in the concurrently modified,
out-of-ticket `src/type_builder.c3` at lines 385, 434, 549, and 606. Neither
configuration ran the replay test. An earlier attempt also failed while
computing the repository mapping because fetching `rules_shell/0.8.0` from the
Bazel Central Registry returned `Operation not permitted`.

## Current parser limit

`src/parser_declaration.c3` provides callback wiring, but the declaration,
type-name, typed-type-name, and local-declaration callbacks are not implemented
in the current port. `fuzz_lib.c3` currently binds an empty
`DeclarationParser`, so valid and malformed inputs exercise preprocessing and
parser recovery, not complete C declaration parsing or meaningful declaration
tree traversal. The deterministic corpus is ready, but parser coverage remains
incomplete until the declaration grammar is implemented and connected.

## Allocation cap limit

The bridge uses a fixed 20 MiB arena for allocations routed through
`FuzzAllocator` and resets the thread's temporary pool after each input. This
does not impose a 20 MiB total-process allocation cap. In the pinned C3
compiler's POSIX `VMEM_TEMP` implementation, `TempAllocator` uses a separate
512 MiB Vmem reservation, and derived `@pool()` scopes use the same mechanism.
Those allocations bypass the arena's OOM flag and recovery path. The aggregate
20 MiB cap and recoverable OOM behavior therefore remain incomplete; a separate
ticket covers bounded temporary allocations across the compiler path.

## AFL++ smoke campaign

Install AFL++ with `afl-clang-fast` and `afl-fuzz` available, then build and
run the instrumented C harness for a bounded 10-second campaign:

```sh
AFL_CC=/absolute/path/to/afl-clang-fast C3C=/home/michaelpollind/opt/c3/c3c bazel --batch --output_user_root=/tmp/arocc-fuzz-bazel-output build --experimental_collect_system_network_usage=false --action_env=AFL_CC //src/tests/fuzz:afl_fuzz
afl-fuzz -i test/fuzz/corpus -o /tmp/arocc-fuzz-afl-out -V 10 -- bazel-bin/test/fuzz/afl_fuzz
```

The AFL compiler is optional: ordinary C3 builds and `replay_test` do not
depend on it. Neither `afl-clang-fast` nor `afl-fuzz` was installed in the
executor environment, so the planned 10-second smoke campaign was not run and
no coverage result is claimed. The installed C3 compiler reports LLVM and C
backends, but its CLI exposes no backend-selection option; `--cflags` only
applies when using the C backend. There is no evidence here that AFL
instrumentation reaches C3 compiler code, so coverage acceptance remains
incomplete.
