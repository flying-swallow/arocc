// Tests for plan 14 agent 14.3 (`builtin-macros`): write_builtin_macros,
// write_compiler_defines, write_common_defines and the int/float/type limit
// helpers in src/c3/predefined_macros.c3.
//
// Provenance of expected values:
// - [fixture] test/cases files named at each check (their _Static_asserts /
//   EXPECT_TYPEs pin the macro value or the type it names).
// - [source] hand-derived from src/aro/Compilation.zig (writeBuiltinMacros,
//   generateSystemDefines tail, generateFloatMacros tables,
//   generateIntMax/Min/Width, generateExactWidthType(s),
//   generateFastOrLeastType) together with TypeStore.zig / Target.zig.
// No Zig executable was run; nothing here claims executable parity.
//
// Sections owned by 14.1/14.2 are still stage-0 stubs, so whole
// INCLUDE_SYSTEM_DEFINES inventories are not tested here; every 14.3 section
// is tested on its own.
module predefined_macros_tests;
import aro, aro::predefined_macros, aro::compilation, aro::target, aro::type_store, aro::lang_opts, aro::code_gen_options;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

fn Target tgt(String triple)
{
	Target? t = target::parse_triple(triple, HOST);
	if (catch f = t)
	{
		io::eprintfn("failed to parse target '%s': %s", triple, f);
		unreachable("target parse failed");
	}
	return t;
}

<* Run the body with a compilation (named types initialized) and a MacroWriter for `triple`; checks nothing leaks. *>
macro @with_comp(String triple; @body(Compilation* comp, MacroWriter* w))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = tgt(triple);
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		MacroWriter w;
		w.init(&ta);
		@body(&comp, &w);
		w.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

<* True when `text` contains `line` as a whole line. *>
fn bool has_line(String text, String line)
{
	foreach (l : text.tsplit("\n"))
	{
		if (l == line) return true;
	}
	return false;
}

<* Like has_line, but reports the missing line. *>
fn void expect_line(String text, String line)
{
	if (!has_line(text, line)) io::eprintfn("missing line: %s", line);
	test::eq(has_line(text, line), true);
}

fn void expect_no_line(String text, String line)
{
	if (has_line(text, line)) io::eprintfn("unexpected line: %s", line);
	test::eq(has_line(text, line), false);
}

<* Lines of `text` that start with `prefix`. *>
fn String lines_with_prefix(String text, String prefix)
{
	DString d;
	d.init(tmem);
	foreach (l : text.tsplit("\n"))
	{
		if (l.starts_with(prefix))
		{
			d.append(l);
			d.append_char('\n');
		}
	}
	return d.str_view();
}

// ---------------------------------------------------------------------------
// write_builtin_macros (NO_SYSTEM_DEFINES never reaches 14.1/14.2 stubs)

fn void builtin_macros_default_hosted() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		// [source] writeBuiltinMacros; default standard is gnu17 -> 201710L.
		test::eq(w.written(),
			"#define __STDC__ 1\n"
			"#define __STDC_HOSTED__ 1\n"
			"#define __STDC_UTF_16__ 1\n"
			"#define __STDC_UTF_32__ 1\n"
			"#define __STDC_EMBED_NOT_FOUND__ 0\n"
			"#define __STDC_EMBED_FOUND__ 1\n"
			"#define __STDC_EMBED_EMPTY__ 2\n"
			"#define __STDC_VERSION__ 201710L\n");
	};
}

fn void builtin_macros_std_versions() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] predefined macros.c (-std=c99): __STDC_VERSION__ == 199901
		comp.langopts.set_standard("c99")!!;
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		expect_line(w.written(), "#define __STDC_VERSION__ 199901L");
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] c23 defines.c (-std=c23): __STDC_VERSION__ == 202311L
		comp.langopts.set_standard("c23")!!;
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		expect_line(w.written(), "#define __STDC_VERSION__ 202311L");
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [source] c89 has no __STDC_VERSION__ (StdCVersionMacro returns null).
		comp.langopts.set_standard("c89")!!;
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		test::eq(w.written().contains("__STDC_VERSION__"), false);
	};
}

