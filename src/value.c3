// Port of the integer, byte and pointer parts of src/aro/Value.zig.
//
// Float/complex operations (floatToInt, intToFloat, floatCast, toFloat, imag,
// realPart/imaginaryPart, isInf/isNan/isInfSign, complexConj and the float
// branches of add/sub/mul/div/compare) are in value_float.c3 (same module); the
// pure bit-level float code they call is aro::primitive_value. `printString`
// (the `.bytes` arm of print) is not ported yet.
//
// Invariants implementers must keep:
//   - none vs null vs zero are three different values: `value::NONE` (no constant
//     value known; Zig `Value{}` / `.none`), `value::NULL` (the nullptr constant,
//     REF_NULL) and `value::ZERO` (int 0, REF_ZERO). A zero-initialized `Value {}`
//     is NOT none (it is item index 0): always start from `value::NONE`.
//   - Every value is interned in `comp.interner`; equal values share one ref, so
//     `opt_ref` equality is value equality (Zig `shallowCompare`).
//   - Integer results are arbitrary-width (`_BitInt` up to 65535 bits) and computed
//     with aro::bigint into scratch limbs allocated from `comp.gpa` and freed before
//     returning (Zig's `defer gpa.free`). No host 64/128-bit shortcuts.
//   - Overflow is returned exactly as Zig does: add/sub via addWrap/subWrap, mul/shl
//     as "!fitsInTwosComp then truncate", div as "!fitsInTwosComp" on the
//     *untruncated* quotient (which is then interned untruncated), pointer
//     arithmetic as mul_overflow || add_overflow.
//   - Pointer constants are (node, byte offset) identities (`KeyPointer`), never
//     host addresses. Arithmetic on them scales by the element size and keeps the
//     node; differences of pointers with different nodes are NONE; ordering
//     comparisons across nodes are unknown (`compare_pointers` faults).
//   - Bytes values never take part in arithmetic: add/sub yield NONE.
//   - Running out of memory panics; Zig's `!Value` (OOM only) is plain `Value`.
module aro::value;
import aro::primitive_value;
import aro::compilation, aro::value_interner, aro::bigint, aro::type_store, aro::lang_opts;
import aro::text_literal_semantics;
import std::core::dstring, std::io;

<* Zig `null` from toInt: none, not an int, or does not fit. *>
excuse NO_INT;
<* Zig `null` from comparePointers: the result is not known at compile time. *>
excuse NOT_COMPARABLE;

struct Value
{
	InternerOptRef opt_ref;
}

<* Zig `Value{}` / `.none`: no known constant value. *>
const Value NONE = { .opt_ref = value_interner::OPT_NONE };
const Value ZERO = { .opt_ref = value_interner::OPT_ZERO };
const Value ONE = { .opt_ref = value_interner::OPT_ONE };
<* Zig `Value.null`: the nullptr constant. *>
const Value NULL = { .opt_ref = value_interner::OPT_NULL };

fn bool Value.is_none(self) => self.opt_ref == value_interner::OPT_NONE;

<*
 Value.ref
 @require !self.is_none()
*>
fn InternerRef Value.ref(self) => self.opt_ref.unwrap();

<* Value.fromRef *>
fn Value from_ref(InternerRef r) => { .opt_ref = r.to_opt() };

<* A BigIntMutable over `limbs` (Zig `.{ .limbs = limbs, .positive = undefined, .len = undefined }`). *>
fn BigIntMutable mutable_over(Limb[] limbs) => { .limbs = limbs, .len = 1, .positive = true };

<* Intern a big int result. *>
fn Value intern_big(Compilation* comp, BigIntConst big) => intern(comp, primitive_value::big_int_key(big));

macro usz @bits_of(QualType qt, Compilation* comp) => (usz)qt.bit_sizeof(comp);

// ---------------------------------------------------------------------------
// Construction and queries
// ---------------------------------------------------------------------------

<* Value.intern: put `k` in comp.interner. *>
fn Value intern(Compilation* comp, PrimitiveValue k)
{
	InternerRef r = comp.interner.put(k);
	return from_ref(r);
}

