// Unit tests for src/c3/value_interner.c3 (port of src/backend/Interner.zig).
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

fn InternerKey big(Limb[] limbs, bool positive) => value_interner::key_big_int({ .limbs = limbs, .positive = positive });

fn KeyFloat fl16(ushort b) => { .tag = F16, .f16 = b };
fn KeyFloat fl32(uint b) => { .tag = F32, .f32 = b };
fn KeyFloat fl64(ulong b) => { .tag = F64, .f64 = b };
fn KeyFloat fl80(ulong lo, ushort hi) => { .tag = F80, .f80 = { .lo = lo, .hi = hi } };
fn KeyFloat fl128(ulong lo, ulong hi) => { .tag = F128, .f128 = { .lo = lo, .hi = hi } };

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
	check(in.put(value_interner::key_int_ty(1)), value_interner::REF_I1);
	check(in.put(value_interner::key_int_ty(8)), value_interner::REF_I8);
	check(in.put(value_interner::key_int_ty(16)), value_interner::REF_I16);
	check(in.put(value_interner::key_int_ty(32)), value_interner::REF_I32);
	check(in.put(value_interner::key_int_ty(64)), value_interner::REF_I64);
	check(in.put(value_interner::key_int_ty(128)), value_interner::REF_I128);
	check(in.put(value_interner::key_float_ty(16)), value_interner::REF_F16);
	check(in.put(value_interner::key_float_ty(32)), value_interner::REF_F32);
	check(in.put(value_interner::key_float_ty(64)), value_interner::REF_F64);
	check(in.put(value_interner::key_float_ty(80)), value_interner::REF_F80);
	check(in.put(value_interner::key_float_ty(128)), value_interner::REF_F128);
	check(in.put(value_interner::key_complex_ty(16)), value_interner::REF_CF16);
	check(in.put(value_interner::key_complex_ty(32)), value_interner::REF_CF32);
	check(in.put(value_interner::key_complex_ty(64)), value_interner::REF_CF64);
	check(in.put(value_interner::key_complex_ty(80)), value_interner::REF_CF80);
	check(in.put(value_interner::key_complex_ty(128)), value_interner::REF_CF128);
	check(in.put(value_interner::key_simple(PTR_TY)), value_interner::REF_PTR);
	check(in.put(value_interner::key_simple(NORETURN_TY)), value_interner::REF_NORETURN);
	check(in.put(value_interner::key_simple(VOID_TY)), value_interner::REF_VOID);
	check(in.put(value_interner::key_simple(FUNC_TY)), value_interner::REF_FUNC);
	check(in.put(value_interner::key_simple(NULL)), value_interner::REF_NULL);
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
	check(in.put(value_interner::key_u64(0)), value_interner::REF_ZERO);
	check(in.put(value_interner::key_i64(0)), value_interner::REF_ZERO);
	check(in.put(big(&zero, true)), value_interner::REF_ZERO);
	check(in.put(value_interner::key_u64(1)), value_interner::REF_ONE);
	check(in.put(value_interner::key_i64(1)), value_interner::REF_ONE);
	check(in.put(big(&one, true)), value_interner::REF_ONE);
	// -1 is not one.
	InternerRef m1 = in.put(value_interner::key_i64(-1));
	test::eq(m1.is_static(), false);
	check(in.put(big(&one, false)), m1);

	// Positive zero and 1.0 of every width map to the int static refs.
	check(in.put(value_interner::key_float(fl16(0))), value_interner::REF_ZERO);
	check(in.put(value_interner::key_float(fl32(0))), value_interner::REF_ZERO);
	check(in.put(value_interner::key_float(fl64(0))), value_interner::REF_ZERO);
	check(in.put(value_interner::key_float(fl80(0, 0))), value_interner::REF_ZERO);
	check(in.put(value_interner::key_float(fl128(0, 0))), value_interner::REF_ZERO);
	check(in.put(value_interner::key_float(fl16(0x3C00))), value_interner::REF_ONE);
	check(in.put(value_interner::key_float(fl32(0x3F80_0000))), value_interner::REF_ONE);
	check(in.put(value_interner::key_float(fl64(0x3FF0_0000_0000_0000))), value_interner::REF_ONE);
	check(in.put(value_interner::key_float(fl80(0x8000_0000_0000_0000, 0x3FFF))), value_interner::REF_ONE);
	check(in.put(value_interner::key_float(fl128(0, 0x3FFF_0000_0000_0000))), value_interner::REF_ONE);
	check(in.len(), 1);

	// Zig quirk: get(value_interner::REF_ONE) / get(value_interner::REF_ZERO) are the *ints* (u64 form).
	InternerKey k = in.get(value_interner::REF_ONE);
	check(k.tag, InternerKeyTag.INT);
	check(k.int_val.tag, KeyIntTag.U64);
	check(k.int_val.u64, 1);
	k = in.get(value_interner::REF_ZERO);
	check(k.tag, InternerKeyTag.INT);
	check(k.int_val.u64, 0);

	// Negative zero floats are not static.
	InternerRef nz = in.put(value_interner::key_float(fl32(0x8000_0000)));
	test::eq(nz.is_static(), false);
	InternerRef nz80 = in.put(value_interner::key_float(fl80(0, 0x8000)));
	test::eq(nz80.is_static(), false);
	test::eq(nz != nz80, true);
	// Complex zero is not static.
	KeyComplex cz = { .tag = CF32, .cf32 = { 0, 0 } };
	test::eq(in.put(value_interner::key_complex(cz)).is_static(), false);
	f.free();
}

