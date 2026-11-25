// Sema contract stubs for c3c src/compiler/sema_expr.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

const int MEMBER_IS_PARAM = -1;

struct CalledDeclContext
{
	bool macro_decl;
	Decl* definition;
	SourceLocId call_location;
	String name;
	String block_parameter;
	Decl*[] params;
	Expr* struct_var;
	Signature* signature;
	Decl*[] macro_va_decls;
	Decl*[] evaluations;
}

struct ContextSwitchState
{
	bool in_no_eval;
	InliningSpan* old_inlining;
	Decl* generic_instance;
}

enum SplatResult : char
{
	ZERO,
	ONE,
	NONE,
}

<* c3c `struct SubcriptLookup` / `SubscriptLookup`. *>
struct SubscriptLookup
{
	Expr* subscripted;
	Type* subscripted_type; // Might be flat version of subscripted's type.
	OperatorOverload operator_overload;
	Decl* overload_method;
	Type* subscript_value_type;
	bool is_ref;
	bool try_get_ref;
	bool ref_succeded;
}

enum RangeEnv : char
{
	ARRAY,
	SLICE,
	PTR,
	FLEXIBLE,
}

// sema_expr.c:218 (static)
fn ContextSwitchState context_switch_state_push(SemaContext* context, SemaContext* new_context)
{
	unreachable("sema stub: context_switch_state_push");
}

// sema_expr.c:227 (static)
fn void context_switch_stat_pop(SemaContext* swapped, ContextSwitchState state)
{
	unreachable("sema stub: context_switch_stat_pop");
}

// sema_expr.c:234
fn bool sema_check_array_index(SemaContext* context, Expr* index, bool is_len)
{
	unreachable("sema stub: sema_check_array_index");
}

// sema_expr.c:243
fn Expr* sema_enter_inline_member(Expr* parent, CanonicalType* type)
{
	unreachable("sema stub: sema_enter_inline_member");
}

// sema_expr.c:284
fn Expr* sema_expr_analyse_ct_arg_index(SemaContext* context, SubscriptIndex* index, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_ct_arg_index");
}

// sema_expr.c:320
fn Expr* sema_resolve_string_ident(SemaContext* context, Expr* inner, bool report_missing)
{
	unreachable("sema stub: sema_resolve_string_ident");
}

// sema_expr.c:364
fn Expr* sema_ct_eval_expr(SemaContext* context, CtEvalKind eval_kind, Expr* inner, bool report_missing, bool* was_reflect)
{
	unreachable("sema stub: sema_ct_eval_expr");
}

// sema_expr.c:388
fn void expr_set_to_ref(Expr* expr)
{
	unreachable("sema stub: expr_set_to_ref");
}

// sema_expr.c:409
fn Expr* expr_access_inline_member(Expr* parent, Decl* parent_decl)
{
	unreachable("sema stub: expr_access_inline_member");
}

// sema_expr.c:419 (static)
fn bool expr_const_foldable_unary(Expr* expr, UnaryOp unary)
{
	unreachable("sema stub: expr_const_foldable_unary");
}

// sema_expr.c:444 (static)
fn bool expr_both_const_foldable(Expr* left, Expr* right, BinaryOp op)
{
	unreachable("sema stub: expr_both_const_foldable");
}

// sema_expr.c:516 (static)
fn bool expr_both_any_integer_or_integer_bool_vector(Expr* left, Expr* right)
{
	unreachable("sema stub: expr_both_any_integer_or_integer_bool_vector");
}

// sema_expr.c:527 (static)
fn void expr_binary_unify_failability(Expr* expr, Expr* left, Expr* right)
{
	unreachable("sema stub: expr_binary_unify_failability");
}

// sema_expr.c:532
fn CondResult sema_check_comp_time_bool(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_check_comp_time_bool");
}

// sema_expr.c:543
fn bool sema_expr_analyse_sprintf(SemaContext* context, Expr* expr, Expr* format_string, Expr*[] args, int num_args)
{
	unreachable("sema stub: sema_expr_analyse_sprintf");
}

// sema_expr.c:597 (static)
fn bool expr_is_const_storage(Expr* expr, bool literal_is_const)
{
	unreachable("sema stub: expr_is_const_storage");
}

// sema_expr.c:638 (static)
fn bool expr_refers_to_const(Expr* expr)
{
	unreachable("sema stub: expr_refers_to_const");
}

