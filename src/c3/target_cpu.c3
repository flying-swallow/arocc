// CPU features and models for aro::target: the subset of std.Target.Cpu and
// the per-architecture std.Target.<family> tables that aro reads, plus the
// CPU-related parts of src/aro/Target.zig (SubArch.toFeature / toCpuModel,
// cpuModelForTargetQuadruple, armVersion) and Cpu.Model.generic/baseline.
//
// Coverage: Feature lists every feature src/aro/{Target,LangOpts,Driver}.zig
// tests by name, the x86 baseline/v2/v3/v4 sets, the ARM architecture-version
// chain and FP chain, the AArch64 version chain, MIPS ISA chain, RISC-V
// base extensions, SPARC v9, s390x vx/te, SPIR-V versions and a few wasm
// features. CpuModel lists the generic/baseline model of every architecture
// family aro supports, every model Target.zig names, and the -mcpu models used
// by test/records target strings that Zig defines. Plan 14 stage 0 added every
// feature Compilation.zig's x86 / aarch64 predefined-macro tables name and the
// complete wasm feature list (iterated in declaration order for __wasm_*__).
// Still missing: FEATURE_DEPS rows for those new features (e.g. avx512vbmi ->
// avx512bw, sve2 -> sve) and the full LLVM CPU model catalog (-mcpu=skylake
// etc.); with them absent a +feature turns on only itself and unknown models
// fail with UNKNOWN_CPU_MODEL.
//
// PROVENANCE: model feature sets, feature dependencies, Model.generic and
// Model.baseline are from Zig std.Target knowledge, not verified by execution
// (the pinned Zig std library is not available here). They follow LLVM's
// target definitions (ARM.td, AArch64.td, Mips.td, RISCV.td, X86.td), from
// which Zig generates std/Target/<arch>.zig (MIT licensed). Only the
// features listed are tracked; any other feature reads as absent.
module aro::target;

enum FeatureFamily : char
{
	OTHER,
	X86,
	ARM,
	AARCH64,
	MIPS,
	RISCV,
	SPARC,
	S390X,
	SPIRV,
	POWERPC,
	WASM,
}

fn FeatureFamily Arch.family(self)
{
	switch (self)
	{
		case X86:
		case X86_64:
		case X86C16:
		case X86_16: return X86;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return ARM;
		case AARCH64:
		case AARCH64_BE: return AARCH64;
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL: return MIPS;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: return RISCV;
		case SPARC:
		case SPARC64: return SPARC;
		case S390X: return S390X;
		case SPIRV32:
		case SPIRV64: return SPIRV;
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE: return POWERPC;
		case WASM32:
		case WASM64: return WASM;
		default: return OTHER;
	}
}

