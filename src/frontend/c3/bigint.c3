// Port of the parser-facing integer helpers of c3c src/compiler/bigint.c:
// i128_to_string, int_to_str, int_fits, the int/i128 comparisons and the
// trivial int_* accessors, and (below) the rest of bigint.c.
//
// Deviations from c3c:
// - `Int128 { high, low }` is a native uint128 (`Int.i`), so the i128_*
//   arithmetic (i128_add64, i128_mult64, i128_neg, i128_shl64, ...) is plain
//   uint128 math at the call site; only helpers with real logic are kept.
// - The i128_* helpers below are kept for call-site parity; they are plain
//   uint128 math (int64_mult, popcnt64, ctz64, clz64 use builtins).
// - i128_from_strl / i128_from_hexstrl take the C `end` pointer as the
//   String that follows the digits (`end.ptr` marks the stop).
module aro::frontend::c3::compiler;
import std::math;

const uint128 UINT128_MAX = ~(uint128)0;
const uint128 INT128_MAX = UINT128_MAX >> 1;
const uint128 INT128_MIN = (uint128)1 << 127;

fn bool i128_is_neg(uint128 op) => (op >> 127) != 0;

fn uint128 i128_from_signed(long i) => (uint128)(int128)i;

fn CmpRes i128_ucomp(uint128 op1, uint128 op2)
{
	if (op1 > op2) return CMP_GT;
	if (op1 < op2) return CMP_LT;
	return CMP_EQ;
}

fn CmpRes i128_scomp(uint128 op1, uint128 op2)
{
	int128 a = (int128)op1;
	int128 b = (int128)op2;
	if (a > b) return CMP_GT;
	if (a < b) return CMP_LT;
	return CMP_EQ;
}

fn CmpRes i128_comp(uint128 op1, uint128 op2, Type* type)
{
	return type_is_signed(type) ? i128_scomp(op1, op2) : i128_ucomp(op1, op2);
}

<* c3c `i128_to_string`: arena string of `op` in `base` (2..16), optionally with a 0b/0o/0x prefix. *>
fn String i128_to_string(uint128 op, ulong base, bool is_signed, bool use_prefix)
{
	assert(base >= 2 && base <= 16);
	const char[16] DIGITS = "0123456789ABCDEF";
	char[130] buffer;
	usz loc = 0;
	bool add_minus = is_signed && i128_is_neg(op);
	if (add_minus) op = -op;
	uint128 base_div = base;
	do
	{
		uint128 rem = op % base_div;
		buffer[loc++] = DIGITS[(usz)rem];
		op = op / base_div;
	}
	while (op != 0);
	char* res = calloc_arena(loc + 4);
	usz c = 0;
	if (add_minus) res[c++] = '-';
	if (use_prefix)
	{
		switch (base)
		{
			case 2:
				res[c++] = '0';
				res[c++] = 'b';
			case 8:
				res[c++] = '0';
				res[c++] = 'o';
			case 16:
				res[c++] = '0';
				res[c++] = 'x';
			default:
				break;
		}
	}
	while (loc > 0)
	{
		res[c++] = buffer[--loc];
	}
	res[c] = 0;
	return (String)res[:c];
}

fn String int_to_str(Int i, int radix, bool use_prefix)
{
	return i128_to_string(i.i, (ulong)radix, type_kind_is_signed(i.type), use_prefix);
}

fn bool int_is_neg(Int op)
{
	if (type_kind_is_unsigned(op.type)) return false;
	return i128_is_neg(op.i);
}

fn ulong int_to_u64(Int op) => (ulong)op.i;

fn long int_to_i64(Int op) => (long)(ulong)op.i;

fn bool int_is_zero(Int op) => op.i == 0;

fn CmpRes int_signed_compare(Int op1, long op2)
{
	if (type_kind_is_signed(op1.type))
	{
		return i128_scomp(op1.i, i128_from_signed(op2));
	}
	ulong high = (ulong)(op1.i >> 64);
	ulong low = (ulong)op1.i;
	if (high || op2 < 0 || low > (ulong)op2) return CMP_GT;
	if (low < (ulong)op2) return CMP_LT;
	return CMP_EQ;
}