fn void deduplication() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	InternerRef a = in.put(value_interner::key_int_ty(7));
	InternerRef b = in.put(value_interner::key_int_ty(24));
	check(a, 0);
	check(b, 1);
	check(in.put(value_interner::key_int_ty(7)), a);
	check(in.put(value_interner::key_int_ty(24)), b);
	check(in.len(), 2);

	// Ints dedupe by value across u64 / i64 / big_int forms.
	Limb[1] five = { 5 };
	InternerRef r5 = in.put(value_interner::key_u64(5));
	check(r5, 2);
	check(in.put(value_interner::key_i64(5)), r5);
	check(in.put(big(&five, true)), r5);
	Limb[2] five_padded = { 5, 0 }; // non-normalized input still dedupes
	check(in.put(big(&five_padded, true)), r5);
	InternerRef rm5 = in.put(big(&five, false));
	check(in.put(value_interner::key_i64(-5)), rm5);
	test::eq(rm5 != r5, true);

	ulong two32 = 0x1_0000_0000;
	Limb[1] l32 = { two32 };
	InternerRef r32 = in.put(value_interner::key_u64(two32));
	check(in.put(value_interner::key_i64((long)two32)), r32);
	check(in.put(big(&l32, true)), r32);

	// Bytes, records, aggregates.
	char[*] s1 = "hello";
	char[*] s2 = "hello";
	InternerRef hb = in.put(value_interner::key_bytes(&s1));
	check(in.put(value_interner::key_bytes(&s2)), hb);
	test::eq(in.put(value_interner::key_bytes("hellp")) != hb, true);
	test::eq(in.put(value_interner::key_bytes("hell")) != hb, true);
	InternerRef[3] e1 = { value_interner::REF_I8, value_interner::REF_I32, a };
	InternerRef[3] e2 = { value_interner::REF_I8, value_interner::REF_I32, a };
	InternerRef rt = in.put(value_interner::key_record_ty(&e1));
	check(in.put(value_interner::key_record_ty(&e2)), rt);
	test::eq(in.put(value_interner::key_record_ty(e1[:2])) != rt, true);
	InternerRef at = in.put(value_interner::key_array_ty(10, value_interner::REF_I8));
	check(in.put(value_interner::key_array_ty(10, value_interner::REF_I8)), at);
	test::eq(in.put(value_interner::key_array_ty(10, value_interner::REF_I16)) != at, true);
	test::eq(in.put(value_interner::key_array_ty(11, value_interner::REF_I8)) != at, true);
	InternerRef vt = in.put(value_interner::key_vector_ty(4, value_interner::REF_F32));
	check(in.put(value_interner::key_vector_ty(4, value_interner::REF_F32)), vt);
	// Different key tags with "same" payload do not collide.
	test::eq(in.put(value_interner::key_vector_ty(10, value_interner::REF_I8)) != at, true);

	// Floats dedupe by bits; NaNs never dedupe (Zig compares floats with ==).
	InternerRef h = in.put(value_interner::key_float(fl64(0x4000_0000_0000_0000)));
	check(in.put(value_interner::key_float(fl64(0x4000_0000_0000_0000))), h);
	test::eq(in.put(value_interner::key_float(fl32(0x4000_0000))) != h, true);
	sz before = in.len();
	InternerRef n1 = in.put(value_interner::key_float(fl32(0x7FC0_0000)));
	InternerRef n2 = in.put(value_interner::key_float(fl32(0x7FC0_0000)));
	test::eq(n1 != n2, true);
	check(in.len(), before + 2);
	KeyComplex cn = { .tag = CF64, .cf64 = { 0x3FF0_0000_0000_0000, 0x7FF8_0000_0000_0000 } };
	test::eq(in.put(value_interner::key_complex(cn)) != in.put(value_interner::key_complex(cn)), true);
	f.free();
}

