// Float comparisons, Value-level NaN/Inf predicates and float/complex printing:
// port of Value.zig compare (float/complex branches), isInf, isNan, isInfSign and
// the .float / .complex arms of Value.print.
//
// OWNER: plan 10 stage 1 agent 10.4 `compare-print`. Stage 0 fixed the signatures.
// (The bit-level predicates KeyFloat.is_nan/is_inf/... are stage-0 code in
// float_value.c3 so every agent can use them; this file owns everything that
// reads a Value or produces text.)
//
// Contract:
//   - No native floats (only float_soft_narrow.c3 may use them): work on KeyFloat
//     bits and the dispatching KeyFloat.mul/div/cast.
//   - Output is appended to a DString, like type_print.c3.
//
// Dependencies on other plan 10 agents: `compare` (Value level) needs to_float /
// imag (10.3); print_float / print_complex need KeyFloat.cast (10.3) for every
// width except f64, and KeyFloat.mul / KeyFloat.div at F64 (10.1) for the f16 /
// f32 / cf32 scaling. Everything else here is self-contained bit code.
module aro::float_value;
import aro::value_interner, aro::value, aro::compilation, aro::bigint, std::core::dstring;

<* Zig Value.IsInfKind (enum(i32)) *>
enum IsInfKind : int (int value)
{
	NEGATIVE { -1 },
	FINITE { 0 },
	POSITIVE { 1 },
	UNKNOWN { 0x7FFF_FFFF },
}

// =============================================================================
// Comparisons and predicates
// =============================================================================

<*
 Total-order key of a non-NaN float: the magnitude bits (sign cleared), negated
 for negative values, so -0 and +0 both map to 0. An f80 pseudo-denormal
 (exponent 0, integer bit 1) has the value of biased exponent 1 with the same
 significand, so it is moved there.
*>
fn int128 compare_key(KeyFloat f)
{
	uint128 mag = f.raw() & ~sign_mask(f.tag);
	if (f.tag == F80 && f.biased_exponent() == 0 && ((mag >> 63) & 1) != 0) mag += (uint128)1 << 64;
	return f.signbit() ? -(int128)mag : (int128)mag;
}

<*
 std.math.compare(a, op, b) for two floats of the same width: IEEE ordering,
 -0 == +0, any comparison with a NaN is false except NEQ, which is true.
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn bool KeyFloat.compare(self, CompareOperator op, KeyFloat rhs)
{
	if (self.is_nan() || rhs.is_nan()) return op == NEQ;
	int128 a = compare_key(self);
	int128 b = compare_key(rhs);
	switch (op)
	{
		case LT: return a < b;
		case LTE: return a <= b;
		case EQ: return a == b;
		case GTE: return a >= b;
		case GT: return a > b;
		case NEQ: return a != b;
	}
}

<*
 Float/complex branch of Value.compare, called after shallowCompare gave no
 answer and when at least one key is FLOAT or COMPLEX:
   either FLOAT: compare to_float(lhs, F128) with to_float(rhs, F128) using `op`.
   else either COMPLEX: assert(op == NEQ); return !(re equal) || !(im equal),
   comparing to_float(.., F128) and imag(.., F128) with EQ (so NaN parts make
   the values unequal).
*>
fn bool compare(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	InternerKeyTag lhs_tag = comp.interner.get(lhs.ref()).tag;
	InternerKeyTag rhs_tag = comp.interner.get(rhs.ref()).tag;
	if (lhs_tag == FLOAT || rhs_tag == FLOAT)
	{
		return to_float(lhs, F128, comp).compare(op, to_float(rhs, F128, comp));
	}
	assert(lhs_tag == COMPLEX || rhs_tag == COMPLEX, "float_value::compare needs a float or complex operand");
	assert(op == NEQ, "complex values only compare with !=");
	bool real_equal = to_float(lhs, F128, comp).compare(EQ, to_float(rhs, F128, comp));
	bool imag_equal = imag(lhs, F128, comp).compare(EQ, imag(rhs, F128, comp));
	return !real_equal || !imag_equal;
}

