// Tests for the integer, byte and pointer operations of aro::value
// (src/c3/value.c3, a port of src/aro/Value.zig).
//
// Sources of expected values (no Zig executable was run; no differential
// parity is claimed):
// - "Value.zig test": the embedded `minUnsignedBits` / `minSignedBits` tests.
// - "fixture <name>": constant-expression results and overflow diagnostics in
//   test/cases/<name>.c (expected warnings such as "overflow in expression;
//   result is '2147483647'", or `_Static_assert`s that hold).
// - "source-derived": computed by hand (and with Python big integers) from the
//   semantics of Value.zig and std.math.big.int: wrapping add/sub, exact mul then
//   truncate, untruncated division quotient, floor shift right, infinite two's
//   complement bitwise ops. Every >128-bit expected value is written as explicit
//   little-endian 64-bit limbs.
//
// All tests run on x86_64-linux-gnu (int 32, long 64, ptrdiff_t long, null
// pointer representation 0), with a TrackingAllocator that must end with no live
// allocations (Zig's `defer gpa.free` of scratch limbs).
module integer_value_tests;
import aro::value, aro::value_interner, aro::bigint, aro::type_store, aro::target, aro::lang_opts, aro::compilation;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

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

fn Value u(Compilation* comp, ulong x) => value::int_u64(x, comp);
fn Value i(Compilation* comp, long x) => value::int_i64(x, comp);

<* Intern a big int from explicit little-endian limbs (must be normalized). *>
fn Value big(Compilation* comp, bool positive, Limb[] limbs)
{
	return value::intern(comp, value_interner::key_big_int({ .limbs = limbs, .positive = positive }));
}

<* (+/-) 2^e for e < 512. *>
fn Value pow2(Compilation* comp, usz e, bool positive = true)
{
	Limb[8] buf;
	buf[e / 64] = (Limb)1 << (e % 64);
	return big(comp, positive, buf[:e / 64 + 1]);
}

<* 2^e - 1 for e < 512. *>
fn Value ones(Compilation* comp, usz e)
{
	Limb[8] buf;
	usz n = e / 64;
	for (usz k = 0; k < n; k++) buf[k] = ulong::max;
	if (e % 64) buf[n++] = ((Limb)1 << (e % 64)) - 1;
	return big(comp, true, buf[:n]);
}

fn QualType bit_int(Compilation* comp, ushort bits, Signedness s) => comp.type_store.put(type_store::type_bit_int(bits, s));

fn void print_val(Compilation* comp, Value v)
{
	if (v.is_none())
	{
		io::eprint("none");
		return;
	}
	InternerKey key = comp.interner.get(v.ref());
	if (key.tag != INT)
	{
		io::eprintf("<key tag %s>", key.tag);
		return;
	}
	BigIntSpace space;
	String s = key.to_big_int(&space).to_string_alloc(tmem, 10, false);
	io::eprint(s);
}

<* Values are interned, so equal values have equal refs. *>
fn void expect(Compilation* comp, Value got, Value want, String what = "")
{
	if (got.opt_ref == want.opt_ref) return;
	io::eprintf("%s: got ", what);
	print_val(comp, got);
	io::eprint(", want ");
	print_val(comp, want);
	io::eprintn();
	unreachable("value mismatch");
}

// ---------------------------------------------------------------------------
// Bit counts (Value.zig tests)
// ---------------------------------------------------------------------------

fn void min_unsigned_bits() @test
{
	@with_comp(; Compilation* comp)
	{
		// Value.zig test "minUnsignedBits".
		ulong[2][*] cases = {
			{ 0, 0 }, { 1, 1 }, { 2, 2 },
			{ 0x7F, 7 }, { 0xFF, 8 }, { 0x7FFF, 15 }, { 0xFFFF, 16 },
			{ 0x7FFF_FFFF, 31 }, { 0xFFFF_FFFF, 32 },
			{ 0x7FFF_FFFF_FFFF_FFFF, 63 }, { ulong::max, 64 },
		};
		foreach (c : cases) check(u(comp, c[0]).min_unsigned_bits(comp), c[1]);
		// source-derived: >64-bit values.
		check(pow2(comp, 64).min_unsigned_bits(comp), 65);
		check(pow2(comp, 200).min_unsigned_bits(comp), 201);
		check(ones(comp, 256).min_unsigned_bits(comp), 256);
	};
}

fn void min_signed_bits() @test
{
	@with_comp(; Compilation* comp)
	{
		// Value.zig test "minSignedBits".
		long[2][*] cases = {
			{ -1, 1 }, { -2, 2 }, { -10, 5 }, { -101, 8 },
			{ -128, 8 }, { -32768, 16 }, { -2147483648, 32 }, { long::min, 64 },
		};
		foreach (c : cases) check(i(comp, c[0]).min_signed_bits(comp), c[1]);
		// source-derived (bitCountTwosComp): -2^64 needs 65 bits, -(2^64+1) 66, -2^200 201.
		check(pow2(comp, 64, false).min_signed_bits(comp), 65);
		check(big(comp, false, { 1, 1 }).min_signed_bits(comp), 66);
		check(pow2(comp, 200, false).min_signed_bits(comp), 201);
	};
}

