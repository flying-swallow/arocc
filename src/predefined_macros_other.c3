// generateSystemDefines sections for every OS other than Windows/Darwin and
// every architecture other than x86, from src/aro/Compilation.zig (plan 14).
// OWNER: plan 14.2 `sysdefs-b`. Called from generate_system_defines
// (predefined_macros.c3) in the documented order.
//
// CPU feature data: every aarch64 feature the Zig __ARM_FEATURE_* table names
// and the full wasm feature list exist in target::Feature (plan 14 stage 0).
// write_wasm_defines iterates `Feature::values` filtered to family WASM: that
// is Zig's `allFeaturesList()` order. ARM/MIPS/RISC-V/s390x features were
// already present (s390x `.vx`/`.te` are S390X_VX/S390X_TE). Missing feature
// dependencies / CPU models go to the integrator, not into target_cpu.c3.
//
// Every section is a line-by-line port of the matching arm of Zig
// generateSystemDefines (Compilation.zig lines ~322-343, 408-543, 750-1376)
// and riscvFloatAbi (~1578). Output text, order and conditions follow the
// Zig source exactly; no Zig executable was run.
module aro::predefined_macros;
import aro::compilation, aro::target, aro::lang_opts, aro::code_gen_options, aro::type_store;
import std::core::ascii;

<*
 Zig `RiscvFloatAbi`; printed as __riscv_float_abi_<name> (Zig `{t}`).
*>
enum RiscvFloatAbi : char (String name)
{
	SOFT { "soft" },
	SINGLE { "single" },
	DOUBLE { "double" },
}

<*
 Zig `riscvFloatAbi`: gnusf/muslsf -> SOFT, gnuf32/muslf32 -> SINGLE,
 otherwise DOUBLE with the d feature, SINGLE with f, else SOFT.
*>
fn RiscvFloatAbi riscv_float_abi(Target* target)
{
	switch (target.abi)
	{
		case GNUSF:
		case MUSLSF: return SOFT;
		case GNUF32:
		case MUSLF32: return SINGLE;
		default:
			if (target.cpu.has(RISCV_D)) return DOUBLE;
			if (target.cpu.has(RISCV_F)) return SINGLE;
			return SOFT;
	}
}

<*
 `if (comp.langopts.pthread)`: _REENTRANT for maccatalyst/macos/tvos/ios/
 driverkit/visionos/watchos/hurd/linux/netbsd/openbsd/fuchsia; _MT for
 windows with abi MSVC; __EMSCRIPTEN_PTHREADS__ for emscripten.
*>
fn void write_pthread_defines(Compilation* comp, MacroWriter* w)
{
	if (!comp.langopts.pthread) return;
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case IOS:
		case DRIVERKIT:
		case VISIONOS:
		case WATCHOS:
		case HURD:
		case LINUX:
		case NETBSD:
		case OPENBSD:
		case FUCHSIA: w.define("_REENTRANT");
		case WINDOWS:
			// This matches clang where it is marked as a FIXME
			if (t.abi == MSVC) w.define("_MT");
		case EMSCRIPTEN: w.define("__EMSCRIPTEN_PTHREADS__");
		default: break;
	}
}

<*
 The OS switch for every OS except windows and Darwin: linux (define_std
 linux), uefi __UEFI__, freebsd (__FreeBSD__ <major>, __FreeBSD_cc_version
 <major*10000+1>), ps4/ps5 (__FreeBSD__ 9, __FreeBSD_cc_version 900001),
 netbsd, openbsd, dragonfly, illumos (define_std sun + __illumos__), wasi,
 emscripten, serenity, switch (__SWITCH__), 3ds (__3DS__), gba, psp (__PSP__),
 psx (__psx__), vita (__vita__), wiiu (__WIIU__); else nothing.