<* A CPU feature: its architecture family and Zig feature name. *>
enum Feature : ushort (FeatureFamily family, String name)
{
	// x86
	X86_64BIT { X86, "64bit" },
	X86_X87 { X86, "x87" },
	X86_CMOV { X86, "cmov" },
	X86_CX8 { X86, "cx8" },
	X86_CX16 { X86, "cx16" },
	X86_FXSR { X86, "fxsr" },
	X86_MMX { X86, "mmx" },
	X86_NOPL { X86, "nopl" },
	X86_SSE { X86, "sse" },
	X86_SSE2 { X86, "sse2" },
	X86_SSE3 { X86, "sse3" },
	X86_SSSE3 { X86, "ssse3" },
	X86_SSE4_1 { X86, "sse4_1" },
	X86_SSE4_2 { X86, "sse4_2" },
	X86_SSE4A { X86, "sse4a" },
	X86_AVX { X86, "avx" },
	X86_AVX2 { X86, "avx2" },
	X86_AVX512F { X86, "avx512f" },
	X86_AVX512BW { X86, "avx512bw" },
	X86_AVX512CD { X86, "avx512cd" },
	X86_AVX512DQ { X86, "avx512dq" },
	X86_AVX512VL { X86, "avx512vl" },
	X86_POPCNT { X86, "popcnt" },
	X86_SAHF { X86, "sahf" },
	X86_CRC32 { X86, "crc32" },
	X86_AES { X86, "aes" },
	X86_PCLMUL { X86, "pclmul" },
	X86_BMI { X86, "bmi" },
	X86_BMI2 { X86, "bmi2" },
	X86_LZCNT { X86, "lzcnt" },
	X86_MOVBE { X86, "movbe" },
	X86_F16C { X86, "f16c" },
	X86_FMA { X86, "fma" },
	X86_XSAVE { X86, "xsave" },
	X86_XSAVEOPT { X86, "xsaveopt" },
	X86_XSAVEC { X86, "xsavec" },
	X86_XSAVES { X86, "xsaves" },
	X86_SHA { X86, "sha" },
	X86_RDRND { X86, "rdrnd" },
	X86_RDSEED { X86, "rdseed" },
	X86_FSGSBASE { X86, "fsgsbase" },
	X86_PRFCHW { X86, "prfchw" },
	X86_ADX { X86, "adx" },
	X86_CLFLUSHOPT { X86, "clflushopt" },
	X86_EGPR { X86, "egpr" },
	X86_PUSH2POP2 { X86, "push2pop2" },
	X86_PPX { X86, "ppx" },
	X86_NDD { X86, "ndd" },
	X86_CCMP { X86, "ccmp" },
	X86_NF { X86, "nf" },
	X86_CF { X86, "cf" },
	X86_ZU { X86, "zu" },
	X86_INLINE_ASM_USE_GPR32 { X86, "inline_asm_use_gpr32" },
	// x86: the rest of Compilation.zig generateSystemDefines' feature -> macro table (plan 14 stage 0)
	X86_VAES { X86, "vaes" },
	X86_VPCLMULQDQ { X86, "vpclmulqdq" },
	X86_RTM { X86, "rtm" },
	X86_TBM { X86, "tbm" },
	X86_LWP { X86, "lwp" },
	X86_MWAITX { X86, "mwaitx" },
	X86_XOP { X86, "xop" },
	X86_FMA4 { X86, "fma4" },
	X86_GFNI { X86, "gfni" },
	X86_AVX10_1 { X86, "avx10_1" },
	X86_AVX10_2 { X86, "avx10_2" },
	X86_AVX512VPOPCNTDQ { X86, "avx512vpopcntdq" },
	X86_AVX512VNNI { X86, "avx512vnni" },
	X86_AVX512BF16 { X86, "avx512bf16" },
	X86_AVX512FP16 { X86, "avx512fp16" },
	X86_AVX512BITALG { X86, "avx512bitalg" },
	X86_AVX512BMM { X86, "avx512bmm" },
	X86_AVX512VBMI { X86, "avx512vbmi" },
	X86_AVX512VBMI2 { X86, "avx512vbmi2" },
	X86_AVX512IFMA { X86, "avx512ifma" },
	X86_AVX512VP2INTERSECT { X86, "avx512vp2intersect" },
	X86_SHA512 { X86, "sha512" },
	X86_PKU { X86, "pku" },
	X86_CLWB { X86, "clwb" },
	X86_WBNOINVD { X86, "wbnoinvd" },
	X86_SHSTK { X86, "shstk" },
	X86_SGX { X86, "sgx" },
	X86_SM3 { X86, "sm3" },
	X86_SM4 { X86, "sm4" },
	X86_PREFETCHI { X86, "prefetchi" },
	X86_CLZERO { X86, "clzero" },
	X86_KL { X86, "kl" },
	X86_WIDEKL { X86, "widekl" },
	X86_RDPID { X86, "rdpid" },
	X86_RDPRU { X86, "rdpru" },
	X86_CLDEMOTE { X86, "cldemote" },
	X86_WAITPKG { X86, "waitpkg" },
	X86_MOVDIRI { X86, "movdiri" },
	X86_MOVDIR64B { X86, "movdir64b" },
	X86_MOVRS { X86, "movrs" },
	X86_PCONFIG { X86, "pconfig" },
	X86_PTWRITE { X86, "ptwrite" },
	X86_INVPCID { X86, "invpcid" },
	X86_ENQCMD { X86, "enqcmd" },
	X86_HRESET { X86, "hreset" },
	X86_AMX_TILE { X86, "amx_tile" },
	X86_AMX_INT8 { X86, "amx_int8" },
	X86_AMX_BF16 { X86, "amx_bf16" },
	X86_AMX_FP16 { X86, "amx_fp16" },
	X86_AMX_COMPLEX { X86, "amx_complex" },
	X86_AMX_FP8 { X86, "amx_fp8" },
	X86_AMX_MOVRS { X86, "amx_movrs" },
	X86_AMX_AVX512 { X86, "amx_avx512" },
	X86_CMPCCXADD { X86, "cmpccxadd" },
	X86_RAOINT { X86, "raoint" },
	X86_AVXIFMA { X86, "avxifma" },
	X86_AVXNECONVERT { X86, "avxneconvert" },
	X86_AVXVNNI { X86, "avxvnni" },
	X86_AVXVNNIINT16 { X86, "avxvnniint16" },
	X86_AVXVNNIINT8 { X86, "avxvnniint8" },
	X86_SERIALIZE { X86, "serialize" },
	X86_TSXLDTRK { X86, "tsxldtrk" },
	X86_UINTR { X86, "uintr" },
	X86_USERMSR { X86, "usermsr" },
	// arm: has_* are the implied version levels, v* the architecture features
	ARM_HAS_V4T { ARM, "has_v4t" },
	ARM_HAS_V5T { ARM, "has_v5t" },
	ARM_HAS_V5TE { ARM, "has_v5te" },
	ARM_HAS_V6 { ARM, "has_v6" },
	ARM_HAS_V6K { ARM, "has_v6k" },
	ARM_HAS_V6M { ARM, "has_v6m" },
	ARM_HAS_V6T2 { ARM, "has_v6t2" },
	ARM_HAS_V7 { ARM, "has_v7" },
	ARM_HAS_V8M { ARM, "has_v8m" },
	ARM_HAS_V8M_MAIN { ARM, "has_v8m_main" },
	ARM_HAS_V8_1M_MAIN { ARM, "has_v8_1m_main" },
	ARM_HAS_V8 { ARM, "has_v8" },
	ARM_HAS_V8_1A { ARM, "has_v8_1a" },
	ARM_HAS_V8_2A { ARM, "has_v8_2a" },
	ARM_HAS_V8_3A { ARM, "has_v8_3a" },
	ARM_HAS_V8_4A { ARM, "has_v8_4a" },
	ARM_HAS_V8_5A { ARM, "has_v8_5a" },
	ARM_HAS_V8_6A { ARM, "has_v8_6a" },
	ARM_HAS_V8_7A { ARM, "has_v8_7a" },
	ARM_HAS_V8_8A { ARM, "has_v8_8a" },
	ARM_HAS_V8_9A { ARM, "has_v8_9a" },
	ARM_HAS_V9A { ARM, "has_v9a" },
	ARM_HAS_V9_1A { ARM, "has_v9_1a" },
	ARM_HAS_V9_2A { ARM, "has_v9_2a" },
	ARM_HAS_V9_3A { ARM, "has_v9_3a" },
	ARM_HAS_V9_4A { ARM, "has_v9_4a" },
	ARM_HAS_V9_5A { ARM, "has_v9_5a" },
	ARM_HAS_V9_6A { ARM, "has_v9_6a" },
	ARM_V2 { ARM, "v2" },
	ARM_V2A { ARM, "v2a" },
	ARM_V3 { ARM, "v3" },
	ARM_V3M { ARM, "v3m" },
	ARM_V4 { ARM, "v4" },
	ARM_V4T { ARM, "v4t" },
	ARM_V5T { ARM, "v5t" },
	ARM_V5TE { ARM, "v5te" },
	ARM_V5TEJ { ARM, "v5tej" },
	ARM_V6 { ARM, "v6" },
	ARM_V6J { ARM, "v6j" },
	ARM_V6K { ARM, "v6k" },
	ARM_V6KZ { ARM, "v6kz" },
	ARM_V6M { ARM, "v6m" },
	ARM_V6SM { ARM, "v6sm" },
	ARM_V6T2 { ARM, "v6t2" },
	ARM_V7A { ARM, "v7a" },
	ARM_V7R { ARM, "v7r" },
	ARM_V7M { ARM, "v7m" },
	ARM_V7EM { ARM, "v7em" },
	ARM_V7VE { ARM, "v7ve" },
	ARM_V8A { ARM, "v8a" },
	ARM_V8R { ARM, "v8r" },
	ARM_V8M { ARM, "v8m" },
	ARM_V8M_MAIN { ARM, "v8m_main" },
	ARM_V8_1M_MAIN { ARM, "v8_1m_main" },
	ARM_V8_1A { ARM, "v8_1a" },
	ARM_V8_2A { ARM, "v8_2a" },
	ARM_V8_3A { ARM, "v8_3a" },
	ARM_V8_4A { ARM, "v8_4a" },
	ARM_V8_5A { ARM, "v8_5a" },
	ARM_V8_6A { ARM, "v8_6a" },
	ARM_V8_7A { ARM, "v8_7a" },
	ARM_V8_8A { ARM, "v8_8a" },
	ARM_V8_9A { ARM, "v8_9a" },
	ARM_V9A { ARM, "v9a" },
	ARM_V9_1A { ARM, "v9_1a" },
	ARM_V9_2A { ARM, "v9_2a" },
	ARM_V9_3A { ARM, "v9_3a" },
	ARM_V9_4A { ARM, "v9_4a" },
	ARM_V9_5A { ARM, "v9_5a" },
	ARM_V9_6A { ARM, "v9_6a" },
	ARM_ACLASS { ARM, "aclass" },
	ARM_RCLASS { ARM, "rclass" },
	ARM_MCLASS { ARM, "mclass" },
	ARM_DSP { ARM, "dsp" },
	ARM_THUMB2 { ARM, "thumb2" },
	ARM_THUMB_MODE { ARM, "thumb_mode" },
	ARM_NOARM { ARM, "noarm" },
	ARM_HWDIV { ARM, "hwdiv" },
	ARM_HWDIV_ARM { ARM, "hwdiv_arm" },
	ARM_NEON { ARM, "neon" },
	ARM_VFP2 { ARM, "vfp2" },
	ARM_VFP2SP { ARM, "vfp2sp" },
	ARM_VFP3 { ARM, "vfp3" },
	ARM_VFP3D16 { ARM, "vfp3d16" },
	ARM_VFP3SP { ARM, "vfp3sp" },
	ARM_VFP3D16SP { ARM, "vfp3d16sp" },
	ARM_VFP4 { ARM, "vfp4" },
	ARM_VFP4D16 { ARM, "vfp4d16" },
	ARM_VFP4SP { ARM, "vfp4sp" },
	ARM_VFP4D16SP { ARM, "vfp4d16sp" },
	ARM_FP_ARMV8 { ARM, "fp_armv8" },
	ARM_FP_ARMV8D16 { ARM, "fp_armv8d16" },
	ARM_FP_ARMV8SP { ARM, "fp_armv8sp" },
	ARM_FP_ARMV8D16SP { ARM, "fp_armv8d16sp" },
	ARM_FP16 { ARM, "fp16" },
	ARM_FP64 { ARM, "fp64" },
	ARM_FULLFP16 { ARM, "fullfp16" },
	ARM_MVE { ARM, "mve" },
	ARM_MVE_FP { ARM, "mve_fp" },
	ARM_SOFT_FLOAT { ARM, "soft_float" },
	ARM_NO_UNALIGNED_ACCESS { ARM, "no_unaligned_access" },
	// aarch64
	AARCH64_V8A { AARCH64, "v8a" },
	AARCH64_V8_1A { AARCH64, "v8_1a" },
	AARCH64_V8_2A { AARCH64, "v8_2a" },
	AARCH64_V8_3A { AARCH64, "v8_3a" },
	AARCH64_V8_4A { AARCH64, "v8_4a" },
	AARCH64_V8_5A { AARCH64, "v8_5a" },
	AARCH64_V8_6A { AARCH64, "v8_6a" },
	AARCH64_V8_7A { AARCH64, "v8_7a" },
	AARCH64_V8_8A { AARCH64, "v8_8a" },
	AARCH64_V8_9A { AARCH64, "v8_9a" },
	AARCH64_V8R { AARCH64, "v8r" },
	AARCH64_V9A { AARCH64, "v9a" },
	AARCH64_V9_1A { AARCH64, "v9_1a" },
	AARCH64_V9_2A { AARCH64, "v9_2a" },
	AARCH64_V9_3A { AARCH64, "v9_3a" },
	AARCH64_V9_4A { AARCH64, "v9_4a" },
	AARCH64_V9_5A { AARCH64, "v9_5a" },
	AARCH64_V9_6A { AARCH64, "v9_6a" },
	AARCH64_FP_ARMV8 { AARCH64, "fp_armv8" },
	AARCH64_NEON { AARCH64, "neon" },
	AARCH64_FULLFP16 { AARCH64, "fullfp16" },
	AARCH64_AES { AARCH64, "aes" },
	AARCH64_SHA2 { AARCH64, "sha2" },
	AARCH64_SHA3 { AARCH64, "sha3" },
	AARCH64_SM4 { AARCH64, "sm4" },
	AARCH64_CRC { AARCH64, "crc" },
	AARCH64_LSE { AARCH64, "lse" },
	AARCH64_RCPC { AARCH64, "rcpc" },
	AARCH64_RCPC3 { AARCH64, "rcpc3" },
	AARCH64_DOTPROD { AARCH64, "dotprod" },
	AARCH64_PAUTH { AARCH64, "pauth" },
	AARCH64_BF16 { AARCH64, "bf16" },
	AARCH64_I8MM { AARCH64, "i8mm" },
	AARCH64_SVE { AARCH64, "sve" },
	AARCH64_SVE2 { AARCH64, "sve2" },
	AARCH64_SVE_AES { AARCH64, "sve_aes" },
	AARCH64_SVE_BITPERM { AARCH64, "sve_bitperm" },
	AARCH64_SME { AARCH64, "sme" },
	AARCH64_FMV { AARCH64, "fmv" },
	AARCH64_NO_UNALIGNED_ACCESS { AARCH64, "no_unaligned_access" },
	// aarch64: the rest of generateSystemDefines' __ARM_FEATURE_* table (plan 14 stage 0)
	AARCH64_SVE2P1 { AARCH64, "sve2p1" },
	AARCH64_SVE2_SHA3 { AARCH64, "sve2_sha3" },
	AARCH64_SVE2_SM4 { AARCH64, "sve2_sm4" },
	AARCH64_SVE_B16B16 { AARCH64, "sve_b16b16" },
	AARCH64_SME2 { AARCH64, "sme2" },
	AARCH64_SME2P1 { AARCH64, "sme2p1" },
	AARCH64_SME_F16F16 { AARCH64, "sme_f16f16" },
	AARCH64_SME_B16B16 { AARCH64, "sme_b16b16" },
	AARCH64_PAUTH_LR { AARCH64, "pauth_lr" },
	AARCH64_BTI { AARCH64, "bti" },
	AARCH64_MTE { AARCH64, "mte" },
	AARCH64_F64MM { AARCH64, "f64mm" },
	AARCH64_F32MM { AARCH64, "f32mm" },
	AARCH64_FP16FML { AARCH64, "fp16fml" },
	AARCH64_LS64 { AARCH64, "ls64" },
	AARCH64_RAND { AARCH64, "rand" },
	AARCH64_MOPS { AARCH64, "mops" },
	AARCH64_D128 { AARCH64, "d128" },
	AARCH64_GCS { AARCH64, "gcs" },
	// mips
	MIPS_MIPS1 { MIPS, "mips1" },
	MIPS_MIPS2 { MIPS, "mips2" },
	MIPS_MIPS3 { MIPS, "mips3" },
	MIPS_MIPS4 { MIPS, "mips4" },
	MIPS_MIPS5 { MIPS, "mips5" },
	MIPS_MIPS32 { MIPS, "mips32" },
	MIPS_MIPS32R2 { MIPS, "mips32r2" },
	MIPS_MIPS32R3 { MIPS, "mips32r3" },
	MIPS_MIPS32R5 { MIPS, "mips32r5" },
	MIPS_MIPS32R6 { MIPS, "mips32r6" },
	MIPS_MIPS64 { MIPS, "mips64" },
	MIPS_MIPS64R2 { MIPS, "mips64r2" },
	MIPS_MIPS64R3 { MIPS, "mips64r3" },
	MIPS_MIPS64R5 { MIPS, "mips64r5" },
	MIPS_MIPS64R6 { MIPS, "mips64r6" },
	MIPS_GP64 { MIPS, "gp64" },
	MIPS_FP64 { MIPS, "fp64" },
	MIPS_FPU_S { MIPS, "fpu_s" },
	MIPS_FPU_D { MIPS, "fpu_d" },
	MIPS_NAN2008 { MIPS, "nan2008" },
	MIPS_ABS2008 { MIPS, "abs2008" },
	MIPS_SOFT_FLOAT { MIPS, "soft_float" },
	MIPS_NOODDSPREG { MIPS, "nooddspreg" },
	MIPS_NOMADD4 { MIPS, "nomadd4" },
	MIPS_NOABICALLS { MIPS, "noabicalls" },
	MIPS_MSA { MIPS, "msa" },
	MIPS_MIPS16 { MIPS, "mips16" },
	MIPS_MICROMIPS { MIPS, "micromips" },
	MIPS_DSP { MIPS, "dsp" },
	MIPS_DSPR2 { MIPS, "dspr2" },
	MIPS_DSPR3 { MIPS, "dspr3" },
	MIPS_CNMIPS { MIPS, "cnmips" },
	// riscv
	RISCV_32BIT { RISCV, "32bit" },
	RISCV_64BIT { RISCV, "64bit" },
	RISCV_I { RISCV, "i" },
	RISCV_E { RISCV, "e" },
	RISCV_M { RISCV, "m" },
	RISCV_A { RISCV, "a" },
	RISCV_F { RISCV, "f" },
	RISCV_D { RISCV, "d" },
	RISCV_Q { RISCV, "q" },
	RISCV_C { RISCV, "c" },
	RISCV_ZCA { RISCV, "zca" },
	RISCV_ZICSR { RISCV, "zicsr" },
	RISCV_ZIFENCEI { RISCV, "zifencei" },
	// sparc
	SPARC_V9 { SPARC, "v9" },
	// s390x
	S390X_VX { S390X, "vector" },
	S390X_TE { S390X, "transactional_execution" },
	// spirv
	SPIRV_V1_1 { SPIRV, "v1_1" },
	SPIRV_V1_2 { SPIRV, "v1_2" },
	SPIRV_V1_3 { SPIRV, "v1_3" },
	SPIRV_V1_4 { SPIRV, "v1_4" },
	SPIRV_V1_5 { SPIRV, "v1_5" },
	SPIRV_V1_6 { SPIRV, "v1_6" },
	// powerpc
	POWERPC_64BIT { POWERPC, "64bit" },
	POWERPC_SPE { POWERPC, "spe" },
	// wasm: every std.Target.wasm feature, in Zig declaration order (allFeaturesList order,
	// which generateSystemDefines iterates for __wasm_<name>__). Plan 14 stage 0.
	WASM_ATOMICS { WASM, "atomics" },
	WASM_BULK_MEMORY { WASM, "bulk_memory" },
	WASM_BULK_MEMORY_OPT { WASM, "bulk_memory_opt" },
	WASM_CALL_INDIRECT_OVERLONG { WASM, "call_indirect_overlong" },
	WASM_EXCEPTION_HANDLING { WASM, "exception_handling" },
	WASM_EXTENDED_CONST { WASM, "extended_const" },
	WASM_FP16 { WASM, "fp16" },
	WASM_MULTIMEMORY { WASM, "multimemory" },
	WASM_MULTIVALUE { WASM, "multivalue" },
	WASM_MUTABLE_GLOBALS { WASM, "mutable_globals" },
	WASM_NONTRAPPING_BULK_MEMORY_LEN0 { WASM, "nontrapping_bulk_memory_len0" },
	WASM_NONTRAPPING_FPTOINT { WASM, "nontrapping_fptoint" },
	WASM_REFERENCE_TYPES { WASM, "reference_types" },
	WASM_RELAXED_SIMD { WASM, "relaxed_simd" },
	WASM_SIGN_EXT { WASM, "sign_ext" },
	WASM_SIMD128 { WASM, "simd128" },
	WASM_TAIL_CALL { WASM, "tail_call" },
	WASM_WIDE_ARITHMETIC { WASM, "wide_arithmetic" },
}

