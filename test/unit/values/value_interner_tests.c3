// Unit tests for src/value_interner.c3 (port of src/backend/Interner.zig).
//
// Expected values are source-derived from Interner.zig (no Zig executable ran):
// static refs from Key.toRef/Interner.get, storage tags and `extra` layout from
// Interner.put/addExtra and the Tag.* pack functions, dense insertion-order refs
// from AutoArrayHashMap indices. Integer keys use limb arrays directly so these
// tests do not depend on bigint arithmetic.
module value_interner_tests;
import std, aro::value_interner, aro::bigint;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

struct Fixture
{
	TrackingAllocator ta;
	Interner in;
}

fn void Fixture.init(&self)
{
	self.ta.init(mem);
	self.in.init(&self.ta);
}

fn void Fixture.free(&self)
{
	self.in.free();
	check(self.ta.allocation_count(), 0);
	self.ta.free();
}

<* A raw int key over `limbs` (not normalized, so tests can feed padded input). *>
fn InternerKey big(Limb[] limbs, bool positive) => { .tag = positive ? InternerKeyTag.INT_POSITIVE : InternerKeyTag.INT_NEGATIVE, .limbs = limbs };

fn InternerKey fl16(ushort b) => value_interner::float_key(F16, b);
fn InternerKey fl32(uint b) => value_interner::float_key(F32, b);
fn InternerKey fl64(ulong b) => value_interner::float_key(F64, b);
fn InternerKey fl80(ulong lo, ushort hi) => value_interner::float_key(F80, (uint128)hi << 64 | lo);
fn InternerKey fl128(ulong lo, ulong hi) => value_interner::float_key(F128, (uint128)hi << 64 | lo);
fn InternerKey cx(InternerKey re, InternerKey im) => value_interner::complex_key(re, im);

<* Round trip: put, get, and the result equals the key and re-puts to the same ref. *>
fn InternerRef round_trip(Interner* in, InternerKey key)
{
	InternerRef r = in.put(key);
	InternerKey got = in.get(r);
	assert(got.eql(key), "round trip changed the key");
	check(in.put(got), r);
	return r;
}

fn void static_refs() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	check(in.put({ .tag = INT_TY, .ty_bits = 1 }), value_interner::REF_I1);
	check(in.put({ .tag = INT_TY, .ty_bits = 8 }), value_interner::REF_I8);
	check(in.put({ .tag = INT_TY, .ty_bits = 16 }), value_interner::REF_I16);
	check(in.put({ .tag = INT_TY, .ty_bits = 32 }), value_interner::REF_I32);
	check(in.put({ .tag = INT_TY, .ty_bits = 64 }), value_interner::REF_I64);
	check(in.put({ .tag = INT_TY, .ty_bits = 128 }), value_interner::REF_I128);
	check(in.put({ .tag = FLOAT_TY, .ty_bits = 16 }), value_interner::REF_F16);
	check(in.put({ .tag = FLOAT_TY, .ty_bits = 32 }), value_interner::REF_F32);
	check(in.put({ .tag = FLOAT_TY, .ty_bits = 64 }), value_interner::REF_F64);
	check(in.put({ .tag = FLOAT_TY, .ty_bits = 80 }), value_interner::REF_F80);
	check(in.put({ .tag = FLOAT_TY, .ty_bits = 128 }), value_interner::REF_F128);
	check(in.put({ .tag = COMPLEX_TY, .ty_bits = 16 }), value_interner::REF_CF16);
	check(in.put({ .tag = COMPLEX_TY, .ty_bits = 32 }), value_interner::REF_CF32);
	check(in.put({ .tag = COMPLEX_TY, .ty_bits = 64 }), value_interner::REF_CF64);
	check(in.put({ .tag = COMPLEX_TY, .ty_bits = 80 }), value_interner::REF_CF80);
	check(in.put({ .tag = COMPLEX_TY, .ty_bits = 128 }), value_interner::REF_CF128);
	check(in.put({ .tag = PTR_TY }), value_interner::REF_PTR);
	check(in.put({ .tag = NORETURN_TY }), value_interner::REF_NORETURN);
	check(in.put({ .tag = VOID_TY }), value_interner::REF_VOID);
	check(in.put({ .tag = FUNC_TY }), value_interner::REF_FUNC);
	check(in.put({ .tag = NULL }), value_interner::REF_NULL);
	check(in.len(), 0);

	// Every static ref except CF128 maps back to its key (Interner.get).
	InternerRef[*] statics = { value_interner::REF_PTR, value_interner::REF_NORETURN, value_interner::REF_VOID, value_interner::REF_I1, value_interner::REF_I8, value_interner::REF_I16, value_interner::REF_I32,
		value_interner::REF_I64, value_interner::REF_I128, value_interner::REF_F16, value_interner::REF_F32, value_interner::REF_F64, value_interner::REF_F80, value_interner::REF_F128, value_interner::REF_FUNC, value_interner::REF_NULL,
		value_interner::REF_CF16, value_interner::REF_CF32, value_interner::REF_CF64, value_interner::REF_CF80 };
	foreach (r : statics)
	{
		test::eq(r.is_static(), true);
		check(in.put(in.get(r)), r);
	}
	check(in.len(), 0);
	f.free();
}

