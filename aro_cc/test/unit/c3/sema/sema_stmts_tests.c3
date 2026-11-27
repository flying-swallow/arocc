// Tests for the c3c sema_stmts.c / sema_static_analysis.c / sema_liveness.c /
// sema_errors.c ports (src/frontend/c3/sema_stmts.c3, sema_static_analysis.c3,
// sema_liveness.c3, sema_errors.c3). Only hand-built AST nodes and builtin
// types are used: the null-pointer flow analysis, the liveness tracer, and
// the standalone statement helpers (contract messages, enum switch errors,
// unused-local warnings, defer scans). Expected texts follow c3c 54bab366a.
module c3_sema_stmts_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Decl* local_ptr(String name)
{
	Decl* d = compiler::decl_calloc();
	d.decl_kind = VAR;
	d.var_decl.kind = LOCAL;
	d.name = name;
	d.type = compiler::type_get_ptr(compiler::type_int);
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

fn Expr* null_ptr()
{
	Expr* p = compiler::expr_new(CONST, 0);
	compiler::expr_rewrite_const_null(p, compiler::type_voidptr);
	return p;
}

fn Expr* enum_const(Decl* value)
{
	Expr* e = compiler::expr_new(CONST, 0);
	e.const_expr.const_kind = ENUM;
	e.const_expr.enum_val = value;
	e.resolve_status = DONE;
	return e;
}

fn Expr* contract(String expr_string, String comment)
{
	Expr* e = compiler::expr_new(CONTRACT, 0);
	e.contract_expr.expr_string = expr_string;
	e.contract_expr.comment = comment;
	return e;
}

fn String last_report() => compiler::global_diagnostics.reports[^1].text;

module c3_sema_stmts_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void sa_slots_and_join()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SAContext c;
	Decl* p = local_ptr("p");
	Decl* q = local_ptr("q");
	assert(compiler::sa_allocate_slot(&c, p) == 0);
	assert(compiler::sa_allocate_slot(&c, q) == 1);
	assert(compiler::sa_allocate_slot(&c, p) == 0);
	assert(compiler::sa_find_slot(&c, q) == 1);
	compiler::sa_set_slot_nullability(&c, 0, NULL);
	compiler::sa_set_slot_nullability(&c, 1, NOT_NULL);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NULL);
	assert(compiler::sa_analyse_ident_expr(&c, ident(q)) == NOT_NULL);
	SAState first = c.state;
	compiler::sa_set_slot_nullability(&c, 0, UNKNOWN);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == UNKNOWN);
	// Joining keeps only the facts both paths agree on.
	c.state = compiler::sa_state_join(first, c.state);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == UNKNOWN);
	assert(compiler::sa_analyse_ident_expr(&c, ident(q)) == NOT_NULL);
	// Statics are never tracked.
	Decl* s = local_ptr("s");
	s.var_decl.is_static = true;
	assert(compiler::sa_allocate_slot(&c, s) == -1);
}

fn void sa_narrowing()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SAContext c;
	Decl* p = local_ptr("p");
	compiler::sa_allocate_slot(&c, p);
	Expr* eq = compiler::expr_new_binary(0, ident(p), null_ptr(), EQ);
	assert(compiler::sa_expr_is_simple(eq));
	assert(!compiler::sa_expr_is_simple(compiler::expr_new_binary(0, ident(p), null_ptr(), ADD)));
	SAState start = c.state;
	compiler::sa_narrow(&c, eq, true);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NULL);
	assert(!c.state.dead);
	c.state = start;
	compiler::sa_narrow(&c, eq, false);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NOT_NULL);
	// Narrowing to the opposite of a known value makes the path dead.
	compiler::sa_narrow(&c, eq, true);
	assert(c.state.dead);
	// `null != p` narrows the right-hand side.
	c.state = start;
	compiler::sa_narrow(&c, compiler::expr_new_binary(0, null_ptr(), ident(p), NE), true);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NOT_NULL);
}

