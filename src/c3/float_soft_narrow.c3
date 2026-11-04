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
//
// All private helpers here are prefixed `narrow_` because the whole
// aro::float_value module (float_value.c3, float_soft_wide.c3, ...) shares one
// namespace.
module aro::float_value;
import aro::value_interner;

// =============================================================================
// Native f16/f32/f64 arithmetic
// =============================================================================
// Each operation first applies the NaN rules on bits (lhs NaN wins, quieted,
// payload and sign kept; else rhs NaN), then computes natively, and maps any
// NaN the hardware produces (necessarily an invalid operation, since neither
// operand was NaN) to DEFAULT_NAN_*. So a native NaN, even one that LLVM
// constant-folds with another sign, never reaches the result, and the order of
// two NaN operands does not depend on how the backend commutes add/mul.
//
// Observed (Zig 0.17.0 x86_64-linux probe, see test/c3/float_narrow_tests.c3):
// the LLVM backend (-O ReleaseSafe -mcpu baseline) gives exactly these results
// in every case probed. With -mcpu native, LLVM may commute the operands of
// a + b and a * b, so with two NaN operands the rhs NaN can win. The self-hosted
// Debug backend with -mcpu baseline computes f16 in compiler-rt: its default NaN
// is positive (0x7E00), and it computes a - b as a + (-b), which flips the sign
// of a NaN rhs. Those are build-dependent reference quirks; this file follows
// the contract.

macro bool @narrow_f16_is_nan(ushort x) => (x & 0x7FFF) > 0x7C00;
macro bool @narrow_f32_is_nan(uint x) => (x & 0x7FFF_FFFF) > 0x7F80_0000;
macro bool @narrow_f64_is_nan(ulong x) => (x & 0x7FFF_FFFF_FFFF_FFFF) > 0x7FF0_0000_0000_0000;

<* NaN operand rule for f16: returns true and sets *out when a or b is NaN. *>
fn bool narrow_f16_nan_operand(ushort a, ushort b, ushort* out) @inline
{
	if (@narrow_f16_is_nan(a)) { *out = a | 0x0200; return true; }
	if (@narrow_f16_is_nan(b)) { *out = b | 0x0200; return true; }
	return false;
}

fn bool narrow_f32_nan_operand(uint a, uint b, uint* out) @inline
{
	if (@narrow_f32_is_nan(a)) { *out = a | 0x0040_0000; return true; }
	if (@narrow_f32_is_nan(b)) { *out = b | 0x0040_0000; return true; }
	return false;
}

fn bool narrow_f64_nan_operand(ulong a, ulong b, ulong* out) @inline
{
	if (@narrow_f64_is_nan(a)) { *out = a | 0x0008_0000_0000_0000; return true; }
	if (@narrow_f64_is_nan(b)) { *out = b | 0x0008_0000_0000_0000; return true; }
	return false;
}

fn ushort narrow_f16_result(float16 r) @inline
{
	ushort bits = bitcast(r, ushort);
	return @narrow_f16_is_nan(bits) ? DEFAULT_NAN_F16 : bits;
}

fn uint narrow_f32_result(float r) @inline
{
	uint bits = bitcast(r, uint);
	return @narrow_f32_is_nan(bits) ? DEFAULT_NAN_F32 : bits;
}

fn ulong narrow_f64_result(double r) @inline
{
	ulong bits = bitcast(r, ulong);
	return @narrow_f64_is_nan(bits) ? DEFAULT_NAN_F64 : bits;
}

macro float16 @narrow_h(ushort x) => bitcast(x, float16);
macro float @narrow_s(uint x) => bitcast(x, float);
macro double @narrow_d(ulong x) => bitcast(x, double);

<* Zig f16 `a + b` *>
fn ushort f16_add(ushort a, ushort b)
{
	ushort n;
	if (narrow_f16_nan_operand(a, b, &n)) return n;
	return narrow_f16_result(@narrow_h(a) + @narrow_h(b));
}