fn void zero_and_one() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	Limb[1] zero = { 0 };
	Limb[1] one = { 1 };
	check(in.put(value_interner::int_key(0)), value_interner::REF_ZERO);
	check(in.put(value_interner::int_key(0)), value_interner::REF_ZERO);
	check(in.put(big(&zero, true)), value_interner::REF_ZERO);
	check(in.put(value_interner::int_key(1)), value_interner::REF_ONE);
	check(in.put(value_interner::int_key(1)), value_interner::REF_ONE);
	check(in.put(big(&one, true)), value_interner::REF_ONE);
	// -1 is not one.
	InternerRef m1 = in.put(value_interner::int_key(-1));
	test::eq(m1.is_static(), false);
	check(in.put(big(&one, false)), m1);

	// Positive zero and 1.0 of every width map to the int static refs.
	check(in.put(fl16(0)), value_interner::REF_ZERO);
	check(in.put(fl32(0)), value_interner::REF_ZERO);
	check(in.put(fl64(0)), value_interner::REF_ZERO);
	check(in.put(fl80(0, 0)), value_interner::REF_ZERO);
	check(in.put(fl128(0, 0)), value_interner::REF_ZERO);
	check(in.put(fl16(0x3C00)), value_interner::REF_ONE);
	check(in.put(fl32(0x3F80_0000)), value_interner::REF_ONE);
	check(in.put(fl64(0x3FF0_0000_0000_0000)), value_interner::REF_ONE);
	check(in.put(fl80(0x8000_0000_0000_0000, 0x3FFF)), value_interner::REF_ONE);
	check(in.put(fl128(0, 0x3FFF_0000_0000_0000)), value_interner::REF_ONE);
	check(in.len(), 1);

	// Zig quirk: get(value_interner::REF_ONE) / get(value_interner::REF_ZERO) are the *ints*.
	InternerKey k = in.get(value_interner::REF_ONE);
	check(k.tag, InternerKeyTag.INT_POSITIVE);
	check(k.limbs.len, 1);
	check(k.limbs[0], 1);
	k = in.get(value_interner::REF_ZERO);
	check(k.tag, InternerKeyTag.INT_POSITIVE);
	// Zig-normalized zero: one zero limb.
	check(k.limbs.len, 1);
	check(k.limbs[0], 0);

	// Negative zero floats are not static.
	InternerRef nz = in.put(fl32(0x8000_0000));
	test::eq(nz.is_static(), false);
	InternerRef nz80 = in.put(fl80(0, 0x8000));
	test::eq(nz80.is_static(), false);
	test::eq(nz != nz80, true);
	// Complex zero is not static.
	InternerKey cz = cx(fl32(0), fl32(0));
	test::eq(in.put(cz).is_static(), false);
	f.free();
}

