## Integration tests

These test cases are used by the `test-integration` build step.

A integration test case consists of a single `.c` file containing a test manifest
embedded inside a `/** manifest: ... */` comment that can be placed anywhere in the file
but preferably in the bottom.

The cases are executed with `test/cases` as the CWD.

### Manifest

The manifest starts with the test type followed by key-value pairs of arugments
and finally by trailing data.

#### Test kinds

Currently 4 test kinds are supported:

- `syntax`: Run the compiler on the test case with `-fsyntax-only` and check the resulting errors
  against those potentially specified in the trailing data. `--verbose-ast` is also used
  the output of which can be checked against an expected result in `test/cases/ast/<test name>`.

- `syntax_ignore_errors`: Same as syntax but any errors are ignored.

- `expand`: Run the compiler on the test case with `-E -P`, checks any warnings match those specified
  in the trailing data, and that the expansion output matches the expected result specified in
  `test/cases/expanded/<test name>`.

- `expand_partial`: Like expand but only checks that the result contains the output
  specified in the trailing data instead of a complete match.

- `expand_error`: Like expand but checks errors like syntax instead of the expansion output.
  (there is no expansion output when the preprocessor emits an error)

#### Arguments

Currently 3 different arguments are supported:

- `skip`: Specify reason why some check was skipped. The manifest can have multiple `skip`s.

- `args`: Takes an array of arguments to be passed to the compiler.

- `env`: Takes an array of KEY=VALUE pairs to be specified in the environment variables
  passed to the compiler.

### Example manifest

```c
/** manifest:
syntax
args = -Iinclude -Wfoo
skip = thing is broken
env = MYENV=1

foo.c: 1:4: error: something went wrong
*/
```

---

## C3 migration runner (Bazel)

`test/migration/runner.c3` is the C3 port of `test/runner.zig`. It runs the same
manifests with the same flags and checks, and it adds gate modes for the C3 port.
Run Bazel as `plan/PARALLEL.md` describes:

```sh-session
B="env C3C=/home/user/tools/c3/c3c /home/user/tools/bazel --output_user_root=/home/user/tools/bazel_root"
$B test //test/migration:runner_tests            # runner unit tests (fake child compiler)
$B test -c opt //test/migration:runner_tests
$B build //test/migration:runner                 # the runner CLI
bazel-bin/test/migration/runner <arocc-exe> test/cases   # like `zig build test-integration`
```

The runner takes the compiler executable as its first argument. If you give only
`<cases-dir>`, it reads the compiler path from `ARO_RUNNER_EXE`. The runner does not
search `PATH`: a relative path resolves against the runner's working directory.

Options:

- `--cases FILE`: run only the cases listed in FILE (a per-stage case list). The run
  fails if an entry names a file that does not exist, or if the selection is empty.
- `--all` (requires `--cases`): run the whole corpus. Every `.c` file in the directory
  must appear in the list; any file not in the list fails the run.
- `--gate` (requires `--cases`): each case's whole outcome (result, exit status,
  terminating signal, `fatal error:` diagnostic) must equal its listed expectation.
  The runner.zig mode accepts any exit status; gate mode does not.
- `--log FILE`: write a per-case TSV of outcomes. The runner writes it after all cases
  have run.

Case list format, one entry per line. Lines starting with `//` are comments; `#` can't
start a comment because case names such as `#pragma pack msvc.c` begin with it:

```
// stage: preprocessor
#elifndef.c
#embed.c exit=1
hello world.c result=unsupported
crashy case.c result=fail signal=11
missing include.c exit=1 fatal
```

The file name runs up to the first `.c` that is followed by whitespace or the end of the
line, so names can contain spaces. When a key is left out, the runner expects
`result=pass exit=0 signal=0` with no fatal diagnostic.

The runner keeps runner.zig's behavior:

- `expand_partial` passes when stdout ends with `expanded/<case>.c`, not when stdout
  merely contains it, whatever the "Test kinds" section above says.
- A missing `ast/<case>.c` is allowed.
- A missing `expanded/<case>.c` is a failure.
- `compare_output` is still unimplemented. The runner reports it as `unsupported`,
  never as passed.

The runner normalizes nothing. Every case runs with the case directory as its working
directory and gets only the case's basename, so its output contains no host paths.
Child stdout and stderr are always read through pipes.

`//test/migration:reference_regression` runs the whole corpus with a reference
compiler and checks the counts against `test/migration/baseline.json`. No Zig
executable is available, so the target is tagged `manual`. Without a compiler it fails
on purpose and prints `reference executable unavailable`. To run it:

```sh-session
$B test //test/migration:reference_regression --test_env=ARO_REFERENCE_EXE=/abs/path/to/arocc
```

---

## Running fuzz tests using AFLplusplus

Fuzz testing requires [AFLplusplus](https://github.com/AFLplusplus/AFLplusplus). Run `zig build fuzz` to build the fuzz target,
then `afl-fuzz -i test/cases -o test/fuzz-output -- ./zig-out/bin/arofuzz`

A Dockerfile is provided to make it easier to get started with fuzzing. It requires two build args,
`ZIG_VERSION` and `ZIG_PUBKEY`. `ZIG_VERSION` should be the release filename from https://ziglang.org/download/, _without_
the `.tar.xz` extension. `ZIG_PUBKEY` should be the minisign public key on https://ziglang.org/download/. You can also
provide `USER_ID` and `GROUP_ID` so that files created in the container have the same user id and group id as files on
your host system.

Please read https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/fuzzing_in_depth.md#0-common-sense-risks before
running the fuzzer on your system.

```sh-session

docker build -t aro-fuzz \
    --build-arg ZIG_VERSION=zig-linux-x86_64-0.12.0-dev.1595+70d8baaec \
    --build-arg ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U \
    --build-arg USER_ID=$(id -u ${USER}) \
    --build-arg GROUP_ID=$(id -g ${USER}) \
    test/docker/fuzz
docker run --rm -it -v $PWD:/arocc -w /arocc --mount type=tmpfs,destination=/ramdisk -e AFL_TMPDIR=/ramdisk aro-fuzz
zig build fuzz  # This might take a while
afl-fuzz -i test/cases -o test/fuzz-output -- ./zig-out/bin/arofuzz
```

---

## Running fuzz tests via Zig build system

```sh-session
zig build test-unit --fuzz
```
