// The check-only pipeline of c3c src/compiler/compiler.c (compile ->
// compiler_compile -> sema_analysis_run, compiler_parse), its static define
// setup, `panic_fn_desc`, source_file.c `source_file_load`, plus stubs for
// the compiler.c functions sema calls ($exec support). Companion of
// compiler.c3.
//
// Deviations from c3c:
// - `compile()` starts after the setup compiler_reset() already did (symtab,
//   module tables, core module, target, builtin types); call
//   `build_target_setup_defaults()` and fill `compiler.build.sources` first.
// - Only the check-only path exists: lex_only / docgen / headers / stats /
//   codegen stop with error_exit. `free_arenas` / `compiler_print_stats` at
//   the end of a check-only run are left to the caller (compiler_free).
// - `update_feature_flags` covers the flags a check-only build sets
//   (DEBUG_SYMBOLS is not tracked).
// - `source_file_load` does not resolve the real path: files are keyed and
//   reported by the name they were given.
// - `compile_and_invoke` / `setup_exec_paths` are POSIX only; the
//   compiler executable is `compiler_exe_name` (set by the driver) next to
//   `find_executable_path()`.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, std::io, std::io::file, std::core::mem::alloc;

const int MAX_MODULES = 100000;
const int MAX_COMMAND_LINE_FILES = 4096;
const String COMPILER_VERSION = "0.8.7";
const bool PRERELEASE = true;

String[3] c3_suffix_list = { ".c3", ".c3t", ".c3i" };

