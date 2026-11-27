// Port of c3c src/compiler/target.c (revision 54bab366a) plus the target
// pieces of build/build_options.c (`arch_os_target` names,
// `arch_os_target_from_string`) and build/builder.c (`default_target`,
// `libc_from_arch_os`): turns a `--target` arch/os name into the
// `compiler.platform` PlatformTarget (C type widths and alignments, int128 /
// float16 / float128 / vector support, TLS, endianness, pointer width, ABI and
// its per-arch sub-structs, object format, relocation model, default cpu
// features).
//
// Skipped (LLVM / linker only):
// - the LLVM target machine (`llvm_target_machine_create`), opt level and
//   `target_alloca_addr_space` users;
// - the macOS / iOS SDK lookup (`darwin_sysroot`, `*_sysroot_sdk_information`,
//   `*_cross_compile_library`, `_darwin_sdk_set_min_ver`) and the versioned
//   triples `llvm_macos_target_triple` / `llvm_ios_target_triple`: the
//   unversioned triple is kept (arch/vendor/os/env are parsed from it, as in
//   c3c);
// - `arch_to_linker_arch`, the Windows .def file check, the Xtensa / LLVM
//   availability checks.
// The cpu feature string (`compiler.platform.features`) is still built, as c3c
// does, but nothing reads it.
//
// Deviations from c3c:
// - The feature enums (X86Feature, WasmFeature, ArmFeature, Aarch64Feature,
//   RiscvFeature) are `alias X = int` plus the C constant names, because the
//   cpu feature helpers take any of them as an int.
// - `x86_features_from_host` is the non-LLVM c3c build's
//   `hostinfo_x86_features`, which detects nothing: a native x64 target gets
//   the baseline cpu set (this matches the LLVM-less reference c3c).
// - `target_host_arch` / `default_target` are fixed to x86_64 Linux (the only
//   host arocc builds the C3 frontend on).
// - `OUTF` warnings go to stdout via io::printfn; `FATAL_ERROR` is
//   `@error_exit`.
// - PlatformTarget's per-arch union members are separate structs.
// - CpuFeatures holds 128 bits but X86_FEAT_XSAVES is feature 128: c3c's
//   `1ULL << (feature - 64)` is then a 64-bit shift (UB; x86 masks the count,
//   so XSAVES aliases feature 64). The shift is masked with `& 63` here to
//   behave like the shipped c3c instead of trapping.
module aro::frontend::c3::compiler;
import std::io;


// ---------------------------------------------------------------------------
// build/build_options.c, build/builder.c

<* build_options.c `arch_os_target`, in ArchOsTarget order. *>
String[ARCH_OS_TARGET_LAST.ordinal + 1] arch_os_target = {
	[ArchOsTarget.ANDROID_AARCH64.ordinal] = "android-aarch64",
	[ArchOsTarget.ANDROID_X86_64.ordinal] = "android-x86_64",
	[ArchOsTarget.ELF_AARCH64.ordinal] = "elf-aarch64",
	[ArchOsTarget.ELF_RISCV32.ordinal] = "elf-riscv32",
	[ArchOsTarget.ELF_RISCV64.ordinal] = "elf-riscv64",
	[ArchOsTarget.ELF_X86.ordinal] = "elf-x86",
	[ArchOsTarget.ELF_X64.ordinal] = "elf-x64",
	[ArchOsTarget.ELF_XTENSA.ordinal] = "elf-xtensa",
	[ArchOsTarget.ELF_AVR.ordinal] = "elf-avr",
	[ArchOsTarget.FREEBSD_X86.ordinal] = "freebsd-x86",
	[ArchOsTarget.FREEBSD_X64.ordinal] = "freebsd-x64",
	[ArchOsTarget.IOS_AARCH64.ordinal] = "ios-aarch64",
	[ArchOsTarget.IOS_AARCH64_SIM.ordinal] = "ios-aarch64-sim",
	[ArchOsTarget.IOS_X64_SIM.ordinal] = "ios-x64-sim",
	[ArchOsTarget.LINUX_AARCH64.ordinal] = "linux-aarch64",
	[ArchOsTarget.LINUX_RISCV32.ordinal] = "linux-riscv32",
	[ArchOsTarget.LINUX_RISCV64.ordinal] = "linux-riscv64",
	[ArchOsTarget.LINUX_X86.ordinal] = "linux-x86",
	[ArchOsTarget.LINUX_X64.ordinal] = "linux-x64",
	[ArchOsTarget.MACOS_AARCH64.ordinal] = "macos-aarch64",
	[ArchOsTarget.MACOS_X64.ordinal] = "macos-x64",
	[ArchOsTarget.MCU_X86.ordinal] = "mcu-x86",
	[ArchOsTarget.MINGW_X64.ordinal] = "mingw-x64",
	[ArchOsTarget.NETBSD_AARCH64.ordinal] = "netbsd-aarch64",
	[ArchOsTarget.NETBSD_X86.ordinal] = "netbsd-x86",
	[ArchOsTarget.NETBSD_X64.ordinal] = "netbsd-x64",
	[ArchOsTarget.OPENBSD_X86.ordinal] = "openbsd-x86",
	[ArchOsTarget.OPENBSD_X64.ordinal] = "openbsd-x64",
	[ArchOsTarget.WASM32.ordinal] = "wasm32",
	[ArchOsTarget.WASM64.ordinal] = "wasm64",
	[ArchOsTarget.EMSCRIPTEN_WASM32.ordinal] = "emscripten",
	[ArchOsTarget.WINDOWS_AARCH64.ordinal] = "windows-aarch64",
	[ArchOsTarget.WINDOWS_X64.ordinal] = "windows-x64",
};

<* builder.c `default_target` (the x86_64 Linux host). *>
const ArchOsTarget DEFAULT_TARGET = LINUX_X64;
ArchOsTarget default_target = DEFAULT_TARGET;

// build_options.c:2184
fn ArchOsTarget arch_os_target_from_string(String target)
{
	for (int i = 0; i <= ARCH_OS_TARGET_LAST.ordinal; i++)
	{
		if (arch_os_target[i] == target)
		{
			return ArchOsTarget::from_ordinal(i);
		}
	}
	return ARCH_OS_TARGET_DEFAULT;
}

// builder.c:299 (static)
fn LinkLibc libc_from_arch_os(ArchOsTarget target)
{
	switch (target)
	{
		case ANDROID_AARCH64:
		case ANDROID_X86_64:
		case FREEBSD_X86:
		case FREEBSD_X64:
		case IOS_AARCH64:
		case IOS_AARCH64_SIM:
		case IOS_X64_SIM:
		case LINUX_AARCH64:
		case LINUX_RISCV32:
		case LINUX_RISCV64:
		case LINUX_X86:
		case LINUX_X64:
		case MACOS_AARCH64:
		case MACOS_X64:
		case MINGW_X64:
		case NETBSD_AARCH64:
		case NETBSD_X86:
		case NETBSD_X64:
		case OPENBSD_X86:
		case OPENBSD_X64:
		case WINDOWS_AARCH64:
		case WINDOWS_X64:
		case EMSCRIPTEN_WASM32:
		case DEFAULT:
			return LINK_LIBC_ON;
		case WASM32:
		case WASM64:
		case MCU_X86:
		case ELF_AARCH64:
		case ELF_RISCV32:
		case ELF_RISCV64:
		case ELF_X86:
		case ELF_X64:
		case ELF_XTENSA:
			return LINK_LIBC_OFF;
		case ELF_AVR:
			return LINK_LIBC_OFF;
	}
	unreachable();
}

<*
 The build.h `default_build_target` values target_setup reads (cpu set,
 float / struct-return / vector / riscv options, reloc model, libc), for a
 BuildTarget that was zeroed.
*>
fn void build_target_setup_target_defaults(BuildTarget* target)
{
	target.arch_os_target = ARCH_OS_TARGET_DEFAULT;
	target.reloc_model = RELOC_DEFAULT;
	target.feature.x86_struct_return = STRUCT_RETURN_DEFAULT;
	target.feature.soft_float = SOFT_FLOAT_DEFAULT;
	target.feature.riscv_abi = RISCV_ABI_DEFAULT;
	target.feature.x86_vector_capability = X86VECTOR_DEFAULT;
	target.feature.x86_cpu_set = X86CPU_DEFAULT;
	target.feature.riscv_cpu_set = RISCV_CPU_DEFAULT;
	target.feature.pass_win64_simd_as_arrays = WIN64_SIMD_FULL;
	target.linuxpaths.libc = LINUX_LIBC_NOT_SET;
}

// ---------------------------------------------------------------------------
// target.c

const CpuFeatures CPU_FEATURE_ZERO = { { 0, 0 } };

<* enums.h `X86Feature`. *>
alias X86Feature = int;
const X86Feature X86_FEAT_ADX = 0;
const X86Feature X86_FEAT_AES = 1;
const X86Feature X86_FEAT_AMX_AVX512 = 2;
const X86Feature X86_FEAT_AMX_FP8 = 3;
const X86Feature X86_FEAT_AMX_MOVRS = 4;
const X86Feature X86_FEAT_AMX_TF32 = 5;
const X86Feature X86_FEAT_AMX_TRANSPOSE = 6;
const X86Feature X86_FEAT_AMX_BF16 = 7;
const X86Feature X86_FEAT_AMX_COMPLEX = 8;
const X86Feature X86_FEAT_AMX_FP16 = 9;
const X86Feature X86_FEAT_AMX_INT8 = 10;
const X86Feature X86_FEAT_AMX_TILE = 11;
const X86Feature X86_FEAT_APX_EGPR = 12;
const X86Feature X86_FEAT_APX_PUSH2POP2 = 13;
const X86Feature X86_FEAT_APX_PPX = 14;
const X86Feature X86_FEAT_APX_NDD = 15;
const X86Feature X86_FEAT_APX_CCMP = 16;
const X86Feature X86_FEAT_APX_NF = 17;
const X86Feature X86_FEAT_APX_CF = 18;
const X86Feature X86_FEAT_APX_ZU = 19;
const X86Feature X86_FEAT_AVX = 20;
const X86Feature X86_FEAT_AVX10_1 = 21;
const X86Feature X86_FEAT_AVX10_2 = 22;
const X86Feature X86_FEAT_AVX10_1_512 = 23;
const X86Feature X86_FEAT_AVX10_1_256 = 24;
const X86Feature X86_FEAT_AVX10_2_512 = 25;
const X86Feature X86_FEAT_AVX10_2_256 = 26;
const X86Feature X86_FEAT_AVX2 = 27;
const X86Feature X86_FEAT_AVX5124FMAPS = 28;
const X86Feature X86_FEAT_AVX5124VNNIW = 29;
const X86Feature X86_FEAT_AVX512BF16 = 30;
const X86Feature X86_FEAT_AVX512BITALG = 31;
const X86Feature X86_FEAT_AVX512BMM = 32;
const X86Feature X86_FEAT_AVX512BW = 33;
const X86Feature X86_FEAT_AVX512CD = 34;
const X86Feature X86_FEAT_AVX512DQ = 35;
const X86Feature X86_FEAT_AVX512ER = 36;
const X86Feature X86_FEAT_AVX512F = 37;
const X86Feature X86_FEAT_AVX512FP16 = 38;
const X86Feature X86_FEAT_AVX512IFMA = 39;
const X86Feature X86_FEAT_AVX512PF = 40;
const X86Feature X86_FEAT_AVX512VBMI = 41;
const X86Feature X86_FEAT_AVX512VBMI2 = 42;
const X86Feature X86_FEAT_AVX512VL = 43;
const X86Feature X86_FEAT_AVX512VNNI = 44;
const X86Feature X86_FEAT_AVX512VP2INTERSECT = 45;
const X86Feature X86_FEAT_AVX512VPOPCNTDQ = 46;
const X86Feature X86_FEAT_AVXIFMA = 47;
const X86Feature X86_FEAT_AVXNECONVERT = 48;
const X86Feature X86_FEAT_AVXVNNI = 49;
const X86Feature X86_FEAT_AVXVNNIINT16 = 50;
const X86Feature X86_FEAT_AVXVNNIINT8 = 51;
const X86Feature X86_FEAT_BMI = 52;
const X86Feature X86_FEAT_BMI2 = 53;
const X86Feature X86_FEAT_CLDEMOTE = 54;
const X86Feature X86_FEAT_CLFLUSHOPT = 55;
const X86Feature X86_FEAT_CLWB = 56;
const X86Feature X86_FEAT_CLZERO = 57;
const X86Feature X86_FEAT_CMOV = 58;
const X86Feature X86_FEAT_CMPCCXADD = 59;
const X86Feature X86_FEAT_CMPXCHG16B = 60;
const X86Feature X86_FEAT_CMPXCHG8B = 61;
const X86Feature X86_FEAT_CRC32 = 62;
const X86Feature X86_FEAT_ENQCMD = 63;
const X86Feature X86_FEAT_EVEX512 = 64;
const X86Feature X86_FEAT_F16C = 65;
const X86Feature X86_FEAT_FMA = 66;
const X86Feature X86_FEAT_FMA4 = 67;
const X86Feature X86_FEAT_FSGSBASE = 68;
const X86Feature X86_FEAT_FXSR = 69;
const X86Feature X86_FEAT_GFNI = 70;
const X86Feature X86_FEAT_HRESET = 71;
const X86Feature X86_FEAT_INVPCID = 72;
const X86Feature X86_FEAT_JMPABS = 73;
const X86Feature X86_FEAT_KL = 74;
const X86Feature X86_FEAT_LWP = 75;
const X86Feature X86_FEAT_LZCNT = 76;
const X86Feature X86_FEAT_MMX = 77;
const X86Feature X86_FEAT_MOVBE = 78;
const X86Feature X86_FEAT_MOVDIR64B = 79;
const X86Feature X86_FEAT_MOVDIRI = 80;
const X86Feature X86_FEAT_MOVRS = 81;
const X86Feature X86_FEAT_MWAITX = 82;
const X86Feature X86_FEAT_PCLMUL = 83;
const X86Feature X86_FEAT_PCONFIG = 84;
const X86Feature X86_FEAT_PKU = 85;
const X86Feature X86_FEAT_POPCNT = 86;
const X86Feature X86_FEAT_PREFETCHI = 87;
const X86Feature X86_FEAT_PREFETCHWT1 = 88;
const X86Feature X86_FEAT_PRFCHW = 89;
const X86Feature X86_FEAT_PTWRITE = 90;
const X86Feature X86_FEAT_RAOINT = 91;
const X86Feature X86_FEAT_RDPID = 92;
const X86Feature X86_FEAT_RDPRU = 93;
const X86Feature X86_FEAT_RDRND = 94;
const X86Feature X86_FEAT_RDSEED = 95;
const X86Feature X86_FEAT_RTM = 96;
const X86Feature X86_FEAT_SAHF = 97;
const X86Feature X86_FEAT_SERIALIZE = 98;
const X86Feature X86_FEAT_SOFT_FLOAT = 99;
const X86Feature X86_FEAT_SGX = 100;
const X86Feature X86_FEAT_SHA = 101;
const X86Feature X86_FEAT_SHA512 = 102;
const X86Feature X86_FEAT_SHSTK = 103;
const X86Feature X86_FEAT_SM3 = 104;
const X86Feature X86_FEAT_SM4 = 105;
const X86Feature X86_FEAT_SSE = 106;
const X86Feature X86_FEAT_SSE2 = 107;
const X86Feature X86_FEAT_SSE3 = 108;
const X86Feature X86_FEAT_SSE4_1 = 109;
const X86Feature X86_FEAT_SSE4_2 = 110;
const X86Feature X86_FEAT_SSE4_A = 111;
const X86Feature X86_FEAT_SSSE3 = 112;
const X86Feature X86_FEAT_TBM = 113;
const X86Feature X86_FEAT_TSXLDTRK = 114;
const X86Feature X86_FEAT_UINTR = 115;
const X86Feature X86_FEAT_USERMSR = 116;
const X86Feature X86_FEAT_VAES = 117;
const X86Feature X86_FEAT_VPCLMULQDQ = 118;
const X86Feature X86_FEAT_VZEROUPPER = 119;
const X86Feature X86_FEAT_WAITPKG = 120;
const X86Feature X86_FEAT_WBNOINVD = 121;
const X86Feature X86_FEAT_WIDEKL = 122;
const X86Feature X86_FEAT_X87 = 123;
const X86Feature X86_FEAT_XOP = 124;
const X86Feature X86_FEAT_XSAVE = 125;
const X86Feature X86_FEAT_XSAVEC = 126;
const X86Feature X86_FEAT_XSAVEOPT = 127;
const X86Feature X86_FEAT_XSAVES = 128;
const X86Feature X86_FEATURE_LAST = X86_FEAT_XSAVES;

