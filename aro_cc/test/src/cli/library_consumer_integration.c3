// Build the standalone consumer workspace against the extracted aro
// distribution: the package lands under a path containing spaces, the C3
// compiler is passed explicitly through C3C, and zig is hidden from PATH.
module library_consumer_integration;
import std::io, std::io::file, std::compression::zip, std::os::env, std::collections::list, aro_harness;

const String[*] CONSUMER_FILES = {
	"aro_cc/test/src/cli/consumer_workspace/MODULE.bazel", "MODULE.bazel",
	"aro_cc/test/src/cli/consumer_workspace/consumer.c3", "consumer.c3",
	"aro_cc/test/src/cli/library_consumer.BUILD.bazel", "BUILD.bazel",
};

<* `$(cd -- "$(dirname -- p)" && pwd -P)/$(basename -- p)`, or "" when the directory is missing. *>
fn String physical_path(Allocator a, String p)
{
	@pool()
	{
		String? dir = aro_harness::real_path(tmem, aro_harness::dirname_of(p));
		if (catch dir) return "";
		return string::format(a, "%s/%s", dir, aro_harness::basename_of(p));
	};
}

<*
 PATH with zig removed: a directory holding zig (or zig.exe) is replaced by a
 symlink view of its other executables in `filtered_bin`.
*>
fn String path_without_zig(Allocator a, String path, String filtered_bin)
{
	DString out;
	out.init(a);
	String[] entries = path.tsplit(":");
	// `for directory in $PATH` with IFS=: drops a trailing empty field.
	if (entries.len && !entries[^1].len) entries = entries[:entries.len - 1];
	foreach (entry : entries)
	{
		String directory = entry.len ? entry : ".";
		if (!aro_harness::dir_exists(directory)) continue;
		directory = aro_harness::real_path(tmem, directory) ?? directory;
		String zig = string::tformat("%s/zig", directory);
		String zig_exe = string::tformat("%s/zig.exe", directory);
		String chosen = directory;
		if (aro_harness::is_executable(zig) || aro_harness::is_executable(zig_exe))
		{
			String[]? names = aro_harness::list_sorted(tmem, directory);
			if (try names)
			{
				foreach (name : names)
				{
					if (name.starts_with(".") || name == "zig" || name == "zig.exe") continue;
					String candidate = string::tformat("%s/%s", directory, name);
					if (!aro_harness::is_executable(candidate)) continue;
					String link = string::tformat("%s/%s", filtered_bin, name);
					if (aro_harness::any_exists(link)) continue;
					(void)aro_harness::make_symlink(candidate, link);
				}
			}
			chosen = filtered_bin;
		}
		if (out.len()) out.append(':');
		out.append(chosen);
	}
	return out.str_view();
}

<* `<install>/c3c` -> the compiler and `<install>/lib` -> its sibling stdlib. *>
fn void? install_layout(String install, String compiler_file, String compiler_root)
{
	aro_harness::mkdir_p(install)!;
	aro_harness::make_symlink(compiler_file, string::tformat("%s/c3c", install))!;
	aro_harness::make_symlink(string::tformat("%s/lib", compiler_root), string::tformat("%s/lib", install))!;
}