fn bool binary_op_matches_res(BinaryOp op, CmpRes res)
{
	switch (op)
	{
		case GT:
			return res == CMP_GT;
		case GE:
			return res != CMP_LT;
		case LT:
			return res == CMP_LT;
		case LE:
			return res != CMP_GT;
		case NE:
			return res != CMP_EQ;
		case EQ:
			return res == CMP_EQ;
		default:
			unreachable();
	}
}

fn CmpRes int_unsigned_compare(Int op1, ulong op2)
{
	if (type_kind_is_signed(op1.type) && i128_is_neg(op1.i)) return CMP_LT;
	ulong high = (ulong)(op1.i >> 64);
	ulong low = (ulong)op1.i;
	if (high || low > op2) return CMP_GT;
	if (low < op2) return CMP_LT;
	return CMP_EQ;
}

fn CmpRes int_compare(Int op1, Int op2)
{
	if (type_kind_is_signed(op1.type))
	{
		if (type_kind_is_signed(op2.type)) return i128_scomp(op1.i, op2.i);
		if (int_is_neg(op1)) return CMP_LT;
		return i128_ucomp(op1.i, op2.i);
	}
	if (int_is_neg(op2)) return CMP_GT;
	return i128_ucomp(op1.i, op2.i);
}

fn bool int_comp(Int op1, Int op2, BinaryOp op) => binary_op_matches_res(op, int_compare(op1, op2));

fn bool int_icomp(Int op1, long op2, BinaryOp op) => binary_op_matches_res(op, int_signed_compare(op1, op2));

fn bool int_ucomp(Int op1, ulong op2, BinaryOp op) => binary_op_matches_res(op, int_unsigned_compare(op1, op2));

fn bool int_fits(Int op1, TypeKind kind)
{
	uint128 min;
	uint128 max;
	bool is_signed = false;
	switch (kind)
	{
		case I128:
			min = INT128_MIN;
			max = INT128_MAX;
			is_signed = true;
		case I64:
			min = i128_from_signed(long::min);
			max = i128_from_signed(long::max);
			is_signed = true;
		case I32:
			min = i128_from_signed(int::min);
			max = i128_from_signed(int::max);
			is_signed = true;
		case I16:
			min = i128_from_signed(short::min);
			max = i128_from_signed(short::max);
			is_signed = true;
		case I8:
			min = i128_from_signed(ichar::min);
			max = i128_from_signed(ichar::max);
			is_signed = true;
		case U128:
			max = UINT128_MAX;
		case U64:
			max = ulong::max;
		case U32:
			max = uint::max;
		case U16:
			max = ushort::max;
		case U8:
			max = char::max;
		default:
			unreachable();
	}
	bool op_is_signed = type_kind_is_signed(op1.type);
	if (is_signed)
	{
		if (op_is_signed)
		{
			if (i128_scomp(op1.i, min) == CMP_LT) return false;
			if (i128_scomp(op1.i, max) == CMP_GT) return false;
			return true;
		}
		// In the unsigned case, we don't need to test the lower limit.
		return i128_ucomp(op1.i, max) != CMP_GT;
	}
	if (op_is_signed)
	{
		if (i128_is_neg(op1.i)) return false;
		if (i128_ucomp(op1.i, max) == CMP_GT) return false;
		return true;
	}
	// In the unsigned case, we don't need to test the lower limit.
	return i128_ucomp(op1.i, max) != CMP_GT;
}

// ---------------------------------------------------------------------------
// The rest of bigint.c (formerly bigint_rest.c3). Int128 `{ high, low }` is
// a uint128; `.high` / `.low` are `(ulong)(x >> 64)` / `(ulong)x`.

// bigint.c:8 (static)
fn uint u32_min(uint a, uint b) => a < b ? a : b;