<* enums.h `WasmFeature`. *>
alias WasmFeature = int;
const WasmFeature WASM_FEAT_BULK_MEMORY = 0;
const WasmFeature WASM_FEAT_BULK_MEMORY_OPT = 1;
const WasmFeature WASM_FEAT_CALL_INDIRECT_OVERLONG = 2;
const WasmFeature WASM_FEAT_MULTIVALUE = 3;
const WasmFeature WASM_FEAT_MUTABLE_GLOBALS = 4;
const WasmFeature WASM_FEAT_NONTRAPPING_FPTORINT = 5;
const WasmFeature WASM_FEAT_REFERENCE_TYPES = 6;
const WasmFeature WASM_FEAT_SIGN_EXT = 7;
const WasmFeature WASM_FEAT_ATOMICS = 8;
const WasmFeature WASM_FEATURE_LAST = WASM_FEAT_ATOMICS;

<* enums.h `ArmFeature`. *>
alias ArmFeature = int;
const ArmFeature ARM_FEAT_ARMV6KZ = 0;
const ArmFeature ARM_FEAT_DSP = 1;
const ArmFeature ARM_FEAT_FP64 = 2;
const ArmFeature ARM_FEAT_STRICT_ALIGN = 3;
const ArmFeature ARM_FEAT_VFP2 = 4;
const ArmFeature ARM_FEAT_VFP2SP = 5;
const ArmFeature ARM_FEAT_AES = 6;
const ArmFeature ARM_FEAT_D32 = 7;
const ArmFeature ARM_FEAT_FP_ARMV8 = 8;
const ArmFeature ARM_FEAT_FP_ARMV8D16 = 9;
const ArmFeature ARM_FEAT_FP_ARMV8D16SP = 10;
const ArmFeature ARM_FEAT_FP_ARMV8SP = 11;
const ArmFeature ARM_FEAT_FP_FP16 = 12;
const ArmFeature ARM_FEAT_FP_FP16FML = 13;
const ArmFeature ARM_FEAT_FP_FULLFP16 = 14;
const ArmFeature ARM_FEAT_NEON = 15;
const ArmFeature ARM_FEAT_SHA2 = 16;
const ArmFeature ARM_FEAT_THUMB_MODE = 17;
const ArmFeature ARM_FEAT_VFP3 = 18;
const ArmFeature ARM_FEAT_VFP3D16 = 19;
const ArmFeature ARM_FEAT_VFP3D16SP = 20;
const ArmFeature ARM_FEAT_VFP3SP = 21;
const ArmFeature ARM_FEAT_VFP4 = 22;
const ArmFeature ARM_FEAT_VFP4D16 = 23;
const ArmFeature ARM_FEAT_VFP4D16SP = 24;
const ArmFeature ARM_FEAT_VFP4SP = 25;
const ArmFeature ARM_FEAT_LAST = ARM_FEAT_VFP4SP;

<* enums.h `Aarch64Feature`. *>
alias Aarch64Feature = int;
const Aarch64Feature AARCH64_FEAT_CRC = 0;
const Aarch64Feature AARCH64_FEAT_LSE = 1;
const Aarch64Feature AARCH64_FEAT_RDM = 2;
const Aarch64Feature AARCH64_FEAT_FP_ARMV8 = 3;
const Aarch64Feature AARCH64_FEAT_NEON = 4;
const Aarch64Feature AARCH64_FEATURE_LAST = AARCH64_FEAT_NEON;

<* enums.h `RiscVFeature`. *>
alias RiscvFeature = int;
const RiscvFeature RISCV_FEAT_64BIT = 0;
const RiscvFeature RISCV_FEAT_32BIT = 1;
const RiscvFeature RISCV_FEAT_A = 2;
const RiscvFeature RISCV_FEAT_B = 3;
const RiscvFeature RISCV_FEAT_C = 4;
const RiscvFeature RISCV_FEAT_D = 5;
const RiscvFeature RISCV_FEAT_E = 6;
const RiscvFeature RISCV_FEAT_F = 7;
const RiscvFeature RISCV_FEAT_I = 8;
const RiscvFeature RISCV_FEAT_M = 9;
const RiscvFeature RISCV_FEAT_RELAX = 10;
const RiscvFeature RISCV_FEAT_V = 11;
const RiscvFeature RISCV_FEAT_ZAAMO = 12;
const RiscvFeature RISCV_FEAT_ZALRSC = 13;
const RiscvFeature RISCV_FEAT_ZBA = 14;
const RiscvFeature RISCV_FEAT_ZBB = 15;
const RiscvFeature RISCV_FEAT_ZBS = 16;
const RiscvFeature RISCV_FEAT_ZCA = 17;
const RiscvFeature RISCV_FEAT_ZCD = 18;
const RiscvFeature RISCV_FEAT_ZCF = 19;
const RiscvFeature RISCV_FEAT_ZFA = 20;
const RiscvFeature RISCV_FEAT_ZICSR = 21;
const RiscvFeature RISCV_FEAT_ZIFENCEI = 22;
const RiscvFeature RISCV_FEAT_ZMMUL = 23;
const RiscvFeature RISCV_FEATURE_LAST = RISCV_FEAT_ZMMUL;

// target.c (static)
String[WASM_FEATURE_LAST + 1] wasm_feature_name = {
	[WASM_FEAT_BULK_MEMORY] = "bulk-memory",
	[WASM_FEAT_BULK_MEMORY_OPT] = "bulk-memory-opt",
	[WASM_FEAT_CALL_INDIRECT_OVERLONG] = "call-indirect-overlong",
	[WASM_FEAT_MULTIVALUE] = "multivalue",
	[WASM_FEAT_MUTABLE_GLOBALS] = "mutable-globals",
	[WASM_FEAT_NONTRAPPING_FPTORINT] = "nontrapping-fptoint",
	[WASM_FEAT_REFERENCE_TYPES] = "reference-types",
	[WASM_FEAT_SIGN_EXT] = "sign-ext",
	[WASM_FEAT_ATOMICS] = "atomics",
};

// target.c (static)
String[ARM_FEAT_LAST + 1] arm_feature_name = {
	[ARM_FEAT_ARMV6KZ] = "armv6kz",
	[ARM_FEAT_DSP] = "dsp",
	[ARM_FEAT_FP64] = "fp64",
	[ARM_FEAT_STRICT_ALIGN] = "strict-align",
	[ARM_FEAT_VFP2] = "vfp2",
	[ARM_FEAT_VFP2SP] = "vfp2sp",
	[ARM_FEAT_AES] = "aes",
	[ARM_FEAT_D32] = "d32",
	[ARM_FEAT_FP_ARMV8] = "fp-armv8",
	[ARM_FEAT_FP_ARMV8D16] = "fp-armv8d16",
	[ARM_FEAT_FP_ARMV8D16SP] = "fp-armv8d16sp",
	[ARM_FEAT_FP_ARMV8SP] = "fp-armv8sp",
	[ARM_FEAT_FP_FP16] = "fp16",
	[ARM_FEAT_FP_FP16FML] = "fp16fml",
	[ARM_FEAT_FP_FULLFP16] = "fullfp16",
	[ARM_FEAT_NEON] = "neon",
	[ARM_FEAT_SHA2] = "sha2",
	[ARM_FEAT_THUMB_MODE] = "thumb-mode",
	[ARM_FEAT_VFP3] = "vfp3",
	[ARM_FEAT_VFP3D16] = "vfp3d16",
	[ARM_FEAT_VFP3D16SP] = "vfp3d16sp",
	[ARM_FEAT_VFP3SP] = "vfp3sp",
};

// target.c (static)
String[AARCH64_FEATURE_LAST + 1] aarch64_feature_name = {
	[AARCH64_FEAT_CRC] = "crc",
	[AARCH64_FEAT_LSE] = "lse",
	[AARCH64_FEAT_RDM] = "rdm",
	[AARCH64_FEAT_FP_ARMV8] = "fp-armv8",
	[AARCH64_FEAT_NEON] = "neon",
};

// target.c (static)
String[RISCV_FEATURE_LAST + 1] riscv_feature_name = {
	[RISCV_FEAT_64BIT] = "64bit",
	[RISCV_FEAT_32BIT] = "32bit",
	[RISCV_FEAT_A] = "a",
	[RISCV_FEAT_B] = "b",
	[RISCV_FEAT_C] = "c",
	[RISCV_FEAT_D] = "d",
	[RISCV_FEAT_E] = "e",
	[RISCV_FEAT_F] = "f",
	[RISCV_FEAT_I] = "i",
	[RISCV_FEAT_M] = "m",
	[RISCV_FEAT_RELAX] = "relax",
	[RISCV_FEAT_V] = "v",
	[RISCV_FEAT_ZAAMO] = "zaamo",
	[RISCV_FEAT_ZALRSC] = "zalrsc",
	[RISCV_FEAT_ZBA] = "zba",
	[RISCV_FEAT_ZBB] = "zbb",
	[RISCV_FEAT_ZBS] = "zbs",
	[RISCV_FEAT_ZCA] = "zca",
	[RISCV_FEAT_ZCD] = "zcd",
	[RISCV_FEAT_ZCF] = "zcf",
	[RISCV_FEAT_ZFA] = "zfa",
	[RISCV_FEAT_ZICSR] = "zicsr",
	[RISCV_FEAT_ZIFENCEI] = "zifencei",
	[RISCV_FEAT_ZMMUL] = "zmmul",
};

