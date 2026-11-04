// Port of src/aro/Hideset.zig. OWNER: plan 13.1 `hideset`.
//
// A hideset is a linked list (implemented as an array so that elements are
// identified by 4-byte indices) of the set of identifiers from which a token
// was expanded. During macro expansion, if a token would otherwise be expanded,
// but its hideset contains the token itself, then it is not expanded. Most
// tokens have an empty hideset, and the hideset is not needed once expansion
// is complete, so a hash map from token location to list head stores them
// instead of storing them with the token. Algorithm:
// https://www.spinellis.gr/blog/20060626/cpp.algo.pdf
//
// Implemented by 13.1 (stage 0 provided the type and init/free/clear).
//
// Ownership: everything is allocated from `comp.gpa` and released by `free`
// (Zig `deinit`). Lists are never freed individually: an Index stays valid
// until `clear_retaining_capacity` / `clear_and_free` / `free`.
//
// Deviations from Zig:
//  - Zig's `AutoHashMap(Identifier, ...)` key is packed into a `ulong`
//    (`identifier_key`: source id bits << 32 | byte_offset); same equality.
//  - `tmp_map` (a set) is a HashMap{ulong, bool}.
//  - Zig's Iterator over the MultiArrayList is replaced by index walks that
//    re-read linked_list on every step, so appends cannot invalidate them.
module aro::hideset;
import aro::source, aro::compilation, std::collections::list, std::collections::map;

<* Zig `Hideset.Index`: a list head; NONE is the empty list. *>
typedef HidesetIndex = uint;

<* Zig `Index.none` (maxInt(u32)). *>
const HidesetIndex NONE = (HidesetIndex)0xFFFF_FFFF;

<* Zig `Hideset.Identifier`: the location of a macro name. Default: unused id, offset 0. *>
struct HidesetIdentifier
{
	SourceId id;
	uint byte_offset;
}

<* Zig `Identifier.fromLocation`. *>
fn HidesetIdentifier identifier_from_location(Location loc) => { .id = loc.id, .byte_offset = loc.byte_offset };

<* The packed hash-map key of an identifier (equal keys <=> equal identifiers). *>
fn ulong HidesetIdentifier.key(self) => (ulong)(uint)self.id << 32 | self.byte_offset;

<* Zig `Hideset.Item`. *>
struct HidesetItem
{
	HidesetIdentifier identifier;
	<* Byte length of the identifier text at `identifier`. *>
	uint len;
	HidesetIndex next;
}

<* Zig `Hideset`. *>
struct Hideset
{
	Compilation* comp;
	<* Location key -> list head. *>
	HashMap{ulong, HidesetIndex} map;
	<* Used for computing union/intersection of two lists; kept to retain allocations. *>
	HashMap{ulong, bool} tmp_map;
	<* Zig `linked_list` (a MultiArrayList(Item)); Index is the position. *>
	List{HidesetItem} linked_list;
}

<* Set up an empty hideset; allocations come from `comp.gpa`. *>
fn void Hideset.init(&self, Compilation* comp)
{
	*self = { .comp = comp };
	self.map.init(comp.gpa);
	self.tmp_map.init(comp.gpa);
	self.linked_list.init(comp.gpa);
}

<* Zig `deinit`. *>
fn void Hideset.free(&self)
{
	self.map.free();
	self.tmp_map.free();
	self.linked_list.free();
	*self = {};
}

<* Zig `clearRetainingCapacity`: drop all lists and the map (tmp_map is kept, as in Zig). *>
fn void Hideset.clear_retaining_capacity(&self)
{
	self.linked_list.clear();
	self.map.clear();
}

<* Zig `clearAndFree`: drop everything and release the memory; the hideset stays usable. *>
fn void Hideset.clear_and_free(&self)
{
	Compilation* comp = self.comp;
	self.free();
	self.init(comp);
}

<*
 Zig `get`: the list head stored for `loc` (by id and byte_offset only), or NONE.
*>
fn HidesetIndex Hideset.get(&self, Location loc)
{
	return self.map.get(identifier_from_location(loc).key()) ?? NONE;
}

<* Zig `put`: map `loc` (id, byte_offset) to `value`, replacing any previous head. *>
fn void Hideset.put(&self, Location loc, HidesetIndex value)
{
	self.map.set(identifier_from_location(loc).key(), value);
}

