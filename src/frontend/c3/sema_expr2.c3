// Sema contract stubs for the second half of c3c src/compiler/sema_expr.c
// (from line 7050; revision 54bab366a). Same module and conventions as
// sema_expr.c3, split so two files can be ported independently.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_expr.c:7050
fn bool sema_expr_rewrite_insert_deref(SemaContext* context, Expr* original)
{
	unreachable("sema stub: sema_expr_rewrite_insert_deref");
}

// sema_expr.c:7082
fn bool sema_check_swizzle_string(SemaContext* context, Expr* expr, String kw, int len, int vec_len, bool* is_overlapping_ref, int* index_ref)
{
	unreachable("sema stub: sema_check_swizzle_string");
}

// sema_expr.c:7120 (static)
fn bool sema_expr_analyse_swizzle(SemaContext* context, Expr* expr, Expr* parent, Type* flat_type, String kw, int len)
{
	unreachable("sema stub: sema_expr_analyse_swizzle");
}

// sema_expr.c:7163 (static)
fn bool sema_analyse_maybe_dead_expr(SemaContext* context, Expr* expr, bool is_dead, Type* infer_type)
{
	unreachable("sema stub: sema_analyse_maybe_dead_expr");
}

// sema_expr.c:7174
fn bool sema_kw_is_swizzle(String kw, int len)
{
	unreachable("sema stub: sema_kw_is_swizzle");
}

// sema_expr.c:7183 (static)
fn void sema_expr_flatten_const_ident(Expr* expr)
{
	unreachable("sema stub: sema_expr_flatten_const_ident");
}

// sema_expr.c:7216 (static)
fn bool sema_expr_analyse_type_property(SemaContext* context, Expr* expr, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_type_property");
}

// sema_expr.c:7233 (static)
fn bool sema_kw_is_non_runtime_type_property(String kw)
{
	unreachable("sema stub: sema_kw_is_non_runtime_type_property");
}

// sema_expr.c:7240 (static)
fn bool sema_expr_analyse_access(SemaContext* context, Expr* expr, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_access");
}

// sema_expr.c:7619 (static)
fn Expr*[] sema_prepare_splat_insert(Expr*[] exprs, int added, int insert_point)
{
	unreachable("sema stub: sema_prepare_splat_insert");
}

// sema_expr.c:7639 (static)
fn Expr*[] sema_vasplat_insert(SemaContext* context, Expr*[] init_expressions, Expr* expr, int insert_point)
{
	unreachable("sema stub: sema_vasplat_insert");
}

// sema_expr.c:7748
fn bool sema_expand_vasplat_exprs(SemaContext* context, Expr*[]* exprs_ptr, Decl*[]* macro_va_decl_ref)
{
	unreachable("sema stub: sema_expand_vasplat_exprs");
}

// sema_expr.c:7816 (static)
fn bool sema_expr_analyse_expr_list(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_expr_list");
}

// sema_expr.c:7831 (static)
fn bool sema_expr_analyse_cast(SemaContext* context, Expr* expr, bool* invalid_cast_ref)
{
	unreachable("sema stub: sema_expr_analyse_cast");
}

// sema_expr.c:7875 (static)
fn bool sema_expr_analyse_slice_assign(SemaContext* context, Expr* expr, Type* left_type, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_slice_assign");
}

// sema_expr.c:7963
fn bool sema_expr_analyse_assign_right_side(SemaContext* context, Expr* expr, Type* left_type, Expr* right, bool is_unwrapped_var, bool is_declaration, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_assign_right_side");
}

// sema_expr.c:8003 (static)
fn bool sema_expr_analyse_ct_identifier_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ct_identifier_assign");
}

// sema_expr.c:8023 (static)
fn bool sema_expr_analyse_ct_subscript_rhs(SemaContext* context, Decl* ct_var, Expr* right)
{
	unreachable("sema stub: sema_expr_analyse_ct_subscript_rhs");
}

// sema_expr.c:8040 (static)
fn void sema_expr_analyse_ct_subscript_set_value(Expr* left, Decl* ct_var, Expr* right)
{
	unreachable("sema stub: sema_expr_analyse_ct_subscript_set_value");
}

// sema_expr.c:8082 (static)
fn bool sema_expr_analyse_ct_subscript_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right)
{
	unreachable("sema stub: sema_expr_analyse_ct_subscript_assign");
}

// sema_expr.c:8092 (static)
fn bool sema_expr_fold_hash(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_fold_hash");
}

