// Filesystem helpers the stdlib lacks: temp dirs, symlinks, realpath, fnmatch,
// sorted listings and walks, recursive copy/remove, atomic writes.
module aro_harness;
import std::io, std::io::path, std::io::file, std::collections::list, std::sort;
import libc, std::os::posix;

extern fn ZString mkdtemp(ZString template) @feat(POSIX);
extern fn CInt symlink(ZString target, ZString linkpath) @feat(POSIX);
extern fn ZString realpath(ZString p, char* resolved) @feat(POSIX);
extern fn CInt fnmatch(ZString pattern, ZString name, CInt flags) @feat(POSIX);
extern fn CInt chmod(ZString p, CUInt mode) @feat(POSIX) @cname("chmod");
extern fn CInt rename(ZString from, ZString to) @cname("rename");

faultdef IO_FAILED;

fn bool dir_exists(String p) => path::is_dir((Path)p);
fn bool file_exists(String p) => path::is_file((Path)p);
fn bool any_exists(String p) => path::exists((Path)p);
fn bool is_symlink(String p) => path::is_link((Path)p);

<* Glob match like Python fnmatch.fnmatchcase (`*`, `?`, `[...]`). *>
fn bool glob_match(String pattern, String name) @feat(POSIX)
{
	@pool()
	{
		return fnmatch(pattern.zstr_tcopy(), name.zstr_tcopy(), 0) == 0;
	};
}

<* A fresh directory `<parent>/<prefix>XXXXXX` (tempfile.mkdtemp). *>
fn String? make_temp_dir(Allocator a, String prefix, String parent = "") @feat(POSIX)
{
	String base = parent;
	@pool()
	{
		if (!base.len) base = temp_root(tmem);
		ZString tmpl = string::tformat("%s/%sXXXXXX", base, prefix).zstr_tcopy();
		ZString got = mkdtemp(tmpl);
		if (!got) return IO_FAILED~;
		return got.str_view().copy(a);
	};
}

<* TMPDIR (Bazel sets it per test), else /tmp. *>
fn String temp_root(Allocator a)
{
	String t = getenv(a, "TEST_TMPDIR");
	if (t.len) return t;
	t = getenv(a, "TMPDIR");
	return t.len ? t : "/tmp".copy(a);
}

fn void? make_symlink(String target, String link_path) @feat(POSIX)
{
	@pool()
	{
		if (symlink(target.zstr_tcopy(), link_path.zstr_tcopy())) return IO_FAILED~;
	};
}

<* Path with symlinks resolved (os.path.realpath / Path.resolve for existing paths). *>
fn String? real_path(Allocator a, String p) @feat(POSIX)
{
	char[4096] buf;
	@pool()
	{
		ZString got = realpath(p.zstr_tcopy(), &buf);
		if (!got) return IO_FAILED~;
		return got.str_view().copy(a);
	};
}

fn void? set_mode(String p, uint mode) @feat(POSIX)
{
	@pool()
	{
		if (chmod(p.zstr_tcopy(), mode)) return IO_FAILED~;
	};
}

fn void? mkdir_p(String p)
{
	if (dir_exists(p)) return;
	path::mkdir((Path)p, true)!;
}

<* Entry names of `dir` (not paths), sorted bytewise like Python's sorted(os.listdir). *>
fn String[]? list_sorted(Allocator a, String dir)
{
	PathList entries = path::ls(tmem, (Path)dir)!;
	List{String} names;
	names.init(a);
	foreach (e : entries)
	{
		String n = (String)e;
		if (n == "." || n == "..") continue;
		names.push(n.copy(a));
	}
	String[] out = names.array_view();
	sort::quicksort(out, fn int(String x, String y) => x.compare_to(y));
	return out;
}

<* Every regular file under `root`, as root-relative paths, in os.walk order with sorted names. *>
fn String[]? walk_files(Allocator a, String root)
{
	List{String} out;
	out.init(a);
	walk_into(a, root, "", &out)!;
	return out.array_view();
}

fn void? walk_into(Allocator a, String root, String rel, List{String}* out) @local
{
	@pool()
	{
		String dir = rel.len ? string::tformat("%s/%s", root, rel) : root;
		String[] names = list_sorted(tmem, dir)!;
		List{String} subdirs;
		subdirs.init(tmem);
		foreach (n : names)
		{
			String full = string::tformat("%s/%s", dir, n);
			String child = rel.len ? string::tformat("%s/%s", rel, n) : n;
			if (dir_exists(full) && !is_symlink(full)) { subdirs.push(child); }
			else if (file_exists(full)) { out.push(child.copy(a)); }
		}
		foreach (s : subdirs) walk_into(a, root, s, out)!;
	};
}

fn void? copy_file(String from, String to)
{
	@pool()
	{
		char[] data = file::load_temp(from)!;
		file::save(to, data)!;
	};
}

<* Copy the tree at `from` into `to` (created), files and directories only; symlinks are copied as their targets. *>
fn void? copy_tree(String from, String to)
{
	mkdir_p(to)!;
	@pool()
	{
		foreach (n : list_sorted(tmem, from)!)
		{
			String src = string::tformat("%s/%s", from, n);
			String dst = string::tformat("%s/%s", to, n);
			if (dir_exists(src)) { copy_tree(src, dst)!; }
			else { copy_file(src, dst)!; }
		}
	};
}

<* Remove a tree, first making read-only directories writable (Bazel tree artifacts are 0555). *>
fn void remove_tree(String p) @feat(POSIX)
{
	if (!any_exists(p) && !is_symlink(p)) return;
	if (is_symlink(p) || !dir_exists(p))
	{
		@pool() { libc::remove(p.zstr_tcopy()); };
		return;
	}
	(void)set_mode(p, 0o755);
	@pool()
	{
		String[]? names = list_sorted(tmem, p);
		if (try names)
		{
			foreach (n : names) remove_tree(string::tformat("%s/%s", p, n));
		}
		libc::remove(p.zstr_tcopy());
	};
}

<* Write `data` to `dest` via a temp file in the same directory and rename (os.replace). Keeps `mode`. *>
fn void? write_atomic(String dest, char[] data, uint mode = 0o644) @feat(POSIX)
{
	@pool()
	{
		String tmp_path = string::tformat("%s/.%s.%d.tmp", dirname_of(dest), basename_of(dest), posix::getpid());
		file::save(tmp_path, data)!;
		(void)set_mode(tmp_path, mode);
		if (rename(tmp_path.zstr_tcopy(), dest.zstr_tcopy()))
		{
			libc::remove(tmp_path.zstr_tcopy());
			return IO_FAILED~;
		}
	};
}

fn String basename_of(String p)
{
	sz? slash = p.rindex_of_char('/');
	if (catch slash) return p;
	return p[slash + 1..];
}

fn String dirname_of(String p)
{
	sz? slash = p.rindex_of_char('/');
	if (catch slash) return ".";
	return slash == 0 ? "/" : p[:slash];
}

fn String join(Allocator a, String dir, String name) => dir.len ? string::format(a, "%s/%s", dir, name) : name.copy(a);

<* Absolute form of `p` against the current directory (no symlink resolution). *>
fn String absolute(Allocator a, String p)
{
	if (p.starts_with("/")) return p.copy(a);
	Path? cwd = path::cwd(tmem);
	if (catch cwd) return p.copy(a);
	return string::format(a, "%s/%s", (String)cwd, p);
}
