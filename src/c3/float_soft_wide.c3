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
//     DEFAULT_NAN_F80 (negative real indefinite).
//   - Every operation ORs IEEE flags into `*status` when it is not null:
//     INVALID (sNaN operand, inf-inf, 0*inf, 0/0, inf/inf), DIV_BY_ZERO (finite
//     nonzero / 0), OVERFLOW (rounded result exceeds the largest finite; result
//     inf for NEAREST_EVEN, largest finite for TOWARD_ZERO), UNDERFLOW (tiny after
//     rounding AND inexact), INEXACT. Exact results raise nothing.
//   - Signed zero: x + (-x) = +0 for NEAREST_EVEN (and TOWARD_ZERO); -0 + -0 = -0;
//     the sign of a zero product/quotient is the XOR of the operand signs.
//
// Reference behaviour pinned by running Zig 0.17.0 (x86_64-linux, see
// test/c3/float_wide_tests.c3 for the vectors) and kept here on purpose:
//   - f128 `a - b` is __subtf3 = __addtf3(a, -b): when only b is NaN the result
//     is b quieted WITH ITS SIGN FLIPPED.
//   - x87 NaN selection (f80): an unnormal / pseudo-NaN / pseudo-infinity
//     operand (exponent != 0, integer bit 0) gives the default NaN (invalid)
//     even when the other operand is a NaN. Otherwise, of two NaNs a quiet one
//     beats a signaling one, then the larger 64-bit significand wins, and on
//     equal significands the positive one wins; the result is quieted. x87 fsub
//     does not flip the sign of a NaN. Pseudo-denormals (exponent 0, integer bit
//     1) are valid operands with the value of biased exponent 1; results are
//     always canonical encodings.
//   - f80 -> f128 is compiler-rt __extendxftf2 on the bits: a pseudo-denormal
//     LOSES its integer bit (0x0000_8000_0000_0000_0001 -> f128 subnormal
//     2^-16494 * 2^... i.e. fraction 1 << 49), an unnormal becomes an f128
//     subnormal with its fraction, a pseudo-infinity becomes +-inf, and NaN
//     quiet bits are kept as is. So to_f128 is exact for every CANONICAL f80
//     encoding only (Aro never creates the others).
//   - f128 -> f80 is compiler-rt __trunctfxf2: a NaN keeps its quiet bit as is
//     (it is NOT quieted) and its fraction is truncated, so a signaling NaN whose
//     payload sits only in the low 49 fraction bits becomes +-INFINITY.
//   - f128 -> f16/f32/f64 (truncf.zig) and f16/f32/f64 -> f128 (extendf.zig) are
//     correctly rounded / exact; narrowing NaNs are quieted, widening NaNs keep
//     their quiet bit.
//   - @mulAdd(f128) is compiler-rt fma.zig fma_f128 (musl's algorithm over
//     __addtf3/__multf3 and std.math ldexp/frexp/ilogb), ported literally below
//     so that its quirks are reproduced. Known quirk: std.math.ldexp(+-0, n)
//     for 114 <= n is not zero (it builds the normal number 2^(n-113-16383)), and
//     fma_f128's exact-cancellation path calls it, so
//     fma(2^60, 2^60, -2^120) = 2^-16374 instead of +0. Special cases: a
//     non-finite z with finite x, y is returned unchanged (not quieted). Status
//     flags of f128_mul_add are those of the exact IEEE operation, not of the
//     literal algorithm's intermediate steps. The optimised compiler-rt build
//     passes the last addition of dd_add128 to __addtf3 with its operands
//     swapped; with finite values this is invisible, but when x*y is so much
//     smaller than z that ldexp(zs, -spread) overflows to inf, the NaNs that
//     follow make the result 0x7FFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF
//     (a source-level Debug build of the same code gives 0xFFFF_8000..0001).
//   - f128 `/` (__divtf3) is correctly rounded except when the quotient is
//     below the smallest normal (writtenExponent < 1 in divtf3.zig):
//       writtenExponent == 0: the 113-bit quotient's implicit bit is cleared
//         but the quotient is NOT shifted right (result about twice too large);
//       writtenExponent < 0: rounded at 113 bits, then shifted right by
//         (1 - writtenExponent) mod 128 (the u7 @intCast truncates in the
//         optimised build) with truncation, and +-0 when that shift is > 112.
//     An exact power-of-two mantissa ratio is computed one binade lower as
//     (2^113 - 1) plus a round-up, which makes min_normal / 2 come out right.
//     Status flags of f128_div describe the correctly rounded operation.
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
	FloatFormat fmt = format_of(self.tag);
	Unpacked u = { .cls = self.classify(), .sign = self.signbit() };
	switch (u.cls)
	{
		case ZERO:
		case INFINITE:
			return u;
		case NAN:
			u.sig = self.fraction();
			return u;
		case SUBNORMAL:
		case NORMAL:
			int be = (int)self.biased_exponent();
			if (be == 0) be = 1;
			if (fmt.explicit_int)
			{
				u.sig = (uint128)self.f80.lo;
			}
			else
			{
				u.sig = self.fraction();
				if (u.cls == NORMAL) u.sig |= (uint128)1 << fmt.frac_bits;
			}
			u.exp = be - fmt.bias - fmt.frac_bits;
			return u;
	}
}