<* Bit set over `Feature` (Zig Cpu.Feature.Set). *>
const usz FEATURE_WORDS = 6;

struct FeatureSet
{
	ulong[FEATURE_WORDS] bits;
}

fn bool FeatureSet.has(&self, Feature f) => (self.bits[(usz)f / 64] >> ((usz)f % 64)) & 1 != 0;
fn void FeatureSet.add(&self, Feature f) => self.bits[(usz)f / 64] |= 1UL << ((usz)f % 64);
fn void FeatureSet.remove(&self, Feature f) => self.bits[(usz)f / 64] &= ~(1UL << ((usz)f % 64));

fn void FeatureSet.add_set(&self, FeatureSet other)
{
	for (usz i = 0; i < FEATURE_WORDS; i++) self.bits[i] |= other.bits[i];
}

fn void FeatureSet.remove_set(&self, FeatureSet other)
{
	for (usz i = 0; i < FEATURE_WORDS; i++) self.bits[i] &= ~other.bits[i];
}

fn bool FeatureSet.is_empty(&self)
{
	foreach (w : self.bits) if (w) return false;
	return true;
}

fn FeatureSet feature_set(Feature[] fs)
{
	FeatureSet s;
	foreach (f : fs) s.add(f);
	return s;
}

struct FeatureDeps
{
	Feature feature;
	Feature[] implies;
}

