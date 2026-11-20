// Focused tests for the C3 toolchain API. Expectations are source-derived
// from src/aro/Toolchain.zig and Toolchain/{Linux,Darwin}.zig. The tests
// exercise the C3 port; no compatible Zig executable was run, so they do not
// claim executable parity.
module toolchain_tests;
import aro::target;
import aro::toolchain;
import aro::toolchain::darwin;
import aro::toolchain::discovery;
import aro::compilation;
import aro::diagnostics;
import aro::system_defaults;
import aro;
import std::collections::list;
import std::core::mem::allocators;
import std::collections::maybe;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn void check_args(List{String}* args, String[] expected)
{
	check(args.len(), expected.len);
	for (usz i = 0; i < expected.len; i++) check(args.get((sz)i), expected[i]);
}

fn uint diagnostic_count(diagnostics::Diagnostics* d, diagnostics::MessageKind kind, String text)
{
	uint count = 0;
	foreach (message : d.messages) if (message.kind == kind && message.text.contains(text)) count++;
	return count;
}

fn bool args_contain(List{String}* args, String expected)
{
	foreach (arg : *args) if (arg == expected) return true;
	return false;
}

fn void paths_with_spaces_and_cross_target_program_lookup() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/opt/SDK Tools/lib/crtbegin.o");
		tree.add_executable("/tool bins/aarch64-linux-gnu-ar");
		tree.add_executable("/tool bins/ar");
		tree.add_executable("/tool bins/ld");
		tree.add_executable("/tool bins/as");
		tree.add_executable("/path bins/ld");
		tree.add_executable("/path bins/path-tool");
		Options opts = {
			.raw_target_triple = maybe::value{String}("aarch64-linux-gnu"),
			.linker_path = maybe::value{String}("ld"),
		};
		discovery::Env env = {
			.fs = tree.fs(), .path = "/path bins", .target = target::from_triple("x86_64-linux-gnu")!!,
		};
		toolchain::Toolchain tc;
		tc.init(&ta, env, opts);
		tc.add_path_from_components({ "/opt/SDK Tools/lib" }, FILE)!!;
		tc.add_path_from_components({ "/tool bins" }, PROGRAM)!!;
		String crt = tc.get_file_path("crtbegin.o")!!;
		check(crt, "/opt/SDK Tools/lib/crtbegin.o");
		alloc::free(&ta, crt.ptr);
		char[128] buf;
		check(tc.get_program_path("ar", &buf), "/tool bins/aarch64-linux-gnu-ar");
		check(tc.get_linker_path(&buf)!!, "/path bins/ld"); // Zig getProgramPath: PATH lookup of the bare name runs after the prefixed name misses.
		// Zig's possibleProgramNames only returns the prefixed entry when a raw
		// triple is set; after that lookup misses, getProgramPath falls back to
		// the bare name instead of checking the unprefixed program directory.
		// See src/aro/Toolchain.zig:239-301.
		check(tc.get_assembler_path(&buf), "as");
		check(tc.get_program_path("path-tool", &buf), "/path bins/path-tool");
		tc.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn bool tree_accessed_exact(discovery::MemTree* tree, String path)
{
	foreach (access : tree.accesses) if (access == path) return true;
	return false;
}

fn void no_raw_triple_skips_program_paths() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_executable("/p/ld");
	toolchain::Toolchain tc;
	tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! });
	defer tc.free();
	tc.add_path_from_components({ "/p" }, PROGRAM)!!;
	char[64] buf;
	check(tc.get_program_path("ld", &buf), "ld");
}

fn void long_raw_triple_skips_prefixed_program_name() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	String triple = "123456789012345678901234567890123456789012345678901234567890";
	// 60 bytes + '-' + "ld.lld" is 67 bytes, so Zig's 64-byte formatting
	// buffer cannot produce this prefixed candidate.
	tree.add_executable("/tools/123456789012345678901234567890123456789012345678901234567890-ld.lld");
	tree.record = true;
	toolchain::Toolchain tc;
	tc.init(mem, {
		.fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!!,
	}, { .raw_target_triple = maybe::value{String}(triple) });
	defer tc.free();
	tc.add_path_from_components({ "/tools" }, PROGRAM)!!;
	char[128] buf;
	check(tc.get_program_path("ld.lld", &buf), "ld.lld");
	check(tree_accessed_exact(&tree, "/tools/123456789012345678901234567890123456789012345678901234567890-ld.lld"), false);
}

