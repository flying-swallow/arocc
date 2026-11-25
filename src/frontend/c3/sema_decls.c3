// Sema contract stubs for c3c src/compiler/sema_decls.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

enum MainSubType : char
{
	NORMAL,
	WINMAIN,
	WMAIN,
}

// sema_decls.c:56 (static)
fn bool sema_resolve_align_expr(SemaContext* context, Expr* expr, AlignSize* result)
{
	unreachable("sema stub: sema_resolve_align_expr");
}

// sema_decls.c:90 (static)
fn bool sema_check_section(SemaContext* context, Attr* attr)
{
	unreachable("sema stub: sema_check_section");
}

// sema_decls.c:125 (static)
fn bool sema_check_param_uniqueness_and_type(SemaContext* context, Decl*[] decls, Decl* current, int current_index)
{
	unreachable("sema stub: sema_check_param_uniqueness_and_type");
}

// sema_decls.c:158 (static)
fn bool sema_resolve_implemented_interfaces(SemaContext* context, Decl* decl, bool resolve_interfaces)
{
	unreachable("sema stub: sema_resolve_implemented_interfaces");
}

// sema_decls.c:207 (static)
fn bool sema_analyse_struct_member(SemaContext* context, Decl* parent, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_struct_member");
}

// sema_decls.c:328 (static)
fn bool sema_check_struct_holes(SemaContext* context, Decl* parent, Decl* member)
{
	unreachable("sema stub: sema_check_struct_holes");
}

// sema_decls.c:371 (static)
fn bool sema_analyse_union_members(SemaContext* context, Decl* union_decl)
{
	unreachable("sema stub: sema_analyse_union_members");
}

// sema_decls.c:505
fn AlignSize sema_get_max_natural_alignment(Type* type)
{
	unreachable("sema stub: sema_get_max_natural_alignment");
}

// sema_decls.c:581 (static)
fn bool sema_analyse_struct_members(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_struct_members");
}

// sema_decls.c:819 (static)
fn bool sema_analyse_struct_union(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_struct_union");
}

// sema_decls.c:867 (static)
fn bool sema_analyse_bitstruct_member(SemaContext* context, Decl* parent, Decl* member, int index, bool allow_overlap, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_bitstruct_member");
}

// sema_decls.c:1054 (static)
fn bool sema_analyse_interface(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_interface");
}

// sema_decls.c:1161 (static)
fn bool sema_deep_resolve_function_ptr(SemaContext* context, TypeInfo* type_to_resolve)
{
	unreachable("sema stub: sema_deep_resolve_function_ptr");
}

// sema_decls.c:1210 (static)
fn bool sema_analyse_bitstruct(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_bitstruct");
}

// sema_decls.c:1260 (static)
fn bool sema_analyse_signature(SemaContext* context, Signature* sig, TypeInfo* method_parent, Decl* decl)
{
	unreachable("sema stub: sema_analyse_signature");
}

// sema_decls.c:1590
fn bool sema_analyse_function_signature(SemaContext* context, Decl* func_decl, TypeInfo* parent, CallABI abi, Signature* signature)
{
	unreachable("sema stub: sema_analyse_function_signature");
}

// sema_decls.c:1624 (static)
fn bool sema_analyse_fntype(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_fntype");
}

// sema_decls.c:1638 (static)
fn bool sema_analyse_type_alias(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_type_alias");
}

// sema_decls.c:1697 (static)
fn bool sema_analyse_typedef(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_typedef");
}

// sema_decls.c:1742 (static)
fn bool sema_analyse_enum_param(SemaContext* context, Decl* param)
{
	unreachable("sema stub: sema_analyse_enum_param");
}

// sema_decls.c:1774 (static)
fn void sema_print_enum_to_constset_error(SemaContext* context, Decl* decl, Expr* arg)
{
	unreachable("sema stub: sema_print_enum_to_constset_error");
}

// sema_decls.c:1786 (static)
fn bool sema_analyse_enum(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_enum");
}

// sema_decls.c:1943 (static)
fn void sema_fixup_global_temps_after_generation(CompilationUnit* unit, int start, Decl* owner, bool writable)
{
	unreachable("sema stub: sema_fixup_global_temps_after_generation");
}

// sema_decls.c:1958 (static)
fn bool sema_analyse_const_enum_constant_val(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_const_enum_constant_val");
}

// sema_decls.c:1974 (static)
fn bool sema_analyse_constset(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_constset");
}

