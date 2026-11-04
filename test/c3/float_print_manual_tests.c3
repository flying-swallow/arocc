// Tests for src/c3/float_print.c3 that depend on other plan 10 stage-1 agents:
//   - print_float / print_complex for f16, f32, f80, f128 (and cf16/cf32/cf80/
//     cf128) need KeyFloat.cast (10.3 `conversions`, built on 10.2's
//     to_f128/from_f128) and, for the f16/f32/cf32 scaling, KeyFloat.mul/div at
//     F64 (10.1 `narrow-float`);
//   - the Value-level `compare` needs to_float / imag (10.3).
// Until those land the stubs hit `unreachable`, so the target is tagged
// "manual" and is not part of //test/... (run it explicitly; the integrator
// should drop the tag once plan 10 is merged).
//
// Provenance of expected values:
// - "zig 0.17.0 run": the Value.print float/complex arms copied verbatim from
//   src/aro/Value.zig into a standalone program, run with
//   /home/user/tools/zig/ziglang/zig (0.17.0) on x86_64-linux, Debug mode.
// - "fixture <name>": value dumps / diagnostics in test/cases/<name>.c.
// - "source-derived": Value.zig compare + std.math.compare, by hand.
module float_print_manual_tests;
import aro::float_value, aro::value_interner, aro::value, aro::bigint, aro::type_store, aro::target, aro::lang_opts, aro::compilation;
import std::io, std::core::mem::allocators, std::core::dstring;

struct RealVector
{
	KeyFloatTag tag;
	ulong hi;
	ulong lo;
	String text;
}

struct ComplexVector
{
	KeyComplexTag tag;
	ulong re_hi;
	ulong re_lo;
	ulong im_hi;
	ulong im_lo;
	String text;
}

fn KeyFloat raw(KeyFloatTag tag, ulong hi, ulong lo) => float_value::from_raw(tag, (uint128)hi << 64 | (uint128)lo);

fn String fmt_float(KeyFloat f)
{
	DString w = dstring::temp();
	float_value::print_float(f, w);
	return w.str_view();
}

fn String fmt_complex(KeyComplex c)
{
	DString w = dstring::temp();
	float_value::print_complex(c, w);
	return w.str_view();
}

<*
 zig 0.17.0 run: `std.debug.print("{d}", .{X})` with X the .float arm of
 Value.print for each bit pattern (f16: Zig @round(f64 * 1000) / 1000, f32:
 Zig @round(f64 * 1000000) / 1000000, f80/f128: Zig @floatCast to f64).