// sema_expr.c:670 (static)
fn bool sema_binary_is_expr_lvalue(SemaContext* context, Expr* top_expr, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_binary_is_expr_lvalue");
}

// sema_expr.c:861
fn bool expr_may_ref(Expr* expr)
{
	unreachable("sema stub: expr_may_ref");
}

// sema_expr.c:989
fn bool sema_expr_check_assign(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_check_assign");
}

// sema_expr.c:1039
fn void sema_fold_global_init(Expr* init)
{
	unreachable("sema stub: sema_fold_global_init");
}

// sema_expr.c:1047 (static)
fn bool sema_cast_ident_rvalue(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_cast_ident_rvalue");
}

// sema_expr.c:1168 (static)
fn bool sema_expr_analyse_ternary(SemaContext* context, Type* infer_type, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_ternary");
}

// sema_expr.c:1299 (static)
fn bool sema_expr_analyse_enum_constant(SemaContext* context, Expr* expr, String name, Decl* decl)
{
	unreachable("sema stub: sema_expr_analyse_enum_constant");
}

// sema_expr.c:1338 (static)
fn bool sema_identifier_find_possible_inferred(SemaContext* context, Type* to, Expr* expr)
{
	unreachable("sema stub: sema_identifier_find_possible_inferred");
}

// sema_expr.c:1352 (static)
fn bool sema_expr_analyse_identifier(SemaContext* context, Type* to, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_identifier");
}

// sema_expr.c:1517 (static)
fn bool sema_expr_resolve_ct_identifier(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_resolve_ct_identifier");
}

// sema_expr.c:1544 (static)
fn bool sema_expr_analyse_ct_identifier(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_ct_identifier");
}

// sema_expr.c:1551 (static)
fn bool sema_binary_analyse_with_inference(SemaContext* context, Expr* left, Expr* right, BinaryOp op, Type* to)
{
	unreachable("sema stub: sema_binary_analyse_with_inference");
}

// sema_expr.c:1612 (static)
fn bool sema_binary_analyse_subexpr(SemaContext* context, Expr* left, Expr* right)
{
	unreachable("sema stub: sema_binary_analyse_subexpr");
}

// sema_expr.c:1661 (static)
fn bool sema_binary_analyse_arithmetic_subexpr(SemaContext* context, Expr* expr, String error, bool bool_and_bitstruct_is_allowed, OperatorOverload* operator_overload_ref, bool* failed_ref)
{
	unreachable("sema stub: sema_binary_analyse_arithmetic_subexpr");
}

// sema_expr.c:1687 (static)
fn int sema_call_find_index_of_named_parameter(SemaContext* context, Decl*[] func_params, Expr* expr)
{
	unreachable("sema stub: sema_call_find_index_of_named_parameter");
}

// sema_expr.c:1698 (static)
fn bool sema_call_check_invalid_body_arguments(SemaContext* context, Expr* call, CalledDeclContext* callee)
{
	unreachable("sema stub: sema_call_check_invalid_body_arguments");
}

// sema_expr.c:1745 (static)
fn bool sema_analyse_parameter(SemaContext* context, Expr* arg, Decl* param, Decl* definition, bool* optional_ref, bool* no_match_ref, bool macro_, bool is_method_target)
{
	unreachable("sema stub: sema_analyse_parameter");
}

// sema_expr.c:1867 (static)
fn bool sema_set_default_argument(SemaContext* context, CalledDeclContext* callee, Expr* call, Decl* param, bool* no_match_ref, Expr** expr_ref, bool* optional)
{
	unreachable("sema stub: sema_set_default_argument");
}

// sema_expr.c:1933 (static)
fn Expr* sema_splat_analyse_temp(SemaContext* context, Decl* decl, Expr* access, Decl*[]* evaluation_ref)
{
	unreachable("sema stub: sema_splat_analyse_temp");
}

// sema_expr.c:1949 (static)
fn Expr*[] sema_splat_struct_insert(SemaContext* context, Expr*[] args, Expr* arg, Decl* strukt, int index, Decl*[]* evaluation_ref)
{
	unreachable("sema stub: sema_splat_struct_insert");
}

// sema_expr.c:2019 (static)
fn Expr*[] sema_splat_arraylike_insert(SemaContext* context, Expr*[] args, Expr* arg, ArrayIndex len, ArrayIndex index, Decl*[]* macro_va_decl_ref, Decl*[]* evaluation_ref)
{
	unreachable("sema stub: sema_splat_arraylike_insert");
}