<* Value.int for unsigned / comptime_int arguments (`.u64` key). *>
fn Value int_u64(ulong i, Compilation* comp) => intern(comp, primitive_value::int_key(i));

<* Value.int for signed arguments (`.i64` key). *>
fn Value int_i64(long i, Compilation* comp) => intern(comp, primitive_value::int_key(i));

<* Value.pointer *>
fn Value pointer(KeyPointer r, Compilation* comp) => intern(comp, { .tag = POINTER, .pointer = { .node = r.node, .offset = r.offset } });

<* Value.is: false for none, else whether the key has `tag`. *>
fn bool Value.is(self, PrimitiveType tag, Compilation* comp)
{
	if (self.is_none()) return false;
	return comp.interner.get(self.ref()).tag == tag;
}

<* False for none, else whether the key is a float. *>
fn bool Value.is_float(self, Compilation* comp)
{
	if (self.is_none()) return false;
	return comp.interner.get(self.ref()).tag.kind == NumberKind.FLOAT;
}

<* False for none, else whether the key is an integer. *>
fn bool Value.is_int(self, Compilation* comp)
{
	if (self.is_none()) return false;
	return comp.interner.get(self.ref()).tag.kind == NumberKind.INT;
}

<* Value.isArithmetic: int, float or complex. *>
fn bool Value.is_arithmetic(self, Compilation* comp)
{
	if (self.is_none()) return false;
	return comp.interner.get(self.ref()).tag.kind != NOT_NUMBER;
}

<* Value.isPointer *>
fn bool Value.is_pointer(self, Compilation* comp)
{
	if (self.is_none()) return false;
	return comp.interner.get(self.ref()).tag == POINTER;
}

<*
 Value.minUnsignedBits: bits needed to hold the value (0 -> 0, 255 -> 8).
 @require !self.is_none()
*>
fn usz Value.min_unsigned_bits(self, Compilation* comp)
{
	BigIntConst big = self.to_big_int(comp);
	assert(big.positive, "min_unsigned_bits of a negative value");
	return big.bit_count_abs();
}

<*
 Value.minSignedBits: two's-complement bits of a negative value (-1 -> 1, -128 -> 8).
 Asserts the value is negative.
*>
fn usz Value.min_signed_bits(self, Compilation* comp)
{
	BigIntConst big = self.to_big_int(comp);
	assert(!big.positive, "min_signed_bits of a non-negative value");
	return big.bit_count_twos_comp();
}

<* Value.toBigInt: the int value as a BigIntConst (small values live in `space`). *>
fn BigIntConst Value.to_big_int(self, Compilation* comp)
{
	PrimitiveValue key = comp.interner.get(self.ref());
	return key.to_big_int();
}

<* Value.IntCastChangeKind *>
enum IntCastChangeKind : char
{
	<* value did not change *>
	NONE,
	<* truncation occurred (e.g. i32 to i16) *>
	TRUNCATED,
	<* sign conversion occurred (e.g. i32 to u32) *>
	SIGN_CHANGED,
}

<*
 Value.intCast: truncate or extend to `dest_ty`'s bit size and signedness.
 None, pointer and bytes values are left unchanged (returns NONE).
*>
fn IntCastChangeKind Value.int_cast(&self, QualType dest_ty, Compilation* comp)
{
	if (self.is_none()) return NONE;
	PrimitiveValue key = comp.interner.get(self.ref());
	if (key.tag == POINTER || key.tag == BYTES) return NONE;

	usz dest_bits = @bits_of(dest_ty, comp);
	Signedness dest_signedness = dest_ty.signedness(comp);
	bool dest_signed = dest_signedness == SIGNED;

	BigIntConst big = key.to_big_int();
	usz value_bits = big.bit_count_twos_comp();

	// if big is negative, then is signed.
	bool src_signed = !big.positive;
	bool sign_change = src_signed != dest_signed;

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(value_bits > dest_bits ? value_bits : dest_bits)));

	BigIntMutable result = mutable_over(limbs);
	result.truncate(big, dest_signedness, dest_bits);

	*self = intern_big(comp, result.to_const());

	if (value_bits > dest_bits) return TRUNCATED;
	if (sign_change) return SIGN_CHANGED;
	return NONE;
}

