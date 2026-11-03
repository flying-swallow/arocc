// std.Target ABI data for aro::target: the parts of Zig's std.Target and
// std.zig.system that src/aro/Target.zig and Driver.zig rely on.
//
// PROVENANCE AND LICENSING
// The rules below are ported from Zig std.Target (lib/std/Target.zig,
// MIT license, Copyright (c) Zig contributors): ptrBitWidth_arch_abi,
// cTypeBitSize, cTypeAlignment, cTypeByteSize, cCharSignedness, Abi.default,
// ObjectFormat.default, Os.Tag.versionRangeTag, Os.VersionRange.default,
// Os.WindowsVersion and DynamicLinker.standard. The pinned Zig std library is
// not available in this environment, so every table here is
// "from Zig std.Target knowledge, not verified by execution".
//
// Cross-checks that WERE done (see test/c3/target_tests.c3):
// - sizeof/_Alignof of char..double and void* for every target string of
//   test/records/0013_test.c (mahkoh/repr-c expectations, 109 targets) except
//   the x86/arm Darwin ones the record runner skips;
// - test/cases fixtures: "avr sizeof long.c" (long double 4 bytes),
//   "msp430 builtin types.c" (long double 8 bytes, align 2, unsigned char),
//   "float header *.c" (x86_64 and x86 NetBSD long double is x87 80-bit,
//   aarch64-linux-gnu long double is IEEE quad), "uefi intmax_t.c";
// - Target.zig's own `test` blocks (parseOs: 3ds is semver, ps3 has no
//   version range, linux/windows/ios/macOS ranges).
// Anything else (notably Darwin/BSD default OS versions, glibc/Android
// defaults, dynamic linker paths for non-x86 targets, alignment caps for
// architectures without fixtures) is unverified.
//
// INVENTORY of std.Target / std.zig.system queries made by src/aro (Target.zig,
// Compilation.zig, Driver.zig, LangOpts.zig, TypeStore.zig, Toolchain) and
// where they live in C3:
//   Cpu.Arch tags, endian(), isX86/isArm/isThumb/isAARCH64/isMIPS(32|64)/
//     isPowerPC/isRISCV/isWasm/isSpirV         -> Arch (target.c3)
//   Cpu.Arch.parseCpuModel, allFeaturesList (Driver -mcpu/+feat) -> parse_cpu_model,
//     parse_feature_name (target_cpu.c3; tracked features only, see there)
//   Cpu.has/hasAll/hasAny, features.isEnabled -> Cpu.has/has_all/has_any
//   Cpu.Model (llvm_name, ==)                -> CpuModel (target_cpu.c3)
//   Cpu.Model.generic/baseline               -> generic_model/baseline_model
//   Os.Tag tags, isDarwin, isBSD, versionRangeTag -> OsTag (target.c3)
//   Os.version_range.semver.min/.order, isAtLeast -> Os.min/max, Os.is_at_least
//   Os.WindowsVersion.parse                  -> windows_version_parse (here)
//   Abi tags, isGnu/isMusl/isAndroid, float(), default() -> Abi (target.c3), default_abi
//   ObjectFormat, ObjectFormat.default       -> ObjectFormat, default_object_format
//   ObjectFormat.fileExt, Cpu.Arch.plan9Ext  -> ObjectFormat.file_ext
//   ptrBitWidth_cpu_abi                      -> ptr_bit_width_arch_abi
//   cTypeBitSize/cTypeAlignment/cTypeByteSize -> c_type_bit_size/alignment/byte_size
//   cCharSignedness                          -> c_char_signedness
//   DynamicLinker.standard                   -> standard_dynamic_linker
//   Query.parse/isNative/isNativeAbi, zig.system.resolveTargetQuery
//                                            -> Query, resolve_query, parse_triple
//   toElfMachine (ELF backend)               -> not ported (plan 27 owns ELF output)
module aro::target;
import aro::lang_opts;

<* std.Target.ptrBitWidth_arch_abi. *>
fn ushort ptr_bit_width_arch_abi(Arch arch, Abi abi)
{
	switch (abi)
	{
		case GNUX32:
		case MUSLX32:
		case X32:
		case GNUABIN32:
		case MUSLABIN32:
		case ABIN32:
		case ILP32: return 32;
		case GNUABI64:
		case MUSLABI64: return 64;
		default: return arch.ptr_bits;
	}
}