// ---------------------------------------------------------------------------
// Interning, none / null / zero
// ---------------------------------------------------------------------------

fn void interning_dedup() @test
{
	@with_comp(; Compilation* comp)
	{
		// Static refs (Interner Key.toRef).
		assert(u(comp, 0).opt_ref == value::ZERO.opt_ref);
		assert(i(comp, 0).opt_ref == value::ZERO.opt_ref);
		assert(u(comp, 1).opt_ref == value::ONE.opt_ref);
		assert(i(comp, 1).opt_ref == value::ONE.opt_ref);
		// u64/i64/big_int forms of one value share a ref.
		assert(u(comp, 5).opt_ref == i(comp, 5).opt_ref);
		assert(u(comp, 5).opt_ref == big(comp, true, { 5 }).opt_ref);
		assert(u(comp, (ulong)1 << 40).opt_ref == i(comp, (long)1 << 40).opt_ref);
		assert(i(comp, -7).opt_ref == big(comp, false, { 7 }).opt_ref);
		assert(pow2(comp, 200).opt_ref == pow2(comp, 200).opt_ref);
		// Different values get different refs, including sign.
		assert(i(comp, -5).opt_ref != u(comp, 5).opt_ref);
		assert(pow2(comp, 200).opt_ref != pow2(comp, 200, false).opt_ref);
		assert(pow2(comp, 64).opt_ref != u(comp, ulong::max).opt_ref);
		// Round trips.
		check(u(comp, 0xFFFF_FFFF_FFFF).to_u64(comp)!!, 0xFFFF_FFFF_FFFF);
		check(i(comp, -12345).to_i64(comp)!!, -12345);
		assert(@catch(i(comp, -1).to_u64(comp)) == value::NO_INT);
		assert(@catch(pow2(comp, 64).to_u64(comp)) == value::NO_INT);
		assert(@catch(u(comp, ((ulong)1) << 32).to_u32(comp)) == value::NO_INT);
		assert(@catch(value::NONE.to_i64(comp)) == value::NO_INT);
		assert(@catch(value::NULL.to_i64(comp)) == value::NO_INT);
		check(pow2(comp, 63, false).to_i64(comp)!!, long::min);
	};
}

fn void none_null_zero() @test
{
	@with_comp(; Compilation* comp)
	{
		assert(value::NONE.is_none());
		assert(!value::ZERO.is_none() && !value::NULL.is_none());
		assert(value::NONE.opt_ref != value::ZERO.opt_ref);
		assert(value::NULL.opt_ref != value::ZERO.opt_ref);
		Value zero_init = {};
		assert(!zero_init.is_none(), "a zero-initialized Value is not none");

		assert(!value::NONE.is_zero(comp));
		assert(value::ZERO.is_zero(comp));
		assert(!value::ONE.is_zero(comp));
		assert(value::NULL.is_zero(comp), "x86_64 null pointer representation is 0");
		assert(!u(comp, 3).is_zero(comp));
		assert(!pow2(comp, 100).is_zero(comp));

		assert(!value::NONE.is(INT, comp));
		assert(value::ZERO.is(INT, comp));
		assert(value::NULL.is(NULL, comp));
		assert(!value::NULL.is(INT, comp));
		assert(u(comp, 42).is_arithmetic(comp));
		assert(!value::NONE.is_arithmetic(comp));
		assert(!value::NULL.is_arithmetic(comp));

		Value v = value::NONE;
		v.bool_cast(comp);
		assert(v.is_none(), "bool_cast keeps none");
		v = i(comp, -9);
		v.bool_cast(comp);
		expect(comp, v, value::ONE);
		v = value::ZERO;
		v.bool_cast(comp);
		expect(comp, v, value::ZERO);
		assert(value::from_bool(true).opt_ref == value::ONE.opt_ref);
	};
}

fn void bytes_values() @test
{
	@with_comp(; Compilation* comp)
	{
		Value s = value::intern(comp, value_interner::key_bytes("ab\0"));
		assert(s.is(BYTES, comp));
		assert(!s.is_zero(comp));
		assert(!s.is_arithmetic(comp));
		test::eq((String)s.to_bytes(comp), "ab\0");
		expect(comp, value::elem(s, u(comp, 0), comp), u(comp, 'a'));
		expect(comp, value::elem(s, u(comp, 2), comp), value::ZERO);
		assert(value::elem(s, u(comp, 4), comp).is_none());
		assert(value::elem(s, i(comp, -1), comp).is_none());
		assert(value::elem(u(comp, 5), value::ZERO, comp).is_none());
		assert(value::elem(value::NONE, value::ZERO, comp).is_none());
		// Bytes operands make add/sub unknown.
		Value r = value::ONE;
		assert(!r.add(s, value::ONE, type_store::INT, comp));
		assert(r.is_none());
		r = value::ONE;
		assert(!r.sub(s, value::ONE, type_store::INT, comp));
		assert(r.is_none());
		// int_cast leaves bytes alone.
		Value b = s;
		assert(b.int_cast(type_store::INT, comp) == NONE);
		assert(b.opt_ref == s.opt_ref);
	};
}

