// Sema contract stubs for c3c src/compiler/sema_casts.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

struct CastContext
{
	SemaContext* context;
	Expr* expr;
	Type* from;
	Type* to_type;
	Type* to;
	ConvGroup from_group;
	ConvGroup to_group;
	bool is_binary_conversion;
}

alias CastRule = fn bool(CastContext* cc, bool is_explicit, bool is_silent);
alias CastFunction = fn void(Expr* expr, Type* to_type);

// c3c's `cast_rules` / `cast_function` / `group_from_type` tables (end of
// sema_casts.c) are ported together with the file.

// sema_casts.c:49
fn bool cast_implicit(SemaContext* context, Expr* expr, Type* to_type, bool is_binary)
{
	unreachable("sema stub: cast_implicit");
}

// sema_casts.c:57
fn bool cast_implicit_checked(SemaContext* context, Expr* expr, Type* to_type, bool is_binary, bool* failed_ref)
{
	unreachable("sema stub: cast_implicit_checked");
}

// sema_casts.c:68
fn bool cast_implicit_binary(SemaContext* context, Expr* expr, Type* to_type, bool* failed_ref)
{
	unreachable("sema stub: cast_implicit_binary");
}

// sema_casts.c:75
fn bool cast_explicit(SemaContext* context, Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_explicit");
}

// sema_casts.c:83
fn bool cast_explicit_checkable(SemaContext* context, Expr* expr, Type* to_type, bool* failed_ref)
{
	unreachable("sema stub: cast_explicit_checkable");
}

// sema_casts.c:97
fn bool cast_explicit_silent(SemaContext* context, Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_explicit_silent");
}

// sema_casts.c:104
fn bool cast_implicit_silent(SemaContext* context, Expr* expr, Type* to_type, bool is_binary_conversion)
{
	unreachable("sema stub: cast_implicit_silent");
}

// sema_casts.c:110
fn bool may_cast(SemaContext* context, Expr* expr, Type* to_type, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: may_cast");
}

// sema_casts.c:126 (static)
fn bool cast_is_allowed(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: cast_is_allowed");
}

// sema_casts.c:182
fn void cast_no_check(Expr* expr, Type* to_type, bool add_optional)
{
	unreachable("sema stub: cast_no_check");
}

// sema_casts.c:207
fn void cast_to_int_to_max_bit_size(Expr* lhs, Expr* rhs, Type* left_type, Type* right_type)
{
	unreachable("sema stub: cast_to_int_to_max_bit_size");
}

// sema_casts.c:241
fn void cast_promote_vararg(Expr* arg)
{
	unreachable("sema stub: cast_promote_vararg");
}

// sema_casts.c:277
fn bool sema_error_failed_cast(SemaContext* context, Expr* expr, Type* from, Type* to)
{
	unreachable("sema stub: sema_error_failed_cast");
}

// sema_casts.c:285 (static)
fn Type* type_infer_len_from_actual_type(Type* to_infer, Type* actual_type)
{
	unreachable("sema stub: type_infer_len_from_actual_type");
}

// sema_casts.c:345 (static)
fn bool cast_if_valid(SemaContext* context, Expr* expr, Type* to_type, bool is_explicit, bool is_silent, bool is_binary_conversion)
{
	unreachable("sema stub: cast_if_valid");
}

// sema_casts.c:395 (static)
fn bool may_convert_int_float(CanonicalType* from, CanonicalType* to)
{
	unreachable("sema stub: may_convert_int_float");
}

// sema_casts.c:424 (static)
fn Expr* recursive_may_narrow(Expr* expr, Type* type)
{
	unreachable("sema stub: recursive_may_narrow");
}

// sema_casts.c:602 (static)
fn bool sema_error_const_int_out_of_range(CastContext* cc, Expr* expr, Expr* problem, Type* to_type)
{
	unreachable("sema stub: sema_error_const_int_out_of_range");
}

// sema_casts.c:624 (static)
fn void expr_recursively_rewrite_untyped_list(Expr* expr, Type* to_type)
{
	unreachable("sema stub: expr_recursively_rewrite_untyped_list");
}

