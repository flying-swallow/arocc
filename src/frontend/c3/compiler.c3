// Global compiler state: the subset of c3c's CompilerState / GlobalContext /
// BuildTarget / PlatformTarget that the parser (and the early sema port)
// touches, with c3c field names, plus the pieces of c3c compiler.c
// (global_context_*, compiler_find_or_create_module, linking_add_link,
// scratch_buffer_interned*), source_file.c (source_file_by_id,
// source_file_text_load, source_file_generate) and the x86_64 Linux part of
// target.c `target_setup` that feed them.
//
// Deviations from c3c:
// - Only the fields used so far exist; add more (with the c3c name) as the
//   port needs them. The sema contract added every BuildTarget /
//   PlatformTarget / GlobalContext field the c3c sema files read (enums in
//   build_enums.c3, CompilerStats / PanicVariant in sema_structs.c3). Left out
//   for now: GlobalContext.ansi and the BuildTarget options only the
//   driver/codegen use. The `feature`, `win` and `x64` sub-structs are named
//   structs (BuildFeatures, BuildWin, PlatformX64).
// - PlatformTarget `int128` / `float128` / `float16` (type names in C3) are
//   `int128_supported` / `float128_supported` / `float16_supported`.
// - `target_setup` is reduced to `target_setup_x64_linux` (the values c3c
//   computes for x86_64-linux); a target-generic port comes later.
// - The c3c symtab and the error printer are globals here too:
//   `global_symtab` (symtab::Symtab) and `global_diagnostics`
//   (diagnostics::Diagnostics, TO_LIST by default). Every ERROR report bumps
//   `compiler.context.errors_found` through `Diagnostics.error_counter`, so
//   lexer errors count like c3c's `sema_verror_range` calls.
// - `exit_compiler` / `error_exit` abort (there is no longjmp recovery);
//   `exit_compiler` first calls `exit_hook` when set (check_probe exits the
//   process there).
// - `compiler_reset()` (tests) tears everything down and sets up a fresh
//   parse-ready state: symtab, core module, target and builtin types.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, aro::frontend::c3::symtab, aro::frontend::c3::diagnostics, aro::frontend::c3::lexer;
import std::core::mem::alloc;

<* enums.h `WarningLevel`. *>
enum WarningLevel : char
{
	NOT_SET,
	SILENT,
	WARN,
	ERROR,
}

<* enums.h `ABI` (all-caps type names are not allowed). *>
enum Abi : char
{
	UNKNOWN,
	X64,
	WIN64,
	X86,
	AARCH64,
	WASM,
	ARM,
	PPC32,
	PPC64_SVR4,
	RISCV,
	XTENSA,
	AVR,
}

<* build.h `Warnings`. *>
struct Warnings
{
	WarningLevel deprecation;
	WarningLevel methods_not_resolved;
	WarningLevel dead_code;
	WarningLevel method_visibility;
	WarningLevel builtin;
	WarningLevel recursive_contracts;
	WarningLevel unused_parameter;
	WarningLevel unused_local;
}

<* build.h `BuildTarget.feature` (subset). *>
struct BuildFeatures
{
	SafetyLevel safe_mode;
	PanicLevel panic_level;
}

<* build.h `BuildTarget.win` (subset). *>
struct BuildWin
{
	WinSubsystem subsystem;
}

<* build.h `BuildTarget` (subset: what the parser, sema and the check-only pipeline read). *>
struct BuildTarget
{
	TargetType type;
	String[] sources;
	String[] object_files;
	String[] llvm_ir_files;
	String echo_prefix;
	String header_file_dir;
	String exec_dir;
	String project_dir;
	String[] emit_only;
	Warnings warnings;
	bool test_output;
	bool lsp_output;
	bool docgen;
	bool output_headers;
	bool lex_only;
	bool silent;
	bool parse_only;
	bool check_only;
	bool build_test;
	bool build_benchmark;
	bool read_stdin;
	bool print_input;
	bool no_entry;
	bool collect_stats;
	bool collect_stats_lists;
	TrustLevel trust_level;
	UseStdlib use_stdlib;
	LinkLibc link_libc;
	CustomLibc custom_libc;
	ShowBacktrace show_backtrace;
	StripUnused strip_unused;
	uint symtab_size;
	int max_vector_size;
	int max_stack_object_size;
	int max_macro_iterations;
	int max_generic_instances;
	int switchrange_max_size;
	int switchjump_max_size;
	String panicfn;
	String benchfn;
	String testfn;
	String compiler_rt_module;
	BuildFeatures feature;
	BuildWin win;
}

