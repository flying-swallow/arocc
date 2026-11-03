// Port of src/aro/Target.zig: the C program's target (not the compiler host).
//
// Module layout (one module, three files):
// - target.c3       Target.zig itself: enums, Os/Cpu/Target records, triple
//                   component parsing (parseArchName/parseOsName/parseAbi/
//                   parseOs/parseVersion), Query resolution and every
//                   Target.zig query (intMaxType, bitfield policy, PIC/PIE, ...).
// - target_cpu.c3   The subset of std.Target.Cpu (features, models, feature
//                   dependencies) that aro reads, plus SubArch.toFeature/
//                   toCpuModel, cpuModelForTargetQuadruple and armVersion.
// - target_data.c3  The std.Target ABI rules aro relies on: ptrBitWidth,
//                   cTypeBitSize/cTypeAlignment/cTypeByteSize, cCharSignedness,
//                   Abi.default, ObjectFormat.default, OS version ranges,
//                   DynamicLinker.standard.
//
// Zig's Target embeds std.Target (Cpu, Os, Abi, ObjectFormat). Here every
// such type is a plain C3 value type with explicit data; nothing calls Zig.
//
// Host vs target: Zig reads `builtin` (the host) in a few places (`Target.default`,
// "native" arch/OS/CPU, the `bpf` arch alias, cpuModelForTargetQuadruple's
// missing-OS/ABI fallback). These take an explicit `Host` value here
// (`target::host()` describes the machine the C3 compiler was built for).
// Unknown names are always errors; nothing silently falls back to the host.
//
// Deviations from Zig:
// - Zig `?T` results become `T?` with a fault, or a `has_*` flag.
// - CPU models/features cover only what aro queries (see target_cpu.c3).
// - Type identities: intMaxType etc. return `CIntKind`, a target-local enum of
//   the basic C integer types, so this module does not depend on TypeStore.
// - Native CPU detection (cpuid etc.) is not ported: a "native" CPU resolves to
//   the baseline model of the host architecture.
module aro::target;
import aro::lang_opts;

excuse UNKNOWN_ARCH;
excuse UNKNOWN_OS;
excuse INVALID_OS_VERSION;
excuse UNKNOWN_ABI;
excuse INVALID_ABI_VERSION;
excuse INVALID_API_VERSION;
excuse UNEXPECTED_EXTRA_FIELD;
excuse UNKNOWN_VENDOR;
excuse UNKNOWN_CPU_MODEL;
excuse UNKNOWN_CPU_FEATURE;
<* "native" was requested but the host is not describable (see `host()`). *>
excuse NATIVE_UNSUPPORTED;
<* parseVersion errors. *>
excuse INVALID_VERSION;
excuse OVERFLOW;

// ---------------------------------------------------------------------------
// Enumerations. `name` is the Zig tag name (what @tagName returns and what
// std.meta.stringToEnum accepts).
// ---------------------------------------------------------------------------

<*
 std.Target.Cpu.Arch. Associated values:
 name: Zig tag; llvm: arch component of toLLVMTriple; ptr_bits: ptrBitWidth
 before the ABI override; big: big endian; max_align: the cap applied by
 cTypeAlignment (see target_data.c3 for provenance).
*>
enum Arch : char (String name, String llvm, ushort ptr_bits, bool big, ushort max_align)
{
	AARCH64       { "aarch64", "aarch64", 64, false, 16 },
	AARCH64_BE    { "aarch64_be", "aarch64_be", 64, true, 16 },
	ALPHA         { "alpha", "alpha", 64, false, 16 },
	AMDGCN        { "amdgcn", "amdgcn", 64, false, 8 },
	ARC           { "arc", "arc", 32, false, 4 },
	ARCEB         { "arceb", "arceb", 32, true, 4 },
	ARM           { "arm", "arm", 32, false, 8 },
	ARMEB         { "armeb", "armeb", 32, true, 8 },
	AVR           { "avr", "avr", 16, false, 1 },
	BPFEB         { "bpfeb", "bpfeb", 64, true, 8 },
	BPFEL         { "bpfel", "bpfel", 64, false, 8 },
	CSKY          { "csky", "csky", 32, false, 4 },
	EZ80          { "ez80", "ez80", 24, false, 1 },
	HEXAGON       { "hexagon", "hexagon", 32, false, 8 },
	HPPA          { "hppa", "hppa", 32, true, 8 },
	HPPA64        { "hppa64", "hppa64", 64, true, 16 },
	KVX           { "kvx", "kvx", 64, false, 16 },
	LANAI         { "lanai", "lanai", 32, true, 8 },
	LOONGARCH32   { "loongarch32", "loongarch32", 32, false, 16 },
	LOONGARCH64   { "loongarch64", "loongarch64", 64, false, 16 },
	M68K          { "m68k", "m68k", 32, true, 2 },
	M88K          { "m88k", "m88k", 32, true, 8 },
	MICROBLAZE    { "microblaze", "microblaze", 32, true, 4 },
	MICROBLAZEEL  { "microblazeel", "microblazeel", 32, false, 4 },
	MIPS          { "mips", "mips", 32, true, 8 },
	MIPSEL        { "mipsel", "mipsel", 32, false, 8 },
	MIPS64        { "mips64", "mips64", 64, true, 16 },
	MIPS64EL      { "mips64el", "mips64el", 64, false, 16 },
	MSP430        { "msp430", "msp430", 16, false, 2 },
	NVPTX         { "nvptx", "nvptx", 32, false, 8 },
	NVPTX64       { "nvptx64", "nvptx64", 64, false, 8 },
	OR1K          { "or1k", "or1k", 32, true, 4 },
	POWERPC       { "powerpc", "powerpc", 32, true, 16 },
	POWERPCLE     { "powerpcle", "powerpcle", 32, false, 16 },
	POWERPC64     { "powerpc64", "powerpc64", 64, true, 16 },
	POWERPC64LE   { "powerpc64le", "powerpc64le", 64, false, 16 },
	PROPELLER     { "propeller", "propeller", 32, false, 4 },
	RISCV32       { "riscv32", "riscv32", 32, false, 16 },
	RISCV32BE     { "riscv32be", "riscv32be", 32, true, 16 },
	RISCV64       { "riscv64", "riscv64", 64, false, 16 },
	RISCV64BE     { "riscv64be", "riscv64be", 64, true, 16 },
	S390X         { "s390x", "s390x", 64, true, 8 },
	SH            { "sh", "sh", 32, false, 4 },
	SHEB          { "sheb", "sheb", 32, true, 4 },
	SPARC         { "sparc", "sparc", 32, true, 8 },
	SPARC64       { "sparc64", "sparc64", 64, true, 16 },
	SPIRV32       { "spirv32", "spirv32", 32, false, 8 },
	SPIRV64       { "spirv64", "spirv64", 64, false, 16 },
	SPORK8        { "spork8", "spork8", 16, false, 1 },
	THUMB         { "thumb", "thumb", 32, false, 8 },
	THUMBEB       { "thumbeb", "thumbeb", 32, true, 8 },
	VE            { "ve", "ve", 64, false, 16 },
	WASM32        { "wasm32", "wasm32", 32, false, 16 },
	WASM64        { "wasm64", "wasm64", 64, false, 16 },
	X86           { "x86", "i386", 32, false, 4 },
	X86C16        { "x86c16", "i386", 32, false, 4 },
	X86_16        { "x86_16", "i86", 16, false, 2 },
	X86_64        { "x86_64", "x86_64", 64, false, 16 },
	XCORE         { "xcore", "xcore", 32, false, 4 },
	XTENSA        { "xtensa", "xtensa", 32, false, 8 },
	XTENSAEB      { "xtensaeb", "xtensaeb", 32, true, 8 },
	Z80           { "z80", "z80", 16, false, 1 },
}

enum Endian : char
{
	LITTLE,
	BIG,
}

fn Endian Arch.endian(self) => self.big ? BIG : LITTLE;
fn bool Arch.is_x86(self) => self == X86 || self == X86_64 || self == X86C16 || self == X86_16;
fn bool Arch.is_arm(self) => self == ARM || self == ARMEB || self == THUMB || self == THUMBEB;
fn bool Arch.is_thumb(self) => self == THUMB || self == THUMBEB;
fn bool Arch.is_aarch64(self) => self == AARCH64 || self == AARCH64_BE;
fn bool Arch.is_mips32(self) => self == MIPS || self == MIPSEL;
fn bool Arch.is_mips64(self) => self == MIPS64 || self == MIPS64EL;
fn bool Arch.is_mips(self) => self.is_mips32() || self.is_mips64();
fn bool Arch.is_powerpc(self) => self == POWERPC || self == POWERPCLE || self == POWERPC64 || self == POWERPC64LE;
fn bool Arch.is_riscv(self) => self == RISCV32 || self == RISCV32BE || self == RISCV64 || self == RISCV64BE;
fn bool Arch.is_wasm(self) => self == WASM32 || self == WASM64;
fn bool Arch.is_spirv(self) => self == SPIRV32 || self == SPIRV64;
fn bool Arch.is_bpf(self) => self == BPFEL || self == BPFEB;
fn bool Arch.is_loongarch(self) => self == LOONGARCH32 || self == LOONGARCH64;
fn bool Arch.is_sparc(self) => self == SPARC || self == SPARC64;

<* std.Target.Os.Tag.versionRangeTag's result. *>
enum VersionRangeTag : char
{
	NONE,
	SEMVER,
	HURD,
	LINUX,
	WINDOWS,
}

<*
 std.Target.Os.Tag. llvm: OS component of toLLVMTriple. range: versionRangeTag
 (provenance in target_data.c3).