// -----------------------------------------------------------------------------
// Private helpers (prefixed `wide_` because the module is shared by five files)
// -----------------------------------------------------------------------------

fn void wide_raise(FloatStatus* status, FloatStatus flags) @local
{
	if (status) *status = *status | flags;
}

<* Number of significant bits of x (0 for 0). *>
fn int wide_bitlen(uint128 x) @local => x == 0 ? 0 : 128 - (int)x.clz();

fn uint128 wide_f128_bits(F128Bits x) @local => (uint128)x.hi << 64 | (uint128)x.lo;
fn F128Bits wide_f128_from(uint128 x) @local => { .lo = (ulong)x, .hi = (ulong)(x >> 64) };

<* Low `n` bits set, 0 <= n <= 128. *>
fn uint128 wide_low_mask(long n) @local
{
	if (n <= 0) return 0;
	if (n >= 128) return ~(uint128)0;
	return ((uint128)1 << n) - 1;
}

struct WideRounded @local
{
	uint128 m;
	bool inexact;
}

<*
 Round sig * 2^exp (+ sticky) to an integer multiple of 2^lsb with `rm`. The
 caller guarantees the result fits (lsb is at or above msb - (precision - 1)).
*>
fn WideRounded wide_round_at(uint128 sig, long exp, bool sticky, long lsb, RoundingMode rm) @local
{
	long shift = lsb - exp;
	uint128 m;
	bool round_bit = false;
	bool st = sticky;
	if (shift <= 0)
	{
		m = sig == 0 ? 0 : sig << (-shift);
	}
	else if (shift > 128)
	{
		m = 0;
		st = st || sig != 0;
	}
	else if (shift == 128)
	{
		m = 0;
		round_bit = (sig >> 127) != 0;
		st = st || (sig & wide_low_mask(127)) != 0;
	}
	else
	{
		m = sig >> shift;
		round_bit = ((sig >> (shift - 1)) & 1) != 0;
		st = st || (sig & wide_low_mask(shift - 1)) != 0;
	}
	if (rm == NEAREST_EVEN && round_bit && (st || (m & 1) != 0)) m++;
	return { m, round_bit || st };
}

<*
 Round the exact value (-1)^sign * (sig + (sticky ? delta : 0)) * 2^exp, where
 0 < delta < 1 stands for nonzero bits below sig's least significant bit, to the
 format `tag` with `rm`. sig may be any uint128 (including 0 -> signed zero) and
 exp any int; overflow, subnormal results, the f80 explicit integer bit and the
 status flags are handled here. This is the single rounding primitive every
 soft conversion and operation should use.
 Callers that pass `sticky` must give sig at least two bits more than the
 target precision (or a value far below the subnormal range), so that the
 sticky delta can never decide a tie on its own.
*>
fn KeyFloat round_pack(KeyFloatTag tag, bool sign, int exp, uint128 sig, bool sticky, RoundingMode rm = NEAREST_EVEN, FloatStatus* status = null)
{
	FloatFormat fmt = format_of(tag);
	long p = (long)fmt.frac_bits + 1;
	long emin = 1 - (long)fmt.bias;
	long emax = fmt.bias;
	long min_lsb = emin - (p - 1);
	if (sig == 0 && !sticky) return zero(tag, sign);

	long msb = (long)exp + wide_bitlen(sig) - 1;
	long lsb = msb - (p - 1);
	if (lsb < min_lsb) lsb = min_lsb;
	WideRounded r = wide_round_at(sig, exp, sticky, lsb, rm);
	uint128 m = r.m;
	if ((m >> p) != 0)
	{
		m >>= 1;
		lsb++;
	}
	FloatStatus flags;
	if (r.inexact) flags.inexact = true;

	// Tininess after rounding (x86): the value rounded to p bits with an
	// unbounded exponent range is below the smallest normal.
	if (msb < emin)
	{
		bool tiny = true;
		if (rm == NEAREST_EVEN && msb == emin - 1)
		{
			WideRounded r2 = wide_round_at(sig, exp, sticky, msb - (p - 1), rm);
			tiny = (r2.m >> p) == 0;
		}
		if (tiny && r.inexact) flags.underflow = true;
	}

	bool normal = (m >> (p - 1)) != 0;
	long e = lsb + p - 1;
	if (normal && e > emax)
	{
		flags.overflow = true;
		flags.inexact = true;
		wide_raise(status, flags);
		if (rm == NEAREST_EVEN) return inf(tag, sign);
		m = wide_low_mask(p);
		e = emax;
	}
	wide_raise(status, flags);

	uint128 bits;
	if (normal)
	{
		uint128 biased = (uint128)(e + fmt.bias);
		if (fmt.explicit_int)
		{
			bits = biased << 64 | m;
		}
		else
		{
			bits = biased << fmt.frac_bits | (m & wide_low_mask(fmt.frac_bits));
		}
	}
	else
	{
		bits = m;
	}
	if (sign) bits |= sign_mask(tag);
	return from_raw(tag, bits);
}

