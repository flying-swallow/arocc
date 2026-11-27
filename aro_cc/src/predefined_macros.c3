// Port of the predefined-macro half of src/aro/Compilation.zig (plan 14):
// generateBuiltinMacros, writeBuiltinMacros, generateSystemDefines and the
// int/float limit helpers.
//
// How the parts fit
// =================
// All predefined macro writers live in this module and source file:
//
//   predefined_macros.c3 (this file; builtin, system, OS and architecture macros)
//       define helpers and SystemDefinesMode (stage 0, implemented),
//       generate_builtin_macros (stage 0, implemented glue),
//       generate_system_defines (stage 0, implemented: the section ORDER is
//       the contract), write_compiler_defines,
//       write_common_defines and every int/float/type limit helper.
//
// Writer: Zig writes into an `Io.Writer.Allocating` that becomes the
// "<builtin>" source (addSourceFromOwnedBuffer, kind user) which
// Preprocessor.preprocess_sources consumes first. Here every section writes
// to an OutStream (write faults propagate, Zig `try`); generate_builtin_macros
// moves its DString directly into the Compilation's source table.
//
// Output must be byte-identical to Zig for the same Compilation state,
// except `__VERSION__`, which is "Aro " ++ aro::VERSION (Zig: build.zig.zon
// `version`, "0.1.0-dev"). This is the one deliberately documented
// difference for macro inventories.
//
// Section order inside generate_system_defines (each line is one function):
//   write_compiler_defines      GNUC version, __ARO_EMULATE*, _MSC_VER, __building_module, __OPTIMIZE*
//   write_pthread_defines       _REENTRANT / _MT / __EMSCRIPTEN_PTHREADS__ (if langopts.pthread)
//   write_target_os_macros      TARGET_OS_* (only if langopts.has_target_os_macros())
//   OS switch                   windows -> write_windows_os_defines; Darwin -> write_darwin_os_defines;
//                               everything else -> write_other_os_defines
//   write_unix_defines          unix (defineStd) for unix-like OSes, then __ANDROID__
//   arch switch                 x86/x86_64 -> write_x86_defines; mips* -> write_mips_defines;
//                               powerpc/powerpcle/powerpc64/powerpc64le -> write_powerpc_defines;
//                               sparc/sparc64 -> write_sparc_defines; arm/armeb/thumb/thumbeb ->
//                               write_arm_defines; aarch64/aarch64_be -> write_aarch64_defines;
//                               msp430/arc -> write_msp430_arc_defines; wasm32/wasm64 ->
//                               write_wasm_defines; s390x -> write_s390x_defines;
//                               riscv32/riscv32be/riscv64/riscv64be -> write_riscv_defines
//   write_common_defines        _LP64/_ILP32 ... __BLOCKS__ (the rest of generateSystemDefines)
module aro::frontend::c::predefined_macros;
import aro::bigint;
import aro::frontend::c::compilation, aro::source, aro::target, aro::frontend::c::type_store, aro::frontend::c::lang_opts, aro::code_gen_options;
import std::core::ascii, std::core::string, std::io;

// ---------------------------------------------------------------------------
// Define helpers (stage 0, implemented)

<* Zig `Compilation.SystemDefinesMode`: which set of system defines generate_builtin_macros writes. *>
enum SystemDefinesMode : char
{
	<* Only define macros required by the C standard (date/time macros and those beginning with `__STDC`) *>
	NO_SYSTEM_DEFINES,
	<* Define the standard set of system macros *>
	INCLUDE_SYSTEM_DEFINES,
}

<* generateSystemDefines' `define`: "#define <name> 1\n". *>
fn void? define(OutStream w, String name)
{
	io::fprintf(w, "#define %s 1\n", name)!;
}

<*
 generateSystemDefines' `defineStd`: in GNU modes "#define <name> 1\n", then
 always "#define __<name> 1\n#define __<name>__ 1\n".
*>
fn void? define_std(OutStream w, String name, bool is_gnu)
{
	if (is_gnu) io::fprintf(w, "#define %s 1\n", name)!;
	io::fprintf(w, "#define __%s 1\n#define __%s__ 1\n", name, name)!;
}

<* generateSystemDefines' `defineBool`: "#define <name> 0\n" or "... 1\n". *>
fn void? define_bool(OutStream w, String name, bool value)
{
	io::fprintf(w, "#define %s %d\n", name, value ? 1 : 0)!;
}

<* "#define <name> <value>\n" (any preformatted value text). *>
fn void? define_value(OutStream w, String name, String value)
{
	io::fprintf(w, "#define %s %s\n", name, value)!;
}

<* "#define <name> <decimal value>\n" (Zig `{d}` of a signed integer). *>
fn void? define_int(OutStream w, String name, long value)
{
	io::fprintf(w, "#define %s %d\n", name, value)!;
}

// ---------------------------------------------------------------------------
// Entry points

<*
 Zig `generateBuiltinMacros`: type_store::init_named_types, write every
 macro and add the bytes as source "<builtin>" (kind
 USER) owned by `comp`. More than 4 GiB of text is FILE_TOO_BIG.
 @return? compilation::FILE_TOO_BIG, compilation::FATAL_ERROR
*>
fn Source? generate_builtin_macros(Compilation* comp, SystemDefinesMode mode)
{
	type_store::init_named_types(&comp.type_store, &comp.target, &comp.string_interner);

	// Zig `.initCapacity(comp.gpa, 2 << 13)`.
	DString out;
	out.init(comp.gpa, 2 << 13);
	defer out.free();

	if (mode == INCLUDE_SYSTEM_DEFINES)
	{
		io::fprintf(&out, "#define __VERSION__ \"Aro %s\"\n", aro::VERSION)!;
		out.write("#define __Aro__\n")!;
	}

	if (comp.langopts.emulate != MSVC) out.write("#define __STDC__ 1\n")!;
	io::fprintf(&out, "#define __STDC_HOSTED__ %d\n", comp.target.os.tag != FREESTANDING ? 1 : 0)!;

	// Standard macros.
	out.write("#define __STDC_UTF_16__ 1\n"
		"#define __STDC_UTF_32__ 1\n"
		"#define __STDC_EMBED_NOT_FOUND__ 0\n"
		"#define __STDC_EMBED_FOUND__ 1\n"
		"#define __STDC_EMBED_EMPTY__ 2\n")!;
	if (comp.langopts.standard.at_least(C11))
	{
		switch (comp.target.os.tag)
		{
			case OPENBSD:
			case DRIVERKIT:
			case IOS:
			case MACCATALYST:
			case MACOS:
			case TVOS:
			case VISIONOS:
			case WATCHOS:
				out.write("#define __STDC_NO_THREADS__ 1\n")!;
			case PS4:
			case PS5:
				out.write("#define __STDC_NO_THREADS__ 1\n#define __STDC_NO_COMPLEX__ 1\n")!;
			default: break;
		}
	}
	String stdc_version = comp.langopts.standard.version_macro;
	if (stdc_version.len)
	{
		out.write("#define __STDC_VERSION__ ")!;
		out.write(stdc_version)!;
		out.write_byte('\n')!;
	}

	if (mode == INCLUDE_SYSTEM_DEFINES) generate_system_defines(comp, &out)!;
	if ((ulong)out.len() > 0xFFFF_FFFF) return compilation::FILE_TOO_BIG~;
	return comp.add_source_from_owned_dstring("<builtin>", &out, USER);
}

<*
 Zig `generateSystemDefines`. The call order is the contract (see the
 file header).
*>
fn void? generate_system_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	bool is_gnu = comp.langopts.standard.is_gnu;

	write_compiler_defines(comp, w)!;
	write_pthread_defines(comp, w)!;
	if (comp.langopts.has_target_os_macros()) write_target_os_macros(comp, w)!;

	// os macros
	if (t.os.tag == WINDOWS)
	{
		write_windows_os_defines(comp, w, is_gnu)!;
	}
	else if (t.os.tag.is_darwin())
	{
		write_darwin_os_defines(comp, w)!;
	}
	else
	{
		write_other_os_defines(comp, w, is_gnu)!;
	}
	// unix and other additional os macros
	write_unix_defines(comp, w, is_gnu)!;

	// architecture macros
	switch (t.cpu.arch)
	{
		case X86:
		case X86_64: write_x86_defines(comp, w, is_gnu)!;
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL: write_mips_defines(comp, w, is_gnu)!;
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE: write_powerpc_defines(comp, w)!;
		case SPARC:
		case SPARC64: write_sparc_defines(comp, w, is_gnu)!;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: write_arm_defines(comp, w)!;
		case AARCH64:
		case AARCH64_BE: write_aarch64_defines(comp, w)!;
		case MSP430:
		case ARC: write_msp430_arc_defines(comp, w)!;
		case WASM32:
		case WASM64: write_wasm_defines(comp, w)!;
		case S390X: write_s390x_defines(comp, w)!;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: write_riscv_defines(comp, w)!;
		default: break;
	}

	write_common_defines(comp, w)!;
}

// ---------------------------------------------------------------------------
// Remaining system macro writers

<* Zig `Compilation.bit_int_max_bits` (std.math.maxInt(u16)). *>
const uint BIT_INT_MAX_BITS = 65535;

<*
 First part of generateSystemDefines:
 - gnuc_version = langopts.gnuc_version if has_gnuc_version else
   emulate.default_gcc_version(); if > 0: __GNUC__ v/10000,
   __GNUC_MINOR__ (v/100)%100, __GNUC_PATCHLEVEL__ v%100.
 - "#define __ARO_EMULATE_NO__ 0", "..._CLANG__ 1", "..._GCC__ 2",
   "..._MSVC__ 3", then "#define __ARO_EMULATE__ __ARO_EMULATE_<X>__".
 - emulate == MSVC: "_MSC_VER 1933", "_MSC_FULL_VER 193300000".
 - "#define __building_module(x) 0".
 - define __OPTIMIZE__ if code_gen_options.optimization_level
   .has_any_optimizations(); __OPTIMIZE_SIZE__ if .is_size_optimized().
