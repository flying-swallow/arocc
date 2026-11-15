// Owner: 12.4 lookup-props (contract frozen by plan 12 stage 0).
// Port of src/aro/Builtins/properties.zig plus the per-builtin record shape of
// Builtins.zig (BuiltinBase / BuiltinTarget) and the group/tag identity.
//
// Invariants (see tools/builtins_schema.md):
// - This file imports nothing but std. The generator binary //tools:generate_def
//   compiles it standalone (no aro_c3_lib), so the enum name tables below are
//   the single source of truth for both .def parsing and runtime lookup.
// - Enum ordinals, associated `name` strings and the Attributes bit layout are
//   part of the generated-table ABI: generated files reference them by C3
//   constant name (HEADER / LANGUAGE values) and by raw bits (Attributes).
//   Changing any of them requires regenerating, and the bit layout must keep
//   matching the Zig `packed struct` field order.
// - BuiltinGroup lists the 19 .def groups in Builtins.zig `Tag` order; its
//   ordinal is the `group` half of a BuiltinTag.
module aro::builtin_properties;

<* Header which must be included for a builtin to be available (properties.Header). name: Zig tag; file: the header. *>
enum Header : char (String name, String file)
{
	NONE      { "none", "" },
	STDIO     { "stdio", "stdio.h" },
	STDLIB    { "stdlib", "stdlib.h" },
	SETJMPEX  { "setjmpex", "setjmpex.h" },
	STDARG    { "stdarg", "stdarg.h" },
	STRING    { "string", "string.h" },
	CTYPE     { "ctype", "ctype.h" },
	WCHAR     { "wchar", "wchar.h" },
	SETJMP    { "setjmp", "setjmp.h" },
	MALLOC    { "malloc", "malloc.h" },
	STRINGS   { "strings", "strings.h" },
	UNISTD    { "unistd", "unistd.h" },
	PTHREAD   { "pthread", "pthread.h" },
	MATH      { "math", "math.h" },
	COMPLEX   { "complex", "complex.h" },
	BLOCKS    { "blocks", "Blocks.h" },
	INTRIN    { "intrin", "intrin.h" },
	IMMINTRIN { "immintrin", "immintrin.h" },
	XMMINTRIN { "xmmintrin", "xmmintrin.h" },
	EMMINTRIN { "emmintrin", "emmintrin.h" },
	MMINTRIN  { "mmintrin", "mmintrin.h" },
	ARM_ACLE  { "arm_acle", "arm_acle.h" },
	STDBIT    { "stdbit", "stdbit.h" },
}

<* Languages in which a builtin is available (properties.Language). name: Zig tag. *>
enum Language : char (String name)
{
	ALL_LANGUAGES     { "all_languages" },
	ALL_MS_LANGUAGES  { "all_ms_languages" },
	ALL_GNU_LANGUAGES { "all_gnu_languages" },
	GNU_LANG          { "gnu_lang" },
	C23_LANG          { "c23_lang" },
}

<* Attributes.format_kind (Zig `enum(u3)`). name: Zig tag. *>
enum FormatKind : char (String name)
{
	NONE    { "none" },    // does not take a format string
	PRINTF  { "printf" },  // printf-like; Nth argument is the format string
	VPRINTF { "vprintf" }, // like vprintf: arguments as a va_list
	SCANF   { "scanf" },   // scanf-like; Nth argument is the format string
	VSCANF  { "vscanf" },  // like vscanf: arguments as a va_list
}

<*
 properties.Attributes. Bit positions follow the Zig packed struct field
 order (LSB first). Zig `@"const"` is `is_const` here. The default value is
 ATTRIBUTES_DEFAULT (eval_args = true), not zero.
*>
bitstruct Attributes : uint
{
	bool noreturn : 0;                                 // does not return
	bool pure : 1;                                     // no side effects
	bool is_const : 2;                                 // no side effects, does not read memory
	bool custom_typecheck : 3;                         // signature is meaningless; custom typecheck
	bool allow_type_mismatch : 4;                      // declaration recognized even if the type mismatches
	bool lib_function_with_builtin_prefix : 5;         // libc/libm function with '__builtin_' prefix
	bool lib_function_without_prefix : 6;              // libc/libm function without the prefix (-fno-builtin-foo)
	bool returns_twice : 7;                            // e.g. setjmp
	FormatKind format_kind : 8..10;
	char format_string_position : 11..15;              // only meaningful if format_kind != NONE
	bool eval_args : 16;                               // if false, arguments are not evaluated
	bool const_without_errno_and_fp_exceptions : 17;
	bool const_without_fp_exceptions : 18;
	bool const_evaluable : 19;                         // can be constant evaluated by the frontend
}

const Attributes ATTRIBUTES_DEFAULT = { .eval_args = true };

<*
 Names of the Attributes fields as written in .def files (`.attributes = .{ .<name> = ... }`).
 kind: how the value is written: BOOL (`true`/`false`), FORMAT_KIND (`.printf`),
 POSITION (decimal 0..31).
*>
enum AttributeValueKind : char { BOOL, FORMAT_KIND, POSITION }