<* Zig f16 `a - b` *>
fn ushort f16_sub(ushort a, ushort b)
{
	ushort n;
	if (narrow_f16_nan_operand(a, b, &n)) return n;
	return narrow_f16_result(@narrow_h(a) - @narrow_h(b));
}

<* Zig f16 `a * b` *>
fn ushort f16_mul(ushort a, ushort b)
{
	ushort n;
	if (narrow_f16_nan_operand(a, b, &n)) return n;
	return narrow_f16_result(@narrow_h(a) * @narrow_h(b));
}

<* Zig f16 `a / b` (x/0 -> +-inf, 0/0 -> DEFAULT_NAN_F16) *>
fn ushort f16_div(ushort a, ushort b)
{
	ushort n;
	if (narrow_f16_nan_operand(a, b, &n)) return n;
	return narrow_f16_result(@narrow_h(a) / @narrow_h(b));
}

<* Zig f32 `a + b` *>
fn uint f32_add(uint a, uint b)
{
	uint n;
	if (narrow_f32_nan_operand(a, b, &n)) return n;
	return narrow_f32_result(@narrow_s(a) + @narrow_s(b));
}

<* Zig f32 `a - b` *>
fn uint f32_sub(uint a, uint b)
{
	uint n;
	if (narrow_f32_nan_operand(a, b, &n)) return n;
	return narrow_f32_result(@narrow_s(a) - @narrow_s(b));
}

<* Zig f32 `a * b` *>
fn uint f32_mul(uint a, uint b)
{
	uint n;
	if (narrow_f32_nan_operand(a, b, &n)) return n;
	return narrow_f32_result(@narrow_s(a) * @narrow_s(b));
}

<* Zig f32 `a / b` *>
fn uint f32_div(uint a, uint b)
{
	uint n;
	if (narrow_f32_nan_operand(a, b, &n)) return n;
	return narrow_f32_result(@narrow_s(a) / @narrow_s(b));
}

<* Zig f64 `a + b` *>
fn ulong f64_add(ulong a, ulong b)
{
	ulong n;
	if (narrow_f64_nan_operand(a, b, &n)) return n;
	return narrow_f64_result(@narrow_d(a) + @narrow_d(b));
}

<* Zig f64 `a - b` *>
fn ulong f64_sub(ulong a, ulong b)
{
	ulong n;
	if (narrow_f64_nan_operand(a, b, &n)) return n;
	return narrow_f64_result(@narrow_d(a) - @narrow_d(b));
}

<* Zig f64 `a * b` *>
fn ulong f64_mul(ulong a, ulong b)
{
	ulong n;
	if (narrow_f64_nan_operand(a, b, &n)) return n;
	return narrow_f64_result(@narrow_d(a) * @narrow_d(b));
}

<* Zig f64 `a / b` *>
fn ulong f64_div(ulong a, ulong b)
{
	ulong n;
	if (narrow_f64_nan_operand(a, b, &n)) return n;
	return narrow_f64_result(@narrow_d(a) / @narrow_d(b));
}

// =============================================================================
// Width-generic std.math helpers (bits only, no native floats)
// =============================================================================
// Zig works on @Int(.unsigned, bits) (u16/u32/u64/u80/u128). Here every width
// is held in a uint128 and masked back to `total_bits` after each left shift,
// which reproduces Zig's truncating shifts. Zig's floatMantissaBits is
// frac_bits + 1 for f80 (the explicit integer bit) and frac_bits otherwise;
// floatFractionalBits is frac_bits.

<* All ones in the low `total_bits` bits. *>
fn uint128 narrow_width_mask(FloatFormat fmt) @inline
{
	return fmt.total_bits == 128 ? ~(uint128)0 : ((uint128)1 << fmt.total_bits) - 1;
}

<* Zig math.floatMantissaBits(T). *>
fn int narrow_mantissa_bits(FloatFormat fmt) @inline => (int)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);