*>
fn void? write_compiler_defines(Compilation* comp, OutStream w)
{
	LangOpts* lo = &comp.langopts;
	uint gnuc_version = lo.has_gnuc_version ? lo.gnuc_version : lo.emulate.default_gcc_version();
	if (gnuc_version > 0)
	{
		io::fprintf(w, "#define __GNUC__ %d\n", gnuc_version / 10_000)!;
		io::fprintf(w, "#define __GNUC_MINOR__ %d\n", (gnuc_version / 100) % 100)!;
		io::fprintf(w, "#define __GNUC_PATCHLEVEL__ %d\n", gnuc_version % 100)!;
	}

	w.write("#define __ARO_EMULATE_NO__ 0\n"
		"#define __ARO_EMULATE_CLANG__ 1\n"
		"#define __ARO_EMULATE_GCC__ 2\n"
		"#define __ARO_EMULATE_MSVC__ 3\n")!;
	String emulate_name;
	switch (lo.emulate)
	{
		case NO: emulate_name = "__ARO_EMULATE_NO__";
		case CLANG: emulate_name = "__ARO_EMULATE_CLANG__";
		case GCC: emulate_name = "__ARO_EMULATE_GCC__";
		case MSVC: emulate_name = "__ARO_EMULATE_MSVC__";
	}
	io::fprintf(w, "#define __ARO_EMULATE__ %s\n", emulate_name)!;

	if (lo.emulate == MSVC)
	{
		w.write("#define _MSC_VER 1933\n")!;
		w.write("#define _MSC_FULL_VER 193300000\n")!;
	}

	// Defined for compatibility with clang.
	w.write("#define __building_module(x) 0\n")!;

	if (comp.code_gen_options.optimization_level.has_any_optimizations()) define(w, "__OPTIMIZE__")!;
	if (comp.code_gen_options.optimization_level.is_size_optimized()) define(w, "__OPTIMIZE_SIZE__")!;
}

<*
 The tail of generateSystemDefines, in Zig order: _LP64/__LP64__ (ptr 64,
 long 64, int 32) else _ILP32/__ILP32__ (ptr 32, long 32, int 32);
 __FLOAT128__ if has_float128; __ORDER_*_ENDIAN__ and __BYTE_ORDER__ +
 __LITTLE_ENDIAN__/__BIG_ENDIAN__; __ELF__ / __MACH__ by target.ofmt; Darwin
 __nonnull/__null_unspecified/__nullable; __ATOMIC_* orders and *_LOCK_FREE
 (1), __ATOMIC_CHAR8_T_LOCK_FREE if langopts.has_char8_t; __CHAR_UNSIGNED__,
 __WCHAR_UNSIGNED__, __WINT_UNSIGNED__, __CHAR_BIT__ 8; the int max/width
 list (BOOL width, SCHAR ... SIG_ATOMIC, __INT24_* when target.has_int24() with
 "LL"/"L" suffix chosen by int bits == 8); __BITINT_MAXWIDTH__ 65535;
 __SIZEOF_*__ (incl. __SIZEOF_INT128__ if has_int128); __INTPTR_TYPE__ ...
 __CHAR32_TYPE__ (note Zig passes `intptr` to __INTMAX/__UINTMAX
 generate_int_literal_macros: kept); exact width types; fast/least
 types; FLT16 (half_precision_type != NONE, ext "F16"), FLT ("F"), DBL
 (""), LDBL ("L") float macros; __FLT_EVAL_METHOD__ (langopts override else
 target default, printed as its integer value); __FLT_RADIX__ 2,
 __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__; __pic__/__PIC__ (and __pie__/__PIE__
 if is_pie) with pic_level.value unless NONE; __BLOCKS__ if langopts.blocks.

 Note: __SIZEOF_LONG_DOUBLE__ is sizeof(long double), the cTypeByteSize: the
 80-bit x87 type is padded to its alignment (16 on x86_64, 12 on i386), as
 gcc/clang report.
*>
fn void? write_common_defines(Compilation* comp, OutStream w)
{
	Target* target = &comp.target;
	TypeStore* ts = &comp.type_store;
	ushort ptr_width = target.ptr_bit_width();

	if (ptr_width == 64 && target.c_type_bit_size(LONG) == 64 && target.c_type_bit_size(INT) == 32)
	{
		define(w, "_LP64")!;
		define(w, "__LP64__")!;
	}
	else if (ptr_width == 32 && target.c_type_bit_size(LONG) == 32 && target.c_type_bit_size(INT) == 32)
	{
		define(w, "_ILP32")!;
		define(w, "__ILP32__")!;
	}

	if (target.has_float128()) define(w, "__FLOAT128__")!;

	w.write("#define __ORDER_LITTLE_ENDIAN__ 1234\n"
		"#define __ORDER_BIG_ENDIAN__ 4321\n"
		"#define __ORDER_PDP_ENDIAN__ 3412\n")!;
	if (target.cpu.arch.endian() == LITTLE)
	{
		w.write("#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__\n#define __LITTLE_ENDIAN__ 1\n")!;
	}
	else
	{
		w.write("#define __BYTE_ORDER__ __ORDER_BIG_ENDIAN__\n#define __BIG_ENDIAN__ 1\n")!;
	}

	switch (target.ofmt)
	{
		case ELF: define(w, "__ELF__")!;
		case MACHO: define(w, "__MACH__")!;
		default: break;
	}

	if (target.os.tag.is_darwin())
	{
		w.write("#define __nonnull _Nonnull\n"
			"#define __null_unspecified _Null_unspecified\n"
			"#define __nullable _Nullable\n")!;
	}

	// atomics
	w.write("#define __ATOMIC_RELAXED 0\n"
		"#define __ATOMIC_CONSUME 1\n"
		"#define __ATOMIC_ACQUIRE 2\n"
		"#define __ATOMIC_RELEASE 3\n"
		"#define __ATOMIC_ACQ_REL 4\n"
		"#define __ATOMIC_SEQ_CST 5\n")!;

	// TODO (Zig): Set these to target-specific constants depending on backend capabilities
	// For now they are just set to the "may be lock-free" value
	w.write("#define __ATOMIC_BOOL_LOCK_FREE 1\n"
		"#define __ATOMIC_CHAR_LOCK_FREE 1\n"
		"#define __ATOMIC_CHAR16_T_LOCK_FREE 1\n"
		"#define __ATOMIC_CHAR32_T_LOCK_FREE 1\n"
		"#define __ATOMIC_WCHAR_T_LOCK_FREE 1\n"
		"#define __ATOMIC_WINT_T_LOCK_FREE 1\n"
		"#define __ATOMIC_SHORT_LOCK_FREE 1\n"
		"#define __ATOMIC_INT_LOCK_FREE 1\n"
		"#define __ATOMIC_LONG_LOCK_FREE 1\n"
		"#define __ATOMIC_LLONG_LOCK_FREE 1\n"
		"#define __ATOMIC_POINTER_LOCK_FREE 1\n")!;
	if (comp.langopts.has_char8_t()) w.write("#define __ATOMIC_CHAR8_T_LOCK_FREE 1\n")!;

	// types
	if (type_store::char_signedness(comp) == UNSIGNED) w.write("#define __CHAR_UNSIGNED__ 1\n")!;
	if (ts.wchar.signedness(comp) == UNSIGNED) w.write("#define __WCHAR_UNSIGNED__ 1\n")!;
	if (ts.wint.signedness(comp) == UNSIGNED) w.write("#define __WINT_UNSIGNED__ 1\n")!;
	w.write("#define __CHAR_BIT__ 8\n")!;

	// int maxs
	generate_int_width(comp, w, "BOOL", type_store::BOOL)!;
	generate_int_max_and_width(comp, w, "SCHAR", type_store::SCHAR)!;
	generate_int_max_and_width(comp, w, "SHRT", type_store::SHORT)!;
	generate_int_max_and_width(comp, w, "INT", type_store::INT)!;
	generate_int_max_and_width(comp, w, "LONG", type_store::LONG)!;
	generate_int_max_and_width(comp, w, "LONG_LONG", type_store::LONG_LONG)!;
	if (comp.target.has_int24())
	{
		bool int_is_8 = TypeInt.INT.bits(comp) == 8;
		io::fprintf(w, "#define __INT24_MAX__ 8388607%s\n", int_is_8 ? "LL" : "L")!;
		w.write("#define __INT24_MIN__ (-__INT24_MAX__-1)\n")!;
		io::fprintf(w, "#define __UINT24_MAX__ 16777215%s\n", int_is_8 ? "ULL" : "UL")!;
	}
	generate_int_max_and_width(comp, w, "WCHAR", ts.wchar)!;
	generate_int_min(comp, w, "WCHAR", ts.wchar)!;
	generate_int_max_and_width(comp, w, "WINT", ts.wint)!;
	generate_int_min(comp, w, "WINT", ts.wint)!;
	generate_int_max_and_width(comp, w, "INTMAX", ts.intmax)!;
	generate_int_max_and_width(comp, w, "SIZE", ts.size)!;
	generate_int_max_and_width(comp, w, "UINTMAX", ts.intmax.make_int_unsigned(comp))!;
	generate_int_max_and_width(comp, w, "PTRDIFF", ts.ptrdiff)!;
	generate_int_max_and_width(comp, w, "INTPTR", ts.intptr)!;
	generate_int_max_and_width(comp, w, "UINTPTR", ts.intptr.make_int_unsigned(comp))!;
	generate_int_max_and_width(comp, w, "SIG_ATOMIC", type_store::int_kind_qt(target.sig_atomic_type()))!;

	// int widths
	io::fprintf(w, "#define __BITINT_MAXWIDTH__ %d\n", BIT_INT_MAX_BITS)!;

	// sizeof types
	generate_sizeof_type(comp, w, "__SIZEOF_FLOAT__", type_store::FLOAT)!;
	generate_sizeof_type(comp, w, "__SIZEOF_DOUBLE__", type_store::DOUBLE)!;
	generate_sizeof_type(comp, w, "__SIZEOF_LONG_DOUBLE__", type_store::LONG_DOUBLE)!;
	generate_sizeof_type(comp, w, "__SIZEOF_SHORT__", type_store::SHORT)!;
	generate_sizeof_type(comp, w, "__SIZEOF_INT__", type_store::INT)!;
	generate_sizeof_type(comp, w, "__SIZEOF_LONG__", type_store::LONG)!;
	generate_sizeof_type(comp, w, "__SIZEOF_LONG_LONG__", type_store::LONG_LONG)!;
	generate_sizeof_type(comp, w, "__SIZEOF_POINTER__", type_store::VOID_POINTER)!;
	generate_sizeof_type(comp, w, "__SIZEOF_PTRDIFF_T__", ts.ptrdiff)!;
	generate_sizeof_type(comp, w, "__SIZEOF_SIZE_T__", ts.size)!;
	generate_sizeof_type(comp, w, "__SIZEOF_WCHAR_T__", ts.wchar)!;
	generate_sizeof_type(comp, w, "__SIZEOF_WINT_T__", ts.wint)!;

	if (target.has_int128()) generate_sizeof_type(comp, w, "__SIZEOF_INT128__", type_store::INT128)!;

	// various int types
	generate_type_macro(comp, w, "__INTPTR_TYPE__", ts.intptr)!;
	generate_type_macro(comp, w, "__UINTPTR_TYPE__", ts.intptr.make_int_unsigned(comp))!;

	generate_type_macro(comp, w, "__INTMAX_TYPE__", ts.intmax)!;
	// Zig passes intptr (not intmax) here; kept for parity.
	generate_int_literal_macros(comp, "__INTMAX", w, ts.intptr)!;

	generate_type_macro(comp, w, "__UINTMAX_TYPE__", ts.intmax.make_int_unsigned(comp))!;
	generate_int_literal_macros(comp, "__UINTMAX", w, ts.intptr.make_int_unsigned(comp))!;

	generate_type_macro(comp, w, "__PTRDIFF_TYPE__", ts.ptrdiff)!;
	generate_type_macro(comp, w, "__SIZE_TYPE__", ts.size)!;
	generate_type_macro(comp, w, "__WCHAR_TYPE__", ts.wchar)!;
	generate_type_macro(comp, w, "__WINT_TYPE__", ts.wint)!;
	generate_type_macro(comp, w, "__CHAR16_TYPE__", ts.uint_least16_t)!;
	generate_type_macro(comp, w, "__CHAR32_TYPE__", ts.uint_least32_t)!;

	generate_exact_width_types(comp, w)!;
	generate_fast_and_least_width_types(comp, w)!;

	FPSemantics half = target::half_precision_type(target);
	if (half != NONE) generate_float_macros(w, "FLT16", half, "F16")!;
	generate_float_macros(w, "FLT", target::fp_semantics_for_type(FLOAT, target), "F")!;
	generate_float_macros(w, "DBL", target::fp_semantics_for_type(DOUBLE, target), "")!;
	generate_float_macros(w, "LDBL", target::fp_semantics_for_type(LONGDOUBLE, target), "L")!;

	// TODO (Zig): clang treats __FLT_EVAL_METHOD__ as a special-cased macro because evaluating it within a scope
	// where `#pragma clang fp eval_method(X)` has been called produces an error diagnostic.
	FPEvalMethod flt_eval_method = comp.langopts.has_fp_eval_method ? comp.langopts.fp_eval_method : target.default_fp_eval_method();
	io::fprintf(w, "#define __FLT_EVAL_METHOD__ %d\n", (int)flt_eval_method.value)!;

	w.write("#define __FLT_RADIX__ 2\n#define __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__\n")!;

	PicLevel pic = comp.code_gen_options.pic_level;
	if (pic != NONE)
	{
		io::fprintf(w, "#define __pic__ %d\n#define __PIC__ %d\n", pic.value, pic.value)!;
		if (comp.code_gen_options.is_pie)
		{
			io::fprintf(w, "#define __pie__ %d\n#define __PIE__ %d\n", pic.value, pic.value)!;
		}
	}

	// Blocks
	if (comp.langopts.blocks) define(w, "__BLOCKS__")!;
}