<*
 Exact conversion of any width to f128 (Zig @floatCast / compiler-rt extendf for
 the widening cases; f128 itself is returned unchanged). Every finite value of
 f16/f32/f64/f80 is representable. NaN: sign kept, payload shifted up into the
 top of the f128 fraction, quiet bit kept as is (extendf.zig does not quiet).
 f80 follows __extendxftf2 bit for bit (see the file header for what it does
 with non-canonical encodings).
*>
fn F128Bits KeyFloat.to_f128(self)
{
	switch (self.tag)
	{
		case F128:
			return self.f128;
		case F80:
			// compiler-rt f128_floatCast_f80, literally.
			ulong fraction = self.f80.lo;
			uint128 sign = (uint128)(self.f80.hi & 0x8000) << 112;
			uint128 exp = (uint128)(self.f80.hi & 0x7FFF);
			uint128 abs_result;
			if (exp == 0 && fraction == 0)
			{
				abs_result = 0;
			}
			else if (exp == 0x7FFF)
			{
				abs_result = (uint128)fraction << 49 | exp << 112;
			}
			else if ((fraction & 0x8000_0000_0000_0000) != 0)
			{
				abs_result = (uint128)(fraction & 0x7FFF_FFFF_FFFF_FFFF) << 49 | exp << 112;
			}
			else
			{
				abs_result = (uint128)fraction << 49;
			}
			return wide_f128_from(abs_result | sign);
		default:
			FloatFormat fmt = format_of(self.tag);
			Unpacked u = self.unpack();
			uint128 sign = u.sign ? (uint128)1 << 127 : 0;
			switch (u.cls)
			{
				case NAN:
					return wide_f128_from(sign | (uint128)0x7FFF << 112 | u.sig << (112 - fmt.frac_bits));
				case INFINITE:
					return inf(F128, u.sign).f128;
				default:
					return round_pack(F128, u.sign, u.exp, u.sig, false).f128;
			}
	}
}

<*
 f128 -> `dest` with one rounding (compiler-rt truncf.zig for narrowing; F128
 returns x unchanged). NaN: sign kept, quiet bit set, top payload bits kept.
 Exception (reference): dest F80 keeps the NaN's quiet bit as is and may turn a
 signaling NaN into an infinity (__trunctfxf2, see the file header).
*>
fn KeyFloat from_f128(F128Bits x, KeyFloatTag dest, RoundingMode rm = NEAREST_EVEN, FloatStatus* status = null)
{
	KeyFloat k = f128_value(x);
	if (dest == F128) return k;
	Unpacked u = k.unpack();
	switch (u.cls)
	{
		case NAN:
			if ((u.sig >> 111) == 0) wide_raise(status, { .invalid = true });
			if (dest == F80)
			{
				ulong lo = (ulong)(u.sig >> 49) | 0x8000_0000_0000_0000;
				ushort hi = u.sign ? 0xFFFF : 0x7FFF;
				return f80_value({ .lo = lo, .hi = hi });
			}
			FloatFormat fmt = format_of(dest);
			uint128 quiet_bit = (uint128)1 << (fmt.frac_bits - 1);
			uint128 payload = (u.sig >> (112 - fmt.frac_bits)) & (quiet_bit - 1);
			uint128 bits = inf(dest).raw() | quiet_bit | payload;
			if (u.sign) bits |= sign_mask(dest);
			return from_raw(dest, bits);
		case INFINITE:
			return inf(dest, u.sign);
		case ZERO:
			return zero(dest, u.sign);
		default:
			return round_pack(dest, u.sign, u.exp, u.sig, false, rm, status);
	}
}

// -----------------------------------------------------------------------------
// 256-bit integer helpers for exact products and sums
// -----------------------------------------------------------------------------

struct WideU256 @local
{
	uint128 hi;
	uint128 lo;
}

fn WideU256 wide_mul256(uint128 a, uint128 b) @local
{
	uint128 a0 = (ulong)a;
	uint128 a1 = a >> 64;
	uint128 b0 = (ulong)b;
	uint128 b1 = b >> 64;
	uint128 p00 = a0 * b0;
	uint128 p01 = a0 * b1;
	uint128 p10 = a1 * b0;
	uint128 p11 = a1 * b1;
	uint128 mid = (p00 >> 64) + (uint128)(ulong)p01 + (uint128)(ulong)p10;
	WideU256 r;
	r.lo = (mid << 64) | (uint128)(ulong)p00;
	r.hi = p11 + (p01 >> 64) + (p10 >> 64) + (mid >> 64);
	return r;
}

fn int wide_bitlen256(WideU256 x) @local => x.hi != 0 ? 128 + wide_bitlen(x.hi) : wide_bitlen(x.lo);

fn WideU256 wide_shl256(WideU256 x, int n) @local
{
	if (n <= 0) return x;
	if (n >= 256) return {};
	if (n >= 128) return { .hi = x.lo << (n - 128), .lo = 0 };
	return { .hi = (x.hi << n) | (x.lo >> (128 - n)), .lo = x.lo << n };
}

<* x >> n; *sticky |= any bit shifted out. *>
fn WideU256 wide_shr256(WideU256 x, long n, bool* sticky) @local
{
	if (n <= 0) return x;
	if (n >= 256)
	{
		if (x.hi != 0 || x.lo != 0) *sticky = true;
		return {};
	}
	if (n >= 128)
	{
		if (x.lo != 0 || (x.hi & wide_low_mask(n - 128)) != 0) *sticky = true;
		return { .hi = 0, .lo = x.hi >> (n - 128) };
	}
	if ((x.lo & wide_low_mask(n)) != 0) *sticky = true;
	return { .hi = x.hi >> n, .lo = (x.lo >> n) | (x.hi << (128 - n)) };
}

