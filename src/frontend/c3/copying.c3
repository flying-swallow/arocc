// Sema contract stubs for c3c src/compiler/copying.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
// `copy_type_info_single` / `copy_attributes_single` exist as shallow
// stand-ins in parse_expr_support.c3 (the parser needs them); move them here
// when copying.c is ported.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* c3c's static `copy_struct`. *>
CopyStruct copy_struct;

// copying.c:23 (static)
fn void copy_reg_ref(CopyStruct* c, void* original, void* result)
{
	unreachable("sema stub: copy_reg_ref");
}

// copying.c:34 (static)
fn void* fixup(CopyStruct* c, void* original)
{
	unreachable("sema stub: fixup");
}

// copying.c:49 (static)
fn void fixup_decl(CopyStruct* c, Decl** decl_ref)
{
	unreachable("sema stub: fixup_decl");
}

// copying.c:57 (static)
fn void fixup_declid(CopyStruct* c, DeclId* declid_ref)
{
	unreachable("sema stub: fixup_declid");
}

// copying.c:66 (static)
fn void fixup_astid(CopyStruct* c, AstId* astid_ref)
{
	unreachable("sema stub: fixup_astid");
}

// copying.c:75 (static)
fn Expr*[] copy_expr_list(CopyStruct* c, Expr*[] expr_list)
{
	unreachable("sema stub: copy_expr_list");
}

// copying.c:82 (static)
fn DeclId decl_copy_label_from_macro(CopyStruct* c, DeclId to_copy, Ast* ast)
{
	unreachable("sema stub: decl_copy_label_from_macro");
}

// copying.c:91 (static)
fn void copy_flow(CopyStruct* c, Ast* ast)
{
	unreachable("sema stub: copy_flow");
}

// copying.c:96 (static)
fn TypeInfo*[] type_info_copy_list_from_macro(CopyStruct* c, TypeInfo*[] to_copy)
{
	unreachable("sema stub: type_info_copy_list_from_macro");
}

// copying.c:103 (static)
fn TypeInfoId type_info_id_copy_deep(CopyStruct* c, TypeInfoId source)
{
	unreachable("sema stub: type_info_id_copy_deep");
}

// copying.c:109 (static)
fn AstId astid_copy_deep(CopyStruct* c, AstId source)
{
	unreachable("sema stub: astid_copy_deep");
}

// copying.c:115 (static)
fn ExprId exprid_copy_deep(CopyStruct* c, ExprId source)
{
	unreachable("sema stub: exprid_copy_deep");
}

// copying.c:121 (static)
fn DeclId declid_copy_deep(CopyStruct* c, DeclId source)
{
	unreachable("sema stub: declid_copy_deep");
}

// copying.c:128 (static)
fn DesignatorElement*[] macro_copy_designator_list(CopyStruct* c, DesignatorElement*[] list)
{
	unreachable("sema stub: macro_copy_designator_list");
}

// copying.c:157
fn Ast* copy_ast_single(Ast* source_ast)
{
	unreachable("sema stub: copy_ast_single");
}

// copying.c:173
fn Ast* copy_ast_macro(Ast* source_ast)
{
	unreachable("sema stub: copy_ast_macro");
}

// copying.c:179
fn Ast* copy_ast_defer(Ast* source_ast)
{
	unreachable("sema stub: copy_ast_defer");
}

// copying.c:188
fn Expr* copy_expr_single(Expr* source_expr)
{
	unreachable("sema stub: copy_expr_single");
}

// copying.c:196
fn Expr*[] copy_exprlist_macro(Expr*[] source_expr_list)
{
	unreachable("sema stub: copy_exprlist_macro");
}

// copying.c:203
fn void copy_range(CopyStruct* c, ExprRange* range)
{
	unreachable("sema stub: copy_range");
}

// copying.c:223 (static)
fn ConstInitializer*[] copy_const_initializer_list(CopyStruct* c, ConstInitializer*[] initializer_list)
{
	unreachable("sema stub: copy_const_initializer_list");
}