fn void hash_eql_consistency() @test
{
	Limb[1] five = { 5 };
	InternerKey[*] same = { value_interner::key_u64(5), value_interner::key_i64(5), big(&five, true) };
	foreach (k : same)
	{
		test::eq(k.eql(same[0]), true);
		check(k.hash(), same[0].hash());
	}
	Limb[1] min_mag = { 0x8000_0000_0000_0000 };
	InternerKey lmin = value_interner::key_i64(long::min);
	InternerKey bmin = big(&min_mag, false);
	test::eq(lmin.eql(bmin), true);
	check(lmin.hash(), bmin.hash());
	test::eq(value_interner::key_u64(0x8000_0000_0000_0000).eql(lmin), false);
	test::eq(value_interner::key_u64(5).eql(value_interner::key_int_ty(5)), false);
	test::eq(value_interner::key_bytes("ab").eql(value_interner::key_bytes("ab")), true);
	check(value_interner::key_bytes("abcdefghij").hash(), value_interner::key_bytes("abcdefghij").hash());
	test::eq(value_interner::key_pointer(3, value_interner::REF_ZERO).eql(value_interner::key_pointer(3, value_interner::REF_ZERO)), true);
	test::eq(value_interner::key_pointer(3, value_interner::REF_ZERO).eql(value_interner::key_pointer(4, value_interner::REF_ZERO)), false);

	// to_big_int forms.
	BigIntSpace space;
	BigIntConst c = value_interner::key_i64(long::min).to_big_int(&space);
	check(c.limbs.len, 1);
	test::eq(c.limbs[0] == 0x8000_0000_0000_0000, true);
	test::eq(c.positive, false);
	c = value_interner::key_u64(ulong::max).to_big_int(&space);
	test::eq(c.limbs[0] == ulong::max, true);
	test::eq(c.positive, true);
	c = value_interner::key_i64(-3).int_val.to_big_int(&space);
	check(c.limbs[0], 3);
	test::eq(c.positive, false);
	c = big(&five, false).to_big_int(&space);
	test::eq(c.limbs.ptr == &five[0], true);
}

