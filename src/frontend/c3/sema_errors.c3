// Sema contract stubs for c3c src/compiler/sema_errors.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
// `sema_shadow_error` is already ported in diagnostics_inline.c3.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_errors.c:13
fn bool sema_type_error_on_binop(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_type_error_on_binop");
}
