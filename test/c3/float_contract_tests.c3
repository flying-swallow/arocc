// Tests for the plan 10 stage-0 contract code in src/c3/float_value.c3 that is
// implemented (not stubbed): format table, bit access, classification, sign
// operations and constants. Expected bit patterns are IEEE 754 / x87 encodings,
// source-derived by hand (std.math.inf/nan in Zig 0.17.0 give the same bits).
module float_contract_tests;
import aro::float_value, aro::value_interner;

macro check(left, right)
{
	test::eq((ulong)left, (ulong)right);
}

fn void check_raw(KeyFloat f, ulong hi, ulong lo)
{
	uint128 r = f.raw();
	check((ulong)(r >> 64), hi);
	check((ulong)r, lo);
}

fn void format_table() @test
{
	check(float_value::format_of(F16).frac_bits, 10);
	check(float_value::format_of(F80).frac_bits, 63);
	assert(float_value::format_of(F80).explicit_int);
	check(float_value::format_of(F128).bias, 16383);
	assert(float_value::tag_for_bits(80) == KeyFloatTag.F80);
	assert(float_value::complex_tag_of(F64) == KeyComplexTag.CF64);
	assert(KeyComplexTag.CF128.scalar() == KeyFloatTag.F128);
}

fn void constants_have_reference_bits() @test
{
	check_raw(float_value::one(F16), 0, 0x3C00);
	check_raw(float_value::one(F32), 0, 0x3F80_0000);
	check_raw(float_value::one(F64), 0, 0x3FF0_0000_0000_0000);
	check_raw(float_value::one(F80), 0x3FFF, 0x8000_0000_0000_0000);
	check_raw(float_value::one(F128), 0x3FFF_0000_0000_0000, 0);
	check_raw(float_value::inf(F16), 0, 0x7C00);
	check_raw(float_value::inf(F64, true), 0, 0xFFF0_0000_0000_0000);
	check_raw(float_value::inf(F80), 0x7FFF, 0x8000_0000_0000_0000);
	check_raw(float_value::inf(F128, true), 0xFFFF_0000_0000_0000, 0);
	check_raw(float_value::zero(F80, true), 0x8000, 0);
	check_raw(float_value::std_nan(F80), 0x7FFF, 0xC000_0000_0000_0000);
	check_raw(float_value::default_nan(F128), 0x7FFF_8000_0000_0000, 0);
}

fn void raw_round_trip() @test
{
	KeyFloat f = float_value::from_raw(F80, (uint128)0x4000 << 64 | (uint128)0xC000_0000_0000_0000); // 3.0
	check(f.f80.hi, 0x4000);
	check(f.f80.lo, 0xC000_0000_0000_0000);
	check(f.biased_exponent(), 0x4000);
	check((ulong)f.fraction(), 0x4000_0000_0000_0000);
	KeyFloat g = float_value::from_raw(F16, 0xFFFF_3C00);
	check(g.f16, 0x3C00);
}

fn void classification() @test
{
	assert(float_value::f16_value(0x0001).classify() == FloatClass.SUBNORMAL);
	assert(float_value::f32_value(0x7F80_0001).is_nan());
	assert(float_value::f64_value(0xFFF0_0000_0000_0000).is_negative_inf());
	assert(float_value::f64_value(0x8000_0000_0000_0000).is_negative_zero());
	assert(!float_value::f64_value(0x8000_0000_0000_0000).is_positive_zero());
	assert(float_value::f128_value({ .lo = 1, .hi = 0x7FFF_0000_0000_0000 }).is_nan());
	assert(float_value::f128_value({ .lo = 0, .hi = 0x7FFF_0000_0000_0000 }).is_inf());
	// f80: pseudo-denormal (exponent 0, integer bit 1) is SUBNORMAL; unnormal and
	// pseudo-infinity (integer bit 0) are NaN.
	assert(float_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0 }).classify() == FloatClass.SUBNORMAL);
	assert(float_value::f80_value({ .lo = 0x4000_0000_0000_0000, .hi = 0x3FFF }).is_nan());
	assert(float_value::f80_value({ .lo = 0, .hi = 0x7FFF }).is_nan());
	assert(float_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0x7FFF }).is_inf());
	assert(float_value::f80_value({ .lo = 0xC000_0000_0000_0000, .hi = 0xFFFF }).is_nan());
	assert(!float_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0x7FFF }).is_finite());
}

fn void sign_operations() @test
{
	KeyFloat one = float_value::one(F64);
	check_raw(one.neg(), 0, 0xBFF0_0000_0000_0000);
	check_raw(one.neg().abs(), 0, 0x3FF0_0000_0000_0000);
	check_raw(one.copysign(float_value::zero(F64, true)), 0, 0xBFF0_0000_0000_0000);
	check_raw(float_value::std_nan(F80).neg(), 0xFFFF, 0xC000_0000_0000_0000);
	check_raw(float_value::f32_value(0x7F80_0001).quiet(), 0, 0x7FC0_0001);
	check_raw(float_value::f80_value({ .lo = 0x8000_0000_0000_0001, .hi = 0x7FFF }).quiet(), 0x7FFF, 0xC000_0000_0000_0001);
}

fn void complex_parts() @test
{
	KeyComplex c = float_value::make_complex(float_value::one(F80), float_value::zero(F80, true));
	assert(c.tag == KeyComplexTag.CF80);
	KeyFloat[2] p = c.parts();
	check_raw(p[0], 0x3FFF, 0x8000_0000_0000_0000);
	check_raw(p[1], 0x8000, 0);
}