<* Value.isZero: false for none; REF_NULL is zero iff the target's null repr is 0. *>
fn bool Value.is_zero(self, Compilation* comp)
{
	if (self.is_none()) return false;
	InternerRef r = self.ref();
	if (r == value_interner::REF_ZERO) return true;
	if (r == value_interner::REF_ONE) return false;
	if (r == value_interner::REF_NULL) return comp.target.null_repr() == 0;
	PrimitiveValue key = comp.interner.get(r);
	switch (key.tag.kind)
	{
		case FLOAT:
			return key.is_zero();
		case INT:
			return key.int_is_zero();
		case COMPLEX:
			return key.re().is_zero() && key.im().is_zero();
		case NOT_NUMBER:
			if (key.tag == BYTES || key.tag == POINTER) return false;
			unreachable("is_zero of a non-value key");
	}
}

<* Value.boolCast: becomes ZERO or ONE; none stays none. *>
fn void Value.bool_cast(&self, Compilation* comp)
{
	if (self.is_none()) return;
	*self = from_bool(self.to_bool(comp));
}

<* Value.fromBool *>
fn Value from_bool(bool b) => b ? ONE : ZERO;

<* Value.toBool: !is_zero. *>
fn bool Value.to_bool(self, Compilation* comp) => !self.is_zero(comp);

<*
 The int value of `self` as a BigIntConst (limbs in `space` for small values);
 NO_INT when none or not an int (first half of Zig toInt).
 @return? NO_INT
*>
fn BigIntConst? Value.int_big(self, Compilation* comp)
{
	if (self.is_none()) return NO_INT~;
	PrimitiveValue key = comp.interner.get(self.ref());
	if (key.tag.kind != NumberKind.INT) return NO_INT~;
	return key.to_big_int();
}

<*
 Value.toInt(u64)
 @return? NO_INT
*>
fn ulong? Value.to_u64(self, Compilation* comp)
{
	BigIntConst big = self.int_big(comp)!;
	if (try v = big.to_u64()) return v;
	return NO_INT~;
}

<*
 Value.toInt(i64)
 @return? NO_INT
*>
fn long? Value.to_i64(self, Compilation* comp)
{
	BigIntConst big = self.int_big(comp)!;
	if (try v = big.to_i64()) return v;
	return NO_INT~;
}

<*
 Value.toInt(u32) (used by `elem`)
 @return? NO_INT
*>
fn uint? Value.to_u32(self, Compilation* comp)
{
	BigIntConst big = self.int_big(comp)!;
	if (try v = big.to_u32()) return v;
	return NO_INT~;
}

<*
 Value.toInt(usize) (used by shl/shr). usz is 64 bits on every supported host.
 @return? NO_INT
*>
fn usz? Value.to_usz(self, Compilation* comp)
{
	$assert usz::size == ulong::size;
	return (usz)self.to_u64(comp)!;
}

<*
 Value.toBytes. The slice stays valid until the interner is freed.
 @require !self.is_none()
*>
fn char[] Value.to_bytes(self, Compilation* comp)
{
	PrimitiveValue key = comp.interner.get(self.ref());
	assert(key.tag == BYTES, "to_bytes of a non-bytes value");
	return key.bytes;
}

// ---------------------------------------------------------------------------
// Arithmetic. `res` may be the same Value as an operand. Bool results report
// overflow of the C operation in type `qt`.
// ---------------------------------------------------------------------------

<*
 Value.add: res = lhs + rhs in `qt`. Pointer + int scales the int by the pointee
 size (1 when unsized) in ptrdiff_t and keeps the node. Bytes operands give NONE.