<* One column of Zig generateFloatMacros' chooseValue tables. *>
struct FloatLimits @local
{
	String denorm_min;
	int digits;
	int decimal_digits;
	String epsilon;
	int mantissa_digits;
	int min_10_exp;
	int max_10_exp;
	int min_exp;
	int max_exp;
	String min;
	String max;
}

<* Zig generateFloatMacros' tables, indexed as FPSemantics.chooseValue: half, single, double, x87, IBM double-double, quad. *>
const FloatLimits[6] FLOAT_LIMITS @local = {
	{ "5.9604644775390625e-8", 3, 5, "9.765625e-4", 11, -4, 4, -13, 16,
		"6.103515625e-5", "6.5504e+4" },
	{ "1.40129846e-45", 6, 9, "1.19209290e-7", 24, -37, 38, -125, 128,
		"1.17549435e-38", "3.40282347e+38" },
	{ "4.9406564584124654e-324", 15, 17, "2.2204460492503131e-16", 53, -307, 308, -1021, 1024,
		"2.2250738585072014e-308", "1.7976931348623157e+308" },
	{ "3.64519953188247460253e-4951", 18, 21, "1.08420217248550443401e-19", 64, -4931, 4932, -16381, 16384,
		"3.36210314311209350626e-4932", "1.18973149535723176502e+4932" },
	{ "4.94065645841246544176568792868221e-324", 31, 33, "4.94065645841246544176568792868221e-324", 106, -291, 308, -968, 1024,
		"2.00416836000897277799610805135016e-292", "1.79769313486231580793728971405301e+308" },
	{ "6.47517511943802511092443895822764655e-4966", 33, 36, "1.92592994438723585305597794258492732e-34", 113, -4931, 4932, -16381, 16384,
		"3.36210314311209350626267781732175260e-4932", "1.18973149535723176508575932662800702e+4932" },
};

<*
 Zig `generateFloatMacros(w, prefix, semantics, ext)`: the 14 __<prefix>_*__
 macros (DENORM_MIN, HAS_DENORM, DIG, DECIMAL_DIG, EPSILON, HAS_INFINITY,
 HAS_QUIET_NAN, MANT_DIG, MAX_10_EXP, MAX_EXP, MAX, MIN_10_EXP (in parens),
 MIN_EXP (in parens), MIN) in that order. Values come from Zig
 `FPSemantics.chooseValue` over (IEEE_HALF, IEEE_SINGLE, IEEE_DOUBLE,
 X87_EXTENDED_DOUBLE, IBM_EXTENDED_DOUBLE, IEEE_QUAD); any other semantics
 is unreachable. `ext` is appended to DENORM_MIN, EPSILON, MAX and MIN.
 Zig writes these as fixed literal text (no float formatting), and so does
 this port.
*>
fn void? generate_float_macros(OutStream w, String prefix, FPSemantics semantics, String ext)
{
	usz idx;
	switch (semantics)
	{
		case IEEE_HALF: idx = 0;
		case IEEE_SINGLE: idx = 1;
		case IEEE_DOUBLE: idx = 2;
		case X87_EXTENDED_DOUBLE: idx = 3;
		case IBM_EXTENDED_DOUBLE: idx = 4;
		case IEEE_QUAD: idx = 5;
		default: unreachable("no float macros for this FPSemantics");
	}
	FloatLimits l = FLOAT_LIMITS[idx];

	io::fprintf(w, "#define __%s_DENORM_MIN__ %s%s\n", prefix, l.denorm_min, ext)!;
	io::fprintf(w, "#define __%s_HAS_DENORM__\n", prefix)!;
	io::fprintf(w, "#define __%s_DIG__ %d\n", prefix, l.digits)!;
	io::fprintf(w, "#define __%s_DECIMAL_DIG__ %d\n", prefix, l.decimal_digits)!;

	io::fprintf(w, "#define __%s_EPSILON__ %s%s\n", prefix, l.epsilon, ext)!;
	io::fprintf(w, "#define __%s_HAS_INFINITY__\n", prefix)!;
	io::fprintf(w, "#define __%s_HAS_QUIET_NAN__\n", prefix)!;
	io::fprintf(w, "#define __%s_MANT_DIG__ %d\n", prefix, l.mantissa_digits)!;

	io::fprintf(w, "#define __%s_MAX_10_EXP__ %d\n", prefix, l.max_10_exp)!;
	io::fprintf(w, "#define __%s_MAX_EXP__ %d\n", prefix, l.max_exp)!;
	io::fprintf(w, "#define __%s_MAX__ %s%s\n", prefix, l.max, ext)!;

	io::fprintf(w, "#define __%s_MIN_10_EXP__ (%d)\n", prefix, l.min_10_exp)!;
	io::fprintf(w, "#define __%s_MIN_EXP__ (%d)\n", prefix, l.min_exp)!;
	io::fprintf(w, "#define __%s_MIN__ %s%s\n", prefix, l.min, ext)!;
}

<* Zig `generateTypeMacro`: "#define <name> " + qt.print + "\n". *>
fn void? generate_type_macro(Compilation* comp, OutStream w, String name, QualType qt)
{
	io::fprintf(w, "#define %s ", name)!;
	qt.print(comp, w)!;
	w.write_byte('\n')!;
}

<*
 Zig `generateIntMin`: unsigned -> "#define __<name>_MIN__ 0<suffix>",
 signed -> "#define __<name>_MIN__ (-__<name>_MAX__ - 1)".
*>
fn void? generate_int_min(Compilation* comp, OutStream w, String name, QualType qt)
{
	if (qt.signedness(comp) == UNSIGNED)
	{
		io::fprintf(w, "#define __%s_MIN__ 0%s\n", name, qt.int_value_suffix(comp))!;
	}
	else
	{
		io::fprintf(w, "#define __%s_MIN__ (-__%s_MAX__ - 1)\n", name, name)!;
	}
}

