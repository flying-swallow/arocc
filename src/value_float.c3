// Port of the float and complex parts of src/aro/Value.zig: floatToInt,
// intToFloat, floatCast, toFloat, imag, realPart / imaginaryPart, complexConj,
// isInf / isNan / isInfSign and the float/complex branches of add/sub/mul/div
// and compare.
//
// Layering: this file is the only place where a `Value` meets float semantics.
// Each operation reads the key(s) from `comp.interner`, calls the pure bit-level
// code in aro::primitive_value (primitive_float.c3, primitive_float_soft_*.c3,
// primitive_float_print.c3) or aro::annex_g, and interns the result. Nothing in
// aro::primitive_value knows about `Value`, `Compilation` or `QualType`.
//
// Interning note (value_interner.c3): float +0.0 interns as REF_ZERO and float
// 1.0 as REF_ONE, whose `get` is the *int* 0 / 1. So a float-typed Value may
// hold an int key; every function here that reads a Value accepts INT keys
// (Zig's toFloat / imag do).
module aro::value;
import aro::primitive_value, aro::annex_g;
import aro::compilation, aro::value_interner, aro::bigint, aro::type_store, aro::lang_opts;

<* Zig Value.FloatToIntChangeKind *>
enum FloatToIntChangeKind : char
{
	<* value did not change *>
	NONE,
	<* floating point number too small or large for destination integer type *>
	OUT_OF_RANGE,
	<* tried to convert a NaN or Infinity *>
	OVERFLOW,
	<* fractional value was converted to zero *>
	NONZERO_TO_ZERO,
	<* fractional part truncated *>
	VALUE_CHANGED,
}

<* Zig Value.IsInfKind (enum(i32)) *>
enum IsInfKind : int (int value)
{
	NEGATIVE { -1 },
	FINITE { 0 },
	POSITIVE { 1 },
	UNKNOWN { 0x7FFF_FFFF },
}

<* The four arithmetic operators of the float/complex branches. *>
enum FloatOp : char
{
	ADD,
	SUB,
	MUL,
	DIV,
}

<* Zig `switch (qt.bitSizeof(comp))` -> width tag. *>
fn PrimitiveType width_of(QualType qt, Compilation* comp) => primitive_value::float_tag_of_width(qt.bit_sizeof(comp));

<* Width of a complex type's element (`qt.childType(comp).bitSizeof(comp)`). *>
fn PrimitiveType element_width_of(QualType qt, Compilation* comp) => width_of(qt.child_type(comp), comp);

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

<*
 Value.toFloat(T): the real part of `self` as a `dest`-width float.
   int -> key_int_to_float; float -> PrimitiveValue.cast; complex -> real part cast.
 Precondition: self is not none and its key is INT, FLOAT or COMPLEX.
*>
fn PrimitiveValue Value.to_float(self, PrimitiveType dest, Compilation* comp)
{
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case INT: return primitive_value::key_int_to_float(key, dest);
		case FLOAT: return key.cast(dest);
		case COMPLEX: return key.re().cast(dest);
		default: unreachable("to_float of a non-arithmetic value");
	}
}

<*
 Value.imag(T): int/float -> +0.0; complex -> the imaginary part cast to `dest`.
*>
fn PrimitiveValue Value.imag(self, PrimitiveType dest, Compilation* comp)
{
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case INT:
		case FLOAT:
			return primitive_value::zero(dest);
		case COMPLEX:
			return key.im().cast(dest);
		default:
			unreachable("imag of a non-arithmetic value");
	}
}

<*
 Value.floatToInt: converts *v (int, float or complex - real part) to an integer
 of dest_ty. None stays none (returns NONE). In this order:
   f = to_float(*v, F128); was_zero = (f == 0).
   dest is bool: *v = from_bool(!was_zero); NONE if was_zero or f == 1.0, else
     VALUE_CHANGED (NaN: !was_zero -> true, VALUE_CHANGED).
   dest unsigned and f < 0 (not -0.0, not NaN): *v = ZERO, OUT_OF_RANGE.
   f not finite: *v = NONE, OVERFLOW.
   Otherwise big = trunc(f) (had_fraction), fits = big fits dest's two's
   complement width; *v = the UNTRUNCATED big (interned), then
   NONZERO_TO_ZERO if !was_zero and *v is zero, else OUT_OF_RANGE if !fits,
   else VALUE_CHANGED if had_fraction, else NONE.
 (Zig truncates a scratch copy after interning, so the stored value is not
 wrapped; that truncation has no observable effect and is not performed.)
