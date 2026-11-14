// Linux toolchain discovery and linker policy, ported from
// src/aro/Toolchain/Linux.zig. The core Toolchain module is still being
// assembled; this module keeps discovery on the shared Env interface so the
// core can delegate to it without coupling the policy to host filesystem I/O.
module aro::toolchain::linux;
import aro::toolchain;
import aro::toolchain::discovery, aro::toolchain::distro, aro::toolchain::gcc_detector;
import aro::target;
import std::collections::list;

struct Linux
{
	Allocator a;
	distro::Tag distro_tag;
	List{String} extra_opts;
	gcc_detector::GccDetector gcc;
}

fn void Linux.init(&self, Allocator a)
{
	*self = { .a = a, .distro_tag = UNKNOWN };
	self.extra_opts.init(a);
	self.gcc.init(a);
}

fn void Linux.free(&self)
{
	foreach (s : self.extra_opts) alloc::free(self.a, s.ptr);
	self.extra_opts.free();
	self.gcc.free();
	*self = {};
}

<* Linux.discover: detects the host distro, GCC install/multilib, and paths. *>
fn void? Linux.discover(&self, discovery::Env* env, List{String}* program_paths, List{String}* file_paths, bool enable_build_id)
{
	self.distro_tag = distro::detect(env);
	self.gcc.discover(env)!;
	self.gcc.append_tool_path(self.a, program_paths);
	self.build_extra_opts(&env.target, enable_build_id);
	self.find_paths(env, file_paths);
}

<* Appends paths that exist, preserving Zig's search order and path joins. *>
fn void Linux.find_paths(&self, discovery::Env* env, List{String}* file_paths)
{
	Target* t = &env.target;
	String os_lib_dir = get_os_lib_dir(t);
	char[64] triple_buf;
	String triple = get_multiarch_triple(t);
	if (triple.len == 0) triple = t.to_llvm_triple(&triple_buf);
	String sysroot = env.sysroot;
	if (sysroot.len == 0) sysroot = "/";
	self.add_multilib_paths(env, file_paths, sysroot, os_lib_dir);
	self.add_existing(env, file_paths, { sysroot, "/lib", triple });
	self.add_existing(env, file_paths, { sysroot, "/lib", "..", os_lib_dir });
	self.add_existing(env, file_paths, { sysroot, "/usr", "lib", triple });
	self.add_existing(env, file_paths, { sysroot, "/usr", "lib", "..", os_lib_dir });
	self.add_multiarch_paths(env, file_paths);
	self.add_existing(env, file_paths, { sysroot, "/lib" });
	self.add_existing(env, file_paths, { sysroot, "/usr", "lib" });
}

fn void Linux.add_existing(&self, discovery::Env* env, List{String}* file_paths, String[] parts)
{
	String path = discovery::join(self.a, parts);
	if (env.exists(path))
	{
		file_paths.push(path);
	}
	else
	{
		alloc::free(self.a, path.ptr);
	}
}

fn void Linux.add_multilib_paths(&self, discovery::Env* env, List{String}* file_paths, String sysroot, String os_lib_dir)
{
	if (!self.gcc.is_valid) return;
	String gcc_triple = self.gcc.gcc_triple;
	String lib_path = self.gcc.parent_lib_path;
	self.add_existing(env, file_paths, { self.gcc.install_path, self.gcc.selected.gcc_suffix });
	self.add_existing(env, file_paths, { self.gcc.install_path, "..", os_lib_dir });
	self.add_existing(env, file_paths, { lib_path, "..", gcc_triple, "lib", "..", os_lib_dir, self.gcc.selected.os_suffix });
	if (lib_path.starts_with(sysroot)) self.add_existing(env, file_paths, { lib_path, "..", os_lib_dir });
}

fn void Linux.add_multiarch_paths(&self, discovery::Env* env, List{String}* file_paths)
{
	if (!self.gcc.is_valid) return;
	self.add_existing(env, file_paths, { self.gcc.parent_lib_path, "..", self.gcc.gcc_triple, "lib", self.gcc.selected.os_suffix });
}

<* Linker options that vary by Linux distro and target ABI/architecture. *>
fn void Linux.build_extra_opts(&self, Target* t, bool enable_build_id)
{
	bool android = t.abi.is_android();
	if (self.distro_tag.is_alpine() || android) self.push_pair("-z", "now");
	if (self.distro_tag.is_open_suse() || self.distro_tag.is_ubuntu() || self.distro_tag.is_alpine() || android) self.push_pair("-z", "relro");
	if ((t.cpu.arch.is_arm() && !t.cpu.arch.is_thumb()) || t.cpu.arch.is_aarch64() || android) self.push_pair("-z", "max-page-size=4096");
	if (t.cpu.arch == ARM || t.cpu.arch == THUMB) self.extra_opts.push("-X".copy(self.a));
	if (!t.cpu.arch.is_mips() && t.cpu.arch != HEXAGON)
	{
		distro::HashStyle style = android ? BOTH : self.distro_tag.get_hash_style();
		self.extra_opts.push("--hash-style=".concat(self.a, style.name));
	}
	if (enable_build_id) self.extra_opts.push("--build-id".copy(self.a));
}

