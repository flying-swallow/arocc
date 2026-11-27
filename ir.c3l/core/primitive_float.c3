// Floating and complex constant semantics on bit patterns: classification,
// constants, the width-generic add/sub/mul/div dispatch and the conversions
// (@floatCast, @floatFromInt, bigIntToFloat, setFloat .trunc) behind the float
// parts of src/aro/Value.zig.
//
// =============================================================================
// Layering
// =============================================================================
//
// Every float constant is raw bits in a `PrimitiveValue` (tag + bit pattern) and
// every complex constant two such patterns of one width. Nothing in this port
// holds a float constant in a host `double`/`long double`: `PrimitiveValue` *is*
// the float type. Three layers, lowest first:
//
//   aro::primitive_value  (pure: no Value, Compilation, QualType or Interner)
//     primitive_value.c3   PrimitiveType / PrimitiveValue, FloatFormat, the
//         F80Bits / F128Bits views, constructors (int_key, float_key,
//         complex_key, f16_value..) and accessors (float_bits, f16()..f128(),
//         re / im, to_big_int).
//     primitive_float.c3   (this file) FloatClass, RoundingMode, FloatStatus, NaN
//         constants, classification, zero/one/inf/nan, the PrimitiveValue
//         add/sub/mul/div dispatch (forwards to the narrow/wide files), and the
//         CONVERSIONS section: PrimitiveValue.cast, int -> float, float -> big int.
//     primitive_float_parse.c3       parse_f128 (std.fmt.parseFloat).
//     primitive_float_soft_narrow.c3 f16/f32/f64 add/sub/mul/div (native per the decision
//         below) and the width-generic std.math helpers Annex G needs: ilogb,
//         scalbn (ldexp), max.
//     primitive_float_soft_wide.c3   The software core: unpack / round_pack for every
//         format, f80/f128 add/sub/mul/div, f128 fused mul_add, and the exact hub
//         conversions PrimitiveValue.to_f128 / from_f128 that cast is built on.
//     primitive_float_print.c3       PrimitiveValue.compare (std.math.compare) and the
//         float / complex text output (Zig `{d}` = shortest round-trip decimal of
//         an f64).
//   aro::annex_g  (annex_g.c3, like src/aro/annex_g.zig)
//     complex_float_mul / complex_float_div, written once over PrimitiveValue
//     with the dispatching methods, so they work at every width.
//   aro::value_interner  (value_interner.c3)
//     Storage only: refs, hash / eql / to_ref, put / get.
//   aro::frontend::c::value  (value.c3 integers, bytes, pointers; value_float.c3 floats)
//     Everything that takes a `Value` and a `Compilation*`: read the key, call
//     the layers above, intern the result.
//
// Placement rule: a signature that mentions Value / Compilation / QualType goes
// in aro::frontend::c::value; interner storage goes in aro::value_interner; everything else
// on PrimitiveValue goes here.
//
// Reference vectors: aro_cc/test/values/data/float_values (bit patterns produced
// by a standalone Zig 0.17.0 probe program; development-only, no target depends
// on the Zig binary). They pin every "confirm with vectors" item below.
//
// Data flow: Parser.parseFloat = parse_f128 then PrimitiveValue.cast to the
// literal's width. Value arithmetic = Value.to_float both operands at the result
// width (via the f128 hub: PrimitiveValue.cast), then PrimitiveValue.add/... which
// dispatches to narrow (f16/f32/f64) or wide (f80/f128). Complex mul/div go
// through annex_g. Printing casts to f64 first (Zig does), so it needs only
// from_f128(.., F64).
//
// =============================================================================
// Native capability decision (backed by //aro_cc/test/values:float_capability_tests)
// =============================================================================
//
// Probed with c3c 0.8.5 on x86_64-linux-gnu at -O0 and -O2:
//
//   f32, f64 (float, double): NATIVE ALLOWED. + - * / are correctly rounded
//     (ties to even), subnormals are neither flushed nor treated as zero, signed
//     zero/inf/NaN follow IEEE 754, comparisons are unordered on NaN, nothing is
//     fast-math folded at -O2. double<->float casts round once; (double)/(float)
//     of ulong/long round once (no double rounding through double). Results,
//     including NaN outputs, are x86 SSE results: the default NaN of an invalid
//     operation is NEGATIVE (0xFFF8..., 0xFFC00000) and a NaN operand propagates
//     quieted with its payload (first operand wins).
//   f16 (float16, LLVM half): NATIVE ALLOWED for + - * / and casts to/from
//     float/double/ulong/long. Arithmetic is done in float and rounded once to
//     half, which is correctly rounded for these four operations. double->half
//     rounds once. Default NaN is 0xFE00 (negative). NOTE: reading a float16
//     back as `(float)h` quiets a signaling NaN (0x7C01 -> 0x7FC02000).
//   f128 (float128, LLVM fp128 -> libgcc soft-fp): NATIVE REJECTED for
//     production. Finite results are right, but (1) float128 *literals* are
//     folded at double precision (0.1 becomes 0x3FFB9999999999999A00..00, not
//     ...999A), (2) 0/0 gives the x86 default NaN 0xFFFF8000.. while the
//     reference (Zig compiler-rt divtf3/addf3/mulf3) gives +0x7FFF8000.., and (3)
//     it depends on the toolchain linking libgcc's soft-fp (plan 32 portability).
//     primitive_float_soft_wide.c3 implements f128 in software. Tests MAY use native
//     float128 as an oracle for finite, non-NaN results built from bit patterns.
//   f80: c3c 0.8.5 has no x87 extended type: SOFTWARE ONLY.
//   uint128/int128 integer ops (+ - * / % << >> clz ctz): ALLOWED inside the
//     soft-float cores (all probes pass). int128<->float casts are NOT allowed:
//     c3's own weak compiler_rt (__floattidf, __fixdfti, ...) replaces libgcc's
//     and was not probed; do these conversions on bits.
//   Literals: double/float literals fold exactly (0.1, the min subnormal, -0.0);
//     still prefer bit-pattern constants (float_key) in production code so the
//     source states the exact value. Never write a float128 literal.
//
// Native operations may only appear in primitive_float_soft_narrow.c3 (and in tests).
// Every other file manipulates PrimitiveValue bits or calls the dispatchers.
//
// =============================================================================
// Reference semantics (what "matches Zig" means for each width)
// =============================================================================
//
// Aro's Value.zig computes on real Zig floats at run time, so the reference is
// what a Zig x86_64-linux build does: f16 in f32 SSE + compiler-rt
// __extendhfsf2/__truncsfhf2; f32/f64 SSE; f80 x87 (64-bit precision control);
// f128 Zig compiler-rt (lib/compiler_rt/addf3.zig, mulf3.zig, divtf3.zig,
// fma.zig, extendf.zig, truncf.zig). Rounding is always to nearest, ties to even;
// Value never looks at exception flags. Where this differs from an idealised
// IEEE implementation, match the reference and document it (CONVENTIONS rule:
// "Match current behavior even when it differs").
//
// NaN rules (confirmed by the Zig 0.17.0 vectors in aro_cc/test/unit/float_values,
// canonical configuration `-fllvm -mcpu=baseline`; see its README):
//   - Invalid operation (0/0, inf-inf, 0*inf) -> DEFAULT_NAN_* below:
//     f16/f32/f64 negative quiet NaN (x86 SSE), f80 negative "real indefinite"
//     (x87), f128 POSITIVE quiet NaN (compiler-rt).
//   - One or two NaN operands, f16/f32/f64/f128 -> the first NaN operand (lhs if
//     NaN, else rhs), quieted, sign and payload kept. Exception: f128 `a - NaN`
//     (only the rhs a NaN) returns that NaN with its sign FLIPPED (__subtf3 is
//     __addtf3(a, -b)); f16 `a - NaN` does not flip.
//   - Two NaN operands, f80 (x87): order-independent, result quieted: (1) a quiet
//     NaN beats a signaling NaN; (2) otherwise the larger 64-bit significand
//     wins (sign ignored); (3) on a tie the POSITIVE NaN wins.
//   - Casts: sign kept, payload aligned at the top of the fraction. The quiet
//     bit is SET (a signaling NaN is quieted) by every cast except those done by
//     a compiler-rt routine that keeps it: any -> f128, f16 -> f32, f16 -> f80
//     and f128 -> f80. In particular f16 -> f64 quiets (__extendhfsf2 then SSE
//     cvtss2sd). Signaling NaNs never arise from C source in Aro
//     (__builtin_nan sets the quiet bit), so this only matters for vectors.
//   - std.math.nan(T) (used by __builtin_nan) is the POSITIVE quiet NaN STD_NAN_*.
// f80 encodings: the explicit integer bit (bit 63 of `lo`) must be 1 for normal,
// inf and NaN values. Unnormals, pseudo-infinities and pseudo-NaNs (exponent != 0,
// integer bit 0) are classified as NaN (x87 treats them as invalid operands;
// Zig's isNan(x) is x != x). Pseudo-denormals (exponent 0, integer bit 1) are
// SUBNORMAL with the value of biased exponent 1. Aro never creates any of these.
//
// Note on interning (value_interner.c3): putting float +0.0 yields REF_ZERO and
// float 1.0 yields REF_ONE, whose `get` is the *int* 0 / 1. So a float-typed
// Value may hold an int key; value_float.c3 accepts INT keys everywhere it reads
// a Value (Zig's toFloat/imag do).
module aro::primitive_value;
import aro::bigint;