// sema_decls.c:2071 (static)
fn bool sema_analyse_fault(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_fault");
}

// sema_decls.c:2082 (static)
fn String method_name_by_decl(Decl* method_like)
{
	unreachable("sema stub: method_name_by_decl");
}

// sema_decls.c:2096 (static)
fn bool sema_analyse_operator_common(SemaContext* context, Decl* method, TypeInfo** rtype_ptr, Decl*[]* params_ptr, int parameters)
{
	unreachable("sema stub: sema_analyse_operator_common");
}

// sema_decls.c:2124
fn bool sema_type_has_subscript_overloads(Type* type)
{
	unreachable("sema stub: sema_type_has_subscript_overloads");
}

// sema_decls.c:2133
fn Decl* sema_find_untyped_operator(Type* type, OperatorOverload operator_overload, Decl* skipped)
{
	unreachable("sema stub: sema_find_untyped_operator");
}

// sema_decls.c:2155
fn OverloadMatch sema_find_typed_operator_type(SemaContext* context, OperatorOverload operator_overload, OverloadType overload_type, Type* lhs_type, Type* rhs_type, Expr* rhs, Decl** candidate_ref, OverloadMatch last_match, Decl** ambiguous_ref)
{
	unreachable("sema stub: sema_find_typed_operator_type");
}

// sema_decls.c:2237
fn String operator_overload_to_string(OperatorOverload operator_overload)
{
	unreachable("sema stub: operator_overload_to_string");
}

// sema_decls.c:2274
fn Decl* sema_find_typed_operator(SemaContext* context, OperatorOverload operator_overload, SourceLocId loc, Expr* lhs, Expr* rhs, bool* reverse)
{
	unreachable("sema stub: sema_find_typed_operator");
}

// sema_decls.c:2312 (static)
fn bool sema_analyse_operator_unary(SemaContext* context, Decl* method, OperatorOverload operator_overload)
{
	unreachable("sema stub: sema_analyse_operator_unary");
}

// sema_decls.c:2327 (static)
fn bool sema_analyse_operator_arithmetics(SemaContext* context, Decl* method, OperatorOverload operator_overload)
{
	unreachable("sema stub: sema_analyse_operator_arithmetics");
}

// sema_decls.c:2362 (static)
fn bool sema_analyse_operator_element_at(SemaContext* context, Decl* method)
{
	unreachable("sema stub: sema_analyse_operator_element_at");
}

// sema_decls.c:2391 (static)
fn bool sema_analyse_operator_element_set(SemaContext* context, Decl* method)
{
	unreachable("sema stub: sema_analyse_operator_element_set");
}

// sema_decls.c:2398 (static)
fn bool sema_analyse_operator_len(SemaContext* context, Decl* method)
{
	unreachable("sema stub: sema_analyse_operator_len");
}

// sema_decls.c:2410 (static)
fn bool sema_check_operator_method_validity(SemaContext* context, Decl* method)
{
	unreachable("sema stub: sema_check_operator_method_validity");
}

// sema_decls.c:2455
fn bool sema_decl_if_cond(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_decl_if_cond");
}

// sema_decls.c:2484 (static)
fn SourceLocId method_find_overload_span(Decl* method)
{
	unreachable("sema stub: method_find_overload_span");
}

// sema_decls.c:2490 (static)
fn bool unit_add_base_extension_method(SemaContext* context, Type* type, Decl* method)
{
	unreachable("sema stub: unit_add_base_extension_method");
}

// sema_decls.c:2511 (static)
fn void sema_get_overload_arguments(Decl* method, Type** value_ref, Type** index_ref)
{
	unreachable("sema stub: sema_get_overload_arguments");
}

// sema_decls.c:2582 (static)
fn bool sema_is_valid_operator_for_type(SemaContext* context, Type* type, OperatorOverload operator, Decl* method)
{
	unreachable("sema stub: sema_is_valid_operator_for_type");
}

// sema_decls.c:2622 (static)
fn bool sema_analyse_operator_method(SemaContext* context, Type* parent_type, Decl* method)
{
	unreachable("sema stub: sema_analyse_operator_method");
}

// sema_decls.c:2838 (static)
fn bool type_add_method(SemaContext* context, Type* parent_type, Decl* method)
{
	unreachable("sema stub: type_add_method");
}

