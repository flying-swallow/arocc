// Port of src/aro/Toolchain/GCCDetector.zig: finding the GCC installation
// (prefixes, triple aliases, lib/gcc{,-cross}/<triple>/<version> scanning,
// biarch multilib selection) for env.target, through env.fs only.
//
// Behavior is kept verbatim, including Zig quirks (see the tests):
// - with a sysroot the second prefix is "/usr" ++ sysroot (string concat);
// - an explicit gcc_install_prefix replaces every default prefix, and is
//   ignored when a sysroot is set;
// - x86 has lib dirs but no triple aliases; the 32/64-bit variant's LLVM
//   triple is a plain (non-biarch) alias;
// - CSKY/MIPS/RISC-V/MSP430 multilib detection is a TODO (empty multilib).
// Deviations: Zig's `version` strings borrow the directory iterator's buffer
// (dangling after discover); here they borrow a detector-owned copy. Strings
// are owned by the detector (`free`) instead of Compilation.arena.
module aro::toolchain::gcc_detector;
import aro::toolchain::discovery, aro::toolchain::gcc_version, aro::toolchain::multilib;
import aro::target;
import std::collections::list;

<* Capacity of every candidate list (Zig uses [16]/[20] stack buffers). *>
const usz MAX_CANDIDATES = 20;

<* A fixed-capacity list of borrowed strings (Zig ArrayList.initBuffer). *>
struct CandidateList
{
	String[MAX_CANDIDATES] items;
	usz len;
}

<* @require self.len < MAX_CANDIDATES *>
fn void CandidateList.push(&self, String s)
{
	self.items[self.len++] = s;
}

fn String[] CandidateList.slice(&self) => self.items[:self.len];

<* The four lists collectLibDirsAndTriples fills. Strings are static. *>
struct Candidates
{
	CandidateList lib_dirs;
	CandidateList triple_aliases;
	CandidateList biarch_lib_dirs;
	CandidateList biarch_triple_aliases;
}

<*
 GCCDetector. Every string it stores (install_path, parent_lib_path,
 gcc_triple, the version text `version` borrows from, and the "/usr"+sysroot
 prefix) is allocated with `a` and released by `free`. Multilib suffixes and
 flags are static strings.
*>
struct GccDetector
{
	Allocator a;
	bool is_valid;
	String install_path;
	String parent_lib_path;
	GccVersion version;
	String gcc_triple;
	Multilib selected;
	<* Zig `?Multilib biarch_sibling` *>
	bool has_biarch_sibling;
	Multilib biarch_sibling;
	<* Allocations owned by the detector. *>
	List{String} owned;
}

fn void GccDetector.init(&self, Allocator a)
{
	*self = { .a = a, .version = gcc_version::DEFAULT };
	self.owned.init(a);
}

fn void GccDetector.free(&self)
{
	foreach (s : self.owned) alloc::free(self.a, s.ptr);
	self.owned.free();
	*self = {};
}

<* @require self.len + s.len <= MAX_CANDIDATES *>
fn void CandidateList.push_all(&self, String[] s)
{
	foreach (x : s) self.push(x);
}

fn String GccDetector.own(&self, String s)
{
	self.owned.push(s);
	return s;
}

<*
 appendToolPath: when valid, appends join(parent_lib_path, "..", gcc_triple,
 "bin") (allocated with `a`, owned by the caller) to `program_paths`.
*>
fn void GccDetector.append_tool_path(&self, Allocator a, List{String}* program_paths)
{
	if (!self.is_valid) return;
	program_paths.push(discovery::join(a, { self.parent_lib_path, "..", self.gcc_triple, "bin" }));
}

const String[] RH_PREFIXES = {
	"/opt/rh/gcc-toolset-12/root/usr",
	"/opt/rh/gcc-toolset-11/root/usr",
	"/opt/rh/gcc-toolset-10/root/usr",
	"/opt/rh/devtoolset-12/root/usr",
	"/opt/rh/devtoolset-11/root/usr",
	"/opt/rh/devtoolset-10/root/usr",
	"/opt/rh/devtoolset-9/root/usr",
	"/opt/rh/devtoolset-8/root/usr",
	"/opt/rh/devtoolset-7/root/usr",
	"/opt/rh/devtoolset-6/root/usr",
	"/opt/rh/devtoolset-4/root/usr",
	"/opt/rh/devtoolset-3/root/usr",
	"/opt/rh/devtoolset-2/root/usr",
};