*>
const RealVector[*] REAL_VECTORS = {
	{ F16, 0x0, 0x3C00, "1" },
	{ F16, 0x0, 0x3E00, "1.5" },
	{ F16, 0x0, 0x3CCD, "1.2" },
	{ F16, 0x0, 0x2E66, "0.1" },
	{ F16, 0x0, 0x1, "0" },
	{ F16, 0x0, 0x8001, "-0" },
	{ F16, 0x0, 0x7BFF, "65504" },
	{ F16, 0x0, 0x7C00, "inf" },
	{ F16, 0x0, 0xFC00, "-inf" },
	{ F16, 0x0, 0x7E00, "nan" },
	{ F16, 0x0, 0xFE00, "-nan" },
	{ F16, 0x0, 0x8000, "-0" },
	{ F16, 0x0, 0x0, "0" },
	{ F16, 0x0, 0x3555, "0.333" },
	{ F16, 0x0, 0x1400, "0.001" },
	{ F16, 0x0, 0x1401, "0.001" },
	{ F16, 0x0, 0x13FF, "0.001" },
	{ F16, 0x0, 0xB400, "-0.25" },
	{ F16, 0x0, 0x3801, "0.5" },
	{ F16, 0x0, 0x400, "0" },
	{ F16, 0x0, 0x1001, "0" },
	{ F16, 0x0, 0x5640, "100" },
	{ F32, 0x0, 0x3F99999A, "1.2" },
	{ F32, 0x0, 0x3F000000, "0.5" },
	{ F32, 0x0, 0x40B00000, "5.5" },
	{ F32, 0x0, 0x3FC00000, "1.5" },
	{ F32, 0x0, 0x3FB33333, "1.4" },
	{ F32, 0x0, 0x4019999A, "2.4" },
	{ F32, 0x0, 0x3DCCCCCD, "0.1" },
	{ F32, 0x0, 0x3EAAAAAB, "0.333333" },
	{ F32, 0x0, 0x40490FDB, "3.141593" },
	{ F32, 0x0, 0x1, "0" },
	{ F32, 0x0, 0x80000001, "-0" },
	{ F32, 0x0, 0x7F7FFFFF, "340282346638528860000000000000000000000" },
	{ F32, 0x0, 0x7F800000, "inf" },
	{ F32, 0x0, 0xFF800000, "-inf" },
	{ F32, 0x0, 0x7FC00000, "nan" },
	{ F32, 0x0, 0xFFC00000, "-nan" },
	{ F32, 0x0, 0x80000000, "-0" },
	{ F32, 0x0, 0x35000000, "0" },
	{ F32, 0x0, 0x35000001, "0" },
	{ F32, 0x0, 0xB5000000, "-0" },
	{ F32, 0x0, 0x34FFFFFF, "0" },
	{ F32, 0x0, 0x4B000001, "8388609" },
	{ F32, 0x0, 0x4B7FFFFF, "16777215" },
	{ F32, 0x0, 0x5F000000, "9223372036854776000" },
	{ F32, 0x0, 0x358637BD, "0.000001" },
	{ F32, 0x0, 0x3F800001, "1" },
	{ F32, 0x0, 0x4E6E6B28, "1000000000" },
	{ F80, 0x3FFF, 0x8000000000000000, "1" },
	{ F80, 0x3FFB, 0xCCCCCCCCCCCCCCCD, "0.1" },
	{ F80, 0x7FFF, 0x8000000000000000, "inf" },
	{ F80, 0xFFFF, 0x8000000000000000, "-inf" },
	{ F80, 0x7FFF, 0xC000000000000000, "nan" },
	{ F80, 0xFFFF, 0xC000000000000000, "-nan" },
	{ F80, 0x43FF, 0x8000000000000000, "inf" },
	{ F80, 0x43FE, 0xFFFFFFFFFFFFFC00, "inf" },
	{ F80, 0x43FE, 0xFFFFFFFFFFFFFFFF, "inf" },
	{ F80, 0x0, 0x1, "0" },
	{ F80, 0x8000, 0x0, "-0" },
	{ F80, 0x4000, 0x8000000000000400, "2" },
	{ F80, 0x4000, 0x8000000000000401, "2.0000000000000004" },
	{ F80, 0x3FFF, 0x8000000000000001, "1" },
	{ F80, 0x1, 0x8000000000000000, "0" },
	{ F128, 0x3FFF000000000000, 0x0, "1" },
	{ F128, 0x3FFB999999999999, 0x999999999999999A, "0.1" },
	{ F128, 0x7FFF000000000000, 0x0, "inf" },
	{ F128, 0x7FFF800000000000, 0x0, "nan" },
	{ F128, 0xFFFF800000000000, 0x0, "-nan" },
	{ F128, 0x43FF000000000000, 0x0, "inf" },
	{ F128, 0x43FEFFFFFFFFFFFF, 0xF800000000000000, "inf" },
	{ F128, 0x43FEFFFFFFFFFFFF, 0xF7FFFFFFFFFFFFFF, "179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" },
	{ F128, 0x0, 0x1, "0" },
	{ F128, 0x8000000000000000, 0x0, "-0" },
	{ F128, 0x3FFF000000000000, 0x800000000000000, "1" },
	{ F128, 0x3FFF000000000000, 0x1800000000000000, "1.0000000000000004" },
	{ F128, 0x3FFF000000000000, 0x800000000000001, "1.0000000000000002" },
	{ F128, 0x3C00FFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022250738585072014" },
	{ F128, 0x3BCD000000000000, 0x0, "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005" },
	{ F128, 0x3BCC000000000000, 0x0, "0" },
};

<*
 zig 0.17.0 run of the .complex arm: cf32 parts scaled like f32, every other
 width (cf16 included) printed as plain @as(f64, @floatCast(x)).
*>
const ComplexVector[*] COMPLEX_VECTORS = {
	{ CF16, 0x0, 0x3C00, 0x0, 0x4000, "1 + 2i" },
	{ CF16, 0x0, 0x2E66, 0x0, 0xBCCD, "0.0999755859375 + -1.2001953125i" },
	{ CF16, 0x0, 0x7E00, 0x0, 0xFC00, "nan + -infi" },
	{ CF32, 0x0, 0x3F800000, 0x0, 0x40000000, "1 + 2i" },
	{ CF32, 0x0, 0x3F99999A, 0x0, 0xC019999A, "1.2 + -2.4i" },
	{ CF32, 0x0, 0x0, 0x0, 0x80000000, "0 + -0i" },
	{ CF32, 0x0, 0x35000000, 0x0, 0xB5000000, "0 + -0i" },
	{ CF64, 0x0, 0x3FF0000000000000, 0x0, 0x4000000000000000, "1 + 2i" },
	{ CF64, 0x0, 0x0, 0x0, 0xBFF0000000000000, "0 + -1i" },
	{ CF64, 0x0, 0x3FB999999999999A, 0x0, 0xFFF8000000000000, "0.1 + -nani" },
	{ CF80, 0x0, 0x0, 0x3FFF, 0x8000000000000000, "0 + 1i" },
	{ CF80, 0x3FFB, 0xCCCCCCCCCCCCCCCD, 0xFFFF, 0x8000000000000000, "0.1 + -infi" },
	{ CF128, 0x3FFF000000000000, 0x0, 0xC000000000000000, 0x0, "1 + -2i" },
	{ CF128, 0x3FFB999999999999, 0x999999999999999A, 0x7FFF800000000000, 0x0, "0.1 + nani" },
};

fn void print_float_matches_zig() @test
{
	foreach (v : REAL_VECTORS)
	{
		@pool()
		{
			String got = fmt_float(raw(v.tag, v.hi, v.lo));
			if (got != v.text) io::printfn("mismatch %s %x %x: got \"%s\" want \"%s\"", v.tag, v.hi, v.lo, got, v.text);
			test::eq(got, v.text);
		};
	}
}

fn void print_complex_matches_zig() @test
{
	foreach (v : COMPLEX_VECTORS)
	{
		@pool()
		{
			KeyFloatTag s = v.tag.scalar();
			String got = fmt_complex(float_value::make_complex(raw(s, v.re_hi, v.re_lo), raw(s, v.im_hi, v.im_lo)));
			if (got != v.text) io::printfn("mismatch %s: got \"%s\" want \"%s\"", v.tag, got, v.text);
			test::eq(got, v.text);
		};
	}
}

fn void print_fixture_goldens() @test
{
	@pool()
	{
		// fixture "float to int": 'float' to 'int' changes value from 1.2 to 1
		test::eq(fmt_float(float_value::f32_value(0x3F99_999A)), "1.2");
		// fixture "float to int": 'float' to 'int' changes non-zero value from 0.5 to 0
		test::eq(fmt_float(float_value::f32_value(0x3F00_0000)), "0.5");
		// fixture "float to int": 'float' to '_Bool' changes value from 1.5 to true
		test::eq(fmt_float(float_value::f32_value(0x3FC0_0000)), "1.5");
		// fixture "assignment": 'float' to '_Bool' changes value from 5.5 to true
		test::eq(fmt_float(float_value::f32_value(0x40B0_0000)), "5.5");
		// fixture "ast/vectors": float_literal: 'float' (value: 1.4) / (value: 2.4)
		test::eq(fmt_float(float_value::f32_value(0x3FB3_3333)), "1.4");
		test::eq(fmt_float(float_value::f32_value(0x4019_999A)), "2.4");
		// fixture "ast/complex init": array_init_expr: '_Complex float' (value: 1 + 2i)
		test::eq(fmt_complex(float_value::make_complex(float_value::f32_value(0x3F80_0000), float_value::f32_value(0x4000_0000))), "1 + 2i");
		// fixture "ast/__float80": imaginary_literal: '_Complex long double' (value: 0 + 1i)
		test::eq(fmt_complex(float_value::make_complex(float_value::zero(F80), float_value::one(F80))), "0 + 1i");
		// fixture "ast/float eval method": (real_to_complex_float) '_Complex float' (value: 0 + 0i)
		test::eq(fmt_complex(float_value::make_complex(float_value::zero(F32), float_value::zero(F32))), "0 + 0i");
	};
}

// -----------------------------------------------------------------------------
// Value-level compare (source-derived from Value.zig compare)
// -----------------------------------------------------------------------------

const Host HOST = { X86_64, LINUX, GNU };

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
	test::eq((long)ta.allocation_count(), 0);
}

