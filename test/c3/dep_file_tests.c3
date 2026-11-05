module dep_file_tests;
import aro::dep_file;
import std::core::mem::allocators;

fn void expect_rule(DepFile* d, String expected)
{
	DString w;
	w.init(mem);
	defer w.free();
	d.write(&w);
	test::eq(w.str_view(), expected);
}

fn void ordered_dedupe_stdin_and_make_escaping() @test
{
	DepFile d;
	d.init(mem, "obj file$#.o", MAKE);
	d.add_dependency("first file.h");
	d.add_dependency("second#$.h");
	d.add_dependency("first file.h");
	d.add_dependency("<stdin>");
	expect_rule(&d, "obj\\ file$$\\#.o: first\\ file.h second\\#$$.h\n");
	d.free();
}

fn void nmake_quotes_special_dependency() @test
{
	DepFile d;
	d.init(mem, "out.obj", NMAKE);
	d.add_dependency("plain.h");
	d.add_dependency("dir/a b$.h");
	expect_rule(&d, "out.obj: plain.h \"dir/a b$.h\"\n");
	d.free();
}

fn void make_escaping_tabs_and_backslashes_before_spaces() @test
{
	char[5] target = { 'o', 'u', 't', '\t', '.' };
	char[6] dependency = { 'a', '\\', '\\', ' ', 'b', '.' };
	DepFile d;
	d.init(mem, (String)&target, MAKE);
	d.add_dependency((String)&dependency);
	expect_rule(&d, "out\\\t.: a\\\\\\\\\\ b.\n");
	d.free();
}

fn void equal_content_paths_from_distinct_buffers_are_deduplicated() @test
{
	char[6] first = { 's', 'a', 'm', 'e', '.', 'h' };
	char[6] second = { 's', 'a', 'm', 'e', '.', 'h' };
	DepFile d;
	d.init(mem, "out.o", MAKE);
	d.add_dependency((String)&first);
	d.add_dependency((String)&second);
	expect_rule(&d, "out.o: same.h\n");
	d.free();
}

fn void nmake_quotes_all_documented_special_characters() @test
{
	DepFile d;
	d.init(mem, "out.obj", NMAKE);
	d.add_dependency("hash#");
	d.add_dependency("braces{}");
	d.add_dependency("caret^");
	d.add_dependency("bang!");
	expect_rule(&d, "out.obj: \"hash#\" \"braces{}\" \"caret^\" \"bang!\"\n");
	d.free();
}

fn void wraps_at_seventy_five_columns() @test
{
	char[71] long_path;
	foreach (&c : long_path) *c = 'x';
	DepFile d;
	d.init(mem, "out.o", MAKE);
	d.add_dependency("one.h");
	d.add_dependency((String)&long_path);
	expect_rule(&d, "out.o: one.h \\\n  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n");
	d.free();
}

fn void borrowed_and_arena_owned_paths() @test
{
	char[3] path = { 'a', '.', 'h' };
	DynamicArenaAllocator arena;
	arena.init(mem, 128);
	defer arena.free();
	DepFile borrowed;
	borrowed.init(mem, "out.o", MAKE);
	borrowed.add_dependency((String)&path);
	DepFile owned;
	owned.init(mem, "out.o", MAKE);
	owned.add_dependency_dupe(&arena, (String)&path);
	path[0] = 'z';
	expect_rule(&borrowed, "out.o: z.h\n");
	expect_rule(&owned, "out.o: a.h\n");
	borrowed.free();
	owned.free();
}

fn void copied_paths_are_deduplicated_and_released() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		char[6] path = { 's', 'a', 'm', 'e', '.', 'h' };
		DepFile d;
		d.init(&ta, "out.o", MAKE);
		d.add_dependency_copy((String)&path);
		path[0] = 'z';
		d.add_dependency_copy("same.h");
		test::eq(d.deps.len(), 1);
		expect_rule(&d, "out.o: same.h\n");
		d.free();
	}
	test::eq((long)ta.allocation_count(), 0);
}

fn void repeated_create_destroy_releases_storage() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	for (int round = 0; round < 25; round++)
	{
		DepFile d;
		d.init(&ta, "out.o", MAKE);
		d.add_dependency("one.h");
		d.add_dependency("two.h");
		d.free();
	}
	test::eq((long)ta.allocation_count(), 0);
}