// bigint.c:13 (static)
fn usz size_max(usz a, usz b) => a > b ? a : b;

// bigint.c:18 (static)
fn uint unsigned_max(uint a, uint b) => a > b ? a : b;

// bigint.c:24 (static)
fn char digit_to_char(char digit, bool upper)
{
	if (digit <= 9) return digit + '0';
	if (digit <= 35) return digit + (upper ? 'A' : 'a') - 10;
	unreachable();
}

macro ulong @hi64(uint128 x) => (ulong)(x >> 64);
macro ulong @lo64(uint128 x) => (ulong)x;
macro uint128 @i128_make(ulong high, ulong low) => ((uint128)high << 64) | (uint128)low;

// bigint.c:94
fn Int int_from_real(Real d, TypeKind type)
{
	return { .i = type_kind_is_unsigned(type) ? i128_from_double_unsigned(d) : i128_from_double_signed(d), .type = type };
}

// bigint.c:100
fn uint128 i128_from_int(ulong i) => (uint128)i;

// bigint.c:105
fn uint128 i128_from_str(String str)
{
	uint128 x = 0;
	foreach (c : str)
	{
		if (c == 0) break;
		x = i128_add64(i128_mult64(x, 10), (ulong)(c - '0'));
	}
	return x;
}

// bigint.c:116: `end` is the remainder of `str` after the digits (C `end` pointer).
fn uint128 i128_from_strl(String str, String end)
{
	uint128 x = 0;
	usz len = end.ptr ? (usz)(end.ptr - str.ptr) : str.len;
	for (usz i = 0; i < len; i++)
	{
		x = i128_add64(i128_mult64(x, 10), (ulong)(str[i] - '0'));
	}
	return x;
}

// bigint.c:127
fn uint128 i128_from_hexstrl(String str, String end)
{
	uint128 x = 0;
	usz len = end.ptr ? (usz)(end.ptr - str.ptr) : str.len;
	for (usz i = 0; i < len; i++)
	{
		x = i128_add64(i128_shl64(x, 4), (ulong)char_hex_to_nibble(str[i]));
	}
	return x;
}

// bigint.c:138
fn uint128 i128_add(uint128 op1, uint128 op2) => op1 + op2;

// bigint.c:146
fn uint128 i128_add64(uint128 op1, ulong op2) => op1 + (uint128)op2;

// bigint.c:152
fn uint128 i128_sub(uint128 op1, uint128 op2) => op1 - op2;

// bigint.c:161
fn uint128 i128_sub64(uint128 op1, ulong op2) => op1 - (uint128)op2;

// bigint.c:167
fn uint128 i128_extend(uint128 op, TypeKind type)
{
	int bits = type_kind_bitsize(type);
	if (bits == 128) return op;
	ulong shift = 128 - (ulong)bits;
	op = i128_shl64(op, shift);
	bool is_signed = type_kind_is_signed(type);
	if (is_signed)
	{
		return i128_ashr64(op, shift);
	}
	return i128_lshr64(op, shift);
}

// bigint.c:181
fn uint128 i128_and(uint128 op1, uint128 op2) => op1 & op2;

// bigint.c:186
fn uint128 i128_or(uint128 op1, uint128 op2) => op1 | op2;

// bigint.c:191
fn uint128 i128_xor(uint128 op1, uint128 op2) => op1 ^ op2;

// bigint.c:196
fn uint128 i128_neg(uint128 op1) => -op1;

// bigint.c:202
fn uint128 i128_not(uint128 op1) => ~op1;

// bigint.c:207 (static)
fn uint128 int64_mult(ulong u, ulong v) => (uint128)u * (uint128)v;

// bigint.c:226
fn uint128 i128_mult(uint128 op1, uint128 op2) => op1 * op2;

// bigint.c:233
fn uint128 i128_mult64(uint128 op1, ulong op2) => op1 * (uint128)op2;

// bigint.c:241
fn CmpRes int128_scomp64(uint128 op1, long op2)
{
	return i128_scomp(op1, i128_from_signed(op2));
}