// target.c (static)
String[X86_FEATURE_LAST + 1] x86_feature_name = {
	[X86_FEAT_CMOV] = "cmov",
	[X86_FEAT_MMX] = "mmx",
	[X86_FEAT_POPCNT] = "popcnt",
	[X86_FEAT_SSE] = "sse",
	[X86_FEAT_SSE2] = "sse2",
	[X86_FEAT_SSE3] = "sse3",
	[X86_FEAT_SSSE3] = "ssse3",
	[X86_FEAT_SSE4_1] = "sse4.1",
	[X86_FEAT_SSE4_2] = "sse4.2",
	[X86_FEAT_APX_EGPR] = "egpr",
	[X86_FEAT_APX_PUSH2POP2] = "push2pop2",
	[X86_FEAT_APX_PPX] = "ppx",
	[X86_FEAT_APX_NDD] = "ndd",
	[X86_FEAT_APX_CCMP] = "ccmp",
	[X86_FEAT_APX_NF] = "nf",
	[X86_FEAT_APX_CF] = "cf",
	[X86_FEAT_APX_ZU] = "zu",
	[X86_FEAT_AVX] = "avx",
	[X86_FEAT_AVX2] = "avx2",
	[X86_FEAT_AVX10_1] = "avx10.1",
	[X86_FEAT_AVX10_2] = "avx10.2",
	[X86_FEAT_AVX10_1_512] = "avx10.1-512",
	[X86_FEAT_AVX10_1_256] = "avx10.1-256",
	[X86_FEAT_AVX10_2_512] = "avx10.2-512",
	[X86_FEAT_AVX10_2_256] = "avx10.2-256",
	[X86_FEAT_SSE4_A] = "sse4a",
	[X86_FEAT_FMA4] = "fma4",
	[X86_FEAT_XOP] = "xop",
	[X86_FEAT_FMA] = "fma",
	[X86_FEAT_AVX512F] = "avx512f",
	[X86_FEAT_BMI] = "bmi",
	[X86_FEAT_BMI2] = "bmi2",
	[X86_FEAT_AES] = "aes",
	[X86_FEAT_PCLMUL] = "pclmul",
	[X86_FEAT_AVX512VL] = "avx512vl",
	[X86_FEAT_AVX512BW] = "avx512bw",
	[X86_FEAT_AVX512DQ] = "avx512dq",
	[X86_FEAT_AVX512CD] = "avx512cd",
	[X86_FEAT_AVX512ER] = "avx512er",
	[X86_FEAT_AVX512PF] = "avx512pf",
	[X86_FEAT_AVX512VBMI] = "avx512vbmi",
	[X86_FEAT_AVX512IFMA] = "avx512ifma",
	[X86_FEAT_AVX5124VNNIW] = "avx5124vnniw",
	[X86_FEAT_AVX5124FMAPS] = "avx5124fmaps",
	[X86_FEAT_AVX512VPOPCNTDQ] = "avx512vpopcntdq",
	[X86_FEAT_AVX512VBMI2] = "avx512vbmi2",
	[X86_FEAT_AVX512BMM] = "avx512bmm",
	[X86_FEAT_GFNI] = "gfni",
	[X86_FEAT_VPCLMULQDQ] = "vpclmulqdq",
	[X86_FEAT_AVX512VNNI] = "avx512vnni",
	[X86_FEAT_AVX512BITALG] = "avx512bitalg",
	[X86_FEAT_AVX512BF16] = "avx512bf16",
	[X86_FEAT_AVX512VP2INTERSECT] = "avx512vp2intersect",
	[X86_FEAT_ADX] = "adx",
	[X86_FEAT_AMX_BF16] = "amx-bf16",
	[X86_FEAT_AMX_INT8] = "amx-int8",
	[X86_FEAT_AMX_TILE] = "amx-tile",
	[X86_FEAT_AMX_AVX512] = "amx-avx512",
	[X86_FEAT_AMX_FP8] = "amx-fp8",
	[X86_FEAT_AMX_MOVRS] = "amx-movrs",
	[X86_FEAT_AMX_TF32] = "amx-tf32",
	[X86_FEAT_AMX_TRANSPOSE] = "amx-transpose",
	[X86_FEAT_MOVRS] = "movrs",
	[X86_FEAT_CLDEMOTE] = "cldemote",
	[X86_FEAT_CLFLUSHOPT] = "clflushopt",
	[X86_FEAT_CLWB] = "clwb",
	[X86_FEAT_CLZERO] = "clzero",
	[X86_FEAT_CMPXCHG16B] = "cx16",
	[X86_FEAT_CMPXCHG8B] = "cx8",
	[X86_FEAT_CRC32] = "crc32",
	[X86_FEAT_ENQCMD] = "enqcmd",
	[X86_FEAT_F16C] = "f16c",
	[X86_FEAT_FSGSBASE] = "fsgsbase",
	[X86_FEAT_FXSR] = "fxsr",
	[X86_FEAT_INVPCID] = "invpcid",
	[X86_FEAT_JMPABS] = "jmpabs",
	[X86_FEAT_KL] = "kl",
	[X86_FEAT_WIDEKL] = "widekl",
	[X86_FEAT_LWP] = "lwp",
	[X86_FEAT_LZCNT] = "lzcnt",
	[X86_FEAT_MOVBE] = "movbe",
	[X86_FEAT_MOVDIR64B] = "movdir64b",
	[X86_FEAT_MOVDIRI] = "movdiri",
	[X86_FEAT_MWAITX] = "mwaitx",
	[X86_FEAT_PCONFIG] = "pconfig",
	[X86_FEAT_PKU] = "pku",
	[X86_FEAT_PREFETCHI] = "prefetchi",
	[X86_FEAT_PREFETCHWT1] = "prefetchwt1",
	[X86_FEAT_PRFCHW] = "prfchw",
	[X86_FEAT_PTWRITE] = "ptwrite",
	[X86_FEAT_RDPID] = "rdpid",
	[X86_FEAT_RDPRU] = "rdpru",
	[X86_FEAT_RDRND] = "rdrnd",
	[X86_FEAT_RDSEED] = "rdseed",
	[X86_FEAT_RTM] = "rtm",
	[X86_FEAT_SAHF] = "sahf",
	[X86_FEAT_SERIALIZE] = "serialize",
	[X86_FEAT_SGX] = "sgx",
	[X86_FEAT_SM3] = "sm3",
	[X86_FEAT_SM4] = "sm4",
	[X86_FEAT_SHA] = "sha",
	[X86_FEAT_SHA512] = "sha512",
	[X86_FEAT_SHSTK] = "shstk",
	[X86_FEAT_TBM] = "tbm",
	[X86_FEAT_TSXLDTRK] = "tsxldtrk",
	[X86_FEAT_UINTR] = "uintr",
	[X86_FEAT_USERMSR] = "usermsr",
	[X86_FEAT_VAES] = "vaes",
	[X86_FEAT_VZEROUPPER] = "vzeroupper",
	[X86_FEAT_WAITPKG] = "waitpkg",
	[X86_FEAT_WBNOINVD] = "wbnoinvd",
	[X86_FEAT_X87] = "x87",
	[X86_FEAT_XSAVE] = "xsave",
	[X86_FEAT_XSAVEC] = "xsavec",
	[X86_FEAT_XSAVEOPT] = "xsaveopt",
	[X86_FEAT_XSAVES] = "xsaves",
	[X86_FEAT_HRESET] = "hreset",
	[X86_FEAT_RAOINT] = "raoint",
	[X86_FEAT_AVX512FP16] = "avx512fp16",
	[X86_FEAT_AMX_FP16] = "amx-fp16",
	[X86_FEAT_AMX_COMPLEX] = "amx-complex",
	[X86_FEAT_CMPCCXADD] = "cmpccxadd",
	[X86_FEAT_AVXNECONVERT] = "avxneconvert",
	[X86_FEAT_AVXVNNI] = "avxvnni",
	[X86_FEAT_AVXIFMA] = "avxifma",
	[X86_FEAT_AVXVNNIINT8] = "avxvnniint8",
	[X86_FEAT_AVXVNNIINT16] = "avxvnniint16",
	[X86_FEAT_EVEX512] = "evex512",
	[X86_FEAT_SOFT_FLOAT] = "soft-float",
};
// target.c:241
fn int target_alloca_addr_space()
{
	return compiler.platform.alloca_address_space;
}

// target.c:246
fn bool os_supports_stacktrace(OsType os_type)
{
	return os_type == LINUX || os_is_apple(os_type) || os_type == WIN32;
}

// target.c:250
fn bool os_is_apple(OsType os_type)
{
	return os_type == TVOS || os_type == WATCHOS ||
	       os_type == MACOSX || os_type == IOS;
}

// target.c:256
fn bool arch_is_wasm(ArchType type)
{
	return type == WASM32 || type == WASM64;
}

// target.c:261 (static)
fn AlignSize os_arch_max_alignment_of_vector(OsType os, ArchType arch, EnvironmentType type, ArmVariant variant, CpuFeatures* x64_features)
{
	switch (arch)
	{
		case AARCH64:
			// aarch64 uses 128 bits.
			// See Clang: AArch64TargetInfo::AArch64TargetInfo
			return 16;
		case ARM:
		case ARMB:
			if (type == ANDROID) return 0;
			switch (variant)
			{
				case AAPCS:
				case AAPCS_LINUX:
					return 8; // AAPCS (not AAPCS16!) uses 64 bits
				case AAPCS16:
				case APCS_GNU:
					break;
			}
		case X86:
			if (os == WIN32) /* COFF */
			{
				return 8192 / 8;
			}
			if (os_is_apple(os))
			{
				// With AVX512 - 512, AVX - 256 otherwise AVX - 128
				if (cpu_features_contains(x64_features, X86_FEAT_AVX512F)) return 512 / 8;
				if (cpu_features_contains(x64_features, X86_FEAT_AVX)) return 256 / 8;
				return 128 / 8;
			}
		default:
			break;
	}
	// No max alignment default.
	return 0;
}

// target.c:302 (static)
fn AlignSize os_arch_max_alignment_of_tls(OsType os, ArchType arch, EnvironmentType type)
{
	switch (arch)
	{
		case X86:
			if (os == WIN32) /* COFF */
			{
				return 8192;
			}
		default:
			break;
	}
	// No max alignment default.
	return 0;
}

// target.c:319 (static)
fn bool os_target_use_thread_local(OsType os)
{
	switch (os)
	{
		case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
		case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
		case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
			return false;
		case UNKNOWN:
		case NONE:
			return false;
		case WATCHOS: case IOS: case TVOS: case MACOSX:
		case FREEBSD:
		case LINUX:
		case ANDROID:
		case NETBSD:
		case OPENBSD:
		case WIN32:
		case WASI:
		case EMSCRIPTEN:
			return true;
	}
	unreachable();
}

// target.c:342 (static)
fn bool os_target_signed_c_char_type(OsType os, ArchType arch)
{
	switch (arch)
	{
		case AARCH64:
		case AARCH64_32:
		case AARCH64_BE:
		case ARM:
		case ARMB:
		case THUMB:
		case THUMBEB:
			if (os_is_apple(os) || os == WIN32) return true;
			return false;
		case PPC:
		case PPC64:
			return os_is_apple(os);
		case HEXAGON:
		case PPC64LE:
		case RISCV32:
		case RISCV64:
		case SYSTEMZ:
		case XCORE:
			return false;
		default:
			return true;
	}
}

// target.c:370 (static)
fn void target_setup_aarch64_abi()
{
	compiler.platform.aarch64.is_darwin_pcs = os_is_apple(compiler.platform.os);
	compiler.platform.aarch64.is_aapcs = !compiler.platform.aarch64.is_darwin_pcs && compiler.platform.os != WIN32;
	compiler.platform.abi = AARCH64;
	// TODO improve Aarch64 functionality support.
	CpuFeatures features = CPU_FEATURE_ZERO;
	cpu_features_add_feature_single(&features, AARCH64_FEAT_CRC);
	cpu_features_add_feature_single(&features, AARCH64_FEAT_LSE);
	cpu_features_add_feature_single(&features, AARCH64_FEAT_RDM);
	cpu_features_add_feature_single(&features, AARCH64_FEAT_FP_ARMV8);
	cpu_features_add_feature_single(&features, AARCH64_FEAT_NEON);
	update_cpu_features(compiler.build.cpu_flags, &features, &aarch64_feature_name, AARCH64_FEATURE_LAST);
	cpu_features_set_to_features(features, CPU_FEATURE_ZERO, null, &aarch64_feature_name, AARCH64_FEATURE_LAST);
}

// target.c:386 (static)
fn void target_setup_arm_abi()
{
	compiler.platform.abi = ARM;
	// c3c: `if (compiler.platform.os)`, i.e. any os other than OS_TYPE_UNKNOWN.
	if (compiler.platform.os != UNKNOWN)
	{
		compiler.platform.arm.is_win32 = true;
		compiler.platform.arm.variant = AAPCS;
		compiler.platform.arm.abi_variant = AAPCS16_VFP;
		return;
	}

	CpuFeatures features = CPU_FEATURE_ZERO;

	// Should be based on feature set. We start with this though.
	cpu_features_add_feature_single(&features, ARM_FEAT_ARMV6KZ);
	cpu_features_add_feature_single(&features, ARM_FEAT_DSP);
	cpu_features_add_feature_single(&features, ARM_FEAT_FP64);
	cpu_features_add_feature_single(&features, ARM_FEAT_STRICT_ALIGN);
	cpu_features_add_feature_single(&features, ARM_FEAT_VFP2);
	cpu_features_add_feature_single(&features, ARM_FEAT_VFP2SP);

	update_cpu_features(compiler.build.cpu_flags, &features, &arm_feature_name, ARM_FEAT_LAST);
	cpu_features_set_to_features(features, CPU_FEATURE_ZERO, null, &arm_feature_name, ARM_FEAT_LAST);
	// c3c: the `goto SET_ABI` jumps become a fall through to target_setup_arm_abi_variant().
	if (compiler.platform.object_format == MACHO)
	{
		if (compiler.platform.environment_type == EABI
			|| compiler.platform.os == UNKNOWN /* or is M */)
		{
			compiler.platform.arm.variant = AAPCS;
			return;
		}
		// TODO: is watch abi -> ARM_AAPCS16
		compiler.platform.arm.variant = APCS_GNU;
		target_setup_arm_abi_variant();
		return;
	}
	switch (compiler.platform.environment_type)
	{
		case ANDROID:
		case GNUEABI:
		case GNUEABIHF:
		case MUSLEABI:
		case MUSLEABIHF:
			compiler.platform.arm.variant = AAPCS_LINUX;
			target_setup_arm_abi_variant();
			return;
		case EABI:
		case EABIHF:
			compiler.platform.arm.variant = AAPCS;
			target_setup_arm_abi_variant();
			return;
		case GNU:
			compiler.platform.arm.variant = APCS_GNU;
			target_setup_arm_abi_variant();
			return;
		default:
			break;
	}
	switch (compiler.platform.os)
	{
		case NETBSD:
			compiler.platform.arm.variant = APCS_GNU;
		case OPENBSD:
			compiler.platform.arm.variant = AAPCS_LINUX;
		default:
			compiler.platform.arm.variant = AAPCS;
	}
	target_setup_arm_abi_variant();
}

