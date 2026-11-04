// Port of the predefined-macro half of src/aro/Compilation.zig (plan 14):
// generateBuiltinMacros, writeBuiltinMacros, generateSystemDefines and the
// int/float limit helpers.
//
// How the parts fit
// =================
// One module, `aro::predefined_macros`, over three files with one owner each
// (plan 14 "Parallel agent breakdown"):
//
//   predefined_macros.c3 (this file; 14.3 `builtin-macros`)
//       MacroWriter and SystemDefinesMode (stage 0, implemented),
//       generate_builtin_macros (stage 0, implemented glue),
//       generate_system_defines (stage 0, implemented: the section ORDER is
//       the contract), write_builtin_macros, write_compiler_defines,
//       write_common_defines and every int/float/type limit helper.
//   predefined_macros_x86.c3 (14.1 `sysdefs-a`)
//       TARGET_OS_* macros, Windows (MSVC/MinGW) and Darwin OS macros,
//       x86/x86_64 architecture macros.
//   predefined_macros_other.c3 (14.2 `sysdefs-b`)
//       pthread macros, every other OS (linux/BSD/wasi/...), unix/__ANDROID__,
//       ARM/AArch64/RISC-V/MIPS/PowerPC/SPARC/wasm/s390x/msp430/arc macros.
//
// Writer: Zig writes into an `Io.Writer.Allocating` that becomes the
// "<builtin>" source (addSourceFromOwnedBuffer, kind user) which
// Preprocessor.preprocess_sources consumes first. Here every section appends
// to a MacroWriter (a DString) and generate_builtin_macros moves its bytes
// into a gpa buffer owned by the Compilation. Section functions never fail
// (Zig's only errors are WriteFailed/OutOfMemory, and OOM panics in C3).
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
module aro::predefined_macros;
import aro, aro::compilation, aro::source, aro::target, aro::type_store, aro::lang_opts, aro::code_gen_options;
import std::core::string;

// ---------------------------------------------------------------------------
// Writer (stage 0, implemented)

<* Zig `Compilation.SystemDefinesMode`: which set of system defines generate_builtin_macros writes. *>
enum SystemDefinesMode : char
{
	<* Only define macros required by the C standard (date/time macros and those beginning with `__STDC`) *>
	NO_SYSTEM_DEFINES,
	<* Define the standard set of system macros *>
	INCLUDE_SYSTEM_DEFINES,
}

<*
 Zig `*Io.Writer` (an Io.Writer.Allocating) for predefined macros: an
 append-only byte buffer. Set up with `init`, released with `free`.
*>
struct MacroWriter
{
	DString out;
}

<* Zig `.initCapacity(comp.gpa, 2 << 13)`. *>
fn void MacroWriter.init(&self, Allocator allocator, sz capacity = 2 << 13)
{
	*self = {};
	self.out.init(allocator, capacity);
}

fn void MacroWriter.free(&self)
{
	self.out.free();
	*self = {};
}

<* Zig `w.writeAll(s)`. *>
fn void MacroWriter.write(&self, String s) => self.out.append_string(s);

<* Zig `w.writeByte(c)`. *>
fn void MacroWriter.write_byte(&self, char c) => self.out.append_char(c);

<* Zig `w.print(...)` with C3 format syntax (%s, %d, %x, %c). *>
fn void MacroWriter.printf(&self, String format, args...) @format(1)
{
	(void)self.out.appendf(format, ...args);
}

<* Bytes written so far (Zig `allocating.written()`); invalidated by the next write. *>
fn String MacroWriter.written(&self) => self.out.str_view();

fn sz MacroWriter.len(&self) => self.out.len();

<*
 Copy the written bytes into a new `allocator` buffer of len + 1 bytes with
 a trailing 0 (Zig `toOwnedSliceSentinel(0)`); the form
 Compilation.add_source_from_owned_buffer takes. The caller owns the result.
*>
fn char[] MacroWriter.to_owned_buffer(&self, Allocator allocator)
{
	String s = self.out.str_view();
	char* p = alloc::malloc(allocator, (usz)s.len + 1);
	if (s.len) mem::copy(p, s.ptr, s.len);
	p[s.len] = 0;
	return p[:s.len];
}

