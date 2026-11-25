// Port of src/aro/LangOpts.zig: language standard, emulated compiler and the
// option flags the tokenizer and later stages read.
//
// Deviations from Zig:
// - C3 struct fields have no default values. Start from `lang_opts::DEFAULT`
//   (Zig's `.{}`), never from a zero-initialized LangOpts.
// - Zig `?T` option fields become a `T` plus a `has_*` flag, or `Maybe{T}`.
// - `setTargetOptions` is gone: its target-derived fields (`has_int24`, `arm_ldrex`)
//   are `Target.has_int24()` / `Target.arm_ldrex()`, computed from the target.
module aro::frontend::c::lang_opts;
import aro::frontend::c::char_info, aro::target, aro::bigint;
import std::collections::maybe;

excuse INVALID_STANDARD;

enum BoundsSafety : char
{
	NONE,
	CLANG,
}



<* Attribute.Args.Visibility (attributes are ported later). *>
enum Visibility : char
{
	DEFAULT,
	HIDDEN,
	PROTECTED,
}

<*
 Declaration order matters: `at_least` compares ordinals like Zig's backing ints.
 `names` are the -std= spellings (Zig `Standard.NameMap`); `version_macro` is the
 __STDC_VERSION__ value, "" where Zig returns null.
*>
enum Standard : char (String[] names, bool is_gnu, String version_macro)
{
	C89 { { "c89", "c90", "iso9899:1990" }, false, "" },  // ISO C 1990
	ISO9899 { { "iso9899:199409" }, false, "199409L" },  // ISO C 1990 with amendment 1
	GNU89 { { "gnu89", "gnu90" }, true, "" },  // ISO C 1990 with GNU extensions
	C99 { { "c99", "iso9899:1999", "c9x", "iso9899:199x" }, false, "199901L" },  // ISO C 1999
	GNU99 { { "gnu99", "gnu9x" }, true, "199901L" },  // ISO C 1999 with GNU extensions
	C11 { { "c11", "iso9899:2011", "c1x", "iso9899:201x" }, false, "201112L" },  // ISO C 2011
	GNU11 { { "gnu11" }, true, "201112L" },  // ISO C 2011 with GNU extensions
	C17 { { "c17", "iso9899:2017", "c18", "iso9899:2018" }, false, "201710L" },  // ISO C 2017
	DEFAULT { {}, true, "201710L" },  // default: GNU keywords on top of C17, without suppressing GNU-extension warnings
	GNU17 { { "gnu17", "gnu18" }, true, "201710L" },  // ISO C 2017 with GNU extensions
	C23 { { "c23", "iso9899:2024", "c2x" }, false, "202311L" },  // ISO C 2023
	// "gnu2y" maps to GNU23 as in upstream Zig.
	GNU23 { { "gnu23", "gnu2x", "gnu2y" }, true, "202311L" },  // ISO C 2023 with GNU extensions
	C2Y { { "c2y" }, false, "202400L" },  // Working Draft for ISO C2Y
	GNU2Y { {}, true, "202400L" },  // Working Draft for ISO C2Y with GNU extensions
}

<* Standard.NameMap lookup. *>
fn Standard? standard_from_name(String name)
{
	foreach (standard : Standard::values)
	{
		foreach (n : standard.names)
		{
			if (n == name) return standard;
		}
	}
	return INVALID_STANDARD~;
}

fn bool Standard.at_least(self, Standard other) => self.ordinal >= other.ordinal;

fn bool Standard.is_explicit_gnu(self) => self.is_gnu && self != DEFAULT;

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

struct LangOpts
{
	Compiler emulate;
	Standard standard;
	<* -fshort-enums: enums only take up as much space as they need to hold all the values. *>
	bool short_enums;
	bool dollars_in_identifiers;
	bool declspec_attrs;
	bool ms_extensions;
	<* Explicit -fdigraphs / -fno-digraphs, or empty. *>
	Maybe{bool} digraphs;
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
	Maybe{bool} char8_t_override;
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
	bool pthread;
	<* `-fwrapv`: signed integer arithmetic wraps, so codegen sets no `nsw`. *>
	bool wrapv;
	<* `--scalar-vector-ext`: lower every GNU vector-extension operation lane by
	   lane in memory instead of as 128-bit SSE2 IR vector values. *>
	bool scalar_vector_ext;
}

<* Zig's `LangOpts{}` defaults. *>
const LangOpts DEFAULT = {
	.emulate = NO,
	.standard = Standard.DEFAULT,
	.dollars_in_identifiers = true,
	.fp_eval_method = SOURCE,
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

fn bool LangOpts.has_char8_t(&self) => self.char8_t_override.get() ?? self.standard.at_least(C23);

fn bool LangOpts.has_digraphs(&self) => self.digraphs.get() ?? self.standard.at_least(GNU89);

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

