// Linker and runtime-library policy ported from src/aro/Toolchain.zig.
// Kept separate from Toolchain so the core API can delegate without importing
// platform-specific linker policy into its discovery implementation.
module aro::toolchain;
import aro::target;
import aro::system_defaults;
import aro::frontend::c::diagnostics;
import std::collections::list, std::collections::maybe;

excuse INVALID_LINKER_PATH;
excuse UNSUPPORTED_LINKER_TARGET;

fn RuntimeLibKind get_runtime_lib_kind(Toolchain* tc)
{
	String rtlib = tc.opts.rtlib.get() ?? system_defaults::RTLIB;
	if (rtlib == "compiler-rt") return COMPILER_RT;
	if (rtlib == "libgcc") return LIBGCC;
	return tc.env.target.abi.is_android() ? COMPILER_RT : LIBGCC;
}

fn LibGCCKind get_libgcc_kind(Toolchain* tc)
{
	if (tc.opts.static_libgcc || tc.opts.is_static || tc.opts.static_pie || tc.env.target.abi.is_android()) return STATIC;
	if (tc.opts.shared_libgcc) return SHARED;
	return UNSPECIFIED;
}

fn UnwindLibKind get_unwind_lib_kind(Toolchain* tc)
{
	String unwindlib = tc.opts.unwindlib.get() ?? system_defaults::UNWINDLIB;
	if (unwindlib.len == 0 || unwindlib == "platform")
	{
		if (get_runtime_lib_kind(tc) == COMPILER_RT) return tc.env.target.abi.is_android() ? COMPILER_RT : NONE;
		return LIBGCC;
	}
	if (unwindlib == "none") return NONE;
	if (unwindlib == "libgcc") return LIBGCC;
	if (unwindlib == "libunwind")
	{
		if (get_runtime_lib_kind(tc) == LIBGCC) tc.err("--rtlib=libgcc requires --unwindlib=libgcc");
		return COMPILER_RT;
	}
	return NONE;
}

fn String as_needed_option(Target* t, bool needed)
{
	if (t.os.tag == ILLUMOS) return needed ? "-zignore" : "-zrecord";
	return needed ? "--as-needed" : "--no-as-needed";
}

fn void append_unwind_library(Toolchain* tc, List{String}* argv)
{
	Target* t = &tc.env.target;
	UnwindLibKind unw = get_unwind_lib_kind(tc);
	if ((t.abi.is_android() && unw == LIBGCC) || t.ofmt == WASM || t.is_windows_msvc_environment() || unw == NONE) return;
	LibGCCKind lgk = get_libgcc_kind(tc);
	bool as_needed = lgk == UNSPECIFIED && !t.abi.is_android() && !t.is_mingw();
	if (as_needed) argv.push(as_needed_option(t, true));
	switch (unw)
	{
		case NONE: return;
		case LIBGCC: argv.push(lgk == STATIC ? "-lgcc_eh" : "-lgcc_s");
		case COMPILER_RT:
			if (lgk == STATIC) { argv.push("-l:libunwind.a"); }
			else if (lgk == SHARED) { argv.push(t.is_mingw() ? "-l:libunwind.dll.a" : "-l:libunwind.so"); }
			else { argv.push("-lunwind"); }
	}
	if (as_needed) argv.push(as_needed_option(t, false));
}

fn void append_libgcc(Toolchain* tc, List{String}* argv)
{
	LibGCCKind kind = get_libgcc_kind(tc);
	if (kind == STATIC || kind == UNSPECIFIED) argv.push("-lgcc");
	append_unwind_library(tc, argv);
	if (kind == SHARED) argv.push("-lgcc");
}

fn void add_runtime_libs(Toolchain* tc, List{String}* argv)
{
	Target* t = &tc.env.target;
	if (get_runtime_lib_kind(tc) == LIBGCC && !t.is_windows_msvc_environment()) append_libgcc(tc, argv);
	if (t.abi.is_android() && !tc.opts.is_static && !tc.opts.static_pie) argv.push("-ldl");
}

<* Resolve the linker executable from --ld-path, -fuse-ld, or platform defaults.
The returned slice is borrowed or written into buf by get_program_path. *>
fn String? select_linker_path(Toolchain* tc, char[] buf)
{
	if (try String path = tc.opts.linker_path.get())
	{
		if (path.len)
		{
			bool has_slash = false;
			foreach (c : path) if (is_path_separator(c)) { has_slash = true; break; }
			if (!has_slash) path = tc.get_program_path(path, buf);
			if (tc.can_execute(path)) return path;
		}
		tc.fatal("invalid linker name in argument '--ld-path=%s'", path);
		return INVALID_LINKER_PATH~;
	}
	String use_linker = tc.opts.use_linker.get() ?? system_defaults::LINKER;
	if (use_linker.len && use_linker != "ld")
	{
		String candidate;
		bool has_slash = false;
		foreach (c : use_linker) if (c == '/') { has_slash = true; break; }
		if (has_slash)
		{
			tc.warn_off_option(diagnostics::Option.FUSE_LD_PATH,
				"'-fuse-ld=' taking a path is deprecated; use '--ld-path=' instead");
		}
		if (has_slash && use_linker[0] == '/')
		{
			candidate = use_linker;
		}
		else
		{
			char[256] name;
			String prefix = tc.env.target.os.tag.is_darwin() ? "ld64." : "ld.";
			usz n = prefix.len + use_linker.len;
			if (n <= name.len)
			{
				mem::copy(&name[0], prefix.ptr, (sz)prefix.len);
				mem::copy(&name[prefix.len], use_linker.ptr, (sz)use_linker.len);
				candidate = tc.get_program_path((String)name[:n], buf);
			}
			else { candidate = ""; }
		}
		if (candidate.len && tc.can_execute(candidate)) return candidate;
		if (tc.opts.use_linker.has_value)
		{
			tc.fatal("invalid linker name in argument '-fuse-ld=%s'", use_linker);
			return INVALID_LINKER_PATH~;
		}
	}
	if (tc.inner == LINUX) return tc.get_program_path(tc.linux_backend.default_linker(&tc.env.target), buf);
	return tc.get_program_path("ld", buf);
}