*>
fn bool Value.add(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	ScalarKind scalar_kind = qt.scalar_kind(comp);
	if (scalar_kind.is_float) return float_arith(res, lhs, rhs, qt, comp, ADD);

	PrimitiveValue lhs_key = comp.interner.get(lhs.ref());
	PrimitiveValue rhs_key = comp.interner.get(rhs.ref());
	if (lhs_key.tag == BYTES || rhs_key.tag == BYTES)
	{
		*res = NONE;
		return false;
	}
	if (lhs_key.tag == POINTER || rhs_key.tag == POINTER)
	{
		KeyPointer rel = lhs_key.tag == POINTER ? lhs_key.pointer : rhs_key.pointer;
		Value index = lhs_key.tag == POINTER ? rhs : lhs;

		QualType ptrdiff = comp.type_store.ptrdiff;
		ulong size = qt.child_type(comp).sizeof_or_null(comp) ?? 1;
		Value elem_size = int_u64(size, comp);
		Value total_offset = NONE;
		bool mul_overflow = total_offset.mul(elem_size, index, ptrdiff, comp);
		Value old_offset = from_ref(rel.offset);
		bool add_overflow = total_offset.add(total_offset, old_offset, ptrdiff, comp);
		total_offset.int_cast(ptrdiff, comp);
		*res = pointer({ .node = rel.node, .offset = total_offset.ref() }, comp);
		return mul_overflow || add_overflow;
	}

	BigIntConst lhs_bigint = lhs_key.to_big_int();
	BigIntConst rhs_bigint = rhs_key.to_big_int();

	usz bits = @bits_of(qt, comp);
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(bits)));
	BigIntMutable result = mutable_over(limbs);

	bool overflowed = result.add_wrap(lhs_bigint, rhs_bigint, qt.signedness(comp), bits);
	*res = intern_big(comp, result.to_const());
	return overflowed;
}

<* Value.negate: res = 0 - val. *>
fn bool Value.negate(&res, Value val, QualType qt, Compilation* comp) => res.sub(ZERO, val, qt, comp);

<* Value.decrement: res = val - 1. *>
fn bool Value.decrement(&res, Value val, QualType qt, Compilation* comp) => res.sub(val, ONE, qt, comp);

<*
 Value.sub: res = lhs - rhs in `qt`. `elem_size` is only used for pointer - pointer
 (the byte difference is divided by it; Zig passes `undefined` otherwise) and for
 pointer - int scaling. Pointers with different nodes give NONE. Parameter order
 deviates from Zig (`elem_size` last, defaulted) so non-pointer callers omit it.
*>
fn bool Value.sub(&res, Value lhs, Value rhs, QualType qt, Compilation* comp, ulong elem_size = 0)
{
	ScalarKind scalar_kind = qt.scalar_kind(comp);
	if (scalar_kind.is_float) return float_arith(res, lhs, rhs, qt, comp, SUB);

	PrimitiveValue lhs_key = comp.interner.get(lhs.ref());
	PrimitiveValue rhs_key = comp.interner.get(rhs.ref());
	if (lhs_key.tag == BYTES || rhs_key.tag == BYTES)
	{
		*res = NONE;
		return false;
	}
	QualType ptrdiff = comp.type_store.ptrdiff;
	if (lhs_key.tag == POINTER && rhs_key.tag == POINTER)
	{
		KeyPointer lhs_pointer = lhs_key.pointer;
		KeyPointer rhs_pointer = rhs_key.pointer;
		if (lhs_pointer.node != rhs_pointer.node)
		{
			*res = NONE;
			return false;
		}
		Value lhs_offset = from_ref(lhs_pointer.offset);
		Value rhs_offset = from_ref(rhs_pointer.offset);
		bool overflowed = res.sub(lhs_offset, rhs_offset, ptrdiff, comp);
		Value rhs_size = int_u64(elem_size, comp);
		res.div(*res, rhs_size, ptrdiff, comp);
		return overflowed;
	}
	if (lhs_key.tag == POINTER)
	{
		KeyPointer rel = lhs_key.pointer;

		Value lhs_size = int_u64(elem_size, comp);
		Value total_offset = NONE;
		bool mul_overflow = total_offset.mul(lhs_size, rhs, ptrdiff, comp);
		Value old_offset = from_ref(rel.offset);
		bool add_overflow = total_offset.sub(old_offset, total_offset, ptrdiff, comp);
		total_offset.int_cast(ptrdiff, comp);
		*res = pointer({ .node = rel.node, .offset = total_offset.ref() }, comp);
		return mul_overflow || add_overflow;
	}

	BigIntConst lhs_bigint = lhs_key.to_big_int();
	BigIntConst rhs_bigint = rhs_key.to_big_int();

	usz bits = @bits_of(qt, comp);
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(bits)));
	BigIntMutable result = mutable_over(limbs);

	bool overflowed = result.sub_wrap(lhs_bigint, rhs_bigint, qt.signedness(comp), bits);
	*res = intern_big(comp, result.to_const());
	return overflowed;
}

