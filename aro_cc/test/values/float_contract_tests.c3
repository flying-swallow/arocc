// Tests for the plan 10 stage-0 contract code in src/primitive_float.c3 that is
// implemented (not stubbed): format table, bit access, classification, sign
// operations and constants. Expected bit patterns are IEEE 754 / x87 encodings,
// source-derived by hand (std.math.inf/nan in Zig 0.17.0 give the same bits).
module float_contract_tests;
import aro::primitive_value;
import aro::value_interner;

macro check(left, right)
{
	test::eq((ulong)left, (ulong)right);
}

fn void check_raw(PrimitiveValue f, ulong hi, ulong lo)
{
	uint128 r = f.float_bits();
	check((ulong)(r >> 64), hi);
	check((ulong)r, lo);
}

fn void format_table() @test
{
	check(PrimitiveType.F16.format.frac_bits, 10);
	check(PrimitiveType.F80.format.frac_bits, 63);
	assert(PrimitiveType.F80.format.explicit_int);
	check(PrimitiveType.F128.format.bias, 16383);
	assert(primitive_value::float_tag_of_width(80) == PrimitiveType.F80);
	assert(PrimitiveType.F64.complex() == PrimitiveType.CF64);
	assert(PrimitiveType.CF128.scalar() == PrimitiveType.F128);
}

fn void constants_have_reference_bits() @test
{
	check_raw(primitive_value::one(F16), 0, 0x3C00);
	check_raw(primitive_value::one(F32), 0, 0x3F80_0000);
	check_raw(primitive_value::one(F64), 0, 0x3FF0_0000_0000_0000);
	check_raw(primitive_value::one(F80), 0x3FFF, 0x8000_0000_0000_0000);
	check_raw(primitive_value::one(F128), 0x3FFF_0000_0000_0000, 0);
	check_raw(primitive_value::inf(F16), 0, 0x7C00);
	check_raw(primitive_value::inf(F64, true), 0, 0xFFF0_0000_0000_0000);
	check_raw(primitive_value::inf(F80), 0x7FFF, 0x8000_0000_0000_0000);
	check_raw(primitive_value::inf(F128, true), 0xFFFF_0000_0000_0000, 0);
	check_raw(primitive_value::zero(F80, true), 0x8000, 0);
	check_raw(primitive_value::std_nan(F80), 0x7FFF, 0xC000_0000_0000_0000);
	check_raw(primitive_value::default_nan(F128), 0x7FFF_8000_0000_0000, 0);
}

fn void raw_round_trip() @test
{
	PrimitiveValue f = primitive_value::float_key(F80, (uint128)0x4000 << 64 | (uint128)0xC000_0000_0000_0000); // 3.0
	check(f.f80().hi, 0x4000);
	check(f.f80().lo, 0xC000_0000_0000_0000);
	check(f.biased_exponent(), 0x4000);
	check((ulong)f.fraction(), 0x4000_0000_0000_0000);
	PrimitiveValue g = primitive_value::float_key(F16, 0xFFFF_3C00);
	check(g.f16(), 0x3C00);
}

fn void classification() @test
{
	assert(primitive_value::f16_value(0x0001).classify() == FloatClass.SUBNORMAL);
	assert(primitive_value::f32_value(0x7F80_0001).is_nan());
	assert(primitive_value::f64_value(0xFFF0_0000_0000_0000).is_negative_inf());
	assert(primitive_value::f64_value(0x8000_0000_0000_0000).is_negative_zero());
	assert(!primitive_value::f64_value(0x8000_0000_0000_0000).is_positive_zero());
	assert(primitive_value::f128_value({ .lo = 1, .hi = 0x7FFF_0000_0000_0000 }).is_nan());
	assert(primitive_value::f128_value({ .lo = 0, .hi = 0x7FFF_0000_0000_0000 }).is_inf());
	// f80: pseudo-denormal (exponent 0, integer bit 1) is SUBNORMAL; unnormal and
	// pseudo-infinity (integer bit 0) are NaN.
	assert(primitive_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0 }).classify() == FloatClass.SUBNORMAL);
	assert(primitive_value::f80_value({ .lo = 0x4000_0000_0000_0000, .hi = 0x3FFF }).is_nan());
	assert(primitive_value::f80_value({ .lo = 0, .hi = 0x7FFF }).is_nan());
	assert(primitive_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0x7FFF }).is_inf());
	assert(primitive_value::f80_value({ .lo = 0xC000_0000_0000_0000, .hi = 0xFFFF }).is_nan());
	assert(!primitive_value::f80_value({ .lo = 0x8000_0000_0000_0000, .hi = 0x7FFF }).is_finite());
}

fn void sign_operations() @test
{
	PrimitiveValue one = primitive_value::one(F64);
	check_raw(one.neg(), 0, 0xBFF0_0000_0000_0000);
	check_raw(one.neg().abs(), 0, 0x3FF0_0000_0000_0000);
	check_raw(one.copysign(primitive_value::zero(F64, true)), 0, 0xBFF0_0000_0000_0000);
	check_raw(primitive_value::std_nan(F80).neg(), 0xFFFF, 0xC000_0000_0000_0000);
	check_raw(primitive_value::f32_value(0x7F80_0001).quiet(), 0, 0x7FC0_0001);
	check_raw(primitive_value::f80_value({ .lo = 0x8000_0000_0000_0001, .hi = 0x7FFF }).quiet(), 0x7FFF, 0xC000_0000_0000_0001);
}

fn void complex_parts() @test
{
	PrimitiveValue c = primitive_value::complex_key(primitive_value::one(F80), primitive_value::zero(F80, true));
	assert(c.tag == PrimitiveType.CF80);
	PrimitiveValue[2] p = c.parts();
	check_raw(p[0], 0x3FFF, 0x8000_0000_0000_0000);
	check_raw(p[1], 0x8000, 0);
}