<* The `SET_ABI:` tail of target.c `target_setup_arm_abi`. *>
fn void target_setup_arm_abi_variant() @local
{
	switch (compiler.platform.arm.variant)
	{
		case APCS_GNU:
			compiler.platform.arm.abi_variant = APCS;
			return;
		case AAPCS16:
			compiler.platform.arm.abi_variant = AAPCS16_VFP;
			return;
		case AAPCS:
		case AAPCS_LINUX:
			if (compiler.platform.float_abi == HARD ||
				(compiler.platform.float_abi != SOFT &&
				 (compiler.platform.environment_type == GNUEABIHF ||
				  compiler.platform.environment_type == MUSLEABIHF ||
				  compiler.platform.environment_type == EABIHF)))
			{
				compiler.platform.arm.abi_variant = AAPCS_VFP;
				return;
			}
			compiler.platform.arm.abi_variant = AAPCS;
	}
	// c3c: UNREACHABLE_VOID after the AAPCS break (never reached in practice
	// since no target maps to ARM); kept as a plain return.
}

// target.c:483 (static)
fn void target_setup_x86_abi(BuildTarget* target)
{
	compiler.platform.abi = X86;
	compiler.platform.x86.use_soft_float = compiler.platform.float_abi == SOFT;
	// Build target override.
	if (target.feature.soft_float != SOFT_FLOAT_DEFAULT)
	{
		compiler.platform.x86.use_soft_float = target.feature.soft_float == SOFT_FLOAT_YES;
	}

	compiler.platform.x86.is_mcu_api = compiler.platform.os == ELFIAMCU;
	switch (compiler.platform.os)
	{
		case WATCHOS: case IOS: case TVOS: case MACOSX:
		case DRAGON_FLY:
		case FREEBSD:
		case ELFIAMCU:
		case OPENBSD:
		case WIN32:
			compiler.platform.x86.return_small_struct_in_reg_abi = true;
		default:
			break;
	}
	if (target.feature.x86_struct_return != STRUCT_RETURN_DEFAULT)
	{
		compiler.platform.x86.return_small_struct_in_reg_abi = target.feature.x86_struct_return == STRUCT_RETURN_REG;
	}
}

// target.c:514 (static)
fn void cpu_features_add_feature_single(CpuFeatures* cpu_features, int feature)
{
	if (feature < 64)
	{
		cpu_features.bits[0] |= 1UL << feature;
	}
	else
	{
		cpu_features.bits[1] |= 1UL << ((feature - 64) & 63);
	}
}

// target.c:527 (static)
fn X86Feature x86feature_from_slice(StringSlice slice)
{
	for (int i = 0; i <= X86_FEATURE_LAST; i++)
	{
		if (slice_strcmp(slice, x86_feature_name[i])) return i;
	}
	return -1;
}

// target.c:536 (static)
fn bool cpu_features_contains(CpuFeatures* cpu_features, int feature)
{
	if (feature < 64)
	{
		return (cpu_features.bits[0] & (1UL << feature)) != 0;
	}
	return (cpu_features.bits[1] & (1UL << ((feature - 64) & 63))) != 0;
}

// target.c:545 (static)
fn CpuFeatures x86_features_from_cpu(X86CpuSet set)
{
	CpuFeatures features = CPU_FEATURE_ZERO;
	switch (set)
	{
		case X86CPU_NATIVE:
			x86_features_from_host(&features);
		case X86CPU_AVX512:
			x86_features_add_feature(&features, X86_FEAT_AVX512BW);
			x86_features_add_feature(&features, X86_FEAT_AVX512CD);
			x86_features_add_feature(&features, X86_FEAT_AVX512DQ);
			x86_features_add_feature(&features, X86_FEAT_AVX512VL);
			nextcase X86CPU_AVX2_V1;
		case X86CPU_AVX2_V1:
		case X86CPU_AVX2_V2:
			x86_features_add_feature(&features, X86_FEAT_AVX2);
			x86_features_add_feature(&features, X86_FEAT_BMI2);
			x86_features_add_feature(&features, X86_FEAT_BMI);
			x86_features_add_feature(&features, X86_FEAT_F16C);
			x86_features_add_feature(&features, X86_FEAT_FMA);
			x86_features_add_feature(&features, X86_FEAT_LZCNT);
			x86_features_add_feature(&features, X86_FEAT_MOVBE);
			x86_features_add_feature(&features, X86_FEAT_XSAVE);
			nextcase X86CPU_SSE4;
		case X86CPU_SSE4:
		case X86CPU_AVX1:
			x86_features_add_feature(&features, X86_FEAT_SAHF);
			x86_features_add_feature(&features, X86_FEAT_POPCNT);
			x86_features_add_feature(&features, X86_FEAT_CRC32);
			x86_features_add_feature(&features, X86_FEAT_SSE4_2);
			x86_features_add_feature(&features, X86_FEAT_CMPXCHG16B);
			nextcase X86CPU_SSSE3;
		case X86CPU_SSSE3:
		case X86CPU_DEFAULT:
		case X86CPU_BASELINE:
			x86_features_add_feature(&features, X86_FEAT_MMX);
			x86_features_add_feature(&features, X86_FEAT_SSE3);
			x86_features_add_feature(&features, X86_FEAT_SSE2);
			x86_features_add_feature(&features, X86_FEAT_SSE);
			x86_features_add_feature(&features, X86_FEAT_CMOV);
			x86_features_add_feature(&features, X86_FEAT_FXSR);
			x86_features_add_feature(&features, X86_FEAT_CMPXCHG8B);
	}
	return features;
}

// target.c:593 (static)
fn void cpu_features_set_to_features(CpuFeatures enabled_features, CpuFeatures cpu_defaults, bool* skip, String* list, int last)
{
	scratch_buffer_clear();
	for (int i = 0; i <= last; i++)
	{
		if (skip && skip[i]) continue;
		bool diff_has = cpu_features_contains(&cpu_defaults, i);
		if (cpu_features_contains(&enabled_features, i))
		{
			if (diff_has) continue;
			scratch_buffer_append_char('+');
		}
		else
		{
			if (!diff_has) continue;
			scratch_buffer_append_char('-');
		}
		scratch_buffer_append(list[i]);
		scratch_buffer_append_char(',');
	}
	if (scratch_buffer_len()) scratch_buffer_delete(1);
	compiler.platform.features = scratch_buffer_copy();
}

<* target.c `x86features_as_diff_to_scratch`'s function static. *>
bool[X86_FEATURE_LAST + 1] x64features_skip = { [X86_FEAT_AVX5124FMAPS] = true, [X86_FEAT_AVX5124VNNIW] = true };

// target.c:617 (static)
fn void x86features_as_diff_to_scratch(CpuFeatures enabled_features, X86CpuSet set)
{
	cpu_features_set_to_features(enabled_features, x86_features_from_cpu(set), &x64features_skip, &x86_feature_name, X86_FEATURE_LAST);
}
// target.c:623 (static)
fn void x86_features_add_feature(CpuFeatures* cpu_features, X86Feature feature)
{
	cpu_features_add_feature_single(cpu_features, feature);
	switch (feature)
	{
		case X86_FEAT_SSE2:
		case X86_FEAT_GFNI:
		case X86_FEAT_PCLMUL:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE);
			return;
		case X86_FEAT_AES:
		case X86_FEAT_SSE3:
		case X86_FEAT_SHA:
		case X86_FEAT_KL:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE2);
			return;
		case X86_FEAT_SSE4_1:
			x86_features_add_feature(cpu_features, X86_FEAT_SSSE3);
			return;
		case X86_FEAT_SSE4_A:
		case X86_FEAT_SSSE3:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE3);
			return;
		case X86_FEAT_SSE4_2:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE4_1);
			return;
		case X86_FEAT_AVX:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE4_2);
			return;
		case X86_FEAT_AVX512F:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX2);
			x86_features_add_feature(cpu_features, X86_FEAT_F16C);
			x86_features_add_feature(cpu_features, X86_FEAT_FMA);
			return;
		case X86_FEAT_AVX2:
		case X86_FEAT_F16C:
		case X86_FEAT_FMA:
		case X86_FEAT_SM3:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX);
			return;
		case X86_FEAT_VAES:
			x86_features_add_feature(cpu_features, X86_FEAT_AES);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX);
			return;
		case X86_FEAT_VPCLMULQDQ:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX);
			x86_features_add_feature(cpu_features, X86_FEAT_PCLMUL);
			return;
		case X86_FEAT_XSAVEC:
		case X86_FEAT_XSAVEOPT:
		case X86_FEAT_XSAVES:
			x86_features_add_feature(cpu_features, X86_FEAT_XSAVE);
			return;
		case X86_FEAT_AVX512CD:
		case X86_FEAT_AVX512BW:
		case X86_FEAT_AVX512DQ:
		case X86_FEAT_AVX512ER:
		case X86_FEAT_AVX512PF:
		case X86_FEAT_AVX512VL:
		case X86_FEAT_AVX512IFMA:
		case X86_FEAT_AVX512VNNI:
		case X86_FEAT_AVX512VPOPCNTDQ:
		case X86_FEAT_AVX512VP2INTERSECT:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512F);
			return;
		case X86_FEAT_FMA4:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE4_A);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX);
			return;
		case X86_FEAT_XOP:
			x86_features_add_feature(cpu_features, X86_FEAT_FMA4);
			return;
		case X86_FEAT_AMX_BF16:
		case X86_FEAT_AMX_FP16:
		case X86_FEAT_AMX_FP8:
		case X86_FEAT_AMX_INT8:
		case X86_FEAT_AMX_COMPLEX:
		case X86_FEAT_AMX_TRANSPOSE:
		case X86_FEAT_AMX_TF32:
		case X86_FEAT_AMX_MOVRS:
		case X86_FEAT_AMX_AVX512:
			x86_features_add_feature(cpu_features, X86_FEAT_AMX_TILE);
			return;
		case X86_FEAT_AVXVNNIINT8:
		case X86_FEAT_AVXVNNIINT16:
		case X86_FEAT_AVXIFMA:
		case X86_FEAT_AVXNECONVERT:
		case X86_FEAT_AVXVNNI:
		case X86_FEAT_SHA512:
		case X86_FEAT_SM4:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX2);
			return;
		case X86_FEAT_AVX512FP16:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BW);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512DQ);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VL);
			return;
		case X86_FEAT_WIDEKL:
			x86_features_add_feature(cpu_features, X86_FEAT_KL);
			return;
		case X86_FEAT_AVX512VBMI:
		case X86_FEAT_AVX512VBMI2:
		case X86_FEAT_AVX512BITALG:
		case X86_FEAT_AVX512BF16:
		case X86_FEAT_AVX512BMM:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BW);
			return;
		case X86_FEAT_AVX5124VNNIW:
		case X86_FEAT_AVX5124FMAPS:
			// Not implemented in LLVM
			return;
		case X86_FEAT_ADX:
		case X86_FEAT_AMX_TILE:
		case X86_FEAT_BMI:
		case X86_FEAT_BMI2:
		case X86_FEAT_CLDEMOTE:
		case X86_FEAT_CLFLUSHOPT:
		case X86_FEAT_CLWB:
		case X86_FEAT_CLZERO:
		case X86_FEAT_CMOV:
		case X86_FEAT_CMPXCHG16B:
		case X86_FEAT_CMPXCHG8B:
		case X86_FEAT_CMPCCXADD:
		case X86_FEAT_CRC32:
		case X86_FEAT_ENQCMD:
		case X86_FEAT_FSGSBASE:
		case X86_FEAT_FXSR:
		case X86_FEAT_HRESET:
		case X86_FEAT_INVPCID:
		case X86_FEAT_JMPABS:
		case X86_FEAT_LWP:
		case X86_FEAT_LZCNT:
		case X86_FEAT_MWAITX:
		case X86_FEAT_MMX:
		case X86_FEAT_MOVBE:
		case X86_FEAT_MOVDIR64B:
		case X86_FEAT_MOVDIRI:
		case X86_FEAT_MOVRS:
		case X86_FEAT_PCONFIG:
		case X86_FEAT_POPCNT:
		case X86_FEAT_PKU:
		case X86_FEAT_PREFETCHI:
		case X86_FEAT_PREFETCHWT1:
		case X86_FEAT_PRFCHW:
		case X86_FEAT_PTWRITE:
		case X86_FEAT_RAOINT:
		case X86_FEAT_RDPID:
		case X86_FEAT_RDPRU:
		case X86_FEAT_RDRND:
		case X86_FEAT_RDSEED:
		case X86_FEAT_RTM:
		case X86_FEAT_SSE:
		case X86_FEAT_SAHF:
		case X86_FEAT_SERIALIZE:
		case X86_FEAT_SGX:
		case X86_FEAT_SHSTK:
		case X86_FEAT_TBM:
		case X86_FEAT_TSXLDTRK:
		case X86_FEAT_UINTR:
		case X86_FEAT_VZEROUPPER:
		case X86_FEAT_WAITPKG:
		case X86_FEAT_WBNOINVD:
		case X86_FEAT_X87:
		case X86_FEAT_XSAVE:
		case X86_FEAT_EVEX512:
		case X86_FEAT_USERMSR:
		case X86_FEAT_APX_EGPR:
		case X86_FEAT_APX_PUSH2POP2:
		case X86_FEAT_APX_PPX:
		case X86_FEAT_APX_NDD:
		case X86_FEAT_APX_CCMP:
		case X86_FEAT_APX_NF:
		case X86_FEAT_APX_CF:
		case X86_FEAT_APX_ZU:
			return;
		case X86_FEAT_AVX10_1_512:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX10_1_256);
			x86_features_add_feature(cpu_features, X86_FEAT_EVEX512);
			nextcase X86_FEAT_AVX10_2_512;
		case X86_FEAT_AVX10_2_512:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX10_1_256);
			x86_features_add_feature(cpu_features, X86_FEAT_EVEX512);
			return;
		case X86_FEAT_AVX10_1_256:
		case X86_FEAT_AVX10_2_256:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512CD);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VBMI);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VBMI2);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512IFMA);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VNNI);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BF16);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VPOPCNTDQ);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BITALG);
			x86_features_add_feature(cpu_features, X86_FEAT_VAES);
			x86_features_add_feature(cpu_features, X86_FEAT_VPCLMULQDQ);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512FP16);
			return;
		case X86_FEAT_AVX10_1:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX10_1_256);
			return;
		case X86_FEAT_AVX10_2:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX10_2_256);
			return;
		case X86_FEAT_SOFT_FLOAT:
			return;
	}
	unreachable();
}