// sema_casts.c:706
fn bool cast_to_index_len(SemaContext* context, Expr* index, bool is_len)
{
	unreachable("sema stub: cast_to_index_len");
}

// sema_casts.c:738
fn Type* cast_numeric_arithmetic_promotion(Type* type)
{
	unreachable("sema stub: cast_numeric_arithmetic_promotion");
}

// sema_casts.c:759 (static)
fn bool report_cast_error(CastContext* cc, bool may_cast_explicit)
{
	unreachable("sema stub: report_cast_error");
}

// sema_casts.c:833 (static)
fn bool sema_cast_error(CastContext* cc, bool may_cast_explicit, bool is_silent)
{
	unreachable("sema stub: sema_cast_error");
}

// sema_casts.c:842 (static)
fn TypeCmpResult match_pointers(CastContext* cc, Type* to_ptr, Type* from_ptr, bool flatten)
{
	unreachable("sema stub: match_pointers");
}

// sema_casts.c:847 (static)
fn bool rule_voidptr_to_any(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_voidptr_to_any");
}

// sema_casts.c:856 (static)
fn bool rule_ptr_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ptr_to_ptr");
}

// sema_casts.c:883 (static)
fn bool rule_all_ok(CastContext* cc, bool is_explicit, bool silent)
{
	unreachable("sema stub: rule_all_ok");
}

// sema_casts.c:888 (static)
fn bool rule_int_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_int_to_ptr");
}

// sema_casts.c:936 (static)
fn bool rule_ptr_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ptr_to_int");
}

// sema_casts.c:953 (static)
fn bool rule_arrptr_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_arrptr_to_slice");
}

// sema_casts.c:1003 (static)
fn bool rule_ulist_to_struct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ulist_to_struct");
}

// sema_casts.c:1026 (static)
fn bool rule_ulist_to_vecarr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ulist_to_vecarr");
}

// sema_casts.c:1046 (static)
fn bool rule_ulist_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ulist_to_slice");
}

// sema_casts.c:1057 (static)
fn bool rule_ulist_to_inferred(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ulist_to_inferred");
}

// sema_casts.c:1104 (static)
fn bool rule_slice_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_slice_to_ptr");
}

// sema_casts.c:1145 (static)
fn bool rule_slice_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_slice_to_slice");
}

// sema_casts.c:1174 (static)
fn bool rule_arr_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_arr_to_arr");
}

// sema_casts.c:1185 (static)
fn bool rule_arr_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_arr_to_vec");
}

// sema_casts.c:1209 (static)
fn bool rule_vec_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_vec_to_arr");
}

// sema_casts.c:1218 (static)
fn bool rule_vecarr_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_vecarr_to_slice");
}

// sema_casts.c:1230 (static)
fn bool rule_slice_to_vecarr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_slice_to_vecarr");
}

// sema_casts.c:1266 (static)
fn bool rule_slice_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_slice_to_infer");
}

// sema_casts.c:1292 (static)
fn bool rule_vecarr_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_vecarr_to_infer");
}

// sema_casts.c:1303 (static)
fn BoolErr type_implements_interface_ignore_substruct(CastContext* cc, Decl* decl, Type* interface_)
{
	unreachable("sema stub: type_implements_interface_ignore_substruct");
}

// sema_casts.c:1317 (static)
fn bool type_implements_interface(CastContext* cc, Decl* decl, Type* interface_)
{
	unreachable("sema stub: type_implements_interface");
}

// sema_casts.c:1342 (static)
fn bool rule_ptr_to_interface(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ptr_to_interface");
}

// sema_casts.c:1358 (static)
fn bool is_parent_interface(Type* from_interface, Type* to_interface)
{
	unreachable("sema stub: is_parent_interface");
}

// sema_casts.c:1369 (static)
fn bool rule_interface_to_interface(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_interface_to_interface");
}

// sema_casts.c:1383 (static)
fn bool rule_ptr_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_ptr_to_infer");
}

// sema_casts.c:1399 (static)
fn bool rule_explicit_ok(CastContext* cc, bool is_explicit, bool silent)
{
	unreachable("sema stub: rule_explicit_ok");
}

// sema_casts.c:1410 (static)
fn bool rule_int_to_float(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_int_to_float");
}