<* compiler.c `panic_fn_desc`, in PanicFunction order. *>
PanicFunctionDescriptor[PanicFunction.FN_COUNT.ordinal] panic_fn_desc = {
	{ .name = "message", .text_count = 1 }, // FN_MESSAGE
	{ .name = "assert", .format = "Assert \"%s\" failed.", .summary = "Assert failed", .text_count = 1 }, // FN_ASSERT
	{ .name = "assert_violation", .format = "Assert violation" }, // FN_ASSERT_VIOLATION
	{ .name = "require", .format = "@require \"%s\" violated.", .summary = "@require violated", .text_count = 1 }, // FN_REQUIRE
	{ .name = "require_message", .format = "@require \"%s\" violated: '%s'.", .summary = "@require violated", .text_count = 2 }, // FN_REQUIRE_MESSAGE
	{ .name = "ensure", .format = "@ensure \"%s\" violated.", .summary = "@ensure violated", .text_count = 1 }, // FN_ENSURE
	{ .name = "ensure_message", .format = "@ensure \"%s\" violated: '%s'.", .summary = "@ensure violated", .text_count = 2 }, // FN_ENSURE_MESSAGE
	{ .name = "ref_param", .format = "Reference parameter '%s' was passed a null pointer argument.", .summary = "Reference parameter was passed a null pointer argument.", .text_count = 1 }, // FN_REF_PARAM
	{ .name = "ref_arg", .format = "Passed null to a ref ('&') parameter." }, // FN_REF_ARG
	{ .name = "null_method", .format = "Called a method on a null value." }, // FN_NULL_METHOD
	{ .name = "null_pointer", .format = "Dereference of null pointer, '%s' was null.", .summary = "Dereference of null pointer", .text_count = 1 }, // FN_NULL_POINTER
	{ .name = "deref", .text_count = 1, .value_count = 2 }, // FN_DEREF
	{ .name = "null_function", .format = "Calling null function pointer, '%s' was null.", .summary = "Calling null function pointer", .text_count = 1 }, // FN_NULL_FUNCTION
	{ .name = "no_method", .format = "No method '%s' could be found on target", .summary = "No method could be found on target", .text_count = 1 }, // FN_NO_METHOD
	{ .name = "add_overflow", .format = "Addition overflow" }, // FN_ADD_OVERFLOW
	{ .name = "sub_overflow", .format = "Subtraction overflow" }, // FN_SUB_OVERFLOW
	{ .name = "mul_overflow", .format = "Integer multiplication overflow" }, // FN_MUL_OVERFLOW
	{ .name = "neg_overflow", .format = "Signed negation overflow" }, // FN_NEG_OVERFLOW
	{ .name = "div_zero", .format = "Division by zero." }, // FN_DIV_ZERO
	{ .name = "rem_zero", .format = "% by zero." }, // FN_REM_ZERO
	{ .name = "infinite_loop", .format = "Infinite loop found" }, // FN_INFINITE_LOOP
	{ .name = "access_inner", .format = "Attempted to access 'inner' on non composite type" }, // FN_ACCESS_INNER
	{ .name = "access_names", .format = "Attempted to access 'names' on non enum/fault type." }, // FN_ACCESS_NAMES
	{ .name = "access_len", .format = "Attempted to access 'len' on non array type" }, // FN_ACCESS_LEN
	{ .name = "unaligned", .format = "Unaligned access: ptr %% %s = %s, use mem::load / mem::store for unaligned access.", .summary = "Unaligned pointer access detected", .value_count = 2 }, // FN_UNALIGNED
	{ .name = "unwrap", .format = "Unexpected fault '%s' was unwrapped!", .summary = "Force unwrap failed!", .value_count = 1 }, // FN_UNWRAP
	{ .name = "shift", .format = "Shift amount out of range (was %s).", .summary = "Invalid shift", .value_count = 1 }, // FN_SHIFT
	{ .name = "index", .value_count = 2 }, // FN_INDEX
	{ .name = "index_negative", .format = "Negative array indexing (index was %d)", .summary = "Negative array indexing", .value_count = 1 }, // FN_INDEX_NEGATIVE
	{ .name = "index_bounds", .format = "Array index out of bounds (array had size %d, index was %d)", .summary = "Array index out of bounds", .value_count = 2 }, // FN_INDEX_BOUNDS
	{ .name = "slice", .value_count = 4 }, // FN_SLICE
	{ .name = "slice_start", .format = "Index exceeds array length (array had size %d, index was %d).", .summary = "Index exceeds array len", .value_count = 2 }, // FN_SLICE_START
	{ .name = "slice_start_negative", .format = "Negative indexing (%d)", .summary = "Negative value", .value_count = 1 }, // FN_SLICE_START_NEGATIVE
	{ .name = "slice_len_negative", .format = "Negative value (%d) given for slice length.", .summary = "Negative slice length", .value_count = 1 }, // FN_SLICE_LEN_NEGATIVE
	{ .name = "slice_end", .format = "End index out of bounds (end index of %d exceeds size of %d)", .summary = "End index out of bounds", .value_count = 2 }, // FN_SLICE_END
	{ .name = "slice_range_negative", .format = "Negative size (slice was: [%d..%d])", .summary = "Negative size", .value_count = 2 }, // FN_SLICE_RANGE_NEGATIVE
	{ .name = "slice_copy", .format = "Slice copy length mismatch (%d != %d).", .summary = "Length mismatch", .value_count = 2 }, // FN_SLICE_COPY
	{ .name = "enum_negative", .format = "Attempt to convert a negative value (%d) to enum '%s' failed.", .summary = "Attempt to convert negative value to enum failed.", .text_count = 1, .value_count = 1 }, // FN_ENUM_NEGATIVE
	{ .name = "enum_range", .format = "Attempting to convert %d to enum '%s' failed as the value exceeds the max ordinal (%d).", .summary = "Failed integer to enum conversion", .text_count = 1, .value_count = 2 }, // FN_ENUM_RANGE
	{ .name = "assert_args", .summary = "Assert violation", .text_count = 1, .value_count = 1 }, // FN_ASSERT_ARGS
};

// ---------------------------------------------------------------------------
// Build target defaults