fn void builtin_macros_emulation_and_os() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [source] no __STDC__ when emulating MSVC.
		comp.langopts.set_emulated_compiler(MSVC);
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		test::eq(w.written().contains("__STDC__ 1"), false);
		expect_line(w.written(), "#define __STDC_HOSTED__ 1");
	};
	@with_comp("x86_64-freestanding-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		expect_line(w.written(), "#define __STDC_HOSTED__ 0");
	};
	@with_comp("x86_64-macos-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		expect_line(w.written(), "#define __STDC_NO_THREADS__ 1");
		test::eq(w.written().contains("__STDC_NO_COMPLEX__"), false);
	};
	@with_comp("x86_64-macos-none"; Compilation* comp, MacroWriter* w)
	{
		// before C11 there are no thread/complex availability macros
		comp.langopts.set_standard("c99")!!;
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		test::eq(w.written().contains("__STDC_NO_THREADS__"), false);
	};
	@with_comp("x86_64-ps4-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_builtin_macros(comp, NO_SYSTEM_DEFINES, w);
		String s = lines_with_prefix(w.written(), "#define __STDC_NO_");
		test::eq(s, "#define __STDC_NO_THREADS__ 1\n#define __STDC_NO_COMPLEX__ 1\n");
	};
}

// ---------------------------------------------------------------------------
// write_compiler_defines

fn void compiler_defines_default() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] gnuc version default gcc.c / default.c (emulate no|gcc): 7.1.0
		// [source] the rest of the head of generateSystemDefines.
		predefined_macros::write_compiler_defines(comp, w);
		test::eq(w.written(),
			"#define __GNUC__ 7\n"
			"#define __GNUC_MINOR__ 1\n"
			"#define __GNUC_PATCHLEVEL__ 0\n"
			"#define __ARO_EMULATE_NO__ 0\n"
			"#define __ARO_EMULATE_CLANG__ 1\n"
			"#define __ARO_EMULATE_GCC__ 2\n"
			"#define __ARO_EMULATE_MSVC__ 3\n"
			"#define __ARO_EMULATE__ __ARO_EMULATE_NO__\n"
			"#define __building_module(x) 0\n");
	};
}

fn void compiler_defines_emulation() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] gnuc version default clang.c: 4.2.1
		comp.langopts.set_emulated_compiler(CLANG);
		predefined_macros::write_compiler_defines(comp, w);
		expect_line(w.written(), "#define __GNUC__ 4");
		expect_line(w.written(), "#define __GNUC_MINOR__ 2");
		expect_line(w.written(), "#define __GNUC_PATCHLEVEL__ 1");
		expect_line(w.written(), "#define __ARO_EMULATE__ __ARO_EMULATE_CLANG__");
	};
	@with_comp("x86_64-windows-msvc"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] gnuc version default msvc.c: no __GNUC__ macros
		comp.langopts.set_emulated_compiler(MSVC);
		predefined_macros::write_compiler_defines(comp, w);
		test::eq(w.written().contains("__GNUC"), false);
		expect_line(w.written(), "#define __ARO_EMULATE__ __ARO_EMULATE_MSVC__");
		expect_line(w.written(), "#define _MSC_VER 1933");
		expect_line(w.written(), "#define _MSC_FULL_VER 193300000");
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] gnuc version override.c (-fgnuc-version=5.3.42)
		comp.langopts.has_gnuc_version = true;
		comp.langopts.gnuc_version = 5 * 10_000 + 3 * 100 + 42;
		predefined_macros::write_compiler_defines(comp, w);
		expect_line(w.written(), "#define __GNUC__ 5");
		expect_line(w.written(), "#define __GNUC_MINOR__ 3");
		expect_line(w.written(), "#define __GNUC_PATCHLEVEL__ 42");
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [fixture] gnuc version empty.c (-fgnuc-version= -> 0): no __GNUC__ macros
		comp.langopts.has_gnuc_version = true;
		comp.langopts.gnuc_version = 0;
		predefined_macros::write_compiler_defines(comp, w);
		test::eq(w.written().contains("__GNUC"), false);
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		comp.code_gen_options.optimization_level = S;
		predefined_macros::write_compiler_defines(comp, w);
		test::eq(w.written().ends_with("#define __building_module(x) 0\n#define __OPTIMIZE__ 1\n#define __OPTIMIZE_SIZE__ 1\n"), true);
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		comp.code_gen_options.optimization_level = FAST;
		predefined_macros::write_compiler_defines(comp, w);
		expect_line(w.written(), "#define __OPTIMIZE__ 1");
		test::eq(w.written().contains("__OPTIMIZE_SIZE__"), false);
	};
}

