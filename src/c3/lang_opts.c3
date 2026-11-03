// Port of src/aro/LangOpts.zig: language standard, emulated compiler and the
// option flags the tokenizer and later stages read.
//
// Deviations from Zig:
// - C3 struct fields have no default values. Start from `lang_opts::DEFAULT`
//   (Zig's `.{}`), never from a zero-initialized LangOpts.
// - Zig `?T` option fields become a `T` plus a `has_*` flag (or `Tristate`).
// - `setTargetOptions` is `set_target_options` (needs aro::target).
module aro::lang_opts;
import aro::char_info, aro::target;

faultdef INVALID_STANDARD;

enum Compiler : char
{
	CLANG,
	GCC,
	MSVC,
	NO,
}

fn uint Compiler.default_gcc_version(self)
{
	switch (self)
	{
		case CLANG: return 4 * 10_000 + 2 * 100 + 1;
		case NO:
		case GCC: return 7 * 10_000 + 1 * 100 + 0;
		case MSVC: return 0;
	}
}

enum BoundsSafety : char
{
	NONE,
	CLANG,
}

<* The floating-point evaluation method for intermediate results within a single expression. `value` is Zig's i8 tag. *>
enum FPEvalMethod : char (ichar value)
{
	<* The evaluation method cannot be determined or is inconsistent for this target. *>
	INDETERMINATE { -1 },
	<* Use the type declared in the source *>
	SOURCE { 0 },
	<* Use double for all float expressions narrower than double. *>
	DOUBLE { 1 },
	<* Use long double for all float expressions narrower than long double. *>
	EXTENDED { 2 },
}

enum Signedness : char
{
	SIGNED,
	UNSIGNED,
}

<* Attribute.Args.Visibility (attributes are ported later). *>
enum Visibility : char
{
	DEFAULT,
	HIDDEN,
	PROTECTED,
}

<* A Zig `?bool` field. *>
enum Tristate : char
{
	UNSET,
	OFF,
	ON,
}

<* Declaration order matters: `at_least` compares ordinals like Zig's backing ints. *>
enum Standard : char
{
	C89,      // ISO C 1990
	ISO9899,  // ISO C 1990 with amendment 1
	GNU89,    // ISO C 1990 with GNU extensions
	C99,      // ISO C 1999
	GNU99,    // ISO C 1999 with GNU extensions
	C11,      // ISO C 2011
	GNU11,    // ISO C 2011 with GNU extensions
	C17,      // ISO C 2017
	DEFAULT,  // default: GNU keywords on top of C17, without suppressing GNU-extension warnings
	GNU17,    // ISO C 2017 with GNU extensions
	C23,      // ISO C 2023
	GNU23,    // ISO C 2023 with GNU extensions
	C2Y,      // Working Draft for ISO C2Y
	GNU2Y,    // Working Draft for ISO C2Y with GNU extensions
}

struct StandardName @private
{
	String name;
	Standard standard;
}

const StandardName[*] STANDARD_NAMES @private = {
	{ "c89", C89 }, { "c90", C89 }, { "iso9899:1990", C89 },
	{ "iso9899:199409", ISO9899 }, { "gnu89", GNU89 }, { "gnu90", GNU89 },
	{ "c99", C99 }, { "iso9899:1999", C99 }, { "c9x", C99 },
	{ "iso9899:199x", C99 }, { "gnu99", GNU99 }, { "gnu9x", GNU99 },
	{ "c11", C11 }, { "iso9899:2011", C11 }, { "c1x", C11 },
	{ "iso9899:201x", C11 }, { "gnu11", GNU11 }, { "c17", C17 },
	{ "iso9899:2017", C17 }, { "c18", C17 }, { "iso9899:2018", C17 },
	{ "gnu17", GNU17 }, { "gnu18", GNU17 }, { "c23", C23 },
	{ "iso9899:2024", C23 }, { "gnu23", GNU23 }, { "c2x", C23 },
	{ "gnu2x", GNU23 }, { "c2y", C2Y }, { "gnu2y", GNU23 },
};