fn void deduplication() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	InternerRef a = in.put({ .tag = INT_TY, .ty_bits = 7 });
	InternerRef b = in.put({ .tag = INT_TY, .ty_bits = 24 });
	check(a, 0);
	check(b, 1);
	check(in.put({ .tag = INT_TY, .ty_bits = 7 }), a);
	check(in.put({ .tag = INT_TY, .ty_bits = 24 }), b);
	check(in.len(), 2);

	// Ints dedupe by value across u64 / i64 / big_int forms.
	Limb[1] five = { 5 };
	InternerRef r5 = in.put(value_interner::int_key(5));
	check(r5, 2);
	check(in.put(value_interner::int_key(5)), r5);
	check(in.put(big(&five, true)), r5);
	Limb[2] five_padded = { 5, 0 }; // non-normalized input still dedupes
	check(in.put(big(&five_padded, true)), r5);
	InternerRef rm5 = in.put(big(&five, false));
	check(in.put(value_interner::int_key(-5)), rm5);
	test::eq(rm5 != r5, true);

	ulong two32 = 0x1_0000_0000;
	Limb[1] l32 = { two32 };
	InternerRef r32 = in.put(value_interner::int_key(two32));
	check(in.put(value_interner::int_key((long)two32)), r32);
	check(in.put(big(&l32, true)), r32);

	// Bytes, records, aggregates.
	char[*] s1 = "hello";
	char[*] s2 = "hello";
	InternerRef hb = in.put({ .tag = BYTES, .bytes = &s1 });
	check(in.put({ .tag = BYTES, .bytes = &s2 }), hb);
	test::eq(in.put({ .tag = BYTES, .bytes = "hellp" }) != hb, true);
	test::eq(in.put({ .tag = BYTES, .bytes = "hell" }) != hb, true);
	InternerRef[3] e1 = { value_interner::REF_I8, value_interner::REF_I32, a };
	InternerRef[3] e2 = { value_interner::REF_I8, value_interner::REF_I32, a };
	InternerRef rt = in.put({ .tag = RECORD_TY, .record_ty = &e1 });
	check(in.put({ .tag = RECORD_TY, .record_ty = &e2 }), rt);
	test::eq(in.put({ .tag = RECORD_TY, .record_ty = e1[:2] }) != rt, true);
	InternerRef at = in.put({ .tag = ARRAY_TY, .array_ty = { .len = 10, .child = value_interner::REF_I8 } });
	check(in.put({ .tag = ARRAY_TY, .array_ty = { .len = 10, .child = value_interner::REF_I8 } }), at);
	test::eq(in.put({ .tag = ARRAY_TY, .array_ty = { .len = 10, .child = value_interner::REF_I16 } }) != at, true);
	test::eq(in.put({ .tag = ARRAY_TY, .array_ty = { .len = 11, .child = value_interner::REF_I8 } }) != at, true);
	InternerRef vt = in.put({ .tag = VECTOR_TY, .vector_ty = { .len = 4, .child = value_interner::REF_F32 } });
	check(in.put({ .tag = VECTOR_TY, .vector_ty = { .len = 4, .child = value_interner::REF_F32 } }), vt);
	// Different key tags with "same" payload do not collide.
	test::eq(in.put({ .tag = VECTOR_TY, .vector_ty = { .len = 10, .child = value_interner::REF_I8 } }) != at, true);

	// Floats dedupe by bits; NaNs never dedupe (Zig compares floats with ==).
	InternerRef h = in.put(fl64(0x4000_0000_0000_0000));
	check(in.put(fl64(0x4000_0000_0000_0000)), h);
	test::eq(in.put(fl32(0x4000_0000)) != h, true);
	sz before = in.len();
	InternerRef n1 = in.put(fl32(0x7FC0_0000));
	InternerRef n2 = in.put(fl32(0x7FC0_0000));
	test::eq(n1 != n2, true);
	check(in.len(), before + 2);
	InternerKey cn = cx(fl64(0x3FF0_0000_0000_0000), fl64(0x7FF8_0000_0000_0000));
	test::eq(in.put(cn) != in.put(cn), true);
	f.free();
}