<* Feature dependencies (from Zig std.Target knowledge, not verified by execution). *>
const FeatureDeps[*] FEATURE_DEPS = {
	// x86
	{ X86_SSE2, { X86_SSE } },
	{ X86_SSE3, { X86_SSE2 } },
	{ X86_SSSE3, { X86_SSE3 } },
	{ X86_SSE4_1, { X86_SSSE3 } },
	{ X86_SSE4_2, { X86_SSE4_1 } },
	{ X86_SSE4A, { X86_SSE3 } },
	{ X86_AVX, { X86_SSE4_2 } },
	{ X86_AVX2, { X86_AVX } },
	{ X86_F16C, { X86_AVX } },
	{ X86_FMA, { X86_AVX } },
	{ X86_AVX512F, { X86_AVX2, X86_F16C, X86_FMA } },
	{ X86_AVX512BW, { X86_AVX512F } },
	{ X86_AVX512CD, { X86_AVX512F } },
	{ X86_AVX512DQ, { X86_AVX512F } },
	{ X86_AVX512VL, { X86_AVX512F } },
	{ X86_AES, { X86_SSE2 } },
	{ X86_PCLMUL, { X86_SSE2 } },
	{ X86_SHA, { X86_SSE2 } },
	{ X86_XSAVEOPT, { X86_XSAVE } },
	{ X86_XSAVEC, { X86_XSAVE } },
	{ X86_XSAVES, { X86_XSAVE } },
	// arm version levels
	{ ARM_HAS_V5T, { ARM_HAS_V4T } },
	{ ARM_HAS_V5TE, { ARM_HAS_V5T } },
	{ ARM_HAS_V6, { ARM_HAS_V5TE } },
	{ ARM_HAS_V6K, { ARM_HAS_V6 } },
	{ ARM_HAS_V6M, { ARM_HAS_V6 } },
	{ ARM_HAS_V6T2, { ARM_HAS_V6K, ARM_HAS_V8M, ARM_THUMB2 } },
	{ ARM_HAS_V7, { ARM_HAS_V6T2 } },
	{ ARM_HAS_V8M, { ARM_HAS_V6M } },
	{ ARM_HAS_V8M_MAIN, { ARM_HAS_V7 } },
	{ ARM_HAS_V8_1M_MAIN, { ARM_HAS_V8M_MAIN } },
	{ ARM_HAS_V8, { ARM_HAS_V7 } },
	{ ARM_HAS_V8_1A, { ARM_HAS_V8 } },
	{ ARM_HAS_V8_2A, { ARM_HAS_V8_1A } },
	{ ARM_HAS_V8_3A, { ARM_HAS_V8_2A } },
	{ ARM_HAS_V8_4A, { ARM_HAS_V8_3A } },
	{ ARM_HAS_V8_5A, { ARM_HAS_V8_4A } },
	{ ARM_HAS_V8_6A, { ARM_HAS_V8_5A } },
	{ ARM_HAS_V8_7A, { ARM_HAS_V8_6A } },
	{ ARM_HAS_V8_8A, { ARM_HAS_V8_7A } },
	{ ARM_HAS_V8_9A, { ARM_HAS_V8_8A } },
	{ ARM_HAS_V9A, { ARM_HAS_V8_5A } },
	{ ARM_HAS_V9_1A, { ARM_HAS_V8_6A, ARM_HAS_V9A } },
	{ ARM_HAS_V9_2A, { ARM_HAS_V8_7A, ARM_HAS_V9_1A } },
	{ ARM_HAS_V9_3A, { ARM_HAS_V8_8A, ARM_HAS_V9_2A } },
	{ ARM_HAS_V9_4A, { ARM_HAS_V8_9A, ARM_HAS_V9_3A } },
	{ ARM_HAS_V9_5A, { ARM_HAS_V9_4A } },
	{ ARM_HAS_V9_6A, { ARM_HAS_V9_5A } },
	// arm architectures
	{ ARM_V4T, { ARM_HAS_V4T } },
	{ ARM_V5T, { ARM_HAS_V5T } },
	{ ARM_V5TE, { ARM_HAS_V5TE } },
	{ ARM_V5TEJ, { ARM_HAS_V5TE } },
	{ ARM_V6, { ARM_HAS_V6, ARM_DSP } },
	{ ARM_V6J, { ARM_V6 } },
	{ ARM_V6K, { ARM_HAS_V6K } },
	{ ARM_V6KZ, { ARM_HAS_V6K } },
	{ ARM_V6M, { ARM_HAS_V6M, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM } },
	{ ARM_V6SM, { ARM_HAS_V6M, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM } },
	{ ARM_V6T2, { ARM_HAS_V6T2, ARM_DSP } },
	{ ARM_V7A, { ARM_HAS_V7, ARM_ACLASS, ARM_DSP, ARM_NEON } },
	{ ARM_V7R, { ARM_HAS_V7, ARM_RCLASS, ARM_DSP, ARM_HWDIV } },
	{ ARM_V7M, { ARM_HAS_V7, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM, ARM_HWDIV } },
	{ ARM_V7EM, { ARM_HAS_V7, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM, ARM_HWDIV, ARM_DSP } },
	{ ARM_V7VE, { ARM_HAS_V7, ARM_ACLASS, ARM_DSP, ARM_NEON, ARM_HWDIV, ARM_HWDIV_ARM } },
	{ ARM_V8A, { ARM_HAS_V8, ARM_ACLASS, ARM_DSP, ARM_FP_ARMV8, ARM_NEON, ARM_HWDIV, ARM_HWDIV_ARM } },
	{ ARM_V8R, { ARM_HAS_V8, ARM_RCLASS, ARM_DSP, ARM_FP_ARMV8, ARM_NEON, ARM_HWDIV, ARM_HWDIV_ARM } },
	{ ARM_V8M, { ARM_HAS_V8M, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM, ARM_HWDIV } },
	{ ARM_V8M_MAIN, { ARM_HAS_V8M_MAIN, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM, ARM_HWDIV } },
	{ ARM_V8_1M_MAIN, { ARM_HAS_V8_1M_MAIN, ARM_MCLASS, ARM_THUMB_MODE, ARM_NOARM, ARM_HWDIV } },
	{ ARM_V8_1A, { ARM_HAS_V8_1A, ARM_V8A } },
	{ ARM_V8_2A, { ARM_HAS_V8_2A, ARM_V8A } },
	{ ARM_V8_3A, { ARM_HAS_V8_3A, ARM_V8A } },
	{ ARM_V8_4A, { ARM_HAS_V8_4A, ARM_V8A } },
	{ ARM_V8_5A, { ARM_HAS_V8_5A, ARM_V8A } },
	{ ARM_V8_6A, { ARM_HAS_V8_6A, ARM_V8A } },
	{ ARM_V8_7A, { ARM_HAS_V8_7A, ARM_V8A } },
	{ ARM_V8_8A, { ARM_HAS_V8_8A, ARM_V8A } },
	{ ARM_V8_9A, { ARM_HAS_V8_9A, ARM_V8A } },
	{ ARM_V9A, { ARM_HAS_V9A, ARM_V8A } },
	{ ARM_V9_1A, { ARM_HAS_V9_1A, ARM_V8A } },
	{ ARM_V9_2A, { ARM_HAS_V9_2A, ARM_V8A } },
	{ ARM_V9_3A, { ARM_HAS_V9_3A, ARM_V8A } },
	{ ARM_V9_4A, { ARM_HAS_V9_4A, ARM_V8A } },
	{ ARM_V9_5A, { ARM_HAS_V9_5A, ARM_V8A } },
	{ ARM_V9_6A, { ARM_HAS_V9_6A, ARM_V8A } },
	// arm FP chain
	{ ARM_NEON, { ARM_VFP3 } },
	{ ARM_FP_ARMV8, { ARM_FP_ARMV8D16, ARM_FP_ARMV8SP, ARM_VFP4 } },
	{ ARM_FP_ARMV8D16, { ARM_FP_ARMV8D16SP, ARM_VFP4D16 } },
	{ ARM_FP_ARMV8SP, { ARM_FP_ARMV8D16SP, ARM_VFP4SP } },
	{ ARM_FP_ARMV8D16SP, { ARM_VFP4D16SP } },
	{ ARM_VFP4, { ARM_VFP3, ARM_VFP4D16, ARM_VFP4SP } },
	{ ARM_VFP4D16, { ARM_VFP3D16, ARM_VFP4D16SP } },
	{ ARM_VFP4SP, { ARM_VFP3SP, ARM_VFP4D16SP } },
	{ ARM_VFP4D16SP, { ARM_VFP3D16SP, ARM_FP16 } },
	{ ARM_VFP3, { ARM_VFP2, ARM_VFP3D16, ARM_VFP3SP } },
	{ ARM_VFP3D16, { ARM_VFP2, ARM_VFP3D16SP, ARM_FP64 } },
	{ ARM_VFP3SP, { ARM_VFP3D16SP } },
	{ ARM_VFP3D16SP, { ARM_VFP2SP } },
	{ ARM_VFP2, { ARM_VFP2SP, ARM_FP64 } },
	{ ARM_FULLFP16, { ARM_FP_ARMV8D16SP } },
	{ ARM_MVE_FP, { ARM_MVE, ARM_FULLFP16 } },
	{ ARM_MVE, { ARM_DSP } },
	// aarch64
	{ AARCH64_V8A, { AARCH64_FP_ARMV8, AARCH64_NEON } },
	{ AARCH64_V8_1A, { AARCH64_V8A, AARCH64_CRC, AARCH64_LSE } },
	{ AARCH64_V8_2A, { AARCH64_V8_1A } },
	{ AARCH64_V8_3A, { AARCH64_V8_2A, AARCH64_PAUTH, AARCH64_RCPC } },
	{ AARCH64_V8_4A, { AARCH64_V8_3A, AARCH64_DOTPROD } },
	{ AARCH64_V8_5A, { AARCH64_V8_4A } },
	{ AARCH64_V8_6A, { AARCH64_V8_5A, AARCH64_BF16, AARCH64_I8MM } },
	{ AARCH64_V8_7A, { AARCH64_V8_6A } },
	{ AARCH64_V8_8A, { AARCH64_V8_7A } },
	{ AARCH64_V8_9A, { AARCH64_V8_8A } },
	{ AARCH64_V9A, { AARCH64_V8_5A, AARCH64_SVE2 } },
	{ AARCH64_V9_1A, { AARCH64_V8_6A, AARCH64_V9A } },
	{ AARCH64_V9_2A, { AARCH64_V8_7A, AARCH64_V9_1A } },
	{ AARCH64_V9_3A, { AARCH64_V8_8A, AARCH64_V9_2A } },
	{ AARCH64_V9_4A, { AARCH64_V8_9A, AARCH64_V9_3A } },
	{ AARCH64_V9_5A, { AARCH64_V9_4A } },
	{ AARCH64_V9_6A, { AARCH64_V9_5A } },
	{ AARCH64_V8R, { AARCH64_CRC, AARCH64_LSE, AARCH64_DOTPROD, AARCH64_RCPC, AARCH64_PAUTH, AARCH64_FP_ARMV8 } },
	{ AARCH64_NEON, { AARCH64_FP_ARMV8 } },
	{ AARCH64_FULLFP16, { AARCH64_FP_ARMV8 } },
	{ AARCH64_AES, { AARCH64_NEON } },
	{ AARCH64_SHA2, { AARCH64_NEON } },
	{ AARCH64_SHA3, { AARCH64_SHA2 } },
	{ AARCH64_SM4, { AARCH64_NEON } },
	{ AARCH64_DOTPROD, { AARCH64_NEON } },
	{ AARCH64_SVE, { AARCH64_FULLFP16 } },
	{ AARCH64_SVE2, { AARCH64_SVE } },
	{ AARCH64_SVE_AES, { AARCH64_AES } },
	{ AARCH64_SVE_BITPERM, { AARCH64_SVE } },
	{ AARCH64_SME, { AARCH64_BF16, AARCH64_FULLFP16 } },
	// mips
	{ MIPS_MIPS2, { MIPS_MIPS1 } },
	{ MIPS_MIPS3, { MIPS_MIPS2, MIPS_FP64, MIPS_GP64 } },
	{ MIPS_MIPS4, { MIPS_MIPS3 } },
	{ MIPS_MIPS5, { MIPS_MIPS4 } },
	{ MIPS_MIPS32, { MIPS_MIPS2 } },
	{ MIPS_MIPS32R2, { MIPS_MIPS32 } },
	{ MIPS_MIPS32R3, { MIPS_MIPS32R2 } },
	{ MIPS_MIPS32R5, { MIPS_MIPS32R3 } },
	{ MIPS_MIPS32R6, { MIPS_MIPS32R5, MIPS_FP64, MIPS_NAN2008, MIPS_ABS2008 } },
	{ MIPS_MIPS64, { MIPS_MIPS32, MIPS_MIPS5 } },
	{ MIPS_MIPS64R2, { MIPS_MIPS64, MIPS_MIPS32R2 } },
	{ MIPS_MIPS64R3, { MIPS_MIPS64R2, MIPS_MIPS32R3 } },
	{ MIPS_MIPS64R5, { MIPS_MIPS64R3, MIPS_MIPS32R5 } },
	{ MIPS_MIPS64R6, { MIPS_MIPS64R5, MIPS_MIPS32R6 } },
	{ MIPS_DSPR2, { MIPS_DSP } },
	{ MIPS_DSPR3, { MIPS_DSPR2 } },
	// riscv
	{ RISCV_D, { RISCV_F } },
	{ RISCV_Q, { RISCV_D } },
	{ RISCV_F, { RISCV_ZICSR } },
	{ RISCV_C, { RISCV_ZCA } },
	// spirv
	{ SPIRV_V1_2, { SPIRV_V1_1 } },
	{ SPIRV_V1_3, { SPIRV_V1_2 } },
	{ SPIRV_V1_4, { SPIRV_V1_3 } },
	{ SPIRV_V1_5, { SPIRV_V1_4 } },
	{ SPIRV_V1_6, { SPIRV_V1_5 } },
	// wasm
	{ WASM_BULK_MEMORY, { WASM_BULK_MEMORY_OPT } },
	{ WASM_REFERENCE_TYPES, { WASM_CALL_INDIRECT_OVERLONG } },
};

