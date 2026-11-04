// Compiler capability checks for plan 10 (floating and complex constants).
//
// These tests decide which float widths the port may compute with native c3c
// operations. The decision they support is recorded in the "Native capability
// decision" block at the top of src/c3/float_value.c3; if one of these tests
// starts failing (new c3c, new host, new Bazel toolchain), revisit that block.
//
// Every operand is read through @volatile_load from a global, so the operation
// runs on the target CPU (or in libgcc / c3's compiler_rt) instead of being
// folded by c3c or LLVM. Every expected value is an exact IEEE 754 bit pattern,
// source-derived by hand from the IEEE 754 rules (round to nearest, ties to
// even) unless marked "observed" (an x86-64 hardware fact we only record).
//
// Probed on c3c 0.8.5, x86_64-linux-gnu, at -O0 (dbg) and -O2 (opt).
module float_capability_tests;

// ---------------------------------------------------------------------------
// Helpers (outside @test functions: c3c rejects parameterised helpers there)
// ---------------------------------------------------------------------------

ushort g_h0;
ushort g_h1;
uint g_s0;
uint g_s1;
ulong g_d0;
ulong g_d1;
ulong g_u0;
long g_i0;
uint128 g_q0;
uint128 g_q1;

macro check(left, right)
{
	test::eq((ulong)left, (ulong)right);
}

macro check128(uint128 left, uint128 right)
{
	test::eq((ulong)(left >> 64), (ulong)(right >> 64));
	test::eq((ulong)left, (ulong)right);
}

fn double dv(ulong bits) { g_d0 = bits; return bitcast(@volatile_load(g_d0), double); }
fn double dv2(ulong bits) { g_d1 = bits; return bitcast(@volatile_load(g_d1), double); }
fn ulong db(double d) => bitcast(d, ulong);
fn float sv(uint bits) { g_s0 = bits; return bitcast(@volatile_load(g_s0), float); }
fn float sv2(uint bits) { g_s1 = bits; return bitcast(@volatile_load(g_s1), float); }
fn uint sb(float f) => bitcast(f, uint);
fn float16 hv(ushort bits) { g_h0 = bits; return bitcast(@volatile_load(g_h0), float16); }
fn float16 hv2(ushort bits) { g_h1 = bits; return bitcast(@volatile_load(g_h1), float16); }
fn ushort hb(float16 h) => bitcast(h, ushort);
fn ulong uv(ulong x) { g_u0 = x; return @volatile_load(g_u0); }
fn long iv(long x) { g_i0 = x; return @volatile_load(g_i0); }
fn uint128 qv(uint128 x) { g_q0 = x; return @volatile_load(g_q0); }
fn uint128 qv2(uint128 x) { g_q1 = x; return @volatile_load(g_q1); }
fn uint128 q(ulong hi, ulong lo) => (uint128)hi << 64 | (uint128)lo;
fn float128 qf(ulong hi, ulong lo) => bitcast(qv(q(hi, lo)), float128);
fn float128 qf2(ulong hi, ulong lo) => bitcast(qv2(q(hi, lo)), float128);
fn uint128 qb(float128 f) => bitcast(f, uint128);

// ---------------------------------------------------------------------------
// f64 (double): correctly rounded IEEE binary64, no FTZ/DAZ, signed zero, NaN
// ---------------------------------------------------------------------------

fn void f64_add_sub_round_to_nearest_even() @test
{
	// 0.1 + 0.2 = 0.30000000000000004
	check(db(dv(0x3FB9_9999_9999_999A) + dv2(0x3FC9_9999_9999_999A)), 0x3FD3_3333_3333_3334);
	// 1 + 2^-53: exact tie, rounds to even (1.0)
	check(db(dv(0x3FF0_0000_0000_0000) + dv2(0x3CA0_0000_0000_0000)), 0x3FF0_0000_0000_0000);
	// (1 + 2^-52) + 2^-53: tie, rounds to even (1 + 2^-51)
	check(db(dv(0x3FF0_0000_0000_0001) + dv2(0x3CA0_0000_0000_0000)), 0x3FF0_0000_0000_0002);
	// 1 - 1 = +0 (round to nearest)
	check(db(dv(0x3FF0_0000_0000_0000) - dv2(0x3FF0_0000_0000_0000)), 0);
}

