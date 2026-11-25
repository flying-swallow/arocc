// Integration coverage for include lookup, preprocessing, pragma callbacks,
// and dependency recording using an injected in-memory file tree.
module include_integration_tests;
import aro::frontend::c::compilation, aro::frontend::c::dep_file, aro::frontend::c::include_search, aro::frontend::c::pragma;
import aro::frontend::c::preprocessor, aro::source, aro::frontend::c::tokenizer, aro::frontend::c::diagnostics, aro::frontend::c::lang_opts;
import aro::frontend::c::pragmas::once, aro::frontend::c::pragmas::gcc;
import aro::toolchain::discovery;
import std::core::mem::allocators, std::core::dstring;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

excuse NO_TEST_FILE;

<* Include-only pragma handler: counts calls and returns `result`. *>
struct CallbackState (pragma::IPragma) { uint calls; pragma::IncludePragmaResult result; }

fn pragma::IncludePragmaResult CallbackState.before_include(&self, preprocessor::Preprocessor* pp, source::Source src) @dynamic
{
	self.calls++;
	return self.result;
}

fn bool tree_exists(void* ctx, String path)
{
	MemTree* tree = ctx;
	uint? found = tree.resolve(path);
	if (catch found) return false;
	return true;
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
	comp.set_include_dirs({ { .kind = NORMAL, .path = "/work/inc" }, { .kind = NORMAL, .path = "/work/next" } });
}

fn String preprocess_text(Compilation* comp, Source src, DepFile* deps)
{
	InitOptions opts = preprocessor::TESTING;
	opts.dependencies = deps;
	opts.base_file = src.id;
	opts.add_builtin_macros = true; // __has_include / __has_embed are builtin macros
	Preprocessor pp;
	pp.init(comp, opts, comp.file_provider())!!;
	pp.preserve_whitespace = true; // -E style output
	pp.add_token(pp.preprocess(src)!!)!!; // Zig callers append the returned eof
	DString output;
	output.init(tmem);
	pp.pretty_print_tokens(&output, RESULT_ONLY)!!;
	String result = output.str_view().copy(tmem);
	pp.free();
	return result;
}

