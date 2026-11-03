// Filesystem/environment discovery interface for the toolchain ports
// (plan 23). Ports the queries of src/aro/Toolchain.zig that GCC, distro and
// multilib discovery use (exists, readFile, joinedExists, the directory
// iteration in GCCDetector.scanLibDirForGCCTriple, getSysroot, getTarget,
// system_defaults.gcc_install_prefix) behind an explicit value so the
// algorithms run on synthetic trees without a Driver or Compilation.
//
// - `FileSystem` is a small vtable (context pointer + function pointers).
//   `MemTree.fs()` is the synthetic in-memory tree used by tests; `host_fs()`
//   reads the real filesystem (for the Driver, plan 24). Tests never use it on
//   /usr or /opt.
// - `Env` bundles the filesystem with the target and the defaults that Zig
//   reads from `system_defaults` / `Toolchain.Options`. Target-vs-host: `target`
//   is the C program's target. Distro detection reads the *host's* /etc files
//   through the same filesystem regardless of `sysroot` (as in Zig).
// - `join` / `join_buf` reproduce std.fs.path.join (POSIX): empty components
//   are skipped; at each boundary a separator is inserted when neither side
//   has one, and one is dropped when both do. Nothing else is normalized
//   ("..", "//" are kept verbatim); resolution is the filesystem's job.
module aro::toolchain::discovery;
import aro::target;
import std::collections::list, std::io;

excuse NOT_FOUND;
excuse NOT_A_DIRECTORY;
excuse PATH_TOO_LONG;

<* std.fs.max_path_bytes on Linux. *>
const usz MAX_PATH_BYTES = 4096;

enum EntryKind : char
{
	FILE,
	DIRECTORY,
	OTHER,
}

<* One directory entry. `name` is owned by the allocator passed to `list_dir`. *>
struct DirEntry
{
	String name;
	EntryKind kind;
}

alias DirEntryList = List{DirEntry};

<* Zig `cwd.access(path)` succeeding (file or directory). *>
alias ExistsFn = fn bool(void* ctx, String path);
<*
 Zig `cwd.readFile(path, buf)`: reads at most buf.len bytes (partial contents
 when the file is larger) and returns the filled prefix of `buf`.
*>
alias ReadFileFn = fn char[]?(void* ctx, String path, char[] buf);
<*
 Zig `openDir(path, .{.iterate = true})` + `iterate()`: appends every entry
 of `path` to `out`, names copied into `a`. Fails with NOT_FOUND /
 NOT_A_DIRECTORY when the directory can't be opened.
*>
alias ListDirFn = fn void?(void* ctx, String path, Allocator a, DirEntryList* out);

struct FileSystem
{
	void* ctx;
	ExistsFn exists_fn;
	ReadFileFn read_file_fn;
	ListDirFn list_dir_fn;
}

fn bool FileSystem.exists(&self, String path) => self.exists_fn(self.ctx, path);

fn char[]? FileSystem.read_file(&self, String path, char[] buf) => self.read_file_fn(self.ctx, path, buf);

<* Toolchain.joinedExists: false when the joined path does not fit MAX_PATH_BYTES. *>
fn bool FileSystem.joined_exists(&self, String[] parts)
{
	char[MAX_PATH_BYTES] buf;
	String? joined = join_buf(&buf, parts);
	if (catch joined) return false;
	return self.exists(joined);
}

fn void? FileSystem.list_dir(&self, String path, Allocator a, DirEntryList* out)
{
	return self.list_dir_fn(self.ctx, path, a, out);
}

<* Frees the names in `list` (allocated with `a`) and the list itself. *>
fn void free_entries(Allocator a, DirEntryList* list)
{
	foreach (e : *list) alloc::free(a, e.name.ptr);
	list.free();
}

<*
 Everything discovery reads besides the filesystem. Strings are borrowed.
*>
struct Env
{
	FileSystem fs;
	<* Toolchain.getTarget(): the target, never the host. *>
	Target target;
	<* Toolchain.getSysroot(): `--sysroot`, else system_defaults.sysroot; "" = none. *>
	String sysroot;
	<* system_defaults.gcc_install_prefix (build option, Zig default ""). *>
	String gcc_install_prefix;
}

fn bool Env.exists(&self, String path) => self.fs.exists(path);
fn bool Env.joined_exists(&self, String[] parts) => self.fs.joined_exists(parts);
<* Toolchain.readFile: NOT_FOUND (Zig null) on any error. *>
fn char[]? Env.read_file(&self, String path, char[] buf) => self.fs.read_file(path, buf);
fn void? Env.list_dir(&self, String path, Allocator a, DirEntryList* out) => self.fs.list_dir(path, a, out);