// sema_expr.c:2063 (static)
fn ArrayIndex sema_len_from_expr(Expr* expr)
{
	unreachable("sema stub: sema_len_from_expr");
}

// sema_expr.c:2096 (static)
fn Decl* sema_find_splat_arg(Decl*[] params, String name)
{
	unreachable("sema stub: sema_find_splat_arg");
}

// sema_expr.c:2112 (static)
fn SplatResult sema_splat_optional_argument(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_splat_optional_argument");
}

// sema_expr.c:2153 (static)
fn Type* sema_get_va_type(SemaContext* context, Expr* expr, Variadic variadic)
{
	unreachable("sema stub: sema_get_va_type");
}

// sema_expr.c:2168 (static)
fn Decl*[]* sema_splat_evaluation_ref(CalledDeclContext* callee)
{
	unreachable("sema stub: sema_splat_evaluation_ref");
}

// sema_expr.c:2174 (static)
fn void sema_add_macro_evaluation(CalledDeclContext* callee, Decl* param)
{
	unreachable("sema stub: sema_add_macro_evaluation");
}

// sema_expr.c:2180 (static)
fn bool sema_call_evaluate_arguments(SemaContext* context, CalledDeclContext* callee, Expr* call, bool* optional, bool* no_match_ref)
{
	unreachable("sema stub: sema_call_evaluate_arguments");
}

// sema_expr.c:2792 (static)
fn bool sema_call_check_contract_param_match(SemaContext* context, Decl* param, Expr* expr)
{
	unreachable("sema stub: sema_call_check_contract_param_match");
}

// sema_expr.c:2817 (static)
fn bool sema_has_require(DeclId doc_id)
{
	unreachable("sema stub: sema_has_require");
}

// sema_expr.c:2823 (static)
fn bool sema_call_analyse_func_invocation(SemaContext* context, Decl* decl, Type* type, Expr* expr, Expr* struct_var, bool optional, String name, bool* no_match_ref)
{
	unreachable("sema stub: sema_call_analyse_func_invocation");
}

// sema_expr.c:2962 (static)
fn bool sema_expr_analyse_var_call(SemaContext* context, Expr* expr, Expr* var_, Type* func_ptr_type, bool optional, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_var_call");
}

// sema_expr.c:2990 (static)
fn Type* context_unify_returns(SemaContext* context)
{
	unreachable("sema stub: context_unify_returns");
}

// sema_expr.c:3074 (static)
fn bool sema_expr_analyse_func_call(SemaContext* context, Expr* expr, Decl* decl, Expr* struct_var, bool optional, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_func_call");
}

// sema_expr.c:3103 (static)
fn bool sema_expr_setup_call_analysis(SemaContext* context, CalledDeclContext* callee, SemaContext* macro_context, Expr* call_expr, Type* rtype, Ast* yield_body, Decl*[] yield_params, Decl*[] params, BlockExit** block_exit_ref, InliningSpan* span_ref)
{
	unreachable("sema stub: sema_expr_setup_call_analysis");
}

// sema_expr.c:3156 (static)
fn void sema_update_link_from_macro(SemaContext* context, ResolvedAttrData* attributes)
{
	unreachable("sema stub: sema_update_link_from_macro");
}

// sema_expr.c:3176 (static)
fn bool sema_analyse_macro_body_params(SemaContext* context, Decl* decl, Expr* call_expr, Decl*[] body_params, bool* no_match_ref)
{
	unreachable("sema stub: sema_analyse_macro_body_params");
}

// sema_expr.c:3287 (static)
fn bool sema_analyse_macro_params(SemaContext* context, SemaContext* macro_context, Expr* call_expr, CalledDeclContext* callee, Decl*[] params, AstId** next_ref)
{
	unreachable("sema stub: sema_analyse_macro_params");
}

// sema_expr.c:3345
fn bool sema_expr_analyse_macro_call(SemaContext* context, Expr* call_expr, Expr* struct_var, Decl* decl, bool call_var_optional, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_macro_call");
}

// sema_expr.c:3669 (static)
fn bool sema_call_analyse_body_expansion(SemaContext* macro_context, Expr* call, bool* no_match_ref)
{
	unreachable("sema stub: sema_call_analyse_body_expansion");
}

// sema_expr.c:3798
fn void sema_expr_convert_enum_to_int(Expr* expr)
{
	unreachable("sema stub: sema_expr_convert_enum_to_int");
}