// =============================================================================
// Shared types
// =============================================================================

<* Value class of a float bit pattern (see the f80 encoding rule above). *>
enum FloatClass : char
{
	ZERO,
	SUBNORMAL,
	NORMAL,
	INFINITE,
	NAN,
}

<*
 Rounding direction for the soft-float core. Value arithmetic and casts always
 use NEAREST_EVEN (Zig's only runtime mode); TOWARD_ZERO is what setFloat(.trunc)
 needs for float -> int. No other modes are used by the reference.
*>
enum RoundingMode : char
{
	NEAREST_EVEN,
	TOWARD_ZERO,
}

<*
 IEEE 754 exception flags raised by a soft operation, OR-ed into the caller's
 `FloatStatus*` when it is not null. UNDERFLOW means "tiny after rounding and
 inexact" (x86 semantics). The reference ignores flags; they exist so tests can
 check overflow/underflow/inexact handling (plan 10 acceptance).
*>
bitstruct FloatStatus : char
{
	bool invalid: 0;
	bool div_by_zero: 1;
	bool overflow: 2;
	bool underflow: 3;
	bool inexact: 4;
}

// =============================================================================
// Constants (bit patterns; implemented in stage 0)
// =============================================================================

<* Result of an invalid operation (0/0, inf-inf, 0*inf) per width; see "NaN rules". *>
const ushort DEFAULT_NAN_F16 = 0xFE00;
const uint DEFAULT_NAN_F32 = 0xFFC0_0000;
const ulong DEFAULT_NAN_F64 = 0xFFF8_0000_0000_0000;
const F80Bits DEFAULT_NAN_F80 = { .lo = 0xC000_0000_0000_0000, .hi = 0xFFFF };
const F128Bits DEFAULT_NAN_F128 = { .lo = 0, .hi = 0x7FFF_8000_0000_0000 };

<* std.math.nan(T): the positive quiet NaN with an empty payload. *>
const ushort STD_NAN_F16 = 0x7E00;
const uint STD_NAN_F32 = 0x7FC0_0000;
const ulong STD_NAN_F64 = 0x7FF8_0000_0000_0000;
const F80Bits STD_NAN_F80 = { .lo = 0xC000_0000_0000_0000, .hi = 0x7FFF };
const F128Bits STD_NAN_F128 = { .lo = 0, .hi = 0x7FFF_8000_0000_0000 };

// =============================================================================
// Bit access (implemented in stage 0)
// =============================================================================

<* Biased exponent field. @require self.tag.kind == FLOAT *>
fn uint PrimitiveValue.biased_exponent(self)
{
	FloatFormat fmt = self.tag.format;
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	return (uint)(self.float_bits() >> shift) & (((uint)1 << fmt.exp_bits) - 1);
}

<* Stored fraction field (f80: bits 0..62, i.e. without the explicit integer bit). @require self.tag.kind == FLOAT *>
fn uint128 PrimitiveValue.fraction(self)
{
	FloatFormat fmt = self.tag.format;
	return self.float_bits() & (((uint128)1 << fmt.frac_bits) - 1);
}

<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.signbit(self) => (self.float_bits() & self.tag.sign_mask()) != 0;

<* @require self.tag.kind == FLOAT *>
fn FloatClass PrimitiveValue.classify(self)
{
	FloatFormat fmt = self.tag.format;
	uint e = self.biased_exponent();
	uint128 frac = self.fraction();
	uint e_max = ((uint)1 << fmt.exp_bits) - 1;
	if (fmt.explicit_int)
	{
		bool int_bit = ((self.float_bits() >> 63) & 1) != 0;
		if (e == 0) return (frac == 0 && !int_bit) ? FloatClass.ZERO : FloatClass.SUBNORMAL;
		if (!int_bit) return NAN;  // unnormal, pseudo-infinity, pseudo-NaN
		if (e == e_max) return frac == 0 ? FloatClass.INFINITE : FloatClass.NAN;
		return NORMAL;
	}
	if (e == 0) return frac == 0 ? FloatClass.ZERO : FloatClass.SUBNORMAL;
	if (e == e_max) return frac == 0 ? FloatClass.INFINITE : FloatClass.NAN;
	return NORMAL;
}

<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_nan(self) => self.classify() == NAN;
<* glibc issignaling: a NaN whose quiet bit (top stored fraction bit) is clear. x87
   pseudo-NaNs (integer bit clear) are not signaling. @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_signaling(self)
{
	FloatFormat fmt = self.tag.format;
	uint e_max = ((uint)1 << fmt.exp_bits) - 1;
	if (self.biased_exponent() != e_max) return false;
	if (fmt.explicit_int && ((self.float_bits() >> 63) & 1) == 0) return false;
	uint128 frac = self.fraction();
	return frac != 0 && (frac >> (fmt.frac_bits - 1)) == 0;
}
<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_inf(self) => self.classify() == INFINITE;
<* std.math.isFinite: not inf and not NaN. @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_finite(self) => self.classify() != INFINITE && self.classify() != NAN;
<* Zig `x == 0` (either sign). @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_zero(self) => self.classify() == ZERO;
<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_positive_zero(self) => self.classify() == ZERO && !self.signbit();
<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_negative_zero(self) => self.classify() == ZERO && self.signbit();
<* std.math.isPositiveInf. @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_positive_inf(self) => self.classify() == INFINITE && !self.signbit();
<* @require self.tag.kind == FLOAT *>
fn bool PrimitiveValue.is_negative_inf(self) => self.classify() == INFINITE && self.signbit();

<* Zig unary minus: flips the sign bit only (also of NaN; no quieting). @require self.tag.kind == FLOAT *>
fn PrimitiveValue PrimitiveValue.neg(self) => float_key(self.tag, self.float_bits() ^ self.tag.sign_mask());
<* Zig @abs: clears the sign bit only. @require self.tag.kind == FLOAT *>
fn PrimitiveValue PrimitiveValue.abs(self) => float_key(self.tag, self.float_bits() & ~self.tag.sign_mask());
<*
 std.math.copysign(magnitude = self, sign = sign_of): bit operation, NaN included.
 @require self.tag.kind == FLOAT && sign_of.tag == self.tag : "operands must be floats of the same width"
*>
fn PrimitiveValue PrimitiveValue.copysign(self, PrimitiveValue sign_of)
{
	uint128 m = self.tag.sign_mask();
	return float_key(self.tag, (self.float_bits() & ~m) | (sign_of.float_bits() & m));
}

<* +0.0 or -0.0. @require tag.kind == FLOAT *>
fn PrimitiveValue zero(PrimitiveType tag, bool negative = false) => float_key(tag, negative ? tag.sign_mask() : 0);

<* 1.0. @require tag.kind == FLOAT *>
fn PrimitiveValue one(PrimitiveType tag)
{
	FloatFormat fmt = tag.format;
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	uint128 bits = (uint128)fmt.bias << shift;
	if (fmt.explicit_int) bits |= (uint128)1 << 63;
	return float_key(tag, bits);
}

<* std.math.inf(T), negated when `negative`. @require tag.kind == FLOAT *>
fn PrimitiveValue inf(PrimitiveType tag, bool negative = false)
{
	FloatFormat fmt = tag.format;
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	uint128 bits = (((uint128)1 << fmt.exp_bits) - 1) << shift;
	if (fmt.explicit_int) bits |= (uint128)1 << 63;
	if (negative) bits |= tag.sign_mask();
	return float_key(tag, bits);
}

<* std.math.nan(T). @require tag.kind == FLOAT *>
fn PrimitiveValue std_nan(PrimitiveType tag)
{
	switch (tag)
	{
		case F16: return f16_value(STD_NAN_F16);
		case F32: return f32_value(STD_NAN_F32);
		case F64: return f64_value(STD_NAN_F64);
		case F80: return f80_value(STD_NAN_F80);
		case F128: return f128_value(STD_NAN_F128);
		default: unreachable("not a float tag");
	}
}

<* The reference's result of an invalid operation at this width (see NaN rules). @require tag.kind == FLOAT *>
fn PrimitiveValue default_nan(PrimitiveType tag)
{
	switch (tag)
	{
		case F16: return f16_value(DEFAULT_NAN_F16);
		case F32: return f32_value(DEFAULT_NAN_F32);
		case F64: return f64_value(DEFAULT_NAN_F64);
		case F80: return f80_value(DEFAULT_NAN_F80);
		case F128: return f128_value(DEFAULT_NAN_F128);
		default: unreachable("not a float tag");
	}
}

<* Sets the quiet bit (the top fraction bit) of a NaN; other values unchanged. @require self.tag.kind == FLOAT *>
fn PrimitiveValue PrimitiveValue.quiet(self)
{
	if (!self.is_nan()) return self;
	FloatFormat fmt = self.tag.format;
	return float_key(self.tag, self.float_bits() | ((uint128)1 << (fmt.frac_bits - 1)));
}

// =============================================================================
// Width-generic arithmetic (dispatch implemented in stage 0)
// =============================================================================
// Zig `a + b` etc. on two values of the same float type T, rounding to nearest
// even, with the NaN rules above. f16/f32/f64 go to primitive_float_soft_narrow.c3,
// f80/f128 to primitive_float_soft_wide.c3 (status flags are dropped here).

<*
 @require self.tag.kind == FLOAT && rhs.tag == self.tag : "operands must be floats of the same width"
*>
fn PrimitiveValue PrimitiveValue.add(self, PrimitiveValue rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_add(self.f16(), rhs.f16()));
		case F32: return f32_value(f32_add(self.f32(), rhs.f32()));
		case F64: return f64_value(f64_add(self.f64(), rhs.f64()));
		case F80: return f80_value(f80_add(self.f80(), rhs.f80()));
		case F128: return f128_value(f128_add(self.f128(), rhs.f128()));
		default: unreachable("not a float tag");
	}
}

