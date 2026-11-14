#!/bin/sh
set -eu

compiler=${AFL_CC:-afl-clang-fast}
if ! command -v "$compiler" >/dev/null 2>&1; then
	printf 'AFL compiler not found: %s (set AFL_CC and pass --action_env=AFL_CC)\n' "$compiler" >&2
	exit 127
fi
exec "$compiler" "$@"