fn void f64_mul_div_correctly_rounded() @test
{
	// 1 / 3
	check(db(dv(0x3FF0_0000_0000_0000) / dv2(0x4008_0000_0000_0000)), 0x3FD5_5555_5555_5555);
	// 2 / 3
	check(db(dv(0x4000_0000_0000_0000) / dv2(0x4008_0000_0000_0000)), 0x3FE5_5555_5555_5555);
	// 0.1 * 3 = 0.30000000000000004
	check(db(dv(0x3FB9_9999_9999_999A) * dv2(0x4008_0000_0000_0000)), 0x3FD3_3333_3333_3334);
	// DBL_MAX * 2 = +inf (overflow)
	check(db(dv(0x7FEF_FFFF_FFFF_FFFF) * dv2(0x4000_0000_0000_0000)), 0x7FF0_0000_0000_0000);
}

fn void f64_subnormals_are_not_flushed() @test
{
	// DBL_MIN / 2 = 2^-1023 (subnormal, exact)
	check(db(dv(0x0010_0000_0000_0000) / dv2(0x4000_0000_0000_0000)), 0x0008_0000_0000_0000);
	// min subnormal * 0.5: tie, rounds to even (+0)
	check(db(dv(0x0000_0000_0000_0001) * dv2(0x3FE0_0000_0000_0000)), 0);
	// 3 * min subnormal * 0.5 = 1.5 ulp: tie, rounds to even (2 ulp)
	check(db(dv(0x0000_0000_0000_0003) * dv2(0x3FE0_0000_0000_0000)), 2);
	// a subnormal operand is used as is (no DAZ): sub + sub
	check(db(dv(0x0000_0000_0000_0001) + dv2(0x0000_0000_0000_0001)), 2);
}

fn void f64_signed_zero() @test
{
	check(db(dv(0x8000_0000_0000_0000) + dv2(0x8000_0000_0000_0000)), 0x8000_0000_0000_0000); // -0 + -0
	check(db(dv(0x0000_0000_0000_0000) + dv2(0x8000_0000_0000_0000)), 0);                     // +0 + -0
	check(db(dv(0xBFF0_0000_0000_0000) * dv2(0x0000_0000_0000_0000)), 0x8000_0000_0000_0000); // -1 * +0
	check(db(dv(0x8000_0000_0000_0000) + dv2(0)), 0);                                          // x + 0.0 is not folded to x
	check(db(-dv(0)), 0x8000_0000_0000_0000);                                                  // negation flips the sign of +0
}

fn void f64_inf_nan() @test
{
	check(db(dv(0x3FF0_0000_0000_0000) / dv2(0)), 0x7FF0_0000_0000_0000);                     // 1/+0 = +inf
	check(db(dv(0xBFF0_0000_0000_0000) / dv2(0)), 0xFFF0_0000_0000_0000);                     // -1/+0 = -inf
	check(db(dv(0x3FF0_0000_0000_0000) / dv2(0x8000_0000_0000_0000)), 0xFFF0_0000_0000_0000); // 1/-0 = -inf
	// Invalid operations produce the x86 "default NaN", which is NEGATIVE (observed, x86 SSE).
	check(db(dv(0) / dv2(0)), 0xFFF8_0000_0000_0000);
	check(db(dv(0x7FF0_0000_0000_0000) - dv2(0x7FF0_0000_0000_0000)), 0xFFF8_0000_0000_0000);
	check(db(dv(0x7FF0_0000_0000_0000) * dv2(0)), 0xFFF8_0000_0000_0000);
	// NaN operand: the (first) NaN propagates, quieted, payload kept (observed, x86 SSE).
	check(db(dv(0x7FF0_0000_0000_0001) + dv2(0x3FF0_0000_0000_0000)), 0x7FF8_0000_0000_0001);
	check(db(dv(0x3FF0_0000_0000_0000) + dv2(0x7FF8_0000_0000_0005)), 0x7FF8_0000_0000_0005);
	check(db(dv(0x7FF8_0000_0000_0007) + dv2(0x7FF8_0000_0000_0005)), 0x7FF8_0000_0000_0007);
	// Comparisons are IEEE (unordered): not folded to "x == x".
	double n = dv(0x7FF8_0000_0000_0000);
	double n2 = dv2(0x7FF8_0000_0000_0000);
	assert(!(n == n2));
	assert(n != n2);
	assert(!(n < n2) && !(n > n2) && !(n <= n2) && !(n >= n2));
	assert(dv(0) == dv2(0x8000_0000_0000_0000)); // +0 == -0
}