<* Cpu.Feature.Set.populateDependencies: add everything implied, to a fixpoint. *>
fn void FeatureSet.populate_dependencies(&self)
{
	bool changed = true;
	while (changed)
	{
		changed = false;
		foreach (dep : FEATURE_DEPS)
		{
			if (!self.has(dep.feature)) continue;
			foreach (f : dep.implies)
			{
				if (self.has(f)) continue;
				self.add(f);
				changed = true;
			}
		}
	}
}

<*
 A CPU model: Zig name, LLVM name, family and its (unexpanded) feature list.
 Models with family OTHER are architecture-independent.
*>
enum CpuModel : ushort (String name, String llvm_name, FeatureFamily family, Feature[] features)
{
	<* Driver.parseTarget's `{ .name = "empty", .llvm_name = null, .features = .empty }`. *>
	EMPTY { "empty", "", OTHER, {} },
	GENERIC { "generic", "generic", OTHER, {} },
	// x86
	I386 { "i386", "i386", X86, { X86_X87 } },
	I486 { "i486", "i486", X86, { X86_X87 } },
	I586 { "i586", "i586", X86, { X86_CX8, X86_X87 } },
	I686 { "i686", "i686", X86, { X86_CMOV, X86_CX8, X86_NOPL, X86_X87 } },
	PENTIUM4 { "pentium4", "pentium4", X86, { X86_CMOV, X86_CX8, X86_FXSR, X86_MMX, X86_NOPL, X86_SSE2, X86_X87 } },
	X86_64 { "x86_64", "x86-64", X86, { X86_64BIT, X86_CMOV, X86_CX8, X86_FXSR, X86_MMX, X86_NOPL, X86_SSE2, X86_X87 } },
	X86_64_V2 { "x86_64_v2", "x86-64-v2", X86, { X86_64BIT, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_FXSR, X86_MMX, X86_NOPL, X86_POPCNT, X86_SAHF, X86_SSE4_2, X86_X87 } },
	X86_64_V3 { "x86_64_v3", "x86-64-v3", X86, { X86_64BIT, X86_AVX2, X86_BMI, X86_BMI2, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_F16C, X86_FMA, X86_FXSR, X86_LZCNT, X86_MMX, X86_MOVBE, X86_NOPL, X86_POPCNT, X86_SAHF, X86_X87, X86_XSAVE } },
	X86_64_V4 { "x86_64_v4", "x86-64-v4", X86, { X86_64BIT, X86_AVX512BW, X86_AVX512CD, X86_AVX512DQ, X86_AVX512VL, X86_BMI, X86_BMI2, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_FXSR, X86_LZCNT, X86_MMX, X86_MOVBE, X86_NOPL, X86_POPCNT, X86_SAHF, X86_X87, X86_XSAVE } },
	CORE2 { "core2", "core2", X86, { X86_64BIT, X86_CMOV, X86_CX8, X86_CX16, X86_FXSR, X86_MMX, X86_NOPL, X86_SAHF, X86_SSSE3, X86_X87 } },
	NEHALEM { "nehalem", "nehalem", X86, { X86_64BIT, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_FXSR, X86_MMX, X86_NOPL, X86_POPCNT, X86_SAHF, X86_SSE4_2, X86_X87 } },
	BTVER2 { "btver2", "btver2", X86, { X86_64BIT, X86_AES, X86_AVX, X86_BMI, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_F16C, X86_FXSR, X86_LZCNT, X86_MMX, X86_MOVBE, X86_NOPL, X86_PCLMUL, X86_POPCNT, X86_PRFCHW, X86_SAHF, X86_SSE4A, X86_X87, X86_XSAVEOPT } },
	ZNVER2 { "znver2", "znver2", X86, { X86_64BIT, X86_ADX, X86_AES, X86_AVX2, X86_BMI, X86_BMI2, X86_CLFLUSHOPT, X86_CMOV, X86_CX8, X86_CX16, X86_CRC32, X86_F16C, X86_FMA, X86_FSGSBASE, X86_FXSR, X86_LZCNT, X86_MMX, X86_MOVBE, X86_NOPL, X86_PCLMUL, X86_POPCNT, X86_PRFCHW, X86_RDRND, X86_RDSEED, X86_SAHF, X86_SHA, X86_SSE4A, X86_X87, X86_XSAVEC, X86_XSAVEOPT, X86_XSAVES } },
	// arm
	ARM_GENERIC { "generic", "generic", ARM, {} },
	ARM_BASELINE { "baseline", "generic", ARM, { ARM_V7A } },
	ARM7TDMI { "arm7tdmi", "arm7tdmi", ARM, { ARM_V4T } },
	ARM710T { "arm710t", "arm710t", ARM, { ARM_V4T } },
	ARM10TDMI { "arm10tdmi", "arm10tdmi", ARM, { ARM_V5T } },
	ARM1020E { "arm1020e", "arm1020e", ARM, { ARM_V5TE } },
	ARM1022E { "arm1022e", "arm1022e", ARM, { ARM_V5TE } },
	ARM926EJ_S { "arm926ej_s", "arm926ej-s", ARM, { ARM_V5TE } },
	ARM1136J_S { "arm1136j_s", "arm1136j-s", ARM, { ARM_V6 } },
	ARM1136JF_S { "arm1136jf_s", "arm1136jf-s", ARM, { ARM_V6, ARM_VFP2 } },
	MPCORE { "mpcore", "mpcore", ARM, { ARM_V6K, ARM_VFP2 } },
	ARM1156T2_S { "arm1156t2_s", "arm1156t2-s", ARM, { ARM_V6T2 } },
	ARM1176JZF_S { "arm1176jzf_s", "arm1176jzf-s", ARM, { ARM_V6KZ, ARM_VFP2 } },
	STRONGARM { "strongarm", "strongarm", ARM, { ARM_V4 } },
	CORTEX_M0 { "cortex_m0", "cortex-m0", ARM, { ARM_V6M } },
	CORTEX_M3 { "cortex_m3", "cortex-m3", ARM, { ARM_V7M } },
	CORTEX_M4 { "cortex_m4", "cortex-m4", ARM, { ARM_V7EM, ARM_VFP4D16SP } },
	CORTEX_M33 { "cortex_m33", "cortex-m33", ARM, { ARM_V8M_MAIN, ARM_DSP, ARM_FP_ARMV8D16SP } },
	CORTEX_R4 { "cortex_r4", "cortex-r4", ARM, { ARM_V7R } },
	CORTEX_A7 { "cortex_a7", "cortex-a7", ARM, { ARM_V7A, ARM_VFP4, ARM_HWDIV, ARM_HWDIV_ARM } },
	CORTEX_A8 { "cortex_a8", "cortex-a8", ARM, { ARM_V7A } },
	CORTEX_A9 { "cortex_a9", "cortex-a9", ARM, { ARM_V7A, ARM_FP16 } },
	ARM_CORTEX_A53 { "cortex_a53", "cortex-a53", ARM, { ARM_V8A } },
	// aarch64
	AARCH64_GENERIC { "generic", "generic", AARCH64, { AARCH64_FP_ARMV8, AARCH64_NEON } },
	APPLE_A7 { "apple_a7", "apple-a7", AARCH64, { AARCH64_V8A, AARCH64_AES, AARCH64_SHA2 } },
	APPLE_M1 { "apple_m1", "apple-m1", AARCH64, { AARCH64_V8_5A, AARCH64_AES, AARCH64_SHA3, AARCH64_FULLFP16 } },
	APPLE_M2 { "apple_m2", "apple-m2", AARCH64, { AARCH64_V8_6A, AARCH64_AES, AARCH64_SHA3, AARCH64_FULLFP16 } },
	APPLE_S4 { "apple_s4", "apple-s4", AARCH64, { AARCH64_V8_3A, AARCH64_AES, AARCH64_SHA2, AARCH64_FULLFP16 } },
	AARCH64_CORTEX_A53 { "cortex_a53", "cortex-a53", AARCH64, { AARCH64_V8A, AARCH64_CRC, AARCH64_AES, AARCH64_SHA2 } },
	// mips
	MIPS1 { "mips1", "mips1", MIPS, { MIPS_MIPS1 } },
	MIPS2 { "mips2", "mips2", MIPS, { MIPS_MIPS2 } },
	MIPS3 { "mips3", "mips3", MIPS, { MIPS_MIPS3 } },
	MIPS4 { "mips4", "mips4", MIPS, { MIPS_MIPS4 } },
	MIPS32 { "mips32", "mips32", MIPS, { MIPS_MIPS32 } },
	MIPS32R2 { "mips32r2", "mips32r2", MIPS, { MIPS_MIPS32R2 } },
	MIPS32R3 { "mips32r3", "mips32r3", MIPS, { MIPS_MIPS32R3 } },
	MIPS32R5 { "mips32r5", "mips32r5", MIPS, { MIPS_MIPS32R5 } },
	MIPS32R6 { "mips32r6", "mips32r6", MIPS, { MIPS_MIPS32R6 } },
	MIPS64 { "mips64", "mips64", MIPS, { MIPS_MIPS64 } },
	MIPS64R2 { "mips64r2", "mips64r2", MIPS, { MIPS_MIPS64R2 } },
	MIPS64R3 { "mips64r3", "mips64r3", MIPS, { MIPS_MIPS64R3 } },
	MIPS64R5 { "mips64r5", "mips64r5", MIPS, { MIPS_MIPS64R5 } },
	MIPS64R6 { "mips64r6", "mips64r6", MIPS, { MIPS_MIPS64R6 } },
	OCTEON { "octeon", "octeon", MIPS, { MIPS_MIPS64R2, MIPS_CNMIPS } },
	OCTEONP { "octeon+", "octeon+", MIPS, { MIPS_MIPS64R2, MIPS_CNMIPS } },
	P5600 { "p5600", "p5600", MIPS, { MIPS_MIPS32R5 } },
	I6400 { "i6400", "i6400", MIPS, { MIPS_MIPS64R6 } },
	I6500 { "i6500", "i6500", MIPS, { MIPS_MIPS64R6 } },
	// riscv
	GENERIC_RV32 { "generic_rv32", "generic-rv32", RISCV, { RISCV_32BIT, RISCV_I } },
	GENERIC_RV64 { "generic_rv64", "generic-rv64", RISCV, { RISCV_64BIT, RISCV_I } },
	BASELINE_RV32 { "baseline_rv32", "", RISCV, { RISCV_32BIT, RISCV_A, RISCV_C, RISCV_D, RISCV_I, RISCV_M } },
	BASELINE_RV64 { "baseline_rv64", "", RISCV, { RISCV_64BIT, RISCV_A, RISCV_C, RISCV_D, RISCV_I, RISCV_M } },
	// sparc
	SPARC_V8 { "v8", "v8", SPARC, {} },
	SPARC_V9 { "v9", "v9", SPARC, { SPARC_V9 } },
	// powerpc
	PPC { "ppc", "ppc", POWERPC, {} },
	PPC32 { "ppc32", "ppc32", POWERPC, {} },
	PPC64 { "ppc64", "ppc64", POWERPC, { POWERPC_64BIT } },
	PPC64LE { "ppc64le", "ppc64le", POWERPC, { POWERPC_64BIT } },
	// s390x
	ARCH8 { "arch8", "arch8", S390X, {} },
	// wasm
	WASM_MVP { "mvp", "mvp", WASM, {} },
	WASM_GENERIC { "generic", "generic", WASM, { WASM_BULK_MEMORY, WASM_MULTIVALUE, WASM_MUTABLE_GLOBALS, WASM_NONTRAPPING_FPTOINT, WASM_REFERENCE_TYPES, WASM_SIGN_EXT } },
	WASM_LIME1 { "lime1", "lime1", WASM, { WASM_BULK_MEMORY_OPT, WASM_CALL_INDIRECT_OVERLONG, WASM_EXTENDED_CONST, WASM_MULTIVALUE, WASM_MUTABLE_GLOBALS, WASM_NONTRAPPING_FPTOINT, WASM_SIGN_EXT } },
	// architectures whose family is not tracked: models named by Model.generic/baseline or test/records
	AVR1 { "avr1", "avr1", OTHER, {} },
	AVR2 { "avr2", "avr2", OTHER, {} },
	MSP430_MODEL { "msp430", "msp430", OTHER, {} },
	HEXAGONV60 { "hexagonv60", "hexagonv60", OTHER, {} },
	HEXAGONV68 { "hexagonv68", "hexagonv68", OTHER, {} },
	CK810 { "ck810", "ck810", OTHER, {} },
	LANAI_V11 { "v11", "v11", OTHER, {} },
	M68000 { "M68000", "M68000", OTHER, {} },
	SM_20 { "sm_20", "sm_20", OTHER, {} },
	SM_52 { "sm_52", "sm_52", OTHER, {} },
	BPF_V1 { "v1", "v1", OTHER, {} },
	LA64V1_0 { "la64v1_0", "la64v1.0", OTHER, {} },
	GENERIC_LA32 { "generic_la32", "generic-la32", OTHER, {} },
	GENERIC_LA64 { "generic_la64", "generic-la64", OTHER, {} },
	XS1B_GENERIC { "xs1b_generic", "xs1b-generic", OTHER, {} },
	GFX600 { "gfx600", "gfx600", OTHER, {} },
}

