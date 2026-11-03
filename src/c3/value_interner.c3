// Port of src/backend/Interner.zig: the constant/IR-type interner behind Value.
//
// OWNER: plan 09 stage 1 agent 09.1 `interner`. Stage 0 (contract) fixed the key,
// handle and storage layouts and the public signatures; 09.1 implemented them.
// The interner reads big-int limbs directly (it calls no bigint arithmetic).
// Hash index: `hashes[i]` is item i's hash, `table` is open addressing with
// linear probing over item indices + 1 (0 = empty), power-of-two sized, <= 3/4 full.
//
// Handles. `InternerRef` is Zig's non-exhaustive `enum(u32)`: values counting down
// from 0xFFFF_FFFE are the static refs below (REF_PTR .. REF_CF128); every other
// value is a dense index into `items`, assigned in insertion order (Zig's
// AutoArrayHashMap index). `InternerOptRef` is the same encoding plus
// OPT_NONE = 0xFFFF_FFFF. Converting between them is a plain bit copy.
//
// Invariants implementers must keep:
//   - `put(key)` first maps static keys to static refs exactly like Zig `Key.toRef`
//     (int 0 / float +0.0 -> REF_ZERO, int 1 / float 1.0 -> REF_ONE, NULL -> REF_NULL,
//     int_ty 1/8/16/32/64/128, float_ty, complex_ty, ptr/func/noreturn/void). Note the
//     Zig quirk this implies: interning float 1.0 yields REF_ONE, and `get(REF_ONE)`
//     is the *int* 1. Keep it.
//   - Deduplication: two keys that are `eql` get the same ref; `hash` is consistent
//     with `eql`. Ints compare by mathematical value regardless of u64/i64/big_int
//     form (hash/eql go through `to_big_int`), so `put(u64 5) == put(i64 5)`.
//   - Float/complex keys hold raw bit patterns (placeholders until plan 10). `eql`
//     must follow Zig's value comparison (`std.meta.eql` uses `==`): a key containing
//     a NaN never equals anything (so NaNs are never deduplicated); otherwise equal
//     bits mean equal. The hash covers the raw bits.
//   - Int storage follows Zig `put`: u64 that fits u32 -> tag U32; i64 that fits i32
//     -> tag I32; big_int that fits u32 (then i32) likewise; else INT_POSITIVE /
//     INT_NEGATIVE with normalized limbs. `get` returns U32 as `.u64`, I32 as `.i64`
//     and big storage as `.big_int`.
//   - Stability (stronger than Zig, required by CONVENTIONS.md): slices inside a Key
//     returned by `get` (bytes, record_ty elements, big_int limbs) stay valid until
//     `free`, even across later `put`s. Hence each such payload is its own owned
//     heap allocation (`limbs`/`strings`/`records` lists of slices below), never a
//     slice into a growing List backing array. `put` copies every slice it stores;
//     callers keep ownership of the key they pass.
//   - `extra` keeps Zig's u32 field layout for the fixed-size payloads (Array,
//     Vector, Pointer, Int, F64, F80, F128, CF*, Bytes, Record) so offsets match the
//     reference; it is only ever read by index.
//   - Running out of memory panics (no faults); `free` releases everything.
module aro::value_interner;
import aro::bigint, std::collections::list;

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

<* Interner.Ref *>
typedef InternerRef = uint;
<* Interner.OptRef: InternerRef plus OPT_NONE. *>
typedef InternerOptRef = uint;

const InternerRef REF_PTR = (InternerRef)0xFFFF_FFFE;      // max - 1
const InternerRef REF_NORETURN = (InternerRef)0xFFFF_FFFD; // max - 2
const InternerRef REF_VOID = (InternerRef)0xFFFF_FFFC;     // max - 3
const InternerRef REF_I1 = (InternerRef)0xFFFF_FFFB;       // max - 4
const InternerRef REF_I8 = (InternerRef)0xFFFF_FFFA;       // max - 5
const InternerRef REF_I16 = (InternerRef)0xFFFF_FFF9;      // max - 6
const InternerRef REF_I32 = (InternerRef)0xFFFF_FFF8;      // max - 7
const InternerRef REF_I64 = (InternerRef)0xFFFF_FFF7;      // max - 8
const InternerRef REF_I128 = (InternerRef)0xFFFF_FFF6;     // max - 9
const InternerRef REF_F16 = (InternerRef)0xFFFF_FFF5;      // max - 10
const InternerRef REF_F32 = (InternerRef)0xFFFF_FFF4;      // max - 11
const InternerRef REF_F64 = (InternerRef)0xFFFF_FFF3;      // max - 12
const InternerRef REF_F80 = (InternerRef)0xFFFF_FFF2;      // max - 13
const InternerRef REF_F128 = (InternerRef)0xFFFF_FFF1;     // max - 14
const InternerRef REF_FUNC = (InternerRef)0xFFFF_FFF0;     // max - 15
const InternerRef REF_ZERO = (InternerRef)0xFFFF_FFEF;     // max - 16
const InternerRef REF_ONE = (InternerRef)0xFFFF_FFEE;      // max - 17
const InternerRef REF_NULL = (InternerRef)0xFFFF_FFED;     // max - 18
const InternerRef REF_CF16 = (InternerRef)0xFFFF_FFEC;     // max - 19
const InternerRef REF_CF32 = (InternerRef)0xFFFF_FFEB;     // max - 20
const InternerRef REF_CF64 = (InternerRef)0xFFFF_FFEA;     // max - 21
const InternerRef REF_CF80 = (InternerRef)0xFFFF_FFE9;     // max - 22
const InternerRef REF_CF128 = (InternerRef)0xFFFF_FFE8;    // max - 23
<* Smallest static ref; any ref below it indexes `items`. *>
const uint FIRST_STATIC_REF = 0xFFFF_FFE8;