<* Value.mul: exact product; overflow = !fits; result truncated when it overflows. *>
fn bool Value.mul(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	ScalarKind scalar_kind = qt.scalar_kind(comp);
	if (scalar_kind.is_float) return float_arith(res, lhs, rhs, qt, comp, MUL);

	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(lhs_bigint.limbs.len + rhs_bigint.limbs.len));
	BigIntMutable result = mutable_over(limbs);

	Limb[] limbs_buffer = alloc::new_array(tmem, Limb, (usz)(bigint::calc_mul_limbs_buffer_len(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1)));

	result.mul(lhs_bigint, rhs_bigint, limbs_buffer);

	usz bits = @bits_of(qt, comp);
	Signedness signedness = qt.signedness(comp);
	bool overflowed = !result.to_const().fits_in_twos_comp(signedness, bits);
	if (overflowed) result.truncate(result.to_const(), signedness, bits);
	*res = intern_big(comp, result.to_const());
	return overflowed;
}

<*
 Value.div: truncating division. Returns !fits for the quotient, which is interned
 untruncated (e.g. INT_MIN / -1). Caller guarantees rhs != 0.
*>
fn bool Value.div(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	ScalarKind scalar_kind = qt.scalar_kind(comp);
	if (scalar_kind.is_float) return float_arith(res, lhs, rhs, qt, comp, DIV);

	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	Limb[] limbs_q = alloc::new_array(tmem, Limb, (usz)lhs_bigint.limbs.len);
	BigIntMutable result_q = mutable_over(limbs_q);

	Limb[] limbs_r = alloc::new_array(tmem, Limb, (usz)rhs_bigint.limbs.len);
	BigIntMutable result_r = mutable_over(limbs_r);

	Limb[] limbs_buffer = alloc::new_array(tmem, Limb, (usz)(bigint::calc_div_limbs_buffer_len(lhs_bigint.limbs.len, rhs_bigint.limbs.len)));

	bigint::div_trunc(&result_q, &result_r, lhs_bigint, rhs_bigint, limbs_buffer);

	usz bits = @bits_of(qt, comp);
	*res = intern_big(comp, result_q.to_const());
	return !result_q.to_const().fits_in_twos_comp(qt.signedness(comp), bits);
}

<*
 Value.rem: C `%` (sign of lhs). Signed INT_MIN % -1 gives NONE. Caller guarantees
 rhs != 0.
*>
fn Value rem(Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	if (qt.signedness(comp) == SIGNED)
	{
		BigIntSpace[2] spaces;
		Value min_val = min_int(qt, comp);
		BigIntConst negative = bigint::init_i64(spaces[0].limbs[..], -1).to_const();
		BigIntConst big_one = bigint::init_i64(spaces[1].limbs[..], 1).to_const();
		if (compare(lhs, EQ, min_val, comp) && rhs_bigint.eql(negative))
		{
			return NONE;
		}
		if (rhs_bigint.order(big_one).compare(LT))
		{
			// lhs - @divTrunc(lhs, rhs) * rhs
			Value tmp = NONE;
			tmp.div(lhs, rhs, qt, comp);
			tmp.mul(tmp, rhs, qt, comp);
			tmp.sub(lhs, tmp, qt, comp);
			return tmp;
		}
	}

	Limb[] limbs_q = alloc::new_array(tmem, Limb, (usz)lhs_bigint.limbs.len);
	BigIntMutable result_q = mutable_over(limbs_q);

	Limb[] limbs_r = alloc::new_array(tmem, Limb, (usz)rhs_bigint.limbs.len);
	BigIntMutable result_r = mutable_over(limbs_r);

	Limb[] limbs_buffer = alloc::new_array(tmem, Limb, (usz)(bigint::calc_div_limbs_buffer_len(lhs_bigint.limbs.len, rhs_bigint.limbs.len)));

	bigint::div_trunc(&result_q, &result_r, lhs_bigint, rhs_bigint, limbs_buffer);
	return intern_big(comp, result_r.to_const());
}