// sema_expr.c:3814
fn bool sema_expr_analyse_general_call(SemaContext* context, Expr* expr, Decl* decl, Expr* struct_var, bool optional, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_general_call");
}

// sema_expr.c:3860 (static)
fn bool sema_expr_analyse_from_ordinal(SemaContext* context, Expr* expr, Expr* tag)
{
	unreachable("sema stub: sema_expr_analyse_from_ordinal");
}

// sema_expr.c:3910 (static)
fn bool sema_expr_analyse_lookup(SemaContext* context, Expr* expr, Expr* tag)
{
	unreachable("sema stub: sema_expr_analyse_lookup");
}

// sema_expr.c:3960 (static)
fn bool sema_expr_analyse_is_generic(SemaContext* context, Expr* expr, Expr* tag)
{
	unreachable("sema stub: sema_expr_analyse_is_generic");
}

// sema_expr.c:3994 (static)
fn bool sema_expr_analyse_typecall(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_typecall");
}

// sema_expr.c:4053 (static)
fn bool sema_call_may_not_have_attributes(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_call_may_not_have_attributes");
}

// sema_expr.c:4070 (static)
fn bool sema_analyse_member_in_type(SemaContext* context, Decl* decl, Expr* inner, TypeKind* target_kind, ArrayIndex* index_ref)
{
	unreachable("sema stub: sema_analyse_member_in_type");
}

// sema_expr.c:4102 (static)
fn bool sema_analyse_member_get_set_common(SemaContext* context, Decl* decl, Expr* inner, TypeKind* target_kind, ArrayIndex* index_ref)
{
	unreachable("sema stub: sema_analyse_member_get_set_common");
}

// sema_expr.c:4108 (static)
fn bool sema_call_analyse_member_set(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_call_analyse_member_set");
}

// sema_expr.c:4136 (static)
fn bool sema_call_analyse_member_get(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_call_analyse_member_get");
}

// sema_expr.c:4162 (static)
fn bool sema_expr_analyse_call_expr_dispatch(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_call_expr_dispatch");
}

// sema_expr.c:4174 (static)
fn bool sema_expr_analyse_call_expr(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_call_expr");
}

// sema_expr.c:4179 (static)
fn bool sema_expr_analyse_call(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_call");
}

// sema_expr.c:4260 (static)
fn bool sema_slice_index_is_in_range(SemaContext* context, Type* type, Expr* index_expr, bool end_index, bool from_end, bool* remove_from_end, bool* missing_ref)
{
	unreachable("sema stub: sema_slice_index_is_in_range");
}

// sema_expr.c:4339 (static)
fn Type* sema_subscript_find_indexable_type_recursively(Type** type, Expr** parent)
{
	unreachable("sema stub: sema_subscript_find_indexable_type_recursively");
}

// sema_expr.c:4355 (static)
fn bool sema_subscript_rewrite_index_const_list(Expr* const_list, ArrayIndex index, bool from_back, Expr* result)
{
	unreachable("sema stub: sema_subscript_rewrite_index_const_list");
}

// sema_expr.c:4381 (static)
fn bool sema_expr_find_subscript_type_or_overload_for_subscript(SemaContext* context, SubscriptLookup* lookup)
{
	unreachable("sema stub: sema_expr_find_subscript_type_or_overload_for_subscript");
}

// sema_expr.c:4440 (static)
fn bool sema_expr_resolve_subscript_index(SemaContext* context, SubscriptLookup* lookup, Expr* expr, Expr* index, long* index_ref, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_resolve_subscript_index");
}

// sema_expr.c:4563 (static)
fn bool sema_expr_analyse_subscript_lvalue(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_subscript_lvalue");
}

// sema_expr.c:4701 (static)
fn bool sema_may_subscript_or_access(SemaContext* context, Expr* expr, String fail_reason, bool* failed_ref)
{
	unreachable("sema stub: sema_may_subscript_or_access");
}

// sema_expr.c:4733 (static)
fn bool sema_expr_analyse_subscript(SemaContext* context, Expr* expr, bool* failed_ref)
{
	unreachable("sema stub: sema_expr_analyse_subscript");
}

// sema_expr.c:4911 (static)
fn bool sema_expr_analyse_pointer_offset(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_pointer_offset");
}

