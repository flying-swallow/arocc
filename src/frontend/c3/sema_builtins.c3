// Sema contract stubs for c3c src/compiler/sema_builtins.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

enum BuiltinArg : char
{
	BA_POINTER,
	BA_SIZE,
	BA_BOOL,
	BA_CHAR,
	BA_FLOATLIKE,
	BA_INTEGER,
	BA_FLOAT,
	BA_INTLIKE,
	BA_NUMLIKE,
	BA_BOOLVEC,
	BA_BOOLINTVEC,
	BA_BOOLINT,
	BA_INTVEC,
	BA_FLOATVEC,
	BA_VEC,
	BA_NUMVEC,
	BA_PTRVEC,
	BA_NUM,
	BA_TYPEID,
}

// sema_builtins.c:42 (static)
fn bool sema_expr_is_valid_mask_for_value(SemaContext* context, Expr* expr, Expr* value)
{
	unreachable("sema stub: sema_expr_is_valid_mask_for_value");
}

// sema_builtins.c:55 (static)
fn bool sema_check_builtin_args_match(SemaContext* context, Expr*[] args, usz arg_len)
{
	unreachable("sema stub: sema_check_builtin_args_match");
}

// sema_builtins.c:72 (static)
fn bool sema_check_builtin_args_const(SemaContext* context, Expr*[] args, usz arg_len)
{
	unreachable("sema stub: sema_check_builtin_args_const");
}

// sema_builtins.c:81 (static)
fn bool sema_check_alignment_expression(SemaContext* context, Expr* align, bool may_be_zero)
{
	unreachable("sema stub: sema_check_alignment_expression");
}

// sema_builtins.c:96 (static)
fn bool sema_check_builtin_args(SemaContext* context, Expr*[] args, BuiltinArg* arg_type, usz arg_len)
{
	unreachable("sema stub: sema_check_builtin_args");
}

// sema_builtins.c:171 (static), renamed from c3c `sema_expr_analyse_swizzle`
fn bool sema_builtins_sema_expr_analyse_swizzle(SemaContext* context, Expr* expr, bool swizzle_two)
{
	unreachable("sema stub: sema_builtins_sema_expr_analyse_swizzle");
}

// sema_builtins.c:211 (static)
fn bool is_valid_atomicity(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: is_valid_atomicity");
}

// sema_builtins.c:221 (static)
fn bool sema_expr_analyse_compare_exchange(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_compare_exchange");
}

// sema_builtins.c:269 (static)
fn bool sema_expr_analyse_syscall(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_syscall");
}

// sema_builtins.c:300
fn ulong rand_u64()
{
	unreachable("sema stub: rand_u64");
}

// sema_builtins.c:305
fn bool sema_expr_analyse_rnd(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_rnd");
}

// sema_builtins.c:314 (static)
fn bool sema_expr_analyse_str_replace(SemaContext* context, Expr* expr, Expr* arg, Expr* pattern, Expr* replace, Expr* limit)
{
	unreachable("sema stub: sema_expr_analyse_str_replace");
}

// sema_builtins.c:381 (static)
fn bool sema_expr_analyse_str_hash(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_str_hash");
}

// sema_builtins.c:394
fn bool sema_expr_analyse_str_find(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_str_find");
}

// sema_builtins.c:414
fn bool sema_expr_analyse_str_conv(SemaContext* context, Expr* expr, BuiltinFunction func)
{
	unreachable("sema stub: sema_expr_analyse_str_conv");
}

// sema_builtins.c:526 (static)
fn uint utf8_to_codepoint(String data_ptr, int* inc)
{
	unreachable("sema stub: utf8_to_codepoint");
}

// sema_builtins.c:556
fn bool sema_expr_analyse_str_wide(SemaContext* context, Expr* expr, BuiltinFunction func)
{
	unreachable("sema stub: sema_expr_analyse_str_wide");
}

// sema_builtins.c:626 (static)
fn BinaryOp operator_from_builtin(BuiltinFunction fn_)
{
	unreachable("sema stub: operator_from_builtin");
}

// sema_builtins.c:640
fn bool sema_expr_analyse_builtin_call(SemaContext* context, Expr* expr)
{
	unreachable("sema stub: sema_expr_analyse_builtin_call");
}

// sema_builtins.c:1434 (static)
fn int builtin_expected_args(BuiltinFunction func)
{
	unreachable("sema stub: builtin_expected_args");
}