<* Value.bitOr (infinite two's complement). *>
fn Value bit_or(Value lhs, Value rhs, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	sz n = lhs_bigint.limbs.len > rhs_bigint.limbs.len ? lhs_bigint.limbs.len : rhs_bigint.limbs.len;
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)n);
	BigIntMutable result = mutable_over(limbs);

	result.bit_or(lhs_bigint, rhs_bigint);
	return intern_big(comp, result.to_const());
}

<* Value.bitXor *>
fn Value bit_xor(Value lhs, Value rhs, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	sz extra = lhs_bigint.positive != rhs_bigint.positive ? 1 : 0;
	sz n = lhs_bigint.limbs.len > rhs_bigint.limbs.len ? lhs_bigint.limbs.len : rhs_bigint.limbs.len;
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(n + extra));
	BigIntMutable result = mutable_over(limbs);

	result.bit_xor(lhs_bigint, rhs_bigint);
	return intern_big(comp, result.to_const());
}

<* Value.bitAnd *>
fn Value bit_and(Value lhs, Value rhs, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	BigIntConst rhs_bigint = rhs.to_big_int(comp);

	sz a_len = lhs_bigint.limbs.len;
	sz b_len = rhs_bigint.limbs.len;
	sz limb_count;
	if (lhs_bigint.positive && rhs_bigint.positive)
	{
		limb_count = a_len < b_len ? a_len : b_len;
	}
	else if (lhs_bigint.positive)
	{
		limb_count = a_len;
	}
	else if (rhs_bigint.positive)
	{
		limb_count = b_len;
	}
	else
	{
		limb_count = (a_len > b_len ? a_len : b_len) + 1;
	}

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)limb_count);
	BigIntMutable result = mutable_over(limbs);

	result.bit_and(lhs_bigint, rhs_bigint);
	return intern_big(comp, result.to_const());
}

<* Value.bitNot: ~val wrapped to `qt`. *>
fn Value bit_not(Value val, QualType qt, Compilation* comp)
{
	usz bits = @bits_of(qt, comp);
	BigIntConst val_bigint = val.to_big_int(comp);

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(bits)));
	BigIntMutable result = mutable_over(limbs);

	result.bit_not_wrap(val_bigint, qt.signedness(comp), bits);
	return intern_big(comp, result.to_const());
}

<*
 Value.shl: res = lhs << rhs. A shift that is not a usz or exceeds the bit size
 gives max_int (lhs >= 0) / min_int (lhs < 0) and overflow. Otherwise overflow =
 !fits, truncating when it overflows.
*>
fn bool Value.shl(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	usz shift = rhs.to_usz(comp) ?? usz::max;

	usz bits = @bits_of(qt, comp);
	if (shift > bits)
	{
		*res = lhs_bigint.positive ? max_int(qt, comp) : min_int(qt, comp);
		return true;
	}

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(lhs_bigint.limbs.len + (sz)(shift / bigint::LIMB_BITS) + 1));
	BigIntMutable result = mutable_over(limbs);

	result.shift_left(lhs_bigint, shift);
	Signedness signedness = qt.signedness(comp);
	bool overflowed = !result.to_const().fits_in_twos_comp(signedness, bits);
	if (overflowed) result.truncate(result.to_const(), signedness, bits);
	*res = intern_big(comp, result.to_const());
	return overflowed;
}

<*
 Value.shr: arithmetic shift right (floor). A shift that is not a usz gives ZERO;
 shifting out every limb gives ZERO or -1 by sign.