<*
 Zig `generateIntMax`: "#define __<name>_MAX__ <max><int_value_suffix>" where
 max is maxInt of the (un)signed integer of qt's bit size (8/16/32/64/128).
*>
fn void? generate_int_max(Compilation* comp, OutStream w, String name, QualType qt)
{
	bool unsigned = qt.signedness(comp) == UNSIGNED;
	uint128 max;
	switch (qt.bit_sizeof(comp))
	{
		case 8: max = unsigned ? (uint128)char::max : (uint128)ichar::max;
		case 16: max = unsigned ? (uint128)ushort::max : (uint128)short::max;
		case 32: max = unsigned ? (uint128)uint::max : (uint128)int::max;
		case 64: max = unsigned ? (uint128)ulong::max : (uint128)long::max;
		case 128: max = unsigned ? uint128::max : (uint128)int128::max;
		default: unreachable("unexpected integer width");
	}
	io::fprintf(w, "#define __%s_MAX__ %d%s\n", name, max, qt.int_value_suffix(comp))!;
}

<* Zig `generateIntWidth`: "#define __<name>_WIDTH__ <sizeof*8>". *>
fn void? generate_int_width(Compilation* comp, OutStream w, String name, QualType qt)
{
	io::fprintf(w, "#define __%s_WIDTH__ %d\n", name, qt.sizeof(comp) * 8)!;
}

<* Zig `generateIntMaxAndWidth`: generate_int_max then generate_int_width. *>
fn void? generate_int_max_and_width(Compilation* comp, OutStream w, String name, QualType qt)
{
	generate_int_max(comp, w, name, qt)!;
	generate_int_width(comp, w, name, qt)!;
}

<* Zig `generateSizeofType`: "#define <name> <sizeof>". *>
fn void? generate_sizeof_type(Compilation* comp, OutStream w, String name, QualType qt)
{
	io::fprintf(w, "#define %s %d\n", name, qt.sizeof(comp))!;
}

<*
 Zig `generateFmt`: for each of "ouxX" (unsigned) or "di" (signed):
 `#define <prefix>_FMT<c>__ "<format_modifier><c>"`.
*>
fn void? generate_fmt(Compilation* comp, String prefix, OutStream w, QualType qt)
{
	bool unsigned = qt.signedness(comp) == UNSIGNED;
	String modifier = qt.format_modifier(comp);
	String formats = unsigned ? "ouxX" : "di";
	foreach (c : formats)
	{
		io::fprintf(w, "#define %s_FMT%c__ \"%s%c\"\n", prefix, c, modifier, c)!;
	}
}

<*
 Zig `generateIntLiteralMacros`: "#define <prefix>_C_SUFFIX__ <suffix>" then
 "#define <prefix>_C(c) c" (empty suffix) or "#define <prefix>_C(c) c##<suffix>".
*>
fn void? generate_int_literal_macros(Compilation* comp, String prefix, OutStream w, QualType qt)
{
	String suffix = qt.int_value_suffix(comp);
	io::fprintf(w, "#define %s_C_SUFFIX__ %s\n", prefix, suffix)!;
	if (suffix.len == 0)
	{
		io::fprintf(w, "#define %s_C(c) c\n", prefix)!;
	}
	else
	{
		io::fprintf(w, "#define %s_C(c) c##%s\n", prefix, suffix)!;
	}
}

<*
 Zig `generateExactWidthType`: __(U)INT<width>_TYPE__, its FMT macros and its
 literal macros. Width 16 / 64 types are replaced by type_store.int16 /
 int64 (made unsigned as needed).
*>
fn void? generate_exact_width_type(Compilation* comp, OutStream w, QualType original_qt) @local
{
	QualType qt = original_qt;
	ulong width = qt.sizeof(comp) * 8;
	bool unsigned = qt.signedness(comp) == UNSIGNED;

	if (width == 16)
	{
		qt = unsigned ? comp.type_store.int16.make_int_unsigned(comp) : comp.type_store.int16;
	}
	else if (width == 64)
	{
		qt = unsigned ? comp.type_store.int64.make_int_unsigned(comp) : comp.type_store.int64;
	}

	String prefix = string::tformat("%s%d", unsigned ? "__UINT" : "__INT", width);
	generate_type_macro(comp, w, string::tformat("%s_TYPE__", prefix), qt)!;
	generate_fmt(comp, prefix, w, qt)!;
	generate_int_literal_macros(comp, prefix, w, qt)!;
}

<* Zig `generateExactWidthIntMax`: __(U)INT<bits>_MAX__, with width 64 replaced by type_store.int64. *>
fn void? generate_exact_width_int_max(Compilation* comp, OutStream w, QualType original_qt) @local
{
	QualType qt = original_qt;
	ulong bit_count = qt.sizeof(comp) * 8;
	bool unsigned = qt.signedness(comp) == UNSIGNED;

	if (bit_count == 64)
	{
		qt = unsigned ? comp.type_store.int64.make_int_unsigned(comp) : comp.type_store.int64;
	}

	generate_int_max(comp, w, string::tformat("%s%d", unsigned ? "UINT" : "INT", bit_count), qt)!;
}

<*
 Zig `generateExactWidthTypes`: schar; short/int/long/long long when wider
 than the previous rank; uchar + UINT8/INT8 max; then the unsigned
 counterparts with their maxes under the same width conditions.
*>
fn void? generate_exact_width_types(Compilation* comp, OutStream w)
{
	generate_exact_width_type(comp, w, type_store::SCHAR)!;
	ushort char_bits = TypeInt.CHAR.bits(comp);
	ushort short_bits = TypeInt.SHORT.bits(comp);
	ushort int_bits = TypeInt.INT.bits(comp);
	ushort long_bits = TypeInt.LONG.bits(comp);
	ushort long_long_bits = TypeInt.LONG_LONG.bits(comp);

	if (short_bits > char_bits) generate_exact_width_type(comp, w, type_store::SHORT)!;
	if (int_bits > short_bits) generate_exact_width_type(comp, w, type_store::INT)!;
	if (long_bits > int_bits) generate_exact_width_type(comp, w, type_store::LONG)!;
	if (long_long_bits > long_bits) generate_exact_width_type(comp, w, type_store::LONG_LONG)!;

	generate_exact_width_type(comp, w, type_store::UCHAR)!;
	generate_exact_width_int_max(comp, w, type_store::UCHAR)!;
	generate_exact_width_int_max(comp, w, type_store::SCHAR)!;

	if (short_bits > char_bits)
	{
		generate_exact_width_type(comp, w, type_store::USHORT)!;
		generate_exact_width_int_max(comp, w, type_store::USHORT)!;
		generate_exact_width_int_max(comp, w, type_store::SHORT)!;
	}
	if (int_bits > short_bits)
	{
		generate_exact_width_type(comp, w, type_store::UINT)!;
		generate_exact_width_int_max(comp, w, type_store::UINT)!;
		generate_exact_width_int_max(comp, w, type_store::INT)!;
	}
	if (long_bits > int_bits)
	{
		generate_exact_width_type(comp, w, type_store::ULONG)!;
		generate_exact_width_int_max(comp, w, type_store::ULONG)!;
		generate_exact_width_int_max(comp, w, type_store::LONG)!;
	}
	if (long_long_bits > long_bits)
	{
		generate_exact_width_type(comp, w, type_store::ULONG_LONG)!;
		generate_exact_width_int_max(comp, w, type_store::ULONG_LONG)!;
		generate_exact_width_int_max(comp, w, type_store::LONG_LONG)!;
	}
}

<*
 Zig `generateFastOrLeastType`: __(U)INT_<LEAST|FAST><bits>_TYPE__ from
 type_store::int_least_n (fast types are defined as the least types); signed
 gets MAX+WIDTH, unsigned only MAX; then FMT.
*>
fn void? generate_fast_or_least_type(Compilation* comp, ulong bits, bool fast, Signedness signedness, OutStream w) @local
{
	QualType ty = type_store::int_least_n(comp, bits, signedness);
	String prefix = string::tformat("%s%s%d", signedness == SIGNED ? "INT_" : "UINT_", fast ? "FAST" : "LEAST", bits);
	generate_type_macro(comp, w, string::tformat("__%s_TYPE__", prefix), ty)!;
	if (signedness == SIGNED)
	{
		generate_int_max_and_width(comp, w, prefix, ty)!;
	}
	else
	{
		generate_int_max(comp, w, prefix, ty)!;
	}
	generate_fmt(comp, prefix, w, ty)!;
}

<*
 Zig `generateFastAndLeastWidthTypes`: for 8, 16, 32, 64: least signed,
 least unsigned, fast signed, fast unsigned.
*>
fn void? generate_fast_and_least_width_types(Compilation* comp, OutStream w)
{
	ulong[4] sizes = { 8, 16, 32, 64 };
	foreach (size : sizes)
	{
		generate_fast_or_least_type(comp, size, false, SIGNED, w)!;
		generate_fast_or_least_type(comp, size, false, UNSIGNED, w)!;
		generate_fast_or_least_type(comp, size, true, SIGNED, w)!;
		generate_fast_or_least_type(comp, size, true, UNSIGNED, w)!;
	}
}


// Target OS, other OS, and non-x86 architecture macro writers.
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
*>
fn RiscvFloatAbi riscv_float_abi(Target* target)
{
	switch (target.abi)
	{
		case GNUSF:
		case MUSLSF: return SOFT;
		case GNUF32:
		case MUSLF32: return SINGLE;
		default:
			if (target.cpu.has(RISCV_D)) return DOUBLE;
			if (target.cpu.has(RISCV_F)) return SINGLE;
			return SOFT;
	}
}