fn bool wide_less256(WideU256 a, WideU256 b) @local => a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo);

fn WideU256 wide_add256(WideU256 a, WideU256 b) @local
{
	uint128 lo = a.lo + b.lo;
	uint128 carry = lo < a.lo ? 1 : 0;
	return { .hi = a.hi + b.hi + carry, .lo = lo };
}

fn WideU256 wide_sub256(WideU256 a, WideU256 b) @local
{
	uint128 lo = a.lo - b.lo;
	uint128 borrow = a.lo < b.lo ? 1 : 0;
	return { .hi = a.hi - b.hi - borrow, .lo = lo };
}

<* Round (-1)^sign * x * 2^exp (+ sticky) to `tag`, compressing x to 128 bits first. *>
fn KeyFloat wide_round_pack256(KeyFloatTag tag, bool sign, long exp, WideU256 x, bool sticky, FloatStatus* status) @local
{
	long n = wide_bitlen256(x);
	long e = exp;
	bool st = sticky;
	if (n > 126)
	{
		x = wide_shr256(x, n - 126, &st);
		e += n - 126;
	}
	return round_pack(tag, sign, (int)e, x.lo, st, NEAREST_EVEN, status);
}

// -----------------------------------------------------------------------------
// Exact cores on finite operands (shared by f80 and f128)
// -----------------------------------------------------------------------------

<* a + b for finite a, b (zeros allowed), rounded to nearest even. *>
fn KeyFloat wide_add_core(KeyFloatTag tag, Unpacked a, Unpacked b, FloatStatus* status) @local
{
	bool az = a.cls == ZERO;
	bool bz = b.cls == ZERO;
	if (az && bz) return zero(tag, a.sign && b.sign);
	if (az) return round_pack(tag, b.sign, b.exp, b.sig, false, NEAREST_EVEN, status);
	if (bz) return round_pack(tag, a.sign, a.exp, a.sig, false, NEAREST_EVEN, status);
	// Put both MSBs at bit 124; significands have at most 113 bits, so the low
	// 12 bits are zero and an alignment shift of up to 12 is exact.
	int sha = 124 - (wide_bitlen(a.sig) - 1);
	int shb = 124 - (wide_bitlen(b.sig) - 1);
	uint128 sa = a.sig << sha;
	uint128 sb = b.sig << shb;
	long ea = (long)a.exp - sha;
	long eb = (long)b.exp - shb;
	if (ea < eb || (ea == eb && sa < sb))
	{
		@swap(sa, sb);
		@swap(ea, eb);
		@swap(a, b);
	}
	long d = ea - eb;
	bool sticky = false;
	uint128 ys;
	if (d >= 128)
	{
		ys = 0;
		sticky = true;
	}
	else
	{
		ys = d > 0 ? sb >> d : sb;
		if ((sb & wide_low_mask(d)) != 0) sticky = true;
	}
	uint128 s;
	if (a.sign == b.sign)
	{
		s = sa + ys;
	}
	else
	{
		s = sa - ys;
		if (sticky) s -= 1;
		if (s == 0 && !sticky) return zero(tag, false);
	}
	return round_pack(tag, a.sign, (int)ea, s, sticky, NEAREST_EVEN, status);
}

<* a * b for finite nonzero a, b. *>
fn KeyFloat wide_mul_core(KeyFloatTag tag, Unpacked a, Unpacked b, FloatStatus* status) @local
{
	WideU256 p = wide_mul256(a.sig, b.sig);
	return wide_round_pack256(tag, a.sign != b.sign, (long)a.exp + b.exp, p, false, status);
}

struct WideQuotient @local
{
	<* floor(sa / sb * 2^115), sa and sb normalised to 113 bits *>
	uint128 q;
	bool sticky;
	<* value = q * 2^exp *>
	long exp;
}

<* Exact long division of finite nonzero a by b. *>
fn WideQuotient wide_div_exact(Unpacked a, Unpacked b) @local
{
	int sha = 112 - (wide_bitlen(a.sig) - 1);
	int shb = 112 - (wide_bitlen(b.sig) - 1);
	uint128 sa = a.sig << sha;
	uint128 sb = b.sig << shb;
	long ea = (long)a.exp - sha;
	long eb = (long)b.exp - shb;
	uint128 q = 0;
	uint128 r = sa;
	for (int i = 0; i < 116; i++)
	{
		q <<= 1;
		if (r >= sb)
		{
			r -= sb;
			q |= 1;
		}
		r <<= 1;
	}
	return { q, r != 0, ea - eb - 115 };
}

// -----------------------------------------------------------------------------
// f80 (x87)
// -----------------------------------------------------------------------------

<* Unnormal, pseudo-NaN or pseudo-infinity: x87 rejects it as an invalid operand. *>
fn bool wide_f80_unsupported(F80Bits x) @local => (x.hi & 0x7FFF) != 0 && (x.lo >> 63) == 0;
fn bool wide_f80_canonical_nan(F80Bits x) @local => (x.hi & 0x7FFF) == 0x7FFF && (x.lo >> 63) != 0 && (x.lo << 1) != 0;

