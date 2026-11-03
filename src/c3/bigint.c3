// Port of the parts of Zig's std.math.big.int (Const / Mutable) that Aro uses:
// src/aro/Value.zig, src/backend/Interner.zig and Parser.zig bitInt (setString).
//
// OWNER: plan 09 stage 1 agent 09.2 `bigint`. Stage 0 (contract) fixed the types and
// signatures below; stage 1 implemented the bodies.
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
//
// Implementation notes (stage 1):
//   - Double-limb arithmetic uses `mul_wide` (four 32x32->64 partial products) and
//     `div_wide` (Hacker's Delight divlu, 32-bit half digits). No uint128 anywhere.
//   - Multiplication is column-wise (Comba) schoolbook; Zig's Karatsuba is an
//     optimisation with identical results. Division is Knuth 4.3.1 Algorithm D
//     (Zig uses HAC 14.20, also exact), so quotients/remainders are identical.
//   - Deliberate deviations from Zig 0.17.0, all where Zig's result is wrong or
//     breaks the normalization invariant above:
//       * zero results are always positive (Zig's div can return a "-0" remainder,
//         e.g. divTrunc(-6, 3), mulNoAlias a "-0" product for multi-limb * 0, and
//         addWrap a "-0" when the carry leaves the kept limbs, e.g. i64.min + i64.min);
//       * `bit_or` of a negative longer operand with a positive shorter operand writes
//         every result limb (Zig leaves the upper limbs uninitialised unless r aliases a);
//       * `saturate` copies `a` into `r` when it fits and picks the limit from
//         `a.positive` (Zig reads `r.positive` and leaves `r` untouched; the two agree
//         whenever r aliases a, which is how Aro calls it);
//       * `mul_wrap` copies an aliased `b` correctly (Zig copies `a` into b's slot);
//       * `to_string` in base 8/32 extracts digits across limb boundaries (Zig's
//         per-limb power-of-two loop drops bits when 64 is not a multiple of log2(base)).
module aro::bigint;
import aro::lang_opts;

<* std.math.big.Limb (usize on 64-bit hosts). Plain alias so slices of ulong interoperate. *>
alias Limb = ulong;
const usz LIMB_BITS = 64;
const usz LIMB_BYTES = 8;
const Limb LIMB_MAX = 0xFFFF_FFFF_FFFF_FFFF;
const Limb HALF_MASK = 0xFFFF_FFFF;
const Limb HALF_BASE = 0x1_0000_0000;

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
// Limb primitives (no uint128)
// ---------------------------------------------------------------------------

<* a + b + *carry (carry in {0,1}); sets *carry to the carry out. *>
fn Limb add_limb(Limb a, Limb b, Limb* carry) @inline
{
	Limb s = a + b;
	Limb c = s < a ? 1 : 0;
	Limb s2 = s + *carry;
	if (s2 < s) c++;
	*carry = c;
	return s2;
}

<* a - b - *borrow (borrow in {0,1}); sets *borrow to the borrow out. *>
fn Limb sub_limb(Limb a, Limb b, Limb* borrow) @inline
{
	Limb d = a - b;
	Limb c = a < b ? 1 : 0;
	Limb d2 = d - *borrow;
	if (d < *borrow) c++;
	*borrow = c;
	return d2;
}

<* Full 64x64 -> 128 product from four 32x32 partial products. Returns the low limb. *>
fn Limb mul_wide(Limb a, Limb b, Limb* hi) @inline
{
	Limb a0 = a & HALF_MASK;
	Limb a1 = a >> 32;
	Limb b0 = b & HALF_MASK;
	Limb b1 = b >> 32;
	Limb p00 = a0 * b0;
	Limb p01 = a0 * b1;
	Limb p10 = a1 * b0;
	Limb p11 = a1 * b1;
	Limb mid = (p00 >> 32) + (p01 & HALF_MASK) + (p10 & HALF_MASK);
	*hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
	return (p00 & HALF_MASK) | (mid << 32);
}