<* generateSystemDefines' `define`: "#define <name> 1\n". *>
fn void MacroWriter.define(&self, String name) => self.printf("#define %s 1\n", name);

<*
 generateSystemDefines' `defineStd`: in GNU modes "#define <name> 1\n", then
 always "#define __<name> 1\n#define __<name>__ 1\n".
*>
fn void MacroWriter.define_std(&self, String name, bool is_gnu)
{
	if (is_gnu) self.printf("#define %s 1\n", name);
	self.printf("#define __%s 1\n#define __%s__ 1\n", name, name);
}

<* generateSystemDefines' `defineBool`: "#define <name> 0\n" or "... 1\n". *>
fn void MacroWriter.define_bool(&self, String name, bool value) => self.printf("#define %s %d\n", name, value ? 1 : 0);

<* "#define <name> <value>\n" (any preformatted value text). *>
fn void MacroWriter.define_value(&self, String name, String value) => self.printf("#define %s %s\n", name, value);

<* "#define <name> <decimal value>\n" (Zig `{d}` of a signed integer). *>
fn void MacroWriter.define_int(&self, String name, long value) => self.printf("#define %s %d\n", name, value);

// ---------------------------------------------------------------------------
// Entry points

<*
 Zig `generateBuiltinMacros`: type_store::init_named_types, write every
 macro (write_builtin_macros) and add the bytes as source "<builtin>" (kind
 USER) owned by `comp`. More than 4 GiB of text is FILE_TOO_BIG.
 @return? compilation::FILE_TOO_BIG, compilation::FATAL_ERROR
*>
fn Source? generate_builtin_macros(Compilation* comp, SystemDefinesMode mode)
{
	type_store::init_named_types(comp);

	MacroWriter w;
	w.init(comp.gpa);
	defer w.free();

	write_builtin_macros(comp, mode, &w);

	if ((ulong)w.len() > 0xFFFF_FFFF) return compilation::FILE_TOO_BIG~;

	char[] contents = w.to_owned_buffer(comp.gpa);
	defer catch alloc::free(comp.gpa, contents.ptr);
	return comp.add_source_from_owned_buffer("<builtin>", contents, USER);
}

<*
 Zig `writeBuiltinMacros`. In order:
 - INCLUDE_SYSTEM_DEFINES: `#define __VERSION__ "Aro <aro::VERSION>"` and
   `#define __Aro__` (no value), each on its own line.
 - `#define __STDC__ 1` unless emulate == MSVC.
 - `#define __STDC_HOSTED__ <0 if os == FREESTANDING else 1>`.
 - __STDC_UTF_16__ 1, __STDC_UTF_32__ 1, __STDC_EMBED_NOT_FOUND__ 0,
   __STDC_EMBED_FOUND__ 1, __STDC_EMBED_EMPTY__ 2.
 - standard >= C11: openbsd/driverkit/ios/maccatalyst/macos/tvos/visionos/
   watchos -> __STDC_NO_THREADS__ 1; ps4/ps5 -> __STDC_NO_THREADS__ 1 and
   __STDC_NO_COMPLEX__ 1.
 - `#define __STDC_VERSION__ <standard.std_c_version_macro()>` unless that is "".
 - INCLUDE_SYSTEM_DEFINES: generate_system_defines.
 Implemented by 14.3.
*>
fn void write_builtin_macros(Compilation* comp, SystemDefinesMode mode, MacroWriter* w)
{
	if (mode == INCLUDE_SYSTEM_DEFINES)
	{
		w.printf("#define __VERSION__ \"Aro %s\"\n", aro::VERSION);
		w.write("#define __Aro__\n");
	}

	if (comp.langopts.emulate != MSVC) w.write("#define __STDC__ 1\n");
	w.printf("#define __STDC_HOSTED__ %d\n", comp.target.os.tag != FREESTANDING ? 1 : 0);

	// standard macros
	w.write("#define __STDC_UTF_16__ 1\n"
		"#define __STDC_UTF_32__ 1\n"
		"#define __STDC_EMBED_NOT_FOUND__ 0\n"
		"#define __STDC_EMBED_FOUND__ 1\n"
		"#define __STDC_EMBED_EMPTY__ 2\n");
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
				w.write("#define __STDC_NO_THREADS__ 1\n");
			case PS4:
			case PS5:
				w.write("#define __STDC_NO_THREADS__ 1\n#define __STDC_NO_COMPLEX__ 1\n");
			default: break;
		}
	}
	String stdc_version = comp.langopts.standard.std_c_version_macro();
	if (stdc_version.len)
	{
		w.write("#define __STDC_VERSION__ ");
		w.write(stdc_version);
		w.write_byte('\n');
	}

	if (mode == INCLUDE_SYSTEM_DEFINES) generate_system_defines(comp, w);
}