<* Value.isInf: none -> false; float -> isInf; complex -> either part isInf; else false. *>
fn bool is_inf(Value v, Compilation* comp)
{
	if (v.is_none()) return false;
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case FLOAT:
			return key.float_val.is_inf();
		case COMPLEX:
			KeyFloat[2] parts = key.complex_val.parts();
			return parts[0].is_inf() || parts[1].is_inf();
		default:
			return false;
	}
}

<* Value.isNan: none -> false; float -> isNan; complex -> either part isNan; else false. *>
fn bool is_nan(Value v, Compilation* comp)
{
	if (v.is_none()) return false;
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case FLOAT:
			return key.float_val.is_nan();
		case COMPLEX:
			KeyFloat[2] parts = key.complex_val.parts();
			return parts[0].is_nan() || parts[1].is_nan();
		default:
			return false;
	}
}

<*
 Value.isInfSign: none -> UNKNOWN; float -> POSITIVE / NEGATIVE / FINITE (NaN is
 FINITE); any other key (int included, e.g. a float 0.0 interned as REF_ZERO)
 -> UNKNOWN.
*>
fn IsInfKind is_inf_sign(Value v, Compilation* comp)
{
	if (v.is_none()) return UNKNOWN;
	InternerKey key = comp.interner.get(v.ref());
	if (key.tag != FLOAT) return UNKNOWN;
	if (key.float_val.is_positive_inf()) return POSITIVE;
	if (key.float_val.is_negative_inf()) return NEGATIVE;
	return FINITE;
}

// =============================================================================
// Ryu: std.fmt.float.binaryToDecimal for f64 (Zig 0.17.0 lib/std/fmt/float.zig)
// =============================================================================
// Ported with the Backend64_TablesSmall tables (the ones Zig uses in
// ReleaseSmall). They reproduce the Backend64_TablesFull entries exactly; a Zig
// 0.17.0 run of `{d}` on 360 bit patterns gave byte-identical output in Debug
// (full tables) and ReleaseSmall (small tables). The table values below are
// copied verbatim from float.zig (FLOAT64_POW5_TABLE, FLOAT64_POW5_SPLIT2,
// FLOAT64_POW5_OFFSETS, FLOAT64_POW5_INV_SPLIT2, FLOAT64_POW5_INV_OFFSETS).

const int RYU_SPECIAL_EXPONENT = 0x7fff_ffff;
const uint RYU_POW5_INV_BITCOUNT = 125;
const uint RYU_POW5_BITCOUNT = 125;
const uint RYU_BOUND1 = 21;
const uint RYU_BOUND2 = 63;
const uint RYU_POW5_TABLE_SIZE = 26;

const ulong[26] RYU_POW5_TABLE = {
	1, 5, 25, 125, 625, 3125, 15625, 78125, 390625, 1953125, 9765625, 48828125,
	244140625, 1220703125, 6103515625, 30517578125, 152587890625, 762939453125,
	3814697265625, 19073486328125, 95367431640625, 476837158203125,
	2384185791015625, 11920928955078125, 59604644775390625, 298023223876953125,
};

const ulong[2][13] RYU_POW5_SPLIT2 = {
	{ 0, 1152921504606846976 },
	{ 0, 1490116119384765625 },
	{ 1032610780636961552, 1925929944387235853 },
	{ 7910200175544436838, 1244603055572228341 },
	{ 16941905809032713930, 1608611746708759036 },
	{ 13024893955298202172, 2079081953128979843 },
	{ 6607496772837067824, 1343575221513417750 },
	{ 17332926989895652603, 1736530273035216783 },
	{ 13037379183483547984, 2244412773384604712 },
	{ 1605989338741628675, 1450417759929778918 },
	{ 9630225068416591280, 1874621017369538693 },
	{ 665883850346957067, 1211445438634777304 },
	{ 14931890668723713708, 1565756531257009982 },
};

const uint[21] RYU_POW5_OFFSETS = {
	0x00000000, 0x00000000, 0x00000000, 0x00000000,
	0x40000000, 0x59695995, 0x55545555, 0x56555515,
	0x41150504, 0x40555410, 0x44555145, 0x44504540,
	0x45555550, 0x40004000, 0x96440440, 0x55565565,
	0x54454045, 0x40154151, 0x55559155, 0x51405555,
	0x00000105,
};