<*
 (u1 * 2^64 + u0) / divisor with u1 < divisor (Hacker's Delight divlu, 32-bit half digits).
 @require divisor != 0 && u1 < divisor
*>
fn Limb div_wide(Limb u1, Limb u0, Limb divisor, Limb* rem)
{
	int s = divisor.clz();
	Limb v = divisor << s;
	Limb vn1 = v >> 32;
	Limb vn0 = v & HALF_MASK;
	Limb un32 = s == 0 ? u1 : (u1 << s) | (u0 >> (64 - s));
	Limb un10 = u0 << s;
	Limb un1 = un10 >> 32;
	Limb un0 = un10 & HALF_MASK;
	Limb q1 = un32 / vn1;
	Limb rhat = un32 - q1 * vn1;
	while (q1 >= HALF_BASE || q1 * vn0 > (rhat << 32) + un1)
	{
		q1--;
		rhat += vn1;
		if (rhat >= HALF_BASE) break;
	}
	Limb un21 = (un32 << 32) + un1 - q1 * v;
	Limb q0 = un21 / vn1;
	rhat = un21 - q0 * vn1;
	while (q0 >= HALF_BASE || q0 * vn0 > (rhat << 32) + un0)
	{
		q0--;
		rhat += vn1;
		if (rhat >= HALF_BASE) break;
	}
	*rem = ((un21 << 32) + un0 - q0 * v) >> s;
	return (q1 << 32) + q0;
}

<* addMulLimbWithCarry: a + b * c + *carry; sets *carry to the high limb. *>
fn Limb add_mul_limb_with_carry(Limb a, Limb b, Limb c, Limb* carry) @inline
{
	Limb hi;
	Limb lo = mul_wide(b, c, &hi);
	Limb c1 = 0;
	Limb s = add_limb(a, *carry, &c1);
	Limb c2 = 0;
	s = add_limb(s, lo, &c2);
	*carry = hi + c1 + c2;
	return s;
}

<* subMulLimbWithBorrow: a - b * c - *carry; sets *carry to the borrow. *>
fn Limb sub_mul_limb_with_borrow(Limb a, Limb b, Limb c, Limb* carry) @inline
{
	Limb hi;
	Limb lo = mul_wide(b, c, &hi);
	Limb c1 = 0;
	Limb d = sub_limb(a, *carry, &c1);
	Limb c2 = 0;
	d = sub_limb(d, lo, &c2);
	*carry = hi + c1 + c2;
	return d;
}

<* llnormalize: the minimal length of `a` (at least 1). *>
fn sz llnormalize(Limb[] a)
{
	sz j = a.len;
	while (j > 0 && a[j - 1] == 0) j--;
	return j != 0 ? j : 1;
}

<* lladdcarry: r = a + b over a.len limbs; returns the carry. r may alias a/b at the same start. *>
fn Limb lladdcarry(Limb[] r, Limb[] a, Limb[] b)
{
	assert(a.len != 0 && b.len != 0);
	assert(a.len >= b.len);
	assert(r.len >= a.len);
	Limb carry = 0;
	sz i = 0;
	for (; i < b.len; i++) r[i] = add_limb(a[i], b[i], &carry);
	for (; i < a.len; i++) r[i] = add_limb(a[i], 0, &carry);
	return carry;
}

<* llsubcarry: r = a - b over a.len limbs; returns the borrow. *>
fn Limb llsubcarry(Limb[] r, Limb[] a, Limb[] b)
{
	assert(a.len != 0 && b.len != 0);
	assert(a.len >= b.len);
	assert(r.len >= a.len);
	Limb borrow = 0;
	sz i = 0;
	for (; i < b.len; i++) r[i] = sub_limb(a[i], b[i], &borrow);
	for (; i < a.len; i++) r[i] = sub_limb(a[i], 0, &borrow);
	return borrow;
}

<* llmulLimb(.sub): acc -= y * xi modulo acc.len; returns whether it borrowed out. *>
fn bool llmul_limb_sub(Limb[] acc, Limb[] y, Limb xi)
{
	if (xi == 0) return false;
	sz split = y.len < acc.len ? y.len : acc.len;
	Limb borrow = 0;
	for (sz j = 0; j < split; j++) acc[j] = sub_mul_limb_with_borrow(acc[j], y[j], xi, &borrow);
	for (sz j = split; borrow != 0 && j < acc.len; j++)
	{
		Limb b = borrow;
		borrow = 0;
		acc[j] = sub_limb(acc[j], b, &borrow);
	}
	return borrow != 0;
}

<*
 Column-wise (Comba) product: r[0:out_len] = (a * b) mod 2^(64 * out_len).
 Returns true when any limb of the exact product at index >= out_len is non-zero.
 r must not overlap a or b.
*>
fn bool llmul_columns(Limb[] r, sz out_len, Limb[] a, Limb[] b)
{
	assert(a.len >= 1 && b.len >= 1 && r.len >= out_len);
	Limb c0 = 0;
	Limb c1 = 0;
	Limb c2 = 0;
	bool high = false;
	sz total = a.len + b.len;
	for (sz k = 0; k < total; k++)
	{
		if (k < total - 1)
		{
			sz i_lo = k >= b.len ? k - b.len + 1 : 0;
			sz i_hi = k < a.len ? k : a.len - 1;
			for (sz i = i_lo; i <= i_hi; i++)
			{
				Limb hi;
				Limb lo = mul_wide(a[i], b[k - i], &hi);
				Limb carry = 0;
				c0 = add_limb(c0, lo, &carry);
				c1 = add_limb(c1, hi, &carry);
				c2 += carry;
			}
		}
		if (k < out_len)
		{
			r[k] = c0;
		}
		else if (c0 != 0)
		{
			high = true;
		}
		c0 = c1;
		c1 = c2;
		c2 = 0;
	}
	assert(c0 == 0);
	for (sz k = total; k < out_len; k++) r[k] = 0;
	return high;
}

<* llshl: r = a << shift; returns the number of limbs written. r may alias a (r.ptr >= a.ptr). *>
fn sz llshl(Limb[] r, Limb[] a, usz shift)
{
	assert(a.len >= 1);
	sz limb_shift = (sz)(shift / LIMB_BITS);
	usz bit_shift = shift % LIMB_BITS;
	if (bit_shift == 0)
	{
		assert(r.len >= a.len + limb_shift);
		for (sz i = a.len; i > 0; i--) r[i - 1 + limb_shift] = a[i - 1];
		for (sz i = 0; i < limb_shift; i++) r[i] = 0;
		return a.len + limb_shift;
	}
	usz opposite = LIMB_BITS - bit_shift;
	bool overflows = (a[a.len - 1] >> opposite) != 0;
	assert(r.len >= a.len + limb_shift + (overflows ? 1 : 0));
	if (overflows) r[a.len + limb_shift] = a[a.len - 1] >> opposite;
	for (sz i = a.len - 1; i > 0; i--)
	{
		r[i + limb_shift] = (a[i - 1] >> opposite) | (a[i] << bit_shift);
	}
	r[limb_shift] = a[0] << bit_shift;
	for (sz i = 0; i < limb_shift; i++) r[i] = 0;
	return a.len + limb_shift + (overflows ? 1 : 0);
}

<* llshr: r = a >> shift; returns the number of limbs written. r may alias a (r.ptr <= a.ptr). *>
fn sz llshr(Limb[] r, Limb[] a, usz shift)
{
	if (a.len == 0) return 0;
	usz full = shift / LIMB_BITS;
	if (full >= (usz)a.len)
	{
		r[0] = 0;
		return 1;
	}
	sz off = (sz)full;
	usz bit_shift = shift % LIMB_BITS;
	sz n = a.len - off;
	if (bit_shift == 0)
	{
		assert(r.len >= n);
		for (sz i = 0; i < n; i++) r[i] = a[i + off];
		return n;
	}
	if (n == 1)
	{
		r[0] = a[off] >> bit_shift;
		return 1;
	}
	usz opposite = LIMB_BITS - bit_shift;
	bool shrink = (a[a.len - 1] >> bit_shift) == 0;
	assert(r.len >= n - (shrink ? 1 : 0));
	sz i = 0;
	for (; i < n - 1; i++) r[i] = (a[i + off] >> bit_shift) | (a[i + off + 1] << opposite);
	if (!shrink) r[i] = a[i + off] >> bit_shift;
	return n - (shrink ? 1 : 0);
}

fn void llnot(Limb[] r)
{
	foreach (&l : r) *l = ~*l;
}

<* -1, 0, 1 for |a| <=> |b| (normalized lengths). *>
fn int llcmp(Limb[] a, Limb[] b)
{
	sz a_len = llnormalize(a);
	sz b_len = llnormalize(b);
	if (a_len != b_len) return a_len < b_len ? -1 : 1;
	for (sz i = a_len; i > 0; i--)
	{
		if (a[i - 1] != b[i - 1]) return a[i - 1] < b[i - 1] ? -1 : 1;
	}
	return 0;
}

fn bool slices_overlap(Limb[] a, Limb[] b)
{
	if (a.len == 0 || b.len == 0) return false;
	uptr a0 = (uptr)a.ptr;
	uptr a1 = a0 + (uptr)a.len * LIMB_BYTES;
	uptr b0 = (uptr)b.ptr;
	uptr b1 = b0 + (uptr)b.len * LIMB_BYTES;
	return a0 < b1 && b0 < a1;
}

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
	usz n = bit_count / LIMB_BITS + (usz)(bit_count % LIMB_BITS != 0 ? 1 : 0);
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

 Implementation: log2(base) is replaced by ceil(log2(base)), which is exact for
 power-of-two bases and at least 0.046 above log2(base) otherwise (base 31), far
 more than f32 rounding can add. For power-of-two bases one extra limb covers f32
 rounding of string_len once it exceeds 2^24.
 @require base >= 2 && base <= 36
*>
fn sz calc_set_string_limb_count(char base, sz string_len)
{
	usz bits_per_digit = 64 - (usz)((ulong)(base - 1)).clz();
	usz total = (usz)string_len * bits_per_digit;
	sz n = 1 + (sz)(total / LIMB_BITS + (usz)(total % LIMB_BITS != 0 ? 1 : 0));
	if ((base & (base - 1)) == 0 && string_len > (sz)1 << 24) n++;
	return n;
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
	BigIntMutable m = { .limbs = limbs_buffer, .len = 1, .positive = true };
	m.set_u64(value);
	return m;
}

<*
 Mutable.init(limbs_buffer, value) for a signed value (handles long.min).
 @require limbs_buffer.len >= 1
*>
fn BigIntMutable init_i64(Limb[] limbs_buffer, long value)
{
	BigIntMutable m = { .limbs = limbs_buffer, .len = 1, .positive = true };
	m.set_i64(value);
	return m;
}

<* Const.toMutable: copy `self` into `limbs` (which must hold self.limbs.len limbs). *>
fn BigIntMutable BigIntConst.to_mutable(self, Limb[] limbs)
{
	assert(limbs.len >= self.limbs.len);
	if (limbs.ptr != self.limbs.ptr)
	{
		for (sz i = 0; i < self.limbs.len; i++) limbs[i] = self.limbs[i];
	}
	return { .limbs = limbs, .len = self.limbs.len, .positive = self.positive };
}

<* Mutable.toConst: view of the normalized value `limbs[:len]`. *>
fn BigIntConst BigIntMutable.to_const(self) => { .limbs = self.limbs[:self.len], .positive = self.positive };

<* Mutable.set (u64). Asserts the value fits in `self.limbs`. *>
fn void BigIntMutable.set_u64(&self, ulong value)
{
	assert(self.limbs.len >= 1);
	self.limbs[0] = value;
	self.len = 1;
	self.positive = true;
}

<* Mutable.set (i64). Asserts the value fits in `self.limbs`. *>
fn void BigIntMutable.set_i64(&self, long value)
{
	assert(self.limbs.len >= 1);
	// |value| as an unsigned limb; two's-complement negation handles long.min (2^63).
	self.limbs[0] = value < 0 ? 0 - (ulong)value : (ulong)value;
	self.len = 1;
	self.positive = value >= 0;
}

<* Mutable.copy: self = other. Asserts other fits in `self.limbs`. *>
fn void BigIntMutable.copy(&self, BigIntConst other)
{
	assert(self.limbs.len >= other.limbs.len);
	if (self.limbs.ptr != other.limbs.ptr)
	{
		if ((uptr)self.limbs.ptr < (uptr)other.limbs.ptr)
		{
			for (sz i = 0; i < other.limbs.len; i++) self.limbs[i] = other.limbs[i];
		}
		else
		{
			for (sz i = other.limbs.len; i > 0; i--) self.limbs[i - 1] = other.limbs[i - 1];
		}
	}
	self.normalize(other.limbs.len);
	self.positive = other.positive || other.eql_zero();
}

<* Mutable.negate (zero stays positive). *>
fn void BigIntMutable.negate(&self)
{
	self.positive = !self.positive || self.to_const().eql_zero();
}

<* Mutable.abs *>
fn void BigIntMutable.abs(&self)
{
	self.positive = true;
}

<*
 Mutable.normalize: set `len` to `length` minus the leading zero limbs (min 1).
 @require length >= 1 && length <= self.limbs.len
*>
fn void BigIntMutable.normalize(&self, sz length)
{
	self.len = llnormalize(self.limbs[:length]);
}

<* Zero is always positive. *>
fn void BigIntMutable.fix_zero_sign(&self) @inline
{
	if (self.len == 1 && self.limbs[0] == 0) self.positive = true;
}

fn int? digit_value(char ch, char base) @inline
{
	int d;
	switch
	{
		case ch >= '0' && ch <= '9': d = ch - '0';
		case ch >= 'a' && ch <= 'z': d = ch - 'a' + 10;
		case ch >= 'A' && ch <= 'Z': d = ch - 'A' + 10;
		default: return INVALID_CHARACTER~;
	}
	if (d >= base) return INVALID_CHARACTER~;
	return d;
}

<* self[:len] = self[:len] * mul + add; grows len by one limb on carry out. *>
fn void BigIntMutable.mul_add_small(&self, Limb mul, Limb add)
{
	Limb carry = add;
	for (sz i = 0; i < self.len; i++)
	{
		self.limbs[i] = add_mul_limb_with_carry(0, self.limbs[i], mul, &carry);
	}
	if (carry != 0)
	{
		assert(self.len < self.limbs.len, "set_string: result does not fit");
		self.limbs[self.len] = carry;
		self.len++;
	}
}

<*
 Mutable.setString: parse `value` (digits only, no prefix, no sign; case
 insensitive; '_' separators ignored) in `base`. `self.limbs` must hold
 calc_set_string_limb_count(base, value.len) limbs and `limbs_buffer`
 calc_set_string_limbs_buffer_len(base, value.len).
 Like Zig, a single leading '-' is accepted and makes the value negative
 (then `value.len - 1` digits size the storage). `limbs_buffer` is unused
 (Zig 0.17.0's setString needs no scratch either) but kept for the contract.
 @return? INVALID_BASE, INVALID_CHARACTER
*>
fn void? BigIntMutable.set_string(&self, char base, String value, Limb[] limbs_buffer)
{
	if (base < 2 || base > 36) return INVALID_BASE~;
	sz i = 0;
	bool positive = true;
	if (value.len > 0 && value[0] == '-')
	{
		positive = false;
		i = 1;
	}
	// Validate everything first so a fault leaves no partially written value behind.
	for (sz k = i; k < value.len; k++)
	{
		if (value[k] == '_') continue;
		digit_value(value[k], base)!;
	}
	assert(self.limbs.len >= 1);
	self.limbs[0] = 0;
	self.len = 1;
	Limb limb = 0;
	Limb mult = 1;
	Limb max_mult = LIMB_MAX / base;
	for (; i < value.len; i++)
	{
		char ch = value[i];
		if (ch == '_') continue;
		Limb d = (Limb)digit_value(ch, base)!!;
		limb = limb * base + d;
		mult *= base;
		if (mult > max_mult)
		{
			self.mul_add_small(mult, limb);
			limb = 0;
			mult = 1;
		}
	}
	if (mult > 1) self.mul_add_small(mult, limb);
	self.positive = positive;
	self.fix_zero_sign();
}

<*
 Mutable.setTwosCompIntLimit: self = the min or max of a `bit_count`-bit integer.
 The result is sign-magnitude. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn void BigIntMutable.set_twos_comp_int_limit(&self, TwosCompIntLimit limit, Signedness signedness, usz bit_count)
{
	if (bit_count == 0)
	{
		self.set_u64(0);
		return;
	}
	sz req_limbs = calc_twos_comp_limb_count(bit_count);
	assert(self.limbs.len >= req_limbs);
	Limb signmask = (Limb)1 << ((bit_count - 1) % LIMB_BITS);
	Limb mask = (signmask << 1) - 1;
	self.positive = true;
	if (signedness == SIGNED)
	{
		if (limit == MIN)
		{
			self.len = req_limbs;
			for (sz i = 0; i < req_limbs - 1; i++) self.limbs[i] = 0;
			self.limbs[req_limbs - 1] = signmask;
			self.positive = false;
			return;
		}
		if (bit_count == 1)
		{
			self.set_u64(0);
			return;
		}
		sz new_req = calc_twos_comp_limb_count(bit_count - 1);
		Limb new_signmask = (Limb)1 << ((bit_count - 2) % LIMB_BITS);
		Limb new_mask = (new_signmask << 1) - 1;
		self.len = new_req;
		for (sz i = 0; i < new_req - 1; i++) self.limbs[i] = LIMB_MAX;
		self.limbs[new_req - 1] = new_mask;
		return;
	}
	if (limit == MIN)
	{
		self.set_u64(0);
		return;
	}
	self.len = req_limbs;
	for (sz i = 0; i < req_limbs - 1; i++) self.limbs[i] = LIMB_MAX;
	self.limbs[req_limbs - 1] = mask;
}

// ---------------------------------------------------------------------------
// Arithmetic (r = self). All results are normalized.
// ---------------------------------------------------------------------------

<* Mutable.addCarry: adds max(a.len, b.len) limbs; returns whether the top limb carried out. *>
fn bool BigIntMutable.add_carry(&r, BigIntConst a, BigIntConst b)
{
	if (a.eql_zero())
	{
		r.copy(b);
		return false;
	}
	if (b.eql_zero())
	{
		r.copy(a);
		return false;
	}
	if (a.positive != b.positive)
	{
		if (a.positive) return r.sub_carry(a, b.abs());
		return r.sub_carry(b, a.abs());
	}
	r.positive = a.positive;
	if (a.limbs.len >= b.limbs.len)
	{
		Limb c = lladdcarry(r.limbs, a.limbs, b.limbs);
		r.normalize(a.limbs.len);
		return c != 0;
	}
	Limb c = lladdcarry(r.limbs, b.limbs, a.limbs);
	r.normalize(b.limbs.len);
	return c != 0;
}

<* Mutable.subCarry *>
fn bool BigIntMutable.sub_carry(&r, BigIntConst a, BigIntConst b)
{
	if (a.eql_zero())
	{
		r.copy(b);
		r.positive = !b.positive || b.eql_zero();
		return false;
	}
	if (b.eql_zero())
	{
		r.copy(a);
		return false;
	}
	if (a.positive != b.positive)
	{
		if (a.positive) return r.add_carry(a, b.abs());
		return r.add_carry(a, b.negate());
	}
	Limb c;
	if (a.positive)
	{
		if (a.order(b) != LT)
		{
			c = llsubcarry(r.limbs, a.limbs, b.limbs);
			r.normalize(a.limbs.len);
			r.positive = true;
		}
		else
		{
			c = llsubcarry(r.limbs, b.limbs, a.limbs);
			r.normalize(b.limbs.len);
			r.positive = false;
		}
	}
	else
	{
		if (a.order(b) == LT)
		{
			c = llsubcarry(r.limbs, a.limbs, b.limbs);
			r.normalize(a.limbs.len);
			r.positive = false;
		}
		else
		{
			c = llsubcarry(r.limbs, b.limbs, a.limbs);
			r.normalize(b.limbs.len);
			r.positive = true;
		}
	}
	r.fix_zero_sign();
	return c != 0;
}

<* Mutable.add: r = a + b. r, a, b may alias. Needs max(a.len, b.len) + 1 limbs. *>
fn void BigIntMutable.add(&r, BigIntConst a, BigIntConst b)
{
	sz msl = a.limbs.len > b.limbs.len ? a.limbs.len : b.limbs.len;
	if (r.add_carry(a, b))
	{
		assert(r.limbs.len > msl, "add: result does not fit");
		r.len = msl + 1;
		r.limbs[msl] = 1;
		return;
	}
	r.fix_zero_sign();
}

<* Mutable.addScalar (signed scalar): r = a + scalar. r and a may alias. Needs max(a.len, 1) + 1 limbs. *>
fn void BigIntMutable.add_scalar(&r, BigIntConst a, long scalar)
{
	Limb[1] buf;
	BigIntConst operand = init_i64(buf[..], scalar).to_const();
	r.add(a, operand);
}

<*
 Mutable.addWrap: r = a + b truncated to a `bit_count`-bit integer of
 `signedness`. Returns true when the exact sum did not fit (overflow).
 r, a, b may alias. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn bool BigIntMutable.add_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count)
{
	sz req_limbs = calc_twos_comp_limb_count(bit_count);
	sz msl = a.limbs.len > b.limbs.len ? a.limbs.len : b.limbs.len;
	BigIntConst x = { .positive = a.positive, .limbs = a.limbs[:a.limbs.len < req_limbs ? a.limbs.len : req_limbs] };
	BigIntConst y = { .positive = b.positive, .limbs = b.limbs[:b.limbs.len < req_limbs ? b.limbs.len : req_limbs] };
	bool carry_truncated = false;
	if (r.add_carry(x, y))
	{
		if (msl < req_limbs)
		{
			r.len = msl + 1;
			r.limbs[msl] = 1;
		}
		else
		{
			carry_truncated = true;
		}
	}
	// A carry out of the top kept limb can leave a zero magnitude with a negative
	// sign (e.g. i64.min + i64.min in 64 bits); Zig keeps that "-0", we do not.
	r.fix_zero_sign();
	if (!r.to_const().fits_in_twos_comp(signedness, bit_count))
	{
		r.truncate(r.to_const(), signedness, bit_count);
		return true;
	}
	return carry_truncated;
}

<* Mutable.sub: r = a - b. r, a, b may alias. Needs max(a.len, b.len) + 1 limbs. *>
fn void BigIntMutable.sub(&r, BigIntConst a, BigIntConst b)
{
	r.add(a, b.negate());
}

<*
 Mutable.subWrap: r = a - b with two's-complement wrapping; returns overflow.
 r, a, b may alias. Needs calc_twos_comp_limb_count(bit_count) limbs.
*>
fn bool BigIntMutable.sub_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count)
{
	return r.add_wrap(a, b.negate(), signedness, bit_count);
}

