#!/usr/bin/env bash
# Differential lexer check: compare `lex_probe` token streams with `c3c -E`
# (lex only) over every .c3 file under the given c3c checkout.
#   bazel build //aro_cc/test/src/c3:lex_probe
#   aro_cc/test/src/c3/lex_diff.sh ~/projects/c3c [path/to/c3c]
set -euo pipefail
repo=${1:?c3c checkout}
c3c=${2:-$repo/build/c3c}
probe=${PROBE:-bazel-bin/aro_cc/test/src/c3/lex_probe}
ok=0; bad=0
while IFS= read -r f; do
	a=$("$c3c" -E compile "$f" 2>/dev/null | grep -v '^#' || true)
	b=$("$probe" "$f" 2>/dev/null | grep -v '^#' || true)
	if [[ "$a" == "$b" ]]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "MISMATCH $f"; fi
done < <(find "$repo/lib/std" "$repo/test/test_suite" "$repo/test/unit" -name '*.c3' | sort)
echo "match=$ok mismatch=$bad"
[[ $bad -eq 0 ]]
