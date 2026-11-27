#!/usr/bin/env bash
# The C3 frontend must stay isolated from the C frontend: no references to
# aro::frontend::c::* (or the aro::api facade, which aliases C modules).
set -euo pipefail
status=0
pattern='frontend::c([^3a-zA-Z0-9_]|$)|aro::api\b'
if [[ "${1:-}" == "--shared" ]]; then
	pattern='aro::frontend::|aro::api\b'
	shift
elif [[ "${1:-}" == "--c" ]]; then
	pattern='aro::frontend::c3([^a-zA-Z0-9_]|$)'
	shift
fi
for f in "$@"; do
	# Line comments are ignored so the rule itself can be documented.
	if sed -E 's://.*$::' "$f" | grep -nE "$pattern"; then
		echo "isolation violation in $f" >&2
		status=1
	fi
done
exit $status