*>
enum OsTag : char (String name, String llvm, VersionRangeTag range)
{
	FREESTANDING { "freestanding", "unknown", NONE },
	OTHER        { "other", "unknown", NONE },
	THREEDS      { "3ds", "unknown", SEMVER },
	AMDHSA       { "amdhsa", "amdhsa", SEMVER },
	ASHETOS      { "ashetos", "unknown", NONE },
	CUDA         { "cuda", "cuda", SEMVER },
	DRAGONFLY    { "dragonfly", "dragonfly", SEMVER },
	DRIVERKIT    { "driverkit", "driverkit", SEMVER },
	EMSCRIPTEN   { "emscripten", "emscripten", NONE },
	FREEBSD      { "freebsd", "freebsd", SEMVER },
	FUCHSIA      { "fuchsia", "fuchsia", SEMVER },
	GBA          { "gba", "unknown", NONE },
	HAIKU        { "haiku", "haiku", NONE },
	HURD         { "hurd", "hurd", HURD },
	ILLUMOS      { "illumos", "illumos", NONE },
	IOS          { "ios", "ios", SEMVER },
	LINUX        { "linux", "linux", LINUX },
	MACCATALYST  { "maccatalyst", "ios", SEMVER },
	MACOS        { "macos", "macosx", SEMVER },
	MANAGARM     { "managarm", "managarm", SEMVER },
	NETBSD       { "netbsd", "netbsd", SEMVER },
	NVCL         { "nvcl", "nvcl", SEMVER },
	OPENBSD      { "openbsd", "openbsd", SEMVER },
	OPENCL       { "opencl", "unknown", SEMVER },
	OPENGL       { "opengl", "unknown", SEMVER },
	PLAN9        { "plan9", "unknown", NONE },
	PS3          { "ps3", "lv2", NONE },
	PS4          { "ps4", "ps4", NONE },
	PS5          { "ps5", "ps5", NONE },
	PSP          { "psp", "unknown", NONE },
	PSX          { "psx", "unknown", NONE },
	RTEMS        { "rtems", "rtems", SEMVER },
	SERENITY     { "serenity", "serenity", NONE },
	SWITCH       { "switch", "unknown", SEMVER },
	TIOS         { "tios", "unknown", NONE },
	TVOS         { "tvos", "tvos", SEMVER },
	UEFI         { "uefi", "windows", NONE },
	VISIONOS     { "visionos", "xros", SEMVER },
	VITA         { "vita", "unknown", SEMVER },
	VULKAN       { "vulkan", "vulkan", SEMVER },
	WASI         { "wasi", "wasi", SEMVER },
	WATCHOS      { "watchos", "watchos", SEMVER },
	WIIU         { "wiiu", "unknown", SEMVER },
	WINDOWS      { "windows", "windows", WINDOWS },
}

fn bool OsTag.is_darwin(self)
{
	switch (self)
	{
		case DRIVERKIT:
		case IOS:
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case VISIONOS:
		case WATCHOS: return true;
		default: return false;
	}
}

<* std.Target.Os.Tag.isBSD: Darwin counts as BSD. *>
fn bool OsTag.is_bsd(self)
{
	if (self.is_darwin()) return true;
	switch (self)
	{
		case FREEBSD:
		case OPENBSD:
		case NETBSD:
		case DRAGONFLY: return true;
		default: return false;
	}
}

fn VersionRangeTag OsTag.version_range_tag(self) => self.range;

<* std.Target.Abi. llvm: environment component of toLLVMTriple (`none` is special-cased). *>
enum Abi : char (String name, String llvm)
{
	NONE        { "none", "unknown" },
	ABIN32      { "abin32", "unknown" },
	ANDROID     { "android", "android" },
	ANDROIDEABI { "androideabi", "androideabi" },
	CALL0       { "call0", "call0" },
	EABI        { "eabi", "eabi" },
	EABIHF      { "eabihf", "eabihf" },
	GNU         { "gnu", "gnu" },
	GNUABI64    { "gnuabi64", "gnuabi64" },
	GNUABIN32   { "gnuabin32", "gnuabin32" },
	GNUEABI     { "gnueabi", "gnueabi" },
	GNUEABIHF   { "gnueabihf", "gnueabihf" },
	GNUF32      { "gnuf32", "gnuf32" },
	GNUSF       { "gnusf", "gnusf" },
	GNUX32      { "gnux32", "gnux32" },
	ILP32       { "ilp32", "unknown" },
	MSVC        { "msvc", "msvc" },
	MUSL        { "musl", "musl" },
	MUSLABI64   { "muslabi64", "muslabi64" },
	MUSLABIN32  { "muslabin32", "muslabin32" },
	MUSLEABI    { "musleabi", "musleabi" },
	MUSLEABIHF  { "musleabihf", "musleabihf" },
	MUSLF32     { "muslf32", "muslf32" },
	MUSLSF      { "muslsf", "muslsf" },
	MUSLX32     { "muslx32", "muslx32" },
	OHOS        { "ohos", "ohos" },
	OHOSEABI    { "ohoseabi", "ohoseabi" },
	SIMULATOR   { "simulator", "simulator" },
	X32         { "x32", "unknown" },
}

fn bool Abi.is_gnu(self)
{
	switch (self)
	{
		case GNU:
		case GNUABI64:
		case GNUABIN32:
		case GNUEABI:
		case GNUEABIHF:
		case GNUF32:
		case GNUSF:
		case GNUX32: return true;
		default: return false;
	}
}

<* OpenHarmony uses musl, so ohos/ohoseabi count as musl (std.Target.Abi.isMusl). *>
fn bool Abi.is_musl(self)
{
	switch (self)
	{
		case MUSL:
		case MUSLABI64:
		case MUSLABIN32:
		case MUSLEABI:
		case MUSLEABIHF:
		case MUSLF32:
		case MUSLSF:
		case MUSLX32:
		case OHOS:
		case OHOSEABI: return true;
		default: return false;
	}
}

fn bool Abi.is_android(self) => self == ANDROID || self == ANDROIDEABI;

enum FloatAbi : char
{
	HARD,
	SOFT,
}

<* std.Target.Abi.float. *>
fn FloatAbi Abi.float_abi(self)
{
	switch (self)
	{
		case ANDROIDEABI:
		case EABI:
		case GNUEABI:
		case GNUSF:
		case MUSLEABI:
		case MUSLSF:
		case OHOSEABI: return SOFT;
		default: return HARD;
	}
}

<* std.Target.ObjectFormat. *>
enum ObjectFormat : char (String name)
{
	C      { "c" },
	COFF   { "coff" },
	ELF    { "elf" },
	GOFF   { "goff" },
	HEX    { "hex" },
	MACHO  { "macho" },
	PLAN9  { "plan9" },
	RAW    { "raw" },
	SPIRV  { "spirv" },
	WASM   { "wasm" },
	XCOFF  { "xcoff" },
}

<* Target.Vendor. *>
enum Vendor : char (String name)
{
	APPLE                    { "apple" },
	PC                       { "pc" },
	SCEI                     { "scei" },
	SIE                      { "sie" },
	FREESCALE                { "freescale" },
	IBM                      { "ibm" },
	IMAGINATION_TECHNOLOGIES { "imagination_technologies" },
	MIPS                     { "mips" },
	NVIDIA                   { "nvidia" },
	CSR                      { "csr" },
	AMD                      { "amd" },
	MESA                     { "mesa" },
	SUSE                     { "suse" },
	OPEN_EMBEDDED            { "open_embedded" },
	INTEL                    { "intel" },
	UNKNOWN                  { "unknown" },
}

<* Target.Vendor.vendor_strings (note "sie" maps to SCEI, as in Zig). *>
fn Vendor? vendor_parse(String candidate)
{
	switch (candidate)
	{
		case "apple": return APPLE;
		case "pc": return PC;
		case "scei": return SCEI;
		case "sie": return SCEI;
		case "fsl": return FREESCALE;
		case "ibm": return IBM;
		case "img": return IMAGINATION_TECHNOLOGIES;
		case "mti": return MIPS;
		case "nvidia": return NVIDIA;
		case "csr": return CSR;
		case "amd": return AMD;
		case "mesa": return MESA;
		case "suse": return SUSE;
		case "oe": return OPEN_EMBEDDED;
		case "intel": return INTEL;
		default: return UNKNOWN_VENDOR~;
	}
}

<* Target.SubArch. *>
enum SubArch : char
{
	ARM_V4T,
	ARM_V5,
	ARM_V5TE,
	ARM_V6,
	ARM_V6K,
	ARM_V6M,
	ARM_V6T2,
	ARM_V7,
	ARM_V7A,
	ARM_V7R,
	ARM_V7EM,
	ARM_V7K,
	ARM_V7M,
	ARM_V7S,
	ARM_V7VE,
	ARM_V8,
	ARM_V8_1A,
	ARM_V8_1M_MAINLINE,
	ARM_V8_2A,
	ARM_V8_3A,
	ARM_V8_4A,
	ARM_V8_5A,
	ARM_V8_6A,
	ARM_V8_7A,
	ARM_V8_8A,
	ARM_V8_9A,
	ARM_V8M_BASELINE,
	ARM_V8M_MAINLINE,
	ARM_V8R,
	ARM_V9,
	ARM_V9_1A,
	ARM_V9_2A,
	ARM_V9_3A,
	ARM_V9_4A,
	ARM_V9_5A,
	ARM_V9_6A,
	AARCH64_ARM64E,
	AARCH64_ARM64EC,
	MIPS_R6,
	POWERPC_SPE,
	SPIRV_V10,
	SPIRV_V11,
	SPIRV_V12,
	SPIRV_V13,
	SPIRV_V14,
	SPIRV_V15,
	SPIRV_V16,
}

<* std.Target.CType. *>
enum CType : char
{
	CHAR,
	SHORT,
	USHORT,
	INT,
	UINT,
	LONG,
	ULONG,
	LONGLONG,
	ULONGLONG,
	FLOAT,
	DOUBLE,
	LONGDOUBLE,
}

<*
 The basic C integer types Target.zig names through QualType (`.long`,
 `.int`, ...). TypeStore maps these to its own handles.
*>
enum CIntKind : char
{
	SCHAR,
	UCHAR,
	SHORT,
	USHORT,
	INT,
	UINT,
	LONG,
	ULONG,
	LONG_LONG,
	ULONG_LONG,
}

// ---------------------------------------------------------------------------
// Versions and OS
// ---------------------------------------------------------------------------

<* std.SemanticVersion without pre-release/build metadata (aro never sets them). *>
struct SemVer
{
	ulong major;
	ulong minor;
	ulong patch;
}

fn int SemVer.order(self, SemVer other)
{
	if (self.major != other.major) return self.major < other.major ? -1 : 1;
	if (self.minor != other.minor) return self.minor < other.minor ? -1 : 1;
	if (self.patch != other.patch) return self.patch < other.patch ? -1 : 1;
	return 0;
}

fn bool SemVer.eq(self, SemVer other) => self.order(other) == 0;

<* std.Target.Query.OsVersion: either a semver or a WindowsVersion. *>
struct OsVersion
{
	bool is_windows;
	SemVer semver;
	uint windows;
}