<*
 The BuildTarget values c3c's build_options / builder.c settle on for
 `c3c compile` at -O0 with strict validation (the default), leaving
 `use_stdlib` etc. at NOT_SET for the caller to override.
*>
fn void build_target_setup_defaults()
{
	BuildTarget* target = &compiler.build;
	target.type = EXECUTABLE;
	target.switchrange_max_size = 256;
	target.switchjump_max_size = 0x3FFF;
	target.feature.safe_mode = SAFETY_ON;
	target.feature.panic_level = PANIC_ON;
	target.show_backtrace = SHOW_BACKTRACE_ON;
	target.win.subsystem = WIN_SUBSYSTEM_DEFAULT;
	// builder.c: LINK_LIBC_NOT_SET -> libc_from_arch_os (compiler_reset set the target).
	target.link_libc = libc_from_arch_os(target.arch_os_target);
	target.custom_libc = CUSTOM_LIBC_NOT_SET;
	target.use_stdlib = USE_STDLIB_NOT_SET;
	target.strip_unused = STRIP_UNUSED_NOT_SET;
	target.max_vector_size = 4096;
	target.max_stack_object_size = 64;
	target.max_macro_iterations = 0xFFFFF;
	target.max_generic_instances = 4096;
	// VALIDATION_STRICT
	target.warnings.unused_parameter = SILENT;
	target.warnings.unused_local = SILENT;
	target.warnings.builtin = WARN;
	target.warnings.dead_code = WARN;
	target.warnings.deprecation = WARN;
	target.warnings.method_visibility = WARN;
	target.warnings.methods_not_resolved = WARN;
	target.warnings.recursive_contracts = ERROR;
}

// ---------------------------------------------------------------------------
// compiler.c

fn void add_feat(String feature_flag) @inline
{
	feature_flag = symtab_preset(feature_flag, CONST_IDENT);
	htable_set(&compiler.context.features, feature_flag.ptr, feature_flag.ptr);
}

fn void setup_define(String id, Expr* expr) @inline
{
	TokenType token_type = CONST_IDENT;
	id = symtab_add(id, &token_type);
	void* previous = htable_set(&compiler.context.compiler_defines, id.ptr, expr);
	if (previous)
	{
		@error_exit("Redefined ident %s", id);
	}
}

fn void setup_int_define(String id, ulong i, Type* type)
{
	Type* flat = type_flatten(type);
	assert(type_is_integer(flat));
	Expr* expr = expr_new_const_int(0, flat, i);
	expr.type = type;
	if (expr_const_will_overflow(&expr.const_expr, flat.type_kind))
	{
		@error_exit("Integer define %s overflow.", id);
	}
	setup_define(id, expr);
}

fn void setup_string_define(String id, String value)
{
	setup_define(id, expr_new_const_string(0, value));
}

fn void setup_bool_define(String id, bool value)
{
	setup_define(id, expr_new_const_bool(0, type_bool, value));
}