*>
fn Value shr(Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	BigIntConst lhs_bigint = lhs.to_big_int(comp);
	usz? shift_opt = rhs.to_usz(comp);
	if (catch shift_opt) return ZERO;
	usz shift = shift_opt;

	// Zig `lhs_bigint.limbs.len -| (shift / limb_bits)` (saturating subtraction).
	usz a_len = (usz)lhs_bigint.limbs.len;
	usz shifted_limbs = shift / bigint::LIMB_BITS;
	if (shifted_limbs >= a_len)
	{
		// The shift is enough to remove all the bits from the number, which means the
		// result is 0 or -1 depending on the sign.
		if (lhs_bigint.positive) return ZERO;
		return int_i64(-1, comp);
	}

	usz bits = @bits_of(qt, comp);
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(bits)));
	BigIntMutable result = mutable_over(limbs);

	result.shift_right(lhs_bigint, shift);
	return intern_big(comp, result.to_const());
}

// ---------------------------------------------------------------------------
// Comparison and limits
// ---------------------------------------------------------------------------

<*
 Value.shallowCompare: EQ compares refs; equal refs satisfy `op` as EQ; otherwise
 unknown (NOT_COMPARABLE).
 @return? NOT_COMPARABLE
*>
fn bool? shallow_compare(Value lhs, CompareOperator op, Value rhs)
{
	if (op == EQ) return lhs.opt_ref == rhs.opt_ref;
	if (lhs.opt_ref == rhs.opt_ref) return BigIntOrder.EQ.compare(op);
	return NOT_COMPARABLE~;
}

<* Value.compare (float/complex branches: compare_float in value_float.c3). *>
fn bool compare(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	if (try shallow = shallow_compare(lhs, op, rhs)) return shallow;

	PrimitiveValue lhs_key = comp.interner.get(lhs.ref());
	PrimitiveValue rhs_key = comp.interner.get(rhs.ref());
	if (lhs_key.tag.kind == NumberKind.FLOAT || rhs_key.tag.kind == NumberKind.FLOAT || lhs_key.tag.kind == NumberKind.COMPLEX || rhs_key.tag.kind == NumberKind.COMPLEX)
	{
		return compare_float(lhs, op, rhs, comp);
	}

	BigIntConst lhs_bigint = lhs_key.to_big_int();
	BigIntConst rhs_bigint = rhs_key.to_big_int();
	return lhs_bigint.order(rhs_bigint).compare(op);
}

<*
 Value.comparePointers: equal refs compare by `op` on EQ; same node compares the
 offsets; different nodes are false for EQ, true for NEQ, and unknown otherwise.
 @return? NOT_COMPARABLE
*>
fn bool? compare_pointers(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	if (lhs.is_none() || rhs.is_none()) return NOT_COMPARABLE~;
	if (try shallow = shallow_compare(lhs, op, rhs)) return shallow;

	PrimitiveValue lhs_key = comp.interner.get(lhs.ref());
	PrimitiveValue rhs_key = comp.interner.get(rhs.ref());

	if (lhs_key.tag == POINTER && rhs_key.tag == POINTER)
	{
		KeyPointer lhs_pointer = lhs_key.pointer;
		KeyPointer rhs_pointer = rhs_key.pointer;
		if (lhs_pointer.node != rhs_pointer.node)
		{
			switch (op)
			{
				case EQ: return false;
				case NEQ: return true;
				default: return NOT_COMPARABLE~;
			}
		}

		Value lhs_offset = from_ref(lhs_pointer.offset);
		Value rhs_offset = from_ref(rhs_pointer.offset);
		return compare(lhs_offset, op, rhs_offset, comp);
	}
	return NOT_COMPARABLE~;
}

