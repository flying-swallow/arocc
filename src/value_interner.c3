// Port of src/backend/Interner.zig: the constant/IR-type interner behind Value.
//
// OWNER: plan 09 stage 1 agent 09.1 `interner`. Stage 0 (contract) fixed the
// handle layout and the public signatures; 09.1 implemented them.
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
// Keys. Deviation from Zig: numeric keys are flat. The key tag carries the whole
// type (INT_POSITIVE / INT_NEGATIVE, F16..F128, CF16..CF128) and `limbs` carries
// the payload:
//   - ints: Zig-normalized magnitude (no leading zero limbs, at least one limb;
//     zero is `[0]` and INT_POSITIVE);
//   - floats: the IEEE/x87 bit pattern, 1 limb up to 64 bits, 2 limbs (lo, hi)
//     for f80/f128; bits above the width are zero;
//   - complexes: the real component's limbs followed by the imaginary's.
// Keys built outside the interner (int_key, float_key, float arithmetic) put their
// limbs in `tmem`; `put` copies every slice it stores, so callers keep ownership.
//
// Invariants implementers must keep:
//   - `put(key)` first maps static keys to static refs exactly like Zig `Key.toRef`
//     (int 0 / float +0.0 -> REF_ZERO, int 1 / float 1.0 -> REF_ONE, NULL -> REF_NULL,
//     int_ty 1/8/16/32/64/128, float_ty, complex_ty, ptr/func/noreturn/void). Note the
//     Zig quirk this implies: interning float 1.0 yields REF_ONE, and `get(REF_ONE)`
//     is the *int* 1. Keep it.
//   - Deduplication: two keys that are `eql` get the same ref; `hash` is consistent
//     with `eql`. Ints compare by mathematical value (canonical limbs, so a
//     non-normalized or negative-zero key still matches).
//   - Float/complex keys compare bit patterns with Zig's value comparison
//     (`std.meta.eql` uses `==`): a key containing a NaN never equals anything (so
//     NaNs are never deduplicated); otherwise equal bits mean equal.
//   - Stability (stronger than Zig, required by CONVENTIONS.md): slices inside a Key
//     returned by `get` (bytes, record_ty elements, limbs) stay valid until `free`,
//     even across later `put`s. Hence each such payload is its own owned heap
//     allocation (`limbs`/`strings`/`records` lists of slices below), never a slice
//     into a growing List backing array.
//   - `extra` keeps Zig's u32 field layout for the remaining fixed-size payloads
//     (Array, Vector, Pointer, Bytes, Record); numeric payloads index `limbs`.
//   - Running out of memory panics (no faults); `free` releases everything.
module aro::value_interner;
import aro::bigint, std::collections::list, std::io, std::hash::metro64;

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

<* Coarse class of a key tag, for switches that only care about int / float / complex. *>
enum NumberKind : char
{
	NOT_NUMBER,
	INT,
	FLOAT,
	COMPLEX,
}

<*
 std.meta.Tag(Interner.Key) with the int/float/complex payload tags flattened in.
 kind: number class of the payload (NOT_NUMBER for types, null, bytes, pointers).
 width: bit width of a float, or of one complex component; 0 otherwise.
*>
enum InternerKeyTag : char (NumberKind kind, ushort width)
{
	INT_TY       { NOT_NUMBER, 0 },
	FLOAT_TY     { NOT_NUMBER, 0 },
	COMPLEX_TY   { NOT_NUMBER, 0 },
	PTR_TY       { NOT_NUMBER, 0 },
	NORETURN_TY  { NOT_NUMBER, 0 },
	VOID_TY      { NOT_NUMBER, 0 },
	FUNC_TY      { NOT_NUMBER, 0 },
	ARRAY_TY     { NOT_NUMBER, 0 },
	VECTOR_TY    { NOT_NUMBER, 0 },
	RECORD_TY    { NOT_NUMBER, 0 },
	<* Zig `.null`: the nullptr constant (may not be zero). *>
	NULL         { NOT_NUMBER, 0 },
	<* Integer >= 0; `limbs` is the normalized magnitude. *>
	INT_POSITIVE { INT, 0 },
	<* Integer < 0; `limbs` is the normalized magnitude. *>
	INT_NEGATIVE { INT, 0 },
	F16          { FLOAT, 16 },
	F32          { FLOAT, 32 },
	F64          { FLOAT, 64 },
	F80          { FLOAT, 80 },
	F128         { FLOAT, 128 },
	CF16         { COMPLEX, 16 },
	CF32         { COMPLEX, 32 },
	CF64         { COMPLEX, 64 },
	CF80         { COMPLEX, 80 },
	CF128        { COMPLEX, 128 },
	BYTES        { NOT_NUMBER, 0 },
	POINTER      { NOT_NUMBER, 0 },
}

