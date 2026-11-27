// Build-option and target enums of c3c src/compiler/enums.h / build/build.h
// that the sema port reads through `compiler.build` / `compiler.platform`
// (see compiler.c3 for the struct fields).
//
// Same translation as ast_enums.c3: plain enums lose their shared C prefix
// (TARGET_TYPE_EXECUTABLE -> TargetType.EXECUTABLE), enums with explicit or
// negative values become `alias X = int` plus constants with the C names
// (PANIC_OFF, SAFETY_ON, USE_STDLIB_OFF, ...), range markers become constants
// (ARCH_TYPE_LAST). `bool`-like on/off settings keep the C names because
// c3c compares them against `*_OFF` / `*_ON`.
module aro::frontend::c3::compiler;

<* enums.h `TargetType`. *>
enum TargetType : char
{
	EXECUTABLE,
	STATIC_LIB,
	DYNAMIC_LIB,
	OBJECT_FILES,
	BENCHMARK,
	TEST,
	PREPARE,
	SOURCE_LIB,
}

<* enums.h `TrustLevel`. *>
enum TrustLevel : char
{
	NONE,
	INCLUDE,
	FULL,
}

alias ShowBacktrace = int;
const ShowBacktrace SHOW_BACKTRACE_NOT_SET = -1;
const ShowBacktrace SHOW_BACKTRACE_OFF = 0;
const ShowBacktrace SHOW_BACKTRACE_ON = 1;

alias PanicLevel = int;
const PanicLevel PANIC_NOT_SET = -1;
const PanicLevel PANIC_OFF = 0;
const PanicLevel PANIC_ON = 1;

alias SafetyLevel = int;
const SafetyLevel SAFETY_NOT_SET = -1;
const SafetyLevel SAFETY_OFF = 0;
const SafetyLevel SAFETY_ON = 1;

alias UseStdlib = int;
const UseStdlib USE_STDLIB_NOT_SET = -1;
const UseStdlib USE_STDLIB_OFF = 0;
const UseStdlib USE_STDLIB_ON = 1;

alias CustomLibc = int;
const CustomLibc CUSTOM_LIBC_NOT_SET = -1;
const CustomLibc CUSTOM_LIBC_OFF = 0;
const CustomLibc CUSTOM_LIBC_ON = 1;

alias LinkLibc = int;
const LinkLibc LINK_LIBC_NOT_SET = -1;
const LinkLibc LINK_LIBC_OFF = 0;
const LinkLibc LINK_LIBC_ON = 1;

alias StripUnused = int;
const StripUnused STRIP_UNUSED_NOT_SET = -1;
const StripUnused STRIP_UNUSED_OFF = 0;
const StripUnused STRIP_UNUSED_ON = 1;

alias WinSubsystem = int;
const WinSubsystem WIN_SUBSYSTEM_DEFAULT = -1;
const WinSubsystem WIN_SUBSYSTEM_CONSOLE = 0;
const WinSubsystem WIN_SUBSYSTEM_WINDOWS = 1;
const WinSubsystem WIN_SUBSYSTEM_NATIVE = 2;
const WinSubsystem WIN_SUBSYSTEM_POSIX = 3;
const WinSubsystem WIN_SUBSYSTEM_BOOT_APPLICATION = 4;
const WinSubsystem WIN_SUBSYSTEM_EFI_APPLICATION = 5;
const WinSubsystem WIN_SUBSYSTEM_EFI_BOOT_SERVICE_DRIVER = 6;
const WinSubsystem WIN_SUBSYSTEM_EFI_ROM = 7;
const WinSubsystem WIN_SUBSYSTEM_EFI_RUNTIME_DRIVER = 8;

alias StatsMode = int;
const StatsMode STATS_NOT_SET = -1;
const StatsMode STATS_NONE = 0;
const StatsMode STATS_SUMMARY = STATS_NONE + 1;
const StatsMode STATS_FULL = STATS_SUMMARY + 1;
const StatsMode STATS_JSON = STATS_FULL + 1;