<*
 x87 operand checks shared by f80 add/sub/mul/div: returns true and sets *out
 when the result is decided by an invalid encoding or a NaN operand.
*>
fn bool wide_f80_nan_rules(F80Bits a, F80Bits b, F80Bits* out, FloatStatus* status) @local
{
	if (wide_f80_unsupported(a) || wide_f80_unsupported(b))
	{
		wide_raise(status, { .invalid = true });
		*out = DEFAULT_NAN_F80;
		return true;
	}
	bool an = wide_f80_canonical_nan(a);
	bool bn = wide_f80_canonical_nan(b);
	if (!an && !bn) return false;
	const ulong QUIET = 0x4000_0000_0000_0000;
	if ((an && (a.lo & QUIET) == 0) || (bn && (b.lo & QUIET) == 0)) wide_raise(status, { .invalid = true });
	F80Bits pick;
	if (an && bn)
	{
		bool aq = (a.lo & QUIET) != 0;
		bool bq = (b.lo & QUIET) != 0;
		if (aq != bq)
		{
			pick = aq ? a : b;
		}
		else if (a.lo != b.lo)
		{
			pick = a.lo > b.lo ? a : b;
		}
		else
		{
			pick = (a.hi & 0x8000) == 0 ? a : b;
		}
	}
	else
	{
		pick = an ? a : b;
	}
	pick.lo |= QUIET;
	*out = pick;
	return true;
}

fn F80Bits wide_f80_addsub(F80Bits a, F80Bits b, bool negate_b, FloatStatus* status) @local
{
	F80Bits out;
	if (wide_f80_nan_rules(a, b, &out, status)) return out;
	Unpacked ua = f80_value(a).unpack();
	Unpacked ub = f80_value(b).unpack();
	if (negate_b) ub.sign = !ub.sign;
	if (ua.cls == INFINITE)
	{
		if (ub.cls == INFINITE && ua.sign != ub.sign)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F80;
		}
		return inf(F80, ua.sign).f80;
	}
	if (ub.cls == INFINITE) return inf(F80, ub.sign).f80;
	return wide_add_core(F80, ua, ub, status).f80;
}

<* Zig f80 `a + b` (x87). *>
fn F80Bits f80_add(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	return wide_f80_addsub(a, b, false, status);
}

<* Zig f80 `a - b` (x87). *>
fn F80Bits f80_sub(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	return wide_f80_addsub(a, b, true, status);
}

<* Zig f80 `a * b` (x87). *>
fn F80Bits f80_mul(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	F80Bits out;
	if (wide_f80_nan_rules(a, b, &out, status)) return out;
	Unpacked ua = f80_value(a).unpack();
	Unpacked ub = f80_value(b).unpack();
	bool sign = ua.sign != ub.sign;
	if (ua.cls == INFINITE || ub.cls == INFINITE)
	{
		if (ua.cls == ZERO || ub.cls == ZERO)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F80;
		}
		return inf(F80, sign).f80;
	}
	if (ua.cls == ZERO || ub.cls == ZERO) return zero(F80, sign).f80;
	return wide_mul_core(F80, ua, ub, status).f80;
}

<* Zig f80 `a / b` (x87). *>
fn F80Bits f80_div(F80Bits a, F80Bits b, FloatStatus* status = null)
{
	F80Bits out;
	if (wide_f80_nan_rules(a, b, &out, status)) return out;
	Unpacked ua = f80_value(a).unpack();
	Unpacked ub = f80_value(b).unpack();
	bool sign = ua.sign != ub.sign;
	if (ua.cls == INFINITE)
	{
		if (ub.cls == INFINITE)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F80;
		}
		return inf(F80, sign).f80;
	}
	if (ub.cls == INFINITE) return zero(F80, sign).f80;
	if (ua.cls == ZERO)
	{
		if (ub.cls == ZERO)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F80;
		}
		return zero(F80, sign).f80;
	}
	if (ub.cls == ZERO)
	{
		wide_raise(status, { .div_by_zero = true });
		return inf(F80, sign).f80;
	}
	WideQuotient q = wide_div_exact(ua, ub);
	return round_pack(F80, sign, (int)q.exp, q.q, q.sticky, NEAREST_EVEN, status).f80;
}

// -----------------------------------------------------------------------------
// f128 (compiler-rt)
// -----------------------------------------------------------------------------

<* compiler-rt: the first NaN operand (a, then b) quieted; INVALID when either is signaling. *>
fn bool wide_f128_nan_rules(KeyFloat a, KeyFloat b, F128Bits* out, FloatStatus* status) @local
{
	bool an = a.is_nan();
	bool bn = b.is_nan();
	if (!an && !bn) return false;
	if ((an && (a.f128.hi & 0x0000_8000_0000_0000) == 0) || (bn && (b.f128.hi & 0x0000_8000_0000_0000) == 0))
	{
		wide_raise(status, { .invalid = true });
	}
	*out = an ? a.quiet().f128 : b.quiet().f128;
	return true;
}

