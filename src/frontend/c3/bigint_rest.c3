// Sema contract stubs for c3c src/compiler/bigint.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
// Companion of bigint.c3: the bigint.c functions not ported yet. Int128 is
// uint128 here (see bigint.c3); the trivial i128_* arithmetic stubs may be
// replaced by inline uint128 math at the call sites when porting.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// bigint.c:8 (static)
fn uint u32_min(uint a, uint b)
{
	unreachable("sema stub: u32_min");
}

// bigint.c:13 (static)
fn usz size_max(usz a, usz b)
{
	unreachable("sema stub: size_max");
}

// bigint.c:18 (static)
fn uint unsigned_max(uint a, uint b)
{
	unreachable("sema stub: unsigned_max");
}

// bigint.c:24 (static)
fn char digit_to_char(char digit, bool upper)
{
	unreachable("sema stub: digit_to_char");
}

// bigint.c:94
fn Int int_from_real(Real d, TypeKind type)
{
	unreachable("sema stub: int_from_real");
}

// bigint.c:100
fn uint128 i128_from_int(ulong i)
{
	unreachable("sema stub: i128_from_int");
}

// bigint.c:105
fn uint128 i128_from_str(String str)
{
	unreachable("sema stub: i128_from_str");
}

// bigint.c:116
fn uint128 i128_from_strl(String str, String end)
{
	unreachable("sema stub: i128_from_strl");
}

// bigint.c:127
fn uint128 i128_from_hexstrl(String str, String end)
{
	unreachable("sema stub: i128_from_hexstrl");
}

// bigint.c:138
fn uint128 i128_add(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_add");
}

// bigint.c:146
fn uint128 i128_add64(uint128 op1, ulong op2)
{
	unreachable("sema stub: i128_add64");
}

// bigint.c:152
fn uint128 i128_sub(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_sub");
}

// bigint.c:161
fn uint128 i128_sub64(uint128 op1, ulong op2)
{
	unreachable("sema stub: i128_sub64");
}

// bigint.c:167
fn uint128 i128_extend(uint128 op, TypeKind type)
{
	unreachable("sema stub: i128_extend");
}

// bigint.c:181
fn uint128 i128_and(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_and");
}

// bigint.c:186
fn uint128 i128_or(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_or");
}

// bigint.c:191
fn uint128 i128_xor(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_xor");
}

// bigint.c:196
fn uint128 i128_neg(uint128 op1)
{
	unreachable("sema stub: i128_neg");
}

// bigint.c:202
fn uint128 i128_not(uint128 op1)
{
	unreachable("sema stub: i128_not");
}

// bigint.c:207 (static)
fn uint128 int64_mult(ulong u, ulong v)
{
	unreachable("sema stub: int64_mult");
}

// bigint.c:226
fn uint128 i128_mult(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_mult");
}

// bigint.c:233
fn uint128 i128_mult64(uint128 op1, ulong op2)
{
	unreachable("sema stub: i128_mult64");
}

// bigint.c:241
fn CmpRes int128_scomp64(uint128 op1, long op2)
{
	unreachable("sema stub: int128_scomp64");
}

// bigint.c:267
fn CmpRes int128_ucomp64(uint128 op1, ulong op2)
{
	unreachable("sema stub: int128_ucomp64");
}

// bigint.c:282
fn uint128 i128_shl64(uint128 op1, ulong amount)
{
	unreachable("sema stub: i128_shl64");
}

// bigint.c:291
fn uint128 i128_shl(uint128 op1, uint128 op)
{
	unreachable("sema stub: i128_shl");
}

// bigint.c:297
fn uint128 i128_lshr64(uint128 op1, ulong amount)
{
	unreachable("sema stub: i128_lshr64");
}

// bigint.c:310
fn bool i128_get_bit(uint128* op, int bit)
{
	unreachable("sema stub: i128_get_bit");
}

// bigint.c:320
fn bool i128_is_zero(uint128 op)
{
	unreachable("sema stub: i128_is_zero");
}

// bigint.c:325
fn uint128 i128_lshr(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_lshr");
}

// bigint.c:331
fn uint128 i128_ashr64(uint128 op1, ulong amount)
{
	unreachable("sema stub: i128_ashr64");
}

// bigint.c:341
fn uint128 i128_ashr(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_ashr");
}

// bigint.c:347
fn uint128 i128_add_swrap64(uint128 op1, long op2, bool* wrapped)
{
	unreachable("sema stub: i128_add_swrap64");
}