// ---------------------------------------------------------------------------
// generate_float_macros

fn void float_macros_single() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MacroWriter w;
		w.init(&ta);
		// [source] generateFloatMacros, IEEESingle column.
		predefined_macros::generate_float_macros(&w, "FLT", IEEE_SINGLE, "F");
		test::eq(w.written(),
			"#define __FLT_DENORM_MIN__ 1.40129846e-45F\n"
			"#define __FLT_HAS_DENORM__\n"
			"#define __FLT_DIG__ 6\n"
			"#define __FLT_DECIMAL_DIG__ 9\n"
			"#define __FLT_EPSILON__ 1.19209290e-7F\n"
			"#define __FLT_HAS_INFINITY__\n"
			"#define __FLT_HAS_QUIET_NAN__\n"
			"#define __FLT_MANT_DIG__ 24\n"
			"#define __FLT_MAX_10_EXP__ 38\n"
			"#define __FLT_MAX_EXP__ 128\n"
			"#define __FLT_MAX__ 3.40282347e+38F\n"
			"#define __FLT_MIN_10_EXP__ (-37)\n"
			"#define __FLT_MIN_EXP__ (-125)\n"
			"#define __FLT_MIN__ 1.17549435e-38F\n");
		w.free();
	}
	check(ta.allocation_count(), 0);
}

fn void float_macros_all_semantics() @test
{
	@pool()
	{
		MacroWriter w;
		w.init(tmem);
		predefined_macros::generate_float_macros(&w, "FLT16", IEEE_HALF, "F16");
		String s = w.written();
		expect_line(s, "#define __FLT16_DENORM_MIN__ 5.9604644775390625e-8F16");
		expect_line(s, "#define __FLT16_MAX__ 6.5504e+4F16");
		expect_line(s, "#define __FLT16_MIN_EXP__ (-13)");
		expect_line(s, "#define __FLT16_MANT_DIG__ 11");

		w.init(tmem);
		predefined_macros::generate_float_macros(&w, "DBL", IEEE_DOUBLE, "");
		s = w.written();
		expect_line(s, "#define __DBL_DENORM_MIN__ 4.9406564584124654e-324");
		expect_line(s, "#define __DBL_EPSILON__ 2.2204460492503131e-16");
		expect_line(s, "#define __DBL_MAX__ 1.7976931348623157e+308");
		expect_line(s, "#define __DBL_MIN__ 2.2250738585072014e-308");
		expect_line(s, "#define __DBL_MIN_10_EXP__ (-307)");
		expect_line(s, "#define __DBL_DECIMAL_DIG__ 17");

		w.init(tmem);
		predefined_macros::generate_float_macros(&w, "LDBL", X87_EXTENDED_DOUBLE, "L");
		s = w.written();
		expect_line(s, "#define __LDBL_DENORM_MIN__ 3.64519953188247460253e-4951L");
		expect_line(s, "#define __LDBL_MAX__ 1.18973149535723176502e+4932L");
		expect_line(s, "#define __LDBL_MIN__ 3.36210314311209350626e-4932L");
		expect_line(s, "#define __LDBL_MANT_DIG__ 64");
		expect_line(s, "#define __LDBL_DIG__ 18");
		expect_line(s, "#define __LDBL_MIN_EXP__ (-16381)");

		w.init(tmem);
		predefined_macros::generate_float_macros(&w, "LDBL", IBM_EXTENDED_DOUBLE, "L");
		s = w.written();
		expect_line(s, "#define __LDBL_EPSILON__ 4.94065645841246544176568792868221e-324L");
		expect_line(s, "#define __LDBL_MANT_DIG__ 106");
		expect_line(s, "#define __LDBL_MIN_10_EXP__ (-291)");
		expect_line(s, "#define __LDBL_MIN_EXP__ (-968)");

		w.init(tmem);
		predefined_macros::generate_float_macros(&w, "LDBL", IEEE_QUAD, "L");
		s = w.written();
		expect_line(s, "#define __LDBL_DENORM_MIN__ 6.47517511943802511092443895822764655e-4966L");
		expect_line(s, "#define __LDBL_EPSILON__ 1.92592994438723585305597794258492732e-34L");
		expect_line(s, "#define __LDBL_MAX__ 1.18973149535723176508575932662800702e+4932L");
		expect_line(s, "#define __LDBL_DECIMAL_DIG__ 36");
		expect_line(s, "#define __LDBL_MAX_EXP__ 16384");
		check(s.tsplit("\n").len, 15); // 14 lines + trailing empty piece
	};
}

