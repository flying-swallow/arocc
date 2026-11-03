// Port of the parts of Zig's std.math.big.int (Const / Mutable) that Aro uses:
// src/aro/Value.zig, src/backend/Interner.zig and Parser.zig bitInt (setString).
//
// OWNER: plan 09 stage 1 agent 09.2 `bigint`. Stage 0 (contract) fixed the types and
// signatures below; bodies are stubs that panic with "stage 0 stub".
//
// Representation (same as Zig, so ported call sites keep their buffer arithmetic):
//   - Sign-magnitude. `limbs` are little-endian 64-bit `Limb`s of the magnitude.
//   - A *normalized* value has no leading (most significant) zero limbs, and zero is
//     exactly one limb `0` with `positive == true`. Every function that produces a
//     result (`BigIntMutable` methods) leaves it normalized; every function reading a
//     `BigIntConst` may assume it is normalized. The interner hashes and compares
//     limbs directly, so a non-normalized value would break deduplication.
//   - Negative zero never escapes: a zero result always has `positive == true`.
//
// Invariants implementers must keep:
//   - Arbitrary width. No host `int128`/`uint128` shortcuts and no truncation to 64
//     or 128 bits anywhere; widths up to `_BitInt(65535)` (1024 limbs) must work.
//     Double-limb products/carries are done with explicit 32-bit half-limb or
//     carry-propagating code (or `ulong` hi/lo helpers) - not with `uint128`.
//   - Callers provide result storage (`BigIntMutable.limbs`) and scratch
//     (`limbs_buffer`), sized with the `calc_*` helpers, exactly like Zig. These
//     functions never allocate, except the `*_alloc` helpers that take an Allocator.
//     Too-small storage is a contract violation (`@require` / assert), not a fault.
//   - Aliasing rules are Zig's and are documented on every function: where `r` "may
//     alias" an operand the implementation must read operands before overwriting.
//   - Types: limb counts and buffer lengths are `sz` (they meet slice `.len`, which is
//     `sz` in c3c 0.8.5); bit counts and shift amounts are `usz` (Zig usize).
//   - Overflow is reported as an explicit `bool` return (`add_wrap`, `sub_wrap`,
//     `mul_wrap`) or via `fits_in_twos_comp`; it is never a fault and never silent.
//   - Faults are only for conversion/parsing errors that Zig reports as errors
//     (`TARGET_TOO_SMALL`, `NEGATIVE_INTO_UNSIGNED`, `INVALID_CHARACTER`, `INVALID_BASE`).
//   - Semantics are those of the Zig std copy at
//     /home/user/tools/zig/ziglang/lib/std/math/big/int.zig (Zig 0.17.0; the pinned
//     0.18-dev was not available). Notably `shift_right` rounds toward negative
//     infinity, and bitwise ops use infinite two's-complement semantics.
module aro::bigint;
import aro::lang_opts;

<* std.math.big.Limb (usize on 64-bit hosts). Plain alias so slices of ulong interoperate. *>
alias Limb = ulong;
const usz LIMB_BITS = 64;
const usz LIMB_BYTES = 8;

<* Const.ConvertError.TargetTooSmall: the value does not fit the requested integer type. *>
excuse TARGET_TOO_SMALL;
<* Const.ConvertError.NegativeIntoUnsigned *>
excuse NEGATIVE_INTO_UNSIGNED;
<* Mutable.setString: a digit is not valid in the requested base. *>
excuse INVALID_CHARACTER;
<* Mutable.setString: base outside [2, 36]. *>
excuse INVALID_BASE;

<* std.math.Order (named BigIntOrder because type_store already defines `Order`). *>
enum BigIntOrder : char
{
	LT,
	EQ,
	GT,
}

<* std.math.CompareOperator *>
enum CompareOperator : char
{
	LT,
	LTE,
	EQ,
	GTE,
	GT,
	NEQ,
}

<* std.math.Order.compare: whether `self` satisfies `op` (e.g. LT.compare(LTE) is true). *>
fn bool BigIntOrder.compare(self, CompareOperator op)
{
	switch (op)
	{
		case LT: return self == LT;
		case LTE: return self != GT;
		case EQ: return self == EQ;
		case GTE: return self != LT;
		case GT: return self == GT;
		case NEQ: return self != EQ;
	}
}

<* std.math.big.int.TwosCompIntLimit *>
enum TwosCompIntLimit : char
{
	<* 0x00 (unsigned) or (-)0x80 (signed) for an 8-bit integer. *>
	MIN,
	<* 0xFF (unsigned) or 0x7F (signed) for an 8-bit integer. *>
	MAX,
}