// bigint.c:267
fn CmpRes int128_ucomp64(uint128 op1, ulong op2)
{
	return i128_ucomp(op1, (uint128)op2);
}

// bigint.c:282
fn uint128 i128_shl64(uint128 op1, ulong amount)
{
	if (amount > 127) return 0;
	return op1 << amount;
}

// bigint.c:291
fn uint128 i128_shl(uint128 op1, uint128 op)
{
	if (op >> 64) return 0;
	return i128_shl64(op1, (ulong)op);
}

// bigint.c:297
fn uint128 i128_lshr64(uint128 op1, ulong amount)
{
	if (amount > 127) return 0;
	return op1 >> amount;
}

// bigint.c:310
fn bool i128_get_bit(uint128* op, int bit)
{
	assert(bit < 128 && bit >= 0);
	return ((*op >> bit) & 1) != 0;
}

// bigint.c:320
fn bool i128_is_zero(uint128 op) => op == 0;

// bigint.c:325
fn uint128 i128_lshr(uint128 op1, uint128 op2)
{
	if (op2 >> 64) return 0;
	return i128_lshr64(op1, (ulong)op2);
}

// bigint.c:331
fn uint128 i128_ashr64(uint128 op1, ulong amount)
{
	if (amount == 0) return op1;
	if (!i128_is_neg(op1)) return i128_lshr64(op1, amount);
	if (amount > 127) return UINT128_MAX;
	return (uint128)((int128)op1 >> amount);
}

// bigint.c:341
fn uint128 i128_ashr(uint128 op1, uint128 op2)
{
	if (op2 >> 64) return i128_is_neg(op1) ? UINT128_MAX : 0;
	return i128_ashr64(op1, (ulong)op2);
}

// bigint.c:347
fn uint128 i128_add_swrap64(uint128 op1, long op2, bool* wrapped)
{
	uint128 res = i128_add64(op1, (ulong)op2);
	bool is_less = i128_scomp(res, op1) == CMP_LT;
	*wrapped = op2 < 0 ? !is_less : is_less;
	return res;
}

// bigint.c:355
fn uint128 i128_add_uwrap64(uint128 op1, ulong op2, bool* wrapped)
{
	uint128 res = i128_add64(op1, op2);
	*wrapped = i128_ucomp(res, op1) == CMP_LT;
	return res;
}

// bigint.c:386 (static)
fn uint popcnt64(ulong n) => (uint)n.popcount();

// bigint.c:393
fn uint i128_popcnt(uint128 i) => popcnt64(@hi64(i)) + popcnt64(@lo64(i));

// bigint.c:398 (static): ctz64(0) is 64 like c3c's branch-free version.
fn uint ctz64(ulong n) => n == 0 ? 64 : (uint)n.ctz();

// bigint.c:432
fn uint i128_ctz(uint128* op)
{
	return !@lo64(*op) ? ctz64(@hi64(*op)) + 64 : ctz64(@lo64(*op));
}

// bigint.c:437 (static)
fn uint clz64(ulong n) => n == 0 ? 64 : (uint)n.clz();

// bigint.c:472
fn uint i128_clz(uint128* op)
{
	return @hi64(*op) ? clz64(@hi64(*op)) : clz64(@lo64(*op)) + 64;
}

// bigint.c:477
fn Real i128_to_float(uint128 op)
{
	return (Real)@lo64(op) + (Real)ldexp((double)@hi64(op), 64);
}

// bigint.c:482
fn Real i128_to_float_signed(uint128 op)
{
	if ((long)@hi64(op) < 0 && op != INT128_MIN)
	{
		return -i128_to_float_signed(i128_neg(op));
	}
	return (Real)@lo64(op) + (Real)ldexp((double)@hi64(op), 64);
}