fn void include_callback_skip_and_fatal_contract() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "#include <callback.h>\nint after;\n");
		tree.add_file("/work/inc/callback.h", "int included;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", "#include <callback.h>\nint after;\n")!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.dependencies = &deps;
		opts.base_file = main.id;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preserve_whitespace = true;
		CallbackState state = { .result = pragma::IncludePragmaResult.SKIP_INCLUDE };
		bool added = comp.pragmas.add("include", &state);
		assert(added);
		pp.add_token(pp.preprocess(main)!!)!!;
		check(state.calls, 1);
		DString output;
		output.init(tmem);
		pp.pretty_print_tokens(&output, RESULT_ONLY)!!;
		// A skipped include leaves no tokens; the first output line is the declaration.
		test::eq(output.str_view(), "int after;\n");
		check(deps.deps.len(), 1);
		test::eq(deps.deps[0], "/work/main.c");
		pp.free();
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "#include <callback.h>\nint unreachable;\n");
		tree.add_file("/work/inc/callback.h", "int included;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", "#include <callback.h>\nint unreachable;\n")!!;
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		pp.init(&comp, opts, comp.file_provider())!!;
		CallbackState state = { .result = pragma::IncludePragmaResult.FATAL };
		bool added = comp.pragmas.add("include", &state);
		assert(added);
		check(@catch(pp.preprocess(main)), compilation::FATAL_ERROR);
		check(state.calls, 1);
		pp.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void pragma_once_repeated_include_preprocessing() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "#include <once.h>\n#include <once.h>\n");
		tree.add_file("/work/inc/once.h", "#pragma once\nint once_only;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		bool added = comp.pragmas.add("once", once::handler(&ta));
		assert(added);
		Source main = comp.add_source_from_buffer("/work/main.c", "#include <once.h>\n#include <once.h>\n")!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "\nint once_only;\n");
		check(deps.deps.len(), 2);
		test::eq(deps.deps[0], "/work/main.c");
		test::eq(deps.deps[1], "/work/inc/once.h");
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_and_include_query_dependencies_own_resolved_paths() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "#if __has_include(<queried.h>)\nint query_found;\n#endif\n#embed \"payload.bin\"\n");
		tree.add_file("/work/inc/queried.h", "int queried;\n");
		tree.add_file("/work/payload.bin", "AB");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", "#if __has_include(<queried.h>)\nint query_found;\n#endif\n#embed \"payload.bin\"\n")!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "\nint query_found;\n65,66\n");
		check(deps.deps.len(), 3);
		test::eq(deps.deps[0], "/work/main.c");
		test::eq(deps.deps[1], "/work/inc/queried.h");
		test::eq(deps.deps[2], "payload.bin"); // Zig records the #embed spelling
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void absolute_include_and_embed_directory_resolution_deduplicate_dependencies() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		String text = "#if __has_include(\"/work/a.h\")\nint header_found;\n#endif\n#include \"/work/a.h\"\n#if __has_embed(\"/work/a.bin\")\nint binary_found;\n#endif\n#embed \"/work/a.bin\"\n#embed \"f.bin\"\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/a.h", "int absolute_header;\n");
		tree.add_file("/work/a.bin", "A");
		tree.add_file("/work/e dir/f.bin", "B");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		comp.set_embed_dirs({ "/work/e dir" });
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "\nint header_found;\nint absolute_header;\nint binary_found;\n65\n66\n");
		check(deps.deps.len(), 4);
		test::eq(deps.deps[0], "/work/main.c");
		test::eq(deps.deps[1], "/work/a.h");
		test::eq(deps.deps[2], "/work/a.bin"); // absolute spelling
		test::eq(deps.deps[3], "f.bin"); // Zig records the #embed spelling
		DString make_rule;
		make_rule.init(tmem);
		deps.write(&make_rule);
		test::eq(make_rule.str_view(), "out.o: /work/main.c /work/a.h /work/a.bin f.bin\n");
		DepFile nmake_deps;
		nmake_deps.init(&ta, "out.obj", NMAKE);
		foreach (path : deps.deps) nmake_deps.add_dependency(path);
		DString nmake_rule;
		nmake_rule.init(tmem);
		nmake_deps.write(&nmake_rule);
		test::eq(nmake_rule.str_view(), "out.obj: /work/main.c /work/a.h /work/a.bin f.bin\n");
		nmake_rule.free();
		nmake_deps.free();
		make_rule.free();
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void missing_queries_and_zero_or_empty_embeds() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		String text = "#if __has_include(<missing.h>)\nint wrong_header;\n#endif\n#if __has_embed(\"missing.bin\")\nint wrong_embed;\n#endif\n#embed \"payload.bin\" limit(0) if_empty(42)\n#embed \"empty.bin\" if_empty(7)\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/payload.bin", "payload");
		tree.add_file("/work/empty.bin", "");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "42\n7\n");
		check(deps.deps.len(), 3);
		test::eq(deps.deps[0], "/work/main.c");
		test::eq(deps.deps[1], "payload.bin");
		test::eq(deps.deps[2], "empty.bin");
		deps.free();
		Source missing_embed = comp.add_source_from_buffer("/work/missing-embed.c", "#embed \"missing.bin\"\n")!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = missing_embed.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		check(@catch(pp.preprocess(missing_embed)), compilation::FATAL_ERROR);
		pp.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void expect_diag(Diagnostics* d, sz i, String text, uint line, uint col)
{
	assert(i < d.messages.len(), "missing diagnostic %d (%s)", i, text);
	test::eq(d.messages[i].text, text);
	check(d.messages[i].location.line_no, line);
	check(d.messages[i].location.col, col);
}

fn uint comma_count(String s)
{
	uint commas = 0;
	for (usz i = 0; i < s.len; i++)
	{
		if (s[i] == ',') commas++;
	}
	return commas;
}

// Fixtures for the test/cases/#embed.c cases. Quoted names fall back to the embed
// dir, and `<embed data>` resolves only there (manifest: --embed-dir=embed).
fn void add_embed_fixtures(MemTree* tree)
{
	tree.add_file("/work/embed/embed data", "Hello, World!");
	tree.add_file("/work/embed/embed byte", "A");
	tree.add_file("/work/embed/empty", "");
}

// Preprocess `text` as /work/main.c with C23 (the manifest's -std=c23, which avoids
// a "#embed is a C23 extension" diagnostic per directive). Diagnostics go to `d`.
fn String embed_output(TrackingAllocator* ta, String text, Diagnostics* d)
{
	MemTree tree;
	tree.init(ta);
	tree.add_file("/work/main.c", text);
	add_embed_fixtures(&tree);
	Compilation comp;
	comp.init(ta, null, d);
	comp.langopts.standard = lang_opts::Standard.C23;
	setup_files(&tree, &comp);
	comp.set_embed_dirs({ "/work/embed" });
	Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
	String output = preprocess_text(&comp, main, null);
	comp.free();
	tree.free();
	return output;
}