// sema_decls.c:2894 (static)
fn Decl* sema_interface_method_by_name(SemaContext* context, Decl* interface_, String name)
{
	unreachable("sema stub: sema_interface_method_by_name");
}

// sema_decls.c:2922 (static)
fn Decl* sema_find_interface_for_method(SemaContext* context, CanonicalType* parent_type, Decl* method)
{
	unreachable("sema stub: sema_find_interface_for_method");
}

// sema_decls.c:2987 (static)
fn bool sema_compare_method_with_interface(SemaContext* context, Decl* decl, Decl* implemented_method)
{
	unreachable("sema stub: sema_compare_method_with_interface");
}

// sema_decls.c:3051 (static)
fn bool sema_analyse_method(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_method");
}

// sema_decls.c:3208 (static)
fn String attribute_domain_to_string(AttributeDomain domain)
{
	unreachable("sema stub: attribute_domain_to_string");
}

// sema_decls.c:3243 (static)
fn bool update_abi(Decl* decl, CallABI abi)
{
	unreachable("sema stub: update_abi");
}

// sema_decls.c:3266 (static)
fn bool update_call_abi_from_string(SemaContext* context, Decl* decl, Expr* expr)
{
	unreachable("sema stub: update_call_abi_from_string");
}

// sema_decls.c:3307 (static)
fn bool sema_analyse_attribute_int_const(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_attribute_int_const");
}

// sema_decls.c:3325 (static)
fn bool sema_analyse_attribute_string_const(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_attribute_string_const");
}

// sema_decls.c:3340 (static)
fn bool sema_analyse_attribute_bool_const(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_analyse_attribute_bool_const");
}

// sema_decls.c:3351 (static)
fn StackProtector stack_protector_from_string(String name)
{
	unreachable("sema stub: stack_protector_from_string");
}

// sema_decls.c:3360 (static)
fn StackProbe stack_probe_from_string(String name)
{
	unreachable("sema stub: stack_probe_from_string");
}

// sema_decls.c:3372 (static)
fn bool sema_analyse_attribute(SemaContext* context, ResolvedAttrData* attr_data, Decl* decl, Attr* attr, AttributeDomain domain, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_attribute");
}

// sema_decls.c:3917 (static)
fn bool sema_analyse_custom_attribute(SemaContext* context, ResolvedAttrData* attr_data_ref, Decl* decl, Attr* attr, AttributeDomain domain, Decl* top, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_custom_attribute");
}

// sema_decls.c:4015 (static)
fn bool sema_analyse_attributes_inner(SemaContext* context, ResolvedAttrData* attr_data_ref, Decl* decl, Attr*[] attrs, AttributeDomain domain, Decl* top, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_attributes_inner");
}

// sema_decls.c:4042
fn bool sema_analyse_attributes(SemaContext* context, Decl* decl, Attr*[] attrs, AttributeDomain domain, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_attributes");
}

// sema_decls.c:4063
fn bool sema_analyse_optional_returns(SemaContext* context, Decl* contracts)
{
	unreachable("sema stub: sema_analyse_optional_returns");
}

// sema_decls.c:4159 (static)
fn Decl* contract_find_param_by_name(String name, Decl*[] params, Decl*[] extra_params)
{
	unreachable("sema stub: contract_find_param_by_name");
}

// sema_decls.c:4171 (static)
fn bool sema_analyse_doc_header(SemaContext* context, DeclId docs, Decl*[] params, Decl*[] extra_params, bool* pure_ref, bool is_raw_vaarg)
{
	unreachable("sema stub: sema_analyse_doc_header");
}

// sema_decls.c:4265 (static)
fn MainType sema_find_main_type(SemaContext* context, Signature* sig, bool is_winmain)
{
	unreachable("sema stub: sema_find_main_type");
}

// sema_decls.c:4341 (static)
fn BoolErr sema_evaluate_feature(Expr* expr)
{
	unreachable("sema stub: sema_evaluate_feature");
}

// sema_decls.c:4360 (static)
fn BoolErr sema_evaluate_feature_expression(Expr* expr)
{
	unreachable("sema stub: sema_evaluate_feature_expression");
}

// sema_decls.c:4396
fn BoolErr sema_evaluate_feature_expr_list(Expr*[] exprs)
{
	unreachable("sema stub: sema_evaluate_feature_expr_list");
}

// sema_decls.c:4411
fn BoolErr sema_retain_feat(Attr* attr)
{
	unreachable("sema stub: sema_retain_feat");
}