// sema_casts.c:1426 (static)
fn bool const_float_fits_int(Real d, Type* int_type)
{
	unreachable("sema stub: const_float_fits_int");
}

// sema_casts.c:1435 (static)
fn bool rule_float_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_float_to_int");
}

// sema_casts.c:1447 (static)
fn Expr* const_float_vector_problem(ConstInitializer* init, Type* int_type)
{
	unreachable("sema stub: const_float_vector_problem");
}

// sema_casts.c:1483 (static)
fn bool expr_is_pointer_diff(Expr* expr)
{
	unreachable("sema stub: expr_is_pointer_diff");
}

// sema_casts.c:1491 (static)
fn bool rule_widen_narrow(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_widen_narrow");
}

// sema_casts.c:1573 (static)
fn bool rule_not_applicable(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_not_applicable");
}

// sema_casts.c:1578 (static)
fn bool rule_from_explicit_flattened(CastContext* cc, bool is_silent)
{
	unreachable("sema stub: rule_from_explicit_flattened");
}

// sema_casts.c:1607 (static)
fn bool rule_from_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_from_distinct");
}

// sema_casts.c:1638 (static)
fn bool rule_to_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_to_distinct");
}

// sema_casts.c:1694 (static)
fn bool rule_to_from_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_to_from_distinct");
}

// sema_casts.c:1714 (static)
fn bool rule_to_struct_to_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_to_struct_to_distinct");
}

// sema_casts.c:1723 (static)
fn bool rule_struct_to_struct(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_struct_to_struct");
}

// sema_casts.c:1732 (static)
fn bool rule_vec_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_vec_to_vec");
}

// sema_casts.c:1767 (static)
fn bool rule_expand_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_expand_to_vec");
}

// sema_casts.c:1779 (static)
fn bool rule_int_to_bits(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_int_to_bits");
}

// sema_casts.c:1805 (static)
fn bool rule_int_to_enum(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_int_to_enum");
}

// sema_casts.c:1828 (static)
fn bool rule_arr_to_bits(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_arr_to_bits");
}

// sema_casts.c:1839 (static)
fn bool rule_enum_to_value(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_enum_to_value");
}

// sema_casts.c:1861 (static)
fn bool rule_bits_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_bits_to_arr");
}

// sema_casts.c:1871 (static)
fn bool rule_bits_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable("sema stub: rule_bits_to_int");
}

// sema_casts.c:1896 (static)
fn void cast_vaptr_to_slice(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_vaptr_to_slice");
}

// sema_casts.c:1909 (static)
fn void cast_ptr_to_any(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_ptr_to_any");
}

// sema_casts.c:1920 (static)
fn void cast_struct_to_inline(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_struct_to_inline");
}

// sema_casts.c:1943 (static)
fn void cast_fault_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_fault_to_ptr");
}

// sema_casts.c:1944 (static)
fn void cast_typeid_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_typeid_to_int");
}

// sema_casts.c:1945 (static)
fn void cast_fault_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_fault_to_int");
}

// sema_casts.c:1946 (static)
fn void cast_typeid_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_typeid_to_ptr");
}

// sema_casts.c:1947 (static)
fn void cast_any_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_any_to_bool");
}

// sema_casts.c:1953 (static)
fn void cast_any_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_any_to_ptr");
}

// sema_casts.c:1954 (static)
fn void cast_all_to_void(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_all_to_void");
}

// sema_casts.c:1955 (static)
fn void cast_retype(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_retype");
}

// sema_casts.c:1957 (static)
fn void vector_const_initializer_convert_to_type(ConstInitializer* initializer, Type* to_type)
{
	unreachable("sema stub: vector_const_initializer_convert_to_type");
}

// sema_casts.c:2024 (static)
fn void cast_ptr_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_ptr_to_ptr");
}

// sema_casts.c:2041 (static)
fn void cast_float_to_float(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_float_to_float");
}

// sema_casts.c:2066 (static)
fn void cast_float_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_float_to_int");
}

// sema_casts.c:2088 (static)
fn void cast_int_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_to_int");
}

// sema_casts.c:2118 (static)
fn void cast_expand_to_vec(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_expand_to_vec");
}

