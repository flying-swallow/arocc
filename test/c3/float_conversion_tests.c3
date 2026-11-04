// Tests for the CONVERSIONS section of src/c3/float_value.c3 (plan 10 agent
// 10.3): KeyFloat.cast, int -> float, bigIntToFloat, float -> big int,
// std.fmt.parseFloat(f128) and the Value-level float/complex operations.
//
// Sources of expected values (each test says which one it uses):
// - "observed": printed by tiny standalone programs run with Zig 0.17.0
//   (/home/user/tools/zig/ziglang/zig, x86_64-linux) that reproduce the exact
//   expression Aro evaluates (@floatCast, @floatFromInt, Value.zig's
//   bigIntToFloat, std.fmt.parseFloat(f128, ..)) on volatile operands. Aro itself
//   was not built or run (the repo pins Zig 0.18.0-dev); no Aro parity is claimed.
// - "fixture <name>": the expected diagnostics / _Static_asserts of
//   test/cases/<name>.c, mapped to the result of the Value operation behind them.
// - "source-derived": worked out by hand from the Zig source and IEEE 754.
//
// These tests call the soft-float primitives of float_soft_wide.c3 (round_pack,
// to_f128, from_f128, f128_mul, f128_div), the narrow arithmetic of
// float_soft_narrow.c3 and annex_g.c3, which other plan 10 agents implement; the
// Bazel target is tagged "manual" until those land.
module float_conversion_tests;
import aro::float_value, aro::value, aro::value_interner, aro::bigint, aro::type_store, aro::target, aro::compilation;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn uint128 u128(ulong hi, ulong lo) => (uint128)hi << 64 | (uint128)lo;

fn void check_bits(KeyFloat f, KeyFloatTag tag, uint128 bits)
{
	if (f.tag != tag || f.raw() != bits)
	{
		io::printfn("got tag %s bits %032x, want tag %s bits %032x", f.tag, f.raw(), tag, bits);
		test::eq(1, 0);
	}
}

fn void check_f128(F128Bits f, ulong hi, ulong lo) => check_bits(float_value::f128_value(f), F128, u128(hi, lo));

fn KeyFloat raw(KeyFloatTag tag, uint128 bits) => float_value::from_raw(tag, bits);

const Host HOST = { X86_64, LINUX, GNU };