const ulong[2][15] RYU_POW5_INV_SPLIT2 = {
	{ 1, 2305843009213693952 },
	{ 5955668970331000884, 1784059615882449851 },
	{ 8982663654677661702, 1380349269358112757 },
	{ 7286864317269821294, 2135987035920910082 },
	{ 7005857020398200553, 1652639921975621497 },
	{ 17965325103354776697, 1278668206209430417 },
	{ 8928596168509315048, 1978643211784836272 },
	{ 10075671573058298858, 1530901034580419511 },
	{ 597001226353042382, 1184477304306571148 },
	{ 1527430471115325346, 1832889850782397517 },
	{ 12533209867169019542, 1418129833677084982 },
	{ 5577825024675947042, 2194449627517475473 },
	{ 11006974540203867551, 1697873161311732311 },
	{ 10313493231639821582, 1313665730009899186 },
	{ 12701016819766672773, 2032799256770390445 },
};

const uint[19] RYU_POW5_INV_OFFSETS = {
	0x54544554, 0x04055545, 0x10041000, 0x00400414,
	0x40010000, 0x41155555, 0x00000454, 0x00010044,
	0x40000000, 0x44000041, 0x50454450, 0x55550054,
	0x51655554, 0x40004000, 0x01000001, 0x00010500,
	0x51515411, 0x05555554, 0x00000000,
};

<* std.fmt.float.FloatDecimal(u64) *>
struct RyuDecimal
{
	ulong mantissa;
	int exponent;
	bool sign;
}

<* floor(log_10(2^e)) *>
fn uint ryu_log10_pow2(uint e) => (uint)(((ulong)e * 169464822037455) >> 49);
<* floor(log_10(5^e)) *>
fn uint ryu_log10_pow5(uint e) => (uint)(((ulong)e * 196742565691928) >> 48);
<* if (e == 0) 1 else ceil(log_2(5^e)) *>
fn uint ryu_pow5_bits(uint e) => (uint)((((ulong)e * 163391164108059) >> 46) + 1);

fn uint ryu_pow5_factor(ulong value)
{
	uint count = 0;
	while (value > 0)
	{
		if (value % 5 != 0) return count;
		count++;
		value /= 5;
	}
	return 0;
}

fn bool ryu_multiple_of_pow5(ulong value, uint p) => ryu_pow5_factor(value) >= p;
fn bool ryu_multiple_of_pow2(ulong value, uint p) => (value & (((ulong)1 << p) - 1)) == 0;

<* mulShift64: ((m * mul) >> j) with a 128-bit multiplier. *>
fn ulong ryu_mul_shift(ulong m, ulong[2] mul, uint j)
{
	assert(j > 64);
	uint128 b0 = (uint128)m * mul[0];
	uint128 b2 = (uint128)m * mul[1];
	if (j >= 128) return 0;
	return (ulong)(((b0 >> 64) + b2) >> (j - 64));
}

<* Backend64_TablesSmall.computePow5 *>
fn ulong[2] ryu_compute_pow5(uint i)
{
	uint base = i / RYU_POW5_TABLE_SIZE;
	uint base2 = base * RYU_POW5_TABLE_SIZE;
	ulong[2] mul = RYU_POW5_SPLIT2[base];
	if (i == base2) return mul;
	uint offset = i - base2;
	ulong m = RYU_POW5_TABLE[offset];
	uint128 b0 = (uint128)m * mul[0];
	uint128 b2 = (uint128)m * mul[1];
	uint delta = ryu_pow5_bits(i) - ryu_pow5_bits(base2);
	uint shift = (i % 16) << 1;
	uint128 shifted_sum = ((b0 >> delta) + (b2 << (64 - delta))) + 1 + (uint128)((RYU_POW5_OFFSETS[i / 16] >> shift) & 3);
	return { (ulong)shifted_sum, (ulong)(shifted_sum >> 64) };
}