// ---------------------------------------------------------------------------
// intCast
// ---------------------------------------------------------------------------

fn void int_cast() @test
{
	@with_comp(; Compilation* comp)
	{
		Value v = value::NONE;
		assert(v.int_cast(type_store::INT, comp) == NONE);
		assert(v.is_none());

		// fixture assignment: `unsigned char x = 1000;` changes value from 1000 to 232.
		v = u(comp, 1000);
		assert(v.int_cast(type_store::UCHAR, comp) == TRUNCATED);
		expect(comp, v, u(comp, 232));

		v = u(comp, 300);
		assert(v.int_cast(type_store::SCHAR, comp) == TRUNCATED);
		expect(comp, v, u(comp, 44));
		v = u(comp, 200);
		assert(v.int_cast(type_store::SCHAR, comp) == SIGN_CHANGED, "200 needs 8 bits: no truncation, sign changes");
		expect(comp, v, i(comp, -56));

		v = i(comp, -1);
		assert(v.int_cast(type_store::UINT, comp) == SIGN_CHANGED);
		expect(comp, v, u(comp, 0xFFFF_FFFF));
		v = i(comp, -1);
		assert(v.int_cast(type_store::ULONG, comp) == SIGN_CHANGED);
		expect(comp, v, u(comp, ulong::max));

		v = u(comp, 5);
		assert(v.int_cast(type_store::INT, comp) == SIGN_CHANGED, "Zig: non-negative source is unsigned, dest int is signed");
		expect(comp, v, u(comp, 5));
		v = u(comp, 5);
		assert(v.int_cast(type_store::UINT, comp) == NONE);
		v = i(comp, -5);
		assert(v.int_cast(type_store::LONG, comp) == NONE);
		expect(comp, v, i(comp, -5));

		// fixture _BitInt: `(int)-18446744073709551616WB == 0`.
		v = pow2(comp, 64, false);
		assert(v.int_cast(type_store::INT, comp) == TRUNCATED);
		expect(comp, v, value::ZERO);

		// source-derived: 2^255 + 7 cast to _BitInt(130) keeps the low 130 bits.
		v = big(comp, true, { 7, 0, 0, ((ulong)1) << 63 });
		assert(v.int_cast(bit_int(comp, 130, UNSIGNED), comp) == TRUNCATED);
		expect(comp, v, u(comp, 7));
		// -(2^129) to signed _BitInt(130) is the minimum: no change.
		v = pow2(comp, 129, false);
		assert(v.int_cast(bit_int(comp, 130, SIGNED), comp) == NONE);
		expect(comp, v, pow2(comp, 129, false));
		// -1 to unsigned _BitInt(200): 2^200 - 1.
		v = i(comp, -1);
		assert(v.int_cast(bit_int(comp, 200, UNSIGNED), comp) == SIGN_CHANGED);
		expect(comp, v, ones(comp, 200));
	};
}

// ---------------------------------------------------------------------------
// add / sub / negate / decrement
// ---------------------------------------------------------------------------

