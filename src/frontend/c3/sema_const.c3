// Sema contract stubs for c3c src/compiler/sema_const.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_const.c:10
fn ArrayIndex sema_len_from_const(Expr* expr)
{
	unreachable("sema stub: sema_len_from_const");
}

// sema_const.c:57 (static)
fn bool sema_expr_const_append(SemaContext* context, Expr* append_expr, Expr* list, Expr* element, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_const_append");
}

// sema_const.c:84 (static)
fn void expr_concat_const_bytes(Expr* expr, Type* type, bool is_bytes, String a, String b, ArrayIndex alen, ArrayIndex blen)
{
	unreachable("sema stub: expr_concat_const_bytes");
}

// sema_const.c:104 (static)
fn void expr_concat_character(Expr* expr, Type* type, String a, ArrayIndex alen, ulong c)
{
	unreachable("sema stub: expr_concat_character");
}

// sema_const.c:145 (static)
fn bool sema_concat_bytes_and_other(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_concat_bytes_and_other");
}

// sema_const.c:215 (static)
fn bool sema_append_concat_const_bytes(SemaContext* context, Expr* expr, Expr* list, Expr* element, bool* failed_ref)
{
	unreachable("sema stub: sema_append_concat_const_bytes");
}

// sema_const.c:239 (static)
fn bool sema_append_const_array_one(SemaContext* context, Expr* expr, Expr* list, Expr* element, bool* failed_ref)
{
	unreachable("sema stub: sema_append_const_array_one");
}

// sema_const.c:300 (static)
fn ConstInitializer* expr_const_initializer_from_expr(Expr* expr)
{
	unreachable("sema stub: expr_const_initializer_from_expr");
}

// sema_const.c:325
fn bool sema_expr_analyse_ct_concat(SemaContext* context, Expr* concat_expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ct_concat");
}