fn bool is_16bit_int_arch(Arch arch) @local
{
	switch (arch)
	{
		case AVR:
		case MSP430:
		case X86_16:
		case Z80:
		case EZ80:
		case SPORK8: return true;
		default: return false;
	}
}

<* std.Target.cTypeBitSize. *>
fn ushort c_type_bit_size(Target* t, CType c_type)
{
	Arch arch = t.cpu.arch;
	OsTag os = t.os.tag;
	switch (c_type)
	{
		case SHORT:
		case USHORT: return 16;
		case INT:
		case UINT: return is_16bit_int_arch(arch) ? 16 : 32;
		case FLOAT: return 32;
		case DOUBLE: return arch == AVR ? 32 : 64;
		case LONGLONG:
		case ULONGLONG: return (os == OPENCL || os == VULKAN) ? 128 : 64;
		case LONG:
		case ULONG:
			if (is_16bit_int_arch(arch)) return 32;
			switch (os)
			{
				case WINDOWS:
				case UEFI: return 32;
				case CUDA:
				case NVCL: return arch == NVPTX ? 32 : 64;
				case AMDHSA:
				case OPENCL:
				case VULKAN:
				case PS4:
				case PS5: return 64;
				default:
					if (os.is_darwin())
					{
						if (arch == X86 || arch == ARM || arch == THUMB) return 32;
						if (arch == X86_64) return 64;
					}
					ushort w = t.ptr_bit_width();
					return w < 32 ? 32 : w;
			}
		case CHAR: return 8;
		case LONGDOUBLE: return long_double_bits(t);
	}
}

fn ushort long_double_bits(Target* t) @local
{
	Arch arch = t.cpu.arch;
	OsTag os = t.os.tag;
	switch (arch)
	{
		case AVR: return 32;
		case MSP430: return 64;
		default: break;
	}
	switch (os)
	{
		case WINDOWS:
		case UEFI:
			if ((arch == X86 || arch == X86_64) && t.abi == GNU) return 80;
			return 64;
		case CUDA:
		case NVCL: return 64;
		case AMDHSA:
		case OPENCL:
		case VULKAN: return 128;
		case PS4:
		case PS5: return 80;
		default: break;
	}
	if (os.is_darwin())
	{
		if (arch == X86 || arch == X86_64) return 80;
		return 64;
	}
	switch (arch)
	{
		case X86:
		case X86C16:
			return t.abi == ANDROID ? 64 : 80;
		case X86_64:
		case X86_16:
		case M68K: return 80;
		case MIPS64:
		case MIPS64EL: return 128;
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE:
			switch (t.abi)
			{
				case MUSL:
				case MUSLEABI:
				case MUSLEABIHF:
				case MUSLX32: return 64;
				default: break;
			}
			if (os == FREEBSD || os == NETBSD || os == OPENBSD) return 64;
			return 128;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE:
		case AARCH64:
		case AARCH64_BE:
		case S390X:
		case SPARC:
		case SPARC64:
		case WASM32:
		case WASM64:
		case LOONGARCH32:
		case LOONGARCH64:
		case VE: return 128;
		default: return 64;
	}
}

fn ushort ceil_pow2(ushort v) @local
{
	ushort p = 1;
	while (p < v) p <<= 1;
	return p;
}

<* std.Target.cTypeAlignment. *>
fn ushort c_type_alignment(Target* t, CType c_type)
{
	// Overrides for unusual alignments
	switch (t.cpu.arch)
	{
		case AVR: return 1;
		case X86:
			if (t.os.tag == WINDOWS || t.os.tag == UEFI)
			{
				switch (c_type)
				{
					case LONGLONG:
					case ULONGLONG:
					case DOUBLE: return 8;
					case LONGDOUBLE: return t.abi == GNU ? 4 : 8;
					default: break;
				}
			}
		default: break;
	}
	// Next-power-of-two-aligned, up to a maximum.
	ushort natural = ceil_pow2((c_type_bit_size(t, c_type) + 7) / 8);
	ushort max = t.cpu.arch.max_align;
	return natural < max ? natural : max;
}

