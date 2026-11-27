// Tests for the c3c sema_decls.c port (src/frontend/c3/sema_decls.c3): the
// standalone helpers (name/table lookups, natural alignment, @feat
// evaluation). Declaration analysis is covered end to end by
// aro_cc/test/src/c3:check_probe against c3c's test suite.
module c3_sema_decls_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn Expr* feature(String name)
{
	Expr* e = compiler::expr_new(UNRESOLVED_IDENTIFIER, 0);
	TokenType t;
	e.unresolved_ident_expr.ident = compiler::symtab_add(name, &t);
	e.unresolved_ident_expr.is_const = true;
	return e;
}

module c3_sema_decls_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void decls_name_helpers()
{
	assert(compiler::char_first_is_upper("__Foo"));
	assert(!compiler::char_first_is_upper("_foo"));
	assert(!compiler::char_first_is_upper("___"));
	assert(compiler::operator_overload_to_string(compiler::OVERLOAD_SHL_ASSIGN) == "<<=");
	assert(compiler::OVERLOAD_NAME[compiler::OVERLOAD_ELEMENT_REF] == "&[]");
	assert(compiler::OVERLOAD_MAY_BE_REVERSE[compiler::OVERLOAD_PLUS]);
	assert(!compiler::OVERLOAD_MAY_BE_REVERSE[compiler::OVERLOAD_PLUS_ASSIGN]);
	assert(compiler::attribute_domain_to_string(compiler::ATTR_FAULT) == "excuse");
	assert(compiler::stack_probe_from_string("inline") == compiler::STACK_PROBE_INLINE);
	assert(compiler::stack_probe_from_string("x") == compiler::STACK_PROBE_NOT_SET);
	assert(compiler::stack_protector_from_string("strong") == compiler::STACK_PROTECTOR_STRONG);
}

fn void decls_attribute_domains()
{
	assert((compiler::ATTRIBUTE_DOMAIN[AttributeType.PACKED.ordinal] & compiler::ATTR_STRUCT) != 0);
	assert((compiler::ATTRIBUTE_DOMAIN[AttributeType.PACKED.ordinal] & compiler::ATTR_FUNC) == 0);
	assert(compiler::ATTRIBUTE_DOMAIN[AttributeType.JUMP.ordinal] == 0);
}

fn void decls_natural_alignment()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(compiler::sema_get_max_natural_alignment(compiler::type_void) == 1);
	assert(compiler::sema_get_max_natural_alignment(compiler::type_long) == 8);
	assert(compiler::sema_get_max_natural_alignment(compiler::type_voidptr) == 8);
	assert(compiler::sema_get_max_natural_alignment(compiler::type_get_slice(compiler::type_char)) == 8);
}

fn void decls_feature_evaluation()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* on = feature("FEAT_ON");
	compiler::htable_set(&compiler::compiler.context.features, (void*)on.unresolved_ident_expr.ident.ptr, (void*)on.unresolved_ident_expr.ident.ptr);
	Expr* off = feature("FEAT_OFF");
	assert(compiler::sema_evaluate_feature_expr_list({ off }) == compiler::BOOL_FALSE);
	assert(compiler::sema_evaluate_feature_expr_list({ off, on }) == compiler::BOOL_TRUE);
}
