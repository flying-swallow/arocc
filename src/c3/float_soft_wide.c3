// Software floating point core: generic unpack / round_pack for all five
// formats, f80/f128 arithmetic, f128 fused multiply-add, and the exact f128 hub
// conversions that KeyFloat.cast is built on.
//
// OWNER: plan 10 stage 1 agent 10.2 `wide-float`. Stage 0 fixed the signatures.
//
// Contract (see the header of float_value.c3 for the shared rules):
//   - No native float types (c3c has no f80, and native float128 is rejected).
//     uint128 integer arithmetic is allowed for significands.
//   - Reference for f128: Zig 0.17.0 compiler-rt (lib/compiler_rt/addf3.zig,
//     mulf3.zig, divtf3.zig, fma.zig, extendf.zig, truncf.zig): round to nearest
//     even, subnormals produced and consumed, overflow -> +-inf, default NaN
//     DEFAULT_NAN_F128 (positive), first NaN operand propagated quieted.
//   - Reference for f80: x87 with 64-bit precision control (correctly rounded to
//     a 64-bit significand, ties to even, f80 subnormals), default NaN
//     DEFAULT_NAN_F80 (negative real indefinite). The x87 rule for two NaN
//     operands (larger significand wins) is to be confirmed by the vectors agent.
//   - Every operation ORs IEEE flags into `*status` when it is not null:
//     INVALID (sNaN operand, inf-inf, 0*inf, 0/0, inf/inf), DIV_BY_ZERO (finite
//     nonzero / 0), OVERFLOW (rounded result exceeds the largest finite; result
//     inf for NEAREST_EVEN, largest finite for TOWARD_ZERO), UNDERFLOW (tiny after
//     rounding AND inexact), INEXACT. Exact results raise nothing.
//   - Signed zero: x + (-x) = +0 for NEAREST_EVEN (and TOWARD_ZERO); -0 + -0 = -0;
//     the sign of a zero product/quotient is the XOR of the operand signs.
module aro::float_value;
import aro::value_interner;

<*
 A float bit pattern split into class, sign and an exact (sig, exp) pair.
 For ZERO: sig = 0. For SUBNORMAL/NORMAL: value = (-1)^sign * sig * 2^exp exactly,
 sig being the integer significand with the implicit (or f80 explicit) integer bit
 included - not normalised to a fixed bit position. For INFINITE: sig = 0. For
 NAN: sig = the stored fraction field (payload incl. the quiet bit; f80 without
 the integer bit) and exp = 0.
*>
struct Unpacked
{
	FloatClass cls;
	bool sign;
	int exp;
	uint128 sig;
}

<* Split a value of any width (f80 non-canonical encodings classify as in float_value.c3). *>
fn Unpacked KeyFloat.unpack(self)
{
	unreachable("stage 0 stub");
}

<*
 Round the exact value (-1)^sign * (sig + (sticky ? delta : 0)) * 2^exp, where
 0 < delta < 1 stands for nonzero bits below sig's least significant bit, to the
 format `tag` with `rm`. sig may be any uint128 (including 0 -> signed zero) and
 exp any int; overflow, subnormal results, the f80 explicit integer bit and the
 status flags are handled here. This is the single rounding primitive every
 soft conversion and operation should use.
*>
fn KeyFloat round_pack(KeyFloatTag tag, bool sign, int exp, uint128 sig, bool sticky, RoundingMode rm = NEAREST_EVEN, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<*
 Exact conversion of any width to f128 (Zig @floatCast / compiler-rt extendf for
 the widening cases; f128 itself is returned unchanged). Every finite value of
 f16/f32/f64/f80 is representable. NaN: sign kept, payload shifted up into the
 top of the f128 fraction, quiet bit kept as is (extendf.zig does not quiet).
*>
fn F128Bits KeyFloat.to_f128(self)
{
	unreachable("stage 0 stub");
}

<*
 f128 -> `dest` with one rounding (compiler-rt truncf.zig for narrowing; F128
 returns x unchanged). NaN: sign kept, quiet bit set, top payload bits kept.
*>
fn KeyFloat from_f128(F128Bits x, KeyFloatTag dest, RoundingMode rm = NEAREST_EVEN, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f80 `a + b` (x87). *>
fn F80Bits f80_add(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f80 `a - b` (x87). *>
fn F80Bits f80_sub(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f80 `a * b` (x87). *>
fn F80Bits f80_mul(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f80 `a / b` (x87). *>
fn F80Bits f80_div(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f128 `a + b` (compiler-rt __addtf3). *>
fn F128Bits f128_add(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f128 `a - b` (compiler-rt __subtf3 = a + (-b)). *>
fn F128Bits f128_sub(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f128 `a * b` (compiler-rt __multf3). *>
fn F128Bits f128_mul(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<* Zig f128 `a / b` (compiler-rt __divtf3). *>
fn F128Bits f128_div(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}

<*
 Zig @mulAdd(f128, a, b, c) = a * b + c with a single rounding (compiler-rt
 fma.zig fmaq). Needed by Value.zig bigIntToFloat (a = 2^64).
*>
fn F128Bits f128_mul_add(F128Bits a, F128Bits b, F128Bits c, FloatStatus* status = null)
{
	unreachable("stage 0 stub");
}
