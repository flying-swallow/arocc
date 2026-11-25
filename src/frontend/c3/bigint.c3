// Port of the parser-facing integer helpers of c3c src/compiler/bigint.c:
// i128_to_string, int_to_str, int_fits, the int/i128 comparisons and the
// trivial int_* accessors.
//
// Deviations from c3c:
// - `Int128 { high, low }` is a native uint128 (`Int.i`), so the i128_*
//   arithmetic (i128_add64, i128_mult64, i128_neg, i128_shl64, ...) is plain
//   uint128 math at the call site; only helpers with real logic are kept.
// - The arithmetic Int ops (int_add, int_conv, int_to_real, ...) wait for sema.
module aro::frontend::c3::compiler;

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
