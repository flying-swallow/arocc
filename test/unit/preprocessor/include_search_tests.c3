// Tests for Compilation's ordered include lookup. All paths and bytes come
// from an injected synthetic tree; these tests never include host files.
module include_search_tests;
import aro::frontend::c::compilation, aro::frontend::c::dep_file, aro::frontend::c::include_search, aro::frontend::c::preprocessor, aro::source;
import aro::frontend::c::tokenizer;
import aro::toolchain::discovery;
import std::core::mem::allocators;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

excuse NO_TEST_FILE;

fn bool tree_exists(void* ctx, String path)
{
	MemTree* tree = ctx;
	uint? found = tree.resolve(path);
	if (catch found) return false;
	return true;
}

fn bool recording_tree_exists(void* ctx, String path)
{
	MemTree* tree = ctx;
	tree.log(path);
	return false;
}

fn char[]? tree_read(void* ctx, Allocator a, String path, ulong limit)
{
	MemTree* tree = ctx;
	uint? found = tree.resolve(path);
	if (catch found) return NO_TEST_FILE~;
	if (tree.nodes[found].kind != FILE) return NO_TEST_FILE~;
	String contents = tree.nodes[found].contents;
	usz len = contents.len;
	if (limit != ulong::max && len > limit) len = (usz)limit;
	char* owned = alloc::malloc(a, (sz)len + 1);
	if (len) mem::copy(owned, contents.ptr, (sz)len);
	owned[len] = 0;
	return owned[:len];
}

fn void setup_files(MemTree* tree, Compilation* comp)
{
	comp.include_files = { .ctx = tree, .exists = &tree_exists, .read = &tree_read };
	comp.cwd = "/work";
}

fn Source add_source(Compilation* comp, String path) => comp.add_source_from_buffer(path, "")!!;