fn void hash_eql_consistency() @test
{
	Limb[1] five = { 5 };
	InternerKey[*] same = { value_interner::int_key(5), value_interner::int_key(5), big(&five, true) };
	foreach (k : same)
	{
		test::eq(k.eql(same[0]), true);
		check(k.hash(), same[0].hash());
	}
	Limb[1] min_mag = { 0x8000_0000_0000_0000 };
	InternerKey lmin = value_interner::int_key(long::min);
	InternerKey bmin = big(&min_mag, false);
	test::eq(lmin.eql(bmin), true);
	check(lmin.hash(), bmin.hash());
	test::eq(value_interner::int_key(0x8000_0000_0000_0000).eql(lmin), false);
	test::eq(value_interner::int_key(5).eql({ .tag = INT_TY, .ty_bits = 5 }), false);
	test::eq((value_interner::InternerKey){ .tag = BYTES, .bytes = "ab" }.eql({ .tag = BYTES, .bytes = "ab" }), true);
	check((value_interner::InternerKey){ .tag = BYTES, .bytes = "abcdefghij" }.hash(), (value_interner::InternerKey){ .tag = BYTES, .bytes = "abcdefghij" }.hash());
	test::eq((value_interner::InternerKey){ .tag = POINTER, .pointer = { .node = 3, .offset = value_interner::REF_ZERO } }.eql({ .tag = POINTER, .pointer = { .node = 3, .offset = value_interner::REF_ZERO } }), true);
	test::eq((value_interner::InternerKey){ .tag = POINTER, .pointer = { .node = 3, .offset = value_interner::REF_ZERO } }.eql({ .tag = POINTER, .pointer = { .node = 4, .offset = value_interner::REF_ZERO } }), false);

	// to_big_int forms.
	BigIntConst c = value_interner::int_key(long::min).to_big_int();
	check(c.limbs.len, 1);
	test::eq(c.limbs[0] == 0x8000_0000_0000_0000, true);
	test::eq(c.positive, false);
	c = value_interner::int_key(ulong::max).to_big_int();
	test::eq(c.limbs[0] == ulong::max, true);
	test::eq(c.positive, true);
	c = value_interner::int_key(-3).to_big_int();
	check(c.limbs[0], 3);
	test::eq(c.positive, false);
	c = big(&five, false).to_big_int();
	test::eq(c.limbs.ptr == &five[0], true);
}

fn void key_int_helpers() @test
{
	test::eq(value_interner::int_key(5).tag == InternerKeyTag.INT_POSITIVE, true);
	test::eq(value_interner::int_key(-5).tag == InternerKeyTag.INT_NEGATIVE, true);
	test::eq(value_interner::int_key(ulong::max).limbs[0] == ulong::max, true);
	test::eq(value_interner::int_key(long::min).limbs[0] == 0x8000_0000_0000_0000, true);
	test::eq(value_interner::int_key(0).int_is_zero(), true);
	test::eq(value_interner::int_key(-1).int_is_zero(), false);
	test::eq(value_interner::big_int_key({ .limbs = {}, .positive = true }).int_is_zero(), true);
	// int128 values wider than 64 bits take two limbs.
	InternerKey wide = value_interner::int_key(-((int128)1 << 64) - 3);
	check(wide.limbs.len, 2);
	check(wide.limbs[0], 3);
	check(wide.limbs[1], 1);
	test::eq(wide.tag == InternerKeyTag.INT_NEGATIVE, true);

	// 64-bit views.
	test::eq(value_interner::int_key(-1).int_fits_64(), true);
	test::eq(value_interner::int_key(-1).int_low_u64() == ulong::max, true);
	test::eq(value_interner::int_key(long::min).int_fits_64(), true);
	test::eq(value_interner::int_key((int128)long::min - 1).int_fits_64(), false);
	test::eq(value_interner::int_key(ulong::max).int_fits_64(), true);
	test::eq(value_interner::uint_key((uint128)1 << 64).int_fits_64(), false);

	Limb[2] two64 = { 0, 1 }; // 2^64
	test::eq(string::tformat("%s", value_interner::int_key(-42)), "-42");
	test::eq(string::tformat("%s", value_interner::int_key(ulong::max)), "18446744073709551615");
	test::eq(string::tformat("%s", value_interner::big_int_key({ .limbs = &two64, .positive = false })), "-18446744073709551616");
}