<* Copies `a` into `buf[*idx:]` when it shares storage with `r`; returns the operand to use. *>
fn BigIntConst unalias(Limb[] r, BigIntConst a, sz copy_len, Limb[] buf, sz* idx)
{
	if (!slices_overlap(r, a.limbs)) return a;
	assert(buf.len >= *idx + copy_len, "limbs_buffer too small for aliased operand");
	Limb[] dst = buf[*idx:copy_len];
	for (sz i = 0; i < copy_len; i++) dst[i] = a.limbs[i];
	*idx += copy_len;
	return { .limbs = dst, .positive = a.positive };
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
	sz idx = 0;
	BigIntConst x = unalias(r.limbs, a, a.limbs.len, limbs_buffer, &idx);
	BigIntConst y;
	if (b.limbs.ptr == a.limbs.ptr && b.limbs.len == a.limbs.len)
	{
		// a and b are the same limbs: reuse a's (possibly copied) storage.
		y = { .limbs = x.limbs, .positive = b.positive };
	}
	else
	{
		y = unalias(r.limbs, b, b.limbs.len, limbs_buffer, &idx);
	}
	sz out_len = x.limbs.len + y.limbs.len;
	assert(r.limbs.len >= out_len, "mul: result does not fit");
	llmul_columns(r.limbs, out_len, x.limbs, y.limbs);
	r.normalize(out_len);
	r.positive = x.positive == y.positive;
	r.fix_zero_sign();
}

