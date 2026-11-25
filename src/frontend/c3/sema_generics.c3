// Sema contract stubs for c3c src/compiler/sema_generics.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_generics.c:4 (static)
fn void mangle_type_param(Type* type, bool mangled)
{
	unreachable("sema stub: mangle_type_param");
}

// sema_generics.c:16 (static)
fn void sema_generate_parameter_suffix_to_scratch(Expr*[] params, bool mangled)
{
	unreachable("sema stub: sema_generate_parameter_suffix_to_scratch");
}

// sema_generics.c:102 (static)
fn bool sema_analyse_generic_module_contracts(SemaContext* c, Module* module_, Decl* instance, Expr*[] contracts, SourceLocId param_loc, SourceLocId invocation_loc)
{
	unreachable("sema stub: sema_analyse_generic_module_contracts");
}

// sema_generics.c:145 (static)
fn Decl* generate_parameterized_identifier(SemaContext* context, Decl* generic, Decl* alias_, Expr*[] params, Decl*[] param_decls, String suffix, String csuffix, SourceLocId invocation_loc, SourceLocId loc)
{
	unreachable("sema stub: generate_parameterized_identifier");
}

// sema_generics.c:369
fn Decl* sema_analyse_parameterized_identifier(SemaContext* context, ModulePath* decl_path, String name, SourceLocId loc, Expr*[] params, SourceLocId invocation_loc)
{
	unreachable("sema stub: sema_analyse_parameterized_identifier");
}

// sema_generics.c:455
fn Decl* sema_generate_parameterized_identifier(SemaContext* context, Decl* generic, Decl* alias_, Expr*[] params, Decl*[] param_decls, String suffix, String csuffix, SourceLocId invocation_loc, SourceLocId loc)
{
	unreachable("sema stub: sema_generate_parameterized_identifier");
}
