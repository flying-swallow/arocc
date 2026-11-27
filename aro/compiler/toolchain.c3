// Core toolchain API ported from src/aro/Toolchain.zig. Platform discovery
// uses the injected filesystem from toolchain::discovery, so callers can use
// the same implementation with host files or synthetic trees.
module aro::toolchain;
import aro::target;
import aro::toolchain::discovery;
import aro::toolchain::linux;
import aro::toolchain::darwin;
import aro::toolchain::multilib;
import aro::compiler::includes;
import aro::system_defaults;
import aro::compiler::reporting;
import std::collections::maybe;
import std::collections::list;
import std::core::dstring;

excuse RESOURCE_DIR_NOT_FOUND;
excuse BUILTIN_HEADERS_NOT_FOUND;

// Named separately from std::io::path::PathList, which is imported by the
// filesystem adapter in the same module namespace.
alias ToolchainPathList = List{String};

enum RuntimeLibKind : char { COMPILER_RT, LIBGCC }
enum FileKind : char { OBJECT, STATIC, SHARED }
enum LibGCCKind : char { UNSPECIFIED, STATIC, SHARED }
enum UnwindLibKind : char { NONE, COMPILER_RT, LIBGCC }
enum PathKind : char { LIBRARY, FILE, PROGRAM }
enum InnerKind : char { UNINITIALIZED, LINUX, DARWIN, UNKNOWN }

<* Zig Toolchain.Options. Zig optionals map to Maybe{T}; C3 forbids optional members. *>
struct Options
{
	Maybe{String} sysroot;
	Maybe{String} resource_dir;
	bool nobuiltininc; bool nostdinc; bool nostdlibinc;
	Maybe{String} use_linker;
	Maybe{String} linker_path;
	bool nodefaultlibs; bool nolibc; bool nostartfiles; bool nostdlib;
	Maybe{bool} pie;
	bool rdynamic; bool relocatable;
	Maybe{String} rtlib;
	bool shared; bool shared_libgcc; bool is_static; bool static_libgcc; bool static_pie; bool strip;
	Maybe{String} unwindlib;
	String aro_name;
	Maybe{String} raw_target_triple;
	String path_env;
	String[] user_lib_dirs;
}

const Options DEFAULT_OPTIONS = {};

<* The reusable result of Toolchain.discover. `inner` records the selected
 platform backend; Linux currently performs GCC/multilib discovery. *>
struct Toolchain
{
	Allocator a;
	reporting::Sink diagnostics;
	Env env;
	Options opts;
	InnerKind inner;
	ToolchainPathList library_paths;
	ToolchainPathList file_paths;
	ToolchainPathList program_paths;
	bool has_selected_multilib;
	Multilib selected_multilib;
	linux::Linux linux_backend;
}

fn void Toolchain.init(&self, Allocator a, Env env, Options opts = DEFAULT_OPTIONS)
{
	if (env.sysroot.len == 0) env.sysroot = system_defaults::SYSROOT;
	if (env.gcc_install_prefix.len == 0) env.gcc_install_prefix = system_defaults::GCC_INSTALL_PREFIX;
	if (env.path.len == 0) env.path = opts.path_env;
	*self = { .a = a, .env = env, .opts = opts, .inner = UNINITIALIZED };
	self.library_paths.init(a);
	self.file_paths.init(a);
	self.program_paths.init(a);
	self.linux_backend.init(a);
}

fn void Toolchain.err(&self, String fmt, args...) @format(1)
{
	// A standalone Toolchain may not have a diagnostics sink.
	if (!self.diagnostics.report) return;
	@pool() { (void)self.diagnostics.emit(ERROR, string::tformat(fmt, ...args)); };
}

fn void Toolchain.fatal(&self, String fmt, args...) @format(1)
{
	// A standalone Toolchain may not have a diagnostics sink.
	if (!self.diagnostics.report) return;
	@pool() { (void)self.diagnostics.emit(FATAL_ERROR, string::tformat(fmt, ...args)); };
}

fn void Toolchain.warn_off_option(&self, String opt, String fmt, args...) @format(2)
{
	if (!self.diagnostics.report) return;
	@pool() { (void)self.diagnostics.emit(OFF, string::tformat(fmt, ...args), opt); };
}

fn Target* Toolchain.get_target(&self) => &self.env.target;

fn String Toolchain.get_sysroot(&self)
{
	return self.opts.sysroot.get() ?? self.env.sysroot;
}

fn void? Toolchain.discover(&self)
{
	if (self.inner != UNINITIALIZED) return;
	Target t = self.env.target;
	if (t.os.tag == LINUX && t.cpu.arch != HEXAGON && !t.cpu.arch.is_mips() && !t.cpu.arch.is_powerpc() && t.cpu.arch != VE)
	{
		self.inner = LINUX;
		Env effective = self.env;
		if (try sysroot = self.opts.sysroot.get()) effective.sysroot = sysroot;
		self.linux_backend.discover(&effective, &self.program_paths, &self.file_paths, system_defaults::ENABLE_LINKER_BUILD_ID)!;
		self.has_selected_multilib = self.linux_backend.gcc.is_valid;
		if (self.has_selected_multilib) self.selected_multilib = self.linux_backend.gcc.selected;
	}
	else if (t.os.tag.is_darwin()) { self.inner = DARWIN; }
	else { self.inner = UNKNOWN; }
}