// bigint.c:491: native division (c3c's shift loop leaves div = 0 and
// rem = op1 when op2 > op1, and divides by zero as 0 / op1 like it).
fn void i128_udivrem(uint128 op1, uint128 op2, uint128* div, uint128* rem)
{
	if (op2 == 0)
	{
		// c3c: clz(0) = 128 >= clz(op1), so the shift loop sets shift + 1 low bits.
		int shift = (int)(128 - i128_clz(&op1));
		*div = shift + 1 >= 128 ? UINT128_MAX : ((uint128)1 << (shift + 1)) - 1;
		*rem = op1;
		return;
	}
	*div = op1 / op2;
	*rem = op1 % op2;
}

// bigint.c:516
fn uint128 i128_udiv(uint128 op1, uint128 op2)
{
	uint128 div, rem;
	i128_udivrem(op1, op2, &div, &rem);
	return div;
}

// bigint.c:523
fn uint128 i128_urem(uint128 op1, uint128 op2)
{
	uint128 div, rem;
	i128_udivrem(op1, op2, &div, &rem);
	return rem;
}

// bigint.c:530
fn uint128 i128_srem(uint128 op1, uint128 op2)
{
	bool topbit1 = i128_is_neg(op1);
	bool topbit2 = i128_is_neg(op2);
	if (topbit1) op1 = i128_neg(op1);
	if (topbit2) op2 = i128_neg(op2);
	uint128 res = i128_urem(op1, op2);
	if (topbit1) return i128_neg(res);
	return res;
}

// bigint.c:549
fn uint128 i128_from_unsigned(ulong i) => (uint128)i;

// bigint.c:554
fn uint128 i128_sdiv(uint128 op1, uint128 op2)
{
	bool topbit1 = i128_is_neg(op1);
	bool topbit2 = i128_is_neg(op2);
	if (topbit1) op1 = i128_neg(op1);
	if (topbit2) op2 = i128_neg(op2);
	uint128 res = i128_udiv(op1, op2);
	if (topbit1 != topbit2) return i128_neg(res);
	return res;
}

// bigint.c:723
fn int int_bits_needed(Int op)
{
	TypeKind kind = op.type;
	uint128 i = op.i;
	if (type_kind_is_signed(kind))
	{
		if (i128_is_neg(i))
		{
			i = i128_neg(i);
			i = i128_sub64(i, 1);
		}
		return (int)(1 + 128 - i128_clz(&i));
	}
	return (int)(128 - i128_clz(&i));
}

// bigint.c:739
fn Int int_add(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_extend(i128_add(op1.i, op2.i), op1.type), op1.type };
}

// bigint.c:745
fn Int int_add64(Int op1, ulong op2)
{
	return { i128_extend(i128_add64(op1.i, op2), op1.type), op1.type };
}

// bigint.c:750
fn Int int_sub(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_extend(i128_sub(op1.i, op2.i), op1.type), op1.type };
}

// bigint.c:756
fn Int int_sub64(Int op1, ulong op2)
{
	return { i128_extend(i128_sub64(op1.i, op2), op1.type), op1.type };
}

// bigint.c:761
fn Int int_mul(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_extend(i128_mult(op1.i, op2.i), op1.type), op1.type };
}

// bigint.c:767
fn Int int_conv(Int op, TypeKind to_type)
{
	int bitsize = type_kind_bitsize(op.type);
	int to_bitsize = type_kind_bitsize(to_type);
	// Simple conversion, to 128 is a no op.
	if (to_bitsize == 128) return { op.i, to_type };

	bool from_signed = type_kind_is_signed(op.type);
	bool to_signed = type_kind_is_signed(to_type);
	if (bitsize < to_bitsize)
	{
		// Extending to a signed or with same signedness is a no-op.
		if (to_signed || to_signed == from_signed)
		{
			return { op.i, to_type };
		}
		// Extending from a signed to unsigned
		ulong shift = (ulong)(128 - to_bitsize);
		// Cut off the top of the signed bits
		return { i128_lshr64(i128_shl64(op.i, shift), shift), to_type };
	}
	// The other case is cutting down bits.
	ulong shift = (ulong)(128 - to_bitsize);
	uint128 without_top_bits = i128_lshr64(i128_shl64(op.i, shift), shift);
	if (to_signed)
	{
		return { i128_ashr64(i128_shl64(without_top_bits, shift), shift), to_type };
	}
	return { without_top_bits, to_type };
}