enum AttributeField : char (String name, AttributeValueKind kind)
{
	NORETURN                              { "noreturn", BOOL },
	PURE                                  { "pure", BOOL },
	CONST                                 { "const", BOOL },
	CUSTOM_TYPECHECK                      { "custom_typecheck", BOOL },
	ALLOW_TYPE_MISMATCH                   { "allow_type_mismatch", BOOL },
	LIB_FUNCTION_WITH_BUILTIN_PREFIX      { "lib_function_with_builtin_prefix", BOOL },
	LIB_FUNCTION_WITHOUT_PREFIX           { "lib_function_without_prefix", BOOL },
	RETURNS_TWICE                         { "returns_twice", BOOL },
	FORMAT_KIND                           { "format_kind", FORMAT_KIND },
	FORMAT_STRING_POSITION                { "format_string_position", POSITION },
	EVAL_ARGS                             { "eval_args", BOOL },
	CONST_WITHOUT_ERRNO_AND_FP_EXCEPTIONS { "const_without_errno_and_fp_exceptions", BOOL },
	CONST_WITHOUT_FP_EXCEPTIONS           { "const_without_fp_exceptions", BOOL },
	CONST_EVALUABLE                       { "const_evaluable", BOOL },
}

<*
 The 19 builtin groups, one per .def file, in Builtins.zig `Tag` order.
 def_name: the .def basename and generated module name
 (aro::builtin_defs::<def_name>). has_features: the group uses
 Zig BuiltinTarget (may carry `.features`); false for BuiltinBase groups,
 whose .def files must not contain `.features`.
*>
enum BuiltinGroup : char (String def_name, bool has_features)
{
	AARCH64      { "aarch64", true },
	AARCH64_NEON { "aarch64_neon", true },
	AMDGCN       { "amdgcn", true },
	ARM          { "arm", true },
	BPF          { "bpf", true },
	COMMON       { "common", false },
	HEXAGON      { "hexagon", true },
	LOONGARCH    { "loongarch", true },
	MIPS         { "mips", false },
	NEON         { "neon", true },
	NVPTX        { "nvptx", true },
	POWERPC      { "powerpc", true },
	RISCV        { "riscv", true },
	S390X        { "s390x", true },
	VE           { "ve", false },
	WASM         { "wasm", true },
	X86_64       { "x86_64", true },
	X86          { "x86", true },
	XCORE        { "xcore", false },
}

<*
 Builtins.Tag (a union of per-group enums). index is the per-group tag value:
 the builtin's rank in its group's bytewise-sorted name list, which equals the
 Zig DAFSA unique index minus one. Compare whole values with `==`; generated
 modules provide named constants (`common::TAG___BUILTIN_VA_START`).
*>
bitstruct BuiltinTag : uint
{
	ushort index : 0..15;
	BuiltinGroup group : 16..23;
}

<*
 One parsed .def entry minus its name (Zig BuiltinBase / BuiltinTarget).
 All strings are static (generated constants) or borrowed from the .def
 buffer inside the generator. features is "" when absent (Zig `null`); the
 .def files never spell an empty features string, so "" is unambiguous.
*>
struct BuiltinRecord
{
	String param_str;
	Language language;
	Header header;
	Attributes attributes;
	String features;
}

const BuiltinRecord RECORD_DEFAULT = { .param_str = "", .language = ALL_LANGUAGES, .header = NONE, .attributes = ATTRIBUTES_DEFAULT, .features = "" };

<* No enum value / group has the given name. *>
excuse UNKNOWN_NAME;

fn Header? header_from_name(String name)
{
	foreach (h : Header::values) if (h.name == name) return h;
	return UNKNOWN_NAME~;
}

fn Language? language_from_name(String name)
{
	foreach (l : Language::values) if (l.name == name) return l;
	return UNKNOWN_NAME~;
}

fn FormatKind? format_kind_from_name(String name)
{
	foreach (k : FormatKind::values) if (k.name == name) return k;
	return UNKNOWN_NAME~;
}

fn AttributeField? attribute_field_from_name(String name)
{
	foreach (f : AttributeField::values) if (f.name == name) return f;
	return UNKNOWN_NAME~;
}

fn BuiltinGroup? group_from_name(String name)
{
	foreach (g : BuiltinGroup::values) if (g.def_name == name) return g;
	return UNKNOWN_NAME~;
}

<*
 Sets one attribute field. `value` is 0/1 for BOOL fields, a FormatKind
 ordinal for FORMAT_KIND, 0..31 for POSITION.
 @require value <= 31
*>
fn Attributes Attributes.with_field(self, AttributeField f, uint value)
{
	Attributes a = self;
	bool b = value != 0;
	switch (f)
	{
		case NORETURN: a.noreturn = b;
		case PURE: a.pure = b;
		case CONST: a.is_const = b;
		case CUSTOM_TYPECHECK: a.custom_typecheck = b;
		case ALLOW_TYPE_MISMATCH: a.allow_type_mismatch = b;
		case LIB_FUNCTION_WITH_BUILTIN_PREFIX: a.lib_function_with_builtin_prefix = b;
		case LIB_FUNCTION_WITHOUT_PREFIX: a.lib_function_without_prefix = b;
		case RETURNS_TWICE: a.returns_twice = b;
		case FORMAT_KIND: a.format_kind = FormatKind::from_ordinal(value);
		case FORMAT_STRING_POSITION: a.format_string_position = (char)value;
		case EVAL_ARGS: a.eval_args = b;
		case CONST_WITHOUT_ERRNO_AND_FP_EXCEPTIONS: a.const_without_errno_and_fp_exceptions = b;
		case CONST_WITHOUT_FP_EXCEPTIONS: a.const_without_fp_exceptions = b;
		case CONST_EVALUABLE: a.const_evaluable = b;
	}
	return a;
}

<*
 properties.isVarArgs: the param string ends in '.'.
 @require param_str.len > 0
*>
fn bool is_var_args(String param_str) => param_str[^1] == '.';
