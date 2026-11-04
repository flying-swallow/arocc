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
// Stage 0: signatures only; every body is a stub.
module aro::predefined_macros;
import aro::compilation, aro::target, aro::lang_opts, aro::code_gen_options;

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
 OWNER: 14.2.
*>
fn RiscvFloatAbi riscv_float_abi(Target* target)
{
	unreachable("stage 0 stub");
}

<*
 `if (comp.langopts.pthread)`: _REENTRANT for maccatalyst/macos/tvos/ios/
 driverkit/visionos/watchos/hurd/linux/netbsd/openbsd/fuchsia; _MT for
 windows with abi MSVC; __EMSCRIPTEN_PTHREADS__ for emscripten.
 OWNER: 14.2.
*>
fn void write_pthread_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 The OS switch for every OS except windows and Darwin: linux (define_std
 linux), uefi __UEFI__, freebsd (__FreeBSD__ <major>, __FreeBSD_cc_version
 <major*10000+1>), ps4/ps5 (__FreeBSD__ 9, __FreeBSD_cc_version 900001),
 netbsd, openbsd, dragonfly, illumos (define_std sun + __illumos__), wasi,
 emscripten, serenity, switch (__SWITCH__), 3ds (__3DS__), gba, psp (__PSP__),
 psx (__psx__), vita (__vita__), wiiu (__WIIU__); else nothing.
 OWNER: 14.2.
*>
fn void write_other_os_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	unreachable("stage 0 stub");
}

<*
 define_std("unix") for freebsd/netbsd/openbsd/dragonfly/linux/haiku/hurd/
 illumos/emscripten/ps4/ps5; then __ANDROID__ if abi.is_android().
 OWNER: 14.2.
*>
fn void write_unix_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	unreachable("stage 0 stub");
}

<*
 The mips/mipsel/mips64/mips64el arm: __mips__, _mips, mips (GNU), endian
 (_MIPSEB/MIPSEB or _MIPSEL/MIPSEL), ABI block by target.mips_abi() (o32,
 n32, n64), _MIPS_ARCH "<llvm_name>" + _MIPS_ARCH_<UPPER> (if the model has
 an llvm name), __mips_abicalls (+ __ABICALLS__ on BSD) when pic_level !=
 NONE, __mips_single_float, __mips_fpr / _MIPS_FPSET / _MIPS_SPFPSET by
 default_mips_fp_mode, nan2008, abs2008, dsp revision, msa, nomadd4,
 _MIPS_SZPTR / _MIPS_SZINT / _MIPS_SZLONG and __mips_isa_rev.
 OWNER: 14.2.
*>
fn void write_mips_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	unreachable("stage 0 stub");
}

<*
 powerpc/powerpcle: __powerpc__ __POWERPC__ __ppc__ __PPC__ _ARCH_PPC;
 powerpc64/powerpc64le: __powerpc __powerpc__ __powerpc64__ __POWERPC__
 __ppc__ __ppc64__ __PPC__ __PPC64__ _ARCH_PPC _ARCH_PPC64; both end with
 "_CALL_ELF <ppc_elf_version>".
 OWNER: 14.2.
*>
fn void write_powerpc_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 sparc64: define_std sparc, __sparc_v9__, __arch64__, and (not illumos)
 __sparc64__, __sparc_v9__ (again), __sparcv9__. sparc: define_std sparc,
 __sparcv8 on illumos.
 OWNER: 14.2.
*>
fn void write_sparc_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	unreachable("stage 0 stub");
}

<*
 arm/armeb/thumb/thumbeb: the ACLE block of generateSystemDefines exactly
 (ISA_THUMB from arm_version(), __thumb__, profile, CLZ/DSP/IDIV/SAT/QBIT/
 SIMD32, HwFp/Fpu computation from arm_float_abi() and the vfp/fp_armv8/
 neon/mve_fp/fp64/fp16 features, __ARM_FP 0x<hex>, FMA, VFPV*, NEON +
 __ARM_NEON_FP, __ARM_PCS_VFP, __SOFTFP__, __ARM_FEATURE_COPROC, interwork,
 LDREX (langopts.has_arm_ldrex), UNALIGNED, endian, ROPI/RWPI, minimal enum
 size and __ARM_SIZEOF_WCHAR_T).
 OWNER: 14.2.
*>
fn void write_arm_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 aarch64/aarch64_be: the fixed ACLE defines, LDREX, __ARM_ACLE_VERSION and
 "__ARM_ACLE 202420", __ARM_ARCH 9/8 (v9a), profile R/A (v8r), v8_3a
 COMPLEX/JCVT, endian, Darwin SIMD/arm64 defines, _M_ARM64 1 (windows-msvc),
 __AARCH64_CMODEL_<UPPER(cmodel.macro_name())>__, FP/NEON, BF16, SVE2_AES,
 SVE2_BITPERM, SME, SHA3, SM4, UNALIGNED, FP16_VECTOR_ARITHMETIC, RCPC, the
 __ARM_FEATURE_<X> table in Zig order, minimal enum size and wchar size.
 OWNER: 14.2.
*>
fn void write_aarch64_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<* msp430: MSP430, __MSP430__. arc: __arc__. OWNER: 14.2. *>
fn void write_msp430_arc_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 wasm32/wasm64: __wasm, __wasm__, __wasm32/__wasm32__ or __wasm64/__wasm64__,
 then "#define __wasm_<feature name>__ 1" for every enabled wasm feature in
 Feature declaration order.
 OWNER: 14.2.
*>
fn void write_wasm_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<* s390x: __s390__, __s390x__, __zarch__, __HTM__ (te), __VX__ (vx). OWNER: 14.2. *>
fn void write_s390x_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 riscv*: __riscv, __riscv_xlen <ptr width>, __riscv_f/d/q 2002000,
 __riscv_flen 128/64/32 (q, d, f), __riscv_float_abi_<riscv_float_abi>.
 OWNER: 14.2.
*>
fn void write_riscv_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}