fn void add_sub() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r = value::NONE;
		assert(!r.add(u(comp, 2), u(comp, 3), type_store::INT, comp));
		expect(comp, r, u(comp, 5));

		// fixture arithmetic overflow: 0xFFFFFFFF + 1 == 0 and 1 + 0xFFFFFFFF == 0 (unsigned int).
		assert(r.add(u(comp, 0xFFFF_FFFF), value::ONE, type_store::UINT, comp));
		expect(comp, r, value::ZERO);
		assert(r.add(value::ONE, u(comp, 0xFFFF_FFFF), type_store::UINT, comp));
		expect(comp, r, value::ZERO);
		// fixture arithmetic overflow: 0 - 0x00000001 == 0xFFFFFFFF.
		assert(r.sub(value::ZERO, value::ONE, type_store::UINT, comp));
		expect(comp, r, u(comp, 0xFFFF_FFFF));

		// source-derived: INT_MAX + 1 wraps to INT_MIN with overflow.
		assert(r.add(i(comp, 2147483647), value::ONE, type_store::INT, comp));
		expect(comp, r, i(comp, -2147483648));
		assert(!r.add(i(comp, -2147483647), i(comp, -1), type_store::INT, comp));
		expect(comp, r, i(comp, -2147483648));
		// `res` may alias an operand.
		r = i(comp, 40);
		assert(!r.add(r, r, type_store::LONG, comp));
		expect(comp, r, u(comp, 80));

		// negate / decrement.
		assert(r.negate(i(comp, -2147483648), type_store::INT, comp), "-INT_MIN overflows");
		expect(comp, r, i(comp, -2147483648));
		// fixture preprocessor binary operators `-(-9223372036854775807L -1)` overflows in long.
		assert(r.negate(i(comp, long::min), type_store::LONG, comp));
		expect(comp, r, i(comp, long::min));
		assert(!r.negate(u(comp, 9), type_store::INT, comp));
		expect(comp, r, i(comp, -9));
		assert(!r.decrement(value::ZERO, type_store::INT, comp));
		expect(comp, r, i(comp, -1));
		assert(r.decrement(value::ZERO, type_store::ULONG, comp));
		expect(comp, r, u(comp, ulong::max));

		// source-derived >128-bit: (2^255 - 1) + 1 in signed _BitInt(256) wraps to -2^255.
		QualType s256 = bit_int(comp, 256, SIGNED);
		QualType u256 = bit_int(comp, 256, UNSIGNED);
		assert(r.add(ones(comp, 255), value::ONE, s256, comp));
		expect(comp, r, pow2(comp, 255, false));
		assert(!r.add(ones(comp, 255), value::ONE, u256, comp));
		expect(comp, r, pow2(comp, 255));
		assert(r.add(ones(comp, 256), value::ONE, u256, comp));
		expect(comp, r, value::ZERO);
		// 2^200 - 2^130 in u256, carries across limbs.
		assert(!r.sub(pow2(comp, 200), pow2(comp, 130), u256, comp));
		expect(comp, r, big(comp, true, { 0, 0, 0xFFFF_FFFF_FFFF_FFFC, 0xFF }));
		// 0 - 1 in u256 wraps to 2^256 - 1.
		assert(r.sub(value::ZERO, value::ONE, u256, comp));
		expect(comp, r, ones(comp, 256));
	};
}

// ---------------------------------------------------------------------------
// mul / div / rem
// ---------------------------------------------------------------------------

fn void mul() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r = value::NONE;
		assert(!r.mul(i(comp, -6), u(comp, 7), type_store::INT, comp));
		expect(comp, r, i(comp, -42));
		// fixture arithmetic overflow: 0x80000000 * 2 == 0 and 2 * 0x80000000 == 0 (unsigned).
		assert(r.mul(u(comp, 0x8000_0000), u(comp, 2), type_store::UINT, comp));
		expect(comp, r, value::ZERO);
		assert(r.mul(u(comp, 2), u(comp, 0x8000_0000), type_store::UINT, comp));
		expect(comp, r, value::ZERO);
		// source-derived: 2^62 * 2 in long overflows to LONG_MIN; 2^62 * -2 fits exactly.
		assert(r.mul(u(comp, ((ulong)1) << 62), u(comp, 2), type_store::LONG, comp));
		expect(comp, r, i(comp, long::min));
		assert(!r.mul(u(comp, ((ulong)1) << 62), i(comp, -2), type_store::LONG, comp));
		expect(comp, r, i(comp, long::min));
		// u64 * u64 in unsigned long: (2^64-1)^2 mod 2^64 = 1.
		assert(r.mul(u(comp, ulong::max), u(comp, ulong::max), type_store::ULONG, comp));
		expect(comp, r, value::ONE);

		// source-derived >128-bit.
		QualType s256 = bit_int(comp, 256, SIGNED);
		QualType u256 = bit_int(comp, 256, UNSIGNED);
		// (2^128 + 1) * 2^100 = 2^228 + 2^100, fits.
		assert(!r.mul(big(comp, true, { 1, 0, 1 }), pow2(comp, 100), u256, comp));
		expect(comp, r, big(comp, true, { 0, ((ulong)1) << 36, 0, ((ulong)1) << 36 }));
		// (2^200 + 3) * 2^60 = 2^260 + 3*2^60: overflows s256, truncates to 3*2^60.
		assert(r.mul(big(comp, true, { 3, 0, 0, ((ulong)1) << 8 }), pow2(comp, 60), s256, comp));
		expect(comp, r, u(comp, ((ulong)3) << 60));
		// -(2^127) * 2^128 = -2^255 is the signed minimum: fits.
		assert(!r.mul(pow2(comp, 127, false), pow2(comp, 128), s256, comp));
		expect(comp, r, pow2(comp, 255, false));
		// 2^127 * 2^128 = 2^255 does not fit s256: wraps to -2^255.
		assert(r.mul(pow2(comp, 127), pow2(comp, 128), s256, comp));
		expect(comp, r, pow2(comp, 255, false));
	};
}