<*
 std.Target.Os: tag plus the tagged version range, flattened. `min`/`max`
 hold the semver range for SEMVER, LINUX and HURD; `win_min`/`win_max` the
 WindowsVersion range; `glibc` is set for LINUX and HURD; `android` (API
 level) for LINUX.
*>
struct Os
{
	OsTag tag;
	SemVer min;
	SemVer max;
	uint win_min;
	uint win_max;
	SemVer glibc;
	uint android;
}

fn VersionRangeTag Os.range_tag(&self) => self.tag.range;

<*
 std.Target.Os.isAtLeast. Zig returns `?bool`: null when `tag` is not the
 target's OS, when the OS has no version range, or when `ver` lies inside
 (min, max]; here null is `has_result = false`.
*>
fn bool Os.is_at_least(&self, OsTag tag, SemVer ver, bool* has_result)
{
	*has_result = false;
	if (self.tag != tag) return false;
	switch (self.tag.range)
	{
		case SEMVER:
		case LINUX:
		case HURD:
			if (self.min.order(ver) >= 0)
			{
				*has_result = true;
				return true;
			}
			if (self.max.order(ver) < 0)
			{
				*has_result = true;
				return false;
			}
			return false;
		default: return false; // WINDOWS ranges are compared as WindowsVersion; NONE has no range
	}
}

<* `isAtLeast(tag, ver) orelse false`. *>
fn bool Os.is_at_least_or_false(&self, OsTag tag, SemVer ver)
{
	bool has;
	bool r = self.is_at_least(tag, ver, &has);
	return has && r;
}

// ---------------------------------------------------------------------------
// Target and Query
// ---------------------------------------------------------------------------

<* std.Target.Cpu. *>
struct Cpu
{
	Arch arch;
	CpuModel model;
	FeatureSet features;
}

fn bool Cpu.has(&self, Feature f) => self.features.has(f);

fn bool Cpu.has_all(&self, Feature[] fs)
{
	foreach (f : fs) if (!self.features.has(f)) return false;
	return true;
}

fn bool Cpu.has_any(&self, Feature[] fs)
{
	foreach (f : fs) if (self.features.has(f)) return true;
	return false;
}

struct Target
{
	Cpu cpu;
	Vendor vendor;
	Os os;
	Abi abi;
	ObjectFormat ofmt;
	<* Empty means none (Zig `DynamicLinker.none`). Points at static data. *>
	String dynamic_linker;
	<*
	 The triple named no C ABI and isn't native, so `abi` is the per-OS default
	 Zig filled in. clang treats such a triple as having an unknown environment
	 and applies its own OS defaults instead, which differ from Zig's in some cases.
	*>
	bool abi_is_default;
}

<*
 The machine the C3 compiler itself was built for (Zig `builtin`). Only
 x86_64/aarch64 on Linux, macOS and Windows are described; any other host
 makes `host()` fail with NATIVE_UNSUPPORTED instead of guessing.
*>
struct Host
{
	Arch arch;
	OsTag os;
	Abi abi;
}

fn Host? host()
{
	Host h;
	$switch env::ARCH_TYPE:
		$case X86_64: h.arch = X86_64;
		$case AARCH64: h.arch = AARCH64;
		$default: return NATIVE_UNSUPPORTED~;
	$endswitch
	$switch env::OS_TYPE:
		$case LINUX:
			h.os = LINUX;
			h.abi = GNU;
		$case MACOS:
			h.os = MACOS;
			h.abi = NONE;
		$case WIN32:
			h.os = WINDOWS;
			h.abi = MSVC;
		$default: return NATIVE_UNSUPPORTED~;
	$endswitch
	return h;
}

<* Zig `Target.default` (the native target), with the CPU at the host arch's baseline. *>
fn Target? native()
{
	Host h = host()!;
	Query q = QUERY_DEFAULT;
	q.has_arch = true;
	q.arch = h.arch;
	q.has_os_tag = true;
	q.os_tag = h.os;
	q.has_abi = true;
	q.abi = h.abi;
	Target t = resolve_query(&q, h)!;
	t.vendor = h.os.is_darwin() ? APPLE : UNKNOWN;
	return t;
}

enum CpuModelQuery : char
{
	DETERMINED_BY_ARCH_OS,
	NATIVE,
	BASELINE,
	EXPLICIT,
}

<* std.Target.Query (the fields aro sets). Start from `QUERY_DEFAULT`. *>
struct Query
{
	bool has_arch;
	Arch arch;
	CpuModelQuery cpu_model_kind;
	CpuModel cpu_model;
	FeatureSet cpu_features_add;
	FeatureSet cpu_features_sub;
	bool has_os_tag;
	OsTag os_tag;
	bool has_os_version_min;
	OsVersion os_version_min;
	bool has_os_version_max;
	OsVersion os_version_max;
	bool has_glibc_version;
	SemVer glibc_version;
	bool has_android_api_level;
	uint android_api_level;
	bool has_abi;
	Abi abi;
	bool has_ofmt;
	ObjectFormat ofmt;
}

const Query QUERY_DEFAULT = { .cpu_model_kind = DETERMINED_BY_ARCH_OS };

<* Query.isNativeAbi: the ABI is unspecified and the OS is native (unspecified). *>
fn bool Query.is_native_abi(&self) => !self.has_os_tag && !self.has_abi;

<* Query.isNative (ignoring dynamic linker / ofmt, which aro never sets). *>
fn bool Query.is_native(&self)
{
	return !self.has_arch && (self.cpu_model_kind == DETERMINED_BY_ARCH_OS || self.cpu_model_kind == NATIVE)
		&& self.cpu_features_add.is_empty() && self.cpu_features_sub.is_empty()
		&& !self.has_os_tag && !self.has_os_version_min && !self.has_os_version_max
		&& !self.has_abi && !self.has_glibc_version && !self.has_android_api_level && !self.has_ofmt;
}

<*
 std.zig.system.resolveTargetQuery for the parts aro uses. Missing arch/OS/ABI
 come from `h` only when the query leaves them native; native CPU detection is
 replaced by the host arch's baseline model.
*>
fn Target? resolve_query(Query* q, Host h)
{
	Arch arch = q.has_arch ? q.arch : h.arch;
	OsTag os_tag = q.has_os_tag ? q.os_tag : h.os;
	Os os = default_os(os_tag, arch);
	if (q.has_os_version_min)
	{
		if (q.os_version_min.is_windows) { os.win_min = q.os_version_min.windows; } else { os.min = q.os_version_min.semver; }
	}
	if (q.has_os_version_max)
	{
		if (q.os_version_max.is_windows) { os.win_max = q.os_version_max.windows; } else { os.max = q.os_version_max.semver; }
	}
	if (q.has_glibc_version) os.glibc = q.glibc_version;
	if (q.has_android_api_level) os.android = q.android_api_level;

	Abi abi;
	if (q.has_abi)
	{
		abi = q.abi;
	}
	else if (q.is_native_abi() && arch == h.arch)
	{
		abi = h.abi;
	}
	else
	{
		abi = default_abi(arch, os_tag);
	}

	CpuModel model;
	switch (q.cpu_model_kind)
	{
		case EXPLICIT: model = q.cpu_model;
		case NATIVE:
		case BASELINE:
		case DETERMINED_BY_ARCH_OS: model = baseline_model(arch, os_tag);
	}
	FeatureSet fs = model.feature_set();
	fs.remove_set(q.cpu_features_sub);
	fs.add_set(q.cpu_features_add);
	fs.populate_dependencies();
	fs.remove_set(q.cpu_features_sub);

	return {
		.cpu = { .arch = arch, .model = model, .features = fs },
		.vendor = UNKNOWN,
		.os = os,
		.abi = abi,
		.ofmt = q.has_ofmt ? q.ofmt : default_object_format(os_tag, arch),
		.dynamic_linker = "",
	};
}

<* Why `parse_triple` failed, and the offending text (Driver error messages). *>
struct TripleError
{
	String text;
}

<*
 Driver.parseTarget without CPU feature flags: `arch[-vendor]-os[-abi]` (or
 "native"). `cpu` is the -mcpu value or "" (model name, then +feat/-feat
 using Zig feature names). On failure `err.text` holds the text the Driver
 quotes in its fatal error:
   UNKNOWN_ARCH "unknown architecture: '{s}'", UNKNOWN_OS "unknown operating
   system '{s}'", INVALID_OS_VERSION "invalid operating system version '{s}'",
   UNKNOWN_ABI "unknown ABI '{s}'", INVALID_ABI_VERSION "invalid ABI version
   '{s}'", INVALID_API_VERSION "invalid Android API version '{s}'",
   UNEXPECTED_EXTRA_FIELD "unexpected extra field in target: '{s}'",
   UNKNOWN_CPU_MODEL "unknown CPU model: '{s}'", UNKNOWN_CPU_FEATURE
   "unknown CPU feature: '{s}'".