<*
 `if (comp.langopts.pthread)`: _REENTRANT for maccatalyst/macos/tvos/ios/
 driverkit/visionos/watchos/hurd/linux/netbsd/openbsd/fuchsia; _MT for
 windows with abi MSVC; __EMSCRIPTEN_PTHREADS__ for emscripten.
*>
fn void? write_pthread_defines(Compilation* comp, OutStream w)
{
	if (!comp.langopts.pthread) return;
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case IOS:
		case DRIVERKIT:
		case VISIONOS:
		case WATCHOS:
		case HURD:
		case LINUX:
		case NETBSD:
		case OPENBSD:
		case FUCHSIA: define(w, "_REENTRANT")!;
		case WINDOWS:
			// This matches clang where it is marked as a FIXME
			if (t.abi == MSVC) define(w, "_MT")!;
		case EMSCRIPTEN: define(w, "__EMSCRIPTEN_PTHREADS__")!;
		default: break;
	}
}

<*
 The OS switch for every OS except windows and Darwin: linux (define_std
 linux), uefi __UEFI__, freebsd (__FreeBSD__ <major>, __FreeBSD_cc_version
 <major*10000+1>), ps4/ps5 (__FreeBSD__ 9, __FreeBSD_cc_version 900001),
 netbsd, openbsd, dragonfly, illumos (define_std sun + __illumos__), wasi,
 emscripten, serenity, switch (__SWITCH__), 3ds (__3DS__), gba, psp (__PSP__),
 psx (__psx__), vita (__vita__), wiiu (__WIIU__); else nothing.
*>
fn void? write_other_os_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case LINUX: define_std(w, "linux", is_gnu)!;
		case UEFI: define(w, "__UEFI__")!;
		case FREEBSD:
			ulong release = t.os.min.major;
			ulong cc_version = release * 10_000 + 1;
			io::fprintf(w, "#define __FreeBSD__ %d\n#define __FreeBSD_cc_version %d\n", release, cc_version)!;
		case PS4:
		case PS5: w.write("#define __FreeBSD__ 9\n#define __FreeBSD_cc_version 900001\n")!;
		case NETBSD: define(w, "__NetBSD__")!;
		case OPENBSD: define(w, "__OpenBSD__")!;
		case DRAGONFLY: define(w, "__DragonFly__")!;
		case ILLUMOS:
			define_std(w, "sun", is_gnu)!;
			define(w, "__illumos__")!;
		case WASI: define(w, "__wasi__")!;
		case EMSCRIPTEN: define(w, "__EMSCRIPTEN__")!;
		case SERENITY: define(w, "__serenity__")!;
		case SWITCH: define(w, "__SWITCH__")!;
		case THREEDS: define(w, "__3DS__")!;
		case GBA: define(w, "__GBA__")!;
		case PSP: define(w, "__PSP__")!;
		case PSX: define(w, "__psx__")!;
		case VITA: define(w, "__vita__")!;
		case WIIU: define(w, "__WIIU__")!;
		default: break;
	}
}

<*
 define_std("unix") for freebsd/netbsd/openbsd/dragonfly/linux/haiku/hurd/
 illumos/emscripten/ps4/ps5; then __ANDROID__ if abi.is_android().
*>
fn void? write_unix_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	switch (t.os.tag)
	{
		case FREEBSD:
		case NETBSD:
		case OPENBSD:
		case DRAGONFLY:
		case LINUX:
		case HAIKU:
		case HURD:
		case ILLUMOS:
		case EMSCRIPTEN:
		case PS4:
		case PS5: define_std(w, "unix", is_gnu)!;
		default: break;
	}
	if (t.abi.is_android()) define(w, "__ANDROID__")!;
}

<*
 The mips/mipsel/mips64/mips64el arm: __mips__, _mips, mips (GNU), endian
 (_MIPSEB/MIPSEB or _MIPSEL/MIPSEL), ABI block by target.mips_abi() (o32,
 n32, n64), _MIPS_ARCH "<llvm_name>" + _MIPS_ARCH_<UPPER> (if the model has
 an llvm name), __mips_abicalls (+ __ABICALLS__ on BSD) when pic_level !=
 NONE, __mips_single_float, __mips_fpr / _MIPS_FPSET / _MIPS_SPFPSET by
 default_mips_fp_mode, nan2008, abs2008, dsp revision, msa, nomadd4,
 _MIPS_SZPTR / _MIPS_SZINT / _MIPS_SZLONG and __mips_isa_rev.
*>
fn void? write_mips_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	define(w, "__mips__")!;
	define(w, "_mips")!;
	if (is_gnu) define(w, "mips")!;
	switch (t.cpu.arch)
	{
		case MIPS:
		case MIPS64:
			define(w, "_MIPSEB")!;
			define_std(w, "MIPSEB", is_gnu)!;
		case MIPSEL:
		case MIPS64EL:
			define(w, "_MIPSEL")!;
			define_std(w, "MIPSEL", is_gnu)!;
		default: unreachable();
	}

	switch (t.mips_abi())
	{
		case O32:
			define(w, "__mips_o32")!;
			define(w, "_ABIO32")!;
			w.write("#define _MIPS_SIM _ABIO32\n")!;
			w.write("#define __mips 32\n")!;
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS32\n")!;
		case N32:
			define(w, "__mips_n32")!;
			w.write("#define _ABIN32 2\n")!;
			w.write("#define _MIPS_SIM _ABIN32\n")!;
			w.write("#define __mips 64\n")!;
			define(w, "__mips64")!;
			define(w, "__mips64__")!;
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS64\n")!;
		case N64:
			define(w, "__mips_n64")!;
			w.write("#define _ABI64 3\n")!;
			w.write("#define _MIPS_SIM _ABI64\n")!;
			w.write("#define __mips 64\n")!;
			define(w, "__mips64")!;
			define(w, "__mips64__")!;
			w.write("#define _MIPS_ISA _MIPS_ISA_MIPS64\n")!;
	}
	// Zig `llvm_name: ?[*:0]const u8`; an empty llvm_name is null here.
	String name = t.cpu.model.llvm_name;
	if (name.len)
	{
		io::fprintf(w, "#define _MIPS_ARCH \"%s\"\n", name)!;
		w.write("#define _MIPS_ARCH_")!;
		foreach (c : name) w.write_byte(ascii::to_upper(c))!;
		w.write(" 1\n")!;
	}

	// Zig also has `!target.cpu.has(.mips, .noabicalls)` commented out.
	if (comp.code_gen_options.pic_level != NONE)
	{
		define(w, "__mips_abicalls")!;
		if (t.os.tag.is_bsd()) define(w, "__ABICALLS__")!;
	}

	// Zig: __mips_soft_float / __mips_hard_float are commented out.
	bool single_only = t.cpu.has(MIPS_FPU_S) && !t.cpu.has(MIPS_FPU_D);
	if (single_only) define(w, "__mips_single_float")!;
	{
		MipsFpMode mode = t.default_mips_fp_mode();
		int fpr;
		switch (mode)
		{
			case FP32: fpr = 32;
			case FP64: fpr = 64;
			case FPXX: fpr = 0;
		}
		io::fprintf(w, "#define __mips_fpr %d\n", fpr)!;
		int fpset = (mode == FP64 || single_only) ? 32 : 16;
		io::fprintf(w, "#define _MIPS_FPSET %d\n", fpset)!;
		// Zig: `target.cpu.has(.mips, .nooddspreg) or` is commented out.
		int spfpset = mode == FPXX ? 16 : 32;
		io::fprintf(w, "#define _MIPS_SPFPSET %d\n", spfpset)!;
	}
	// Zig: __mips16 / __mips_micromips are commented out.
	if (t.cpu.has(MIPS_NAN2008)) define(w, "__mips_nan2008")!;
	if (t.cpu.has(MIPS_ABS2008)) define(w, "__mips_abs2008")!;
	if (t.cpu.has(MIPS_DSPR3))
	{
		w.write("#define __mips_dsp_rev 3\n")!;
		w.write("#define __mips_dsp 3\n")!;
		define(w, "__mips_dspr3")!;
	}
	else if (t.cpu.has(MIPS_DSPR2))
	{
		w.write("#define __mips_dsp_rev 2\n")!;
		w.write("#define __mips_dsp 2\n")!;
		define(w, "__mips_dspr2")!;
	}
	else if (t.cpu.has(MIPS_DSP))
	{
		w.write("#define __mips_dsp_rev 1\n")!;
		w.write("#define __mips_dsp 1\n")!;
	}
	if (t.cpu.has(MIPS_MSA)) define(w, "__mips_msa")!;
	if (t.cpu.has(MIPS_NOMADD4)) define(w, "__mips_no_madd4")!;
	io::fprintf(w, "#define _MIPS_SZPTR %d\n", t.ptr_bit_width())!;
	io::fprintf(w, "#define _MIPS_SZINT %d\n", t.c_type_bit_size(INT))!;
	io::fprintf(w, "#define _MIPS_SZLONG %d\n", t.c_type_bit_size(LONG))!;
	io::fprintf(w, "#define __mips_isa_rev %d\n", t.mips_isa_rev())!;
}

<*
 powerpc/powerpcle: __powerpc__ __POWERPC__ __ppc__ __PPC__ _ARCH_PPC;
 powerpc64/powerpc64le: __powerpc __powerpc__ __powerpc64__ __POWERPC__
 __ppc__ __ppc64__ __PPC__ __PPC64__ _ARCH_PPC _ARCH_PPC64; both end with
 "_CALL_ELF <ppc_elf_version>".
*>
fn void? write_powerpc_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	switch (t.cpu.arch)
	{
		case POWERPC:
		case POWERPCLE:
			define(w, "__powerpc__")!;
			define(w, "__POWERPC__")!;
			define(w, "__ppc__")!;
			define(w, "__PPC__")!;
			define(w, "_ARCH_PPC")!;
		default:
			define(w, "__powerpc")!;
			define(w, "__powerpc__")!;
			define(w, "__powerpc64__")!;
			define(w, "__POWERPC__")!;
			define(w, "__ppc__")!;
			define(w, "__ppc64__")!;
			define(w, "__PPC__")!;
			define(w, "__PPC64__")!;
			define(w, "_ARCH_PPC")!;
			define(w, "_ARCH_PPC64")!;
	}
	io::fprintf(w, "#define _CALL_ELF %d\n", t.ppc_elf_version())!;
}