fn void div() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r = value::NONE;
		assert(!r.div(i(comp, 7), i(comp, -2), type_store::INT, comp));
		expect(comp, r, i(comp, -3));
		assert(!r.div(i(comp, -7), u(comp, 2), type_store::INT, comp));
		expect(comp, r, i(comp, -3));
		assert(!r.div(u(comp, 1), u(comp, 3), type_store::INT, comp));
		expect(comp, r, value::ZERO);
		// fixture arithmetic overflow: (-9223372036854775807LL - 1LL) / -1 warns with
		// "result is '9223372036854775808'": the quotient is interned untruncated.
		assert(r.div(i(comp, long::min), i(comp, -1), type_store::LONG_LONG, comp));
		expect(comp, r, u(comp, ((ulong)9223372036854775808)));
		// INT_MIN / -1 likewise.
		assert(r.div(i(comp, -2147483648), i(comp, -1), type_store::INT, comp));
		expect(comp, r, u(comp, 2147483648));

		// source-derived >128-bit.
		QualType s256 = bit_int(comp, 256, SIGNED);
		assert(!r.div(pow2(comp, 200), pow2(comp, 100), s256, comp));
		expect(comp, r, pow2(comp, 100));
		assert(!r.div(pow2(comp, 200, false), u(comp, 3), s256, comp));
		// floor((2^200) / 3) = 0x5555...5 (200 bits), truncated toward zero, negated.
		expect(comp, r, big(comp, false, { 0x5555_5555_5555_5555, 0x5555_5555_5555_5555, 0x5555_5555_5555_5555, 0x55 }));
		// -2^255 / -1 = 2^255 does not fit s256 and stays untruncated.
		assert(r.div(pow2(comp, 255, false), i(comp, -1), s256, comp));
		expect(comp, r, pow2(comp, 255));
		// small / big = 0.
		assert(!r.div(u(comp, 5), pow2(comp, 200), s256, comp));
		expect(comp, r, value::ZERO);
	};
}

fn void rem() @test
{
	@with_comp(; Compilation* comp)
	{
		// C `%` takes the sign of the dividend.
		expect(comp, value::rem(i(comp, -7), u(comp, 2), type_store::INT, comp), i(comp, -1));
		expect(comp, value::rem(u(comp, 7), i(comp, -2), type_store::INT, comp), value::ONE);
		expect(comp, value::rem(i(comp, -7), i(comp, -2), type_store::INT, comp), i(comp, -1));
		expect(comp, value::rem(u(comp, 10), u(comp, 3), type_store::UINT, comp), value::ONE);
		// INT_MIN % -1 is unknown (Zig returns `.{}`).
		assert(value::rem(i(comp, -2147483648), i(comp, -1), type_store::INT, comp).is_none());
		assert(value::rem(i(comp, long::min), i(comp, -1), type_store::LONG, comp).is_none());
		// But not for a different type's minimum.
		expect(comp, value::rem(i(comp, -2147483648), i(comp, -1), type_store::LONG, comp), value::ZERO);

		// fixture _BitInt min max: -10 % -444444444444444442051616WB != 0 (_BitInt(80)).
		QualType s80 = bit_int(comp, 80, SIGNED);
		Value rhs = big(comp, false, { 0x61b1_3ea2_804d_4420, 0x5e1d });
		Value r = value::rem(i(comp, -10), rhs, s80, comp);
		expect(comp, r, i(comp, -10));
		assert(!r.is_zero(comp));

		// source-derived >128-bit: (2^200 + 5) % 2^100 = 5; -(2^200 + 5) % 2^64 = -5.
		QualType s256 = bit_int(comp, 256, SIGNED);
		expect(comp, value::rem(big(comp, true, { 5, 0, 0, 0x100 }), pow2(comp, 100), s256, comp), u(comp, 5));
		expect(comp, value::rem(big(comp, false, { 5, 0, 0, 0x100 }), pow2(comp, 64), s256, comp), i(comp, -5));
	};
}

// ---------------------------------------------------------------------------
// Bitwise operations and shifts
// ---------------------------------------------------------------------------