<*
 addDefaultGCCPrefixes. With a sysroot, Zig appends "/usr" ++ sysroot (the
 string concatenation, e.g. "/usr/sr" for sysroot "/sr", not "/sr/usr");
 that behavior is preserved verbatim.
*>
fn void GccDetector.add_default_gcc_prefixes(&self, Env* env, CandidateList* prefixes)
{
	String sysroot = env.sysroot;
	if (sysroot.len == 0 && env.target.os.tag == LINUX && env.exists("/opt/rh"))
	{
		prefixes.push_all(RH_PREFIXES);
	}
	if (sysroot.len == 0)
	{
		prefixes.push("/usr");
	}
	else
	{
		prefixes.push(self.own("/usr".concat(self.a, sysroot)));
	}
}

// collectLibDirsAndTriples tables (verbatim from GCCDetector.zig).
const String[] AARCH64_LIB_DIRS = { "/lib64", "/lib" };
const String[] AARCH64_TRIPLES = { "aarch64-none-linux-gnu", "aarch64-linux-gnu", "aarch64-redhat-linux", "aarch64-suse-linux" };
const String[] AARCH64BE_LIB_DIRS = { "/lib" };
const String[] AARCH64BE_TRIPLES = { "aarch64_be-none-linux-gnu", "aarch64_be-linux-gnu" };

const String[] ARM_LIB_DIRS = { "/lib" };
const String[] ARM_TRIPLES = { "arm-linux-gnueabi" };
const String[] ARMHF_TRIPLES = { "arm-linux-gnueabihf", "armv7hl-redhat-linux-gnueabi", "armv6hl-suse-linux-gnueabi", "armv7hl-suse-linux-gnueabi" };

const String[] ARMEB_LIB_DIRS = { "/lib" };
const String[] ARMEB_TRIPLES = { "armeb-linux-gnueabi" };
const String[] ARMEBHF_TRIPLES = { "armeb-linux-gnueabihf", "armebv7hl-redhat-linux-gnueabi" };

const String[] AVR_LIB_DIRS = { "/lib" };
const String[] AVR_TRIPLES = { "avr" };

const String[] CSKY_LIB_DIRS = { "/lib" };
const String[] CSKY_TRIPLES = { "csky-linux-gnuabiv2", "csky-linux-uclibcabiv2", "csky-elf-noneabiv2" };

const String[] X86_64_LIB_DIRS = { "/lib64", "/lib" };
const String[] X86_64_TRIPLES = {
	"x86_64-linux-gnu", "x86_64-unknown-linux-gnu",
	"x86_64-pc-linux-gnu", "x86_64-redhat-linux6E",
	"x86_64-redhat-linux", "x86_64-suse-linux",
	"x86_64-manbo-linux-gnu", "x86_64-linux-gnu",
	"x86_64-slackware-linux", "x86_64-unknown-linux",
	"x86_64-amazon-linux",
};
const String[] X32_TRIPLES = { "x86_64-linux-gnux32", "x86_64-pc-linux-gnux32" };
const String[] X32_LIB_DIRS = { "/libx32", "/lib" };
const String[] X86_LIB_DIRS = { "/lib32", "/lib" };
const String[] X86_TRIPLES = {
	"i586-linux-gnu", "i686-linux-gnu", "i686-pc-linux-gnu",
	"i386-redhat-linux6E", "i686-redhat-linux", "i386-redhat-linux",
	"i586-suse-linux", "i686-montavista-linux", "i686-gnu",
};

const String[] LOONGARCH64_LIB_DIRS = { "/lib64", "/lib" };
const String[] LOONGARCH64_TRIPLES = { "loongarch64-linux-gnu", "loongarch64-unknown-linux-gnu" };

