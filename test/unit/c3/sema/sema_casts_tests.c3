// Tests for the c3 frontend conversions and constant folding helpers:
// sema_casts.c3 (cast_* / rules), sema_const.c3 (ct concat, len) and the
// function prototype map of sema_types.c3. Only builtin types are used, so no
// SemaContext is needed (the silent paths never report).
module c3_sema_casts_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Expr* cint(Type* type, ulong v) => compiler::expr_new_const_int(0, type, v);

module c3_sema_casts_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void int_casts()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	// Implicit narrowing of a constant that fits.
	Expr* e = cint(compiler::type_int, 3);
	assert(compiler::cast_implicit_silent(null, e, compiler::type_char, false));
	assert(e.type == compiler::type_char && e.const_expr.ixx.i == 3);
	// Out of range: implicit fails, explicit truncates.
	e = cint(compiler::type_int, 300);
	assert(!compiler::cast_implicit_silent(null, e, compiler::type_char, false));
	assert(compiler::cast_explicit_silent(null, e, compiler::type_char));
	assert(e.type == compiler::type_char && e.const_expr.ixx.i == 44);
	// Widening is fine, the constant is converted.
	e = cint(compiler::type_char, 200);
	assert(compiler::cast_implicit_silent(null, e, compiler::type_long, false));
	assert(e.type == compiler::type_long && e.const_expr.ixx.i == 200 && e.const_expr.ixx.type == I64);
}

fn void int_float_bool_casts()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* e = cint(compiler::type_int, 3);
	assert(compiler::cast_implicit_silent(null, e, compiler::type_double, false));
	assert(e.const_expr.const_kind == FLOAT && e.const_expr.fxx.f == 3.0 && e.type == compiler::type_double);
	// float -> int needs an explicit cast, and the constant must fit.
	Expr* f = compiler::expr_new_const_float(0, compiler::type_double, 2.75);
	assert(!compiler::cast_implicit_silent(null, f, compiler::type_int, false));
	assert(compiler::cast_explicit_silent(null, f, compiler::type_int));
	assert(f.const_expr.const_kind == INTEGER && f.const_expr.ixx.i == 2);
	Expr* big = compiler::expr_new_const_float(0, compiler::type_double, 1e30);
	assert(!compiler::cast_explicit_silent(null, big, compiler::type_int));
	// bool -> int is explicit only.
	Expr* b = compiler::expr_new_const_bool(0, compiler::type_bool, true);
	assert(!compiler::cast_implicit_silent(null, b, compiler::type_int, false));
	assert(compiler::cast_explicit_silent(null, b, compiler::type_int));
	assert(b.const_expr.const_kind == INTEGER && b.const_expr.ixx.i == 1);
	// int -> bool
	Expr* z = cint(compiler::type_int, 0);
	assert(compiler::cast_explicit_silent(null, z, compiler::type_bool));
	assert(z.const_expr.const_kind == BOOL && !z.const_expr.b);
}

fn void ptr_casts()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* e = cint(compiler::type_uptr, 16);
	assert(!compiler::cast_implicit_silent(null, e, compiler::type_voidptr, false));
	assert(compiler::cast_explicit_silent(null, e, compiler::type_voidptr));
	assert(e.const_expr.const_kind == POINTER && e.const_expr.ptr == 16);
	// void* -> int* is implicit.
	Expr* p = compiler::expr_new(CONST, 0);
	compiler::expr_rewrite_const_null(p, compiler::type_voidptr);
	assert(compiler::cast_implicit_silent(null, p, compiler::type_get_ptr(compiler::type_int), false));
	assert(p.type == compiler::type_get_ptr(compiler::type_int));
	// Pointer to a smaller int is rejected even explicitly.
	Expr* q = compiler::expr_new(CONST, 0);
	compiler::expr_rewrite_const_null(q, compiler::type_voidptr);
	assert(!compiler::cast_explicit_silent(null, q, compiler::type_char));
}

fn void promotion()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::cast_numeric_arithmetic_promotion(compiler::type_char) == compiler::type_cint);
	assert(compiler::cast_numeric_arithmetic_promotion(compiler::type_long) == compiler::type_long);
	assert(compiler::cast_numeric_arithmetic_promotion(compiler::type_float16) == compiler::type_float);
	assert(compiler::cast_numeric_arithmetic_promotion(compiler::type_double) == compiler::type_double);
}

fn void const_concat()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* a = compiler::expr_new_const_string(0, "ab");
	Expr* b = compiler::expr_new_const_string(0, "cd");
	assert(compiler::sema_len_from_const(a) == 2);
	Expr* r = compiler::expr_new(BINARY, 0);
	r.resolve_status = RUNNING;
	assert(compiler::sema_expr_analyse_ct_concat(null, r, a, b, null));
	assert(r.const_expr.const_kind == STRING);
	assert((String)r.const_expr.bytes.ptr[:r.const_expr.bytes.len] == "abcd");
	// String + a character appends its UTF-8 encoding.
	Expr* c = compiler::expr_new_const_string(0, "ab");
	Expr* ch = cint(compiler::type_int, 0xE9);
	Expr* r2 = compiler::expr_new(BINARY, 0);
	r2.resolve_status = RUNNING;
	assert(compiler::sema_expr_analyse_ct_concat(null, r2, c, ch, null));
	assert((String)r2.const_expr.bytes.ptr[:r2.const_expr.bytes.len] == "abé");
	// A non-unicode value fails (silently with a failed_ref).
	Expr* d = compiler::expr_new_const_string(0, "ab");
	Expr* neg = cint(compiler::type_int, 0x110000);
	Expr* r3 = compiler::expr_new(BINARY, 0);
	r3.resolve_status = RUNNING;
	bool failed;
	assert(!compiler::sema_expr_analyse_ct_concat(null, r3, d, neg, &failed));
	assert(failed);
}

fn void func_prototype_map()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	compiler::type_func_prototype_init(16);
	Signature sig1 = { .rtype = compiler::type_infoid(compiler::type_info_new_base(compiler::type_int, 0)) };
	Signature sig2 = { .rtype = compiler::type_infoid(compiler::type_info_new_base(compiler::type_int, 0)) };
	Signature sig3 = { .rtype = compiler::type_infoid(compiler::type_info_new_base(compiler::type_bool, 0)) };
	Type* f1 = compiler::sema_resolve_type_get_func(&sig1, C);
	Type* f2 = compiler::sema_resolve_type_get_func(&sig2, C);
	Type* f3 = compiler::sema_resolve_type_get_func(&sig3, C);
	assert(f1 == f2);
	assert(f1 != f3);
	assert(f1.type_kind == FUNC_RAW && f1.name == "fn int()");
	assert(f3.name == "fn bool()");
	// Growing the map keeps the entries.
	for (int i = 0; i < 40; i++)
	{
		Type* elem = compiler::type_get_array(compiler::type_int, (ArrayIndex)i + 1);
		Signature s = { .rtype = compiler::type_infoid(compiler::type_info_new_base(elem, 0)) };
		compiler::sema_resolve_type_get_func(&s, C);
	}
	assert(compiler::sema_resolve_type_get_func(&sig1, C) == f1);
}
