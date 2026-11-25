#!/usr/bin/env bash
# The C3 frontend must stay isolated from the C frontend: no references to
# aro::frontend::c::* (or the aro::api facade, which aliases C modules).
set -euo pipefail
status=0
for f in "$@"; do
	# Line comments are ignored so the rule itself can be documented.
	if sed -E 's://.*$::' "$f" | grep -nE 'frontend::c([^3a-zA-Z0-9_]|$)|aro::api\b'; then
		echo "isolation violation in $f" >&2
		status=1
	fi
done
exit $status