// target.c:844 (static)
fn void x64features_limit_from_capability(CpuFeatures* cpu_features, X86VectorCapability capability)
{
	switch (capability)
	{
		case X86VECTOR_NONE:
			cpu_features_remove_feature(cpu_features, X86_FEAT_MMX);
			nextcase X86VECTOR_MMX;
		case X86VECTOR_MMX:
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE2);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE3);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSSE3);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE4_1);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE4_2);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SSE4_A);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AES);
			cpu_features_remove_feature(cpu_features, X86_FEAT_GFNI);
			cpu_features_remove_feature(cpu_features, X86_FEAT_KL);
			cpu_features_remove_feature(cpu_features, X86_FEAT_WIDEKL);
			cpu_features_remove_feature(cpu_features, X86_FEAT_PCLMUL);
			cpu_features_remove_feature(cpu_features, X86_FEAT_SHA);
			nextcase X86VECTOR_SSE;
		case X86VECTOR_SSE:
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX2);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVXNECONVERT);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVXVNNI);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVXIFMA);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVXVNNIINT8);
			cpu_features_remove_feature(cpu_features, X86_FEAT_F16C);
			cpu_features_remove_feature(cpu_features, X86_FEAT_FMA);
			cpu_features_remove_feature(cpu_features, X86_FEAT_FMA4);
			cpu_features_remove_feature(cpu_features, X86_FEAT_VAES);
			cpu_features_remove_feature(cpu_features, X86_FEAT_VPCLMULQDQ);
			cpu_features_remove_feature(cpu_features, X86_FEAT_XOP);
			nextcase X86VECTOR_AVX;
		case X86VECTOR_AVX:
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512DQ);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512BW);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512CD);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VL);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512ER);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512F);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512FP16);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512BF16);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX5124FMAPS);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512BITALG);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX5124VNNIW);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VNNI);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512IFMA);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VBMI);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VBMI2);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512PF);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VP2INTERSECT);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512VPOPCNTDQ);
			nextcase X86VECTOR_AVX512;
		case X86VECTOR_AVX512:
			cpu_features_remove_feature(cpu_features, X86_FEAT_EVEX512);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX10_1_512);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX10_1_256);
			cpu_features_remove_feature(cpu_features, X86_FEAT_USERMSR);
			cpu_features_remove_feature(cpu_features, X86_FEAT_AVX512BMM);
		case X86VECTOR_CPU:
		case X86VECTOR_DEFAULT:
			break;
	}
}


// target.c:982 (static)
fn void x86features_from_cpu(CpuFeatures* cpu_features, X86CpuSet cpu_set)
{
	*cpu_features = CPU_FEATURE_ZERO;
	switch (cpu_set)
	{
		case X86CPU_AVX512:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512F);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512CD);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VPOPCNTDQ);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BW);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512DQ);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BF16);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VL);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512IFMA);
			x86_features_add_feature(cpu_features, X86_FEAT_SHA);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512BITALG);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VBMI);
			x86_features_add_feature(cpu_features, X86_FEAT_AVX512VBMI2);
			x86_features_add_feature(cpu_features, X86_FEAT_AVXVNNI);
			x86_features_add_feature(cpu_features, X86_FEAT_GFNI);
			x86_features_add_feature(cpu_features, X86_FEAT_RDPID);
			x86_features_add_feature(cpu_features, X86_FEAT_VAES);
			x86_features_add_feature(cpu_features, X86_FEAT_VPCLMULQDQ);
			x86_features_add_feature(cpu_features, X86_FEAT_PKU);
			nextcase X86CPU_AVX2_V2;
		case X86CPU_AVX2_V2:
			x86_features_add_feature(cpu_features, X86_FEAT_AES);
			x86_features_add_feature(cpu_features, X86_FEAT_ADX);
			x86_features_add_feature(cpu_features, X86_FEAT_RDSEED);
			x86_features_add_feature(cpu_features, X86_FEAT_PRFCHW);
			x86_features_add_feature(cpu_features, X86_FEAT_XSAVES);
			x86_features_add_feature(cpu_features, X86_FEAT_XSAVEC);
			x86_features_add_feature(cpu_features, X86_FEAT_CLFLUSHOPT);
			nextcase X86CPU_AVX2_V1;
		case X86CPU_AVX2_V1:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX2);
			x86_features_add_feature(cpu_features, X86_FEAT_BMI);
			x86_features_add_feature(cpu_features, X86_FEAT_BMI2);
			x86_features_add_feature(cpu_features, X86_FEAT_F16C);
			x86_features_add_feature(cpu_features, X86_FEAT_FMA);
			x86_features_add_feature(cpu_features, X86_FEAT_LZCNT);
			x86_features_add_feature(cpu_features, X86_FEAT_MOVBE);
			x86_features_add_feature(cpu_features, X86_FEAT_XSAVEOPT);
			x86_features_add_feature(cpu_features, X86_FEAT_PCLMUL);
			x86_features_add_feature(cpu_features, X86_FEAT_FSGSBASE);
			x86_features_add_feature(cpu_features, X86_FEAT_RDRND);
			x86_features_add_feature(cpu_features, X86_FEAT_LZCNT);
			nextcase X86CPU_AVX1;
		case X86CPU_AVX1:
			x86_features_add_feature(cpu_features, X86_FEAT_AVX);
			x86_features_add_feature(cpu_features, X86_FEAT_PCLMUL);
			x86_features_add_feature(cpu_features, X86_FEAT_XSAVE);
			nextcase X86CPU_SSE4;
		case X86CPU_SSE4:
			x86_features_add_feature(cpu_features, X86_FEAT_SSE4_1);
			x86_features_add_feature(cpu_features, X86_FEAT_SSE4_2);
			x86_features_add_feature(cpu_features, X86_FEAT_POPCNT);
			x86_features_add_feature(cpu_features, X86_FEAT_CRC32);
			nextcase X86CPU_SSSE3;
		case X86CPU_SSSE3:
			x86_features_add_feature(cpu_features, X86_FEAT_SAHF);
			x86_features_add_feature(cpu_features, X86_FEAT_SSSE3);
			x86_features_add_feature(cpu_features, X86_FEAT_CMPXCHG16B);
			nextcase X86CPU_DEFAULT;
		case X86CPU_DEFAULT:
		case X86CPU_BASELINE:
			x86_features_add_feature(cpu_features, X86_FEAT_CMPXCHG8B);
			x86_features_add_feature(cpu_features, X86_FEAT_MMX);
			x86_features_add_feature(cpu_features, X86_FEAT_FXSR);
			x86_features_add_feature(cpu_features, X86_FEAT_SSE);
			x86_features_add_feature(cpu_features, X86_FEAT_SSE2);
			x86_features_add_feature(cpu_features, X86_FEAT_CMOV);
			return;
		case X86CPU_NATIVE:
			x86_features_from_host(cpu_features);
			return;
	}
	unreachable();
}


// target.c:832 (static)
fn void cpu_features_remove_feature(CpuFeatures* cpu_features, int feature)
{
	if (feature < 64)
	{
		cpu_features.bits[0] &= ~(1UL << feature);
	}
	else
	{
		cpu_features.bits[1] &= ~(1UL << ((feature - 64) & 63));
	}
}

// target.c:913 (static)
fn String x86_cpu_from_set(X86CpuSet set)
{
	switch (set)
	{
		case X86CPU_DEFAULT:
		case X86CPU_BASELINE:
		case X86CPU_SSSE3:
			return "x86-64";
		case X86CPU_SSE4:
		case X86CPU_AVX1:
			return "x86-64-v2";
		case X86CPU_AVX2_V1:
		case X86CPU_AVX2_V2:
			return "x86-64-v3";
		case X86CPU_AVX512:
			return "x86-64-v4";
		case X86CPU_NATIVE:
			// c3c without LLVM: hostinfo_x86_cpu_name().
			return "x86-64";
	}
	unreachable();
}

// target.c:939 (static)
fn void x86_features_from_host(CpuFeatures* cpu_features)
{
	// c3c without LLVM: hostinfo_x86_features(), which detects nothing (TODO in c3c).
}

// target.c:1062 (static)
fn bool cpu_has_all_features(CpuFeatures* feature_to_test, CpuFeatures* features_to_match)
{
	return (feature_to_test.bits[0] & features_to_match.bits[0]) == features_to_match.bits[0]
		&& (feature_to_test.bits[1] & features_to_match.bits[1]) == features_to_match.bits[1];
}

// target.c:1068 (static)
fn X86CpuSet x64_cpu_default()
{
	CpuFeatures features;
	x86_features_from_host(&features);
	CpuFeatures other_features;
	x86features_from_cpu(&other_features, X86CPU_AVX2_V1);
	if (cpu_has_all_features(&features, &other_features)) return X86CPU_AVX2_V1;
	x86features_from_cpu(&other_features, X86CPU_AVX1);
	if (cpu_has_all_features(&features, &other_features)) return X86CPU_AVX1;
	x86features_from_cpu(&other_features, X86CPU_SSE4);
	if (cpu_has_all_features(&features, &other_features)) return X86CPU_SSE4;
	x86features_from_cpu(&other_features, X86CPU_SSSE3);
	if (cpu_has_all_features(&features, &other_features)) return X86CPU_SSSE3;
	return X86CPU_BASELINE;
}

// target.c:1084 (static)
fn void target_setup_x64_abi(BuildTarget* target)
{
	compiler.platform.abi = X64;
	X86CpuSet cpu_set;
	compiler.platform.x64.is_win64 = compiler.platform.os == WIN32;
	bool is_native = target.arch_os_target == default_target;
	if (!is_native && target.feature.x86_cpu_set == X86CPU_NATIVE) target.feature.x86_cpu_set = X86CPU_DEFAULT;
	if (target.feature.x86_cpu_set != X86CPU_DEFAULT)
	{
		cpu_set = target.feature.x86_cpu_set;
	}
	else
	{
		cpu_set = is_native ? x64_cpu_default() : X86CPU_AVX1;
		if (cpu_set > X86CPU_AVX1) cpu_set = X86CPU_AVX1;
	}

	compiler.platform.cpu = x86_cpu_from_set(cpu_set);
	CpuFeatures cpu_features;
	x86features_from_cpu(&cpu_features, cpu_set);
	x64features_limit_from_capability(&cpu_features, target.feature.x86_vector_capability);
	if (target.feature.soft_float == SOFT_FLOAT_YES) compiler.platform.x64.soft_float = true;
	if (target.feature.pass_win64_simd_as_arrays == WIN64_SIMD_ARRAY) compiler.platform.x64.win64_simd_as_array = true;
	if (compiler.platform.x64.soft_float) cpu_features_add_feature_single(&cpu_features, X86_FEAT_SOFT_FLOAT);

	update_cpu_features(compiler.build.cpu_flags, &cpu_features, &x86_feature_name, X86_FEATURE_LAST);

	x86features_as_diff_to_scratch(cpu_features, cpu_set);

	// c3c: ENV_TYPE_GNU only logs "Mingw" (is_mingw64 is commented out).
	if (compiler.platform.os == LINUX || compiler.platform.os == NETBSD)
	{
		compiler.platform.x64.pass_int128_vector_in_mem = true;
	}
	compiler.platform.x64.features = cpu_features;
	if (cpu_features_contains(&cpu_features, X86_FEAT_AVX512F))
	{
		compiler.platform.x64.native_vector_size_avx = 64;
		compiler.platform.x64.align_simd_default = 512;
	}
	else if (cpu_features_contains(&cpu_features, X86_FEAT_AVX))
	{
		compiler.platform.x64.native_vector_size_avx = 32;
		compiler.platform.x64.align_simd_default = 256;
	}
	else if (cpu_features_contains(&cpu_features, X86_FEAT_SSE))
	{
		compiler.platform.x64.native_vector_size_avx = 16;
		compiler.platform.x64.align_simd_default = 128;
	}
}

// target.c:1186 (static)
fn String arch_to_target_triple(ArchOsTarget target, LinuxLibc linux_libc)
{
	switch (target)
	{
		case FREEBSD_X86: return "i386-unknown-freebsd";
		case OPENBSD_X86: return "i386-unknown-openbsd";
		case NETBSD_X86: return "i386-unknown-netbsd";
		case MCU_X86: return "i386-pc-elfiamcu";
		case LINUX_X86: return linux_libc == LINUX_LIBC_MUSL ? "i386-unknown-linux-musl" : "i386-unknown-linux";
		case ELF_X86: return "i386-unknown-elf";
		case MACOS_X64: return "x86_64-apple-macosx";
		case LINUX_X64: return linux_libc == LINUX_LIBC_MUSL ? "x86_64-pc-linux-musl" : "x86_64-pc-linux-gnu";
		case WINDOWS_X64: return "x86_64-pc-windows-msvc";
		case MINGW_X64: return "x86_64-w64-windows-gnu";
		case NETBSD_X64: return "x86_64-pc-netbsd";
		case FREEBSD_X64: return "x86_64-pc-freebsd";
		case OPENBSD_X64: return "x86_64-pc-openbsd";
		case ELF_X64: return "x86_64-unknown-elf";
		case ANDROID_AARCH64: return "aarch64-linux-android";
		case ANDROID_X86_64: return "x86_64-linux-android";
		case LINUX_AARCH64: return linux_libc == LINUX_LIBC_MUSL ? "aarch64-unknown-linux-musl" : "aarch64-unknown-linux-gnu";
		case IOS_AARCH64: return "arm64-apple-ios";
		case IOS_AARCH64_SIM: return "arm64-apple-ios-simulator";
		case IOS_X64_SIM: return "x86_64-apple-ios-simulator";
		case MACOS_AARCH64: return "aarch64-apple-macosx";
		case ELF_AARCH64: return "aarch64-unknown-elf";
		case WINDOWS_AARCH64: return "aarch64-pc-windows-msvc";
		case NETBSD_AARCH64: return "aarch64-unknown-netbsd";
		case LINUX_RISCV32: return linux_libc == LINUX_LIBC_MUSL ? "riscv32-unknown-linux-musl" : "riscv32-unknown-linux-gnu";
		case ELF_RISCV32: return "riscv32-unknown-elf";
		case LINUX_RISCV64: return linux_libc == LINUX_LIBC_MUSL ? "riscv64-unknown-linux-musl" : "riscv64-unknown-linux-gnu";
		case ELF_RISCV64: return "riscv64-unknown-elf";
		case ELF_XTENSA: return "xtensa-unknown-elf";
		case ELF_AVR: return "avr-unknown-unknown";
		case WASM32: return "wasm32-unknown-unknown";
		case WASM64: return "wasm64-unknown-unknown";
		case EMSCRIPTEN_WASM32: return "wasm32-unknown-emscripten";
		case DEFAULT: unreachable();
	}
	unreachable();
}

