// generateSystemDefines sections for x86/x86_64, Windows (MSVC/MinGW) and
// Darwin, from src/aro/Compilation.zig (plan 14).
// OWNER: plan 14.1 `sysdefs-a`. Called from generate_system_defines
// (predefined_macros.c3) in the documented order.
//
// CPU feature data: every feature the Zig x86 table names exists in
// target::Feature (X86_<ZIG_NAME_UPPER>, plan 14 stage 0); the table itself
// (X86_FEATURE_MACROS, feature -> macro name, Zig order) is in this file.
// Feature dependencies for the newer features and LLVM CPU models beyond the
// ones in target_cpu.c3 are not ported (see target_cpu.c3 header), so a
// -mcpu=<model> or +feature only enables what target_cpu.c3 knows; the macro
// writer itself just reads cpu.features.
//
// PROVENANCE: transcribed from Compilation.zig generateSystemDefines (the
// TARGET_OS_* block, the .windows and Darwin os arms, the .x86/.x86_64 arch
// arm). The feature table is extracted mechanically from that source (113
// rows, duplicates kept). No Zig executable was run.
module aro::predefined_macros;
import aro::compilation, aro::target, aro::lang_opts, aro::code_gen_options;

<*
 Target OS macros, transcribed from LLVM TargetOSMacros.def (only called
 when langopts.has_target_os_macros()). define_bool in Zig order:
 TARGET_OS_WIN32 / TARGET_OS_WINDOWS (windows), TARGET_OS_LINUX (linux),
 TARGET_OS_UNIX (freebsd/openbsd/netbsd/illumos), TARGET_OS_MAC (Darwin),
 TARGET_OS_OSX (macos), TARGET_OS_IPHONE (ios/tvos/watchos), TARGET_OS_IOS,
 TARGET_OS_TV, TARGET_OS_WATCH, TARGET_OS_VISION, TARGET_OS_DRIVERKIT,
 TARGET_OS_MACCATALYST, TARGET_OS_SIMULATOR (abi == SIMULATOR),
 TARGET_OS_EMBEDDED (ios/tvos/visionos/watchos and abi != SIMULATOR),
 TARGET_OS_NANO (watchos), TARGET_IPHONE_SIMULATOR (abi == SIMULATOR),
 TARGET_OS_UIKITFORMAC (maccatalyst), TARGET_OS_UEFI (uefi).
 OWNER: 14.1.
*>
fn void write_target_os_macros(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	OsTag os = t.os.tag;
	// Windows
	w.define_bool("TARGET_OS_WIN32", os == WINDOWS);
	w.define_bool("TARGET_OS_WINDOWS", os == WINDOWS);
	// Linux
	w.define_bool("TARGET_OS_LINUX", os == LINUX);
	// Unix
	w.define_bool("TARGET_OS_UNIX", os == FREEBSD || os == OPENBSD || os == NETBSD || os == ILLUMOS);
	// Apple Targets
	w.define_bool("TARGET_OS_MAC", os.is_darwin());
	w.define_bool("TARGET_OS_OSX", os == MACOS);
	w.define_bool("TARGET_OS_IPHONE", os == IOS || os == TVOS || os == WATCHOS);
	w.define_bool("TARGET_OS_IOS", os == IOS);
	w.define_bool("TARGET_OS_TV", os == TVOS);
	w.define_bool("TARGET_OS_WATCH", os == WATCHOS);
	w.define_bool("TARGET_OS_VISION", os == VISIONOS);
	w.define_bool("TARGET_OS_DRIVERKIT", os == DRIVERKIT);
	w.define_bool("TARGET_OS_MACCATALYST", os == MACCATALYST);
	w.define_bool("TARGET_OS_SIMULATOR", t.abi == SIMULATOR);
	bool embedded_os = os == IOS || os == TVOS || os == VISIONOS || os == WATCHOS;
	w.define_bool("TARGET_OS_EMBEDDED", embedded_os && t.abi != SIMULATOR);
	w.define_bool("TARGET_OS_NANO", os == WATCHOS);
	w.define_bool("TARGET_IPHONE_SIMULATOR", t.abi == SIMULATOR);
	w.define_bool("TARGET_OS_UIKITFORMAC", os == MACCATALYST);
	// UEFI
	w.define_bool("TARGET_OS_UEFI", os == UEFI);
}