*>
fn void write_other_os_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case LINUX: w.define_std("linux", is_gnu);
		case UEFI: w.define("__UEFI__");
		case FREEBSD:
			ulong release = t.os.min.major;
			ulong cc_version = release * 10_000 + 1;
			w.printf("#define __FreeBSD__ %d\n#define __FreeBSD_cc_version %d\n", release, cc_version);
		case PS4:
		case PS5: w.write("#define __FreeBSD__ 9\n#define __FreeBSD_cc_version 900001\n");
		case NETBSD: w.define("__NetBSD__");
		case OPENBSD: w.define("__OpenBSD__");
		case DRAGONFLY: w.define("__DragonFly__");
		case ILLUMOS:
			w.define_std("sun", is_gnu);
			w.define("__illumos__");
		case WASI: w.define("__wasi__");
		case EMSCRIPTEN: w.define("__EMSCRIPTEN__");
		case SERENITY: w.define("__serenity__");
		case SWITCH: w.define("__SWITCH__");
		case THREEDS: w.define("__3DS__");
		case GBA: w.define("__GBA__");
		case PSP: w.define("__PSP__");
		case PSX: w.define("__psx__");
		case VITA: w.define("__vita__");
		case WIIU: w.define("__WIIU__");
		default: break;
	}
}

<*
 define_std("unix") for freebsd/netbsd/openbsd/dragonfly/linux/haiku/hurd/
 illumos/emscripten/ps4/ps5; then __ANDROID__ if abi.is_android().
*>
fn void write_unix_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case FREEBSD:
		case NETBSD:
		case OPENBSD:
		case DRAGONFLY:
		case LINUX:
		case HAIKU:
		case HURD:
		case ILLUMOS:
		case EMSCRIPTEN:
		case PS4:
		case PS5: w.define_std("unix", is_gnu);
		default: break;
	}
	if (t.abi.is_android()) w.define("__ANDROID__");
}

<*
 The mips/mipsel/mips64/mips64el arm: __mips__, _mips, mips (GNU), endian
 (_MIPSEB/MIPSEB or _MIPSEL/MIPSEL), ABI block by target.mips_abi() (o32,
 n32, n64), _MIPS_ARCH "<llvm_name>" + _MIPS_ARCH_<UPPER> (if the model has
 an llvm name), __mips_abicalls (+ __ABICALLS__ on BSD) when pic_level !=
 NONE, __mips_single_float, __mips_fpr / _MIPS_FPSET / _MIPS_SPFPSET by
 default_mips_fp_mode, nan2008, abs2008, dsp revision, msa, nomadd4,
 _MIPS_SZPTR / _MIPS_SZINT / _MIPS_SZLONG and __mips_isa_rev.
*>
fn void write_mips_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	w.define("__mips__");
	w.define("_mips");
	if (is_gnu) w.define("mips");
	switch (t.cpu.arch)
	{
		case MIPS:
		case MIPS64:
			w.define("_MIPSEB");
			w.define_std("MIPSEB", is_gnu);
		case MIPSEL:
		case MIPS64EL:
			w.define("_MIPSEL");
			w.define_std("MIPSEL", is_gnu);
		default: unreachable();
	}

	switch (t.mips_abi())
	{
		case O32:
			w.define("__mips_o32");
			w.define("_ABIO32");
			w.write("#define _MIPS_SIM _ABIO32\n");
			w.write("#define __mips 32\n");
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS32\n");
		case N32:
			w.define("__mips_n32");
			w.write("#define _ABIN32 2\n");
			w.write("#define _MIPS_SIM _ABIN32\n");
			w.write("#define __mips 64\n");
			w.define("__mips64");
			w.define("__mips64__");
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS64\n");
		case N64:
			w.define("__mips_n64");
			w.write("#define _ABI64 3\n");
			w.write("#define _MIPS_SIM _ABI64\n");
			w.write("#define __mips 64\n");
			w.define("__mips64");
			w.define("__mips64__");
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS64\n");
	}
	// Zig `llvm_name: ?[*:0]const u8`; an empty llvm_name is null here.
	String name = t.cpu.model.llvm_name;
	if (name.len)
	{
		w.printf("#define _MIPS_ARCH \"%s\"\n", name);
		w.write("#define _MIPS_ARCH_");
		foreach (c : name) w.write_byte(ascii::to_upper(c));
		w.write(" 1\n");
	}

	// Zig also has `!target.cpu.has(.mips, .noabicalls)` commented out.
	if (comp.code_gen_options.pic_level != NONE)
	{
		w.define("__mips_abicalls");
		if (t.os.tag.is_bsd()) w.define("__ABICALLS__");
	}

	// Zig: __mips_soft_float / __mips_hard_float are commented out.
	bool single_only = t.cpu.has(MIPS_FPU_S) && !t.cpu.has(MIPS_FPU_D);
	if (single_only) w.define("__mips_single_float");
	{
		MipsFpMode mode = t.default_mips_fp_mode();
		int fpr;
		switch (mode)
		{
			case FP32: fpr = 32;
			case FP64: fpr = 64;
			case FPXX: fpr = 0;
		}
		w.printf("#define __mips_fpr %d\n", fpr);
		int fpset = (mode == FP64 || single_only) ? 32 : 16;
		w.printf("#define _MIPS_FPSET %d\n", fpset);
		// Zig: `target.cpu.has(.mips, .nooddspreg) or` is commented out.
		int spfpset = mode == FPXX ? 16 : 32;
		w.printf("#define _MIPS_SPFPSET %d\n", spfpset);
	}
	// Zig: __mips16 / __mips_micromips are commented out.
	if (t.cpu.has(MIPS_NAN2008)) w.define("__mips_nan2008");
	if (t.cpu.has(MIPS_ABS2008)) w.define("__mips_abs2008");
	if (t.cpu.has(MIPS_DSPR3))
	{
		w.write("#define __mips_dsp_rev 3\n");
		w.write("#define __mips_dsp 3\n");
		w.define("__mips_dspr3");
	}
	else if (t.cpu.has(MIPS_DSPR2))
	{
		w.write("#define __mips_dsp_rev 2\n");
		w.write("#define __mips_dsp 2\n");
		w.define("__mips_dspr2");
	}
	else if (t.cpu.has(MIPS_DSP))
	{
		w.write("#define __mips_dsp_rev 1\n");
		w.write("#define __mips_dsp 1\n");
	}
	if (t.cpu.has(MIPS_MSA)) w.define("__mips_msa");
	if (t.cpu.has(MIPS_NOMADD4)) w.define("__mips_no_madd4");
	w.printf("#define _MIPS_SZPTR %d\n", t.ptr_bit_width());
	w.printf("#define _MIPS_SZINT %d\n", t.c_type_bit_size(INT));
	w.printf("#define _MIPS_SZLONG %d\n", t.c_type_bit_size(LONG));
	w.printf("#define __mips_isa_rev %d\n", t.mips_isa_rev());
}