<*
 Zig `generateSystemDefines`, split into sections owned by 14.1/14.2/14.3.
 Implemented in stage 0 because the call order is the contract (see the
 file header); the sections themselves are stubs.
*>
fn void generate_system_defines(Compilation* comp, MacroWriter* w)
{
	Target* t = &comp.target;
	bool is_gnu = comp.langopts.standard.is_gnu();

	write_compiler_defines(comp, w);
	write_pthread_defines(comp, w);
	if (comp.langopts.has_target_os_macros()) write_target_os_macros(comp, w);

	// os macros
	if (t.os.tag == WINDOWS)
	{
		write_windows_os_defines(comp, w, is_gnu);
	}
	else if (t.os.tag.is_darwin())
	{
		write_darwin_os_defines(comp, w);
	}
	else
	{
		write_other_os_defines(comp, w, is_gnu);
	}
	// unix and other additional os macros
	write_unix_defines(comp, w, is_gnu);

	// architecture macros
	switch (t.cpu.arch)
	{
		case X86:
		case X86_64: write_x86_defines(comp, w, is_gnu);
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL: write_mips_defines(comp, w, is_gnu);
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE: write_powerpc_defines(comp, w);
		case SPARC:
		case SPARC64: write_sparc_defines(comp, w, is_gnu);
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: write_arm_defines(comp, w);
		case AARCH64:
		case AARCH64_BE: write_aarch64_defines(comp, w);
		case MSP430:
		case ARC: write_msp430_arc_defines(comp, w);
		case WASM32:
		case WASM64: write_wasm_defines(comp, w);
		case S390X: write_s390x_defines(comp, w);
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: write_riscv_defines(comp, w);
		default: break;
	}

	write_common_defines(comp, w);
}

// ---------------------------------------------------------------------------
// Sections owned by 14.3 `builtin-macros`

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
fn void write_compiler_defines(Compilation* comp, MacroWriter* w)
{
	LangOpts* lo = &comp.langopts;
	uint gnuc_version = lo.has_gnuc_version ? lo.gnuc_version : lo.emulate.default_gcc_version();
	if (gnuc_version > 0)
	{
		w.printf("#define __GNUC__ %d\n", gnuc_version / 10_000);
		w.printf("#define __GNUC_MINOR__ %d\n", (gnuc_version / 100) % 100);
		w.printf("#define __GNUC_PATCHLEVEL__ %d\n", gnuc_version % 100);
	}

	w.write("#define __ARO_EMULATE_NO__ 0\n"
		"#define __ARO_EMULATE_CLANG__ 1\n"
		"#define __ARO_EMULATE_GCC__ 2\n"
		"#define __ARO_EMULATE_MSVC__ 3\n");
	String emulate_name;
	switch (lo.emulate)
	{
		case NO: emulate_name = "__ARO_EMULATE_NO__";
		case CLANG: emulate_name = "__ARO_EMULATE_CLANG__";
		case GCC: emulate_name = "__ARO_EMULATE_GCC__";
		case MSVC: emulate_name = "__ARO_EMULATE_MSVC__";
	}
	w.printf("#define __ARO_EMULATE__ %s\n", emulate_name);

	if (lo.emulate == MSVC)
	{
		w.write("#define _MSC_VER 1933\n");
		w.write("#define _MSC_FULL_VER 193300000\n");
	}

	// Defined for compatibility with clang.
	w.write("#define __building_module(x) 0\n");

	if (comp.code_gen_options.optimization_level.has_any_optimizations()) w.define("__OPTIMIZE__");
	if (comp.code_gen_options.optimization_level.is_size_optimized()) w.define("__OPTIMIZE_SIZE__");
}

