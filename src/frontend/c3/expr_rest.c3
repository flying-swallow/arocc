// Sema contract stubs for c3c src/compiler/expr.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
// Companion of expr.c3: the expr.c functions not ported yet. Merge into
// expr.c3 when they are ported.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// expr.c:134
fn bool expr_is_zero(Expr* expr)
{
	unreachable("sema stub: expr_is_zero");
}

// expr.c:493 (static)
fn ConstInitializer* initializer_for_index(ConstInitializer* initializer, ArrayIndex index, bool from_back)
{
	unreachable("sema stub: initializer_for_index");
}

// expr.c:533
fn void expr_rewrite_to_const_zero(Expr* expr, Type* type)
{
	unreachable("sema stub: expr_rewrite_to_const_zero");
}

// expr.c:606
fn Expr* expr_from_const_expr_at_index(Expr* expr, ArrayIndex index)
{
	unreachable("sema stub: expr_from_const_expr_at_index");
}

// expr.c:646
fn bool expr_rewrite_to_const_initializer_index(Type* list_type, ConstInitializer* list, Expr* result, int index, bool from_back)
{
	unreachable("sema stub: expr_rewrite_to_const_initializer_index");
}

// expr.c:675
fn bool expr_is_pure(Expr* expr)
{
	unreachable("sema stub: expr_is_pure");
}

// expr.c:834
fn bool expr_is_simple(Expr* expr, bool to_float)
{
	unreachable("sema stub: expr_is_simple");
}