<*
 powerpc/powerpcle: __powerpc__ __POWERPC__ __ppc__ __PPC__ _ARCH_PPC;
 powerpc64/powerpc64le: __powerpc __powerpc__ __powerpc64__ __POWERPC__
 __ppc__ __ppc64__ __PPC__ __PPC64__ _ARCH_PPC _ARCH_PPC64; both end with
 "_CALL_ELF <ppc_elf_version>".
*>
fn void write_powerpc_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	switch (t.cpu.arch)
	{
		case POWERPC:
		case POWERPCLE:
			w.define("__powerpc__");
			w.define("__POWERPC__");
			w.define("__ppc__");
			w.define("__PPC__");
			w.define("_ARCH_PPC");
		default:
			w.define("__powerpc");
			w.define("__powerpc__");
			w.define("__powerpc64__");
			w.define("__POWERPC__");
			w.define("__ppc__");
			w.define("__ppc64__");
			w.define("__PPC__");
			w.define("__PPC64__");
			w.define("_ARCH_PPC");
			w.define("_ARCH_PPC64");
	}
	w.printf("#define _CALL_ELF %d\n", t.ppc_elf_version());
}

<*
 sparc64: define_std sparc, __sparc_v9__, __arch64__, and (not illumos)
 __sparc64__, __sparc_v9__ (again), __sparcv9__. sparc: define_std sparc,
 __sparcv8 on illumos.
*>
fn void write_sparc_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	w.define_std("sparc", is_gnu);
	if (t.cpu.arch == SPARC64)
	{
		w.define("__sparc_v9__");
		w.define("__arch64__");
		if (t.os.tag != ILLUMOS)
		{
			w.define("__sparc64__");
			w.define("__sparc_v9__");
			w.define("__sparcv9__");
		}
	}
	else if (t.os.tag == ILLUMOS)
	{
		w.define("__sparcv8");
	}
}

// ACLE 6.5.1 Hardware Floating Point (Zig `HwFp`, packed u4): the value of __ARM_FP.
const char HWFP_HP = 1 << 1; // half (16-bit)
const char HWFP_SP = 1 << 2; // single (32-bit)
const char HWFP_DP = 1 << 3; // double (64-bit)