<*
 r = a * b truncated to `bit_count` bits of `signedness`; returns true when the
 exact product does not fit (Value.mul's `!fitsInTwosComp` check). Same storage
 rules as Zig mulWrap: r needs calc_twos_comp_limb_count(bit_count) limbs and
 `limbs_buffer` calc_mul_wrap_limbs_buffer_len(bit_count, a.len, b.len, n).
 The overflow result must be computed from the exact product, not the wrapped one.

 Overflow without exact storage: if either operand has more than req_limbs limbs
 (and the other is non-zero) the product's magnitude is >= 2^(64*req_limbs) and
 cannot fit; otherwise the column product reports whether any limb above
 req_limbs is non-zero, and the low limbs are the exact product when none is.
*>
fn bool BigIntMutable.mul_wrap(&r, BigIntConst a, BigIntConst b, Signedness signedness, usz bit_count, Limb[] limbs_buffer)
{
	if (a.eql_zero() || b.eql_zero())
	{
		r.set_u64(0);
		return false;
	}
	sz req_limbs = calc_twos_comp_limb_count(bit_count);
	assert(r.limbs.len >= req_limbs, "mul_wrap: result does not fit");
	bool overflow = a.limbs.len > req_limbs || b.limbs.len > req_limbs;
	sz a_len = a.limbs.len < req_limbs ? a.limbs.len : req_limbs;
	sz b_len = b.limbs.len < req_limbs ? b.limbs.len : req_limbs;
	BigIntConst at = { .limbs = a.limbs[:a_len], .positive = a.positive };
	BigIntConst bt = { .limbs = b.limbs[:b_len], .positive = b.positive };
	sz idx = 0;
	BigIntConst x = unalias(r.limbs, at, a_len, limbs_buffer, &idx);
	BigIntConst y = unalias(r.limbs, bt, b_len, limbs_buffer, &idx);
	if (llmul_columns(r.limbs, req_limbs, x.limbs, y.limbs)) overflow = true;
	r.normalize(req_limbs);
	r.positive = a.positive == b.positive;
	r.fix_zero_sign();
	if (!r.to_const().fits_in_twos_comp(signedness, bit_count)) overflow = true;
	if (overflow) r.truncate(r.to_const(), signedness, bit_count);
	return overflow;
}

<*
 Truncating division of magnitudes. x = buf limbs holding |a| with capacity
 xlen + 2, y = |b| (n limbs, restored on return). Writes q (sign q_pos) and r
 (sign x_pos); zero results are positive.
*>
fn void div_impl(BigIntMutable* q, BigIntMutable* r, Limb[] x, sz xlen, Limb[] y, bool x_pos, bool y_pos)
{
	sz n = y.len;
	assert(n >= 1 && y[n - 1] != 0, "division by zero");
	bool q_pos = x_pos == y_pos;
	if (llcmp(x[:xlen], y) < 0)
	{
		r.copy({ .limbs = x[:xlen], .positive = true });
		r.positive = x_pos;
		r.fix_zero_sign();
		q.set_u64(0);
		return;
	}
	assert(q.limbs.len >= xlen - n + 1);
	if (n == 1)
	{
		Limb d = y[0];
		Limb rem = 0;
		for (sz i = xlen; i > 0; i--) q.limbs[i - 1] = div_wide(rem, x[i - 1], d, &rem);
		q.normalize(xlen);
		q.positive = q_pos;
		q.fix_zero_sign();
		assert(r.limbs.len >= 1);
		r.limbs[0] = rem;
		r.len = 1;
		r.positive = x_pos || rem == 0;
		return;
	}
	// Knuth 4.3.1 Algorithm D. D1: normalize so the divisor's top bit is set.
	int s = y[n - 1].clz();
	sz ulen = llshl(x, x[:xlen], (usz)s);
	if (ulen == xlen) x[xlen] = 0;
	if (s != 0) llshl(y, y, (usz)s);
	Limb[] u = x[:xlen + 1];
	Limb vtop = y[n - 1];
	Limb vnext = y[n - 2];
	sz m = xlen - n;
	for (sz jj = m + 1; jj > 0; jj--)
	{
		sz j = jj - 1;
		// D3: estimate qhat from the top two limbs, refine with the third.
		Limb ujn = u[j + n];
		Limb ujn1 = u[j + n - 1];
		Limb ujn2 = u[j + n - 2];
		Limb qhat;
		Limb rhat;
		bool rhat_big = false;
		if (ujn >= vtop)
		{
			qhat = LIMB_MAX;
			rhat = ujn1 + vtop;
			rhat_big = rhat < ujn1;
		}
		else
		{
			qhat = div_wide(ujn, ujn1, vtop, &rhat);
		}
		while (!rhat_big)
		{
			Limb phi;
			Limb plo = mul_wide(qhat, vnext, &phi);
			if (phi < rhat || (phi == rhat && plo <= ujn2)) break;
			qhat--;
			Limb old = rhat;
			rhat += vtop;
			rhat_big = rhat < old;
		}
		// D4-D6: multiply and subtract, add back on borrow.
		Limb[] uj = u[j:n + 1];
		if (llmul_limb_sub(uj, y, qhat))
		{
			qhat--;
			lladdcarry(uj, uj, y);
		}
		q.limbs[j] = qhat;
	}
	q.normalize(m + 1);
	q.positive = q_pos;
	q.fix_zero_sign();
	// D8: remainder = u[0:n] >> s; restore y.
	assert(r.limbs.len >= n);
	sz rlen = llshr(r.limbs, u[:n], (usz)s);
	r.normalize(rlen);
	r.positive = x_pos;
	r.fix_zero_sign();
	if (s != 0) llshr(y, y, (usz)s);
}

<* Copies a and b into limbs_buffer as Zig's divTrunc does; returns |b|'s copy through *y_copy. *>
fn void div_setup(BigIntMutable* q, BigIntMutable* r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer, Limb[]* y_copy)
{
	assert(!b.eql_zero(), "division by zero");
	assert(q != r);
	sz sep = a.limbs.len + 2;
	assert(limbs_buffer.len >= sep + b.limbs.len, "limbs_buffer too small for division");
	Limb[] x = limbs_buffer[:sep];
	Limb[] y = limbs_buffer[sep:b.limbs.len];
	for (sz i = 0; i < a.limbs.len; i++) x[i] = a.limbs[i];
	x[a.limbs.len] = 0;
	x[a.limbs.len + 1] = 0;
	for (sz i = 0; i < b.limbs.len; i++) y[i] = b.limbs[i];
	div_impl(q, r, x, a.limbs.len, y, a.positive, b.positive);
	*y_copy = y;
}

<*
 Mutable.divTrunc: q = a / b rounded toward zero, r = a - q*b (sign of a).
 q may alias a or b. q needs a.len limbs, r needs b.len limbs, `limbs_buffer`
 calc_div_limbs_buffer_len(a.len, b.len).
 @require !b.eql_zero() : "division by zero"
*>
fn void div_trunc(BigIntMutable* q, BigIntMutable* r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer)
{
	Limb[] y;
	div_setup(q, r, a, b, limbs_buffer, &y);
}

<*
 Mutable.divFloor: q = floor(a / b), r = a - q*b (sign of b).
 Same storage rules as div_trunc.
 @require !b.eql_zero() : "division by zero"
*>
fn void div_floor(BigIntMutable* q, BigIntMutable* r, BigIntConst a, BigIntConst b, Limb[] limbs_buffer)
{
	bool a_pos = a.positive;
	bool b_pos = b.positive;
	Limb[] y;
	div_setup(q, r, a, b, limbs_buffer, &y);
	BigIntConst y_abs = { .limbs = y, .positive = true };
	if (a_pos == b_pos)
	{
		// Same signs: truncation already floors; @mod(-a, -b) = -@rem(a, b) = r.
		return;
	}
	if (r.to_const().eql_zero()) return;
	q.add_scalar(q.to_const(), -1);
	if (a_pos)
	{
		// a / -b: mod = rem - |b| (non-positive).
		r.positive = true;
		r.sub(r.to_const(), y_abs);
	}
	else
	{
		// -a / b: mod = |b| - |rem| (positive).
		r.positive = false;
		r.add(r.to_const(), y_abs);
	}
}

<*
 r = remainder of truncating division (C `%`, @rem): the `r` of div_trunc.
 Allocates its quotient/scratch from `gpa` and frees it before returning.
 r needs b.len limbs.
 @require !b.eql_zero() : "division by zero"
*>
fn void BigIntMutable.rem(&r, Allocator gpa, BigIntConst a, BigIntConst b)
{
	sz q_len = a.limbs.len;
	Limb[] scratch = alloc::alloc_array(gpa, Limb, q_len + calc_div_limbs_buffer_len(a.limbs.len, b.limbs.len));
	defer alloc::free(gpa, scratch.ptr);
	BigIntMutable q = { .limbs = scratch[:q_len], .len = 1, .positive = true };
	div_trunc(&q, r, a, b, scratch[q_len..]);
}

<*
 r = remainder of flooring division (@mod): the `r` of div_floor.
 Allocates scratch from `gpa` and frees it before returning. r needs b.len limbs.
 @require !b.eql_zero() : "division by zero"
*>
fn void BigIntMutable.mod(&r, Allocator gpa, BigIntConst a, BigIntConst b)
{
	sz q_len = a.limbs.len + 1;
	Limb[] scratch = alloc::alloc_array(gpa, Limb, q_len + calc_div_limbs_buffer_len(a.limbs.len, b.limbs.len));
	defer alloc::free(gpa, scratch.ptr);
	BigIntMutable q = { .limbs = scratch[:q_len], .len = 1, .positive = true };
	div_floor(&q, r, a, b, scratch[q_len..]);
}

// ---------------------------------------------------------------------------
// Shifts and bitwise operations
// ---------------------------------------------------------------------------

<* Mutable.shiftLeft: r = a * 2^shift. r and a may alias. Needs a.len + shift / 64 + 1 limbs. *>
fn void BigIntMutable.shift_left(&r, BigIntConst a, usz shift)
{
	bool positive = a.positive;
	if (a.eql_zero())
	{
		r.set_u64(0);
		return;
	}
	sz new_len = llshl(r.limbs, a.limbs, shift);
	r.normalize(new_len);
	r.positive = positive;
}

<*
 Mutable.shiftRight: r = a >> shift, rounding toward negative infinity
 (negative values converge to -1, never 0). r and a may alias.
 Needs max(a.len - shift / 64, 1) limbs.
*>
fn void BigIntMutable.shift_right(&r, BigIntConst a, usz shift)
{
	usz full = shift / LIMB_BITS;
	usz rem_bits = shift % LIMB_BITS;
	if ((usz)a.limbs.len <= full)
	{
		r.len = 1;
		r.positive = a.positive;
		r.limbs[0] = a.positive ? 0 : 1;
		return;
	}
	bool nonzero_negative_shiftout = false;
	if (!a.positive)
	{
		for (usz i = 0; i < full; i++)
		{
			if (a.limbs[i] != 0)
			{
				nonzero_negative_shiftout = true;
				break;
			}
		}
		if (!nonzero_negative_shiftout && rem_bits != 0)
		{
			nonzero_negative_shiftout = (a.limbs[full] << (LIMB_BITS - rem_bits)) != 0;
		}
	}
	bool positive = a.positive;
	sz new_len = llshr(r.limbs, a.limbs, shift);
	r.len = new_len;
	r.positive = positive;
	if (nonzero_negative_shiftout) r.add_scalar(r.to_const(), -1);
	r.normalize(r.len);
	r.fix_zero_sign();
}

<* Mutable.bitNotWrap: r = ~a as a `bit_count`-bit integer of `signedness`. Needs calc_twos_comp_limb_count(bit_count) limbs. *>
fn void BigIntMutable.bit_not_wrap(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	r.copy(a.negate());
	Limb[1] one = { 1 };
	BigIntConst negative_one = { .limbs = one[..], .positive = false };
	r.add_wrap(r.to_const(), negative_one, signedness, bit_count);
}

<* llsignedor: r = a | b (two's complement), a.len >= b.len, both non-zero. Returns the sign. *>
fn bool llsignedor(Limb[] r, Limb[] a, bool a_positive, Limb[] b, bool b_positive)
{
	assert(r.len >= a.len && a.len >= b.len);
	sz i = 0;
	if (a_positive && b_positive)
	{
		for (; i < b.len; i++) r[i] = a[i] | b[i];
		for (; i < a.len; i++) r[i] = a[i];
		return true;
	}
	if (!a_positive && b_positive)
	{
		// r = -(((|a| - 1) & ~b) + 1)
		Limb a_borrow = 1;
		Limb r_carry = 1;
		for (; i < b.len; i++)
		{
			Limb t = sub_limb(a[i], 0, &a_borrow);
			r[i] = add_limb(t & ~b[i], 0, &r_carry);
		}
		assert(r_carry == 0);
		for (; i < a.len; i++) r[i] = sub_limb(a[i], 0, &a_borrow);
		assert(a_borrow == 0);
		return false;
	}
	if (a_positive && !b_positive)
	{
		// r = -((~a & (|b| - 1)) + 1); upper limbs are zero.
		Limb b_borrow = 1;
		Limb r_carry = 1;
		for (; i < b.len; i++)
		{
			Limb t = sub_limb(b[i], 0, &b_borrow);
			r[i] = add_limb(~a[i] & t, 0, &r_carry);
		}
		assert(b_borrow == 0 && r_carry == 0);
		return false;
	}
	// r = -(((|a| - 1) & (|b| - 1)) + 1); upper limbs are zero.
	Limb a_borrow = 1;
	Limb b_borrow = 1;
	Limb r_carry = 1;
	for (; i < b.len; i++)
	{
		Limb ta = sub_limb(a[i], 0, &a_borrow);
		Limb tb = sub_limb(b[i], 0, &b_borrow);
		r[i] = add_limb(ta & tb, 0, &r_carry);
	}
	assert(b_borrow == 0 && r_carry == 0);
	return false;
}

<* llsignedand: r = a & b (two's complement), a.len >= b.len, both non-zero. Returns the sign. *>
fn bool llsignedand(Limb[] r, Limb[] a, bool a_positive, Limb[] b, bool b_positive)
{
	assert(a.len >= b.len);
	sz i = 0;
	if (a_positive && b_positive)
	{
		for (; i < b.len; i++) r[i] = a[i] & b[i];
		return true;
	}
	if (!a_positive && b_positive)
	{
		Limb a_borrow = 1;
		for (; i < b.len; i++) r[i] = ~sub_limb(a[i], 0, &a_borrow) & b[i];
		return true;
	}
	if (a_positive && !b_positive)
	{
		Limb b_borrow = 1;
		for (; i < b.len; i++) r[i] = a[i] & ~sub_limb(b[i], 0, &b_borrow);
		assert(b_borrow == 0);
		for (; i < a.len; i++) r[i] = a[i];
		return true;
	}
	// r = -(((|a| - 1) | (|b| - 1)) + 1)
	assert(r.len >= a.len + 1);
	Limb a_borrow = 1;
	Limb b_borrow = 1;
	Limb r_carry = 1;
	for (; i < b.len; i++)
	{
		Limb ta = sub_limb(a[i], 0, &a_borrow);
		Limb tb = sub_limb(b[i], 0, &b_borrow);
		r[i] = add_limb(ta | tb, 0, &r_carry);
	}
	assert(b_borrow == 0);
	for (; i < a.len; i++)
	{
		Limb ta = sub_limb(a[i], 0, &a_borrow);
		r[i] = add_limb(ta, 0, &r_carry);
	}
	assert(a_borrow == 0);
	r[i] = r_carry;
	return false;
}

<* llsignedxor: r = a ^ b (two's complement), a.len >= b.len, both non-zero. Returns the sign. *>
fn bool llsignedxor(Limb[] r, Limb[] a, bool a_positive, Limb[] b, bool b_positive)
{
	assert(r.len >= a.len && a.len >= b.len);
	Limb a_borrow = a_positive ? 0 : 1;
	Limb b_borrow = b_positive ? 0 : 1;
	Limb r_carry = a_positive != b_positive ? 1 : 0;
	sz i = 0;
	for (; i < b.len; i++)
	{
		Limb ta = sub_limb(a[i], 0, &a_borrow);
		Limb tb = sub_limb(b[i], 0, &b_borrow);
		r[i] = add_limb(ta ^ tb, 0, &r_carry);
	}
	for (; i < a.len; i++)
	{
		Limb ta = sub_limb(a[i], 0, &a_borrow);
		r[i] = add_limb(ta, 0, &r_carry);
	}
	if (a_positive != b_positive)
	{
		assert(r.len > i);
		r[i] = r_carry;
	}
	else
	{
		assert(r_carry == 0);
	}
	assert(a_borrow == 0 && b_borrow == 0);
	return a_positive == b_positive;
}

<* Mutable.bitOr under infinite two's complement. r may alias a or b. Needs max(a.len, b.len) limbs. *>
fn void BigIntMutable.bit_or(&r, BigIntConst a, BigIntConst b)
{
	if (a.eql_zero())
	{
		r.copy(b);
		return;
	}
	if (b.eql_zero())
	{
		r.copy(a);
		return;
	}
	if (a.limbs.len >= b.limbs.len)
	{
		sz len = b.positive ? a.limbs.len : b.limbs.len;
		r.positive = llsignedor(r.limbs, a.limbs, a.positive, b.limbs, b.positive);
		r.normalize(len);
	}
	else
	{
		sz len = a.positive ? b.limbs.len : a.limbs.len;
		r.positive = llsignedor(r.limbs, b.limbs, b.positive, a.limbs, a.positive);
		r.normalize(len);
	}
	r.fix_zero_sign();
}

<*
 Mutable.bitAnd under infinite two's complement. r may alias a or b. Needs:
 both positive min(a.len, b.len); one positive that one's len; both negative
 max(a.len, b.len) + 1.
*>
fn void BigIntMutable.bit_and(&r, BigIntConst a, BigIntConst b)
{
	if (a.eql_zero())
	{
		r.copy(a);
		return;
	}
	if (b.eql_zero())
	{
		r.copy(b);
		return;
	}
	if (a.limbs.len >= b.limbs.len)
	{
		sz len = b.positive ? b.limbs.len : a.positive ? a.limbs.len : a.limbs.len + 1;
		r.positive = llsignedand(r.limbs, a.limbs, a.positive, b.limbs, b.positive);
		r.normalize(len);
	}
	else
	{
		sz len = a.positive ? a.limbs.len : b.positive ? b.limbs.len : b.limbs.len + 1;
		r.positive = llsignedand(r.limbs, b.limbs, b.positive, a.limbs, a.positive);
		r.normalize(len);
	}
	r.fix_zero_sign();
}

<* Mutable.bitXor under infinite two's complement. r may alias a or b. Needs max(a.len, b.len) (+1 if signs differ) limbs. *>
fn void BigIntMutable.bit_xor(&r, BigIntConst a, BigIntConst b)
{
	if (a.eql_zero())
	{
		r.copy(b);
		return;
	}
	if (b.eql_zero())
	{
		r.copy(a);
		return;
	}
	sz extra = a.positive != b.positive ? 1 : 0;
	if (a.limbs.len > b.limbs.len)
	{
		sz len = a.limbs.len + extra;
		r.positive = llsignedxor(r.limbs, a.limbs, a.positive, b.limbs, b.positive);
		r.normalize(len);
	}
	else
	{
		sz len = b.limbs.len + extra;
		r.positive = llsignedxor(r.limbs, b.limbs, b.positive, a.limbs, a.positive);
		r.normalize(len);
	}
	r.fix_zero_sign();
}

<*
 Mutable.truncate: r = a reduced to a `bit_count`-bit two's-complement integer of
 `signedness` (wraps; e.g. 255 -> -1 for signed 8 bits, -1 -> 255 unsigned).
 r may alias a. Needs max(calc_twos_comp_limb_count(bit_count), 1) limbs.
*>
fn void BigIntMutable.truncate(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	if (bit_count == 0)
	{
		r.set_u64(0);
		return;
	}
	sz max_limbs = calc_twos_comp_limb_count(bit_count);
	Limb sign_bit = (Limb)1 << ((bit_count - 1) % LIMB_BITS);
	Limb mask = LIMB_MAX >> ((LIMB_BITS - bit_count % LIMB_BITS) % LIMB_BITS);
	bool a_positive = a.positive;
	bool same_sign_guess;
	if (signedness == SIGNED)
	{
		same_sign_guess = max_limbs > a.limbs.len || (a.limbs[max_limbs - 1] & sign_bit) == 0;
	}
	else
	{
		same_sign_guess = a_positive;
	}
	sz trunc_len = a.limbs.len < max_limbs ? a.limbs.len : max_limbs;
	BigIntConst abs_trunc_a = { .positive = true, .limbs = a.limbs[:llnormalize(a.limbs[:trunc_len])] };
	if (same_sign_guess || abs_trunc_a.eql_zero())
	{
		r.copy(abs_trunc_a);
		if (max_limbs <= r.len) r.limbs[max_limbs - 1] &= mask;
		r.normalize(r.len);
		r.positive = a_positive || r.to_const().eql_zero();
		return;
	}
	assert(r.limbs.len >= max_limbs, "truncate: result does not fit");
	r.add_scalar(abs_trunc_a, -1);
	llnot(r.limbs[:r.len]);
	for (sz i = r.len; i < max_limbs; i++) r.limbs[i] = LIMB_MAX;
	r.limbs[max_limbs - 1] &= mask;
	r.normalize(max_limbs);
	if (signedness == SIGNED)
	{
		r.positive = !a_positive && (r.limbs[max_limbs - 1] & sign_bit) == 0;
	}
	else
	{
		r.positive = !a_positive || r.to_const().eql_zero();
	}
	r.fix_zero_sign();
}

<* Mutable.saturate: clamp a to the `bit_count`-bit range of `signedness`. r may alias a. *>
fn void BigIntMutable.saturate(&r, BigIntConst a, Signedness signedness, usz bit_count)
{
	if (!a.fits_in_twos_comp(signedness, bit_count))
	{
		r.set_twos_comp_int_limit(a.positive ? MAX : MIN, signedness, bit_count);
		return;
	}
	r.copy(a);
}

// ---------------------------------------------------------------------------
// Queries (Const)
// ---------------------------------------------------------------------------

<* Const.abs (shares limbs). *>
fn BigIntConst BigIntConst.abs(self) => { .limbs = self.limbs, .positive = true };

<* Const.negate (shares limbs; zero stays positive). *>
fn BigIntConst BigIntConst.negate(self)
{
	return { .limbs = self.limbs, .positive = !self.positive || self.eql_zero() };
}

fn bool BigIntConst.is_odd(self) => (self.limbs[0] & 1) != 0;

fn bool BigIntConst.is_even(self) => !self.is_odd();

<* Const.bitCountAbs: bits needed for |self| (0 for zero). *>
fn usz BigIntConst.bit_count_abs(self)
{
	Limb top = self.limbs[self.limbs.len - 1];
	usz top_bits = top == 0 ? 0 : LIMB_BITS - (usz)top.clz();
	return (usz)(self.limbs.len - 1) * LIMB_BITS + top_bits;
}

<*
 Const.bitCountTwosComp: for negative values the bits of the smallest signed
 type holding it (-127 -> 8, -128 -> 8, -129 -> 9); for non-negative values the
 bits of the smallest unsigned type (127 -> 7, 0 -> 0).
*>
fn usz BigIntConst.bit_count_twos_comp(self)
{
	usz bits = self.bit_count_abs();
	if (!self.positive)
	{
		bits++;
		if (self.limbs[self.limbs.len - 1].popcount() == 1)
		{
			for (sz i = 0; i < self.limbs.len - 1; i++)
			{
				if (self.limbs[i] != 0) return bits;
			}
			bits--;
		}
	}
	return bits;
}

<* Const.bitCountTwosCompForSignedness: bit_count_twos_comp, +1 for non-negative signed. *>
fn usz BigIntConst.bit_count_twos_comp_for_signedness(self, Signedness signedness)
{
	return self.bit_count_twos_comp() + (usz)(self.positive && signedness == SIGNED ? 1 : 0);
}

<* Const.fitsInTwosComp: whether self is representable in `bit_count` bits of `signedness`. *>
fn bool BigIntConst.fits_in_twos_comp(self, Signedness signedness, usz bit_count)
{
	if (self.eql_zero()) return true;
	if (signedness == UNSIGNED && !self.positive) return false;
	return bit_count >= self.bit_count_twos_comp_for_signedness(signedness);
}

<* Const.orderAbs: compare magnitudes. *>
fn BigIntOrder BigIntConst.order_abs(a, BigIntConst b)
{
	if (a.limbs.len < b.limbs.len) return LT;
	if (a.limbs.len > b.limbs.len) return GT;
	for (sz i = a.limbs.len; i > 0; i--)
	{
		Limb x = a.limbs[i - 1];
		Limb y = b.limbs[i - 1];
		if (x < y) return LT;
		if (x > y) return GT;
	}
	return EQ;
}

<* Const.order: signed comparison. *>
fn BigIntOrder BigIntConst.order(a, BigIntConst b)
{
	if (a.positive != b.positive)
	{
		if (a.eql_zero() && b.eql_zero()) return EQ;
		return a.positive ? GT : LT;
	}
	BigIntOrder r = a.order_abs(b);
	if (a.positive) return r;
	switch (r)
	{
		case LT: return GT;
		case EQ: return EQ;
		case GT: return LT;
	}
}

<* Const.orderAgainstScalar (signed 64-bit scalar). *>
fn BigIntOrder BigIntConst.order_against_i64(a, long scalar)
{
	Limb[1] buf;
	return a.order(init_i64(buf[..], scalar).to_const());
}

<* Const.eqlZero *>
fn bool BigIntConst.eql_zero(a)
{
	Limb d = 0;
	foreach (l : a.limbs) d |= l;
	return d == 0;
}

<* Const.eqlAbs *>
fn bool BigIntConst.eql_abs(a, BigIntConst b) => a.order_abs(b) == EQ;

<* Const.eql *>
fn bool BigIntConst.eql(a, BigIntConst b) => a.order(b) == EQ;

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

<*
 Const.toInt(u64)
 Note (Zig order of checks): a negative non-zero value fails `fitsInTwosComp`
 first, so it reports TARGET_TOO_SMALL, exactly like Zig 0.17.0.
 @return? NEGATIVE_INTO_UNSIGNED, TARGET_TOO_SMALL
*>
fn ulong? BigIntConst.to_u64(self)
{
	if (self.eql_zero()) return 0;
	if (!self.fits_in_twos_comp(UNSIGNED, 64)) return TARGET_TOO_SMALL~;
	if (!self.positive) return NEGATIVE_INTO_UNSIGNED~;
	return self.limbs[0];
}

<*
 Const.toInt(i64)
 @return? TARGET_TOO_SMALL
*>
fn long? BigIntConst.to_i64(self)
{
	if (self.eql_zero()) return 0;
	if (!self.fits_in_twos_comp(SIGNED, 64)) return TARGET_TOO_SMALL~;
	ulong m = self.limbs[0];
	return self.positive ? (long)m : (long)(0 - m);
}

<*
 Const.toInt(u32) (Interner.put's small-int check)
 @return? NEGATIVE_INTO_UNSIGNED, TARGET_TOO_SMALL
*>
fn uint? BigIntConst.to_u32(self)
{
	if (self.eql_zero()) return 0;
	if (!self.fits_in_twos_comp(UNSIGNED, 32)) return TARGET_TOO_SMALL~;
	if (!self.positive) return NEGATIVE_INTO_UNSIGNED~;
	return (uint)self.limbs[0];
}

<*
 Const.toInt(i32)
 @return? TARGET_TOO_SMALL
*>
fn int? BigIntConst.to_i32(self)
{
	if (self.eql_zero()) return 0;
	if (!self.fits_in_twos_comp(SIGNED, 32)) return TARGET_TOO_SMALL~;
	ulong m = self.limbs[0];
	return (int)(self.positive ? (long)m : (long)(0 - m));
}

fn usz floor_log2_base(char base) @inline => 63 - (usz)((ulong)base).clz();

<*
 Const.sizeInBaseUpperBound: chars needed to print self in `base` (includes a
 minus sign; may overestimate by 1-2).
*>
fn sz BigIntConst.size_in_base_upper_bound(self, char base)
{
	usz bit_count = (usz)(self.positive ? 0 : 1) + self.bit_count_abs();
	return (sz)(bit_count / floor_log2_base(base) + 2);
}

fn char digit_to_char(Limb d, bool upper) @inline
{
	if (d < 10) return (char)('0' + d);
	return (char)((upper ? 'A' : 'a') + (d - 10));
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
	if (self.eql_zero())
	{
		buf[0] = '0';
		return 1;
	}
	sz n = 0;
	if ((base & (base - 1)) == 0)
	{
		// Power of two: extract log2(base)-bit digits from the bit stream, least
		// significant first (digits may straddle limbs for bases 8 and 32).
		usz shift = floor_log2_base(base);
		usz total_bits = self.bit_count_abs();
		Limb dmask = (Limb)base - 1;
		for (usz bit = 0; bit < total_bits; bit += shift)
		{
			usz li = bit / LIMB_BITS;
			usz bo = bit % LIMB_BITS;
			Limb d = self.limbs[li] >> bo;
			if (bo + shift > LIMB_BITS && li + 1 < (usz)self.limbs.len)
			{
				d |= self.limbs[li + 1] << (LIMB_BITS - bo);
			}
			buf[n++] = digit_to_char(d & dmask, upper);
		}
	}
	else
	{
		// Divide by the largest power of `base` that fits in a limb, emitting
		// that many digits per division.
		Limb big_base = base;
		usz digits_per_limb = 1;
		while (big_base <= LIMB_MAX / base)
		{
			big_base *= base;
			digits_per_limb++;
		}
		assert(limbs_buffer.len >= self.limbs.len, "limbs_buffer too small for to_string");
		Limb[] q = limbs_buffer[:self.limbs.len];
		for (sz i = 0; i < self.limbs.len; i++) q[i] = self.limbs[i];
		sz qlen = self.limbs.len;
		while (qlen >= 2)
		{
			Limb rem = 0;
			for (sz i = qlen; i > 0; i--) q[i - 1] = div_wide(rem, q[i - 1], big_base, &rem);
			qlen = llnormalize(q[:qlen]);
			for (usz k = 0; k < digits_per_limb; k++)
			{
				buf[n++] = digit_to_char(rem % base, upper);
				rem /= base;
			}
		}
		Limb w = q[0];
		while (w != 0)
		{
			buf[n++] = digit_to_char(w % base, upper);
			w /= base;
		}
	}
	if (!self.positive) buf[n++] = '-';
	for (sz i = 0; i < n / 2; i++)
	{
		char t = buf[i];
		buf[i] = buf[n - 1 - i];
		buf[n - 1 - i] = t;
	}
	return n;
}

<*
 Const.toStringAlloc: like to_string, returning a new `gpa` allocation the caller
 frees (`alloc::free(gpa, s.ptr)`). Decimal printing of Value ints uses base 10.
 @require base >= 2 && base <= 36
*>
fn String BigIntConst.to_string_alloc(self, Allocator gpa, char base, bool upper)
{
	if (self.eql_zero())
	{
		char[] z = alloc::alloc_array(gpa, char, 1);
		z[0] = '0';
		return (String)z;
	}
	char[] s = alloc::alloc_array(gpa, char, self.size_in_base_upper_bound(base));
	sz scratch_len = calc_to_string_limbs_buffer_len(self.limbs.len, base);
	Limb[] scratch;
	if (scratch_len > 0) scratch = alloc::alloc_array(gpa, Limb, scratch_len);
	defer
	{
		if (scratch_len > 0) alloc::free(gpa, scratch.ptr);
	}
	sz n = self.to_string(s, base, upper, scratch);
	return (String)s[:n];
}
