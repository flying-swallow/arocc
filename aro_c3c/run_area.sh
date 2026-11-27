#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
compiler="$1"
c3c="$2"
area="$3"
stdlib="$(dirname "$c3c")/lib/std"
exec python3 -I "$script_dir/runner.py" \
    --compiler "$compiler" \
    --stdlib "$stdlib" \
    --suite-root "$script_dir/test_suite" \
    --area "$area"