const String[] M68K_LIB_DIRS = { "/lib" };
const String[] M68K_TRIPLES = { "m68k-linux-gnu", "m68k-unknown-linux-gnu", "m68k-suse-linux" };

const String[] MIPS_LIB_DIRS = { "/libo32", "/lib" };
const String[] MIPS_TRIPLES = { "mips-linux-gnu", "mips-mti-linux", "mips-mti-linux-gnu", "mips-img-linux-gnu", "mipsisa32r6-linux-gnu" };
const String[] MIPSEL_LIB_DIRS = { "/libo32", "/lib" };
const String[] MIPSEL_TRIPLES = { "mipsel-linux-gnu", "mips-img-linux-gnu", "mipsisa32r6el-linux-gnu" };

const String[] MIPS64_LIB_DIRS = { "/lib64", "/lib" };
const String[] MIPS64_TRIPLES = {
	"mips64-linux-gnu", "mips-mti-linux-gnu",
	"mips-img-linux-gnu", "mips64-linux-gnuabi64",
	"mipsisa64r6-linux-gnu", "mipsisa64r6-linux-gnuabi64",
};
const String[] MIPS64EL_LIB_DIRS = { "/lib64", "/lib" };
const String[] MIPS64EL_TRIPLES = {
	"mips64el-linux-gnu", "mips-mti-linux-gnu",
	"mips-img-linux-gnu", "mips64el-linux-gnuabi64",
	"mipsisa64r6el-linux-gnu", "mipsisa64r6el-linux-gnuabi64",
};

const String[] MIPSN32_LIB_DIRS = { "/lib32" };
const String[] MIPSN32_TRIPLES = { "mips64-linux-gnuabin32", "mipsisa64r6-linux-gnuabin32" };
const String[] MIPSN32EL_LIB_DIRS = { "/lib32" };
const String[] MIPSN32EL_TRIPLES = { "mips64el-linux-gnuabin32", "mipsisa64r6el-linux-gnuabin32" };

const String[] MSP430_LIB_DIRS = { "/lib" };
const String[] MSP430_TRIPLES = { "msp430-elf" };

const String[] PPC_LIB_DIRS = { "/lib32", "/lib" };
const String[] PPC_TRIPLES = {
	"powerpc-linux-gnu", "powerpc-unknown-linux-gnu", "powerpc-linux-gnuspe",
	// On 32-bit PowerPC systems running SUSE Linux, gcc is configured as a
	// 64-bit compiler which defaults to "-m32", hence "powerpc64-suse-linux".
	"powerpc64-suse-linux", "powerpc-montavista-linuxspe",
};
const String[] PPCLE_LIB_DIRS = { "/lib32", "/lib" };
const String[] PPCLE_TRIPLES = { "powerpcle-linux-gnu", "powerpcle-unknown-linux-gnu", "powerpcle-linux-musl" };

const String[] PPC64_LIB_DIRS = { "/lib64", "/lib" };
const String[] PPC64_TRIPLES = { "powerpc64-linux-gnu", "powerpc64-unknown-linux-gnu", "powerpc64-suse-linux", "ppc64-redhat-linux" };
const String[] PPC64LE_LIB_DIRS = { "/lib64", "/lib" };
const String[] PPC64LE_TRIPLES = {
	"powerpc64le-linux-gnu", "powerpc64le-unknown-linux-gnu",
	"powerpc64le-none-linux-gnu", "powerpc64le-suse-linux",
	"ppc64le-redhat-linux",
};

const String[] RISCV32_LIB_DIRS = { "/lib32", "/lib" };
const String[] RISCV32_TRIPLES = { "riscv32-unknown-linux-gnu", "riscv32-linux-gnu", "riscv32-unknown-elf" };
const String[] RISCV64_LIB_DIRS = { "/lib64", "/lib" };
const String[] RISCV64_TRIPLES = { "riscv64-unknown-linux-gnu", "riscv64-linux-gnu", "riscv64-unknown-elf" };

const String[] SPARCV8_LIB_DIRS = { "/lib32", "/lib" };
const String[] SPARCV8_TRIPLES = { "sparc-linux-gnu", "sparcv8-linux-gnu" };
const String[] SPARCV9_LIB_DIRS = { "/lib64", "/lib" };
const String[] SPARCV9_TRIPLES = { "sparc64-linux-gnu", "sparcv9-linux-gnu" };