// target.c:1228 (static)
fn bool arch_is_supported(ArchType arch)
{
	switch (arch)
	{
		case WASM32:
		case WASM64:
		case X86_64:
		case AARCH64:
		case RISCV32:
		case RISCV64:
			return true;
		default:
			return false;
	}
}
// target.c:1244 (static)
fn ArchType arch_from_llvm_string(StringSlice slice)
{
	if (slice_strcmp(slice, "i386")) return ArchType.X86;
	if (slice_strcmp(slice, "i486")) return ArchType.X86;
	if (slice_strcmp(slice, "i586")) return ArchType.X86;
	if (slice_strcmp(slice, "i686")) return ArchType.X86;
	if (slice_strcmp(slice, "i786")) return ArchType.X86;
	if (slice_strcmp(slice, "i886")) return ArchType.X86;
	if (slice_strcmp(slice, "i986")) return ArchType.X86;
	if (slice_strcmp(slice, "aarch64")) return ArchType.AARCH64;
	if (slice_strcmp(slice, "arm64")) return ArchType.AARCH64;
	if (slice_strcmp(slice, "aarch64_be")) return ArchType.AARCH64_BE;
	if (slice_strcmp(slice, "aarch64_32")) return ArchType.AARCH64_32;
	if (slice_strcmp(slice, "arm64_32")) return ArchType.AARCH64_32;
	if (slice_strcmp(slice, "arm")) return ArchType.ARM;
	if (slice_strcmp(slice, "xscale")) return ArchType.ARM;
	if (slice_strcmp(slice, "armeb")) return ArchType.ARMB;
	if (slice_strcmp(slice, "xscaleeb")) return ArchType.ARMB;
	if (slice_strcmp(slice, "arc")) return ArchType.ARC;
	if (slice_strcmp(slice, "avr")) return ArchType.AVR;
	if (slice_strcmp(slice, "bpfeb")) return ArchType.BPFEB;
	if (slice_strcmp(slice, "bpfel")) return ArchType.BPFEL;
	if (slice_strcmp(slice, "hexagon")) return ArchType.HEXAGON;
	if (slice_strcmp(slice, "mips")) return ArchType.MIPS;
	if (slice_strcmp(slice, "mipseb")) return ArchType.MIPS;
	if (slice_strcmp(slice, "mipsallegrex")) return ArchType.MIPS;
	if (slice_strcmp(slice, "mipsisa32r6")) return ArchType.MIPS;
	if (slice_strcmp(slice, "mipsr6")) return ArchType.MIPS;
	if (slice_strcmp(slice, "mipsel")) return ArchType.MIPSEL;
	if (slice_strcmp(slice, "mipsallegrexel")) return ArchType.MIPSEL;
	if (slice_strcmp(slice, "mipsisa32r6el")) return ArchType.MIPSEL;
	if (slice_strcmp(slice, "mipsr6el")) return ArchType.MIPSEL;
	if (slice_strcmp(slice, "mips64")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mips64eb")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mipsn32")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mipsisa64r6")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mips64r6")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mipsn32r6")) return ArchType.MIPS64;
	if (slice_strcmp(slice, "mips64el")) return ArchType.MIPS64EL;
	if (slice_strcmp(slice, "mipsn32el")) return ArchType.MIPS64EL;
	if (slice_strcmp(slice, "mipsisa64r6el")) return ArchType.MIPS64EL;
	if (slice_strcmp(slice, "mips64r6el")) return ArchType.MIPS64EL;
	if (slice_strcmp(slice, "mipsn32r6el")) return ArchType.MIPS64EL;
	if (slice_strcmp(slice, "msp430")) return ArchType.MSP430;
	if (slice_strcmp(slice, "powerpc64")) return ArchType.PPC64;
	if (slice_strcmp(slice, "ppu")) return ArchType.PPC64;
	if (slice_strcmp(slice, "ppc64")) return ArchType.PPC64;
	if (slice_strcmp(slice, "powerpc64le")) return ArchType.PPC64LE;
	if (slice_strcmp(slice, "ppc64le")) return ArchType.PPC64LE;
	if (slice_strcmp(slice, "powerpc")) return ArchType.PPC;
	if (slice_strcmp(slice, "ppc")) return ArchType.PPC;
	if (slice_strcmp(slice, "ppc32")) return ArchType.PPC;
	if (slice_strcmp(slice, "r600")) return ArchType.R600;
	if (slice_strcmp(slice, "amdgcn")) return ArchType.AMDGCN;
	if (slice_strcmp(slice, "riscv32")) return ArchType.RISCV32;
	if (slice_strcmp(slice, "riscv64")) return ArchType.RISCV64;
	if (slice_strcmp(slice, "sparc")) return ArchType.SPARC;
	if (slice_strcmp(slice, "sparcel")) return ArchType.SPARCEL;
	if (slice_strcmp(slice, "sparcv9")) return ArchType.SPARCV9;
	if (slice_strcmp(slice, "sparc64")) return ArchType.SPARCV9;
	if (slice_strcmp(slice, "systemz")) return ArchType.SYSTEMZ;
	if (slice_strcmp(slice, "s390x")) return ArchType.SYSTEMZ;
	if (slice_strcmp(slice, "tce")) return ArchType.TCE;
	if (slice_strcmp(slice, "tcele")) return ArchType.TCELE;
	if (slice_strcmp(slice, "thumb")) return ArchType.THUMB;
	if (slice_strcmp(slice, "thumbeb")) return ArchType.THUMBEB;
	if (slice_strcmp(slice, "x86_64")) return ArchType.X86_64;
	if (slice_strcmp(slice, "amd64")) return ArchType.X86_64;
	if (slice_strcmp(slice, "x86_64h")) return ArchType.X86_64;
	if (slice_strcmp(slice, "xcore")) return ArchType.XCORE;
	if (slice_strcmp(slice, "xtensa")) return ArchType.XTENSA;
	if (slice_strcmp(slice, "nvptx")) return ArchType.NVPTX;
	if (slice_strcmp(slice, "nvptx64")) return ArchType.NVPTX64;
	if (slice_strcmp(slice, "le32")) return ArchType.LE32;
	if (slice_strcmp(slice, "le64")) return ArchType.LE64;
	if (slice_strcmp(slice, "amdil")) return ArchType.AMDIL;
	if (slice_strcmp(slice, "amdil64")) return ArchType.AMDIL64;
	if (slice_strcmp(slice, "hsail")) return ArchType.HSAIL;
	if (slice_strcmp(slice, "hsail64")) return ArchType.HSAIL64;
	if (slice_strcmp(slice, "spir")) return ArchType.SPIR;
	if (slice_strcmp(slice, "spir64")) return ArchType.SPIR64;
	if (slice_strcmp(slice, "kalimba")) return ArchType.KALIMBA;
	if (slice_strcmp(slice, "lanai")) return ArchType.LANAI;
	if (slice_strcmp(slice, "shave")) return ArchType.SHAVE;
	if (slice_strcmp(slice, "wasm32")) return ArchType.WASM32;
	if (slice_strcmp(slice, "wasm64")) return ArchType.WASM64;
	if (slice_strcmp(slice, "renderscript32")) return ArchType.RSCRIPT32;
	if (slice_strcmp(slice, "renderscript64")) return ArchType.RSCRIPT64;
	return ArchType.UNKNOWN;
}

// target.c:1338 (static)
fn EnvironmentType environment_type_from_llvm_string(StringSlice env)
{
	// Remove trailing parts.
	for (usz i = 0; i < env.len; i++)
	{
		if (env[i] < 'A')
		{
			env = env[:i];
			break;
		}
	}
	if (slice_strcmp(env, "gnu")) return EnvironmentType.GNU;
	if (slice_strcmp(env, "gnuabin32")) return EnvironmentType.GNUABIN32;
	if (slice_strcmp(env, "gnuabi64")) return EnvironmentType.GNUABI64;
	if (slice_strcmp(env, "gnueabihf")) return EnvironmentType.GNUEABIHF;
	if (slice_strcmp(env, "gnueabi")) return EnvironmentType.GNUEABI;
	if (slice_strcmp(env, "gnux32")) return EnvironmentType.GNUX32;
	if (slice_strcmp(env, "code16")) return EnvironmentType.CODE16;
	if (slice_strcmp(env, "eabi")) return EnvironmentType.EABI;
	if (slice_strcmp(env, "eabihf")) return EnvironmentType.EABIHF;
	if (slice_strcmp(env, "elfv1")) return EnvironmentType.ELFV1;
	if (slice_strcmp(env, "elfv2")) return EnvironmentType.ELFV2;
	if (slice_strcmp(env, "android")) return EnvironmentType.ANDROID;
	if (slice_strcmp(env, "musl")) return EnvironmentType.MUSL;
	if (slice_strcmp(env, "musleabi")) return EnvironmentType.MUSLEABI;
	if (slice_strcmp(env, "musleabihf")) return EnvironmentType.MUSLEABIHF;
	if (slice_strcmp(env, "msvc")) return EnvironmentType.MSVC;
	if (slice_strcmp(env, "itanium")) return EnvironmentType.ITANIUM;
	if (slice_strcmp(env, "cygnus")) return EnvironmentType.CYGNUS;
	if (slice_strcmp(env, "coreclr")) return EnvironmentType.CORECLR;
	if (slice_strcmp(env, "simulator")) return EnvironmentType.SIMULATOR;
	if (slice_strcmp(env, "macabi")) return EnvironmentType.MACABI;
	return EnvironmentType.UNKNOWN;
}

// target.c:1377 (static)
fn OsType os_from_llvm_string(StringSlice os_string)
{
	// Remove trailing parts.
	for (usz i = 0; i < os_string.len; i++)
	{
		if (os_string[i] < 'A')
		{
			os_string = os_string[:i];
			break;
		}
	}
	if (slice_strcmp(os_string, "ananas")) return OsType.ANANAS;
	if (slice_strcmp(os_string, "cloudabi")) return OsType.CLOUD_ABI;
	if (slice_strcmp(os_string, "darwin")) return OsType.MACOSX;
	if (slice_strcmp(os_string, "dragonfly")) return OsType.DRAGON_FLY;
	if (slice_strcmp(os_string, "freebsd")) return OsType.FREEBSD;
	if (slice_strcmp(os_string, "fuchsia")) return OsType.FUCHSIA;
	if (slice_strcmp(os_string, "ios")) return OsType.IOS;
	if (slice_strcmp(os_string, "kfreebsd")) return OsType.KFREEBSD;
	if (slice_strcmp(os_string, "linux")) return OsType.LINUX;
	if (slice_strcmp(os_string, "lv2")) return OsType.PS3;
	if (slice_strcmp(os_string, "macosx")) return OsType.MACOSX;
	if (slice_strcmp(os_string, "netbsd")) return OsType.NETBSD;
	if (slice_strcmp(os_string, "openbsd")) return OsType.OPENBSD;
	if (slice_strcmp(os_string, "solaris")) return OsType.SOLARIS;
	if (slice_strcmp(os_string, "windows")) return OsType.WIN32;
	if (slice_strcmp(os_string, "haiku")) return OsType.HAIKU;
	if (slice_strcmp(os_string, "minix")) return OsType.MINIX;
	if (slice_strcmp(os_string, "rtems")) return OsType.RTEMS;
	if (slice_strcmp(os_string, "nacl")) return OsType.NACL;
	if (slice_strcmp(os_string, "cnk")) return OsType.CNK;
	if (slice_strcmp(os_string, "aix")) return OsType.AIX;
	if (slice_strcmp(os_string, "cuda")) return OsType.CUDA;
	if (slice_strcmp(os_string, "nvcl")) return OsType.NVOPENCL;
	if (slice_strcmp(os_string, "amdhsa")) return OsType.AMDHSA;
	if (slice_strcmp(os_string, "ps4")) return OsType.PS4;
	if (slice_strcmp(os_string, "elfiamcu")) return OsType.ELFIAMCU;
	if (slice_strcmp(os_string, "tvos")) return OsType.TVOS;
	if (slice_strcmp(os_string, "watchos")) return OsType.WATCHOS;
	if (slice_strcmp(os_string, "mesa3d")) return OsType.MESA3D;
	if (slice_strcmp(os_string, "contiki")) return OsType.CONTIKI;
	if (slice_strcmp(os_string, "amdpal")) return OsType.AMDPAL;
	if (slice_strcmp(os_string, "hermit")) return OsType.HERMITCORE;
	if (slice_strcmp(os_string, "hurd")) return OsType.HURD;
	if (slice_strcmp(os_string, "wasi")) return OsType.WASI;
	if (slice_strcmp(os_string, "emscripten")) return OsType.EMSCRIPTEN;
	if (slice_strcmp(os_string, "elf")) return OsType.NONE;
	if (slice_strcmp(os_string, "android")) return OsType.ANDROID;
	return OsType.UNKNOWN;
}