<* std.Target.cTypeByteSize: long double of 80 bits is padded to its alignment. *>
fn ushort c_type_byte_size(Target* t, CType c_type)
{
	ushort bits = c_type_bit_size(t, c_type);
	if (c_type == LONGDOUBLE && bits == 80)
	{
		ushort a = c_type_alignment(t, c_type);
		return (10 + a - 1) / a * a;
	}
	return bits / 8;
}

<* std.Target.cCharSignedness. *>
fn Signedness c_char_signedness(Target* t)
{
	if (t.os.tag.is_darwin() || t.os.tag == WINDOWS || t.os.tag == UEFI) return SIGNED;
	switch (t.cpu.arch)
	{
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB:
		case AARCH64:
		case AARCH64_BE:
		case ARC:
		case ARCEB:
		case CSKY:
		case HEXAGON:
		case MSP430:
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE:
		case S390X:
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE:
		case XCORE:
		case XTENSA:
		case XTENSAEB: return UNSIGNED;
		default: return SIGNED;
	}
}

<* std.Target.Abi.default. *>
fn Abi default_abi(Arch arch, OsTag os)
{
	switch (os)
	{
		case FREESTANDING:
		case OTHER:
			switch (arch)
			{
				// Soft float is usually a sane default for freestanding.
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case CSKY:
				case MIPS:
				case MIPSEL:
				case POWERPC:
				case POWERPCLE: return EABI;
				default: return NONE;
			}
		case HAIKU:
			switch (arch)
			{
				case ARM:
				case THUMB:
				case POWERPC: return EABIHF;
				default: return NONE;
			}
		case HURD: return GNU;
		case LINUX:
			switch (arch)
			{
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case POWERPC:
				case POWERPCLE: return MUSLEABIHF;
				// Soft float tends to be more common for CSKY and MIPS.
				case CSKY: return GNUEABI; // No musl support.
				case MIPS:
				case MIPSEL: return MUSLEABI;
				case MIPS64:
				case MIPS64EL: return MUSLABI64;
				default: return MUSL;
			}
		case RTEMS:
			switch (arch)
			{
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case MIPS:
				case MIPSEL: return EABI;
				case POWERPC: return EABIHF;
				default: return NONE;
			}
		case FREEBSD:
		case NETBSD:
			switch (arch)
			{
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case POWERPC: return EABIHF;
				// Soft float tends to be more common for MIPS.
				case MIPS:
				case MIPSEL: return EABI;
				default: return NONE;
			}
		case OPENBSD:
			switch (arch)
			{
				case ARM:
				case THUMB: return EABI;
				case POWERPC: return EABIHF;
				default: return NONE;
			}
		case IOS:
		case TVOS:
		case VISIONOS:
		case WATCHOS: return arch == X86_64 ? SIMULATOR : NONE;
		case WINDOWS: return GNU;
		case UEFI: return MSVC;
		case WASI:
		case EMSCRIPTEN: return MUSL;
		default: return NONE;
	}
}

<* std.Target.ObjectFormat.default. *>
fn ObjectFormat default_object_format(OsTag os, Arch arch)
{
	if (os.is_darwin()) return MACHO;
	switch (os)
	{
		case PLAN9: return PLAN9;
		case UEFI:
		case WINDOWS: return COFF;
		default: break;
	}
	switch (arch)
	{
		case SPIRV32:
		case SPIRV64: return SPIRV;
		case WASM32:
		case WASM64: return WASM;
		default: return ELF;
	}
}

<* std.Target.ObjectFormat.fileExt (with Cpu.Arch.plan9Ext for PLAN9). *>
fn String ObjectFormat.file_ext(self, Arch arch)
{
	switch (self)
	{
		case C: return ".c";
		case COFF: return ".obj";
		case ELF:
		case GOFF:
		case MACHO:
		case WASM:
		case XCOFF: return ".o";
		case HEX: return ".ihex";
		case RAW: return ".bin";
		case SPIRV: return ".spv";
		case PLAN9:
			switch (arch)
			{
				case ARM: return ".5";
				case X86_64: return ".6";
				case AARCH64: return ".7";
				case X86: return ".8";
				case SPARC: return ".k";
				case POWERPC:
				case POWERPCLE: return ".q";
				case MIPS:
				case MIPSEL: return ".v";
				// ISAs without designated characters get 'X' for lack of a better option.
				default: return ".X";
			}
	}
}