const String[] SYSTEMZ_LIB_DIRS = { "/lib64", "/lib" };
const String[] SYSTEMZ_TRIPLES = { "s390x-linux-gnu", "s390x-unknown-linux-gnu", "s390x-ibm-linux-gnu", "s390x-suse-linux", "s390x-redhat-linux" };

const String[] AARCH64_ANDROID_TRIPLES = { "aarch64-linux-android" };
const String[] ARM_ANDROID_TRIPLES = { "arm-linux-androideabi" };
const String[] MIPSEL_ANDROID_TRIPLES = { "mipsel-linux-android" };
const String[] MIPS64EL_ANDROID_TRIPLES = { "mips64el-linux-android" };
const String[] X86_ANDROID_TRIPLES = { "i686-linux-android" };
const String[] X86_64_ANDROID_TRIPLES = { "x86_64-linux-android" };

<*
 collectLibDirsAndTriples for env.target. Quirks kept from Zig: x86 gets lib
 dirs but no triple aliases (it relies on its own triple and the x86_64
 biarch variant), arm/thumb have no biarch lists, illumos gets nothing.
*>
fn void collect_lib_dirs_and_triples(Env* env, Candidates* out)
{
	Target* target = &env.target;
	if (target.os.tag == ILLUMOS) return; // TODO in Zig
	if (target.abi.is_android())
	{
		switch (target.cpu.arch)
		{
			case AARCH64:
				out.lib_dirs.push_all(AARCH64_LIB_DIRS);
				out.triple_aliases.push_all(AARCH64_ANDROID_TRIPLES);
			case ARM:
			case THUMB:
				out.lib_dirs.push_all(ARM_LIB_DIRS);
				out.triple_aliases.push_all(ARM_ANDROID_TRIPLES);
			case MIPSEL:
				out.lib_dirs.push_all(MIPSEL_LIB_DIRS);
				out.triple_aliases.push_all(MIPSEL_ANDROID_TRIPLES);
				out.biarch_lib_dirs.push_all(MIPS64EL_LIB_DIRS);
				out.biarch_triple_aliases.push_all(MIPS64EL_ANDROID_TRIPLES);
			case MIPS64EL:
				out.lib_dirs.push_all(MIPS64EL_LIB_DIRS);
				out.triple_aliases.push_all(MIPS64EL_ANDROID_TRIPLES);
				out.biarch_lib_dirs.push_all(MIPSEL_LIB_DIRS);
				out.biarch_triple_aliases.push_all(MIPSEL_ANDROID_TRIPLES);
			case X86_64:
				out.lib_dirs.push_all(X86_64_LIB_DIRS);
				out.triple_aliases.push_all(X86_64_ANDROID_TRIPLES);
				out.biarch_lib_dirs.push_all(X86_LIB_DIRS);
				out.biarch_triple_aliases.push_all(X86_ANDROID_TRIPLES);
			case X86:
				out.lib_dirs.push_all(X86_LIB_DIRS);
				out.triple_aliases.push_all(X86_ANDROID_TRIPLES);
				out.biarch_lib_dirs.push_all(X86_64_LIB_DIRS);
				out.biarch_triple_aliases.push_all(X86_64_ANDROID_TRIPLES);
			default:
				break;
		}
		return;
	}
	switch (target.cpu.arch)
	{
		case AARCH64:
			out.lib_dirs.push_all(AARCH64_LIB_DIRS);
			out.triple_aliases.push_all(AARCH64_TRIPLES);
			out.biarch_lib_dirs.push_all(AARCH64_LIB_DIRS);
			out.biarch_triple_aliases.push_all(AARCH64_TRIPLES);
		case AARCH64_BE:
			out.lib_dirs.push_all(AARCH64BE_LIB_DIRS);
			out.triple_aliases.push_all(AARCH64BE_TRIPLES);
			out.biarch_lib_dirs.push_all(AARCH64BE_LIB_DIRS);
			out.biarch_triple_aliases.push_all(AARCH64BE_TRIPLES);
		case ARM:
		case THUMB:
			out.lib_dirs.push_all(ARM_LIB_DIRS);
			out.triple_aliases.push_all(target.abi == GNUEABIHF ? ARMHF_TRIPLES : ARM_TRIPLES);
		case ARMEB:
		case THUMBEB:
			out.lib_dirs.push_all(ARMEB_LIB_DIRS);
			out.triple_aliases.push_all(target.abi == GNUEABIHF ? ARMEBHF_TRIPLES : ARMEB_TRIPLES);
		case AVR:
			out.lib_dirs.push_all(AVR_LIB_DIRS);
			out.triple_aliases.push_all(AVR_TRIPLES);
		case CSKY:
			out.lib_dirs.push_all(CSKY_LIB_DIRS);
			out.triple_aliases.push_all(CSKY_TRIPLES);
		case X86_64:
			if (target.abi == GNUX32 || target.abi == MUSLX32)
			{
				out.lib_dirs.push_all(X32_LIB_DIRS);
				out.triple_aliases.push_all(X32_TRIPLES);
				out.biarch_lib_dirs.push_all(X86_64_LIB_DIRS);
				out.biarch_triple_aliases.push_all(X86_64_TRIPLES);
			}
			else
			{
				out.lib_dirs.push_all(X86_64_LIB_DIRS);
				out.triple_aliases.push_all(X86_64_TRIPLES);
				out.biarch_lib_dirs.push_all(X32_LIB_DIRS);
				out.biarch_triple_aliases.push_all(X32_TRIPLES);
			}
			out.biarch_lib_dirs.push_all(X86_LIB_DIRS);
			out.biarch_triple_aliases.push_all(X86_TRIPLES);
		case X86:
			out.lib_dirs.push_all(X86_LIB_DIRS);
		case LOONGARCH64:
			out.lib_dirs.push_all(LOONGARCH64_LIB_DIRS);
			out.triple_aliases.push_all(LOONGARCH64_TRIPLES);
		case M68K:
			out.lib_dirs.push_all(M68K_LIB_DIRS);
			out.triple_aliases.push_all(M68K_TRIPLES);
		case MIPS:
			out.lib_dirs.push_all(MIPS_LIB_DIRS);
			out.triple_aliases.push_all(MIPS_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPS64_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPS64_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPSN32_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPSN32_TRIPLES);
		case MIPSEL:
			out.lib_dirs.push_all(MIPSEL_LIB_DIRS);
			out.triple_aliases.push_all(MIPSEL_TRIPLES);
			out.triple_aliases.push_all(MIPS_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPS64EL_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPS64EL_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPSN32EL_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPSN32EL_TRIPLES);
		case MIPS64:
			out.lib_dirs.push_all(MIPS64_LIB_DIRS);
			out.triple_aliases.push_all(MIPS64_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPS_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPS_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPSN32_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPSN32_TRIPLES);
		case MIPS64EL:
			out.lib_dirs.push_all(MIPS64EL_LIB_DIRS);
			out.triple_aliases.push_all(MIPS64EL_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPSEL_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPSEL_TRIPLES);
			out.biarch_lib_dirs.push_all(MIPSN32EL_LIB_DIRS);
			out.biarch_triple_aliases.push_all(MIPSN32EL_TRIPLES);
			out.biarch_triple_aliases.push_all(MIPS_TRIPLES);
		case MSP430:
			out.lib_dirs.push_all(MSP430_LIB_DIRS);
			out.triple_aliases.push_all(MSP430_TRIPLES);
		case POWERPC:
			out.lib_dirs.push_all(PPC_LIB_DIRS);
			out.triple_aliases.push_all(PPC_TRIPLES);
			out.biarch_lib_dirs.push_all(PPC64_LIB_DIRS);
			out.biarch_triple_aliases.push_all(PPC64_TRIPLES);
		case POWERPCLE:
			out.lib_dirs.push_all(PPCLE_LIB_DIRS);
			out.triple_aliases.push_all(PPCLE_TRIPLES);
			out.biarch_lib_dirs.push_all(PPC64LE_LIB_DIRS);
			out.biarch_triple_aliases.push_all(PPC64LE_TRIPLES);
		case POWERPC64:
			out.lib_dirs.push_all(PPC64_LIB_DIRS);
			out.triple_aliases.push_all(PPC64_TRIPLES);
			out.biarch_lib_dirs.push_all(PPC_LIB_DIRS);
			out.biarch_triple_aliases.push_all(PPC_TRIPLES);
		case POWERPC64LE:
			out.lib_dirs.push_all(PPC64LE_LIB_DIRS);
			out.triple_aliases.push_all(PPC64LE_TRIPLES);
			out.biarch_lib_dirs.push_all(PPCLE_LIB_DIRS);
			out.biarch_triple_aliases.push_all(PPCLE_TRIPLES);
		case RISCV32:
			out.lib_dirs.push_all(RISCV32_LIB_DIRS);
			out.triple_aliases.push_all(RISCV32_TRIPLES);
			out.biarch_lib_dirs.push_all(RISCV64_LIB_DIRS);
			out.biarch_triple_aliases.push_all(RISCV64_TRIPLES);
		case RISCV64:
			out.lib_dirs.push_all(RISCV64_LIB_DIRS);
			out.triple_aliases.push_all(RISCV64_TRIPLES);
			out.biarch_lib_dirs.push_all(RISCV32_LIB_DIRS);
			out.biarch_triple_aliases.push_all(RISCV32_TRIPLES);
		case SPARC:
			out.lib_dirs.push_all(SPARCV8_LIB_DIRS);
			out.triple_aliases.push_all(SPARCV8_TRIPLES);
			out.biarch_lib_dirs.push_all(SPARCV9_LIB_DIRS);
			out.biarch_triple_aliases.push_all(SPARCV9_TRIPLES);
		case SPARC64:
			out.lib_dirs.push_all(SPARCV9_LIB_DIRS);
			out.triple_aliases.push_all(SPARCV9_TRIPLES);
			out.biarch_lib_dirs.push_all(SPARCV8_LIB_DIRS);
			out.biarch_triple_aliases.push_all(SPARCV8_TRIPLES);
		case S390X:
			out.lib_dirs.push_all(SYSTEMZ_LIB_DIRS);
			out.triple_aliases.push_all(SYSTEMZ_TRIPLES);
		default:
			break;
	}
}