// target.c:1430 (static)
fn VendorType vendor_from_llvm_string(StringSlice slice)
{
	if (slice_strcmp(slice, "apple")) return VendorType.APPLE;
	if (slice_strcmp(slice, "pc")) return VendorType.PC;
	if (slice_strcmp(slice, "scei")) return VendorType.SCEI;
	if (slice_strcmp(slice, "bgp")) return VendorType.BGP;
	if (slice_strcmp(slice, "bgq")) return VendorType.BGQ;
	if (slice_strcmp(slice, "fsl")) return VendorType.FREESCALE;
	if (slice_strcmp(slice, "ibm")) return VendorType.IBM;
	if (slice_strcmp(slice, "img")) return VendorType.IMAGINATION_TECHNOLOGIES;
	if (slice_strcmp(slice, "mti")) return VendorType.MIPS_TECHNOLOGIES;
	if (slice_strcmp(slice, "nvidia")) return VendorType.NVIDIA;
	if (slice_strcmp(slice, "csr")) return VendorType.CSR;
	if (slice_strcmp(slice, "myriad")) return VendorType.MYRIAD;
	if (slice_strcmp(slice, "amd")) return VendorType.AMD;
	if (slice_strcmp(slice, "mesa")) return VendorType.MESA;
	if (slice_strcmp(slice, "suse")) return VendorType.SUSE;
	if (slice_strcmp(slice, "oe")) return VendorType.OPEN_EMBEDDED;
	return VendorType.UNKNOWN;
}

// ARCH_UNSUPPORTED (enums.h) spelled out as:
//   case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
//   case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
//   case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
//   case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
//   case SPIR64: case SPIR:
// OS_DARWIN_TYPES: case WATCHOS: case IOS: case TVOS: case MACOSX:
// OS_UNSUPPORTED: case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA:
//   case KFREEBSD: case PS3: case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA:
//   case NVOPENCL: case AMDHSA: case PS4: case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL:
//   case HERMITCORE: case HURD:

// target.c:1456 (static)
fn int arch_pointer_bit_width(OsType os, ArchType arch)
{
	switch (arch)
	{
		case UNKNOWN:
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			return 0;
		case ARM:
		case ARMB:
		case PPC:
		case RISCV32:
		case THUMB:
		case THUMBEB:
		case X86:
		case WASM32:
		case XTENSA:
			return 32;
		case AVR:
			return 16;
		case WASM64:
		case AARCH64:
		case AARCH64_BE:
		case RISCV64:
			return 64;
		case PPC64:
		case PPC64LE:
			if (os == PS3) return 32;
			return 64;
		case X86_64:
			if (os == NACL) return 32;
			return 64;
	}
	unreachable();
}

// target.c:1491 (static)
fn int arch_int_register_bit_width(OsType os, ArchType arch)
{
	switch (arch)
	{
		case UNKNOWN:
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			return 0;
		case ARM:
		case ARMB:
		case PPC:
		case RISCV32:
		case THUMB:
		case THUMBEB:
		case X86:
		case WASM32:
		case XTENSA:
			return 32;
		case AVR:
			return 16;
		case WASM64:
		case AARCH64:
		case AARCH64_BE:
		case RISCV64:
			return 64;
		case PPC64:
		case PPC64LE:
			if (os == PS3) return 32;
			return 64;
		case X86_64:
			if (os == NACL) return 32;
			return 64;
	}
	unreachable();
}

// target.c:1526 (static)
fn bool os_target_supports_float16(OsType os, ArchType arch)
{
	switch (arch)
	{
		case AARCH64:
			return true;
		case ARM:
			// Supported on fullfp16 and mve.fp in Clang
			return false;
		default:
			// Supported by AMDGPU
			return false;
	}
}

// target.c:1540 (static)
fn bool os_target_supports_float128(OsType os, ArchType arch)
{
	switch (arch)
	{
		case RISCV64:
		case RISCV32:
			return true;
		case AARCH64:
			return false;
		case PPC64:
			if (os == MACOSX) return true;
			return false;
		case PPC:
			if (os == MACOSX) return false; // Only for later OS X 10.4+
			return false;
		case X86:
			if (os == MACOSX) return true;
			return false;
		default:
			return false;
	}
}

// target.c:1563 (static)
fn bool os_target_supports_vec(OsType os, ArchType arch, int bits, bool is_int)
{
	if (bits != 64 && bits != 128) return false;
	switch (arch)
	{
		case AARCH64:
		case PPC64:
		case PPC:
			return true;
		case X86:
			if (os == MACOSX)
			{
				// 64i 128f 128i
				return bits == 128 || is_int;
			}
			return false;
		default:
			return false;
	}
}

// target.c:1584 (static)
fn ObjectFormatType object_format_from_os(OsType os, ArchType arch_type)
{
	switch (os)
	{
		case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
		case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
		case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
			return UNSUPPORTED;
		case UNKNOWN:
		case NONE:
			if (arch_is_wasm(arch_type)) return WASM;
			return ELF;
		case LINUX:
		case ANDROID:
		case NETBSD:
		case OPENBSD:
		case FREEBSD:
			return ELF;
		case WATCHOS: case IOS: case TVOS: case MACOSX:
			return MACHO;
		case WIN32:
			return COFF;
		case WASI:
		case EMSCRIPTEN:
			return WASM;
	}
	unreachable();
}

// target.c:1610 (static)
fn bool os_target_supports_int128(OsType os, ArchType arch)
{
	switch (arch)
	{
		case RISCV64:
		case AARCH64:
		case WASM32:
		case WASM64:
			return true;
		default:
			return false;
	}
}

// target.c:1626 (static)
fn int os_target_c_type_bits(OsType os, ArchType arch, CType type)
{
	switch (os)
	{
		case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
		case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
		case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
			unreachable();
		case UNKNOWN:
			if (arch == MSP430 || arch == AVR)
			{
				switch (type)
				{
					case SHORT:
					case INT:
						return 16;
					case LONG:
						return 32;
					case LONG_LONG:
						return 64;
				}
			}
			// Use default
		case WATCHOS: case IOS: case TVOS: case MACOSX:
		case LINUX:
		case ANDROID:
		case NONE:
		case FREEBSD:
		case NETBSD:
		case OPENBSD:
		case WASI:
		case EMSCRIPTEN:
			// Use default
			break;
		case WIN32:
			switch (type)
			{
				case SHORT:
					return 16;
				case INT:
				case LONG:
					return 32;
				case LONG_LONG:
					return 64;
			}
	}
	switch (type)
	{
		case SHORT:
			return 16;
		case INT:
			return 32;
		case LONG:
			return arch_pointer_bit_width(os, arch);
		case LONG_LONG:
			return 64;
	}
	unreachable();
}

// target.c:1692 (static)
fn AlignData os_target_alignment_of_int(OsType os, ArchType arch, uint bits)
{
	switch (arch)
	{
		case UNKNOWN:
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			unreachable();
		case ARM:
		case THUMB:
		case ARMB:
		case THUMBEB:
			if ((os_is_apple(os) || os == NETBSD) && bits > 32) return { 32, (int)umin(64, bits) };
			return { (int)umin(64, bits), (int)umin(64, bits) };
		case PPC64:
		case PPC:
		case PPC64LE:
		case RISCV32:
		case AVR:
		case XTENSA:
			return { (int)umin(64, bits), (int)umin(64, bits) };
		case X86_64:
		case RISCV64:
			return { (int)bits, (int)bits };
		case WASM64:
		case WASM32:
			// c3c: { MIN(64u, bits), ... } only with LLVM < 20.
			return { (int)bits, (int)bits };
		case AARCH64:
		case AARCH64_BE:
			if (bits < 32) return { (int)bits, 32 };
			return { (int)bits, (int)bits };
		case X86:
			if (bits <= 32) return { (int)bits, (int)bits };
			if (bits == 128) return { 128, 128 };
			if (os == ELFIAMCU) return { 32, 32 };
			if (os == WIN32 || os == NACL) return { 64, 64 };
			return { 32, 64 };
	}
	unreachable();
}

// target.c:1738 (static)
fn bool arch_big_endian(ArchType arch)
{
	switch (arch)
	{
		case UNKNOWN:
		case X86:
		case AARCH64:
		case ARM:
		case THUMB:
		case PPC64LE:
		case X86_64:
		case RISCV32:
		case RISCV64:
		case WASM32:
		case WASM64:
		case AVR:
		case XTENSA:
			return false;
		case ARMB:
		case THUMBEB:
		case AARCH64_BE:
		case PPC64:
		case PPC:
			return true;
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			unreachable();
	}
	unreachable();
}

// target.c:1769 (static)
fn AlignData os_target_alignment_of_float(OsType os, ArchType arch, uint bits)
{
	switch (arch)
	{
		case UNKNOWN:
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			unreachable();
		case X86:
			if (os == ELFIAMCU && bits >= 32) return { 32, 32 };
			if (os == WIN32 || os == NACL)
			{
				return { (int)bits, (int)bits };
			}
			return { (int)umin(32, bits), (int)bits };
		case AARCH64:
		case AARCH64_BE:
		case PPC64:
		case PPC64LE:
		case PPC:
		case RISCV32:
		case RISCV64:
		case WASM32:
		case WASM64:
		case AVR:
		case XTENSA:
			return { (int)bits, (int)bits };
		case ARM:
		case THUMB:
		case THUMBEB:
		case ARMB:
			if ((os_is_apple(os) || os == NETBSD) && bits == 64)
			{
				return { 32, (int)bits };
			}
			return { (int)bits, (int)bits };
		case X86_64:
			if (bits == 128 && os == ELFIAMCU) return { 32, 32 };
			return { (int)bits, (int)bits };
	}
	unreachable();
}

// target.c:1813 (static)
fn String os_dynamic_library_suffix(OsType os)
{
	if (os_is_apple(os)) return ".dylib";
	if (os == WIN32) return ".dll";
	return ".so";
}

// target.c:1820 (static)
fn RelocModel arch_os_reloc_default(ArchType arch, OsType os, EnvironmentType env, bool library)
{
	if (library)
	{
		switch (os)
		{
			case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
			case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
			case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
				unreachable();
			case OPENBSD:
				return RELOC_SMALL_PIC;
			case WATCHOS: case IOS: case TVOS: case MACOSX:
				return RELOC_BIG_PIC;
			case WIN32:
				if (arch == X86) return RELOC_NONE;
				return RELOC_BIG_PIC;
			case LINUX:
			case ANDROID:
				return RELOC_BIG_PIC;
			case WASI:
			case EMSCRIPTEN:
				// Same as System V i386?
				return RELOC_NONE;
			case FREEBSD:
			case NETBSD:
			case UNKNOWN:
			case NONE:
				switch (arch)
				{
					case MIPS64:
					case MIPS64EL:
						return RELOC_SMALL_PIC;
					default:
						return RELOC_NONE;
				}
		}
		unreachable();
	}
	switch (os)
	{
		case UNKNOWN:
		case NONE:
		case FREEBSD:
		case NETBSD:
			switch (arch)
			{
				case MIPS64:
				case MIPS64EL:
					return RELOC_SMALL_PIE;
				default:
					return RELOC_NONE;
			}
		case WATCHOS: case IOS: case TVOS: case MACOSX:
			return RELOC_BIG_PIE;
		case WIN32:
			if (arch == X86) return RELOC_NONE;
			return RELOC_BIG_PIE;
		case WASI:
		case EMSCRIPTEN:
			return RELOC_NONE;
		case LINUX:
		case ANDROID:
			return RELOC_BIG_PIE;
		case OPENBSD:
			return RELOC_SMALL_PIE;
		case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
		case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
		case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
			unreachable();
	}
	unreachable();
}

// target.c:1890 (static)
fn bool arch_os_pic_default_forced(ArchType arch, OsType os)
{
	switch (os)
	{
		case WIN32:
			return arch == X86_64;
		case WATCHOS: case IOS: case TVOS: case MACOSX:
			return arch == AARCH64 || arch == X86_64;
		case WASI:
		case EMSCRIPTEN:
		case UNKNOWN:
		case NONE:
		case FREEBSD:
		case LINUX:
		case ANDROID:
		case NETBSD:
		case OPENBSD:
			return false;
		case AIX: case HAIKU: case ANANAS: case CLOUD_ABI: case DRAGON_FLY: case FUCHSIA: case KFREEBSD: case PS3:
		case RTEMS: case SOLARIS: case MINIX: case NACL: case CNK: case CUDA: case NVOPENCL: case AMDHSA: case PS4:
		case ELFIAMCU: case MESA3D: case CONTIKI: case AMDPAL: case HERMITCORE: case HURD:
			unreachable();
	}
	unreachable();
}

<* C `MIN` on the unsigned bit sizes of the alignment helpers. *>
fn uint umin(uint a, uint b) @local => a < b ? a : b;

// target.c:2060 (static)
fn void target_setup_wasm_abi(BuildTarget* target)
{
	compiler.platform.abi = WASM;
	CpuFeatures features = CPU_FEATURE_ZERO;
	cpu_features_add_feature_single(&features, WASM_FEAT_BULK_MEMORY);
	// c3c: BULK_MEMORY_OPT / CALL_INDIRECT_OVERLONG only with LLVM > 19.
	cpu_features_add_feature_single(&features, WASM_FEAT_MULTIVALUE);
	cpu_features_add_feature_single(&features, WASM_FEAT_MUTABLE_GLOBALS);
	cpu_features_add_feature_single(&features, WASM_FEAT_NONTRAPPING_FPTORINT);
	cpu_features_add_feature_single(&features, WASM_FEAT_REFERENCE_TYPES);
	cpu_features_add_feature_single(&features, WASM_FEAT_SIGN_EXT);
	if (compiler.platform.os == EMSCRIPTEN) cpu_features_add_feature_single(&features, WASM_FEAT_ATOMICS);
	update_cpu_features(target.cpu_flags, &features, &wasm_feature_name, WASM_FEATURE_LAST);
	cpu_features_set_to_features(features, CPU_FEATURE_ZERO, null, &wasm_feature_name, WASM_FEATURE_LAST);
}