// Os.WindowsVersion values (NTDDI version constants).
const uint WIN_NT4 = 0x04000000;
const uint WIN_WIN10 = 0x0A000000;
const uint WIN_LATEST = 0x0A000010; // the newest entry of WINDOWS_VERSIONS

struct WindowsVersionName
{
	String name;
	uint value;
}

const WindowsVersionName[*] WINDOWS_VERSIONS = {
	{ "nt4", 0x04000000 },
	{ "win2k", 0x05000000 },
	{ "xp", 0x05010000 },
	{ "ws2003", 0x05020000 },
	{ "vista", 0x06000000 },
	{ "win7", 0x06010000 },
	{ "win8", 0x06020000 },
	{ "win8_1", 0x06030000 },
	{ "win10", 0x0A000000 },
	{ "win10_th2", 0x0A000001 },
	{ "win10_rs1", 0x0A000002 },
	{ "win10_rs2", 0x0A000003 },
	{ "win10_rs3", 0x0A000004 },
	{ "win10_rs4", 0x0A000005 },
	{ "win10_rs5", 0x0A000006 },
	{ "win10_19h1", 0x0A000007 },
	{ "win10_vb", 0x0A000008 },
	{ "win10_mn", 0x0A000009 },
	{ "win10_fe", 0x0A00000A },
	{ "win10_co", 0x0A00000B },
	{ "win10_ni", 0x0A00000C },
	{ "win10_cu", 0x0A00000D },
	{ "win11_zn", 0x0A00000E },
	{ "win11_ga", 0x0A00000F },
	{ "win11_ge", 0x0A000010 },
};

<*
 Os.WindowsVersion.parse: a version name, or an integer (std.fmt.parseInt
 base 0: optional 0x/0o/0b prefix, '_' separators).
*>
fn uint? windows_version_parse(String str)
{
	foreach (v : WINDOWS_VERSIONS) if (v.name == str) return v.value;
	String digits = str;
	ulong base = 10;
	if (digits.len > 2 && digits[0] == '0')
	{
		switch (digits[1])
		{
			case 'x':
			case 'X': base = 16;
			case 'o':
			case 'O': base = 8;
			case 'b':
			case 'B': base = 2;
			default: break;
		}
		if (base != 10) digits = digits[2..];
	}
	if (digits.len == 0 || digits[0] == '_' || digits[^1] == '_') return INVALID_VERSION~;
	ulong v = 0;
	foreach (c : digits)
	{
		if (c == '_') continue;
		ulong d;
		switch
		{
			case c >= '0' && c <= '9': d = (ulong)(c - '0');
			case c >= 'a' && c <= 'z': d = (ulong)(c - 'a') + 10;
			case c >= 'A' && c <= 'Z': d = (ulong)(c - 'A') + 10;
			default: return INVALID_VERSION~;
		}
		if (d >= base) return INVALID_VERSION~;
		v = v * base + d;
		if (v > 0xFFFF_FFFF) return OVERFLOW~;
	}
	return (uint)v;
}

<*
 Os.Tag.defaultVersionRange: the OS with its default version range.
 Values from Zig std.Target knowledge, not verified by execution.
