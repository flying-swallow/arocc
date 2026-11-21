// Linker argv parsing and library lookup tests.
module link_args_tests;
import aro::backend::link;
import aro::frontend::c::diagnostics;
import aro::target;
import aro::toolchain;
import aro::toolchain::discovery;
import std::collections::list;
import std::core::mem, std::core::mem::allocators;
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

fn void check_input(link::LinkPlan* plan, sz index, link::LinkItemKind kind, String value,
	bool as_needed = false, bool static_only = false, bool whole_archive = false, bool exact = false)
{
	link::LinkItem item = plan.inputs[index];
	check(item.kind, kind);
	check(item.value, value);
	check(item.as_needed, as_needed);
	check(item.static_only, static_only);
	check(item.whole_archive, whole_archive);
	check(item.exact, exact);
}

fn bool has_input(link::LinkPlan* plan, link::LinkItemKind kind, String value)
{
	foreach (item : plan.inputs) if (item.kind == kind && item.value == value) return true;
	return false;
}

fn void? zig_fake_list_dir(void* ctx, String path, Allocator a, discovery::DirEntryList* out)
{
	(void)ctx;
	(void)path;
	(void)a;
	(void)out;
	return discovery::NOT_A_DIRECTORY~;
}

fn void default_dynamic_exe_ubuntu() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 4096);
	defer arena.free();
	discovery::MemTree tree;
	tree.init(&arena);
	defer tree.free();
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
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("", { "/tmp/foo.o" }, &args)!!;
	String[31] expected = {
		"-z", "relro", "--hash-style=gnu", "--eh-frame-hdr", "-m", "elf_x86_64",
		"-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-o", "a.out",
		"/lib/x86_64-linux-gnu/crt1.o", "/lib/x86_64-linux-gnu/crti.o", "crtbegin.o",
		"-L/lib/x86_64-linux-gnu", "-L/lib/../lib64", "-L/usr/lib/x86_64-linux-gnu",
		"-L/usr/lib/../lib64", "-L/lib", "-L/usr/lib", "/tmp/foo.o", "-lgcc",
		"--as-needed", "-lgcc_s", "--no-as-needed", "-lc", "-lgcc", "--as-needed",
		"-lgcc_s", "--no-as-needed", "crtend.o", "/lib/x86_64-linux-gnu/crtn.o",
	};
	check_args(&args, expected[..]);

	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.kind, link::OutputKind.EXEC);
	check(plan.output, "a.out");
	check(plan.emulation, "elf_x86_64");
	check(plan.has_emulation, true);
	check(plan.dynamic_linker, "/lib64/ld-linux-x86-64.so.2");
	check(plan.has_dynamic_linker, true);
	check(plan.z_relro, true);
	check(plan.eh_frame_hdr, true);
	check(plan.has_hash_style, true);
	check(plan.hash_style, "gnu");
	String[6] expected_dirs = {
		"/lib/x86_64-linux-gnu", "/lib/../lib64", "/usr/lib/x86_64-linux-gnu",
		"/usr/lib/../lib64", "/lib", "/usr/lib",
	};
	check(plan.search_dirs.len(), expected_dirs.len);
	for (usz i = 0; i < expected_dirs.len; i++) check(plan.search_dirs[(sz)i], expected_dirs[i]);
	check(plan.inputs.len(), 11);
	check_input(&plan, 0, link::LinkItemKind.FILE, "/lib/x86_64-linux-gnu/crt1.o");
	check_input(&plan, 1, link::LinkItemKind.FILE, "/lib/x86_64-linux-gnu/crti.o");
	check_input(&plan, 2, link::LinkItemKind.FILE, "crtbegin.o");
	check_input(&plan, 3, link::LinkItemKind.FILE, "/tmp/foo.o");
	check_input(&plan, 4, link::LinkItemKind.LIBRARY, "gcc");
	check_input(&plan, 5, link::LinkItemKind.LIBRARY, "gcc_s", true);
	check_input(&plan, 6, link::LinkItemKind.LIBRARY, "c");
	check_input(&plan, 7, link::LinkItemKind.LIBRARY, "gcc");
	check_input(&plan, 8, link::LinkItemKind.LIBRARY, "gcc_s", true);
	check_input(&plan, 9, link::LinkItemKind.FILE, "crtend.o");
	check_input(&plan, 10, link::LinkItemKind.FILE, "/lib/x86_64-linux-gnu/crtn.o");
	check(d.messages.len(), 0);
}

fn void pie_and_rdynamic_strip() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	toolchain::Toolchain tc;
	tc.init(&arena, { .target = target::from_triple("x86_64-linux-gnu")!! }, {
		.pie = maybe::value{bool}(true), .rdynamic = true, .strip = true,
	});
	tc.inner = toolchain::InnerKind.LINUX;
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("", { "main.o" }, &args)!!;
	uint export_count = 0;
	foreach (arg : args) if (arg == "-export-dynamic") export_count++;
	check(export_count, 2);
	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.kind, link::OutputKind.PIE);
	check(plan.export_dynamic, true);
	check(plan.strip_all, true);
	check(d.messages.len(), 0);
}