<* Backend64_TablesSmall.computeInvPow5 *>
fn ulong[2] ryu_compute_inv_pow5(uint i)
{
	uint base = (i + RYU_POW5_TABLE_SIZE - 1) / RYU_POW5_TABLE_SIZE;
	uint base2 = base * RYU_POW5_TABLE_SIZE;
	ulong[2] mul = RYU_POW5_INV_SPLIT2[base];
	if (i == base2) return mul;
	uint offset = base2 - i;
	ulong m = RYU_POW5_TABLE[offset];
	uint128 b0 = (uint128)m * (uint128)(mul[0] - 1);
	uint128 b2 = (uint128)m * mul[1];
	uint delta = ryu_pow5_bits(base2) - ryu_pow5_bits(i);
	uint shift = (i % 16) << 1;
	uint128 shifted_sum = ((b0 >> delta) + (b2 << (64 - delta))) + 1 + (uint128)((RYU_POW5_INV_OFFSETS[i / 16] >> shift) & 3);
	return { (ulong)shifted_sum, (ulong)(shifted_sum >> 64) };
}

<* binaryToDecimal(u64, bits, 52, 11, false, tables): shortest round-trip digits. *>
fn RyuDecimal ryu_f64_to_decimal(ulong bits)
{
	const uint MANTISSA_BITS = 52;
	const uint BIAS = 1023;
	bool ieee_sign = (bits >> 63) != 0;
	ulong ieee_mantissa = bits & (((ulong)1 << MANTISSA_BITS) - 1);
	uint ieee_exponent = (uint)(bits >> MANTISSA_BITS) & 0x7FF;

	if (ieee_exponent == 0 && ieee_mantissa == 0) return { 0, 0, ieee_sign };
	if (ieee_exponent == 0x7FF) return { ieee_mantissa, RYU_SPECIAL_EXPONENT, ieee_sign };

	int e2;
	ulong m2;
	if (ieee_exponent == 0)
	{
		e2 = 1 - (int)BIAS - (int)MANTISSA_BITS - 2;
		m2 = ieee_mantissa;
	}
	else
	{
		e2 = (int)ieee_exponent - (int)BIAS - (int)MANTISSA_BITS - 2;
		m2 = ((ulong)1 << MANTISSA_BITS) | ieee_mantissa;
	}
	bool accept_bounds = (m2 & 1) == 0;

	// Step 2: Determine the interval of legal decimal representations.
	ulong mv = 4 * m2;
	ulong mm_shift = (ieee_mantissa != 0 || ieee_exponent == 0) ? 1 : 0;

	// Step 3: Convert to a decimal power base.
	ulong vr;
	ulong vp;
	ulong vm;
	int e10;
	bool vm_is_trailing_zeros = false;
	bool vr_is_trailing_zeros = false;
	if (e2 >= 0)
	{
		uint q = ryu_log10_pow2((uint)e2) - (e2 > 3 ? 1 : 0);
		e10 = (int)q;
		int k = (int)(RYU_POW5_INV_BITCOUNT + ryu_pow5_bits(q) - 1);
		uint i = (uint)(-e2 + (int)q + k);
		ulong[2] pow5 = ryu_compute_inv_pow5(q);
		vr = ryu_mul_shift(4 * m2, pow5, i);
		vp = ryu_mul_shift(4 * m2 + 2, pow5, i);
		vm = ryu_mul_shift(4 * m2 - 1 - mm_shift, pow5, i);
		if (q <= RYU_BOUND1)
		{
			if (mv % 5 == 0)
			{
				vr_is_trailing_zeros = ryu_multiple_of_pow5(mv, q);
			}
			else if (accept_bounds)
			{
				vm_is_trailing_zeros = ryu_multiple_of_pow5(mv - 1 - mm_shift, q);
			}
			else
			{
				if (ryu_multiple_of_pow5(mv + 2, q)) vp -= 1;
			}
		}
	}
	else
	{
		uint q = ryu_log10_pow5((uint)-e2) - (-e2 > 1 ? 1 : 0);
		e10 = (int)q + e2;
		int i = -e2 - (int)q;
		int k = (int)ryu_pow5_bits((uint)i) - (int)RYU_POW5_BITCOUNT;
		uint j = (uint)((int)q - k);
		ulong[2] pow5 = ryu_compute_pow5((uint)i);
		vr = ryu_mul_shift(4 * m2, pow5, j);
		vp = ryu_mul_shift(4 * m2 + 2, pow5, j);
		vm = ryu_mul_shift(4 * m2 - 1 - mm_shift, pow5, j);
		if (q <= 1)
		{
			vr_is_trailing_zeros = true;
			if (accept_bounds)
			{
				vm_is_trailing_zeros = mm_shift == 1;
			}
			else
			{
				vp -= 1;
			}
		}
		else if (q < RYU_BOUND2)
		{
			vr_is_trailing_zeros = ryu_multiple_of_pow2(mv, q);
		}
	}

	// Step 4: Find the shortest decimal representation in the interval.
	uint removed = 0;
	ulong last_removed_digit = 0;
	while (vp / 10 > vm / 10)
	{
		vm_is_trailing_zeros = vm_is_trailing_zeros && vm % 10 == 0;
		vr_is_trailing_zeros = vr_is_trailing_zeros && last_removed_digit == 0;
		last_removed_digit = vr % 10;
		vr /= 10;
		vp /= 10;
		vm /= 10;
		removed++;
	}
	if (vm_is_trailing_zeros)
	{
		while (vm % 10 == 0)
		{
			vr_is_trailing_zeros = vr_is_trailing_zeros && last_removed_digit == 0;
			last_removed_digit = vr % 10;
			vr /= 10;
			vp /= 10;
			vm /= 10;
			removed++;
		}
	}
	if (vr_is_trailing_zeros && last_removed_digit == 5 && vr % 2 == 0) last_removed_digit = 4;

	bool round_up = (vr == vm && (!accept_bounds || !vm_is_trailing_zeros)) || last_removed_digit >= 5;
	return { vr + (round_up ? (ulong)1 : (ulong)0), e10 + (int)removed, ieee_sign };
}