<*
 @require self.tag.kind == FLOAT && rhs.tag == self.tag : "operands must be floats of the same width"
*>
fn PrimitiveValue PrimitiveValue.sub(self, PrimitiveValue rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_sub(self.f16(), rhs.f16()));
		case F32: return f32_value(f32_sub(self.f32(), rhs.f32()));
		case F64: return f64_value(f64_sub(self.f64(), rhs.f64()));
		case F80: return f80_value(f80_sub(self.f80(), rhs.f80()));
		case F128: return f128_value(f128_sub(self.f128(), rhs.f128()));
		default: unreachable("not a float tag");
	}
}

<*
 @require self.tag.kind == FLOAT && rhs.tag == self.tag : "operands must be floats of the same width"
*>
fn PrimitiveValue PrimitiveValue.mul(self, PrimitiveValue rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_mul(self.f16(), rhs.f16()));
		case F32: return f32_value(f32_mul(self.f32(), rhs.f32()));
		case F64: return f64_value(f64_mul(self.f64(), rhs.f64()));
		case F80: return f80_value(f80_mul(self.f80(), rhs.f80()));
		case F128: return f128_value(f128_mul(self.f128(), rhs.f128()));
		default: unreachable("not a float tag");
	}
}

<*
 @require self.tag.kind == FLOAT && rhs.tag == self.tag : "operands must be floats of the same width"