<*
 The tail of generateSystemDefines, in Zig order: _LP64/__LP64__ (ptr 64,
 long 64, int 32) else _ILP32/__ILP32__ (ptr 32, long 32, int 32);
 __FLOAT128__ if has_float128; __ORDER_*_ENDIAN__ and __BYTE_ORDER__ +
 __LITTLE_ENDIAN__/__BIG_ENDIAN__; __ELF__ / __MACH__ by target.ofmt; Darwin
 __nonnull/__null_unspecified/__nullable; __ATOMIC_* orders and *_LOCK_FREE
 (1), __ATOMIC_CHAR8_T_LOCK_FREE if langopts.has_char8_t; __CHAR_UNSIGNED__,
 __WCHAR_UNSIGNED__, __WINT_UNSIGNED__, __CHAR_BIT__ 8; the int max/width
 list (BOOL width, SCHAR ... SIG_ATOMIC, __INT24_* when has_int24 with
 "LL"/"L" suffix chosen by int bits == 8); __BITINT_MAXWIDTH__ 65535;
 __SIZEOF_*__ (incl. __SIZEOF_INT128__ if has_int128); __INTPTR_TYPE__ ...
 __CHAR32_TYPE__ (note Zig passes `intptr` to __INTMAX/__UINTMAX
 generate_int_literal_macros: kept); exact width types; fast/least
 types; FLT16 (half_precision_type != NONE, ext "F16"), FLT ("F"), DBL
 (""), LDBL ("L") float macros; __FLT_EVAL_METHOD__ (langopts override else
 target default, printed as its integer value); __FLT_RADIX__ 2,
 __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__; __pic__/__PIC__ (and __pie__/__PIE__
 if is_pie) with pic_level.value unless NONE; __BLOCKS__ if langopts.blocks.

 Note: __SIZEOF_LONG_DOUBLE__ is sizeof(long double) = cTypeBitSize / 8, as
 in Zig (TypeStore Float.bits uses cTypeBitSize, not cTypeByteSize), so it is
 10 on x86/x86_64 targets whose long double is the 80-bit x87 type.
