// Port of src/backend/CodeGenOptions.zig plus std.builtin.CodeModel (plan 14
// stage 0): the code generation options that predefined macros read
// (__OPTIMIZE__, __pic__/__PIE__, __ARM_ROPI/__ARM_RWPI, __code_model_*__).
// The Driver (plan 25) fills them; the backend (plans 26-29) reads the rest.
module aro::code_gen_options;

<* Zig `CodeGenOptions.PicLevel` (enum(u8)); `value` is the integer Zig prints with @backingInt. *>
enum PicLevel : char (char value)
{
	<* Do not generate position-independent code *>
	NONE { 0 },
	<* Generate position-independent code (PIC) suitable for use in a shared library, if supported for the target machine. *>
	ONE { 1 },
	<* If supported for the target machine, emit position-independent code, suitable for dynamic linking and avoiding any limit on the size of the global offset table. *>
	TWO { 2 },
}

<* Zig `CodeGenOptions.OptimizationLevel`; `name` is the -O spelling (Zig tag name). *>
enum OptimizationLevel : char (String name)
{
	O0 { "0" },
	O1 { "1" },
	O2 { "2" },
	O3 { "3" },
	<* Optimize for size *>
	S { "s" },
	<* Disregard strict standards compliance *>
	FAST { "fast" },
	<* Optimize debugging experience *>
	G { "g" },
	<* Optimize aggressively for size rather than speed *>
	Z { "z" },
}

excuse UNKNOWN_OPTIMIZATION_LEVEL;
excuse UNKNOWN_CODE_MODEL;

<*
 Zig `OptimizationLevel.fromString` (level_map lookup; null -> UNKNOWN_OPTIMIZATION_LEVEL).
 @return? UNKNOWN_OPTIMIZATION_LEVEL
*>
fn OptimizationLevel? optimization_level_from_string(String str)
{
	foreach (l : OptimizationLevel::values)
	{
		if (l.name == str) return l;
	}
	return UNKNOWN_OPTIMIZATION_LEVEL~;
}

<* Zig `isSizeOptimized`: s and z. *>
fn bool OptimizationLevel.is_size_optimized(self) => self == S || self == Z;

<* Zig `hasAnyOptimizations`: everything but 0. *>
fn bool OptimizationLevel.has_any_optimizations(self) => self != O0;

<* Zig `std.dwarf.Format`. *>
enum DwarfFormat : char
{
	FORMAT32,
	FORMAT64,
}

<* Tag of Zig `CodeGenOptions.DebugFormat` (union(enum) { strip, dwarf: std.dwarf.Format, code_view }). *>
enum DebugKind : char
{
	STRIP,
	DWARF,
	CODE_VIEW,
}

<* Zig `CodeGenOptions.DebugFormat`. `dwarf` is meaningful only when kind == DWARF. *>
struct DebugFormat
{
	DebugKind kind;
	DwarfFormat dwarf;
}

<* Zig `CodeGenOptions.DwarfVersion` (enum(u3)). *>
enum DwarfVersion : char (char value)
{
	V0 { 0 },
	V2 { 2 },
	V3 { 3 },
	V4 { 4 },
	V5 { 5 },
}

<* Zig `CodeGenOptions`. Start from `DEFAULT`. *>
struct CodeGenOptions
{
	<* place uninitialized global variables in a common block *>
	bool common;
	<* Place each function into its own section in the output file if the target supports arbitrary sections *>
	bool func_sections;
	<* Place each data item into its own section in the output file if the target supports arbitrary sections *>
	bool data_sections;
	PicLevel pic_level;
	<* Generate position-independent code that can only be linked into executables *>
	bool is_pie;
	OptimizationLevel optimization_level;
	<* Generate Read-Only and Read-Write Position Independent (ROPI/RWPI) code an ARM targets. This currently only emits macros for better clang compat. *>
	bool is_ropi;
	bool is_rwpi;
	<* Generate debug information *>
	DebugFormat debug;
	DwarfVersion dwarf_version;
}

<* Zig `CodeGenOptions.default`. *>
const CodeGenOptions DEFAULT = {
	.common = false,
	.func_sections = false,
	.data_sections = false,
	.pic_level = NONE,
	.is_pie = false,
	.is_ropi = false,
	.is_rwpi = false,
	.optimization_level = O0,
	.debug = { .kind = STRIP },
	.dwarf_version = V0,
};

<*
 Zig `std.builtin.CodeModel` (source-derived from Zig std knowledge; the
 pinned std is not available). `name` is the Zig tag name: what -mcmodel=
 accepts (std.meta.stringToEnum) and what @tagName prints in
 __code_model_<name>__ / __AARCH64_CMODEL_<NAME>__.
*>
enum CodeModel : char (String name)
{
	DEFAULT { "default" },
	EXTREME { "extreme" },
	KERNEL { "kernel" },
	LARGE { "large" },
	MEDANY { "medany" },
	MEDIUM { "medium" },
	MEDLOW { "medlow" },
	MEDMID { "medmid" },
	NORMAL { "normal" },
	SMALL { "small" },
	TINY { "tiny" },
}

<*
 Zig `std.meta.stringToEnum(std.builtin.CodeModel, name)`.
 @return? UNKNOWN_CODE_MODEL
*>
fn CodeModel? code_model_from_name(String name)
{
	foreach (m : CodeModel::values)
	{
		if (m.name == name) return m;
	}
	return UNKNOWN_CODE_MODEL~;
}

<* The name predefined macros use: DEFAULT prints as "small" (Compilation.zig `.default => "small"`). *>
fn String CodeModel.macro_name(self) => self == DEFAULT ? "small" : self.name;