fn void bitwise() @test
{
	@with_comp(; Compilation* comp)
	{
		expect(comp, value::bit_or(u(comp, 0xF0), u(comp, 0x0F), comp), u(comp, 0xFF));
		expect(comp, value::bit_and(i(comp, -1), u(comp, 0xFF), comp), u(comp, 0xFF));
		expect(comp, value::bit_and(i(comp, -8), i(comp, -3), comp), i(comp, -8));
		expect(comp, value::bit_xor(u(comp, 5), i(comp, -1), comp), i(comp, -6));
		expect(comp, value::bit_or(i(comp, -8), u(comp, 3), comp), i(comp, -5));
		expect(comp, value::bit_not(value::ZERO, type_store::INT, comp), i(comp, -1));
		expect(comp, value::bit_not(value::ZERO, type_store::UINT, comp), u(comp, 0xFFFF_FFFF));
		expect(comp, value::bit_not(u(comp, 0xFF), type_store::UCHAR, comp), value::ZERO);
		// fixture preprocessor binary operators: `~0 && 0`; ~0 in int is -1.
		expect(comp, value::bit_not(value::ZERO, type_store::LONG, comp), i(comp, -1));

		// source-derived >128-bit.
		QualType u256 = bit_int(comp, 256, UNSIGNED);
		expect(comp, value::bit_not(value::ZERO, u256, comp), ones(comp, 256));
		expect(comp, value::bit_not(ones(comp, 200), u256, comp), big(comp, true, { 0, 0, 0, 0xFFFF_FFFF_FFFF_FF00 }));
		expect(comp, value::bit_or(pow2(comp, 200), pow2(comp, 3), comp), big(comp, true, { 8, 0, 0, 0x100 }));
		expect(comp, value::bit_and(ones(comp, 200), pow2(comp, 150), comp), pow2(comp, 150));
		// -(2^200) & (2^256 - 1) = 2^256 - 2^200.
		expect(comp, value::bit_and(pow2(comp, 200, false), ones(comp, 256), comp), big(comp, true, { 0, 0, 0, 0xFFFF_FFFF_FFFF_FF00 }));
		// -1 & -(2^200) both negative.
		expect(comp, value::bit_and(i(comp, -1), pow2(comp, 200, false), comp), pow2(comp, 200, false));
		expect(comp, value::bit_xor(ones(comp, 256), pow2(comp, 255), comp), ones(comp, 255));
		// 2^200 ^ -1 = -(2^200) - 1.
		expect(comp, value::bit_xor(pow2(comp, 200), i(comp, -1), comp), big(comp, false, { 1, 0, 0, 0x100 }));
	};
}

fn void shl() @test
{
	@with_comp(; Compilation* comp)
	{
		Value r = value::NONE;
		// fixture negative and too big shift count: `0b11 << -32` warns
		// "result is '2147483647'"; `0b11 << 32` warns "result is '0'".
		assert(r.shl(u(comp, 3), i(comp, -32), type_store::INT, comp));
		expect(comp, r, i(comp, 2147483647));
		assert(r.shl(u(comp, 3), u(comp, 32), type_store::INT, comp));
		expect(comp, r, value::ZERO);
		// Negative lhs with a too-big shift gives the minimum.
		assert(r.shl(i(comp, -1), u(comp, 40), type_store::INT, comp));
		expect(comp, r, i(comp, -2147483648));
		// fixture arithmetic overflow: ((unsigned)(-1) << 1) == 0xFFFFFFFFU - 1.
		assert(r.shl(u(comp, 0xFFFF_FFFF), value::ONE, type_store::UINT, comp));
		expect(comp, r, u(comp, 0xFFFF_FFFE));
		// Shift boundaries.
		assert(r.shl(value::ONE, u(comp, 31), type_store::INT, comp), "1 << 31 overflows int");
		expect(comp, r, i(comp, -2147483648));
		assert(!r.shl(value::ONE, u(comp, 31), type_store::UINT, comp));
		expect(comp, r, u(comp, 0x8000_0000));
		assert(!r.shl(u(comp, 5), value::ZERO, type_store::INT, comp));
		expect(comp, r, u(comp, 5));
		assert(!r.shl(i(comp, -1), u(comp, 31), type_store::INT, comp), "-1 << 31 is INT_MIN");
		expect(comp, r, i(comp, -2147483648));
		assert(!r.shl(value::ONE, u(comp, 63), type_store::ULONG, comp));
		expect(comp, r, u(comp, ((ulong)1) << 63));
		assert(r.shl(value::ONE, u(comp, 64), type_store::ULONG, comp), "shift == width truncates");
		expect(comp, r, value::ZERO);
		// A huge shift amount (not a usz) saturates.
		assert(r.shl(u(comp, 1), pow2(comp, 70), type_store::UINT, comp));
		expect(comp, r, u(comp, 0xFFFF_FFFF));

		// source-derived >128-bit.
		QualType s256 = bit_int(comp, 256, SIGNED);
		QualType u256 = bit_int(comp, 256, UNSIGNED);
		assert(!r.shl(value::ONE, u(comp, 255), u256, comp));
		expect(comp, r, pow2(comp, 255));
		assert(r.shl(value::ONE, u(comp, 255), s256, comp));
		expect(comp, r, pow2(comp, 255, false));
		assert(!r.shl(u(comp, 3), u(comp, 130), s256, comp));
		expect(comp, r, big(comp, true, { 0, 0, 12 }));
		assert(r.shl(u(comp, 3), u(comp, 300), s256, comp));
		expect(comp, r, ones(comp, 255), "too-big shift gives max_int");
	};
}

