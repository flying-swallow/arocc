// Tests for predefined_macros_other.c3 (plan 14.2 `sysdefs-b`): the
// non-x86 / non-Windows / non-Darwin sections of generateSystemDefines.
//
// PROVENANCE
// - [fixture] lines restate the #if/#ifdef checks of the named
//   test/cases/*.c file for the same target (riscv * predefined macros.c,
//   arm-acle-6.4 *.c, arm-pic-predefines ropi rwpi.c, msp430 builtin types.c).
// - Every full-text golden is source-derived: hand-traced through
//   src/aro/Compilation.zig generateSystemDefines / riscvFloatAbi with the
//   target_cpu.c3 feature data (itself source-derived). No Zig executable
//   was run.
module predefined_macros_other_tests;
import aro::predefined_macros, aro::compilation, aro::target, aro::type_store, aro::code_gen_options, aro::lang_opts;
import std::core::mem::allocators, std::io;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

fn Target tgt(String triple, String cpu)
{
	Target? t = target::parse_triple(triple, HOST, cpu);
	if (catch f = t)
	{
		io::eprintfn("failed to parse target '%s' cpu '%s': %s", triple, cpu, f);
		unreachable("target parse failed");
	}
	return t;
}

alias SectionFn = fn void (Compilation*, MacroWriter*, bool is_gnu);

<* Compilation knobs the sections read. Zero value = Zig defaults (pic NONE, cmodel DEFAULT). *>
struct Opts
{
	bool is_gnu;
	bool pthread;
	PicLevel pic;
	bool ropi;
	bool rwpi;
	bool short_enums;
	CodeModel cmodel;
	bool set_os;
	OsTag os;
}

<*
 Run `section` for a compilation targeting `triple` (and -mcpu `cpu`) the
 way generate_builtin_macros would (set_target_options, init_named_types)
 and return its output in the temp allocator. Checks nothing leaks.
*>
fn String emit(String triple, String cpu, SectionFn section, Opts o = {})
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	String result;
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = tgt(triple, cpu);
		if (o.set_os) comp.target.os.tag = o.os;
		comp.langopts.set_target_options(&comp.target);
		comp.langopts.pthread = o.pthread;
		comp.langopts.short_enums = o.short_enums;
		comp.code_gen_options.pic_level = o.pic;
		comp.code_gen_options.is_ropi = o.ropi;
		comp.code_gen_options.is_rwpi = o.rwpi;
		comp.cmodel = o.cmodel;
		type_store::init_named_types(&comp);
		MacroWriter w;
		w.init(&ta);
		section(&comp, &w, o.is_gnu);
		result = w.written().tcopy();
		w.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	return result;
}

