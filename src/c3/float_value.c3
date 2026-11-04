// Floating and complex constant semantics: port of the float parts of
// src/aro/Value.zig (floatToInt, intToFloat, floatCast, toFloat, imag,
// realPart/imaginaryPart, complexConj, the float/complex branches of
// add/sub/mul/div) and of Parser.parseFloat's `std.fmt.parseFloat(f128, ...)`.
//
// =============================================================================
// How the six parts fit together (plan 10 parallel breakdown)
// =============================================================================
//
// Every float constant is stored as raw bits in the interner's `KeyFloat` (tag +
// bit pattern, value_interner.c3) and every complex constant as `KeyComplex`
// (two components of one width). Nothing in this port holds a float constant in
// a host `double`/`long double`: `KeyFloat` *is* the float type. All five files
// below are one module, `aro::float_value`, except annex_g.c3 (`aro::annex_g`,
// like src/aro/annex_g.zig):
//
//   float_value.c3       (stage 0 + 10.3 `conversions`)
//       Shared types (FloatFormat, FloatClass, RoundingMode, FloatStatus), bit
//       access and classification (implemented in stage 0, see below), the
//       width-generic `KeyFloat.add/sub/mul/div` dispatch (implemented in stage
//       0, it forwards to the narrow/wide files), and the CONVERSIONS section:
//       KeyFloat.cast (@floatCast), int -> float (@floatFromInt, bigIntToFloat),
//       float -> big int (setFloat .trunc), parse_f128 (std.fmt.parseFloat) and
//       the Value-level operations (float_to_int, int_to_float, float_cast,
//       to_float, imag, real_part, imaginary_part, complex_conj, add/sub/mul/div).
//   float_soft_narrow.c3 (10.1 `narrow-float`)
//       f16/f32/f64 add/sub/mul/div (native per the decision below) and the
//       width-generic std.math helpers Annex G needs: ilogb, scalbn (ldexp), max.
//   float_soft_wide.c3   (10.2 `wide-float`)
//       The software core: unpack / round_pack for every format, f80/f128
//       add/sub/mul/div, f128 fused mul_add, and the exact hub conversions
//       KeyFloat.to_f128 / from_f128 that KeyFloat.cast is built on.
//   float_print.c3       (10.4 `compare-print`)
//       KeyFloat.compare (std.math.compare), the Value-level float/complex
//       compare, isInf/isNan/isInfSign over Values, and Value.print's float and
//       complex output (Zig `{d}` = shortest round-trip decimal of an f64).
//   annex_g.c3           (10.5 `annex-g`)
//       complex_float_mul / complex_float_div, written once over KeyFloat with
//       the dispatching methods, so they work at every width.
//   test/migration/float_probe.zig + test/c3/data/float_values/*  (10.6 `vectors`)
//       Reference bit-pattern vectors produced by running the Zig 0.17.0 binary
//       at /home/user/tools/zig/ziglang/zig on a standalone probe program (it can
//       run standalone programs but cannot build Aro). Its job includes pinning
//       every "confirm with vectors" item below. The binary is development-only:
//       no production or test target may depend on it.
//
// Data flow: Parser.parseFloat = parse_f128 then KeyFloat.cast to the literal's
// width. Value arithmetic = to_float() both operands at the result width (via the
// f128 hub: KeyFloat.cast), then KeyFloat.add/... which dispatches to
// narrow (f16/f32/f64) or wide (f80/f128). Complex mul/div go through annex_g.
// Printing casts to f64 first (Zig does), so it needs only from_f128(.., F64).
//
// The integrator (stage 2) makes value.c3's float branches forward here, e.g.
// `if (scalar_kind.is_float()) return float_value::add(res, lhs, rhs, qt, comp);`
// (aro::value and aro::float_value import each other; c3c 0.8.5 accepts
// cyclic module imports), and writes test/c3/float_value_tests.c3.
//
// =============================================================================
// Native capability decision (backed by //test/c3:float_capability_tests)
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
//     float_soft_wide.c3 implements f128 in software. Tests MAY use native
//     float128 as an oracle for finite, non-NaN results built from bit patterns.
//   f80: c3c 0.8.5 has no x87 extended type: SOFTWARE ONLY.
//   uint128/int128 integer ops (+ - * / % << >> clz ctz): ALLOWED inside the
//     soft-float cores (all probes pass). int128<->float casts are NOT allowed:
//     c3's own weak compiler_rt (__floattidf, __fixdfti, ...) replaces libgcc's
//     and was not probed; do these conversions on bits.
//   Literals: double/float literals fold exactly (0.1, the min subnormal, -0.0);
//     still prefer bit-pattern constants (from_raw) in production code so the
//     source states the exact value. Never write a float128 literal.
//
// Native operations may only appear in float_soft_narrow.c3 (and in tests).
// Every other file manipulates KeyFloat bits or calls the dispatchers.
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
// NaN rules (confirmed by the Zig 0.17.0 vectors in test/c3/data/float_values,
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
// Note on interning (value_interner.c3, plan 09): putting float +0.0 yields
// REF_ZERO and float 1.0 yields REF_ONE, whose `get` is the *int* 0 / 1. So a
// float-typed Value may hold an int key; every function here that reads a Value
// must accept INT keys (Zig's toFloat/imag do).
//
// OWNER of this file after stage 0: 10.3 `conversions` (the CONVERSIONS section).
// Stage-0 code outside that section is the contract; change it only through the
// integrator.
module aro::float_value;
import aro::value_interner, aro::value, aro::compilation, aro::type_store, aro::bigint, aro::annex_g, aro::lang_opts;

// =============================================================================
// Shared types
// =============================================================================

<*
 IEEE / x87 storage format of one KeyFloatTag. `frac_bits` counts the stored
 fraction bits (for f80 *excluding* the explicit integer bit); `explicit_int`
 is true only for f80, whose bit 63 holds the integer bit.
*>
struct FloatFormat
{
	<* Total width: 16, 32, 64, 80, 128. *>
	char total_bits;
	char exp_bits;
	char frac_bits;
	bool explicit_int;
	<* Exponent bias: 2^(exp_bits-1) - 1. *>
	int bias;
}

const FloatFormat FORMAT_F16 = { 16, 5, 10, false, 15 };
const FloatFormat FORMAT_F32 = { 32, 8, 23, false, 127 };
const FloatFormat FORMAT_F64 = { 64, 11, 52, false, 1023 };
const FloatFormat FORMAT_F80 = { 80, 15, 63, true, 16383 };
const FloatFormat FORMAT_F128 = { 128, 15, 112, false, 16383 };

fn FloatFormat format_of(KeyFloatTag tag)
{
	switch (tag)
	{
		case F16: return FORMAT_F16;
		case F32: return FORMAT_F32;
		case F64: return FORMAT_F64;
		case F80: return FORMAT_F80;
		case F128: return FORMAT_F128;
	}
}

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
	bool invalid : 0;
	bool div_by_zero : 1;
	bool overflow : 2;
	bool underflow : 3;
	bool inexact : 4;
}

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

<* Zig error.InvalidCharacter from std.fmt.parseFloat. *>
excuse INVALID_CHARACTER;

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

<*
 Zig `switch (bitSizeof(T))` -> width tag.
 @require bits == 16 || bits == 32 || bits == 64 || bits == 80 || bits == 128 : "not a float width"
