// Sema contract stubs for c3c src/compiler/sema_liveness.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_liveness.c:11 (static)
fn void sema_trace_type_liveness(Module* m, Type* type)
{
	unreachable("sema stub: sema_trace_type_liveness");
}

// sema_liveness.c:70 (static)
fn void sema_trace_exprid_liveness(Module* m, ExprId expr)
{
	unreachable("sema stub: sema_trace_exprid_liveness");
}

// sema_liveness.c:75 (static)
fn void sema_trace_astid_liveness(Module* m, AstId astid)
{
	unreachable("sema stub: sema_trace_astid_liveness");
}

// sema_liveness.c:80 (static)
fn void sema_trace_decl_list_liveness(Module* m, Decl*[] decllist)
{
	unreachable("sema stub: sema_trace_decl_list_liveness");
}

// sema_liveness.c:85 (static)
fn void sema_trace_expr_list_liveness(Module* m, Expr*[] exprlist)
{
	unreachable("sema stub: sema_trace_expr_list_liveness");
}

// sema_liveness.c:90 (static)
fn void sema_trace_stmt_chain_liveness(Module* m, AstId astid)
{
	unreachable("sema stub: sema_trace_stmt_chain_liveness");
}

// sema_liveness.c:110 (static)
fn void sema_trace_expr_asm_arg(Module* m, ExprAsmArg* arg)
{
	unreachable("sema stub: sema_trace_expr_asm_arg");
}

// sema_liveness.c:132 (static)
fn void sema_trace_asm_arg_list(Module* m, ExprAsmArg*[] list)
{
	unreachable("sema stub: sema_trace_asm_arg_list");
}

// sema_liveness.c:140 (static)
fn void sema_trace_stmt_liveness(Module* m, Ast* ast)
{
	unreachable("sema stub: sema_trace_stmt_liveness");
}

// sema_liveness.c:246 (static)
fn void sema_trace_const_initializer_liveness(Module* m, ConstInitializer* const_init)
{
	unreachable("sema stub: sema_trace_const_initializer_liveness");
}

// sema_liveness.c:296 (static)
fn void sema_trace_expr_liveness(Module* m, Expr* expr)
{
	unreachable("sema stub: sema_trace_expr_liveness");
}

// sema_liveness.c:549
fn void sema_trace_liveness()
{
	unreachable("sema stub: sema_trace_liveness");
}

// sema_liveness.c:598 (static)
fn void sema_trace_enum_associated(Module* m, Decl* decl)
{
	unreachable("sema stub: sema_trace_enum_associated");
}

// sema_liveness.c:606 (static)
fn void sema_trace_decl_dynamic_methods(Module* m, Decl* decl)
{
	unreachable("sema stub: sema_trace_decl_dynamic_methods");
}

// sema_liveness.c:623 (static)
fn void sema_trace_func_liveness(Module* m, Signature* sig)
{
	unreachable("sema stub: sema_trace_func_liveness");
}

// sema_liveness.c:629 (static)
fn void sema_trace_decl_internal(Module* m, Decl* decl)
{
	unreachable("sema stub: sema_trace_decl_internal");
}

// sema_liveness.c:725 (static)
fn bool decl_is_emitted_in_own_module(Decl* decl)
{
	unreachable("sema stub: decl_is_emitted_in_own_module");
}

// sema_liveness.c:731 (static)
fn void sema_trace_decl_used_externally(Module* m, Decl* decl)
{
	unreachable("sema stub: sema_trace_decl_used_externally");
}

// sema_liveness.c:754 (static)
fn void sema_trace_decl_liveness(Module* m, Decl* decl)
{
	unreachable("sema stub: sema_trace_decl_liveness");
}