const InternerOptRef OPT_NONE = (InternerOptRef)0xFFFF_FFFF;
const InternerOptRef OPT_ZERO = (InternerOptRef)0xFFFF_FFEF;
const InternerOptRef OPT_ONE = (InternerOptRef)0xFFFF_FFEE;
const InternerOptRef OPT_NULL = (InternerOptRef)0xFFFF_FFED;

fn InternerOptRef InternerRef.to_opt(self) => (InternerOptRef)(uint)self;
fn bool InternerOptRef.is_none(self) => self == OPT_NONE;
<*
 @require !self.is_none() : "unwrapping OptRef.none"
*>
fn InternerRef InternerOptRef.unwrap(self) => (InternerRef)(uint)self;
fn bool InternerRef.is_static(self) => (uint)self >= FIRST_STATIC_REF;

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

<* std.meta.Tag(Interner.Key), in Zig declaration order. *>
enum InternerKeyTag : char
{
	INT_TY,
	FLOAT_TY,
	COMPLEX_TY,
	PTR_TY,
	NORETURN_TY,
	VOID_TY,
	FUNC_TY,
	ARRAY_TY,
	VECTOR_TY,
	RECORD_TY,
	<* Zig `.null`: the nullptr constant (may not be zero). *>
	NULL,
	INT,
	FLOAT,
	COMPLEX,
	BYTES,
	POINTER,
}

struct KeyArrayTy
{
	ulong len;
	InternerRef child;
}

struct KeyVectorTy
{
	uint len;
	InternerRef child;
}

<* Key.Pointer: an address constant is a declaration/compound-literal node plus a byte offset, never a host address. *>
struct KeyPointer
{
	<* NodeIndex of the decl or compound literal whose address we are offsetting from. *>
	uint node;
	<* Offset in bytes (an interned integer). *>
	InternerRef offset;
}

enum KeyIntTag : char
{
	U64,
	I64,
	BIG_INT,
}

<* Key.int: union(enum) { u64, i64, big_int }. `big_int` must be normalized. *>
struct KeyInt
{
	KeyIntTag tag;
	union
	{
		ulong u64;
		long i64;
		BigIntConst big_int;
	}
}

// Float bit storage (placeholders until plan 10 adds float semantics). Each
// field holds the IEEE/x87 bit pattern Zig gets from `@bitCast`.

<* f80 bits: `lo` = bits 0..63 (explicit-integer-bit mantissa), `hi` = bits 64..79 (sign + exponent). *>
struct F80Bits
{
	ulong lo;
	ushort hi;
}

<* f128 bits: `lo` = bits 0..63, `hi` = bits 64..127. *>
struct F128Bits
{
	ulong lo;
	ulong hi;
}

enum KeyFloatTag : char
{
	F16,
	F32,
	F64,
	F80,
	F128,
}

<* Key.Float: union(enum) { f16, f32, f64, f80, f128 } stored as bit patterns. *>
struct KeyFloat
{
	KeyFloatTag tag;
	union
	{
		ushort f16;
		uint f32;
		ulong f64;
		F80Bits f80;
		F128Bits f128;
	}
}

enum KeyComplexTag : char
{
	CF16,
	CF32,
	CF64,
	CF80,
	CF128,
}

<* Key.Complex: [2]fN (real, imaginary) per width, stored as bit patterns. *>
struct KeyComplex
{
	KeyComplexTag tag;
	union
	{
		ushort[2] cf16;
		uint[2] cf32;
		ulong[2] cf64;
		F80Bits[2] cf80;
		F128Bits[2] cf128;
	}
}

<* Interner.Key: a tagged record; the active member is selected by `tag`. *>
struct InternerKey
{
	InternerKeyTag tag;
	union
	{
		<* INT_TY / FLOAT_TY / COMPLEX_TY: bit width. *>
		ushort bits;
		KeyArrayTy array_ty;
		KeyVectorTy vector_ty;
		InternerRef[] record_ty;
		KeyInt int_val;
		KeyFloat float_val;
		KeyComplex complex_val;
		char[] bytes;
		KeyPointer pointer;
	}
}