// sema_expr.c:8120 (static)
fn bool sema_expr_analyse_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_assign");
}

// sema_expr.c:8188 (static)
fn bool sema_binary_analyse_ct_op_assign(SemaContext* context, Expr* expr, Expr* left)
{
	unreachable("sema stub: sema_binary_analyse_ct_op_assign");
}

// sema_expr.c:8215 (static)
fn bool sema_binary_analyse_ct_subscript_op_assign(SemaContext* context, Expr* expr, Expr* left)
{
	unreachable("sema stub: sema_binary_analyse_ct_subscript_op_assign");
}

// sema_expr.c:8233 (static)
fn BoolErr sema_insert_overload_in_op_assign_or_error(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp operator, Type* lhs_type)
{
	unreachable("sema stub: sema_insert_overload_in_op_assign_or_error");
}

// sema_expr.c:8259 (static)
fn bool sema_rewrite_op_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp new_op)
{
	unreachable("sema stub: sema_rewrite_op_assign");
}

// sema_expr.c:8366 (static)
fn bool sema_expr_analyse_op_assign_enum_ptr(SemaContext* context, Expr* rhs, Type* flat, Type* base, Type* flat_rhs, BinaryOp op, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_op_assign_enum_ptr");
}

// sema_expr.c:8406 (static)
fn bool sema_expr_analyse_op_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp operator, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_op_assign");
}

// sema_expr.c:8625 (static)
fn bool sema_replace_with_overload(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* left_type, OperatorOverload* operator_overload_ref)
{
	unreachable("sema stub: sema_replace_with_overload");
}

// sema_expr.c:8639 (static)
fn bool sema_check_untyped_promotion(SemaContext* context, Expr* expr, bool is_left, CanonicalType* max_flat, Type* max)
{
	unreachable("sema stub: sema_check_untyped_promotion");
}

// sema_expr.c:8655 (static)
fn bool sema_binary_arithmetic_promotion(SemaContext* context, Expr* left, Expr* right, Type* left_type, Type* right_type, Expr* parent, String error_message, bool allow_bool_vec, OperatorOverload* operator_overload_ref, bool* failed_ref)
{
	unreachable("sema stub: sema_binary_arithmetic_promotion");
}

// sema_expr.c:8707 (static)
fn void sema_binary_unify_voidptr(Expr* left, Expr* right, Type** left_type_ref, Type** right_type_ref)
{
	unreachable("sema stub: sema_binary_unify_voidptr");
}

// sema_expr.c:8722 (static)
fn Type* defer_iptr_cast(Expr* maybe_pointer)
{
	unreachable("sema stub: defer_iptr_cast");
}

// sema_expr.c:8737 (static)
fn bool sema_expr_analyse_ptr_sub(SemaContext* context, Expr* expr, Expr* left, Expr* right, CanonicalType* left_type, Type* cast_to_iptr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ptr_sub");
}

// sema_expr.c:8838 (static)
fn bool sema_expr_analyse_sub(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_sub");
}

// sema_expr.c:8892 (static)
fn bool sema_expr_analyse_ptr_add(SemaContext* context, Expr* expr, Expr* left, Expr* right, CanonicalType* left_type, CanonicalType* right_type, Type* cast_to_iptr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ptr_add");
}

// sema_expr.c:8953 (static)
fn bool sema_expr_analyse_add(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_add");
}

// sema_expr.c:9004 (static)
fn bool sema_expr_analyse_mult(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_mult");
}

// sema_expr.c:9036 (static)
fn bool sema_convert_denominator_to_unsigned_if_needed(SemaContext* context, Expr* left, Expr* right)
{
	unreachable("sema stub: sema_convert_denominator_to_unsigned_if_needed");
}

// sema_expr.c:9051 (static)
fn bool sema_expr_analyse_div(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_div");
}

// sema_expr.c:9114 (static)
fn bool sema_expr_analyse_mod(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_mod");
}

// sema_expr.c:9173 (static)
fn bool sema_expr_analyse_bit(SemaContext* context, Expr* expr, Expr* left, Expr* right, OperatorOverload overload, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_bit");
}

// sema_expr.c:9244 (static)
fn bool sema_expr_check_shift_rhs(SemaContext* context, Expr* expr, Expr* left, Type* left_type_flat, Expr* right, Type* right_type_flat, bool* failed_ref, bool is_assign)
{
	unreachable("sema stub: sema_expr_check_shift_rhs");
}