*>
fn Target? parse_triple(String arch_os_abi, Host h, String cpu = "", TripleError* err = null)
{
	TripleError dummy;
	if (!err) err = &dummy;
	Query query = QUERY_DEFAULT;
	Vendor vendor = UNKNOWN;
	bool has_sub_arch;
	SubArch sub_arch;

	SplitIter it = { .s = arch_os_abi };
	String arch_name = it.next()!!;
	bool arch_is_native = arch_name == "native";
	if (!arch_is_native)
	{
		ArchSubArch? as = parse_arch_name(arch_name, h);
		if (catch as)
		{
			err.text = arch_name;
			return UNKNOWN_ARCH~;
		}
		query.has_arch = true;
		query.arch = as.arch;
		has_sub_arch = as.has_sub;
		sub_arch = as.sub;
	}
	Arch arch = query.has_arch ? query.arch : h.arch;

	bool has_os_text;
	String os_text;
	if (try os_or_vendor = it.next())
	{
		if (try v = vendor_parse_name(os_or_vendor))
		{
			vendor = v;
			if (try o = it.next())
			{
				os_text = o;
				has_os_text = true;
			}
		}
		else
		{
			os_text = os_or_vendor;
			has_os_text = true;
		}
	}
	if (has_os_text)
	{
		String version_str;
		if (catch f = parse_os(&query, os_text, h, &version_str))
		{
			err.text = f == UNKNOWN_OS ? os_text : version_str;
			return f~;
		}
	}
	if (try abi_text = it.next())
	{
		String version_str;
		if (catch f = parse_abi(&query, abi_text, &version_str))
		{
			err.text = f == UNKNOWN_ABI ? abi_text : version_str;
			return f~;
		}
	}
	if (try extra = it.next())
	{
		err.text = arch_os_abi;
		return UNEXPECTED_EXTRA_FIELD~;
	}

	if (cpu.len)
	{
		apply_cpu_features(&query, arch, cpu, has_sub_arch, sub_arch, err)!;
	}
	else if (!arch_is_native)
	{
		if (try model = cpu_model_for_target_quadruple(arch, query.has_os_tag, query.os_tag, query.has_abi, query.abi, vendor, has_sub_arch, sub_arch, h))
		{
			query.cpu_model_kind = EXPLICIT;
			query.cpu_model = model;
		}
		else if (has_sub_arch)
		{
			if (try model = sub_arch.to_cpu_model(arch))
			{
				query.cpu_model_kind = EXPLICIT;
				query.cpu_model = model;
			}
			else if (try feature = sub_arch.to_feature(arch))
			{
				query.cpu_model_kind = EXPLICIT;
				query.cpu_model = EMPTY;
				query.cpu_features_add.add(feature);
			}
		}
	}

	Target target = resolve_query(&query, h)!;
	if (query.is_native() && target.os.tag.is_darwin()) vendor = APPLE;
	target.vendor = vendor;
	target.abi_is_default = !query.has_abi && !query.is_native_abi();
	return target;
}

<* Zig mem.splitScalar(u8, s, '-'): yields at least one (possibly empty) part. *>
struct SplitIter
{
	String s;
	usz pos;
	bool done;
}

fn String? SplitIter.next(&self)
{
	if (self.done) return UNEXPECTED_EXTRA_FIELD~;
	usz start = self.pos;
	usz i = start;
	while (i < self.s.len && self.s[i] != '-') i++;
	if (i == self.s.len) self.done = true;
	self.pos = i + 1;
	return self.s[start:i - start];
}

<* The -mcpu=<model>(+feat|-feat)* handling of Driver.parseTarget. *>
fn void? apply_cpu_features(Query* query, Arch arch, String cpu_features, bool has_sub_arch, SubArch sub_arch, TripleError* err)
{
	usz index = 0;
	while (index < cpu_features.len && cpu_features[index] != '+' && cpu_features[index] != '-') index++;
	String cpu_name = cpu_features[:index];
	if (cpu_name == "native")
	{
		query.cpu_model_kind = NATIVE;
	}
	else if (cpu_name == "baseline")
	{
		query.cpu_model_kind = BASELINE;
	}
	else
	{
		CpuModel? m = parse_cpu_model(arch, cpu_name);
		if (catch m)
		{
			err.text = cpu_name;
			return UNKNOWN_CPU_MODEL~;
		}
		query.cpu_model_kind = EXPLICIT;
		query.cpu_model = m;
	}
	if (has_sub_arch)
	{
		if (try feature = sub_arch.to_feature(arch)) query.cpu_features_add.add(feature);
	}
	while (index < cpu_features.len)
	{
		char op = cpu_features[index];
		index++;
		usz start = index;
		while (index < cpu_features.len && cpu_features[index] != '+' && cpu_features[index] != '-') index++;
		String feature_name = cpu_features[start:index - start];
		Feature? f = parse_feature_name(arch, feature_name);
		if (catch f)
		{
			err.text = feature_name;
			return UNKNOWN_CPU_FEATURE~;
		}
		if (op == '+') { query.cpu_features_add.add(f); } else { query.cpu_features_sub.add(f); }
	}
}

<* Convenience for tests and tools: a target from a triple with a fixed host. *>
fn Target? from_triple(String triple, Host h = { X86_64, LINUX, GNU }, String cpu = "")
{
	return parse_triple(triple, h, cpu);
}

// ---------------------------------------------------------------------------
// Name parsing (Target.zig parseArchName / parseOsName / parseVendorName /
// parseAbiName / parseAbi / parseOs / parseVersion)
// ---------------------------------------------------------------------------

<* Target.toLower: fails when `src` is longer than the 64-byte buffer. *>
fn String? to_lower(String src, char[] dest) @local
{
	if (src.len > dest.len) return UNKNOWN_ARCH~;
	foreach (i, c : src) dest[i] = (c >= 'A' && c <= 'Z') ? c + 32 : c;
	return (String)dest[:src.len];
}

fn Arch? arch_from_name(String name)
{
	foreach (a : Arch::values) if (a.name == name) return a;
	return UNKNOWN_ARCH~;
}

fn OsTag? os_tag_from_name(String name)
{
	foreach (t : OsTag::values) if (t.name == name) return t;
	return UNKNOWN_OS~;
}

fn Abi? abi_from_name(String name)
{
	foreach (a : Abi::values) if (a.name == name) return a;
	return UNKNOWN_ABI~;
}

struct ArchSubArch
{
	Arch arch;
	bool has_sub;
	SubArch sub;
}

fn ArchSubArch? arch_alias(String lower) @local
{
	switch (lower)
	{
		case "i386":
		case "i486":
		case "i586":
		case "i686":
		case "i786":
		case "i886":
		case "i986": return { X86, false, ARM_V4T };
		case "amd64":
		case "x86_64h": return { X86_64, false, ARM_V4T };
		case "powerpcspe": return { POWERPC, true, POWERPC_SPE };
		case "ppc":
		case "ppc32": return { POWERPC, false, ARM_V4T };
		case "ppcle":
		case "ppc32le": return { POWERPCLE, false, ARM_V4T };
		case "ppu":
		case "ppc64": return { POWERPC64, false, ARM_V4T };
		case "ppc64le": return { POWERPC64LE, false, ARM_V4T };
		case "xscale": return { ARM, false, ARM_V4T };
		case "xscaleeb": return { ARMEB, false, ARM_V4T };
		case "arm64": return { AARCH64, false, ARM_V4T };
		case "arm64e": return { AARCH64, true, AARCH64_ARM64E };
		case "arm64ec": return { AARCH64, true, AARCH64_ARM64EC };
		case "mipseb":
		case "mipsallegrex": return { MIPS, false, ARM_V4T };
		case "mipsisa32r6":
		case "mipsr6": return { MIPS, true, MIPS_R6 };
		case "mipsallegrexel": return { MIPSEL, false, ARM_V4T };
		case "mipsisa32r6el":
		case "mipsr6el": return { MIPSEL, true, MIPS_R6 };
		case "mips64eb":
		case "mipsn32": return { MIPS64, false, ARM_V4T };
		case "mipsisa64r6":
		case "mips64r6":
		case "mipsn32r6": return { MIPS64, true, MIPS_R6 };
		case "mipsn32el": return { MIPS64EL, false, ARM_V4T };
		case "mipsisa64r6el":
		case "mips64r6el":
		case "mipsn32r6el": return { MIPS64EL, true, MIPS_R6 };
		case "systemz": return { S390X, false, ARM_V4T };
		case "sparcv9": return { SPARC64, false, ARM_V4T };
		case "spirv32": return { SPIRV32, false, ARM_V4T };
		case "spirv32v1.0": return { SPIRV32, true, SPIRV_V10 };
		case "spirv32v1.1": return { SPIRV32, true, SPIRV_V11 };
		case "spirv32v1.2": return { SPIRV32, true, SPIRV_V12 };
		case "spirv32v1.3": return { SPIRV32, true, SPIRV_V13 };
		case "spirv32v1.4": return { SPIRV32, true, SPIRV_V14 };
		case "spirv32v1.5": return { SPIRV32, true, SPIRV_V15 };
		case "spirv32v1.6": return { SPIRV32, true, SPIRV_V16 };
		case "spirv64v1.0": return { SPIRV64, true, SPIRV_V10 };
		case "spirv64v1.1": return { SPIRV64, true, SPIRV_V11 };
		case "spirv64v1.2": return { SPIRV64, true, SPIRV_V12 };
		case "spirv64v1.3": return { SPIRV64, true, SPIRV_V13 };
		case "spirv64v1.4": return { SPIRV64, true, SPIRV_V14 };
		case "spirv64v1.5": return { SPIRV64, true, SPIRV_V15 };
		case "spirv64v1.6": return { SPIRV64, true, SPIRV_V16 };
		default: return UNKNOWN_ARCH~;
	}
}

fn SubArch? arm_subarch(String s) @local
{
	switch (s)
	{
		case "v4t": return ARM_V4T;
		case "v5":
		case "v5t": return ARM_V5;
		case "v5e":
		case "v5te":
		case "v5tel": return ARM_V5TE;
		case "v6":
		case "v6j": return ARM_V6;
		case "v6k":
		case "v6hl": return ARM_V6K;
		case "v6m":
		case "v6sm":
		case "v6s-m":
		case "v6-m": return ARM_V6M;
		case "v6z":
		case "v6zk":
		case "v6kz": return ARM_V6K;
		case "v7": return ARM_V7;
		case "v7a":
		case "v7-a": return ARM_V7A;
		case "v7hl":
		case "v7l": return ARM_V7;
		case "v7r": return ARM_V7R;
		case "v7m":
		case "v7-m": return ARM_V7M;
		case "v7em":
		case "v7e-m": return ARM_V7EM;
		case "v8":
		case "v8a":
		case "v8l":
		case "v8-a": return ARM_V8;
		case "v8.1a":
		case "v8.1-a": return ARM_V8_1A;
		case "v8.2a":
		case "v8.2-a": return ARM_V8_2A;
		case "v8.3a":
		case "v8.3-a": return ARM_V8_3A;
		case "v8.4a":
		case "v8.4-a": return ARM_V8_4A;
		case "v8.5a":
		case "v8.5-a": return ARM_V8_5A;
		case "v8.6a":
		case "v8.6-a": return ARM_V8_6A;
		case "v8.7a":
		case "v8.7-a": return ARM_V8_7A;
		case "v8.8a":
		case "v8.8-a": return ARM_V8_8A;
		case "v8.9a":
		case "v8.9-a": return ARM_V8_9A;
		case "v8r":
		case "v8-r": return ARM_V8R;
		case "v9": return ARM_V9;
		case "v9a":
		case "v9-a":
		case "v9.1a":
		case "v9.1-a": return ARM_V9_1A;
		case "v9.2a":
		case "v9.2-a": return ARM_V9_2A;
		case "v9.3a":
		case "v9.3-a": return ARM_V9_3A;
		case "v9.4a":
		case "v9.4-a": return ARM_V9_4A;
		case "v9.5a":
		case "v9.5-a": return ARM_V9_5A;
		case "v9.6a":
		case "v9.6-a": return ARM_V9_6A;
		case "v8m.base":
		case "v8-m.base": return ARM_V8M_BASELINE;
		case "v8m.main":
		case "v8-m.main": return ARM_V8M_MAINLINE;
		case "v8.1m.main":
		case "v8.1-m.main": return ARM_V8_1M_MAINLINE;
		default: return UNKNOWN_ARCH~;
	}
}

