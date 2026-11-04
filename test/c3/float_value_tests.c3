// Plan 10 stage 2: value.c3's float/complex wiring. Checks that the generic
// Value operations (add/sub/mul/div/negate/compare/print and the Zig-named
// wrappers) forward float and complex operands to aro::float_value, and that the
// integer paths are unaffected.
//
// Expected values are source-derived (IEEE 754 by hand, from the Zig source of
// Value.zig and std.fmt `{d}`), or come from the fixture named on the check.
// The bit-pattern vectors from the Zig 0.17.0 probe are checked by
// //test/c3:float_vector_tests.
module float_value_tests;
import aro::float_value, aro::value, aro::value_interner, aro::type_store, aro::target, aro::compilation;
import std::io, std::core::mem::allocators, std::core::dstring;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn uint128 u128(ulong hi, ulong lo) => (uint128)hi << 64 | (uint128)lo;

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
	check(ta.allocation_count(), 0);
}

fn Value fv(Compilation* comp, KeyFloat f) => value::intern(comp, value_interner::key_float(f));
fn Value f32v(Compilation* comp, uint bits) => fv(comp, float_value::f32_value(bits));
fn Value f64v(Compilation* comp, ulong bits) => fv(comp, float_value::f64_value(bits));
fn Value c64v(Compilation* comp, ulong re, ulong im) => value::intern(comp, value_interner::key_complex(float_value::make_complex(float_value::f64_value(re), float_value::f64_value(im))));
fn QualType complex_of(Compilation* comp, QualType qt) => comp.type_store.put(type_store::type_complex(qt));

fn void check_value(Value got, Value want)
{
	if (got.opt_ref != want.opt_ref)
	{
		io::printfn("value ref %x, want %x", (uint)got.opt_ref, (uint)want.opt_ref);
		test::eq(1, 0);
	}
}

fn void check_float_bits(Compilation* comp, Value v, KeyFloatTag tag, uint128 bits)
{
	InternerKey k = comp.interner.get(v.ref());
	if (k.tag != FLOAT || k.float_val.tag != tag || k.float_val.raw() != bits)
	{
		io::printfn("got key %s, want %s bits %032x", k.tag, tag, bits);
		test::eq(1, 0);
	}
}

fn void check_print(Compilation* comp, Value v, QualType qt, String want)
{
	DString w = dstring::temp();
	bool nested = v.print(qt, comp, w);
	assert(!nested);
	if (w.str_view() != want)
	{
		io::printfn("printed '%s', want '%s'", w.str_view(), want);
		test::eq(1, 0);
	}
}

const ulong D_ONE = 0x3FF0_0000_0000_0000;
const ulong D_ONE_HALF = 0x3FF8_0000_0000_0000;
const ulong D_TWO = 0x4000_0000_0000_0000;
const ulong D_THREE = 0x4008_0000_0000_0000;
const ulong D_FOUR = 0x4010_0000_0000_0000;
const ulong D_NEG_TWO = 0xC000_0000_0000_0000;
const ulong D_NEG_FOUR = 0xC010_0000_0000_0000;
const ulong D_INF = 0x7FF0_0000_0000_0000;

