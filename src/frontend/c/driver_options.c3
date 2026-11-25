// Reusable command-line state derived from src/aro/Driver.zig and
// src/aro/Toolchain.zig. Strings in this structure are borrowed from argv.
module aro::frontend::c::driver_options;
import aro::bigint, aro::target;
import std::collections::list, std::collections::maybe;
import aro::frontend::c::compilation;
import aro::frontend::c::lang_opts;

enum ParseAction : char
{
	CONTINUE, HELP, VERSION
}

enum PicRequest : char
{
	DEFAULT, PIC, PIC_LARGE, PIE, PIE_LARGE, NO_PIC
}

<* Debug info format requested by -g / -gdwarf* / -gcodeview / -g0. *>
enum DebugFormatRequest : char
{
	STRIP, DWARF32, DWARF64, CODE_VIEW
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
	<* `-x <lang>` in effect for the inputs that follow; "" means by extension (`-x none`). *>
	String input_language;
	<* `-m<feature>` / `-mno-<feature>` as `+name` / `-name`, appended to the `-mcpu` features. *>
	String cpu_feature_flags;
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
	Maybe{String} output_name;
	Maybe{String} target_triple;
	Maybe{String} darwin_variant_triple;
	Maybe{String} cpu;
	Maybe{String} standard;
	Maybe{target::Compiler} emulate;
	Maybe{String} gnuc_version;
	Maybe{uint} macro_backtrace_limit;
	Maybe{bool} short_enums;
	Maybe{bool} ms_extensions;
	Maybe{bool} declspec_attrs;
	Maybe{bool} dollars_in_identifiers;
	Maybe{bool} digraphs;
	Maybe{bool} gnu_asm;
	Maybe{bigint::Signedness} char_signedness;
	Maybe{target::FPEvalMethod} fp_eval_method;
	Maybe{lang_opts::BoundsSafety} bounds_safety;
	Maybe{bool} char8_t_override;
	Maybe{lang_opts::Visibility} visibility;
	bool use_native_half_type;
	bool allow_half_args_returns;
	Maybe{bool} blocks;
	<* `-fwrapv` / `-fno-strict-overflow`: signed integer overflow wraps. *>
	bool wrapv;
	<* `-fno-tree-vectorize` / `-fno-vectorize`. *>
	bool no_vectorize;
	bool pthread;
	Maybe{bool} hosted;
	Maybe{String} optimization;
	<* Force whole-program IR generation regardless of optimization level. *>
	bool whole_program;
	<* Prefer the in-process IR object emitter over the external assembler; empty: the target picks (on for x86_64 Linux). *>
	Maybe{bool} integrated_as;
	Maybe{String} code_model;
	Maybe{DebugFormatRequest} debug_format;
	Maybe{uint} dwarf_version;
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
	<* `--scalar-vector-ext`: see `LangOpts.scalar_vector_ext`. *>
	bool scalar_vector_ext;
	bool verbose_linker_args;
	bool apple_kext;
	bool common;
	bool kernel;
	Maybe{bool} mabicalls;
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
	Maybe{String} use_linker;
	Maybe{String} linker_path;
	Maybe{String} rtlib;
	Maybe{String} unwindlib;
	Maybe{bool} pie;
	bool relocatable;
	Maybe{String} sysroot;
	Maybe{String} resource_dir;
	bool warnings_as_errors;
	bool ignore_warnings;
	bool dependency_only;
	bool write_dependencies;
	bool dependency_nmake;
	Maybe{String} dependency_file;
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