*>
fn KeyFloatTag tag_for_bits(ulong bits)
{
	switch (bits)
	{
		case 16: return F16;
		case 32: return F32;
		case 64: return F64;
		case 80: return F80;
		default: return F128;
	}
}

fn KeyComplexTag complex_tag_of(KeyFloatTag tag) => KeyComplexTag::values[tag.ordinal];
fn KeyFloatTag KeyComplexTag.scalar(self) => KeyFloatTag::values[self.ordinal];

<* The bit pattern zero-extended to 128 bits (f80: `hi` << 64 | `lo`). *>
fn uint128 KeyFloat.raw(self)
{
	switch (self.tag)
	{
		case F16: return (uint128)self.f16;
		case F32: return (uint128)self.f32;
		case F64: return (uint128)self.f64;
		case F80: return (uint128)self.f80.hi << 64 | (uint128)self.f80.lo;
		case F128: return (uint128)self.f128.hi << 64 | (uint128)self.f128.lo;
	}
}

<* Inverse of KeyFloat.raw; bits above the width are ignored. *>
fn KeyFloat from_raw(KeyFloatTag tag, uint128 bits)
{
	switch (tag)
	{
		case F16: return { .tag = F16, .f16 = (ushort)bits };
		case F32: return { .tag = F32, .f32 = (uint)bits };
		case F64: return { .tag = F64, .f64 = (ulong)bits };
		case F80: return { .tag = F80, .f80 = { .lo = (ulong)bits, .hi = (ushort)(bits >> 64) } };
		case F128: return { .tag = F128, .f128 = { .lo = (ulong)bits, .hi = (ulong)(bits >> 64) } };
	}
}

fn KeyFloat f16_value(ushort bits) => { .tag = F16, .f16 = bits };
fn KeyFloat f32_value(uint bits) => { .tag = F32, .f32 = bits };
fn KeyFloat f64_value(ulong bits) => { .tag = F64, .f64 = bits };
fn KeyFloat f80_value(F80Bits bits) => { .tag = F80, .f80 = bits };
fn KeyFloat f128_value(F128Bits bits) => { .tag = F128, .f128 = bits };

<* Components of a complex constant: [0] real, [1] imaginary. *>
fn KeyFloat[2] KeyComplex.parts(self)
{
	switch (self.tag)
	{
		case CF16: return { f16_value(self.cf16[0]), f16_value(self.cf16[1]) };
		case CF32: return { f32_value(self.cf32[0]), f32_value(self.cf32[1]) };
		case CF64: return { f64_value(self.cf64[0]), f64_value(self.cf64[1]) };
		case CF80: return { f80_value(self.cf80[0]), f80_value(self.cf80[1]) };
		case CF128: return { f128_value(self.cf128[0]), f128_value(self.cf128[1]) };
	}
}

<*
 Build a complex constant from two components of the same width.
 @require re.tag == im.tag : "complex components must have the same width"
*>
fn KeyComplex make_complex(KeyFloat re, KeyFloat im)
{
	switch (re.tag)
	{
		case F16: return { .tag = CF16, .cf16 = { re.f16, im.f16 } };
		case F32: return { .tag = CF32, .cf32 = { re.f32, im.f32 } };
		case F64: return { .tag = CF64, .cf64 = { re.f64, im.f64 } };
		case F80: return { .tag = CF80, .cf80 = { re.f80, im.f80 } };
		case F128: return { .tag = CF128, .cf128 = { re.f128, im.f128 } };
	}
}

<* Sign bit mask of the width (bit total_bits - 1). *>
fn uint128 sign_mask(KeyFloatTag tag) => (uint128)1 << (format_of(tag).total_bits - 1);

<* Biased exponent field. *>
fn uint KeyFloat.biased_exponent(self)
{
	FloatFormat fmt = format_of(self.tag);
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	return (uint)(self.raw() >> shift) & (((uint)1 << fmt.exp_bits) - 1);
}

<* Stored fraction field (f80: bits 0..62, i.e. without the explicit integer bit). *>
fn uint128 KeyFloat.fraction(self)
{
	FloatFormat fmt = format_of(self.tag);
	return self.raw() & (((uint128)1 << fmt.frac_bits) - 1);
}

fn bool KeyFloat.signbit(self) => (self.raw() & sign_mask(self.tag)) != 0;

fn FloatClass KeyFloat.classify(self)
{
	FloatFormat fmt = format_of(self.tag);
	uint e = self.biased_exponent();
	uint128 frac = self.fraction();
	uint e_max = ((uint)1 << fmt.exp_bits) - 1;
	if (fmt.explicit_int)
	{
		bool int_bit = ((self.raw() >> 63) & 1) != 0;
		if (e == 0) return (frac == 0 && !int_bit) ? FloatClass.ZERO : FloatClass.SUBNORMAL;
		if (!int_bit) return NAN; // unnormal, pseudo-infinity, pseudo-NaN
		if (e == e_max) return frac == 0 ? FloatClass.INFINITE : FloatClass.NAN;
		return NORMAL;
	}
	if (e == 0) return frac == 0 ? FloatClass.ZERO : FloatClass.SUBNORMAL;
	if (e == e_max) return frac == 0 ? FloatClass.INFINITE : FloatClass.NAN;
	return NORMAL;
}

fn bool KeyFloat.is_nan(self) => self.classify() == NAN;
fn bool KeyFloat.is_inf(self) => self.classify() == INFINITE;
<* std.math.isFinite: not inf and not NaN. *>
fn bool KeyFloat.is_finite(self) => self.classify() != INFINITE && self.classify() != NAN;
<* Zig `x == 0` (either sign). *>
fn bool KeyFloat.is_zero(self) => self.classify() == ZERO;
fn bool KeyFloat.is_positive_zero(self) => self.classify() == ZERO && !self.signbit();
fn bool KeyFloat.is_negative_zero(self) => self.classify() == ZERO && self.signbit();
<* std.math.isPositiveInf / isNegativeInf *>
fn bool KeyFloat.is_positive_inf(self) => self.classify() == INFINITE && !self.signbit();
fn bool KeyFloat.is_negative_inf(self) => self.classify() == INFINITE && self.signbit();

<* Zig unary minus: flips the sign bit only (also of NaN; no quieting). *>
fn KeyFloat KeyFloat.neg(self) => from_raw(self.tag, self.raw() ^ sign_mask(self.tag));
<* Zig @abs: clears the sign bit only. *>
fn KeyFloat KeyFloat.abs(self) => from_raw(self.tag, self.raw() & ~sign_mask(self.tag));
<*
 std.math.copysign(magnitude = self, sign = sign_of): bit operation, NaN included.
 @require self.tag == sign_of.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.copysign(self, KeyFloat sign_of)
{
	uint128 m = sign_mask(self.tag);
	return from_raw(self.tag, (self.raw() & ~m) | (sign_of.raw() & m));
}

<* +0.0 or -0.0 *>
fn KeyFloat zero(KeyFloatTag tag, bool negative = false) => from_raw(tag, negative ? sign_mask(tag) : 0);

<* 1.0 *>
fn KeyFloat one(KeyFloatTag tag)
{
	FloatFormat fmt = format_of(tag);
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	uint128 bits = (uint128)fmt.bias << shift;
	if (fmt.explicit_int) bits |= (uint128)1 << 63;
	return from_raw(tag, bits);
}

