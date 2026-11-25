// Sema contract stubs for c3c src/compiler/sema_stmts.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_stmts.c:56
fn bool sema_scope_check_locals(SemaContext* context, DynamicScope old_scope)
{
	unreachable("sema stub: sema_scope_check_locals");
}

// sema_stmts.c:81 (static)
fn bool sema_analyse_asm_label(SemaContext* context, AsmInlineBlock* block, Ast* label)
{
	unreachable("sema stub: sema_analyse_asm_label");
}

// sema_stmts.c:97 (static)
fn bool sema_analyse_asm_stmt(SemaContext* context, Ast* stmt)
{
	unreachable("sema stub: sema_analyse_asm_stmt");
}

// sema_stmts.c:129 (static)
fn bool sema_analyse_assert_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_assert_stmt");
}

// sema_stmts.c:229 (static)
fn bool sema_analyse_break_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_break_stmt");
}

// sema_stmts.c:275 (static)
fn bool sema_analyse_compound_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_compound_stmt");
}

// sema_stmts.c:293 (static)
fn bool sema_analyse_ct_compound_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_compound_stmt");
}

// sema_stmts.c:314 (static)
fn bool sema_analyse_continue_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_continue_stmt");
}

// sema_stmts.c:352 (static)
fn Expr* sema_dive_into_expression(Expr* expr)
{
	unreachable("sema stub: sema_dive_into_expression");
}

// sema_stmts.c:383 (static)
fn bool sema_catch_in_cond(Expr* cond)
{
	unreachable("sema stub: sema_catch_in_cond");
}

// sema_stmts.c:398 (static)
fn void sema_unwrappable_from_catch_in_else(SemaContext* c, Expr* cond)
{
	unreachable("sema stub: sema_unwrappable_from_catch_in_else");
}

// sema_stmts.c:438 (static)
fn PanicFunction contract_panic_function(Expr* contract, bool is_ensure)
{
	unreachable("sema stub: contract_panic_function");
}

// sema_stmts.c:444
fn String contract_to_message(Expr* contract, bool is_ensure)
{
	unreachable("sema stub: contract_to_message");
}

// sema_stmts.c:452 (static)
fn bool assert_create_from_contract(SemaContext* context, Expr* directive, bool is_ensure, AstId** asserts, SourceLocId evaluation_location, SourceLocId* arg_loc_map)
{
	unreachable("sema stub: assert_create_from_contract");
}

// sema_stmts.c:493 (static)
fn bool sema_defer_has_try_or_catch(AstId defer_top, AstId defer_bottom, bool* has_catch_ref)
{
	unreachable("sema stub: sema_defer_has_try_or_catch");
}

// sema_stmts.c:515 (static)
fn void sema_inline_return_defers(SemaContext* context, Ast* stmt, AstId defer_bottom)
{
	unreachable("sema stub: sema_inline_return_defers");
}

// sema_stmts.c:537 (static)
fn bool sema_check_return_matches_opt_returns(SemaContext* context, Expr* ret_expr)
{
	unreachable("sema stub: sema_check_return_matches_opt_returns");
}

// sema_stmts.c:562 (static)
fn bool sema_analyse_macro_constant_ensures(SemaContext* context, Expr* ret_expr)
{
	unreachable("sema stub: sema_analyse_macro_constant_ensures");
}

// sema_stmts.c:623 (static)
fn bool sema_analyse_block_exit_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_block_exit_stmt");
}

// sema_stmts.c:672 (static)
fn bool sema_check_not_stack_variable_escape(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_check_not_stack_variable_escape");
}

// sema_stmts.c:751 (static)
fn bool sema_analyse_return_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_return_stmt");
}

// sema_stmts.c:830 (static)
fn bool sema_expr_valid_try_expression(Expr* expr)
{
	unreachable("sema stub: sema_expr_valid_try_expression");
}

// sema_stmts.c:925 (static)
fn bool sema_analyse_try_unwrap(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_try_unwrap");
}

// sema_stmts.c:1031 (static)
fn bool sema_analyse_try_unwrap_chain(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	unreachable("sema stub: sema_analyse_try_unwrap_chain");
}

// sema_stmts.c:1051 (static)
fn bool sema_analyse_catch_unwrap(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_catch_unwrap");
}

// sema_stmts.c:1099 (static)
fn void sema_remove_unwraps_from_try(SemaContext* c, Expr* cond)
{
	unreachable("sema stub: sema_remove_unwraps_from_try");
}

// sema_stmts.c:1119 (static)
fn bool sema_analyse_last_cond(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	unreachable("sema stub: sema_analyse_last_cond");
}

// sema_stmts.c:1153 (static)
fn bool sema_analyse_cond_list(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	unreachable("sema stub: sema_analyse_cond_list");
}

// sema_stmts.c:1196 (static)
fn bool sema_analyse_cond(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	unreachable("sema stub: sema_analyse_cond");
}

// sema_stmts.c:1283 (static)
fn bool sema_analyse_ct_type_assign_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_type_assign_stmt");
}

// sema_stmts.c:1302 (static)
fn bool sema_analyse_decls_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_decls_stmt");
}

// sema_stmts.c:1323 (static)
fn bool sema_analyse_declare_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_declare_stmt");
}

// sema_stmts.c:1337 (static)
fn bool sema_analyse_expr_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_expr_stmt");
}

// sema_stmts.c:1350 (static)
fn bool sema_analyse_defer_stmt_body(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_defer_stmt_body");
}

// sema_stmts.c:1392 (static)
fn bool sema_analyse_defer_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_defer_stmt");
}

// sema_stmts.c:1403 (static)
fn bool sema_analyse_for_cond(SemaContext* context, ExprId* cond_ref, bool* infinite)
{
	unreachable("sema stub: sema_analyse_for_cond");
}

