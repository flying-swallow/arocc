// Port of src/backend/Interner.zig: the constant/IR-type interner behind Value.
//
// OWNER: plan 09 stage 1 agent 09.1 `interner`. Stage 0 (contract) fixed the key,
// handle and storage layouts and the public signatures; `put`, `get`, `hash` and
// `eql` are stubs. `init`/`free` are real so `Compilation` can own an Interner.
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
	unreachable("stage 0 stub: KeyInt.to_big_int");
}

<*
 Key.toBigInt
 @require self.tag == INT
*>
fn BigIntConst InternerKey.to_big_int(self, BigIntSpace* space) => self.int_val.to_big_int(space);

<* Key.hash (32-bit). Need not match Wyhash bit-for-bit (ref numbering does not depend on it), but must be consistent with `eql`. *>
fn uint InternerKey.hash(self)
{
	unreachable("stage 0 stub: InternerKey.hash");
}

<* Key.eql *>
fn bool InternerKey.eql(a, InternerKey b)
{
	unreachable("stage 0 stub: InternerKey.eql");
}

<* Key.toRef: the static ref for keys that have one; NO_STATIC_REF otherwise. *>
excuse NO_STATIC_REF;
fn InternerRef? InternerKey.to_ref(self)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub: Interner.put");
}

<*
 Interner.get: the key for `ref`. Slices in the result stay valid until `free`.
 Zig quirk kept: REF_CF128 has no case in Zig's `get` (it would index `items`);
 treat it as unreachable.
*>
fn InternerKey Interner.get(&self, InternerRef ref)
{
	unreachable("stage 0 stub: Interner.get");
}