fn void embed_plain_data_emits_every_byte() @test
{
	// test/cases/#embed.c:2-3: "embed data" is 13 bytes; ", 0" adds the explicit trailing element.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "unsigned char hello[] = {\n#embed \"embed data\"\n\t, 0\n};\n", &d);
		check(d.messages.len(), 0);
		check(comma_count(output), 13);
		assert(output.contains("72,101,108,108,111,44,32,87,111,114,108,100,33"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_empty_emits_nothing() @test
{
	// test/cases/#embed.c:7-9
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "int empty[] = {\n#embed \"empty\"\n};\n", &d);
		check(d.messages.len(), 0);
		check(comma_count(output), 0);
		assert(output.contains("int empty"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_byte_is_single_element() @test
{
	// test/cases/#embed.c:12-14: "embed byte" is the single byte 'A' (65).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "const int Foo = 1 +\n#embed \"embed byte\"\n;\n", &d);
		check(d.messages.len(), 0);
		check(comma_count(output), 0);
		assert(output.contains("65"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_macro_expanded_angle_name_and_limit() @test
{
	// test/cases/#embed.c:45-50: `<embed data>` rebuilt from macros, B(1) expands to limit(1) -> 'H'.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "#define B limit\n#define A <embed\nconst int expanded_byte =\n#embed A data> B(1)\n;\n", &d);
		check(d.messages.len(), 0);
		check(comma_count(output), 0);
		assert(output.contains("72"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_limit_normalized_and_duplicate() @test
{
	// test/cases/#embed.c:18-20; duplicate warning at 19:62 (the second `limit`).
	// Last limit wins: __limit__(3) is normalized, limit(4) overrides it.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "unsigned char third[] = {\n#embed \"embed data\" __limit__(3) prefix(0, 1,) suffix(,3, 4) limit(4)\n};\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "duplicate embed parameter 'limit'", 2, 62);
		assert(d.messages[0].effective_kind == diagnostics::MessageKind.WARNING);
		// prefix 2 + 4 bytes + suffix 2 = 8 elements = 7 separators.
		check(comma_count(output), 7);
		assert(output.contains("72,101,108,108"));
		assert(!output.contains("111"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_duplicate_limit_last_wins() @test
{
	// test/cases/#embed.c:24-27; duplicate warning at 25:30. limit(a) is overridden by limit(1).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "const int bar =\n#embed \"embed data\" limit(a) limit(1)\n;\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "duplicate embed parameter 'limit'", 2, 30);
		assert(d.messages[0].effective_kind == diagnostics::MessageKind.WARNING);
		check(comma_count(output), 0);
		assert(output.contains("72"));
		assert(!output.contains("101"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_unknown_vendor_param_is_error() @test
{
	// test/cases/#embed.c:52-53: reported at the name token after `vendor::` (col 24).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"empty\" vendor::unsupported\n#embed \"empty\" vendor::unsupported(2)\n", &d);
		check(d.messages.len(), 2);
		expect_diag(&d, 0, "unknown embed parameter 'vendor::unsupported'", 1, 24);
		expect_diag(&d, 1, "unknown embed parameter 'vendor::unsupported'", 2, 24);
		assert(d.messages[0].effective_kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].effective_kind == diagnostics::MessageKind.ERROR);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_vendor_param_without_name_expects_identifier() @test
{
	// test/cases/#embed.c:54 (manifest 55:24): the newline after `vendor::` is
	// attributed to the next line, so the error sits at 2:24 in this one-line source.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"empty\" vendor::\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "expected identifier", 2, 24);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_param_without_parens_expects_paren() @test
{
	// test/cases/#embed.c:55 (manifest 55:16): reported at the `limit` token.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"empty\" limit\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "expected '('", 1, 16);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_negative_limit_is_rejected() @test
{
	// test/cases/#embed.c:56 (manifest 56:16): reported at the `limit` token.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"empty\" limit(-1)\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "the limit parameter expects a non-negative integer as a parameter", 1, 16);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_non_identifier_param_stops_directive() @test
{
	// test/cases/#embed.c:57 (manifest 57:25): the `1` after limit(1) is not a parameter name.
	// Only that one diagnostic: limit(3) is never parsed.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"empty\" limit(1) 1 limit(3)\n", &d);
		check(d.messages.len(), 1);
		expect_diag(&d, 0, "expected identifier", 1, 25);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void embed_unclosed_param_reports_closing_paren_with_note() @test
{
	// Unclosed `prefix(` : closing error at the end-of-line token, note at the '(' (col 27).
	// The end-of-line position follows the manifest's next-line convention (see vendor:: case).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		embed_output(&ta, "#embed \"embed data\" prefix(1\n", &d);
		check(d.messages.len(), 2);
		expect_diag(&d, 0, "expected closing ')'", 2, 29);
		expect_diag(&d, 1, "to match this '('", 1, 27);
		assert(d.messages[0].effective_kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].effective_kind == diagnostics::MessageKind.NOTE);
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void has_embed_unknown_param_evaluates_zero() @test
{
	// test/cases/#embed.c:29-31: an unknown parameter makes __has_embed 0.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "#if __has_embed(\"embed data\" foo(1)) == 0\nint unknown_zero;\n#endif\n", &d);
		assert(output.contains("int unknown_zero;"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void has_embed_known_param_and_empty_values() @test
{
	// test/cases/#embed.c:37-39: limit(1) on a non-empty file -> FOUND (1).
	// test/cases/#embed.c:41-43: an empty file -> EMPTY (2).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "#if __has_embed(\"embed data\" limit(1)) == 1\nint limited_found;\n#endif\n#if __has_embed(\"empty\") == 2\nint empty_found;\n#endif\n", &d);
		assert(output.contains("int limited_found;"));
		assert(output.contains("int empty_found;"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void has_embed_missing_file_evaluates_zero() @test
{
	// test/cases/#embed.c:33-35: a missing file -> NOT_FOUND (0).
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		String output = embed_output(&ta, "#if __has_embed(\"doesn't exist\") == 0\nint absent_zero;\n#endif\n", &d);
		assert(output.contains("int absent_zero;"));
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void repeated_guarded_include_and_dependencies() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/main.c", "#include <guard.h>\n#include <guard.h>\n");
		tree.add_file("/work/inc/guard.h", "#ifndef GUARD_H\n#define GUARD_H\nint guarded;\n#endif\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", "#include <guard.h>\n#include <guard.h>\n")!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "int guarded;\n");
		check(deps.deps.len(), 2);
		test::eq(deps.deps[0], "/work/main.c");
		test::eq(deps.deps[1], "/work/inc/guard.h");
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_next_and_missing_include() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		tree.add_file("/work/inc/chain.h", "#include_next <chain.h>\nint first;\n");
		tree.add_file("/work/next/chain.h", "int second;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", "#include <chain.h>\n")!!;
		String output = preprocess_text(&comp, main, null);
		test::eq(output, "int second;\nint first;\n");
		Source missing = comp.add_source_from_buffer("/work/missing-main.c", "#include <absent.h>\n")!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = missing.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		check(@catch(pp.preprocess(missing)), compilation::FATAL_ERROR);
		pp.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_angle_brackets_keep_space() @test
{
	// Mirrors src/aro/Preprocessor.zig:findIncludeFilenameToken / findIncludeSource.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		String text = "#include <a b.h>\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/a b.h", "int spaced;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "int spaced;\n");
		check(deps.deps.len(), 2);
		test::eq(deps.deps[1], "/work/inc/a b.h");
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_header_name_macro_expands() @test
{
	// Mirrors src/aro/Preprocessor.zig:include and findIncludeFilenameToken.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree tree;
		tree.init(&ta);
		String text = "#define H \"x.h\"\n#include H\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/x.h", "int from_header;\n");
		Compilation comp;
		comp.init(&ta);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		DepFile deps;
		deps.init(&ta, "out.o", MAKE);
		String output = preprocess_text(&comp, main, &deps);
		test::eq(output, "\nint from_header;\n");
		check(deps.deps.len(), 2);
		test::eq(deps.deps[1], "/work/inc/x.h");
		deps.free();
		comp.free();
		tree.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_quoted_header_reports_extra_tokens() @test
{
	// Mirrors src/aro/Preprocessor.zig:findIncludeFilenameToken's trailing-token check.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		MemTree tree;
		tree.init(&ta);
		String text = "#include \"x.h\" junk\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/x.h", "int included;\n");
		Compilation comp;
		comp.init(&ta, null, &d);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preprocess(main)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "extra tokens at end of macro directive");
		pp.free();
		comp.free();
		tree.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_poisoned_header_identifier_is_diagnosed() @test
{
	// Mirrors src/aro/Preprocessor.zig:findIncludeFilenameToken's poisoned-identifier check.
	// Zig checks only tokens read after the first one, so the poisoned name follows H.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		MemTree tree;
		tree.init(&ta);
		String text = "#pragma GCC poison P\n#define H \"x.h\"\n#include H P\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/x.h", "int included;\n");
		Compilation comp;
		comp.init(&ta, null, &d);
		setup_files(&tree, &comp);
		bool added = comp.pragmas.add("GCC", gcc::make_handler(&ta));
		assert(added);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preprocess(main)!!;
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "attempt to use a poisoned identifier");
		test::eq(d.messages[1].text, "extra tokens at end of macro directive");
		pp.free();
		comp.free();
		tree.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_angle_header_without_closing_bracket_reports_pair() @test
{
	// Mirrors src/aro/Preprocessor.zig:reconstructIncludeString header-string diagnostics.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		MemTree tree;
		tree.init(&ta);
		String text = "#include <x.h\n";
		tree.add_file("/work/main.c", text);
		Compilation comp;
		comp.init(&ta, null, &d);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preprocess(main)!!;
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "expected closing '>'");
		test::eq(d.messages[1].text, "to match this '<'");
		pp.free();
		comp.free();
		tree.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_resume_uses_next_token_end_and_line() @test
{
	// Mirrors src/aro/Preprocessor.zig:include's INCLUDE_RESUME location calculation.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		MemTree tree;
		tree.init(&ta);
		String text = "#include \"x.h\"\n\nint y;\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/x.h", "int x;\n");
		Compilation comp;
		comp.init(&ta, null, &d);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preserve_whitespace = true;
		pp.linemarkers = NUMERIC_DIRECTIVES;
		pp.preprocess(main)!!;

		Tokenizer source_tokens;
		source_tokens.init(main.buf, main.id, comp.langopts, &comp.target);
		Token after_directive;
		while (true)
		{
			after_directive = source_tokens.next();
			if (after_directive.id == TokenId.KEYWORD_INT) break;
		}
		uint expected_offset = after_directive.end;
		uint expected_line = after_directive.line;
		check(expected_offset, 19);
		check(expected_line, 3);

		uint resume_index = uint::max;
		for (uint i = 0; i < (uint)pp.tokens.len(); i++)
		{
			if (pp.tokens[i].id == TokenId.INCLUDE_RESUME) resume_index = i;
		}
		assert(resume_index != uint::max);
		check(pp.tokens[resume_index].loc.byte_offset, expected_offset);
		check(pp.tokens[resume_index].loc.line, expected_line);
		pp.free();
		comp.free();
		tree.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void include_without_final_newline_adds_nl_before_resume() @test
{
	// Mirrors src/aro/Preprocessor.zig:include's preserve-whitespace NL before INCLUDE_RESUME.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		MemTree tree;
		tree.init(&ta);
		String text = "#include \"x.h\"\n";
		tree.add_file("/work/main.c", text);
		tree.add_file("/work/inc/x.h", "int a;");
		Compilation comp;
		comp.init(&ta, null, &d);
		setup_files(&tree, &comp);
		Source main = comp.add_source_from_buffer("/work/main.c", text)!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = main.id;
		Preprocessor pp;
		pp.init(&comp, opts, comp.file_provider())!!;
		pp.preserve_whitespace = true;
		pp.linemarkers = NUMERIC_DIRECTIVES;
		pp.preprocess(main)!!;

		uint resume_index = uint::max;
		for (uint i = 0; i < (uint)pp.tokens.len(); i++)
		{
			if (pp.tokens[i].id == TokenId.INCLUDE_RESUME) resume_index = i;
		}
		assert(resume_index != uint::max);
		assert(resume_index >= 5);
		check(pp.tokens[(sz)resume_index - 1].id.ordinal, TokenId.NL.ordinal);
		check(pp.tokens[(sz)resume_index - 2].id.ordinal, TokenId.SEMICOLON.ordinal);
		check(pp.tokens[(sz)resume_index - 3].id.ordinal, TokenId.IDENTIFIER.ordinal);
		check(pp.tokens[(sz)resume_index - 5].id.ordinal, TokenId.KEYWORD_INT.ordinal);
		pp.free();
		comp.free();
		tree.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}