*>
fn FloatToIntChangeKind Value.float_to_int(&v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return FloatToIntChangeKind.NONE;

	PrimitiveValue float_val = v.to_float(F128, comp);
	bool was_zero = float_val.is_zero();

	if (dest_ty.is(comp, BOOL))
	{
		PrimitiveValue one_val = primitive_value::one(F128);
		bool was_one = float_val.float_bits() == one_val.float_bits();
		*v = from_bool(!was_zero);
		if (was_zero || was_one) return FloatToIntChangeKind.NONE;
		return VALUE_CHANGED;
	}
	Signedness signedness = dest_ty.signedness(comp);
	if (signedness == UNSIGNED && float_val.signbit() && !float_val.is_zero() && !float_val.is_nan())
	{
		*v = ZERO;
		return OUT_OF_RANGE;
	}
	if (!float_val.is_finite())
	{
		*v = NONE;
		return OVERFLOW;
	}

	usz bits = (usz)dest_ty.bit_sizeof(comp);
	sz limb_len = primitive_value::calc_float_limb_len(float_val.f128());
	sz twos_len = bigint::calc_twos_comp_limb_count(bits);
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(limb_len > twos_len ? limb_len: twos_len));
	BigIntMutable big = mutable_over(limbs);
	bool had_fraction = primitive_value::f128_to_big_int_trunc(float_val.f128(), &big);

	bool fits = big.to_const().fits_in_twos_comp(signedness, bits);
	*v = intern_big(comp, big.to_const());

	if (!was_zero && v.is_zero(comp)) return NONZERO_TO_ZERO;
	if (!fits) return OUT_OF_RANGE;
	if (had_fraction) return VALUE_CHANGED;
	return FloatToIntChangeKind.NONE;
}

<*
 Value.intToFloat: none stays none. Complex dest: *v = { toFloat(child width), +0 }.
 Real dest: from the int key - u64/i64 -> from_u64/from_i64 at dest's bit width;
 big_int -> big_int_to_f128 then cast (double rounding kept).
*>
fn void Value.int_to_float(&v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return;

	if (dest_ty.is(comp, COMPLEX))
	{
		PrimitiveType w = element_width_of(dest_ty, comp);
		*v = intern(comp, primitive_value::complex_key(v.to_float(w, comp), primitive_value::zero(w)));
		return;
	}
	PrimitiveValue key = comp.interner.get(v.ref());
	assert(key.tag.kind == NumberKind.INT, "int_to_float of a non-int value");
	*v = intern(comp, primitive_value::key_int_to_float(key, width_of(dest_ty, comp)));
}

<*
 Value.floatCast: none stays none. Complex dest: { to_float(w), imag(w) } with
 w = the element width; real dest: to_float(dest width). Interned.
*>
fn void Value.float_cast(&v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return;
	if (try t = dest_ty.get(comp, COMPLEX))
	{
		PrimitiveType w = width_of(t.complex, comp);
		*v = intern(comp, primitive_value::complex_key(v.to_float(w, comp), v.imag(w, comp)));
		return;
	}
	*v = intern(comp, v.to_float(width_of(dest_ty, comp), comp));
}

<* Value.realPart: none -> none; int/float -> self; complex -> its real part as a float value. *>
fn Value Value.real_part(self, Compilation* comp)
{
	if (self.is_none()) return self;
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case INT:
		case FLOAT:
			return self;
		case COMPLEX:
			return intern(comp, key.re());
		default:
			unreachable("real_part of a non-arithmetic value");
	}
}

<* Value.imaginaryPart: none -> none; int/float -> ZERO; complex -> imaginary part as a float value. *>
fn Value Value.imaginary_part(self, Compilation* comp)
{
	if (self.is_none()) return self;
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case INT:
		case FLOAT:
			return ZERO;
		case COMPLEX:
			return intern(comp, key.im());
		default:
			unreachable("imaginary_part of a non-arithmetic value");
	}
}

<* Value.complexConj: { to_float(w), -imag(w) } (sign flip, also of +0 and NaN), w = qt's element width. *>
fn Value complex_conj(Value val, QualType qt, Compilation* comp)
{
	PrimitiveType w = element_width_of(qt, comp);
	return intern(comp, primitive_value::complex_key(val.to_float(w, comp), val.imag(w, comp).neg()));
}

// ---------------------------------------------------------------------------
// Arithmetic and comparison branches
// ---------------------------------------------------------------------------

