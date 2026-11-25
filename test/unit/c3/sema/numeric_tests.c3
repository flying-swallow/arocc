// Tests for the c3 frontend numeric helpers: bigint.c3 (i128_* / int_*),
// number.c3 (expr_const_*) and a few types.c3 sema predicates.
module c3_numeric_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Int mk(long v, TypeKind kind) => { .i = (uint128)(int128)v, .type = kind };

module c3_numeric_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void i128_ops()
{
	uint128 max = compiler::UINT128_MAX;
	assert(compiler::i128_add64(max, 1) == 0);
	assert(compiler::i128_shl64(1, 127) == compiler::INT128_MIN);
	assert(compiler::i128_shl64(1, 128) == 0);
	assert(compiler::i128_lshr64(compiler::INT128_MIN, 127) == 1);
	assert(compiler::i128_ashr64(compiler::INT128_MIN, 127) == max);
	assert(compiler::i128_ashr64(compiler::INT128_MIN, 200) == max);
	assert(compiler::i128_udiv(100, 7) == 14 && compiler::i128_urem(100, 7) == 2);
	assert(compiler::i128_sdiv(compiler::i128_from_signed(-100), 7) == compiler::i128_from_signed(-14));
	assert(compiler::i128_srem(compiler::i128_from_signed(-100), 7) == compiler::i128_from_signed(-2));
	uint128 x = (uint128)1 << 100;
	assert(compiler::i128_clz(&x) == 27 && compiler::i128_ctz(&x) == 100);
	assert(compiler::i128_popcnt(max) == 128);
	assert(compiler::i128_from_str("340282366920938463463374607431768211455") == max);
	assert(compiler::i128_to_float((uint128)1 << 64) == 18446744073709551616.0);
	assert(compiler::i128_to_float_signed(compiler::i128_from_signed(-5)) == -5.0);
	assert(compiler::i128_from_double_signed(-3.0) == compiler::i128_from_signed(-3));
	bool wrapped;
	compiler::i128_add_uwrap64(max, 2, &wrapped);
	assert(wrapped);
	assert(compiler::int128_scomp64(compiler::i128_from_signed(-2), -1) == compiler::CMP_LT);
}

fn void int_ops()
{
	// Truncation, sign / zero extension.
	assert(compiler::int_conv(mk(300, I32), U8).i == 44);
	assert(compiler::int_conv(mk(200, U8), I8).i == (uint128)(int128)-56);
	assert(compiler::int_conv(mk(-1, I8), U32).i == 0xFFFF_FFFF);
	assert(compiler::int_conv(mk(-1, I8), I64).i == (uint128)(int128)-1);
	// Wrapping arithmetic in the type width.
	assert(compiler::int_add(mk(127, I8), mk(1, I8)).i == (uint128)(int128)-128);
	assert(compiler::int_add(mk(255, U8), mk(1, U8)).i == 0);
	assert(compiler::int_mul(mk(16, U8), mk(16, U8)).i == 0);
	assert(compiler::int_neg(mk(1, U32)).i == 0xFFFF_FFFF);
	assert(compiler::int_not(mk(0, U16)).i == 0xFFFF);
	// Division: signed rounds to zero, INT_MIN / -1 wraps.
	assert(compiler::int_div(mk(-7, I32), mk(2, I32)).i == (uint128)(int128)-3);
	assert(compiler::int_rem(mk(-7, I32), mk(2, I32)).i == (uint128)(int128)-1);
	assert(compiler::int_div(mk(int::min, I32), mk(-1, I32)).i == (uint128)(int128)int::min);
	assert(compiler::int_div(mk(7, U64), mk(2, U64)).i == 3);
	assert(compiler::int_shr64(mk(-8, I32), 1).i == (uint128)(int128)-4);
	assert(compiler::int_shr64(mk(0x80, U8), 7).i == 1);
	assert(compiler::int_shl64(mk(1, U8), 8).i == 0);
	assert(compiler::int_bits_needed(mk(-1, I32)) == 1);
	assert(compiler::int_bits_needed(mk(255, U32)) == 8);
	assert(compiler::int_bits_needed(mk(128, I32)) == 9);
	assert(compiler::int_to_real(mk(-3, I32), 53) == -3.0);
	assert(compiler::int_to_real({ .i = compiler::UINT128_MAX, .type = U128 }, 53) == 340282366920938463463374607431768211456.0);
	assert(compiler::int_from_real(-2.0, I16).i == (uint128)(int128)-2);
}