*>
fn PrimitiveValue PrimitiveValue.div(self, PrimitiveValue rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_div(self.f16(), rhs.f16()));
		case F32: return f32_value(f32_div(self.f32(), rhs.f32()));
		case F64: return f64_value(f64_div(self.f64(), rhs.f64()));
		case F80: return f80_value(f80_div(self.f80(), rhs.f80()));
		case F128: return f128_value(f128_div(self.f128(), rhs.f128()));
		default: unreachable("not a float tag");
	}
}

// =============================================================================
// CONVERSIONS (owner: 10.3 `conversions`)
// =============================================================================
//
// Everything below works on bit patterns. It needs three primitives from
// primitive_float_soft_wide.c3: round_pack (one correctly rounded result from an exact
// sig * 2^exp), PrimitiveValue.to_f128 and from_f128 (the exact hub), plus
// f128_mul / f128_div for parseFloat's fast path (primitive_float_parse.c3).
//
// NaN through casts (observed with Zig 0.17.0 on x86_64-linux, LLVM backend,
// baseline CPU; aro_cc/test/unit/float_values/nan.txt): sign kept, payload aligned
// at the top of the fraction. The quiet bit is set by every cast EXCEPT those
// that go through a compiler-rt routine that keeps it: any -> f128
// (__extend*ftf2), f16 -> f32 (__extendhfsf2), f16 -> f80 (__extendhfxf2) and
// f128 -> f80 (__trunctfxf2). f16 -> f64 is __extendhfsf2 then SSE cvtss2sd,
// which quiets.
//
// Non-canonical f80 sources (exponent != 0, integer bit 0: unnormal,
// pseudo-infinity, pseudo-NaN): to f32/f64 the x87 `fstp` raises invalid and
// gives the default NaN; to f16 compiler-rt __truncxfhf2 ignores the integer bit
// (0x3fff4000.. is 1.5); to f128 __extendxftf2 is what to_f128 models.