fn void path_lookup_skips_empty_component() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_executable("/ld");
	tree.add_executable("/bin/ld");
	tree.record = true;
	toolchain::Toolchain tc;
	tc.init(mem, {
		.fs = tree.fs(), .path = ":/bin", .target = target::from_triple("x86_64-linux-gnu")!!,
	}, { .raw_target_triple = maybe::value{String}("x86_64-linux-gnu") });
	defer tc.free();
	char[64] buf;
	check(tc.get_program_path("ld", &buf), "/bin/ld");
	check(tree_accessed_exact(&tree, "ld"), false);
}

fn void missing_program_returns_bare_name() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	toolchain::Toolchain tc;
	tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! },
		{ .linker_path = maybe::value{String}("missing-linker") });
	char[64] buf;
	check(tc.get_program_path("missing-tool", &buf), "missing-tool");
	check(@catch(tc.find_program_by_name("missing-tool", &buf)), discovery::NOT_FOUND);
	check(@catch(tc.get_linker_path(&buf)), toolchain::INVALID_LINKER_PATH);
	tree.add_file("/not-executable");
	check(@catch(tc.find_program_by_name("not-executable", &buf)), discovery::NOT_FOUND);
	tc.free();
}

fn void linux_linker_order_and_nodefaultlibs() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	Options opts = { .nodefaultlibs = true, .nostartfiles = true };
	toolchain::Toolchain tc;
	tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! }, opts);
	tc.inner = LINUX;
	List{String} args;
	args.init(mem);
	tc.build_linker_args("program", { "first.o", "second.o" }, &args)!!;
	// Zig Linux.buildLinkerArgs adds the standard dynamic linker for non-static, non-shared links.
	String[9] expected = { "--eh-frame-hdr", "-m", "elf_x86_64", "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-o", "program", "first.o", "second.o" };
	check(args.len(), expected.len);
	for (usz i = 0; i < expected.len; i++) check(args[(sz)i], expected[i]);
	foreach (arg : args) check(arg == "-lc" || arg == "-lgcc" || arg == "-lgcc_s", false);
	args.free();
	tc.free();
}

fn void linux_linker_user_and_toolchain_library_path_order() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	String[1] user_lib_dirs = { "/user/lib" };
	Options opts = { .nodefaultlibs = true, .nostartfiles = true, .user_lib_dirs = user_lib_dirs[..] };
	toolchain::Toolchain tc;
	tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! }, opts);
	tc.inner = LINUX;
	tc.add_path_from_components({ "/toolchain/lib" }, FILE)!!;
	List{String} args;
	args.init(mem);
	tc.build_linker_args("program", { "main.o", "-lm", "libfoo.a" }, &args)!!;
	String[12] expected = {
		"--eh-frame-hdr", "-m", "elf_x86_64", "-dynamic-linker",
		"/lib64/ld-linux-x86-64.so.2", "-o", "program", "-L/user/lib", "-L/toolchain/lib",
		"main.o", "-lm", "libfoo.a",
	};
	check_args(&args, &expected);
	String user_lib_arg = args[(sz)7];
	String toolchain_lib_arg = args[(sz)8];
	args.free();
	alloc::free(mem, user_lib_arg.ptr);
	alloc::free(mem, toolchain_lib_arg.ptr);
	tc.free();
}