// arm_acle.h co-processor intrinsic groups (Zig `coproc`).
const char COPROC_B1 = 1 << 0; // __arm_cdp __arm_ldc, __arm_ldcl, __arm_stc, __arm_stcl, __arm_mcr and __arm_mrc
const char COPROC_B2 = 1 << 1; // __arm_cdp2, __arm_ldc2, __arm_stc2, __arm_ldc2l, __arm_stc2l, __arm_mcr2 and __arm_mrc2
const char COPROC_B3 = 1 << 2; // __arm_mcrr, __arm_mrrc
const char COPROC_B4 = 1 << 3; // __arm_mcrr2, __arm_mrrc2
const char COPROC_ALL = COPROC_B1 | COPROC_B2 | COPROC_B3 | COPROC_B4;

<* Zig `coproc_bf`: which co-processor intrinsics in arm_acle.h are available. *>
fn char arm_coproc_bits(Target* t) @local
{
	ArmVersion? v = t.arm_version();
	if (catch v) return 0;
	if (v.string == "6M" || v.string == "6SM" || v.string == "8M_BASE") return 0;
	if (v.string == "8M_MAIN" || v.string == "8_1M_MAIN") return COPROC_ALL;
	switch (v.version)
	{
		case 4: return COPROC_B1;
		case 5: return v.string == "5T" ? COPROC_B1 | COPROC_B2 : COPROC_B1 | COPROC_B2 | COPROC_B3;
		case 6:
		case 7: return COPROC_ALL;
		case 8:
		case 9: return COPROC_B1 | COPROC_B3;
		default: return 0;
	}
}

<*
 arm/armeb/thumb/thumbeb: the ACLE block of generateSystemDefines exactly
 (ISA_THUMB from arm_version(), __thumb__, profile, CLZ/DSP/IDIV/SAT/QBIT/
 SIMD32, HwFp/Fpu computation from arm_float_abi() and the vfp/fp_armv8/
 neon/mve_fp/fp64/fp16 features, __ARM_FP 0x<hex>, FMA, VFPV*, NEON +
 __ARM_NEON_FP, __ARM_PCS_VFP, __SOFTFP__, __ARM_FEATURE_COPROC, interwork,
 LDREX (langopts.has_arm_ldrex), UNALIGNED, endian, ROPI/RWPI, minimal enum
 size and __ARM_SIZEOF_WCHAR_T). Needs type_store::init_named_types (wchar).