// ---------------------------------------------------------------------------
// f32 (float)
// ---------------------------------------------------------------------------

fn void f32_arithmetic() @test
{
	// 0.1f + 0.2f = 0.3f (0x3E99999A)
	check(sb(sv(0x3DCC_CCCD) + sv2(0x3E4C_CCCD)), 0x3E99_999A);
	// 1 + 2^-24: tie to even; (1 + 2^-23) + 2^-24: tie to even upward
	check(sb(sv(0x3F80_0000) + sv2(0x3380_0000)), 0x3F80_0000);
	check(sb(sv(0x3F80_0001) + sv2(0x3380_0000)), 0x3F80_0002);
	// 1 / 3
	check(sb(sv(0x3F80_0000) / sv2(0x4040_0000)), 0x3EAA_AAAB);
	// FLT_MIN / 2 (subnormal), min subnormal * 0.5 (tie to +0)
	check(sb(sv(0x0080_0000) / sv2(0x4000_0000)), 0x0040_0000);
	check(sb(sv(0x0000_0001) * sv2(0x3F00_0000)), 0);
	// overflow, signed zero, default NaN (observed, negative on x86)
	check(sb(sv(0x7F7F_FFFF) * sv2(0x4000_0000)), 0x7F80_0000);
	check(sb(sv(0x8000_0000) + sv2(0x8000_0000)), 0x8000_0000);
	check(sb(sv(0) / sv2(0)), 0xFFC0_0000);
	check(sb(sv(0x7F80_0001) + sv2(0x3F80_0000)), 0x7FC0_0001);
}

// ---------------------------------------------------------------------------
// Native conversions: double <-> float, integers -> double/float
// ---------------------------------------------------------------------------

fn void f64_to_f32_rounds_once() @test
{
	// 1 + 2^-24 + 2^-60 (as double) -> float: just above the tie, rounds up
	check(sb((float)dv(0x3FF0_0000_1000_0001)), 0x3F80_0001);
	// 1 + 2^-24 exactly: tie, rounds to even (1.0f)
	check(sb((float)dv(0x3FF0_0000_1000_0000)), 0x3F80_0000);
	// DBL_MAX -> +inf, tiny -> +0 / -0, subnormal result
	check(sb((float)dv(0x7FEF_FFFF_FFFF_FFFF)), 0x7F80_0000);
	check(sb((float)dv(0x0000_0000_0000_0001)), 0);
	check(sb((float)dv(0x8000_0000_0000_0001)), 0x8000_0000);
	check(sb((float)dv(0x3690_0000_0000_0000)), 0);          // 2^-150: half the min subnormal, tie -> +0
	check(sb((float)dv(0x3698_0000_0000_0000)), 0x0000_0001); // 1.5 * 2^-150 -> min subnormal
}

fn void f32_f64_nan_payload_conversions() @test
{
	// NaN narrowing keeps sign and the top payload bits, sets the quiet bit (observed, x86 cvtsd2ss).
	check(sb((float)dv(0x7FF4_0000_0000_0000)), 0x7FE0_0000);
	check(sb((float)dv(0xFFF8_0000_0000_0001)), 0xFFC0_0000);
	// NaN widening shifts the payload up, sets the quiet bit (observed, x86 cvtss2sd).
	check(db((double)sv(0x7F80_0001)), 0x7FF8_0000_2000_0000);
	check(db((double)sv(0xFFC0_0000)), 0xFFF8_0000_0000_0000);
	// -0 and inf survive both ways
	check(db((double)sv(0x8000_0000)), 0x8000_0000_0000_0000);
	check(sb((float)dv(0xFFF0_0000_0000_0000)), 0xFF80_0000);
}

fn void u64_i64_to_double_and_float() @test
{
	check(db((double)uv(0xFFFF_FFFF_FFFF_FFFF)), 0x43F0_0000_0000_0000);            // 2^64
	check(db((double)uv(0x0020_0000_0000_0001)), 0x4340_0000_0000_0000);            // 2^53 + 1 -> 2^53 (tie, even)
	check(db((double)uv(0x0020_0000_0000_0003)), 0x4340_0000_0000_0002);            // 2^53 + 3 -> 2^53 + 4
	check(db((double)uv(0x8000_0000_0000_0401)), 0x43E0_0000_0000_0001);            // 2^63 + 2^10 + 1 -> up
	check(db((double)iv(long::min)), 0xC3E0_0000_0000_0000);                         // -2^63
	check(db((double)iv(-0x0020_0000_0000_0003)), 0xC340_0000_0000_0002);
	// 2^63 + 2^39 + 1 -> float: above the tie, rounds up to 2^63 + 2^40. A
	// conversion through double would round twice and give 2^63 (0x5F000000).
	check(sb((float)uv(0x8000_0080_0000_0001)), 0x5F00_0001);
	check(sb((float)iv(-0x0100_0001)), 0xCB80_0000);                                // -(2^24 + 1) -> tie, even
}