fn void sec_riscv(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_riscv_defines(c, w);
fn void sec_other_os(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_other_os_defines(c, w, g);
fn void sec_unix(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_unix_defines(c, w, g);
fn void sec_pthread(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_pthread_defines(c, w);
fn void sec_mips(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_mips_defines(c, w, g);
fn void sec_ppc(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_powerpc_defines(c, w);
fn void sec_sparc(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_sparc_defines(c, w, g);
fn void sec_msp430_arc(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_msp430_arc_defines(c, w);
fn void sec_wasm(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_wasm_defines(c, w);
fn void sec_s390x(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_s390x_defines(c, w);
fn void sec_arm(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_arm_defines(c, w);
fn void sec_a64(Compilation* c, MacroWriter* w, bool g) => predefined_macros::write_aarch64_defines(c, w);

<* `out` contains the full line `line` (without the newline). *>
fn bool has_line(String out, String line)
{
	foreach (l : out.tsplit("\n")) if (l == line) return true;
	return false;
}

<* `out` defines `name` (any value). *>
fn bool defines(String out, String name)
{
	foreach (l : out.tsplit("\n"))
	{
		if (!l.starts_with("#define ")) continue;
		String rest = l[8..];
		if (rest.starts_with(name) && (rest.len == name.len || rest[name.len] == ' ' || rest[name.len] == '(')) return true;
	}
	return false;
}

fn void expect_lines(String out, String[] lines)
{
	foreach (l : lines)
	{
		if (!has_line(out, l))
		{
			io::eprintfn("missing line '%s' in:\n%s", l, out);
			test::eq(true, false);
		}
	}
}

fn void expect_undefined(String out, String[] names)
{
	foreach (n : names)
	{
		if (defines(out, n))
		{
			io::eprintfn("unexpected '%s' in:\n%s", n, out);
			test::eq(true, false);
		}
	}
}

// ---------------------------------------------------------------------------
// RISC-V

fn String riscv(String triple, String cpu) => emit(triple, cpu, &sec_riscv);

fn void riscv_float_abi_selection() @test
{
	Target t = tgt("riscv64-linux-gnu", "baseline");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.DOUBLE);
	t = tgt("riscv64-linux-gnusf", "baseline");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SOFT);
	t = tgt("riscv64-linux-muslsf", "baseline");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SOFT);
	t = tgt("riscv64-linux-gnuf32", "baseline");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SINGLE);
	t = tgt("riscv32-linux-muslf32", "baseline");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SINGLE);
	t = tgt("riscv64-linux-gnu", "generic_rv64");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SOFT);
	t = tgt("riscv64-linux-gnu", "generic_rv64+f");
	test::eq(predefined_macros::riscv_float_abi(&t), RiscvFloatAbi.SINGLE);
}

fn void riscv_defines() @test
{
	// [fixture] riscv hard-float predefined macros.c; full text source-derived.
	test::eq(riscv("riscv64-linux-gnu", "baseline"),
		"#define __riscv 1\n#define __riscv_xlen 64\n#define __riscv_f 2002000\n#define __riscv_d 2002000\n"
		"#define __riscv_flen 64\n#define __riscv_float_abi_double 1\n");
	// [fixture] riscv soft-float predefined macros.c (flen still 64: the d feature stays on).
	test::eq(riscv("riscv64-linux-gnusf", "baseline"),
		"#define __riscv 1\n#define __riscv_xlen 64\n#define __riscv_f 2002000\n#define __riscv_d 2002000\n"
		"#define __riscv_flen 64\n#define __riscv_float_abi_soft 1\n");
	// [fixture] riscv single-float predefined macros.c
	test::eq(riscv("riscv64-linux-gnuf32", "baseline"),
		"#define __riscv 1\n#define __riscv_xlen 64\n#define __riscv_f 2002000\n#define __riscv_d 2002000\n"
		"#define __riscv_flen 64\n#define __riscv_float_abi_single 1\n");
	// [fixture] riscv no-float predefined macros.c uses -mcpu=rv64i (a Driver
	// spelling); generic_rv64 is the same feature set (64bit + i).
	test::eq(riscv("riscv64-linux-gnu", "generic_rv64"),
		"#define __riscv 1\n#define __riscv_xlen 64\n#define __riscv_float_abi_soft 1\n");
	test::eq(riscv("riscv32-linux-gnu", "generic_rv32+f"),
		"#define __riscv 1\n#define __riscv_xlen 32\n#define __riscv_f 2002000\n#define __riscv_flen 32\n#define __riscv_float_abi_single 1\n");
	test::eq(riscv("riscv64-linux-gnu", "generic_rv64+q"),
		"#define __riscv 1\n#define __riscv_xlen 64\n#define __riscv_f 2002000\n#define __riscv_d 2002000\n"
		"#define __riscv_q 2002000\n#define __riscv_flen 128\n#define __riscv_float_abi_double 1\n");
}

// ---------------------------------------------------------------------------
// OS sections

fn String other_os(String triple, bool is_gnu) => emit(triple, "", &sec_other_os, { .is_gnu = is_gnu });

fn String other_os_tag(OsTag tag) => emit("x86_64-linux-none", "", &sec_other_os, { .set_os = true, .os = tag });

fn String unix(String triple, bool is_gnu) => emit(triple, "", &sec_unix, { .is_gnu = is_gnu });

fn String pthread(String triple, bool on) => emit(triple, "", &sec_pthread, { .pthread = on });

fn void other_os_defines() @test
{
	test::eq(other_os("x86_64-linux-gnu", true), "#define linux 1\n#define __linux 1\n#define __linux__ 1\n");
	test::eq(other_os("x86_64-linux-gnu", false), "#define __linux 1\n#define __linux__ 1\n");
	test::eq(other_os("x86_64-freebsd.13.2-none", false), "#define __FreeBSD__ 13\n#define __FreeBSD_cc_version 130001\n");
	test::eq(other_os("x86_64-ps4-none", false), "#define __FreeBSD__ 9\n#define __FreeBSD_cc_version 900001\n");
	test::eq(other_os("x86_64-ps5-none", false), "#define __FreeBSD__ 9\n#define __FreeBSD_cc_version 900001\n");
	test::eq(other_os("x86_64-illumos-none", true), "#define sun 1\n#define __sun 1\n#define __sun__ 1\n#define __illumos__ 1\n");
	test::eq(other_os("wasm32-wasi-musl", false), "#define __wasi__ 1\n");
	test::eq(other_os("wasm32-emscripten-musl", false), "#define __EMSCRIPTEN__ 1\n");
	// Windows and Darwin are not this function's (generate_system_defines routes them elsewhere);
	// freestanding and other unlisted OSes define nothing.
	test::eq(other_os("x86_64-freestanding-none", true), "");
	test::eq(other_os("x86_64-haiku-none", true), "");

	test::eq(other_os_tag(UEFI), "#define __UEFI__ 1\n");
	test::eq(other_os_tag(NETBSD), "#define __NetBSD__ 1\n");
	test::eq(other_os_tag(OPENBSD), "#define __OpenBSD__ 1\n");
	test::eq(other_os_tag(DRAGONFLY), "#define __DragonFly__ 1\n");
	test::eq(other_os_tag(SERENITY), "#define __serenity__ 1\n");
	test::eq(other_os_tag(SWITCH), "#define __SWITCH__ 1\n");
	test::eq(other_os_tag(THREEDS), "#define __3DS__ 1\n");
	test::eq(other_os_tag(GBA), "#define __GBA__ 1\n");
	test::eq(other_os_tag(PSP), "#define __PSP__ 1\n");
	test::eq(other_os_tag(PSX), "#define __psx__ 1\n");
	test::eq(other_os_tag(VITA), "#define __vita__ 1\n");
	test::eq(other_os_tag(WIIU), "#define __WIIU__ 1\n");
	test::eq(other_os_tag(FUCHSIA), "");
	test::eq(other_os_tag(HURD), "");
}

fn void unix_and_android_defines() @test
{
	test::eq(unix("x86_64-linux-gnu", true), "#define unix 1\n#define __unix 1\n#define __unix__ 1\n");
	test::eq(unix("x86_64-linux-gnu", false), "#define __unix 1\n#define __unix__ 1\n");
	test::eq(unix("aarch64-linux-android", false), "#define __unix 1\n#define __unix__ 1\n#define __ANDROID__ 1\n");
	test::eq(unix("arm-linux-androideabi", false), "#define __unix 1\n#define __unix__ 1\n#define __ANDROID__ 1\n");
	test::eq(unix("x86_64-haiku-none", false), "#define __unix 1\n#define __unix__ 1\n");
	test::eq(unix("x86_64-ps5-none", false), "#define __unix 1\n#define __unix__ 1\n");
	test::eq(unix("wasm32-emscripten-musl", false), "#define __unix 1\n#define __unix__ 1\n");
	test::eq(unix("x86_64-windows-msvc", true), "");
	test::eq(unix("wasm32-wasi-musl", true), "");
	test::eq(unix("x86_64-fuchsia-none", true), "");
	test::eq(unix("x86_64-macos-none", true), "");
}

fn void pthread_defines() @test
{
	test::eq(pthread("x86_64-linux-gnu", false), "");
	test::eq(pthread("x86_64-linux-gnu", true), "#define _REENTRANT 1\n");
	test::eq(pthread("aarch64-macos-none", true), "#define _REENTRANT 1\n");
	test::eq(pthread("x86_64-fuchsia-none", true), "#define _REENTRANT 1\n");
	test::eq(pthread("x86_64-windows-msvc", true), "#define _MT 1\n");
	test::eq(pthread("x86_64-windows-gnu", true), "");
	test::eq(pthread("wasm32-emscripten-musl", true), "#define __EMSCRIPTEN_PTHREADS__ 1\n");
	test::eq(pthread("x86_64-freebsd-none", true), "");
	test::eq(pthread("wasm32-wasi-musl", true), "");
}

// ---------------------------------------------------------------------------
// MIPS / PowerPC / SPARC / msp430 / arc / wasm / s390x

fn String mips(String triple, String cpu, bool is_gnu, PicLevel pic) => emit(triple, cpu, &sec_mips, { .is_gnu = is_gnu, .pic = pic });

fn void mips_defines() @test
{
	test::eq(mips("mipsel-linux-gnu", "mips32r2", true, NONE),
		"#define __mips__ 1\n#define _mips 1\n#define mips 1\n"
		"#define _MIPSEL 1\n#define MIPSEL 1\n#define __MIPSEL 1\n#define __MIPSEL__ 1\n"
		"#define __mips_o32 1\n#define _ABIO32 1\n#define _MIPS_SIM _ABIO32\n#define __mips 32\n#define _MIPS_ISA _MIPS_ISA_MIPS32\n"
		"#define _MIPS_ARCH \"mips32r2\"\n#define _MIPS_ARCH_MIPS32R2 1\n"
		"#define __mips_fpr 0\n#define _MIPS_FPSET 16\n#define _MIPS_SPFPSET 16\n"
		"#define _MIPS_SZPTR 32\n#define _MIPS_SZINT 32\n#define _MIPS_SZLONG 32\n#define __mips_isa_rev 2\n");
	test::eq(mips("mips64-linux-gnuabi64", "mips64r6", false, TWO),
		"#define __mips__ 1\n#define _mips 1\n"
		"#define _MIPSEB 1\n#define __MIPSEB 1\n#define __MIPSEB__ 1\n"
		"#define __mips_n64 1\n#define _ABI64 3\n#define _MIPS_SIM _ABI64\n#define __mips 64\n#define __mips64 1\n#define __mips64__ 1\n"
		"#define _MIPS_ISA _MIPS_ISA_MIPS64\n"
		"#define _MIPS_ARCH \"mips64r6\"\n#define _MIPS_ARCH_MIPS64R6 1\n"
		"#define __mips_abicalls 1\n"
		"#define __mips_fpr 64\n#define _MIPS_FPSET 32\n#define _MIPS_SPFPSET 32\n"
		"#define __mips_nan2008 1\n#define __mips_abs2008 1\n"
		"#define _MIPS_SZPTR 64\n#define _MIPS_SZINT 32\n#define _MIPS_SZLONG 64\n#define __mips_isa_rev 6\n");
	String n32 = mips("mips64el-linux-gnuabin32", "mips64r2+dspr2+msa+nomadd4+fpu_s", false, ONE);
	expect_lines(n32, {
		"#define __mips_n32 1", "#define _ABIN32 2", "#define _MIPS_SIM _ABIN32", "#define __mips 64",
		"#define __mips_single_float 1", "#define __mips_fpr 64", "#define _MIPS_FPSET 32",
		"#define __mips_dsp_rev 2", "#define __mips_dsp 2", "#define __mips_dspr2 1",
		"#define __mips_msa 1", "#define __mips_no_madd4 1", "#define _MIPS_SZPTR 32", "#define _MIPS_SZLONG 32",
		"#define __mips_abicalls 1", "#define _MIPSEL 1" });
	expect_undefined(n32, { "__ABICALLS__", "__mips_dspr3", "mips" });
	// BSD + PIC adds __ABICALLS__; dspr3 wins over dspr2/dsp.
	String bsd = mips("mips-netbsd-none", "mips32+dspr3", false, ONE);
	expect_lines(bsd, { "#define __mips_abicalls 1", "#define __ABICALLS__ 1", "#define __mips_dsp_rev 3",
		"#define __mips_dsp 3", "#define __mips_dspr3 1", "#define __mips_isa_rev 1", "#define _MIPS_ARCH_MIPS32 1" });
}

fn String ppc(String triple) => emit(triple, "", &sec_ppc);

fn void powerpc_defines() @test
{
	test::eq(ppc("powerpc-linux-gnu"),
		"#define __powerpc__ 1\n#define __POWERPC__ 1\n#define __ppc__ 1\n#define __PPC__ 1\n#define _ARCH_PPC 1\n#define _CALL_ELF 1\n");
	String ppc64 = "#define __powerpc 1\n#define __powerpc__ 1\n#define __powerpc64__ 1\n#define __POWERPC__ 1\n"
		"#define __ppc__ 1\n#define __ppc64__ 1\n#define __PPC__ 1\n#define __PPC64__ 1\n#define _ARCH_PPC 1\n#define _ARCH_PPC64 1\n";
	test::eq(ppc("powerpc64le-linux-gnu"), ppc64.tconcat("#define _CALL_ELF 2\n"));
	test::eq(ppc("powerpc64-linux-gnu"), ppc64.tconcat("#define _CALL_ELF 1\n"));
	test::eq(ppc("powerpc64-linux-musl"), ppc64.tconcat("#define _CALL_ELF 2\n"));
}

fn String sparc(String triple, bool is_gnu) => emit(triple, "", &sec_sparc, { .is_gnu = is_gnu });

fn void sparc_defines() @test
{
	test::eq(sparc("sparc64-linux-gnu", true),
		"#define sparc 1\n#define __sparc 1\n#define __sparc__ 1\n#define __sparc_v9__ 1\n#define __arch64__ 1\n"
		"#define __sparc64__ 1\n#define __sparc_v9__ 1\n#define __sparcv9__ 1\n");
	test::eq(sparc("sparc64-illumos-none", false),
		"#define __sparc 1\n#define __sparc__ 1\n#define __sparc_v9__ 1\n#define __arch64__ 1\n");
	test::eq(sparc("sparc-linux-gnu", false), "#define __sparc 1\n#define __sparc__ 1\n");
	test::eq(sparc("sparc-illumos-none", false), "#define __sparc 1\n#define __sparc__ 1\n#define __sparcv8 1\n");
}


fn void msp430_arc_wasm_s390x_defines() @test
{
	// [fixture] msp430 builtin types.c checks MSP430 and __MSP430__.
	test::eq(emit("msp430-freestanding-none", "", &sec_msp430_arc), "#define MSP430 1\n#define __MSP430__ 1\n");
	test::eq(emit("arc-linux-gnu", "", &sec_msp430_arc), "#define __arc__ 1\n");

	test::eq(emit("wasm32-wasi-musl", "generic", &sec_wasm),
		"#define __wasm 1\n#define __wasm__ 1\n#define __wasm32 1\n#define __wasm32__ 1\n"
		"#define __wasm_bulk_memory__ 1\n#define __wasm_bulk_memory_opt__ 1\n#define __wasm_call_indirect_overlong__ 1\n"
		"#define __wasm_multivalue__ 1\n#define __wasm_mutable_globals__ 1\n#define __wasm_nontrapping_fptoint__ 1\n"
		"#define __wasm_reference_types__ 1\n#define __wasm_sign_ext__ 1\n");
	test::eq(emit("wasm64-freestanding-none", "mvp", &sec_wasm),
		"#define __wasm 1\n#define __wasm__ 1\n#define __wasm64 1\n#define __wasm64__ 1\n");
	test::eq(emit("wasm32-freestanding-none", "mvp+simd128+atomics+wide_arithmetic", &sec_wasm),
		"#define __wasm 1\n#define __wasm__ 1\n#define __wasm32 1\n#define __wasm32__ 1\n"
		"#define __wasm_atomics__ 1\n#define __wasm_simd128__ 1\n#define __wasm_wide_arithmetic__ 1\n");

	test::eq(emit("s390x-linux-gnu", "arch8", &sec_s390x),
		"#define __s390__ 1\n#define __s390x__ 1\n#define __zarch__ 1\n");
	test::eq(emit("s390x-linux-gnu", "arch8+vector+transactional_execution", &sec_s390x),
		"#define __s390__ 1\n#define __s390x__ 1\n#define __zarch__ 1\n#define __HTM__ 1\n#define __VX__ 1\n");
}

// ---------------------------------------------------------------------------
// ARM (32-bit)

fn String arm(String triple, String cpu, Opts o = {}) => emit(triple, cpu, &sec_arm, o);

const String ARM_PREFIX = "#define __arm__ 1\n#define __arm 1\n#define __ARM_32BIT_STATE 1\n#define __APCS_32__ 1\n#define __VFP_FP__ 1\n"
	"#define __ARM_FP16_ARGS 1\n#define __ARM_FP16_FORMAT_IEEE 1\n#define __ARM_ACLE 200\n";

fn void arm_v7a_soft_float() @test
{
	// gnueabi is a soft-float ABI (Abi.float), so no FP macros and __SOFTFP__.
	test::eq(arm("armv7a-linux-gnueabi", ""), ARM_PREFIX.tconcat(
		"#define __ARM_ARCH_ISA_THUMB 2\n#define __thumb__ 1\n#define __ARM_ARCH_ISA_ARM 1\n"
		"#define __ARM_ARCH_7A__ 1\n#define __ARM_ARCH 7\n#define __ARM_ARCH_PROFILE 'A'\n"
		"#define __ARM_FEATURE_CLZ 1\n#define __ARM_FEATURE_DSP 1\n#define __ARM_FEATURE_SAT 1\n"
		"#define __ARM_FEATURE_QBIT 1\n#define __ARM_FEATURE_SIMD32 1\n#define __SOFTFP__ 1\n"
		"#define __ARM_FEATURE_COPROC 0xf\n#define __THUMB_INTERWORK__ 1\n#define __ARM_FEATURE_LDREX 0xf\n"
		"#define __ARM_FEATURE_UNALIGNED 1\n#define __ARMEL__ 1\n"
		"#define __ARM_SIZEOF_MINIMAL_ENUM 4\n#define __ARM_SIZEOF_WCHAR_T 4\n"));
}

fn void arm_v7a_hard_float() @test
{
	// v7a implies neon -> vfp3 -> vfp2/vfp3d16/vfp3sp/fp64: HwFp sp|dp = 0xc,
	// Neon FP drops dp = 0x4.
	test::eq(arm("armv7a-linux-gnueabihf", ""), ARM_PREFIX.tconcat(
		"#define __ARM_ARCH_ISA_THUMB 2\n#define __thumb__ 1\n#define __ARM_ARCH_ISA_ARM 1\n"
		"#define __ARM_ARCH_7A__ 1\n#define __ARM_ARCH 7\n#define __ARM_ARCH_PROFILE 'A'\n"
		"#define __ARM_FEATURE_CLZ 1\n#define __ARM_FEATURE_DSP 1\n#define __ARM_FEATURE_SAT 1\n"
		"#define __ARM_FEATURE_QBIT 1\n#define __ARM_FEATURE_SIMD32 1\n"
		"#define __ARM_FP 0xc\n#define __ARM_VFPV2__ 1\n#define __ARM_VFPV3__ 1\n"
		"#define __ARM_NEON 1\n#define __ARM_NEON__ 1\n#define __ARM_NEON_FP 0x4\n#define __ARM_PCS_VFP 1\n"
		"#define __ARM_FEATURE_COPROC 0xf\n#define __THUMB_INTERWORK__ 1\n#define __ARM_FEATURE_LDREX 0xf\n"
		"#define __ARM_FEATURE_UNALIGNED 1\n#define __ARMEL__ 1\n"
		"#define __ARM_SIZEOF_MINIMAL_ENUM 4\n#define __ARM_SIZEOF_WCHAR_T 4\n"));
}

fn void arm_acle_fixtures() @test
{
	// [fixture] arm-acle-6.4 arm-eabi.c
	String base = arm("arm-linux-gnueabi", "");
	expect_lines(base, { "#define __ARM_32BIT_STATE 1", "#define __ARM_ACLE 200" });
	expect_undefined(base, { "__ARM_64BIT_STATE", "__ARM_ARCH_ISA_A64", "__ARM_BIG_ENDIAN" });

	// [fixture] arm-acle-6.4 armv7-m.c
	String v7m = arm("armv7m-linux-gnueabi", "");
	expect_lines(v7m, { "#define __ARM_ARCH 7", "#define __ARM_ARCH_ISA_THUMB 2", "#define __ARM_ARCH_PROFILE 'M'",
		"#define __ARM_FEATURE_CLZ 1", "#define __ARM_FEATURE_IDIV 1", "#define __ARM_FEATURE_LDREX 0x7",
		"#define __ARM_FEATURE_QBIT 1", "#define __ARM_FEATURE_SAT 1", "#define __ARM_FEATURE_UNALIGNED 1" });
	expect_undefined(v7m, { "__ARM_ARCH_ISA_ARM", "__ARM_FEATURE_SIMD32" });
	// source-derived for v7m: Thumb-only, no DSP.
	expect_lines(v7m, { "#define __thumb__ 1", "#define __ARM_ARCH_7M__ 1", "#define __ARM_ARCH_EXT_IDIV__ 1",
		"#define __ARM_FEATURE_COPROC 0xf", "#define __SOFTFP__ 1" });
	expect_undefined(v7m, { "__ARM_FEATURE_DSP" });

	// [fixture] arm-acle-6.4 armv7-a.c
	String v7a = arm("armv7a-linux-gnueabi", "");
	expect_lines(v7a, { "#define __ARM_ARCH 7", "#define __ARM_ARCH_ISA_ARM 1", "#define __ARM_ARCH_ISA_THUMB 2",
		"#define __ARM_ARCH_PROFILE 'A'", "#define __ARM_FEATURE_CLZ 1", "#define __ARM_FEATURE_DSP 1",
		"#define __ARM_FEATURE_LDREX 0xf", "#define __ARM_FEATURE_QBIT 1", "#define __ARM_FEATURE_SAT 1",
		"#define __ARM_FEATURE_SIMD32 1", "#define __ARM_FEATURE_UNALIGNED 1" });

	// [fixture] arm-acle-6.4 armv8-a.c
	String v8a = arm("armv8a-linux-gnueabi", "");
	expect_lines(v8a, { "#define __ARM_ARCH 8", "#define __ARM_ARCH_ISA_ARM 1", "#define __ARM_ARCH_ISA_THUMB 2",
		"#define __ARM_ARCH_PROFILE 'A'", "#define __ARM_FEATURE_CLZ 1", "#define __ARM_FEATURE_DSP 1",
		"#define __ARM_FEATURE_IDIV 1", "#define __ARM_FEATURE_LDREX 0xf", "#define __ARM_FEATURE_QBIT 1",
		"#define __ARM_FEATURE_SAT 1", "#define __ARM_FEATURE_SIMD32 1", "#define __ARM_FEATURE_UNALIGNED 1" });
	// source-derived: v8 coproc is b1|b3, still interworking.
	expect_lines(v8a, { "#define __ARM_ARCH_8A__ 1", "#define __ARM_FEATURE_COPROC 0x5", "#define __THUMB_INTERWORK__ 1" });
}

fn void arm_options_and_variants() @test
{
	// [fixture] arm-pic-predefines ropi rwpi.c
	String pic = arm("arm-linux-gnueabi", "", { .ropi = true, .rwpi = true });
	expect_lines(pic, { "#define __ARM_ROPI 1", "#define __ARM_RWPI 1" });
	expect_undefined(arm("arm-linux-gnueabi", ""), { "__ARM_ROPI", "__ARM_RWPI" });

	// -fshort-enums
	String se = arm("arm-linux-gnueabi", "", { .short_enums = true });
	expect_lines(se, { "#define __ARM_SIZEOF_MINIMAL_ENUM 1" });

	// Big endian.
	String eb = arm("armebv7a-linux-gnueabi", "");
	expect_lines(eb, { "#define __ARMEB__ 1", "#define __ARM_BIG_ENDIAN 1" });
	expect_undefined(eb, { "__ARMEL__" });

	// Thumb arch: __thumb__ and IDIV via hwdiv (v7a has no hwdiv -> none).
	String th = arm("thumbv7em-freestanding-eabihf", "");
	expect_lines(th, { "#define __thumb__ 1", "#define __ARM_ARCH_7EM__ 1", "#define __ARM_ARCH_PROFILE 'M'",
		"#define __ARM_FEATURE_DSP 1", "#define __ARM_FEATURE_SIMD32 1", "#define __ARM_FEATURE_IDIV 1", "#define __ARMEL__ 1" });

	// Windows: no interworking, wchar_t is 2 bytes.
	String win = arm("thumbv7a-windows-msvc", "");
	expect_undefined(win, { "__THUMB_INTERWORK__", "__SOFTFP__" });
	expect_lines(win, { "#define __ARM_SIZEOF_WCHAR_T 2", "#define __ARM_PCS_VFP 1" });

	// cortex-m4 (v7em + vfp4d16sp), hard float: HwFp hp|sp = 0x6, FMA, VFPV4 (and VFPV3 via vfp3d16sp).
	String m4 = arm("thumbv7em-freestanding-eabihf", "cortex_m4");
	expect_lines(m4, { "#define __ARM_FP 0x6", "#define __ARM_FEATURE_FMA 1", "#define __ARM_VFPV2__ 1",
		"#define __ARM_VFPV3__ 1", "#define __ARM_VFPV4__ 1", "#define __ARM_PCS_VFP 1" });
	expect_undefined(m4, { "__ARM_NEON", "__ARM_FPV5__", "__SOFTFP__" });

	// v6-M: thumb ISA 1, no CLZ/SAT/QBIT/SIMD32, coproc 0, LDREX none.
	String m0 = arm("thumbv6m-freestanding-eabi", "");
	expect_lines(m0, { "#define __ARM_ARCH_ISA_THUMB 1", "#define __ARM_ARCH_6M__ 1", "#define __ARM_ARCH 6",
		"#define __ARM_FEATURE_COPROC 0x0", "#define __ARM_FEATURE_LDREX 0x0" });
	expect_undefined(m0, { "__ARM_FEATURE_CLZ", "__ARM_FEATURE_SAT", "__ARM_FEATURE_QBIT", "__ARM_FEATURE_SIMD32",
		"__ARM_FEATURE_DSP", "__ARM_ARCH_ISA_ARM" });

	// v4t (arm7tdmi): ISA_THUMB 1 by the 'T', coproc b1, ldrex none, no __ARM_ARCH_PROFILE.
	String v4t = arm("armv4t-linux-gnueabi", "");
	expect_lines(v4t, { "#define __ARM_ARCH_ISA_THUMB 1", "#define __ARM_ARCH_4T__ 1", "#define __ARM_ARCH 4",
		"#define __ARM_FEATURE_COPROC 0x1", "#define __ARM_FEATURE_LDREX 0x0" });
	expect_undefined(v4t, { "__ARM_ARCH_PROFILE", "__ARM_FEATURE_CLZ", "__THUMB_INTERWORK__", "__thumb__" });

	// v5te: CLZ, DSP (5TE), coproc b1|b2|b3.
	String v5 = arm("armv5te-linux-gnueabi", "");
	expect_lines(v5, { "#define __ARM_FEATURE_CLZ 1", "#define __ARM_FEATURE_DSP 1", "#define __ARM_FEATURE_QBIT 1",
		"#define __ARM_FEATURE_COPROC 0x7", "#define __THUMB_INTERWORK__ 1" });
}

// ---------------------------------------------------------------------------
// AArch64

fn String a64(String triple, String cpu, Opts o = {}) => emit(triple, cpu, &sec_a64, o);

const String A64_PREFIX = "#define __aarch64__ 1\n#define __ARM_64BIT_STATE 1\n#define __ARM_ARCH_ISA_A64 1\n"
	"#define __ARM_FEATURE_CLZ 1\n#define __ARM_FEATURE_FMA 1\n#define __ARM_FEATURE_LDREX 0xf\n"
	"#define __ARM_FEATURE_IDIV 1\n#define __ARM_FEATURE_DIV 1\n#define __ARM_STATE_ZA 1\n#define __ARM_STATE_ZT0 1\n"
	"#define __ARM_ALIGN_MAX_STACK_PWR 4\n#define __ARM_FEATURE_NUMERIC_MAXMIN 1\n#define __ARM_FEATURE_DIRECTED_ROUNDING 1\n"
	"#define __ARM_ACLE_VERSION(year,quarter,patch) (100 * (year) + 10 * (quarter) + (patch))\n#define __ARM_ACLE 202420\n";

fn void aarch64_generic() @test
{
	test::eq(a64("aarch64-linux-gnu", "generic"), A64_PREFIX.tconcat(
		"#define __ARM_ARCH 8\n#define __ARM_ARCH_PROFILE 'A'\n#define __AARCH64EL__ 1\n"
		"#define __AARCH64_CMODEL_SMALL__ 1\n#define __ARM_FP 0xE\n#define __ARM_NEON 1\n#define __ARM_NEON_FP 0xE\n"
		"#define __ARM_FEATURE_UNALIGNED 1\n#define __ARM_SIZEOF_MINIMAL_ENUM 4\n#define __ARM_SIZEOF_WCHAR_T 4\n"));
}

fn void aarch64_variants() @test
{
	String be = a64("aarch64_be-linux-gnu", "generic");
	expect_lines(be, { "#define __AARCH64EB__ 1", "#define __AARCH_BIG_ENDIAN 1", "#define __ARM_BIG_ENDIAN 1" });
	expect_undefined(be, { "__AARCH64EL__" });

	String win = a64("aarch64-windows-msvc", "generic");
	expect_lines(win, { "#define _M_ARM64 1", "#define __ARM_SIZEOF_WCHAR_T 2" });
	expect_undefined(a64("aarch64-windows-gnu", "generic"), { "_M_ARM64" });

	String large = a64("aarch64-linux-gnu", "generic", { .cmodel = LARGE });
	expect_lines(large, { "#define __AARCH64_CMODEL_LARGE__ 1" });

	// apple_m1 (v8.5a + aes + sha3 + fullfp16) on macOS.
	String m1 = a64("aarch64-macos-none", "apple_m1");
	expect_lines(m1, { "#define __AARCH64_SIMD__ 1", "#define __ARM64_ARCH_8__ 1", "#define __ARM_NEON__ 1",
		"#define __arm64 1", "#define __arm64__ 1", "#define __ARM_FEATURE_COMPLEX 1", "#define __ARM_FEATURE_JCVT 1",
		"#define __ARM_FEATURE_SHA3 1", "#define __ARM_FEATURE_SHA512 1", "#define __ARM_FEATURE_FP16_VECTOR_ARITHMETIC 1",
		"#define __ARM_FEATURE_RCPC 1", "#define __ARM_FEATURE_CRC32 1", "#define __ARM_FEATURE_AES 1",
		"#define __ARM_FEATURE_SHA2 1", "#define __ARM_FEATURE_PAUTH 1", "#define __ARM_FEATURE_FP16_SCALAR_ARITHMETIC 1",
		"#define __ARM_FEATURE_DOTPROD 1", "#define __ARM_FEATURE_ATOMICS 1" });
	expect_undefined(m1, { "__ARM_FEATURE_BF16", "__ARM_FEATURE_SVE", "__ARM_FEATURE_SM4", "_M_ARM64" });
	// Table order: CRC32 before AES before SHA2 before PAUTH.
	sz crc = m1.index_of("__ARM_FEATURE_CRC32")!!;
	sz aes = m1.index_of("__ARM_FEATURE_AES ")!!;
	sz sha2 = m1.index_of("__ARM_FEATURE_SHA2 ")!!;
	sz pauth = m1.index_of("__ARM_FEATURE_PAUTH ")!!;
	test::eq(crc < aes && aes < sha2 && sha2 < pauth, true);

	// v9a: __ARM_ARCH 9, sve/sve2 table entries; i8mm (v8.6a) appears twice; bf16 with sve.
	String v9 = a64("aarch64-linux-gnu", "generic+v9_1a+rcpc3+sme+sm4+sve_aes+sve_bitperm");
	expect_lines(v9, { "#define __ARM_ARCH 9", "#define __ARM_FEATURE_SVE 1", "#define __ARM_FEATURE_SVE2 1",
		"#define __ARM_FEATURE_MATMUL_INT8 1", "#define __ARM_FEATURE_SVE_MATMUL_INT8 1",
		"#define __ARM_FEATURE_BF16 1", "#define __ARM_FEATURE_SVE_BF16 1", "#define __ARM_FEATURE_RCPC 3",
		"#define __ARM_FEATURE_SME 1", "#define __ARM_FEATURE_LOCALLY_STREAMING 1", "#define __ARM_FEATURE_SM3 1",
		"#define __ARM_FEATURE_SM4 1", "#define __ARM_FEATURE_SVE2_AES 1", "#define __ARM_FEATURE_SVE2_BITPERM 1" });
	expect_undefined(v9, { "__ARM64_ARCH_8__" });

	// v8r: profile 'R'.
	expect_lines(a64("aarch64-linux-gnu", "generic+v8r"), { "#define __ARM_ARCH_PROFILE 'R'", "#define __ARM_ARCH 8" });

	// no_unaligned_access, short enums.
	String nu = a64("aarch64-linux-gnu", "generic+no_unaligned_access", { .short_enums = true });
	expect_undefined(nu, { "__ARM_FEATURE_UNALIGNED" });
	expect_lines(nu, { "#define __ARM_SIZEOF_MINIMAL_ENUM 1" });
}