// sema_casts.c:2130 (static)
fn void cast_bitstruct_to_int_arr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_bitstruct_to_int_arr");
}

// sema_casts.c:2140 (static)
fn void cast_int_arr_to_bitstruct(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_arr_to_bitstruct");
}

// sema_casts.c:2151 (static)
fn void cast_bitstruct_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_bitstruct_to_bool");
}

// sema_casts.c:2162 (static)
fn void cast_int_to_float(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_to_float");
}

// sema_casts.c:2182 (static)
fn void cast_int_to_enum(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_to_enum");
}

// sema_casts.c:2206 (static)
fn void cast_enum_to_value(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_enum_to_value");
}

// sema_casts.c:2216 (static)
fn void cast_vec_to_arr(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_vec_to_arr");
}

// sema_casts.c:2237 (static)
fn void cast_vec_to_vec(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_vec_to_vec");
}

// sema_casts.c:2365 (static)
fn void cast_untyped_list_to_other(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_untyped_list_to_other");
}

// sema_casts.c:2373 (static)
fn void cast_slice_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_slice_to_ptr");
}

// sema_casts.c:2388 (static)
fn void cast_int_to_ptr(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_to_ptr");
}

// sema_casts.c:2409 (static)
fn void cast_bool_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_bool_to_int");
}

// sema_casts.c:2424 (static)
fn void cast_bool_to_float(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_bool_to_float");
}

// sema_casts.c:2440 (static)
fn void cast_int_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_int_to_bool");
}

// sema_casts.c:2456 (static)
fn void cast_float_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_float_to_bool");
}

// sema_casts.c:2477 (static)
fn void cast_ptr_to_int(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_ptr_to_int");
}

// sema_casts.c:2491 (static)
fn void cast_ptr_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_ptr_to_bool");
}

// sema_casts.c:2520 (static)
fn void cast_slice_to_bool(Expr* expr, Type* type)
{
	unreachable("sema stub: cast_slice_to_bool");
}

// sema_casts.c:2544 (static)
fn void cast_slice_to_slice(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_slice_to_slice");
}

// sema_casts.c:2554 (static)
fn void cast_vecarr_to_slice(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_vecarr_to_slice");
}

// sema_casts.c:2594 (static)
fn void const_bytes_zero_extend(Expr* expr, ArrayIndex len)
{
	unreachable("sema stub: const_bytes_zero_extend");
}

// sema_casts.c:2604 (static)
fn void cast_slice_to_arr(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_slice_to_arr");
}

// sema_casts.c:2635 (static)
fn void expr_rewrite_bytes_to_const_initializer(Expr* expr, Type* target_type)
{
	unreachable("sema stub: expr_rewrite_bytes_to_const_initializer");
}

// sema_casts.c:2657 (static)
fn void cast_slice_to_vec(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_slice_to_vec");
}

// sema_casts.c:2697 (static)
fn void cast_slice_to_infer(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_slice_to_infer");
}

// sema_casts.c:2706 (static)
fn void cast_vecarr_to_infer(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_vecarr_to_infer");
}

// sema_casts.c:2712 (static)
fn void cast_ptr_to_infer(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_ptr_to_infer");
}

// sema_casts.c:2723 (static)
fn void cast_arr_to_vec(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_arr_to_vec");
}

// sema_casts.c:2754 (static)
fn void cast_arr_to_arr(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_arr_to_arr");
}

// sema_casts.c:2760 (static)
fn void cast_anyfault_to_bool(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_anyfault_to_bool");
}

// sema_casts.c:2765 (static)
fn void cast_typeid_to_bool(Expr* expr, Type* to_type)
{
	unreachable("sema stub: cast_typeid_to_bool");
}

// sema_casts.c:2958 (static)
fn ConvGroup type_to_group(Type* type)
{
	unreachable("sema stub: type_to_group");
}

// sema_casts.c:2967 (static)
fn void cast_context_set_from(CastContext* cc, Type* new_from)
{
	unreachable("sema stub: cast_context_set_from");
}

// sema_casts.c:2972 (static)
fn void cast_context_set_to(CastContext* cc, Type* new_to)
{
	unreachable("sema stub: cast_context_set_to");
}