// Key constructors (Zig anonymous literals such as `.{ .int = .{ .u64 = x } }`).
fn InternerKey key_int_ty(ushort bits) => { .tag = INT_TY, .bits = bits };
fn InternerKey key_float_ty(ushort bits) => { .tag = FLOAT_TY, .bits = bits };
fn InternerKey key_complex_ty(ushort bits) => { .tag = COMPLEX_TY, .bits = bits };
fn InternerKey key_simple(InternerKeyTag tag) => { .tag = tag };
fn InternerKey key_array_ty(ulong len, InternerRef child) => { .tag = ARRAY_TY, .array_ty = { .len = len, .child = child } };
fn InternerKey key_vector_ty(uint len, InternerRef child) => { .tag = VECTOR_TY, .vector_ty = { .len = len, .child = child } };
fn InternerKey key_record_ty(InternerRef[] elems) => { .tag = RECORD_TY, .record_ty = elems };
fn InternerKey key_u64(ulong v) => { .tag = INT, .int_val = { .tag = U64, .u64 = v } };
fn InternerKey key_i64(long v) => { .tag = INT, .int_val = { .tag = I64, .i64 = v } };
fn InternerKey key_big_int(BigIntConst v) => { .tag = INT, .int_val = { .tag = BIG_INT, .big_int = v } };
fn InternerKey key_float(KeyFloat f) => { .tag = FLOAT, .float_val = f };
fn InternerKey key_complex(KeyComplex c) => { .tag = COMPLEX, .complex_val = c };
fn InternerKey key_bytes(char[] bytes) => { .tag = BYTES, .bytes = bytes };
fn InternerKey key_pointer(uint node, InternerRef offset) => { .tag = POINTER, .pointer = { .node = node, .offset = offset } };

<*
 Interner.Tag.Int.BigIntSpace: big enough for any non-big int key, plus one limb
 of headroom so a single increment/decrement needs no allocator.
*>
struct BigIntSpace
{
	Limb[bigint::SMALL_LIMBS] limbs;
}

<*
 Key.Int.toBigInt: the value as a BigIntConst. For U64/I64 the limbs live in
 `space`, so the result is valid only while `space` is.
*>
fn BigIntConst KeyInt.to_big_int(self, BigIntSpace* space)
{
	switch (self.tag)
	{
		case BIG_INT:
			return self.big_int;
		case U64:
			space.limbs[0] = self.u64;
			return { .limbs = space.limbs[:1], .positive = true };
		case I64:
			// Two's-complement negation in ulong handles long::min (magnitude 2^63).
			long v = self.i64;
			space.limbs[0] = v < 0 ? (ulong)0 - (ulong)v : (ulong)v;
			return { .limbs = space.limbs[:1], .positive = v >= 0 };
	}
}

<*
 Key.toBigInt
 @require self.tag == INT
*>
fn BigIntConst InternerKey.to_big_int(self, BigIntSpace* space) => self.int_val.to_big_int(space);

// Integer helpers. These read limbs directly instead of calling bigint queries so
// the interner does not depend on the bigint agent's implementation. A value is
// first viewed in canonical form: leading zero limbs dropped (zero = no limbs) and
// zero forced positive. For normalized input this is the identity apart from zero.

<* Canonical view of `big`: no leading zero limbs, zero has no limbs and is positive. *>
fn BigIntConst canonical_int(BigIntConst big) @local
{
	sz n = big.limbs.len;
	while (n > 0 && big.limbs[n - 1] == 0) n--;
	return { .limbs = big.limbs[:n], .positive = n == 0 || big.positive };
}

fn bool canonical_int_eql(BigIntConst a, BigIntConst b) @local
{
	if (a.positive != b.positive || a.limbs.len != b.limbs.len) return false;
	foreach (i, l : a.limbs) if (l != b.limbs[i]) return false;
	return true;
}

// Float bit-pattern helpers (Zig compares float payloads with `==`).