<* The model's features with dependencies populated (Model.toCpu). *>
fn FeatureSet CpuModel.feature_set(self)
{
	FeatureSet s = feature_set(self.features);
	s.populate_dependencies();
	return s;
}

<* Model families that only apply to specific architectures within the OTHER family. *>
fn bool other_model_matches(CpuModel m, Arch arch) @local
{
	switch (m)
	{
		case EMPTY:
		case GENERIC: return true;
		case AVR1:
		case AVR2: return arch == AVR;
		case MSP430_MODEL: return arch == MSP430;
		case HEXAGONV60:
		case HEXAGONV68: return arch == HEXAGON;
		case CK810: return arch == CSKY;
		case LANAI_V11: return arch == LANAI;
		case M68000: return arch == M68K;
		case SM_20:
		case SM_52: return arch == NVPTX || arch == NVPTX64;
		case BPF_V1: return arch.is_bpf();
		case LA64V1_0:
		case GENERIC_LA32:
		case GENERIC_LA64: return arch.is_loongarch();
		case XS1B_GENERIC: return arch == XCORE;
		case GFX600: return arch == AMDGCN;
		default: return false;
	}
}

<* Cpu.Arch.parseCpuModel: an exact Zig model name of this architecture. *>
fn CpuModel? parse_cpu_model(Arch arch, String name)
{
	FeatureFamily fam = arch.family();
	if (fam != OTHER)
	{
		foreach (m : CpuModel::values)
		{
			if (m.family == fam && m.name == name) return m;
		}
	}
	foreach (m : CpuModel::values)
	{
		if (m.family == OTHER && m != EMPTY && m.name == name && other_model_matches(m, arch)) return m;
	}
	return UNKNOWN_CPU_MODEL~;
}