<* std.math.big.int.Const: a read-only view of a normalized big integer. *>
struct BigIntConst
{
	Limb[] limbs;
	bool positive;
}

<*
 std.math.big.int.Mutable: a big integer over caller-owned storage.
 `limbs` is the whole buffer; the value is `limbs[:len]`.
*>
struct BigIntMutable
{
	Limb[] limbs;
	sz len;
	bool positive;
}

<*
 Size of the fixed buffer that can hold any u64/i64 value plus one limb of
 headroom (Zig `Interner.Tag.Int.BigIntSpace`, re-exported by value_interner).
*>
const sz SMALL_LIMBS = 2;

// ---------------------------------------------------------------------------
// Buffer size helpers (std.math.big.int.calc*)
// ---------------------------------------------------------------------------

<* calcLimbLen for an unsigned 64-bit scalar: 1 for zero, else limbs needed for the magnitude. *>
fn sz calc_limb_len_u64(ulong scalar) => 1; // 64-bit limbs: any u64 fits in one limb

<* calcLimbLen for a signed 64-bit scalar (uses |scalar|). *>
fn sz calc_limb_len_i64(long scalar) => 1; // 64-bit limbs: |i64| <= 2^63 fits in one limb

<* calcTwosCompLimbCount: max(ceil(bit_count / 64), 1). *>
fn sz calc_twos_comp_limb_count(usz bit_count)
{
	usz n = (bit_count + LIMB_BITS - 1) / LIMB_BITS;
	return n == 0 ? 1 : (sz)n;
}

<*
 calcNonZeroTwosCompLimbCount
 @require bit_count != 0
*>
fn sz calc_non_zero_twos_comp_limb_count(usz bit_count) => calc_twos_comp_limb_count(bit_count);

<* calcDivLimbsBufferLen: a_len + b_len + 4. *>
fn sz calc_div_limbs_buffer_len(sz a_len, sz b_len) => a_len + b_len + 4;

<* calcMulLimbsBufferLen: aliases * max(a_len, b_len). `aliases` = how many of a/b alias the result. *>
fn sz calc_mul_limbs_buffer_len(sz a_len, sz b_len, sz aliases) => aliases * (a_len > b_len ? a_len : b_len);

<* calcMulWrapLimbsBufferLen: aliases * min(calcTwosCompLimbCount(bit_count), max(a_len, b_len)). *>
fn sz calc_mul_wrap_limbs_buffer_len(usz bit_count, sz a_len, sz b_len, sz aliases)
{
	sz req = calc_twos_comp_limb_count(bit_count);
	sz m = a_len > b_len ? a_len : b_len;
	return aliases * (req < m ? req : m);
}

<*
 calcSetStringLimbCount: 1 + ceil(string_len * log2(base) / 64).
 Assumes `string_len` does not count a minus sign. Zig computes this in f32;
 implementers must return a value >= Zig's for every input (an upper bound).
 @require base >= 2 && base <= 36
*>
fn sz calc_set_string_limb_count(char base, sz string_len)
{
	unreachable("stage 0 stub: bigint::calc_set_string_limb_count");
}

<* calcSetStringLimbsBufferLen: calcMulLimbsBufferLen(n, n, 2) with n = calc_set_string_limb_count. *>
fn sz calc_set_string_limbs_buffer_len(char base, sz string_len)
{
	sz n = calc_set_string_limb_count(base, string_len);
	return calc_mul_limbs_buffer_len(n, n, 2);
}