fn Value fv(Compilation* comp, KeyFloat f) => value::intern(comp, value_interner::key_float(f));
fn Value cv(Compilation* comp, KeyFloat re, KeyFloat im) => value::intern(comp, value_interner::key_complex(float_value::make_complex(re, im)));

fn void value_compare() @test
{
	@with_comp(; Compilation* comp)
	{
		Value half = fv(comp, float_value::f64_value(0x3FE0_0000_0000_0000));
		Value two_f = fv(comp, float_value::f32_value(0x4000_0000));
		Value nan = fv(comp, float_value::std_nan(F64));
		Value three = value::int_u64(3, comp);
		// float vs float of other widths, and vs int (both go through f128).
		assert(float_value::compare(half, LT, two_f, comp));
		assert(float_value::compare(two_f, LT, three, comp));
		assert(float_value::compare(three, GT, half, comp));
		assert(!float_value::compare(half, EQ, two_f, comp));
		// value::ONE is the int key a float 1.0 interns to.
		assert(float_value::compare(value::ONE, GT, half, comp));
		// NaN: unordered, only != holds (also against itself through compare).
		assert(!float_value::compare(nan, LT, three, comp) && !float_value::compare(nan, GTE, three, comp));
		assert(float_value::compare(nan, NEQ, half, comp));
		// complex: only !=; NaN parts make values unequal.
		KeyFloat one = float_value::one(F64);
		Value c12 = cv(comp, one, float_value::f64_value(0x4000_0000_0000_0000));
		Value c10 = cv(comp, one, float_value::f64_value(0));
		Value c_nan = cv(comp, one, float_value::std_nan(F64));
		Value c_nan2 = cv(comp, one, float_value::default_nan(F64));
		assert(float_value::compare(c12, NEQ, c10, comp));
		assert(!float_value::compare(c10, NEQ, value::ONE, comp)); // 1 + 0i vs int 1
		assert(float_value::compare(c_nan, NEQ, c_nan2, comp));
		assert(float_value::compare(c12, NEQ, value::ONE, comp));
	};
}