<* A Zig feature name of this architecture's family. *>
fn Feature? parse_feature_name(Arch arch, String name)
{
	FeatureFamily fam = arch.family();
	foreach (f : Feature::values)
	{
		if (f.family == fam && f.name == name) return f;
	}
	return UNKNOWN_CPU_FEATURE~;
}

<* Cpu.Model.generic. *>
fn CpuModel generic_model(Arch arch)
{
	switch (arch)
	{
		case AMDGCN: return GFX600;
		case AVR: return AVR1;
		case LOONGARCH32: return GENERIC_LA32;
		case LOONGARCH64: return GENERIC_LA64;
		case MIPS:
		case MIPSEL: return MIPS32;
		case MIPS64:
		case MIPS64EL: return MIPS64;
		case NVPTX:
		case NVPTX64: return SM_20;
		case POWERPC:
		case POWERPCLE: return PPC;
		case POWERPC64:
		case POWERPC64LE: return PPC64;
		case RISCV32:
		case RISCV32BE: return GENERIC_RV32;
		case RISCV64:
		case RISCV64BE: return GENERIC_RV64;
		case SPARC64: return SPARC_V9; // SPARC can only be 64-bit from v9 and up.
		case WASM32:
		case WASM64: return WASM_MVP;
		case X86: return I386;
		case X86_64: return X86_64;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return ARM_GENERIC;
		case AARCH64:
		case AARCH64_BE: return AARCH64_GENERIC;
		case MSP430: return MSP430_MODEL;
		default: return GENERIC;
	}
}

<* Cpu.Model.baseline. *>
fn CpuModel baseline_model(Arch arch, OsTag os)
{
	switch (arch)
	{
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return ARM_BASELINE;
		case AARCH64:
			switch (os)
			{
				case DRIVERKIT:
				case MACOS: return APPLE_M1;
				case IOS:
				case TVOS: return APPLE_A7;
				case VISIONOS: return APPLE_M2;
				case WATCHOS: return APPLE_S4;
				default: return generic_model(arch);
			}
		case AVR: return AVR2;
		case BPFEL:
		case BPFEB: return BPF_V1;
		case CSKY: return CK810; // gcc/clang do not have a generic csky model.
		case HEXAGON: return HEXAGONV68; // gcc/clang do not have a generic hexagon model.
		case LANAI: return LANAI_V11; // clang does not have a generic lanai model.
		case LOONGARCH64: return LA64V1_0;
		case M68K: return M68000;
		case MIPS:
		case MIPSEL: return MIPS32R2;
		case MIPS64:
		case MIPS64EL: return MIPS64R2;
		case MSP430: return MSP430_MODEL;
		case NVPTX:
		case NVPTX64: return SM_52;
		case POWERPC64LE: return PPC64LE;
		case RISCV32:
		case RISCV32BE: return BASELINE_RV32;
		case RISCV64:
		case RISCV64BE: return BASELINE_RV64;
		case S390X: return ARCH8; // gcc/clang do not have a generic s390x model.
		case SPARC: return SPARC_V9; // glibc does not work with 'plain' v8.
		case X86: return PENTIUM4;
		case X86_64:
			switch (os)
			{
				case DRIVERKIT: return NEHALEM;
				case IOS:
				case MACOS:
				case TVOS:
				case VISIONOS:
				case WATCHOS: return CORE2;
				case PS4: return BTVER2;
				case PS5: return ZNVER2;
				default: return generic_model(arch);
			}
		case XCORE: return XS1B_GENERIC;
		case WASM32:
		case WASM64: return WASM_LIME1;
		default: return generic_model(arch);
	}
}

<* SubArch.toFeature. *>
fn Feature? SubArch.to_feature(self, Arch arch)
{
	// if (arch.isPowerPC()) { if (sub == .powerpc_spe) return spe; } -- commented out in Zig
	if (arch.is_mips32()) return MIPS_MIPS32R6;
	if (arch.is_mips64()) return MIPS_MIPS64R6;
	if (arch.is_spirv())
	{
		switch (self)
		{
			case SPIRV_V11: return SPIRV_V1_1;
			case SPIRV_V12: return SPIRV_V1_2;
			case SPIRV_V13: return SPIRV_V1_3;
			case SPIRV_V14: return SPIRV_V1_4;
			case SPIRV_V15: return SPIRV_V1_5;
			case SPIRV_V16: return SPIRV_V1_6;
			default: return UNKNOWN_CPU_FEATURE~;
		}
	}
	if (arch.is_aarch64())
	{
		switch (self)
		{
			case ARM_V8_1A: return AARCH64_V8_1A;
			case ARM_V8_2A: return AARCH64_V8_2A;
			case ARM_V8_3A: return AARCH64_V8_3A;
			case ARM_V8_4A: return AARCH64_V8_4A;
			case ARM_V8_5A: return AARCH64_V8_5A;
			case ARM_V8_6A: return AARCH64_V8_6A;
			case ARM_V8_7A: return AARCH64_V8_7A;
			case ARM_V8_8A: return AARCH64_V8_8A;
			case ARM_V8_9A: return AARCH64_V8_9A;
			case ARM_V8R: return AARCH64_V8R;
			case ARM_V9: return AARCH64_V9A;
			case ARM_V9_1A: return AARCH64_V9_1A;
			case ARM_V9_2A: return AARCH64_V9_2A;
			case ARM_V9_3A: return AARCH64_V9_3A;
			case ARM_V9_4A: return AARCH64_V9_4A;
			case ARM_V9_5A: return AARCH64_V9_5A;
			case ARM_V9_6A: return AARCH64_V9_6A;
			default: return UNKNOWN_CPU_FEATURE~;
		}
	}
	if (arch.is_arm())
	{
		switch (self)
		{
			case ARM_V4T: return ARM_V4T;
			case ARM_V5: return ARM_V5T;
			case ARM_V5TE: return ARM_V5TE;
			case ARM_V6: return ARM_V6;
			case ARM_V6K: return ARM_V6K;
			case ARM_V6M: return ARM_V6M;
			case ARM_V6T2: return ARM_V6T2;
			case ARM_V7: return ARM_V7A;
			case ARM_V7A: return ARM_V7A;
			case ARM_V7R: return ARM_V7R;
			case ARM_V7EM: return ARM_V7EM;
			case ARM_V7M: return ARM_V7M;
			case ARM_V7VE: return ARM_V7VE;
			case ARM_V8: return ARM_V8A;
			case ARM_V8R: return ARM_V8R;
			case ARM_V8_1A: return ARM_V8_1A;
			case ARM_V8_1M_MAINLINE: return ARM_V8_1M_MAIN;
			case ARM_V8_2A: return ARM_V8_2A;
			case ARM_V8_3A: return ARM_V8_3A;
			case ARM_V8_4A: return ARM_V8_4A;
			case ARM_V8_5A: return ARM_V8_5A;
			case ARM_V8_6A: return ARM_V8_6A;
			case ARM_V8_7A: return ARM_V8_7A;
			case ARM_V8_8A: return ARM_V8_8A;
			case ARM_V8_9A: return ARM_V8_9A;
			case ARM_V8M_BASELINE: return ARM_V8M;
			case ARM_V8M_MAINLINE: return ARM_V8M_MAIN;
			case ARM_V9: return ARM_V9A;
			case ARM_V9_1A: return ARM_V9_1A;
			case ARM_V9_2A: return ARM_V9_2A;
			case ARM_V9_3A: return ARM_V9_3A;
			case ARM_V9_4A: return ARM_V9_4A;
			case ARM_V9_5A: return ARM_V9_5A;
			case ARM_V9_6A: return ARM_V9_6A;
			default: return UNKNOWN_CPU_FEATURE~; // arm_v7k, arm_v7s and non-ARM subarches
		}
	}
	return UNKNOWN_CPU_FEATURE~;
}

