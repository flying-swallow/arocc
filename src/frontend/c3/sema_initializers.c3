// Sema contract stubs for c3c src/compiler/sema_initializers.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_initializers.c:39 (static)
fn bool const_init_local_init_may_be_global_inner(ConstInitializer* init, bool top)
{
	unreachable("sema stub: const_init_local_init_may_be_global_inner");
}

// sema_initializers.c:80
fn void const_init_rewrite_to_zero(ConstInitializer* init, Type* type)
{
	unreachable("sema stub: const_init_rewrite_to_zero");
}

// sema_initializers.c:86
fn ConstInitializer* const_init_new_array(Type* type, ConstInitializer*[] elements)
{
	unreachable("sema stub: const_init_new_array");
}

// sema_initializers.c:95
fn ConstInitializer* const_init_new_array_full(Type* type, ConstInitializer*[] elements)
{
	unreachable("sema stub: const_init_new_array_full");
}

// sema_initializers.c:104
fn ConstInitializer* const_init_new_struct(Type* type, Expr*[] elements)
{
	unreachable("sema stub: const_init_new_struct");
}

// sema_initializers.c:123
fn ConstInitializer* const_init_new_union(Type* type, ArrayIndex index, Expr* value)
{
	unreachable("sema stub: const_init_new_union");
}

// sema_initializers.c:140
fn ConstInitializer* const_init_new_array_value(Expr* expr, ArrayIndex index)
{
	unreachable("sema stub: const_init_new_array_value");
}

// sema_initializers.c:150
fn ConstInitializer* const_init_new_zero_array_value(Type* type, ArrayIndex index)
{
	unreachable("sema stub: const_init_new_zero_array_value");
}

// sema_initializers.c:159
fn ConstInitializer* const_init_new_zero(Type* type)
{
	unreachable("sema stub: const_init_new_zero");
}

// sema_initializers.c:166
fn bool const_init_local_init_may_be_global(ConstInitializer* init)
{
	unreachable("sema stub: const_init_local_init_may_be_global");
}

// sema_initializers.c:171 (static)
fn void sema_not_enough_elements_error(SemaContext* context, Expr* initializer, int element)
{
	unreachable("sema stub: sema_not_enough_elements_error");
}

// sema_initializers.c:185 (static)
fn bool sema_expr_analyse_struct_plain_initializer(SemaContext* context, Decl* assigned, Expr* initializer, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_struct_plain_initializer");
}

// sema_initializers.c:315
fn Expr* sema_create_struct_from_expressions(Decl* struct_decl, SourceLocId loc, Expr*[] exprs)
{
	unreachable("sema stub: sema_create_struct_from_expressions");
}

// sema_initializers.c:325 (static)
fn bool sema_expr_analyse_array_plain_initializer(SemaContext* context, Type* assigned, Type* flattened, Expr* initializer, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_array_plain_initializer");
}

// sema_initializers.c:440 (static)
fn bool sema_expr_analyse_untyped_initializer(SemaContext* context, Expr* initializer, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_untyped_initializer");
}

// sema_initializers.c:466 (static)
fn bool sema_expr_analyse_designated_initializer(SemaContext* context, Type* assigned, Type* flattened, Expr* initializer, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_designated_initializer");
}

// sema_initializers.c:570 (static)
fn bool sema_expr_analyse_initializer(SemaContext* context, Type* assigned_type, Type* flattened, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_initializer");
}

// sema_initializers.c:639 (static)
fn void sema_create_const_initializer_from_designated_init(ConstInitializer* const_init, Expr* initializer)
{
	unreachable("sema stub: sema_create_const_initializer_from_designated_init");
}

// sema_initializers.c:664
fn void sema_invert_bitstruct_const_initializer(ConstInitializer* initializer)
{
	unreachable("sema stub: sema_invert_bitstruct_const_initializer");
}

// sema_initializers.c:714
fn ConstInitializer* sema_merge_bitstruct_const_initializers(ConstInitializer* lhs, ConstInitializer* rhs, BinaryOp op)
{
	unreachable("sema stub: sema_merge_bitstruct_const_initializers");
}

// sema_initializers.c:803
fn bool sema_expr_analyse_initializer_list(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_initializer_list");
}

// sema_initializers.c:907
fn void const_init_rewrite_to_value(ConstInitializer* const_init, Expr* value)
{
	unreachable("sema stub: const_init_rewrite_to_value");
}

// sema_initializers.c:931
fn bool const_init_is_zero(ConstInitializer* init)
{
	unreachable("sema stub: const_init_is_zero");
}

// sema_initializers.c:972
fn ConstInitializer* const_init_new_value(Expr* value)
{
	unreachable("sema stub: const_init_new_value");
}

// sema_initializers.c:982 (static)
fn void sema_update_const_initializer_with_designator_struct(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	unreachable("sema stub: sema_update_const_initializer_with_designator_struct");
}

// sema_initializers.c:1039 (static)
fn void sema_update_const_initializer_with_designator_union(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	unreachable("sema stub: sema_update_const_initializer_with_designator_union");
}

// sema_initializers.c:1091 (static)
fn ConstInitializer* sema_update_const_initializer_at_index(ConstInitializer* const_init, Type* element_type, ArrayIndex index, ArrayIndex* insert_index_ref)
{
	unreachable("sema stub: sema_update_const_initializer_at_index");
}

// sema_initializers.c:1147
fn void const_init_rewrite_array_at(ConstInitializer* const_init, Expr* value, ArrayIndex index)
{
	unreachable("sema stub: const_init_rewrite_array_at");
}

// sema_initializers.c:1174 (static)
fn void sema_update_const_initializer_with_designator_array(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	unreachable("sema stub: sema_update_const_initializer_with_designator_array");
}

// sema_initializers.c:1213 (static)
fn void sema_update_const_initializer_with_designator(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	unreachable("sema stub: sema_update_const_initializer_with_designator");
}

// sema_initializers.c:1237 (static)
fn Type* sema_expr_analyse_designator(SemaContext* context, Type* current, Expr* expr, ArrayIndex* max_index, Decl** member_ptr, bool* no_match_ref)
{
	unreachable("sema stub: sema_expr_analyse_designator");
}

// sema_initializers.c:1262 (static)
fn Type* sema_resolve_vector_element_for_name(SemaContext* context, FlatType* type, DesignatorElement* element, bool* did_report_error)
{
	unreachable("sema stub: sema_resolve_vector_element_for_name");
}

// sema_initializers.c:1299 (static)
fn bool sema_initializer_list_is_empty(Expr* value)
{
	unreachable("sema stub: sema_initializer_list_is_empty");
}

// sema_initializers.c:1304 (static)
fn Type* sema_find_type_of_element(SemaContext* context, Type* type, DesignatorElement*[]* elements_ref, int* curr_index, bool* did_report_error, ArrayIndex* max_index, Decl** member_ptr)
{
	unreachable("sema stub: sema_find_type_of_element");
}

// sema_initializers.c:1392 (static)
fn ArrayIndex sema_analyse_designator_index(SemaContext* context, Expr* index)
{
	unreachable("sema stub: sema_analyse_designator_index");
}

// sema_initializers.c:1420 (static)
fn Decl* sema_resolve_element_for_name(SemaContext* context, Decl*[] decls, DesignatorElement*[]* elements_ref, int* index, bool is_substruct)
{
	unreachable("sema stub: sema_resolve_element_for_name");
}
