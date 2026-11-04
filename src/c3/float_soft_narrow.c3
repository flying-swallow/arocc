// f16/f32/f64 arithmetic and the width-generic std.math helpers used by Annex G.
//
// OWNER: plan 10 stage 1 agent 10.1 `narrow-float`. Stage 0 fixed the signatures.
//
// Contract (see the header of float_value.c3 for the shared rules):
//   - Operands and results are raw IEEE bit patterns (ushort / uint / ulong).
//   - Per the native capability decision, f16/f32/f64 + - * / may use c3c's
//     float16/float/double (bitcast in, operate, bitcast out); this is the only
//     production file allowed to use native float types. Results must equal the
//     reference (x86_64 Zig: SSE for f32/f64; f16 computed in f32 and rounded
//     once to half), ties to even, subnormals kept.
//   - NaN results follow float_value.c3's NaN rules: an invalid operation gives
//     DEFAULT_NAN_F16/F32/F64, a NaN operand propagates (first NaN operand,
//     quieted, payload kept). Native x86 already behaves like this; route NaN
//     cases through those constants anyway so a vectors-confirmed change to the
//     constants applies everywhere.
//   - The width-generic helpers (ilogb, scalbn, max) operate on bits for all five
//     widths, f80 included (explicit integer bit), and are exact ports of Zig
//     0.17.0 lib/std/math/ilogb.zig, lib/std/math/ldexp.zig (scalbn is an alias
//     of ldexp) and the @max builtin. They must not use native floats.
module aro::float_value;
import aro::value_interner;

<* Zig f16 `a + b` *>
fn ushort f16_add(ushort a, ushort b)
{
	unreachable("stage 0 stub");
}

<* Zig f16 `a - b` *>
fn ushort f16_sub(ushort a, ushort b)
{
	unreachable("stage 0 stub");
}

<* Zig f16 `a * b` *>
fn ushort f16_mul(ushort a, ushort b)
{
	unreachable("stage 0 stub");
}

<* Zig f16 `a / b` (x/0 -> +-inf, 0/0 -> DEFAULT_NAN_F16) *>
fn ushort f16_div(ushort a, ushort b)
{
	unreachable("stage 0 stub");
}

<* Zig f32 `a + b` *>
fn uint f32_add(uint a, uint b)
{
	unreachable("stage 0 stub");
}

<* Zig f32 `a - b` *>
fn uint f32_sub(uint a, uint b)
{
	unreachable("stage 0 stub");
}

<* Zig f32 `a * b` *>
fn uint f32_mul(uint a, uint b)
{
	unreachable("stage 0 stub");
}

<* Zig f32 `a / b` *>
fn uint f32_div(uint a, uint b)
{
	unreachable("stage 0 stub");
}

<* Zig f64 `a + b` *>
fn ulong f64_add(ulong a, ulong b)
{
	unreachable("stage 0 stub");
}

<* Zig f64 `a - b` *>
fn ulong f64_sub(ulong a, ulong b)
{
	unreachable("stage 0 stub");
}

<* Zig f64 `a * b` *>
fn ulong f64_mul(ulong a, ulong b)
{
	unreachable("stage 0 stub");
}

<* Zig f64 `a / b` *>
fn ulong f64_div(ulong a, ulong b)
{
	unreachable("stage 0 stub");
}

<*
 std.math.ilogb(x) (Zig 0.17.0 lib/std/math/ilogb.zig), any width:
   +-0 -> int::min (fp_ilogb0); NaN -> int::min (fp_ilogbnan); +-inf -> int::max;
   subnormal -> the exponent of its leading one bit (f80 counts the explicit
   integer bit, as ilogbX does with @intFromBool(T == f80)); normal -> e - bias.
*>
fn int KeyFloat.ilogb(self)
{
	unreachable("stage 0 stub");
}

<*
 std.math.scalbn(x, n) = std.math.ldexp(x, n) (Zig 0.17.0 lib/std/math/ldexp.zig),
 any width, bit-exact including its own rounding of subnormal results (the
 `exact_tie` / (result + 1) >> 1 step) and "severe underflow" -> signed zero.
 NaN and +-inf are returned unchanged; overflow -> +-inf. Annex G calls it with
 n = -(int::min + 1) (= int::max) on a NaN/inf quotient, which must not overflow
 any intermediate.
*>
fn KeyFloat KeyFloat.scalbn(self, int n)
{
	unreachable("stage 0 stub");
}

<*
 Zig @max(a, b) on floats (LLVM maxnum): if exactly one operand is NaN the other
 is returned; if both are NaN a NaN is returned (DEFAULT_NAN rules do not apply;
 return `self` quieted). Operands that compare equal (including +0 vs -0, which
 Zig leaves unspecified; Annex G only passes absolute values) return `self`.
 Otherwise the larger value.
 @require self.tag == other.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.max(self, KeyFloat other)
{
	unreachable("stage 0 stub");
}