<*
 The `.windows` OS arm: _WIN32; _WIN64 if ptr width 64. abi.is_gnu(): WIN32,
 WINNT (define_std), then 64-bit: WIN64 (define_std) + __MINGW64__, else
 _X86_; __MSVCRT__, __MINGW32__; then `__declspec` ("#define __declspec
 __declspec" if langopts.declspec_attrs else "#define __declspec(a)
 __attribute__((a))") and, without ms_extensions, _cdecl/__cdecl,
 _stdcall/__stdcall, _fastcall/__fastcall, _thiscall/__thiscall as
 `__attribute__((__<kw>__))`.
 OWNER: 14.1.
*>
fn void write_windows_os_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	ushort ptr_width = t.ptr_bit_width();
	w.define("_WIN32");
	if (ptr_width == 64) w.define("_WIN64");

	if (t.abi.is_gnu())
	{
		w.define_std("WIN32", is_gnu);
		w.define_std("WINNT", is_gnu);
		if (ptr_width == 64)
		{
			w.define_std("WIN64", is_gnu);
			w.define("__MINGW64__");
		}
		else
		{
			w.define("_X86_");
		}
		w.define("__MSVCRT__");
		w.define("__MINGW32__");
	}

	if (t.abi.is_gnu())
	{
		// MinGW and Cygwin define __declspec(a) to __attribute((a)).
		// Like Clang we make the define no op if -fdeclspec is enabled.
		if (comp.langopts.declspec_attrs)
		{
			w.write("#define __declspec __declspec\n");
		}
		else
		{
			w.write("#define __declspec(a) __attribute__((a))\n");
		}
		if (!comp.langopts.ms_extensions)
		{
			// Provide aliases for the calling convention keywords.
			foreach (keyword : CALLING_CONVENTION_KEYWORDS)
			{
				w.printf("#define _%s __attribute__((__%s__))\n", keyword, keyword);
				w.printf("#define __%s __attribute__((__%s__))\n", keyword, keyword);
			}
		}
	}
}

<*
 The Darwin OS arm (maccatalyst/macos/tvos/ios/driverkit/visionos/watchos):
 __APPLE__, "__APPLE_CC__ 6000", the platform min-version define
 (__ENVIRONMENT_{TV_OS,IPHONE_OS,WATCH_OS,DRIVERKIT,MAC_OS_X}_VERSION_MIN_REQUIRED__;
 none for visionos; ios and maccatalyst share IPHONE_OS) and
 __ENVIRONMENT_OS_VERSION_MIN_REQUIRED__, both with the version string of
 os.version_range min: macos < 10.10 -> "{major}{min(minor,9)}{min(patch,9)}",
 else "{major:0>2}{min(minor,99):0>2}{min(patch,99):0>2}".
 OWNER: 14.1.
*>
fn void write_darwin_os_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	w.define("__APPLE__");
	w.write("#define __APPLE_CC__ 6000\n");

	SemVer version = t.os.min;
	ulong minor;
	ulong patch;
	bool short_form = t.os.tag == MACOS && version.order({ 10, 10, 0 }) < 0;
	if (short_form)
	{
		minor = min(version.minor, 9UL);
		patch = min(version.patch, 9UL);
	}
	else
	{
		minor = min(version.minor, 99UL);
		patch = min(version.patch, 99UL);
	}

	String platform_define;
	switch (t.os.tag)
	{
		case TVOS: platform_define = "__ENVIRONMENT_TV_OS_VERSION_MIN_REQUIRED__";
		case IOS:
		case MACCATALYST: platform_define = "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__";
		case WATCHOS: platform_define = "__ENVIRONMENT_WATCH_OS_VERSION_MIN_REQUIRED__";
		case DRIVERKIT: platform_define = "__ENVIRONMENT_DRIVERKIT_VERSION_MIN_REQUIRED__";
		case MACOS: platform_define = "__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__";
		case VISIONOS: platform_define = ""; // No platform-specific OS version define for visionOS
		default: unreachable("write_darwin_os_defines on a non-Darwin OS");
	}

	// Zig formats into an [8]u8 buffer: "{d}{d}{d}" or "{d:0>2}{d:0>2}{d:0>2}".
	for (int pass = 0; pass < 2; pass++)
	{
		String name = pass == 0 ? platform_define : "__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__";
		if (!name.len) continue;
		if (short_form)
		{
			w.printf("#define %s %d%d%d\n", name, version.major, minor, patch);
		}
		else
		{
			w.printf("#define %s %02d%02d%02d\n", name, version.major, minor, patch);
		}
	}
}