fn void static_group() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	toolchain::Toolchain tc;
	tc.init(&arena, { .target = target::from_triple("x86_64-linux-gnu")!! }, { .is_static = true });
	tc.inner = toolchain::InnerKind.LINUX;
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("", { "main.o" }, &args)!!;
	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.kind, link::OutputKind.STATIC);
	check(plan.inputs.len(), 11);
	check_input(&plan, 0, link::LinkItemKind.FILE, "crt1.o", false, true);
	check_input(&plan, 1, link::LinkItemKind.FILE, "crti.o", false, true);
	check_input(&plan, 2, link::LinkItemKind.FILE, "crtbeginT.o", false, true);
	check_input(&plan, 3, link::LinkItemKind.FILE, "main.o", false, true);
	check(plan.inputs[4].kind, link::LinkItemKind.GROUP_START);
	check_input(&plan, 5, link::LinkItemKind.LIBRARY, "gcc", false, true);
	check_input(&plan, 6, link::LinkItemKind.LIBRARY, "gcc_eh", false, true);
	check_input(&plan, 7, link::LinkItemKind.LIBRARY, "c", false, true);
	check(plan.inputs[8].kind, link::LinkItemKind.GROUP_END);
	check_input(&plan, 9, link::LinkItemKind.FILE, "crtend.o", false, true);
	check_input(&plan, 10, link::LinkItemKind.FILE, "crtn.o", false, true);
	foreach (item : plan.inputs) check(item.static_only, true);
}

fn void static_pie() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	toolchain::Toolchain tc;
	tc.init(&arena, { .target = target::from_triple("x86_64-linux-gnu")!! }, { .static_pie = true });
	tc.inner = toolchain::InnerKind.LINUX;
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("", { "main.o" }, &args)!!;
	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.kind, link::OutputKind.STATIC_PIE);
	check(plan.no_dynamic_linker, true);
	check(plan.z_text, true);
	check_input(&plan, 0, link::LinkItemKind.FILE, "rcrt1.o", false, true);
}

fn void shared() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	toolchain::Toolchain tc;
	tc.init(&arena, { .target = target::from_triple("x86_64-linux-gnu")!! }, {
		.shared = true, .nodefaultlibs = true,
	});
	tc.inner = toolchain::InnerKind.LINUX;
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("output.so", { "main.o" }, &args)!!;
	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.kind, link::OutputKind.SHARED);
	check(plan.output, "output.so");
	check(plan.has_dynamic_linker, false);
	check(d.messages.len(), 0);
}

fn void user_libs_in_order() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	String[1] user_lib_dirs = { "/user/lib" };
	toolchain::Toolchain tc;
	tc.init(&arena, { .target = target::from_triple("x86_64-linux-gnu")!! }, {
		.nodefaultlibs = true, .nostartfiles = true, .user_lib_dirs = user_lib_dirs[..],
	});
	tc.inner = toolchain::InnerKind.LINUX;
	List{String} args;
	args.init(&arena);
	defer args.free();
	tc.build_linker_args("p", { "main.o", "-lm", "-l:libfoo.a", "libbar.so" }, &args)!!;
	diagnostics::Diagnostics d;
	d.init_list(&arena);
	defer d.free();
	link::LinkPlan plan;
	plan.init(&arena);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args.array_view())!!;
	check(plan.search_dirs.len(), 1);
	check(plan.search_dirs[0], "/user/lib");
	check(has_input(&plan, link::LinkItemKind.LIBRARY, "m"), true);
	check(has_input(&plan, link::LinkItemKind.LIBRARY, "libfoo.a"), true);
	check(has_input(&plan, link::LinkItemKind.FILE, "libbar.so"), true);
	check(plan.inputs.len(), 4);
	check_input(&plan, 0, link::LinkItemKind.FILE, "main.o");
	check_input(&plan, 1, link::LinkItemKind.LIBRARY, "m");
	check_input(&plan, 2, link::LinkItemKind.LIBRARY, "libfoo.a", false, false, false, true);
	check_input(&plan, 3, link::LinkItemKind.FILE, "libbar.so");
}

fn void manual_flags() @test
{
	String[21] args = {
		"-Bstatic", "-lx", "-Bdynamic", "--as-needed", "-ly", "--no-as-needed",
		"--whole-archive", "a.a", "--no-whole-archive", "-e", "start", "-z", "now",
		"-z", "noexecstack", "-zmax-page-size=0x200000", "-L", "/d", "-o", "out", "x.o",
	};
	diagnostics::Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::LinkPlan plan;
	plan.init(mem);
	defer plan.free();
	link::parse_ld_args(&plan, &d, args[..])!!;
	check(plan.inputs.len(), 4);
	check_input(&plan, 0, link::LinkItemKind.LIBRARY, "x", false, true);
	check_input(&plan, 1, link::LinkItemKind.LIBRARY, "y", true);
	check_input(&plan, 2, link::LinkItemKind.FILE, "a.a", false, false, true);
	check_input(&plan, 3, link::LinkItemKind.FILE, "x.o");
	check(plan.has_entry, true);
	check(plan.entry, "start");
	check(plan.z_now, true);
	check(plan.z_noexecstack, true);
	check(plan.has_max_page_size, true);
	check(plan.max_page_size, 0x200000);
	check(plan.search_dirs.len(), 1);
	check(plan.search_dirs[0], "/d");
	check(plan.output, "out");
	check(d.messages.len(), 0);
}