*>
fn void write_common_defines(Compilation* comp, MacroWriter* w)
{
	Target* target = &comp.target;
	TypeStore* ts = &comp.type_store;
	ushort ptr_width = target.ptr_bit_width();

	if (ptr_width == 64 && target.c_type_bit_size(LONG) == 64 && target.c_type_bit_size(INT) == 32)
	{
		w.define("_LP64");
		w.define("__LP64__");
	}
	else if (ptr_width == 32 && target.c_type_bit_size(LONG) == 32 && target.c_type_bit_size(INT) == 32)
	{
		w.define("_ILP32");
		w.define("__ILP32__");
	}

	if (target.has_float128()) w.define("__FLOAT128__");

	w.write("#define __ORDER_LITTLE_ENDIAN__ 1234\n"
		"#define __ORDER_BIG_ENDIAN__ 4321\n"
		"#define __ORDER_PDP_ENDIAN__ 3412\n");
	if (target.cpu.arch.endian() == LITTLE)
	{
		w.write("#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__\n#define __LITTLE_ENDIAN__ 1\n");
	}
	else
	{
		w.write("#define __BYTE_ORDER__ __ORDER_BIG_ENDIAN__\n#define __BIG_ENDIAN__ 1\n");
	}

	switch (target.ofmt)
	{
		case ELF: w.define("__ELF__");
		case MACHO: w.define("__MACH__");
		default: break;
	}

	if (target.os.tag.is_darwin())
	{
		w.write("#define __nonnull _Nonnull\n"
			"#define __null_unspecified _Null_unspecified\n"
			"#define __nullable _Nullable\n");
	}

	// atomics
	w.write("#define __ATOMIC_RELAXED 0\n"
		"#define __ATOMIC_CONSUME 1\n"
		"#define __ATOMIC_ACQUIRE 2\n"
		"#define __ATOMIC_RELEASE 3\n"
		"#define __ATOMIC_ACQ_REL 4\n"
		"#define __ATOMIC_SEQ_CST 5\n");

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
		"#define __ATOMIC_POINTER_LOCK_FREE 1\n");
	if (comp.langopts.has_char8_t()) w.write("#define __ATOMIC_CHAR8_T_LOCK_FREE 1\n");

	// types
	if (type_store::char_signedness(comp) == UNSIGNED) w.write("#define __CHAR_UNSIGNED__ 1\n");
	if (ts.wchar.signedness(comp) == UNSIGNED) w.write("#define __WCHAR_UNSIGNED__ 1\n");
	if (ts.wint.signedness(comp) == UNSIGNED) w.write("#define __WINT_UNSIGNED__ 1\n");
	w.write("#define __CHAR_BIT__ 8\n");

	// int maxs
	generate_int_width(comp, w, "BOOL", type_store::BOOL);
	generate_int_max_and_width(comp, w, "SCHAR", type_store::SCHAR);
	generate_int_max_and_width(comp, w, "SHRT", type_store::SHORT);
	generate_int_max_and_width(comp, w, "INT", type_store::INT);
	generate_int_max_and_width(comp, w, "LONG", type_store::LONG);
	generate_int_max_and_width(comp, w, "LONG_LONG", type_store::LONG_LONG);
	if (comp.langopts.has_int24)
	{
		bool int_is_8 = TypeInt.INT.bits(comp) == 8;
		w.printf("#define __INT24_MAX__ 8388607%s\n", int_is_8 ? "LL" : "L");
		w.write("#define __INT24_MIN__ (-__INT24_MAX__-1)\n");
		w.printf("#define __UINT24_MAX__ 16777215%s\n", int_is_8 ? "ULL" : "UL");
	}
	generate_int_max_and_width(comp, w, "WCHAR", ts.wchar);
	generate_int_min(comp, w, "WCHAR", ts.wchar);
	generate_int_max_and_width(comp, w, "WINT", ts.wint);
	generate_int_min(comp, w, "WINT", ts.wint);
	generate_int_max_and_width(comp, w, "INTMAX", ts.intmax);
	generate_int_max_and_width(comp, w, "SIZE", ts.size);
	generate_int_max_and_width(comp, w, "UINTMAX", ts.intmax.make_int_unsigned(comp));
	generate_int_max_and_width(comp, w, "PTRDIFF", ts.ptrdiff);
	generate_int_max_and_width(comp, w, "INTPTR", ts.intptr);
	generate_int_max_and_width(comp, w, "UINTPTR", ts.intptr.make_int_unsigned(comp));
	generate_int_max_and_width(comp, w, "SIG_ATOMIC", type_store::int_kind_qt(target.sig_atomic_type()));

	// int widths
	w.printf("#define __BITINT_MAXWIDTH__ %d\n", BIT_INT_MAX_BITS);

	// sizeof types
	generate_sizeof_type(comp, w, "__SIZEOF_FLOAT__", type_store::FLOAT);
	generate_sizeof_type(comp, w, "__SIZEOF_DOUBLE__", type_store::DOUBLE);
	generate_sizeof_type(comp, w, "__SIZEOF_LONG_DOUBLE__", type_store::LONG_DOUBLE);
	generate_sizeof_type(comp, w, "__SIZEOF_SHORT__", type_store::SHORT);
	generate_sizeof_type(comp, w, "__SIZEOF_INT__", type_store::INT);
	generate_sizeof_type(comp, w, "__SIZEOF_LONG__", type_store::LONG);
	generate_sizeof_type(comp, w, "__SIZEOF_LONG_LONG__", type_store::LONG_LONG);
	generate_sizeof_type(comp, w, "__SIZEOF_POINTER__", type_store::VOID_POINTER);
	generate_sizeof_type(comp, w, "__SIZEOF_PTRDIFF_T__", ts.ptrdiff);
	generate_sizeof_type(comp, w, "__SIZEOF_SIZE_T__", ts.size);
	generate_sizeof_type(comp, w, "__SIZEOF_WCHAR_T__", ts.wchar);
	generate_sizeof_type(comp, w, "__SIZEOF_WINT_T__", ts.wint);

	if (target.has_int128()) generate_sizeof_type(comp, w, "__SIZEOF_INT128__", type_store::INT128);

	// various int types
	generate_type_macro(comp, w, "__INTPTR_TYPE__", ts.intptr);
	generate_type_macro(comp, w, "__UINTPTR_TYPE__", ts.intptr.make_int_unsigned(comp));

	generate_type_macro(comp, w, "__INTMAX_TYPE__", ts.intmax);
	// Zig passes intptr (not intmax) here; kept for parity.
	generate_int_literal_macros(comp, "__INTMAX", w, ts.intptr);

	generate_type_macro(comp, w, "__UINTMAX_TYPE__", ts.intmax.make_int_unsigned(comp));
	generate_int_literal_macros(comp, "__UINTMAX", w, ts.intptr.make_int_unsigned(comp));

	generate_type_macro(comp, w, "__PTRDIFF_TYPE__", ts.ptrdiff);
	generate_type_macro(comp, w, "__SIZE_TYPE__", ts.size);
	generate_type_macro(comp, w, "__WCHAR_TYPE__", ts.wchar);
	generate_type_macro(comp, w, "__WINT_TYPE__", ts.wint);
	generate_type_macro(comp, w, "__CHAR16_TYPE__", ts.uint_least16_t);
	generate_type_macro(comp, w, "__CHAR32_TYPE__", ts.uint_least32_t);

	generate_exact_width_types(comp, w);
	generate_fast_and_least_width_types(comp, w);

	FPSemantics half = target::half_precision_type(target);
	if (half != NONE) generate_float_macros(w, "FLT16", half, "F16");
	generate_float_macros(w, "FLT", target::fp_semantics_for_type(FLOAT, target), "F");
	generate_float_macros(w, "DBL", target::fp_semantics_for_type(DOUBLE, target), "");
	generate_float_macros(w, "LDBL", target::fp_semantics_for_type(LONGDOUBLE, target), "L");

	// TODO (Zig): clang treats __FLT_EVAL_METHOD__ as a special-cased macro because evaluating it within a scope
	// where `#pragma clang fp eval_method(X)` has been called produces an error diagnostic.
	FPEvalMethod flt_eval_method = comp.langopts.has_fp_eval_method ? comp.langopts.fp_eval_method : target.default_fp_eval_method();
	w.printf("#define __FLT_EVAL_METHOD__ %d\n", (int)flt_eval_method.value);

	w.write("#define __FLT_RADIX__ 2\n#define __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__\n");

	PicLevel pic = comp.code_gen_options.pic_level;
	if (pic != NONE)
	{
		w.printf("#define __pic__ %d\n#define __PIC__ %d\n", pic.value, pic.value);
		if (comp.code_gen_options.is_pie)
		{
			w.printf("#define __pie__ %d\n#define __PIE__ %d\n", pic.value, pic.value);
		}
	}

	// Blocks
	if (comp.langopts.blocks) w.define("__BLOCKS__");
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
fn void generate_float_macros(MacroWriter* w, String prefix, FPSemantics semantics, String ext)
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

	w.printf("#define __%s_DENORM_MIN__ %s%s\n", prefix, l.denorm_min, ext);
	w.printf("#define __%s_HAS_DENORM__\n", prefix);
	w.printf("#define __%s_DIG__ %d\n", prefix, l.digits);
	w.printf("#define __%s_DECIMAL_DIG__ %d\n", prefix, l.decimal_digits);

	w.printf("#define __%s_EPSILON__ %s%s\n", prefix, l.epsilon, ext);
	w.printf("#define __%s_HAS_INFINITY__\n", prefix);
	w.printf("#define __%s_HAS_QUIET_NAN__\n", prefix);
	w.printf("#define __%s_MANT_DIG__ %d\n", prefix, l.mantissa_digits);

	w.printf("#define __%s_MAX_10_EXP__ %d\n", prefix, l.max_10_exp);
	w.printf("#define __%s_MAX_EXP__ %d\n", prefix, l.max_exp);
	w.printf("#define __%s_MAX__ %s%s\n", prefix, l.max, ext);

	w.printf("#define __%s_MIN_10_EXP__ (%d)\n", prefix, l.min_10_exp);
	w.printf("#define __%s_MIN_EXP__ (%d)\n", prefix, l.min_exp);
	w.printf("#define __%s_MIN__ %s%s\n", prefix, l.min, ext);
}