<*
 sparc64: define_std sparc, __sparc_v9__, __arch64__, and (not illumos)
 __sparc64__, __sparc_v9__ (again), __sparcv9__. sparc: define_std sparc,
 __sparcv8 on illumos.
*>
fn void? write_sparc_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	define_std(w, "sparc", is_gnu)!;
	if (t.cpu.arch == SPARC64)
	{
		define(w, "__sparc_v9__")!;
		define(w, "__arch64__")!;
		if (t.os.tag != ILLUMOS)
		{
			define(w, "__sparc64__")!;
			define(w, "__sparc_v9__")!;
			define(w, "__sparcv9__")!;
		}
	}
	else if (t.os.tag == ILLUMOS)
	{
		define(w, "__sparcv8")!;
	}
}

// ACLE 6.5.1 Hardware Floating Point (Zig `HwFp`, packed u4): the value of __ARM_FP.
const char HWFP_HP = 1 << 1; // half (16-bit)
const char HWFP_SP = 1 << 2; // single (32-bit)
const char HWFP_DP = 1 << 3; // double (64-bit)

// arm_acle.h co-processor intrinsic groups (Zig `coproc`).
const char COPROC_B1 = 1 << 0; // __arm_cdp __arm_ldc, __arm_ldcl, __arm_stc, __arm_stcl, __arm_mcr and __arm_mrc
const char COPROC_B2 = 1 << 1; // __arm_cdp2, __arm_ldc2, __arm_stc2, __arm_ldc2l, __arm_stc2l, __arm_mcr2 and __arm_mrc2
const char COPROC_B3 = 1 << 2; // __arm_mcrr, __arm_mrrc
const char COPROC_B4 = 1 << 3; // __arm_mcrr2, __arm_mrrc2
const char COPROC_ALL = COPROC_B1 | COPROC_B2 | COPROC_B3 | COPROC_B4;

<* Zig `coproc_bf`: which co-processor intrinsics in arm_acle.h are available. *>
fn char arm_coproc_bits(Target* t) @local
{
	ArmVersion? v = t.arm_version();
	if (catch v) return 0;
	if (v.string == "6M" || v.string == "6SM" || v.string == "8M_BASE") return 0;
	if (v.string == "8M_MAIN" || v.string == "8_1M_MAIN") return COPROC_ALL;
	switch (v.version)
	{
		case 4: return COPROC_B1;
		case 5: return v.string == "5T" ? COPROC_B1 | COPROC_B2 : COPROC_B1 | COPROC_B2 | COPROC_B3;
		case 6:
		case 7: return COPROC_ALL;
		case 8:
		case 9: return COPROC_B1 | COPROC_B3;
		default: return 0;
	}
}

<*
 arm/armeb/thumb/thumbeb: the ACLE block of generateSystemDefines exactly
 (ISA_THUMB from arm_version(), __thumb__, profile, CLZ/DSP/IDIV/SAT/QBIT/
 SIMD32, HwFp/Fpu computation from arm_float_abi() and the vfp/fp_armv8/
 neon/mve_fp/fp64/fp16 features, __ARM_FP 0x<hex>, FMA, VFPV*, NEON +
 __ARM_NEON_FP, __ARM_PCS_VFP, __SOFTFP__, __ARM_FEATURE_COPROC, interwork,
 LDREX (target.arm_ldrex()), UNALIGNED, endian, ROPI/RWPI, minimal enum
 size and __ARM_SIZEOF_WCHAR_T). Needs type_store::init_named_types (wchar).
