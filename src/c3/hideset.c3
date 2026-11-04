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
// Stage 0 (contract): the type, `init`/`free`/clear functions are implemented
// (the Preprocessor's lifecycle needs them); the list operations are stubs.
// The private field layout may be changed by 13.1 as long as the API stays.
//
// Ownership: everything is allocated from `comp.gpa` and released by `free`
// (Zig `deinit`). Lists are never freed individually: an Index stays valid
// until `clear_retaining_capacity` / `clear_and_free` / `free`.
//
// Deviations from Zig:
//  - Zig's `AutoHashMap(Identifier, ...)` key is packed into a `ulong`
//    (`identifier_key`: source id bits << 32 | byte_offset); same equality.
//  - `tmp_map` (a set) is a HashMap{ulong, bool}.
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
	unreachable("stage 0 stub");
}

<* Zig `put`: map `loc` (id, byte_offset) to `value`, replacing any previous head. *>
fn void Hideset.put(&self, Location loc, HidesetIndex value)
{
	unreachable("stage 0 stub");
}

<*
 Zig `prepend`: append a new item { identifier_from_location(loc), len, next = tail }
 to linked_list and return its index (the new head). `tail` is not copied.
*>
fn HidesetIndex Hideset.prepend(&self, Location loc, uint length, HidesetIndex tail)
{
	unreachable("stage 0 stub");
}

<*
 Zig `union` (`union` is a C3 keyword): attach the elements of `a` that are not in `b` to the front of `b`.
 a == NONE -> b; b == NONE -> a. Otherwise clear tmp_map, insert every
 identifier of `b`, then walk `a` in order and for each identifier not in
 tmp_map create a node { identifier, len, next = head } and make it the head
 (so the copied elements end up in REVERSE order of `a`, followed by `b`).
 Reserve len(a) items first so the walk is not invalidated.
*>
fn HidesetIndex Hideset.union_of(&self, HidesetIndex a, HidesetIndex b)
{
	unreachable("stage 0 stub");
}

<*
 Zig `intersection`: NONE if either is NONE. Otherwise clear tmp_map, insert
 every identifier of `a`, reserve min(len(a), len(b)) items, then walk `b`
 and for each identifier in tmp_map append a node { identifier, len,
 next = NONE }, linking it after the previous one (order of `b`). Returns the
 first created node or NONE.
*>
fn HidesetIndex Hideset.intersection(&self, HidesetIndex a, HidesetIndex b)
{
	unreachable("stage 0 stub");
}

<*
 Zig `contains`: whether any item of `list` spells `str`, comparing `str`
 with comp.get_source(item.identifier.id).buf[byte_offset : len].
*>
fn bool Hideset.contains(&self, HidesetIndex list, String str)
{
	unreachable("stage 0 stub");
}

<* Zig `len`: number of items in `list`. *>
fn usz Hideset.len(&self, HidesetIndex list)
{
	unreachable("stage 0 stub");
}