<* Every float tag, narrowest first (the old KeyFloatTag::values). *>
const InternerKeyTag[5] FLOAT_TAGS = { F16, F32, F64, F80, F128 };

fn bool InternerKeyTag.is_int(self) => self.kind == INT;
fn bool InternerKeyTag.is_float(self) => self.kind == FLOAT;
fn bool InternerKeyTag.is_complex(self) => self.kind == COMPLEX;
<* Whether the key's payload is `limbs`. *>
fn bool InternerKeyTag.has_limbs(self) => self.kind != NOT_NUMBER;

<*
 The scalar float tag of a float or complex tag (CF64 -> F64, F64 -> F64).
 @require self.is_float() || self.is_complex()
*>
fn InternerKeyTag InternerKeyTag.scalar(self) => self.is_complex() ? float_tag_of_width(self.width) : self;

<*
 The complex tag over float tag `self` (F64 -> CF64).
 @require self.is_float()
*>
fn InternerKeyTag InternerKeyTag.complex(self) => InternerKeyTag::values[self.ordinal - InternerKeyTag.F16.ordinal + InternerKeyTag.CF16.ordinal];

<*
 Limbs per float (or per complex component).
 @require self.is_float() || self.is_complex()
*>
fn sz InternerKeyTag.float_limbs(self) => self.width <= 64 ? 1 : 2;