fn void Linux.push_pair(&self, String a, String b)
{
	self.extra_opts.push(a.copy(self.a));
	self.extra_opts.push(b.copy(self.a));
}

fn String Linux.default_linker(&self, Target* t) => t.abi.is_android() ? "ld.lld" : "ld";

fn String[] Linux.linker_extra_opts(&self) => self.extra_opts.entries[:self.extra_opts.size];

<*
 Appends the Linux-specific front of the linker command. The core resolves
 option defaults and supplies target emulation/dynamic-linker strings; an
 empty dynamic_linker means no path was available and must be diagnosed by
 the caller when a dynamic executable requires one. Startup objects, runtime
 libraries, user objects, and closing CRT files remain core-owned.
*>
fn void Linux.append_linker_policy(&self, Toolchain* tc, Target* t, bool pie, bool static_pie, bool rdynamic, bool strip,
	bool shared, bool static_link, bool relocatable, String emulation, String dynamic_linker,
	List{String}* argv)
{
	if (pie) argv.push("-pie");
	if (static_pie) argv.push_all({ "-static", "-pie", "--no-dynamic-linker", "-z", "text" });
	if (rdynamic) argv.push("-export-dynamic");
	if (strip) argv.push("-s");
	argv.push_all(self.linker_extra_opts());
	argv.push("--eh-frame-hdr");
	if (emulation.len == 0) return;
	argv.push_all({ "-m", emulation });
	if (t.cpu.arch.is_riscv()) argv.push("-X");
	if (shared) argv.push("-shared");
	if (static_link)
	{
		argv.push("-static");
	}
	else
	{
		if (rdynamic) argv.push("-export-dynamic");
		if (!shared && !static_pie && !relocatable && dynamic_linker.len != 0)
		{
			argv.push("-dynamic-linker");
			argv.push(dynamic_linker);
		}
		else if (!shared && !static_pie && !relocatable && dynamic_linker.len == 0)
		{
			tc.err("Could not find dynamic linker path");
		}
	}
}

fn String get_multiarch_triple(Target* t)
{
	bool android = t.abi.is_android();
	bool mips_r6 = t.cpu.has(MIPS_MIPS32R6) || t.cpu.has(MIPS_MIPS64R6);
	switch (t.cpu.arch)
	{
		case ARM:
		case THUMB: return android ? "arm-linux-androideabi" : (t.abi == GNUEABIHF ? "arm-linux-gnueabihf" : "arm-linux-gnueabi");
		case ARMEB:
		case THUMBEB: return t.abi == GNUEABIHF ? "armeb-linux-gnueabihf" : "armeb-linux-gnueabi";
		case AARCH64: return android ? "aarch64-linux-android" : "aarch64-linux-gnu";
		case AARCH64_BE: return "aarch64_be-linux-gnu";
		case X86: return android ? "i686-linux-android" : "i386-linux-gnu";
		case X86_64: return android ? "x86_64-linux-android" : (t.abi == GNUX32 ? "x86_64-linux-gnux32" : "x86_64-linux-gnu");
		case M68K: return "m68k-linux-gnu";
		case MIPS: return mips_r6 ? "mipsisa32r6-linux-gnu" : "mips-linux-gnu";
		case MIPSEL: return android ? "mipsel-linux-android" : (mips_r6 ? "mipsisa32r6el-linux-gnu" : "mipsel-linux-gnu");
		case POWERPCLE: return "powerpcle-linux-gnu";
		case POWERPC64: return "powerpc64-linux-gnu";
		case POWERPC64LE: return "powerpc64le-linux-gnu";
		case RISCV64: return "riscv64-linux-gnu";
		case SPARC: return "sparc-linux-gnu";
		case SPARC64: return "sparc64-linux-gnu";
		case S390X: return "s390x-linux-gnu";
		default: return "";
	}
}

fn String get_os_lib_dir(Target* t)
{
	switch (t.cpu.arch)
	{
		case X86:
		case POWERPC:
		case POWERPCLE:
		case SPARC: return "lib32";
		default: break;
	}
	if (t.cpu.arch == X86_64 && (t.abi == GNUX32 || t.abi == MUSLX32)) return "libx32";
	if (t.cpu.arch == RISCV32) return "lib32";
	if (t.ptr_bit_width() == 32) return "lib";
	return "lib64";
}
