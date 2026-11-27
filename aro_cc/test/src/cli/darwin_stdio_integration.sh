#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "SKIP: requires ARM64 macOS"
    exit 0
fi

aro="$1"
source="$2"
binary="${TEST_TMPDIR:?}/darwin-stdio"

"$aro" -fsyntax-only "$source"
"$aro" "$source" -o "$binary"
output="$("$binary")"
[[ "$output" == "aro stdio" ]]