<* Zig @clz on the width's unsigned integer type (`x` already fits the width). *>
fn int narrow_clz(uint128 x, FloatFormat fmt) @inline
{
	if (x == 0) return fmt.total_bits;
	return (int)x.clz() - (128 - (int)fmt.total_bits);
}

<* Zig @ctz on the width's unsigned integer type (`x` already fits the width). *>
fn int narrow_ctz(uint128 x, FloatFormat fmt) @inline
{
	if (x == 0) return fmt.total_bits;
	return (int)x.ctz();
}

<*
 std.math.ilogb(x) (Zig 0.17.0 lib/std/math/ilogb.zig), any width:
   +-0 -> int::min (fp_ilogb0); NaN -> int::min (fp_ilogbnan); +-inf -> int::max;
   subnormal -> the exponent of its leading one bit (f80 counts the explicit
   integer bit, as ilogbX does with @intFromBool(T == f80)); normal -> e - bias.
 Exact port, also for non-canonical f80 encodings: Zig compares the 79-bit
 magnitude with inf's bits, so a pseudo-infinity (integer bit clear) gives
 int::max, and an unnormal gives e - bias.
*>
fn int KeyFloat.ilogb(self)
{
	FloatFormat fmt = format_of(self.tag);
	int significand_bits = narrow_mantissa_bits(fmt);
	uint128 sign_bit = sign_mask(self.tag);
	int max_exponent = (1 << fmt.exp_bits) - 1;
	int exponent_bias = max_exponent >> 1;
	uint128 u = self.raw() & (sign_bit - 1);
	int e = (int)(u >> significand_bits);
	if (e == 0)
	{
		if (u == 0) return int::min; // fp_ilogb0
		// offset sign bit, exponent bits, and integer bit (if present) + bias
		int offset = 1 + fmt.exp_bits + (fmt.explicit_int ? 1 : 0) - exponent_bias;
		return offset - narrow_clz(u, fmt);
	}
	if (e == max_exponent)
	{
		return u > inf(self.tag).raw() ? int::min : int::max; // fp_ilogbnan
	}
	return e - exponent_bias;
}

<*
 std.math.scalbn(x, n) = std.math.ldexp(x, n) (Zig 0.17.0 lib/std/math/ldexp.zig),
 any width, bit-exact including its own rounding of subnormal results (the
 `exact_tie` / (result + 1) >> 1 step) and "severe underflow" -> signed zero.
 NaN and +-inf are returned unchanged; overflow -> +-inf. Annex G calls it with
 n = -(int::min + 1) (= int::max) on a NaN/inf quotient, which must not overflow
 any intermediate.

 Reference quirk kept (observed with Zig 0.17.0, x86_64): a zero operand goes
 through the subnormal path with exponent = exp_bits + is_f80 - total_bits, so
 for large enough n it does not stay zero: f32 scalbn(+0, 25) = 0x0080_0000
 (FLT_MIN) and scalbn(+0, 300) = +inf. The intermediates are `long`, so no n
 (int::min included) overflows, and Zig's results are reproduced wherever Zig
 itself does not trap.