*>
fn void write_arm_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	Arch arch = t.cpu.arch;
	w.define("__arm__");
	w.define("__arm");
	w.define("__ARM_32BIT_STATE");
	w.define("__APCS_32__");
	w.define("__VFP_FP__");
	w.define("__ARM_FP16_ARGS");
	w.define("__ARM_FP16_FORMAT_IEEE");

	w.write("#define __ARM_ACLE 200\n");

	// __ARM_ARCH_ISA_THUMB is defined to 2 if the core supports the Thumb-2 ISA.
	if (try v = t.arm_version())
	{
		bool supports_thumb2 = v.string == "6T2" || (v.version >= 7 && v.string != "8M_BASE");
		if (supports_thumb2)
		{
			w.write("#define __ARM_ARCH_ISA_THUMB 2\n");
		}
		else if (v.string.contains_char('T') || v.version >= 6)
		{
			w.write("#define __ARM_ARCH_ISA_THUMB 1\n");
		}
	}

	bool mclass = t.cpu.has(ARM_MCLASS);
	bool is_thumb = arch.is_thumb() || mclass;
	if (t.cpu.has(ARM_THUMB2) || is_thumb) w.define("__thumb__");
	// ARM ISA means we are not M profile
	if (!mclass) w.define("__ARM_ARCH_ISA_ARM");

	char arm_version = 6;
	if (try v = t.arm_version())
	{
		arm_version = v.version;
		w.printf("#define __ARM_ARCH_%s__ 1\n", v.string);
		w.printf("#define __ARM_ARCH %d\n", v.version);
	}

	char arm_profile = 0;
	if (t.cpu.has(ARM_ACLASS))
	{
		arm_profile = 'A';
	}
	else if (t.cpu.has(ARM_RCLASS))
	{
		arm_profile = 'R';
	}
	else if (mclass)
	{
		arm_profile = 'M';
	}
	if (arm_profile) w.printf("#define __ARM_ARCH_PROFILE '%c'\n", arm_profile);

	if (arm_version == 5 || (arm_version == 6 && !mclass) || arm_version > 6) w.define("__ARM_FEATURE_CLZ");

	bool has_dsp = t.arm_has_dsp();
	if (has_dsp) w.define("__ARM_FEATURE_DSP");

	if ((is_thumb && t.cpu.has(ARM_HWDIV)) || (!is_thumb && t.cpu.has(ARM_HWDIV_ARM)))
	{
		w.define("__ARM_FEATURE_IDIV");
		w.define("__ARM_ARCH_EXT_IDIV__");
	}
	bool sat = false;
	if ((arm_version == 6 && !mclass) || arm_version > 6)
	{
		w.define("__ARM_FEATURE_SAT");
		sat = true;
	}

	if (has_dsp || sat) w.define("__ARM_FEATURE_QBIT");

	if ((!mclass && arm_version >= 6) || (mclass && t.cpu.has(ARM_DSP))) w.define("__ARM_FEATURE_SIMD32");

	ArmFloatAbi float_abi = t.arm_float_abi();

	// This is a (hopefully) exact copy of the code in clang (lib/Basic/Targets/ARM.cpp).
	char hw_fp = 0;
	bool fpu_vfp2, fpu_vfp3, fpu_vfp4, fpu_neon, fpu_fp_armv8;
	if (float_abi != SOFT)
	{
		if (t.cpu.has(ARM_VFP2) || t.cpu.has(ARM_VFP2SP))
		{
			fpu_vfp2 = true;
			hw_fp |= HWFP_SP;
			if (t.cpu.has(ARM_VFP2)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_VFP3) || t.cpu.has(ARM_VFP3D16) || t.cpu.has(ARM_VFP3SP) || t.cpu.has(ARM_VFP3D16SP))
		{
			fpu_vfp3 = true;
			hw_fp |= HWFP_SP;
			if (t.cpu.has(ARM_VFP3) || t.cpu.has(ARM_VFP3D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_VFP4) || t.cpu.has(ARM_VFP4D16) || t.cpu.has(ARM_VFP4SP) || t.cpu.has(ARM_VFP4D16SP))
		{
			fpu_vfp4 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
			if (t.cpu.has(ARM_VFP4) || t.cpu.has(ARM_VFP4D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_FP_ARMV8) || t.cpu.has(ARM_FP_ARMV8D16) || t.cpu.has(ARM_FP_ARMV8SP) || t.cpu.has(ARM_FP_ARMV8D16SP))
		{
			fpu_fp_armv8 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
			if (t.cpu.has(ARM_FP_ARMV8) || t.cpu.has(ARM_FP_ARMV8D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_NEON))
		{
			fpu_neon = true;
			hw_fp |= HWFP_SP;
		}
		if (t.cpu.has(ARM_MVE_FP))
		{
			fpu_fp_armv8 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
		}
		if (t.cpu.has(ARM_FP64)) hw_fp |= HWFP_DP;
		if (t.cpu.has(ARM_FP16)) hw_fp |= HWFP_HP;
	}
	// clang: `FPUModeIsVFP`
	bool fpu_is_vfp = fpu_vfp2 || fpu_vfp3 || fpu_vfp4 || fpu_neon || fpu_fp_armv8;

	if (hw_fp != 0) w.printf("#define __ARM_FP 0x%x\n", hw_fp);

	if (arm_version >= 7 && fpu_vfp4) w.define("__ARM_FEATURE_FMA");

	if (fpu_is_vfp)
	{
		if (fpu_vfp2) w.define("__ARM_VFPV2__");
		if (fpu_vfp3) w.define("__ARM_VFPV3__");
		if (fpu_vfp4) w.define("__ARM_VFPV4__");
		if (fpu_fp_armv8) w.define("__ARM_FPV5__");
	}

	if (fpu_neon && float_abi != SOFT && arm_version >= 7)
	{
		w.define("__ARM_NEON");
		w.define("__ARM_NEON__");
		// Current AArch32 Neon implementations have no double-precision support
		// even when VFP does.
		char neon_fp = hw_fp & (char)~HWFP_DP;
		w.printf("#define __ARM_NEON_FP 0x%x\n", neon_fp);
	}

	if (float_abi == HARD) w.define("__ARM_PCS_VFP");

	if (float_abi == SOFT || (float_abi == SOFT_FP && !fpu_is_vfp)) w.define("__SOFTFP__");

	w.printf("#define __ARM_FEATURE_COPROC 0x%x\n", arm_coproc_bits(t));

	if (arm_version >= 5 && arm_version <= 8 && t.os.tag != WINDOWS) w.define("__THUMB_INTERWORK__");

	if (comp.langopts.has_arm_ldrex) w.printf("#define __ARM_FEATURE_LDREX 0x%x\n", (char)comp.langopts.arm_ldrex);

	if (!t.cpu.has(ARM_NO_UNALIGNED_ACCESS)) w.define("__ARM_FEATURE_UNALIGNED");

	if (arch == ARM || arch == THUMB) w.define("__ARMEL__");

	if (arch == ARMEB || arch == THUMBEB)
	{
		w.define("__ARMEB__");
		w.define("__ARM_BIG_ENDIAN");
	}
	if (comp.code_gen_options.is_ropi) w.define("__ARM_ROPI");
	if (comp.code_gen_options.is_rwpi) w.define("__ARM_RWPI");

	write_arm_enum_and_wchar_size(comp, w);
}

<* The shared ARM/AArch64 tail: __ARM_SIZEOF_MINIMAL_ENUM and __ARM_SIZEOF_WCHAR_T. *>
fn void write_arm_enum_and_wchar_size(Compilation* comp, MacroWriter* w) @local
{
	int min_enum_size = comp.langopts.short_enums ? 1 : 4;
	w.printf("#define __ARM_SIZEOF_MINIMAL_ENUM %d\n", min_enum_size);
	w.printf("#define __ARM_SIZEOF_WCHAR_T %d\n", comp.type_store.wchar.sizeof(comp));
}

struct Aarch64FeatureMacro
{
	Feature feature;
	String name;
}

<* Zig's __ARM_FEATURE_<name> table for aarch64, in Zig order (i8mm appears twice). *>
const Aarch64FeatureMacro[*] AARCH64_FEATURE_MACROS = {
	{ AARCH64_SVE, "SVE" },
	{ AARCH64_SVE2, "SVE2" },
	{ AARCH64_SVE2P1, "SVE2p1" },
	{ AARCH64_SVE2_SHA3, "SVE2_SHA3" },
	{ AARCH64_SVE2_SM4, "SVE2_SM4" },
	{ AARCH64_SVE_B16B16, "SVE_B16B16" },
	{ AARCH64_SME2, "SME2" },
	{ AARCH64_SME2P1, "SME2p1" },
	{ AARCH64_SME_F16F16, "SME_F16F16" },
	{ AARCH64_SME_B16B16, "SME_B16B16" },
	{ AARCH64_CRC, "CRC32" },
	{ AARCH64_AES, "AES" },
	{ AARCH64_SHA2, "SHA2" },
	{ AARCH64_PAUTH, "PAUTH" },
	{ AARCH64_PAUTH_LR, "PAUTH_LR" },
	{ AARCH64_BTI, "BTI" },
	{ AARCH64_FULLFP16, "FP16_SCALAR_ARITHMETIC" },
	{ AARCH64_DOTPROD, "DOTPROD" },
	{ AARCH64_MTE, "MEMORY_TAGGING" },
	{ AARCH64_I8MM, "MATMUL_INT8" },
	{ AARCH64_LSE, "ATOMICS" },
	{ AARCH64_F64MM, "SVE_MATMUL_FP64" },
	{ AARCH64_F32MM, "SVE_MATMUL_FP32" },
	{ AARCH64_I8MM, "SVE_MATMUL_INT8" },
	{ AARCH64_FP16FML, "FP16_FML" },
	{ AARCH64_LS64, "LS64" },
	{ AARCH64_RAND, "RNG" },
	{ AARCH64_MOPS, "MOPS" },
	{ AARCH64_D128, "SYSREG128" },
	{ AARCH64_GCS, "GCS" },
};

<*
 aarch64/aarch64_be: the fixed ACLE defines, LDREX, __ARM_ACLE_VERSION and
 "__ARM_ACLE 202420", __ARM_ARCH 9/8 (v9a), profile R/A (v8r), v8_3a
 COMPLEX/JCVT, endian, Darwin SIMD/arm64 defines, _M_ARM64 1 (windows-msvc),
 __AARCH64_CMODEL_<UPPER(cmodel.macro_name())>__, FP/NEON, BF16, SVE2_AES,
 SVE2_BITPERM, SME, SHA3, SM4, UNALIGNED, FP16_VECTOR_ARITHMETIC, RCPC, the
 __ARM_FEATURE_<X> table in Zig order, minimal enum size and wchar size.
 Needs type_store::init_named_types (wchar).
*>
fn void write_aarch64_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	w.define("__aarch64__");
	w.define("__ARM_64BIT_STATE");
	w.define("__ARM_ARCH_ISA_A64");
	w.define("__ARM_FEATURE_CLZ");
	w.define("__ARM_FEATURE_FMA");
	if (comp.langopts.has_arm_ldrex) w.printf("#define __ARM_FEATURE_LDREX 0x%x\n", (char)comp.langopts.arm_ldrex);
	w.define("__ARM_FEATURE_IDIV"); // As specified in ACLE
	w.define("__ARM_FEATURE_DIV"); // For backwards compatibility
	w.define("__ARM_STATE_ZA");
	w.define("__ARM_STATE_ZT0");
	w.write("#define __ARM_ALIGN_MAX_STACK_PWR 4\n");
	w.define("__ARM_FEATURE_NUMERIC_MAXMIN");
	w.define("__ARM_FEATURE_DIRECTED_ROUNDING");

	w.write("#define __ARM_ACLE_VERSION(year,quarter,patch) (100 * (year) + 10 * (quarter) + (patch))\n");
	int acle_version = (100 * 2024) + (10 * 2) + 0; // ACLE 2024.2
	w.printf("#define __ARM_ACLE %d\n", acle_version);

	int arm_version = t.cpu.has(AARCH64_V9A) ? 9 : 8;
	char arm_profile = t.cpu.has(AARCH64_V8R) ? 'R' : 'A';
	w.printf("#define __ARM_ARCH %d\n", arm_version);
	w.printf("#define __ARM_ARCH_PROFILE '%c'\n", arm_profile);

	if (t.cpu.has(AARCH64_V8_3A))
	{
		w.define("__ARM_FEATURE_COMPLEX");
		w.define("__ARM_FEATURE_JCVT");
	}

	if (t.cpu.arch == AARCH64)
	{
		w.define("__AARCH64EL__");
	}
	else
	{
		w.define("__AARCH64EB__");
		w.define("__AARCH_BIG_ENDIAN");
		w.define("__ARM_BIG_ENDIAN");
	}
	if (t.os.tag.is_darwin())
	{
		w.define("__AARCH64_SIMD__");
		if (t.ptr_bit_width() == 32)
		{
			w.define("__ARM64_ARCH_8_32__");
		}
		else
		{
			w.define("__ARM64_ARCH_8__");
		}
		w.define("__ARM_NEON__");
		w.define("__arm64");
		w.define("__arm64__");
	}
	if (t.os.tag == WINDOWS && t.abi == MSVC) w.write("#define _M_ARM64 1\n");

	w.write("#define __AARCH64_CMODEL_");
	foreach (c : comp.cmodel.macro_name()) w.write_byte(ascii::to_upper(c));
	w.write("__ 1\n");

	if (t.cpu.has(AARCH64_FP_ARMV8)) w.write("#define __ARM_FP 0xE\n");
	if (t.cpu.has(AARCH64_NEON))
	{
		w.define("__ARM_NEON");
		w.write("#define __ARM_NEON_FP 0xE\n");
	}
	if (t.cpu.has(AARCH64_BF16))
	{
		w.define("__ARM_FEATURE_BF16");
		w.define("__ARM_FEATURE_BF16_VECTOR_ARITHMETIC");
		w.define("__ARM_BF16_FORMAT_ALTERNATIVE");
		w.define("__ARM_FEATURE_BF16_SCALAR_ARITHMETIC");
		if (t.cpu.has(AARCH64_SVE)) w.define("__ARM_FEATURE_SVE_BF16");
	}
	if (t.cpu.has(AARCH64_SVE2) && t.cpu.has(AARCH64_SVE_AES)) w.define("__ARM_FEATURE_SVE2_AES");
	if (t.cpu.has(AARCH64_SVE2) && t.cpu.has(AARCH64_SVE_BITPERM)) w.define("__ARM_FEATURE_SVE2_BITPERM");
	if (t.cpu.has(AARCH64_SME))
	{
		w.define("__ARM_FEATURE_SME");
		w.define("__ARM_FEATURE_LOCALLY_STREAMING");
	}
	// Zig: __HAVE_FUNCTION_MULTI_VERSIONING (fmv) is commented out.
	if (t.cpu.has(AARCH64_SHA3))
	{
		w.define("__ARM_FEATURE_SHA3");
		w.define("__ARM_FEATURE_SHA512");
	}
	if (t.cpu.has(AARCH64_SM4))
	{
		w.define("__ARM_FEATURE_SM3");
		w.define("__ARM_FEATURE_SM4");
	}
	if (!t.cpu.has(AARCH64_NO_UNALIGNED_ACCESS)) w.define("__ARM_FEATURE_UNALIGNED");
	if (t.cpu.has(AARCH64_NEON) && t.cpu.has(AARCH64_FULLFP16)) w.define("__ARM_FEATURE_FP16_VECTOR_ARITHMETIC");
	if (t.cpu.has(AARCH64_RCPC3))
	{
		w.write("#define __ARM_FEATURE_RCPC 3\n");
	}
	else if (t.cpu.has(AARCH64_RCPC))
	{
		w.define("__ARM_FEATURE_RCPC");
	}

	foreach (fm : AARCH64_FEATURE_MACROS)
	{
		if (t.cpu.has(fm.feature)) w.printf("#define __ARM_FEATURE_%s 1\n", fm.name);
	}
	write_arm_enum_and_wchar_size(comp, w);
}

<* msp430: MSP430, __MSP430__. arc: __arc__. *>
fn void write_msp430_arc_defines(Compilation* comp, MacroWriter* w)
{
	switch (comp.target.cpu.arch)
	{
		case MSP430:
			w.define("MSP430");
			w.define("__MSP430__");
		case ARC: w.define("__arc__");
		default: break;
	}
}

<*
 wasm32/wasm64: __wasm, __wasm__, __wasm32/__wasm32__ or __wasm64/__wasm64__,
 then "#define __wasm_<feature name>__ 1" for every enabled wasm feature in
 Feature declaration order.
*>
fn void write_wasm_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	w.define("__wasm");
	w.define("__wasm__");
	if (t.cpu.arch == WASM32)
	{
		w.define("__wasm32");
		w.define("__wasm32__");
	}
	else
	{
		w.define("__wasm64");
		w.define("__wasm64__");
	}
	foreach (f : Feature::values)
	{
		if (f.family != WASM || !t.cpu.has(f)) continue;
		w.printf("#define __wasm_%s__ 1\n", f.name);
	}
}