fn void sa_null_deref_is_reported()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SAContext c;
	// `int* p;` is zero initialized, so it is known null.
	Decl* p = local_ptr("p");
	compiler::sa_analyse_declare(&c, p);
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NULL);
	Expr* deref = compiler::expr_new(UNARY, 0);
	deref.unary_expr.operator = DEREF;
	deref.unary_expr.expr = ident(p);
	int errors = compiler::compiler.context.errors_found;
	compiler::sa_analyse_expr(&c, deref);
	assert(!c.bail);
	assert(compiler::compiler.context.errors_found == errors + 1);
	test::eq(last_report(), "This would dereference a null pointer.");
	// `p = &x` (a TADDR here) makes it non-null: no further report.
	Expr* taddr = compiler::expr_new(UNARY, 0);
	taddr.unary_expr.operator = TADDR;
	taddr.unary_expr.expr = compiler::expr_new_const_int(0, compiler::type_int, 1);
	compiler::sa_analyse_expr(&c, compiler::expr_new_binary(0, ident(p), taddr, ASSIGN));
	assert(compiler::sa_analyse_ident_expr(&c, ident(p)) == NOT_NULL);
	compiler::sa_analyse_expr(&c, deref);
	assert(compiler::compiler.context.errors_found == errors + 1);
	// `@noinit` locals are unknown.
	Decl* r = local_ptr("r");
	r.var_decl.no_init = true;
	compiler::sa_analyse_declare(&c, r);
	assert(compiler::sa_analyse_ident_expr(&c, ident(r)) == UNKNOWN);
}

fn void liveness_traces_types_and_vars()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Type* ptr = compiler::type_get_ptr(compiler::type_long);
	compiler::sema_trace_type_liveness(null, ptr);
	assert(ptr.is_live && compiler::type_long.is_live);
	Decl* v = local_ptr("v");
	v.var_decl.init_expr = null_ptr();
	compiler::sema_trace_decl_liveness(null, v);
	assert(v.is_live);
	assert(v.type.is_live && compiler::type_voidptr.is_live);
	assert(compiler::decl_is_emitted_in_own_module(v) == false);
	v.var_decl.kind = GLOBAL;
	assert(compiler::decl_is_emitted_in_own_module(v));
}

fn void contract_messages()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	test::eq(compiler::contract_to_message(contract("x > 0", {}), false), "@require \"x > 0\" violated.");
	test::eq(compiler::contract_to_message(contract("x > 0", "too small"), false), "@require \"x > 0\" violated: 'too small'.");
	test::eq(compiler::contract_to_message(contract("return > 0", {}), true), "@ensure \"return > 0\" violated.");
	test::eq(compiler::contract_to_message(contract("a", "b"), true), "@ensure \"a\" violated: 'b'.");
	assert(compiler::contract_panic_function(contract("a", "b"), true) == FN_ENSURE_MESSAGE);
}

fn void missing_enum_cases_message()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Decl*[4] values;
	String[4] names = { "A", "B", "C", "D" };
	for (int i = 0; i < 4; i++)
	{
		values[i] = compiler::decl_calloc();
		values[i].decl_kind = ENUM_CONSTANT;
		values[i].name = names[i];
		values[i].enum_constant.inner_ordinal = i;
	}
	Ast* case_b = compiler::new_ast(CASE_STMT, 0);
	case_b.case_stmt.expr = compiler::exprid(enum_const(values[1]));
	Ast*[1] cases = { case_b };
	test::eq(compiler::create_missing_enums_in_switch_error(&cases, 1, &values),
		"3 enum values were not handled in the switch: A, C and D - either add them or use 'default'.");
	// A range B..D leaves only A.
	case_b.case_stmt.to_expr = compiler::exprid(enum_const(values[3]));
	test::eq(compiler::create_missing_enums_in_switch_error(&cases, 3, &values),
		"Enum value A was not handled in the switch - either add it or add 'default'.");
}