*>
fn void? write_arm_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	Arch arch = t.cpu.arch;
	define(w, "__arm__")!;
	define(w, "__arm")!;
	define(w, "__ARM_32BIT_STATE")!;
	define(w, "__APCS_32__")!;
	define(w, "__VFP_FP__")!;
	define(w, "__ARM_FP16_ARGS")!;
	define(w, "__ARM_FP16_FORMAT_IEEE")!;

	w.write("#define __ARM_ACLE 200\n")!;

	// __ARM_ARCH_ISA_THUMB is defined to 2 if the core supports the Thumb-2 ISA.
	if (try v = t.arm_version())
	{
		bool supports_thumb2 = v.string == "6T2" || (v.version >= 7 && v.string != "8M_BASE");
		if (supports_thumb2)
		{
			w.write("#define __ARM_ARCH_ISA_THUMB 2\n")!;
		}
		else if (v.string.contains_char('T') || v.version >= 6)
		{
			w.write("#define __ARM_ARCH_ISA_THUMB 1\n")!;
		}
	}

	bool mclass = t.cpu.has(ARM_MCLASS);
	bool is_thumb = arch.is_thumb() || mclass;
	if (t.cpu.has(ARM_THUMB2) || is_thumb) define(w, "__thumb__")!;
	// ARM ISA means we are not M profile
	if (!mclass) define(w, "__ARM_ARCH_ISA_ARM")!;

	char arm_version = 6;
	if (try v = t.arm_version())
	{
		arm_version = v.version;
		io::fprintf(w, "#define __ARM_ARCH_%s__ 1\n", v.string)!;
		io::fprintf(w, "#define __ARM_ARCH %d\n", v.version)!;
	}

	char arm_profile = 0;
	if (t.cpu.has(ARM_ACLASS))
	{
		arm_profile = 'A';
	}
	else if (t.cpu.has(ARM_RCLASS))
	{
		arm_profile = 'R';
	}
	else if (mclass)
	{
		arm_profile = 'M';
	}
	if (arm_profile) io::fprintf(w, "#define __ARM_ARCH_PROFILE '%c'\n", arm_profile)!;

	if (arm_version == 5 || (arm_version == 6 && !mclass) || arm_version > 6) define(w, "__ARM_FEATURE_CLZ")!;

	bool has_dsp = t.arm_has_dsp();
	if (has_dsp) define(w, "__ARM_FEATURE_DSP")!;

	if ((is_thumb && t.cpu.has(ARM_HWDIV)) || (!is_thumb && t.cpu.has(ARM_HWDIV_ARM)))
	{
		define(w, "__ARM_FEATURE_IDIV")!;
		define(w, "__ARM_ARCH_EXT_IDIV__")!;
	}
	bool sat = false;
	if ((arm_version == 6 && !mclass) || arm_version > 6)
	{
		define(w, "__ARM_FEATURE_SAT")!;
		sat = true;
	}

	if (has_dsp || sat) define(w, "__ARM_FEATURE_QBIT")!;

	if ((!mclass && arm_version >= 6) || (mclass && t.cpu.has(ARM_DSP))) define(w, "__ARM_FEATURE_SIMD32")!;

	ArmFloatAbi float_abi = t.arm_float_abi();

	// This is a (hopefully) exact copy of the code in clang (lib/Basic/Targets/ARM.cpp).
	char hw_fp = 0;
	bool fpu_vfp2, fpu_vfp3, fpu_vfp4, fpu_neon, fpu_fp_armv8;
	if (float_abi != SOFT)
	{
		if (t.cpu.has(ARM_VFP2) || t.cpu.has(ARM_VFP2SP))
		{
			fpu_vfp2 = true;
			hw_fp |= HWFP_SP;
			if (t.cpu.has(ARM_VFP2)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_VFP3) || t.cpu.has(ARM_VFP3D16) || t.cpu.has(ARM_VFP3SP) || t.cpu.has(ARM_VFP3D16SP))
		{
			fpu_vfp3 = true;
			hw_fp |= HWFP_SP;
			if (t.cpu.has(ARM_VFP3) || t.cpu.has(ARM_VFP3D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_VFP4) || t.cpu.has(ARM_VFP4D16) || t.cpu.has(ARM_VFP4SP) || t.cpu.has(ARM_VFP4D16SP))
		{
			fpu_vfp4 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
			if (t.cpu.has(ARM_VFP4) || t.cpu.has(ARM_VFP4D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_FP_ARMV8) || t.cpu.has(ARM_FP_ARMV8D16) || t.cpu.has(ARM_FP_ARMV8SP) || t.cpu.has(ARM_FP_ARMV8D16SP))
		{
			fpu_fp_armv8 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
			if (t.cpu.has(ARM_FP_ARMV8) || t.cpu.has(ARM_FP_ARMV8D16)) hw_fp |= HWFP_DP;
		}
		if (t.cpu.has(ARM_NEON))
		{
			fpu_neon = true;
			hw_fp |= HWFP_SP;
		}
		if (t.cpu.has(ARM_MVE_FP))
		{
			fpu_fp_armv8 = true;
			hw_fp |= HWFP_SP | HWFP_HP;
		}
		if (t.cpu.has(ARM_FP64)) hw_fp |= HWFP_DP;
		if (t.cpu.has(ARM_FP16)) hw_fp |= HWFP_HP;
	}
	// clang: `FPUModeIsVFP`
	bool fpu_is_vfp = fpu_vfp2 || fpu_vfp3 || fpu_vfp4 || fpu_neon || fpu_fp_armv8;

	if (hw_fp != 0) io::fprintf(w, "#define __ARM_FP 0x%x\n", hw_fp)!;

	if (arm_version >= 7 && fpu_vfp4) define(w, "__ARM_FEATURE_FMA")!;

	if (fpu_is_vfp)
	{
		if (fpu_vfp2) define(w, "__ARM_VFPV2__")!;
		if (fpu_vfp3) define(w, "__ARM_VFPV3__")!;
		if (fpu_vfp4) define(w, "__ARM_VFPV4__")!;
		if (fpu_fp_armv8) define(w, "__ARM_FPV5__")!;
	}

	if (fpu_neon && float_abi != SOFT && arm_version >= 7)
	{
		define(w, "__ARM_NEON")!;
		define(w, "__ARM_NEON__")!;
		// Current AArch32 Neon implementations have no double-precision support
		// even when VFP does.
		char neon_fp = hw_fp & (char)~HWFP_DP;
		io::fprintf(w, "#define __ARM_NEON_FP 0x%x\n", neon_fp)!;
	}

	if (float_abi == HARD) define(w, "__ARM_PCS_VFP")!;

	if (float_abi == SOFT || (float_abi == SOFT_FP && !fpu_is_vfp)) define(w, "__SOFTFP__")!;

	io::fprintf(w, "#define __ARM_FEATURE_COPROC 0x%x\n", arm_coproc_bits(t))!;

	if (arm_version >= 5 && arm_version <= 8 && t.os.tag != WINDOWS) define(w, "__THUMB_INTERWORK__")!;

	if (try ldrex = comp.target.arm_ldrex()) io::fprintf(w, "#define __ARM_FEATURE_LDREX 0x%x\n", (char)ldrex)!;

	if (!t.cpu.has(ARM_NO_UNALIGNED_ACCESS)) define(w, "__ARM_FEATURE_UNALIGNED")!;

	if (arch == ARM || arch == THUMB) define(w, "__ARMEL__")!;

	if (arch == ARMEB || arch == THUMBEB)
	{
		define(w, "__ARMEB__")!;
		define(w, "__ARM_BIG_ENDIAN")!;
	}
	if (comp.code_gen_options.is_ropi) define(w, "__ARM_ROPI")!;
	if (comp.code_gen_options.is_rwpi) define(w, "__ARM_RWPI")!;

	write_arm_enum_and_wchar_size(comp, w)!;
}

<* The shared ARM/AArch64 tail: __ARM_SIZEOF_MINIMAL_ENUM and __ARM_SIZEOF_WCHAR_T. *>
fn void? write_arm_enum_and_wchar_size(Compilation* comp, OutStream w) @local
{
	int min_enum_size = comp.langopts.short_enums ? 1 : 4;
	io::fprintf(w, "#define __ARM_SIZEOF_MINIMAL_ENUM %d\n", min_enum_size)!;
	io::fprintf(w, "#define __ARM_SIZEOF_WCHAR_T %d\n", comp.type_store.wchar.sizeof(comp))!;
}

struct Aarch64FeatureMacro
{
	Feature feature;
	String name;
}

<* Zig's __ARM_FEATURE_<name> table for aarch64, in Zig order (i8mm appears twice). *>
const Aarch64FeatureMacro[*] AARCH64_FEATURE_MACROS = {
	{ AARCH64_SVE, "SVE" },
	{ AARCH64_SVE2, "SVE2" },
	{ AARCH64_SVE2P1, "SVE2p1" },
	{ AARCH64_SVE2_SHA3, "SVE2_SHA3" },
	{ AARCH64_SVE2_SM4, "SVE2_SM4" },
	{ AARCH64_SVE_B16B16, "SVE_B16B16" },
	{ AARCH64_SME2, "SME2" },
	{ AARCH64_SME2P1, "SME2p1" },
	{ AARCH64_SME_F16F16, "SME_F16F16" },
	{ AARCH64_SME_B16B16, "SME_B16B16" },
	{ AARCH64_CRC, "CRC32" },
	{ AARCH64_AES, "AES" },
	{ AARCH64_SHA2, "SHA2" },
	{ AARCH64_PAUTH, "PAUTH" },
	{ AARCH64_PAUTH_LR, "PAUTH_LR" },
	{ AARCH64_BTI, "BTI" },
	{ AARCH64_FULLFP16, "FP16_SCALAR_ARITHMETIC" },
	{ AARCH64_DOTPROD, "DOTPROD" },
	{ AARCH64_MTE, "MEMORY_TAGGING" },
	{ AARCH64_I8MM, "MATMUL_INT8" },
	{ AARCH64_LSE, "ATOMICS" },
	{ AARCH64_F64MM, "SVE_MATMUL_FP64" },
	{ AARCH64_F32MM, "SVE_MATMUL_FP32" },
	{ AARCH64_I8MM, "SVE_MATMUL_INT8" },
	{ AARCH64_FP16FML, "FP16_FML" },
	{ AARCH64_LS64, "LS64" },
	{ AARCH64_RAND, "RNG" },
	{ AARCH64_MOPS, "MOPS" },
	{ AARCH64_D128, "SYSREG128" },
	{ AARCH64_GCS, "GCS" },
};

<*
 aarch64/aarch64_be: the fixed ACLE defines, LDREX, __ARM_ACLE_VERSION and
 "__ARM_ACLE 202420", __ARM_ARCH 9/8 (v9a), profile R/A (v8r), v8_3a
 COMPLEX/JCVT, endian, Darwin SIMD/arm64 defines, _M_ARM64 1 (windows-msvc),
 __AARCH64_CMODEL_<UPPER(cmodel.macro_name())>__, FP/NEON, BF16, SVE2_AES,
 SVE2_BITPERM, SME, SHA3, SM4, UNALIGNED, FP16_VECTOR_ARITHMETIC, RCPC, the
 __ARM_FEATURE_<X> table in Zig order, minimal enum size and wchar size.
 Needs type_store::init_named_types (wchar).
*>
fn void? write_aarch64_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	define(w, "__aarch64__")!;
	define(w, "__ARM_64BIT_STATE")!;
	define(w, "__ARM_ARCH_ISA_A64")!;
	define(w, "__ARM_FEATURE_CLZ")!;
	define(w, "__ARM_FEATURE_FMA")!;
	if (try ldrex = comp.target.arm_ldrex()) io::fprintf(w, "#define __ARM_FEATURE_LDREX 0x%x\n", (char)ldrex)!;
	define(w, "__ARM_FEATURE_IDIV")!; // As specified in ACLE
	define(w, "__ARM_FEATURE_DIV")!; // For backwards compatibility
	define(w, "__ARM_STATE_ZA")!;
	define(w, "__ARM_STATE_ZT0")!;
	w.write("#define __ARM_ALIGN_MAX_STACK_PWR 4\n")!;
	define(w, "__ARM_FEATURE_NUMERIC_MAXMIN")!;
	define(w, "__ARM_FEATURE_DIRECTED_ROUNDING")!;

	w.write("#define __ARM_ACLE_VERSION(year,quarter,patch) (100 * (year) + 10 * (quarter) + (patch))\n")!;
	int acle_version = (100 * 2024) + (10 * 2) + 0; // ACLE 2024.2
	io::fprintf(w, "#define __ARM_ACLE %d\n", acle_version)!;

	int arm_version = t.cpu.has(AARCH64_V9A) ? 9 : 8;
	char arm_profile = t.cpu.has(AARCH64_V8R) ? 'R' : 'A';
	io::fprintf(w, "#define __ARM_ARCH %d\n", arm_version)!;
	io::fprintf(w, "#define __ARM_ARCH_PROFILE '%c'\n", arm_profile)!;

	if (t.cpu.has(AARCH64_V8_3A))
	{
		define(w, "__ARM_FEATURE_COMPLEX")!;
		define(w, "__ARM_FEATURE_JCVT")!;
	}

	if (t.cpu.arch == AARCH64)
	{
		define(w, "__AARCH64EL__")!;
	}
	else
	{
		define(w, "__AARCH64EB__")!;
		define(w, "__AARCH_BIG_ENDIAN")!;
		define(w, "__ARM_BIG_ENDIAN")!;
	}
	if (t.os.tag.is_darwin())
	{
		define(w, "__AARCH64_SIMD__")!;
		if (t.ptr_bit_width() == 32)
		{
			define(w, "__ARM64_ARCH_8_32__")!;
		}
		else
		{
			define(w, "__ARM64_ARCH_8__")!;
		}
		define(w, "__ARM_NEON__")!;
		define(w, "__arm64")!;
		define(w, "__arm64__")!;
	}
	if (t.os.tag == WINDOWS && t.abi == MSVC) w.write("#define _M_ARM64 1\n")!;

	w.write("#define __AARCH64_CMODEL_")!;
	foreach (c : comp.cmodel.macro_name()) w.write_byte(ascii::to_upper(c))!;
	w.write("__ 1\n")!;

	if (t.cpu.has(AARCH64_FP_ARMV8)) w.write("#define __ARM_FP 0xE\n")!;
	if (t.cpu.has(AARCH64_NEON))
	{
		define(w, "__ARM_NEON")!;
		w.write("#define __ARM_NEON_FP 0xE\n")!;
	}
	if (t.cpu.has(AARCH64_BF16))
	{
		define(w, "__ARM_FEATURE_BF16")!;
		define(w, "__ARM_FEATURE_BF16_VECTOR_ARITHMETIC")!;
		define(w, "__ARM_BF16_FORMAT_ALTERNATIVE")!;
		define(w, "__ARM_FEATURE_BF16_SCALAR_ARITHMETIC")!;
		if (t.cpu.has(AARCH64_SVE)) define(w, "__ARM_FEATURE_SVE_BF16")!;
	}
	if (t.cpu.has(AARCH64_SVE2) && t.cpu.has(AARCH64_SVE_AES)) define(w, "__ARM_FEATURE_SVE2_AES")!;
	if (t.cpu.has(AARCH64_SVE2) && t.cpu.has(AARCH64_SVE_BITPERM)) define(w, "__ARM_FEATURE_SVE2_BITPERM")!;
	if (t.cpu.has(AARCH64_SME))
	{
		define(w, "__ARM_FEATURE_SME")!;
		define(w, "__ARM_FEATURE_LOCALLY_STREAMING")!;
	}
	// Zig: __HAVE_FUNCTION_MULTI_VERSIONING (fmv) is commented out.
	if (t.cpu.has(AARCH64_SHA3))
	{
		define(w, "__ARM_FEATURE_SHA3")!;
		define(w, "__ARM_FEATURE_SHA512")!;
	}
	if (t.cpu.has(AARCH64_SM4))
	{
		define(w, "__ARM_FEATURE_SM3")!;
		define(w, "__ARM_FEATURE_SM4")!;
	}
	if (!t.cpu.has(AARCH64_NO_UNALIGNED_ACCESS)) define(w, "__ARM_FEATURE_UNALIGNED")!;
	if (t.cpu.has(AARCH64_NEON) && t.cpu.has(AARCH64_FULLFP16)) define(w, "__ARM_FEATURE_FP16_VECTOR_ARITHMETIC")!;
	if (t.cpu.has(AARCH64_RCPC3))
	{
		w.write("#define __ARM_FEATURE_RCPC 3\n")!;
	}
	else if (t.cpu.has(AARCH64_RCPC))
	{
		define(w, "__ARM_FEATURE_RCPC")!;
	}

	foreach (fm : AARCH64_FEATURE_MACROS)
	{
		if (t.cpu.has(fm.feature)) io::fprintf(w, "#define __ARM_FEATURE_%s 1\n", fm.name)!;
	}
	write_arm_enum_and_wchar_size(comp, w)!;
}

