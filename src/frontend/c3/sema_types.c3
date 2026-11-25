// Sema contract stubs for c3c src/compiler/sema_types.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

struct FuncTypeEntry
{
	uint key;
	Type* value;
}

struct FuncMap
{
	uint count;
	uint capacity;
	uint max_load;
	FuncTypeEntry* entries;
}

<* c3c `map` (the function prototype hash map, see type_func_prototype_init). *>
FuncMap map;

// sema_types.c:17 (static)
fn bool sema_resolve_ptr_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	unreachable("sema stub: sema_resolve_ptr_type");
}

// sema_types.c:32
fn bool sema_resolve_type_info(SemaContext* context, TypeInfo* type_info, ResolveTypeKind kind)
{
	unreachable("sema stub: sema_resolve_type_info");
}

// sema_types.c:37
fn bool sema_resolve_array_like_len(SemaContext* context, TypeInfo* type_info, ArrayIndex* len_ref)
{
	unreachable("sema stub: sema_resolve_array_like_len");
}

// sema_types.c:98 (static)
fn bool sema_check_array_type(SemaContext* context, TypeInfo* original_info, Type* base, TypeInfoKind kind, ArrayIndex len, Type** result_ref)
{
	unreachable("sema stub: sema_check_array_type");
}

// sema_types.c:179 (static)
fn bool sema_resolve_array_type(SemaContext* context, TypeInfo* type, ResolveTypeKind resolve_kind)
{
	unreachable("sema stub: sema_resolve_array_type");
}

// sema_types.c:213 (static)
fn bool sema_resolve_type_on_use(SemaContext* context, Decl* decl, TypeInfo* type_info, ResolveTypeKind resolve_type_kind)
{
	unreachable("sema stub: sema_resolve_type_on_use");
}

// sema_types.c:295 (static)
fn bool sema_resolve_type_identifier(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_type_kind)
{
	unreachable("sema stub: sema_resolve_type_identifier");
}

// sema_types.c:314 (static)
fn bool sema_resolve_typeof(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: sema_resolve_typeof");
}

// sema_types.c:369
fn TypeInfo* sema_type_info_from_string(SemaContext* context, Expr* expr, bool report_missing)
{
	unreachable("sema stub: sema_type_info_from_string");
}

// sema_types.c:407 (static)
fn bool sema_resolve_typefrom(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	unreachable("sema stub: sema_resolve_typefrom");
}

// sema_types.c:449
fn bool sema_unresolved_type_is_generic(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: sema_unresolved_type_is_generic");
}

// sema_types.c:474 (static)
fn bool sema_resolve_generic_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	unreachable("sema stub: sema_resolve_generic_type");
}

// sema_types.c:512 (static)
fn bool sema_check_ptr_type(SemaContext* context, TypeInfo* type_info, Type* inner)
{
	unreachable("sema stub: sema_check_ptr_type");
}

// sema_types.c:529 (static)
fn bool sema_resolve_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	unreachable("sema stub: sema_resolve_type");
}

// sema_types.c:662
fn void type_func_prototype_init(uint capacity)
{
	unreachable("sema stub: type_func_prototype_init");
}

// sema_types.c:670 (static)
fn Type* flatten_raw_function_type(Type* type)
{
	unreachable("sema stub: flatten_raw_function_type");
}

// sema_types.c:712 (static)
fn uint hash_function(Signature* sig)
{
	unreachable("sema stub: hash_function");
}

// sema_types.c:726 (static)
fn Type* func_create_new_func_proto(Signature* sig, CallABI abi, uint hash, FuncTypeEntry* entry)
{
	unreachable("sema stub: func_create_new_func_proto");
}

// sema_types.c:801 (static)
fn bool compare_func_param(Type* one, Type* other)
{
	unreachable("sema stub: compare_func_param");
}

// sema_types.c:828 (static)
fn int compare_function(Signature* sig, FunctionPrototype* proto)
{
	unreachable("sema stub: compare_function");
}

// sema_types.c:846
fn Type* sema_resolve_type_get_func(Signature* signature, CallABI abi)
{
	unreachable("sema stub: sema_resolve_type_get_func");
}