<* Standard.NameMap lookup. *>
fn Standard? standard_from_name(String name)
{
	foreach (entry : STANDARD_NAMES)
	{
		if (entry.name == name) return entry.standard;
	}
	return INVALID_STANDARD~;
}

fn bool Standard.at_least(self, Standard other) => self.ordinal >= other.ordinal;

fn bool Standard.is_gnu(self)
{
	switch (self)
	{
		case GNU89:
		case GNU99:
		case GNU11:
		case DEFAULT:
		case GNU17:
		case GNU23:
		case GNU2Y:
			return true;
		default:
			return false;
	}
}

fn bool Standard.is_explicit_gnu(self) => self.is_gnu() && self != DEFAULT;

<* Value reported by the __STDC_VERSION__ macro; "" where Zig returns null. *>
fn String Standard.std_c_version_macro(self)
{
	switch (self)
	{
		case C89:
		case GNU89: return "";
		case ISO9899: return "199409L";
		case C99:
		case GNU99: return "199901L";
		case C11:
		case GNU11: return "201112L";
		case DEFAULT:
		case C17:
		case GNU17: return "201710L";
		case C23:
		case GNU23: return "202311L";
		case C2Y:
		case GNU2Y: return "202400L";
	}
}

<*
 @require codepoint > 0x7F
*>
fn bool Standard.codepoint_allowed_in_identifier(self, uint codepoint, bool is_start)
{
	if (is_start)
	{
		if (self.at_least(C23)) return char_info::is_xid_start(codepoint);
		if (self.at_least(C11))
		{
			return char_info::is_c11_id_char(codepoint) && !char_info::is_c11_disallowed_initial_id_char(codepoint);
		}
		return char_info::is_c99_id_char(codepoint) && !char_info::is_c99_disallowed_initial_id_char(codepoint);
	}
	if (self.at_least(C23)) return char_info::is_xid_continue(codepoint);
	if (self.at_least(C11)) return char_info::is_c11_id_char(codepoint);
	return char_info::is_c99_id_char(codepoint);
}

<* Zig's `packed struct(u4)`; the bit value is `(char)ldrex`. *>
bitstruct ArmLdrex : char
{
	bool b : 0; // byte (8-bit)
	bool h : 1; // half (16-bit)
	bool w : 2; // word (32-bit)
	bool d : 3; // double (64-bit)
}

const char ARM_LDREX_B_INT = 1;
const char ARM_LDREX_H_INT = 2;
const char ARM_LDREX_W_INT = 4;
const char ARM_LDREX_D_INT = 8;
const ArmLdrex ARM_LDREX_NONE = {};
const ArmLdrex ARM_LDREX_ALL = { .b = true, .h = true, .w = true, .d = true };

struct LangOpts
{
	Compiler emulate;
	Standard standard;
	<* -fshort-enums: enums only take up as much space as they need to hold all the values. *>
	bool short_enums;
	bool dollars_in_identifiers;
	bool declspec_attrs;
	bool ms_extensions;
	<* Explicit -fdigraphs / -fno-digraphs, or UNSET. *>
	Tristate digraphs;
	<* Use the native half type instead of promoting to float. *>
	bool use_native_half_type;
	<* Function arguments and return values may be __fp16 even without a standard ABI for it. *>
	bool allow_half_args_and_returns;
	<* If false the user did not select a value; use the target to determine the default. *>
	bool has_fp_eval_method;
	FPEvalMethod fp_eval_method;
	<* If set, use `char_signedness` instead of the target's default char signedness. *>
	bool has_char_signedness_override;
	Signedness char_signedness_override;
	<* Override the default availability of char8_t (enabled in C23 and later). *>
	Tristate has_char8_t_override;
	<* Whether to allow GNU-style inline assembly. *>
	bool gnu_asm;
	<* Preserve comments when preprocessing. *>
	bool preserve_comments;
	<* Preserve comments in macros when preprocessing. *>
	bool preserve_comments_in_macros;
	<*
	 Used ONLY for generating __GNUC__ and related macros; major * 10,000 + minor * 100 + patch.
	 Only meaningful when `has_gnuc_version` is set.
	*>
	bool has_gnuc_version;
	uint gnuc_version;
	BoundsSafety bounds_safety;
	Visibility default_symbol_visibility;
	bool blocks;
	<* ARM LDREX/STREX mask, only populated on ARM targets (`has_arm_ldrex`). *>
	bool has_arm_ldrex;
	ArmLdrex arm_ldrex;
	<* Whether the target supports AVR's non-standard 24-bit integer types. *>
	bool has_int24;
	bool pthread;
}

