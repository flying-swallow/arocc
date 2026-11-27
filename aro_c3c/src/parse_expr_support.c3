// Support helpers for the parse_expr.c3 / parse_stmt.c3 ports.
//
// - `assign_*_ok`: the checks of c3c's ASSIGN_*_OR_RET macros when the
//   destination is an existing lvalue (a field, an out-parameter or a
//   reassigned local): `ASSIGN_EXPRID_OR_RET(x, e, r)` ->
//   `if (!assign_exprid_ok(&x, e)) return r;`. Like the macros they only
//   store on success. When the macro declares a fresh local, the ports write
//   `Expr* x = e; if (!expr_ok(x)) return r;` instead.
// - `copy_type_info_single` / `copy_attributes_single` live in copying.c3.
module aro::frontend::c3::compiler;

<* ASSIGN_EXPR_OR_RET into an existing lvalue. *>
fn bool assign_expr_ok(Expr** ref, Expr* expr)
{
	if (!expr_ok(expr)) return false;
	*ref = expr;
	return true;
}

<* ASSIGN_EXPRID_OR_RET. *>
fn bool assign_exprid_ok(ExprId* ref, Expr* expr)
{
	if (!expr_ok(expr)) return false;
	*ref = exprid(expr);
	return true;
}

<* ASSIGN_AST_OR_RET into an existing lvalue. *>
fn bool assign_ast_ok(Ast** ref, Ast* ast)
{
	if (!ast_ok(ast)) return false;
	*ref = ast;
	return true;
}

<* ASSIGN_ASTID_OR_RET. *>
fn bool assign_astid_ok(AstId* ref, Ast* ast)
{
	if (!ast_ok(ast)) return false;
	*ref = astid(ast);
	return true;
}

<* ASSIGN_DECL_OR_RET into an existing lvalue. *>
fn bool assign_decl_ok(Decl** ref, Decl* decl)
{
	if (!decl_ok(decl)) return false;
	*ref = decl;
	return true;
}

<* ASSIGN_DECLID_OR_RET (a null decl stores id 0). *>
fn bool assign_declid_ok(DeclId* ref, Decl* decl)
{
	if (!decl_ok(decl)) return false;
	*ref = decl ? declid(decl) : 0;
	return true;
}

<* ASSIGN_TYPE_OR_RET into an existing lvalue. *>
fn bool assign_type_ok(TypeInfo** ref, TypeInfo* type)
{
	if (!type_info_ok(type)) return false;
	*ref = type;
	return true;
}