fn void unused_local_warning()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	WarningLevel saved = compiler::compiler.build.warnings.unused_local;
	defer compiler::compiler.build.warnings.unused_local = saved;
	SemaContext context;
	Decl* x = local_ptr("x");
	Decl* used = local_ptr("used");
	used.is_used = true;
	Decl*[2] locals = { used, x };
	context.locals = &locals;
	context.active_scope.current_local = 2;
	DynamicScope old_scope;
	sz reports = compiler::global_diagnostics.reports.len();
	compiler::compiler.build.warnings.unused_local = SILENT;
	assert(compiler::sema_scope_check_locals(&context, old_scope));
	assert(compiler::global_diagnostics.reports.len() == reports);
	compiler::compiler.build.warnings.unused_local = WARN;
	assert(compiler::sema_scope_check_locals(&context, old_scope));
	test::eq(last_report(), "The variable 'x' is never used.");
	compiler::compiler.build.warnings.unused_local = ERROR;
	assert(!compiler::sema_scope_check_locals(&context, old_scope));
	// Locals from before the scope are not checked.
	old_scope.current_local = 2;
	assert(compiler::sema_scope_check_locals(&context, old_scope));
}

fn void defer_and_try_helpers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Ast* d1 = compiler::new_ast(DEFER_STMT, 0);
	Ast* d2 = compiler::new_ast(DEFER_STMT, 0);
	d2.defer_stmt.prev_defer = compiler::astid(d1);
	bool has_catch = false;
	assert(!compiler::sema_defer_has_try_or_catch(compiler::astid(d2), 0, &has_catch));
	d1.defer_stmt.is_try = true;
	assert(compiler::sema_defer_has_try_or_catch(compiler::astid(d2), 0, &has_catch) && !has_catch);
	// The bottom of the chain is excluded.
	assert(!compiler::sema_defer_has_try_or_catch(compiler::astid(d2), compiler::astid(d1), &has_catch));
	d2.defer_stmt.is_catch = true;
	assert(compiler::sema_defer_has_try_or_catch(compiler::astid(d2), 0, &has_catch) && has_catch);

	// Casts and rvalues are looked through.
	Decl* p = local_ptr("p");
	Expr* id = ident(p);
	Expr* rv = compiler::expr_new(RVALUE, 0);
	rv.inner_expr = id;
	Expr* to_bool = compiler::expr_new(INT_TO_BOOL, 0);
	to_bool.int_to_bool_expr.inner = rv;
	assert(compiler::sema_dive_into_expression(to_bool) == id);

	// `if (try foo())` accepts calls but not binary expressions.
	Expr* call = compiler::expr_new(CALL, 0);
	call.resolve_status = DONE;
	assert(compiler::sema_expr_valid_try_expression(call));
	Expr* bin = compiler::expr_new_binary(0, ident(p), null_ptr(), EQ);
	bin.resolve_status = DONE;
	assert(!compiler::sema_expr_valid_try_expression(bin));
	Expr* two = compiler::expr_new(TWO, 0);
	two.resolve_status = DONE;
	two.two_expr.first = bin;
	two.two_expr.last = call;
	assert(compiler::sema_expr_valid_try_expression(two));
}

fn void contract_asserts_are_prepended()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Ast* body = compiler::new_ast(COMPOUND_STMT, 0);
	Ast* stmt = compiler::new_ast(NOP_STMT, 0);
	body.compound_stmt.first_stmt = compiler::astid(stmt);
	compiler::sema_append_contract_asserts(0, body);
	assert(body.compound_stmt.first_stmt == compiler::astid(stmt));
	Ast* assert_stmt = compiler::new_ast(ASSERT_STMT, 0);
	compiler::sema_append_contract_asserts(compiler::astid(assert_stmt), body);
	Ast* first = compiler::astptr(body.compound_stmt.first_stmt);
	assert(first.ast_kind == COMPOUND_STMT);
	assert(first.compound_stmt.first_stmt == compiler::astid(assert_stmt));
	assert(first.next == compiler::astid(stmt));
}

fn void binop_type_error()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* l = compiler::expr_new_const_int(0, compiler::type_int, 1);
	Expr* r = compiler::expr_new_const_bool(0, compiler::type_bool, true);
	Expr* e = compiler::expr_new_binary(0, l, r, MULT);
	SemaContext context;
	assert(!compiler::sema_type_error_on_binop(&context, e));
	test::eq(last_report(), "* is not defined in the expression 'int' * 'bool'.");
}