// sema_decls.c:4418
fn BoolErr sema_retain_conditional_feat(Attr*[] attrs)
{
	unreachable("sema stub: sema_retain_conditional_feat");
}

// sema_decls.c:4429
fn Decl* sema_create_runner_main(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_create_runner_main");
}

// sema_decls.c:4499 (static)
fn Decl* sema_create_synthetic_main(SemaContext* context, Decl* decl, MainType main, MainSubType sub_type)
{
	unreachable("sema stub: sema_create_synthetic_main");
}

// sema_decls.c:4605 (static)
fn bool sema_analyse_main_function(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_main_function");
}

// sema_decls.c:4689 (static)
fn bool sema_analyse_func(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_func");
}

// sema_decls.c:4787 (static)
fn bool sema_is_valid_method_param(SemaContext* context, Decl* param, Type* parent_type, bool is_dynamic)
{
	unreachable("sema stub: sema_is_valid_method_param");
}

// sema_decls.c:4825 (static)
fn bool sema_analyse_macro_method(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_macro_method");
}

// sema_decls.c:4856 (static)
fn bool sema_analyse_macro_body(SemaContext* context, Decl*[] body_parameters)
{
	unreachable("sema stub: sema_analyse_macro_body");
}

// sema_decls.c:4900 (static)
fn bool sema_check_body_const(SemaContext* context, Ast* body)
{
	unreachable("sema stub: sema_check_body_const");
}

// sema_decls.c:4969 (static)
fn bool sema_analyse_macro(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_macro");
}

// sema_decls.c:5012 (static)
fn bool sema_analyse_attributes_for_var(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_attributes_for_var");
}

// sema_decls.c:5035 (static)
fn bool sema_type_is_valid_size(SemaContext* context, Type* type, SourceLocId loc)
{
	unreachable("sema stub: sema_type_is_valid_size");
}

// sema_decls.c:5093 (static)
fn bool sema_analyse_variable_type(SemaContext* context, Type* type, SourceLocId loc)
{
	unreachable("sema stub: sema_analyse_variable_type");
}

// sema_decls.c:5121 (static)
fn void sema_error_not_constant(SemaContext* context, Decl* target, Expr* init)
{
	unreachable("sema stub: sema_error_not_constant");
}

// sema_decls.c:5139
fn bool sema_analyse_var_decl_ct(SemaContext* context, Decl* decl, bool* check_defined)
{
	unreachable("sema stub: sema_analyse_var_decl_ct");
}

// sema_decls.c:5283 (static)
fn bool sema_analyse_var_decl(SemaContext* context, Decl* decl, bool local, bool* check_defined)
{
	unreachable("sema stub: sema_analyse_var_decl");
}

// sema_decls.c:5544 (static)
fn bool sema_analyse_attribute_decl(SemaContext* context, SemaContext* c, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_attribute_decl");
}

// sema_decls.c:5571 (static)
fn bool char_first_is_upper(String c)
{
	unreachable("sema stub: char_first_is_upper");
}

// sema_decls.c:5577 (static)
fn bool check_valid_symbol_match(SemaContext* context, bool was_constant, Expr* expr, Decl* decl)
{
	unreachable("sema stub: check_valid_symbol_match");
}

// sema_decls.c:5606 (static)
fn bool sema_analyse_alias(SemaContext* context, Decl* decl, bool* erase_decl)
{
	unreachable("sema stub: sema_analyse_alias");
}

// sema_decls.c:5668
fn bool sema_resolve_type_structure(SemaContext* context, Type* type)
{
	unreachable("sema stub: sema_resolve_type_structure");
}

// sema_decls.c:5718 (static)
fn Decl* type_is_possible_template(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: type_is_possible_template");
}

// sema_decls.c:5726
fn bool sema_analyse_method_register(SemaContext* context, Decl* method)
{
	unreachable("sema stub: sema_analyse_method_register");
}

// sema_decls.c:5764
fn bool sema_compare_weak_decl(SemaContext* context, Decl* replaced, Decl* replacement)
{
	unreachable("sema stub: sema_compare_weak_decl");
}

// sema_decls.c:5796
fn bool sema_analyse_local(SemaContext* context, Decl* decl, bool* failed_ref)
{
	unreachable("sema stub: sema_analyse_local");
}

// sema_decls.c:5817
fn bool sema_analyse_decl(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_analyse_decl");
}