// ---------------------------------------------------------------------------
// Integer helpers

fn void int_helpers() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [source] generateIntMax/Min/Width/SizeofType/Fmt/IntLiteralMacros
		predefined_macros::generate_int_max(comp, w, "SCHAR", type_store::SCHAR);
		predefined_macros::generate_int_max(comp, w, "U8", type_store::UCHAR);
		predefined_macros::generate_int_max(comp, w, "U16", type_store::USHORT);
		predefined_macros::generate_int_max(comp, w, "U32", type_store::UINT);
		predefined_macros::generate_int_max(comp, w, "LL", type_store::LONG_LONG);
		predefined_macros::generate_int_max(comp, w, "ULL", type_store::ULONG_LONG);
		predefined_macros::generate_int_min(comp, w, "INT", type_store::INT);
		predefined_macros::generate_int_min(comp, w, "UL", type_store::ULONG);
		predefined_macros::generate_int_width(comp, w, "BOOL", type_store::BOOL);
		predefined_macros::generate_sizeof_type(comp, w, "__SIZEOF_POINTER__", type_store::VOID_POINTER);
		predefined_macros::generate_fmt(comp, "__UINT32", w, type_store::UINT);
		predefined_macros::generate_fmt(comp, "__INT8", w, type_store::SCHAR);
		predefined_macros::generate_int_literal_macros(comp, "__INT32", w, type_store::INT);
		predefined_macros::generate_int_literal_macros(comp, "__UINT64", w, type_store::ULONG);
		predefined_macros::generate_type_macro(comp, w, "__X_TYPE__", type_store::ULONG_LONG);
		test::eq(w.written(),
			"#define __SCHAR_MAX__ 127\n"
			"#define __U8_MAX__ 255\n"
			"#define __U16_MAX__ 65535\n"
			"#define __U32_MAX__ 4294967295U\n"
			"#define __LL_MAX__ 9223372036854775807LL\n"
			"#define __ULL_MAX__ 18446744073709551615ULL\n"
			"#define __INT_MIN__ (-__INT_MAX__ - 1)\n"
			"#define __UL_MIN__ 0UL\n"
			"#define __BOOL_WIDTH__ 8\n"
			"#define __SIZEOF_POINTER__ 8\n"
			"#define __UINT32_FMTo__ \"o\"\n"
			"#define __UINT32_FMTu__ \"u\"\n"
			"#define __UINT32_FMTx__ \"x\"\n"
			"#define __UINT32_FMTX__ \"X\"\n"
			"#define __INT8_FMTd__ \"hhd\"\n"
			"#define __INT8_FMTi__ \"hhi\"\n"
			"#define __INT32_C_SUFFIX__ \n"
			"#define __INT32_C(c) c\n"
			"#define __UINT64_C_SUFFIX__ UL\n"
			"#define __UINT64_C(c) c##UL\n"
			"#define __X_TYPE__ unsigned long long\n");
	};
}