fn void int_storage_forms() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;

	// Every non-static int is stored as owned limbs, tagged by sign.
	InternerRef r = in.put(value_interner::int_key(0xFFFF_FFFF));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.INT_POSITIVE);
	InternerKey k = in.get(r);
	check(k.limbs.len, 1);
	test::eq(k.limbs[0] == 0xFFFF_FFFF, true);

	r = in.put(value_interner::int_key(-0x8000_0000));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.INT_NEGATIVE);
	k = in.get(r);
	check(k.limbs[0], 0x8000_0000);
	test::eq(k.to_big_int().positive, false);

	r = in.put(value_interner::int_key(0x1_0000_0000));
	k = in.get(r);
	check(k.tag, InternerKeyTag.INT_POSITIVE);
	check(k.limbs.len, 1);
	test::eq(k.limbs[0] == 0x1_0000_0000, true);

	r = in.put(value_interner::int_key(long::min));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.INT_NEGATIVE);
	test::eq(in.get(r).limbs[0] == 0x8000_0000_0000_0000, true);

	// Small values given as raw limbs dedupe with int_key.
	Limb[1] small = { 0xFFFF_FFFF };
	check(in.put(big(&small, true)), in.put(value_interner::int_key(0xFFFF_FFFF)));
	Limb[1] smin = { 0x8000_0000 };
	check(in.put(big(&smin, false)), in.put(value_interner::int_key(-0x8000_0000)));
	// Negative zero is zero.
	Limb[1] zero = { 0 };
	check(in.put(big(&zero, false)), value_interner::REF_ZERO);

	// Multi-limb (>128-bit) values round trip; limbs stored normalized, sign kept.
	Limb[3] wide = { 1, 2, 0x8000_0000_0000_0000 };
	InternerRef pw = round_trip(in, big(&wide, true));
	InternerRef nw = round_trip(in, big(&wide, false));
	test::eq(pw != nw, true);
	check(in.items[(sz)(uint)pw].tag, InternerKeyTag.INT_POSITIVE);
	check(in.items[(sz)(uint)nw].tag, InternerKeyTag.INT_NEGATIVE);
	k = in.get(nw);
	check(k.limbs.len, 3);
	test::eq(k.limbs[2] == 0x8000_0000_0000_0000, true);
	Limb[5] wide_padded = { 1, 2, 0x8000_0000_0000_0000, 0, 0 };
	check(in.put(big(&wide_padded, true)), pw);
	check(in.get(in.put(big(&wide_padded, false))).limbs.len, 3);
	// item.data indexes the owned limb slices.
	uint d = in.items[(sz)(uint)pw].data;
	check(in.limbs[(sz)d].len, 3);
	f.free();
}