<* std.math.inf(T), negated when `negative`. *>
fn KeyFloat inf(KeyFloatTag tag, bool negative = false)
{
	FloatFormat fmt = format_of(tag);
	uint shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	uint128 bits = (((uint128)1 << fmt.exp_bits) - 1) << shift;
	if (fmt.explicit_int) bits |= (uint128)1 << 63;
	if (negative) bits |= sign_mask(tag);
	return from_raw(tag, bits);
}

<* std.math.nan(T) *>
fn KeyFloat std_nan(KeyFloatTag tag)
{
	switch (tag)
	{
		case F16: return f16_value(STD_NAN_F16);
		case F32: return f32_value(STD_NAN_F32);
		case F64: return f64_value(STD_NAN_F64);
		case F80: return f80_value(STD_NAN_F80);
		case F128: return f128_value(STD_NAN_F128);
	}
}

<* The reference's result of an invalid operation at this width (see NaN rules). *>
fn KeyFloat default_nan(KeyFloatTag tag)
{
	switch (tag)
	{
		case F16: return f16_value(DEFAULT_NAN_F16);
		case F32: return f32_value(DEFAULT_NAN_F32);
		case F64: return f64_value(DEFAULT_NAN_F64);
		case F80: return f80_value(DEFAULT_NAN_F80);
		case F128: return f128_value(DEFAULT_NAN_F128);
	}
}

<* Sets the quiet bit (the top fraction bit) of a NaN; other values unchanged. *>
fn KeyFloat KeyFloat.quiet(self)
{
	if (!self.is_nan()) return self;
	FloatFormat fmt = format_of(self.tag);
	return from_raw(self.tag, self.raw() | ((uint128)1 << (fmt.frac_bits - 1)));
}

// =============================================================================
// Width-generic arithmetic (dispatch implemented in stage 0)
// =============================================================================
// Zig `a + b` etc. on two values of the same float type T, rounding to nearest
// even, with the NaN rules above. f16/f32/f64 go to float_soft_narrow.c3,
// f80/f128 to float_soft_wide.c3 (status flags are dropped here).

<*
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.add(self, KeyFloat rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_add(self.f16, rhs.f16));
		case F32: return f32_value(f32_add(self.f32, rhs.f32));
		case F64: return f64_value(f64_add(self.f64, rhs.f64));
		case F80: return f80_value(f80_add(self.f80, rhs.f80));
		case F128: return f128_value(f128_add(self.f128, rhs.f128));
	}
}

<*
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.sub(self, KeyFloat rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_sub(self.f16, rhs.f16));
		case F32: return f32_value(f32_sub(self.f32, rhs.f32));
		case F64: return f64_value(f64_sub(self.f64, rhs.f64));
		case F80: return f80_value(f80_sub(self.f80, rhs.f80));
		case F128: return f128_value(f128_sub(self.f128, rhs.f128));
	}
}

<*
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.mul(self, KeyFloat rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_mul(self.f16, rhs.f16));
		case F32: return f32_value(f32_mul(self.f32, rhs.f32));
		case F64: return f64_value(f64_mul(self.f64, rhs.f64));
		case F80: return f80_value(f80_mul(self.f80, rhs.f80));
		case F128: return f128_value(f128_mul(self.f128, rhs.f128));
	}
}

<*
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn KeyFloat KeyFloat.div(self, KeyFloat rhs)
{
	switch (self.tag)
	{
		case F16: return f16_value(f16_div(self.f16, rhs.f16));
		case F32: return f32_value(f32_div(self.f32, rhs.f32));
		case F64: return f64_value(f64_div(self.f64, rhs.f64));
		case F80: return f80_value(f80_div(self.f80, rhs.f80));
		case F128: return f128_value(f128_div(self.f128, rhs.f128));
	}
}

// =============================================================================
// CONVERSIONS (owner: 10.3 `conversions`)
// =============================================================================
//
// Everything below works on bit patterns. It needs three primitives from
// float_soft_wide.c3: round_pack (one correctly rounded result from an exact
// sig * 2^exp), KeyFloat.to_f128 and from_f128 (the exact hub), plus
// f128_mul / f128_div for parseFloat's fast path and the narrow/wide dispatchers
// for the Value-level arithmetic.
//
// NaN through casts (observed with Zig 0.17.0 on x86_64-linux, LLVM backend,
// baseline CPU; test/c3/data/float_values/nan.txt): sign kept, payload aligned
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

fn bool cast_keeps_nan_quiet_bit(KeyFloatTag src, KeyFloatTag dest)
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
*>
fn KeyFloat KeyFloat.cast(self, KeyFloatTag dest)
{
	if (self.tag == dest) return self;
	KeyFloat src = self;
	if (src.tag == F80 && (src.f80.hi & 0x7FFF) != 0 && (src.f80.lo >> 63) == 0)
	{
		if (dest == F32 || dest == F64) return default_nan(dest);
		if (dest == F16) src.f80.lo |= (ulong)1 << 63;
	}
	if (src.tag == F16 && dest == F32 && src.is_nan())
	{
		// __extendhfsf2: the fraction (quiet bit included) moves up unchanged.
		// from_f128 always quiets a narrow NaN, so this pair is done here.
		uint bits = 0x7F80_0000 | ((uint)(src.f16 & 0x03FF) << 13);
		if (src.signbit()) bits |= 0x8000_0000;
		return f32_value(bits);
	}
	KeyFloat r = from_f128(src.to_f128(), dest);
	if (!cast_keeps_nan_quiet_bit(src.tag, dest)) r = r.quiet();
	return r;
}

<*
 Zig @floatFromInt(x) for a u64 into `dest`: rounded once to nearest even
 (u64 -> f16 overflows to +inf from 65520 up; u64 fits f80/f128 exactly).
*>
fn KeyFloat from_u64(ulong x, KeyFloatTag dest) => round_pack(dest, false, 0, (uint128)x, false);

