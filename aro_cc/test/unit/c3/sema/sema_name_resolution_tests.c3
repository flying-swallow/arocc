// Tests for the c3c sema_name_resolution.c / sema_initializers.c /
// sema_builtins.c / sema_generics.c ports (src/frontend/c3/): edit distance,
// sub-path matching, the decl stack, local scopes, ConstInitializer helpers,
// UTF-8 decoding for $$wstr16/32, builtin arities and generic suffixes.
// Expectations follow c3c 54bab366a.
module c3_sema_name_resolution_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Expr* cint(Type* type, ulong v) => compiler::expr_new_const_int(0, type, v);

fn int dist(String a, String b) => compiler::damerau_levenshtein_distance(a, (int)a.len, b, (int)b.len);

fn ModulePath* path(String s) => compiler::path_create_from_string(s, (uint)s.len, 0);

module c3_sema_name_resolution_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void edit_distance()
{
	test::eq(dist("kitten", "sitting"), 3);
	test::eq(dist("ab", "ba"), 1);
	test::eq(dist("", "abc"), 3);
	test::eq(dist("abc", ""), 3);
	test::eq(dist("printf", "printfn"), 1);
	test::eq(dist("same", "same"), 0);
	char[300] long_buf;
	String long_str = (String)long_buf[..];
	test::eq(dist(long_str, "a"), 256);
}

fn void subpath_matching()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::matches_subpath(path("a::foo::bar"), path("foo::bar")));
	assert(compiler::matches_subpath(path("foo::bar"), path("foo::bar")));
	assert(!compiler::matches_subpath(path("afoo::bar"), path("foo::bar")));
	assert(!compiler::matches_subpath(path("foo::bar"), path("a::foo::bar")));
	assert(!compiler::matches_subpath(path("a::foo::baz"), path("foo::bar")));
}

fn void decl_stack()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	compiler::compiler.context.decl_stack_bottom = compiler::compiler.context.decl_stack_top = &compiler::compiler.context.decl_stack;
	String a = "a";
	String b = "b";
	Decl* da = compiler::decl_new(VAR, a, 0);
	Decl* db = compiler::decl_new(VAR, b, 0);
	compiler::sema_decl_stack_push(da);
	assert(compiler::sema_decl_stack_resolve_symbol(a) == da);
	Decl** state = compiler::sema_decl_stack_store();
	// The new frame hides the outer one.
	assert(compiler::sema_decl_stack_resolve_symbol(a) == null);
	compiler::sema_decl_stack_push(db);
	assert(compiler::sema_decl_stack_resolve_symbol(b) == db);
	compiler::sema_decl_stack_restore(state);
	assert(compiler::sema_decl_stack_resolve_symbol(a) == da);
	assert(compiler::sema_decl_stack_resolve_symbol(b) == null);
}

fn void locals_and_erase()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	String x = "x";
	String y = "y";
	String ct = "$ct";
	Decl* dx = compiler::decl_new_var(x, 0, null, LOCAL);
	Decl* dy = compiler::decl_new_var(y, 0, null, LOCAL);
	assert(compiler::sema_add_local(&context, dx));
	assert(compiler::sema_add_local(&context, dy));
	test::eq(context.active_scope.current_local, 2);
	assert(compiler::sema_find_local(&context, x) == dx);
	assert(compiler::sema_find_local(&context, y) == dy);
	// Untyped vars are not marked done yet.
	assert(dx.resolve_status == NOT_DONE);
	compiler::sema_erase_var(&context, dx);
	assert(compiler::sema_find_local(&context, x) == null);
	// Leaving the scope makes the erasure go away again.
	context.active_scope.current_local = 2;
	assert(compiler::sema_find_local(&context, x) == dx);
	// Compile time locals go to their own list.
	Decl* dct = compiler::decl_new_var(ct, 0, null, LOCAL_CT);
	assert(compiler::sema_add_local(&context, dct));
	assert(compiler::sema_find_local(&context, ct) == dct);
	assert(dct.resolve_status == DONE);
	// Labels are found from label_start.
	context.active_scope.label_start = 1;
	assert(compiler::sema_find_label_symbol(&context, x) == null);
	assert(compiler::sema_find_label_symbol_anywhere(&context, x) == dx);
}