<* gccToolchainDir: "" when a sysroot is set, else env.gcc_install_prefix. *>
fn String gcc_toolchain_dir(Env* env)
{
	if (env.sysroot.len != 0) return "";
	return env.gcc_install_prefix;
}

<*
 The ordered GCC prefixes discover() scans (exposed for tests): the explicit
 GCC install prefix (one trailing '/' dropped) alone when set, else the
 sysroot (if any) followed by addDefaultGCCPrefixes.
*>
fn void GccDetector.collect_prefixes(&self, Env* env, CandidateList* prefixes)
{
	String toolchain_dir = gcc_toolchain_dir(env);
	if (toolchain_dir.len != 0)
	{
		String adjusted = toolchain_dir[^1] == '/' ? toolchain_dir[:^1] : toolchain_dir;
		prefixes.push(adjusted);
		return;
	}
	String sysroot = env.sysroot;
	if (sysroot.len > 0)
	{
		prefixes.push(sysroot);
		self.add_default_gcc_prefixes(env, prefixes);
	}
	if (sysroot.len == 0) self.add_default_gcc_prefixes(env, prefixes);
	// TODO (Zig): Special-case handling for Gentoo
}

<*
 GCCDetector.discover. Fails only with multilib::TOO_MANY_MULTILIBS
 (out-of-memory panics, see CONVENTIONS.md).