<* Zig `generateTypeMacro`: "#define <name> " + qt.print + "\n". *>
fn void generate_type_macro(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	w.printf("#define %s ", name);
	qt.print(comp, w.out);
	w.write_byte('\n');
}

<*
 Zig `generateIntMin`: unsigned -> "#define __<name>_MIN__ 0<suffix>",
 signed -> "#define __<name>_MIN__ (-__<name>_MAX__ - 1)".
*>
fn void generate_int_min(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	if (qt.signedness(comp) == UNSIGNED)
	{
		w.printf("#define __%s_MIN__ 0%s\n", name, qt.int_value_suffix(comp));
	}
	else
	{
		w.printf("#define __%s_MIN__ (-__%s_MAX__ - 1)\n", name, name);
	}
}

<*
 Zig `generateIntMax`: "#define __<name>_MAX__ <max><int_value_suffix>" where
 max is maxInt of the (un)signed integer of qt's bit size (8/16/32/64/128).
*>
fn void generate_int_max(Compilation* comp, MacroWriter* w, String name, QualType qt)
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
	w.printf("#define __%s_MAX__ %d%s\n", name, max, qt.int_value_suffix(comp));
}

<* Zig `generateIntWidth`: "#define __<name>_WIDTH__ <sizeof*8>". *>
fn void generate_int_width(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	w.printf("#define __%s_WIDTH__ %d\n", name, qt.sizeof(comp) * 8);
}

