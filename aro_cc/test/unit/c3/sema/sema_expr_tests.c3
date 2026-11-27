// Tests for the first half of c3c sema_expr.c (src/frontend/c3/sema_expr.c3):
// helpers that work on hand-built nodes and builtin types (lvalue / ref
// checks, const folding predicates, type property validity, min/max
// constants, splat lengths). Expected texts follow c3c 54bab366a.
module c3_sema_expr_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Expr* const_int(long v) => compiler::expr_new_const_int(0, compiler::type_int, (ulong)v);

fn Decl* local_var(String name, Type* type)
{
	Decl* d = compiler::decl_calloc();
	d.decl_kind = VAR;
	d.var_decl.kind = LOCAL;
	d.name = name;
	d.type = type;
	d.resolve_status = DONE;
	return d;
}

fn Expr* ident(Decl* d)
{
	Expr* e = compiler::expr_new(IDENTIFIER, 0);
	e.ident_expr = d;
	e.type = d.type;
	e.resolve_status = DONE;
	return e;
}

fn String last_report() => compiler::global_diagnostics.reports[^1].text;

module c3_sema_expr_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void may_ref_kinds()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Decl* d = local_var("x", compiler::type_int);
	assert(compiler::expr_may_ref(ident(d)));
	d.var_decl.kind = CONST;
	assert(!compiler::expr_may_ref(ident(d)));
	assert(!compiler::expr_may_ref(const_int(1)));
}

fn void assign_to_constant_is_an_error()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	Expr* c = const_int(10);
	assert(!compiler::sema_expr_check_assign(&context, c, null));
	test::eq(last_report(), "You cannot assign to a constant expression.");
	bool failed = false;
	assert(!compiler::sema_expr_check_assign(&context, const_int(1), &failed));
	assert(failed);
}

fn void assign_to_local_and_const()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	Decl* d = local_var("x", compiler::type_int);
	assert(compiler::sema_expr_check_assign(&context, ident(d), null));
	assert(d.var_decl.is_written);
	Decl* k = local_var("K", compiler::type_int);
	k.var_decl.kind = CONST;
	assert(!compiler::sema_expr_check_assign(&context, ident(k), null));
	test::eq(last_report(), "You cannot assign to a constant.");
}

fn void const_foldable()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* a = const_int(1);
	Expr* b = const_int(2);
	assert(compiler::expr_both_const_foldable(a, b, ADD));
	assert(!compiler::expr_both_const_foldable(a, b, AND));
	Expr* t = compiler::expr_new_const_bool(0, compiler::type_bool, true);
	Expr* f = compiler::expr_new_const_bool(0, compiler::type_bool, false);
	assert(compiler::expr_both_const_foldable(t, f, OR));
	assert(!compiler::expr_both_const_foldable(t, f, ADD));
	assert(!compiler::expr_both_const_foldable(a, t, EQ));
	assert(compiler::expr_const_foldable_unary(a, NEG));
	assert(!compiler::expr_const_foldable_unary(a, NOT));
	assert(compiler::expr_const_foldable_unary(t, NOT));
}

fn void ct_only_types()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::type_is_ct_only(compiler::type_member));
	assert(compiler::type_is_ct_only(compiler::type_wildcard));
	assert(!compiler::type_is_ct_only(compiler::type_int));
}

fn void type_property_validity()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::sema_type_property_is_valid_for_type(compiler::type_float, PROPERTY_NAN));
	assert(!compiler::sema_type_property_is_valid_for_type(compiler::type_int, PROPERTY_NAN));
	assert(compiler::sema_type_property_is_valid_for_type(compiler::type_int, PROPERTY_MAX));
	assert(!compiler::sema_type_property_is_valid_for_type(compiler::type_int, PROPERTY_LEN));
	Type* arr = compiler::type_get_array(compiler::type_int, 4);
	assert(compiler::sema_type_property_is_valid_for_type(arr, PROPERTY_LEN));
	assert(compiler::sema_type_property_is_valid_for_type(arr, PROPERTY_INNER));
	assert(!compiler::sema_type_property_is_valid_for_type(compiler::type_member, PROPERTY_SIZE));
}

fn void min_max_constants()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* e = compiler::expr_new(POISONED, 0);
	assert(compiler::sema_create_const_max(e, compiler::type_ichar, compiler::type_ichar));
	assert(e.const_expr.const_kind == INTEGER);
	test::eq((long)(ulong)e.const_expr.ixx.i, 127);
	assert(compiler::sema_create_const_min(e, compiler::type_short, compiler::type_short));
	test::eq((long)(ulong)e.const_expr.ixx.i, -32768);
	assert(compiler::sema_create_const_max(e, compiler::type_ulong, compiler::type_ulong));
	assert(e.const_expr.ixx.i == ulong::max);
	assert(e.const_expr.is_hex);
	assert(compiler::sema_create_const_min(e, compiler::type_uint, compiler::type_uint));
	assert(e.const_expr.ixx.i == 0);
}

fn void const_len_of_array()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Type* arr = compiler::type_get_array(compiler::type_int, 7);
	Expr* e = compiler::expr_new(POISONED, 0);
	assert(compiler::sema_create_const_len(e, arr, arr));
	test::eq((long)(ulong)e.const_expr.ixx.i, 7);
	Decl* d = local_var("a", arr);
	test::eq(compiler::sema_len_from_expr(ident(d)), 7);
	Decl* p = local_var("p", compiler::type_get_ptr(compiler::type_int));
	test::eq(compiler::sema_len_from_expr(ident(p)), -1);
}

fn void array_index_range()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SemaContext context;
	assert(compiler::sema_check_array_index(&context, const_int(5), false));
	Expr* big = compiler::expr_new_const_int(0, compiler::type_u128, 0);
	big.const_expr.ixx.i = (uint128)1 << 100;
	assert(!compiler::sema_check_array_index(&context, big, true));
	test::eq(last_report(), "The length is out of range: it cannot fit in a 'sz' (long).");
}