fn void shr() @test
{
	@with_comp(; Compilation* comp)
	{
		// fixture preprocessor binary operators: (4 >> -2) and (4 >> 250) are 0.
		expect(comp, value::shr(u(comp, 4), i(comp, -2), type_store::INT, comp), value::ZERO);
		expect(comp, value::shr(u(comp, 4), u(comp, 250), type_store::INT, comp), value::ZERO);
		// Arithmetic (floor) shift of negatives.
		expect(comp, value::shr(i(comp, -4), u(comp, 250), type_store::INT, comp), i(comp, -1));
		expect(comp, value::shr(i(comp, -7), value::ONE, type_store::INT, comp), i(comp, -4));
		expect(comp, value::shr(i(comp, -1), u(comp, 31), type_store::INT, comp), i(comp, -1));
		expect(comp, value::shr(u(comp, 0x8000_0000), u(comp, 31), type_store::UINT, comp), value::ONE);
		expect(comp, value::shr(u(comp, 12), u(comp, 2), type_store::INT, comp), u(comp, 3));
		expect(comp, value::shr(u(comp, ulong::max), u(comp, 63), type_store::ULONG, comp), value::ONE);
		// Shift of exactly one limb removes every bit of a one-limb value.
		expect(comp, value::shr(u(comp, ulong::max), u(comp, 64), type_store::ULONG, comp), value::ZERO);

		// source-derived >128-bit.
		QualType s256 = bit_int(comp, 256, SIGNED);
		expect(comp, value::shr(pow2(comp, 200), u(comp, 136), s256, comp), pow2(comp, 64));
		expect(comp, value::shr(pow2(comp, 200, false), u(comp, 199), s256, comp), i(comp, -2));
		expect(comp, value::shr(big(comp, false, { 1, 0, 0, 0x100 }), u(comp, 200), s256, comp), i(comp, -2), "floor(-(2^200+1) / 2^200)");
		expect(comp, value::shr(pow2(comp, 200), u(comp, 201), s256, comp), value::ZERO);
		expect(comp, value::shr(pow2(comp, 200, false), u(comp, 256), s256, comp), i(comp, -1));
	};
}

// ---------------------------------------------------------------------------
// Comparison and limits
// ---------------------------------------------------------------------------

fn void compare() @test
{
	@with_comp(; Compilation* comp)
	{
		assert(value::compare(u(comp, 5), LT, u(comp, 7), comp));
		assert(!value::compare(u(comp, 5), GT, u(comp, 7), comp));
		assert(value::compare(i(comp, -1), LT, value::ZERO, comp));
		assert(value::compare(u(comp, 5), EQ, i(comp, 5), comp));
		assert(value::compare(u(comp, 5), LTE, u(comp, 5), comp));
		assert(value::compare(u(comp, 5), GTE, u(comp, 5), comp));
		assert(!value::compare(u(comp, 5), NEQ, u(comp, 5), comp));
		assert(value::compare(u(comp, 5), NEQ, u(comp, 6), comp));
		assert(value::compare(pow2(comp, 200), GT, u(comp, ulong::max), comp));
		assert(value::compare(pow2(comp, 200, false), LT, i(comp, long::min), comp));
		assert(value::compare(pow2(comp, 200, false), LT, pow2(comp, 199, false), comp));
		// fixture enum overflow linux: G == 9223372036854775808ULL (big vs u64 forms).
		assert(value::compare(pow2(comp, 63), EQ, u(comp, ((ulong)1) << 63), comp));
	};
}

fn void min_max_int() @test
{
	@with_comp(; Compilation* comp)
	{
		expect(comp, value::min_int(type_store::INT, comp), i(comp, -2147483648));
		expect(comp, value::max_int(type_store::INT, comp), i(comp, 2147483647));
		expect(comp, value::min_int(type_store::UINT, comp), value::ZERO);
		expect(comp, value::max_int(type_store::UINT, comp), u(comp, 0xFFFF_FFFF));
		expect(comp, value::min_int(type_store::SCHAR, comp), i(comp, -128));
		expect(comp, value::max_int(type_store::UCHAR, comp), u(comp, 255));
		expect(comp, value::min_int(type_store::SHORT, comp), i(comp, -32768));
		expect(comp, value::min_int(type_store::LONG, comp), i(comp, long::min));
		expect(comp, value::max_int(type_store::LONG, comp), i(comp, long::max));
		expect(comp, value::max_int(type_store::ULONG, comp), u(comp, ulong::max));
		expect(comp, value::min_int(type_store::INT128, comp), pow2(comp, 127, false));
		expect(comp, value::max_int(type_store::UINT128, comp), ones(comp, 128));
		// _BitInt widths that are not 8/16/32/64 go through setTwosCompIntLimit.
		expect(comp, value::min_int(bit_int(comp, 17, SIGNED), comp), i(comp, -65536));
		expect(comp, value::max_int(bit_int(comp, 17, SIGNED), comp), u(comp, 65535));
		expect(comp, value::max_int(bit_int(comp, 1, UNSIGNED), comp), value::ONE);
		expect(comp, value::min_int(bit_int(comp, 256, SIGNED), comp), pow2(comp, 255, false));
		expect(comp, value::max_int(bit_int(comp, 256, SIGNED), comp), ones(comp, 255));
		expect(comp, value::max_int(bit_int(comp, 200, UNSIGNED), comp), ones(comp, 200));
		expect(comp, value::min_int(bit_int(comp, 200, UNSIGNED), comp), value::ZERO);
	};
}