fn void update_feature_flags()
{
	foreach (feature_flag : compiler.build.feature_list) add_feat(feature_flag);

	if (link_libc()) add_feat("LIBC");
	if (custom_libc()) add_feat("CUSTOM_LIBC");
	bool no_libc = !link_libc() && !custom_libc();
	if (no_libc)
	{
		add_feat("NO_LIBC");
		add_feat("FREESTANDING");
		switch (compiler.platform.os)
		{
			case WIN32: add_feat("FREESTANDING_PE32");
			case MACOSX: add_feat("FREESTANDING_MACHO");
			default:
				if (compiler.platform.arch == WASM32 || compiler.platform.arch == WASM64)
				{
					add_feat("FREESTANDING_WASM");
				}
				else
				{
					add_feat("FREESTANDING_ELF");
				}
		}
	}
	if (compiler.platform.big_endian) add_feat("BIG_ENDIAN");
	if (!compiler.platform.big_endian) add_feat("LITTLE_ENDIAN");
	if (safe_mode_enabled()) add_feat("SAFE_MODE");
	if (compiler.build.debug_info_full) add_feat("DEBUG_SYMBOLS");
	if (compiler.build.show_backtrace != SHOW_BACKTRACE_OFF) add_feat("BACKTRACE");
	if (compiler.build.build_benchmark) add_feat("BENCHMARKING");
	if (compiler.build.build_test) add_feat("TESTING");
	switch (compiler.platform.width_register)
	{
		case 8: add_feat("ARCH_8_BIT");
		case 16: add_feat("ARCH_16_BIT");
		case 32: add_feat("ARCH_32_BIT");
		case 64: add_feat("ARCH_64_BIT");
		case 128: add_feat("ARCH_128_BIT");
		default: unreachable();
	}
	switch (compiler.platform.arch)
	{
		case ARM: add_feat("ARM");
		case ARMB: add_feat("ARMB");
		case AARCH64: add_feat("AARCH64");
		case RISCV32: add_feat("RISCV32");
		case RISCV64: add_feat("RISCV64");
		case X86: add_feat("X86");
		case X86_64: add_feat("X86_64");
		case WASM32: add_feat("WASM"); add_feat("WASM32");
		case WASM64: add_feat("WASM"); add_feat("WASM64");
		case XTENSA: add_feat("XTENSA");
		default: break;
	}
	if (link_libc())
	{
		switch (compiler.platform.os)
		{
			case FREEBSD: add_feat("POSIX"); add_feat("BSD"); add_feat("FREEBSD");
			case IOS: add_feat("POSIX"); add_feat("DARWIN"); add_feat("IOS");
			case LINUX: add_feat("POSIX"); add_feat("LINUX");
			case MACOSX: add_feat("POSIX"); add_feat("DARWIN"); add_feat("MACOS");
			case NETBSD: add_feat("POSIX"); add_feat("BSD"); add_feat("NETBSD");
			case OPENBSD: add_feat("POSIX"); add_feat("BSD"); add_feat("OPENBSD");
			case WIN32: add_feat("WIN32");
			case TVOS: add_feat("POSIX"); add_feat("DARWIN"); add_feat("TVOS");
			case WATCHOS: add_feat("POSIX"); add_feat("DARWIN"); add_feat("WATCHOS");
			case WASI: add_feat("WASI");
			case EMSCRIPTEN: add_feat("POSIX"); add_feat("EMSCRIPTEN");
			case ANDROID: add_feat("POSIX"); add_feat("ANDROID");
			default: break;
		}
	}
	if (compiler.platform.int128_supported) add_feat("NATIVE_I128");
	if (compiler.platform.float128_supported) add_feat("NATIVE_F128");
	if (compiler.platform.float16_supported) add_feat("NATIVE_F16");
	if (compiler.build.feature.sanitize_address) add_feat("ASAN");
	if (compiler.build.feature.sanitize_memory) add_feat("MSAN");
	if (compiler.build.feature.sanitize_thread) add_feat("TSAN");
	if (!no_panic()) add_feat("PRINT_PANIC");
}