fn void value_arithmetic_dispatches_float() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r = value::NONE;
		// 0.1 + 0.2 = 0x3FD3333333333334 (IEEE double, source-derived)
		assert(!r.add(f64v(comp, 0x3FB9_9999_9999_999A), f64v(comp, 0x3FC9_9999_9999_999A), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, 0x3FD3_3333_3333_3334));
		// 1 - 3 = -2.0: int operands are converted to the result type
		assert(!r.sub(value::ONE, value::int_u64(3, comp), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, D_NEG_TWO));
		// 1.5f * 2 = 3.0f
		assert(!r.mul(f32v(comp, 0x3FC0_0000), value::int_u64(2, comp), type_store::FLOAT, comp));
		check_value(r, f32v(comp, 0x4040_0000));
		// 1.0 / 0.0 = +inf, never an error
		assert(!r.div(value::ONE, f64v(comp, 0), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, D_INF));
		// negate goes through sub(0, x): 0.0 - 1.5 = -1.5
		assert(!r.negate(f64v(comp, D_ONE_HALF), type_store::DOUBLE, comp));
		check_value(r, f64v(comp, 0xBFF8_0000_0000_0000));
		// decrement: 1.5L - 1 = 0.5L (f80)
		assert(!r.decrement(f64v(comp, D_ONE_HALF), type_store::LONG_DOUBLE, comp));
		check_float_bits(comp, r, F80, u128(0x3FFE, 0x8000_0000_0000_0000));
		// __float128: 1 + 1 = 2
		assert(!r.add(value::ONE, value::ONE, type_store::FLOAT128, comp));
		check_float_bits(comp, r, F128, u128(0x4000_0000_0000_0000, 0));
		// integer path still works: 2 + 3 = 5 in int
		assert(!r.add(value::int_u64(2, comp), value::int_u64(3, comp), type_store::INT, comp));
		check_value(r, value::int_u64(5, comp));
	};
}

