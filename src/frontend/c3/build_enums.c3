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