<*
 Target.parseArchName. The bare "bpf" alias picks the endianness of the host
 (Zig reads builtin.cpu.arch), so it takes `h`.
*>
fn ArchSubArch? parse_arch_name(String query, Host h = { X86_64, LINUX, GNU })
{
	char[64] buf;
	String lower = to_lower(query, &buf)!;
	if (try a = arch_from_name(lower)) return { a, false, ARM_V4T };
	if (try as = arch_alias(lower)) return as;

	foreach (arch : (Arch[]){ ARM, ARMEB, THUMB, THUMBEB, AARCH64, AARCH64_BE })
	{
		String name = arch.name;
		if (!lower.starts_with(name)) continue;
		Arch actual_arch = arch;
		String trimmed = lower[name.len..];
		if (arch == ARM && trimmed.ends_with("eb"))
		{
			actual_arch = ARMEB;
			trimmed = trimmed[:trimmed.len - 2];
		}
		else if (arch == THUMB && trimmed.ends_with("eb"))
		{
			actual_arch = THUMBEB;
			trimmed = trimmed[:trimmed.len - 2];
		}
		if (try sub_arch = arm_subarch(trimmed))
		{
			bool m_profile = sub_arch == ARM_V6M || sub_arch == ARM_V7EM || sub_arch == ARM_V7M;
			if (actual_arch.is_thumb())
			{
				if (!m_profile) actual_arch = actual_arch == THUMB ? ARM : ARMEB;
			}
			else if (actual_arch.is_arm())
			{
				if (m_profile) actual_arch = actual_arch == ARM ? THUMB : THUMBEB;
			}
			return { actual_arch, true, sub_arch };
		}
	}

	if (lower.starts_with("bpf"))
	{
		if (lower.len == 3) return { h.arch.big ? BPFEB : BPFEL, false, ARM_V4T };
		String rest = lower[3..];
		if (rest == "_le" || rest == "el") return { BPFEL, false, ARM_V4T };
		if (rest == "_be" || rest == "eb") return { BPFEB, false, ARM_V4T };
	}
	return UNKNOWN_ARCH~;
}

<* Target.parseOsName. *>
fn OsTag? parse_os_name(String query)
{
	char[64] buf;
	String? lower = to_lower(query, &buf);
	if (catch lower) return UNKNOWN_OS~;
	if (try t = os_tag_from_name(lower)) return t;
	switch (lower)
	{
		case "darwin":
		case "macosx": return MACOS;
		case "win32": return WINDOWS;
		case "xros": return VISIONOS;
		default: return UNKNOWN_OS~;
	}
}

<* Target.parseVendorName. *>
fn Vendor? vendor_parse_name(String query)
{
	char[64] buf;
	String lower = to_lower(query, &buf)!;
	return vendor_parse(lower);
}

<* Target.parseAbiName. *>
fn Abi? parse_abi_name(String query)
{
	char[64] buf;
	String? lower = to_lower(query, &buf);
	if (catch lower) return UNKNOWN_ABI~;
	return abi_from_name(lower);
}

<* Target.isAbi. *>
fn bool Target.is_abi(&self, String query)
{
	char[64] buf;
	String? lower = to_lower(query, &buf);
	if (catch lower) return false;
	if (try some = abi_from_name(lower))
	{
		// Clang thinks maccatalyst has macabi
		if (some == NONE && self.os.tag == MACCATALYST) return false;
		return self.abi == some;
	}
	if (lower == "macabi") return self.os.tag == MACCATALYST;
	return false;
}

<* Target.isOs. *>
fn bool Target.is_os(&self, String query_str, Host h = { X86_64, LINUX, GNU })
{
	Query query = QUERY_DEFAULT;
	if (catch parse_os(&query, query_str, h)) return false;
	if (!query.has_os_tag) return false;
	// clang treats all darwin OS's as equivalent
	if (query.os_tag.is_darwin()) return self.os.tag.is_darwin();
	return self.os.tag == query.os_tag;
}

<* std.fmt.parseUnsigned(T, s, 10): digits with interior '_' separators. *>
fn ulong? parse_unsigned(String s, ulong max) @local
{
	if (s.len == 0 || s[0] == '_' || s[^1] == '_') return INVALID_VERSION~;
	ulong v = 0;
	foreach (c : s)
	{
		if (c == '_') continue;
		if (c < '0' || c > '9') return INVALID_VERSION~;
		ulong d = (ulong)(c - '0');
		if (v > (max - d) / 10) return OVERFLOW~;
		v = v * 10 + d;
	}
	return v;
}

const ulong USIZE_MAX = 0xFFFF_FFFF_FFFF_FFFF;

<*
 Target.parseVersion: 1, 2 or 3 dot-separated components; missing ones are 0.
 @return? INVALID_VERSION, OVERFLOW
*>
fn SemVer? parse_version(String ver)
{
	String[3] comps = { "", "0", "0" };
	usz n = 0;
	usz start = 0;
	for (usz i = 0; i <= ver.len; i++)
	{
		if (i == ver.len || ver[i] == '.')
		{
			if (n == 3) return INVALID_VERSION~;
			comps[n++] = ver[start:i - start];
			start = i + 1;
		}
	}
	return { parse_unsigned(comps[0], USIZE_MAX)!, parse_unsigned(comps[1], USIZE_MAX)!, parse_unsigned(comps[2], USIZE_MAX)! };
}

<* std.Target.Query.parseVersion: like parse_version but the minor component is required. *>
fn SemVer? std_parse_version(String ver)
{
	usz dots = 0;
	foreach (c : ver) if (c == '.') dots++;
	if (dots == 0) return INVALID_VERSION~;
	return parse_version(ver);
}

<*
 Target.parseAbi: `<abi>(.?<version>)?`. Populates `abi`, `glibc_version`
 and `android_api_level` of `result`; `version_string` receives the version
 text (also when INVALID_ABI_VERSION / INVALID_API_VERSION is returned).
 @return? UNKNOWN_ABI, INVALID_ABI_VERSION, INVALID_API_VERSION
*>
fn void? parse_abi(Query* result, String text, String* version_string = null)
{
	Abi abi;
	String version_text;
	bool found;
	foreach (i, c : text)
	{
		if (c >= '0' && c <= '9')
		{
			if (try a = parse_abi_name(text[:i]))
			{
				abi = a;
				version_text = text[i..];
				found = true;
				break;
			}
		}
		else if (c == '.')
		{
			abi = parse_abi_name(text[:i])!;
			version_text = text[i + 1..];
			found = true;
			break;
		}
	}
	if (!found)
	{
		Abi? a = parse_abi_name(text);
		if (catch a)
		{
			if (text == "macabi" && result.has_os_tag && result.os_tag == IOS)
			{
				result.os_tag = MACCATALYST;
				return;
			}
			return UNKNOWN_ABI~;
		}
		abi = a;
		version_text = "";
	}
	result.has_abi = true;
	result.abi = abi;
	if (version_string) *version_string = version_text;

	if (version_text.len != 0)
	{
		if (abi.is_gnu())
		{
			SemVer? v = std_parse_version(version_text);
			if (catch v) return INVALID_ABI_VERSION~;
			result.has_glibc_version = true;
			result.glibc_version = v;
		}
		else if (abi.is_android())
		{
			ulong? lvl = parse_unsigned(version_text, 0xFFFF_FFFF);
			if (catch lvl) return INVALID_API_VERSION~;
			result.has_android_api_level = true;
			result.android_api_level = (uint)lvl;
		}
		else
		{
			return INVALID_ABI_VERSION~;
		}
	}
}

fn OsTag? check_os(String os_text, Host h) @local
{
	if (os_text == "native") return h.os;
	return parse_os_name(os_text);
}

fn OsVersion? parse_os_version_part(VersionRangeTag tag, String text) @local
{
	if (tag == WINDOWS)
	{
		uint? w = windows_version_parse(text);
		if (catch w) return INVALID_OS_VERSION~;
		return { .is_windows = true, .windows = w };
	}
	SemVer? v = parse_version(text);
	if (catch v) return INVALID_OS_VERSION~;
	return { .semver = v };
}

<*
 Target.parseOs: `<os>(.?<version>(...<version>))?`. "native" is the host OS
 (`h`). Populates `os_tag`, `os_version_min` and `os_version_max`;
 `version_string` receives the version text.
 @return? UNKNOWN_OS, INVALID_OS_VERSION
*>
fn void? parse_os(Query* result, String text, Host h = { X86_64, LINUX, GNU }, String* version_string = null)
{
	bool seen_digit;
	OsTag tag;
	String version_text;
	bool found;
	foreach (i, c : text)
	{
		if (c >= '0' && c <= '9')
		{
			if (i == 0) continue;
			if (try os = check_os(text[:i], h))
			{
				tag = os;
				version_text = text[i..];
				found = true;
				break;
			}
			seen_digit = true;
		}
		else if (c == '.')
		{
			OsTag? os = check_os(text[:i], h);
			if (catch os) return UNKNOWN_OS~;
			tag = os;
			version_text = text[i + 1..];
			found = true;
			break;
		}
		else if (seen_digit)
		{
			if (try os = check_os(text[:i], h))
			{
				tag = os;
				version_text = text[i..];
				found = true;
				break;
			}
		}
	}
	if (!found)
	{
		OsTag? os = check_os(text, h);
		if (catch os) return UNKNOWN_OS~;
		tag = os;
		version_text = "";
	}

	result.has_os_tag = true;
	result.os_tag = tag;
	if (version_string) *version_string = version_text;

	if (version_text.len > 0)
	{
		VersionRangeTag rt = tag.range;
		if (rt == NONE) return INVALID_OS_VERSION~;
		// split on "..."
		usz sep = version_text.len;
		for (usz i = 0; i + 3 <= version_text.len; i++)
		{
			if (version_text[i:3] == "...")
			{
				sep = i;
				break;
			}
		}
		result.os_version_min = parse_os_version_part(rt, version_text[:sep])!;
		result.has_os_version_min = true;
		if (sep < version_text.len)
		{
			String rest = version_text[sep + 3..];
			// Zig's splitSequence: a further "..." makes this component invalid.
			result.os_version_max = parse_os_version_part(rt, rest)!;
			result.has_os_version_max = true;
		}
	}
}

