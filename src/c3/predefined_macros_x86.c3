// generateSystemDefines sections for x86/x86_64, Windows (MSVC/MinGW) and
// Darwin, from src/aro/Compilation.zig (plan 14).
// OWNER: plan 14.1 `sysdefs-a`. Called from generate_system_defines
// (predefined_macros.c3) in the documented order.
//
// CPU feature data: every feature the Zig x86 table names exists in
// target::Feature (X86_<ZIG_NAME_UPPER>, plan 14 stage 0); the table itself
// (feature -> macro name, Zig order) belongs in this file. Feature
// dependencies for the newer features and LLVM CPU models beyond the ones in
// target_cpu.c3 are not ported (see target_cpu.c3 header); report needed
// rows to the integrator instead of editing target_cpu.c3.
//
// Stage 0: signatures only; every body is a stub.
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}