<* enums.h `ArchType`. *>
enum ArchType : char
{
	UNKNOWN,
	ARM,
	ARMB,
	AARCH64,
	AARCH64_BE,
	AARCH64_32,
	ARC,
	AVR,
	BPFEL,
	BPFEB,
	HEXAGON,
	MIPS,
	MIPSEL,
	MIPS64,
	MIPS64EL,
	MSP430,
	PPC,
	PPC64,
	PPC64LE,
	R600,
	AMDGCN,
	RISCV32,
	RISCV64,
	SPARC,
	SPARCV9,
	SPARCEL,
	SYSTEMZ,
	TCE,
	TCELE,
	THUMB,
	THUMBEB,
	X86,
	X86_64,
	XCORE,
	NVPTX,
	NVPTX64,
	LE32,
	LE64,
	AMDIL,
	AMDIL64,
	HSAIL,
	HSAIL64,
	SPIR,
	SPIR64,
	KALIMBA,
	SHAVE,
	LANAI,
	WASM32,
	WASM64,
	RSCRIPT32,
	RSCRIPT64,
	XTENSA,
}
const ArchType ARCH_TYPE_LAST = ArchType.XTENSA;

<* enums.h `OsType`. *>
enum OsType : char
{
	UNKNOWN,
	NONE,
	ANANAS,
	CLOUD_ABI,
	DRAGON_FLY,
	FREEBSD,
	FUCHSIA,
	IOS,
	KFREEBSD,
	LINUX,
	PS3,
	MACOSX,
	NETBSD,
	OPENBSD,
	SOLARIS,
	WIN32,
	HAIKU,
	MINIX,
	RTEMS,
	NACL,
	CNK,
	AIX,
	CUDA,
	NVOPENCL,
	AMDHSA,
	PS4,
	ELFIAMCU,
	TVOS,
	WATCHOS,
	MESA3D,
	CONTIKI,
	AMDPAL,
	HERMITCORE,
	HURD,
	WASI,
	EMSCRIPTEN,
	ANDROID,
}
const OsType OS_TYPE_LAST = OsType.ANDROID;

<* enums.h `ObjectFormatType`. *>
enum ObjectFormatType : char
{
	UNSUPPORTED,
	COFF,
	GOFF,
	ELF,
	MACHO,
	WASM,
	XCOFF,
	AOUT,
}


alias StackProbe = int;
const StackProbe STACK_PROBE_NOT_SET = -1;
const StackProbe STACK_PROBE_NONE = 0;
const StackProbe STACK_PROBE_CALL = 1;
const StackProbe STACK_PROBE_INLINE = 2;

alias StackProtector = int;
const StackProtector STACK_PROTECTOR_NOT_SET = -1;
const StackProtector STACK_PROTECTOR_NONE = 0;
const StackProtector STACK_PROTECTOR_BASIC = 1;
const StackProtector STACK_PROTECTOR_STRONG = 2;
const StackProtector STACK_PROTECTOR_ALL = 3;


<*
 enums.h `ArchOsTarget`. c3c's ARCH_OS_TARGET_DEFAULT is -1; here it is the
 extra last member DEFAULT so the other ordinals match c3c.
*>
enum ArchOsTarget : char
{
	ANDROID_AARCH64,
	ANDROID_X86_64,
	ELF_AARCH64,
	ELF_RISCV32,
	ELF_RISCV64,
	ELF_X86,
	ELF_X64,
	ELF_XTENSA,
	ELF_AVR,
	FREEBSD_X86,
	FREEBSD_X64,
	IOS_AARCH64,
	IOS_AARCH64_SIM,
	IOS_X64_SIM,
	LINUX_AARCH64,
	LINUX_RISCV32,
	LINUX_RISCV64,
	LINUX_X86,
	LINUX_X64,
	MACOS_AARCH64,
	MACOS_X64,
	MCU_X86,
	MINGW_X64,
	NETBSD_AARCH64,
	NETBSD_X86,
	NETBSD_X64,
	OPENBSD_X86,
	OPENBSD_X64,
	WASM32,
	WASM64,
	EMSCRIPTEN_WASM32,
	WINDOWS_AARCH64,
	WINDOWS_X64,
	DEFAULT,
}
const ArchOsTarget ARCH_OS_TARGET_DEFAULT = ArchOsTarget.DEFAULT;
const ArchOsTarget ARCH_OS_TARGET_LAST = ArchOsTarget.WINDOWS_X64;

<* enums.h `VendorType`. *>
enum VendorType : char
{
	UNKNOWN,
	APPLE,
	PC,
	SCEI,
	BGP,
	BGQ,
	FREESCALE,
	IBM,
	IMAGINATION_TECHNOLOGIES,
	MIPS_TECHNOLOGIES,
	NVIDIA,
	CSR,
	MYRIAD,
	AMD,
	MESA,
	SUSE,
	OPEN_EMBEDDED,
}
const VendorType VENDOR_LAST = VendorType.OPEN_EMBEDDED;