<* Run the body with an x86_64-linux-gnu compilation on a tracking allocator; checks nothing leaks. *>
macro @with_comp(; @body(Compilation* comp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		@body(&comp);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn Value fv(Compilation* comp, KeyFloat f) => value::intern(comp, value_interner::key_float(f));
fn Value f32v(Compilation* comp, uint bits) => fv(comp, float_value::f32_value(bits));
fn Value f64v(Compilation* comp, ulong bits) => fv(comp, float_value::f64_value(bits));
fn Value cv(Compilation* comp, KeyFloat re, KeyFloat im) => value::intern(comp, value_interner::key_complex(float_value::make_complex(re, im)));
fn Value c64v(Compilation* comp, ulong re, ulong im) => cv(comp, float_value::f64_value(re), float_value::f64_value(im));

fn void check_value(Value got, Value want)
{
	if (got.opt_ref != want.opt_ref)
	{
		io::printfn("value ref %x, want %x", (uint)got.opt_ref, (uint)want.opt_ref);
		test::eq(1, 0);
	}
}

fn QualType complex_of(Compilation* comp, QualType qt) => comp.type_store.put(type_store::type_complex(qt));

<* The interner dedups floats with `==` (as Zig does), so a NaN gets a new ref each time: compare bits. *>
fn void check_float_key(Compilation* comp, Value v, KeyFloat want)
{
	InternerKey k = comp.interner.get(v.ref());
	assert(k.tag == FLOAT);
	check_bits(k.float_val, want.tag, want.raw());
}

const ulong D_ONE = 0x3FF0_0000_0000_0000;
const ulong D_TWO = 0x4000_0000_0000_0000;
const ulong D_FOUR = 0x4010_0000_0000_0000;
const ulong D_NEG_FOUR = 0xC010_0000_0000_0000;
const ulong D_NEG_TWO = 0xC000_0000_0000_0000;
const ulong D_NEG_ZERO = 0x8000_0000_0000_0000;

// ---------------------------------------------------------------------------
// KeyFloat.cast
// ---------------------------------------------------------------------------

fn void cast_same_tag_is_identity() @test
{
	// source-derived: @floatCast to the same type is a no-op, even for a signaling NaN.
	check_bits(raw(F32, 0x7F80_0001).cast(F32), F32, 0x7F80_0001);
	check_bits(raw(F128, u128(0x7FFF_0000_0000_0000, 1)).cast(F128), F128, u128(0x7FFF_0000_0000_0000, 1));
}

fn void cast_from_f64_observed() @test
{
	// observed (Zig 0.17.0): @floatCast of f64 bit patterns to every width.
	// 1 + 2^-24: an f32 tie, rounds to even (down).
	KeyFloat a = raw(F64, 0x3FF0_0000_1000_0000);
	check_bits(a.cast(F16), F16, 0x3C00);
	check_bits(a.cast(F32), F32, 0x3F80_0000);
	check_bits(a.cast(F80), F80, u128(0x3FFF, 0x8000_0080_0000_0000));
	check_bits(a.cast(F128), F128, u128(0x3FFF_0000_0100_0000, 0));
	// 1 + 3 * 2^-24: an f32 tie, rounds to even (up).
	check_bits(raw(F64, 0x3FF0_0000_3000_0000).cast(F32), F32, 0x3F80_0002);
	// 0.1
	KeyFloat tenth = raw(F64, 0x3FB9_9999_9999_999A);
	check_bits(tenth.cast(F16), F16, 0x2E66);
	check_bits(tenth.cast(F32), F32, 0x3DCC_CCCD);
	check_bits(tenth.cast(F80), F80, u128(0x3FFB, 0xCCCC_CCCC_CCCC_D000));
	check_bits(tenth.cast(F128), F128, u128(0x3FFB_9999_9999_9999, 0xA000_0000_0000_0000));
	// min subnormal f64: underflows to +0 in f16/f32, normal in f80/f128.
	KeyFloat tiny = raw(F64, 1);
	check_bits(tiny.cast(F16), F16, 0);
	check_bits(tiny.cast(F32), F32, 0);
	check_bits(tiny.cast(F80), F80, u128(0x3BCD, 0x8000_0000_0000_0000));
	check_bits(tiny.cast(F128), F128, u128(0x3BCD_0000_0000_0000, 0));
	// -0.0 keeps its sign.
	KeyFloat nz = raw(F64, D_NEG_ZERO);
	check_bits(nz.cast(F16), F16, 0x8000);
	check_bits(nz.cast(F32), F32, 0x8000_0000);
	check_bits(nz.cast(F80), F80, u128(0x8000, 0));
	check_bits(nz.cast(F128), F128, u128(0x8000_0000_0000_0000, 0));
	// overflow to +inf in f16/f32
	KeyFloat big = raw(F64, 0x47EF_FFFF_F000_0000);
	check_bits(big.cast(F16), F16, 0x7C00);
	check_bits(big.cast(F32), F32, 0x7F80_0000);
	check_bits(big.cast(F80), F80, u128(0x407E, 0xFFFF_FF80_0000_0000));
	// 65520: overflows f16 (ties away from the largest finite 65504 into inf).
	check_bits(raw(F64, 0x40EF_FE00_0000_0000).cast(F16), F16, 0x7C00);
	check_bits(raw(F64, 0x40EF_FE00_0000_0000).cast(F32), F32, 0x477F_F000);
	// 2^-24: exactly the f16 min subnormal.
	check_bits(raw(F64, 0x3E70_0000_0000_0000).cast(F16), F16, 0x0001);
	check_bits(raw(F64, 0x3E70_0000_0000_0000).cast(F32), F32, 0x3380_0000);
}

fn void cast_from_f80_and_f128_observed() @test
{
	// observed (Zig 0.17.0)
	// f80 1 + 2^-53: an f64 tie, to even (down); exact in f128.
	KeyFloat a = raw(F80, u128(0x3FFF, 0x8000_0000_0000_0400));
	check_bits(a.cast(F64), F64, D_ONE);
	check_bits(a.cast(F32), F32, 0x3F80_0000);
	check_bits(a.cast(F128), F128, u128(0x3FFF_0000_0000_0000, 0x0800_0000_0000_0000));
	// f80 1 + 3 * 2^-53: tie, to even (up).
	check_bits(raw(F80, u128(0x3FFF, 0x8000_0000_0000_0C00)).cast(F64), F64, 0x3FF0_0000_0000_0002);
	// largest f80 below 2: rounds up to 2.0 in every narrower width.
	KeyFloat b = raw(F80, u128(0x3FFF, 0xFFFF_FFFF_FFFF_FFFF));
	check_bits(b.cast(F16), F16, 0x4000);
	check_bits(b.cast(F32), F32, 0x4000_0000);
	check_bits(b.cast(F64), F64, D_TWO);
	check_bits(b.cast(F128), F128, u128(0x3FFF_FFFF_FFFF_FFFF, 0xFFFE_0000_0000_0000));
	// f128 1 + 2^-65 / 1 + 3 * 2^-65 into f80 (64-bit significand).
	check_bits(raw(F128, u128(0x3FFF_0000_0000_0000, 0x0000_8000_0000_0000)).cast(F80), F80, u128(0x3FFF, 0x8000_0000_0000_0000));
	check_bits(raw(F128, u128(0x3FFF_0000_0000_0000, 0x0001_8000_0000_0000)).cast(F80), F80, u128(0x3FFF, 0x8000_0000_0000_0001));
	// f128 0.1
	KeyFloat c = raw(F128, u128(0x3FFB_9999_9999_9999, 0x9999_9999_9999_999A));
	check_bits(c.cast(F16), F16, 0x2E66);
	check_bits(c.cast(F32), F32, 0x3DCC_CCCD);
	check_bits(c.cast(F64), F64, 0x3FB9_9999_9999_999A);
	check_bits(c.cast(F80), F80, u128(0x3FFB, 0xCCCC_CCCC_CCCC_CCCD));
	// f128 min subnormal underflows to +0 everywhere.
	KeyFloat d = raw(F128, 1);
	check_bits(d.cast(F64), F64, 0);
	check_bits(d.cast(F80), F80, 0);
}

fn void cast_nan_observed() @test
{
	// observed (Zig 0.17.0): signaling NaNs through @floatCast. Every cast sets the
	// quiet bit except a cast to f128, which keeps it clear (compiler-rt
	// __extend*ftf2). The payload moves with the fraction's top bits.
	KeyFloat h = raw(F16, 0x7C01);
	check_bits(h.cast(F32), F32, 0x7FC0_2000);
	check_bits(h.cast(F64), F64, 0x7FF8_0400_0000_0000);
	check_bits(h.cast(F80), F80, u128(0x7FFF, 0xC020_0000_0000_0000));
	check_bits(h.cast(F128), F128, u128(0x7FFF_0040_0000_0000, 0));
	KeyFloat s = raw(F32, 0x7F80_0001);
	check_bits(s.cast(F16), F16, 0x7E00);
	check_bits(s.cast(F64), F64, 0x7FF8_0000_2000_0000);
	check_bits(s.cast(F80), F80, u128(0x7FFF, 0xC000_0100_0000_0000));
	check_bits(s.cast(F128), F128, u128(0x7FFF_0000_0200_0000, 0));
	KeyFloat d = raw(F64, 0x7FF0_0000_0000_0001);
	check_bits(d.cast(F32), F32, 0x7FC0_0000);
	check_bits(d.cast(F80), F80, u128(0x7FFF, 0xC000_0000_0000_0800));
	check_bits(d.cast(F128), F128, u128(0x7FFF_0000_0000_0000, 0x1000_0000_0000_0000));
	KeyFloat x = raw(F80, u128(0x7FFF, 0x8000_0000_0000_0001));
	check_bits(x.cast(F64), F64, 0x7FF8_0000_0000_0000);
	check_bits(x.cast(F128), F128, u128(0x7FFF_0000_0000_0000, 0x0002_0000_0000_0000));
	// source-derived: the default NaN of f64 (negative quiet) keeps its sign.
	check_bits(raw(F64, 0xFFF8_0000_0000_0000).cast(F32), F32, 0xFFC0_0000);
	check_bits(float_value::inf(F64, true).cast(F16), F16, 0xFC00);
	check_bits(float_value::inf(F16).cast(F128), F128, u128(0x7FFF_0000_0000_0000, 0));
}

// ---------------------------------------------------------------------------
// int -> float
// ---------------------------------------------------------------------------

fn void check_u64(ulong x, ushort h, uint s, ulong d, uint128 e, uint128 q)
{
	check_bits(float_value::from_u64(x, F16), F16, h);
	check_bits(float_value::from_u64(x, F32), F32, s);
	check_bits(float_value::from_u64(x, F64), F64, d);
	check_bits(float_value::from_u64(x, F80), F80, e);
	check_bits(float_value::from_u64(x, F128), F128, q);
}

fn void check_i64(long x, ushort h, uint s, ulong d, uint128 e, uint128 q)
{
	check_bits(float_value::from_i64(x, F16), F16, h);
	check_bits(float_value::from_i64(x, F32), F32, s);
	check_bits(float_value::from_i64(x, F64), F64, d);
	check_bits(float_value::from_i64(x, F80), F80, e);
	check_bits(float_value::from_i64(x, F128), F128, q);
}

fn void int_to_float_observed() @test
{
	// observed (Zig 0.17.0): @floatFromInt of u64 / i64 at every width.
	check_u64(0, 0, 0, 0, 0, 0);
	check_i64(0, 0, 0, 0, 0, 0);
	check_u64(1, 0x3C00, 0x3F80_0000, D_ONE, u128(0x3FFF, 0x8000_0000_0000_0000), u128(0x3FFF_0000_0000_0000, 0));
	check_i64(-1, 0xBC00, 0xBF80_0000, 0xBFF0_0000_0000_0000, u128(0xBFFF, 0x8000_0000_0000_0000), u128(0xBFFF_0000_0000_0000, 0));
	check_u64(65504, 0x7BFF, 0x477F_E000, 0x40EF_FC00_0000_0000, u128(0x400E, 0xFFE0_0000_0000_0000), u128(0x400E_FFC0_0000_0000, 0));
	check_i64(-65519, 0xFBFF, 0xC77F_EF00, 0xC0EF_FDE0_0000_0000, u128(0xC00E, 0xFFEF_0000_0000_0000), u128(0xC00E_FFDE_0000_0000, 0));
	check_u64(65520, 0x7C00, 0x477F_F000, 0x40EF_FE00_0000_0000, u128(0x400E, 0xFFF0_0000_0000_0000), u128(0x400E_FFE0_0000_0000, 0));
	check_u64(ulong::max, 0x7C00, 0x5F80_0000, 0x43F0_0000_0000_0000, u128(0x403E, 0xFFFF_FFFF_FFFF_FFFF), u128(0x403E_FFFF_FFFF_FFFF, 0xFFFE_0000_0000_0000));
	check_u64(16777217, 0x7C00, 0x4B80_0000, 0x4170_0000_1000_0000, u128(0x4017, 0x8000_0080_0000_0000), u128(0x4017_0000_0100_0000, 0));
	check_i64(-536870913, 0xFC00, 0xCE00_0000, 0xC1C0_0000_0080_0000, u128(0xC01C, 0x8000_0004_0000_0000), u128(0xC01C_0000_0008_0000, 0));
	check_u64(9007199254740993, 0x7C00, 0x5A00_0000, 0x4340_0000_0000_0000, u128(0x4034, 0x8000_0000_0000_0400), u128(0x4034_0000_0000_0000, 0x0800_0000_0000_0000));
	check_i64(-9007199254740995, 0xFC00, 0xDA00_0000, 0xC340_0000_0000_0002, u128(0xC034, 0x8000_0000_0000_0C00), u128(0xC034_0000_0000_0000, 0x1800_0000_0000_0000));
	check_i64(long::min, 0xFC00, 0xDF00_0000, 0xC3E0_0000_0000_0000, u128(0xC03E, 0x8000_0000_0000_0000), u128(0xC03E_0000_0000_0000, 0));
}

fn F128Bits big_to_f128(bool positive, Limb[] limbs) => float_value::big_int_to_f128({ .limbs = limbs, .positive = positive });

fn void big_int_to_f128_observed() @test
{
	// observed (Zig 0.17.0): Value.zig's bigIntToFloat copied into a probe.
	check_f128(big_to_f128(true, { 1, 0, 1 }), 0x407F_0000_0000_0000, 0);
	check_f128(big_to_f128(false, { 1, 0, 1 }), 0xC07F_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 0x8000_0000_0000_0001, 0, 1 }), 0x407F_0000_0000_0000, 0x0000_8000_0000_0000);
	check_f128(big_to_f128(true, { ulong::max, ulong::max, ulong::max }), 0x40BF_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 1, 0, 0x8000_0000_0000_0000 }), 0x40BE_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 0x8000_0000_0000_0001, 0, 4 }), 0x4081_0000_0000_0000, 0x0000_2000_0000_0000);
	check_f128(big_to_f128(true, { 1, 0x4000, 0x0001_0000_0000_0000 }), 0x40AF_0000_0000_0000, 0x0000_0000_0000_4000);
	check_f128(big_to_f128(true, { 0x8000_0000_0000_0000, 0x2000, 0x0002_0000_0000_0000 }), 0x40B0_0000_0000_0000, 0x0000_0000_0000_1000);
	check_f128(big_to_f128(true, { 0, 0, 0, 1 }), 0x40BF_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 0x1234_5678_9ABC_DEF0, 0x0FED_CBA9_8765_4321, 0x1111_1111_1111_1111, 0x2222_2222_2222_2222 }), 0x40FC_1111_1111_1111, 0x1110_8888_8888_8889);
	check_f128(big_to_f128(true, { ulong::max, ulong::max }), 0x407F_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 0x800, 0x0020_0000_0000_0000 }), 0x4074_0000_0000_0000, 0x40);
	// The fused steps round twice: 2^191 + 2^78 + 1 correctly rounds to
	// 2^191 + 2^79, but the middle step ties to even first, giving 2^191.
	check_f128(big_to_f128(true, { 1, 0x4000, 0x8000_0000_0000_0000 }), 0x40BE_0000_0000_0000, 0);
	check_f128(big_to_f128(true, { 1, 0xC000, 0x8000_0000_0000_0000 }), 0x40BE_0000_0000_0000, 2);
	// source-derived: no limbs -> +0; normalized zero -> +0.
	check_f128(big_to_f128(true, {}), 0, 0);
	check_f128(big_to_f128(true, { 0 }), 0, 0);
}