fn void int128_max() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		// [source] generateIntWidth for a 128-bit type. (generateIntMax on a
		// 128-bit type reaches intValueSuffix's `else => unreachable` in Zig,
		// and Zig never calls it that way.)
		predefined_macros::generate_int_width(comp, w, "INT128", type_store::INT128);
		test::eq(w.written(), "#define __INT128_WIDTH__ 128\n");
	};
}

// ---------------------------------------------------------------------------
// write_common_defines

fn void common_defines_x86_64_linux() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		// [source] layout / endian / object format / atomics
		test::eq(s.starts_with("#define _LP64 1\n#define __LP64__ 1\n#define __FLOAT128__ 1\n"
			"#define __ORDER_LITTLE_ENDIAN__ 1234\n#define __ORDER_BIG_ENDIAN__ 4321\n#define __ORDER_PDP_ENDIAN__ 3412\n"
			"#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__\n#define __LITTLE_ENDIAN__ 1\n#define __ELF__ 1\n"
			"#define __ATOMIC_RELAXED 0\n"), true);
		expect_line(s, "#define __ATOMIC_POINTER_LOCK_FREE 1");
		expect_no_line(s, "#define __ATOMIC_CHAR8_T_LOCK_FREE 1");
		expect_no_line(s, "#define __CHAR_UNSIGNED__ 1");
		expect_no_line(s, "#define __WCHAR_UNSIGNED__ 1");
		expect_line(s, "#define __WINT_UNSIGNED__ 1");
		expect_line(s, "#define __CHAR_BIT__ 8");
		expect_no_line(s, "#define __nonnull _Nonnull");

		// [source] int max/width list
		test::eq(lines_with_prefix(s, "#define __BOOL_"), "#define __BOOL_WIDTH__ 8\n");
		expect_line(s, "#define __SCHAR_MAX__ 127");
		expect_line(s, "#define __SHRT_MAX__ 32767");
		expect_line(s, "#define __SHRT_WIDTH__ 16");
		expect_line(s, "#define __INT_MAX__ 2147483647");
		expect_line(s, "#define __LONG_MAX__ 9223372036854775807L");
		expect_line(s, "#define __LONG_LONG_MAX__ 9223372036854775807LL");
		expect_line(s, "#define __LONG_LONG_WIDTH__ 64");
		test::eq(lines_with_prefix(s, "#define __WCHAR_M"), "#define __WCHAR_MAX__ 2147483647\n#define __WCHAR_MIN__ (-__WCHAR_MAX__ - 1)\n");
		test::eq(lines_with_prefix(s, "#define __WINT_M"), "#define __WINT_MAX__ 4294967295U\n#define __WINT_MIN__ 0U\n");
		// [fixture] intmax_t.c / intptr_t.c
		expect_line(s, "#define __INTMAX_MAX__ 9223372036854775807L");
		expect_line(s, "#define __INTMAX_WIDTH__ 64");
		expect_line(s, "#define __UINTMAX_MAX__ 18446744073709551615UL");
		expect_line(s, "#define __UINTMAX_WIDTH__ 64");
		expect_line(s, "#define __INTPTR_MAX__ 9223372036854775807L");
		expect_line(s, "#define __INTPTR_WIDTH__ 64");
		expect_line(s, "#define __UINTPTR_MAX__ 18446744073709551615UL");
		expect_line(s, "#define __UINTPTR_WIDTH__ 64");
		expect_line(s, "#define __INTMAX_TYPE__ long");
		expect_line(s, "#define __INTMAX_C_SUFFIX__ L");
		expect_line(s, "#define __INTMAX_C(c) c##L");
		expect_line(s, "#define __UINTMAX_TYPE__ unsigned long");
		expect_line(s, "#define __UINTMAX_C_SUFFIX__ UL");
		expect_line(s, "#define __INTPTR_TYPE__ long");
		expect_line(s, "#define __UINTPTR_TYPE__ unsigned long");
		// [source]
		expect_line(s, "#define __SIZE_MAX__ 18446744073709551615UL");
		expect_line(s, "#define __PTRDIFF_MAX__ 9223372036854775807L");
		expect_line(s, "#define __SIG_ATOMIC_MAX__ 2147483647");
		expect_line(s, "#define __SIG_ATOMIC_WIDTH__ 32");
		expect_line(s, "#define __BITINT_MAXWIDTH__ 65535");
		expect_no_line(s, "#define __INT24_MAX__ 8388607L");

		// [source] sizeof list; [fixture] int128.c pins __SIZEOF_INT128__ == sizeof(int128)
		test::eq(lines_with_prefix(s, "#define __SIZEOF_"),
			"#define __SIZEOF_FLOAT__ 4\n"
			"#define __SIZEOF_DOUBLE__ 8\n"
			"#define __SIZEOF_LONG_DOUBLE__ 10\n" // [source] cTypeBitSize(.longdouble)=80, /8; see header of write_common_defines
			"#define __SIZEOF_SHORT__ 2\n"
			"#define __SIZEOF_INT__ 4\n"
			"#define __SIZEOF_LONG__ 8\n"
			"#define __SIZEOF_LONG_LONG__ 8\n"
			"#define __SIZEOF_POINTER__ 8\n"
			"#define __SIZEOF_PTRDIFF_T__ 8\n"
			"#define __SIZEOF_SIZE_T__ 8\n"
			"#define __SIZEOF_WCHAR_T__ 4\n"
			"#define __SIZEOF_WINT_T__ 4\n"
			"#define __SIZEOF_INT128__ 16\n");

		expect_line(s, "#define __PTRDIFF_TYPE__ long");
		expect_line(s, "#define __SIZE_TYPE__ unsigned long");
		expect_line(s, "#define __WCHAR_TYPE__ int");
		expect_line(s, "#define __WINT_TYPE__ unsigned int");
		expect_line(s, "#define __CHAR16_TYPE__ unsigned short");
		expect_line(s, "#define __CHAR32_TYPE__ unsigned int");

		// [fixture] fixed size integer constants x86_64-linux-gnu.c; [source] order/FMT.
		test::eq(lines_with_prefix(s, "#define __INT8_"),
			"#define __INT8_TYPE__ signed char\n"
			"#define __INT8_FMTd__ \"hhd\"\n"
			"#define __INT8_FMTi__ \"hhi\"\n"
			"#define __INT8_C_SUFFIX__ \n"
			"#define __INT8_C(c) c\n"
			"#define __INT8_MAX__ 127\n");
		expect_line(s, "#define __UINT8_TYPE__ unsigned char");
		expect_line(s, "#define __UINT8_C_SUFFIX__ ");
		expect_line(s, "#define __UINT8_MAX__ 255");
		expect_line(s, "#define __INT16_TYPE__ short");
		expect_line(s, "#define __UINT16_TYPE__ unsigned short");
		expect_line(s, "#define __INT16_MAX__ 32767");
		expect_line(s, "#define __UINT16_MAX__ 65535");
		expect_line(s, "#define __INT16_C_SUFFIX__ ");
		expect_line(s, "#define __UINT16_C_SUFFIX__ ");
		expect_line(s, "#define __INT32_TYPE__ int");
		expect_line(s, "#define __UINT32_TYPE__ unsigned int");
		expect_line(s, "#define __INT32_MAX__ 2147483647");
		expect_line(s, "#define __UINT32_MAX__ 4294967295U");
		expect_line(s, "#define __UINT32_C_SUFFIX__ U");
		expect_line(s, "#define __INT64_TYPE__ long");
		expect_line(s, "#define __UINT64_TYPE__ unsigned long");
		expect_line(s, "#define __INT64_MAX__ 9223372036854775807L");
		expect_line(s, "#define __UINT64_MAX__ 18446744073709551615UL");
		expect_line(s, "#define __INT64_C_SUFFIX__ L");
		expect_line(s, "#define __UINT64_C_SUFFIX__ UL");
		expect_line(s, "#define __UINT64_C(c) c##UL");

		// [source] fast/least types (smallestNBitIntTargetIndependent on linux)
		test::eq(lines_with_prefix(s, "#define __INT_LEAST8_"),
			"#define __INT_LEAST8_TYPE__ signed char\n"
			"#define __INT_LEAST8_MAX__ 127\n"
			"#define __INT_LEAST8_WIDTH__ 8\n");
		// Zig quirk kept: generateFastOrLeastType passes the prefix with "__"
		// stripped to generateFmt, so these FMT macros lack the leading "__".
		test::eq(lines_with_prefix(s, "#define INT_LEAST8_"),
			"#define INT_LEAST8_FMTd__ \"hhd\"\n"
			"#define INT_LEAST8_FMTi__ \"hhi\"\n");
		test::eq(lines_with_prefix(s, "#define __UINT_FAST16_"),
			"#define __UINT_FAST16_TYPE__ unsigned short\n"
			"#define __UINT_FAST16_MAX__ 65535\n");
		test::eq(lines_with_prefix(s, "#define UINT_FAST16_"),
			"#define UINT_FAST16_FMTo__ \"ho\"\n"
			"#define UINT_FAST16_FMTu__ \"hu\"\n"
			"#define UINT_FAST16_FMTx__ \"hx\"\n"
			"#define UINT_FAST16_FMTX__ \"hX\"\n");
		expect_line(s, "#define __INT_FAST64_TYPE__ long");
		expect_line(s, "#define __INT_FAST64_MAX__ 9223372036854775807L");
		expect_line(s, "#define INT_LEAST64_FMTd__ \"ld\"");

		// [source] float macros: x86_64 has SSE2 -> FLT16; x87 long double
		expect_line(s, "#define __FLT16_MAX__ 6.5504e+4F16");
		expect_line(s, "#define __FLT_MAX__ 3.40282347e+38F");
		expect_line(s, "#define __DBL_MAX__ 1.7976931348623157e+308");
		expect_line(s, "#define __LDBL_MAX__ 1.18973149535723176502e+4932L");
		expect_line(s, "#define __FLT_EVAL_METHOD__ 0");
		test::eq(s.ends_with("#define __FLT_EVAL_METHOD__ 0\n#define __FLT_RADIX__ 2\n#define __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__\n"), true);
	};
}

