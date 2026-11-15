// Port of src/aro/StringInterner.zig, plus `StringTable`, the insertion-ordered
// string -> index set that stands in for Zig's StringArrayHashMapUnmanaged.
module aro::string_interner;
import std::collections::list, std::hash::fnv32a;

excuse NOT_FOUND;

<*
 Insertion-ordered set of strings with dense `uint` indices (0, 1, 2, ...).
 Keys are BORROWED: the table stores the slices it is given and never copies
 or frees the bytes, so the caller must keep them alive (and unmoved) for as
 long as the table is used. Growing the table never moves key bytes.
*>
struct StringTable
{
	Allocator allocator;
	List{String} keys;
	<* Open-addressing slots: 0 = empty, otherwise key index + 1. Length is 0 or a power of two. *>
	uint[] slots;
}

fn void StringTable.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.keys.init(allocator);
}

fn void StringTable.free(&self)
{
	self.keys.free();
	if (self.slots.len) alloc::free(self.allocator, self.slots.ptr);
	*self = {};
}

fn sz StringTable.len(&self) @inline => self.keys.len();

fn String StringTable.key(&self, uint index) @inline => self.keys[index];

fn String[] StringTable.key_slice(&self) => self.keys.array_view();

fn uint? StringTable.find(&self, String key)
{
	if (!self.slots.len) return NOT_FOUND~;
	sz mask = self.slots.len - 1;
	sz slot = fnv32a::hash(key) & mask;
	while (true)
	{
		uint entry = self.slots[slot];
		if (!entry) return NOT_FOUND~;
		if (self.keys[(sz)entry - 1] == key) return entry - 1;
		slot = (slot + 1) & mask;
	}
}

fn void StringTable.grow(&self)
{
	sz new_len = self.slots.len ? self.slots.len * 2 : 16;
	if (self.slots.len) alloc::free(self.allocator, self.slots.ptr);
	self.slots = alloc::new_array(self.allocator, uint, new_len);
	sz mask = new_len - 1;
	foreach (i, k : self.keys)
	{
		sz slot = fnv32a::hash(k) & mask;
		while (self.slots[slot]) slot = (slot + 1) & mask;
		self.slots[slot] = (uint)i + 1;
	}
}

<*
 Return the index of `key`, inserting it (borrowed) if missing.
 @param [out] found_existing : "Set to whether the key was already present"
 @require self.keys.len() < uint::max - 1 : "Table is full"
*>
fn uint StringTable.get_or_put(&self, String key, bool* found_existing = null)
{
	if (try idx = self.find(key))
	{
		if (found_existing) *found_existing = true;
		return idx;
	}
	if (found_existing) *found_existing = false;
	if ((self.keys.len() + 1) * 2 > self.slots.len) self.grow();
	uint index = (uint)self.keys.len();
	self.keys.push(key);
	sz mask = self.slots.len - 1;
	sz slot = fnv32a::hash(key) & mask;
	while (self.slots[slot]) slot = (slot + 1) & mask;
	self.slots[slot] = index + 1;
	return index;
}

<* Interned string handle. `EMPTY` stands for "" and is never stored. *>
typedef StringId = uint;

const StringId EMPTY = (StringId)uint::max;

struct StringInterner
{
	StringTable table;
}

fn void StringInterner.init(&self, Allocator allocator)
{
	self.table.init(allocator);
}

fn void StringInterner.free(&self)
{
	self.table.free();
}

<* Intern an externally owned string. The bytes are borrowed, not copied. *>
fn StringId StringInterner.intern(&self, String str)
{
	if (!str.len) return EMPTY;
	return (StringId)self.table.get_or_put(str);
}

fn String StringId.lookup_extra(self, StringInterner* si)
{
	if (self == EMPTY) return "";
	return si.table.key((uint)self);
}