<* Zig f128 `a + b` (compiler-rt __addtf3). *>
fn F128Bits f128_add(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	KeyFloat ka = f128_value(a);
	KeyFloat kb = f128_value(b);
	F128Bits out;
	if (wide_f128_nan_rules(ka, kb, &out, status)) return out;
	Unpacked ua = ka.unpack();
	Unpacked ub = kb.unpack();
	if (ua.cls == INFINITE)
	{
		if (ub.cls == INFINITE && ua.sign != ub.sign)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F128;
		}
		return a;
	}
	if (ub.cls == INFINITE) return b;
	return wide_add_core(F128, ua, ub, status).f128;
}

<* Zig f128 `a - b` (compiler-rt __subtf3 = a + (-b)). *>
fn F128Bits f128_sub(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	return f128_add(a, { .lo = b.lo, .hi = b.hi ^ 0x8000_0000_0000_0000 }, status);
}

<* Zig f128 `a * b` (compiler-rt __multf3). *>
fn F128Bits f128_mul(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	KeyFloat ka = f128_value(a);
	KeyFloat kb = f128_value(b);
	F128Bits out;
	if (wide_f128_nan_rules(ka, kb, &out, status)) return out;
	Unpacked ua = ka.unpack();
	Unpacked ub = kb.unpack();
	bool sign = ua.sign != ub.sign;
	if (ua.cls == INFINITE || ub.cls == INFINITE)
	{
		if (ua.cls == ZERO || ub.cls == ZERO)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F128;
		}
		return inf(F128, sign).f128;
	}
	if (ua.cls == ZERO || ub.cls == ZERO) return zero(F128, sign).f128;
	return wide_mul_core(F128, ua, ub, status).f128;
}

<* Zig f128 `a / b` (compiler-rt __divtf3). *>
fn F128Bits f128_div(F128Bits a, F128Bits b, FloatStatus* status = null)
{
	KeyFloat ka = f128_value(a);
	KeyFloat kb = f128_value(b);
	F128Bits out;
	if (wide_f128_nan_rules(ka, kb, &out, status)) return out;
	Unpacked ua = ka.unpack();
	Unpacked ub = kb.unpack();
	bool sign = ua.sign != ub.sign;
	if (ua.cls == INFINITE)
	{
		if (ub.cls == INFINITE)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F128;
		}
		return inf(F128, sign).f128;
	}
	if (ub.cls == INFINITE) return zero(F128, sign).f128;
	if (ua.cls == ZERO)
	{
		if (ub.cls == ZERO)
		{
			wide_raise(status, { .invalid = true });
			return DEFAULT_NAN_F128;
		}
		return zero(F128, sign).f128;
	}
	if (ub.cls == ZERO)
	{
		wide_raise(status, { .div_by_zero = true });
		return inf(F128, sign).f128;
	}
	WideQuotient q = wide_div_exact(ua, ub);
	KeyFloat correct = round_pack(F128, sign, (int)q.exp, q.q, q.sticky, NEAREST_EVEN, status);
	// Reproduce __divtf3's subnormal path. Its quotient estimate is strictly
	// below a/b, so an exact power-of-two ratio comes out as (2^113 - 1) one
	// binade lower with the round bit set; otherwise q113 is the truncated
	// 113-bit quotient and `round` its next bit (exact ties cannot occur).
	uint128 q113;
	bool round;
	long ebin = q.exp + wide_bitlen(q.q) - 1;
	if (q.q == (uint128)1 << 115 && !q.sticky)
	{
		q113 = ((uint128)1 << 113) - 1;
		round = true;
		ebin--;
	}
	else
	{
		int extra = wide_bitlen(q.q) - 113;
		q113 = q.q >> extra;
		round = ((q.q >> (extra - 1)) & 1) != 0;
	}
	long written = ebin + 16383;
	if (written >= 1) return correct.f128;
	uint128 sign_bit = sign ? WIDE_F128_SIGN : 0;
	uint128 round_up = round ? 1 : 0;
	if (written == 0)
	{
		// The implicit bit is cleared but the quotient is not shifted.
		return wide_f128_from(((q113 & WIDE_F128_MANT_MASK) + round_up) | sign_bit);
	}
	// `@as(u7, @intCast(1 - writtenExponent))` truncates in the optimised
	// compiler-rt build, and the shift truncates after rounding at 113 bits.
	long shift = (1 - written) & 127;
	if (shift > 112) return wide_f128_from(sign_bit);
	return wide_f128_from((((q113 + round_up) >> shift) & WIDE_F128_MANT_MASK) | sign_bit);
}

// -----------------------------------------------------------------------------
// f128 fused multiply-add
// -----------------------------------------------------------------------------