<* calcToStringLimbsBufferLen: 0 for power-of-two bases, else a_len + 2 + a_len + calcDivLimbsBufferLen(a_len, 1). *>
fn sz calc_to_string_limbs_buffer_len(sz a_len, char base)
{
	if (base & (base - 1) == 0) return 0;
	return a_len + 2 + a_len + calc_div_limbs_buffer_len(a_len, 1);
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

<*
 Mutable.init(limbs_buffer, value) for an unsigned value.
 @require limbs_buffer.len >= 1
*>
fn BigIntMutable init_u64(Limb[] limbs_buffer, ulong value)
{
	unreachable("stage 0 stub: bigint::init_u64");
}

<*
 Mutable.init(limbs_buffer, value) for a signed value (handles long.min).
 @require limbs_buffer.len >= 1
*>
fn BigIntMutable init_i64(Limb[] limbs_buffer, long value)
{
	unreachable("stage 0 stub: bigint::init_i64");
}

<* Const.toMutable: copy `self` into `limbs` (which must hold self.limbs.len limbs). *>
fn BigIntMutable BigIntConst.to_mutable(self, Limb[] limbs)
{
	unreachable("stage 0 stub: BigIntConst.to_mutable");
}

<* Mutable.toConst: view of the normalized value `limbs[:len]`. *>
fn BigIntConst BigIntMutable.to_const(self) => { .limbs = self.limbs[:self.len], .positive = self.positive };

<* Mutable.set (u64). Asserts the value fits in `self.limbs`. *>
fn void BigIntMutable.set_u64(&self, ulong value)
{
	unreachable("stage 0 stub: BigIntMutable.set_u64");
}

<* Mutable.set (i64). Asserts the value fits in `self.limbs`. *>
fn void BigIntMutable.set_i64(&self, long value)
{
	unreachable("stage 0 stub: BigIntMutable.set_i64");
}

<* Mutable.copy: self = other. Asserts other fits in `self.limbs`. *>
fn void BigIntMutable.copy(&self, BigIntConst other)
{
	unreachable("stage 0 stub: BigIntMutable.copy");
}

<* Mutable.negate (zero stays positive). *>
fn void BigIntMutable.negate(&self)
{
	unreachable("stage 0 stub: BigIntMutable.negate");
}

<* Mutable.abs *>
fn void BigIntMutable.abs(&self)
{
	unreachable("stage 0 stub: BigIntMutable.abs");
}

<*
 Mutable.normalize: set `len` to `length` minus the leading zero limbs (min 1).
 @require length >= 1 && length <= self.limbs.len
*>
fn void BigIntMutable.normalize(&self, sz length)
{
	unreachable("stage 0 stub: BigIntMutable.normalize");
}

<*
 Mutable.setString: parse `value` (digits only, no prefix, no sign; case
 insensitive; '_' separators ignored) in `base`. `self.limbs` must hold
 calc_set_string_limb_count(base, value.len) limbs and `limbs_buffer`
 calc_set_string_limbs_buffer_len(base, value.len).
 @return? INVALID_BASE, INVALID_CHARACTER
*>
fn void? BigIntMutable.set_string(&self, char base, String value, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub");
}

<*
 Mutable.setTwosCompIntLimit: self = the min or max of a `bit_count`-bit integer.
 The result is sign-magnitude. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn void BigIntMutable.set_twos_comp_int_limit(&self, TwosCompIntLimit limit, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.set_twos_comp_int_limit");
}

// ---------------------------------------------------------------------------
// Arithmetic (r = self). All results are normalized.
// ---------------------------------------------------------------------------

<* Mutable.add: r = a + b. r, a, b may alias. Needs max(a.len, b.len) + 1 limbs. *>
fn void BigIntMutable.add(&r, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.add");
}

<* Mutable.addScalar (signed scalar): r = a + scalar. r and a may alias. Needs max(a.len, 1) + 1 limbs. *>
fn void BigIntMutable.add_scalar(&r, BigIntConst a, long scalar)
{
	unreachable("stage 0 stub: BigIntMutable.add_scalar");
}

<*
 Mutable.addWrap: r = a + b truncated to a `bit_count`-bit integer of
 `signedness`. Returns true when the exact sum did not fit (overflow).
 r, a, b may alias. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn bool BigIntMutable.add_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.add_wrap");
}

<* Mutable.sub: r = a - b. r, a, b may alias. Needs max(a.len, b.len) + 1 limbs. *>
fn void BigIntMutable.sub(&r, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.sub");
}

<*
 Mutable.subWrap: r = a - b with two's-complement wrapping; returns overflow.
 r, a, b may alias. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn bool BigIntMutable.sub_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.sub_wrap");
}

<*
 Mutable.mul: r = a * b (exact). r may alias a or b; a and b may alias each other.
 Needs a.len + b.len limbs. `limbs_buffer` must hold
 calc_mul_limbs_buffer_len(a.len, b.len, n) where n is the number of operands
 aliasing r (it may be empty when n == 0). Zig's optional Karatsuba allocator is
 dropped: schoolbook multiplication gives identical results.
*>
fn void BigIntMutable.mul(&r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub: BigIntMutable.mul");
}