// ---------------------------------------------------------------------------
// f16 (float16): LLVM `half`, promoted to float for arithmetic
// ---------------------------------------------------------------------------

fn void f16_arithmetic() @test
{
	check(hb(hv(0x3C00) + hv2(0x3C00)), 0x4000);   // 1 + 1
	check(hb(hv(0x3C00) + hv2(0x1000)), 0x3C00);   // 1 + 2^-11: tie, even
	check(hb(hv(0x3C01) + hv2(0x1000)), 0x3C02);   // (1 + 2^-10) + 2^-11: tie, even (up)
	check(hb(hv(0x3C00) / hv2(0x4200)), 0x3555);   // 1 / 3
	check(hb(hv(0x7BFF) + hv2(0x7BFF)), 0x7C00);   // 65504 + 65504 = +inf
	check(hb(hv(0x0001) * hv2(0x3800)), 0x0000);   // min subnormal * 0.5: tie, +0
	check(hb(hv(0x0003) * hv2(0x3800)), 0x0002);   // 1.5 ulp: tie, even
	check(hb(hv(0x0400) / hv2(0x4000)), 0x0200);   // HALF_MIN / 2: subnormal, kept
	check(hb(hv(0x8000) + hv2(0x8000)), 0x8000);   // -0 + -0
	check(hb(hv(0x0000) / hv2(0x0000)), 0xFE00);   // default NaN, negative (observed, x86 via float)
}

fn void f16_conversions() @test
{
	// double -> half rounds once: 1 + 2^-11 + 2^-30 is above the f16 tie, so it
	// rounds up to 1 + 2^-10. Going through float would round to 1 + 2^-11 first
	// and then to 1.0 (tie, even).
	check(hb((float16)dv(0x3FF0_0200_0400_0000)), 0x3C01);
	check(hb((float16)dv(0x3FF0_0200_0000_0000)), 0x3C00);                 // exact tie -> even
	check(hb((float16)dv(0x40EF_FDFF_FFFF_FFFF)), 0x7BFF);                 // just below 65520 -> HALF_MAX
	check(hb((float16)dv(0x40EF_FE00_0000_0000)), 0x7C00);                 // 65520: tie between 65504 and 2^16, even -> inf
	check(hb((float16)sv(0x3F80_1000)), 0x3C00);                            // 1 + 2^-11 (float) -> tie -> 1.0
	check(db((double)hv(0x0001)), 0x3E70_0000_0000_0000);                   // 2^-24
	check(sb((float)hv(0x7C01)), 0x7FC0_2000);                              // sNaN payload widened, quieted
	check(hb((float16)uv(2049)), 0x6800);                                   // 2049 -> 2048 (tie, even)
	check(hb((float16)uv(2051)), 0x6802);                                   // 2051 -> 2052
	check(hb((float16)uv(65520)), 0x7C00);                                  // rounds to 65536 -> inf
	check(hb((float16)iv(-65519)), 0xFBFF);
}

// ---------------------------------------------------------------------------
// uint128: used by the soft-float cores for 113-bit significands
// ---------------------------------------------------------------------------

fn void uint128_integer_ops() @test
{
	uint128 m = qv(0xFFFF_FFFF_FFFF_FFFF) * qv2(0xFFFF_FFFF_FFFF_FFFF);
	check128(m, q(0xFFFF_FFFF_FFFF_FFFE, 0x0000_0000_0000_0001));
	check128(qv(q(1, 0)) >> 1, q(0, 0x8000_0000_0000_0000));
	check128(qv(1) << 127, q(0x8000_0000_0000_0000, 0));
	check128(qv(q(0x8000_0000_0000_0000, 0)) >> 127, 1);
	check((ulong)qv(q(0, 1)).clz(), 127);
	check((ulong)qv(q(0x0001_0000_0000_0000, 0)).clz(), 15);
	check((ulong)qv(q(1, 0)).ctz(), 64);
	// 128 / 64 division and remainder (c3 compiler_rt __udivti3/__umodti3)
	uint128 n = qv(q(0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210));
	uint128 d = qv2(0x1_0000_0001);
	uint128 quo = n / d;
	uint128 rem = n % d;
	check128(quo * d + rem, n);
	assert(rem < d);
	check128(qv(q(0x8000_0000_0000_0000, 0)) / qv2(q(0, 3)), q(0x2AAA_AAAA_AAAA_AAAA, 0xAAAA_AAAA_AAAA_AAAA));
}