<*
 Float/complex branch of Value.add/sub/mul/div (qt.scalar_kind is FLOAT or
 COMPLEX_FLOAT). Real: `op` on to_float(lhs, w) and to_float(rhs, w), w = qt's
 width (x/0 is inf or NaN, never an error). Complex, at the element width:
 add/sub componentwise (complexAddSub), mul/div through annex_g. Operand
 conversions happen in Zig's evaluation order (lhs.toFloat, lhs.imag,
 rhs.toFloat, rhs.imag); they are pure, so the order is not observable.
 Always returns false: no overflow is reported for floats.
*>
fn bool float_arith(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp, FloatOp op)
{
	if (qt.scalar_kind(comp) == COMPLEX_FLOAT)
	{
		PrimitiveType w = element_width_of(qt, comp);
		PrimitiveValue a = lhs.to_float(w, comp);
		PrimitiveValue b = lhs.imag(w, comp);
		PrimitiveValue c = rhs.to_float(w, comp);
		PrimitiveValue d = rhs.imag(w, comp);
		PrimitiveValue result;
		switch (op)
		{
			case ADD: result = primitive_value::complex_key(a.add(c), b.add(d));  // complexAddSub
			case SUB: result = primitive_value::complex_key(a.sub(c), b.sub(d));
			case MUL: result = annex_g::complex_float_mul(a, b, c, d);
			case DIV: result = annex_g::complex_float_div(a, b, c, d);
		}
		*res = intern(comp, result);
		return false;
	}
	PrimitiveType w = width_of(qt, comp);
	PrimitiveValue a = lhs.to_float(w, comp);
	PrimitiveValue b = rhs.to_float(w, comp);
	PrimitiveValue result;
	switch (op)
	{
		case ADD: result = a.add(b);
		case SUB: result = a.sub(b);
		case MUL: result = a.mul(b);
		case DIV: result = a.div(b);
	}
	*res = intern(comp, result);
	return false;
}

<*
 Float/complex branch of Value.compare, called after shallowCompare gave no
 answer and when at least one key is FLOAT or COMPLEX:
   either FLOAT: compare to_float(lhs, F128) with to_float(rhs, F128) using `op`.
   else either COMPLEX: assert(op == NEQ); return !(re equal) || !(im equal),
   comparing to_float(.., F128) and imag(.., F128) with EQ (so NaN parts make
   the values unequal).
*>
fn bool compare_float(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	PrimitiveType lhs_tag = comp.interner.get(lhs.ref()).tag;
	PrimitiveType rhs_tag = comp.interner.get(rhs.ref()).tag;
	if (lhs_tag.kind == NumberKind.FLOAT || rhs_tag.kind == NumberKind.FLOAT)
	{
		return lhs.to_float(F128, comp).compare(op, rhs.to_float(F128, comp));
	}
	assert(lhs_tag.kind == NumberKind.COMPLEX || rhs_tag.kind == NumberKind.COMPLEX, "value::compare_float needs a float or complex operand");
	assert(op == EQ || op == NEQ, "complex values only compare with == or !=");
	bool real_equal = lhs.to_float(F128, comp).compare(EQ, rhs.to_float(F128, comp));
	bool imag_equal = lhs.imag(F128, comp).compare(EQ, rhs.imag(F128, comp));
	bool equal = real_equal && imag_equal;
	return op == EQ ? equal : !equal;
}

// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

<* Value.isInf: none -> false; float -> isInf; complex -> either part isInf; else false. *>
fn bool Value.is_inf(self, Compilation* comp)
{
	if (self.is_none()) return false;
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case FLOAT: return key.is_inf();
		case COMPLEX: return key.re().is_inf() || key.im().is_inf();
		default: return false;
	}
}

<* Value.isNan: none -> false; float -> isNan; complex -> either part isNan; else false. *>
fn bool Value.is_nan(self, Compilation* comp)
{
	if (self.is_none()) return false;
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case FLOAT: return key.is_nan();
		case COMPLEX: return key.re().is_nan() || key.im().is_nan();
		default: return false;
	}
}

<*
 Value.isInfSign: none -> UNKNOWN; float -> POSITIVE / NEGATIVE / FINITE (NaN is
 FINITE); any other key (int included, e.g. a float 0.0 interned as REF_ZERO)
 -> UNKNOWN.
*>
fn IsInfKind Value.is_inf_sign(self, Compilation* comp)
{
	if (self.is_none()) return UNKNOWN;
	PrimitiveValue key = comp.interner.get(self.ref());
	if (key.tag.kind != NumberKind.FLOAT) return UNKNOWN;
	if (key.is_positive_inf()) return POSITIVE;
	if (key.is_negative_inf()) return NEGATIVE;
	return FINITE;
}
