// Tests for plan 14.1 `sysdefs-a` (src/c3/predefined_macros_x86.c3):
// write_target_os_macros, write_windows_os_defines, write_darwin_os_defines
// and write_x86_defines.
//
// PROVENANCE
// - TARGET_OS_* vectors: test/cases/target_macros *.c (each fixture's
//   `#if NAME != V` lines and its `-target` triple), fixture-derived.
// - Every other expected text: source-derived by hand from
//   src/aro/Compilation.zig generateSystemDefines (no Zig executable was
//   run). CPU feature sets come from target_cpu.c3's model table, which is
//   itself source-derived (see its header); the tests that depend on a
//   model say which features they expect it to carry.
module predefined_macros_x86_tests;
import aro::predefined_macros, aro::compilation, aro::target, aro::lang_opts, aro::code_gen_options;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const String[*] TARGET_OS_NAMES = {
	"TARGET_OS_WIN32", "TARGET_OS_WINDOWS", "TARGET_OS_LINUX", "TARGET_OS_UNIX",
	"TARGET_OS_MAC", "TARGET_OS_OSX", "TARGET_OS_IPHONE", "TARGET_OS_IOS",
	"TARGET_OS_TV", "TARGET_OS_WATCH", "TARGET_OS_VISION", "TARGET_OS_DRIVERKIT",
	"TARGET_OS_MACCATALYST", "TARGET_OS_SIMULATOR", "TARGET_OS_EMBEDDED",
	"TARGET_OS_NANO", "TARGET_IPHONE_SIMULATOR", "TARGET_OS_UIKITFORMAC",
	"TARGET_OS_UEFI",
};

<* One test/cases/target_macros fixture: triple and the 19 values in TARGET_OS_NAMES order. *>
struct OsMacroCase
{
	String triple;
	String values;
}

const OsMacroCase[*] OS_MACRO_CASES = {
	{ "aarch64-driverkit",     "0000100000010000000" }, // target_macros driverkit.c
	{ "aarch64-ios",           "0000101100000010000" }, // target_macros ios.c / iphone.c
	{ "x86_64-linux",          "0010000000000000000" }, // target_macros linux.c
	{ "aarch64-maccatalyst",   "0000100000001000010" }, // target_macros maccatalyst.c
	{ "aarch64-macos",         "0000110000000000000" }, // target_macros macos.c
	{ "aarch64-ios-simulator", "0000101100000100100" }, // target_macros simulator.c
	{ "aarch64-tvos",          "0000101010000010000" }, // target_macros tvos.c
	{ "x86_64-uefi",           "0000000000000000001" }, // target_macros uefi.c
	{ "x86_64-freebsd",        "0001000000000000000" }, // target_macros unix.c
	{ "aarch64-visionos",      "0000100000100010000" }, // target_macros visionos.c
	{ "aarch64-watchos",       "0000101001000011000" }, // target_macros watchos.c
	{ "x86_64-windows",        "1100000000000000000" }, // target_macros windows.c
};

fn void set_target(Compilation* comp, String triple, String cpu = "")
{
	comp.target = target::from_triple(triple, cpu: cpu)!!;
}

// The fixed x86 tail every x86/x86_64 target writes after the arch macros.
const String SEG = "#define __SEG_GS 1\n#define __SEG_FS 1\n"
	"#define __seg_gs __attribute__((address_space(256)))\n"
	"#define __seg_fs __attribute__((address_space(257)))\n";

module predefined_macros_x86_tests @test;
import aro::predefined_macros, aro::compilation, aro::target, aro::lang_opts, aro::code_gen_options;
import std::core::mem::allocators;

fn void target_os_macros_match_fixtures()
{
	foreach (c : OS_MACRO_CASES)
	{
		Compilation comp;
		comp.init(mem);
		defer comp.free();
		set_target(&comp, c.triple);
		MacroWriter w;
		w.init(mem);
		defer w.free();
		predefined_macros::write_target_os_macros(&comp, &w);

		DString exp;
		exp.init(mem);
		defer exp.free();
		foreach (i, name : TARGET_OS_NAMES) exp.appendf("#define %s %c\n", name, c.values[i]);
		test::eq(w.written(), exp.str_view());
	}
}