// ---------------------------------------------------------------------------
// std.fs.path.join
// ---------------------------------------------------------------------------

fn usz joined_len(String[] parts)
{
	usz sum = 0;
	String prev = "";
	foreach (p : parts)
	{
		if (p.len == 0) continue;
		if (prev.len == 0)
		{
			sum = p.len;
			prev = p;
			continue;
		}
		bool prev_sep = prev[^1] == '/';
		bool this_sep = p[0] == '/';
		if (!prev_sep && !this_sep) sum++;
		sum += (prev_sep && this_sep) ? p.len - 1 : p.len;
		prev = p;
	}
	return sum;
}

<* std.fs.path.join into `buf`; PATH_TOO_LONG when it does not fit. *>
fn String? join_buf(char[] buf, String[] parts)
{
	usz total = joined_len(parts);
	if (total > buf.len) return PATH_TOO_LONG~;
	usz n = 0;
	String prev = "";
	foreach (p : parts)
	{
		if (p.len == 0) continue;
		String piece = p;
		if (prev.len != 0)
		{
			bool prev_sep = prev[^1] == '/';
			bool this_sep = p[0] == '/';
			if (!prev_sep && !this_sep) buf[n++] = '/';
			if (prev_sep && this_sep) piece = p[1..];
		}
		buf[n:piece.len] = piece[..];
		n += piece.len;
		prev = p;
	}
	return (String)buf[:n];
}

<* std.fs.path.join; the result (zero terminated) is owned by `a`. *>
fn String join(Allocator a, String[] parts)
{
	usz total = joined_len(parts);
	char* p = alloc::malloc(a, (sz)total + 1);
	String s = join_buf(p[:total], parts)!!;
	p[total] = 0;
	return s;
}

// ---------------------------------------------------------------------------
// MemTree: synthetic in-memory directory tree
// ---------------------------------------------------------------------------

struct MemNode
{
	String name;
	uint parent;
	EntryKind kind;
	String contents;
}