*>
fn void? GccDetector.discover(&self, Env* env)
{
	Target* target = &env.target;
	bool has_biarch = false;
	Target biarch_variant_target;
	if (target.ptr_bit_width() == 32)
	{
		if (try t = target.get_64bit_arch_variant())
		{
			biarch_variant_target = t;
			has_biarch = true;
		}
	}
	else
	{
		if (try t = target.get_32bit_arch_variant())
		{
			biarch_variant_target = t;
			has_biarch = true;
		}
	}

	Candidates c;
	collect_lib_dirs_and_triples(env, &c);

	char[64] target_buf;
	String triple_str = target.to_llvm_triple(&target_buf);
	c.triple_aliases.push(triple_str);

	// Also include the multiarch variant if it's different.
	char[64] biarch_buf;
	if (has_biarch)
	{
		String biarch_triple_str = biarch_variant_target.to_llvm_triple(&biarch_buf);
		if (biarch_triple_str != triple_str) c.triple_aliases.push(biarch_triple_str);
	}

	CandidateList prefixes;
	self.collect_prefixes(env, &prefixes);

	GccVersion v0 = gcc_version::parse("0.0.0");
	char[discovery::MAX_PATH_BYTES] path_buf;
	foreach (prefix : prefixes.slice())
	{
		if (!env.exists(prefix)) continue;

		foreach (suffix : c.lib_dirs.slice())
		{
			String? lib_dir = discovery::join_buf(&path_buf, { prefix, suffix });
			if (catch lib_dir) continue;
			if (!env.exists(lib_dir)) continue;

			bool gcc_dir_exists = env.joined_exists({ lib_dir, "/gcc" });
			bool gcc_cross_dir_exists = env.joined_exists({ lib_dir, "/gcc-cross" });

			self.scan_lib_dir_for_gcc_triple(env, lib_dir, triple_str, false, gcc_dir_exists, gcc_cross_dir_exists)!;
			foreach (candidate : c.triple_aliases.slice())
			{
				self.scan_lib_dir_for_gcc_triple(env, lib_dir, candidate, false, gcc_dir_exists, gcc_cross_dir_exists)!;
			}
		}
		foreach (suffix : c.biarch_lib_dirs.slice())
		{
			String? lib_dir = discovery::join_buf(&path_buf, { prefix, suffix });
			if (catch lib_dir) continue;
			if (!env.exists(lib_dir)) continue;

			bool gcc_dir_exists = env.joined_exists({ lib_dir, "/gcc" });
			bool gcc_cross_dir_exists = env.joined_exists({ lib_dir, "/gcc-cross" });
			foreach (candidate : c.biarch_triple_aliases.slice())
			{
				self.scan_lib_dir_for_gcc_triple(env, lib_dir, candidate, true, gcc_dir_exists, gcc_cross_dir_exists)!;
			}
		}
		if (self.version.order(v0) == GT) break;
	}
}