fn void linux_linker_args_preserve_runtime_crt_and_mode_order() @test
{
	target::Target target = target::from_triple("x86_64-linux-gnu")!!;
	List{String} args;
	args.init(mem);
	toolchain::Toolchain pie_tc;
	pie_tc.init(mem, { .target = target });
	pie_tc.inner = LINUX;
	pie_tc.opts = { .pie = maybe::value{bool}(true) };
	pie_tc.build_linker_args("", { "main.o" }, &args)!!;
	String[23] pie_expected = {
		"-pie", "--eh-frame-hdr", "-m", "elf_x86_64", "-dynamic-linker",
		"/lib64/ld-linux-x86-64.so.2", "-o", "a.out", "Scrt1.o", "crti.o",
		"crtbeginS.o", "main.o", "-lgcc", "--as-needed", "-lgcc_s", "--no-as-needed",
		"-lc", "-lgcc", "--as-needed", "-lgcc_s", "--no-as-needed", "crtendS.o", "crtn.o",
	};
	check_args(&args, &pie_expected);
	args.clear();
	pie_tc.free();

	toolchain::Toolchain static_tc;
	static_tc.init(mem, { .target = target }, { .is_static = true, .nolibc = true });
	static_tc.inner = LINUX;
	static_tc.build_linker_args("static.out", { "main.o" }, &args)!!;
	String[16] static_expected = {
		"--eh-frame-hdr", "-m", "elf_x86_64", "-static", "-o", "static.out",
		"crt1.o", "crti.o", "crtbeginT.o", "main.o", "--start-group", "-lgcc",
		"-lgcc_eh", "--end-group", "crtend.o", "crtn.o",
	};
	check_args(&args, &static_expected);
	args.clear();
	static_tc.free();

	toolchain::Toolchain shared_tc;
	shared_tc.init(mem, { .target = target }, { .shared = true, .nodefaultlibs = true });
	shared_tc.inner = LINUX;
	shared_tc.build_linker_args("shared.so", { "main.o" }, &args)!!;
	String[11] shared_expected = {
		"--eh-frame-hdr", "-m", "elf_x86_64", "-shared", "-o", "shared.so",
		"crti.o", "crtbeginS.o", "main.o", "crtendS.o", "crtn.o",
	};
	check_args(&args, &shared_expected);
	args.clear();
	shared_tc.free();

	toolchain::Toolchain static_pie_tc;
	diagnostics::Diagnostics static_pie_d;
	static_pie_d.init_list(mem);
	static_pie_tc.init(mem, { .target = target }, {
		.static_pie = true, .pie = maybe::value{bool}(true), .nostdlib = true,
	});
	static_pie_tc.diagnostics = &static_pie_d;
	static_pie_tc.inner = LINUX;
	static_pie_tc.build_linker_args("static-pie.out", { "main.o" }, &args)!!;
	String[11] static_pie_expected = {
		"-static", "-pie", "--no-dynamic-linker", "-z", "text", "--eh-frame-hdr",
		"-m", "elf_x86_64", "-o", "static-pie.out", "main.o",
	};
	check_args(&args, &static_pie_expected);
	check(diagnostic_count(&static_pie_d, diagnostics::MessageKind.ERROR,
		"cannot specify 'nopie' along with 'static-pie'"), 1);
	args.clear();
	args.free();
	static_pie_tc.free();
	static_pie_d.free();
}

fn void linux_unwindlib_libgcc_reports_error_and_keeps_unwind_arg() @test
{
	toolchain::Toolchain tc;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	tc.init(mem, { .target = target::from_triple("x86_64-linux-gnu")!! }, {
		.unwindlib = maybe::value{String}("libunwind"),
		.rtlib = maybe::value{String}("libgcc"),
	});
	tc.diagnostics = &d;
	tc.inner = LINUX;
	List{String} args;
	args.init(mem);
	tc.build_linker_args("program", { "main.o" }, &args)!!;
	check(diagnostic_count(&d, diagnostics::MessageKind.ERROR,
		"--rtlib=libgcc requires --unwindlib=libgcc") >= 1, true);
	check(args_contain(&args, "-lunwind"), true);
	args.free();
	tc.free();
	d.free();
}

fn void builtin_headers_resolve_from_installed_layout_and_validate_resource_dir() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_file("/opt/aro/include/stddef.h");
	toolchain::Toolchain tc;
	// Match Zig passing the executable directory as aro_name and searching its parent
	// for builtin headers (src/aro/Toolchain.zig:315-318, 589-597).
	tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! },
		{ .aro_name = "/opt/aro/bin" });
	List{IncludeDir} includes;
	includes.init(mem);
	tc.add_builtin_include_dir(&includes)!!;
	check(includes.len(), 1);
	check(includes[0].path, "/opt/aro/include");
	foreach (include : includes) alloc::free(mem, include.path.ptr);
	includes.free();
	tc.free();
	tree.add_file("/runfiles/_main/include/stddef.h");
	toolchain::Toolchain runfiles_tc;
	runfiles_tc.init(mem, {
		.fs = tree.fs(), .runfiles_dir = "/runfiles", .target = target::from_triple("x86_64-linux-gnu")!!,
	});
	List{IncludeDir} runfiles_includes;
	runfiles_includes.init(mem);
	runfiles_tc.add_builtin_include_dir(&runfiles_includes)!!;
	check(runfiles_includes.len(), 1);
	check(runfiles_includes[0].path, "/runfiles/_main/include");
	foreach (include : runfiles_includes) alloc::free(mem, include.path.ptr);
	runfiles_includes.free();
	runfiles_tc.free();

	toolchain::Toolchain explicit_tc;
	explicit_tc.init(mem, { .fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!! },
		{ .resource_dir = maybe::value{String}("/missing/resource") });
	List{IncludeDir} explicit_includes;
	explicit_includes.init(mem);
	check(@catch(explicit_tc.add_builtin_include_dir(&explicit_includes)), toolchain::RESOURCE_DIR_NOT_FOUND);
	explicit_includes.free();
	explicit_tc.free();
}