fn void big_int_to_f128_overflow_observed() @test
{
	// observed (Zig 0.17.0): 2^(64*299) -> +inf; 2^16320 is finite.
	Limb[300] limbs;
	limbs[299] = 1;
	check_f128(big_to_f128(true, limbs[..]), 0x7FFF_0000_0000_0000, 0);
	check_f128(big_to_f128(false, limbs[..]), 0xFFFF_0000_0000_0000, 0);
	limbs[299] = 0;
	limbs[255] = 1;
	check_f128(big_to_f128(true, limbs[:256]), 0x7FBF_0000_0000_0000, 0);
}

fn void key_int_to_float_double_rounding_observed() @test
{
	// observed (Zig 0.17.0): 2^127 + 2^74 + 1 goes through f128 (2^127 + 2^74, an
	// f64 tie) and then to f64 (to even: 2^127). A single rounding would give
	// 0x47E0000000000001. Reference quirk kept.
	Limb[2] limbs = { 1, 0x8000_0000_0000_0400 };
	KeyInt k = { .tag = BIG_INT, .big_int = { .limbs = limbs[..], .positive = true } };
	check_bits(float_value::key_int_to_float(k, F128), F128, u128(0x407E_0000_0000_0000, 0x0800_0000_0000_0000));
	check_bits(float_value::key_int_to_float(k, F64), F64, 0x47E0_0000_0000_0000);
	check_bits(float_value::key_int_to_float(k, F32), F32, 0x7F00_0000);
	KeyInt u = { .tag = U64, .u64 = 3 };
	check_bits(float_value::key_int_to_float(u, F32), F32, 0x4040_0000);
	KeyInt n = { .tag = I64, .i64 = -2 };
	check_bits(float_value::key_int_to_float(n, F64), F64, D_NEG_TWO);
}