<* target.h `AlignData` (in bits). *>
struct AlignData
{
	int align;
	int pref_align;
}

const usz BITSIZES_COUNT = BitSizes.BITSIZES_LEN.ordinal;

<* target.h `PlatformTarget.x64` (subset; c3c keeps it in a per-arch union). *>
struct PlatformX64
{
	bool pass_int128_vector_in_mem;
	int native_vector_size_avx;
}

<* target.h `PlatformTarget` (subset). *>
struct PlatformTarget
{
	ArchType arch;
	OsType os;
	ObjectFormatType object_format;
	Abi abi;
	AlignData[BITSIZES_COUNT] integers;
	AlignData[BITSIZES_COUNT] floats;
	bool big_endian;
	bool tls_supported;
	bool float128_supported;
	bool float16_supported;
	bool int128_supported;
	bool signed_c_char;
	AlignData align_pointer;
	int align_max_vector;
	int align_max_tls;
	int width_pointer;
	int width_register;
	int width_c_short;
	int width_c_int;
	int width_c_long;
	int width_c_long_long;
	PlatformX64 x64;
	bool asm_initialized;
	String[] clobber_name_list;
	AsmRegister[ASM_REGISTER_MAX] registers;
	AsmInstruction[ASM_INSTRUCTION_MAX] instructions;
	int register_count;
}

<* compiler_internal.h `Linking` (subset). *>
struct Linking
{
	String[] links;
}

<* compiler_internal.h `GlobalContext` (subset). *>
struct GlobalContext
{
	bool should_print_environment;
	bool should_print_asm;
	HTable modules;
	Module* core_module;
	int generic_id_counter;
	CompilationUnit* core_unit;
	Module*[] module_list;
	Type*[] type;
	String lib_dir;
	String[] sources;
	SourceFile*[] loaded_sources;
	bool in_panic_mode;
	<* Set where c3c would `exit_compiler` mid-parse (lexer failure); mutes further reports. *>
	bool exit_requested;
	int errors_found;
	int warnings_found;
	int includes_used;
	Decl*[][] locals_list;
	HTable compiler_defines;
	HTable features;
	Module std_module;
	MethodTable method_extensions;
	Decl*[] unregistered_method_specializations;
	Decl*[] unregistered_generic_decls;
	Type*[] types_with_failed_methods;
	Decl*[] method_extension_list;
	DeclTable symbols;
	PathTable path_symbols;
	ModulePath std_module_path;
	ModulePath compiler_rt_path;
	Type* string_type;
	Decl* panic_var;
	Decl* panic_fn;
	PanicVariant[] panic_variants;
	Decl* io_error_file_not_found;
	Decl* main;
	Decl*[MAX_GLOBAL_DECL_STACK] decl_stack;
	Decl** decl_stack_bottom;
	Decl** decl_stack_top;
}

<* compiler_internal.h `CompilerState` (subset). *>
struct CompilerState
{
	BuildTarget build;
	PlatformTarget platform;
	Linking linking;
	GlobalContext context;
	CompilerStats stats;
	String obj_output;
	int generic_depth;
	double exec_time;
	double script_time;
	String base_dir;
}

const int INITIAL_SYMBOL_MAP = 0x10000;
const int INITIAL_GENERIC_SYMBOL_MAP = 0x1000;
const int MAX_MODULE_NAME = 31;
const int MAX_MODULE_PATH = 63;
const int MAX_PARAMS = 255;
const int MAX_INTERFACES = 127;
const int MAX_VAARGS = 512;
const int MAX_BITSTRUCT = 0x1000;
const int MAX_MEMBERS = 0x7FFF;
const int MAX_GENERIC_DEPTH = 32;
const int MAX_PRIORITY = 0xFFFF;
const int MAX_MACRO_RECURSION_DEPTH = 64;
const int MAX_CONTRACT_DEPTH = 20;
const int MAX_INCLUDE_DIRECTIVES = 2048;
const FileId STDIN_FILE_ID = ~(FileId)0;
const int MAX_GLOBAL_DECL_STACK = 65536;
const int COMPILER_SUCCESS_EXIT = -1000;
const int EXIT_FAILURE = 1;