fn void int_storage_forms() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;

	// u64 that fits u32 -> U32, returned as .u64.
	InternerRef r = in.put(value_interner::key_u64(0xFFFF_FFFF));
	check(in.items[(sz)(uint)r].tag, InternerTag.U32);
	InternerKey k = in.get(r);
	check(k.int_val.tag, KeyIntTag.U64);
	test::eq(k.int_val.u64 == 0xFFFF_FFFF, true);

	// i64 that fits i32 -> I32, returned as .i64.
	r = in.put(value_interner::key_i64(-0x8000_0000));
	check(in.items[(sz)(uint)r].tag, InternerTag.I32);
	k = in.get(r);
	check(k.int_val.tag, KeyIntTag.I64);
	check(k.int_val.i64, -0x8000_0000);
	// Non-negative i64 that fits i32 is still I32 (Zig checks i32 for .i64).
	r = in.put(value_interner::key_i64(77));
	check(in.items[(sz)(uint)r].tag, InternerTag.I32);
	check(in.get(r).int_val.i64, 77);

	// u64 above u32 -> INT_POSITIVE, returned as big_int.
	r = in.put(value_interner::key_u64(0x1_0000_0000));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_POSITIVE);
	k = in.get(r);
	check(k.int_val.tag, KeyIntTag.BIG_INT);
	check(k.int_val.big_int.limbs.len, 1);
	test::eq(k.int_val.big_int.limbs[0] == 0x1_0000_0000, true);
	test::eq(k.int_val.big_int.positive, true);

	// i64 below i32 -> INT_NEGATIVE.
	r = in.put(value_interner::key_i64(-0x8000_0001));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_NEGATIVE);
	k = in.get(r);
	check(k.int_val.big_int.limbs[0], 0x8000_0001);
	test::eq(k.int_val.big_int.positive, false);
	// i64 2^31 does not fit i32 -> INT_POSITIVE even though it fits u32.
	r = in.put(value_interner::key_i64(0x8000_0000));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_POSITIVE);
	check(in.put(value_interner::key_u64(0x8000_0000)), r); // ... and dedupes with the u64 form
	r = in.put(value_interner::key_i64(long::min));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_NEGATIVE);
	test::eq(in.get(r).int_val.big_int.limbs[0] == 0x8000_0000_0000_0000, true);

	// big_int that fits u32 / i32 -> U32 / I32 (returned as u64 / i64).
	Limb[1] small = { 0xFFFF_FFFF };
	r = in.put(big(&small, true));
	check(in.items[(sz)(uint)r].tag, InternerTag.U32);
	check(in.get(r).int_val.tag, KeyIntTag.U64);
	Limb[1] smin = { 0x8000_0000 };
	r = in.put(big(&smin, false));
	check(in.items[(sz)(uint)r].tag, InternerTag.I32);
	check(in.get(r).int_val.i64, -0x8000_0000);
	Limb[1] sbelow = { 0x8000_0001 };
	r = in.put(big(&sbelow, false));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_NEGATIVE);

	// Multi-limb (>128-bit) values round trip; limbs stored normalized, sign kept.
	Limb[3] wide = { 1, 2, 0x8000_0000_0000_0000 };
	InternerRef pw = round_trip(in, big(&wide, true));
	InternerRef nw = round_trip(in, big(&wide, false));
	test::eq(pw != nw, true);
	check(in.items[(sz)(uint)pw].tag, InternerTag.INT_POSITIVE);
	check(in.items[(sz)(uint)nw].tag, InternerTag.INT_NEGATIVE);
	k = in.get(nw);
	check(k.int_val.big_int.limbs.len, 3);
	test::eq(k.int_val.big_int.limbs[2] == 0x8000_0000_0000_0000, true);
	Limb[5] wide_padded = { 1, 2, 0x8000_0000_0000_0000, 0, 0 };
	check(in.put(big(&wide_padded, true)), pw);
	check(in.get(in.put(big(&wide_padded, false))).int_val.big_int.limbs.len, 3);
	// Tag.Int extra layout: limbs_index, limbs_len.
	uint d = in.items[(sz)(uint)pw].data;
	check(in.extra[(sz)d + 1], 3);
	f.free();
}