fn void target_os_unix_bsds_and_illumos()
{
	// Source-derived: TARGET_OS_UNIX is freebsd/openbsd/netbsd/illumos only.
	String[*] yes = { "x86_64-openbsd", "x86_64-netbsd", "x86_64-illumos" };
	foreach (triple : yes)
	{
		Compilation comp;
		comp.init(mem);
		defer comp.free();
		set_target(&comp, triple);
		MacroWriter w;
		w.init(mem);
		defer w.free();
		predefined_macros::write_target_os_macros(&comp, &w);
		test::eq(w.written().contains("#define TARGET_OS_UNIX 1\n"), true);
	}
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-dragonfly");
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_target_os_macros(&comp, &w);
	test::eq(w.written().contains("#define TARGET_OS_UNIX 0\n"), true);
}

fn void windows_msvc()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-windows-msvc");
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_windows_os_defines(&comp, &w, false);
	test::eq(w.written(), "#define _WIN32 1\n#define _WIN64 1\n");

	MacroWriter w32;
	w32.init(mem);
	defer w32.free();
	set_target(&comp, "x86-windows-msvc");
	predefined_macros::write_windows_os_defines(&comp, &w32, true);
	test::eq(w32.written(), "#define _WIN32 1\n");
}

fn void windows_mingw64()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-windows-gnu");
	comp.langopts.declspec_attrs = false;
	comp.langopts.ms_extensions = false;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_windows_os_defines(&comp, &w, false);
	test::eq(w.written(),
		"#define _WIN32 1\n#define _WIN64 1\n"
		"#define __WIN32 1\n#define __WIN32__ 1\n"
		"#define __WINNT 1\n#define __WINNT__ 1\n"
		"#define __WIN64 1\n#define __WIN64__ 1\n"
		"#define __MINGW64__ 1\n#define __MSVCRT__ 1\n#define __MINGW32__ 1\n"
		"#define __declspec(a) __attribute__((a))\n"
		"#define _cdecl __attribute__((__cdecl__))\n#define __cdecl __attribute__((__cdecl__))\n"
		"#define _stdcall __attribute__((__stdcall__))\n#define __stdcall __attribute__((__stdcall__))\n"
		"#define _fastcall __attribute__((__fastcall__))\n#define __fastcall __attribute__((__fastcall__))\n"
		"#define _thiscall __attribute__((__thiscall__))\n#define __thiscall __attribute__((__thiscall__))\n");
}

fn void windows_mingw32_gnu_mode_and_ms_extensions()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86-windows-gnu");
	comp.langopts.set_ms_extensions(true); // sets declspec_attrs and ms_extensions
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_windows_os_defines(&comp, &w, true);
	test::eq(w.written(),
		"#define _WIN32 1\n"
		"#define WIN32 1\n#define __WIN32 1\n#define __WIN32__ 1\n"
		"#define WINNT 1\n#define __WINNT 1\n#define __WINNT__ 1\n"
		"#define _X86_ 1\n#define __MSVCRT__ 1\n#define __MINGW32__ 1\n"
		"#define __declspec __declspec\n");
}

fn void windows_declspec_without_ms_extensions()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-windows-gnu");
	comp.langopts.declspec_attrs = true;
	comp.langopts.ms_extensions = false;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_windows_os_defines(&comp, &w, false);
	String s = w.written();
	test::eq(s.contains("#define __declspec __declspec\n#define _cdecl __attribute__((__cdecl__))\n"), true);
}

fn void darwin_versions()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();

	// macOS before 10.10: one digit each for minor/patch (clamped to 9).
	set_target(&comp, "x86_64-macos");
	comp.target.os.min = { 10, 9, 5 };
	MacroWriter w;
	w.init(mem);
	predefined_macros::write_darwin_os_defines(&comp, &w);
	test::eq(w.written(),
		"#define __APPLE__ 1\n#define __APPLE_CC__ 6000\n"
		"#define __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ 1095\n"
		"#define __ENVIRONMENT_OS_VERSION_MIN_REQUIRED__ 1095\n");
	w.free();

	comp.target.os.min = { 10, 4, 11 };
	w.init(mem);
	predefined_macros::write_darwin_os_defines(&comp, &w);
	test::eq(w.written().contains("__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ 1049\n"), true);
	w.free();

	// macOS 10.10 and later: two zero-padded digits each, clamped to 99.
	comp.target.os.min = { 10, 13, 6 };
	w.init(mem);
	predefined_macros::write_darwin_os_defines(&comp, &w);
	test::eq(w.written().contains("__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ 101306\n"), true);
	w.free();

	comp.target.os.min = { 13, 0, 0 };
	w.init(mem);
	predefined_macros::write_darwin_os_defines(&comp, &w);
	test::eq(w.written().contains("__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__ 130000\n"), true);
	w.free();

	comp.target.os.min = { 9, 150, 100 };
	w.init(mem);
	set_target(&comp, "aarch64-ios");
	comp.target.os.min = { 9, 150, 100 };
	predefined_macros::write_darwin_os_defines(&comp, &w);
	test::eq(w.written(),
		"#define __APPLE__ 1\n#define __APPLE_CC__ 6000\n"
		"#define __ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__ 099999\n"
		"#define __ENVIRONMENT_OS_VERSION_MIN_REQUIRED__ 099999\n");
	w.free();
}