fn void ordered_classes_and_path_forms() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "");
		tree.add_file("/work/h.h", "cwd");
		tree.add_file("/work/q/h.h", "iquote");
		tree.add_file("/work/i/h.h", "normal");
		tree.add_file("/work/i/fallback.h", "include-dir");
		tree.add_file("/work/s/h.h", "system");
		tree.add_file("/work/a/h.h", "after");
		tree.add_file("/work/s/late.h", "system");
		tree.add_file("/work/a/late.h", "after");
		tree.add_file("/work/a/after.h", "after-only");
		tree.add_file("/absolute/h.h", "absolute");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = AFTER, .path = "/work/a" },
			{ .kind = SYSTEM, .path = "/work/s" },
			{ .kind = NORMAL, .path = "/work/./i/../i" },
			{ .kind = NORMAL, .path = "/missing" },
			{ .kind = QUOTE, .path = "/work/q" },
			{ .kind = QUOTE, .path = "/work/q" }, // duplicate is removed
		}, true);
		bool kept_missing = false;
		foreach (dir : comp.include_dirs) if (dir.path == "/missing") kept_missing = true;
		check(kept_missing, false);
		Source main = add_source(&comp, "/else/main.c");
		Source found = comp.search_include("h.h", main.id, QUOTES, FIRST, null)!!;
		check(found.path, "/work/q/h.h");
		check(found.kind.ordinal, SourceKind.USER.ordinal);
		found = comp.search_include("h.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/work/i/h.h");
		found = comp.search_include("late.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/work/s/late.h");
		check(found.kind.ordinal, SourceKind.SYSTEM.ordinal);
		found = comp.search_include("after.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/work/a/after.h");
		check(found.kind.ordinal, SourceKind.SYSTEM.ordinal);
		found = comp.search_include("h.h", main.id, CLI, FIRST, null)!!;
		check(found.path, "/work/h.h"); // CLI begins at the explicit cwd
		found = comp.search_include("fallback.h", main.id, CLI, FIRST, null)!!;
		check(found.path, "/work/i/fallback.h"); // A cwd miss continues through include dirs
		found = comp.search_include("/absolute/h.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/absolute/h.h");
		check(@catch(comp.search_include("/absolute/h.h", main.id, QUOTES, NEXT, null)), preprocessor::FILE_NOT_FOUND);
		check(@catch(comp.search_include("bad\x00name.h", main.id, QUOTES, FIRST, null)), preprocessor::FILE_NOT_FOUND);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void system_directory_shadows_duplicate_normal_directory() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/first/header.h", "first");
		tree.add_file("/inc/header.h", "system");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = NORMAL, .path = "/inc" },
			{ .kind = NORMAL, .path = "/first" },
			{ .kind = SYSTEM, .path = "/inc" },
		});
		Source main = add_source(&comp, "/main.c");
		Source found = comp.search_include("header.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/first/header.h");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void quoted_and_include_next() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/w/src/main.c", "");
		tree.add_file("/w/src/local.h", "local");
		tree.add_file("/alias/local.h", "alias-relative");
		tree.add_file("/w/quote/local.h", "quote");
		tree.add_file("/w/inc/local.h", "normal");
		tree.add_file("/w/sys/local.h", "system");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = QUOTE, .path = "/w/quote" },
			{ .kind = NORMAL, .path = "/w/inc" },
			{ .kind = SYSTEM, .path = "/w/sys" },
		});
		Source main = add_source(&comp, "/w/src/main.c");
		SourceId alias_id = comp.add_source_alias(main.id, "/alias/main.c", USER);
		Source alias_relative = comp.search_include("local.h", alias_id, QUOTES, FIRST, null)!!;
		check(alias_relative.path, "/alias/local.h");
		Source found = comp.search_include("local.h", main.id, QUOTES, FIRST, null)!!;
		check(found.path, "/w/src/local.h");
		// A header found in the quote directory starts include_next after it.
		Source quote = add_source(&comp, "/w/quote/local.h");
		found = comp.search_include("local.h", quote.id, QUOTES, NEXT, null)!!;
		check(found.path, "/w/inc/local.h");
		check(found.kind.ordinal, SourceKind.USER.ordinal);
		Source normal = add_source(&comp, "/w/inc/local.h");
		found = comp.search_include("local.h", normal.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(found.path, "/w/sys/local.h");
		check(found.kind.ordinal, SourceKind.SYSTEM.ordinal);
		check(@catch(comp.search_include("local.h", main.id, ANGLE_BRACKETS, NEXT, null)), preprocessor::FILE_NOT_FOUND);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void microsoft_cwd_search_reports_extension() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/ms/header.h", "ms");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = add_source(&comp, "/work/main.c");
		Source ms = add_source(&comp, "/ms/anchor.c");
		comp.ms_cwd_source_id = ms.id;
		Preprocessor pp = { .comp = &comp };
		FileProvider files = comp.file_provider();
		Token tok = { .id = INVALID, .source = main.id, .start = 0, .line = 1 };
		Source found = files.find_include(files.ctx, &pp, "header.h", tok, QUOTES, FIRST)!!;
		check(found.path, "/ms/header.h");
		check(comp.warning_count(), 1);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void ms_warning_only_on_ms_cwd_fallback() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/header.h", "cwd");
		tree.add_file("/inc/header.h", "include-dir");
		tree.add_file("/inc/fallback.h", "include-dir");
		tree.add_file("/ms/other.h", "ms");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({ { .kind = NORMAL, .path = "/inc" } });
		Source main = add_source(&comp, "/work/main.c");
		Source ms = add_source(&comp, "/ms/anchor.c");
		comp.ms_cwd_source_id = ms.id;
		Preprocessor pp = { .comp = &comp };
		FileProvider files = comp.file_provider();
		Token tok = { .id = INVALID, .source = main.id, .start = 0, .line = 1 };
		files.find_include(files.ctx, &pp, "fallback.h", tok, QUOTES, FIRST)!!;
		check(comp.warning_count(), 0);
		files.find_include(files.ctx, &pp, "header.h", tok, QUOTES, FIRST)!!;
		check(comp.warning_count(), 0);
		files.find_include(files.ctx, &pp, "other.h", tok, QUOTES, FIRST)!!;
		check(comp.warning_count(), 1);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void framework_subframework_and_reuse() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/sdk/Foo.framework/Headers/Foo.h", "foo");
		tree.add_file("/sdk/Foo.framework/Frameworks/Bar.framework/Headers/Bar.h", "bar");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({ { .kind = SYSTEM_FRAMEWORK, .path = "/sdk" } });
		Source main = add_source(&comp, "/main.c");
		Source? result = comp.search_include("Foo/Foo.h", main.id, ANGLE_BRACKETS, FIRST, null);
		Source foo = result!!;
		check(foo.path, "/sdk/Foo.framework/Headers/Foo.h");
		check(foo.has_umbrella_framework_path(), true);
		check(foo.umbrella_framework_path, "/sdk/Foo.framework");
		check(foo.kind.ordinal, SourceKind.SYSTEM.ordinal);
		check(comp.get_source(foo.id).umbrella_framework_path, foo.umbrella_framework_path);
		// Add the child framework by explicit search dir; framework nesting is
		// resolved relative to the umbrella framework recorded on Foo.h.
		Source bar = comp.search_include("Bar/Bar.h", foo.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(bar.path, "/sdk/Foo.framework/Frameworks/Bar.framework/Headers/Bar.h");
		check(bar.umbrella_framework_path, foo.umbrella_framework_path);
		check(bar.kind.ordinal, SourceKind.SYSTEM.ordinal);
		uint count = (uint)comp.sources.len();
		Source again = comp.search_include("Foo/Foo.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(again.id.index, foo.id.index);
		check((uint)comp.sources.len(), count);
		SourceId alias_id = comp.add_source_alias(main.id, "/alias/main.c", SYSTEM);
		check(comp.get_source(alias_id).path, "/alias/main.c");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void framework_include_next_continues_to_next_root() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/sdk/frameworks/SimpleFramework.framework/Headers/Foo.h", "first");
		tree.add_file("/sdk/next/SimpleFramework.framework/Headers/Foo.h", "second");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = SYSTEM_FRAMEWORK, .path = "/sdk/frameworks" },
			{ .kind = SYSTEM_FRAMEWORK, .path = "/sdk/next" },
		});
		Source main = add_source(&comp, "/main.c");
		Source first = comp.search_include("SimpleFramework/Foo.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(first.path, "/sdk/frameworks/SimpleFramework.framework/Headers/Foo.h");
		Source next = comp.search_include("SimpleFramework/Foo.h", first.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(next.path, "/sdk/next/SimpleFramework.framework/Headers/Foo.h");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void missing_empty_binary_and_repeated_cleanup() @test
{
	for (int round = 0; round < 12; round++)
	{
		TrackingAllocator ta;
		ta.init(mem);
		{
			MemTree tree;
			tree.init(&ta);
			tree.add_file("/inc/empty.h", "");
			tree.add_file("/inc/binary.h", "A\x00B");
			Compilation comp;
			comp.init(&ta);
			setup_files(&tree, &comp);
			comp.set_include_dirs({ { .kind = NORMAL, .path = "/inc" } });
			comp.set_embed_dirs({ "/inc" });
			Source main = add_source(&comp, "/main.c");
			Source empty = comp.search_include("empty.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
			check(empty.buf.len, 0);
			Source binary = comp.search_include("binary.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
			check(binary.buf.len, 3);
			check(binary.buf[1], 0);
			DepFile deps;
			deps.init(&ta, "out.o", MAKE);
			Preprocessor pp = { .comp = &comp, .dependencies = &deps };
			FileProvider provider = comp.file_provider();
			char[] limited = provider.find_embed(provider.ctx, &pp, "binary.h", main.id, ANGLE_BRACKETS, 1)!!;
			defer alloc::free(&ta, limited.ptr);
			check(limited.len, 1);
			check(limited[0], 'A');
			check(deps.deps.len(), 1);
			check(deps.deps[0], "binary.h");
			check(provider.has_include(provider.ctx, &pp, "empty.h", main.id, ANGLE_BRACKETS, FIRST)!!, true);
			check(deps.deps.len(), 2);
			check(deps.deps[1], "/inc/empty.h");
			check(@catch(comp.search_include("missing.h", main.id, ANGLE_BRACKETS, FIRST, null)), preprocessor::FILE_NOT_FOUND);
			deps.free();
			comp.free();
			tree.free();
		}
		check(ta.allocation_count(), 0);
		ta.free();
	}
}

fn void embed_order_absolute_limits_and_missing() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/src/main.c", "");
		tree.add_file("/work/src/local.bin", "relative-data");
		tree.add_file("/embed/local.bin", "embed-data");
		tree.add_file("/embed/empty.bin", "");
		tree.add_file("/absolute/data.bin", "absolute-data");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_embed_dirs({ "/embed" });
		Source main = add_source(&comp, "/work/src/main.c");
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		Preprocessor pp = { .comp = &comp, .dependencies = &deps };
		FileProvider provider = comp.file_provider();

		char[] data = provider.find_embed(provider.ctx, &pp, "local.bin", main.id, QUOTES, ulong::max)!!;
		defer alloc::free(&ta, data.ptr);
		check((String)data, "relative-data");
		check(deps.deps.len(), 1);
		check(deps.deps[0], "local.bin"); // Zig records the embed spelling

		char[] limited = provider.find_embed(provider.ctx, &pp, "local.bin", main.id, ANGLE_BRACKETS, 3)!!;
		defer alloc::free(&ta, limited.ptr);
		check((String)limited, "emb");
		check(deps.deps.len(), 1); // same spelling: DepFile keeps one entry
		check(deps.deps[0], "local.bin");

		char[] absolute = provider.find_embed(provider.ctx, &pp, "/absolute/data.bin", main.id, QUOTES, 4)!!;
		defer alloc::free(&ta, absolute.ptr);
		check((String)absolute, "abso");
		check(deps.deps.len(), 2);
		check(deps.deps[1], "/absolute/data.bin");

		char[] empty = provider.find_embed(provider.ctx, &pp, "empty.bin", main.id, ANGLE_BRACKETS, ulong::max)!!;
		defer alloc::free(&ta, empty.ptr);
		check(empty.len, 0);
		check(deps.deps.len(), 3);
		check(@catch(provider.find_embed(provider.ctx, &pp, "missing.bin", main.id, ANGLE_BRACKETS, ulong::max)), preprocessor::FILE_NOT_FOUND);
		check(deps.deps.len(), 3);
		check(@catch(provider.find_embed(provider.ctx, &pp, "bad\x00name", main.id, QUOTES, ulong::max)), preprocessor::FILE_NOT_FOUND);
		check(deps.deps.len(), 3);
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void quote_system_shadowing_and_include_next_exhaustion() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/quote/shared.h", "quote");
		tree.add_file("/normal/shared.h", "normal");
		tree.add_file("/system/shared.h", "system");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = SYSTEM, .path = "/system" },
			{ .kind = NORMAL, .path = "/normal" },
			{ .kind = QUOTE, .path = "/quote" },
		});
		Source main = add_source(&comp, "/main.c");
		Source quoted = comp.search_include("shared.h", main.id, QUOTES, FIRST, null)!!;
		check(quoted.path, "/quote/shared.h");
		Source angled = comp.search_include("shared.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(angled.path, "/normal/shared.h");
		Source sys = add_source(&comp, "/system/shared.h");
		check(@catch(comp.search_include("shared.h", sys.id, ANGLE_BRACKETS, NEXT, null)), preprocessor::FILE_NOT_FOUND);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_candidate_path_normalization_edges() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/terminal/header.h", "terminal");
		tree.add_file("a/b.h", "dot component");
		tree.add_file("b.h", "parent component");
		tree.add_file("/rooted.h", "absolute parent");
		tree.add_file("/trail", "trailing slash");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = add_source(&comp, "/main.c");

		comp.set_include_dirs({ { .kind = NORMAL, .path = "/terminal" } });
		Source found = comp.search_include("header.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/terminal/header.h"); // Final path component reaches the end of the string.

		comp.set_include_dirs({ { .kind = NORMAL, .path = "a/." } });
		found = comp.search_include("b.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "a/b.h");

		comp.set_include_dirs({ { .kind = NORMAL, .path = "a/.." } });
		found = comp.search_include("b.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "b.h");

		found = comp.search_include("/../rooted.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/rooted.h"); // An absolute .. component stays at the root.

		found = comp.search_include("/trail/", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(found.path, "/trail");

		comp.set_include_dirs({ { .kind = NORMAL, .path = "" } });
		tree.record = true;
		comp.include_files.exists = &recording_tree_exists;
		check(@catch(comp.search_include("", main.id, ANGLE_BRACKETS, FIRST, null)), preprocessor::FILE_NOT_FOUND);
		check(tree.accesses.len(), 1);
		check(tree.accesses[0], ".");

		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_next_normalizes_include_dir_spelling() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/w/include/mixed/other_mixed.h", "mixed");
		tree.add_file("/w/include/other_mixed.h", "next");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = NORMAL, .path = "/w/include//mixed" },
			{ .kind = NORMAL, .path = "/w/include" },
		});
		Source main = add_source(&comp, "/w/main.c");
		Source first = comp.search_include("other_mixed.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(first.path, "/w/include/mixed/other_mixed.h");
		Source next = comp.search_include("other_mixed.h", first.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(next.path, "/w/include/other_mixed.h");
		check(next.kind.ordinal, SourceKind.USER.ordinal);
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_next_bare_includer_name_waits_on_nothing() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/inc/y.h", "next");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({ { .kind = NORMAL, .path = "/inc" } });
		// Zig dirname("x.h") is null, so FindInclude never waits and /inc is searched.
		Source includer = add_source(&comp, "x.h");
		Source next = comp.search_include("y.h", includer.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(next.path, "/inc/y.h");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_next_root_wait_dir_matches_slash_dir() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/a.h", "root");
		tree.add_file("/x/a.h", "next");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = NORMAL, .path = "/" },
			{ .kind = NORMAL, .path = "/x" },
		});
		Source main = add_source(&comp, "/main.c");
		Source first = comp.search_include("a.h", main.id, ANGLE_BRACKETS, FIRST, null)!!;
		check(first.path, "/a.h");
		// The includer "/a.h" waits on "/", so the "/" entry must clear the wait.
		Source next = comp.search_include("a.h", first.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(next.path, "/x/a.h");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_next_slash_name_waits_on_candidate_dirname() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/a/inc/sub/y.h", "a sub");
		tree.add_file("/b/sub/y.h", "b sub");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_include_dirs({
			{ .kind = NORMAL, .path = "/a/inc" },
			{ .kind = NORMAL, .path = "/b" },
		});
		// Zig FindInclude.check (src/aro/Compilation.zig ~2583): while waiting, a candidate
		// clears the wait only when the candidate's dirname equals the includer's dirname.
		// Includer /a/inc/x.h waits on /a/inc. Under /a/inc the candidate is /a/inc/sub/y.h,
		// whose dirname /a/inc/sub never equals /a/inc, so the wait never clears and every
		// candidate, including /b/sub/y.h, is rejected.
		Source main = add_source(&comp, "/a/inc/x.h");
		check(@catch(comp.search_include("sub/y.h", main.id, ANGLE_BRACKETS, NEXT, null)), preprocessor::FILE_NOT_FOUND);
		// Includer /a/inc/sub/z.h waits on /a/inc/sub. The /a/inc candidate /a/inc/sub/y.h has
		// dirname /a/inc/sub, which matches, so it clears the wait and is itself skipped:
		// /a/inc/sub/y.h must NOT be returned even though it exists. The search then continues
		// to -I /b and finds /b/sub/y.h.
		Source sub = add_source(&comp, "/a/inc/sub/z.h");
		Source next = comp.search_include("sub/y.h", sub.id, ANGLE_BRACKETS, NEXT, null)!!;
		check(next.path, "/b/sub/y.h");
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}