*>
fn Os default_os(OsTag tag, Arch arch)
{
	Os os = { .tag = tag };
	switch (tag)
	{
		case FREEBSD:
			os.min = { 14, 0, 0 };
			os.max = { 14, 3, 0 };
		case NETBSD:
			os.min = { 10, 1, 0 };
			os.max = { 10, 1, 0 };
		case OPENBSD:
			os.min = { 7, 6, 0 };
			os.max = { 7, 7, 0 };
		case DRAGONFLY:
			os.min = { 6, 0, 0 };
			os.max = { 6, 4, 2 };
		case FUCHSIA:
			os.min = { 1, 0, 0 };
			os.max = { 26, 0, 0 };
		case MACOS:
			os.min = { 13, 0, 0 };
			os.max = { 15, 6, 0 };
		case IOS:
		case MACCATALYST:
			os.min = { 15, 0, 0 };
			os.max = { 18, 6, 0 };
		case TVOS:
			os.min = { 15, 0, 0 };
			os.max = { 18, 5, 0 };
		case VISIONOS:
			os.min = { 1, 0, 0 };
			os.max = { 2, 5, 0 };
		case WATCHOS:
			os.min = { 8, 0, 0 };
			os.max = { 11, 6, 0 };
		case DRIVERKIT:
			os.min = { 20, 0, 0 };
			os.max = { 24, 6, 0 };
		case RTEMS:
			os.min = { 5, 1, 0 };
			os.max = { 5, 3, 0 };
		case WASI:
			os.min = { 0, 1, 0 };
			os.max = { 0, 3, 0 };
		case CUDA:
			os.min = { 11, 0, 1 };
			os.max = { 12, 9, 0 };
		case NVCL:
		case OPENCL:
			os.min = { 2, 2, 0 };
			os.max = { 3, 0, 0 };
		case OPENGL:
			os.min = { 4, 5, 0 };
			os.max = { 4, 6, 0 };
		case VULKAN:
			os.min = { 1, 2, 0 };
			os.max = { 1, 4, 0 };
		case AMDHSA:
			os.min = { 5, 0, 2 };
			os.max = { 6, 4, 0 };
		case HURD:
			os.min = { 0, 9, 0 };
			os.max = { 0, 9, 0 };
			os.glibc = { 2, 28, 0 };
		case LINUX:
			os.min = { 5, 10, 0 };
			os.max = { 6, 16, 0 };
			os.glibc = { 2, 31, 0 };
			os.android = 29;
		case WINDOWS:
			os.win_min = WIN_WIN10;
			os.win_max = WIN_LATEST;
		default:
			if (tag.range == SEMVER)
			{
				os.min = { 0, 0, 0 };
				os.max = { 0, 0, 0 };
			}
	}
	return os;
}

