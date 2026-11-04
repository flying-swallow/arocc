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
import aro::compilation, aro::source, aro::target, aro::type_store, aro::lang_opts, aro::code_gen_options;

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
 OWNER: 14.3.
*>
fn void write_builtin_macros(Compilation* comp, SystemDefinesMode mode, MacroWriter* w)
{
	unreachable("stage 0 stub");
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
 OWNER: 14.3.
*>
fn void write_compiler_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
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
 generate_int_literal_macros: keep it); exact width types; fast/least
 types; FLT16 (half_precision_type != NONE, ext "F16"), FLT ("F"), DBL
 (""), LDBL ("L") float macros; __FLT_EVAL_METHOD__ (langopts override else
 target default, printed as its integer value); __FLT_RADIX__ 2,
 __DECIMAL_DIG__ __LDBL_DECIMAL_DIG__; __pic__/__PIC__ (and __pie__/__PIE__
 if is_pie) with pic_level.value unless NONE; __BLOCKS__ if langopts.blocks.
 OWNER: 14.3.
*>
fn void write_common_defines(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateFloatMacros(w, prefix, semantics, ext)`: the 15 __<prefix>_*__
 macros (DENORM_MIN, HAS_DENORM, DIG, DECIMAL_DIG, EPSILON, HAS_INFINITY,
 HAS_QUIET_NAN, MANT_DIG, MAX_10_EXP, MAX_EXP, MAX, MIN_10_EXP (in parens),
 MIN_EXP (in parens), MIN) in that order. Values come from Zig
 `FPSemantics.chooseValue` over (IEEE_HALF, IEEE_SINGLE, IEEE_DOUBLE,
 X87_EXTENDED_DOUBLE, IBM_EXTENDED_DOUBLE, IEEE_QUAD); any other semantics
 is unreachable. `ext` is appended to DENORM_MIN, EPSILON, MAX and MIN.
 OWNER: 14.3.
*>
fn void generate_float_macros(MacroWriter* w, String prefix, FPSemantics semantics, String ext)
{
	unreachable("stage 0 stub");
}

<* Zig `generateTypeMacro`: "#define <name> " + qt.print + "\n". OWNER: 14.3. *>
fn void generate_type_macro(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateIntMin`: unsigned -> "#define __<name>_MIN__ 0<suffix>",
 signed -> "#define __<name>_MIN__ (-__<name>_MAX__ - 1)". OWNER: 14.3.
*>
fn void generate_int_min(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateIntMax`: "#define __<name>_MAX__ <max><int_value_suffix>" where
 max is maxInt of the (un)signed integer of qt's bit size (8/16/32/64/128).
 OWNER: 14.3.
*>
fn void generate_int_max(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<* Zig `generateIntWidth`: "#define __<name>_WIDTH__ <sizeof*8>". OWNER: 14.3. *>
fn void generate_int_width(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<* Zig `generateIntMaxAndWidth`: generate_int_max then generate_int_width. OWNER: 14.3. *>
fn void generate_int_max_and_width(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<* Zig `generateSizeofType`: "#define <name> <sizeof>". OWNER: 14.3. *>
fn void generate_sizeof_type(Compilation* comp, MacroWriter* w, String name, QualType qt)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateFmt`: for each of "ouxX" (unsigned) or "di" (signed):
 `#define <prefix>_FMT<c>__ "<format_modifier><c>"`. OWNER: 14.3.
*>
fn void generate_fmt(Compilation* comp, String prefix, MacroWriter* w, QualType qt)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateIntLiteralMacros`: "#define <prefix>_C_SUFFIX__ <suffix>" then
 "#define <prefix>_C(c) c" (empty suffix) or "#define <prefix>_C(c) c##<suffix>".
 OWNER: 14.3.
*>
fn void generate_int_literal_macros(Compilation* comp, String prefix, MacroWriter* w, QualType qt)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateExactWidthTypes`: schar; short/int/long/long long when wider
 than the previous rank; uchar + UINT8/INT8 max; then the unsigned
 counterparts with their maxes under the same width conditions.
 Width 16 / 64 types are replaced by type_store.int16 / int64 (made
 unsigned as needed) as in Zig generateExactWidthType / generateExactWidthIntMax.
 OWNER: 14.3.
*>
fn void generate_exact_width_types(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}

<*
 Zig `generateFastAndLeastWidthTypes`: for 8, 16, 32, 64: least signed,
 least unsigned, fast signed, fast unsigned (generateFastOrLeastType with
 type_store::int_least_n; signed gets MAX+WIDTH, unsigned only MAX; then FMT).
 OWNER: 14.3.
*>
fn void generate_fast_and_least_width_types(Compilation* comp, MacroWriter* w)
{
	unreachable("stage 0 stub");
}