<*
 r = a * b truncated to `bit_count` bits of `signedness`; returns true when the
 exact product does not fit (Value.mul's `!fitsInTwosComp` check). Same storage
 rules as Zig mulWrap: r needs calc_twos_comp_limb_count(bit_count) limbs and
 `limbs_buffer` calc_mul_wrap_limbs_buffer_len(bit_count, a.len, b.len, n).
 The overflow result must be computed from the exact product, not the wrapped one.
*>
fn bool BigIntMutable.mul_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub: BigIntMutable.mul_wrap");
}

<*
 Mutable.divTrunc: q = a / b rounded toward zero, r = a - q*b (sign of a).
 q may alias a or b. q needs a.len limbs, r needs b.len limbs, `limbs_buffer`
 calc_div_limbs_buffer_len(a.len, b.len).
 @require !b.eql_zero() : "division by zero"
*>
fn void div_trunc(BigIntMutable* q, BigIntMutable* r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub: bigint::div_trunc");
}

<*
 Mutable.divFloor: q = floor(a / b), r = a - q*b (sign of b).
 Same storage rules as div_trunc.
 @require !b.eql_zero() : "division by zero"
*>
fn void div_floor(BigIntMutable* q, BigIntMutable* r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub: bigint::div_floor");
}

<*
 r = remainder of truncating division (C `%`, @rem): the `r` of div_trunc.
 Allocates its quotient/scratch from `gpa` and frees it before returning.
 r needs b.len limbs.
 @require !b.eql_zero() : "division by zero"
*>
fn void BigIntMutable.rem(&r, Allocator gpa, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.rem");
}

<*
 r = remainder of flooring division (@mod): the `r` of div_floor.
 Allocates scratch from `gpa` and frees it before returning. r needs b.len limbs.
 @require !b.eql_zero() : "division by zero"
*>
fn void BigIntMutable.mod(&r, Allocator gpa, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.mod");
}

// ---------------------------------------------------------------------------
// Shifts and bitwise operations
// ---------------------------------------------------------------------------

<* Mutable.shiftLeft: r = a * 2^shift. r and a may alias. Needs a.len + shift / 64 + 1 limbs. *>
fn void BigIntMutable.shift_left(&r, BigIntConst a, usz shift)
{
	unreachable("stage 0 stub: BigIntMutable.shift_left");
}

<*
 Mutable.shiftRight: r = a >> shift, rounding toward negative infinity
 (negative values converge to -1, never 0). r and a may alias.
 Needs max(a.len - shift / 64, 1) limbs.
*>
fn void BigIntMutable.shift_right(&r, BigIntConst a, usz shift)
{
	unreachable("stage 0 stub: BigIntMutable.shift_right");
}

<* Mutable.bitNotWrap: r = ~a as a `bit_count`-bit integer of `signedness`. Needs calc_twos_comp_limb_count(bit_count) limbs. *>
fn void BigIntMutable.bit_not_wrap(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.bit_not_wrap");
}

<* Mutable.bitOr under infinite two's complement. r may alias a or b. Needs max(a.len, b.len) limbs. *>
fn void BigIntMutable.bit_or(&r, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.bit_or");
}

<*
 Mutable.bitAnd under infinite two's complement. r may alias a or b. Needs:
 both positive min(a.len, b.len); one positive that one's len; both negative
 max(a.len, b.len) + 1.
*>
fn void BigIntMutable.bit_and(&r, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.bit_and");
}

<* Mutable.bitXor under infinite two's complement. r may alias a or b. Needs max(a.len, b.len) (+1 if signs differ) limbs. *>
fn void BigIntMutable.bit_xor(&r, BigIntConst a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntMutable.bit_xor");
}

<*
 Mutable.truncate: r = a reduced to a `bit_count`-bit two's-complement integer of
 `signedness` (wraps; e.g. 255 -> -1 for signed 8 bits, -1 -> 255 unsigned).
 r may alias a. Needs max(calc_twos_comp_limb_count(bit_count), 1) limbs.
*>
fn void BigIntMutable.truncate(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.truncate");
}

<* Mutable.saturate: clamp a to the `bit_count`-bit range of `signedness`. r may alias a. *>
fn void BigIntMutable.saturate(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntMutable.saturate");
}

// ---------------------------------------------------------------------------
// Queries (Const)
// ---------------------------------------------------------------------------

<* Const.abs (shares limbs). *>
fn BigIntConst BigIntConst.abs(self) => { .limbs = self.limbs, .positive = true };

<* Const.negate (shares limbs; zero stays positive). *>
fn BigIntConst BigIntConst.negate(self)
{
	unreachable("stage 0 stub: BigIntConst.negate");
}

fn bool BigIntConst.is_odd(self)
{
	unreachable("stage 0 stub: BigIntConst.is_odd");
}