<* Zig `generateIntMaxAndWidth`: generate_int_max then generate_int_width. *>
fn void generate_int_max_and_width(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	generate_int_max(comp, w, name, qt);
	generate_int_width(comp, w, name, qt);
}

<* Zig `generateSizeofType`: "#define <name> <sizeof>". *>
fn void generate_sizeof_type(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	w.printf("#define %s %d\n", name, qt.sizeof(comp));
}

<*
 Zig `generateFmt`: for each of "ouxX" (unsigned) or "di" (signed):
 `#define <prefix>_FMT<c>__ "<format_modifier><c>"`.
*>
fn void generate_fmt(Compilation* comp, String prefix, MacroWriter* w, QualType qt)
{
	bool unsigned = qt.signedness(comp) == UNSIGNED;
	String modifier = qt.format_modifier(comp);
	String formats = unsigned ? "ouxX" : "di";
	foreach (c : formats)
	{
		w.printf("#define %s_FMT%c__ \"%s%c\"\n", prefix, c, modifier, c);
	}
}

<*
 Zig `generateIntLiteralMacros`: "#define <prefix>_C_SUFFIX__ <suffix>" then
 "#define <prefix>_C(c) c" (empty suffix) or "#define <prefix>_C(c) c##<suffix>".
*>
fn void generate_int_literal_macros(Compilation* comp, String prefix, MacroWriter* w, QualType qt)
{
	String suffix = qt.int_value_suffix(comp);
	w.printf("#define %s_C_SUFFIX__ %s\n", prefix, suffix);
	if (suffix.len == 0)
	{
		w.printf("#define %s_C(c) c\n", prefix);
	}
	else
	{
		w.printf("#define %s_C(c) c##%s\n", prefix, suffix);
	}
}

<*
 Zig `generateExactWidthType`: __(U)INT<width>_TYPE__, its FMT macros and its
 literal macros. Width 16 / 64 types are replaced by type_store.int16 /
 int64 (made unsigned as needed).
*>
fn void generate_exact_width_type(Compilation* comp, MacroWriter* w, QualType original_qt) @local
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
	generate_type_macro(comp, w, string::tformat("%s_TYPE__", prefix), qt);
	generate_fmt(comp, prefix, w, qt);
	generate_int_literal_macros(comp, prefix, w, qt);
}

<* Zig `generateExactWidthIntMax`: __(U)INT<bits>_MAX__, with width 64 replaced by type_store.int64. *>
fn void generate_exact_width_int_max(Compilation* comp, MacroWriter* w, QualType original_qt) @local
{
	QualType qt = original_qt;
	ulong bit_count = qt.sizeof(comp) * 8;
	bool unsigned = qt.signedness(comp) == UNSIGNED;

	if (bit_count == 64)
	{
		qt = unsigned ? comp.type_store.int64.make_int_unsigned(comp) : comp.type_store.int64;
	}

	generate_int_max(comp, w, string::tformat("%s%d", unsigned ? "UINT" : "INT", bit_count), qt);
}