// ---------------------------------------------------------------------------
// Target.zig queries
// ---------------------------------------------------------------------------

fn ushort Target.ptr_bit_width(&self) => ptr_bit_width_arch_abi(self.cpu.arch, self.abi);

fn ushort Target.c_type_bit_size(&self, CType t) => c_type_bit_size(self, t);
fn ushort Target.c_type_alignment(&self, CType t) => c_type_alignment(self, t);
fn ushort Target.c_type_byte_size(&self, CType t) => c_type_byte_size(self, t);
fn Signedness Target.c_char_signedness(&self) => c_char_signedness(self);

<* Target.standardDynamicLinkerPath; "" means none. *>
fn String Target.standard_dynamic_linker_path(&self) => standard_dynamic_linker(self);

<* intmax_t for this target *>
fn CIntKind Target.int_max_type(&self)
{
	switch (self.cpu.arch)
	{
		case AARCH64:
		case AARCH64_BE:
		case SPARC64:
			if (self.os.tag == OPENBSD) return LONG_LONG;
			if (self.os.tag == WINDOWS) return LONG_LONG;
			if (self.os.tag.is_darwin() && self.abi == ILP32) return LONG_LONG;
			return LONG;
		case BPFEL:
		case BPFEB:
		case LOONGARCH64:
		case RISCV64:
		case POWERPC64:
		case POWERPC64LE:
		case VE:
			return LONG;
		case X86_64:
			switch (self.os.tag)
			{
				case WINDOWS:
				case OPENBSD:
				case UEFI: break;
				default:
					switch (self.abi)
					{
						case GNUX32:
						case MUSLX32:
						case X32:
						case GNUABIN32:
						case MUSLABIN32:
						case ABIN32:
						case ILP32: break;
						default: return LONG;
					}
			}
		default: break;
	}
	return LONG_LONG;
}

<* intptr_t for this target *>
fn CIntKind Target.int_ptr_type(&self)
{
	if (self.os.tag == HAIKU) return LONG;
	switch (self.cpu.arch)
	{
		case AARCH64:
		case AARCH64_BE:
			if (self.os.tag == WINDOWS) return LONG_LONG;
		case MSP430:
		case CSKY:
		case LOONGARCH32:
		case RISCV32:
		case XCORE:
		case HEXAGON:
		case M68K:
		case SPIRV32:
		case ARC:
		case AVR:
			return INT;
		case SPARC:
			if (self.os.tag != NETBSD && self.os.tag != OPENBSD) return INT;
		case POWERPC:
		case POWERPCLE:
			if (self.os.tag == LINUX || self.os.tag == FREEBSD || self.os.tag == NETBSD) return INT;
		case X86:
			// 32-bit x86 Darwin, OpenBSD, and RTEMS use long (the default); others use int
			if (self.os.tag != OPENBSD && self.os.tag != RTEMS && !self.os.tag.is_darwin()) return INT;
		case X86_64:
			if (self.os.tag == WINDOWS) return LONG_LONG;
			if (self.abi == GNUX32 || self.abi == MUSLX32) return INT;
		default: break;
	}
	return LONG;
}

<* int16_t for this target *>
fn CIntKind Target.int16_type(&self) => self.cpu.arch == AVR ? INT : SHORT;

<* sig_atomic_t for this target *>
fn CIntKind Target.sig_atomic_type(&self)
{
	if (self.cpu.arch.is_wasm()) return LONG;
	switch (self.cpu.arch)
	{
		case AVR: return SCHAR;
		case MSP430: return LONG;
		default: return INT;
	}
}

<* int64_t for this target *>
fn CIntKind Target.int64_type(&self)
{
	switch (self.cpu.arch)
	{
		case LOONGARCH64:
		case VE:
		case RISCV64:
		case POWERPC64:
		case POWERPC64LE:
		case BPFEL:
		case BPFEB:
			return LONG;
		case SPARC64:
			return self.int_max_type();
		case X86:
		case X86_64:
			if (!self.os.tag.is_darwin()) return self.int_max_type();
		case AARCH64:
		case AARCH64_BE:
			if (!self.os.tag.is_darwin() && self.os.tag != OPENBSD && self.os.tag != WINDOWS) return LONG;
		default: break;
	}
	return LONG_LONG;
}

<*
 wchar_t for this target. Not in Target.zig: this is TypeStore.initNamedTypes'
 `wchar` selection, kept here so it stays independent of TypeStore.
*>
fn CIntKind Target.wchar_type(&self)
{
	switch (self.os.tag)
	{
		case OPENBSD:
		case NETBSD: return INT;
		case PS4:
		case PS5:
		case UEFI:
		case WINDOWS: return USHORT;
		case DRIVERKIT:
		case IOS:
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case VISIONOS:
		case WATCHOS: return INT;
		default:
			switch (self.cpu.arch)
			{
				case AARCH64:
				case AARCH64_BE:
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case VE:
				case MSP430: return UINT;
				case XCORE: return UCHAR;
				default: return INT;
			}
	}
}

<* Bit width of a CIntKind on this target. *>
fn ushort Target.int_kind_bits(&self, CIntKind k)
{
	switch (k)
	{
		case SCHAR:
		case UCHAR: return 8;
		case SHORT: return self.c_type_bit_size(SHORT);
		case USHORT: return self.c_type_bit_size(USHORT);
		case INT: return self.c_type_bit_size(INT);
		case UINT: return self.c_type_bit_size(UINT);
		case LONG: return self.c_type_bit_size(LONG);
		case ULONG: return self.c_type_bit_size(ULONG);
		case LONG_LONG: return self.c_type_bit_size(LONGLONG);
		case ULONG_LONG: return self.c_type_bit_size(ULONGLONG);
	}
}

<* Target.float80Type: true when `long double` is the 80-bit type. *>
fn bool Target.has_float80_type(&self) => self.cpu.arch == X86 || self.cpu.arch == X86_64;

<* This function returns 1 if function alignment is not observable or settable. *>
fn char Target.default_function_alignment(&self)
{
	// Overrides of the minimum for performance.
	switch (self.cpu.arch)
	{
		case CSKY:
		case THUMB:
		case THUMBEB:
		case XCORE: return 4;
		case AARCH64:
		case AARCH64_BE:
		case HEXAGON:
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE:
		case S390X:
		case X86:
		case X86_64: return 16;
		case LOONGARCH32:
		case LOONGARCH64: return 32;
		default: return self.min_function_alignment();
	}
}

<* This function returns 1 if function alignment is not observable or settable. *>
fn char Target.min_function_alignment(&self)
{
	switch (self.cpu.arch)
	{
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE:
			return self.cpu.has_any({ RISCV_C, RISCV_ZCA }) ? 2 : 4;
		case THUMB:
		case THUMBEB:
		case CSKY:
		case M68K:
		case MSP430:
		case SH:
		case SHEB:
		case S390X:
		case XCORE: return 2;
		case AARCH64:
		case AARCH64_BE:
		case ALPHA:
		case ARC:
		case ARCEB:
		case ARM:
		case ARMEB:
		case HEXAGON:
		case HPPA:
		case HPPA64:
		case LANAI:
		case LOONGARCH32:
		case LOONGARCH64:
		case MICROBLAZE:
		case MICROBLAZEEL:
		case MIPS:
		case MIPSEL:
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE:
		case SPARC:
		case SPARC64:
		case XTENSA:
		case XTENSAEB: return 4;
		case BPFEB:
		case BPFEL:
		case MIPS64:
		case MIPS64EL: return 8;
		case VE: return 16;
		default: return 1;
	}
}

fn bool Target.is_blocks_supported(&self)
{
	if (self.os.tag.is_darwin())
	{
		// per https://clang.llvm.org/docs/Block-ABI-Apple.html#id1, usage on macos prior to 10.6 is undefined
		bool has;
		bool sup = self.os.is_at_least(MACOS, { 10, 6, 0 }, &has);
		if (has) return sup;
		// TODO: do iOS or other OSes have a min version?
		return self.os.tag != MACOS;
	}
	return false;
}

fn bool Target.is_tls_supported(&self)
{
	if (self.os.tag.is_darwin())
	{
		if (self.os.tag == MACOS) return !self.os.is_at_least_or_false(MACOS, { 10, 7, 0 });
		return false;
	}
	switch (self.cpu.arch)
	{
		case BPFEL:
		case BPFEB:
		case MSP430:
		case NVPTX:
		case NVPTX64:
		case X86:
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return false;
		default: return true;
	}
}

fn bool Target.ignore_non_zero_sized_bitfield_type_alignment(&self)
{
	switch (self.cpu.arch)
	{
		case AVR: return true;
		case ARM:
			if (self.cpu.has(ARM_HAS_V7)) return self.os.tag == IOS;
			return false;
		default: return false;
	}
}

fn bool Target.ignore_zero_sized_bitfield_type_alignment(&self) => self.cpu.arch == AVR;

<* Target.minZeroWidthBitfieldAlignment; 0 means null. *>
fn uint Target.min_zero_width_bitfield_alignment(&self)
{
	switch (self.cpu.arch)
	{
		case AVR: return 8;
		case ARM:
			if (self.cpu.has(ARM_HAS_V7) && self.os.tag == IOS) return 32;
			return 0;
		default: return 0;
	}
}

fn bool Target.unnamed_field_affects_alignment(&self)
{
	switch (self.cpu.arch)
	{
		case AARCH64:
			if (self.os.tag.is_darwin() || self.os.tag == WINDOWS) return false;
			return true;
		case ARMEB:
			if (self.cpu.has(ARM_HAS_V7))
			{
				if (default_abi(self.cpu.arch, self.os.tag) == EABI) return true;
			}
			return false;
		case ARM: return true;
		case AVR: return true;
		case THUMB: return self.os.tag != WINDOWS;
		default: return false;
	}
}