<* s390x: __s390__, __s390x__, __zarch__, __HTM__ (te), __VX__ (vx). *>
fn void write_s390x_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	w.define("__s390__");
	w.define("__s390x__");
	w.define("__zarch__");
	if (t.cpu.has(S390X_TE)) w.define("__HTM__");
	if (t.cpu.has(S390X_VX)) w.define("__VX__");
}

<*
 riscv*: __riscv, __riscv_xlen <ptr width>, __riscv_f/d/q 2002000,
 __riscv_flen 128/64/32 (q, d, f), __riscv_float_abi_<riscv_float_abi>.
*>
fn void write_riscv_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	w.define("__riscv");
	w.printf("#define __riscv_xlen %d\n", t.ptr_bit_width());
	bool has_f = t.cpu.has(RISCV_F);
	bool has_d = t.cpu.has(RISCV_D);
	bool has_q = t.cpu.has(RISCV_Q);
	if (has_f) w.write("#define __riscv_f 2002000\n");
	if (has_d) w.write("#define __riscv_d 2002000\n");
	if (has_q) w.write("#define __riscv_q 2002000\n");
	if (has_q)
	{
		w.write("#define __riscv_flen 128\n");
	}
	else if (has_d)
	{
		w.write("#define __riscv_flen 64\n");
	}
	else if (has_f)
	{
		w.write("#define __riscv_flen 32\n");
	}
	w.printf("#define __riscv_float_abi_%s 1\n", riscv_float_abi(t).name);
}