struct FakeProcess
{
	bool started;
	bool exited;
	int exit_code;
	String stdout;
	String stderr;
	usz calls;
	String sdk;
	String arg;
}

fn ProcessResult fake_process_run(void* ctx, Allocator a, String[] argv)
{
	FakeProcess* fake = ctx;
	fake.calls++;
	check(argv.len, 4);
	check(argv[0], "xcrun");
	check(argv[1], "--sdk");
	fake.sdk = argv[2];
	fake.arg = argv[3];
	// Empty output is a null slice: the caller frees any non-null buffer.
	String out;
	String err;
	if (fake.stdout.len) out = fake.stdout.copy(a);
	if (fake.stderr.len) err = fake.stderr.copy(a);
	return { .started = fake.started, .exited = fake.exited, .exit_code = fake.exit_code, .stdout = out, .stderr = err };
}

fn void darwin_xcrun_sdk_success_and_status_failures() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_dir("/SDK with spaces");
	FakeProcess fake = { .started = true, .exited = true, .stdout = "/SDK with spaces\n" };
	discovery::Env env = { .fs = tree.fs(), .process = { .ctx = &fake, .run = &fake_process_run } };
	String sdk = darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")!!;
	defer alloc::free(mem, sdk.ptr);
	check(sdk, "/SDK with spaces");
	check(fake.calls, 1);
	check(fake.sdk, "macosx");
	check(fake.arg, "--show-sdk-path");

	fake.started = false;
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::XCRUN_FAILED);
	fake.started = true;
	fake.exited = false;
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::XCRUN_FAILED);
	fake.exited = true;
	fake.exit_code = 1;
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::XCRUN_FAILED);
}

fn void darwin_xcrun_stdout_and_stderr_failures() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_dir("/SDK");
	FakeProcess fake = { .started = true, .exited = true, .stdout = "/SDK" };
	discovery::Env env = { .fs = tree.fs(), .process = { .ctx = &fake, .run = &fake_process_run } };
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::INVALID_XCRUN_OUTPUT);
	fake.stdout = "\n";
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::INVALID_XCRUN_OUTPUT);
	fake.stdout = "/SDK\nextra\n";
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::INVALID_XCRUN_OUTPUT);
	fake.stdout = "/missing SDK\n";
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::INVALID_XCRUN_OUTPUT);
	fake.stdout = "/SDK\n";
	fake.stderr = "warning\n";
	check(@catch(darwin::xcrun_path(mem, &env, darwin::Sdk.MACOSX, "--show-sdk-path")), darwin::XCRUN_FAILED);
}

fn void darwin_system_include_order_uses_injected_sdk_path() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_dir("/SDK with spaces");
	FakeProcess fake = { .started = true, .exited = true, .stdout = "/SDK with spaces\n" };
	discovery::Env env = {
		.fs = tree.fs(), .process = { .ctx = &fake, .run = &fake_process_run },
		.host_is_darwin = true, .target = target::from_triple("x86_64-macos-none")!!,
	};
	toolchain::Toolchain tc;
	tc.init(mem, env, { .nobuiltininc = true });
	List{IncludeDir} includes;
	includes.init(mem);
	darwin::define_system_includes(&tc, &tc.env, &includes, true)!!;
	check(includes.len(), 3);
	check(includes[0].path, "usr/local/include"); // Zig Darwin.zig joins {"usr","local","include"}: relative.
	check(includes[1].path, "/SDK with spaces/usr/local/include");
	check(includes[2].path, "/SDK with spaces/usr/include");
	foreach (include : includes) alloc::free(mem, include.path.ptr);
	includes.free();
	tc.free();
}

