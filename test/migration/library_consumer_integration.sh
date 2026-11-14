#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
	printf 'usage: %s <aro distribution archive-or-directory> <c3c executable-or-install-dir> [bazel executable]\n' "$0" >&2
	exit 2
fi

distribution=$1
c3c_override=$2
bazel_command=${3:-bazel}
if [[ -d "$c3c_override" ]]; then
	c3c_override=$(cd -- "$c3c_override" && pwd -P)
elif [[ "$c3c_override" != /* ]]; then
	c3c_override=$(cd -- "$(dirname -- "$c3c_override")" && pwd -P)/$(basename -- "$c3c_override")
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/aro-consumer.XXXXXXXX")
# Bazel leaves tree artifacts read-only; make them writable before removing.
trap 'chmod -R u+w -- "$tmp_root" 2>/dev/null; rm -rf -- "$tmp_root"' EXIT

if [[ -f "$c3c_override" && -d "$(dirname -- "$c3c_override")/lib/std" ]]; then
	# Bazel exposes its compiler as `compiler` and the stdlib as a sibling
	# runfiles directory. Create the conventional c3c install layout expected
	# by the isolated repository rule.
	compiler_file=$c3c_override
	compiler_root=$(dirname -- "$compiler_file")
	if [[ "${compiler_file##*/}" == c3c || "${compiler_file##*/}" == c3c.exe ]]; then
		c3c_override=$compiler_root
	else
		c3c_override="$tmp_root/c3c install"
		mkdir -p -- "$c3c_override"
		ln -s -- "$compiler_file" "$c3c_override/c3c"
		ln -s -- "$compiler_root/lib" "$c3c_override/lib"
	fi
fi

extract_dir="$tmp_root/extracted public package"
mkdir -p -- "$extract_dir"
if [[ -d "$distribution" ]]; then
	cp -R -- "$distribution"/. "$extract_dir"/
else
	tar -xf "$distribution" -C "$extract_dir"
fi

module_file=$(find "$extract_dir" -type f -name MODULE.bazel -print -quit)
if [[ -z "$module_file" ]]; then
	printf 'distribution has no MODULE.bazel: %s\n' "$distribution" >&2
	exit 1
fi
package_root=$(dirname -- "$module_file")
if [[ "$package_root" != *" "* ]]; then
	printf 'distribution was not extracted under a path containing spaces: %s\n' "$package_root" >&2
	exit 1
fi
consumer_dir="$tmp_root/consumer-workspace"
mkdir -p -- "$consumer_dir"
cp -- "$script_dir/consumer_workspace/MODULE.bazel" "$consumer_dir/MODULE.bazel"
cp -- "$script_dir/consumer_workspace/consumer.c3" "$consumer_dir/consumer.c3"
cp -- "$script_dir/library_consumer.BUILD.bazel" "$consumer_dir/BUILD.bazel"

if [[ "$bazel_command" == */* ]]; then
	bazel_bin=$(cd -- "$(dirname -- "$bazel_command")" && pwd -P)/$(basename -- "$bazel_command")
else
	bazel_bin=$(command -v -- "$bazel_command")
fi
if [[ -z "$bazel_bin" || ! -x "$bazel_bin" ]]; then
	printf 'Bazel executable not found: %s\n' "$bazel_command" >&2
	exit 1
fi

# Retain normal host tools, but remove zig from PATH even when it shares a
# directory with the system compiler. That directory gets an executable-only
# symlink view with zig omitted; the C3 compiler itself is selected directly
# through the explicit C3C repository override below.
filtered_bin="$tmp_root/path without zig"
mkdir -p -- "$filtered_bin"
filtered_path=
old_ifs=$IFS
IFS=:
for directory in $PATH; do
	[[ -n "$directory" ]] || directory=.
	[[ -d "$directory" ]] || continue
	directory=$(cd -- "$directory" && pwd -P)
	if [[ -x "$directory/zig" || -x "$directory/zig.exe" ]]; then
		for candidate in "$directory"/*; do
			[[ -f "$candidate" && -x "$candidate" ]] || continue
			name=${candidate##*/}
			[[ "$name" == zig || "$name" == zig.exe ]] && continue
			[[ -e "$filtered_bin/$name" ]] || ln -s -- "$candidate" "$filtered_bin/$name"
		done
		filtered_path="${filtered_path:+$filtered_path:}$filtered_bin"
	else
		filtered_path="${filtered_path:+$filtered_path:}$directory"
	fi
done
IFS=$old_ifs
export PATH=$filtered_path
if command -v zig >/dev/null 2>&1; then
	printf 'zig is still visible on PATH after filtering\n' >&2
	exit 1
fi

cd -- "$consumer_dir"
"$bazel_bin" --batch --output_user_root="$tmp_root/bazel-output-root" build \
	--override_module="aro=$package_root" \
	--repo_env="C3C=$c3c_override" \
	//:consumer