<* c3c `compiler`. *>
CompilerState compiler;
<* c3c's static `symtab` (symtab.c). *>
Symtab global_symtab;
<* The report sink behind c3c's eprintf-based diagnostics.c. *>
Diagnostics global_diagnostics;
bool compiler_ready;

<* c3c `stdin_file` (parser.c). *>
SourceFile stdin_file;

<* c3c `error_exit`. *>
macro void @error_exit(String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "error_exit arguments do not match the format";
	abort($fmt, ...$vaarg);
}

alias ExitHook = fn void(int exit_value);
<* Called by `exit_compiler` before it aborts (probes set it to a process exit). *>
ExitHook exit_hook;

<* c3c `exit_compiler`. *>
fn void exit_compiler(int exit_value)
{
	if (exit_hook) exit_hook(exit_value);
	abort("exit_compiler(%d)", exit_value);
}

// ---------------------------------------------------------------------------
// compiler.c

fn void global_context_add_decl(Decl* decl)
{
	decltable_set(&compiler.context.symbols, decl);
	pathtable_set(&compiler.context.path_symbols, decl);
}

fn void global_context_replace_decl(Decl* old, Decl* new_symbol)
{
	decltable_replace(&compiler.context.symbols, old, new_symbol);
	pathtable_replace(&compiler.context.path_symbols, old, new_symbol);
}

fn void linking_add_link(Linking* linking, String link)
{
	foreach (existing_link : linking.links)
	{
		if (str_eq(link, existing_link)) return;
	}
	@vec_add(&linking.links, link);
}

fn void global_context_clear_errors()
{
	compiler.context.in_panic_mode = false;
	compiler.context.exit_requested = false;
	compiler.context.errors_found = 0;
	compiler.context.warnings_found = 0;
}

fn void global_context_add_type(Type* type)
{
	assert(type_ok(type));
	@vec_add(&compiler.context.type, type);
}

fn Module* global_context_find_module(String name)
{
	assert(name.ptr != null);
	return htable_get(&compiler.context.modules, name.ptr);
}

fn Module* compiler_find_or_create_module(ModulePath* module_name)
{
	Module* mod = global_context_find_module(module_name.module_name);
	if (mod) return mod;

	// Set up the module.
	mod = calloc_arena(Module::size);
	mod.name = module_name;
	mod.inlined_at = { 0, null, null };
	ModulePath* rt = &compiler.context.compiler_rt_path;
	mod.is_compiler_rt = module_name.len >= rt.len && rt.module_name.ptr
	                     && mem::equals(module_name.module_name.ptr, rt.module_name.ptr, rt.len)
	                     && (module_name.len == rt.len || module_name.module_name[rt.len] == ':');
	usz first = 0;
	for (usz i = module_name.len; i > 0; i--)
	{
		if (module_name.module_name[i - 1] == ':')
		{
			first = i;
			break;
		}
	}
	if (!first)
	{
		mod.short_path = module_name.module_name;
	}
	else
	{
		String name = module_name.module_name[first..];
		TokenType type = IDENT;
		mod.short_path = symtab_add(name, &type);
	}
	mod.stage = NOT_BEGUN;
	htable_init(&mod.symbols, 0x1000);
	htable_set(&compiler.context.modules, module_name.module_name.ptr, mod);
	@vec_add(&compiler.context.module_list, mod);
	return mod;
}

fn String scratch_buffer_interned()
{
	TokenType type = INVALID_TOKEN;
	return scratch_buffer_interned_as(&type);
}

fn String scratch_buffer_interned_as(TokenType* type)
{
	return symtab_add(scratch_buffer_str(), type);
}

// ---------------------------------------------------------------------------
// source_file.c

fn SourceFile* source_file_by_id(FileId file)
{
	if (file == STDIN_FILE_ID) return &stdin_file;
	assert(file < compiler.context.loaded_sources.len);
	return compiler.context.loaded_sources[file];
}

<* Register `file` as the next loaded source (and its path with the report sink). *>
fn void source_file_register(SourceFile* file)
{
	file.file_id = (FileId)compiler.context.loaded_sources.len;
	@vec_add(&compiler.context.loaded_sources, file);
	uint diag_id = global_diagnostics.add_file(file.full_path);
	assert(diag_id == file.file_id);
}

<*
 c3c `source_file_text_load`: a source file with in-memory `content`
 (cleaned like `file_clean_buffer`). Aborts on UTF-16 input.