// bigint.c:355
fn uint128 i128_add_uwrap64(uint128 op1, ulong op2, bool* wrapped)
{
	unreachable("sema stub: i128_add_uwrap64");
}

// bigint.c:386 (static)
fn uint popcnt64(ulong n)
{
	unreachable("sema stub: popcnt64");
}

// bigint.c:393
fn uint i128_popcnt(uint128 i)
{
	unreachable("sema stub: i128_popcnt");
}

// bigint.c:398 (static)
fn uint ctz64(ulong n)
{
	unreachable("sema stub: ctz64");
}

// bigint.c:432
fn uint i128_ctz(uint128* op)
{
	unreachable("sema stub: i128_ctz");
}

// bigint.c:437 (static)
fn uint clz64(ulong n)
{
	unreachable("sema stub: clz64");
}

// bigint.c:472
fn uint i128_clz(uint128* op)
{
	unreachable("sema stub: i128_clz");
}

// bigint.c:477
fn Real i128_to_float(uint128 op)
{
	unreachable("sema stub: i128_to_float");
}

// bigint.c:482
fn Real i128_to_float_signed(uint128 op)
{
	unreachable("sema stub: i128_to_float_signed");
}

// bigint.c:491
fn void i128_udivrem(uint128 op1, uint128 op2, uint128* div, uint128* rem)
{
	unreachable("sema stub: i128_udivrem");
}

// bigint.c:516
fn uint128 i128_udiv(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_udiv");
}

// bigint.c:523
fn uint128 i128_urem(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_urem");
}

// bigint.c:530
fn uint128 i128_srem(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_srem");
}

// bigint.c:549
fn uint128 i128_from_unsigned(ulong i)
{
	unreachable("sema stub: i128_from_unsigned");
}

// bigint.c:554
fn uint128 i128_sdiv(uint128 op1, uint128 op2)
{
	unreachable("sema stub: i128_sdiv");
}

// bigint.c:723
fn int int_bits_needed(Int op)
{
	unreachable("sema stub: int_bits_needed");
}

// bigint.c:739
fn Int int_add(Int op1, Int op2)
{
	unreachable("sema stub: int_add");
}

// bigint.c:745
fn Int int_add64(Int op1, ulong op2)
{
	unreachable("sema stub: int_add64");
}

// bigint.c:750
fn Int int_sub(Int op1, Int op2)
{
	unreachable("sema stub: int_sub");
}

// bigint.c:756
fn Int int_sub64(Int op1, ulong op2)
{
	unreachable("sema stub: int_sub64");
}

// bigint.c:761
fn Int int_mul(Int op1, Int op2)
{
	unreachable("sema stub: int_mul");
}

// bigint.c:767
fn Int int_conv(Int op, TypeKind to_type)
{
	unreachable("sema stub: int_conv");
}

// bigint.c:799
fn Int int_div(Int op1, Int op2)
{
	unreachable("sema stub: int_div");
}

// bigint.c:814
fn Int int_rem(Int op1, Int op2)
{
	unreachable("sema stub: int_rem");
}

// bigint.c:829
fn Int int_and(Int op1, Int op2)
{
	unreachable("sema stub: int_and");
}

// bigint.c:835
fn Int int_or(Int op1, Int op2)
{
	unreachable("sema stub: int_or");
}

// bigint.c:841
fn Int int_xor(Int op1, Int op2)
{
	unreachable("sema stub: int_xor");
}

// bigint.c:847
fn Int int_neg(Int op)
{
	unreachable("sema stub: int_neg");
}

// bigint.c:852
fn Int int_not(Int op)
{
	unreachable("sema stub: int_not");
}

// bigint.c:857
fn Int int_shr64(Int op1, ulong op2)
{
	unreachable("sema stub: int_shr64");
}

// bigint.c:866
fn Int int_shl64(Int op, ulong op2)
{
	unreachable("sema stub: int_shl64");
}

// bigint.c:871
fn Real int_to_real(Int op, int precision)
{
	unreachable("sema stub: int_to_real");
}

// bigint.c:894
fn bool i128_can_convert_from_double(double x)
{
	unreachable("sema stub: i128_can_convert_from_double");
}

// bigint.c:901
fn bool i128_can_convert_from_double_signed(double x)
{
	unreachable("sema stub: i128_can_convert_from_double_signed");
}

// bigint.c:908
fn uint128 i128_from_double_unsigned(double x)
{
	unreachable("sema stub: i128_from_double_unsigned");
}

// bigint.c:919
fn uint128 i128_from_double_signed(double x)
{
	unreachable("sema stub: i128_from_double_signed");
}