// ---------------------------------------------------------------------------
// float128 (LLVM fp128 -> libgcc soft-fp calls): probed as a test oracle only
// ---------------------------------------------------------------------------

fn void f128_native_arithmetic() @test
{
	// 1 + 1
	check128(qb(qf(0x3FFF_0000_0000_0000, 0) + qf2(0x3FFF_0000_0000_0000, 0)), q(0x4000_0000_0000_0000, 0));
	// 1 / 3 (113-bit significand 1.0101...01, rounded down)
	check128(qb(qf(0x3FFF_0000_0000_0000, 0) / qf2(0x4000_8000_0000_0000, 0)), q(0x3FFD_5555_5555_5555, 0x5555_5555_5555_5555));
	// 1 + 2^-113: tie, even
	check128(qb(qf(0x3FFF_0000_0000_0000, 0) + qf2(0x3F8E_0000_0000_0000, 0)), q(0x3FFF_0000_0000_0000, 0));
	// (1 + 2^-112) + 2^-113: tie, even (up)
	check128(qb(qf(0x3FFF_0000_0000_0000, 1) + qf2(0x3F8E_0000_0000_0000, 0)), q(0x3FFF_0000_0000_0000, 2));
	// 0/0: libgcc soft-fp returns the x86 default NaN, which is NEGATIVE (observed).
	// Zig's compiler-rt (divtf3.zig, the reference) returns the POSITIVE quiet NaN
	// 0x7FFF8000..., so native float128 does not reproduce the reference.
	check128(qb(qf(0, 0) / qf2(0, 0)), q(0xFFFF_8000_0000_0000, 0));
	// subnormal result kept
	check128(qb(qf(0x0001_0000_0000_0000, 0) / qf2(0x4000_0000_0000_0000, 0)), q(0x0000_8000_0000_0000, 0));
}

fn void f128_native_conversions() @test
{
	// double -> f128 exact; f128 -> double rounds once (1 + 2^-53 + 2^-112 -> up)
	check128(qb((float128)dv(0x3FB9_9999_9999_999A)), q(0x3FFB_9999_9999_9999, 0xA000_0000_0000_0000));
	check(db((double)qf(0x3FFF_0000_0000_0000, 0x0800_0000_0000_0001)), 0x3FF0_0000_0000_0001);
	check(db((double)qf(0x3FFF_0000_0000_0000, 0x0800_0000_0000_0000)), 0x3FF0_0000_0000_0000); // 1 + 2^-53: tie, even
	// u64 -> f128 exact
	check128(qb((float128)uv(0xFFFF_FFFF_FFFF_FFFF)), q(0x403E_FFFF_FFFF_FFFF, 0xFFFE_0000_0000_0000));
}

// ---------------------------------------------------------------------------
// c3c compile-time literals (decides whether float literals may be trusted)
// ---------------------------------------------------------------------------

fn void double_and_float_literals_are_exact() @test
{
	double d = 0.1;
	check(db(d), 0x3FB9_9999_9999_999A);
	double sub = 4.9406564584124654e-324;
	check(db(sub), 1);
	float f = 0.1f;
	check(sb(f), 0x3DCC_CCCD);
	double neg_zero = -0.0;
	check(db(neg_zero), 0x8000_0000_0000_0000);
}

// Observed limitation: c3c folds float128 literals at double precision. 0.1 as
// f128 should be 0x3FFB_9999_9999_9999_9999_9999_9999_999A; c3c produces the
// widened double 0.1. Never write float128 literals (if this test starts failing,
// c3c fixed it; the decision in float_value.c3 still stands for the other reasons).
fn void float128_literals_have_double_precision() @test
{
	float128 x = 0.1;
	check128(qb(x), q(0x3FFB_9999_9999_9999, 0xA000_0000_0000_0000));
}