fn bool Target.pack_all_enums(&self) => self.cpu.arch == HEXAGON;

<* Default alignment (in bytes) for __attribute__((aligned)) when no alignment is specified *>
fn uint Target.default_alignment(&self)
{
	switch (self.cpu.arch)
	{
		case AVR: return 1;
		case ARM: return (self.abi.is_android() || self.os.tag == IOS) ? 16 : 8;
		case SPARC: return self.cpu.has(SPARC_V9) ? 16 : 8;
		case MIPS:
		case MIPSEL:
			return (self.abi == NONE || self.abi == GNUABI64) ? 16 : 8;
		case S390X:
		case ARMEB:
		case THUMBEB:
		case THUMB: return 8;
		default: return 16;
	}
}

fn Compiler Target.system_compiler(&self)
{
	// Android is linux but not gcc, so these checks go first
	// the rest for documentation as fn returns .clang
	if (self.os.tag.is_darwin() || self.abi.is_android() || self.os.tag.is_bsd() || self.os.tag == FUCHSIA
		|| self.os.tag == ILLUMOS || self.os.tag == HAIKU || self.cpu.arch == HEXAGON)
	{
		return CLANG;
	}
	if (self.os.tag == UEFI) return MSVC;
	// this is before windows to grab WindowsGnu
	if (self.abi.is_gnu() || self.os.tag == LINUX) return GCC;
	if (self.os.tag == WINDOWS) return MSVC;
	if (self.cpu.arch == AVR) return GCC;
	return CLANG;
}

fn bool Target.has_float128(&self)
{
	if (self.os.tag.is_darwin()) return false;
	if (self.os.tag == WINDOWS) return false;
	if (self.cpu.arch.is_x86()) return true;
	return self.c_type_bit_size(LONGDOUBLE) == 128;
}

fn bool Target.has_int128(&self)
{
	if (self.cpu.arch == WASM32) return true;
	if (self.cpu.arch == X86_64) return true;
	return self.ptr_bit_width() >= 64;
}

fn bool Target.has_half_precision_float_abi(&self)
{
	switch (self.cpu.arch)
	{
		case THUMB:
		case THUMBEB:
		case ARM:
		case AARCH64: return true;
		default: return false;
	}
}

fn bool Target.has_aarch64_acle_types(&self) => self.cpu.arch.is_aarch64();

fn bool Target.has_protected_visibility(&self)
{
	if (self.cpu.arch.is_wasm()) return false;
	if (self.ofmt == MACHO) return false;
	return true;
}

enum FPSemantics : char
{
	NONE,
	IEEE_HALF,
	BFLOAT,
	IEEE_SINGLE,
	IEEE_DOUBLE,
	IEEE_QUAD,
	<* Minifloat 5-bit exponent 2-bit mantissa *>
	E5M2,
	<* Minifloat 4-bit exponent 3-bit mantissa *>
	E4M3,
	X87_EXTENDED_DOUBLE,
	IBM_EXTENDED_DOUBLE,
}

<*
 Only intended for generating float.h macros for the preprocessor
 @require ty == FLOAT || ty == DOUBLE || ty == LONGDOUBLE
*>
fn FPSemantics fp_semantics_for_type(CType ty, Target* target)
{
	switch (target.c_type_bit_size(ty))
	{
		case 32: return IEEE_SINGLE;
		case 64: return IEEE_DOUBLE;
		case 80: return X87_EXTENDED_DOUBLE;
		case 128: return target.cpu.arch.is_powerpc() ? IBM_EXTENDED_DOUBLE : IEEE_QUAD;
		default: unreachable("unexpected float size");
	}
}

<* FPSemantics.halfPrecisionType; NONE means null. *>
fn FPSemantics half_precision_type(Target* target)
{
	switch (target.cpu.arch)
	{
		case AARCH64:
		case AARCH64_BE:
		case ARM:
		case ARMEB:
		case HEXAGON:
		case RISCV32:
		case RISCV64:
		case SPIRV32:
		case SPIRV64: return IEEE_HALF;
		case X86:
		case X86_64: return target.cpu.has(X86_SSE2) ? IEEE_HALF : NONE;
		default: return NONE;
	}
}

fn bool Target.is_lp64(&self) => self.c_type_bit_size(INT) == 32 && self.ptr_bit_width() == 64;
fn bool Target.is_known_windows_msvc_environment(&self) => self.os.tag == WINDOWS && self.abi == MSVC;
fn bool Target.is_windows_msvc_environment(&self) => self.os.tag == WINDOWS && (self.abi == MSVC || self.abi == NONE);
fn bool Target.is_mingw(&self) => self.os.tag == WINDOWS && self.abi.is_gnu();
fn bool Target.is_ps(&self) => (self.os.tag == PS4 || self.os.tag == PS5) && self.cpu.arch == X86_64;

fn FPEvalMethod Target.default_fp_eval_method(&self)
{
	switch (self.cpu.arch)
	{
		case X86:
		case X86_64:
			if (self.ptr_bit_width() == 32 && self.os.tag == NETBSD)
			{
				if (self.os.min.order({ 6, 99, 26 }) <= 0)
				{
					// NETBSD <= 6.99.26 on 32-bit x86 defaults to double
					return DOUBLE;
				}
			}
			if (self.cpu.has(X86_SSE)) return SOURCE;
			return EXTENDED;
		default: return SOURCE;
	}
}

<*
 Value of the `-m` flag for `ld` for this target; "" means null.
 `has_arm_endianness`/`arm_endianness` is Zig's `?std.builtin.Endian` argument.
*>
fn String Target.ld_emulation_option(&self, bool has_arm_endianness = false, Endian arm_endianness = LITTLE)
{
	switch (self.cpu.arch)
	{
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB:
			Endian e = has_arm_endianness ? arm_endianness : self.cpu.arch.endian();
			return e == LITTLE ? "armelf_linux_eabi" : "armelfb_linux_eabi";
		case AARCH64: return "aarch64linux";
		case AARCH64_BE: return "aarch64linuxb";
		case CSKY: return "cskyelf_linux";
		case LOONGARCH32: return "elf32loongarch";
		case LOONGARCH64: return "elf64loongarch";
		case M68K: return "m68kelf";
		case MIPS: return "elf32btsmip";
		case MIPS64: return (self.abi == GNUABIN32 || self.abi == MUSLABIN32) ? "elf32btsmipn32" : "elf64btsmip";
		case MIPS64EL: return (self.abi == GNUABIN32 || self.abi == MUSLABIN32) ? "elf32ltsmipn32" : "elf64ltsmip";
		case MIPSEL: return "elf32ltsmip";
		case POWERPC: return self.os.tag == LINUX ? "elf32ppclinux" : "elf32ppc";
		case POWERPC64: return "elf64ppc";
		case POWERPC64LE: return "elf64lppc";
		case POWERPCLE: return self.os.tag == LINUX ? "elf32lppclinux" : "elf32lppc";
		case RISCV32: return "elf32lriscv";
		case RISCV64: return "elf64lriscv";
		case SPARC: return "elf32_sparc";
		case SPARC64: return "elf64_sparc";
		case VE: return "elf64ve";
		case X86: return "elf_i386";
		case X86_64: return (self.abi == GNUX32 || self.abi == MUSLX32) ? "elf32_x86_64" : "elf_x86_64";
		default: return "";
	}
}

fn Target? Target.get_32bit_arch_variant(&self)
{
	Target copy = *self;
	switch (self.cpu.arch)
	{
		case ALPHA:
		case AMDGCN:
		case AVR:
		case BPFEB:
		case BPFEL:
		case EZ80:
		case KVX:
		case MSP430:
		case S390X:
		case SPORK8:
		case VE:
		case Z80: return UNKNOWN_ARCH~;
		case AARCH64: copy.cpu.arch = ARM;
		case AARCH64_BE: copy.cpu.arch = ARMEB;
		case HPPA64: copy.cpu.arch = HPPA;
		case LOONGARCH64: copy.cpu.arch = LOONGARCH32;
		case MIPS64: copy.cpu.arch = MIPS;
		case MIPS64EL: copy.cpu.arch = MIPSEL;
		case NVPTX64: copy.cpu.arch = NVPTX;
		case POWERPC64: copy.cpu.arch = POWERPC;
		case POWERPC64LE: copy.cpu.arch = POWERPCLE;
		case RISCV64: copy.cpu.arch = RISCV32;
		case RISCV64BE: copy.cpu.arch = RISCV32BE;
		case SPARC64: copy.cpu.arch = SPARC;
		case SPIRV64: copy.cpu.arch = SPIRV32;
		case WASM64: copy.cpu.arch = WASM32;
		case X86_16: copy.cpu.arch = X86;
		case X86_64: copy.cpu.arch = X86;
		default: break; // Already 32 bit
	}
	return copy;
}

fn Target? Target.get_64bit_arch_variant(&self)
{
	Target copy = *self;
	switch (self.cpu.arch)
	{
		case ARC:
		case ARCEB:
		case AVR:
		case CSKY:
		case EZ80:
		case HEXAGON:
		case LANAI:
		case M68K:
		case M88K:
		case MICROBLAZE:
		case MICROBLAZEEL:
		case MSP430:
		case OR1K:
		case PROPELLER:
		case SH:
		case SHEB:
		case SPORK8:
		case XCORE:
		case XTENSA:
		case XTENSAEB:
		case Z80: return UNKNOWN_ARCH~;
		case ARM: copy.cpu.arch = AARCH64;
		case ARMEB: copy.cpu.arch = AARCH64_BE;
		case HPPA: copy.cpu.arch = HPPA64;
		case LOONGARCH32: copy.cpu.arch = LOONGARCH64;
		case MIPS: copy.cpu.arch = MIPS64;
		case MIPSEL: copy.cpu.arch = MIPS64EL;
		case NVPTX: copy.cpu.arch = NVPTX64;
		case POWERPC: copy.cpu.arch = POWERPC64;
		case POWERPCLE: copy.cpu.arch = POWERPC64LE;
		case RISCV32: copy.cpu.arch = RISCV64;
		case RISCV32BE: copy.cpu.arch = RISCV64BE;
		case SPARC: copy.cpu.arch = SPARC64;
		case SPIRV32: copy.cpu.arch = SPIRV64;
		case THUMB: copy.cpu.arch = AARCH64;
		case THUMBEB: copy.cpu.arch = AARCH64_BE;
		case WASM32: copy.cpu.arch = WASM64;
		case X86:
		case X86C16:
		case X86_16: copy.cpu.arch = X86_64;
		default: break; // Already 64 bit
	}
	return copy;
}