fn bool BigIntConst.is_even(self)
{
	unreachable("stage 0 stub: BigIntConst.is_even");
}

<* Const.bitCountAbs: bits needed for |self| (0 for zero). *>
fn usz BigIntConst.bit_count_abs(self)
{
	unreachable("stage 0 stub: BigIntConst.bit_count_abs");
}

<*
 Const.bitCountTwosComp: for negative values the bits of the smallest signed
 type holding it (-127 -> 8, -128 -> 8, -129 -> 9); for non-negative values the
 bits of the smallest unsigned type (127 -> 7, 0 -> 0).
*>
fn usz BigIntConst.bit_count_twos_comp(self)
{
	unreachable("stage 0 stub: BigIntConst.bit_count_twos_comp");
}

<* Const.bitCountTwosCompForSignedness: bit_count_twos_comp, +1 for non-negative signed. *>
fn usz BigIntConst.bit_count_twos_comp_for_signedness(self, Signedness signedness)
{
	unreachable("stage 0 stub: BigIntConst.bit_count_twos_comp_for_signedness");
}

<* Const.fitsInTwosComp: whether self is representable in `bit_count` bits of `signedness`. *>
fn bool BigIntConst.fits_in_twos_comp(self, Signedness signedness, usz bit_count)
{
	unreachable("stage 0 stub: BigIntConst.fits_in_twos_comp");
}

<* Const.orderAbs: compare magnitudes. *>
fn BigIntOrder BigIntConst.order_abs(a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntConst.order_abs");
}

<* Const.order: signed comparison. *>
fn BigIntOrder BigIntConst.order(a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntConst.order");
}

<* Const.orderAgainstScalar (signed 64-bit scalar). *>
fn BigIntOrder BigIntConst.order_against_i64(a, long scalar)
{
	unreachable("stage 0 stub: BigIntConst.order_against_i64");
}

<* Const.eqlZero *>
fn bool BigIntConst.eql_zero(a)
{
	unreachable("stage 0 stub: BigIntConst.eql_zero");
}

<* Const.eqlAbs *>
fn bool BigIntConst.eql_abs(a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntConst.eql_abs");
}

<* Const.eql *>
fn bool BigIntConst.eql(a, BigIntConst b)
{
	unreachable("stage 0 stub: BigIntConst.eql");
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

<*
 Const.toInt(u64)
 @return? NEGATIVE_INTO_UNSIGNED, TARGET_TOO_SMALL
*>
fn ulong? BigIntConst.to_u64(self)
{
	unreachable("stage 0 stub");
}

<*
 Const.toInt(i64)
 @return? TARGET_TOO_SMALL
*>
fn long? BigIntConst.to_i64(self)
{
	unreachable("stage 0 stub");
}

<*
 Const.toInt(u32) (Interner.put's small-int check)
 @return? NEGATIVE_INTO_UNSIGNED, TARGET_TOO_SMALL
*>
fn uint? BigIntConst.to_u32(self)
{
	unreachable("stage 0 stub");
}

<*
 Const.toInt(i32)
 @return? TARGET_TOO_SMALL
*>
fn int? BigIntConst.to_i32(self)
{
	unreachable("stage 0 stub");
}

<*
 Const.sizeInBaseUpperBound: chars needed to print self in `base` (includes a
 minus sign; may overestimate by 1-2).
*>
fn sz BigIntConst.size_in_base_upper_bound(self, char base)
{
	unreachable("stage 0 stub: BigIntConst.size_in_base_upper_bound");
}

<*
 Const.toString: write self in `base` (2..36) into `buf` (at least
 size_in_base_upper_bound(base) bytes) with a leading '-' when negative; digits
 above 9 are upper case when `upper`. `limbs_buffer` must hold
 calc_to_string_limbs_buffer_len(self.limbs.len, base). Returns the length written.
 @require base >= 2 && base <= 36
*>
fn sz BigIntConst.to_string(self, char[] buf, char base, bool upper, Limb[] limbs_buffer)
{
	unreachable("stage 0 stub: BigIntConst.to_string");
}

<*
 Const.toStringAlloc: like to_string, returning a new `gpa` allocation the caller
 frees (`alloc::free(gpa, s.ptr)`). Decimal printing of Value ints uses base 10.
 @require base >= 2 && base <= 36
*>
fn String BigIntConst.to_string_alloc(self, Allocator gpa, char base, bool upper)
{
	unreachable("stage 0 stub: BigIntConst.to_string_alloc");
}