<*
 scanLibDirForGCCTriple: every directory entry of lib_dir/gcc{,-cross}/triple
 that parses as a version >= 4.1.1, is strictly preferred over the current
 pick, and has a usable multilib becomes the selection. Non-directory entries
 (files, symlinks) are skipped, as in Zig.
*>
fn void? GccDetector.scan_lib_dir_for_gcc_triple(&self, Env* env, String lib_dir, String candidate_triple, bool needs_biarch_suffix, bool gcc_dir_exists, bool gcc_cross_dir_exists)
{
	for (int i = 0; i < 2; i++)
	{
		if (i == 0 && !gcc_dir_exists) continue;
		if (i == 1 && !gcc_cross_dir_exists) continue;

		String base = i == 0 ? "gcc" : "gcc-cross";
		char[64] lib_suffix_buf;
		String? lib_suffix = discovery::join_buf(&lib_suffix_buf, { base, candidate_triple });
		if (catch lib_suffix) continue;

		char[discovery::MAX_PATH_BYTES] dir_buf;
		String? dir_name = discovery::join_buf(&dir_buf, { lib_dir, lib_suffix });
		if (catch dir_name) continue;

		@pool()
		{
			DirEntryList entries;
			entries.init(tmem);
			if (catch env.list_dir(dir_name, tmem, &entries)) continue;
			foreach (entry : entries)
			{
				if (entry.kind != DIRECTORY) continue;
				String version_text = entry.name;
				GccVersion candidate_version = gcc_version::parse(version_text);
				if (candidate_version.is_less_than(4, 1, 1, "")) continue;
				if (candidate_version.order(self.version) != GT) continue;

				if (!self.scan_gcc_for_multilibs(env, { dir_name, version_text }, needs_biarch_suffix)!) continue;

				String owned_text = self.own(version_text.copy(self.a));
				self.version = gcc_version::parse(owned_text);
				self.gcc_triple = self.own(candidate_triple.copy(self.a));
				self.install_path = self.own(discovery::join(self.a, { lib_dir, lib_suffix, version_text }));
				self.parent_lib_path = self.own(discovery::join(self.a, { self.install_path, "..", "..", ".." }));
				self.is_valid = true;
			}
		};
	}
}