fn bool cast_keeps_nan_quiet_bit(PrimitiveType src, PrimitiveType dest)
{
	switch
	{
		case dest == F128: return true;
		case src == F16 && (dest == F32 || dest == F80): return true;
		case src == F128 && dest == F80: return true;
		default: return false;
	}
}

<*
 Zig @floatCast(x) to `dest` (also used for exact widening): round to nearest
 even once, overflow -> +-inf, underflow -> subnormal or signed zero, sign of
 zero kept. NaN: sign and the top payload bits kept; the quiet bit per
 cast_keeps_nan_quiet_bit. Non-canonical f80 sources as described above. Same
 tag returns `self` unchanged.
 @require self.tag.kind == FLOAT && dest.kind == FLOAT
*>
fn PrimitiveValue PrimitiveValue.cast(self, PrimitiveType dest)
{
	if (self.tag == dest) return self;
	PrimitiveValue src = self;
	if (src.tag == F80 && (src.f80().hi & 0x7FFF) != 0 && (src.f80().lo >> 63) == 0)
	{
		if (dest == F32 || dest == F64) return default_nan(dest);
		if (dest == F16) src = float_key(F80, src.float_bits() | (uint128)1 << 63);
	}
	if (src.tag == F16 && dest == F32 && src.is_nan())
	{
		// __extendhfsf2: the fraction (quiet bit included) moves up unchanged.
		// from_f128 always quiets a narrow NaN, so this pair is done here.
		uint bits = 0x7F80_0000 | ((uint)(src.f16() & 0x03FF) << 13);
		if (src.signbit()) bits |= 0x8000_0000;
		return f32_value(bits);
	}
	PrimitiveValue r = from_f128(src.to_f128(), dest);
	if (!cast_keeps_nan_quiet_bit(src.tag, dest)) r = r.quiet();
	return r;
}