fn void common_defines_options() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		comp.code_gen_options.pic_level = TWO;
		comp.code_gen_options.is_pie = true;
		comp.langopts.blocks = true;
		comp.langopts.set_fp_eval_method(EXTENDED);
		comp.langopts.set_standard("c23")!!;
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		expect_line(s, "#define __ATOMIC_CHAR8_T_LOCK_FREE 1");
		test::eq(s.ends_with("#define __FLT_EVAL_METHOD__ 2\n#define __FLT_RADIX__ 2\n#define __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__\n"
			"#define __pic__ 2\n#define __PIC__ 2\n#define __pie__ 2\n#define __PIE__ 2\n#define __BLOCKS__ 1\n"), true);
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		comp.code_gen_options.pic_level = ONE;
		predefined_macros::write_common_defines(comp, w);
		test::eq(w.written().ends_with("#define __pic__ 1\n#define __PIC__ 1\n"), true);
	};
}

fn void common_defines_other_targets() @test
{
	@with_comp("i386-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		test::eq(s.starts_with("#define _ILP32 1\n#define __ILP32__ 1\n#define __FLOAT128__ 1\n"), true);
		expect_no_line(s, "#define __SIZEOF_INT128__ 16");
		expect_line(s, "#define __INT64_TYPE__ long long");
		expect_line(s, "#define __INT64_MAX__ 9223372036854775807LL");
		expect_line(s, "#define __SIZE_TYPE__ unsigned int");
		expect_line(s, "#define __SIZEOF_LONG_DOUBLE__ 10");
	};
	@with_comp("x86_64-macos-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		expect_line(s, "#define __MACH__ 1");
		expect_no_line(s, "#define __ELF__ 1");
		expect_no_line(s, "#define __FLOAT128__ 1");
		expect_line(s, "#define __nonnull _Nonnull");
		expect_line(s, "#define __nullable _Nullable");
		// [source] intLeastN: Darwin uses long long for the 64-bit least/fast types
		expect_line(s, "#define __INT_LEAST64_TYPE__ long long");
		expect_line(s, "#define __UINT_FAST64_TYPE__ unsigned long long");
		expect_line(s, "#define __INT_LEAST64_MAX__ 9223372036854775807LL");
	};
	@with_comp("aarch64-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		expect_line(s, "#define __CHAR_UNSIGNED__ 1");
		expect_line(s, "#define __WCHAR_UNSIGNED__ 1");
		expect_line(s, "#define __FLOAT128__ 1");
		expect_line(s, "#define __SIZEOF_LONG_DOUBLE__ 16");
		expect_line(s, "#define __LDBL_MANT_DIG__ 113");
		expect_line(s, "#define __FLT16_MANT_DIG__ 11");
	};
	@with_comp("powerpc64le-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		expect_line(s, "#define __LDBL_MANT_DIG__ 106");
		expect_no_line(s, "#define __FLT16_MANT_DIG__ 11");
	};
	@with_comp("powerpc-linux-gnu"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		expect_line(s, "#define __BYTE_ORDER__ __ORDER_BIG_ENDIAN__");
		expect_line(s, "#define __BIG_ENDIAN__ 1");
		expect_no_line(s, "#define __LITTLE_ENDIAN__ 1");
	};
	@with_comp("avr-freestanding-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		String s = w.written();
		// [fixture] avr 24-bit int.c: __INT24_MAX__ == 8388607L etc.
		test::eq(lines_with_prefix(s, "#define __INT24_"),
			"#define __INT24_MAX__ 8388607L\n#define __INT24_MIN__ (-__INT24_MAX__-1)\n");
		expect_line(s, "#define __UINT24_MAX__ 16777215UL");
		// [fixture] avr sizeof long.c: sizeof(long double) == 4
		expect_line(s, "#define __SIZEOF_LONG_DOUBLE__ 4");
		expect_line(s, "#define __INT_MAX__ 32767");
		expect_line(s, "#define __SIG_ATOMIC_MAX__ 127");
		// [source] intLeastN: AVR uses int for the 16-bit least/fast types
		expect_line(s, "#define __INT_LEAST16_TYPE__ int");
		expect_line(s, "#define __INT16_TYPE__ int");
		expect_line(s, "#define __DBL_MANT_DIG__ 24");
	};
	@with_comp("msp430-freestanding-none"; Compilation* comp, MacroWriter* w)
	{
		predefined_macros::write_common_defines(comp, w);
		// [fixture] msp430 builtin types.c: sizeof(long double) == 8
		expect_line(w.written(), "#define __SIZEOF_LONG_DOUBLE__ 8");
		expect_line(w.written(), "#define __SIG_ATOMIC_MAX__ 2147483647L");
	};
}