<*
 The `.x86, .x86_64` arch arm: __code_model_<cmodel.macro_name()>__ 1;
 x86_64: __amd64__, __amd64, __x86_64__, __x86_64 (+ _M_X64 100, _M_AMD64 100
 for windows-msvc); x86: i386 (define_std) (+ _M_IX86 300/400/500/600 by
 cpu.model I386/I486/I586/other for windows-msvc); __SEG_GS, __SEG_FS,
 __seg_gs/__seg_fs address_space defines; __LAHF_SAHF__ (sahf, or emulate
 CLANG on x86); the feature table in Zig order (incl. duplicates such as
 AVX10_1 -> __AVX10_1__ and __AVX10_1_512__, avx512vl -> __EVEX256__,
 sse -> __SSE_MATH__); _M_IX86_FP 2/1/0 with ms_extensions on x86;
 __APX_F__ when egpr/push2pop2/ppx/ndd/ccmp/nf/cf/zu all set;
 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 for cx8 and again for cx16 on x86_64
 (sic, Zig writes _8 twice); "__SIZEOF_FLOAT128__ 16" if has_float128.
 OWNER: 14.1.
*>
fn void write_x86_defines(Compilation* comp, MacroWriter* w, bool is_gnu)
{
	Target* t = &comp.target;
	w.printf("#define __code_model_%s__ 1\n", comp.cmodel.macro_name());

	bool is_msvc_windows = t.os.tag == WINDOWS && t.abi == MSVC;
	if (t.cpu.arch == X86_64)
	{
		w.define("__amd64__");
		w.define("__amd64");
		w.define("__x86_64__");
		w.define("__x86_64");

		if (is_msvc_windows) w.write("#define _M_X64 100\n#define _M_AMD64 100\n");
	}
	else
	{
		w.define_std("i386", is_gnu);

		if (is_msvc_windows)
		{
			int level;
			switch (t.cpu.model)
			{
				case I386: level = 300;
				case I486: level = 400;
				case I586: level = 500;
				default: level = 600;
			}
			w.define_int("_M_IX86", level);
		}
	}
	w.define("__SEG_GS");
	w.define("__SEG_FS");
	w.write("#define __seg_gs __attribute__((address_space(256)))\n#define __seg_fs __attribute__((address_space(257)))\n");

	if (t.cpu.has(X86_SAHF) || (comp.langopts.emulate == CLANG && t.cpu.arch == X86))
	{
		w.define("__LAHF_SAHF__");
	}

	foreach (fm : X86_FEATURE_MACROS)
	{
		if (t.cpu.has(fm.feature)) w.define(fm.macro_name);
	}

	if (comp.langopts.ms_extensions && t.cpu.arch == X86)
	{
		String level = "0";
		if (t.cpu.has(X86_SSE2))
		{
			level = "2";
		}
		else if (t.cpu.has(X86_SSE))
		{
			level = "1";
		}
		w.define_value("_M_IX86_FP", level);
	}

	if (t.cpu.has_all(&APX_F_FEATURES)) w.define("__APX_F__");

	// Zig keeps __APX_INLINE_ASM_USE_GPR32__ (egpr + inline_asm_use_gpr32) commented out.

	if (t.cpu.has(X86_CX8)) w.define("__GCC_HAVE_SYNC_COMPARE_AND_SWAP_8");
	// sic: Zig defines _8 (not _16) again for cx16.
	if (t.cpu.has(X86_CX16) && t.cpu.arch == X86_64) w.define("__GCC_HAVE_SYNC_COMPARE_AND_SWAP_8");

	if (t.has_float128()) w.write("#define __SIZEOF_FLOAT128__ 16\n");
}