<* Exact IEEE fma for finite nonzero x, y, z (status flags of f128_mul_add). *>
fn KeyFloat wide_fma_exact(Unpacked x, Unpacked y, Unpacked z, FloatStatus* status) @local
{
	WideU256 p = wide_mul256(x.sig, y.sig);
	bool ps = x.sign != y.sign;
	// Normalise both to MSB at bit 250: the product has <= 226 significant bits
	// and z <= 113, so the low 24 bits are zero and a 24-bit alignment is exact.
	int shp = 250 - (wide_bitlen256(p) - 1);
	int shz = 250 - (wide_bitlen(z.sig) - 1);
	WideU256 a = wide_shl256(p, shp);
	WideU256 b = wide_shl256({ .hi = 0, .lo = z.sig }, shz);
	long ea = (long)x.exp + y.exp - shp;
	long eb = (long)z.exp - shz;
	bool sa = ps;
	bool sb = z.sign;
	if (ea < eb || (ea == eb && wide_less256(a, b)))
	{
		@swap(a, b);
		@swap(ea, eb);
		@swap(sa, sb);
	}
	bool sticky = false;
	b = wide_shr256(b, ea - eb, &sticky);
	WideU256 s;
	if (sa == sb)
	{
		s = wide_add256(a, b);
	}
	else
	{
		s = wide_sub256(a, b);
		if (sticky) s = wide_sub256(s, { .hi = 0, .lo = 1 });
		if (s.hi == 0 && s.lo == 0 && !sticky) return zero(F128, false);
	}
	return wide_round_pack256(F128, sa, ea, s, sticky, status);
}

const uint128 WIDE_F128_SIGN = (uint128)1 << 127;
const uint128 WIDE_F128_MANT_MASK = ((uint128)1 << 112) - 1;
const uint128 WIDE_F128_INF = (uint128)0x7FFF << 112;

fn bool wide_f128_is_finite(F128Bits x) @local => (x.hi & 0x7FFF_0000_0000_0000) != 0x7FFF_0000_0000_0000;
fn bool wide_f128_is_zero(F128Bits x) @local => (x.hi & 0x7FFF_FFFF_FFFF_FFFF) == 0 && x.lo == 0;

<* std.math.ldexp(x, n) for f128 (Zig 0.17.0 lib/std/math/ldexp.zig), literally. *>
fn F128Bits wide_f128_ldexp(F128Bits x, int n) @local
{
	uint128 repr = wide_f128_bits(x);
	uint128 sign_bit = repr & WIDE_F128_SIGN;
	if (!wide_f128_is_finite(x)) return x;
	int exponent = (int)((repr << 1) >> 113);
	if (exponent == 0) exponent += 15 - (int)(repr << 1).clz();
	if (n >= 0)
	{
		if (n > 32766 - exponent) return wide_f128_from(WIDE_F128_INF | sign_bit);
		if (exponent + n <= 0) return wide_f128_from((repr << n) | sign_bit);
		if (exponent <= 0)
		{
			uint128 result = (uint128)(n + exponent) << 112;
			result |= (repr << (1 - exponent)) & WIDE_F128_MANT_MASK;
			return wide_f128_from(result | sign_bit);
		}
		return wide_f128_from(repr + ((uint128)n << 112));
	}
	if (n <= -exponent)
	{
		if (n < -(112 + exponent)) return wide_f128_from(sign_bit);
		int shift = -n;
		if (-(exponent + n) + 1 < shift) shift = -(exponent + n) + 1;
		bool exact_tie = (int)repr.ctz() == shift - 1;
		uint128 result = repr & WIDE_F128_MANT_MASK;
		if (exponent > 0) result |= (uint128)1 << 112;
		result = result >> (shift - 1);
		result = ((result + 1) >> 1) & ~(uint128)(exact_tie ? 1 : 0);
		return wide_f128_from(result | sign_bit);
	}
	return wide_f128_from(repr - ((uint128)(-n) << 112));
}

struct WideFrexp @local
{
	F128Bits significand;
	int exponent;
}

<* std.math.frexp for a finite f128 (lib/std/math/frexp.zig). *>
fn WideFrexp wide_f128_frexp(F128Bits x) @local
{
	uint128 v = wide_f128_bits(x);
	uint128 m = v & WIDE_F128_MANT_MASK;
	uint e = (uint)((v >> 112) & 0x7FFF);
	uint128 zero_exponent = (uint128)16382 << 112;
	WideFrexp r;
	if (e == 0)
	{
		if (m != 0)
		{
			int offset = (int)m.clz() - 16;
			int shift = offset + 1;
			v &= WIDE_F128_SIGN;
			v |= zero_exponent;
			v |= shift >= 112 ? 0 : (m << shift) & WIDE_F128_MANT_MASK;
			r.exponent = -16382 - offset;
		}
		else
		{
			r.exponent = 0;
		}
	}
	else
	{
		v &= ~((uint128)0x7FFF << 112);
		v |= zero_exponent;
		r.exponent = (int)e - 16382;
	}
	r.significand = wide_f128_from(v);
	return r;
}

<* std.math.ilogb for a finite nonzero f128. *>
fn int wide_f128_ilogb(F128Bits x) @local
{
	uint128 u = wide_f128_bits(x) & ~WIDE_F128_SIGN;
	int e = (int)(u >> 112);
	if (e == 0)
	{
		if (u == 0) return int::min;
		return -16367 - (int)u.clz();
	}
	if (e == 0x7FFF) return u > WIDE_F128_INF ? int::min : int::max;
	return e - 16383;
}

struct WideDd @local
{
	F128Bits hi;
	F128Bits lo;
}

