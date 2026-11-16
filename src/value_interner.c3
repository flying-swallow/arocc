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
// type (INT_POSITIVE / INT_NEGATIVE, F16..F128, CF16..CF128) and the payload is:
//   - ints: `limbs`, the Zig-normalized magnitude (no leading zero limbs, at least
//     one limb; zero is `[0]` and INT_POSITIVE);
//   - floats: inline `fbits`, the IEEE/x87 bit pattern; bits above the width are zero;
//   - complexes: inline `cbits` = { real, imaginary } bit patterns.
// Int keys built outside the interner (primitive_value::int_key) put their limbs in `tmem`; float
// and complex keys never allocate. `put` copies every slice it stores (floats are
// stored as owned limb slices: 1 limb up to 64 bits, 2 (lo, hi) for f80/f128,
// real then imaginary for complexes), so callers keep ownership.
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
import aro::bigint, aro::primitive_value, std::collections::list, std::io;

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


<*
 Interner.Tag.Int.BigIntSpace: big enough for any 64-bit int, plus one limb of
 headroom so a single increment/decrement needs no allocator.
*>
struct BigIntSpace
{
	Limb[bigint::SMALL_LIMBS] limbs;
}

fn uint128 limbs_bits(Limb[] limbs) @local
{
	if (limbs.len == 0) return 0;
	if (limbs.len == 1) return limbs[0];
	return (uint128)limbs[0] | (uint128)limbs[1] << 64;
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
	PrimitiveType tag;
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
fn InternerRef Interner.put(&self, PrimitiveValue key)
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
			BigIntConst big = primitive_value::normalized_int(key.to_big_int());
			item = { big.positive ? INT_POSITIVE : INT_NEGATIVE, self.add_limbs(big.limbs) };
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			sz n = key.tag.float_limbs();
			Limb[2] buf = { (Limb)key.fbits, (Limb)(key.fbits >> 64) };
			item = { key.tag, self.add_limbs(buf[:n]) };
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			sz n = key.tag.float_limbs();
			Limb[4] buf;
			buf[0] = (Limb)key.cbits[0];
			buf[n] = (Limb)key.cbits[1];
			if (n == 2)
			{
				buf[1] = (Limb)(key.cbits[0] >> 64);
				buf[3] = (Limb)(key.cbits[1] >> 64);
			}
			item = { key.tag, self.add_limbs(buf[:2 * n]) };
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
fn PrimitiveValue Interner.get(&self, InternerRef ref)
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
			case REF_ZERO: return { .tag = INT_POSITIVE, .limbs = primitive_value::zero_limbs[..] };
			case REF_ONE: return { .tag = INT_POSITIVE, .limbs = primitive_value::one_limbs[..] };
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
	PrimitiveType tag = item.tag;
	if (tag.kind == NumberKind.INT) return { .tag = tag, .limbs = self.limbs[(sz)data] };
	if (tag.kind == NumberKind.FLOAT) return { .tag = tag, .fbits = limbs_bits(self.limbs[(sz)data]) };
	if (tag.kind == NumberKind.COMPLEX)
	{
		Limb[] l = self.limbs[(sz)data];
		sz n = tag.float_limbs();
		return { .tag = tag, .cbits = { limbs_bits(l[:n]), limbs_bits(l[n:n]) } };
	}
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