<*
 A synthetic filesystem. Node 0 is the root "/". Paths are resolved
 component by component like POSIX: empty and "." components are skipped,
 ".." goes to the parent (the root's parent is the root), every intermediate
 component must be an existing directory. Relative paths resolve from "/".
 `list_dir` returns children in insertion order (Zig iterates in on-disk
 order, which is unspecified; selection only depends on it for equal versions).
 When `record` is set, every queried path is copied into `accesses`, so tests
 can assert that discovery never looked outside a sysroot.
*>
struct MemTree
{
	Allocator a;
	List{MemNode} nodes;
	bool record;
	List{String} accesses;
}

fn void MemTree.init(&self, Allocator a)
{
	*self = { .a = a };
	self.nodes.init(a);
	self.accesses.init(a);
	self.nodes.push({ .name = "", .parent = 0, .kind = DIRECTORY });
}

fn void MemTree.free(&self)
{
	foreach (n : self.nodes)
	{
		if (n.name.len) alloc::free(self.a, n.name.ptr);
		if (n.contents.len) alloc::free(self.a, n.contents.ptr);
	}
	self.nodes.free();
	self.clear_accesses();
	self.accesses.free();
	*self = {};
}

fn void MemTree.clear_accesses(&self)
{
	foreach (s : self.accesses) alloc::free(self.a, s.ptr);
	self.accesses.clear();
}

<* True when some recorded query path starts with `prefix`. *>
fn bool MemTree.accessed_with_prefix(&self, String prefix)
{
	foreach (s : self.accesses)
	{
		if (s.starts_with(prefix)) return true;
	}
	return false;
}

fn void MemTree.log(&self, String path)
{
	if (!self.record) return;
	self.accesses.push(path.copy(self.a));
}

fn uint? MemTree.child(&self, uint dir, String name)
{
	foreach (i, n : self.nodes)
	{
		if (i != 0 && n.parent == dir && n.name == name) return (uint)i;
	}
	return NOT_FOUND~;
}

<* Resolves `path` to a node index. *>
fn uint? MemTree.resolve(&self, String path)
{
	uint cur = 0;
	usz i = 0;
	while (i < path.len)
	{
		usz start = i;
		while (i < path.len && path[i] != '/') i++;
		String comp = path[start:i - start];
		i++;
		if (comp.len == 0 || comp == ".") continue;
		if (self.nodes[cur].kind != DIRECTORY) return NOT_A_DIRECTORY~;
		if (comp == "..")
		{
			cur = self.nodes[cur].parent;
			continue;
		}
		cur = self.child(cur, comp)!;
	}
	return cur;
}

fn uint MemTree.make(&self, String path, EntryKind leaf_kind, String contents)
{
	uint cur = 0;
	usz i = 0;
	while (i < path.len)
	{
		usz start = i;
		while (i < path.len && path[i] != '/') i++;
		String comp = path[start:i - start];
		i++;
		if (comp.len == 0 || comp == ".") continue;
		assert(comp != "..", "MemTree paths must not contain '..'");
		bool last = true;
		for (usz j = i; j < path.len; j++)
		{
			if (path[j] != '/') { last = false; break; }
		}
		uint? existing = self.child(cur, comp);
		if (try existing)
		{
			cur = existing;
			if (last && leaf_kind != DIRECTORY)
			{
				MemNode* n = &self.nodes[cur];
				assert(n.kind != DIRECTORY, "path already exists as a directory");
				if (n.contents.len) alloc::free(self.a, n.contents.ptr);
				n.kind = leaf_kind;
				n.contents = contents.len ? contents.copy(self.a) : "";
			}
			else
			{
				assert(self.nodes[cur].kind == DIRECTORY, "path component is not a directory");
			}
			continue;
		}
		self.nodes.push({
			.name = comp.copy(self.a),
			.parent = cur,
			.kind = last ? leaf_kind : DIRECTORY,
			.contents = (last && contents.len) ? contents.copy(self.a) : "",
		});
		cur = (uint)self.nodes.len() - 1;
	}
	return cur;
}

<* mkdir -p. *>
fn void MemTree.add_dir(&self, String path) => (void)self.make(path, DIRECTORY, "");

<* Creates a regular file (and its parent directories). *>
fn void MemTree.add_file(&self, String path, String contents = "") => (void)self.make(path, FILE, contents);

<* Creates a non-directory, non-regular entry (e.g. a symlink stand-in). *>
fn void MemTree.add_other(&self, String path) => (void)self.make(path, OTHER, "");

fn bool mem_exists(void* ctx, String path)
{
	MemTree* t = ctx;
	t.log(path);
	return @ok(t.resolve(path));
}

fn char[]? mem_read_file(void* ctx, String path, char[] buf)
{
	MemTree* t = ctx;
	t.log(path);
	uint idx = t.resolve(path)!;
	MemNode* n = &t.nodes[idx];
	if (n.kind == DIRECTORY) return NOT_FOUND~;
	usz len = n.contents.len < buf.len ? n.contents.len : buf.len;
	if (len) buf[:len] = n.contents[:len];
	return buf[:len];
}

fn void? mem_list_dir(void* ctx, String path, Allocator a, DirEntryList* out)
{
	MemTree* t = ctx;
	t.log(path);
	uint idx = t.resolve(path)!;
	if (t.nodes[idx].kind != DIRECTORY) return NOT_A_DIRECTORY~;
	foreach (i, n : t.nodes)
	{
		if (i != 0 && n.parent == idx) out.push({ .name = n.name.copy(a), .kind = n.kind });
	}
}

fn FileSystem MemTree.fs(&self)
{
	return { .ctx = self, .exists_fn = &mem_exists, .read_file_fn = &mem_read_file, .list_dir_fn = &mem_list_dir };
}

// ---------------------------------------------------------------------------
// Host filesystem (relative paths resolve against the process cwd).
// ---------------------------------------------------------------------------

fn bool host_exists(void* ctx, String path) => file::exists(path);

fn char[]? host_read_file(void* ctx, String path, char[] buf)
{
	File? f = file::open(path, "rb");
	if (catch f) return NOT_FOUND~;
	defer (void)f.close();
	usz n = 0;
	while (n < buf.len)
	{
		sz? got = f.read(buf[n..]);
		if (catch got) return NOT_FOUND~;
		if (got == 0) break;
		n += (usz)got;
	}
	return buf[:n];
}

fn void? host_list_dir(void* ctx, String path, Allocator a, DirEntryList* out)
{
	if (!file::is_dir(path)) return file::exists(path) ? NOT_A_DIRECTORY~ : NOT_FOUND~;
	@pool()
	{
		PathList? list = path::ls(tmem, path::tnew(path)!!);
		if (catch list) return NOT_FOUND~;
		foreach (p : list)
		{
			String name = (String)p;
			char[MAX_PATH_BYTES] buf;
			String? full = join_buf(&buf, { path, name });
			EntryKind kind = OTHER;
			if (try full)
			{
				kind = file::is_dir(full) ? DIRECTORY : file::is_file(full) ? FILE : OTHER;
			}
			out.push({ .name = name.copy(a), .kind = kind });
		}
	};
}

<* The real filesystem of the machine running the compiler. *>
fn FileSystem host_fs()
{
	return { .ctx = null, .exists_fn = &host_exists, .read_file_fn = &host_read_file, .list_dir_fn = &host_list_dir };
}