<* Zig @floatFromInt(x) for an i64 into `dest`; -0 never results (0 -> +0.0). *>
fn KeyFloat from_i64(long x, KeyFloatTag dest)
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
	if (e_field == 0x7FFF) return r; // +inf * 2^64 + finite = +inf
	if (e_field == 0) return round_pack(F128, false, 0, (uint128)limb, false).f128; // r == +0
	uint128 sig = ((uint128)1 << 112) | ((uint128)(r.hi & F128_HI_FRAC_MASK) << 64) | (uint128)r.lo;
	// r = sig * 2^e with e = e_field - bias - 112 >= -112; r * 2^64 = sig * 2^s.
	int s = (int)e_field - 16383 - 112 + 64;
	if (s <= 14)
	{
		// r is an integer, so sig has at least -e trailing zero bits and the
		// right shift below is exact; sig << 14 < 2^127.
		uint128 m = s >= 0 ? sig << s : sig >> -s;
		return round_pack(F128, false, 0, m + (uint128)limb, false).f128;
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
	return round_pack(F128, false, d, m, sticky).f128;
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
*>
fn KeyFloat key_int_to_float(KeyInt i, KeyFloatTag dest)
{
	switch (i.tag)
	{
		case U64: return from_u64(i.u64, dest);
		case I64: return from_i64(i.i64, dest);
		case BIG_INT: return f128_value(big_int_to_f128(i.big_int)).cast(dest);
	}
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
	return bigint::calc_non_zero_twos_comp_limb_count((usz)2 + (usz)(unbiased > 0 ? unbiased : 0));
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

// -----------------------------------------------------------------------------
// std.fmt.parseFloat(f128, s) (Zig 0.17.0 lib/std/fmt/parse_float*.zig)
// -----------------------------------------------------------------------------

<* parse_float/FloatStream.zig *>
struct FloatStream
{
	String slice;
	sz offset;
	sz underscore_count;
}

fn sz FloatStream.offset_true(&self) => self.offset - self.underscore_count;

fn void FloatStream.reset(&self)
{
	self.offset = 0;
	self.underscore_count = 0;
}

fn bool FloatStream.has_len(&self, sz n) => self.offset + n <= self.slice.len;

fn bool FloatStream.first(&self, char* c)
{
	if (!self.has_len(1)) return false;
	*c = self.slice[self.offset];
	return true;
}

fn bool FloatStream.first_is(&self, String cs)
{
	char c;
	if (!self.first(&c)) return false;
	foreach (x : cs)
	{
		if (c == x) return true;
	}
	return false;
}

fn bool FloatStream.first_is_lower(&self, char lower)
{
	char c;
	if (!self.first(&c)) return false;
	return (c | 0x20) == lower;
}

fn bool FloatStream.first_is_digit(&self, int base)
{
	char c;
	if (!self.first(&c)) return false;
	return is_float_digit(c, base);
}

fn void FloatStream.advance(&self, sz n) => self.offset += n;

fn void FloatStream.skip_chars(&self, String cs)
{
	while (self.first_is(cs)) self.advance(1);
}

<* FloatStream.scanDigit: skips (and counts) '_' before a digit. *>
fn bool FloatStream.scan_digit(&self, int base, char* digit)
{
	while (true)
	{
		char c;
		if (!self.first(&c)) return false;
		if (c >= '0' && c <= '9')
		{
			self.advance(1);
			*digit = c - '0';
			return true;
		}
		if (base == 16 && c >= 'a' && c <= 'f')
		{
			self.advance(1);
			*digit = c - 'a' + 10;
			return true;
		}
		if (base == 16 && c >= 'A' && c <= 'F')
		{
			self.advance(1);
			*digit = c - 'A' + 10;
			return true;
		}
		if (c == '_')
		{
			self.advance(1);
			self.underscore_count++;
			continue;
		}
		return false;
	}
}

<* parse_float/common.zig isDigit *>
fn bool is_float_digit(char c, int base)
{
	if (base == 10) return c >= '0' && c <= '9';
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

<* parse_float/common.zig Number(f128) *>
struct ParsedNumber
{
	long exponent;
	uint128 mantissa;
	bool negative;
	<* More than max_mantissa digits were found during parse *>
	bool many_digits;
	<* The number was a hex-float (e.g. 0x1.234p567) *>
	bool hex;
}

<* parse.zig tryParseDigits (the 8-digit fast path is the same arithmetic mod 2^128). *>
fn void try_parse_digits(FloatStream* stream, uint128* x, int base)
{
	char digit;
	while (stream.scan_digit(base, &digit)) *x = *x * (uint128)base + (uint128)digit;
}

<* parse.zig min_n_digit_int: 10^(n-1). *>
fn uint128 min_n_digit_int(sz digit_count)
{
	uint128 n = 1;
	for (sz i = 1; i < digit_count; i++) n *= 10;
	return n;
}

<* parse.zig tryParseNDigits (base 16 also stops at 10^(n-1), as in Zig). *>
fn void try_parse_n_digits(FloatStream* stream, uint128* x, int base, sz n)
{
	uint128 limit = min_n_digit_int(n);
	char digit;
	while (*x < limit)
	{
		if (!stream.scan_digit(base, &digit)) break;
		*x = *x * (uint128)base + (uint128)digit;
	}
}

<* parse.zig parseScientific: false is Zig `null`. *>
fn bool parse_scientific(FloatStream* stream, long* out)
{
	long exponent = 0;
	bool negative = false;
	char c;
	if (stream.first(&c))
	{
		negative = c == '-';
		if (c == '-' || c == '+') stream.advance(1);
	}
	if (stream.first_is_digit(10))
	{
		char digit;
		while (stream.scan_digit(10, &digit))
		{
			// no overflows here, saturate well before overflow
			if (exponent < 0x1000_0000) exponent = 10 * exponent + digit;
		}
		*out = negative ? -exponent : exponent;
		return true;
	}
	return false;
}

<* parse.zig validUnderscores *>
fn bool valid_underscores(String s, int base)
{
	for (sz i = 0; i < s.len; i++)
	{
		if (s[i] == '_')
		{
			// underscore at start of end
			if (i == 0 || i + 1 == s.len) return false;
			// consecutive underscores
			if (!is_float_digit(s[i - 1], base) || !is_float_digit(s[i + 1], base)) return false;
			// next is guaranteed a digit, skip an extra
			i++;
		}
	}
	return true;
}

<* parse.zig parsePartialNumberBase for f128 (u128 mantissa). false is Zig `null`. *>
fn bool parse_partial_number_base(FloatStream* stream, bool negative, sz* n, int base, sz max_mantissa_digits, char exp_char_lower, ParsedNumber* out)
{
	// parse initial digits before dot
	uint128 mantissa = 0;
	try_parse_digits(stream, &mantissa, base);
	sz int_end = stream.offset_true();
	sz n_digits = stream.offset_true();

	// handle dot with the following digits
	long exponent = 0;
	if (stream.first_is("."))
	{
		stream.advance(1);
		sz marker = stream.offset_true();
		try_parse_digits(stream, &mantissa, base);
		sz n_after_dot = stream.offset_true() - marker;
		exponent = -(long)n_after_dot;
		n_digits += n_after_dot;
	}

	// adjust required shift to offset mantissa for base-16 (2^4)
	if (base == 16) exponent *= 4;

	if (n_digits == 0) return false;

	// handle scientific format
	long exp_number = 0;
	if (stream.first_is_lower(exp_char_lower))
	{
		stream.advance(1);
		if (!parse_scientific(stream, &exp_number)) return false;
		exponent += exp_number;
	}

	*n += stream.offset; // length must be complete parsed length

	if (stream.underscore_count > 0 && !valid_underscores(stream.slice, base)) return false;

	// common case with not many digits
	if (n_digits <= max_mantissa_digits)
	{
		*out = { .exponent = exponent, .mantissa = mantissa, .negative = negative, .many_digits = false, .hex = base == 16 };
		return true;
	}

	n_digits -= max_mantissa_digits;
	bool many_digits = false;
	stream.reset(); // re-parse from beginning
	while (stream.first_is("0._"))
	{
		// '0' = '.' + 2
		char next = stream.slice[stream.offset];
		if (next != '_')
		{
			n_digits -= next > '/' ? (sz)(next - '/') : 0; // next -| ('0' - 1)
		}
		else
		{
			stream.underscore_count++;
		}
		stream.advance(1);
	}
	if (n_digits > 0)
	{
		// at this point we have more than max_mantissa_digits significant digits, let's try again
		many_digits = true;
		mantissa = 0;
		stream.reset();
		try_parse_n_digits(stream, &mantissa, base, max_mantissa_digits);

		if (mantissa >= min_n_digit_int(max_mantissa_digits))
		{
			// big int
			exponent = (long)int_end - (long)stream.offset_true();
		}
		else
		{
			// the next byte must be present and be '.'
			stream.advance(1);
			sz marker = stream.offset_true();
			try_parse_n_digits(stream, &mantissa, base, max_mantissa_digits);
			exponent = (long)marker - (long)stream.offset_true();
		}
		if (base == 16) exponent *= 4;
		// add back the explicit part
		exponent += exp_number;
	}

	*out = { .exponent = exponent, .mantissa = mantissa, .negative = negative, .many_digits = many_digits, .hex = base == 16 };
	return true;
}

<* parse.zig parsePartialNumber *>
fn bool parse_partial_number(String s, bool negative, sz* n, ParsedNumber* out)
{
	assert(s.len != 0);
	*n = 0;
	if (s.len >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
	{
		FloatStream stream = { .slice = s[2..], .offset = 0, .underscore_count = 0 };
		*n += 2;
		return parse_partial_number_base(&stream, negative, n, 16, 32, 'p', out);
	}
	FloatStream stream = { .slice = s, .offset = 0, .underscore_count = 0 };
	return parse_partial_number_base(&stream, negative, n, 10, 38, 'e', out);
}

<* parse.zig parseNumber: the whole input must be consumed. *>
fn bool parse_number(String s, bool negative, ParsedNumber* out)
{
	sz consumed = 0;
	if (parse_partial_number(s, negative, &consumed, out)) return s.len == consumed;
	return false;
}

fn bool starts_with_ignore_case(String s, String prefix)
{
	if (s.len < prefix.len) return false;
	for (sz i = 0; i < prefix.len; i++)
	{
		char a = s[i];
		char b = prefix[i];
		if (a >= 'A' && a <= 'Z') a += 32;
		if (b >= 'A' && b <= 'Z') b += 32;
		if (a != b) return false;
	}
	return true;
}

<* parse.zig parseInfOrNan: "inf"/"infinity" (signed), "nan" (always std.math.nan, positive). *>
fn bool parse_inf_or_nan(String s, bool negative, F128Bits* out)
{
	sz consumed;
	KeyFloat value;
	if (starts_with_ignore_case(s, "inf"))
	{
		consumed = 3;
		if (starts_with_ignore_case(s[3..], "inity")) consumed = 8;
		value = inf(F128, negative);
	}
	else if (starts_with_ignore_case(s, "nan"))
	{
		consumed = 3;
		value = std_nan(F128);
	}
	else
	{
		return false;
	}
	if (s.len != consumed) return false;
	*out = value.f128;
	return true;
}

<* convert_hex.zig convertHex for f128 (round to nearest even on two guard bits). *>
fn F128Bits convert_hex(ParsedNumber n)
{
	if (n.mantissa == 0) return zero(F128, n.negative).f128;

	const long MAX_EXP = 16383;
	const long MIN_EXP = -16382;
	const long EXP_BIAS = MIN_EXP - 1;
	uint128 m = n.mantissa;
	long e = n.exponent;

	// mantissa now implicitly divided by 2^fractional_bits
	e += 112;

	// Shift mantissa and exponent to bring representation into float range.
	while (m != 0 && m >> 114 == 0)
	{
		m <<= 1;
		e -= 1;
	}
	if (n.many_digits) m |= 1;
	while (m >> 115 != 0)
	{
		m = (m >> 1) | (m & 1);
		e += 1;
	}

	// If exponent is too negative, denormalize in hopes of making it representable.
	while (m > 1 && e < MIN_EXP - 2)
	{
		m = (m >> 1) | (m & 1);
		e += 1;
	}

	// Round using two bottom bits.
	uint128 round = m & 3;
	m >>= 2;
	round |= m & 1; // round to even (round up if mantissa is odd)
	e += 2;
	if (round == 3)
	{
		m += 1;
		if (m == (uint128)1 << 113)
		{
			m >>= 1;
			e += 1;
		}
	}

	// Denormal or zero
	if (m >> 112 == 0) e = EXP_BIAS;

	// Infinity and range error
	if (e > MAX_EXP) return inf(F128, n.negative).f128;

	uint128 bits = m & (((uint128)1 << 112) - 1);
	bits |= (uint128)((e - EXP_BIAS) & 0x7FFF) << 112;
	if (n.negative) bits |= (uint128)1 << 127;
	return from_raw(F128, bits).f128;
}

<* 10^i as an exact f128 (i <= 48: 5^i < 2^113). *>
fn F128Bits f128_pow10(long i)
{
	uint128 p5 = 1;
	for (long k = 0; k < i; k++) p5 *= 5;
	return round_pack(F128, false, (int)i, p5, false).f128;
}

<*
 convert_fast.zig convertFast for f128: exact mantissa and power of ten, one
 f128 multiplication or division (compiler-rt, through f128_mul / f128_div).
 false is Zig `null`.
*>
fn bool convert_fast(ParsedNumber n, F128Bits* out)
{
	const long MIN_EXPONENT_FAST_PATH = -48;
	const long MAX_EXPONENT_FAST_PATH = 48;
	const long MAX_EXPONENT_FAST_PATH_DISGUISED = 82;
	const uint128 MAX_MANTISSA_FAST_PATH = (uint128)2 << 112;

	if (!(MIN_EXPONENT_FAST_PATH <= n.exponent && n.exponent <= MAX_EXPONENT_FAST_PATH_DISGUISED
		&& n.mantissa <= MAX_MANTISSA_FAST_PATH && !n.many_digits)) return false;

	F128Bits value;
	if (n.exponent <= MAX_EXPONENT_FAST_PATH)
	{
		// normal fast path
		value = round_pack(F128, false, 0, n.mantissa, false).f128;
		if (n.exponent < 0)
		{
			value = f128_div(value, f128_pow10(-n.exponent));
		}
		else
		{
			value = f128_mul(value, f128_pow10(n.exponent));
		}
	}
	else
	{
		// disguised fast path
		long shift = n.exponent - MAX_EXPONENT_FAST_PATH;
		uint128 pow = 1;
		for (long k = 0; k < shift; k++) pow *= 10;
		// math.mul(u128, ...) catch return null
		if (n.mantissa != 0 && pow > ~(uint128)0 / n.mantissa) return false;
		uint128 mantissa = n.mantissa * pow;
		if (mantissa > MAX_MANTISSA_FAST_PATH) return false;
		value = f128_mul(round_pack(F128, false, 0, mantissa, false).f128, f128_pow10(MAX_EXPONENT_FAST_PATH));
	}
	if (n.negative) value.hi ^= F128_SIGN_BIT;
	*out = value;
	return true;
}

<* decimal.zig Decimal(f128) constants. *>
const sz DECIMAL_MAX_DIGITS = 11564;
const sz DECIMAL_MAX_DIGITS_WITHOUT_OVERFLOW = 38;
const int DECIMAL_POINT_RANGE = 32767;
const int DECIMAL_MIN_EXPONENT = -4966;
const int DECIMAL_MAX_EXPONENT = 4934;
const int DECIMAL_MAX_DECIMAL_DIGITS = 37;

<* decimal.zig Decimal(f128): the "Simple Decimal Conversion" big decimal. *>
struct Decimal
{
	<* The number of significant digits in the decimal. *>
	sz num_digits;
	<* The offset of the decimal point in the significant digits. *>
	int decimal_point;
	<* If the number of significant digits stored in the decimal is truncated. *>
	bool truncated;
	<* buffer of the raw digits, in the range [0, 9]. *>
	char[DECIMAL_MAX_DIGITS] digits;
}

fn void Decimal.try_add_digit(&self, char digit)
{
	if (self.num_digits < DECIMAL_MAX_DIGITS) self.digits[self.num_digits] = digit;
	self.num_digits++;
}

fn void Decimal.trim(&self)
{
	assert(self.num_digits <= DECIMAL_MAX_DIGITS);
	while (self.num_digits != 0 && self.digits[self.num_digits - 1] == 0) self.num_digits--;
}

fn uint128 Decimal.round(&self)
{
	if (self.num_digits == 0 || self.decimal_point < 0) return 0;
	if (self.decimal_point > DECIMAL_MAX_DECIMAL_DIGITS) return ~(uint128)0;
	sz dp = (sz)self.decimal_point;
	uint128 n = 0;
	for (sz i = 0; i < dp; i++)
	{
		n *= 10;
		if (i < self.num_digits) n += (uint128)self.digits[i];
	}
	bool round_up = false;
	if (dp < self.num_digits)
	{
		round_up = self.digits[dp] >= 5;
		if (self.digits[dp] == 5 && dp + 1 == self.num_digits)
		{
			round_up = self.truncated || (dp != 0 && (self.digits[dp - 1] & 1) != 0);
		}
	}
	if (round_up) n += 1;
	return n;
}

<* Decimal digits of base^exp, most significant first, into `out`; returns the count. *>
fn sz pow_decimal_digits(uint base, usz exp, char[] out)
{
	// little-endian work buffer
	char[128] le;
	sz len = 1;
	le[0] = 1;
	for (usz k = 0; k < exp; k++)
	{
		uint carry = 0;
		for (sz i = 0; i < len; i++)
		{
			uint v = (uint)le[i] * base + carry;
			le[i] = (char)(v % 10);
			carry = v / 10;
		}
		while (carry != 0)
		{
			le[len++] = (char)(carry % 10);
			carry /= 10;
		}
	}
	for (sz i = 0; i < len; i++) out[i] = le[len - 1 - i];
	return len;
}

<*
 Decimal.numberOfDigitsLeftShift. Zig's pow2_to_pow5_table row `shift` is
 { .delta = digits of 2^shift, .cutoff = decimal digits of 5^shift } (row 0 is
 { 0, "" }); the row is computed here instead of copied.
 @require shift < 128
*>
fn sz Decimal.number_of_digits_left_shift(&self, usz shift)
{
	if (shift == 0) return 0;
	char[128] p5;
	char[128] p2;
	sz p5_len = pow_decimal_digits(5, shift, p5[..]);
	sz delta = pow_decimal_digits(2, shift, p2[..]);
	for (sz i = 0; i < p5_len; i++)
	{
		if (i >= self.num_digits) return delta - 1;
		if (self.digits[i] == p5[i]) continue;
		if (self.digits[i] < p5[i]) return delta - 1;
		return delta;
	}
	return delta;
}

<* Decimal.leftShift: decimal * 2^shift. *>
fn void Decimal.left_shift(&self, usz shift)
{
	if (self.num_digits == 0) return;
	sz num_new_digits = self.number_of_digits_left_shift(shift);
	sz read_index = self.num_digits;
	sz write_index = self.num_digits + num_new_digits;
	uint128 n = 0;
	while (read_index != 0)
	{
		read_index--;
		write_index--;
		n += (uint128)self.digits[read_index] << shift;
		uint128 quotient = n / 10;
		uint128 remainder = n - 10 * quotient;
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = (char)remainder;
		}
		else if (remainder > 0)
		{
			self.truncated = true;
		}
		n = quotient;
	}
	while (n > 0)
	{
		write_index--;
		uint128 quotient = n / 10;
		uint128 remainder = n - 10 * quotient;
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = (char)remainder;
		}
		else if (remainder > 0)
		{
			self.truncated = true;
		}
		n = quotient;
	}
	self.num_digits += num_new_digits;
	if (self.num_digits > DECIMAL_MAX_DIGITS) self.num_digits = DECIMAL_MAX_DIGITS;
	self.decimal_point += (int)num_new_digits;
	self.trim();
}

<* Decimal.rightShift: decimal * 2^-shift. *>
fn void Decimal.right_shift(&self, usz shift)
{
	sz read_index = 0;
	sz write_index = 0;
	uint128 n = 0;
	while (n >> shift == 0)
	{
		if (read_index < self.num_digits)
		{
			n = 10 * n + (uint128)self.digits[read_index];
			read_index++;
		}
		else if (n == 0)
		{
			return;
		}
		else
		{
			while (n >> shift == 0)
			{
				n *= 10;
				read_index++;
			}
			break;
		}
	}

	self.decimal_point -= (int)read_index - 1;
	if (self.decimal_point < -DECIMAL_POINT_RANGE)
	{
		self.num_digits = 0;
		self.decimal_point = 0;
		self.truncated = false;
		return;
	}

	uint128 mask = ((uint128)1 << shift) - 1;
	while (read_index < self.num_digits)
	{
		char new_digit = (char)(n >> shift);
		n = 10 * (n & mask) + (uint128)self.digits[read_index];
		read_index++;
		self.digits[write_index] = new_digit;
		write_index++;
	}
	while (n > 0)
	{
		char new_digit = (char)(n >> shift);
		n = 10 * (n & mask);
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = new_digit;
			write_index++;
		}
		else if (new_digit > 0)
		{
			self.truncated = true;
		}
	}
	self.num_digits = write_index;
	self.trim();
}

<*
 Decimal.parse (decimal input only, already validated by parse_number). Kept
 quirks: leading '0'/'_' are skipped without counting underscores, and the
 trailing-zero scan indexes the raw string with an underscore-free offset.
*>
fn void Decimal.parse(&self, String s)
{
	*self = {};
	FloatStream stream = { .slice = s, .offset = 0, .underscore_count = 0 };
	char digit;

	stream.skip_chars("0_");
	while (stream.scan_digit(10, &digit)) self.try_add_digit(digit);

	if (stream.first_is("."))
	{
		stream.advance(1);
		sz marker = stream.offset_true();
		// Skip leading zeroes
		if (self.num_digits == 0) stream.skip_chars("0");
		while (stream.scan_digit(10, &digit)) self.try_add_digit(digit);
		self.decimal_point = (int)marker - (int)stream.offset_true();
	}
	if (self.num_digits != 0)
	{
		// Ignore trailing zeros if any
		sz n_trailing_zeros = 0;
		sz i = stream.offset_true() - 1;
		while (true)
		{
			if (s[i] == '0')
			{
				n_trailing_zeros++;
			}
			else if (s[i] != '.')
			{
				break;
			}
			i--;
			if (i == 0) break;
		}
		self.decimal_point += (int)n_trailing_zeros;
		self.num_digits -= n_trailing_zeros;
		self.decimal_point += (int)self.num_digits;
		if (self.num_digits > DECIMAL_MAX_DIGITS)
		{
			self.truncated = true;
			self.num_digits = DECIMAL_MAX_DIGITS;
		}
	}
	if (stream.first_is_lower('e'))
	{
		stream.advance(1);
		bool neg_exp = false;
		if (stream.first_is("-"))
		{
			neg_exp = true;
			stream.advance(1);
		}
		else if (stream.first_is("+"))
		{
			stream.advance(1);
		}
		int exp_num = 0;
		while (stream.scan_digit(10, &digit))
		{
			if (exp_num < 0x10000) exp_num = 10 * exp_num + digit;
		}
		self.decimal_point += neg_exp ? -exp_num : exp_num;
	}

	for (sz i = self.num_digits; i < DECIMAL_MAX_DIGITS_WITHOUT_OVERFLOW; i++) self.digits[i] = 0;
}

<* common.zig BiasedFp(f128): significand bits and biased exponent. *>
struct BiasedFp
{
	uint128 f;
	int e;
}

fn F128Bits BiasedFp.to_f128(self, bool negative)
{
	uint128 word = self.f | ((uint128)(uint)self.e << 112);
	F128Bits r = from_raw(F128, word).f128;
	if (negative) r.hi ^= F128_SIGN_BIT;
	return r;
}

<* convert_slow.zig getShift *>
fn usz get_slow_shift(sz n)
{
	const char[19] POWERS = { 0, 3, 6, 9, 13, 16, 19, 23, 26, 29, 33, 36, 39, 43, 46, 49, 53, 56, 59 };
	return n < 19 ? (usz)POWERS[n] : 60;
}

<* convert_slow.zig convertSlow for f128 (`s` without the sign). *>
fn BiasedFp convert_slow(String s)
{
	const int MIN_EXPONENT = -16383;
	const int INFINITE_POWER = 0x7FFF;
	const BiasedFp ZERO_FP = { 0, 0 };
	const BiasedFp INF_FP = { 0, 0x7FFF };

	Decimal d;
	d.parse(s); // no need to recheck underscores
	if (d.num_digits == 0 || d.decimal_point < DECIMAL_MIN_EXPONENT) return ZERO_FP;
	if (d.decimal_point >= DECIMAL_MAX_EXPONENT) return INF_FP;

	int exp2 = 0;
	// Shift right toward (1/2 .. 1]
	while (d.decimal_point > 0)
	{
		usz shift = get_slow_shift((sz)d.decimal_point);
		d.right_shift(shift);
		if (d.decimal_point < -DECIMAL_POINT_RANGE) return ZERO_FP;
		exp2 += (int)shift;
	}
	// Shift left toward (1/2 .. 1]
	while (d.decimal_point <= 0)
	{
		usz shift;
		if (d.decimal_point == 0)
		{
			char first = d.digits[0];
			if (first >= 5) break;
			shift = first <= 1 ? 2 : 1;
		}
		else
		{
			shift = get_slow_shift((sz)-d.decimal_point);
		}
		d.left_shift(shift);
		if (d.decimal_point > DECIMAL_POINT_RANGE) return INF_FP;
		exp2 -= (int)shift;
	}
	// We are now in the range [1/2 .. 1] but the binary format uses [1 .. 2]
	exp2 -= 1;
	while (MIN_EXPONENT + 1 > exp2)
	{
		int n = (MIN_EXPONENT + 1) - exp2;
		if (n > 60) n = 60;
		d.right_shift((usz)n);
		exp2 += n;
	}
	if (exp2 - MIN_EXPONENT >= INFINITE_POWER) return INF_FP;

	// Shift the decimal to the hidden bit, and then round the value
	// to get the high mantissa+1 bits.
	d.left_shift(113);
	uint128 mantissa = d.round();
	if (mantissa >= (uint128)1 << 113)
	{
		// Rounding up overflowed to the carry bit, need to
		// shift back to the hidden bit.
		d.right_shift(1);
		exp2 += 1;
		mantissa = d.round();
		if (exp2 - MIN_EXPONENT >= INFINITE_POWER) return INF_FP;
	}
	int power2 = exp2 - MIN_EXPONENT;
	if (mantissa < (uint128)1 << 112) power2 -= 1;
	// Zero out all the bits above the mantissa bits.
	mantissa &= ((uint128)1 << 112) - 1;
	return { mantissa, power2 };
}

<*
 std.fmt.parseFloat(f128, s) from Zig 0.17.0 lib/std/fmt/parse_float.zig, as
 Parser.parseFloat calls it (digit separators already removed, suffix already
 stripped). Port: optional sign, parseNumber (decimal and 0x hexadecimal with
 p exponent, '_' separators allowed by Zig), parseInfOrNan, then convertHex /
 convertFast / convertSlow (Decimal with max_digits 11564; Eisel-Lemire is NOT
 used for f128). Correctly rounded to nearest even within those rules;
 "1e5000" -> +inf, "1e-5000" -> +0, "-nan" -> +NaN (std.math.nan).
 @return? INVALID_CHARACTER
*>
fn F128Bits? parse_f128(String s)
{
	if (s.len == 0) return INVALID_CHARACTER~;
	sz i = 0;
	bool negative = s[i] == '-';
	if (s[i] == '-' || s[i] == '+') i++;
	if (s.len == i) return INVALID_CHARACTER~;
	String rest = s[i..];

	ParsedNumber n;
	if (!parse_number(rest, negative, &n))
	{
		F128Bits special;
		if (parse_inf_or_nan(rest, negative, &special)) return special;
		return INVALID_CHARACTER~;
	}
	if (n.hex) return convert_hex(n);
	F128Bits fast;
	if (convert_fast(n, &fast)) return fast;
	return convert_slow(rest).to_f128(negative);
}

// -----------------------------------------------------------------------------
// Value-level operations
// -----------------------------------------------------------------------------

<* Zig `switch (qt.bitSizeof(comp))` -> width tag. *>
fn KeyFloatTag width_of(QualType qt, Compilation* comp) => tag_for_bits(qt.bit_sizeof(comp));

<* Width of a complex type's element (`qt.childType(comp).bitSizeof(comp)`). *>
fn KeyFloatTag element_width_of(QualType qt, Compilation* comp) => width_of(qt.child_type(comp), comp);

fn Value intern_float(KeyFloat f, Compilation* comp) => value::intern(comp, value_interner::key_float(f));
fn Value intern_complex(KeyComplex c, Compilation* comp) => value::intern(comp, value_interner::key_complex(c));

<*
 Value.toFloat(T): the real part of `v` as a `dest`-width float.
   int -> key_int_to_float; float -> KeyFloat.cast; complex -> real part cast.
 Precondition: v is not none and its key is INT, FLOAT or COMPLEX.
*>
fn KeyFloat to_float(Value v, KeyFloatTag dest, Compilation* comp)
{
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case INT: return key_int_to_float(key.int_val, dest);
		case FLOAT: return key.float_val.cast(dest);
		case COMPLEX: return key.complex_val.parts()[0].cast(dest);
		default: unreachable("to_float of a non-arithmetic value");
	}
}

