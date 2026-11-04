// Complex arithmetic algorithms from C99 Annex G: port of src/aro/annex_g.zig.
//
// OWNER: plan 10 stage 1 agent 10.5 `annex-g`. Stage 0 fixed the signatures.
//
// Contract:
//   - Written once over KeyFloat with the dispatching float_value methods
//     (mul/add/sub/div, is_nan/is_inf/is_finite/is_positive_zero, abs, copysign,
//     max, ilogb, scalbn, inf/zero/one constructors), so one body serves every
//     width; the four (or two) components always share one width. No native
//     floats.
//   - Every operation must be the same operation, in the same order, as the Zig
//     source (a*c, b*d, a*d, b*c, then x = ac - bd, y = ad + bc; recalc products
//     `inf(T) * (a * c - b * d)`; the division's denom_logb scaling with
//     scalbn(.., -denom_logb) and denom_logb = int::min + 1 for a zero
//     denominator; `0.0 * (...)` in the third recovery case), so intermediate
//     rounding and NaN propagation match bit for bit.
//   - Embedded Zig tests to port (source-derived expectations):
//       mul(f64: inf, nan, 2, 0) -> real is inf, imag is NaN;
//       div(f64: inf, nan, 2, 0) -> real is inf, imag is NaN;
//       div(f64: 2, 2, 0, 0)     -> both parts inf.
module aro::annex_g;
import aro::value_interner, aro::float_value;

<*
 annex_g.complexFloatMul(T, a, b, c, d): (a + bi) * (c + di) with the Annex G
 infinity/NaN recovery. Returns { x, y } as a complex of the operands' width.
 @require a.tag == b.tag && a.tag == c.tag && a.tag == d.tag : "operands must have the same width"
*>
fn KeyComplex complex_float_mul(KeyFloat a, KeyFloat b, KeyFloat c, KeyFloat d)
{
	unreachable("stage 0 stub");
}

<*
 annex_g.complexFloatDiv(T, a, b, c, d): (a + bi) / (c + di) with logb scaling and
 the Annex G infinity/NaN recovery. Returns { x, y } as a complex of the
 operands' width.
 @require a.tag == b.tag && a.tag == c.tag && a.tag == d.tag : "operands must have the same width"
*>
fn KeyComplex complex_float_div(KeyFloat a, KeyFloat b, KeyFloat c, KeyFloat d)
{
	unreachable("stage 0 stub");
}