<* The float tag of bit width `bits` (16/32/64/80/128). *>
fn InternerKeyTag float_tag_of_width(uint bits)
{
	switch (bits)
	{
		case 16: return F16;
		case 32: return F32;
		case 64: return F64;
		case 80: return F80;
		case 128: return F128;
		default: unreachable("unsupported float width");
	}
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

// Float bit views. Both are uint128-backed bitstructs, so neither has internal
// padding (c3c can drop padding bytes when it copies an aggregate by value).

<* f80 bits: `lo` = bits 0..63 (explicit-integer-bit mantissa), `hi` = bits 64..79 (sign + exponent); 80..127 zero. *>
bitstruct F80Bits : uint128
{
	ulong lo : 0..63;
	ushort hi : 64..79;
}

<* f128 bits: `lo` = bits 0..63, `hi` = bits 64..127. *>
bitstruct F128Bits : uint128
{
	ulong lo : 0..63;
	ulong hi : 64..127;
}

<* Interner.Key: a tag plus its payload; numeric tags use `limbs`. *>
struct InternerKey (Printable)
{
	InternerKeyTag tag;
	union
	{
		<* INT_TY / FLOAT_TY / COMPLEX_TY: bit width. *>
		ushort ty_bits;
		KeyArrayTy array_ty;
		KeyVectorTy vector_ty;
		InternerRef[] record_ty;
		char[] bytes;
		KeyPointer pointer;
		<* INT_*, F*, CF*: see the module header for the layout. *>
		Limb[] limbs;
	}
}

<*
 Interner.Tag.Int.BigIntSpace: big enough for any 64-bit int, plus one limb of
 headroom so a single increment/decrement needs no allocator.
*>
struct BigIntSpace
{
	Limb[bigint::SMALL_LIMBS] limbs;
}

// Shared limbs for the static int refs (never written).
Limb[1] zero_limbs @local = { 0 };
Limb[1] one_limbs @local = { 1 };

// Integer keys.

<* An integer key for `v` (limbs in tmem; zero and one use static limbs). *>
fn InternerKey int_key(int128 v)
{
	if (v == 0) return { .tag = INT_POSITIVE, .limbs = zero_limbs[..] };
	if (v == 1) return { .tag = INT_POSITIVE, .limbs = one_limbs[..] };
	bool negative = v < 0;
	// Two's-complement negation in uint128 handles int128::min.
	uint128 mag = negative ? (uint128)0 - (uint128)v : (uint128)v;
	return mag_key(negative, mag);
}

<* An integer key for unsigned `v` (limbs in tmem). *>
fn InternerKey uint_key(uint128 v)
{
	if (v == 0) return { .tag = INT_POSITIVE, .limbs = zero_limbs[..] };
	return mag_key(false, v);
}

fn InternerKey mag_key(bool negative, uint128 mag) @local
{
	sz n = mag >> 64 != 0 ? 2 : 1;
	Limb[] limbs = alloc::new_array(tmem, Limb, n);
	limbs[0] = (Limb)mag;
	if (n == 2) limbs[1] = (Limb)(mag >> 64);
	return { .tag = negative ? INT_NEGATIVE : INT_POSITIVE, .limbs = limbs };
}

<* An integer key viewing `big`'s limbs (no copy; leading zero limbs are dropped). *>
fn InternerKey big_int_key(BigIntConst big)
{
	BigIntConst c = normalized_int(big);
	return { .tag = c.positive ? INT_POSITIVE : INT_NEGATIVE, .limbs = c.limbs };
}

<*
 Key.toBigInt: a view of the key's limbs (no copy).
 @require self.tag.is_int()
*>
fn BigIntConst InternerKey.to_big_int(self) => { .limbs = self.limbs, .positive = self.tag == INT_POSITIVE };

<* @require self.tag.is_int() *>
fn bool InternerKey.int_is_zero(self) => canonical_int(self.to_big_int()).limbs.len == 0;

<*
 Whether the integer fits in 64 bits as either u64 or i64 (the old `.u64` / `.i64` key forms).
 @require self.tag.is_int()
*>
fn bool InternerKey.int_fits_64(self)
{
	BigIntConst c = canonical_int(self.to_big_int());
	if (c.limbs.len == 0) return true;
	if (c.limbs.len > 1) return false;
	return c.positive || c.limbs[0] <= 0x8000_0000_0000_0000;
}

<*
 The low 64 bits of the integer in two's complement (wraps when wider).
 @require self.tag.is_int()
*>
fn ulong InternerKey.int_low_u64(self)
{
	BigIntConst c = canonical_int(self.to_big_int());
	ulong low = c.limbs.len > 0 ? c.limbs[0] : 0;
	return c.positive ? low : 0 - low;
}

// Float and complex keys.

<* `bits` truncated to the width of float tag `tag`. *>
fn uint128 float_width_bits(InternerKeyTag tag, uint128 bits) @local
{
	uint w = tag.width;
	return w >= 128 ? bits : bits & (((uint128)1 << w) - 1);
}

<*
 A float key holding bit pattern `bits` (limbs in tmem; bits above the width are dropped).
 @require tag.is_float()
*>
fn InternerKey float_key(InternerKeyTag tag, uint128 bits)
{
	bits = float_width_bits(tag, bits);
	Limb[] limbs = alloc::new_array(tmem, Limb, tag.float_limbs());
	limbs[0] = (Limb)bits;
	if (limbs.len == 2) limbs[1] = (Limb)(bits >> 64);
	return { .tag = tag, .limbs = limbs };
}

fn uint128 limbs_bits(Limb[] limbs) @local
{
	if (limbs.len == 0) return 0;
	if (limbs.len == 1) return limbs[0];
	return (uint128)limbs[0] | (uint128)limbs[1] << 64;
}

<*
 The float's bit pattern, zero-extended to 128 bits.
 @require self.tag.is_float()
*>
fn uint128 InternerKey.float_bits(self) => limbs_bits(self.limbs);

fn ushort InternerKey.f16(self) => (ushort)self.float_bits();
fn uint InternerKey.f32(self) => (uint)self.float_bits();
fn ulong InternerKey.f64(self) => (ulong)self.float_bits();
fn F80Bits InternerKey.f80(self) => (F80Bits)self.float_bits();
fn F128Bits InternerKey.f128(self) => (F128Bits)self.float_bits();

<*
 A complex key from two floats of the same width (limbs in tmem).
 @require re.tag.is_float() && re.tag == im.tag
*>
fn InternerKey complex_key(InternerKey re, InternerKey im)
{
	sz n = re.tag.float_limbs();
	Limb[] limbs = alloc::new_array(tmem, Limb, 2 * n);
	uint128 r = float_width_bits(re.tag, re.float_bits());
	uint128 i = float_width_bits(re.tag, im.float_bits());
	limbs[0] = (Limb)r;
	limbs[n] = (Limb)i;
	if (n == 2)
	{
		limbs[1] = (Limb)(r >> 64);
		limbs[3] = (Limb)(i >> 64);
	}
	return { .tag = re.tag.complex(), .limbs = limbs };
}

<* @require self.tag.is_complex() *>
fn InternerKey InternerKey.re(self)
{
	sz n = self.tag.float_limbs();
	return { .tag = self.tag.scalar(), .limbs = self.limbs[:n] };
}

<* @require self.tag.is_complex() *>
fn InternerKey InternerKey.im(self)
{
	sz n = self.tag.float_limbs();
	return { .tag = self.tag.scalar(), .limbs = self.limbs[n:n] };
}

<* Integers print in decimal; other keys print their tag. *>
fn sz? InternerKey.to_format(&self, Formatter* f) @dynamic
{
	if (self.tag.is_int()) return f.print(self.to_big_int().to_string_alloc(tmem, 10, false));
	return f.printf("%s", self.tag);
}

// Integer helpers. These read limbs directly instead of calling bigint queries so
// the interner does not depend on the bigint implementation.

<* Canonical view of `big`: no leading zero limbs, zero has no limbs and is positive. *>
fn BigIntConst canonical_int(BigIntConst big) @local
{
	sz n = big.limbs.len;
	while (n > 0 && big.limbs[n - 1] == 0) n--;
	return { .limbs = big.limbs[:n], .positive = n == 0 || big.positive };
}

<* Zig-normalized view of `big`: as canonical_int, but zero is `[0]`. *>
fn BigIntConst normalized_int(BigIntConst big) @local
{
	BigIntConst c = canonical_int(big);
	if (c.limbs.len == 0) return { .limbs = zero_limbs[..], .positive = true };
	return c;
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

<* Whether bit pattern `bits` of float tag `tag` is a NaN. *>
fn bool bits_are_nan(InternerKeyTag tag, uint128 bits) @local
{
	switch (tag)
	{
		case F16: return f16_is_nan((ushort)bits);
		case F32: return f32_is_nan((uint)bits);
		case F64: return f64_is_nan((ulong)bits);
		case F80: return f80_is_nan((F80Bits)bits);
		case F128: return f128_is_nan((F128Bits)bits);
		default: unreachable("not a float tag");
	}
}

<* std.meta.eql on one float: equal bits, never equal when NaN. *>
fn bool float_bits_eql(InternerKeyTag tag, Limb[] a, Limb[] b) @local
{
	uint128 x = float_width_bits(tag, limbs_bits(a));
	return x == float_width_bits(tag, limbs_bits(b)) && !bits_are_nan(tag, x);
}

<* Key.hash (32-bit, folded MetroHash64). Need not match Zig's Wyhash bit-for-bit (ref numbering does not depend on it), but must be consistent with `eql`. Fields are fed one at a time so union and struct padding never reach the hash. *>
fn uint InternerKey.hash(self)
{
	MetroHash64 hs;
	hs.init(0x243F_6A88_85A3_08D3);
	if (self.tag.is_int())
	{
		// The sign comes from the canonical value so negative zero hashes as zero.
		BigIntConst big = canonical_int(self.to_big_int());
		InternerKeyTag int_tag = INT_POSITIVE;
		hs.update(@as_char_view(int_tag));
		hs.update(@as_char_view(big.positive));
		hs.update(((char*)big.limbs.ptr)[:big.limbs.len * @sizeof(big.limbs[0])]);
		return (uint)hs.final();
	}
	hs.update(@as_char_view(self.tag));
	switch (self.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			hs.update(@as_char_view(self.ty_bits));
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			break;
		case ARRAY_TY:
			hs.update(@as_char_view(self.array_ty.len));
			hs.update(@as_char_view(self.array_ty.child));
		case VECTOR_TY:
			hs.update(@as_char_view(self.vector_ty.len));
			hs.update(@as_char_view(self.vector_ty.child));
		case RECORD_TY:
			InternerRef[] fields = self.record_ty;
			sz fields_len = fields.len;
			hs.update(@as_char_view(fields_len));
			hs.update(((char*)fields.ptr)[:fields_len * @sizeof(fields[0])]);
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			uint128 b = float_width_bits(self.tag, self.float_bits());
			hs.update(@as_char_view(b));
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			InternerKeyTag s = self.tag.scalar();
			uint128 r = float_width_bits(s, self.re().float_bits());
			uint128 i = float_width_bits(s, self.im().float_bits());
			hs.update(@as_char_view(r));
			hs.update(@as_char_view(i));
		case BYTES:
			char[] bytes = self.bytes;
			sz bytes_len = bytes.len;
			hs.update(@as_char_view(bytes_len));
			hs.update(bytes);
		case POINTER:
			hs.update(@as_char_view(self.pointer.node));
			hs.update(@as_char_view(self.pointer.offset));
		case INT_POSITIVE:
		case INT_NEGATIVE:
			unreachable();
	}
	return (uint)hs.final();
}

<*
 Key.eql. Ints compare by mathematical value; floats and complexes compare their
 bit patterns, and a NaN component never compares equal (Zig `std.meta.eql` uses
 `==` on float payloads).
*>
fn bool InternerKey.eql(a, InternerKey b)
{
	if (a.tag.is_int() && b.tag.is_int())
	{
		return canonical_int_eql(canonical_int(a.to_big_int()), canonical_int(b.to_big_int()));
	}
	if (a.tag != b.tag) return false;
	switch (a.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			return a.ty_bits == b.ty_bits;
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
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			return float_bits_eql(a.tag, a.limbs, b.limbs);
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			InternerKeyTag s = a.tag.scalar();
			return float_bits_eql(s, a.re().limbs, b.re().limbs) && float_bits_eql(s, a.im().limbs, b.im().limbs);
		case BYTES:
			if (a.bytes.len != b.bytes.len) return false;
			foreach (i, c : a.bytes) if (c != b.bytes[i]) return false;
			return true;
		case POINTER:
			return a.pointer.node == b.pointer.node && a.pointer.offset == b.pointer.offset;
		case INT_POSITIVE:
		case INT_NEGATIVE:
			unreachable();
	}
}

<* Key.toRef: the static ref for keys that have one; NO_STATIC_REF otherwise. *>
excuse NO_STATIC_REF;
fn InternerRef? InternerKey.to_ref(self)
{
	switch (self.tag)
	{
		case INT_TY:
			switch (self.ty_bits)
			{
				case 1: return REF_I1;
				case 8: return REF_I8;
				case 16: return REF_I16;
				case 32: return REF_I32;
				case 64: return REF_I64;
				case 128: return REF_I128;
			}
		case FLOAT_TY:
			switch (self.ty_bits)
			{
				case 16: return REF_F16;
				case 32: return REF_F32;
				case 64: return REF_F64;
				case 80: return REF_F80;
				case 128: return REF_F128;
				default: unreachable("float_ty with unsupported bit width");
			}
		case COMPLEX_TY:
			switch (self.ty_bits)
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
		case INT_POSITIVE:
		case INT_NEGATIVE:
			BigIntConst big = canonical_int(self.to_big_int());
			if (big.limbs.len == 0) return REF_ZERO;
			if (big.positive && big.limbs.len == 1 && big.limbs[0] == 1) return REF_ONE;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			// isPositiveZero(x) -> zero; x == 1 -> one (compared as the bit pattern of 1.0).
			uint128 b = float_width_bits(self.tag, self.float_bits());
			if (b == 0) return REF_ZERO;
			uint128 one;
			switch (self.tag)
			{
				case F16: one = 0x3C00;
				case F32: one = 0x3F80_0000;
				case F64: one = 0x3FF0_0000_0000_0000;
				case F80: one = 0x3FFF_8000_0000_0000_0000;
				default: one = 0x3FFF_0000_0000_0000_0000_0000_0000_0000;
			}
			if (b == one) return REF_ONE;
		default:
			break;
	}
	return NO_STATIC_REF~;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

// Items store the key tag directly. `data` holds:
//   INT_TY / FLOAT_TY / COMPLEX_TY: ushort bits
//   INT_*, F*, CF*: index into `limbs`
//   ARRAY_TY / VECTOR_TY / BYTES / RECORD_TY / POINTER: extra index of the Tag* struct
// The static-only tags (PTR_TY, NORETURN_TY, VOID_TY, FUNC_TY, NULL) never appear.

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
	InternerKeyTag tag;
	uint data;
}

struct Interner
{
	Allocator gpa;
	<* Indexed by InternerRef (non-static). *>
	List{InternerItem} items;
	List{uint} extra;
	<* Owned limb slices of numeric keys (item.data). *>
	List{Limb[]} limbs;
	<* Owned byte slices (TagBytes.strings_index). *>
	List{char[]} strings;
	<* Owned element slices of record types (TagRecord.records_index). *>
	List{InternerRef[]} records;
	<*
	 Hash index over `items` (Zig's AutoArrayHashMap(void, void) with KeyAdapter):
	 `hashes[i]` = hash of item i and an open-addressing `table` of item indices
	 (+1, 0 = empty).
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
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			item = { key.tag, key.ty_bits };
		case ARRAY_TY:
			// Tag.Array: PackedU64 split, low half first.
			ulong len = key.array_ty.len;
			item = { ARRAY_TY, self.add_extra((uint)len, (uint)(len >> 32), (uint)key.array_ty.child) };
		case VECTOR_TY:
			item = { VECTOR_TY, self.add_extra(key.vector_ty.len, (uint)key.vector_ty.child) };
		case POINTER:
			item = { POINTER, self.add_extra(key.pointer.node, (uint)key.pointer.offset) };
		case INT_POSITIVE:
		case INT_NEGATIVE:
			BigIntConst big = normalized_int(key.to_big_int());
			item = { big.positive ? INT_POSITIVE : INT_NEGATIVE, self.add_limbs(big.limbs) };
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			item = { key.tag, self.add_limbs(key.limbs[:key.tag.float_limbs()]) };
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			item = { key.tag, self.add_limbs(key.limbs[:2 * key.tag.float_limbs()]) };
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

<* Store an owned copy of `limbs`, returning its index in `self.limbs`. *>
fn uint Interner.add_limbs(&self, Limb[] limbs)
{
	uint index = (uint)self.limbs.len();
	self.limbs.push(copy_slice(self.gpa, limbs));
	return index;
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

<* Two consecutive `extra` words, low first (PackedU64). *>
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
			case REF_PTR: return { .tag = PTR_TY };
			case REF_FUNC: return { .tag = FUNC_TY };
			case REF_NORETURN: return { .tag = NORETURN_TY };
			case REF_VOID: return { .tag = VOID_TY };
			case REF_I1: return { .tag = INT_TY, .ty_bits = 1 };
			case REF_I8: return { .tag = INT_TY, .ty_bits = 8 };
			case REF_I16: return { .tag = INT_TY, .ty_bits = 16 };
			case REF_I32: return { .tag = INT_TY, .ty_bits = 32 };
			case REF_I64: return { .tag = INT_TY, .ty_bits = 64 };
			case REF_I128: return { .tag = INT_TY, .ty_bits = 128 };
			case REF_F16: return { .tag = FLOAT_TY, .ty_bits = 16 };
			case REF_F32: return { .tag = FLOAT_TY, .ty_bits = 32 };
			case REF_F64: return { .tag = FLOAT_TY, .ty_bits = 64 };
			case REF_F80: return { .tag = FLOAT_TY, .ty_bits = 80 };
			case REF_F128: return { .tag = FLOAT_TY, .ty_bits = 128 };
			case REF_ZERO: return { .tag = INT_POSITIVE, .limbs = zero_limbs[..] };
			case REF_ONE: return { .tag = INT_POSITIVE, .limbs = one_limbs[..] };
			case REF_NULL: return { .tag = NULL };
			case REF_CF16: return { .tag = COMPLEX_TY, .ty_bits = 16 };
			case REF_CF32: return { .tag = COMPLEX_TY, .ty_bits = 32 };
			case REF_CF64: return { .tag = COMPLEX_TY, .ty_bits = 64 };
			case REF_CF80: return { .tag = COMPLEX_TY, .ty_bits = 80 };
			default: unreachable("Interner.get: REF_CF128 has no key (Zig quirk)");
		}
	}

	InternerItem item = self.items[(sz)(uint)ref];
	uint data = item.data;
	InternerKeyTag tag = item.tag;
	if (tag.has_limbs()) return { .tag = tag, .limbs = self.limbs[(sz)data] };
	switch (tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			return { .tag = tag, .ty_bits = (ushort)data };
		case ARRAY_TY:
			return { .tag = ARRAY_TY, .array_ty = { .len = self.u64_at(data), .child = (InternerRef)self.extra[(sz)data + 2] } };
		case VECTOR_TY:
			return { .tag = VECTOR_TY, .vector_ty = { .len = self.extra[(sz)data], .child = (InternerRef)self.extra[(sz)data + 1] } };
		case POINTER:
			return { .tag = POINTER, .pointer = { .node = self.extra[(sz)data], .offset = (InternerRef)self.extra[(sz)data + 1] } };
		case BYTES:
			return { .tag = BYTES, .bytes = self.strings[(sz)self.extra[(sz)data]] };
		case RECORD_TY:
			return { .tag = RECORD_TY, .record_ty = self.records[(sz)self.extra[(sz)data + 1]] };
		default:
			unreachable("Interner.get: corrupt item tag");
	}
}