fn void Toolchain.free(&self)
{
	foreach (p : self.library_paths) alloc::free(self.a, p.ptr);
	foreach (p : self.file_paths) alloc::free(self.a, p.ptr);
	foreach (p : self.program_paths) alloc::free(self.a, p.ptr);
	self.linux_backend.free();
	self.library_paths.free(); self.file_paths.free(); self.program_paths.free();
	*self = {};
}

fn void? Toolchain.add_path_from_components(&self, String[] components, PathKind kind)
{
	String p = discovery::join(self.a, components);
	self.path_list(kind).push(p);
}

fn void? Toolchain.add_path_if_exists(&self, String[] components, PathKind kind)
{
	String p = discovery::join(self.a, components);
	if (!self.env.exists(p)) { alloc::free(self.a, p.ptr); return; }
	self.path_list(kind).push(p);
}

fn ToolchainPathList* Toolchain.path_list(&self, PathKind kind)
{
	switch (kind)
	{
		case LIBRARY: return &self.library_paths;
		case FILE: return &self.file_paths;
		case PROGRAM: return &self.program_paths;
	}
}

<* Search path prefixes in order. A prefix beginning '=' is rooted under sysroot. *>
fn String? Toolchain.get_file_path(&self, String name)
{
	if (self.opts.aro_name.len)
	{
		String aro_dir = dirname(self.opts.aro_name);
		String candidate = discovery::join(self.a, { aro_dir, "..", name });
		if (self.env.exists(candidate)) return candidate;
		alloc::free(self.a, candidate.ptr);
	}
	String? found = self.search_paths(self.library_paths, name);
	if (try p = found) return p;
	found = self.search_paths(self.file_paths, name);
	if (try p = found) return p;
	return name;
}

fn String? Toolchain.search_paths(&self, ToolchainPathList paths, String name)
{
	String sysroot = self.get_sysroot();
	foreach (prefix : paths)
	{
		if (!prefix.len) continue;
		String candidate;
		if (prefix[0] == '=') { candidate = discovery::join(self.a, { sysroot, prefix[1..], name }); }
		else { candidate = discovery::join(self.a, { prefix, name }); }
		if (self.env.exists(candidate)) return candidate;
		alloc::free(self.a, candidate.ptr);
	}
	return discovery::NOT_FOUND~;
}

fn String dirname(String path)
{
	for (usz i = path.len; i > 0; i--) if (path[i - 1] == '/') return i == 1 ? "/" : path[:i - 1];
	return "";
}

<* If the raw triple and name fit Zig's 64-byte prefix buffer, search that
 candidate in configured program directories, then search the bare name in
 PATH. Otherwise, or when both searches miss, return the bare name. *>
fn String Toolchain.get_program_path(&self, String name, char[] buf)
{
	char[64] prefixed;
	String triple = self.opts.raw_target_triple.get() ?? "";
	if (triple.len && triple.len + name.len + 1 <= prefixed.len)
	{
		usz n = triple.len;
		mem::copy(&prefixed[0], triple.ptr, (sz)n);
		prefixed[n] = '-'; mem::copy(&prefixed[n + 1], name.ptr, (sz)name.len);
		String candidate_name = (String)prefixed[:n + name.len + 1];
		foreach (dir : self.program_paths)
		{
			String candidate = discovery::join(self.a, { dir, candidate_name });
			if (self.can_execute(candidate) && candidate.len <= buf.len)
			{
				mem::copy(buf.ptr, candidate.ptr, candidate.len);
				String result = (String)buf[:candidate.len];
				alloc::free(self.a, candidate.ptr);
				return result;
			}
			alloc::free(self.a, candidate.ptr);
		}
		String? located = self.find_program_by_name(name, buf);
		if (try path = located) return path;
	}
	if (name.len <= buf.len) { mem::copy(buf.ptr, name.ptr, name.len); return (String)buf[:name.len]; }
	return name;
}

<* Path separators on this host: '/' everywhere, plus '\\' on Windows. *>
fn bool is_path_separator(char c)
{
	$if env::WIN32:
		return c == '/' || c == '\\';
	$else
		return c == '/';
	$endif
}

fn String? Toolchain.find_program_by_name(&self, String name, char[] buf)
{
	if (name.len == 0) return discovery::NOT_FOUND~;
	for (usz i = 0; i < name.len; i++)
	{
		if (is_path_separator(name[i]))
		{
			if (name.len > buf.len) return discovery::NOT_FOUND~;
			mem::copy(buf.ptr, name.ptr, name.len);
			return (String)buf[:name.len];
		}
	}
	String path = self.env.path;
	usz start = 0;
	for (usz i = 0; i <= path.len; i++)
	{
		if (i < path.len && path[i] != ':') continue;
		if (i == start) { start = i + 1; continue; }
		String dir = path[start:i - start];
		String candidate = discovery::join(self.a, { dir, name });
		if (candidate.len <= buf.len && self.can_execute(candidate))
		{
			mem::copy(buf.ptr, candidate.ptr, candidate.len);
			String result = (String)buf[:candidate.len];
			alloc::free(self.a, candidate.ptr);
			return result;
		}
		alloc::free(self.a, candidate.ptr);
		start = i + 1;
	}
	return discovery::NOT_FOUND~;
}