// sema_expr.c:9319 (static)
fn bool sema_expr_analyse_shift(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_shift");
}

// sema_expr.c:9377 (static)
fn bool sema_expr_analyse_and_or(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_and_or");
}

// sema_expr.c:9399 (static)
fn bool sema_binary_is_unsigned_always_same_comparison(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* lhs_type, Type* rhs_type)
{
	unreachable("sema stub: sema_binary_is_unsigned_always_same_comparison");
}

// sema_expr.c:9458 (static)
fn BoolErr sema_type_has_overload(SemaContext* context, CanonicalType* type, OperatorOverload overload)
{
	unreachable("sema stub: sema_type_has_overload");
}

// sema_expr.c:9481
fn BoolErr sema_type_has_compare_overload(SemaContext* context, CanonicalType* type)
{
	unreachable("sema stub: sema_type_has_compare_overload");
}

// sema_expr.c:9488
fn BoolErr sema_type_has_equality_overload(SemaContext* context, Type* type)
{
	unreachable("sema stub: sema_type_has_equality_overload");
}

// sema_expr.c:9493
fn BoolErr sema_type_can_check_equality_with_overload(SemaContext* context, Type* type)
{
	unreachable("sema stub: sema_type_can_check_equality_with_overload");
}

// sema_expr.c:9544
fn BoolErr sema_type_can_order_with_overload(SemaContext* context, Type* type)
{
	unreachable("sema stub: sema_type_can_order_with_overload");
}

// sema_expr.c:9595 (static)
fn Decl* ast_append_generated_local(Ast** ast_current_ref, Expr* init)
{
	unreachable("sema stub: ast_append_generated_local");
}

// sema_expr.c:9607 (static)
fn bool sema_rewrite_slice_comparison(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* max)
{
	unreachable("sema stub: sema_rewrite_slice_comparison");
}

// sema_expr.c:9749 (static)
fn bool sema_expr_analyse_comp(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_comp");
}

// sema_expr.c:9920 (static)
fn bool sema_expr_analyse_deref(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_deref");
}

// sema_expr.c:9989 (static)
fn String sema_addr_may_take_of_var(Expr* expr, Decl* decl)
{
	unreachable("sema stub: sema_addr_may_take_of_var");
}

// sema_expr.c:10030 (static)
fn String sema_addr_may_take_of_ident(Expr* inner)
{
	unreachable("sema stub: sema_addr_may_take_of_ident");
}

// sema_expr.c:10064 (static)
fn String sema_addr_check_may_take(Expr* inner)
{
	unreachable("sema stub: sema_addr_check_may_take");
}

// sema_expr.c:10107 (static)
fn bool sema_expr_is_temporary(Expr* expr)
{
	unreachable("sema stub: sema_expr_is_temporary");
}

// sema_expr.c:10141 (static)
fn bool sema_expr_analyse_addr(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_addr");
}

// sema_expr.c:10240 (static)
fn bool sema_expr_analyse_neg_plus(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_neg_plus");
}

// sema_expr.c:10320 (static)
fn bool sema_expr_analyse_bit_not(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_bit_not");
}

// sema_expr.c:10380 (static)
fn bool sema_expr_analyse_not(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_not");
}

// sema_expr.c:10440 (static)
fn void sema_expr_inc_dec_const_enum(bool dec, Expr* value)
{
	unreachable("sema stub: sema_expr_inc_dec_const_enum");
}

// sema_expr.c:10465 (static)
fn void sema_expr_inc_dec_const_int(bool dec, Expr* value)
{
	unreachable("sema stub: sema_expr_inc_dec_const_int");
}

// sema_expr.c:10477 (static)
fn bool sema_expr_analyse_ct_subscript_incdec(SemaContext* context, Expr* expr, Expr* inner)
{
	unreachable("sema stub: sema_expr_analyse_ct_subscript_incdec");
}

// sema_expr.c:10509 (static)
fn bool sema_expr_analyse_ct_incdec(SemaContext* context, Expr* expr, Expr* inner)
{
	unreachable("sema stub: sema_expr_analyse_ct_incdec");
}

// sema_expr.c:10538 (static)
fn bool sema_analyse_assign_mutate_overloaded_subscript(SemaContext* context, Expr* main, Expr* subscript_expr, Type* type)
{
	unreachable("sema stub: sema_analyse_assign_mutate_overloaded_subscript");
}

// sema_expr.c:10637 (static)
fn bool sema_expr_analyse_incdec(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_incdec");
}

