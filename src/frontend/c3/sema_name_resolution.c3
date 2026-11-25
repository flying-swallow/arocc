// Sema contract stubs for c3c src/compiler/sema_name_resolution.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_name_resolution.c:12
fn Decl* sema_find_generic_instance(SemaContext* context, Module* module_, Decl* generic, Decl* instance, String name)
{
	unreachable("sema stub: sema_find_generic_instance");
}

// sema_name_resolution.c:33 (static)
fn bool matches_subpath(ModulePath* path_to_check, ModulePath* path_to_find)
{
	unreachable("sema stub: matches_subpath");
}

// sema_name_resolution.c:53
fn Decl* sema_decl_stack_resolve_symbol(String symbol)
{
	unreachable("sema stub: sema_decl_stack_resolve_symbol");
}

// sema_name_resolution.c:65
fn Decl** sema_decl_stack_store()
{
	unreachable("sema stub: sema_decl_stack_store");
}

// sema_name_resolution.c:72
fn void sema_decl_stack_restore(Decl** state)
{
	unreachable("sema stub: sema_decl_stack_restore");
}

// sema_name_resolution.c:78
fn void sema_decl_stack_push(Decl* decl)
{
	unreachable("sema stub: sema_decl_stack_push");
}

// sema_name_resolution.c:89 (static)
fn bool add_interface_to_decl_stack(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: add_interface_to_decl_stack");
}

// sema_name_resolution.c:103 (static)
fn bool add_members_to_decl_stack(SemaContext* context, Decl* decl, FindMember find)
{
	unreachable("sema stub: add_members_to_decl_stack");
}

// sema_name_resolution.c:142
fn Decl* sema_decl_stack_find_decl_member(SemaContext* context, Decl* decl_owner, String symbol, FindMember find)
{
	unreachable("sema stub: sema_decl_stack_find_decl_member");
}

// sema_name_resolution.c:156 (static)
fn Decl* sema_find_decl_in_module(Module* module_, ModulePath* path, String symbol, Module** path_found_ref)
{
	unreachable("sema stub: sema_find_decl_in_module");
}

// sema_name_resolution.c:165 (static)
fn bool sema_find_decl_in_imports(SemaContext* context, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_find_decl_in_imports");
}

// sema_name_resolution.c:216 (static)
fn Module* sema_is_path_found(Module*[] modules, ModulePath* path)
{
	unreachable("sema stub: sema_is_path_found");
}

// sema_name_resolution.c:225
fn Decl* sema_find_decl_in_modules(Module*[] module_list, ModulePath* path, String interned_name)
{
	unreachable("sema stub: sema_find_decl_in_modules");
}

// sema_name_resolution.c:236 (static)
fn bool module_inclusion_match(Module* a, Module* b)
{
	unreachable("sema stub: module_inclusion_match");
}

// sema_name_resolution.c:250 (static)
fn bool decl_is_visible(CompilationUnit* unit, Decl* decl)
{
	unreachable("sema stub: decl_is_visible");
}

// sema_name_resolution.c:283 (static)
fn Type* sema_fold_weak(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_fold_weak");
}

// sema_name_resolution.c:317 (static)
fn BoolErr sema_first_is_preferred(SemaContext* context, Decl* decl, Decl* decl2, bool has_path)
{
	unreachable("sema stub: sema_first_is_preferred");
}

// sema_name_resolution.c:351 (static)
fn bool sema_resolve_ambiguity(SemaContext* context, Decl** current, Decl* candidate, Decl** ambiguous, bool has_path)
{
	unreachable("sema stub: sema_resolve_ambiguity");
}

// sema_name_resolution.c:387 (static)
fn Decl* sema_find_decl_by_short_path(ModulePath* path, String name)
{
	unreachable("sema stub: sema_find_decl_by_short_path");
}

// sema_name_resolution.c:392 (static)
fn bool sema_find_decl_in_global(SemaContext* context, DeclTable* table, Module*[] module_list, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_find_decl_in_global");
}

// sema_name_resolution.c:459 (static)
fn bool sema_resolve_path_symbol(SemaContext* context, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_resolve_path_symbol");
}

// sema_name_resolution.c:503 (static)
fn Decl* sema_find_ct_local(SemaContext* context, String symbol)
{
	unreachable("sema stub: sema_find_ct_local");
}

// sema_name_resolution.c:513
fn Decl* sema_find_local(SemaContext* context, String symbol)
{
	unreachable("sema stub: sema_find_local");
}

// sema_name_resolution.c:541 (static)
fn bool sema_resolve_no_path_symbol(SemaContext* context, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_resolve_no_path_symbol");
}

// sema_name_resolution.c:578
fn int damerau_levenshtein_distance(String a, int a_len, String b, int b_len)
{
	unreachable("sema stub: damerau_levenshtein_distance");
}

// sema_name_resolution.c:608 (static)
fn void find_closest(String name, int name_len, Decl*[] decls, int* count_ref, Decl** matches, int* best_distance_ref)
{
	unreachable("sema stub: find_closest");
}