// compiler.c:1495 (static)
fn int jump_buffer_size()
{
	switch (compiler.build.arch_os_target)
	{
		case DEFAULT:
			return 512;
		case ELF_RISCV32:
		case LINUX_RISCV32:
			// Godbolt test
			return 76;
		case ELF_XTENSA:
			// Godbolt 68 => 17 with 32 bit pointers
			return 17;
		case ELF_AVR:
			// Extracted from avr-libc
			return 12;
		case ELF_RISCV64:
		case LINUX_RISCV64:
			// Godbolt test
			return 43;
		case IOS_X64_SIM:
		case MACOS_X64:
			return 19; // Actually 18.5
		case WINDOWS_X64: // 16 on x32
		case MINGW_X64:
			// Godbolt test
			return 32;
		case ELF_X64:
		case LINUX_X64:
		case ANDROID_X86_64:
			// Godbolt test
			return 25;
		case FREEBSD_X64:
		case NETBSD_AARCH64:
		case NETBSD_X64:
		case OPENBSD_X64:
			// c3c: REMINDER("Guessing setjmp for platform.")
			return 32;
		case ANDROID_AARCH64:
		case LINUX_AARCH64:
		case ELF_AARCH64:
			return 39;
		case WINDOWS_AARCH64:
			// Based on Godbolt
			return 24;
		case IOS_AARCH64:
		case IOS_AARCH64_SIM:
		case MACOS_AARCH64:
			// Based on macOS headers
			return 25;
		case LINUX_X86:
		case MCU_X86:
		case NETBSD_X86:
		case OPENBSD_X86:
		case ELF_X86:
		case FREEBSD_X86:
			// Early GCC
			return 39;
		case WASM32:
		case EMSCRIPTEN_WASM32:
			// 39 * 4 bytes = 156 bytes
			return 39;
		case WASM64:
			// 20 * 8 bytes = 160 bytes
			return 20;
	}
	unreachable();
}

<* c3c `compile` (check-only subset, after compiler_reset()). *>
fn void compile()
{
	// compiler_reset() did symtab_init, the core module and target_setup.
	compiler.context.main = null;
	compiler.context.string_type = null;
	compiler.platform.asm_initialized = false;
	update_feature_flags();
	compiler.context.sources = compiler.build.sources;
	setup_int_define("C_SHORT_SIZE", (ulong)compiler.platform.width_c_short, type_int);
	setup_int_define("C_INT_SIZE", (ulong)compiler.platform.width_c_int, type_int);
	setup_int_define("C_LONG_SIZE", (ulong)compiler.platform.width_c_long, type_int);
	setup_int_define("C_LONG_LONG_SIZE", (ulong)compiler.platform.width_c_long_long, type_int);
	setup_int_define("REGISTER_SIZE", (ulong)compiler.platform.width_register, type_int);
	setup_int_define("MAX_VECTOR_SIZE", (ulong)compiler.build.max_vector_size, type_int);
	setup_bool_define("C_CHAR_IS_SIGNED", compiler.platform.signed_c_char);
	setup_int_define("ARCH_TYPE", (ulong)compiler.platform.arch.ordinal, type_int);
	// c3c: (uint64_t)compiler.build.memory_environment, MEMORY_ENV_NORMAL = 0.
	setup_int_define("MEMORY_ENVIRONMENT", 0, type_int);
	// c3c: compiler.build.optlevel / optsize at -O0.
	setup_int_define("COMPILER_OPT_LEVEL", 0, type_int);
	setup_int_define("OS_TYPE", (ulong)compiler.platform.os.ordinal, type_int);
	setup_int_define("COMPILER_SIZE_OPT_LEVEL", 0, type_int);
	setup_int_define("LLVM_VERSION", 0, type_int);
	setup_string_define("VERSION", COMPILER_VERSION);
	setup_bool_define("PRERELEASE", PRERELEASE);
	setup_int_define("JMP_BUF_SIZE", (ulong)jump_buffer_size(), type_int);
	setup_int_define("LANGUAGE_DEV_VERSION", 8, type_int);
	setup_string_define("BUILD_HASH", "54bab366a");
	setup_string_define("BUILD_DATE", "");
	setup_string_define("PROJECT_PATH", compiler.build.project_dir.ptr ? compiler.build.project_dir : compiler.base_dir);
	Expr* expr_names = expr_new(CONST, 0);
	Expr* expr_emails = expr_new(CONST, 0);
	expr_names.const_expr.const_kind = UNTYPED_LIST;
	expr_emails.const_expr.const_kind = UNTYPED_LIST;
	expr_names.type = type_untypedlist;
	expr_emails.type = type_untypedlist;
	expr_names.resolve_status = expr_emails.resolve_status = DONE;
	setup_define("AUTHORS", expr_names);
	setup_define("AUTHOR_EMAILS", expr_emails);
	setup_string_define("PROJECT_VERSION", "1.0.0");
	type_init_cint();
	compiler.stats.init_time = bench_mark();

	if (!compiler.build.object_files.len && !compiler.build.llvm_ir_files.len && !compiler.build.sources.len && !compiler.build.read_stdin) @error_exit("No files to compile.");
	if (compiler.build.lex_only) @error_exit("--lex-only is not supported by this pipeline.");
	if (compiler.build.parse_only)
	{
		compiler_parse();
		compiler.stats.parsing_time = bench_mark();
		exit_compiler(COMPILER_SUCCESS_EXIT);
	}
	compiler_compile();
}