// ---------------------------------------------------------------------------
// float -> big int (setFloat .trunc)
// ---------------------------------------------------------------------------

fn void calc_float_limb_len_source_derived() @test
{
	// source-derived from std.math.big.int.calcLimbLen
	check(float_value::calc_float_limb_len({ 0, 0 }), 1);
	check(float_value::calc_float_limb_len({ 1, 0 }), 1);                       // subnormal
	check(float_value::calc_float_limb_len({ 0, 0x3FFE_0000_0000_0000 }), 1);  // 0.5: 2 + 0 bits
	check(float_value::calc_float_limb_len({ 0, 0x403D_0000_0000_0000 }), 1);  // 2^62: 64 bits
	check(float_value::calc_float_limb_len({ 0, 0x403E_0000_0000_0000 }), 2);  // 2^63: 65 bits
	check(float_value::calc_float_limb_len({ 0, 0x7FFE_0000_0000_0000 }), 257); // 2^16383: 16385 bits
	check(float_value::calc_float_limb_len({ 0, 0x7FFF_0000_0000_0000 }), 0);  // inf
}

fn void check_trunc(F128Bits f, bool want_inexact, bool want_positive, Limb[] want)
{
	Limb[300] buf;
	BigIntMutable m = { .limbs = buf[:float_value::calc_float_limb_len(f)], .len = 1, .positive = true };
	bool inexact = float_value::f128_to_big_int_trunc(f, &m);
	assert(inexact == want_inexact);
	assert(m.positive == want_positive);
	check(m.len, want.len);
	for (sz i = 0; i < want.len; i++) assert(m.limbs[i] == want[i]);
}