fn void linux_system_includes_use_sysroot_and_multiarch_paths() @test
{
	MemTree tree;
	tree.init(mem);
	defer tree.free();
	tree.add_dir("/sr/usr/include/x86_64-linux-gnu");
	toolchain::Toolchain tc;
	tc.init(mem, {
		.fs = tree.fs(), .target = target::from_triple("x86_64-linux-gnu")!!,
	}, { .sysroot = maybe::value{String}("/sr"), .nobuiltininc = true });
	tc.inner = LINUX;
	List{IncludeDir} includes;
	includes.init(mem);
	tc.define_system_includes(&includes)!!;
	String[4] expected = {
		"/sr/usr/local/include", "/sr/usr/include/x86_64-linux-gnu", "/include", "/usr/include",
	};
	check(includes.len(), expected.len);
	for (usz i = 0; i < expected.len; i++) check(includes[(sz)i].path, expected[i]);
	foreach (include : includes) alloc::free(mem, include.path.ptr);
	includes.free();
	tc.free();

	toolchain::Toolchain rtems_tc;
	rtems_tc.init(mem, {
		.fs = tree.fs(), .target = target::from_triple("x86_64-rtems")!!,
	}, { .sysroot = maybe::value{String}("/sr"), .nobuiltininc = true });
	rtems_tc.inner = LINUX;
	List{IncludeDir} rtems_includes;
	rtems_includes.init(mem);
	rtems_tc.define_system_includes(&rtems_includes)!!;
	String[2] rtems_expected = { "/sr/usr/local/include", "/sr/usr/include/x86_64-linux-gnu" };
	check(rtems_includes.len(), rtems_expected.len);
	for (usz i = 0; i < rtems_expected.len; i++) check(rtems_includes[(sz)i].path, rtems_expected[i]);
	foreach (include : rtems_includes) alloc::free(mem, include.path.ptr);
	rtems_includes.free();
	rtems_tc.free();
}

fn void? zig_fake_list_dir(void* ctx, String path, Allocator a, discovery::DirEntryList* out)
{
	(void)ctx;
	(void)path;
	(void)a;
	(void)out;
	return discovery::NOT_A_DIRECTORY~;
}

fn void linux_zig_test() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	MemTree tree;
	tree.init(&arena);
	defer tree.free();
	// The Zig fake I/O exposes these exact paths to access/execute checks. Its
	// directory iterator reports NOT_A_DIRECTORY, so no GCC version is selected.
	tree.add_dir("/tmp");
	tree.add_dir("/usr/lib64");
	tree.add_dir("/usr/bin");
	tree.add_executable("/usr/bin/ld");
	tree.add_dir("/lib/x86_64-linux-gnu");
	tree.add_file("/lib/x86_64-linux-gnu/crt1.o");
	tree.add_file("/lib/x86_64-linux-gnu/crti.o");
	tree.add_file("/lib/x86_64-linux-gnu/crtn.o");
	tree.add_dir("/lib64");
	tree.add_dir("/usr/lib");
	tree.add_dir("/usr/lib/gcc/x86_64-linux-gnu/9");
	tree.add_file("/usr/lib/gcc/x86_64-linux-gnu/9/crtbegin.o");
	tree.add_file("/usr/lib/gcc/x86_64-linux-gnu/9/crtend.o");
	tree.add_dir("/usr/lib/x86_64-linux-gnu");
	tree.add_file("/etc/lsb-release",
		"DISTRIB_ID=Ubuntu\nDISTRIB_RELEASE=20.04\nDISTRIB_CODENAME=focal\nDISTRIB_DESCRIPTION=\"Ubuntu 20.04.6 LTS\"\n");

	discovery::FileSystem fs = tree.fs();
	fs.list_dir_fn = &zig_fake_list_dir;
	discovery::Env env = {
		.fs = fs,
		.path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		.target = target::from_triple("x86_64-linux-gnu")!!,
	};
	toolchain::Toolchain tc;
	tc.init(&arena, env, { .raw_target_triple = maybe::value{String}("x86_64-linux-gnu") });
	defer tc.free();
	tc.discover()!!;
	check(system_defaults::ENABLE_LINKER_BUILD_ID, false);
	check(system_defaults::LINKER, "ld");
	char[128] linker_buf;
	List{String} args;
	args.init(&arena);
	defer args.free();
	args.push(tc.get_linker_path(&linker_buf)!!);
	tc.build_linker_args("", { "/tmp/foo.o" }, &args)!!;
	String[32] expected = {
		"/usr/bin/ld",
		"-z", "relro", "--hash-style=gnu",
		"--eh-frame-hdr", "-m", "elf_x86_64",
		"-dynamic-linker", "/lib64/ld-linux-x86-64.so.2",
		"-o", "a.out",
		"/lib/x86_64-linux-gnu/crt1.o", "/lib/x86_64-linux-gnu/crti.o", "crtbegin.o",
		"-L/lib/x86_64-linux-gnu", "-L/lib/../lib64",
		"-L/usr/lib/x86_64-linux-gnu", "-L/usr/lib/../lib64",
		"-L/lib", "-L/usr/lib",
		"/tmp/foo.o",
		"-lgcc", "--as-needed", "-lgcc_s", "--no-as-needed", "-lc",
		"-lgcc", "--as-needed", "-lgcc_s", "--no-as-needed",
		"crtend.o", "/lib/x86_64-linux-gnu/crtn.o",
	};
	check_args(&args, &expected);
}