*>
fn SourceFile* source_file_text_load(String filename, String content)
{
	SourceFile* file = calloc_arena(SourceFile::size);
	file.kind = TEXT;
	file.full_path = str_copy(filename);
	String? cleaned = lexer::clean_source(ast_allocator(), content);
	if (catch cleaned) @error_exit("The file %s is not valid UTF-8.", filename);
	file.contents = cleaned;
	file.name = file.full_path;
	file.dir_path = str_copy("");
	source_file_register(file);
	return file;
}

<* c3c `source_file_generate`. *>
fn SourceFile* source_file_generate(String filename)
{
	SourceFile* file = calloc_arena(SourceFile::size);
	file.kind = GENERATED;
	file.full_path = "<generated>";
	file.contents = (String)((char*)calloc_arena(lexer::BUFFER_PADDING))[:0];
	file.name = str_copy(filename);
	file.dir_path = "";
	source_file_register(file);
	return file;
}

// ---------------------------------------------------------------------------
// target.c (x86_64 Linux only)

<* The PlatformTarget values c3c's `target_setup` computes for x86_64-linux. *>
fn void target_setup_x64_linux()
{
	PlatformTarget* p = &compiler.platform;
	p.arch = X86_64;
	p.os = OsType.LINUX;
	p.object_format = ELF;
	p.abi = X64;
	// target.c x64 setup for the generic (SSE2, no AVX) x86-64 cpu on Linux.
	p.x64.pass_int128_vector_in_mem = true;
	p.x64.native_vector_size_avx = 16;
	p.big_endian = false;
	p.tls_supported = true;
	p.width_pointer = 64;
	p.width_register = 64;
	p.int128_supported = true;
	p.float128_supported = true;
	p.float16_supported = true;
	for (usz i = BitSizes.BITS8.ordinal; i < BITSIZES_COUNT; i++)
	{
		int bits = 8 << (i - 1);
		p.integers[i] = { bits, bits };
		p.floats[i] = { bits, bits };
	}
	p.integers[BitSizes.BIT1.ordinal] = p.integers[BitSizes.BITS8.ordinal];
	p.align_pointer = { p.width_pointer, p.width_pointer };
	p.width_c_short = 16;
	p.width_c_int = 32;
	p.width_c_long = 64;
	p.width_c_long_long = 64;
	p.signed_c_char = true;
	p.align_max_vector = 0;
	p.align_max_tls = 0;
}

// ---------------------------------------------------------------------------
// Setup / teardown

<* Release all compiler memory (arenas, symtab, report sink, globals). *>
fn void compiler_free()
{
	if (compiler_ready)
	{
		global_symtab.free();
		global_diagnostics.free();
	}
	ast_memory_reset();
	compiler = {};
	stdin_file = {};
	scratch_buffer_reset();
	symtab_globals_reset();
	types_reset();
	poisoned_reset();
	compiler_ready = false;
}

<*
 Fresh compiler for tests: everything freed, then c3c's compiler_init /
 compile setup up to the point where files can be parsed (symtab, module
 tables, core module + unit, x86_64-linux target, builtin types).
*>
fn void compiler_reset()
{
	compiler_free();
	global_diagnostics.init_list(mem);
	global_diagnostics.error_counter = &compiler.context.errors_found;
	symtab_init(0x10000);
	compiler_ready = true;
	htable_init(&compiler.context.modules, 16 * 1024);
	pathtable_init(&compiler.context.path_symbols, INITIAL_SYMBOL_MAP);
	decltable_init(&compiler.context.symbols, INITIAL_SYMBOL_MAP);
	htable_init(&compiler.context.features, 1024);
	htable_init(&compiler.context.compiler_defines, 16 * 1024);
	compiler.context.compiler_rt_path = { .module_name = "compiler_rt", .len = 11 };
	// Create the core module.
	ModulePath* core_path = calloc_arena(ModulePath::size);
	core_path.module_name = kw_std__core;
	core_path.loc = 0;
	core_path.len = (uint)kw_std__core.len;
	compiler.context.core_module = compiler_find_or_create_module(core_path);
	CompilationUnit* unit = unit_create(source_file_generate("core_internal.c3"));
	unit.mod = compiler.context.core_module;
	compiler.context.core_unit = unit;
	target_setup_x64_linux();
	type_setup(&compiler.platform);
}