<* scanGCCForMultilibs; path = { dir_name, version_text }. *>
fn bool? GccDetector.scan_gcc_for_multilibs(&self, Env* env, String[2] path, bool needs_biarch_suffix)
{
	Detected detected;
	Arch arch = env.target.cpu.arch;
	if (arch == CSKY || arch.is_mips() || arch.is_riscv() || arch == MSP430)
	{
		// TODO in Zig: the default (empty) multilib is selected.
	}
	else if (arch == AVR)
	{
		// No multilibs
	}
	else if (!find_biarch_multilibs(env, &detected, path, needs_biarch_suffix)!)
	{
		return false;
	}
	self.selected = detected.selected;
	self.has_biarch_sibling = detected.has_biarch_sibling;
	self.biarch_sibling = detected.biarch_sibling;
	return true;
}

enum Want : char
{
	WANT32,
	WANT64,
	WANTX32,
}

<* findBiarchMultilibs. *>
fn bool? find_biarch_multilibs(Env* env, Detected* result, String[2] path, bool needs_biarch_suffix)
{
	Target* target = &env.target;
	String suff64 = "/64";
	if (target.os.tag == ILLUMOS)
	{
		switch (target.cpu.arch)
		{
			case X86:
			case X86_64: suff64 = "/amd64";
			case SPARC: suff64 = "/sparcv9";
			default: break;
		}
	}

	Multilib alt_64 = multilib::init(suff64, suff64, { "-m32", "+m64", "-mx32" });
	Multilib alt_32 = multilib::init("/32", "/32", { "+m32", "-m64", "-mx32" });
	Multilib alt_x32 = multilib::init("/x32", "/x32", { "-m32", "-m64", "+mx32" });

	Filter multilib_filter = { .base = { path[0], path[1] }, .file = "crtbegin.o" };

	bool is_x32 = target.abi == GNUX32 || target.abi == MUSLX32;
	ushort target_ptr_width = target.ptr_bit_width();
	Want want;
	if (target_ptr_width == 32 && multilib_filter.exists(&alt_32, env))
	{
		want = WANT64;
	}
	else if (target_ptr_width == 64 && is_x32 && multilib_filter.exists(&alt_x32, env))
	{
		want = WANT64;
	}
	else if (target_ptr_width == 64 && !is_x32 && multilib_filter.exists(&alt_64, env))
	{
		want = WANT32;
	}
	else if (target_ptr_width == 32)
	{
		want = needs_biarch_suffix ? WANT64 : WANT32;
	}
	else if (is_x32)
	{
		want = needs_biarch_suffix ? WANT64 : WANTX32;
	}
	else
	{
		want = needs_biarch_suffix ? WANT32 : WANT64;
	}

	Multilib default_ml;
	switch (want)
	{
		case WANT32: default_ml = multilib::init("", "", { "+m32", "-m64", "-mx32" });
		case WANT64: default_ml = multilib::init("", "", { "-m32", "+m64", "-mx32" });
		case WANTX32: default_ml = multilib::init("", "", { "-m32", "-m64", "+mx32" });
	}
	result.push(default_ml);
	result.push(alt_64);
	result.push(alt_32);
	result.push(alt_x32);

	result.filter(multilib_filter, env);
	return result.select({
		target_ptr_width == 64 && !is_x32 ? "+m64" : "-m64",
		target_ptr_width == 32 ? "+m32" : "-m32",
		target_ptr_width == 64 && is_x32 ? "+mx32" : "-mx32",
	});
}