<* Value.twosCompIntLimit *>
fn Value twos_comp_int_limit(TwosCompIntLimit limit, QualType qt, Compilation* comp)
{
	Signedness signedness = qt.signedness(comp);
	if (limit == MIN && signedness == UNSIGNED) return ZERO;
	usz mag_bits = @bits_of(qt, comp);
	switch (mag_bits)
	{
		case 8:
		case 16:
		case 32:
		case 64:
			// Zig: Value.int(@as(i64, minInt(iN))) / Value.int(maxInt(iN or uN)); the
			// signedness of the Zig argument picks the .i64 or .u64 key.
			if (limit == MIN) return int_i64(mag_bits == 64 ? long::min : -((long)1 << (mag_bits - 1)), comp);
			if (signedness == SIGNED) return int_i64(mag_bits == 64 ? long::max : ((long)1 << (mag_bits - 1)) - 1, comp);
			return int_u64(mag_bits == 64 ? ulong::max : ((ulong)1 << mag_bits) - 1, comp);
		default:
			break;
	}

	usz sign_bits = signedness == SIGNED ? 1 : 0;
	usz total_bits = mag_bits + sign_bits;

	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_twos_comp_limb_count(total_bits)));

	BigIntMutable result = mutable_over(limbs);
	result.set_twos_comp_int_limit(limit, signedness, mag_bits);
	return intern_big(comp, result.to_const());
}

<* Value.minInt: smallest value of integer type `qt` (ZERO for unsigned). *>
fn Value min_int(QualType qt, Compilation* comp) => twos_comp_int_limit(MIN, qt, comp);

<* Value.maxInt: largest value of integer type `qt`. *>
fn Value max_int(QualType qt, Compilation* comp) => twos_comp_int_limit(MAX, qt, comp);

<*
 Value.elem: element `index` of a bytes value as an int (NONE when out of range,
 not bytes, or the index is not a u32). Keeps Zig's `index > len` bound check.
*>
fn Value elem(Value arr, Value index, Compilation* comp)
{
	uint? index_opt = index.to_u32(comp);
	if (catch index_opt) return NONE;
	uint index_int = index_opt;
	if (arr.is_none()) return NONE;
	PrimitiveValue key = comp.interner.get(arr.ref());
	if (key.tag != BYTES) return NONE;
	char[] b = key.bytes;
	if ((sz)index_int > b.len) return NONE;
	return int_u64(b[index_int], comp);
}

// ---------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------

<* Zig `NestedPrint` (only `.pointer`): returned by print for pointer values. *>
struct NestedPrint
{
	uint node;
	Value offset;
}

<*
 Value.print: appends `v` (of type `qt`) to `w`. Returns true and sets `*nested`
 for a pointer value (Zig `?NestedPrint` non-null); the caller prints the base
 and then calls print_pointer. The `.bytes` arm is Zig printString
 (text_literal_semantics::print_string, quoted).
 @require !self.is_none()
*>
fn bool? Value.print(self, QualType qt, Compilation* comp, OutStream w, NestedPrint* nested = null)
{
	if (qt.is(comp, BOOL))
	{
		w.write(self.is_zero(comp) ? "false" : "true")!;
		return false;
	}
	PrimitiveValue key = comp.interner.get(self.ref());
	switch (key.tag.kind)
	{
		case INT:
			io::fprintf(w, "%s", key)!;
			return false;
		case FLOAT:
			primitive_value::print_float(key, w)!;
			return false;
		case COMPLEX:
			primitive_value::print_complex(key, w)!;
			return false;
		case NOT_NUMBER:
			break;
	}
	switch (key.tag)
	{
		case NULL:
			w.write("nullptr_t")!;
		case POINTER:
			if (nested) *nested = { .node = key.pointer.node, .offset = from_ref(key.pointer.offset) };
			return true;
		case BYTES:
			text_literal_semantics::print_string(key.bytes, qt, comp, w)!;
		default:
			unreachable("Value.print of a non-value key");
	}
	return false;
}

<* Value.printPointer: "&" ++ base, then the offset (in ptrdiff_t) unless it is zero. *>
fn void? print_pointer(Value offset, String base, Compilation* comp, OutStream w)
{
	w.write_byte('&')!;
	w.write(base)!;
	if (!offset.is_zero(comp))
	{
		bool nested = offset.print(comp.type_store.ptrdiff, comp, w)!;
		assert(!nested);
	}
}