<*
 Value.imag(T): int/float -> +0.0; complex -> the imaginary part cast to `dest`.
*>
fn KeyFloat imag(Value v, KeyFloatTag dest, Compilation* comp)
{
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case INT:
		case FLOAT:
			return zero(dest);
		case COMPLEX:
			return key.complex_val.parts()[1].cast(dest);
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
fn FloatToIntChangeKind float_to_int(Value* v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return NONE;

	KeyFloat float_val = to_float(*v, F128, comp);
	bool was_zero = float_val.is_zero();

	if (dest_ty.is(comp, BOOL))
	{
		KeyFloat one_val = one(F128);
		bool was_one = float_val.raw() == one_val.raw();
		*v = value::from_bool(!was_zero);
		if (was_zero || was_one) return NONE;
		return VALUE_CHANGED;
	}
	Signedness signedness = dest_ty.signedness(comp);
	if (signedness == UNSIGNED && float_val.signbit() && !float_val.is_zero() && !float_val.is_nan())
	{
		*v = value::ZERO;
		return OUT_OF_RANGE;
	}
	if (!float_val.is_finite())
	{
		*v = value::NONE;
		return OVERFLOW;
	}

	usz bits = (usz)dest_ty.bit_sizeof(comp);
	sz limb_len = calc_float_limb_len(float_val.f128);
	sz twos_len = bigint::calc_twos_comp_limb_count(bits);
	Limb[] limbs = value::alloc_limbs(comp, limb_len > twos_len ? limb_len : twos_len);
	defer value::free_limbs(comp, limbs);
	BigIntMutable big = value::mutable_over(limbs);
	bool had_fraction = f128_to_big_int_trunc(float_val.f128, &big);

	bool fits = big.to_const().fits_in_twos_comp(signedness, bits);
	*v = value::intern_big(comp, big.to_const());

	if (!was_zero && v.is_zero(comp)) return NONZERO_TO_ZERO;
	if (!fits) return OUT_OF_RANGE;
	if (had_fraction) return VALUE_CHANGED;
	return NONE;
}

<*
 Value.intToFloat: none stays none. Complex dest: *v = { toFloat(child width), +0 }.
 Real dest: from the int key - u64/i64 -> from_u64/from_i64 at dest's bit width;
 big_int -> big_int_to_f128 then cast (double rounding kept).
*>
fn void int_to_float(Value* v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return;

	if (dest_ty.is(comp, COMPLEX))
	{
		KeyFloatTag w = element_width_of(dest_ty, comp);
		*v = intern_complex(make_complex(to_float(*v, w, comp), zero(w)), comp);
		return;
	}
	InternerKey key = comp.interner.get(v.ref());
	assert(key.tag == INT, "int_to_float of a non-int value");
	*v = intern_float(key_int_to_float(key.int_val, width_of(dest_ty, comp)), comp);
}

<*
 Value.floatCast: none stays none. Complex dest: { to_float(w), imag(w) } with
 w = the element width; real dest: to_float(dest width). Interned.
*>
fn void float_cast(Value* v, QualType dest_ty, Compilation* comp)
{
	if (v.is_none()) return;
	if (try t = dest_ty.get(comp, COMPLEX))
	{
		KeyFloatTag w = width_of(t.complex, comp);
		*v = intern_complex(make_complex(to_float(*v, w, comp), imag(*v, w, comp)), comp);
		return;
	}
	*v = intern_float(to_float(*v, width_of(dest_ty, comp), comp), comp);
}

<* Value.realPart: none -> none; int/float -> v; complex -> its real part as a float value. *>
fn Value real_part(Value v, Compilation* comp)
{
	if (v.is_none()) return v;
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case INT:
		case FLOAT:
			return v;
		case COMPLEX:
			return intern_float(key.complex_val.parts()[0], comp);
		default:
			unreachable("real_part of a non-arithmetic value");
	}
}

