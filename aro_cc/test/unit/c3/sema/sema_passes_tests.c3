// Tests for the c3c sema_passes.c / semantic_analyser.c / utils ports
// (src/frontend/c3/sema_passes.c3, semantic_analyser.c3, utils_rest.c3,
// methodtable.c3): module parent paths, the module hierarchy pass, scope /
// defer helpers and the file / hash utilities. Expectations follow c3c
// 54bab366a (a5hash values computed with c3c's lib.h implementation).
module c3_sema_passes_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn String parent_of(String name)
{
	StringSlice slice = name;
	compiler::parent_path(&slice);
	return slice;
}

module c3_sema_passes_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void parent_paths()
{
	test::eq(parent_of("foo::bar::baz"), "foo::bar");
	test::eq(parent_of("foo::bar"), "foo");
	test::eq(parent_of("foo"), "");
}

fn void module_hierarchy_creates_parent()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Module* child = compiler::compiler_find_or_create_module(compiler::path_create_from_string("foo::bar", 8, 0));
	compiler::sema_analyse_pass_module_hierarchy(child);
	assert(child.parent_module != null);
	test::eq(child.parent_module.name.module_name, "foo");
	assert(child.parent_module.parent_module == null);
	// An existing parent module is reused.
	Module* sibling = compiler::compiler_find_or_create_module(compiler::path_create_from_string("foo::qux", 8, 0));
	compiler::sema_analyse_pass_module_hierarchy(sibling);
	assert(sibling.parent_module == child.parent_module);
}

fn void a5hash_matches_c3c()
{
	test::eq(compiler::a5hash("", 0, 0), 1093617220344544657UL);
	test::eq(compiler::a5hash("a", 1, 0), 9746025406203176355UL);
	test::eq(compiler::a5hash("abc", 3, 0), 16465500363238275262UL);
	test::eq(compiler::a5hash("abcd", 4, 0), 5757949028221002399UL);
	test::eq(compiler::a5hash("hello world!", 12, 0), 5802469576210154766UL);
	test::eq(compiler::a5hash("0123456789abcdefghij", 20, 0), 1270766466800888304UL);
	String fox = "the quick brown fox jumps over the lazy dog";
	test::eq(compiler::a5hash(fox, (uint)fox.len, 12345), 9226480849318018689UL);
	test::eq(compiler::a5hash("ab", 2, 12345), 2413421128422290043UL);
}

fn void file_utils()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	String name;
	String dir;
	assert(compiler::file_namesplit("foo/bar.c3", &name, &dir));
	test::eq(name, "bar.c3");
	test::eq(dir, "foo");
	assert(compiler::file_namesplit("bar.c3", &name, &dir));
	test::eq(name, "bar.c3");
	test::eq(dir, ".");
	assert(!compiler::file_namesplit("foo/..", &name, &dir));
	assert(!compiler::file_namesplit("foo/", &name, &dir));
	test::eq(compiler::file_append_path("a/b", "c.c3"), "a/b/c.c3");
	test::eq(compiler::file_append_path("a/b/", "c.c3"), "a/b/c.c3");
	test::eq(compiler::file_append_path("", "c.c3"), "c.c3");
	assert(compiler::file_path_is_relative("a/b"));
	assert(!compiler::file_path_is_relative("/a/b"));
	assert(!compiler::file_path_is_relative(""));
}

fn void scope_flags_and_depth()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	context.active_scope.flags = compiler::SCOPE_ENSURE;
	context.active_scope.current_local = 3;
	context.active_scope.label_start = 1;
	DynamicScope old = compiler::scope_start(&context, 0);
	test::eq(context.active_scope.depth, 1);
	test::eq(context.active_scope.flags, compiler::SCOPE_ENSURE);
	test::eq(context.active_scope.label_start, 1);
	context.active_scope = old;
	// A macro scope drops the ensure flags and starts a new label scope.
	compiler::context_change_scope_with_flags(&context, compiler::SCOPE_MACRO, 0);
	test::eq(context.active_scope.flags, compiler::SCOPE_MACRO);
	test::eq(context.active_scope.label_start, 3);
	test::eq(compiler::context_filename(&context), "<unknown unit>");
}

fn void empty_defers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	assert(compiler::context_get_defers(&context, 0, true) == 0);
	AstId next = 0;
	compiler::context_pop_defers(&context, &next);
	assert(next == 0);
}

fn void methodtable_empty()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	MethodTable table;
	assert(compiler::methodtable_get(&table, compiler::type_int, "foo") == 0);
	compiler::methodtable_init(&table, 16);
	test::eq(table.capacity, 16u);
	test::eq(table.max_load, 8u);
	assert(compiler::methodtable_get(&table, compiler::type_int, "foo") == 0);
}