fn void const_initializers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ConstInitializer* zero = compiler::const_init_new_zero(compiler::type_int);
	assert(compiler::const_init_is_zero(zero));
	assert(compiler::const_init_local_init_may_be_global(zero));
	assert(compiler::const_init_is_zero(compiler::const_init_new_value(cint(compiler::type_int, 0))));
	ConstInitializer* five = compiler::const_init_new_value(cint(compiler::type_int, 5));
	assert(!compiler::const_init_is_zero(five));
	assert(five.kind == INIT_VALUE);

	// Writing [2] then [0] into a zero int[4] keeps the elements sorted.
	Type* arr = compiler::type_get_array(compiler::type_int, 4);
	ConstInitializer* init = compiler::const_init_new_zero(arr);
	compiler::const_init_rewrite_array_at(init, cint(compiler::type_int, 7), 2);
	compiler::const_init_rewrite_array_at(init, cint(compiler::type_int, 9), 0);
	assert(init.kind == INIT_ARRAY);
	test::eq(init.init_array.elements.len, 2);
	test::eq(init.init_array.elements[0].init_array_value.index, 0);
	test::eq(init.init_array.elements[1].init_array_value.index, 2);
	assert(init.init_array.elements[1].init_array_value.element.init_value.const_expr.ixx.i == 7);
	assert(!compiler::const_init_is_zero(init));
	// Overwriting an existing index does not add an element.
	compiler::const_init_rewrite_array_at(init, cint(compiler::type_int, 0), 2);
	test::eq(init.init_array.elements.len, 2);
}

fn void utf8_codepoints()
{
	int inc;
	// The pointer is just past the lead byte, like the c3c caller.
	char[*] e_acute = { 0xC3, 0xA9, 0 };
	assert(compiler::utf8_to_codepoint(&e_acute[1], &inc) == 0xE9);
	test::eq(inc, 2);
	char[*] euro = { 0xE2, 0x82, 0xAC, 0 };
	assert(compiler::utf8_to_codepoint(&euro[1], &inc) == 0x20AC);
	test::eq(inc, 3);
	char[*] emoji = { 0xF0, 0x9F, 0x98, 0x80, 0 };
	assert(compiler::utf8_to_codepoint(&emoji[1], &inc) == 0x1F600);
	test::eq(inc, 4);
}

fn void builtin_arities()
{
	test::eq(compiler::builtin_expected_args(SWIZZLE), -2);
	test::eq(compiler::builtin_expected_args(SWIZZLE2), -3);
	test::eq(compiler::builtin_expected_args(SPRINTF), -1);
	test::eq(compiler::builtin_expected_args(TRAP), 0);
	test::eq(compiler::builtin_expected_args(MEMSET), 5);
	test::eq(compiler::builtin_expected_args(MEMCOPY), 6);
	test::eq(compiler::builtin_expected_args(COMPARE_EXCHANGE), 8);
	assert(compiler::operator_from_builtin(VECCOMPLT) == VEC_LT);
	assert(compiler::operator_from_builtin(VECCOMPNE) == VEC_NE);
}

fn void swizzle_indices()
{
	test::eq(compiler::swizzle_index('x'), 0);
	test::eq(compiler::swizzle_index('w'), 3);
	test::eq(compiler::swizzle_index('r'), 0);
	test::eq(compiler::swizzle_index('a'), 3);
}

fn void generic_suffixes()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr*[] params = { cint(compiler::type_int, (ulong)-3), compiler::expr_new_const_bool(0, compiler::type_bool, true) };
	compiler::sema_generate_parameter_suffix_to_scratch(params, false);
	test::eq(compiler::scratch_buffer_str(), "{-3, true}");
	compiler::sema_generate_parameter_suffix_to_scratch(params, true);
	test::eq(compiler::scratch_buffer_str(), "$_3$t$");
}