<* Value.imaginaryPart: none -> none; int/float -> value::ZERO; complex -> imaginary part as a float value. *>
fn Value imaginary_part(Value v, Compilation* comp)
{
	if (v.is_none()) return v;
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case INT:
		case FLOAT:
			return value::ZERO;
		case COMPLEX:
			return intern_float(key.complex_val.parts()[1], comp);
		default:
			unreachable("imaginary_part of a non-arithmetic value");
	}
}

<* Value.complexConj: { to_float(w), -imag(w) } (sign flip, also of +0 and NaN), w = qt's element width. *>
fn Value complex_conj(Value v, QualType qt, Compilation* comp)
{
	KeyFloatTag w = element_width_of(qt, comp);
	return intern_complex(make_complex(to_float(v, w, comp), imag(v, w, comp).neg()), comp);
}

<* The four arithmetic operators of the float/complex branches. *>
enum FloatOp : char
{
	ADD,
	SUB,
	MUL,
	DIV,
}

fn KeyFloat apply_float_op(FloatOp op, KeyFloat a, KeyFloat b)
{
	switch (op)
	{
		case ADD: return a.add(b);
		case SUB: return a.sub(b);
		case MUL: return a.mul(b);
		case DIV: return a.div(b);
	}
}

<*
 Shared body of the float/complex branches of Value.add/sub/mul/div. Operand
 conversions happen in Zig's evaluation order (lhs.toFloat, lhs.imag,
 rhs.toFloat, rhs.imag); they are pure, so the order is not observable.
