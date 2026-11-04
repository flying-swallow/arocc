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
// NaN rules (source-derived from the above; the vectors agent must confirm each,
// and a confirmed difference changes these constants, not the call sites):
//   - Invalid operation (0/0, inf-inf, 0*inf) -> DEFAULT_NAN_* below:
//     f16/f32/f64 negative quiet NaN (x86 SSE), f80 negative "real indefinite"
//     (x87), f128 POSITIVE quiet NaN (compiler-rt).
//   - One or two NaN operands -> the first NaN operand (lhs if NaN, else rhs),
//     quieted, sign and payload kept. (SSE and compiler-rt; for f80 the x87 rule
//     is "larger significand wins" when both are NaN - confirm with vectors.)
//   - Narrowing cast (@floatCast to a smaller width): sign kept, quiet bit set,
//     the top payload bits kept (compiler-rt truncf.zig, SSE cvtsd2ss agree).
//   - Widening cast: sign kept, payload shifted up. The quiet bit is set by SSE
//     (f32->f64) and x87 loads (any -> f80), but KEPT AS IS by compiler-rt
//     extendf.zig (f16 -> f32/f64, any -> f128). Signaling NaNs never arise from
//     C source in Aro (__builtin_nan sets the quiet bit), so this only matters
//     for vectors.
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
import aro::value_interner, aro::value, aro::compilation, aro::type_store, aro::bigint;

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

<*
 Zig @floatCast(x) to `dest` (also used for exact widening): round to nearest
 even once, overflow -> +-inf, underflow -> subnormal or signed zero, sign of
 zero kept, NaN per the cast NaN rules (narrowing quiets; widening quiets only
 on the SSE/x87 paths f32->f64 and any->f80). Same tag returns `self` unchanged.
 Build on the hub: from_f128(self.to_f128(), dest) is a single rounding because
 every format converts to f128 exactly.
*>
fn KeyFloat KeyFloat.cast(self, KeyFloatTag dest)
{
	unreachable("stage 0 stub");
}

<*
 Zig @floatFromInt(x) for a u64 into `dest`: rounded once to nearest even
 (u64 -> f16 overflows to +inf from 65520 up; u64 fits f80/f128 exactly).
*>
fn KeyFloat from_u64(ulong x, KeyFloatTag dest)
{
	unreachable("stage 0 stub");
}

<* Zig @floatFromInt(x) for an i64 into `dest`; -0 never results (0 -> +0.0). *>
fn KeyFloat from_i64(long x, KeyFloatTag dest)
{
	unreachable("stage 0 stub");
}

<*
 Value.zig bigIntToFloat(limbs, positive) -> f128, reproduced exactly INCLUDING
 its rounding: zero limbs -> +0; otherwise, from the most significant limb down,
 `result = @mulAdd(f128, 2^64, result, @floatFromInt(limb))` (one fused rounding
 per step, f128_mul_add), then negated (sign bit flip) when !positive. For more
 than two significant limbs this can differ from a correctly rounded
 conversion; keep the reference behaviour. Overflow gives +-inf.
*>
fn F128Bits big_int_to_f128(BigIntConst big)
{
	unreachable("stage 0 stub");
}

<*
 Value.toFloat(T) of an int key: u64/i64 -> from_u64/from_i64 (one rounding);
 big_int -> @floatCast(bigIntToFloat(..)) i.e. big_int_to_f128 then cast to
 `dest` (two roundings - a reference quirk to keep).
*>
fn KeyFloat key_int_to_float(KeyInt i, KeyFloatTag dest)
{
	unreachable("stage 0 stub");
}

<*
 std.math.big.int.calcLimbLen(float) for a finite f128: the limb count needed
 to hold its integer part (at least 1).
*>
fn sz calc_float_limb_len(F128Bits f)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

<*
 std.fmt.parseFloat(f128, s) from Zig 0.17.0 lib/std/fmt/parse_float.zig, as
 Parser.parseFloat calls it (digit separators already removed, suffix already
 stripped). Port: optional sign, parseNumber (decimal and 0x hexadecimal with
 p exponent, '_' separators allowed by Zig), parseInfOrNan, then convertHex /
 convertFast / convertSlow (Decimal with max_digits 11564; Eisel-Lemire is NOT
 used for f128). Correctly rounded to nearest even within those rules;
 "1e5000" -> +inf, "1e-5000" -> +0.
 @return? INVALID_CHARACTER
*>
fn F128Bits? parse_f128(String s)
{
	unreachable("stage 0 stub");
}

<*
 Value.toFloat(T): the real part of `v` as a `dest`-width float.
   int -> key_int_to_float; float -> KeyFloat.cast; complex -> real part cast.
 Precondition: v is not none and its key is INT, FLOAT or COMPLEX.
*>
fn KeyFloat to_float(Value v, KeyFloatTag dest, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.imag(T): int/float -> +0.0; complex -> the imaginary part cast to `dest`.
*>
fn KeyFloat imag(Value v, KeyFloatTag dest, Compilation* comp)
{
	unreachable("stage 0 stub");
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
 wrapped; keep that.)
*>
fn FloatToIntChangeKind float_to_int(Value* v, QualType dest_ty, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.intToFloat: none stays none. Complex dest: *v = { toFloat(child width), +0 }.
 Real dest: from the int key - u64/i64 -> from_u64/from_i64 at dest's bit width;
 big_int -> big_int_to_f128 then cast (double rounding kept).
*>
fn void int_to_float(Value* v, QualType dest_ty, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.floatCast: none stays none. Complex dest: { to_float(w), imag(w) } with
 w = the element width; real dest: to_float(dest width). Interned.
*>
fn void float_cast(Value* v, QualType dest_ty, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.realPart: none -> none; int/float -> v; complex -> its real part as a float value. *>
fn Value real_part(Value v, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.imaginaryPart: none -> none; int/float -> value::ZERO; complex -> imaginary part as a float value. *>
fn Value imaginary_part(Value v, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.complexConj: { to_float(w), -imag(w) } (sign flip, also of +0 and NaN), w = qt's element width. *>
fn Value complex_conj(Value v, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Float/complex branch of Value.add (qt.scalar_kind is FLOAT or COMPLEX_FLOAT).
 Real: to_float(lhs, w).add(to_float(rhs, w)), w = qt's width. Complex
 (complexAddSub): re = lhs.toFloat + rhs.toFloat, im = lhs.imag + rhs.imag at
 the element width. Always returns false (no overflow is reported for floats).
*>
fn bool add(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Float/complex branch of Value.sub, as `add` with subtraction. Returns false. *>
fn bool sub(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Float/complex branch of Value.mul. Real: a.mul(b) at qt's width. Complex:
 annex_g::complex_float_mul(lhs.toFloat, lhs.imag, rhs.toFloat, rhs.imag) at the
 element width. Returns false.
*>
fn bool mul(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Float/complex branch of Value.div. Real: a.div(b) (x/0 is inf or NaN, never an
 error). Complex: annex_g::complex_float_div. Returns false.
*>
fn bool div(Value* res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub");
}
