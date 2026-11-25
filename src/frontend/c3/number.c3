// Sema contract stubs for c3c src/compiler/number.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// number.c:14 (static)
fn bool compare_bool(bool left, bool right, BinaryOp op)
{
	unreachable("sema stub: compare_bool");
}

// number.c:34 (static)
fn bool compare_fps(Real left, Real right, BinaryOp op)
{
	unreachable("sema stub: compare_fps");
}

// number.c:54
fn void expr_contract_array(ExprConst* expr_const, ConstKind contract_type)
{
	unreachable("sema stub: expr_contract_array");
}

// number.c:101 (static)
fn bool const_is_bytes(ConstKind kind)
{
	unreachable("sema stub: const_is_bytes");
}

// number.c:106 (static)
fn ConstInitializer* expr_const_array_init_at(ConstInitializer* init, ArrayIndex index)
{
	unreachable("sema stub: expr_const_array_init_at");
}

// number.c:133 (static)
fn void swap_to_zero_to_left(ConstInitializer** left_ref, ConstInitializer** right_ref)
{
	unreachable("sema stub: swap_to_zero_to_left");
}

// number.c:144 (static)
fn bool expr_const_compare_bitstruct(ExprConst* left, ExprConst* right, BinaryOp op)
{
	unreachable("sema stub: expr_const_compare_bitstruct");
}

// number.c:181
fn bool expr_const_compare(ExprConst* left, ExprConst* right, BinaryOp op)
{
	unreachable("sema stub: expr_const_compare");
}

// number.c:325
fn bool expr_const_in_range(ExprConst* left, ExprConst* left_to, ExprConst* right, ExprConst* right_to)
{
	unreachable("sema stub: expr_const_in_range");
}

// number.c:332
fn bool expr_const_float_fits_type(ExprConst* expr_const, TypeKind kind)
{
	unreachable("sema stub: expr_const_float_fits_type");
}

// number.c:362
fn bool expr_const_will_overflow(ExprConst* expr, TypeKind kind)
{
	unreachable("sema stub: expr_const_will_overflow");
}

// number.c:393
fn void const_init_to_scratch_buffer(ConstInitializer* init)
{
	unreachable("sema stub: const_init_to_scratch_buffer");
}

// number.c:451
fn void expr_const_to_scratch_buffer(ExprConst* expr)
{
	unreachable("sema stub: expr_const_to_scratch_buffer");
}

// number.c:530
fn String expr_const_to_error_string(ExprConst* expr)
{
	unreachable("sema stub: expr_const_to_error_string");
}
