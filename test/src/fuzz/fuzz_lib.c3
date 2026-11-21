module aro::fuzz_lib;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::parser_declaration, aro::frontend::c::preprocessor;
import aro::frontend::c::predefined_macros, aro::frontend::c::pragmas::gcc, aro::frontend::c::pragmas::message, aro::frontend::c::pragmas::once;
import aro::frontend::c::pragma, aro::source, aro::target, aro::toolchain, aro::frontend::c::tree;
import aro::frontend::c::tokens;
import std::collections::list, std::core::mem::allocators, std::io, std::io::file, std::io::path, std::io::os, libc;

const usz MAX_FUZZ_BYTES = 20 * 1024 * 1024;
const usz FUZZ_TEMP_POOL_BYTES = 64 * 1024;

// A pool backed by FuzzAllocator makes tmem and every derived @pool share this
// fixed per-input arena. The fuzz targets disable VMEM_TEMP so the supported
// stdlib TempAllocator uses its backing allocator instead of a private Vmem.
char[MAX_FUZZ_BYTES] fuzz_storage;
struct FuzzAllocator (Allocator)
{
	ArenaAllocator arena;
}
FuzzAllocator fuzz_allocator;
libc::JmpBuf fuzz_oom_jump;
PanicFn previous_panic;
bool fuzz_active;
bool fuzz_arena_exhausted;
bool fuzz_last_compile_succeeded;
bool fuzz_include_file_open;
File fuzz_include_file;

fn void*? FuzzAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	void*? result = self.arena.acquire(size, init_type, alignment);
	if (catch f = result)
	{
		fuzz_arena_exhausted = true;
		return f~;
	}
	return result;
}

fn void*? FuzzAllocator.resize(&self, void* ptr, sz size, sz alignment) @dynamic
{
	void*? result = self.arena.resize(ptr, size, alignment);
	if (catch f = result)
	{
		fuzz_arena_exhausted = true;
		return f~;
	}
	return result;
}

fn void FuzzAllocator.release(&self, void* ptr, bool aligned) @dynamic
{
	self.arena.release(ptr, aligned);
}

fn void fuzz_panic_unwind_if_oom() @local
{
	if (fuzz_active && fuzz_arena_exhausted)
	{
		if (fuzz_include_file_open)
		{
			(void)fuzz_include_file.close();
			fuzz_include_file_open = false;
		}
		toolchain::discovery::close_open_host_directory();
		libc::longjmp(&fuzz_oom_jump, 1);
	}
}

// PanicFn gained (fmt, args) in c3c 0.8.6; match whichever stdlib is installed.
alias PanicFnWithArgs = fn void(String, String, String, int, String, any[]);
const bool PANIC_HAS_ARGS = $defined(PanicFnWithArgs probe = builtin::panic);

fn void fuzz_panic_handler(String message, String file, String function, int line, String fmt, any[] args) @if(PANIC_HAS_ARGS)
{
	fuzz_panic_unwind_if_oom();
	previous_panic(message, file, function, line, fmt, args);
}

fn void fuzz_panic_handler(String message, String file, String function, int line) @if(!PANIC_HAS_ARGS)
{
	fuzz_panic_unwind_if_oom();
	previous_panic(message, file, function, line);
}

fn bool fuzz_include_exists(void* ctx, String path) => file::is_file(path);

fn char[]? fuzz_include_read(void* ctx, Allocator a, String path, ulong limit)
{
	File? opened = file::open(path, "rb");
	if (catch opened) return preprocessor::FILE_NOT_FOUND~;
	fuzz_include_file = opened;
	fuzz_include_file_open = true;
	defer
	{
		if (fuzz_include_file_open) (void)fuzz_include_file.close();
		fuzz_include_file_open = false;
	}

	long? size_opt = fuzz_include_file.size();
	if (catch size_opt) return preprocessor::FILE_NOT_FOUND~;
	long size = size_opt;
	if (size < 0) return preprocessor::FILE_NOT_FOUND~;
	if (limit != ulong::max && (ulong)size > limit) size = (long)limit;
	if (size == 0) return (char[])"";
	char* bytes = alloc::malloc(a, (sz)size);
	char[]? contents = io::read_buffer_to_end((InStream)&fuzz_include_file, bytes[0:(usz)size]);
	if (catch contents) return preprocessor::FILE_NOT_FOUND~;
	return contents;
}

fn ulong? fuzz_include_mtime(void* ctx, String path)
{
	return (ulong)(os::native_get_modified_time(path) ?? 0);
}

struct DiscardWriter (OutStream) { char unused; }

fn sz? DiscardWriter.write(&self, char[] bytes) @dynamic => bytes.len;
fn void? DiscardWriter.write_byte(&self, char byte) @dynamic {}

<* C ABI fuzz entry point. Invalid lengths and invalid non-empty pointers are ignored. *>
fn void compile_c_buf(char* buf, int len) @export("compile_c_buf")
{
	if (len < 0 || len > (int)MAX_FUZZ_BYTES || (!buf && len != 0)) return;

	String input = "";
	if (len != 0) input = (String)buf[0:(usz)len];
	(void)run_fuzz_input(input, false);
}