// sema_expr.c:4953 (static)
fn bool sema_expr_analyse_range_internal(SemaContext* context, ExprRange* range, ArrayIndex len, RangeEnv env, FlatType* indexed_type)
{
	unreachable("sema stub: sema_expr_analyse_range_internal");
}

// sema_expr.c:5117 (static)
fn bool sema_expr_analyse_range(SemaContext* context, ExprRange* range, ArrayIndex len, RangeEnv env, FlatType* indexed_type)
{
	unreachable("sema stub: sema_expr_analyse_range");
}

// sema_expr.c:5145 (static)
fn bool sema_slice_initializer(SemaContext* context, Expr* expr, Expr* subscripted, ExprRange* range)
{
	unreachable("sema stub: sema_slice_initializer");
}

// sema_expr.c:5215 (static)
fn bool sema_expr_analyse_slice(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_slice");
}

// sema_expr.c:5335
fn Expr* sema_expr_resolve_access_child(SemaContext* context, Expr* child, bool* missing, bool* was_reflect)
{
	unreachable("sema stub: sema_expr_resolve_access_child");
}

// sema_expr.c:5404 (static)
fn bool sema_expr_replace_with_enum_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	unreachable("sema stub: sema_expr_replace_with_enum_array");
}

// sema_expr.c:5434 (static)
fn bool sema_expr_replace_with_const_enum_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	unreachable("sema stub: sema_expr_replace_with_const_enum_array");
}

// sema_expr.c:5457 (static)
fn bool sema_expr_replace_with_enum_name_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	unreachable("sema stub: sema_expr_replace_with_enum_name_array");
}

// sema_expr.c:5480 (static)
fn bool sema_analyse_macro_func_access(SemaContext* context, Expr* expr, Decl* parent, Expr* identifier, String kw, bool* missing_ref)
{
	unreachable("sema stub: sema_analyse_macro_func_access");
}

// sema_expr.c:5506 (static)
fn bool sema_expr_analyse_type_access(SemaContext* context, Expr* expr, Type* parent_type, Expr* identifier, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_type_access");
}

// sema_expr.c:5609 (static)
fn bool sema_expr_analyse_member_access(SemaContext* context, Expr* expr, Expr* parent, Expr* identifier, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_member_access");
}

// sema_expr.c:5660 (static)
fn bool sema_expr_analyse_reflection_cname(SemaContext* context, Expr* expr, Decl* decl)
{
	unreachable("sema stub: sema_expr_analyse_reflection_cname");
}

// sema_expr.c:5727 (static)
fn void sema_expr_analyse_reflection_name(SemaContext* context, Expr* expr, Decl* decl, bool is_qualified)
{
	unreachable("sema stub: sema_expr_analyse_reflection_name");
}

// sema_expr.c:5741 (static)
fn ArrayIndex sema_recursive_analyse_alignment_offset(Expr* access, AlignSize* alignment_ref)
{
	unreachable("sema stub: sema_recursive_analyse_alignment_offset");
}

// sema_expr.c:5762 (static)
fn BoolErr sema_expr_analyse_reflection_alignment(SemaContext* context, Expr* expr, Expr* reflect, Decl* member)
{
	unreachable("sema stub: sema_expr_analyse_reflection_alignment");
}

// sema_expr.c:5793 (static)
fn bool sema_expr_analyse_reflection_offset(Expr* expr, Expr* reflect)
{
	unreachable("sema stub: sema_expr_analyse_reflection_offset");
}

// sema_expr.c:5814 (static)
fn bool sema_expr_rewrite_to_is_ordered(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_expr_rewrite_to_is_ordered");
}

// sema_expr.c:5830 (static)
fn bool sema_expr_rewrite_to_generic_args(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_expr_rewrite_to_generic_args");
}

// sema_expr.c:5851 (static)
fn bool sema_expr_rewrite_to_generic_qname(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_expr_rewrite_to_generic_qname");
}

// sema_expr.c:5875 (static)
fn bool sema_expr_rewrite_to_has_equals(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_expr_rewrite_to_has_equals");
}

// sema_expr.c:5891
fn bool type_is_ct_only(Type* type)
{
	unreachable("sema stub: type_is_ct_only");
}

// sema_expr.c:5902 (static)
fn bool sema_expr_analyse_reflection_access(SemaContext* context, Expr* expr, Expr* parent, Expr* identifier, bool* missing_ref)
{
	unreachable("sema stub: sema_expr_analyse_reflection_access");
}

