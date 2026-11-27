// Complex arithmetic algorithms from C99 Annex G: port of src/aro/annex_g.zig.
//
// OWNER: plan 10 stage 1 agent 10.5 `annex-g`. Stage 0 fixed the signatures.
//
// Contract:
//   - Written once over PrimitiveValue with the dispatching primitive_value float methods
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
//
// Porting notes (Zig -> C3):
//   - Zig `copysign(if (isInf(v)) @as(T, 1.0) else @as(T, 0.0), v)` is `box(v)`:
//     magnitude 1 or 0, sign of `v`.
//   - Zig literals `0` / `0.0` coerced to T are +0.0 (`primitive_value::zero(t)`).
//   - Zig `max_cd == 0` is `is_zero()` (max_cd is finite there, so not NaN).
//   - `-denom_logb` never overflows: denom_logb is int::min + 1 or the ilogb of
//     a finite nonzero value.
//   - The mul's third branch ("recover infinities from overflow") only rewrites
//     NaN operands to zero and does not set `recalc`, so x and y stay NaN. That
//     is the Zig behaviour (unlike C11 Annex G's _Cmultd); kept as is.
module aro::annex_g;
import aro::primitive_value;

<* Zig `copysign(if (isInf(v)) @as(T, 1.0) else @as(T, 0.0), v)`. *>
fn PrimitiveValue box(PrimitiveValue v)
{
	// if/else, not `?:`: see CONVENTIONS.md (c3c by-value aggregate ternary).
	PrimitiveValue mag;
	if (v.is_inf())
	{
		mag = primitive_value::one(v.tag);
	}
	else
	{
		mag = primitive_value::zero(v.tag);
	}
	return mag.copysign(v);
}

<* Zig `if (isNan(v)) v = copysign(@as(T, 0.0), v);` *>
fn PrimitiveValue nan_to_zero(PrimitiveValue v)
{
	if (v.is_nan()) return primitive_value::zero(v.tag).copysign(v);
	return v;
}

<*
 annex_g.complexFloatMul(T, a, b, c, d): (a + bi) * (c + di) with the Annex G
 infinity/NaN recovery. Returns { x, y } as a complex of the operands' width.
 @require a.tag == b.tag && a.tag == c.tag && a.tag == d.tag : "operands must have the same width"
*>
fn PrimitiveValue complex_float_mul(PrimitiveValue a, PrimitiveValue b, PrimitiveValue c, PrimitiveValue d)
{
	PrimitiveType t = a.tag;
	PrimitiveValue ac = a.mul(c);
	PrimitiveValue bd = b.mul(d);
	PrimitiveValue ad = a.mul(d);
	PrimitiveValue bc = b.mul(c);
	PrimitiveValue x = ac.sub(bd);
	PrimitiveValue y = ad.add(bc);
	if (x.is_nan() && y.is_nan())
	{
		bool recalc = false;
		if (a.is_inf() || b.is_inf())
		{
			// lhs infinite
			// Box the infinity and change NaNs in the other factor to 0
			a = box(a);
			b = box(b);
			c = nan_to_zero(c);
			d = nan_to_zero(d);
			recalc = true;
		}
		if (c.is_inf() || d.is_inf())
		{
			// rhs infinite
			// Box the infinity and change NaNs in the other factor to 0
			c = box(c);
			d = box(d);
			a = nan_to_zero(a);
			b = nan_to_zero(b);
			recalc = true;
		}
		if (!recalc && (ac.is_inf() || bd.is_inf() || ad.is_inf() || bc.is_inf()))
		{
			// Recover infinities from overflow by changing NaN's to 0
			a = nan_to_zero(a);
			b = nan_to_zero(b);
			c = nan_to_zero(c);
			d = nan_to_zero(d);
		}
		if (recalc)
		{
			PrimitiveValue inf_t = primitive_value::inf(t);
			x = inf_t.mul(a.mul(c).sub(b.mul(d)));
			y = inf_t.mul(a.mul(d).add(b.mul(c)));
		}
	}
	return primitive_value::complex_key(x, y);
}

<*
 annex_g.complexFloatDiv(T, a, b, c, d): (a + bi) / (c + di) with logb scaling and
 the Annex G infinity/NaN recovery. Returns { x, y } as a complex of the
 operands' width.
 @require a.tag == b.tag && a.tag == c.tag && a.tag == d.tag : "operands must have the same width"
*>
fn PrimitiveValue complex_float_div(PrimitiveValue a, PrimitiveValue b, PrimitiveValue c, PrimitiveValue d)
{
	PrimitiveType t = a.tag;
	int denom_logb = 0;
	PrimitiveValue max_cd = c.abs().max(d.abs());
	if (max_cd.is_finite())
	{
		if (max_cd.is_zero())
		{
			denom_logb = int::min + 1;
			c = primitive_value::zero(t);
			d = primitive_value::zero(t);
		}
		else
		{
			denom_logb = max_cd.ilogb();
			c = c.scalbn(-denom_logb);
			d = d.scalbn(-denom_logb);
		}
	}
	PrimitiveValue denom = c.mul(c).add(d.mul(d));
	PrimitiveValue x = a.mul(c).add(b.mul(d)).div(denom).scalbn(-denom_logb);
	PrimitiveValue y = b.mul(c).sub(a.mul(d)).div(denom).scalbn(-denom_logb);
	if (x.is_nan() && y.is_nan())
	{
		if (denom.is_positive_zero() && (!a.is_nan() || !b.is_nan()))
		{
			PrimitiveValue signed_inf = primitive_value::inf(t).copysign(c);
			x = signed_inf.mul(a);
			y = signed_inf.mul(b);
		}
		else if ((a.is_inf() || b.is_inf()) && c.is_finite() && d.is_finite())
		{
			a = box(a);
			b = box(b);
			PrimitiveValue inf_t = primitive_value::inf(t);
			x = inf_t.mul(a.mul(c).add(b.mul(d)));
			y = inf_t.mul(b.mul(c).sub(a.mul(d)));
		}
		else if (max_cd.is_inf() && a.is_finite() && b.is_finite())
		{
			c = box(c);
			d = box(d);
			PrimitiveValue zero_t = primitive_value::zero(t);
			x = zero_t.mul(a.mul(c).add(b.mul(d)));
			y = zero_t.mul(b.mul(c).sub(a.mul(d)));
		}
	}
	return primitive_value::complex_key(x, y);
}