<*
 Zig @floatFromInt(x) for a u64 into `dest`: rounded once to nearest even
 (u64 -> f16 overflows to +inf from 65520 up; u64 fits f80/f128 exactly).
 @require dest.kind == FLOAT
*>
fn PrimitiveValue from_u64(ulong x, PrimitiveType dest) => round_pack(dest, false, 0, (uint128)x, false);

<* Zig @floatFromInt(x) for an i64 into `dest`; -0 never results (0 -> +0.0). @require dest.kind == FLOAT *>
fn PrimitiveValue from_i64(long x, PrimitiveType dest)
{
	bool negative = x < 0;
	// Two's-complement negation in ulong handles long::min (magnitude 2^63).
	ulong magnitude = negative ? (ulong)0 - (ulong)x : (ulong)x;
	return round_pack(dest, negative, 0, (uint128)magnitude, false);
}

const ulong F128_HI_FRAC_MASK = 0x0000_FFFF_FFFF_FFFF;
const ulong F128_SIGN_BIT = 0x8000_0000_0000_0000;

fn uint f128_exp_field(F128Bits f) @inline => (uint)(f.hi >> 48) & 0x7FFF;

<*
 One step of bigIntToFloat: @mulAdd(f128, 2^64, r, @floatFromInt(limb)) with a
 single rounding, for `r` a non-negative integer-valued f128 or +inf (the only
 values the loop produces). The exact value r * 2^64 + limb is handed to
 round_pack with at most 127 significant bits plus a sticky bit.
