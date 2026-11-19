// Reusable command-line state derived from src/aro/Driver.zig and
// src/aro/Toolchain.zig. Strings in this structure are borrowed from argv.
module aro::driver_options;
import std::collections::list;
import aro::compilation;
import aro::lang_opts;

enum ParseAction : char
{
	CONTINUE, HELP, VERSION
}

enum PicRequest : char
{
	DEFAULT, PIC, PIC_LARGE, PIE, PIE_LARGE, NO_PIC
}

enum ParseEffectKind : char
{
	DEFINE, UNDEFINE
}

enum WarningMode : char
{
	WARNING, OFF, ERROR
}

struct ParseEffect
{
	ParseEffectKind kind; String value;
}

<* A named warning-policy change. Entries stay in argv order so later setup
 can replay source-style -W options with their command-line precedence. *>
struct WarningPolicy
{
	String name; WarningMode mode;
}

struct DriverOptions
{
	Allocator a;
	ParseAction action;
	List{String} inputs;
	List{String} link_objects;
	List{String} lib_dirs;
	List{usz} input_link_slots;
	List{String} owned_link_args;
	List{String} defines;
	List{String} undefs;
	<* Macro operations in command-line order, for the preprocessor setup stage. *>
	List{ParseEffect} macro_effects;
	<* Named warning changes in command-line order; names are borrowed from argv. *>
	List{WarningPolicy} warning_policies;
	List{IncludeDir} includes;
	List{String} embed_dirs;
	String output_name;
	bool has_output_name;
	String target_triple;
	bool has_target_triple;
	String darwin_variant_triple;
	bool has_darwin_variant_triple;
	String cpu;
	bool has_cpu;
	String standard;
	bool has_standard;
	lang_opts::Compiler emulate;
	bool has_emulate;
	String gnuc_version;
	bool has_gnuc_version;
	uint macro_backtrace_limit;
	bool has_macro_backtrace_limit;
	bool short_enums;
	bool has_short_enums;
	bool ms_extensions;
	bool has_ms_extensions;
	bool declspec_attrs;
	bool has_declspec_attrs;
	bool dollars_in_identifiers;
	bool has_dollars_in_identifiers;
	bool digraphs;
	bool has_digraphs;
	bool gnu_asm;
	bool has_gnu_asm;
	lang_opts::Signedness char_signedness;
	bool has_char_signedness;
	lang_opts::FPEvalMethod fp_eval_method;
	bool has_fp_eval_method;
	lang_opts::BoundsSafety bounds_safety;
	bool has_bounds_safety;
	lang_opts::Tristate char8_t_override;
	bool has_char8_t_override;
	lang_opts::Visibility visibility;
	bool has_visibility;
	bool use_native_half_type;
	bool allow_half_args_returns;
	bool has_blocks;
	bool blocks;
	bool pthread;
	bool hosted;
	bool has_hosted;
	String optimization;
	bool has_optimization;
	<* Force whole-program IR generation regardless of optimization level. *>
	bool whole_program;
	<* Prefer the in-process IR object emitter over the external assembler. *>
	bool integrated_as;
	<* -f[no-]integrated-as was given; otherwise the target picks (on for x86_64 Linux). *>
	bool has_integrated_as;
	String code_model;
	bool has_code_model;
	String debug_format;
	bool has_debug_format;
	uint dwarf_version;
	bool has_dwarf_version;
	PicRequest pic;
	String pic_arg;
	bool only_preprocess;
	bool only_syntax;
	bool only_compile;
	bool only_preprocess_and_compile;
	bool no_system_defines;
	bool preserve_comments;
	bool preserve_comments_in_macros;
	bool line_commands;
	bool use_line_directives;
	bool verbose_ast;
	bool verbose_pp;
	bool verbose_ir;
	<* Run the internal IR verifier before dumping or rendering IR. *>
	bool verify_ir;
	bool codegen_todo_report;
	bool x86_64_spill_all;
	bool verbose_linker_args;
	bool apple_kext;
	bool common;
	bool kernel;
	bool has_mabicalls;
	bool mabicalls;
	bool dynamic_nopic;
	bool ropi;
	bool rwpi;
	bool nobuiltininc;
	bool nostdinc;
	bool nostdlibinc;
	bool no_standard_libraries;
	bool nodefaultlibs;
	bool nolibc;
	bool nostartfiles;
	bool nostdlib;
	bool shared;
	bool static_link;
	bool shared_libgcc;
	bool static_libgcc;
	bool static_pie;
	bool rdynamic;
	bool strip;
	bool has_use_linker;
	String use_linker;
	bool has_linker_path;
	String linker_path;
	bool has_rtlib;
	String rtlib;
	bool has_unwindlib;
	String unwindlib;
	bool has_pie;
	bool pie;
	bool relocatable;
	bool has_sysroot;
	String sysroot;
	bool has_resource_dir;
	String resource_dir;
	bool warnings_as_errors;
	bool ignore_warnings;
	bool dependency_only;
	bool write_dependencies;
	bool dependency_nmake;
	bool has_dependency_file;
	String dependency_file;
}

fn void DriverOptions.init(&self, Allocator a)
{
	*self = { .a = a, .action = CONTINUE, .pic = DEFAULT, .line_commands = true };
	self.inputs.init(a);
	self.link_objects.init(a);
	self.lib_dirs.init(a);
	self.input_link_slots.init(a);
	self.owned_link_args.init(a);
	self.defines.init(a);
	self.undefs.init(a);
	self.macro_effects.init(a);
	self.warning_policies.init(a);
	self.includes.init(a);
	self.embed_dirs.init(a);
}

fn void DriverOptions.free(&self)
{
	foreach (arg : self.owned_link_args) alloc::free(self.a, arg.ptr);
	self.inputs.free(); self.link_objects.free(); self.lib_dirs.free();
	self.input_link_slots.free(); self.owned_link_args.free(); self.defines.free();
	self.undefs.free(); self.includes.free(); self.embed_dirs.free(); self.macro_effects.free();
	self.warning_policies.free();
	*self = {};
}