fn WideDd wide_dd_add128(F128Bits a, F128Bits b) @local
{
	WideDd ret;
	ret.hi = f128_add(a, b);
	F128Bits s = f128_sub(ret.hi, a);
	// fma.zig writes `(a - (ret.hi - s)) + (b - s)`; the optimised compiler-rt
	// build (Zig 0.17.0, LLVM) passes the operands to __addtf3 swapped, which
	// only matters for which NaN wins. Keep the swapped order (see header).
	ret.lo = f128_add(f128_sub(b, s), f128_sub(a, f128_sub(ret.hi, s)));
	return ret;
}

fn F128Bits wide_add_adjusted128(F128Bits a, F128Bits b) @local
{
	WideDd sum = wide_dd_add128(a, b);
	if (!wide_f128_is_zero(sum.lo))
	{
		uint128 uhii = wide_f128_bits(sum.hi);
		if ((uhii & 1) == 0)
		{
			uint128 uloi = wide_f128_bits(sum.lo);
			uhii = uhii + 1 - ((uhii ^ uloi) >> 126);
			sum.hi = wide_f128_from(uhii);
		}
	}
	return sum.hi;
}

fn F128Bits wide_add_and_denorm128(F128Bits a, F128Bits b, int scale) @local
{
	WideDd sum = wide_dd_add128(a, b);
	if (!wide_f128_is_zero(sum.lo))
	{
		uint128 uhii = wide_f128_bits(sum.hi);
		int bits_lost = -(int)((uhii >> 112) & 0x7FFF) - scale + 1;
		if ((bits_lost != 1) == ((uhii & 1) != 0))
		{
			uint128 uloi = wide_f128_bits(sum.lo);
			uhii = uhii + 1 - (((uhii ^ uloi) >> 126) & 2);
			sum.hi = wide_f128_from(uhii);
		}
	}
	return wide_f128_ldexp(sum.hi, scale);
}

<* 0x1.0p57 + 1.0 *>
const F128Bits WIDE_DD_SPLIT = { .lo = 0x0080_0000_0000_0000, .hi = 0x4038_0000_0000_0000 };

fn WideDd wide_dd_mul128(F128Bits a, F128Bits b) @local
{
	WideDd ret;
	F128Bits p = f128_mul(a, WIDE_DD_SPLIT);
	F128Bits ha = f128_sub(a, p);
	ha = f128_add(ha, p);
	F128Bits la = f128_sub(a, ha);

	p = f128_mul(b, WIDE_DD_SPLIT);
	F128Bits hb = f128_sub(b, p);
	hb = f128_add(hb, p);
	F128Bits lb = f128_sub(b, hb);

	p = f128_mul(ha, hb);
	F128Bits q = f128_add(f128_mul(ha, lb), f128_mul(la, hb));

	ret.hi = f128_add(p, q);
	ret.lo = f128_add(f128_add(f128_sub(p, ret.hi), q), f128_mul(la, lb));
	return ret;
}

<*
 Zig @mulAdd(f128, a, b, c) = a * b + c with a single rounding (compiler-rt
 fma.zig fmaq). Needed by Value.zig bigIntToFloat (a = 2^64).
 Ported literally (including the ldexp(0, n) quirk described in the file
 header); status flags are those of the exact operation.
*>
fn F128Bits f128_mul_add(F128Bits a, F128Bits b, F128Bits c, FloatStatus* status = null)
{
	F128Bits x = a;
	F128Bits y = b;
	F128Bits z = c;
	if (!wide_f128_is_finite(x) || !wide_f128_is_finite(y))
	{
		return f128_add(f128_mul(x, y, status), z, status);
	}
	if (!wide_f128_is_finite(z))
	{
		if (f128_value(z).is_nan() && (z.hi & 0x0000_8000_0000_0000) == 0) wide_raise(status, { .invalid = true });
		return z;
	}
	if (wide_f128_is_zero(x) || wide_f128_is_zero(y))
	{
		return f128_add(f128_mul(x, y, status), z, status);
	}
	if (wide_f128_is_zero(z)) return f128_mul(x, y, status);

	wide_fma_exact(f128_value(x).unpack(), f128_value(y).unpack(), f128_value(z).unpack(), status);

	WideFrexp x1 = wide_f128_frexp(x);
	int ex = x1.exponent;
	F128Bits xs = x1.significand;
	WideFrexp x2 = wide_f128_frexp(y);
	int ey = x2.exponent;
	F128Bits ys = x2.significand;
	WideFrexp x3 = wide_f128_frexp(z);
	int ez = x3.exponent;
	F128Bits zs = x3.significand;

	int spread = ex + ey - ez;
	if (spread <= 113 * 2)
	{
		zs = wide_f128_ldexp(zs, -spread);
	}
	else
	{
		zs = { .lo = 0, .hi = (zs.hi & 0x8000_0000_0000_0000) | 0x0001_0000_0000_0000 };
	}

	WideDd xy = wide_dd_mul128(xs, ys);
	WideDd r = wide_dd_add128(xy.hi, zs);
	spread = ex + ey;

	if (wide_f128_is_zero(r.hi))
	{
		return f128_add(f128_add(xy.hi, zs), wide_f128_ldexp(xy.lo, spread));
	}

	F128Bits adj = wide_add_adjusted128(r.lo, xy.lo);
	if (spread + wide_f128_ilogb(r.hi) > -16383)
	{
		return wide_f128_ldexp(f128_add(r.hi, adj), spread);
	}
	return wide_add_and_denorm128(r.hi, adj, spread);
}