<* msp430: MSP430, __MSP430__. arc: __arc__. *>
fn void? write_msp430_arc_defines(Compilation* comp, OutStream w)
{
	switch (comp.target.cpu.arch)
	{
		case MSP430:
			define(w, "MSP430")!;
			define(w, "__MSP430__")!;
		case ARC: define(w, "__arc__")!;
		default: break;
	}
}

<*
 wasm32/wasm64: __wasm, __wasm__, __wasm32/__wasm32__ or __wasm64/__wasm64__,
 then "#define __wasm_<feature name>__ 1" for every enabled wasm feature in
 Feature declaration order.
*>
fn void? write_wasm_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	define(w, "__wasm")!;
	define(w, "__wasm__")!;
	if (t.cpu.arch == WASM32)
	{
		define(w, "__wasm32")!;
		define(w, "__wasm32__")!;
	}
	else
	{
		define(w, "__wasm64")!;
		define(w, "__wasm64__")!;
	}
	foreach (f : Feature::values)
	{
		if (f.family != WASM || !t.cpu.has(f)) continue;
		io::fprintf(w, "#define __wasm_%s__ 1\n", f.name)!;
	}
}

<* s390x: __s390__, __s390x__, __zarch__, __HTM__ (te), __VX__ (vx). *>
fn void? write_s390x_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	define(w, "__s390__")!;
	define(w, "__s390x__")!;
	define(w, "__zarch__")!;
	if (t.cpu.has(S390X_TE)) define(w, "__HTM__")!;
	if (t.cpu.has(S390X_VX)) define(w, "__VX__")!;
}

<*
 riscv*: __riscv, __riscv_xlen <ptr width>, __riscv_f/d/q 2002000,
 __riscv_flen 128/64/32 (q, d, f), __riscv_float_abi_<riscv_float_abi>.
*>
fn void? write_riscv_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	define(w, "__riscv")!;
	io::fprintf(w, "#define __riscv_xlen %d\n", t.ptr_bit_width())!;
	bool has_f = t.cpu.has(RISCV_F);
	bool has_d = t.cpu.has(RISCV_D);
	bool has_q = t.cpu.has(RISCV_Q);
	if (has_f) w.write("#define __riscv_f 2002000\n")!;
	if (has_d) w.write("#define __riscv_d 2002000\n")!;
	if (has_q) w.write("#define __riscv_q 2002000\n")!;
	if (has_q)
	{
		w.write("#define __riscv_flen 128\n")!;
	}
	else if (has_d)
	{
		w.write("#define __riscv_flen 64\n")!;
	}
	else if (has_f)
	{
		w.write("#define __riscv_flen 32\n")!;
	}
	io::fprintf(w, "#define __riscv_float_abi_%s 1\n", riscv_float_abi(t).name)!;
}


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
fn void? write_target_os_macros(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	OsTag os = t.os.tag;
	// Windows
	define_bool(w, "TARGET_OS_WIN32", os == WINDOWS)!;
	define_bool(w, "TARGET_OS_WINDOWS", os == WINDOWS)!;
	// Linux
	define_bool(w, "TARGET_OS_LINUX", os == LINUX)!;
	// Unix
	define_bool(w, "TARGET_OS_UNIX", os == FREEBSD || os == OPENBSD || os == NETBSD || os == ILLUMOS)!;
	// Apple Targets
	define_bool(w, "TARGET_OS_MAC", os.is_darwin())!;
	define_bool(w, "TARGET_OS_OSX", os == MACOS)!;
	define_bool(w, "TARGET_OS_IPHONE", os == IOS || os == TVOS || os == WATCHOS)!;
	define_bool(w, "TARGET_OS_IOS", os == IOS)!;
	define_bool(w, "TARGET_OS_TV", os == TVOS)!;
	define_bool(w, "TARGET_OS_WATCH", os == WATCHOS)!;
	define_bool(w, "TARGET_OS_VISION", os == VISIONOS)!;
	define_bool(w, "TARGET_OS_DRIVERKIT", os == DRIVERKIT)!;
	define_bool(w, "TARGET_OS_MACCATALYST", os == MACCATALYST)!;
	define_bool(w, "TARGET_OS_SIMULATOR", t.abi == SIMULATOR)!;
	bool embedded_os = os == IOS || os == TVOS || os == VISIONOS || os == WATCHOS;
	define_bool(w, "TARGET_OS_EMBEDDED", embedded_os && t.abi != SIMULATOR)!;
	define_bool(w, "TARGET_OS_NANO", os == WATCHOS)!;
	define_bool(w, "TARGET_IPHONE_SIMULATOR", t.abi == SIMULATOR)!;
	define_bool(w, "TARGET_OS_UIKITFORMAC", os == MACCATALYST)!;
	// UEFI
	define_bool(w, "TARGET_OS_UEFI", os == UEFI)!;
}



// Windows, Darwin, and x86/x86_64 macro writers.
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
fn void? write_windows_os_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	ushort ptr_width = t.ptr_bit_width();
	define(w, "_WIN32")!;
	if (ptr_width == 64) define(w, "_WIN64")!;

	if (t.abi.is_gnu())
	{
		define_std(w, "WIN32", is_gnu)!;
		define_std(w, "WINNT", is_gnu)!;
		if (ptr_width == 64)
		{
			define_std(w, "WIN64", is_gnu)!;
			define(w, "__MINGW64__")!;
		}
		else
		{
			define(w, "_X86_")!;
		}
		define(w, "__MSVCRT__")!;
		define(w, "__MINGW32__")!;
	}

	if (t.abi.is_gnu())
	{
		// MinGW and Cygwin define __declspec(a) to __attribute((a)).
		// Like Clang we make the define no op if -fdeclspec is enabled.
		if (comp.langopts.declspec_attrs)
		{
			w.write("#define __declspec __declspec\n")!;
		}
		else
		{
			w.write("#define __declspec(a) __attribute__((a))\n")!;
		}
		if (!comp.langopts.ms_extensions)
		{
			// Provide aliases for the calling convention keywords.
			foreach (keyword : CALLING_CONVENTION_KEYWORDS)
			{
				io::fprintf(w, "#define _%s __attribute__((__%s__))\n", keyword, keyword)!;
				io::fprintf(w, "#define __%s __attribute__((__%s__))\n", keyword, keyword)!;
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
fn void? write_darwin_os_defines(Compilation* comp, OutStream w)
{
	Target* t = &comp.target;
	define(w, "__APPLE__")!;
	w.write("#define __APPLE_CC__ 6000\n")!;

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
			io::fprintf(w, "#define %s %d%d%d\n", name, version.major, minor, patch)!;
		}
		else
		{
			io::fprintf(w, "#define %s %02d%02d%02d\n", name, version.major, minor, patch)!;
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
fn void? write_x86_defines(Compilation* comp, OutStream w, bool is_gnu)
{
	Target* t = &comp.target;
	io::fprintf(w, "#define __code_model_%s__ 1\n", comp.cmodel.macro_name())!;

	bool is_msvc_windows = t.os.tag == WINDOWS && t.abi == MSVC;
	if (t.cpu.arch == X86_64)
	{
		define(w, "__amd64__")!;
		define(w, "__amd64")!;
		define(w, "__x86_64__")!;
		define(w, "__x86_64")!;

		if (is_msvc_windows) w.write("#define _M_X64 100\n#define _M_AMD64 100\n")!;
	}
	else
	{
		define_std(w, "i386", is_gnu)!;

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
			define_int(w, "_M_IX86", level)!;
		}
	}
	define(w, "__SEG_GS")!;
	define(w, "__SEG_FS")!;
	w.write("#define __seg_gs __attribute__((address_space(256)))\n#define __seg_fs __attribute__((address_space(257)))\n")!;

	if (t.cpu.has(X86_SAHF) || (comp.langopts.emulate == CLANG && t.cpu.arch == X86))
	{
		define(w, "__LAHF_SAHF__")!;
	}

	foreach (fm : X86_FEATURE_MACROS)
	{
		if (t.cpu.has(fm.feature)) define(w, fm.macro_name)!;
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
		define_value(w, "_M_IX86_FP", level)!;
	}

	if (t.cpu.has_all(&APX_F_FEATURES)) define(w, "__APX_F__")!;

	// Zig keeps __APX_INLINE_ASM_USE_GPR32__ (egpr + inline_asm_use_gpr32) commented out.

	if (t.cpu.has(X86_CX8)) define(w, "__GCC_HAVE_SYNC_COMPARE_AND_SWAP_8")!;
	// sic: Zig defines _8 (not _16) again for cx16.
	if (t.cpu.has(X86_CX16) && t.cpu.arch == X86_64) define(w, "__GCC_HAVE_SYNC_COMPARE_AND_SWAP_8")!;

	if (t.has_float128()) w.write("#define __SIZEOF_FLOAT128__ 16\n")!;
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
