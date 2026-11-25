// Sema contract stubs for c3c src/compiler/types.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
// Companion of types.c3: the types.c functions not ported yet. Merge into
// types.c3 when they are ported.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* The `void (*append_decl_name)(Decl *)` callback of type_mangle_introspect_name_with. *>
alias DeclAppendFn = fn void(Decl* decl);

// types.c:477
fn FunctionPrototype* type_get_resolved_prototype(Type* type)
{
	unreachable("sema stub: type_get_resolved_prototype");
}

// types.c:527
fn Type* type_is_must_init(Type* type)
{
	unreachable("sema stub: type_is_must_init");
}

// types.c:564
fn bool type_is_abi_aggregate(Type* type)
{
	unreachable("sema stub: type_is_abi_aggregate");
}

// types.c:570
fn bool type_is_aggregate(Type* type)
{
	unreachable("sema stub: type_is_aggregate");
}

// types.c:614
fn Type* type_find_largest_union_element(Type* type)
{
	unreachable("sema stub: type_find_largest_union_element");
}

// types.c:631
fn bool type_is_ordered(Type* type)
{
	unreachable("sema stub: type_is_ordered");
}

// types.c:654
fn bool type_is_comparable(Type* type)
{
	unreachable("sema stub: type_is_comparable");
}

// types.c:704 (static)
fn void append_extern_decl_name_no_clear(Decl* decl)
{
	unreachable("sema stub: append_extern_decl_name_no_clear");
}

// types.c:709
fn void type_mangle_introspect_name_to_buffer(Type* type)
{
	unreachable("sema stub: type_mangle_introspect_name_to_buffer");
}

// types.c:714
fn void type_mangle_introspect_name_with(Type* type, DeclAppendFn append_decl_name)
{
	unreachable("sema stub: type_mangle_introspect_name_with");
}

// types.c:815
fn bool type_func_match(Type* fn_type, Type* rtype, int arg_count, Type*... arg_types)
{
	unreachable("sema stub: type_func_match");
}

// types.c:920 (static)
fn bool _type_contains_padded_union(Type* type, bool in_union_rep)
{
	unreachable("sema stub: _type_contains_padded_union");
}

// types.c:945
fn bool type_contains_padded_union(Type* type)
{
	unreachable("sema stub: type_contains_padded_union");
}

// types.c:1192 (static)
fn bool array_structurally_equivalent_to_struct(Type* array, Type* type)
{
	unreachable("sema stub: array_structurally_equivalent_to_struct");
}

// types.c:1222
fn bool type_is_structurally_equivalent(Type* type1, Type* type2)
{
	unreachable("sema stub: type_is_structurally_equivalent");
}

// types.c:1753
fn bool type_is_subtype(Type* type, Type* possible_subtype)
{
	unreachable("sema stub: type_is_subtype");
}

// types.c:1828 (static)
fn TypeCmpResult type_array_is_equivalent(SemaContext* context, Type* from, Type* to, bool is_explicit)
{
	unreachable("sema stub: type_array_is_equivalent");
}

// types.c:1855
fn TypeCmpResult type_array_element_is_equivalent(SemaContext* context, Type* element1, Type* element2, bool is_explicit)
{
	unreachable("sema stub: type_array_element_is_equivalent");
}

// types.c:1899
fn TypeCmpResult type_is_pointer_equivalent(SemaContext* context, Type* to_pointer, Type* from_pointer, bool flatten_distinct)
{
	unreachable("sema stub: type_is_pointer_equivalent");
}

// types.c:1965
fn bool type_may_have_method(Type* type)
{
	unreachable("sema stub: type_may_have_method");
}

// types.c:2024
fn Type* type_find_max_num_type(Type* num_type, Type* other_num)
{
	unreachable("sema stub: type_find_max_num_type");
}

// types.c:2089 (static)
fn Type* type_find_max_ptr_type(SemaContext* context, Type* type, Type* other)
{
	unreachable("sema stub: type_find_max_ptr_type");
}

// types.c:2134
fn Type* type_decay_array_pointer(Type* type)
{
	unreachable("sema stub: type_decay_array_pointer");
}

// types.c:2148 (static)
fn Type* type_find_max_distinct_type(Type* left, Type* right)
{
	unreachable("sema stub: type_find_max_distinct_type");
}

// types.c:2180
fn Type* type_find_max_type(SemaContext* context, Type* type, Type* other, Expr* first, Expr* second)
{
	unreachable("sema stub: type_find_max_type");
}

// types.c:2400
fn int type_get_introspection_kind(TypeKind kind)
{
	unreachable("sema stub: type_get_introspection_kind");
}

// types.c:2475
fn Module* type_base_module(Type* type)
{
	unreachable("sema stub: type_base_module");
}