fn void const_compare()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* a = compiler::expr_new_const_int(0, compiler::type_int, 3);
	Expr* b = compiler::expr_new_const_int(0, compiler::type_int, 5);
	assert(compiler::expr_const_compare(&a.const_expr, &b.const_expr, BinaryOp.LT));
	assert(!compiler::expr_const_compare(&a.const_expr, &b.const_expr, BinaryOp.EQ));
	assert(compiler::expr_const_compare(&b.const_expr, &b.const_expr, BinaryOp.GE));
	assert(compiler::expr_const_in_range(&b.const_expr, &b.const_expr, &a.const_expr, &b.const_expr));
	assert(!compiler::expr_const_in_range(&b.const_expr, &b.const_expr, &a.const_expr, &a.const_expr));
	Expr* t = compiler::expr_new_const_bool(0, compiler::type_bool, true);
	Expr* f = compiler::expr_new_const_bool(0, compiler::type_bool, false);
	assert(compiler::expr_const_compare(&t.const_expr, &f.const_expr, BinaryOp.NE));
	Expr* x = compiler::expr_new_const_float(0, compiler::type_double, 1.5);
	Expr* y = compiler::expr_new_const_float(0, compiler::type_double, 2.5);
	assert(compiler::expr_const_compare(&x.const_expr, &y.const_expr, BinaryOp.LE));
	// Overflow checks.
	Expr* big = compiler::expr_new_const_int(0, compiler::type_int, 300);
	assert(compiler::expr_const_will_overflow(&big.const_expr, I8));
	assert(!compiler::expr_const_will_overflow(&big.const_expr, I16));
	Expr* huge = compiler::expr_new_const_float(0, compiler::type_double, 1e300);
	assert(compiler::expr_const_will_overflow(&huge.const_expr, F32));
	assert(!compiler::expr_const_will_overflow(&huge.const_expr, F64));
	assert(compiler::expr_const_to_error_string(&big.const_expr) == "300");
	assert(compiler::expr_const_to_error_string(&t.const_expr) == "true");
	// expr_is_zero needs sema_cast_const (sema_expr2.c3); covered once sema lands.
	assert(compiler::expr_is_pure(a) && compiler::expr_is_simple(a, false));
}

fn void type_predicates()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::type_is_ordered(compiler::type_int));
	assert(compiler::type_is_comparable(compiler::type_double));
	assert(!compiler::type_is_aggregate(compiler::type_int));
	assert(compiler::type_is_aggregate(compiler::type_get_slice(compiler::type_int)));
	assert(compiler::type_find_max_type(null, compiler::type_int, compiler::type_long, null, null) == compiler::type_long);
	assert(compiler::type_find_max_type(null, compiler::type_int, compiler::type_uint, null, null) == compiler::type_uint);
	assert(compiler::type_find_max_type(null, compiler::type_long, compiler::type_uint, null, null) == compiler::type_long);
	assert(compiler::type_find_max_type(null, compiler::type_int, compiler::type_float, null, null) == compiler::type_float);
	assert(compiler::type_find_max_type(null, compiler::type_bool, compiler::type_int, null, null) == null);
	assert(compiler::type_get_introspection_kind(TypeKind.I32) == compiler::INTROSPECT_TYPE_SIGNED_INT);
	assert(compiler::type_base_module(compiler::type_int) == null);
	assert(compiler::type_may_have_method(compiler::type_int));
	assert(compiler::type_may_have_method(compiler::type_voidptr));
	assert(compiler::type_array_element_is_equivalent(null, compiler::type_int, compiler::type_uint, false) == compiler::TYPE_SAME_INT_SIZE);
	compiler::scratch_buffer_clear();
	compiler::type_mangle_introspect_name_to_buffer(compiler::type_get_ptr(compiler::type_int));
	assert(((ZString)compiler::scratch_buffer_to_string()).str_view() == "p$int");
}