// bigint.c:799
fn Int int_div(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	uint128 res;
	if (type_kind_is_signed(op1.type))
	{
		res = i128_sdiv(op1.i, op2.i);
	}
	else
	{
		res = i128_udiv(op1.i, op2.i);
	}
	return { i128_extend(res, op1.type), op1.type };
}

// bigint.c:814
fn Int int_rem(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	uint128 res;
	if (type_kind_is_signed(op1.type))
	{
		res = i128_srem(op1.i, op2.i);
	}
	else
	{
		res = i128_urem(op1.i, op2.i);
	}
	return { res, op1.type };
}

// bigint.c:829
fn Int int_and(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_and(op1.i, op2.i), op1.type };
}

// bigint.c:835
fn Int int_or(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_or(op1.i, op2.i), op1.type };
}

// bigint.c:841
fn Int int_xor(Int op1, Int op2)
{
	assert(op1.type == op2.type);
	return { i128_xor(op1.i, op2.i), op1.type };
}

// bigint.c:847
fn Int int_neg(Int op)
{
	return int_sub({ 0, op.type }, op);
}

// bigint.c:852
fn Int int_not(Int op)
{
	return { i128_extend(i128_not(op.i), op.type), op.type };
}

// bigint.c:857
fn Int int_shr64(Int op1, ulong op2)
{
	if (type_kind_is_unsigned(op1.type))
	{
		return { i128_extend(i128_lshr64(op1.i, op2), op1.type), op1.type };
	}
	return { i128_extend(i128_ashr64(op1.i, op2), op1.type), op1.type };
}

// bigint.c:866
fn Int int_shl64(Int op, ulong op2)
{
	return { i128_extend(i128_shl64(op.i, op2), op.type), op.type };
}

// bigint.c:871
fn Real int_to_real(Int op, int precision)
{
	bool negative = int_is_neg(op);
	uint128 magnitude = negative ? i128_neg(op.i) : op.i;
	int shift = (int)(128 - i128_clz(&magnitude)) - precision;
	if (shift <= 0) return negative ? -(Real)@lo64(magnitude) : (Real)@lo64(magnitude);
	uint128 significand = i128_lshr64(magnitude, (ulong)shift);
	uint128 remainder = i128_sub(magnitude, i128_shl64(significand, (ulong)shift));
	uint128 halfway = i128_shl64(1, (ulong)shift - 1);
	CmpRes cmp = i128_ucomp(remainder, halfway);
	// Round once, to nearest with ties to even, before converting to the host double.
	ulong sig_low = @lo64(significand);
	if (cmp == CMP_GT || (cmp == CMP_EQ && (sig_low & 1))) sig_low++;
	Real result = ldexp((Real)sig_low, shift);
	return negative ? -result : result;
}

// bigint.c:894
fn bool i128_can_convert_from_double(double x)
{
	return math::is_finite(x) && x > -1 && x < ldexp(1, 128);
}

// bigint.c:901
fn bool i128_can_convert_from_double_signed(double x)
{
	return math::is_finite(x) && x >= -ldexp(1, 127) && x < ldexp(1, 127);
}

// bigint.c:908
fn uint128 i128_from_double_unsigned(double x)
{
	if (x >= ldexp(1, 64))
	{
		ulong hi = (ulong)ldexp(x, -64);
		ulong lo = (ulong)(x - ldexp((double)hi, 64));
		return @i128_make(hi, lo);
	}
	return i128_from_int((ulong)x);
}

// bigint.c:919
fn uint128 i128_from_double_signed(double x)
{
	return x < 0 ? i128_neg(i128_from_double_unsigned(-x)) : i128_from_double_unsigned(x);
}