fn String Toolchain.get_assembler_path(&self, char[] buf) => self.get_program_path("as", buf);

fn String? Toolchain.get_linker_path(&self, char[] buf)
{
	return select_linker_path(self, buf);
}

fn bool Toolchain.can_execute(&self, String path) => self.env.can_execute(path);
fn bool Toolchain.exists(&self, String path) => self.env.exists(path);
fn bool Toolchain.joined_exists(&self, String[] parts) => self.env.joined_exists(parts);
fn char[]? Toolchain.read_file(&self, String path, char[] buf) => self.env.read_file(path, buf);

<* Append system include directories in caller order. *>
fn void? Toolchain.define_system_includes(&self, List{IncludeDir}* includes)
{
	if (self.opts.nostdinc) return;
	if (self.inner == DARWIN)
	{
		darwin::define_system_includes(self, &self.env, includes, self.env.host_is_darwin)!;
		return;
	}
	if (self.inner == LINUX)
	{
		bool musl = self.env.target.abi.is_musl();
		if (!self.opts.nobuiltininc && (!musl || self.opts.nostdlibinc)) self.add_builtin_include_dir(includes)!;
		if (self.opts.nostdlibinc) return;
		String sysroot = self.get_sysroot();
		if (sysroot.len == 0) sysroot = "/";
		self.add_system_include_dir_joined({ sysroot, "/usr/local/include" }, includes)!!;
		if (self.linux_backend.gcc.is_valid)
		{
			self.add_system_include_dir_joined({ self.linux_backend.gcc.parent_lib_path, "..", self.linux_backend.gcc.gcc_triple, "include" }, includes)!!;
		}
		String multiarch = linux::get_multiarch_triple(&self.env.target);
		if (multiarch.len)
		{
			String multiarch_dir = discovery::join(self.a, { sysroot, "/usr/include", multiarch });
			if (self.env.exists(multiarch_dir)) { includes.push({ .kind = SYSTEM, .path = multiarch_dir }); }
			else { alloc::free(self.a, multiarch_dir.ptr); }
		}
		if (self.env.target.os.tag == RTEMS) return;
		self.add_system_include_dir("/include", includes)!!;
		self.add_system_include_dir("/usr/include", includes)!!;
		if (!self.opts.nobuiltininc && musl) self.add_builtin_include_dir(includes)!;
		return;
	}
	if (!self.opts.nobuiltininc) self.add_builtin_include_dir(includes)!;
	if (!self.opts.nostdlibinc) self.add_system_include_dir("/usr/include", includes)!!;
}

fn void? Toolchain.add_system_include_dir(&self, String path, List{IncludeDir}* includes)
{
	includes.push({ .kind = SYSTEM, .path = path.copy(self.a) });
}

fn void? Toolchain.add_system_include_dir_joined(&self, String[] parts, List{IncludeDir}* includes)
{
	String path = discovery::join(self.a, parts);
	includes.push({ .kind = SYSTEM, .path = path });
}

fn void? Toolchain.add_builtin_include_dir(&self, List{IncludeDir}* includes)
{
	if (try resource_dir = self.opts.resource_dir.get())
	{
		String path = discovery::join(self.a, { resource_dir, "include" });
		if (!self.env.exists(path)) { alloc::free(self.a, path.ptr); return RESOURCE_DIR_NOT_FOUND~; }
		includes.push({ .kind = SYSTEM, .path = path });
		return;
	}
	if (self.opts.aro_name.len)
	{
		String base = dirname(self.opts.aro_name);
		while (base.len)
		{
			String path = discovery::join(self.a, { base, "include" });
			String header = discovery::join(self.a, { path, "stddef.h" });
			bool found = self.env.exists(header);
			alloc::free(self.a, header.ptr);
			if (found) { includes.push({ .kind = SYSTEM, .path = path }); return; }
			alloc::free(self.a, path.ptr);
			String parent = dirname(base);
			if (parent == base) break;
			base = parent;
		}
	}
	if (self.env.runfiles_dir.len)
	{
		String[2] runfiles_includes = {
			discovery::join(self.a, { self.env.runfiles_dir, "_main", "include" }),
			discovery::join(self.a, { self.env.runfiles_dir, "include" }),
		};
		bool pushed = false;
		foreach (path : runfiles_includes)
		{
			if (!pushed)
			{
				String header = discovery::join(self.a, { path, "stddef.h" });
				bool found = self.env.exists(header);
				alloc::free(self.a, header.ptr);
				if (found) { includes.push({ .kind = SYSTEM, .path = path }); pushed = true; continue; }
			}
			alloc::free(self.a, path.ptr);
		}
		if (pushed) return;
	}
	return BUILTIN_HEADERS_NOT_FOUND~;
}
