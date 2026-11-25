// Sema contract stubs for c3c src/compiler/sema_static_analysis.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

const int MAX_SLOTS = 64;

alias FlagSlot = ulong;
alias SASlotId = int;

struct SAState
{
	FlagSlot is_null;
	FlagSlot not_null;
	bool dead;
}

struct SAContext
{
	bool bail;
	DeclId[MAX_SLOTS] slots;
	int slot_count;
	SAState state;
}

enum SANullability : char
{
	UNKNOWN,
	NULL,
	NOT_NULL,
}

// sema_static_analysis.c:70
fn void sema_static_analysis()
{
	unreachable("sema stub: sema_static_analysis");
}

// sema_static_analysis.c:83 (static)
fn void sa_analyse_functions(Decl*[] functions)
{
	unreachable("sema stub: sa_analyse_functions");
}

// sema_static_analysis.c:94 (static)
fn void sa_analyse_function(SAContext* c, Decl* func)
{
	unreachable("sema stub: sa_analyse_function");
}

// sema_static_analysis.c:120 (static)
fn void sa_analyse_stmt(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_stmt");
}

// sema_static_analysis.c:194 (static)
fn void sa_analyse_stmt_chain(SAContext* c, AstId id)
{
	unreachable("sema stub: sa_analyse_stmt_chain");
}

// sema_static_analysis.c:204 (static)
fn void sa_analyse_expr_stmt(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_expr_stmt");
}

// sema_static_analysis.c:209 (static)
fn void sa_analyse_declare(SAContext* c, Decl* decl)
{
	unreachable("sema stub: sa_analyse_declare");
}

// sema_static_analysis.c:235 (static)
fn void sa_analyse_return(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_return");
}

// sema_static_analysis.c:240 (static)
fn void sa_analyse_block_exit(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_block_exit");
}

// sema_static_analysis.c:245 (static)
fn void sa_analyse_assert(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_assert");
}

// sema_static_analysis.c:250 (static)
fn void sa_analyse_if(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_if");
}

// sema_static_analysis.c:270 (static)
fn void sa_analyse_for(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_for");
}

// sema_static_analysis.c:274 (static)
fn void sa_analyse_switch(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_switch");
}

// sema_static_analysis.c:278 (static)
fn void sa_analyse_nextcase(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_nextcase");
}

// sema_static_analysis.c:282 (static)
fn void sa_analyse_break_continue(SAContext* c, Ast* stmt)
{
	unreachable("sema stub: sa_analyse_break_continue");
}

// sema_static_analysis.c:287 (static)
fn void sa_assign_slot(SAContext* c, Expr* lhs, SANullability value)
{
	unreachable("sema stub: sa_assign_slot");
}

// sema_static_analysis.c:294 (static)
fn void sa_set_slot_nullability(SAContext* c, SASlotId slot, SANullability nullability)
{
	unreachable("sema stub: sa_set_slot_nullability");
}

// sema_static_analysis.c:316 (static)
fn SASlotId sa_find_slot(SAContext* c, Decl* decl)
{
	unreachable("sema stub: sa_find_slot");
}

// sema_static_analysis.c:326 (static)
fn SASlotId sa_allocate_slot(SAContext* c, Decl* decl)
{
	unreachable("sema stub: sa_allocate_slot");
}

// sema_static_analysis.c:341 (static)
fn SAState sa_state_join(SAState a, SAState b)
{
	unreachable("sema stub: sa_state_join");
}

// sema_static_analysis.c:346 (static)
fn SANullability sa_analyse_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_expr");
}

// sema_static_analysis.c:443 (static)
fn SANullability sa_analyse_const_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_const_expr");
}

// sema_static_analysis.c:457 (static)
fn SANullability sa_analyse_binary_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_binary_expr");
}

// sema_static_analysis.c:491 (static)
fn SANullability sa_analyse_call_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_call_expr");
}

// sema_static_analysis.c:523 (static)
fn SANullability sa_analyse_ident_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_ident_expr");
}

// sema_static_analysis.c:532 (static)
fn SANullability sa_analyse_expr_list(SAContext* c, Expr*[] exprs)
{
	unreachable("sema stub: sa_analyse_expr_list");
}

// sema_static_analysis.c:539 (static)
fn SANullability sa_analyse_unary_expr(SAContext* c, Expr* expr)
{
	unreachable("sema stub: sa_analyse_unary_expr");
}

// sema_static_analysis.c:573 (static)
fn Expr* sa_flatten_expr(Expr* expr)
{
	unreachable("sema stub: sa_flatten_expr");
}

// sema_static_analysis.c:579 (static)
fn bool sa_expr_is_null_const(Expr* expr)
{
	unreachable("sema stub: sa_expr_is_null_const");
}

// sema_static_analysis.c:585 (static)
fn bool sa_expr_is_simple_recursive(Expr* expr, int* budget)
{
	unreachable("sema stub: sa_expr_is_simple_recursive");
}

// sema_static_analysis.c:628 (static)
fn bool sa_expr_is_simple(Expr* expr)
{
	unreachable("sema stub: sa_expr_is_simple");
}

// sema_static_analysis.c:634 (static)
fn void sa_narrow(SAContext* c, Expr* expr, bool truth)
{
	unreachable("sema stub: sa_narrow");
}

// sema_static_analysis.c:701 (static)
fn void sa_narrow_nullable(SAContext* c, Expr* expr, SANullability nullability)
{
	unreachable("sema stub: sa_narrow_nullable");
}