<* enums.h `EnvironmentType` (ENV_TYPE_ prefix dropped). *>
enum EnvironmentType : char
{
	UNKNOWN,
	GNU,
	GNUABIN32,
	GNUABI64,
	GNUEABI,
	GNUEABIHF,
	GNUX32,
	CODE16,
	EABI,
	EABIHF,
	ELFV1,
	ELFV2,
	ANDROID,
	MUSL,
	MUSLEABI,
	MUSLEABIHF,
	MSVC,
	ITANIUM,
	CYGNUS,
	CORECLR,
	SIMULATOR,
	MACABI,
}
const EnvironmentType ENV_TYPE_LAST = EnvironmentType.MACABI;

<* enums.h `FloatABI`. *>
enum FloatAbi : char
{
	NONE,
	SOFT,
	HARD,
}

<* enums.h `ARMVariant`. *>
enum ArmVariant : char
{
	AAPCS,
	AAPCS16,
	APCS_GNU,
	AAPCS_LINUX,
}

<* enums.h `ARMABIVariant` (ARM_ABI_ prefix dropped). *>
enum ArmAbiVariant : char
{
	AAPCS,
	APCS,
	AAPCS16_VFP,
	AAPCS_VFP,
}

alias RelocModel = int;
const RelocModel RELOC_DEFAULT = -1;
const RelocModel RELOC_NONE = 0;
const RelocModel RELOC_SMALL_PIC = 1;
const RelocModel RELOC_BIG_PIC = 2;
const RelocModel RELOC_SMALL_PIE = 3;
const RelocModel RELOC_BIG_PIE = 4;

alias LinuxLibc = int;
const LinuxLibc LINUX_LIBC_NOT_SET = -1;
const LinuxLibc LINUX_LIBC_GNU = 0;
const LinuxLibc LINUX_LIBC_MUSL = 1;
const LinuxLibc LINUX_LIBC_HOST = 2;

alias SoftFloat = int;
const SoftFloat SOFT_FLOAT_DEFAULT = -1;
const SoftFloat SOFT_FLOAT_NONE = 0;
const SoftFloat SOFT_FLOAT_YES = 1;

alias Win64Simd = int;
const Win64Simd WIN64_SIMD_DEFAULT = -1;
const Win64Simd WIN64_SIMD_FULL = 0;
const Win64Simd WIN64_SIMD_ARRAY = 1;

alias StructReturn = int;
const StructReturn STRUCT_RETURN_DEFAULT = -1;
const StructReturn STRUCT_RETURN_STACK = 0;
const StructReturn STRUCT_RETURN_REG = 1;

alias X86VectorCapability = int;
const X86VectorCapability X86VECTOR_DEFAULT = -1;
const X86VectorCapability X86VECTOR_NONE = 0;
const X86VectorCapability X86VECTOR_MMX = 1;
const X86VectorCapability X86VECTOR_SSE = 2;
const X86VectorCapability X86VECTOR_AVX = 3;
const X86VectorCapability X86VECTOR_AVX512 = 4;
const X86VectorCapability X86VECTOR_CPU = 5;

alias X86CpuSet = int;
const X86CpuSet X86CPU_DEFAULT = -1;
const X86CpuSet X86CPU_BASELINE = 0;
const X86CpuSet X86CPU_SSSE3 = 1;
const X86CpuSet X86CPU_SSE4 = 2;
const X86CpuSet X86CPU_AVX1 = 3;
const X86CpuSet X86CPU_AVX2_V1 = 4;
const X86CpuSet X86CPU_AVX2_V2 = 5;
const X86CpuSet X86CPU_AVX512 = 6;
const X86CpuSet X86CPU_NATIVE = 7;

alias RiscvCpuSet = int;
const RiscvCpuSet RISCV_CPU_DEFAULT = -1;
const RiscvCpuSet RISCV_CPU_RVI = 0;
const RiscvCpuSet RISCV_CPU_RVIMAC = 1;
const RiscvCpuSet RISCV_CPU_RVIMAFC = 2;
const RiscvCpuSet RISCV_CPU_RVGC = 3;
const RiscvCpuSet RISCV_CPU_RVGCV = 4;

alias RiscvAbi = int;
const RiscvAbi RISCV_ABI_DEFAULT = -1;
const RiscvAbi RISCV_ABI_INT_ONLY = 0;
const RiscvAbi RISCV_ABI_FLOAT = 1;
const RiscvAbi RISCV_ABI_DOUBLE = 2;