fn void every_key_tag_round_trip() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;

	InternerRef r = round_trip(in, value_interner::key_int_ty(24));
	check(in.items[(sz)(uint)r].tag, InternerTag.INT_TY);
	check(in.items[(sz)(uint)r].data, 24);
	// float_ty / complex_ty only accept the static widths (Zig `toRef` else => unreachable).

	// Array: PackedU64 split of len, low half first.
	r = round_trip(in, value_interner::key_array_ty(0x1_2345_6789_ABCD, value_interner::REF_I8));
	check(in.items[(sz)(uint)r].tag, InternerTag.ARRAY_TY);
	uint d = in.items[(sz)(uint)r].data;
	test::eq(in.extra[(sz)d] == 0x6789_ABCD, true);
	check(in.extra[(sz)d + 1], 0x1_2345);
	check(in.extra[(sz)d + 2], value_interner::REF_I8);
	test::eq(in.get(r).array_ty.len == 0x1_2345_6789_ABCD, true);
	round_trip(in, value_interner::key_array_ty(ulong::max, r));

	r = round_trip(in, value_interner::key_vector_ty(0xFFFF_FFFF, value_interner::REF_F64));
	check(in.items[(sz)(uint)r].tag, InternerTag.VECTOR_TY);
	check(in.get(r).vector_ty.child, value_interner::REF_F64);

	InternerRef[4] elems = { value_interner::REF_I8, value_interner::REF_PTR, r, value_interner::REF_I8 };
	r = round_trip(in, value_interner::key_record_ty(&elems));
	check(in.items[(sz)(uint)r].tag, InternerTag.RECORD_TY);
	check(in.get(r).record_ty.len, 4);
	check(in.get(r).record_ty[2], elems[2]);
	InternerRef empty_rec = round_trip(in, value_interner::key_record_ty({}));
	check(in.get(empty_rec).record_ty.len, 0);

	r = round_trip(in, value_interner::key_bytes("abc\0def"));
	check(in.items[(sz)(uint)r].tag, InternerTag.BYTES);
	check(in.get(r).bytes.len, 7);
	InternerRef empty_bytes = round_trip(in, value_interner::key_bytes(""));
	test::eq(empty_bytes != empty_rec, true);
	check(in.get(empty_bytes).bytes.len, 0);

	r = round_trip(in, value_interner::key_pointer(42, value_interner::REF_ONE));
	check(in.items[(sz)(uint)r].tag, InternerTag.POINTER);
	check(in.get(r).pointer.node, 42);
	check(in.get(r).pointer.offset, value_interner::REF_ONE);

	round_trip(in, value_interner::key_i64(-123456));
	round_trip(in, value_interner::key_u64(ulong::max));

	// Floats: every width, bit patterns preserved exactly.
	r = round_trip(in, value_interner::key_float(fl16(0xC000)));
	check(in.items[(sz)(uint)r].tag, InternerTag.F16);
	check(in.items[(sz)(uint)r].data, 0xC000);
	r = round_trip(in, value_interner::key_float(fl32(0x4049_0FDB)));
	check(in.items[(sz)(uint)r].tag, InternerTag.F32);
	r = round_trip(in, value_interner::key_float(fl64(0x4009_21FB_5444_2D18)));
	check(in.items[(sz)(uint)r].tag, InternerTag.F64);
	d = in.items[(sz)(uint)r].data;
	check(in.extra[(sz)d], 0x5444_2D18);
	check(in.extra[(sz)d + 1], 0x4009_21FB);
	r = round_trip(in, value_interner::key_float(fl80(0xC90F_DAA2_2168_C235, 0xC000)));
	check(in.items[(sz)(uint)r].tag, InternerTag.F80);
	d = in.items[(sz)(uint)r].data;
	check(in.extra[(sz)d + 2], 0xC000);
	KeyFloat g = in.get(r).float_val;
	check(g.tag, KeyFloatTag.F80);
	test::eq(g.f80.lo == 0xC90F_DAA2_2168_C235, true);
	check(g.f80.hi, 0xC000);
	r = round_trip(in, value_interner::key_float(fl128(0x8469_898C_C517_01B8, 0x4000_921F_B544_42D1)));
	check(in.items[(sz)(uint)r].tag, InternerTag.F128);
	g = in.get(r).float_val;
	test::eq(g.f128.lo == 0x8469_898C_C517_01B8 && g.f128.hi == 0x4000_921F_B544_42D1, true);
	// Same bits in different widths are different keys.
	test::eq(in.put(value_interner::key_float(fl16(0x4000))) != in.put(value_interner::key_float(fl32(0x4000))), true);

	// Complex: every width.
	KeyComplex c16 = { .tag = CF16, .cf16 = { 0x3C00, 0xC000 } };
	r = round_trip(in, value_interner::key_complex(c16));
	check(in.items[(sz)(uint)r].tag, InternerTag.CF16);
	check(in.extra[(sz)in.items[(sz)(uint)r].data], 0x3C00_C000); // real in the high half
	KeyComplex c32 = { .tag = CF32, .cf32 = { 0x3F80_0000, 0x4000_0000 } };
	r = round_trip(in, value_interner::key_complex(c32));
	check(in.get(r).complex_val.cf32[1], 0x4000_0000);
	KeyComplex c64 = { .tag = CF64, .cf64 = { 0x3FF0_0000_0000_0001, 0xBFF0_0000_0000_0002 } };
	r = round_trip(in, value_interner::key_complex(c64));
	d = in.items[(sz)(uint)r].data;
	check(in.extra[(sz)d + 2], 2);
	check(in.extra[(sz)d + 3], 0xBFF0_0000);
	KeyComplex c80 = { .tag = CF80, .cf80 = { { 0x8000_0000_0000_0001, 0x3FFF }, { 0xC000_0000_0000_0000, 0xBFFE } } };
	r = round_trip(in, value_interner::key_complex(c80));
	d = in.items[(sz)(uint)r].data;
	check(in.extra[(sz)d + 2], 0x3FFF);
	check(in.extra[(sz)d + 5], 0xBFFE);
	KeyComplex g80 = in.get(r).complex_val;
	test::eq(g80.cf80[1].lo == 0xC000_0000_0000_0000, true);
	KeyComplex c128 = { .tag = CF128, .cf128 = { { 1, 0x3FFF_0000_0000_0000 }, { 2, 0x8000_0000_0000_0003 } } };
	r = round_trip(in, value_interner::key_complex(c128));
	KeyComplex g128 = in.get(r).complex_val;
	test::eq(g128.cf128[0].lo == 1 && g128.cf128[1].hi == 0x8000_0000_0000_0003, true);
	d = in.items[(sz)(uint)r].data;
	check(in.extra[(sz)d + 4], 2);
	check(in.extra[(sz)d + 7], 0x8000_0000);
	f.free();
}