// ---------------------------------------------------------------------------
// Pointer constants
// ---------------------------------------------------------------------------

fn void pointers() @test
{
	@with_comp(; Compilation* comp)
	{
		QualType int_ptr = comp.type_store.put(type_store::type_pointer(type_store::INT));
		InternerRef zero_ref = value::ZERO.ref();
		Value p = value::pointer({ .node = 1, .offset = zero_ref }, comp);
		Value p4 = value::pointer({ .node = 1, .offset = u(comp, 4).ref() }, comp);
		Value q = value::pointer({ .node = 2, .offset = zero_ref }, comp);

		// Distinct bases are distinct identities; same base and offset dedups.
		assert(p.opt_ref != q.opt_ref);
		assert(p.opt_ref != p4.opt_ref);
		assert(p.opt_ref == value::pointer({ .node = 1, .offset = zero_ref }, comp).opt_ref);
		assert(p.is_pointer(comp) && !u(comp, 1).is_pointer(comp) && !value::NONE.is_pointer(comp));
		assert(!p.is_zero(comp), "an address constant is not zero");
		assert(!p.is_arithmetic(comp));
		Value c = p;
		assert(c.int_cast(type_store::INT, comp) == NONE);
		assert(c.opt_ref == p.opt_ref, "int_cast leaves pointers alone");

		// compare_pointers.
		assert(value::compare_pointers(p, LT, p4, comp)!!);
		assert(!value::compare_pointers(p, GT, p4, comp)!!);
		assert(value::compare_pointers(p, EQ, p, comp)!!);
		assert(value::compare_pointers(p, LTE, p, comp)!!);
		assert(!value::compare_pointers(p, EQ, q, comp)!!);
		assert(value::compare_pointers(p, NEQ, q, comp)!!);
		assert(@catch(value::compare_pointers(p, LT, q, comp)) == value::NOT_COMPARABLE);
		assert(@catch(value::compare_pointers(p, GTE, q, comp)) == value::NOT_COMPARABLE);
		assert(@catch(value::compare_pointers(p, LT, u(comp, 5), comp)) == value::NOT_COMPARABLE);

		// p + 3 (int *): offset 12 bytes, same node; 3 + p is the same.
		Value r = value::NONE;
		assert(!r.add(p, u(comp, 3), int_ptr, comp));
		expect(comp, r, value::pointer({ .node = 1, .offset = u(comp, 12).ref() }, comp));
		assert(!r.add(u(comp, 3), p, int_ptr, comp));
		expect(comp, r, value::pointer({ .node = 1, .offset = u(comp, 12).ref() }, comp));
		// p4 + (-1) is back at p (pointer dedup by offset value).
		assert(!r.add(p4, i(comp, -1), int_ptr, comp));
		expect(comp, r, p);
		// void * arithmetic scales by 1 (sizeof unknown -> 1).
		assert(!r.add(p, u(comp, 3), type_store::VOID_POINTER, comp));
		expect(comp, r, value::pointer({ .node = 1, .offset = u(comp, 3).ref() }, comp));

		// fixture pointer subtraction: `&c[1] - &c[0]` for char is 1.
		Value c1 = value::pointer({ .node = 7, .offset = value::ONE.ref() }, comp);
		Value c0 = value::pointer({ .node = 7, .offset = zero_ref }, comp);
		assert(!r.sub(c1, c0, type_store::CHAR_POINTER, comp, 1));
		expect(comp, r, value::ONE);
		// p4 - p for int * (elem size 4) is 1; p - p4 is -1.
		assert(!r.sub(p4, p, int_ptr, comp, 4));
		expect(comp, r, value::ONE);
		assert(!r.sub(p, p4, int_ptr, comp, 4));
		expect(comp, r, i(comp, -1));
		// Different bases: unknown.
		r = value::ONE;
		assert(!r.sub(p, q, int_ptr, comp, 4));
		assert(r.is_none());
		// p4 - 1 (int *): back at p.
		assert(!r.sub(p4, value::ONE, int_ptr, comp, 4));
		expect(comp, r, p);

		// Offsets wrap in ptrdiff_t (long): node + LONG_MAX elements of 4 bytes overflows.
		assert(r.add(p, i(comp, long::max), int_ptr, comp));
		Value off = r.is_pointer(comp) ? value::from_ref(comp.interner.get(r.ref()).pointer.offset) : value::NONE;
		expect(comp, off, i(comp, -4), "LONG_MAX * 4 wraps to -4 in ptrdiff_t");
	};
}