// copying.c:234 (static)
fn void copy_const_initializer(CopyStruct* c, ConstInitializer** initializer_ref)
{
	unreachable("sema stub: copy_const_initializer");
}

// copying.c:267 (static)
fn Expr* copy_const_expr(CopyStruct* c, Expr* expr)
{
	unreachable("sema stub: copy_const_expr");
}

// copying.c:309 (static)
fn Expr* copy_expr(CopyStruct* c, Expr* source_expr)
{
	unreachable("sema stub: copy_expr");
}

// copying.c:627 (static)
fn void copy_expr_asm_arg(CopyStruct* c, ExprAsmArg* arg)
{
	unreachable("sema stub: copy_expr_asm_arg");
}

// copying.c:649 (static)
fn ExprAsmArg*[] copy_expr_asm_arg_list(CopyStruct* c, ExprAsmArg*[] args)
{
	unreachable("sema stub: copy_expr_asm_arg_list");
}

// copying.c:662 (static)
fn Ast* ast_copy_deep(CopyStruct* c, Ast* source)
{
	unreachable("sema stub: ast_copy_deep");
}

// copying.c:833 (static)
fn Ast*[] copy_ast_list(CopyStruct* c, Ast*[] to_copy)
{
	unreachable("sema stub: copy_ast_list");
}

// copying.c:840
fn void copy_begin()
{
	unreachable("sema stub: copy_begin");
}

// copying.c:848
fn void copy_end()
{
	unreachable("sema stub: copy_end");
}

// copying.c:854
fn Decl*[] copy_decl_list_macro(Decl*[] decl_list)
{
	unreachable("sema stub: copy_decl_list_macro");
}

// copying.c:860
fn Decl*[] copy_decl_list_single(Decl*[] decl_list)
{
	unreachable("sema stub: copy_decl_list_single");
}

// copying.c:868 (static)
fn Attr* copy_attribute(CopyStruct* c, Attr* attr)
{
	unreachable("sema stub: copy_attribute");
}

// copying.c:877 (static)
fn Attr*[] copy_attributes(CopyStruct* c, Attr*[] attr_list)
{
	unreachable("sema stub: copy_attributes");
}

// copying.c:889 (static)
fn ResolvedAttrData* copy_attrs_resolved(CopyStruct* c, ResolvedAttrData* data)
{
	unreachable("sema stub: copy_attrs_resolved");
}

// copying.c:914 (static)
fn void copy_rename_inner_types(Decl* decl, String prefix, int old_len)
{
	unreachable("sema stub: copy_rename_inner_types");
}

// copying.c:936
fn Decl*[] copy_decl_list_single_for_generic(Decl*[] decl_list, Decl* generic_instance)
{
	unreachable("sema stub: copy_decl_list_single_for_generic");
}

// copying.c:970
fn Decl* copy_lambda_deep(Decl* decl)
{
	unreachable("sema stub: copy_lambda_deep");
}

// copying.c:983 (static)
fn Decl*[] copy_decl_list(CopyStruct* c, Decl*[] decl_list)
{
	unreachable("sema stub: copy_decl_list");
}

// copying.c:990 (static)
fn Methods* copy_decl_methods(CopyStruct* c, Methods* methods)
{
	unreachable("sema stub: copy_decl_methods");
}

// copying.c:1003 (static)
fn TypeInfo* copy_type_info(CopyStruct* c, TypeInfo* source)
{
	unreachable("sema stub: copy_type_info");
}

// copying.c:1043 (static)
fn void copy_signature_deep(CopyStruct* c, Signature* signature)
{
	unreachable("sema stub: copy_signature_deep");
}

// copying.c:1048
fn void copy_decl_type(Decl* decl)
{
	unreachable("sema stub: copy_decl_type");
}

// copying.c:1061 (static)
fn bool decl_is_resolved_static_var(Decl* decl)
{
	unreachable("sema stub: decl_is_resolved_static_var");
}

// copying.c:1069 (static)
fn Decl* copy_decl(CopyStruct* c, Decl* decl)
{
	unreachable("sema stub: copy_decl");
}