<*
 Zig `generateExactWidthTypes`: schar; short/int/long/long long when wider
 than the previous rank; uchar + UINT8/INT8 max; then the unsigned
 counterparts with their maxes under the same width conditions.
*>
fn void generate_exact_width_types(Compilation* comp, MacroWriter* w)
{
	generate_exact_width_type(comp, w, type_store::SCHAR);
	ushort char_bits = TypeInt.CHAR.bits(comp);
	ushort short_bits = TypeInt.SHORT.bits(comp);
	ushort int_bits = TypeInt.INT.bits(comp);
	ushort long_bits = TypeInt.LONG.bits(comp);
	ushort long_long_bits = TypeInt.LONG_LONG.bits(comp);

	if (short_bits > char_bits) generate_exact_width_type(comp, w, type_store::SHORT);
	if (int_bits > short_bits) generate_exact_width_type(comp, w, type_store::INT);
	if (long_bits > int_bits) generate_exact_width_type(comp, w, type_store::LONG);
	if (long_long_bits > long_bits) generate_exact_width_type(comp, w, type_store::LONG_LONG);

	generate_exact_width_type(comp, w, type_store::UCHAR);
	generate_exact_width_int_max(comp, w, type_store::UCHAR);
	generate_exact_width_int_max(comp, w, type_store::SCHAR);

	if (short_bits > char_bits)
	{
		generate_exact_width_type(comp, w, type_store::USHORT);
		generate_exact_width_int_max(comp, w, type_store::USHORT);
		generate_exact_width_int_max(comp, w, type_store::SHORT);
	}
	if (int_bits > short_bits)
	{
		generate_exact_width_type(comp, w, type_store::UINT);
		generate_exact_width_int_max(comp, w, type_store::UINT);
		generate_exact_width_int_max(comp, w, type_store::INT);
	}
	if (long_bits > int_bits)
	{
		generate_exact_width_type(comp, w, type_store::ULONG);
		generate_exact_width_int_max(comp, w, type_store::ULONG);
		generate_exact_width_int_max(comp, w, type_store::LONG);
	}
	if (long_long_bits > long_bits)
	{
		generate_exact_width_type(comp, w, type_store::ULONG_LONG);
		generate_exact_width_int_max(comp, w, type_store::ULONG_LONG);
		generate_exact_width_int_max(comp, w, type_store::LONG_LONG);
	}
}

<*
 Zig `generateFastOrLeastType`: __(U)INT_<LEAST|FAST><bits>_TYPE__ from
 type_store::int_least_n (fast types are defined as the least types); signed
 gets MAX+WIDTH, unsigned only MAX; then FMT.
*>
fn void generate_fast_or_least_type(Compilation* comp, ulong bits, bool fast, Signedness signedness, MacroWriter* w) @local
{
	QualType ty = type_store::int_least_n(comp, bits, signedness);
	String prefix = string::tformat("%s%s%d", signedness == SIGNED ? "INT_" : "UINT_", fast ? "FAST" : "LEAST", bits);
	generate_type_macro(comp, w, string::tformat("__%s_TYPE__", prefix), ty);
	if (signedness == SIGNED)
	{
		generate_int_max_and_width(comp, w, prefix, ty);
	}
	else
	{
		generate_int_max(comp, w, prefix, ty);
	}
	generate_fmt(comp, prefix, w, ty);
}

<*
 Zig `generateFastAndLeastWidthTypes`: for 8, 16, 32, 64: least signed,
 least unsigned, fast signed, fast unsigned.
*>
fn void generate_fast_and_least_width_types(Compilation* comp, MacroWriter* w)
{
	ulong[4] sizes = { 8, 16, 32, 64 };
	foreach (size : sizes)
	{
		generate_fast_or_least_type(comp, size, false, SIGNED, w);
		generate_fast_or_least_type(comp, size, false, UNSIGNED, w);
		generate_fast_or_least_type(comp, size, true, SIGNED, w);
		generate_fast_or_least_type(comp, size, true, UNSIGNED, w);
	}
}