fn void value_arithmetic_dispatches_complex() @test
{
	// fixture "complex values" (_Static_assert left-hand sides)
	@with_comp(; Compilation* comp)
	{
		QualType cd = complex_of(comp, type_store::DOUBLE);
		Value r = value::NONE;
		assert(!r.add(value::ONE, c64v(comp, 0, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_ONE, D_TWO));
		assert(!r.mul(c64v(comp, 0, D_TWO), c64v(comp, 0, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_NEG_FOUR, 0));
		assert(!r.div(c64v(comp, D_TWO, D_FOUR), c64v(comp, 0, D_ONE), cd, comp));
		check_value(r, c64v(comp, D_FOUR, D_NEG_TWO));
		assert(!r.sub(c64v(comp, D_FOUR, D_FOUR), c64v(comp, D_TWO, D_TWO), cd, comp));
		check_value(r, c64v(comp, D_TWO, D_TWO));
		// Annex G (embedded Zig test): (inf + NaN i) * 2 -> real inf, imag NaN
		Value a = c64v(comp, D_INF, 0x7FF8_0000_0000_0000);
		assert(!r.mul(a, f64v(comp, D_TWO), cd, comp));
		InternerKey k = comp.interner.get(r.ref());
		assert(k.tag == COMPLEX);
		KeyFloat[2] parts = k.complex_val.parts();
		assert(parts[0].is_positive_inf());
		assert(parts[1].is_nan());
		// 2 + 2i divided by 0: both parts inf (embedded Zig test)
		assert(!r.div(c64v(comp, D_TWO, D_TWO), value::ZERO, cd, comp));
		parts = comp.interner.get(r.ref()).complex_val.parts();
		assert(parts[0].is_inf() && parts[1].is_inf());
	};
}

fn void value_compare_dispatches() @test
{
	@with_comp(; Compilation* comp)
	{
		Value one_half = f64v(comp, D_ONE_HALF);
		assert(value::compare(one_half, GT, value::ONE, comp));
		assert(value::compare(value::ONE, LT, one_half, comp));
		assert(!value::compare(one_half, LTE, value::ONE, comp));
		// mixed widths compare at f128: 0.1f != 0.1
		assert(value::compare(f32v(comp, 0x3DCC_CCCD), NEQ, f64v(comp, 0x3FB9_9999_9999_999A), comp));
		// NaN: unordered, NEQ true, even with itself (distinct refs)
		Value nan = f64v(comp, 0x7FF8_0000_0000_0000);
		assert(value::compare(nan, NEQ, nan, comp) == false); // same ref: shallow compare says equal
		Value nan2 = f64v(comp, 0x7FF8_0000_0000_0000);
		assert(!value::compare(nan, EQ, nan2, comp));
		assert(value::compare(nan, NEQ, nan2, comp));
		assert(!value::compare(nan, LT, value::ONE, comp));
		// -0.0 == +0.0 numerically (different refs; EQ is shallow, so use LTE/GTE)
		Value neg_zero = f64v(comp, 0x8000_0000_0000_0000);
		assert(value::compare(neg_zero, LTE, value::ZERO, comp));
		assert(value::compare(neg_zero, GTE, value::ZERO, comp));
		// complex: only NEQ
		assert(value::compare(c64v(comp, D_ONE, D_TWO), NEQ, c64v(comp, D_ONE, D_THREE), comp));
		assert(!value::compare(c64v(comp, D_TWO, 0), NEQ, f64v(comp, D_TWO), comp));
		// int compare untouched
		assert(value::compare(value::int_u64(3, comp), GT, value::int_i64(-3, comp), comp));
	};
}

fn void value_wrappers() @test
{
	@with_comp(; Compilation* comp)
	{
		Value v = f64v(comp, 0x400C_0000_0000_0000); // 3.5 -> int: 3, value changed
		check(v.float_to_int(type_store::INT, comp).ordinal, FloatToIntChangeKind.VALUE_CHANGED.ordinal);
		check_value(v, value::int_u64(3, comp));
		v = value::int_u64(3, comp);
		v.int_to_float(type_store::DOUBLE, comp);
		check_value(v, f64v(comp, D_THREE));
		v.float_cast(type_store::FLOAT, comp);
		check_value(v, f32v(comp, 0x4040_0000));
		check(v.to_float(F64, comp).raw(), D_THREE);
		Value c = c64v(comp, D_ONE_HALF, D_TWO);
		check_value(c.real_part(comp), f64v(comp, D_ONE_HALF));
		check_value(c.imaginary_part(comp), f64v(comp, D_TWO));
		check(c.imag(F64, comp).raw(), D_TWO);
		check_value(value::complex_conj(c, complex_of(comp, type_store::DOUBLE), comp), c64v(comp, D_ONE_HALF, 0xC000_0000_0000_0000));
		Value inf = f64v(comp, 0xFFF0_0000_0000_0000);
		assert(inf.is_inf(comp));
		check(inf.is_inf_sign(comp).value, -1);
		assert(!inf.is_nan(comp));
		assert(f64v(comp, 0x7FF8_0000_0000_0001).is_nan(comp));
		check(value::ONE.is_inf_sign(comp).value, IsInfKind.UNKNOWN.value);
	};
}

fn void value_print() @test
{
	@with_comp(; Compilation* comp)
	{
		// Zig `{d}` of the (rounded) f64; source-derived.
		check_print(comp, f64v(comp, D_ONE_HALF), type_store::DOUBLE, "1.5");
		check_print(comp, f64v(comp, D_TWO), type_store::DOUBLE, "2");
		check_print(comp, f64v(comp, 0x3FB9_9999_9999_999A), type_store::DOUBLE, "0.1");
		check_print(comp, f32v(comp, 0x3DCC_CCCD), type_store::FLOAT, "0.1"); // f32 rounded to 6 places
		check_print(comp, f64v(comp, 0xFFF0_0000_0000_0000), type_store::DOUBLE, "-inf");
		check_print(comp, c64v(comp, D_ONE, D_NEG_TWO), complex_of(comp, type_store::DOUBLE), "1 + -2i");
		check_print(comp, value::int_i64(-42, comp), type_store::INT, "-42");
		check_print(comp, value::int_u64(18446744073709551615, comp), type_store::ULONG, "18446744073709551615");
		check_print(comp, value::ONE, type_store::BOOL, "true");
		check_print(comp, value::ZERO, type_store::BOOL, "false");
		check_print(comp, value::NULL, type_store::NULLPTR_T, "nullptr_t");
		// pointer: nested print, then print_pointer
		Value p = value::pointer({ .node = 7, .offset = value::int_i64(8, comp).ref() }, comp);
		DString w = dstring::temp();
		NestedPrint nested;
		assert(p.print(type_store::INT_POINTER, comp, w, &nested));
		check(nested.node, 7);
		value::print_pointer(nested.offset, "x", comp, w);
		assert(w.str_view() == "&x8");
		w = dstring::temp();
		value::print_pointer(value::ZERO, "y", comp, w);
		assert(w.str_view() == "&y");
	};
}