fn void f128_to_big_int_trunc_source_derived() @test
{
	// source-derived from Mutable.setFloat(.., .trunc)
	check_trunc({ 0, 0 }, false, true, { 0 });
	check_trunc({ 0, 0x8000_0000_0000_0000 }, false, true, { 0 });              // -0.0
	check_trunc({ 0, 0xBFFE_0000_0000_0000 }, true, true, { 0 });               // -0.5 -> +0
	check_trunc({ 1, 0 }, true, true, { 0 });                                   // min subnormal
	check_trunc({ 0, 0x3FFF_8000_0000_0000 }, true, true, { 1 });               // 1.5
	check_trunc({ 0, 0xC000_4000_0000_0000 }, true, false, { 2 });              // -2.5
	check_trunc({ 0, 0x4000_0000_0000_0000 }, false, true, { 2 });              // 2.0
	// f64 1e30 widened: 1000000000000000019884624838656 exactly.
	check_trunc(raw(F64, 0x4629_3E59_39A0_8CEA).cast(F128).f128, false, true, { 0x4675_0000_0000_0000, 0xC_9F2C_9CD0 });
	// 2^112 + 1 (exponent 112: exact, no shift) and (2^113 - 1) * 2^1.
	check_trunc({ 1, 0x406F_0000_0000_0000 }, false, true, { 1, 0x0001_0000_0000_0000 });
	check_trunc({ ulong::max, 0x4070_FFFF_FFFF_FFFF }, false, true, { 0xFFFF_FFFF_FFFF_FFFE, 0x0003_FFFF_FFFF_FFFF });
	// -(2^200 + 2^152): shift 88 = one limb + 24 bits.
	check_trunc({ 0, 0xC0C7_0000_0000_0001 }, false, false, { 0, 0, 0x0100_0000, 0x100 });
	// 2^111 + 0.5: exponent 111, fraction bit set.
	check_trunc({ 1, 0x406E_0000_0000_0000 }, true, true, { 0, 0x0000_8000_0000_0000 });
}

// ---------------------------------------------------------------------------
// parse_f128 (std.fmt.parseFloat(f128, s))
// ---------------------------------------------------------------------------

fn void check_parse(String s, ulong hi, ulong lo)
{
	F128Bits? r = float_value::parse_f128(s);
	if (catch r)
	{
		io::printfn("parse_f128(\"%s\") failed", s);
		test::eq(1, 0);
		return;
	}
	F128Bits f = r;
	if (f.hi != hi || f.lo != lo)
	{
		io::printfn("parse_f128(\"%s\") = %016x%016x, want %016x%016x", s, f.hi, f.lo, hi, lo);
		test::eq(1, 0);
	}
}

fn void check_parse_error(String s)
{
	F128Bits? r = float_value::parse_f128(s);
	if (try r)
	{
		io::printfn("parse_f128(\"%s\") succeeded", s);
		test::eq(1, 0);
	}
}

fn void parse_f128_basic_observed() @test
{
	// observed (Zig 0.17.0 std.fmt.parseFloat(f128, s))
	check_parse("0", 0, 0);
	check_parse("-0", 0x8000_0000_0000_0000, 0);
	check_parse("+1", 0x3FFF_0000_0000_0000, 0);
	check_parse("1", 0x3FFF_0000_0000_0000, 0);
	check_parse("0.1", 0x3FFB_9999_9999_9999, 0x9999_9999_9999_999A);
	check_parse("2.5", 0x4000_4000_0000_0000, 0);
	check_parse(".5", 0x3FFE_0000_0000_0000, 0);
	check_parse("5.", 0x4001_4000_0000_0000, 0);
	check_parse("100", 0x4005_9000_0000_0000, 0);
	check_parse("1000.000", 0x4008_F400_0000_0000, 0);
	check_parse("1E3", 0x4008_F400_0000_0000, 0);
	check_parse("1.5e+3", 0x4009_7700_0000_0000, 0);
	check_parse("1_000.5", 0x4008_F440_0000_0000, 0);
	check_parse("0.000001", 0x3FEB_0C6F_7A0B_5ED8, 0xD36B_4C7F_3493_8583);
	check_parse("0e0", 0, 0);
	check_parse("1e48", 0x409E_5E53_1A0A_1C87, 0x2BAD_2CE1_6256_FE82);
	check_parse("1e49", 0x40A1_B5E7_E08C_A3A8, 0xF698_7819_BAEC_BE22);
	check_parse("1e82", 0x410F_5159_AF80_4446, 0x2379_8810_65D4_1AD2);
	check_parse("1e83", 0x4112_A5B0_1B60_5557, 0xAC57_EA14_7F49_2186);
	check_parse("1e-48", 0x3F5F_7624_F8A7_62FD, 0x82B2_AAC1_8030_B01B);
	check_parse("123e-50", 0x3F5F_CC32_983E_868E, 0xDBA3_70BF_ED08_AFA6);
	check_parse("4.9e-324", 0x3BCC_FBC9_69F6_329F, 0x9DB1_48F5_D573_72FD);
	check_parse("1.79769313486231570815e308", 0x43FE_FFFF_FFFF_FFFF, 0xF000_18D4_07E6_B7CF);
}

fn void parse_f128_rounding_observed() @test
{
	// observed (Zig 0.17.0): ties and long inputs (slow path).
	check_parse("10384593717069655257060992658440193", 0x4070_0000_0000_0000, 0);       // 2^113 + 1: tie, to even
	check_parse("10384593717069655257060992658440195", 0x4070_0000_0000_0000, 2);       // 2^113 + 3: tie, to even (up)
	check_parse("10384593717069655257060992658440193.0000000000000000000000001", 0x4070_0000_0000_0000, 1);
	check_parse("123456789012345678901234567890123456789", 0x407D_7383_A695_8057, 0xFB16_AB7E_8CA2_B8E6);
	check_parse("340282366920938463463374607431768211455", 0x407F_0000_0000_0000, 0);
	check_parse("3.14159265358979323846264338327950288419716939937510", 0x4000_921F_B544_42D1, 0x8469_898C_C517_01B8);
	check_parse("0.30000000000000000000000000000000000000000000001", 0x3FFD_3333_3333_3333, 0x3333_3333_3333_3333);
	check_parse("1.0000000000000000000000000000000000000000000000000000000000000000000000000000001", 0x3FFF_0000_0000_0000, 0);
}