<* Zig's `LangOpts{}` defaults. *>
const LangOpts DEFAULT = {
	.emulate = NO,
	.standard = Standard.DEFAULT,
	.dollars_in_identifiers = true,
	.digraphs = UNSET,
	.fp_eval_method = SOURCE,
	.has_char8_t_override = UNSET,
	.gnu_asm = true,
	.bounds_safety = NONE,
	.default_symbol_visibility = Visibility.DEFAULT,
};

fn void? LangOpts.set_standard(&self, String name)
{
	self.standard = standard_from_name(name)!;
}

fn void LangOpts.set_ms_extensions(&self, bool enabled)
{
	self.declspec_attrs = enabled;
	self.ms_extensions = enabled;
}

fn bool LangOpts.has_char8_t(&self)
{
	switch (self.has_char8_t_override)
	{
		case UNSET: return self.standard.at_least(C23);
		case OFF: return false;
		case ON: return true;
	}
}

fn bool LangOpts.has_digraphs(&self)
{
	switch (self.digraphs)
	{
		case UNSET: return self.standard.at_least(GNU89);
		case OFF: return false;
		case ON: return true;
	}
}

fn bool LangOpts.has_target_os_macros(&self) => self.emulate == NO || self.emulate == CLANG;

fn void LangOpts.set_emulated_compiler(&self, Compiler compiler)
{
	self.emulate = compiler;
	self.set_ms_extensions(compiler == MSVC);
}

fn void LangOpts.set_fp_eval_method(&self, FPEvalMethod method)
{
	self.has_fp_eval_method = true;
	self.fp_eval_method = method;
}

fn void LangOpts.set_char_signedness(&self, Signedness signedness)
{
	self.has_char_signedness_override = true;
	self.char_signedness_override = signedness;
}

fn bool LangOpts.allow_fixed_sized_int_suffixes(&self)
{
	switch (self.emulate)
	{
		case MSVC: return true;
		case CLANG:
		case NO: return self.ms_extensions;
		case GCC: return false;
	}
}

fn void LangOpts.set_target_options(&self, Target* t)
{
	// TODO: Move more stuff here :)
	self.has_int24 = t.cpu.arch == AVR;
	switch (t.cpu.arch)
	{
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB:
			// ARM exclusive load/store support.
			// See this: https://arm-software.github.io/acle/main/acle.html#ldrexstrex
			// These constants define masks containing data sizes are suitable for
			// __builtin_arm_ldrex and __builtin_arm_strex.
			char arm_version = 6;
			if (try v = t.arm_version()) arm_version = v.version;
			ArmLdrex ldrex;
			switch (arm_version)
			{
				case 6:
					if (t.cpu.has(ARM_MCLASS))
					{
						ldrex = ARM_LDREX_NONE;
					}
					else if (t.cpu.has(ARM_V6K) || t.cpu.has(ARM_V6KZ))
					{
						ldrex = ARM_LDREX_ALL;
					}
					else
					{
						ldrex = { .w = true };
					}
				case 7:
				case 8:
					ldrex = t.cpu.has(ARM_MCLASS) ? (ArmLdrex){ .b = true, .h = true, .w = true } : ARM_LDREX_ALL;
				case 9:
					ldrex = ARM_LDREX_ALL;
				default:
					ldrex = ARM_LDREX_NONE;
			}
			self.has_arm_ldrex = true;
			self.arm_ldrex = ldrex;
		case AARCH64:
		case AARCH64_BE:
			// ARM ldrex is always full-width
			self.has_arm_ldrex = true;
			self.arm_ldrex = ARM_LDREX_ALL;
		default:
			break;
	}
}
