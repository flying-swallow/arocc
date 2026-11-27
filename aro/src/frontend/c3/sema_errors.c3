// Port of c3c src/compiler/sema_errors.c (revision 54bab366a).
// `sema_shadow_error` is already ported in diagnostics_inline.c3.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_errors.c:13
fn bool sema_type_error_on_binop(SemaContext* context, Expr* expr)
{
	String c = token_type_to_string(binaryop_to_token(expr.binary_expr.operator));
	return @sema_error_at(context, expr.loc, "%s is not defined in the expression %s %s %s.",
		c, type_quoted_error_string(exprptr(expr.binary_expr.left).type),
		c, type_quoted_error_string(exprptr(expr.binary_expr.right).type));
}