<* Runs one isolated input; `force_oom` exercises the same abort and cleanup path in tests. *>
fn bool run_fuzz_input(String input, bool force_oom)
{
	fuzz_allocator.arena.init(fuzz_storage[0:MAX_FUZZ_BYTES]);
	fuzz_arena_exhausted = false;
	fuzz_last_compile_succeeded = false;
	previous_panic = builtin::panic;
	fuzz_active = true;
	builtin::panic = &fuzz_panic_handler;

	// The pool's deferred cleanup still runs after longjmp returns to the setjmp
	// in its body, destroying all children and restoring the caller's temp state.
	bool exhausted = false;
	// @pool_init is intended for the thread's first temp pool. Fuzz calls may run
	// inside another allocator's pool (for example, the test runner), so suspend
	// the existing top while creating this independently backed input pool.
	TempAllocator* previous_top_temp = allocators::top_temp;
	allocators::top_temp = null;
	@pool_init((Allocator)&fuzz_allocator, FUZZ_TEMP_POOL_BYTES)
	{
		int jumped = libc::setjmp(&fuzz_oom_jump);
		if (jumped == 0)
		{
			if (force_oom)
			{
				// Keep the first two live blocks below the cap, one via the compiler's
				// explicit allocator and one via a derived @pool allocator. The final
				// block must fail only if all pools share this arena.
				(void)alloc::malloc((Allocator)&fuzz_allocator, 8 * 1024 * 1024);
				@pool()
				{
					(void)alloc::malloc(allocators::current_temp, 8 * 1024 * 1024);
					(void)alloc::malloc((Allocator)&fuzz_allocator, 5 * 1024 * 1024);
				};
			}
			fuzz_last_compile_succeeded = compile_one(input);
		}
		exhausted = fuzz_arena_exhausted;
	};
	allocators::top_temp = previous_top_temp;

	builtin::panic = previous_panic;
	fuzz_active = false;
	fuzz_arena_exhausted = false;
	fuzz_allocator.arena.clear();
	return exhausted;
}

<* Test hook for verifying that exhaustion aborts one input and leaves later inputs usable. *>
fn bool force_oom_for_test() => run_fuzz_input("", true);

<* Test hook that reports whether the compiler completed a valid input without exhausting the arena. *>
fn bool compile_succeeds_for_test(String input)
{
	if (run_fuzz_input(input, false)) return false;
	return fuzz_last_compile_succeeded;
}

fn bool compile_one(String input)
{
	Allocator a = (Allocator)&fuzz_allocator;
	diagnostics::Diagnostics diagnostics;
	diagnostics.init_ignore();
	Compilation comp;
	comp.init(a, a, &diagnostics);
	defer comp.free();

	comp.include_files = {
		.exists = &fuzz_include_exists,
		.read = &fuzz_include_read,
		.mtime = &fuzz_include_mtime,
	};
	comp.pragmas.add("GCC", gcc::make_handler(a));
	comp.pragmas.add("once", once::handler(a));
	comp.pragmas.add("message", message::handler());

	// Match the normal driver's toolchain-derived builtin and system include
	// directories. The cwd-relative executable hint also locates this checkout's
	// include/stddef.h when the fuzzer runs from the repository tree.
	String cwd = path::cwd(a)!!;
	defer alloc::free(a, cwd.ptr);
	String aro_name = toolchain::discovery::join(a, { cwd, "bin", "aro" });
	defer alloc::free(a, aro_name.ptr);
	Host host = target::host()!!;
	toolchain::discovery::Env tc_env = {
		.fs = toolchain::discovery::host_fs(),
		.target = comp.target,
		.host_is_darwin = host.os.is_darwin(),
	};
	toolchain::Toolchain tc;
	tc.init(a, tc_env, { .aro_name = aro_name });
	defer tc.free();
	if (catch tc.discover()) return false;
	List{IncludeDir} includes;
	includes.init(a);
	defer includes.free();
	if (catch tc.define_system_includes(&includes)) return false;
	comp.set_include_dirs(includes.array_view());

	Source? user_opt = comp.add_source_from_buffer("<fuzz>", (char[])input);
	if (catch user_opt) return false;
	Source user_source = user_opt;
	Source? builtin_opt = predefined_macros::generate_builtin_macros(&comp,
		predefined_macros::SystemDefinesMode.INCLUDE_SYSTEM_DEFINES);
	if (catch builtin_opt) return false;
	Source builtin_source = builtin_opt;

	preprocessor::Preprocessor pp;
	preprocessor::InitOptions pp_options = {
		.base_file = user_source.id,
		.add_builtin_macros = true,
	};
	if (catch pp.init(&comp, pp_options)) return false;
	defer pp.free();
	if (catch pp.preprocess(builtin_source)) return false;
	tokens::TokenWithExpansionLocs? eof_opt = pp.preprocess(user_source);
	if (catch eof_opt) return false;
	if (catch pp.add_token(eof_opt)) return false;

	// Bind the complete front-end handler so parser recovery, statement bodies
	// and builtin/compound-literal expressions use the same path as the driver.
	parser::Parser c_parser;
	c_parser.init(&pp);
	parser_declaration::DeclarationParser handler;
	handler.bind(&c_parser);
	defer c_parser.free();
	Tree? tree_opt = c_parser.parse();
	if (catch tree_opt) return false;
	Tree tree = tree_opt;
	defer tree.free();

	DiscardWriter discard;
	diagnostics::Terminal terminal = { .writer = (OutStream)&discard, .mode = diagnostics::ColorMode.NO_COLOR };
	(void)tree.dump(terminal);
	return true;
}