<*
 Zig `w.print("{d}", .{x})` for an f64 bit pattern (Zig 0.17.0
 std.fmt.float.render, mode .decimal, no precision): the shortest round-trip
 digits from binaryToDecimal (Ryu, Backend64 tables; the "small" and "full"
 tables give the same digits), written without an exponent ("0.000001234",
 "123456000", "12345.6789", "1", "-0"). Specials: "inf", "-inf", "nan", "-nan"
 (the NaN sign bit is printed). Appends to `w`.

 The 347-byte buffer of Writer.printFloat always fits an f64 in decimal mode
 (the longest output, the smallest subnormal, needs 2 + 324 + 1 bytes), so the
 "(float)" BufferTooSmall fallback can never happen here.
*>
fn void format_f64_decimal(ulong bits, DString w)
{
	RyuDecimal d = ryu_f64_to_decimal(bits);
	if (d.sign) w.append_char('-');
	if (d.exponent == RYU_SPECIAL_EXPONENT)
	{
		w.append_string(d.mantissa != 0 ? "nan" : "inf");
		return;
	}

	// The mantissa's decimal digits (decimalLength(0) == 1, so zero is "0").
	char[20] digits;
	int olength = 0;
	ulong output = d.mantissa;
	do
	{
		digits[19 - olength] = (char)('0' + output % 10);
		output /= 10;
		olength++;
	}
	while (output != 0);
	char[] ds = digits[(sz)(20 - olength)..];

	int dp_offset = d.exponent + olength;
	if (dp_offset <= 0)
	{
		// 0.000001234
		w.append_string("0.");
		w.append_char_repeat('0', (sz)-dp_offset);
		w.append_bytes(ds);
	}
	else if (dp_offset >= olength)
	{
		// 123456000
		w.append_bytes(ds);
		w.append_char_repeat('0', (sz)(dp_offset - olength));
	}
	else
	{
		// 12345.6789
		w.append_bytes(ds[:dp_offset]);
		w.append_char('.');
		w.append_bytes(ds[dp_offset..]);
	}
}