fn void darwin_platform_defines()
{
	// Source-derived: os -> platform define (ios and maccatalyst share IPHONE_OS; visionos has none).
	String[*] triples = { "aarch64-tvos", "aarch64-maccatalyst", "aarch64-watchos", "aarch64-driverkit", "aarch64-macos", "aarch64-visionos" };
	String[*] defines = {
		"__ENVIRONMENT_TV_OS_VERSION_MIN_REQUIRED__",
		"__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__",
		"__ENVIRONMENT_WATCH_OS_VERSION_MIN_REQUIRED__",
		"__ENVIRONMENT_DRIVERKIT_VERSION_MIN_REQUIRED__",
		"__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__",
		"",
	};
	foreach (i, triple : triples)
	{
		Compilation comp;
		comp.init(mem);
		defer comp.free();
		set_target(&comp, triple);
		comp.target.os.min = { 17, 2, 1 };
		MacroWriter w;
		w.init(mem);
		defer w.free();
		predefined_macros::write_darwin_os_defines(&comp, &w);
		String head = "#define __APPLE__ 1\n#define __APPLE_CC__ 6000\n";
		String tail = "#define __ENVIRONMENT_OS_VERSION_MIN_REQUIRED__ 170201\n";
		String exp = defines[i].len ? string::tformat("%s#define %s 170201\n%s", head, defines[i], tail) : string::tformat("%s%s", head, tail);
		test::eq(w.written(), exp);
	}
}

fn void x86_64_linux_baseline()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	// target_cpu.c3 model x86_64: 64bit cmov cx8 fxsr mmx nopl sse2 x87 (+ sse via deps).
	set_target(&comp, "x86_64-linux-gnu", "x86_64");
	comp.langopts.emulate = CLANG;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_x86_defines(&comp, &w, false);
	String exp = string::tformat("%s%s%s",
		"#define __code_model_small__ 1\n"
		"#define __amd64__ 1\n#define __amd64 1\n#define __x86_64__ 1\n#define __x86_64 1\n",
		SEG,
		"#define __FXSR__ 1\n#define __SSE2__ 1\n#define __SSE__ 1\n#define __SSE_MATH__ 1\n#define __MMX__ 1\n"
		"#define __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 1\n"
		"#define __SIZEOF_FLOAT128__ 16\n");
	test::eq(w.written(), exp);
}

fn void x86_64_v3_feature_order()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-linux-gnu", "x86_64_v3");
	comp.cmodel = KERNEL;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_x86_defines(&comp, &w, true);
	// Features walked in Zig table order; cx8 and cx16 both give _SWAP_8 (sic).
	String exp = string::tformat("%s%s%s",
		"#define __code_model_kernel__ 1\n"
		"#define __amd64__ 1\n#define __amd64 1\n#define __x86_64__ 1\n#define __x86_64 1\n",
		SEG,
		"#define __LAHF_SAHF__ 1\n"
		"#define __LZCNT__ 1\n#define __BMI__ 1\n#define __BMI2__ 1\n#define __POPCNT__ 1\n#define __MOVBE__ 1\n"
		"#define __FMA__ 1\n#define __F16C__ 1\n"
		"#define __FXSR__ 1\n#define __XSAVE__ 1\n#define __CRC32__ 1\n"
		"#define __AVX2__ 1\n#define __AVX__ 1\n#define __SSE4_2__ 1\n#define __SSE4_1__ 1\n#define __SSSE3__ 1\n"
		"#define __SSE3__ 1\n#define __SSE2__ 1\n#define __SSE__ 1\n#define __SSE_MATH__ 1\n#define __MMX__ 1\n"
		"#define __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 1\n#define __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 1\n"
		"#define __SIZEOF_FLOAT128__ 16\n");
	test::eq(w.written(), exp);
}