<*
 std.Target.DynamicLinker.standard; "" means none. Paths from Zig
 std.Target knowledge, not verified by execution (only the x86_64 glibc path
 is exercised by an existing fixture, src/aro/Toolchain/Linux.zig's test).
*>
fn String standard_dynamic_linker(Target* t)
{
	Arch arch = t.cpu.arch;
	Abi abi = t.abi;
	switch (t.os.tag)
	{
		case FUCHSIA: return "ld.so.1"; // Fuchsia is unusual in that `DT_INTERP` is just a basename.
		case HAIKU: return "/system/runtime_loader";
		case HURD:
			switch (arch)
			{
				case AARCH64:
				case AARCH64_BE: return "/lib/ld-aarch64.so.1";
				case X86: return "/lib/ld.so.1";
				case X86_64: return "/lib/ld-x86-64.so.1";
				default: return "";
			}
		case LINUX:
			if (abi.is_android()) return arch.ptr_bits == 64 ? "/system/bin/linker64" : "/system/bin/linker";
			if (abi.is_musl()) return musl_dynamic_linker(t);
			if (abi.is_gnu()) return glibc_dynamic_linker(t);
			return "";
		case SERENITY: return "/usr/lib/Loader.so";
		case DRAGONFLY: return "/libexec/ld-elf.so.2";
		case FREEBSD: return "/libexec/ld-elf.so.1";
		case NETBSD: return "/libexec/ld.elf_so";
		case OPENBSD: return "/usr/libexec/ld.so";
		case ILLUMOS: return arch.ptr_bits == 64 ? "/lib/64/ld.so.1" : "/lib/ld.so.1";
		case DRIVERKIT:
		case IOS:
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case VISIONOS:
		case WATCHOS: return "/usr/lib/dyld";
		default: return "";
	}
}

fn String musl_dynamic_linker(Target* t) @local
{
	bool hard = t.abi.float_abi() == HARD;
	switch (t.cpu.arch)
	{
		case ARM:
		case THUMB: return hard ? "/lib/ld-musl-armhf.so.1" : "/lib/ld-musl-arm.so.1";
		case ARMEB:
		case THUMBEB: return hard ? "/lib/ld-musl-armebhf.so.1" : "/lib/ld-musl-armeb.so.1";
		case AARCH64: return "/lib/ld-musl-aarch64.so.1";
		case AARCH64_BE: return "/lib/ld-musl-aarch64_be.so.1";
		case HEXAGON: return "/lib/ld-musl-hexagon.so.1";
		case LOONGARCH64: return "/lib/ld-musl-loongarch64.so.1";
		case M68K: return "/lib/ld-musl-m68k.so.1";
		case MIPS: return hard ? "/lib/ld-musl-mips.so.1" : "/lib/ld-musl-mips-sf.so.1";
		case MIPSEL: return hard ? "/lib/ld-musl-mipsel.so.1" : "/lib/ld-musl-mipsel-sf.so.1";
		case MIPS64:
			return t.abi == MUSLABIN32 ? "/lib/ld-musl-mipsn32.so.1" : "/lib/ld-musl-mips64.so.1";
		case MIPS64EL:
			return t.abi == MUSLABIN32 ? "/lib/ld-musl-mipsn32el.so.1" : "/lib/ld-musl-mips64el.so.1";
		case POWERPC: return hard ? "/lib/ld-musl-powerpc.so.1" : "/lib/ld-musl-powerpc-sf.so.1";
		case POWERPCLE: return hard ? "/lib/ld-musl-powerpcle.so.1" : "/lib/ld-musl-powerpcle-sf.so.1";
		case POWERPC64: return "/lib/ld-musl-powerpc64.so.1";
		case POWERPC64LE: return "/lib/ld-musl-powerpc64le.so.1";
		case RISCV32: return "/lib/ld-musl-riscv32.so.1";
		case RISCV64: return "/lib/ld-musl-riscv64.so.1";
		case S390X: return "/lib/ld-musl-s390x.so.1";
		case X86: return "/lib/ld-musl-i386.so.1";
		case X86_64: return t.abi == MUSLX32 ? "/lib/ld-musl-x32.so.1" : "/lib/ld-musl-x86_64.so.1";
		default: return "";
	}
}

fn String glibc_dynamic_linker(Target* t) @local
{
	Abi abi = t.abi;
	switch (t.cpu.arch)
	{
		case AARCH64: return "/lib/ld-linux-aarch64.so.1";
		case AARCH64_BE: return "/lib/ld-linux-aarch64_be.so.1";
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return abi.float_abi() == HARD ? "/lib/ld-linux-armhf.so.3" : "/lib/ld-linux.so.3";
		case CSKY: return abi.float_abi() == HARD ? "/lib/ld-linux-cskyv2-hf.so.1" : "/lib/ld-linux-cskyv2.so.1";
		case LOONGARCH64:
			switch (abi)
			{
				case GNUF32: return "/lib64/ld-linux-loongarch-lp64f.so.1";
				case GNUSF: return "/lib64/ld-linux-loongarch-lp64s.so.1";
				default: return "/lib64/ld-linux-loongarch-lp64d.so.1";
			}
		case M68K: return "/lib/ld.so.1";
		case MIPS:
		case MIPSEL:
			return t.cpu.has(MIPS_NAN2008) ? "/lib/ld-linux-mipsn8.so.1" : "/lib/ld.so.1";
		case MIPS64:
		case MIPS64EL:
			if (abi == GNUABIN32) return t.cpu.has(MIPS_NAN2008) ? "/lib32/ld-linux-mipsn8.so.1" : "/lib32/ld.so.1";
			return t.cpu.has(MIPS_NAN2008) ? "/lib64/ld-linux-mipsn8.so.1" : "/lib64/ld.so.1";
		case POWERPC: return "/lib/ld.so.1";
		case POWERPC64:
		case POWERPC64LE: return "/lib64/ld64.so.2";
		case RISCV32:
			return t.cpu.has(RISCV_D) ? "/lib/ld-linux-riscv32-ilp32d.so.1" : t.cpu.has(RISCV_F) ? "/lib/ld-linux-riscv32-ilp32f.so.1" : "/lib/ld-linux-riscv32-ilp32.so.1";
		case RISCV64:
			return t.cpu.has(RISCV_D) ? "/lib/ld-linux-riscv64-lp64d.so.1" : t.cpu.has(RISCV_F) ? "/lib/ld-linux-riscv64-lp64f.so.1" : "/lib/ld-linux-riscv64-lp64.so.1";
		case S390X: return "/lib/ld64.so.1";
		case SPARC: return "/lib/ld-linux.so.2";
		case SPARC64: return "/lib64/ld-linux.so.2";
		case X86: return "/lib/ld-linux.so.2";
		case X86_64: return abi == GNUX32 ? "/libx32/ld-linux-x32.so.2" : "/lib64/ld-linux-x86-64.so.2";
		default: return "";
	}
}