// ---------------------------------------------------------------------------
// Data

const String[*] CALLING_CONVENTION_KEYWORDS = { "cdecl", "stdcall", "fastcall", "thiscall" };

const Feature[*] APX_F_FEATURES = { X86_EGPR, X86_PUSH2POP2, X86_PPX, X86_NDD, X86_CCMP, X86_NF, X86_CF, X86_ZU };

<* One row of generateSystemDefines' x86 feature -> macro table. *>
struct X86FeatureMacro
{
	Feature feature;
	String macro_name;
}

<* Zig order, duplicates kept (avx10_1, avx10_2, avx512vl and sse map to two macros each). *>
const X86FeatureMacro[*] X86_FEATURE_MACROS = {
	{ X86_AES, "__AES__" },
	{ X86_VAES, "__VAES__" },
	{ X86_PCLMUL, "__PCLMUL__" },
	{ X86_VPCLMULQDQ, "__VPCLMULQDQ__" },
	{ X86_LZCNT, "__LZCNT__" },
	{ X86_RDRND, "__RDRND__" },
	{ X86_FSGSBASE, "__FSGSBASE__" },
	{ X86_BMI, "__BMI__" },
	{ X86_BMI2, "__BMI2__" },
	{ X86_POPCNT, "__POPCNT__" },
	{ X86_RTM, "__RTM__" },
	{ X86_PRFCHW, "__PRFCHW__" },
	{ X86_RDSEED, "__RDSEED__" },
	{ X86_ADX, "__ADX__" },
	{ X86_TBM, "__TBM__" },
	{ X86_LWP, "__LWP__" },
	{ X86_MWAITX, "__MWAITX__" },
	{ X86_MOVBE, "__MOVBE__" },
	{ X86_XOP, "__XOP__" },
	{ X86_FMA4, "__FMA4__" },
	{ X86_SSE4A, "__SSE4A__" },
	{ X86_FMA, "__FMA__" },
	{ X86_F16C, "__F16C__" },
	{ X86_GFNI, "__GFNI__" },
	{ X86_AVX10_1, "__AVX10_1__" },
	{ X86_AVX10_1, "__AVX10_1_512__" },
	{ X86_AVX10_2, "__AVX10_2__" },
	{ X86_AVX10_2, "__AVX10_2_512__" },
	{ X86_AVX512CD, "__AVX512CD__" },
	{ X86_AVX512VPOPCNTDQ, "__AVX512VPOPCNTDQ__" },
	{ X86_AVX512VNNI, "__AVX512VNNI__" },
	{ X86_AVX512BF16, "__AVX512BF16__" },
	{ X86_AVX512FP16, "__AVX512FP16__" },
	{ X86_AVX512DQ, "__AVX512DQ__" },
	{ X86_AVX512BITALG, "__AVX512BITALG__" },
	{ X86_AVX512BMM, "__AVX512BMM__" },
	{ X86_AVX512BW, "__AVX512BW__" },
	{ X86_AVX512VL, "__AVX512VL__" },
	{ X86_AVX512VL, "__EVEX256__" },
	{ X86_AVX512VBMI, "__AVX512VBMI__" },
	{ X86_AVX512VBMI2, "__AVX512VBMI2__" },
	{ X86_AVX512IFMA, "__AVX512IFMA__" },
	{ X86_AVX512VP2INTERSECT, "__AVX512VP2INTERSECT__" },
	{ X86_SHA, "__SHA__" },
	{ X86_SHA512, "__SHA512__" },
	{ X86_FXSR, "__FXSR__" },
	{ X86_XSAVE, "__XSAVE__" },
	{ X86_XSAVEOPT, "__XSAVEOPT__" },
	{ X86_XSAVEC, "__XSAVEC__" },
	{ X86_XSAVES, "__XSAVES__" },
	{ X86_PKU, "__PKU__" },
	{ X86_CLFLUSHOPT, "__CLFLUSHOPT__" },
	{ X86_CLWB, "__CLWB__" },
	{ X86_WBNOINVD, "__WBNOINVD__" },
	{ X86_SHSTK, "__SHSTK__" },
	{ X86_SGX, "__SGX__" },
	{ X86_SM3, "__SM3__" },
	{ X86_SM4, "__SM4__" },
	{ X86_PREFETCHI, "__PREFETCHI__" },
	{ X86_CLZERO, "__CLZERO__" },
	{ X86_KL, "__KL__" },
	{ X86_WIDEKL, "__WIDEKL__" },
	{ X86_RDPID, "__RDPID__" },
	{ X86_RDPRU, "__RDPRU__" },
	{ X86_CLDEMOTE, "__CLDEMOTE__" },
	{ X86_WAITPKG, "__WAITPKG__" },
	{ X86_MOVDIRI, "__MOVDIRI__" },
	{ X86_MOVDIR64B, "__MOVDIR64B__" },
	{ X86_MOVRS, "__MOVRS__" },
	{ X86_PCONFIG, "__PCONFIG__" },
	{ X86_PTWRITE, "__PTWRITE__" },
	{ X86_INVPCID, "__INVPCID__" },
	{ X86_ENQCMD, "__ENQCMD__" },
	{ X86_HRESET, "__HRESET__" },
	{ X86_AMX_TILE, "__AMX_TILE__" },
	{ X86_AMX_INT8, "__AMX_INT8__" },
	{ X86_AMX_BF16, "__AMX_BF16__" },
	{ X86_AMX_FP16, "__AMX_FP16__" },
	{ X86_AMX_COMPLEX, "__AMX_COMPLEX__" },
	{ X86_AMX_FP8, "__AMX_FP8__" },
	{ X86_AMX_MOVRS, "__AMX_MOVRS__" },
	{ X86_AMX_AVX512, "__AMX_AVX512__" },
	{ X86_CMPCCXADD, "__CMPCCXADD__" },
	{ X86_RAOINT, "__RAOINT__" },
	{ X86_AVXIFMA, "__AVXIFMA__" },
	{ X86_AVXNECONVERT, "__AVXNECONVERT__" },
	{ X86_AVXVNNI, "__AVXVNNI__" },
	{ X86_AVXVNNIINT16, "__AVXVNNIINT16__" },
	{ X86_AVXVNNIINT8, "__AVXVNNIINT8__" },
	{ X86_SERIALIZE, "__SERIALIZE__" },
	{ X86_TSXLDTRK, "__TSXLDTRK__" },
	{ X86_UINTR, "__UINTR__" },
	{ X86_USERMSR, "__USERMSR__" },
	{ X86_CRC32, "__CRC32__" },
	{ X86_EGPR, "__EGPR__" },
	{ X86_PUSH2POP2, "__PUSH2POP2__" },
	{ X86_PPX, "__PPX__" },
	{ X86_NDD, "__NDD__" },
	{ X86_CCMP, "__CCMP__" },
	{ X86_NF, "__NF__" },
	{ X86_CF, "__CF__" },
	{ X86_ZU, "__ZU__" },
	{ X86_AVX512F, "__AVX512F__" },
	{ X86_AVX2, "__AVX2__" },
	{ X86_AVX, "__AVX__" },
	{ X86_SSE4_2, "__SSE4_2__" },
	{ X86_SSE4_1, "__SSE4_1__" },
	{ X86_SSSE3, "__SSSE3__" },
	{ X86_SSE3, "__SSE3__" },
	{ X86_SSE2, "__SSE2__" },
	{ X86_SSE, "__SSE__" },
	{ X86_SSE, "__SSE_MATH__" },
	{ X86_MMX, "__MMX__" },
};