// sema_expr.c:10683 (static)
fn bool sema_expr_analyse_taddr(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_taddr");
}

// sema_expr.c:10738 (static)
fn bool expr_is_ungrouped_binary(Expr* expr)
{
	unreachable("sema stub: expr_is_ungrouped_binary");
}

// sema_expr.c:10743 (static)
fn bool sema_binary_check_unclear_op_precedence(Expr* left_side, Expr* main_expr, Expr* right_side)
{
	unreachable("sema stub: sema_binary_check_unclear_op_precedence");
}

// sema_expr.c:10789 (static)
fn bool expr_is_ungrouped_ternary(Expr* expr)
{
	unreachable("sema stub: expr_is_ungrouped_ternary");
}

// sema_expr.c:10794 (static)
fn bool sema_expr_analyse_or_error(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* infer_type, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_or_error");
}

// sema_expr.c:10871 (static)
fn bool sema_expr_analyse_ct_and_or(SemaContext* context, Expr* expr, Expr* left, Expr* right)
{
	unreachable("sema stub: sema_expr_analyse_ct_and_or");
}

// sema_expr.c:10893 (static)
fn bool sema_expr_analyse_ct_concat_assign(SemaContext* context, Expr* concat_expr, Expr* left, Expr* right, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ct_concat_assign");
}

// sema_expr.c:10911 (static)
fn bool sema_expr_analyse_binary(SemaContext* context, Type* infer_type, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_binary");
}

// sema_expr.c:11014 (static)
fn bool sema_expr_analyse_unary(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_unary");
}

// sema_expr.c:11043 (static)
fn bool sema_expr_analyse_rethrow(SemaContext* context, Expr* expr, Type* to)
{
	unreachable("sema stub: sema_expr_analyse_rethrow");
}

// sema_expr.c:11119 (static)
fn bool sema_expr_analyse_force_unwrap(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_force_unwrap");
}

// sema_expr.c:11135 (static)
fn bool sema_expr_analyse_typeid(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_typeid");
}

// sema_expr.c:11154 (static)
fn bool sema_expr_analyse_optional(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_optional");
}

// sema_expr.c:11188 (static)
fn bool sema_expr_analyse_compiler_const(SemaContext* context, Expr* expr, bool report_missing)
{
	unreachable("sema stub: sema_expr_analyse_compiler_const");
}

// sema_expr.c:11369 (static)
fn bool sema_expr_rewrite_to_type_nameof(SemaContext* context, Expr* expr, Type* type, int level)
{
	unreachable("sema stub: sema_expr_rewrite_to_type_nameof");
}

// sema_expr.c:11411 (static)
fn Type* sema_expr_check_type_exists(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: sema_expr_check_type_exists");
}

// sema_expr.c:11560 (static)
fn bool sema_may_reuse_lambda(Decl* lambda, Type*[] types)
{
	unreachable("sema stub: sema_may_reuse_lambda");
}

// sema_expr.c:11573 (static)
fn Type* sema_evaluate_type_copy(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: sema_evaluate_type_copy");
}

// sema_expr.c:11581 (static)
fn bool lambda_parameter_match(Decl*[] ct_lambda_params, Decl* candidate)
{
	unreachable("sema stub: lambda_parameter_match");
}

// sema_expr.c:11621 (static)
fn Decl* sema_find_cached_lambda(SemaContext* context, Type* func_type, Decl* original, Decl*[] ct_lambda_parameters)
{
	unreachable("sema stub: sema_find_cached_lambda");
}

// sema_expr.c:11667 (static)
fn bool sema_expr_analyse_embed(SemaContext* context, Expr* expr, bool allow_fail)
{
	unreachable("sema stub: sema_expr_analyse_embed");
}

// sema_expr.c:11736 (static)
fn bool sema_expr_analyse_generic_ident(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_generic_ident");
}

// sema_expr.c:11782 (static)
fn bool sema_expr_analyse_lambda(SemaContext* context, Type* target_type, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_lambda");
}

// sema_expr.c:11949 (static)
fn bool sema_expr_analyse_ct_feature(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_ct_feature");
}

// sema_expr.c:11982 (static)
fn bool sema_expr_analyse_lenof(SemaContext* context, Expr* expr, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_lenof");
}

// sema_expr.c:12031 (static)
fn bool sema_expr_analyse_ct_defined(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_ct_defined");
}

// sema_expr.c:12338 (static)
fn bool sema_expr_analyse_vaarg(SemaContext* context, Type* infer_type, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_vaarg");
}