<*
 Target.toLLVMTriple (adapted from Zig's src/codegen/llvm.zig). Writes into
 `buf` and returns the written slice.
 @require buf.len >= 64 : "64 bytes is assumed to be large enough to hold any target triple"
*>
fn String Target.to_llvm_triple(&self, char[] buf)
{
	usz n = 0;
	String arch = (self.cpu.arch == AARCH64 && self.abi == ILP32) ? "aarch64_32" : self.cpu.arch.llvm;
	n = append(buf, n, arch);
	n = append(buf, n, "-");
	n = append(buf, n, self.os.tag.llvm);
	if (self.os.tag.is_darwin())
	{
		n = append_uint(buf, n, self.os.min.major);
		n = append(buf, n, ".");
		n = append_uint(buf, n, self.os.min.minor);
		n = append(buf, n, ".");
		n = append_uint(buf, n, self.os.min.patch);
	}
	n = append(buf, n, "-");
	String abi = self.abi.llvm;
	if (self.abi == NONE && self.os.tag == MACCATALYST) abi = "macabi";
	n = append(buf, n, abi);
	return (String)buf[:n];
}

fn usz append(char[] buf, usz n, String s) @local
{
	assert(n + s.len <= buf.len);
	buf[n:s.len] = s[..];
	return n + s.len;
}

fn usz append_uint(char[] buf, usz n, ulong v) @local
{
	char[20] tmp;
	usz len = 0;
	do
	{
		tmp[len++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	for (usz i = 0; i < len; i++) buf[n + i] = tmp[len - 1 - i];
	return n + len;
}

enum DefaultPIStatus : char
{
	YES,
	NO,
	DEPENDS_ON_LINKER,
}

fn DefaultPIStatus Target.is_pie_default(&self)
{
	switch (self.os.tag)
	{
		case HAIKU:
		case MACCATALYST:
		case MACOS:
		case IOS:
		case TVOS:
		case WATCHOS:
		case VISIONOS:
		case DRIVERKIT:
		case DRAGONFLY:
		case NETBSD:
		case FREEBSD:
		case ILLUMOS:
		case CUDA:
		case AMDHSA:
		case PS4:
		case PS5:
		case HURD: return NO;
		case OPENBSD:
		case FUCHSIA: return YES;
		case LINUX:
			if (self.abi == OHOS) return YES;
			if (self.cpu.arch == VE) return NO;
			return YES; // os.tag == .linux
		case WINDOWS:
			if (self.is_mingw()) return NO;
			if (self.abi == MSVC || self.abi == NONE) return DEPENDS_ON_LINKER;
			return NO;
		default:
			if (self.cpu.arch == HEXAGON)
			{
				// CLANG_DEFAULT_PIE_ON_LINUX
				return (self.abi.is_android() || self.abi.is_musl()) ? YES : NO;
			}
			return NO;
	}
}

<* @require self.cpu.arch.is_powerpc() *>
fn uint Target.ppc_elf_version(&self)
{
	switch (self.cpu.arch)
	{
		case POWERPC64LE: return 2;
		case POWERPC64:
			if (self.os.is_at_least_or_false(FREEBSD, { 13, 0, 0 }) || self.os.tag == OPENBSD || self.abi.is_musl()) return 2;
			return 1;
		default: return 1;
	}
}

fn DefaultPIStatus Target.is_pic_default(&self)
{
	switch (self.os.tag)
	{
		case HAIKU:
		case MACCATALYST:
		case MACOS:
		case IOS:
		case TVOS:
		case WATCHOS:
		case VISIONOS:
		case DRIVERKIT:
		case AMDHSA:
		case PS4:
		case PS5: return YES;
		case FUCHSIA:
		case CUDA: return NO;
		case DRAGONFLY:
		case OPENBSD:
		case NETBSD:
		case FREEBSD:
		case ILLUMOS:
		case HURD:
			return self.cpu.arch.is_mips64() ? YES : NO;
		case LINUX:
			if (self.abi == OHOS) return NO;
			return self.cpu.arch.is_mips64() ? YES : NO;
		case WINDOWS:
			if (self.is_mingw()) return (self.cpu.arch == X86_64 || self.cpu.arch == AARCH64) ? YES : NO;
			if (self.abi == MSVC || self.abi == NONE) return DEPENDS_ON_LINKER;
			if (self.ofmt == MACHO) return YES;
			return (self.cpu.arch == X86_64 || self.cpu.arch.is_mips64()) ? YES : NO;
		default:
			if (self.ofmt == MACHO) return YES;
			return self.cpu.arch.is_mips64() ? YES : NO;
	}
}

fn DefaultPIStatus Target.is_pic_default_forced(&self)
{
	switch (self.os.tag)
	{
		case AMDHSA: return YES;
		case HAIKU:
		case DRAGONFLY:
		case OPENBSD:
		case NETBSD:
		case FREEBSD:
		case ILLUMOS:
		case CUDA:
		case PS4:
		case PS5:
		case HURD:
		case LINUX:
		case FUCHSIA: return NO;
		case WINDOWS:
			if (self.is_mingw()) return YES;
			if (self.abi == MSVC || self.abi == NONE) return DEPENDS_ON_LINKER;
			if (self.ofmt == MACHO) return (self.cpu.arch == AARCH64 || self.cpu.arch == X86_64) ? YES : NO;
			return self.cpu.arch == X86_64 ? YES : NO;
		case MACCATALYST:
		case MACOS:
		case IOS:
		case TVOS:
		case WATCHOS:
		case VISIONOS:
		case DRIVERKIT:
			return (self.cpu.arch == X86_64 || self.cpu.arch == AARCH64) ? YES : NO;
		default:
			switch (self.cpu.arch)
			{
				case HEXAGON:
				case LANAI:
				case AVR:
				case RISCV32:
				case RISCV64:
				case CSKY:
				case XCORE:
				case WASM32:
				case WASM64:
				case VE:
				case SPIRV32:
				case SPIRV64: return NO;
				case MSP430: return YES;
				default:
					if (self.ofmt == MACHO) return (self.cpu.arch == AARCH64 || self.cpu.arch == X86_64) ? YES : NO;
					return NO;
			}
	}
}

<* The canonical integer representation of nullptr_t. *>
fn ulong Target.null_repr(&self) => 0;

enum MipsAbi : char
{
	O32,
	N32,
	N64,
}

<* @require self.cpu.arch.is_mips() *>
fn MipsAbi Target.mips_abi(&self)
{
	switch (self.abi)
	{
		case GNUABIN32:
		case MUSLABIN32:
		case ABIN32: return N32;
		default: return self.cpu.arch.is_mips32() ? O32 : N64;
	}
}

enum MipsFpMode : char
{
	FP32,
	FP64,
	FPXX,
}

<* Returns the default MIPS floating-point mode for the target. *>
fn MipsFpMode Target.default_mips_fp_mode(&self)
{
	if (self.cpu.model == MIPS32R6 || self.mips_abi() == N32 || self.mips_abi() == N64) return FP64;
	if (self.cpu.model == MIPS1) return FP32;
	return FPXX;
}

<* clang: MipsTargetInfo::getISARev, clang/lib/Basic/Targets/Mips.cpp *>
fn char Target.mips_isa_rev(&self)
{
	switch (self.cpu.model)
	{
		case MIPS32:
		case MIPS64: return 1;
		case MIPS32R2:
		case MIPS64R2:
		case OCTEON:
		case OCTEONP: return 2;
		case MIPS32R3:
		case MIPS64R3: return 3;
		case MIPS32R5:
		case MIPS64R5:
		case P5600: return 5;
		case MIPS32R6:
		case MIPS64R6:
		case I6400:
		case I6500: return 6;
		default: return 0;
	}
}

<* @require self.cpu.arch.is_arm() *>
fn bool Target.arm_has_dsp(&self)
{
	if (self.cpu.has(ARM_MCLASS)) return self.cpu.has(ARM_DSP);
	ArmVersion? v = self.arm_version();
	if (catch v) return false;
	return v.version >= 6 || v.string.starts_with("5TE");
}

enum ArmFloatAbi : char
{
	SOFT,
	SOFT_FP,
	HARD,
}

<* @require self.cpu.arch.is_arm() *>
fn ArmFloatAbi Target.arm_float_abi(&self)
{
	if (self.abi.float_abi() == SOFT) return SOFT;
	Abi abi = self.abi_is_default ? Abi.NONE : self.abi;
	switch (self.os.tag)
	{
		case WATCHOS: return HARD;
		// Darwin defaults to softfp for v6 and v7, soft otherwise.
		case IOS:
		case MACOS:
		case TVOS:
		case DRIVERKIT:
		case VISIONOS:
			ArmVersion? v = self.arm_version();
			if (catch v) return SOFT;
			return (v.version == 6 || v.version == 7) ? SOFT_FP : SOFT;
		case WINDOWS: return HARD;
		case NETBSD: return (abi == EABIHF || abi == GNUEABIHF) ? HARD : SOFT;
		// FreeBSD honours only `gnueabihf`, not `eabihf`.
		case FREEBSD: return abi == GNUEABIHF ? HARD : SOFT;
		case OPENBSD:
		case HAIKU: return SOFT_FP;
		case FUCHSIA: return HARD;
		default:
			switch (abi)
			{
				// clang checks `Triple.isOHOSFamily()` ahead of the environment switch.
				case OHOS:
				case OHOSEABI: return SOFT;
				case EABIHF:
				case GNUEABIHF:
				case MUSLEABIHF: return HARD;
				// EABI is always AAPCS, and if it was not marked 'hard', it's softfp.
				case EABI:
				case GNUEABI:
				case MUSLEABI:
				case ANDROID:
				case ANDROIDEABI: return SOFT_FP;
				default: return SOFT;
			}
	}
}

<* The `arch-os-abi` spelling the Driver uses in "unsupported option" errors. *>
fn String Target.arch_os_abi_name(&self, char[] buf)
{
	usz n = append(buf, 0, self.cpu.arch.name);
	n = append(buf, n, "-");
	n = append(buf, n, self.os.tag.name);
	n = append(buf, n, "-");
	n = append(buf, n, self.abi.name);
	return (String)buf[:n];
}