<* Zig `createNodeAssumeCapacityExtra`: append { identifier, len, next } and return its index. *>
fn HidesetIndex Hideset.create_node(&self, HidesetIdentifier identifier, HidesetIndex next, uint length)
{
	sz new_idx = self.linked_list.len();
	assert(new_idx < 0xFFFF_FFFF, "hideset index overflow");
	self.linked_list.push({ .identifier = identifier, .len = length, .next = next });
	return (HidesetIndex)(uint)new_idx;
}

<*
 Zig `prepend`: append a new item { identifier_from_location(loc), len, next = tail }
 to linked_list and return its index (the new head). `tail` is not copied.
*>
fn HidesetIndex Hideset.prepend(&self, Location loc, uint length, HidesetIndex tail)
{
	return self.create_node(identifier_from_location(loc), tail, length);
}

<*
 Zig `union` (`union` is a C3 keyword). Despite Zig's doc comment ("attach
 elements of `b` to the front of `a`"), the code attaches the elements of `a`
 that are not in `b` to the front of `b`; that is what is ported.
 a == NONE -> b; b == NONE -> a. Otherwise clear tmp_map, insert every
 identifier of `b`, then walk `a` in order and for each identifier not in
 tmp_map create a node { identifier, len, next = head } and make it the head
 (so the copied elements end up in REVERSE order of `a`, followed by `b`).
 Duplicates within `a` itself are not removed (as in Zig). Neither input is
 modified.
*>
fn HidesetIndex Hideset.union_of(&self, HidesetIndex a, HidesetIndex b)
{
	if (a == NONE) return b;
	if (b == NONE) return a;
	self.tmp_map.clear();

	for (HidesetIndex i = b; i != NONE; i = self.linked_list[(sz)i].next)
	{
		self.tmp_map.set(self.linked_list[(sz)i].identifier.key(), true);
	}

	HidesetIndex head = b;
	self.linked_list.reserve((sz)self.len(a));
	for (HidesetIndex i = a; i != NONE; i = self.linked_list[(sz)i].next)
	{
		HidesetItem item = self.linked_list[(sz)i];
		if (!self.tmp_map.has_key(item.identifier.key()))
		{
			head = self.create_node(item.identifier, head, item.len);
		}
	}
	return head;
}

<*
 Zig `intersection`: NONE if either is NONE. Otherwise clear tmp_map, insert
 every identifier of `a`, reserve min(len(a), len(b)) items, then walk `b`
 and for each identifier in tmp_map append a node { identifier, len,
 next = NONE }, linking it after the previous one (order of `b`). Returns the
 first created node or NONE. Duplicates within `b` are kept (as in Zig).
*>
fn HidesetIndex Hideset.intersection(&self, HidesetIndex a, HidesetIndex b)
{
	if (a == NONE || b == NONE) return NONE;
	self.tmp_map.clear();

	usz a_len = 0;
	for (HidesetIndex i = a; i != NONE; i = self.linked_list[(sz)i].next)
	{
		self.tmp_map.set(self.linked_list[(sz)i].identifier.key(), true);
		a_len++;
	}
	usz b_len = self.len(b);
	self.linked_list.reserve((sz)(a_len < b_len ? a_len : b_len));

	HidesetIndex cur = NONE;
	HidesetIndex head = NONE;
	for (HidesetIndex i = b; i != NONE; i = self.linked_list[(sz)i].next)
	{
		HidesetItem item = self.linked_list[(sz)i];
		if (self.tmp_map.has_key(item.identifier.key()))
		{
			HidesetIndex new_idx = self.create_node(item.identifier, NONE, item.len);
			if (head == NONE) head = new_idx;
			if (cur != NONE) self.linked_list[(sz)cur].next = new_idx;
			cur = new_idx;
		}
	}
	return head;
}

<*
 Zig `contains`: whether any item of `list` spells `str`, comparing `str`
 with comp.get_source(item.identifier.id).buf[byte_offset : len].
*>
fn bool Hideset.contains(&self, HidesetIndex list, String str)
{
	for (HidesetIndex i = list; i != NONE; i = self.linked_list[(sz)i].next)
	{
		HidesetItem item = self.linked_list[(sz)i];
		String buf = self.comp.get_source(item.identifier.id).buf;
		usz start = item.identifier.byte_offset;
		if (str == buf[start:item.len]) return true;
	}
	return false;
}

<* Zig `len`: number of items in `list`. *>
fn usz Hideset.len(&self, HidesetIndex list)
{
	usz count = 0;
	for (HidesetIndex cur = list; cur != NONE; cur = self.linked_list[(sz)cur].next) count++;
	return count;
}