<* The Linux linker policy preserves the order of CRT files, user library
search paths, user objects, runtime libraries and closing CRT files. User
search paths precede toolchain paths. Unsupported platform backends return
without inventing linker arguments. *>
fn void? Toolchain.build_linker_args(&self, String output_name, String[] link_objects, List{String}* argv)
{
	if (self.inner != LINUX)
	{
		// Zig aborts here; C3 reports a fatal and fails the link.
		self.fatal("This toolchain does not support linking yet");
		return UNSUPPORTED_LINKER_TARGET~;
	}
	return append_linux_linker_policy(self, output_name, link_objects, argv);
}

<* Append the common Linux linker command policy. Startup object resolution and
diagnostic reporting remain the caller's responsibility. *>
fn void? append_linux_linker_policy(Toolchain* tc, String output_name, String[] link_objects, List{String}* argv)
{
	Target* t = &tc.env.target;
	bool pie = !tc.opts.shared && !tc.opts.is_static && !tc.opts.relocatable && !tc.opts.static_pie && (tc.opts.pie.get() ?? false);
	bool static_link = tc.opts.is_static && !tc.opts.static_pie;
	String emulation = t.ld_emulation_option();
	if (tc.opts.static_pie && tc.opts.pie.has_value) tc.err("cannot specify 'nopie' along with 'static-pie'");
	String dynamic_linker = t.standard_dynamic_linker_path();
	tc.linux_backend.append_linker_policy(tc, t, pie, tc.opts.static_pie, tc.opts.rdynamic, tc.opts.strip,
		tc.opts.shared, static_link, tc.opts.relocatable, emulation, dynamic_linker, argv);
	if (emulation.len == 0)
	{
		tc.err("Unknown target triple");
		return;
	}
	argv.push_all({ "-o", output_name.len ? output_name : "a.out" });
	bool android = t.abi.is_android();
	bool has_crt = t.abi != NONE;
	if (!tc.opts.nostdlib && !tc.opts.nostartfiles && !tc.opts.relocatable)
	{
		if (!android)
		{
			if (!tc.opts.shared)
			{
				String crt1 = tc.opts.static_pie ? "rcrt1.o" : pie ? "Scrt1.o" : "crt1.o";
				argv.push(tc.get_file_path(crt1)!!);
			}
			argv.push(tc.get_file_path("crti.o")!!);
		}
		if (t.cpu.arch == VE) argv.push_all({ "-z", "max-page-size=0x4000000" });
		if (has_crt)
		{
			String crtbegin;
			if (tc.opts.shared) { crtbegin = android ? "crtbegin_so.o" : "crtbeginS.o"; }
			else if (static_link) { crtbegin = android ? "crtbegin_static.o" : "crtbeginT.o"; }
			else if (pie || tc.opts.static_pie) { crtbegin = android ? "crtbegin_dynamic.o" : "crtbeginS.o"; }
			else { crtbegin = android ? "crtbegin_dynamic.o" : "crtbegin.o"; }
			argv.push(tc.get_file_path(crtbegin)!!);
		}
	}
	foreach (p : tc.opts.user_lib_dirs) argv.push("-L".concat(tc.a, p));
	foreach (p : tc.file_paths) argv.push("-L".concat(tc.a, p));
	argv.push_all(link_objects);
	if (!tc.opts.nostdlib && !tc.opts.nodefaultlibs && !tc.opts.relocatable)
	{
		if (static_link || tc.opts.static_pie) { argv.push("--start-group"); }
		add_runtime_libs(tc, argv);
		if (!tc.opts.nolibc) argv.push("-lc");
		if (static_link || tc.opts.static_pie) { argv.push("--end-group"); }
		else { add_runtime_libs(tc, argv); }
	}
	if (!tc.opts.nostdlib && !tc.opts.nostartfiles && !tc.opts.relocatable)
	{
		if (has_crt)
		{
			String crtend = tc.opts.shared ? (android ? "crtend_so.o" : "crtendS.o") :
				((pie || tc.opts.static_pie) ? (android ? "crtend_android.o" : "crtendS.o") : (android ? "crtend_android.o" : "crtend.o"));
			argv.push(tc.get_file_path(crtend)!!);
		}
		if (!android) argv.push(tc.get_file_path("crtn.o")!!);
	}
}