<* SubArch.toCpuModel. *>
fn CpuModel? SubArch.to_cpu_model(self, Arch arch)
{
	if (arch.is_arm())
	{
		switch (self)
		{
			case ARM_V4T: return ARM7TDMI;
			case ARM_V5: return ARM10TDMI;
			case ARM_V5TE: return ARM1022E;
			case ARM_V6: return ARM1136JF_S;
			case ARM_V6K: return MPCORE;
			case ARM_V6T2: return ARM1156T2_S;
			case ARM_V6M: return CORTEX_M0;
			case ARM_V7R: return CORTEX_R4;
			case ARM_V7M: return CORTEX_M3;
			case ARM_V7EM: return CORTEX_M4;
			default: return UNKNOWN_CPU_MODEL~;
		}
	}
	if (arch.is_mips32() && self == MIPS_R6) return MIPS32R6;
	if (arch.is_mips64() && self == MIPS_R6) return MIPS64R6;
	return UNKNOWN_CPU_MODEL~;
}

<*
 Target.cpuModelForTargetQuadruple: the CPU model based on arch, os, abi and
 vendor. A missing OS or ABI falls back to the host's (`h`), as Zig's does
 with `builtin`.
*>
fn CpuModel? cpu_model_for_target_quadruple(Arch arch, bool has_os, OsTag opt_os, bool has_abi, Abi opt_abi, Vendor vendor, bool has_sub_arch, SubArch sub, Host h)
{
	OsTag os_tag = has_os ? opt_os : h.os;
	Abi abi = has_abi ? opt_abi : h.abi;
	switch (arch)
	{
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB:
			if (has_sub_arch)
			{
				switch (os_tag)
				{
					case FREEBSD:
					case NETBSD:
					case OPENBSD:
					case HAIKU:
						if (sub == ARM_V6) return ARM1176JZF_S;
						if (sub == ARM_V7) return CORTEX_A8;
					case WINDOWS:
						// clang: `parseArchVersion(MArch) <= 7`
						switch (sub)
						{
							case ARM_V4T:
							case ARM_V5:
							case ARM_V5TE:
							case ARM_V6:
							case ARM_V6K:
							case ARM_V6M:
							case ARM_V6T2:
							case ARM_V7:
							case ARM_V7A:
							case ARM_V7R:
							case ARM_V7EM:
							case ARM_V7K:
							case ARM_V7M:
							case ARM_V7S:
							case ARM_V7VE: return CORTEX_A9;
							default: break;
						}
					case IOS:
					case MACOS:
					case TVOS:
					case WATCHOS:
					case DRIVERKIT:
					case VISIONOS:
						if (sub == ARM_V7K) return CORTEX_A7;
					default: break;
				}
				return UNKNOWN_CPU_MODEL~;
			}
			switch (os_tag)
			{
				case WINDOWS: return CORTEX_A9;
				case HAIKU: return ARM1176JZF_S;
				case NETBSD:
					switch (abi)
					{
						case EABI:
						case EABIHF:
						case GNUEABI:
						case GNUEABIHF: return ARM926EJ_S;
						default: return STRONGARM;
					}
				case OPENBSD: return CORTEX_A8;
				case FUCHSIA: return ARM_CORTEX_A53;
				default:
					switch (abi)
					{
						case EABIHF:
						case GNUEABIHF:
						case MUSLEABIHF: return ARM1176JZF_S;
						default: return ARM7TDMI;
					}
			}
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL:
			bool is_64 = arch.is_mips64();
			// see clang: `mips::getMipsCPUAndABI`,
			CpuModel model = is_64 ? MIPS64R2 : MIPS32R2;
			if (vendor == IMAGINATION_TECHNOLOGIES && abi.is_gnu()) model = is_64 ? MIPS64R6 : MIPS32R6;
			if (has_sub_arch && sub == MIPS_R6) model = is_64 ? MIPS64R6 : MIPS32R6;
			if (os_tag == OPENBSD && is_64) model = MIPS3;
			if (os_tag == FREEBSD) model = is_64 ? MIPS3 : MIPS2;
			return model;
		default:
			return UNKNOWN_CPU_MODEL~;
	}
}

struct ArmVersion
{
	char version;
	String string;
}

struct ArmVersionEntry
{
	Feature feature;
	String string;
}

const ArmVersionEntry[*] ARM_VERSIONS = {
	{ ARM_V9_6A, "9_6A" },
	{ ARM_V9_5A, "9_5A" },
	{ ARM_V9_4A, "9_4A" },
	{ ARM_V9_3A, "9_3A" },
	{ ARM_V9_2A, "9_2A" },
	{ ARM_V9_1A, "9_1A" },
	{ ARM_V9A, "9A" },
	{ ARM_V8_9A, "8_9A" },
	{ ARM_V8_8A, "8_8A" },
	{ ARM_V8_7A, "8_7A" },
	{ ARM_V8_6A, "8_6A" },
	{ ARM_V8_5A, "8_5A" },
	{ ARM_V8_4A, "8_4A" },
	{ ARM_V8_3A, "8_3A" },
	{ ARM_V8_2A, "8_2A" },
	{ ARM_V8_1A, "8_1A" },
	{ ARM_V8_1M_MAIN, "8_1M_MAIN" },
	{ ARM_V8A, "8A" },
	{ ARM_V8R, "8R" },
	{ ARM_V8M_MAIN, "8M_MAIN" },
	{ ARM_V8M, "8M_BASE" },
	{ ARM_V7VE, "7VE" },
	{ ARM_V7A, "7A" },
	{ ARM_V7R, "7R" },
	{ ARM_V7M, "7M" },
	{ ARM_V7EM, "7EM" },
	{ ARM_HAS_V7, "7A" }, // bare armv7 with no profile: default to A
	{ ARM_V6T2, "6T2" },
	{ ARM_V6KZ, "6KZ" },
	{ ARM_V6K, "6K" },
	{ ARM_V6J, "6J" },
	{ ARM_V6SM, "6SM" },
	{ ARM_V6M, "6M" },
	{ ARM_V6, "6" },
	{ ARM_V5TEJ, "5TEJ" },
	{ ARM_V5TE, "5TE" },
	{ ARM_V5T, "5T" },
	{ ARM_V4T, "4T" },
	{ ARM_V4, "4" },
	{ ARM_V3M, "3M" },
	{ ARM_V3, "3" },
	{ ARM_V2A, "2A" },
	{ ARM_V2, "2" },
};

<*
 Target.armVersion; faults when no architecture feature is set (Zig null).
 @require self.cpu.arch.is_arm()
*>
fn ArmVersion? Target.arm_version(&self)
{
	foreach (e : ARM_VERSIONS)
	{
		if (self.cpu.features.has(e.feature)) return { e.string[0] - '0', e.string };
	}
	return UNKNOWN_CPU_FEATURE~;
}