// sema_name_resolution.c:650 (static)
fn int module_closest_ident_names(Module* module_, String name, Decl** matches)
{
	unreachable("sema stub: module_closest_ident_names");
}

// sema_name_resolution.c:666 (static)
fn void sema_report_error_on_decl(SemaContext* context, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_report_error_on_decl");
}

// sema_name_resolution.c:795 (static)
fn Module* sema_module_matches_path(SemaContext* context, Module* module_, ModulePath* path)
{
	unreachable("sema stub: sema_module_matches_path");
}

// sema_name_resolution.c:815 (static)
fn Module* sema_find_module_for_path(SemaContext* context, ModulePath* path)
{
	unreachable("sema stub: sema_find_module_for_path");
}

// sema_name_resolution.c:825 (static)
fn bool sema_has_matching_generic_params(Decl* generic_instance, Decl* generic)
{
	unreachable("sema stub: sema_has_matching_generic_params");
}

// sema_name_resolution.c:841 (static)
fn bool sema_resolve_symbol_common(SemaContext* context, NameResolve* name_resolve)
{
	unreachable("sema stub: sema_resolve_symbol_common");
}

// sema_name_resolution.c:957
fn Decl* sema_find_extension_method_in_list(Decl*[] extensions, Type* type, String method_name)
{
	unreachable("sema stub: sema_find_extension_method_in_list");
}

// sema_name_resolution.c:968
fn Decl* sema_resolve_method_only(Decl* type, String method_name)
{
	unreachable("sema stub: sema_resolve_method_only");
}

// sema_name_resolution.c:979
fn Decl* sema_resolve_method(Decl* type, String method_name)
{
	unreachable("sema stub: sema_resolve_method");
}

// sema_name_resolution.c:1000
fn bool sema_check_type_variable_array(SemaContext* context, TypeInfo* type_info)
{
	unreachable("sema stub: sema_check_type_variable_array");
}

// sema_name_resolution.c:1035
fn bool sema_resolve_type_decl(SemaContext* context, Type* type)
{
	unreachable("sema stub: sema_resolve_type_decl");
}

// sema_name_resolution.c:1082
fn Decl* sema_resolve_type_method(SemaContext* context, CanonicalType* type, String method_name)
{
	unreachable("sema stub: sema_resolve_type_method");
}

// sema_name_resolution.c:1131
fn Decl* sema_find_template_symbol(SemaContext* context, String symbol, ModulePath* path)
{
	unreachable("sema stub: sema_find_template_symbol");
}

// sema_name_resolution.c:1145
fn Decl* sema_find_symbol(SemaContext* context, String symbol)
{
	unreachable("sema stub: sema_find_symbol");
}

// sema_name_resolution.c:1155
fn Decl* sema_find_label_symbol(SemaContext* context, String symbol)
{
	unreachable("sema stub: sema_find_label_symbol");
}

// sema_name_resolution.c:1169
fn Decl* sema_find_label_symbol_anywhere(SemaContext* context, String symbol)
{
	unreachable("sema stub: sema_find_label_symbol_anywhere");
}

// sema_name_resolution.c:1183
fn BoolErr sema_symbol_is_defined_in_scope(SemaContext* c, String symbol)
{
	unreachable("sema stub: sema_symbol_is_defined_in_scope");
}

// sema_name_resolution.c:1201
fn Decl* sema_find_path_symbol(SemaContext* context, String symbol, ModulePath* path)
{
	unreachable("sema stub: sema_find_path_symbol");
}

// sema_name_resolution.c:1216
fn Decl* sema_resolve_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	unreachable("sema stub: sema_resolve_symbol");
}

// sema_name_resolution.c:1234
fn Decl* sema_resolve_parameterized_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	unreachable("sema stub: sema_resolve_parameterized_symbol");
}

// sema_name_resolution.c:1253
fn Decl* sema_resolve_generic_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	unreachable("sema stub: sema_resolve_generic_symbol");
}

// sema_name_resolution.c:1269
fn Decl* sema_resolve_maybe_parameterized_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	unreachable("sema stub: sema_resolve_maybe_parameterized_symbol");
}

// sema_name_resolution.c:1284
fn bool sema_parameterized_type_is_found(SemaContext* context, ModulePath* decl_path, String name, SourceLocId loc)
{
	unreachable("sema stub: sema_parameterized_type_is_found");
}

// sema_name_resolution.c:1296 (static)
fn void sema_append_local(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_append_local");
}

// sema_name_resolution.c:1317 (static)
fn bool sema_add_ct_local(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_add_ct_local");
}

// sema_name_resolution.c:1334
fn bool sema_add_local(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_add_local");
}

// sema_name_resolution.c:1359
fn void sema_unwrap_var(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_unwrap_var");
}

// sema_name_resolution.c:1369
fn void sema_rewrap_var(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_rewrap_var");
}

// sema_name_resolution.c:1375
fn void sema_erase_var(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_erase_var");
}

// sema_name_resolution.c:1384
fn void sema_erase_unwrapped(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_erase_unwrapped");
}