fn void parse_f128_range_observed() @test
{
	// observed (Zig 0.17.0): overflow, underflow and subnormals.
	check_parse("1e5000", 0x7FFF_0000_0000_0000, 0);
	check_parse("1e-5000", 0, 0);
	check_parse("1.18973149535723176508575932662800702e4932", 0x7FFE_FFFF_FFFF_FFFF, ulong::max);
	check_parse("1.18973149535723176508575932662800703e4932", 0x7FFE_FFFF_FFFF_FFFF, ulong::max);
	check_parse("6.4751751194380251109244389582276465524996e-4966", 0, 1);
	check_parse("6.4751751194380251109244389582276465524995e-4966", 0, 1);
	check_parse("3.2e-4966", 0, 0);
	check_parse("1e-4966", 0, 0);
	check_parse("7e-4967", 0, 0);
	check_parse("1.5e-4965", 0, 2);
}

fn void parse_f128_hex_observed() @test
{
	// observed (Zig 0.17.0): hexadecimal floats (convertHex).
	check_parse("0x1.8p3", 0x4002_8000_0000_0000, 0);
	check_parse("0x1P+3", 0x4002_0000_0000_0000, 0);
	check_parse("0X1p0", 0x3FFF_0000_0000_0000, 0);
	check_parse("0x.8p1", 0x3FFF_0000_0000_0000, 0);
	check_parse("0x1.8", 0x3FFF_8000_0000_0000, 0);
	check_parse("-0x0p0", 0x8000_0000_0000_0000, 0);
	check_parse("0x1p-16494", 0, 1);
	check_parse("0x1p-16495", 0, 0);
	check_parse("0x1.ffffffffffffffffffffffffffffp16383", 0x7FFE_FFFF_FFFF_FFFF, ulong::max);
	check_parse("0x1.ffffffffffffffffffffffffffff8p16383", 0x7FFF_0000_0000_0000, 0);
	// More than 32 hex digits: Zig re-reads digits only up to 10^31 (a decimal
	// limit applied to base 16), dropping the low ones - quirk kept.
	check_parse("0x123456789abcdef0123456789abcdef01p0", 0x407F_2345_6789_ABCD, 0xEF01_2345_6789_AB00);
	check_parse("0x1.0000000000000000000000000000000000001p0", 0x3FFF_0000_0000_0000, 0);
}

fn void parse_f128_special_observed() @test
{
	// observed (Zig 0.17.0): "-nan" is std.math.nan (positive).
	check_parse("nan", 0x7FFF_8000_0000_0000, 0);
	check_parse("-nan", 0x7FFF_8000_0000_0000, 0);
	check_parse("inf", 0x7FFF_0000_0000_0000, 0);
	check_parse("-Infinity", 0xFFFF_0000_0000_0000, 0);
	check_parse_error("");
	check_parse_error("-");
	check_parse_error("1__0");
	check_parse_error("1e");
	check_parse_error("1e+");
	check_parse_error(".");
	check_parse_error("0x");
	check_parse_error("0x1p");
	check_parse_error("infx");
	// Zig's own parseFloat test
	check_parse_error("   1");
	check_parse_error("1abc");
	check_parse_error("+");
}

// ---------------------------------------------------------------------------
// Value-level operations
// ---------------------------------------------------------------------------