fn void compiler_parse()
{
	// Cleanup any errors (could there really be one here?!)
	global_context_clear_errors();
	String rt = compiler.build.compiler_rt_module.ptr ? compiler.build.compiler_rt_module : "compiler_rt";
	compiler.context.compiler_rt_path = { .module_name = rt, .len = (uint)rt.len };

	// Add the standard library
	if (compiler.context.lib_dir.ptr && !no_stdlib())
	{
		file_add_wildcard_files(&compiler.context.sources, compiler.context.lib_dir, true, &c3_suffix_list, 3);
	}

	// Load and parse all files.
	bool has_error = false;
	if (compiler.build.print_input) io::printn("# input-files-begin");
	foreach (source : compiler.context.sources)
	{
		bool loaded = false;
		String error;
		SourceFile* file = source_file_load(source, &loaded, &error);
		if (!file) @error_exit("%s", error);
		if (loaded) continue;
		if (!parse_file(file)) has_error = true;
		if (compiler.build.print_input) io::printn(file.full_path);
	}
	if (compiler.build.print_input) io::printn("# input-files-end");
	if (compiler.build.read_stdin) @error_exit("Reading from stdin is not supported by this pipeline.");

	if (has_error)
	{
		if (compiler.build.lsp_output)
		{
			io::eprint("> ENDLSP-ERROR\n");
			exit_compiler(COMPILER_SUCCESS_EXIT);
		}
		exit_compiler(EXIT_FAILURE);
	}
	compiler.stats.parsing_time = bench_mark();
}

fn void compiler_compile()
{
	if (compiler.build.lsp_output) io::eprint("> BEGINLSP\n");
	sema_analysis_run();
	if (compiler.build.docgen) @error_exit("Docgen is not ported yet.");
	if (compiler.build.lsp_output)
	{
		io::eprint("> ENDLSP-OK\n");
		exit_compiler(COMPILER_SUCCESS_EXIT);
	}
	compiler.stats.sema_time = bench_mark();
	if (compiler.build.collect_stats) @error_exit("Statistics are not ported yet.");
	Module*[] modules = compiler.context.module_list;
	usz module_count = modules.len;
	if (module_count > MAX_MODULES)
	{
		@error_exit("Too many modules.");
	}
	if (module_count < 1 && !compiler.build.object_files.len && !compiler.build.llvm_ir_files.len)
	{
		@error_exit("No module to compile.");
	}
	if (compiler.build.output_headers) @error_exit("Header generation is not ported yet.");

	// c3c: free_arenas(); compiler_print_stats();
	if (compiler.build.check_only) return;

	@error_exit("Code generation is not ported yet; use check_only.");
}

<* main.c `compiler_exe_name` (argv[0]); set by the driver, used by `compile_and_invoke`. *>
String compiler_exe_name;