*>
fn F128Bits mul_add_limb(F128Bits r, ulong limb)
{
	uint e_field = f128_exp_field(r);
	if (e_field == 0x7FFF) return r;  // +inf * 2^64 + finite = +inf
	if (e_field == 0) return round_pack(F128, false, 0, (uint128)limb, false).f128();  // r == +0
	uint128 sig = ((uint128)1 << 112) | ((uint128)(r.hi & F128_HI_FRAC_MASK) << 64) | (uint128)r.lo;
	// r = sig * 2^e with e = e_field - bias - 112 >= -112; r * 2^64 = sig * 2^s.
	int s = (int)e_field - 16383 - 112 + 64;
	if (s <= 14)
	{
		// r is an integer, so sig has at least -e trailing zero bits and the
		// right shift below is exact; sig << 14 < 2^127.
		uint128 m = s >= 0 ? sig << s : sig >> - s;
		return round_pack(F128, false, 0, m + (uint128)limb, false).f128();
	}
	int d = s - 14;
	uint128 m = sig << 14;
	bool sticky;
	if (d >= 64)
	{
		sticky = limb != 0;
	}
	else
	{
		m += (uint128)(limb >> d);
		sticky = (limb & (((ulong)1 << d) - 1)) != 0;
	}
	return round_pack(F128, false, d, m, sticky).f128();
}

<*
 Value.zig bigIntToFloat(limbs, positive) -> f128, reproduced exactly INCLUDING
 its rounding: zero limbs -> +0; otherwise, from the most significant limb down,
 `result = @mulAdd(f128, 2^64, result, @floatFromInt(limb))` (one fused rounding
 per step), then negated (sign bit flip) when !positive. For more than two
 significant limbs this can differ from a correctly rounded conversion
 (observed: limbs {1, 0x4000, 2^63} give 2^191, not 2^191 + 2^79); the
 reference behaviour is kept. Overflow gives +-inf.
*>
fn F128Bits big_int_to_f128(BigIntConst big)
{
	F128Bits r = { 0, 0 };
	if (big.limbs.len == 0) return r;
	for (sz i = big.limbs.len; i > 0; i--) r = mul_add_limb(r, big.limbs[i - 1]);
	if (!big.positive) r.hi ^= F128_SIGN_BIT;
	return r;
}

