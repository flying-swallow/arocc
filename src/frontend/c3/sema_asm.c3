// Sema contract stubs for c3c src/compiler/sema_asm.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_asm.c:9 (static)
fn void sema_add_clobber(AsmInlineBlock* block, uint index)
{
	unreachable("sema stub: sema_add_clobber");
}

// sema_asm.c:15 (static)
fn void sema_add_clobbers(AsmInlineBlock* block, Clobbers* clobbers)
{
	unreachable("sema stub: sema_add_clobbers");
}

// sema_asm.c:23 (static)
fn Type* max_supported_imm_int(bool is_signed, AsmArgType arg)
{
	unreachable("sema stub: max_supported_imm_int");
}

// sema_asm.c:42 (static)
fn Decl* sema_resolve_external_symbol(SemaContext* context, Expr* expr, String name)
{
	unreachable("sema stub: sema_resolve_external_symbol");
}

// sema_asm.c:64 (static)
fn bool sema_reg_int_supported_type(AsmArgType arg, Type* type)
{
	unreachable("sema stub: sema_reg_int_supported_type");
}

// sema_asm.c:72 (static)
fn bool sema_reg_float_supported_type(AsmArgType arg, Type* type)
{
	unreachable("sema stub: sema_reg_float_supported_type");
}

// sema_asm.c:79 (static)
fn bool sema_check_npot_imm_fits(Int imm, AsmArgType arg_type)
{
	unreachable("sema stub: sema_check_npot_imm_fits");
}

// sema_asm.c:126 (static)
fn bool sema_check_asm_arg_const_int(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr, Expr* int_expr)
{
	unreachable("sema stub: sema_check_asm_arg_const_int");
}

// sema_asm.c:171 (static)
fn bool sema_check_asm_arg_addr(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_arg_addr");
}

// sema_asm.c:250 (static)
fn bool sema_check_asm_arg_reg(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_arg_reg");
}

// sema_asm.c:283 (static)
fn ExprAsmArg* asm_reg_find_decl(ExprAsmArg*[] args, Decl* decl, AsmArgKind kind)
{
	unreachable("sema stub: asm_reg_find_decl");
}

// sema_asm.c:292 (static)
fn void asm_reg_add_output(AsmInlineBlock* block, ExprAsmArg* arg)
{
	unreachable("sema stub: asm_reg_add_output");
}

// sema_asm.c:326 (static)
fn void asm_add_input(AsmInlineBlock* block, ExprAsmArg* arg)
{
	unreachable("sema stub: asm_add_input");
}

// sema_asm.c:334 (static)
fn void asm_reg_add_input(AsmInlineBlock* block, ExprAsmArg* arg)
{
	unreachable("sema stub: asm_reg_add_input");
}

// sema_asm.c:362 (static)
fn bool sema_check_asm_var(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_var");
}

// sema_asm.c:436 (static)
fn bool sema_check_asm_memvar(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_memvar");
}

// sema_asm.c:471 (static)
fn bool sema_check_asm_arg_addrof_var(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_arg_addrof_var");
}

// sema_asm.c:498 (static)
fn bool sema_check_asm_arg_value(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_arg_value");
}

// sema_asm.c:532 (static)
fn bool sema_check_asm_arg(SemaContext* context, AsmInlineBlock* block, AsmInstruction* instr, AsmArgType arg_type, Expr* expr)
{
	unreachable("sema stub: sema_check_asm_arg");
}

// sema_asm.c:555
fn bool sema_analyse_asm(SemaContext* context, AsmInlineBlock* block, Ast* asm_stmt)
{
	unreachable("sema stub: sema_analyse_asm");
}