// =============================================================================
// Value.print (.float / .complex arms)
// =============================================================================

const ulong F64_BITS_1000 = 0x408F_4000_0000_0000;
const ulong F64_BITS_1000000 = 0x412E_8480_0000_0000;

<*
 Zig @round for an f64 bit pattern: round to an integer, halfway cases away
 from zero, sign kept (so -0.4 -> -0). Infinities and integers >= 2^52 are
 returned unchanged; a NaN is returned quieted (libm round returns x + x).
*>
fn ulong f64_round_half_away(ulong bits)
{
	uint e = (uint)(bits >> 52) & 0x7FF;
	ulong sign = bits & 0x8000_0000_0000_0000;
	if (e == 0x7FF)
	{
		if ((bits & 0x000F_FFFF_FFFF_FFFF) != 0) return bits | 0x0008_0000_0000_0000;
		return bits;
	}
	if (e >= 1075) return bits; // |x| >= 2^52: already an integer
	if (e < 1022) return sign; // |x| < 0.5
	if (e == 1022) return sign | 0x3FF0_0000_0000_0000; // 0.5 <= |x| < 1
	// 1 <= |x| < 2^52: `frac_bits` fraction bits lie below the binary point.
	uint frac_bits = 1075 - e;
	ulong mask = ((ulong)1 << frac_bits) - 1;
	// Adding half an ulp of the integer part rounds the magnitude half away from
	// zero; a carry into the exponent field gives the next power of two.
	ulong mag = (bits & ~sign) + ((ulong)1 << (frac_bits - 1));
	return sign | (mag & ~mask);
}

<* Zig @as(f64, @floatCast(x)); f64 itself is passed through (KeyFloat.cast of the same tag is the identity). *>
fn KeyFloat print_to_f64(KeyFloat f)
{
	// if, not `?:`: c3c 0.8.5 miscompiles ternaries on KeyFloat at -O0.
	if (f.tag == F64) return f;
	return f.cast(F64);
}

<* Zig @round(@as(f64, @floatCast(x)) * scale) / scale, every step an f64 operation. *>
fn ulong print_scaled(KeyFloat f, ulong scale_bits)
{
	KeyFloat scale = f64_value(scale_bits);
	KeyFloat scaled = print_to_f64(f).mul(scale);
	KeyFloat rounded = f64_value(f64_round_half_away(scaled.f64));
	return rounded.div(scale).f64;
}

<* The bits Value.print formats for one float of a `.float` key or a complex component. *>
fn ulong print_bits(KeyFloat f, bool scale_narrow)
{
	if (scale_narrow)
	{
		switch (f.tag)
		{
			case F16: return print_scaled(f, F64_BITS_1000);
			case F32: return print_scaled(f, F64_BITS_1000000);
			default: break;
		}
	}
	return print_to_f64(f).f64;
}

<*
 The .float arm of Value.print:
   f16: x = (f64)h; print @round(x * 1000) / 1000;
   f32: x = (f64)f; print @round(x * 1000000) / 1000000;
   f64/f80/f128: print (f64)x (@floatCast: may overflow to inf).
 The scaling is f64 arithmetic (KeyFloat.mul / KeyFloat.div at F64, each
 rounded); Zig @round rounds to an integer, halfway cases away from zero (a
 bit-level helper in this file). Printing goes through format_f64_decimal.
*>
fn void print_float(KeyFloat f, DString w)
{
	format_f64_decimal(print_bits(f, true), w);
}

<*
 The .complex arm of Value.print: "{d} + {d}i" of the two parts (a negative
 imaginary part prints as "1 + -2i"). cf32 parts are rounded like f32 above;
 every other width (cf16 included - no 1000 scaling) is plain (f64)x.
*>
fn void print_complex(KeyComplex c, DString w)
{
	KeyFloat[2] parts = c.parts();
	bool scale = c.tag == CF32;
	format_f64_decimal(print_bits(parts[0], scale), w);
	w.append_string(" + ");
	format_f64_decimal(print_bits(parts[1], scale), w);
	w.append_char('i');
}
