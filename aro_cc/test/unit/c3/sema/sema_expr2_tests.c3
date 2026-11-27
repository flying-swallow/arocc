// Tests for the second half of c3c sema_expr.c (src/frontend/c3/sema_expr2.c3):
// the helpers that do not depend on the rest of sema yet (swizzle keywords,
// builtin lookup, path/ident splitting, operator precedence checks,
// const folding of plain constants). Expectations follow c3c 54bab366a.
module c3_sema_expr2_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn Expr* resolved(Expr* e)
{
	e.resolve_status = DONE;
	return e;
}

module c3_sema_expr2_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void swizzle_keywords()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::sema_kw_is_swizzle("xyzw", 4));
	assert(compiler::sema_kw_is_swizzle("rgba", 4));
	assert(compiler::sema_kw_is_swizzle("xxy", 3));
	assert(!compiler::sema_kw_is_swizzle("xq", 2));
	assert(!compiler::sema_kw_is_swizzle("len", 3));
}

fn void builtin_lookup()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	TokenType tt = IDENT;
	String max = compiler::symtab_add("max", &tt);
	assert(compiler::builtin_by_name(max) == BuiltinFunction.MAX);
	tt = IDENT;
	String nope = compiler::symtab_add("not_a_builtin_zz", &tt);
	assert(compiler::builtin_by_name(nope) == BuiltinFunction.NONE);
}

fn void split_path_ref()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ModulePath* path;
	String ident;
	// symtab_find only returns names that are already interned.
	TokenType tt = IDENT;
	compiler::symtab_add("foo", &tt);
	tt = TYPE_IDENT;
	compiler::symtab_add("Foo", &tt);
	assert(compiler::sema_splitpathref("bar_unknown", 11, &path, &ident) == IDENT);
	assert(ident.ptr == null);
	assert(compiler::sema_splitpathref("foo", 3, &path, &ident) == IDENT);
	assert(path == null);
	test::eq(ident, "foo");
	assert(compiler::sema_splitpathref("Foo", 3, &path, &ident) == TYPE_IDENT);
	assert(compiler::sema_splitpathref("FOO", 3, &path, &ident) == CONST_IDENT);
	assert(compiler::sema_splitpathref("std::io::Foo", 12, &path, &ident) == TYPE_IDENT);
	assert(path != null);
	test::eq(path.module_name, "std::io");
	test::eq(ident, "Foo");
	assert(compiler::sema_splitpathref("1abc", 4, &path, &ident) == INVALID_TOKEN);
	assert(compiler::sema_splitpathref("std::Io::foo", 12, &path, &ident) == INVALID_TOKEN);
}

fn void unclear_precedence()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* a = compiler::expr_new_const_int(0, compiler::type_int, 1);
	Expr* b = compiler::expr_new_const_int(0, compiler::type_int, 2);
	// a & b | c is unclear, a & b & c is fine, a + b | c is fine.
	Expr* band = compiler::expr_new_binary(0, a, b, BIT_AND);
	Expr* bor = compiler::expr_new_binary(0, band, b, BIT_OR);
	assert(compiler::sema_binary_check_unclear_op_precedence(band, bor, b));
	Expr* band2 = compiler::expr_new_binary(0, band, b, BIT_AND);
	assert(!compiler::sema_binary_check_unclear_op_precedence(band, band2, b));
	Expr* add = compiler::expr_new_binary(0, a, b, ADD);
	assert(!compiler::sema_binary_check_unclear_op_precedence(add, bor, b));
	// a < b == c is unclear; grouping removes it.
	Expr* lt = compiler::expr_new_binary(0, a, b, LT);
	Expr* eq = compiler::expr_new_binary(0, lt, b, EQ);
	assert(compiler::sema_binary_check_unclear_op_precedence(lt, eq, b));
	lt.binary_expr.grouped = true;
	assert(!compiler::sema_binary_check_unclear_op_precedence(lt, eq, b));
	// a << b >> c
	Expr* shl = compiler::expr_new_binary(0, a, b, SHL);
	Expr* shr = compiler::expr_new_binary(0, a, shl, SHR);
	assert(compiler::sema_binary_check_unclear_op_precedence(a, shr, shl));
}

fn void cast_const_on_constants()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::sema_cast_const(resolved(compiler::expr_new_const_int(0, compiler::type_int, 3))));
	assert(compiler::sema_cast_const(resolved(compiler::expr_new_const_bool(0, compiler::type_bool, true))));
	Expr* recast = resolved(compiler::expr_new(RECAST, 0));
	recast.inner_expr = resolved(compiler::expr_new_const_int(0, compiler::type_int, 7));
	recast.type = compiler::type_long;
	assert(compiler::sema_cast_const(recast));
	assert(compiler::expr_is_const_int(recast));
	assert(recast.type == compiler::type_long);
}