fn void float_to_int_fixture() @test
{
	// fixture "float to int": one Value.floatToInt per initializer.
	@with_comp(; Compilation* comp)
	{
		Value v = f32v(comp, 0x5015_02F9); // 10000000000.0f -> int
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		v = f32v(comp, 0x3F99_999A); // 1.2f
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.VALUE_CHANGED);
		check_value(v, value::ONE);
		v = f32v(comp, 0xFFC0_0000); // 0.0f / 0 (x86 default NaN)
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.OVERFLOW);
		assert(v.is_none());
		v = f64v(comp, 0x4004_0000_0000_0000); // 5.0 / 2
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.VALUE_CHANGED);
		check_value(v, value::int_u64(2, comp));
		v = f32v(comp, 0x3F00_0000); // 1.0f / 2
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONZERO_TO_ZERO);
		check_value(v, value::ZERO);
		v = f64v(comp, D_TWO); // 2.0
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::int_u64(2, comp));
		v = f32v(comp, 0x4F00_0000); // 2147483647.0f == 2^31
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		check_value(v, value::int_u64(0x8000_0000, comp)); // stored untruncated
		v = f32v(comp, 0x4380_0000); // 256.0f -> char
		assert(float_value::float_to_int(&v, type_store::CHAR, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		v = f64v(comp, 0xBFF0_0000_0000_0000); // -1.0 -> unsigned
		assert(float_value::float_to_int(&v, type_store::UINT, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		check_value(v, value::ZERO);
		v = f64v(comp, 0); // 0.0 -> _Bool
		assert(float_value::float_to_int(&v, type_store::BOOL, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::ZERO);
		v = f32v(comp, 0x3F80_0000); // 1.0f -> _Bool
		assert(float_value::float_to_int(&v, type_store::BOOL, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::ONE);
		v = f32v(comp, 0x3FC0_0000); // 1.5f -> _Bool
		assert(float_value::float_to_int(&v, type_store::BOOL, comp) == FloatToIntChangeKind.VALUE_CHANGED);
		check_value(v, value::ONE);
	};
}

fn void float_to_int_source_derived() @test
{
	// source-derived from Value.floatToInt
	@with_comp(; Compilation* comp)
	{
		Value v = value::NONE;
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONE);
		assert(v.is_none());
		// NaN -> unsigned: `f < 0` is false for NaN, so OVERFLOW (not OUT_OF_RANGE).
		v = f32v(comp, 0xFFC0_0000);
		assert(float_value::float_to_int(&v, type_store::UINT, comp) == FloatToIntChangeKind.OVERFLOW);
		// NaN -> _Bool: NaN != 0, so true and VALUE_CHANGED.
		v = f32v(comp, 0x7FC0_0000);
		assert(float_value::float_to_int(&v, type_store::BOOL, comp) == FloatToIntChangeKind.VALUE_CHANGED);
		check_value(v, value::ONE);
		// -inf -> unsigned is `< 0`: ZERO, OUT_OF_RANGE; -inf -> int: OVERFLOW.
		v = fv(comp, float_value::inf(F64, true));
		assert(float_value::float_to_int(&v, type_store::UINT, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		v = fv(comp, float_value::inf(F64, true));
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.OVERFLOW);
		// -0.0 -> unsigned: not `< 0`, converts to 0 unchanged.
		v = f64v(comp, D_NEG_ZERO);
		assert(float_value::float_to_int(&v, type_store::UINT, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::ZERO);
		// -0.5 -> unsigned: OUT_OF_RANGE wins over NONZERO_TO_ZERO; -> int: NONZERO_TO_ZERO.
		v = f64v(comp, 0xBFE0_0000_0000_0000);
		assert(float_value::float_to_int(&v, type_store::UINT, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		v = f64v(comp, 0xBFE0_0000_0000_0000);
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONZERO_TO_ZERO);
		// -2.5 -> int: -2, VALUE_CHANGED.
		v = f64v(comp, 0xC004_0000_0000_0000);
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.VALUE_CHANGED);
		check_value(v, value::int_i64(-2, comp));
		// 1e30 -> __int128 fits; -> long does not and the untruncated value is kept.
		Limb[2] e30 = { 0x4675_0000_0000_0000, 0xC_9F2C_9CD0 };
		Value want = value::intern(comp, value_interner::key_big_int({ .limbs = e30[..], .positive = true }));
		v = f64v(comp, 0x4629_3E59_39A0_8CEA);
		assert(float_value::float_to_int(&v, type_store::INT128, comp) == FloatToIntChangeKind.NONE);
		check_value(v, want);
		v = f64v(comp, 0x4629_3E59_39A0_8CEA);
		assert(float_value::float_to_int(&v, type_store::LONG, comp) == FloatToIntChangeKind.OUT_OF_RANGE);
		check_value(v, want);
		// complex: the real part converts.
		v = c64v(comp, 0x4008_0000_0000_0000, D_FOUR); // 3.0 + 4.0i
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::int_u64(3, comp));
		// an int stays an int.
		v = value::int_i64(-7, comp);
		assert(float_value::float_to_int(&v, type_store::INT, comp) == FloatToIntChangeKind.NONE);
		check_value(v, value::int_i64(-7, comp));
	};
}

fn void int_to_float_values() @test
{
	@with_comp(; Compilation* comp)
	{
		// observed (Zig 0.17.0, @floatFromInt)
		Value v = value::int_u64(ulong::max, comp);
		float_value::int_to_float(&v, type_store::DOUBLE, comp);
		check_value(v, f64v(comp, 0x43F0_0000_0000_0000));
		v = value::int_u64(65520, comp);
		float_value::int_to_float(&v, type_store::FLOAT16, comp);
		check_value(v, fv(comp, raw(F16, 0x7C00)));
		v = value::int_i64(-9007199254740993, comp);
		float_value::int_to_float(&v, type_store::DOUBLE, comp);
		check_value(v, f64v(comp, 0xC340_0000_0000_0000));
		v = value::int_i64(-9007199254740995, comp);
		float_value::int_to_float(&v, type_store::LONG_DOUBLE, comp);
		check_value(v, fv(comp, raw(F80, u128(0xC034, 0x8000_0000_0000_0C00))));
		// observed: big int through f128 then f64 (double rounding kept).
		Limb[2] limbs = { 1, 0x8000_0000_0000_0400 };
		v = value::intern(comp, value_interner::key_big_int({ .limbs = limbs[..], .positive = true }));
		float_value::int_to_float(&v, type_store::DOUBLE, comp);
		check_value(v, f64v(comp, 0x47E0_0000_0000_0000));
		// source-derived: complex destination -> { value, +0.0 }.
		v = value::int_u64(3, comp);
		float_value::int_to_float(&v, complex_of(comp, type_store::DOUBLE), comp);
		check_value(v, c64v(comp, 0x4008_0000_0000_0000, 0));
		// none stays none.
		v = value::NONE;
		float_value::int_to_float(&v, type_store::DOUBLE, comp);
		assert(v.is_none());
	};
}

fn void float_cast_values() @test
{
	// source-derived from Value.floatCast; bit patterns as in cast_from_f64_observed.
	@with_comp(; Compilation* comp)
	{
		Value v = f64v(comp, 0x3FB9_9999_9999_999A); // 0.1 -> float
		float_value::float_cast(&v, type_store::FLOAT, comp);
		check_value(v, f32v(comp, 0x3DCC_CCCD));
		v = c64v(comp, 0x3FF8_0000_0000_0000, D_TWO); // (1.5 + 2.0i) -> float: the real part
		float_value::float_cast(&v, type_store::FLOAT, comp);
		check_value(v, f32v(comp, 0x3FC0_0000));
		v = f64v(comp, D_TWO); // 2.0 -> _Complex float
		QualType cf = complex_of(comp, type_store::FLOAT);
		float_value::float_cast(&v, cf, comp);
		check_value(v, cv(comp, raw(F32, 0x4000_0000), raw(F32, 0)));
		v = c64v(comp, 0x3FB9_9999_9999_999A, D_NEG_FOUR); // _Complex double -> _Complex float
		float_value::float_cast(&v, cf, comp);
		check_value(v, cv(comp, raw(F32, 0x3DCC_CCCD), raw(F32, 0xC080_0000)));
		v = value::int_u64(5, comp); // int value with a float cast (to_float of an int key)
		float_value::float_cast(&v, type_store::FLOAT128, comp);
		check_value(v, fv(comp, raw(F128, u128(0x4001_4000_0000_0000, 0))));
		v = value::NONE;
		float_value::float_cast(&v, type_store::FLOAT, comp);
		assert(v.is_none());
	};
}

fn void real_imaginary_conj_values() @test
{
	@with_comp(; Compilation* comp)
	{
		// source-derived from Value.realPart / imaginaryPart / complexConj
		Value c = c64v(comp, 0x3FF8_0000_0000_0000, 0x4004_0000_0000_0000); // 1.5 + 2.5i
		check_value(float_value::real_part(c, comp), f64v(comp, 0x3FF8_0000_0000_0000));
		check_value(float_value::imaginary_part(c, comp), f64v(comp, 0x4004_0000_0000_0000));
		Value f = f64v(comp, 0x3FF8_0000_0000_0000);
		check_value(float_value::real_part(f, comp), f);
		check_value(float_value::imaginary_part(f, comp), value::ZERO);
		check_value(float_value::imaginary_part(value::int_u64(9, comp), comp), value::ZERO);
		assert(float_value::real_part(value::NONE, comp).is_none());
		assert(float_value::imaginary_part(value::NONE, comp).is_none());
		QualType cd = complex_of(comp, type_store::DOUBLE);
		// fixture "complex values": ~(2.0 + 4.0i) == 2.0 - 4.0i
		check_value(float_value::complex_conj(c64v(comp, D_TWO, D_FOUR), cd, comp), c64v(comp, D_TWO, D_NEG_FOUR));
		// conj of a real value: the +0.0 imaginary part becomes -0.0.
		check_value(float_value::complex_conj(value::int_u64(5, comp), cd, comp), c64v(comp, 0x4014_0000_0000_0000, D_NEG_ZERO));
		// to_float / imag at another width
		check_bits(float_value::to_float(c, F32, comp), F32, 0x3FC0_0000);
		check_bits(float_value::imag(c, F32, comp), F32, 0x4020_0000);
		check_bits(float_value::imag(f, F80, comp), F80, 0);
		check_bits(float_value::to_float(value::ONE, F16, comp), F16, 0x3C00);
	};
}

fn void real_arithmetic_values() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r;
		// source-derived (IEEE 754): 0.1 + 0.2 = 0x3FD3333333333334 in double.
		assert(!float_value::add(&r, f64v(comp, 0x3FB9_9999_9999_999A), f64v(comp, 0x3FC9_9999_9999_999A), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, 0x3FD3_3333_3333_3334));
		// int operands are converted first: 1 - 3 = -2.0.
		assert(!float_value::sub(&r, value::ONE, value::int_u64(3, comp), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, D_NEG_TWO));
		// 1.5f * 2 = 3.0f
		assert(!float_value::mul(&r, f32v(comp, 0x3FC0_0000), value::int_u64(2, comp), type_store::FLOAT, comp));
		check_value(r, f32v(comp, 0x4040_0000));
		// 1.0 / 0.0 = +inf (no error); 0.0 / 0.0 = the x86 default NaN.
		assert(!float_value::div(&r, value::ONE, f64v(comp, 0), type_store::DOUBLE, comp));
		check_value(r, fv(comp, float_value::inf(F64)));
		assert(!float_value::div(&r, f64v(comp, 0), f64v(comp, 0), type_store::DOUBLE, comp));
		check_float_key(comp, r, float_value::f64_value(0xFFF8_0000_0000_0000)); // NaN: never shares a ref
		// long double / __float128: 1 + 1 = 2
		assert(!float_value::add(&r, value::ONE, value::ONE, type_store::LONG_DOUBLE, comp));
		check_value(r, fv(comp, raw(F80, u128(0x4000, 0x8000_0000_0000_0000))));
		assert(!float_value::add(&r, value::ONE, value::ONE, type_store::FLOAT128, comp));
		check_value(r, fv(comp, raw(F128, u128(0x4000_0000_0000_0000, 0))));
	};
}

fn void complex_arithmetic_fixture() @test
{
	// fixture "complex values": the _Static_asserts' left-hand sides.
	@with_comp(; Compilation* comp)
	{
		QualType cd = complex_of(comp, type_store::DOUBLE);
		Value r;
		// 1.0 + 2.0i
		assert(!float_value::add(&r, value::ONE, c64v(comp, 0, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_ONE, D_TWO));
		// -2.0i - 2.0i == -4.0i  (-0.0 - +0.0 = -0.0)
		assert(!float_value::sub(&r, c64v(comp, D_NEG_ZERO, D_NEG_TWO), c64v(comp, 0, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_NEG_ZERO, D_NEG_FOUR));
		// 2.0i * 2.0i == -4.0
		assert(!float_value::mul(&r, c64v(comp, 0, D_TWO), c64v(comp, 0, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_NEG_FOUR, 0));
		// (2.0 + 2.0i) / 2.0 == 1.0 + 1.0i
		assert(!float_value::div(&r, c64v(comp, D_TWO, D_TWO), f64v(comp, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_ONE, D_ONE));
		// (2.0 + 4.0i) / 1.0i == 4.0 - 2.0i
		assert(!float_value::div(&r, c64v(comp, D_TWO, D_FOUR), c64v(comp, 0, D_ONE), cd, comp));
		check_value(r, c64v(comp, D_FOUR, D_NEG_TWO));
		// (_Complex double){2.0} + (_Complex double){2.0, 4.0} == {4.0, 4.0}
		assert(!float_value::add(&r, c64v(comp, D_TWO, 0), c64v(comp, D_TWO, D_FOUR), cd, comp));
		check_value(r, c64v(comp, D_FOUR, D_FOUR));
	};
}