fn int main(String[] args)
{
	if (args.len < 3 || args.len > 4)
	{
		io::eprintfn("usage: %s <aro distribution archive-or-directory> <c3c executable-or-install-dir> [bazel executable]", args[0]);
		return 2;
	}
	String distribution = args[1];
	String c3c_override = args[2];
	String bazel_command = args.len > 3 ? args[3] : "bazel";
	if (aro_harness::dir_exists(c3c_override))
	{
		c3c_override = aro_harness::real_path(mem, c3c_override) ?? c3c_override;
	}
	else if (!c3c_override.starts_with("/"))
	{
		c3c_override = physical_path(mem, c3c_override);
	}

	String tmp_parent = aro_harness::getenv(mem, "TMPDIR");
	if (!tmp_parent.len) tmp_parent = "/tmp";
	String? tmp_root = aro_harness::make_temp_dir(mem, "aro-consumer.", tmp_parent);
	if (catch tmp_root)
	{
		io::eprintn("cannot create a temporary directory");
		return 1;
	}
	// Bazel leaves tree artifacts read-only; remove_tree makes them writable first.
	defer aro_harness::remove_tree(tmp_root);

	if (aro_harness::file_exists(c3c_override) && aro_harness::dir_exists(string::tformat("%s/lib/std", aro_harness::dirname_of(c3c_override))))
	{
		// Bazel exposes its compiler as `compiler` and the stdlib as a sibling
		// runfiles directory. Create the conventional c3c install layout expected
		// by the isolated repository rule.
		String compiler_file = c3c_override;
		String compiler_root = aro_harness::dirname_of(compiler_file);
		String name = aro_harness::basename_of(compiler_file);
		if (name == "c3c" || name == "c3c.exe")
		{
			c3c_override = compiler_root;
		}
		else
		{
			c3c_override = string::format(mem, "%s/c3c install", tmp_root);
			if (catch install_layout(c3c_override, compiler_file, compiler_root))
			{
				io::eprintfn("cannot create the c3c install layout in %s", c3c_override);
				return 1;
			}
		}
	}

	String extract_dir = string::format(mem, "%s/extracted public package", tmp_root);
	if (catch aro_harness::mkdir_p(extract_dir))
	{
		io::eprintfn("cannot create %s", extract_dir);
		return 1;
	}
	if (aro_harness::dir_exists(distribution))
	{
		if (catch aro_harness::copy_tree(distribution, extract_dir))
		{
			io::eprintfn("cannot copy the distribution directory %s", distribution);
			return 1;
		}
	}
	else
	{
		ZipArchive? archive = zip::open(mem, distribution);
		if (catch archive)
		{
			io::eprintfn("zip: %s: cannot open the archive", distribution);
			return 2;
		}
		defer (void)archive.close();
		if (catch archive.extract(extract_dir))
		{
			io::eprintfn("zip: %s: cannot extract the archive", distribution);
			return 2;
		}
	}

	String module_file;
	String[]? files = aro_harness::walk_files(mem, extract_dir);
	if (try files)
	{
		foreach (rel : files)
		{
			if (aro_harness::basename_of(rel) == "MODULE.bazel")
			{
				module_file = string::format(mem, "%s/%s", extract_dir, rel);
				break;
			}
		}
	}
	if (!module_file.len)
	{
		io::eprintfn("distribution has no MODULE.bazel: %s", distribution);
		return 1;
	}
	String package_root = aro_harness::dirname_of(module_file);
	if (!package_root.contains(" "))
	{
		io::eprintfn("distribution was not extracted under a path containing spaces: %s", package_root);
		return 1;
	}

	String consumer_dir = string::format(mem, "%s/consumer-workspace", tmp_root);
	if (catch aro_harness::mkdir_p(consumer_dir))
	{
		io::eprintfn("cannot create %s", consumer_dir);
		return 1;
	}
	for (sz i = 0; i < CONSUMER_FILES.len; i += 2)
	{
		String from = aro_harness::runfile(tmem, CONSUMER_FILES[i]);
		String to = string::tformat("%s/%s", consumer_dir, CONSUMER_FILES[i + 1]);
		if (catch aro_harness::copy_file(from, to))
		{
			io::eprintfn("cp: cannot copy %s to %s", from, to);
			return 1;
		}
	}

	String bazel_bin;
	if (bazel_command.contains("/"))
	{
		bazel_bin = physical_path(mem, bazel_command);
	}
	else
	{
		bazel_bin = aro_harness::which(mem, bazel_command);
	}
	if (!bazel_bin.len || !aro_harness::is_executable(bazel_bin))
	{
		io::eprintfn("Bazel executable not found: %s", bazel_command);
		return 1;
	}

	// Retain normal host tools, but remove zig from PATH even when it shares a
	// directory with the system compiler. That directory gets an executable-only
	// symlink view with zig omitted; the C3 compiler itself is selected directly
	// through the explicit C3C repository override below.
	String filtered_bin = string::format(mem, "%s/path without zig", tmp_root);
	if (catch aro_harness::mkdir_p(filtered_bin))
	{
		io::eprintfn("cannot create %s", filtered_bin);
		return 1;
	}
	String filtered_path = path_without_zig(mem, aro_harness::getenv(tmem, "PATH"), filtered_bin);
	env::set_var("PATH", filtered_path);
	if (aro_harness::which(tmem, "zig").len)
	{
		io::eprintn("zig is still visible on PATH after filtering");
		return 1;
	}

	(void)io::stdout().flush();
	(void)io::stderr().flush();
	RunResult r = aro_harness::run(mem, {
		bazel_bin,
		"--batch",
		string::tformat("--output_user_root=%s/bazel-output-root", tmp_root),
		"build",
		string::tformat("--override_module=aro=%s", package_root),
		string::tformat("--repo_env=C3C=%s", c3c_override),
		"//:consumer",
	}, { .cwd = consumer_dir, .inherit_stdio = true });
	if (!r.spawned)
	{
		io::eprintfn("cannot run %s", bazel_bin);
		return 127;
	}
	return r.exited ? r.exit_code : 128 + r.signal;
}