<*
 Value.toFloat(T) of an int key: u64/i64 -> from_u64/from_i64 (one rounding);
 big_int -> @floatCast(bigIntToFloat(..)) i.e. big_int_to_f128 then cast to
 `dest` (two roundings - a reference quirk to keep).
 @require i.tag.kind == INT && dest.kind == FLOAT
*>
fn PrimitiveValue key_int_to_float(PrimitiveValue i, PrimitiveType dest)
{
	if (!i.int_fits_64()) return f128_value(big_int_to_f128(i.to_big_int())).cast(dest);
	if (i.tag == INT_NEGATIVE) return from_i64((long)i.int_low_u64(), dest);
	return from_u64(i.int_low_u64(), dest);
}

<*
 std.math.big.int.calcLimbLen(float) for an f128: denormal (and zero) -> 1,
 infinity/NaN -> 0, otherwise calcNonZeroTwosCompLimbCount(2 + max(unbiased exponent, 0)).
*>
fn sz calc_float_limb_len(F128Bits f)
{
	uint e_field = f128_exp_field(f);
	if (e_field == 0) return 1;
	if (e_field == 0x7FFF) return 0;
	int unbiased = (int)e_field - 16383;
	return bigint::calc_non_zero_twos_comp_limb_count((usz)2 + (usz)(unbiased > 0 ? unbiased: 0));
}

<*
 Mutable.setFloat(f, .trunc): r = trunc(f) exactly (f finite). Returns true when
 the value had a fractional part (Zig `.inexact`). -0.0 and -0.5 give r = 0 with
 positive sign (bigint normalisation). `r.limbs` must hold calc_float_limb_len(f)
 limbs.
 @require !f128_value(f).is_nan() && !f128_value(f).is_inf() : "setFloat needs a finite value"
*>
fn bool f128_to_big_int_trunc(F128Bits f, BigIntMutable* r)
{
	bool negative = (f.hi & F128_SIGN_BIT) != 0;
	uint e_field = f128_exp_field(f);
	if (e_field < 16383)
	{
		// |f| < 1.0 (zero and subnormals included): r = 0, inexact unless f == 0.
		r.set_u64(0);
		return e_field != 0 || (f.hi & F128_HI_FRAC_MASK) != 0 || f.lo != 0;
	}
	int exponent = (int)e_field - 16383;
	uint128 mantissa = ((uint128)1 << 112) | ((uint128)(f.hi & F128_HI_FRAC_MASK) << 64) | (uint128)f.lo;
	if (exponent >= 112)
	{
		// Exact: mantissa * 2^(exponent - 112), placed limb by limb.
		usz shift = (usz)exponent - 112;
		usz word = shift / 64;
		usz bit = shift % 64;
		usz needed = (113 + shift + 63) / 64;
		assert(r.limbs.len >= (sz)needed);
		for (usz k = 0; k < needed; k++) r.limbs[k] = 0;
		ulong t0 = (ulong)mantissa;
		ulong t1 = (ulong)(mantissa >> 64);
		ulong l0 = t0;
		ulong l1 = t1;
		ulong l2 = 0;
		if (bit != 0)
		{
			l0 = t0 << bit;
			l1 = (t1 << bit) | (t0 >> (64 - bit));
			l2 = t1 >> (64 - bit);
		}
		r.limbs[word] = l0;
		if (word + 1 < needed) r.limbs[word + 1] = l1;
		if (word + 2 < needed) r.limbs[word + 2] = l2;
		r.normalize((sz)needed);
		r.positive = !negative;
		return false;
	}
	usz drop = 112 - (usz)exponent;
	uint128 int_part = mantissa >> drop;
	uint128 frac = mantissa & (((uint128)1 << drop) - 1);
	r.limbs[0] = (ulong)int_part;
	sz len = 1;
	if ((int_part >> 64) != 0)
	{
		r.limbs[1] = (ulong)(int_part >> 64);
		len = 2;
	}
	r.len = len;
	r.positive = !negative;
	return frac != 0;
}