fn void x86_windows_msvc_m_ix86()
{
	// _M_IX86 by cpu model; _M_IX86_FP by sse2/sse with ms_extensions.
	String[*] cpus = { "i386", "i486", "i586", "i686", "pentium4" };
	String[*] ix86 = { "300", "400", "500", "600", "600" };
	String[*] fp = { "0", "0", "0", "0", "2" };
	foreach (i, cpu : cpus)
	{
		Compilation comp;
		comp.init(mem);
		defer comp.free();
		set_target(&comp, "x86-windows-msvc", cpu);
		comp.langopts.ms_extensions = true;
		comp.langopts.emulate = MSVC;
		MacroWriter w;
		w.init(mem);
		defer w.free();
		predefined_macros::write_x86_defines(&comp, &w, false);
		String s = w.written();
		String head = string::tformat("#define __code_model_small__ 1\n#define __i386 1\n#define __i386__ 1\n#define _M_IX86 %s\n%s", ix86[i], SEG);
		test::eq(s.starts_with(head), true);
		test::eq(s.contains(string::tformat("#define _M_IX86_FP %s\n", fp[i])), true);
		test::eq(s.contains("__LAHF_SAHF__"), false);
		test::eq(s.contains("__SIZEOF_FLOAT128__"), false); // windows: no float128
	}

	// +sse without sse2 -> 1.
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86-windows-msvc", "i686+sse");
	comp.langopts.ms_extensions = true;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_x86_defines(&comp, &w, false);
	test::eq(w.written().contains("#define _M_IX86_FP 1\n"), true);
}

fn void x86_linux_gnu_mode()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86-linux-gnu", "i386");
	comp.langopts.emulate = CLANG;
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_x86_defines(&comp, &w, true);
	// i386 model: x87 only. No _M_IX86 (not msvc), no _M_IX86_FP (no ms_extensions),
	// __LAHF_SAHF__ because emulate == clang on x86, no cx8.
	String exp = string::tformat("%s%s%s",
		"#define __code_model_small__ 1\n#define i386 1\n#define __i386 1\n#define __i386__ 1\n",
		SEG,
		"#define __LAHF_SAHF__ 1\n#define __SIZEOF_FLOAT128__ 16\n");
	test::eq(w.written(), exp);
}

fn void x86_64_msvc_and_apx()
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	set_target(&comp, "x86_64-windows-msvc", "x86_64+egpr+push2pop2+ppx+ndd+ccmp+nf+cf+zu+avx10_1+avx512vl");
	MacroWriter w;
	w.init(mem);
	defer w.free();
	predefined_macros::write_x86_defines(&comp, &w, false);
	String s = w.written();
	test::eq(s.starts_with("#define __code_model_small__ 1\n#define __amd64__ 1\n#define __amd64 1\n"
		"#define __x86_64__ 1\n#define __x86_64 1\n#define _M_X64 100\n#define _M_AMD64 100\n"), true);
	test::eq(s.contains("#define __AVX10_1__ 1\n#define __AVX10_1_512__ 1\n"), true);
	test::eq(s.contains("#define __AVX512VL__ 1\n#define __EVEX256__ 1\n"), true);
	test::eq(s.contains("#define __EGPR__ 1\n#define __PUSH2POP2__ 1\n#define __PPX__ 1\n#define __NDD__ 1\n"
		"#define __CCMP__ 1\n#define __NF__ 1\n#define __CF__ 1\n#define __ZU__ 1\n"), true);
	test::eq(s.contains("#define __MMX__ 1\n#define __APX_F__ 1\n#define __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 1\n"), true);
	test::eq(s.contains("_M_IX86_FP"), false);

	// One APX feature missing -> no __APX_F__.
	set_target(&comp, "x86_64-windows-msvc", "x86_64+egpr+push2pop2+ppx+ndd+ccmp+nf+cf");
	MacroWriter w2;
	w2.init(mem);
	defer w2.free();
	predefined_macros::write_x86_defines(&comp, &w2, false);
	test::eq(w2.written().contains("__APX_F__"), false);
}

fn void feature_table_shape()
{
	// 113 rows extracted from Compilation.zig; first/last rows and the duplicates.
	check(predefined_macros::X86_FEATURE_MACROS.len, 113);
	test::eq(predefined_macros::X86_FEATURE_MACROS[0].macro_name, "__AES__");
	test::eq(predefined_macros::X86_FEATURE_MACROS[112].macro_name, "__MMX__");
	foreach (fm : predefined_macros::X86_FEATURE_MACROS) test::eq(fm.feature.family, FeatureFamily.X86);
}

fn void no_leaks()
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		set_target(&comp, "x86_64-windows-gnu");
		MacroWriter w;
		w.init(&ta);
		predefined_macros::write_target_os_macros(&comp, &w);
		predefined_macros::write_windows_os_defines(&comp, &w, true);
		predefined_macros::write_x86_defines(&comp, &w, true);
		set_target(&comp, "x86_64-macos");
		predefined_macros::write_darwin_os_defines(&comp, &w);
		w.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}