// sema_stmts.c:1438 (static)
fn bool sema_analyse_for_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_for_stmt");
}

// sema_stmts.c:1534 (static)
fn bool sema_foreach_param_contract(SemaContext* context, Expr* enumerator, Decl* var_, bool value_by_ref)
{
	unreachable("sema stub: sema_foreach_param_contract");
}

// sema_stmts.c:1559 (static)
fn bool sema_analyse_foreach_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_foreach_stmt");
}

// sema_stmts.c:2023 (static)
fn bool sema_check_for_dead_code(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_check_for_dead_code");
}

// sema_stmts.c:2035 (static)
fn bool sema_analyse_if_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_if_stmt");
}

// sema_stmts.c:2164 (static)
fn bool sema_analyse_asm_string_stmt(SemaContext* context, Ast* stmt)
{
	unreachable("sema stub: sema_analyse_asm_string_stmt");
}

// sema_stmts.c:2182 (static)
fn Decl* sema_analyse_label(SemaContext* context, Ast* stmt)
{
	unreachable("sema stub: sema_analyse_label");
}

// sema_stmts.c:2243 (static)
fn bool context_labels_exist_in_scope(SemaContext* context)
{
	unreachable("sema stub: context_labels_exist_in_scope");
}

// sema_stmts.c:2254 (static)
fn bool sema_analyse_nextcase_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_nextcase_stmt");
}

// sema_stmts.c:2380 (static)
fn bool sema_analyse_then_overwrite(SemaContext* context, Ast* statement, AstId replacement)
{
	unreachable("sema stub: sema_analyse_then_overwrite");
}

// sema_stmts.c:2405 (static)
fn bool sema_analyse_ct_if_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_if_stmt");
}

// sema_stmts.c:2449 (static)
fn bool sema_analyse_compound_statement_no_scope(SemaContext* context, Ast* compound_statement)
{
	unreachable("sema stub: sema_analyse_compound_statement_no_scope");
}

// sema_stmts.c:2475 (static)
fn bool sema_check_type_case(SemaContext* context, Ast* case_stmt, Ast*[] cases, int index)
{
	unreachable("sema stub: sema_check_type_case");
}

// sema_stmts.c:2503 (static)
fn bool sema_check_duplicate_case(SemaContext* context, Ast* case_stmt, Ast*[] cases, int index, ExprConst* const_expr, ExprConst* to_const_expr)
{
	unreachable("sema stub: sema_check_duplicate_case");
}

// sema_stmts.c:2528 (static)
fn bool sema_check_value_case(SemaContext* context, Type* switch_type, Ast* case_stmt, Ast*[] cases, int index, bool* if_chained, bool* max_ranged, long* actual_cases_ref, Int* low, Int* high)
{
	unreachable("sema stub: sema_check_value_case");
}

// sema_stmts.c:2612 (static)
fn String create_missing_enums_in_switch_error(Ast*[] cases, int found_count, Decl*[] enums)
{
	unreachable("sema stub: create_missing_enums_in_switch_error");
}

// sema_stmts.c:2660 (static)
fn bool sema_analyse_switch_body(SemaContext* context, Ast* statement, SourceLocId expr_loc, CanonicalType* switch_type, Ast*[] cases)
{
	unreachable("sema stub: sema_analyse_switch_body");
}

// sema_stmts.c:2791 (static)
fn bool sema_analyse_ct_switch_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_switch_stmt");
}

// sema_stmts.c:2960 (static)
fn bool sema_analyse_ct_foreach_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_foreach_stmt");
}

// sema_stmts.c:3099 (static)
fn bool sema_analyse_switch_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_switch_stmt");
}

// sema_stmts.c:3139
fn bool sema_analyse_ct_assert_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_assert_stmt");
}

// sema_stmts.c:3175
fn bool sema_analyse_ct_expand_stmt(SemaContext* context, Ast* stmt)
{
	unreachable("sema stub: sema_analyse_ct_expand_stmt");
}

// sema_stmts.c:3191
fn bool sema_analyse_ct_echo_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_echo_stmt");
}

// sema_stmts.c:3256 (static)
fn bool sema_analyse_ct_for_stmt(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_ct_for_stmt");
}

// sema_stmts.c:3342 (static)
fn bool sema_analyse_statement_inner(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_statement_inner");
}

// sema_stmts.c:3413
fn bool sema_analyse_statement(SemaContext* context, Ast* statement)
{
	unreachable("sema stub: sema_analyse_statement");
}

// sema_stmts.c:3440 (static)
fn bool sema_analyse_ensure(SemaContext* context, Expr* directive)
{
	unreachable("sema stub: sema_analyse_ensure");
}

// sema_stmts.c:3455 (static)
fn bool sema_analyse_call_optional_returns(SemaContext* context, Decl* contract)
{
	unreachable("sema stub: sema_analyse_call_optional_returns");
}

// sema_stmts.c:3468
fn void sema_append_contract_asserts(AstId assert_first, Ast* compound_stmt)
{
	unreachable("sema stub: sema_append_contract_asserts");
}

// sema_stmts.c:3477
fn bool sema_analyse_contracts(SemaContext* context, Decl* contract, Expr*[] requires, Expr*[] ensures, AstId** asserts, SourceLocId call_loc, bool* has_ensures, SourceLocId* arg_loc_map)
{
	unreachable("sema stub: sema_analyse_contracts");
}

// sema_stmts.c:3498
fn bool sema_analyse_function_body(SemaContext* context, Decl* func, int macro_depth_start)
{
	unreachable("sema stub: sema_analyse_function_body");
}