fn void every_key_tag_round_trip() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;

	InternerRef r = round_trip(in, { .tag = INT_TY, .ty_bits = 24 });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.INT_TY);
	check(in.items[(sz)(uint)r].data, 24);
	// float_ty / complex_ty only accept the static widths (Zig `toRef` else => unreachable).

	// Array: PackedU64 split of len, low half first.
	r = round_trip(in, { .tag = ARRAY_TY, .array_ty = { .len = 0x1_2345_6789_ABCD, .child = value_interner::REF_I8 } });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.ARRAY_TY);
	uint d = in.items[(sz)(uint)r].data;
	test::eq(in.extra[(sz)d] == 0x6789_ABCD, true);
	check(in.extra[(sz)d + 1], 0x1_2345);
	check(in.extra[(sz)d + 2], value_interner::REF_I8);
	test::eq(in.get(r).array_ty.len == 0x1_2345_6789_ABCD, true);
	round_trip(in, { .tag = ARRAY_TY, .array_ty = { .len = ulong::max, .child = r } });

	r = round_trip(in, { .tag = VECTOR_TY, .vector_ty = { .len = 0xFFFF_FFFF, .child = value_interner::REF_F64 } });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.VECTOR_TY);
	check(in.get(r).vector_ty.child, value_interner::REF_F64);

	InternerRef[4] elems = { value_interner::REF_I8, value_interner::REF_PTR, r, value_interner::REF_I8 };
	r = round_trip(in, { .tag = RECORD_TY, .record_ty = &elems });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.RECORD_TY);
	check(in.get(r).record_ty.len, 4);
	check(in.get(r).record_ty[2], elems[2]);
	InternerRef empty_rec = round_trip(in, { .tag = RECORD_TY, .record_ty = {} });
	check(in.get(empty_rec).record_ty.len, 0);

	r = round_trip(in, { .tag = BYTES, .bytes = "abc\0def" });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.BYTES);
	check(in.get(r).bytes.len, 7);
	InternerRef empty_bytes = round_trip(in, { .tag = BYTES, .bytes = "" });
	test::eq(empty_bytes != empty_rec, true);
	check(in.get(empty_bytes).bytes.len, 0);

	r = round_trip(in, { .tag = POINTER, .pointer = { .node = 42, .offset = value_interner::REF_ONE } });
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.POINTER);
	check(in.get(r).pointer.node, 42);
	check(in.get(r).pointer.offset, value_interner::REF_ONE);

	round_trip(in, value_interner::int_key(-123456));
	round_trip(in, value_interner::int_key(ulong::max));

	// Floats: every width, bit patterns preserved exactly.
	r = round_trip(in, fl16(0xC000));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.F16);
	check(in.limbs[(sz)in.items[(sz)(uint)r].data][0], 0xC000);
	r = round_trip(in, fl32(0x4049_0FDB));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.F32);
	r = round_trip(in, fl64(0x4009_21FB_5444_2D18));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.F64);
	d = in.items[(sz)(uint)r].data;
	check(in.limbs[(sz)d].len, 1);
	test::eq(in.limbs[(sz)d][0] == 0x4009_21FB_5444_2D18, true);
	r = round_trip(in, fl80(0xC90F_DAA2_2168_C235, 0xC000));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.F80);
	d = in.items[(sz)(uint)r].data;
	check(in.limbs[(sz)d].len, 2);
	check(in.limbs[(sz)d][1], 0xC000);
	InternerKey g = in.get(r);
	check(g.tag, InternerKeyTag.F80);
	test::eq(g.f80().lo == 0xC90F_DAA2_2168_C235, true);
	check(g.f80().hi, 0xC000);
	r = round_trip(in, fl128(0x8469_898C_C517_01B8, 0x4000_921F_B544_42D1));
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.F128);
	g = in.get(r);
	test::eq(g.f128().lo == 0x8469_898C_C517_01B8 && g.f128().hi == 0x4000_921F_B544_42D1, true);
	// Same bits in different widths are different keys.
	test::eq(in.put(fl16(0x4000)) != in.put(fl32(0x4000)), true);

	// Complex: every width.
	InternerKey c16 = cx(fl16(0x3C00), fl16(0xC000));
	r = round_trip(in, c16);
	check(in.items[(sz)(uint)r].tag, InternerKeyTag.CF16);
	// Real component's limbs first, then the imaginary's.
	Limb[] cl = in.limbs[(sz)in.items[(sz)(uint)r].data];
	check(cl.len, 2);
	check(cl[0], 0x3C00);
	check(cl[1], 0xC000);
	InternerKey c32 = cx(fl32(0x3F80_0000), fl32(0x4000_0000));
	r = round_trip(in, c32);
	check(in.get(r).im().f32(), 0x4000_0000);
	InternerKey c64 = cx(fl64(0x3FF0_0000_0000_0001), fl64(0xBFF0_0000_0000_0002));
	r = round_trip(in, c64);
	d = in.items[(sz)(uint)r].data;
	test::eq(in.limbs[(sz)d][1] == 0xBFF0_0000_0000_0002, true);
	InternerKey c80 = cx(fl80(0x8000_0000_0000_0001, 0x3FFF), fl80(0xC000_0000_0000_0000, 0xBFFE));
	r = round_trip(in, c80);
	d = in.items[(sz)(uint)r].data;
	check(in.limbs[(sz)d].len, 4);
	check(in.limbs[(sz)d][1], 0x3FFF);
	check(in.limbs[(sz)d][3], 0xBFFE);
	InternerKey g80 = in.get(r);
	test::eq(g80.im().f80().lo == 0xC000_0000_0000_0000, true);
	InternerKey c128 = cx(fl128(1, 0x3FFF_0000_0000_0000), fl128(2, 0x8000_0000_0000_0003));
	r = round_trip(in, c128);
	InternerKey g128 = in.get(r);
	test::eq(g128.re().f128().lo == 1 && g128.im().f128().hi == 0x8000_0000_0000_0003, true);
	d = in.items[(sz)(uint)r].data;
	check(in.limbs[(sz)d][2], 2);
	test::eq(in.limbs[(sz)d][3] == 0x8000_0000_0000_0003, true);
	f.free();
}

fn void distinct_pointer_bases() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	InternerRef p1 = in.put({ .tag = POINTER, .pointer = { .node = 1, .offset = value_interner::REF_ZERO } });
	InternerRef p2 = in.put({ .tag = POINTER, .pointer = { .node = 2, .offset = value_interner::REF_ZERO } });
	test::eq(p1 != p2, true);
	InternerRef off8 = in.put(value_interner::int_key(8));
	InternerRef p1_8 = in.put({ .tag = POINTER, .pointer = { .node = 1, .offset = off8 } });
	InternerRef p2_8 = in.put({ .tag = POINTER, .pointer = { .node = 2, .offset = off8 } });
	test::eq(p1_8 != p1, true);
	test::eq(p1_8 != p2_8, true);
	check(in.put({ .tag = POINTER, .pointer = { .node = 1, .offset = value_interner::REF_ZERO } }), p1);
	check(in.put({ .tag = POINTER, .pointer = { .node = 2, .offset = in.put(value_interner::int_key(8)) } }), p2_8);
	// Node 0 is an ordinary base, distinct from the null constant and from int zero.
	InternerRef p0 = in.put({ .tag = POINTER, .pointer = { .node = 0, .offset = value_interner::REF_ZERO } });
	test::eq(p0 != value_interner::REF_NULL && p0 != value_interner::REF_ZERO, true);
	check(in.get(p2_8).pointer.node, 2);
	check(in.get(p2_8).pointer.offset, off8);
	f.free();
}