// sema_expr.c:12353 (static)
fn bool sema_expr_analyse_vacount(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_vacount");
}

// sema_expr.c:12364 (static)
fn bool sema_expr_analyse_maybe_deref(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_maybe_deref");
}

// sema_expr.c:12378 (static)
fn bool sema_expr_analyse_iota_decl(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_iota_decl");
}

// sema_expr.c:12401 (static)
fn bool sema_expr_analyse_ct_stringify(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_ct_stringify");
}

// sema_expr.c:12440 (static)
fn bool sema_expr_resolve_ct_eval(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_resolve_ct_eval");
}

// sema_expr.c:12448 (static)
fn bool sema_expr_analyse_ct_reflect(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_ct_reflect");
}

// sema_expr.c:12463 (static)
fn BuiltinFunction builtin_by_name(String name)
{
	unreachable("sema stub: builtin_by_name");
}

// sema_expr.c:12473 (static)
fn bool sema_expr_analyse_retval(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_retval");
}

// sema_expr.c:12502 (static)
fn bool sema_expr_analyse_builtin(SemaContext* context, Expr* expr, bool throw_error)
{
	unreachable("sema stub: sema_expr_analyse_builtin");
}

// sema_expr.c:12521 (static)
fn bool sema_expr_analyse_compound_literal(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_compound_literal");
}

// sema_expr.c:12538 (static)
fn bool sema_analyse_expr_dispatch(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_expr_dispatch");
}

// sema_expr.c:12745
fn bool sema_analyse_cond_expr(SemaContext* context, Expr* expr, CondResult* result)
{
	unreachable("sema stub: sema_analyse_cond_expr");
}

// sema_expr.c:12767 (static)
fn bool sema_analyse_expr_rhs_param(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_analyse_expr_rhs_param");
}

// sema_expr.c:12776
fn bool sema_analyse_expr_rhs(SemaContext* context, Type* to, Expr* expr, bool allow_optional, bool* no_match_ref, bool as_binary)
{
	unreachable("sema stub: sema_analyse_expr_rhs");
}

// sema_expr.c:12858 (static)
fn bool sema_cast_ct_ident_rvalue(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_cast_ct_ident_rvalue");
}

// sema_expr.c:12872 (static)
fn bool sema_cast_rvalue(SemaContext* context, Expr* expr, bool mutate)
{
	unreachable("sema stub: sema_cast_rvalue");
}

// sema_expr.c:12960
fn bool sema_analyse_ct_expr(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_ct_expr");
}

// sema_expr.c:12979
fn bool sema_analyse_expr(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_expr");
}

// sema_expr.c:12984 (static)
fn bool sema_analyse_expr_lvalue_dispatch(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_analyse_expr_lvalue_dispatch");
}

// sema_expr.c:13180
fn bool sema_analyse_expr_lvalue(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_analyse_expr_lvalue");
}

// sema_expr.c:13186
fn bool sema_expr_check_discard(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_check_discard");
}

// sema_expr.c:13260
fn bool sema_analyse_expr_rvalue(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_expr_rvalue");
}

// sema_expr.c:13265
fn bool sema_cast_const(Expr* expr)
{
	unreachable("sema stub: sema_cast_const");
}

// sema_expr.c:13324
fn bool sema_analyse_inferred_expr(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_analyse_inferred_expr");
}

// sema_expr.c:13432 (static)
fn TokenType sema_string_ident_token(String string, ArrayIndex len, String* interned_ref)
{
	unreachable("sema stub: sema_string_ident_token");
}

// sema_expr.c:13484
fn TokenType sema_splitpathref(String string, ArrayIndex len, ModulePath** path_ref, String* ident_ref)
{
	unreachable("sema stub: sema_splitpathref");
}

// sema_expr.c:13520
fn bool sema_insert_method_call(SemaContext* context, Expr* method_call, Decl* method_decl, Expr* parent, Expr*[] arguments, bool reverse_overload)
{
	unreachable("sema stub: sema_insert_method_call");
}

// sema_expr.c:13579 (static)
fn bool sema_insert_binary_overload(SemaContext* context, Expr* expr, Decl* overload, Expr* lhs, Expr* rhs, bool reverse)
{
	unreachable("sema stub: sema_insert_binary_overload");
}

// sema_expr.c:13587
fn bool sema_bit_assignment_check(SemaContext* context, Expr* right, Decl* member, bool* failed_ref)
{
	unreachable("sema stub: sema_bit_assignment_check");
}