fn bool f16_is_nan(ushort b) @local => (b & 0x7C00) == 0x7C00 && (b & 0x03FF) != 0;
fn bool f32_is_nan(uint b) @local => (b & 0x7F80_0000) == 0x7F80_0000 && (b & 0x007F_FFFF) != 0;
fn bool f64_is_nan(ulong b) @local
{
	return (b & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 && (b & 0x000F_FFFF_FFFF_FFFF) != 0;
}
<* x87: exponent all ones with any fraction bit set (the explicit integer bit, bit 63, is not part of the fraction). *>
fn bool f80_is_nan(F80Bits b) @local => (b.hi & 0x7FFF) == 0x7FFF && (b.lo & 0x7FFF_FFFF_FFFF_FFFF) != 0;
fn bool f128_is_nan(F128Bits b) @local
{
	return (b.hi & 0x7FFF_0000_0000_0000) == 0x7FFF_0000_0000_0000
		&& ((b.hi & 0x0000_FFFF_FFFF_FFFF) | b.lo) != 0;
}

fn bool f16_eq(ushort a, ushort b) @local => a == b && !f16_is_nan(a);
fn bool f32_eq(uint a, uint b) @local => a == b && !f32_is_nan(a);
fn bool f64_eq(ulong a, ulong b) @local => a == b && !f64_is_nan(a);
fn bool f80_eq(F80Bits a, F80Bits b) @local => a.lo == b.lo && a.hi == b.hi && !f80_is_nan(a);
fn bool f128_eq(F128Bits a, F128Bits b) @local => a.lo == b.lo && a.hi == b.hi && !f128_is_nan(a);

<* std.meta.eql on Key.Float: same width and equal bits, never equal when NaN. *>
fn bool KeyFloat.eql(a, KeyFloat b)
{
	if (a.tag != b.tag) return false;
	switch (a.tag)
	{
		case F16: return f16_eq(a.f16, b.f16);
		case F32: return f32_eq(a.f32, b.f32);
		case F64: return f64_eq(a.f64, b.f64);
		case F80: return f80_eq(a.f80, b.f80);
		case F128: return f128_eq(a.f128, b.f128);
	}
}

<* std.meta.eql on Key.Complex: both components as in KeyFloat.eql. *>
fn bool KeyComplex.eql(a, KeyComplex b)
{
	if (a.tag != b.tag) return false;
	switch (a.tag)
	{
		case CF16: return f16_eq(a.cf16[0], b.cf16[0]) && f16_eq(a.cf16[1], b.cf16[1]);
		case CF32: return f32_eq(a.cf32[0], b.cf32[0]) && f32_eq(a.cf32[1], b.cf32[1]);
		case CF64: return f64_eq(a.cf64[0], b.cf64[0]) && f64_eq(a.cf64[1], b.cf64[1]);
		case CF80: return f80_eq(a.cf80[0], b.cf80[0]) && f80_eq(a.cf80[1], b.cf80[1]);
		case CF128: return f128_eq(a.cf128[0], b.cf128[0]) && f128_eq(a.cf128[1], b.cf128[1]);
	}
}

<* Word-at-a-time 64-bit mixing hasher (stand-in for Zig's Wyhash). *>
struct KeyHasher @local
{
	ulong h;
}

fn void KeyHasher.add(&self, ulong v)
{
	ulong x = (self.h ^ v) * 0x9E37_79B9_7F4A_7C15;
	self.h = x ^ (x >> 29);
}

fn void KeyHasher.add_f80(&self, F80Bits b)
{
	self.add(b.lo);
	self.add(b.hi);
}

fn void KeyHasher.add_f128(&self, F128Bits b)
{
	self.add(b.lo);
	self.add(b.hi);
}

fn uint KeyHasher.final(&self)
{
	// fmix64 (MurmurHash3 finalizer), then fold to 32 bits.
	ulong x = self.h;
	x ^= x >> 33;
	x *= 0xFF51_AFD7_ED55_8CCD;
	x ^= x >> 33;
	x *= 0xC4CE_B9FE_1A85_EC53;
	x ^= x >> 33;
	return (uint)x;
}

<* Key.hash (32-bit). Need not match Wyhash bit-for-bit (ref numbering does not depend on it), but must be consistent with `eql`. *>
fn uint InternerKey.hash(self)
{
	KeyHasher hs = { .h = 0x243F_6A88_85A3_08D3 };
	hs.add((ulong)self.tag.ordinal);
	switch (self.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			hs.add(self.bits);
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			break;
		case ARRAY_TY:
			hs.add(self.array_ty.len);
			hs.add((uint)self.array_ty.child);
		case VECTOR_TY:
			hs.add(self.vector_ty.len);
			hs.add((uint)self.vector_ty.child);
		case RECORD_TY:
			hs.add((ulong)self.record_ty.len);
			foreach (e : self.record_ty) hs.add((uint)e);
		case INT:
			BigIntSpace space;
			BigIntConst big = canonical_int(self.int_val.to_big_int(&space));
			hs.add(big.positive ? 1 : 0);
			foreach (l : big.limbs) hs.add(l);
		case FLOAT:
			KeyFloat f = self.float_val;
			hs.add((ulong)f.tag.ordinal);
			switch (f.tag)
			{
				case F16: hs.add(f.f16);
				case F32: hs.add(f.f32);
				case F64: hs.add(f.f64);
				case F80: hs.add_f80(f.f80);
				case F128: hs.add_f128(f.f128);
			}
		case COMPLEX:
			KeyComplex c = self.complex_val;
			hs.add((ulong)c.tag.ordinal);
			for (int i = 0; i < 2; i++)
			{
				switch (c.tag)
				{
					case CF16: hs.add(c.cf16[i]);
					case CF32: hs.add(c.cf32[i]);
					case CF64: hs.add(c.cf64[i]);
					case CF80: hs.add_f80(c.cf80[i]);
					case CF128: hs.add_f128(c.cf128[i]);
				}
			}
		case BYTES:
			char[] bytes = self.bytes;
			hs.add((ulong)bytes.len);
			sz i = 0;
			for (; i + 8 <= bytes.len; i += 8)
			{
				ulong w = 0;
				for (sz j = 0; j < 8; j++) w |= (ulong)bytes[i + j] << (ulong)(8 * j);
				hs.add(w);
			}
			if (i < bytes.len)
			{
				ulong w = 0;
				for (sz j = 0; i + j < bytes.len; j++) w |= (ulong)bytes[i + j] << (ulong)(8 * j);
				hs.add(w);
			}
		case POINTER:
			hs.add(self.pointer.node);
			hs.add((uint)self.pointer.offset);
	}
	return hs.final();
}

<*
 Key.eql. Ints compare by mathematical value (any u64/i64/big_int form); floats
 and complexes compare their bit patterns, and a NaN component never compares
 equal (Zig `std.meta.eql` uses `==` on float payloads).
*>
fn bool InternerKey.eql(a, InternerKey b)
{
	if (a.tag != b.tag) return false;
	switch (a.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			return a.bits == b.bits;
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			return true;
		case ARRAY_TY:
			return a.array_ty.len == b.array_ty.len && a.array_ty.child == b.array_ty.child;
		case VECTOR_TY:
			return a.vector_ty.len == b.vector_ty.len && a.vector_ty.child == b.vector_ty.child;
		case RECORD_TY:
			if (a.record_ty.len != b.record_ty.len) return false;
			foreach (i, e : a.record_ty) if (e != b.record_ty[i]) return false;
			return true;
		case INT:
			BigIntSpace a_space;
			BigIntSpace b_space;
			return canonical_int_eql(canonical_int(a.int_val.to_big_int(&a_space)),
				canonical_int(b.int_val.to_big_int(&b_space)));
		case FLOAT:
			return a.float_val.eql(b.float_val);
		case COMPLEX:
			return a.complex_val.eql(b.complex_val);
		case BYTES:
			if (a.bytes.len != b.bytes.len) return false;
			foreach (i, c : a.bytes) if (c != b.bytes[i]) return false;
			return true;
		case POINTER:
			return a.pointer.node == b.pointer.node && a.pointer.offset == b.pointer.offset;
	}
}

<* Key.toRef: the static ref for keys that have one; NO_STATIC_REF otherwise. *>
excuse NO_STATIC_REF;
fn InternerRef? InternerKey.to_ref(self)
{
	switch (self.tag)
	{
		case INT_TY:
			switch (self.bits)
			{
				case 1: return REF_I1;
				case 8: return REF_I8;
				case 16: return REF_I16;
				case 32: return REF_I32;
				case 64: return REF_I64;
				case 128: return REF_I128;
			}
		case FLOAT_TY:
			switch (self.bits)
			{
				case 16: return REF_F16;
				case 32: return REF_F32;
				case 64: return REF_F64;
				case 80: return REF_F80;
				case 128: return REF_F128;
				default: unreachable("float_ty with unsupported bit width");
			}
		case COMPLEX_TY:
			switch (self.bits)
			{
				case 16: return REF_CF16;
				case 32: return REF_CF32;
				case 64: return REF_CF64;
				case 80: return REF_CF80;
				case 128: return REF_CF128;
				default: unreachable("complex_ty with unsupported bit width");
			}
		case PTR_TY: return REF_PTR;
		case FUNC_TY: return REF_FUNC;
		case NORETURN_TY: return REF_NORETURN;
		case VOID_TY: return REF_VOID;
		case NULL: return REF_NULL;
		case INT:
			BigIntSpace space;
			BigIntConst big = canonical_int(self.int_val.to_big_int(&space));
			if (big.limbs.len == 0) return REF_ZERO;
			if (big.positive && big.limbs.len == 1 && big.limbs[0] == 1) return REF_ONE;
		case FLOAT:
			// isPositiveZero(x) -> zero; x == 1 -> one (compared as the bit pattern of 1.0).
			KeyFloat f = self.float_val;
			switch (f.tag)
			{
				case F16:
					if (f.f16 == 0) return REF_ZERO;
					if (f.f16 == 0x3C00) return REF_ONE;
				case F32:
					if (f.f32 == 0) return REF_ZERO;
					if (f.f32 == 0x3F80_0000) return REF_ONE;
				case F64:
					if (f.f64 == 0) return REF_ZERO;
					if (f.f64 == 0x3FF0_0000_0000_0000) return REF_ONE;
				case F80:
					if (f.f80.lo == 0 && f.f80.hi == 0) return REF_ZERO;
					if (f.f80.lo == 0x8000_0000_0000_0000 && f.f80.hi == 0x3FFF) return REF_ONE;
				case F128:
					if (f.f128.lo == 0 && f.f128.hi == 0) return REF_ZERO;
					if (f.f128.lo == 0 && f.f128.hi == 0x3FFF_0000_0000_0000) return REF_ONE;
			}
		default:
			break;
	}
	return NO_STATIC_REF~;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

<* Interner.Tag (u8), Zig order. Comments give what `data` holds. *>
enum InternerTag : char
{
	INT_TY,       // ushort bits
	FLOAT_TY,     // ushort bits
	COMPLEX_TY,   // ushort bits
	ARRAY_TY,     // extra index of TagArray
	VECTOR_TY,    // extra index of TagVector
	U32,          // uint value
	I32,          // int value (bitcast)
	INT_POSITIVE, // extra index of TagInt
	INT_NEGATIVE, // extra index of TagInt
	F16,          // ushort bits
	F32,          // uint bits
	F64,          // extra index of TagF64
	F80,          // extra index of TagF80
	F128,         // extra index of TagF128
	CF16,         // extra index of TagCF16
	CF32,         // extra index of TagCF32
	CF64,         // extra index of TagCF64
	CF80,         // extra index of TagCF80
	CF128,        // extra index of TagCF128
	BYTES,        // extra index of TagBytes
	RECORD_TY,    // extra index of TagRecord
	POINTER,      // extra index of TagPointer
}

// `extra` payloads, one uint per field, in this order (Zig Tag.* structs).

<* Tag.Array: len split into two u32 halves (PackedU64: len0 = low, len1 = high). *>
struct TagArray
{
	uint len0;
	uint len1;
	InternerRef child;
}

struct TagVector
{
	uint len;
	InternerRef child;
}

struct TagPointer
{
	uint node;
	InternerRef offset;
}

<* Tag.Int. Deviation: `limbs_index` indexes `Interner.limbs` (one owned slice per int), not a flat limb array. *>
struct TagInt
{
	uint limbs_index;
	uint limbs_len;
}

<* Tag.F64: piece0 = bits 0..31, piece1 = bits 32..63. *>
struct TagF64
{
	uint piece0;
	uint piece1;
}

<* Tag.F80: piece0/1 = bits 0..63, piece2 = bits 64..79 (u16 in a u32). *>
struct TagF80
{
	uint piece0;
	uint piece1;
	uint piece2;
}

<* Tag.F128: piece0..3 = bits 0..127, low first. *>
struct TagF128
{
	uint piece0;
	uint piece1;
	uint piece2;
	uint piece3;
}

<* Tag.CF16: real in the high 16 bits, imaginary in the low 16 bits. *>
struct TagCF16
{
	uint piece0;
}

<* Tag.CF32: piece0 = real bits, piece1 = imaginary bits. *>
struct TagCF32
{
	uint piece0;
	uint piece1;
}

<* Tag.CF64: real F64 pieces then imaginary F64 pieces. *>
struct TagCF64
{
	uint piece0;
	uint piece1;
	uint piece2;
	uint piece3;
}

<* Tag.CF80: real F80 pieces (0..2) then imaginary F80 pieces (3..5). *>
struct TagCF80
{
	uint piece0;
	uint piece1;
	uint piece2;
	uint piece3;
	uint piece4;
	uint piece5;
}

<* Tag.CF128: real F128 pieces (0..3) then imaginary (4..7). *>
struct TagCF128
{
	uint[8] pieces;
}

<* Tag.Bytes. Deviation: `strings_index` indexes `Interner.strings` (one owned slice per entry). *>
struct TagBytes
{
	uint strings_index;
	uint len;
}

<* Tag.Record. Deviation: elements live in `Interner.records[records_index]` instead of trailing in `extra`. *>
struct TagRecord
{
	uint elements_len;
	uint records_index;
}

struct InternerItem
{
	InternerTag tag;
	uint data;
}

struct Interner
{
	Allocator gpa;
	<* Indexed by InternerRef (non-static). *>
	List{InternerItem} items;
	List{uint} extra;
	<* Owned limb slices of big ints (TagInt.limbs_index). *>
	List{Limb[]} limbs;
	<* Owned byte slices (TagBytes.strings_index). *>
	List{char[]} strings;
	<* Owned element slices of record types (TagRecord.records_index). *>
	List{InternerRef[]} records;
	<*
	 Hash index over `items` (Zig's AutoArrayHashMap(void, void) with KeyAdapter).
	 Layout is private to the interner agent: e.g. `hashes[i]` = hash of item i and
	 an open-addressing `table` of item indices (+1, 0 = empty).
	*>
	List{uint} hashes;
	uint[] table;
}

fn void Interner.init(&self, Allocator gpa)
{
	*self = { .gpa = gpa };
	self.items.init(gpa);
	self.extra.init(gpa);
	self.limbs.init(gpa);
	self.strings.init(gpa);
	self.records.init(gpa);
	self.hashes.init(gpa);
}

fn void Interner.free(&self)
{
	Allocator gpa = self.gpa;
	foreach (s : self.limbs) if (s.len) alloc::free(gpa, s.ptr);
	foreach (s : self.strings) if (s.len) alloc::free(gpa, s.ptr);
	foreach (s : self.records) if (s.len) alloc::free(gpa, s.ptr);
	if (self.table.len) alloc::free(gpa, self.table.ptr);
	self.items.free();
	self.extra.free();
	self.limbs.free();
	self.strings.free();
	self.records.free();
	self.hashes.free();
	*self = {};
}

<* Number of non-static entries (`items.len`). *>
fn sz Interner.len(&self) => self.items.len();

<*
 Interner.put: intern `key` and return its ref (static ref, existing entry, or a
 new entry with the next dense index). Copies all slices in `key`.
 PTR_TY/NORETURN_TY/VOID_TY/FUNC_TY/NULL always resolve through `to_ref`.
*>
fn InternerRef Interner.put(&self, InternerKey key)
{
	if (try r = key.to_ref()) return r;
	uint h = key.hash();
	if (self.table.len)
	{
		usz mask = self.table.len - 1;
		for (usz slot = (usz)h & mask;; slot = (slot + 1) & mask)
		{
			uint entry = self.table[slot];
			if (entry == 0) break;
			uint index = entry - 1;
			if (self.hashes[index] == h && self.get((InternerRef)index).eql(key)) return (InternerRef)index;
		}
	}

	sz new_index = self.items.len();
	assert(new_index < (sz)FIRST_STATIC_REF, "interner full");
	InternerItem item;
	switch (key.tag)
	{
		case INT_TY: item = { INT_TY, key.bits };
		case FLOAT_TY: item = { FLOAT_TY, key.bits };
		case COMPLEX_TY: item = { COMPLEX_TY, key.bits };
		case ARRAY_TY:
			// Tag.Array: PackedU64 split, low half first.
			ulong len = key.array_ty.len;
			item = { ARRAY_TY, self.add_extra((uint)len, (uint)(len >> 32), (uint)key.array_ty.child) };
		case VECTOR_TY:
			item = { VECTOR_TY, self.add_extra(key.vector_ty.len, (uint)key.vector_ty.child) };
		case POINTER:
			item = { POINTER, self.add_extra(key.pointer.node, (uint)key.pointer.offset) };
		case INT:
			item = self.put_int(key.int_val);
		case FLOAT:
			item = self.put_float(key.float_val);
		case COMPLEX:
			item = self.put_complex(key.complex_val);
		case BYTES:
			uint strings_index = (uint)self.strings.len();
			self.strings.push(copy_slice(self.gpa, key.bytes));
			item = { BYTES, self.add_extra(strings_index, (uint)key.bytes.len) };
		case RECORD_TY:
			uint records_index = (uint)self.records.len();
			self.records.push(copy_slice(self.gpa, key.record_ty));
			item = { RECORD_TY, self.add_extra((uint)key.record_ty.len, records_index) };
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			unreachable("key always has a static ref");
	}
	self.items.push(item);
	self.hashes.push(h);
	self.index_insert((uint)new_index, h);
	return (InternerRef)(uint)new_index;
}

<* An owned heap copy of `slice` (empty slices are not allocated). *>
macro copy_slice(Allocator gpa, slice) @local
{
	if (!slice.len) return slice[:0];
	var copy = alloc::new_array(gpa, $Typeof(slice[0]), slice.len);
	copy[..] = slice[..];
	return copy;
}

<* addExtra: append `fields` to `extra`, returning the index of the first. *>
fn uint Interner.add_extra(&self, uint... fields)
{
	uint result = (uint)self.extra.len();
	foreach (f : fields) self.extra.push(f);
	return result;
}

<* The `put` int branch: U32/I32 when the value fits, else owned normalized limbs. *>
fn InternerItem Interner.put_int(&self, KeyInt repr)
{
	switch (repr.tag)
	{
		case U64:
			if (repr.u64 <= 0xFFFF_FFFF) return { U32, (uint)repr.u64 };
		case I64:
			if (repr.i64 >= int::min && repr.i64 <= int::max) return { I32, (uint)(int)repr.i64 };
		case BIG_INT:
			// fitsInTwosComp(.unsigned, 32), then (.signed, 32). Zero never gets here.
			BigIntConst c = canonical_int(repr.big_int);
			if (c.limbs.len == 1)
			{
				Limb mag = c.limbs[0];
				if (c.positive && mag <= 0xFFFF_FFFF) return { U32, (uint)mag };
				if (!c.positive && mag <= 0x8000_0000) return { I32, (uint)(int)(0 - (long)mag) };
			}
	}
	BigIntSpace space;
	BigIntConst big = canonical_int(repr.to_big_int(&space));
	uint limbs_index = (uint)self.limbs.len();
	self.limbs.push(copy_slice(self.gpa, big.limbs));
	InternerTag tag = big.positive ? INT_POSITIVE : INT_NEGATIVE;
	return { tag, self.add_extra(limbs_index, (uint)big.limbs.len) };
}

<* Tag.F80.pack *>
fn uint Interner.add_f80(&self, F80Bits b) => self.add_extra((uint)b.lo, (uint)(b.lo >> 32), b.hi);

<* Tag.F128.pack *>
fn uint Interner.add_f128(&self, F128Bits b)
{
	return self.add_extra((uint)b.lo, (uint)(b.lo >> 32), (uint)b.hi, (uint)(b.hi >> 32));
}

fn InternerItem Interner.put_float(&self, KeyFloat f)
{
	switch (f.tag)
	{
		case F16: return { F16, f.f16 };
		case F32: return { F32, f.f32 };
		case F64: return { F64, self.add_extra((uint)f.f64, (uint)(f.f64 >> 32)) };
		case F80: return { F80, self.add_f80(f.f80) };
		case F128: return { F128, self.add_f128(f.f128) };
	}
}

fn InternerItem Interner.put_complex(&self, KeyComplex c)
{
	switch (c.tag)
	{
		case CF16:
			// Tag.CF16.pack: real in the high half.
			return { CF16, self.add_extra((uint)c.cf16[0] << 16 | (uint)c.cf16[1]) };
		case CF32:
			return { CF32, self.add_extra(c.cf32[0], c.cf32[1]) };
		case CF64:
			ulong re = c.cf64[0];
			ulong im = c.cf64[1];
			return { CF64, self.add_extra((uint)re, (uint)(re >> 32), (uint)im, (uint)(im >> 32)) };
		case CF80:
			uint at = self.add_f80(c.cf80[0]);
			self.add_f80(c.cf80[1]);
			return { CF80, at };
		case CF128:
			uint at = self.add_f128(c.cf128[0]);
			self.add_f128(c.cf128[1]);
			return { CF128, at };
	}
}

<* Insert item `index` with hash `h` into the open-addressing table, growing it at 3/4 load. *>
fn void Interner.index_insert(&self, uint index, uint h)
{
	if ((usz)(index + 1) * 4 > (usz)self.table.len * 3)
	{
		sz new_len = self.table.len ? self.table.len * 2 : 16;
		if (self.table.len) alloc::free(self.gpa, self.table.ptr);
		self.table = alloc::new_array(self.gpa, uint, new_len);
		self.table[..] = 0;
		// Re-add every existing item; the new one is added below.
		for (uint i = 0; i < index; i++) self.table_place(i, self.hashes[i]);
	}
	self.table_place(index, h);
}

fn void Interner.table_place(&self, uint index, uint h)
{
	usz mask = self.table.len - 1;
	usz slot = (usz)h & mask;
	while (self.table[slot] != 0) slot = (slot + 1) & mask;
	self.table[slot] = index + 1;
}

<* Tag.F80.get as bits *>
fn F80Bits Interner.f80_at(&self, uint at)
{
	return { .lo = (ulong)self.extra[(sz)at] | (ulong)self.extra[(sz)at + 1] << 32, .hi = (ushort)self.extra[(sz)at + 2] };
}

<* Tag.F128.get as bits *>
fn F128Bits Interner.f128_at(&self, uint at)
{
	return {
		.lo = (ulong)self.extra[(sz)at] | (ulong)self.extra[(sz)at + 1] << 32,
		.hi = (ulong)self.extra[(sz)at + 2] | (ulong)self.extra[(sz)at + 3] << 32,
	};
}

<* Two consecutive `extra` words, low first (PackedU64 / Tag.F64). *>
fn ulong Interner.u64_at(&self, uint at) => (ulong)self.extra[(sz)at] | (ulong)self.extra[(sz)at + 1] << 32;

<*
 Interner.get: the key for `ref`. Slices in the result stay valid until `free`.
 Zig quirk kept: REF_CF128 has no case in Zig's `get` (it would index `items`);
 treat it as unreachable.
*>
fn InternerKey Interner.get(&self, InternerRef ref)
{
	if (ref.is_static())
	{
		switch (ref)
		{
			case REF_PTR: return key_simple(PTR_TY);
			case REF_FUNC: return key_simple(FUNC_TY);
			case REF_NORETURN: return key_simple(NORETURN_TY);
			case REF_VOID: return key_simple(VOID_TY);
			case REF_I1: return key_int_ty(1);
			case REF_I8: return key_int_ty(8);
			case REF_I16: return key_int_ty(16);
			case REF_I32: return key_int_ty(32);
			case REF_I64: return key_int_ty(64);
			case REF_I128: return key_int_ty(128);
			case REF_F16: return key_float_ty(16);
			case REF_F32: return key_float_ty(32);
			case REF_F64: return key_float_ty(64);
			case REF_F80: return key_float_ty(80);
			case REF_F128: return key_float_ty(128);
			case REF_ZERO: return key_u64(0);
			case REF_ONE: return key_u64(1);
			case REF_NULL: return key_simple(NULL);
			case REF_CF16: return key_complex_ty(16);
			case REF_CF32: return key_complex_ty(32);
			case REF_CF64: return key_complex_ty(64);
			case REF_CF80: return key_complex_ty(80);
			default: unreachable("Interner.get: REF_CF128 has no key (Zig quirk)");
		}
	}

	InternerItem item = self.items[(sz)(uint)ref];
	uint data = item.data;
	switch (item.tag)
	{
		case INT_TY: return key_int_ty((ushort)data);
		case FLOAT_TY: return key_float_ty((ushort)data);
		case COMPLEX_TY: return key_complex_ty((ushort)data);
		case ARRAY_TY:
			return key_array_ty(self.u64_at(data), (InternerRef)self.extra[(sz)data + 2]);
		case VECTOR_TY:
			return key_vector_ty(self.extra[(sz)data], (InternerRef)self.extra[(sz)data + 1]);
		case POINTER:
			return key_pointer(self.extra[(sz)data], (InternerRef)self.extra[(sz)data + 1]);
		case U32: return key_u64(data);
		case I32: return key_i64((int)data);
		case INT_POSITIVE:
		case INT_NEGATIVE:
			Limb[] limbs = self.limbs[(sz)self.extra[(sz)data]];
			return key_big_int({ .limbs = limbs, .positive = item.tag == INT_POSITIVE });
		case F16: return key_float({ .tag = F16, .f16 = (ushort)data });
		case F32: return key_float({ .tag = F32, .f32 = data });
		case F64: return key_float({ .tag = F64, .f64 = self.u64_at(data) });
		case F80: return key_float({ .tag = F80, .f80 = self.f80_at(data) });
		case F128: return key_float({ .tag = F128, .f128 = self.f128_at(data) });
		case CF16:
			uint p = self.extra[(sz)data];
			return key_complex({ .tag = CF16, .cf16 = { (ushort)(p >> 16), (ushort)p } });
		case CF32:
			return key_complex({ .tag = CF32, .cf32 = { self.extra[(sz)data], self.extra[(sz)data + 1] } });
		case CF64:
			return key_complex({ .tag = CF64, .cf64 = { self.u64_at(data), self.u64_at(data + 2) } });
		case CF80:
			return key_complex({ .tag = CF80, .cf80 = { self.f80_at(data), self.f80_at(data + 3) } });
		case CF128:
			return key_complex({ .tag = CF128, .cf128 = { self.f128_at(data), self.f128_at(data + 4) } });
		case BYTES:
			return key_bytes(self.strings[(sz)self.extra[(sz)data]]);
		case RECORD_TY:
			return key_record_ty(self.records[(sz)self.extra[(sz)data + 1]]);
	}
}