*>
fn void float_arith(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp, FloatOp op)
{
	if (qt.scalar_kind(comp) == COMPLEX_FLOAT)
	{
		KeyFloatTag w = element_width_of(qt, comp);
		KeyFloat a = to_float(lhs, w, comp);
		KeyFloat b = imag(lhs, w, comp);
		KeyFloat c = to_float(rhs, w, comp);
		KeyFloat d = imag(rhs, w, comp);
		KeyComplex result;
		switch (op)
		{
			case ADD: result = make_complex(a.add(c), b.add(d)); // complexAddSub
			case SUB: result = make_complex(a.sub(c), b.sub(d));
			case MUL: result = annex_g::complex_float_mul(a, b, c, d);
			case DIV: result = annex_g::complex_float_div(a, b, c, d);
		}
		*res = intern_complex(result, comp);
		return;
	}
	KeyFloatTag w = width_of(qt, comp);
	*res = intern_float(apply_float_op(op, to_float(lhs, w, comp), to_float(rhs, w, comp)), comp);
}

<*
 Float/complex branch of Value.add (qt.scalar_kind is FLOAT or COMPLEX_FLOAT).
 Real: to_float(lhs, w).add(to_float(rhs, w)), w = qt's width. Complex
 (complexAddSub): re = lhs.toFloat + rhs.toFloat, im = lhs.imag + rhs.imag at
 the element width. Always returns false (no overflow is reported for floats).
*>
fn bool add(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	float_arith(res, lhs, rhs, qt, comp, ADD);
	return false;
}

<* Float/complex branch of Value.sub, as `add` with subtraction. Returns false. *>
fn bool sub(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	float_arith(res, lhs, rhs, qt, comp, SUB);
	return false;
}

<*
 Float/complex branch of Value.mul. Real: a.mul(b) at qt's width. Complex:
 annex_g::complex_float_mul(lhs.toFloat, lhs.imag, rhs.toFloat, rhs.imag) at the
 element width. Returns false.
*>
fn bool mul(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	float_arith(res, lhs, rhs, qt, comp, MUL);
	return false;
}

<*
 Float/complex branch of Value.div. Real: a.div(b) (x/0 is inf or NaN, never an
 error). Complex: annex_g::complex_float_div. Returns false.
*>
fn bool div(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	float_arith(res, lhs, rhs, qt, comp, DIV);
	return false;
}
