// Support helpers for the parse_expr.c3 / parse_stmt.c3 ports.
//
// - `assign_*_ok`: the checks of c3c's ASSIGN_*_OR_RET macros when the
//   destination is an existing lvalue (a field, an out-parameter or a
//   reassigned local): `ASSIGN_EXPRID_OR_RET(x, e, r)` ->
//   `if (!assign_exprid_ok(&x, e)) return r;`. Like the macros they only
//   store on success. When the macro declares a fresh local, the ports write
//   `Expr* x = e; if (!expr_ok(x)) return r;` instead.
// - `copy_type_info_single` / `copy_attributes_single`: stand-ins for the
//   c3c copying.c entry points (copying.c is not ported yet). They copy the
//   TypeInfo / Attr nodes like c3c but only shallow-copy (one node) the
//   expressions hanging off them (array lengths, generic parameters, typeof
//   expressions, attribute arguments), where c3c deep-copies them with
//   copy_expr. Replace with the real port when copying.c lands.
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

fn Expr* copy_expr_shallow_stub(Expr* expr) @local => expr ? expr_copy_node(expr) : null;

fn TypeInfo* copy_type_info_stub(TypeInfo* source) @local
{
	if (!source) return null;
	TypeInfo* copy = type_info_copy_node(source);
	if (source.resolve_status == DONE) return copy;
	switch (source.kind)
	{
		case INFO_POISON:
			return copy;
		case INFO_CT_IDENTIFIER:
		case INFO_IDENTIFIER:
			return copy;
		case INFO_GENERIC:
			copy.generic.base = copy_type_info_stub(copy.generic.base);
			Expr*[] params;
			foreach (p : copy.generic.params) @vec_add(&params, copy_expr_shallow_stub(p));
			copy.generic.params = params;
			return copy;
		case INFO_TYPEFROM:
		case INFO_TYPEOF:
			copy.unresolved_type_expr = copy_expr_shallow_stub(source.unresolved_type_expr);
			return copy;
		case INFO_VECTOR:
		case INFO_ARRAY:
			copy.array.len = copy_expr_shallow_stub(source.array.len);
			copy.array.base = copy_type_info_stub(source.array.base);
			return copy;
		case INFO_INFERRED_ARRAY:
		case INFO_SLICE:
		case INFO_INFERRED_VECTOR:
			copy.array.base = copy_type_info_stub(source.array.base);
			return copy;
		case INFO_POINTER:
			copy.pointer = copy_type_info_stub(source.pointer);
			return copy;
	}
}

<* c3c copying.c `copy_type_info_single` (expressions shallow-copied, see header). *>
fn TypeInfo* copy_type_info_single(TypeInfo* type_info) => copy_type_info_stub(type_info);

<* c3c copying.c `copy_attributes_single` (expressions shallow-copied, see header). *>
fn Attr*[] copy_attributes_single(Attr*[] attr_list)
{
	if (!attr_list.len) return attr_list;
	Attr*[] list;
	foreach (attribute : attr_list)
	{
		Attr* copy = null;
		if (attribute)
		{
			copy = calloc_arena(Attr::size);
			*copy = *attribute;
			Expr*[] exprs;
			foreach (e : attribute.exprs) @vec_add(&exprs, copy_expr_shallow_stub(e));
			copy.exprs = exprs;
		}
		@vec_add(&list, copy);
	}
	return list;
}