fn void expect_reject(String[] args, bool unsupported, String unsupported_arg = "")
{
	diagnostics::Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::LinkPlan plan;
	plan.init(mem);
	defer plan.free();
	if (unsupported)
	{
		check(@catch(link::parse_ld_args(&plan, &d, args)), link::UNSUPPORTED_LD_ARG);
		check(plan.unsupported_arg, unsupported_arg);
	}
	else
	{
		check(@catch(link::parse_ld_args(&plan, &d, args)), link::MALFORMED_LD_ARGS);
	}
	check(d.messages.len(), 1);
	check(d.messages[0].kind, diagnostics::MessageKind.NOTE);
	check(d.messages[0].effective_kind, diagnostics::MessageKind.NOTE);
	check(d.errors, 0);
}

fn void rejects() @test
{
	String[1] relocatable = { "-r" };
	expect_reject(relocatable[..], true, "-r");
	String[1] gc_sections = { "--gc-sections" };
	expect_reject(gc_sections[..], true, "--gc-sections");
	String[2] bad_emulation = { "-m", "elf_i386" };
	expect_reject(bad_emulation[..], true, "-m");
	String[2] bad_z = { "-z", "ignore" };
	expect_reject(bad_z[..], true, "-z");
	String[1] missing_output = { "-o" };
	expect_reject(missing_output[..], false);
	String[1] unmatched_end = { "--end-group" };
	expect_reject(unmatched_end[..], false);
	String[2] nested_group = { "--start-group", "--start-group" };
	expect_reject(nested_group[..], false);
	String[1] unclosed_group = { "--start-group" };
	expect_reject(unclosed_group[..], false);
}

fn void find_library_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		LinkFs fs;
		fs.init(&ta);
		fs.add_overlay("/nonexistent-aro-link/r/a/libm.a", "");
		fs.add_overlay("/nonexistent-aro-link/r/b/libm.so", "");
		fs.add_overlay("/nonexistent-aro-link/r/b/libq.so", "");
		link::LinkPlan plan;
		plan.init(&ta);
		plan.search_dirs.push("/nonexistent-aro-link/r/a");
		plan.search_dirs.push("/nonexistent-aro-link/r/b");
		String path = link::find_library(&ta, &fs, &plan, "m", false, false)!!;
		check(path, "/nonexistent-aro-link/r/a/libm.a");
		alloc::free(&ta, path.ptr);
		path = link::find_library(&ta, &fs, &plan, "m", false, true)!!;
		check(path, "/nonexistent-aro-link/r/a/libm.a");
		alloc::free(&ta, path.ptr);
		path = link::find_library(&ta, &fs, &plan, "q", false, false)!!;
		check(path, "/nonexistent-aro-link/r/b/libq.so");
		alloc::free(&ta, path.ptr);
		check(@catch(link::find_library(&ta, &fs, &plan, "q", false, true)), link::LIBRARY_NOT_FOUND);
		path = link::find_library(&ta, &fs, &plan, "libm.so", true, false)!!;
		check(path, "/nonexistent-aro-link/r/b/libm.so");
		alloc::free(&ta, path.ptr);
		check(@catch(link::find_library(&ta, &fs, &plan, "zz", false, false)), link::LIBRARY_NOT_FOUND);
		plan.free();
		fs.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void link_plan_allocation_leak_check() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		link::LinkPlan plan;
		plan.init(&ta);
		String[4] args = { "-L/one", "-o", "out", "input.o" };
		link::parse_ld_args(&plan, &d, args[..])!!;
		plan.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void host_libc_lookup() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		LinkFs fs;
		fs.init(&ta);
		String libc_link = "/usr/lib/x86_64-linux-gnu/libc.so";
		if (fs.exists(libc_link))
		{
			link::LinkPlan plan;
			plan.init(&ta);
			plan.search_dirs.push("/usr/lib/x86_64-linux-gnu");
			String path = link::find_library(&ta, &fs, &plan, "c", false, false)!!;
			check(path, libc_link);
			alloc::free(&ta, path.ptr);
			String libc_static = "/usr/lib/x86_64-linux-gnu/libc.a";
			if (fs.exists(libc_static))
			{
				path = link::find_library(&ta, &fs, &plan, "c", false, true)!!;
				check(path, libc_static);
				alloc::free(&ta, path.ptr);
			}
			plan.free();
		}
		fs.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