<* The current working directory, copied to the arena (c3c's static PATH_MAX buffers). *>
fn String getcwd_copy() @local
{
	char[4097] buffer;
	ZString cwd = posix_getcwd(&buffer, 4096);
	if (!cwd) return str_copy(".");
	return str_copy(cwd.str_view());
}

// compiler.c:1570
fn void setup_exec_paths(String* old_dir_ref, String* script_dir_ref, String* exec_dir_ref)
{
	String old_path = getcwd_copy();
	*old_dir_ref = old_path;
	*exec_dir_ref = *script_dir_ref = old_path;
	if (compiler.build.script_dir.ptr)
	{
		if (!dir_change(compiler.build.script_dir)) @error_exit("Failed to open script dir '%s'", compiler.build.script_dir);
		String script_path = getcwd_copy();
		*exec_dir_ref = *script_dir_ref = script_path;
		dir_change(old_path);
	}
	if (compiler.build.exec_dir.ptr)
	{
		if (!dir_change(compiler.build.exec_dir)) @error_exit("Failed to open exec dir '%s'", compiler.build.exec_dir);
		String exec_path = getcwd_copy();
		*exec_dir_ref = exec_path;
	}
}

// compiler.c:2244
fn SourceFile* compile_and_invoke(String file, String args, String stdin_data, usz limit)
{
	String name;
	if (!file_namesplit(compiler_exe_name, &name, null))
	{
		@error_exit("Failed to extract file name from '%s'", compiler_exe_name);
	}
	String compiler_path = file_append_path(find_executable_path(), name);

	scratch_buffer_clear();
	// scratch_buffer_append_native_safe_path is a plain append on POSIX.
	scratch_buffer_append(compiler_path);
	String output = "__c3exec__";
	scratch_buffer_append(" compile -g0 --single-module=yes");
	StringSlice slice = slice_from_string(file);
	while (slice.len > 0)
	{
		StringSlice file_name = slice_next_token(&slice, ';');
		if (!file_name.len) continue;
		scratch_buffer_append(" ");
		scratch_buffer_append(file_name);
	}
	@scratch_buffer_printf(" -o %s", output);
	String out;
	if (!execute_cmd_failable(scratch_buffer_copy(), &out, {}, limit))
	{
		if (out.len)
		{
			io::eprintf("+-- Script compilation output ---------+\n");
			io::eprintf("%s\n", out);
			io::eprintf("+--------------------------------------+\n");
		}
		@error_exit("Failed to compile script '%s'.", file);
	}
	scratch_buffer_clear();
	scratch_buffer_append("./");
	scratch_buffer_append(output);
	scratch_buffer_append(" ");
	scratch_buffer_append(args);
	if (!execute_cmd_failable(scratch_buffer_copy(), &out, stdin_data, limit))
	{
		if (out.len)
		{
			io::eprintf("+-- Script output ---------------------+\n");
			io::eprintf("%s\n", out);
			io::eprintf("+--------------------------------------+\n");
		}
		@error_exit("Error invoking script '%s' with arguments %s.", file, args);
	}
	(void)file::delete(output);
	return source_file_text_load(file, out);
}

// ---------------------------------------------------------------------------
// source_file.c

fn SourceFile* source_file_load(String filename, bool* already_loaded, String* error)
{
	if (already_loaded) *already_loaded = false;
	foreach (file : compiler.context.loaded_sources)
	{
		if (file.full_path == filename)
		{
			if (already_loaded) *already_loaded = true;
			return file;
		}
	}
	if (compiler.context.loaded_sources.len == MAX_COMMAND_LINE_FILES)
	{
		*error = @str_printf("Exceeded max number of files %d", MAX_COMMAND_LINE_FILES);
		return null;
	}
	char[]? raw = file::load(mem, filename);
	if (catch raw)
	{
		*error = @str_printf("Failed to resolve %s", filename);
		return null;
	}
	defer alloc::free(mem, raw.ptr);
	SourceFile* file = source_file_text_load(filename, (String)raw);
	file.kind = SOURCE;
	if (try slash = filename.rindex_of_char('/'))
	{
		file.name = file.full_path[slash + 1..];
		file.dir_path = str_copy(filename[:slash]);
	}
	return file;
}