*>
fn KeyFloat KeyFloat.scalbn(self, int n_in)
{
	if (!self.is_finite()) return self;
	FloatFormat fmt = format_of(self.tag);
	uint128 wmask = narrow_width_mask(fmt);
	long exponent_bits = fmt.exp_bits;
	long mantissa_bits = narrow_mantissa_bits(fmt);
	long fractional_bits = fmt.frac_bits;
	long max_biased_exponent = 2 * (long)fmt.bias; // 2 * floatExponentMax(T)
	uint128 mantissa_mask = ((uint128)1 << mantissa_bits) - 1;
	uint128 repr = self.raw();
	uint128 sign_bit = repr & sign_mask(self.tag);
	long n = n_in;

	long exponent = (long)(((repr << 1) & wmask) >> (mantissa_bits + 1));
	if (exponent == 0)
	{
		exponent += (exponent_bits + (fmt.explicit_int ? 1 : 0)) - narrow_clz((repr << 1) & wmask, fmt);
	}

	if (n >= 0)
	{
		if (n > max_biased_exponent - exponent)
		{
			// Overflow. Return +/- inf
			return from_raw(self.tag, inf(self.tag).raw() | sign_bit);
		}
		if (exponent + n <= 0)
		{
			// Result is subnormal
			return from_raw(self.tag, ((repr << n) & wmask) | sign_bit);
		}
		if (exponent <= 0)
		{
			// Result is normal, but needs shifting
			uint128 result = (uint128)(n + exponent) << mantissa_bits;
			result |= ((repr << (1 - exponent)) & wmask) & mantissa_mask;
			return from_raw(self.tag, result | sign_bit);
		}
		// Result needs no shifting
		return from_raw(self.tag, (repr + ((uint128)n << mantissa_bits)) & wmask);
	}
	if (n <= -exponent)
	{
		// Severe underflow. Return +/- 0
		if (n < -(mantissa_bits + exponent)) return from_raw(self.tag, sign_bit);
		// Result underflowed, we need to shift and round
		long shift = min(-n, -(exponent + n) + 1);
		bool exact_tie = narrow_ctz(repr, fmt) == shift - 1;
		uint128 result = repr & mantissa_mask;
		// Include integer bit (f80 has it in the mantissa already)
		if (!fmt.explicit_int && exponent > 0) result |= (uint128)1 << fractional_bits;
		result = result >> (shift - 1);
		// Round result, including round-to-even for exact ties
		result = ((result + 1) >> 1) & ~(uint128)(exact_tie ? 1 : 0);
		return from_raw(self.tag, result | sign_bit);
	}
	// Result is exact, and needs no shifting
	return from_raw(self.tag, (repr - ((uint128)(-n) << mantissa_bits)) & wmask);
}

<*
 Magnitude of a non-NaN value as an integer that orders like the value. An f80
 pseudo-denormal (exponent 0, integer bit set) has the value of biased
 exponent 1, so it is moved there.
*>
fn uint128 narrow_magnitude_key(KeyFloat f) @inline
{
	uint128 m = f.raw() & ~sign_mask(f.tag);
	if (f.tag == F80 && (m >> 64) == 0 && (m >> 63) != 0) m += (uint128)1 << 64;
	return m;
}

<* `a < b` for two non-NaN values of one width (+0 == -0). *>
fn bool narrow_less_than(KeyFloat a, KeyFloat b)
{
	if (a.is_zero() && b.is_zero()) return false;
	bool sa = a.signbit();
	bool sb = b.signbit();
	if (sa != sb) return sa;
	uint128 ma = narrow_magnitude_key(a);
	uint128 mb = narrow_magnitude_key(b);
	return sa ? ma > mb : ma < mb;
}

<*
 Zig @max(a, b) on floats (observed with Zig 0.17.0, annex_helpers.txt): if
 exactly one operand is NaN the other is returned; if both are NaN the rhs is
 returned unchanged (not quieted). +0 vs -0: f32/f64 return the lhs, f16/f80/f128
 return +0 (Zig leaves this unspecified; Annex G only passes absolute values).
 Otherwise the larger value (equal values: the lhs).
 @require self.tag == other.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.max(self, KeyFloat other)
{
	// No `?:` on KeyFloat values: c3c 0.8.5 miscompiles it (see CONVENTIONS.md).
	if (self.is_nan()) return other; // with two NaNs: the rhs, unchanged (observed)
	if (other.is_nan()) return self;
	if (self.is_zero() && other.is_zero())
	{
		// Observed: f32/f64 (SSE) return the lhs; f16/f80/f128 return +0 if either is +0.
		if (self.tag == F32 || self.tag == F64) return self;
		if (self.signbit()) return other;
		return self;
	}
	if (narrow_less_than(self, other)) return other;
	return self;
}
