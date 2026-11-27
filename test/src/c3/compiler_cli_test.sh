#!/usr/bin/env bash
set -euo pipefail
compiler="$1"
work="${TEST_TMPDIR:?}/aro-c3-cli"
mkdir -p "$work"
printf 'module smoke;\nfn int main() { return 42; }\n' > "$work/good.c3"
printf 'module broken;\nfn int main( {\n' > "$work/bad.c3"
"$compiler" --help > "$work/help"
grep -q 'Usage: aro_c3' "$work/help"
"$compiler" --version > "$work/version"
grep -q 'aro_c3' "$work/version"
"$compiler" --check "$work/good.c3"
"$compiler" --parse-only "$work/good.c3"
expect_failure() {
    local message="$1"
    shift
    if "$compiler" "$@" > "$work/stdout" 2> "$work/stderr"; then
        echo "Expected failure: $*" >&2
        exit 1
    fi
    grep -q "$message" "$work/stderr"
}
expect_failure 'Error' --check "$work/bad.c3"
expect_failure 'code generation is not implemented' "$work/good.c3"
expect_failure 'no input files' --check
expect_failure 'requires a value' --target
expect_failure 'invalid target' --check --target invalid "$work/good.c3"
expect_failure 'unknown option' --unknown
expect_failure 'choose either' --check --parse-only "$work/good.c3"