// sema_expr.c:6090 (static)
fn void sema_expr_rewrite_typeid_kind(Expr* expr, Expr* parent)
{
	unreachable("sema stub: sema_expr_rewrite_typeid_kind");
}

// sema_expr.c:6102 (static)
fn bool sema_create_const_kind(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_create_const_kind");
}

// sema_expr.c:6127 (static)
fn bool sema_create_const_len(Expr* expr, Type* type, Type* flat)
{
	unreachable("sema stub: sema_create_const_len");
}

// sema_expr.c:6157 (static)
fn bool sema_create_const_inner(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_create_const_inner");
}

// sema_expr.c:6193 (static)
fn bool sema_create_const_parent(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_create_const_parent");
}

// sema_expr.c:6202 (static)
fn bool sema_create_const_min(Expr* expr, Type* type, Type* flat)
{
	unreachable("sema stub: sema_create_const_min");
}

// sema_expr.c:6272 (static)
fn bool sema_create_const_type_params(Expr* expr, Type* type)
{
	unreachable("sema stub: sema_create_const_type_params");
}

// sema_expr.c:6301 (static)
fn bool sema_create_type_param_struct(SemaContext* context, Expr* expr, Decl* fn_decl)
{
	unreachable("sema stub: sema_create_type_param_struct");
}

// sema_expr.c:6342 (static)
fn bool sema_create_const_tags(SemaContext* context, Expr* expr_tags, ResolvedAttrData* resolved_attr)
{
	unreachable("sema stub: sema_create_const_tags");
}

// sema_expr.c:6363 (static)
fn void sema_create_const_membersof(Expr* expr, Type* type, AlignSize alignment, AlignSize offset)
{
	unreachable("sema stub: sema_create_const_membersof");
}

// sema_expr.c:6404 (static)
fn Expr* create_method_copy(Decl* method, SourceLocId loc)
{
	unreachable("sema stub: create_method_copy");
}

// sema_expr.c:6419 (static)
fn void append_to_method_list(Decl*[] methods, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	unreachable("sema stub: append_to_method_list");
}

// sema_expr.c:6430 (static)
fn void sema_append_interface_methods(Decl* interface_, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	unreachable("sema stub: sema_append_interface_methods");
}

// sema_expr.c:6438 (static)
fn void append_extension_methods(Type* type, Decl*[] extensions, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	unreachable("sema stub: append_extension_methods");
}

// sema_expr.c:6449 (static)
fn bool sema_create_const_methodsof(SemaContext* context, Expr* expr, Type* type)
{
	unreachable("sema stub: sema_create_const_methodsof");
}

// sema_expr.c:6481 (static)
fn bool sema_create_const_max(Expr* expr, Type* type, Type* flat)
{
	unreachable("sema stub: sema_create_const_max");
}

// sema_expr.c:6566 (static)
fn bool sema_expr_rewrite_typeid_call(Expr* expr, Expr* typeid_, TypeIdInfoKind kind, Type* result_type)
{
	unreachable("sema stub: sema_expr_rewrite_typeid_call");
}

// sema_expr.c:6575 (static)
fn bool sema_expr_rewrite_to_typeid_property(SemaContext* context, Expr* expr, Expr* typeid_, String kw, bool* was_error)
{
	unreachable("sema stub: sema_expr_rewrite_to_typeid_property");
}

// sema_expr.c:6637 (static)
fn bool sema_expr_fold_to_index(Expr* expr, Expr* parent, SubscriptIndex index_expr)
{
	unreachable("sema stub: sema_expr_fold_to_index");
}

// sema_expr.c:6697 (static)
fn ConstInitializer* sema_expr_fold_to_struct_member(ConstInitializer* init, Type* parent_type, Decl* member)
{
	unreachable("sema stub: sema_expr_fold_to_struct_member");
}

// sema_expr.c:6737 (static)
fn bool sema_expr_fold_to_member(Expr* expr, Expr* parent, Decl* member)
{
	unreachable("sema stub: sema_expr_fold_to_member");
}

// sema_expr.c:6784 (static)
fn bool sema_type_property_is_valid_for_type(CanonicalType* original_type, TypeProperty property)
{
	unreachable("sema stub: sema_type_property_is_valid_for_type");
}

// sema_expr.c:6902 (static)
fn bool sema_expr_rewrite_to_type_property(SemaContext* context, Expr* expr, Type* type, TypeProperty property, Type* parent_type)
{
	unreachable("sema stub: sema_expr_rewrite_to_type_property");
}