// target.c:2079 (static)
fn void target_setup_riscv_abi(BuildTarget* target)
{
	compiler.platform.riscv.xlen = arch_pointer_bit_width(compiler.platform.os, compiler.platform.arch) / 8; // pointer width
	RiscvCpuSet cpu = target.feature.riscv_cpu_set;
	compiler.platform.abi = RISCV;
	CpuFeatures features = CPU_FEATURE_ZERO;
	if (compiler.platform.arch == RISCV64)
	{
		cpu_features_add_feature_single(&features, RISCV_FEAT_64BIT);
		if (cpu == RISCV_CPU_DEFAULT) cpu = RISCV_CPU_RVGC;
	}
	else
	{
		cpu_features_add_feature_single(&features, RISCV_FEAT_32BIT);
		if (cpu == RISCV_CPU_DEFAULT) cpu = RISCV_CPU_RVI;
	}
	if (target.feature.riscv_abi == RISCV_ABI_DEFAULT)
	{
		switch (cpu)
		{
			case RISCV_CPU_DEFAULT:
				unreachable();
			case RISCV_CPU_RVI:
			case RISCV_CPU_RVIMAC:
				target.feature.riscv_abi = RISCV_ABI_INT_ONLY;
			case RISCV_CPU_RVIMAFC:
				target.feature.riscv_abi = RISCV_ABI_FLOAT;
			case RISCV_CPU_RVGC:
			case RISCV_CPU_RVGCV:
				target.feature.riscv_abi = RISCV_ABI_DOUBLE;
		}
	}
	switch (target.feature.riscv_abi)
	{
		case RISCV_ABI_DEFAULT:
			unreachable();
		case RISCV_ABI_INT_ONLY:
		case RISCV_ABI_FLOAT:
		case RISCV_ABI_DOUBLE:
			compiler.platform.riscv.flen = 4 * target.feature.riscv_abi;
	}
	cpu_features_add_feature_single(&features, RISCV_FEAT_I);
	switch (cpu)
	{
		case RISCV_CPU_DEFAULT:
			unreachable();
		case RISCV_CPU_RVI:
			break;
		case RISCV_CPU_RVGCV:
			cpu_features_add_feature_single(&features, RISCV_FEAT_V);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZFA);
			nextcase RISCV_CPU_RVGC;
		case RISCV_CPU_RVGC:
			cpu_features_add_feature_single(&features, RISCV_FEAT_D);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZICSR);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZIFENCEI);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZBA);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZBB);
			cpu_features_add_feature_single(&features, RISCV_FEAT_ZBS);
			nextcase RISCV_CPU_RVIMAFC;
		case RISCV_CPU_RVIMAFC:
			cpu_features_add_feature_single(&features, RISCV_FEAT_F);
			nextcase RISCV_CPU_RVIMAC;
		case RISCV_CPU_RVIMAC:
			cpu_features_add_feature_single(&features, RISCV_FEAT_M);
			cpu_features_add_feature_single(&features, RISCV_FEAT_A);
			cpu_features_add_feature_single(&features, RISCV_FEAT_C);
	}

	if (target.feature.riscv_abi >= RISCV_ABI_FLOAT)
	{
		cpu_features_add_feature_single(&features, RISCV_FEAT_F);
		cpu_features_add_feature_single(&features, RISCV_FEAT_ZICSR);
	}
	if (target.feature.riscv_abi >= RISCV_ABI_DOUBLE)
	{
		cpu_features_add_feature_single(&features, RISCV_FEAT_D);
	}
	update_cpu_features(target.cpu_flags, &features, &riscv_feature_name, RISCV_FEATURE_LAST);
	cpu_features_set_to_features(features, CPU_FEATURE_ZERO, null, &riscv_feature_name, RISCV_FEATURE_LAST);
}

// target.c:2171 (static)
fn void update_cpu_features(String features, CpuFeatures* cpu_features, String* feature_names, int feature_count)
{
	if (!features.ptr) return;
	StringSlice slice = features;
	if (!slice.len) return;
	while (slice.len)
	{
		StringSlice next = slice_next_token(&slice, ',');
		slice_trim(&next);
		if (!next.len) continue;
		bool add_feature = true;
		if (next.len < 2 || (next[0] != '+' && next[0] != '-'))
		{
			@error_exit("Invalid feature flag: %s in '%s'", next, features);
		}
		if (next[0] == '-') add_feature = false;
		next = next[1..];
		bool found = false;
		for (int i = 0; i <= feature_count; i++)
		{
			if (feature_names[i] == next)
			{
				if (add_feature)
				{
					cpu_features_add_feature_single(cpu_features, i);
				}
				else
				{
					cpu_features_remove_feature(cpu_features, i);
				}
				found = true;
				break;
			}
		}
		if (!found) io::printfn("Unsupported feature flag: '%s', will be ignored.", next);
	}
}

// target.c:2225
fn void target_setup(BuildTarget* build_target)
{
	compiler.platform.target_triple = arch_to_target_triple(build_target.arch_os_target, build_target.linuxpaths.libc);
	assert(compiler.platform.target_triple.ptr);

	compiler.platform.alloca_address_space = 0;

	StringSlice target_triple_string = compiler.platform.target_triple;
	compiler.platform.arch = arch_from_llvm_string(slice_next_token(&target_triple_string, '-'));
	if (!arch_is_supported(compiler.platform.arch))
	{
		io::printf("WARNING! This architecture is unsupported.\n");
	}
	compiler.platform.vendor = vendor_from_llvm_string(slice_next_token(&target_triple_string, '-'));
	compiler.platform.os = os_from_llvm_string(slice_next_token(&target_triple_string, '-'));
	compiler.platform.environment_type = environment_type_from_llvm_string(target_triple_string);
	if (compiler.platform.environment_type == ANDROID) compiler.platform.os = ANDROID;

	// c3c: debug_info NOT_SET -> DEBUG_INFO_FULL (debug info is not tracked here).

	compiler.platform.float_abi = NONE;
	// TLS should not be supported for:
	// ARM Cygwin
	// NVPTX
	compiler.platform.tls_supported = os_target_use_thread_local(compiler.platform.os);
	// Compiling natively to Android in Termux requires emulated TLS
	// c3c: `&& !compiler.build.android.ndk_path` (no NDK path option here).
	compiler.platform.emulated_tls = compiler.platform.os == ANDROID;
	compiler.platform.big_endian = arch_big_endian(compiler.platform.arch);
	compiler.platform.width_pointer = arch_pointer_bit_width(compiler.platform.os, compiler.platform.arch);
	compiler.platform.width_register = arch_int_register_bit_width(compiler.platform.os, compiler.platform.arch);
	compiler.platform.alloca_address_space = 0;
	compiler.platform.object_format = object_format_from_os(compiler.platform.os, compiler.platform.arch);
	compiler.platform.noredzone = build_target.arch_os_target == ELF_X64;
	switch (compiler.platform.object_format)
	{
		case COFF:
		case ELF:
		case WASM:
			compiler.platform.use_comdat = true;
		default:
			break;
	}

	compiler.platform.int128_supported = os_target_supports_int128(compiler.platform.os, compiler.platform.arch);
	compiler.platform.vec128f = os_target_supports_vec(compiler.platform.os, compiler.platform.arch, 128, false);
	compiler.platform.vec128i = os_target_supports_vec(compiler.platform.os, compiler.platform.arch, 128, true);
	compiler.platform.vec64f = os_target_supports_vec(compiler.platform.os, compiler.platform.arch, 64, false);
	compiler.platform.vec64i = os_target_supports_vec(compiler.platform.os, compiler.platform.arch, 64, true);
	compiler.platform.float128_supported = os_target_supports_float128(compiler.platform.os, compiler.platform.arch);
	compiler.platform.float16_supported = os_target_supports_float16(compiler.platform.os, compiler.platform.arch);
	for (usz i = BitSizes.BITS8.ordinal; i < BITSIZES_COUNT; i++)
	{
		uint bits = (uint)(8 << (i - 1));
		compiler.platform.integers[i] = os_target_alignment_of_int(compiler.platform.os, compiler.platform.arch, bits);
		compiler.platform.floats[i] = os_target_alignment_of_float(compiler.platform.os, compiler.platform.arch, bits);
	}
	compiler.platform.integers[BitSizes.BIT1.ordinal] = compiler.platform.integers[BitSizes.BITS8.ordinal];

	compiler.platform.align_pointer = { compiler.platform.width_pointer, compiler.platform.width_pointer };
	compiler.platform.width_c_short = os_target_c_type_bits(compiler.platform.os, compiler.platform.arch, SHORT);
	compiler.platform.width_c_int = os_target_c_type_bits(compiler.platform.os, compiler.platform.arch, INT);
	compiler.platform.width_c_long = os_target_c_type_bits(compiler.platform.os, compiler.platform.arch, LONG);
	compiler.platform.width_c_long_long = os_target_c_type_bits(compiler.platform.os, compiler.platform.arch, LONG_LONG);
	compiler.platform.signed_c_char = os_target_signed_c_char_type(compiler.platform.os, compiler.platform.arch);
	switch (compiler.platform.arch)
	{
		case AARCH64_32: case BPFEL: case BPFEB: case SPARCEL: case LE64: case AMDIL: case AMDIL64: case HSAIL:
		case HSAIL64: case KALIMBA: case SHAVE: case RSCRIPT32: case RSCRIPT64: case LE32: case MIPS: case MIPSEL:
		case MIPS64EL: case MIPS64: case NVPTX64: case NVPTX: case MSP430: case SYSTEMZ: case TCELE: case TCE:
		case LANAI: case HEXAGON: case AMDGCN: case R600: case SPARC: case SPARCV9: case XCORE: case ARC:
		case SPIR64: case SPIR:
			unreachable();
		case AARCH64:
		case AARCH64_BE:
			target_setup_aarch64_abi();
		case XTENSA:
			compiler.platform.abi = XTENSA;
		case AVR:
			compiler.platform.abi = AVR;
			compiler.platform.tls_supported = false;
		case WASM32:
		case WASM64:
			target_setup_wasm_abi(build_target);
		case ARMB:
		case ARM:
		case THUMBEB:
		case THUMB:
			target_setup_arm_abi();
		case PPC:
			@error_exit("PPC32 is not supported.");
		case PPC64:
		case PPC64LE:
			if (compiler.platform.object_format != ELF)
			{
				if (compiler.platform.arch == PPC64LE)
				{
					@error_exit("PPC64 LE non-ELF not supported.");
				}
				@error_exit("PPC64 not supported");
			}
			/** Here we need to have different codegen depending on elf version :( */
			compiler.platform.abi = PPC64_SVR4;
			compiler.platform.ppc64.is_softfp = compiler.platform.float_abi == SOFT;
			/* todo enable if elfv2 */
			compiler.platform.ppc64.is_elfv2 = compiler.platform.arch == PPC64LE;
			/* todo enable if elfv1-qpx */
			compiler.platform.ppc64.has_qpx = false;
		case RISCV64:
		case RISCV32:
			target_setup_riscv_abi(build_target);
		case X86:
			target_setup_x86_abi(build_target);
		case X86_64:
			target_setup_x64_abi(build_target);
			if (compiler.platform.os == WIN32)
			{
				compiler.platform.abi = WIN64;
				break;
			}
			compiler.platform.abi = X64;
		case UNKNOWN:
			compiler.platform.abi = UNKNOWN;
	}
	compiler.platform.align_max_vector = (int)os_arch_max_alignment_of_vector(compiler.platform.os,
	                                                                          compiler.platform.arch,
	                                                                          compiler.platform.environment_type,
	                                                                          compiler.platform.arm.variant,
	                                                                          &compiler.platform.x64.features);
	compiler.platform.align_max_tls = (int)os_arch_max_alignment_of_tls(compiler.platform.os,
	                                                                    compiler.platform.arch,
	                                                                    compiler.platform.environment_type);
	compiler.platform.reloc_model = arch_os_reloc_default(compiler.platform.arch,
	                                                      compiler.platform.os,
	                                                      compiler.platform.environment_type,
	                                                      compiler.build.type != EXECUTABLE);
	compiler.platform.pic_required = arch_os_pic_default_forced(compiler.platform.arch, compiler.platform.os);
	compiler.platform.dylib_suffix = os_dynamic_library_suffix(compiler.platform.os);
	// Override PIC, but only if the platform does not require PIC
	if (build_target.reloc_model != RELOC_DEFAULT
		&& (build_target.reloc_model != RELOC_NONE || !compiler.platform.pic_required))
	{
		compiler.platform.reloc_model = build_target.reloc_model;
	}

	// c3c: iOS / macOS SDK lookup and versioned LLVM triples (skipped, see the file header).
	assert(compiler.platform.reloc_model != RELOC_DEFAULT);
	compiler.platform.use_dso_local = compiler.platform.object_format == COFF || compiler.platform.object_format == ELF;

	if (compiler.platform.reloc_model == RELOC_BIG_PIC || compiler.platform.reloc_model == RELOC_SMALL_PIC)
	{
		compiler.platform.use_dso_local = false;
	}

	// TODO remove
	type_setup(&compiler.platform);
}

// target.c:2515
fn ArchType target_host_arch()
{
	// c3c picks this from the host compiler's predefined macros.
	return X86_64;
}