fn void slices_stable_across_growth() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;

	char[*] text = "constant string";
	InternerRef sref = in.put({ .tag = BYTES, .bytes = &text });
	Limb[3] wide = { 7, 8, 9 };
	InternerRef wref = in.put(big(&wide, false));
	InternerRef[2] elems = { value_interner::REF_I32, value_interner::REF_I64 };
	InternerRef rref = in.put({ .tag = RECORD_TY, .record_ty = &elems });

	// The interner copied the key slices: mutating the caller's buffers changes nothing.
	text[0] = 'X';
	wide[0] = 99;
	elems[0] = value_interner::REF_F32;

	String s = (String)in.get(sref).bytes;
	Limb[] l = in.get(wref).limbs;
	InternerRef[] e = in.get(rref).record_ty;
	test::eq(s, "constant string");
	check(l[0], 7);
	check(e[0], value_interner::REF_I32);

	// Grow every container (items, extra, limbs, strings, records, table) a lot.
	char[16] buf;
	for (uint i = 0; i < 5000; i++)
	{
		in.put({ .tag = INT_TY, .ty_bits = (ushort)(200 + i % 60000) });
		in.put(value_interner::int_key((int128)0x1_0000_0000 + i));
		Limb[2] li = { i, 1 };
		in.put(big(&li, true));
		for (int j = 0; j < 8; j++) buf[j] = (char)('a' + (i >> (4 * j)) % 16);
		in.put({ .tag = BYTES, .bytes = buf[:8] });
		InternerRef[1] one = { (InternerRef)i };
		in.put({ .tag = RECORD_TY, .record_ty = &one });
		in.put(fl64(0x4000_0000_0000_0000 + (ulong)i));
	}
	// Same slices (same addresses) still valid and unchanged.
	test::eq(s.ptr == in.get(sref).bytes.ptr, true);
	test::eq(l.ptr == in.get(wref).limbs.ptr, true);
	test::eq(e.ptr == in.get(rref).record_ty.ptr, true);
	test::eq(s, "constant string");
	check(l[0], 7);
	check(l[2], 9);
	check(e[1], value_interner::REF_I64);

	// Dedup still works after rehashing, and refs are dense in insertion order.
	check(in.put({ .tag = BYTES, .bytes = "constant string" }), sref);
	check(in.put({ .tag = INT_TY, .ty_bits = 200 }), 3);
	sz n = in.len();
	for (uint i = 0; i < 5000; i++)
	{
		Limb[2] li = { i, 1 };
		in.put(big(&li, true));
		in.put(value_interner::int_key((int128)0x1_0000_0000 + i));
	}
	check(in.len(), n);
	f.free();
}

fn void leak_checks() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	for (int round = 0; round < 20; round++)
	{
		Interner in;
		in.init(&ta);
		Limb[3] wide = { 1, 2, 3 };
		InternerRef[2] elems = { value_interner::REF_I8, value_interner::REF_I16 };
		for (int i = 0; i < round * 7; i++)
		{
			in.put(big(&wide, i % 2 == 0));
			in.put({ .tag = BYTES, .bytes = "leak" });
			in.put({ .tag = RECORD_TY, .record_ty = &elems });
			in.put({ .tag = RECORD_TY, .record_ty = {} });
			in.put({ .tag = BYTES, .bytes = "" });
			in.put(value_interner::int_key((int128)0x1_0000_0000 * (int128)(i + 1)));
			in.put(fl32(0x7FC0_0000)); // NaN: a new entry each time
			InternerKey c = cx(fl128((ulong)i, 0), fl128(0, 1));
			in.put(c);
		}
		in.free();
		check(ta.allocation_count(), 0);
	}
	// An interner that was never used frees cleanly too.
	Interner idle;
	idle.init(&ta);
	idle.free();
	check(ta.allocation_count(), 0);
	ta.free();
}