fn void distinct_pointer_bases() @test
{
	Fixture f;
	f.init();
	Interner* in = &f.in;
	InternerRef p1 = in.put(value_interner::key_pointer(1, value_interner::REF_ZERO));
	InternerRef p2 = in.put(value_interner::key_pointer(2, value_interner::REF_ZERO));
	test::eq(p1 != p2, true);
	InternerRef off8 = in.put(value_interner::key_u64(8));
	InternerRef p1_8 = in.put(value_interner::key_pointer(1, off8));
	InternerRef p2_8 = in.put(value_interner::key_pointer(2, off8));
	test::eq(p1_8 != p1, true);
	test::eq(p1_8 != p2_8, true);
	check(in.put(value_interner::key_pointer(1, value_interner::REF_ZERO)), p1);
	check(in.put(value_interner::key_pointer(2, in.put(value_interner::key_i64(8)))), p2_8);
	// Node 0 is an ordinary base, distinct from the null constant and from int zero.
	InternerRef p0 = in.put(value_interner::key_pointer(0, value_interner::REF_ZERO));
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
	InternerRef sref = in.put(value_interner::key_bytes(&text));
	Limb[3] wide = { 7, 8, 9 };
	InternerRef wref = in.put(big(&wide, false));
	InternerRef[2] elems = { value_interner::REF_I32, value_interner::REF_I64 };
	InternerRef rref = in.put(value_interner::key_record_ty(&elems));

	// The interner copied the key slices: mutating the caller's buffers changes nothing.
	text[0] = 'X';
	wide[0] = 99;
	elems[0] = value_interner::REF_F32;

	String s = (String)in.get(sref).bytes;
	Limb[] l = in.get(wref).int_val.big_int.limbs;
	InternerRef[] e = in.get(rref).record_ty;
	test::eq(s, "constant string");
	check(l[0], 7);
	check(e[0], value_interner::REF_I32);

	// Grow every container (items, extra, limbs, strings, records, table) a lot.
	char[16] buf;
	for (uint i = 0; i < 5000; i++)
	{
		in.put(value_interner::key_int_ty((ushort)(200 + i % 60000)));
		in.put(value_interner::key_u64(0x1_0000_0000 + (ulong)i));
		Limb[2] li = { i, 1 };
		in.put(big(&li, true));
		for (int j = 0; j < 8; j++) buf[j] = (char)('a' + (i >> (4 * j)) % 16);
		in.put(value_interner::key_bytes(buf[:8]));
		InternerRef[1] one = { (InternerRef)i };
		in.put(value_interner::key_record_ty(&one));
		in.put(value_interner::key_float(fl64(0x4000_0000_0000_0000 + (ulong)i)));
	}
	// Same slices (same addresses) still valid and unchanged.
	test::eq(s.ptr == in.get(sref).bytes.ptr, true);
	test::eq(l.ptr == in.get(wref).int_val.big_int.limbs.ptr, true);
	test::eq(e.ptr == in.get(rref).record_ty.ptr, true);
	test::eq(s, "constant string");
	check(l[0], 7);
	check(l[2], 9);
	check(e[1], value_interner::REF_I64);

	// Dedup still works after rehashing, and refs are dense in insertion order.
	check(in.put(value_interner::key_bytes("constant string")), sref);
	check(in.put(value_interner::key_int_ty(200)), 3);
	sz n = in.len();
	for (uint i = 0; i < 5000; i++)
	{
		Limb[2] li = { i, 1 };
		in.put(big(&li, true));
		in.put(value_interner::key_u64(0x1_0000_0000 + (ulong)i));
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
			in.put(value_interner::key_bytes("leak"));
			in.put(value_interner::key_record_ty(&elems));
			in.put(value_interner::key_record_ty({}));
			in.put(value_interner::key_bytes(""));
			in.put(value_interner::key_u64(0x1_0000_0000 * (ulong)(i + 1)));
			in.put(value_interner::key_float(fl32(0x7FC0_0000))); // NaN: a new entry each time
			KeyComplex c = { .tag = CF128, .cf128 = { { (ulong)i, 0 }, { 0, 1 } } };
			in.put(value_interner::key_complex(c));
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
