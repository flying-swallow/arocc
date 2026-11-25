// Sema contract stubs for c3c src/compiler/sema_passes.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_passes.c:8
fn void parent_path(StringSlice* slice)
{
	unreachable("sema stub: parent_path");
}

// sema_passes.c:22
fn void sema_analyse_pass_module_hierarchy(Module* module_)
{
	unreachable("sema stub: sema_analyse_pass_module_hierarchy");
}

// sema_passes.c:52
fn void sema_analyse_pass_remove_feat_conditionals(Module* module_)
{
	unreachable("sema stub: sema_analyse_pass_remove_feat_conditionals");
}

// sema_passes.c:75
fn void sema_analysis_pass_process_imports(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_process_imports");
}

// sema_passes.c:185 (static)
fn bool sema_check_if_implicit_generic(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_check_if_implicit_generic");
}

// sema_passes.c:202
fn void unit_register_optional_global_decl(CompilationUnit* unit, Decl* decl)
{
	unreachable("sema stub: unit_register_optional_global_decl");
}

// sema_passes.c:227 (static)
fn void register_global_decls(CompilationUnit* unit, Decl*[] decls)
{
	unreachable("sema stub: register_global_decls");
}

// sema_passes.c:236 (static)
fn SourceFile* sema_load_file(CompilationUnit* unit, Expr* filename)
{
	unreachable("sema stub: sema_load_file");
}

// sema_passes.c:261 (static)
fn Decl*[] sema_load_include(CompilationUnit* unit, Decl* decl)
{
	unreachable("sema stub: sema_load_include");
}

// sema_passes.c:288 (static)
fn bool exec_arg_append_to_scratch(Expr* arg)
{
	unreachable("sema stub: exec_arg_append_to_scratch");
}

// sema_passes.c:336 (static)
fn Decl*[] sema_run_exec(CompilationUnit* unit, Decl* decl)
{
	unreachable("sema stub: sema_run_exec");
}

// sema_passes.c:426 (static)
fn Decl*[] sema_interpret_expand(CompilationUnit* unit, Decl* decl)
{
	unreachable("sema stub: sema_interpret_expand");
}

// sema_passes.c:455 (static)
fn void register_includes(CompilationUnit* unit, Decl*[] decls)
{
	unreachable("sema stub: register_includes");
}

// sema_passes.c:488
fn void sema_process_includes(CompilationUnit* unit)
{
	unreachable("sema stub: sema_process_includes");
}

// sema_passes.c:500
fn void sema_analysis_pass_register_global_declarations(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_register_global_declarations");
}

// sema_passes.c:514
fn void sema_analysis_pass_process_includes(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_process_includes");
}

// sema_passes.c:528
fn void sema_analysis_pass_process_methods(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_process_methods");
}

// sema_passes.c:569
fn void sema_analysis_pass_process_method_specialization()
{
	unreachable("sema stub: sema_analysis_pass_process_method_specialization");
}

// sema_passes.c:603
fn void sema_analysis_pass_process_late_generics()
{
	unreachable("sema stub: sema_analysis_pass_process_late_generics");
}

// sema_passes.c:629
fn void sema_analysis_pass_register_conditional_units_and_decls(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_register_conditional_units_and_decls");
}

// sema_passes.c:748
fn void sema_analysis_pass_ct_assert(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_ct_assert");
}

// sema_passes.c:770
fn void sema_analysis_pass_ct_echo(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_ct_echo");
}

// sema_passes.c:792
fn bool analyse_func_body(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: analyse_func_body");
}

// sema_passes.c:833
fn void sema_analyse_inner_func_ptr(SemaContext* c, Decl* decl)
{
	unreachable("sema stub: sema_analyse_inner_func_ptr");
}

// sema_passes.c:853 (static)
fn void sema_analyse_weak_decls(SemaContext* context, Decl*[] decls)
{
	unreachable("sema stub: sema_analyse_weak_decls");
}

// sema_passes.c:876 (static)
fn void sema_analyse_decls(SemaContext* context, Decl*[] decls)
{
	unreachable("sema stub: sema_analyse_decls");
}

// sema_passes.c:894
fn void sema_analysis_pass_decls(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_decls");
}

// sema_passes.c:933
fn void sema_analysis_pass_lambda(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_lambda");
}

// sema_passes.c:954 (static)
fn bool sema_check_interface(SemaContext* context, Decl* decl, TypeInfo* interface_type, TypeInfo* original_type)
{
	unreachable("sema stub: sema_check_interface");
}

// sema_passes.c:993
fn bool sema_check_interfaces(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_check_interfaces");
}

// sema_passes.c:1009
fn void sema_analysis_pass_interface_and_weak_sym(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_interface_and_weak_sym");
}

// sema_passes.c:1043
fn void sema_analysis_pass_functions(Module* module_)
{
	unreachable("sema stub: sema_analysis_pass_functions");
}
