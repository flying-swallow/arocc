// Port of src/aro/Attribute/Map.zig: compact attribute storage (one `AttrRepr`
// per attribute, variable data in `extra`), the per-declaration attribute
// lists and the queries over them (`attrs`, `getAttribute`, `hasAttribute`,
// `requestedAlignment`), plus TypeStore.zig `QualType.getAttribute` /
// `hasAttribute` which need the map — plan 16 stage 1 agent 16.5
// `attributes`.
//
// Layout (Zig, kept word for word; docs/c3-tree-tags.md section 5):
//  - `AttrRepr.data` is the attribute's token for tags without extra data;
//    otherwise an index into `extra` whose first word is the token.
//  - ALIGNMENT: extra [tok, alignment]. NONNULL_ONE: [tok, pos].
//    NONNULL: [tok, len, positions...]. CLEANUP: [tok, function node].
//    DEPRECATED_REPLACEMENT: [tok, str(msg), str(replacement)].
//    DEPRECATED_REASON, UNAVAILABLE_REASON, WARNING, ERROR,
//    WARN_UNUSED_RESULT_MSG, SECTION: [tok, str(msg)].
//  - A string `str(s)` is [s.len, ceil(s.len / 4) words of bytes] (Zig
//    `putString`; trailing pad bytes unspecified, zero here).
//  - `decl_attrs` maps a declaration node to an `AttrSpan` of `AttrRef`s
//    stored in `extra` (Zig Wip.addAppliedAttrs appends them; here
//    `set_decl_attrs`).
//  - Strings and slices returned by `get` alias `extra` and stay valid until
//    the map grows.
//  - Attribute args other than the tags in `AttrReprTag` are Zig
//    `@panic("TODO")` in `put`; keep that as unreachable.
//
// Stage 0 (contract): types and signatures only.
module aro::attribute_map;
import aro::attribute, aro::tokens, aro::type_store, aro::compilation, aro::tree;
import std::collections::list, std::collections::map;

<* Zig `null` from `getAttribute` / `requestedAlignment`. *>
excuse NO_ATTRIBUTE;

<* Zig `Map.Ref` (enum(u32) { _ }). *>
typedef AttrRef = uint;

<* Zig `Map.Repr.Tag` (enum(u8)), in Zig order. *>
enum AttrReprTag : char
{
	PACKED,
	HOT,
	COLD,
	CONST,
	ALIGNMENT,
	ALIGNMENT_NULL,
	DEPRECATED_REPLACEMENT,
	DEPRECATED_REASON,
	DEPRECATED,
	UNAVAILABLE_REASON,
	UNAVAILABLE,
	WARNING,
	ERROR,
	WARN_UNUSED_RESULT_MSG,
	WARN_UNUSED_RESULT,
	NONNULL_ZERO,
	NONNULL_ONE,
	NONNULL,
	TRANSPARENT_UNION,
	DESIGNATED_INIT,
	FALLTHROUGH,
	VISIBILITY_DEFAULT,
	VISIBILITY_HIDDEN,
	VISIBILITY_PROTECTED,
	NORETURN,
	CLEANUP,
	ALWAYS_INLINE,
	GNU_INLINE,
	SECTION,
	WEAK,
	SELECTANY,
	INTERNAL_LINKAGE,
	UNSEQUENCED,
	REPRODUCIBLE,
	UNUSED,
}

<* Zig `Map.Repr`. *>
struct AttrRepr
{
	AttrReprTag tag;
	uint data;
	AttributeSyntax syntax;
	Namespaced name;
}

<* Zig `decl_attrs` value `struct { u32, u32 }`: start index in `extra` and count. *>
struct AttrSpan
{
	uint index;
	uint len;
}

<* Zig `Attribute.Map`. Create with `init`, release with `free`. *>
struct AttributeMap
{
	Allocator gpa;
	List{AttrRepr} attributes;
	List{uint} extra;
	<* Keyed by `(uint)NodeIndex` (C3 HashMap needs a hashable key). *>
	HashMap{uint, AttrSpan} decl_attrs;
}

fn void AttributeMap.init(&self, Allocator gpa)
{
	unreachable("stage 0 stub");
}

<* Zig `deinit`; resets to `{}`. *>
fn void AttributeMap.free(&self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `put`: store `attribute` compactly (see the module comment) and return
 its ref. Void-payload tags PACKED, HOT, COLD, CONST, TRANSPARENT_UNION,
 DESIGNATED_INIT, FALLTHROUGH, NORETURN, ALWAYS_INLINE, GNU_INLINE, WEAK,
 SELECTANY, INTERNAL_LINKAGE, UNSEQUENCED, REPRODUCIBLE, UNUSED map to the
 same-named repr tag; ALIGNMENT null -> ALIGNMENT_NULL; DEPRECATED with
 replacement (requires msg) -> DEPRECATED_REPLACEMENT, with msg only ->
 DEPRECATED_REASON, else DEPRECATED; UNAVAILABLE -> UNAVAILABLE_REASON /
 UNAVAILABLE; WARN_UNUSED_RESULT -> WARN_UNUSED_RESULT_MSG /
 WARN_UNUSED_RESULT; NONNULL by position count 0 / 1 / more ->
 NONNULL_ZERO / NONNULL_ONE / NONNULL; VISIBILITY -> VISIBILITY_DEFAULT /
 _HIDDEN / _PROTECTED; CLEANUP, SECTION, WARNING, ERROR. Any other tag is
 unreachable (Zig `@panic("TODO")`).
*>
fn AttrRef AttributeMap.put(&self, Attribute attribute)
{
	unreachable("stage 0 stub");
}

<* Zig `get`: decode the attribute stored at `ref` (inverse of `put`). *>
fn Attribute AttributeMap.get(&self, AttrRef ref)
{
	unreachable("stage 0 stub");
}

<* Zig `putString`: append [len, bytes padded to whole words] to `extra`. *>
fn void AttributeMap.put_string(&self, String str)
{
	unreachable("stage 0 stub");
}

<*
 Zig `getString`: the string stored at extra[index] (aliases `extra`); sets
 `*next` to the index just after it.
*>
fn String AttributeMap.get_string(&self, uint index, uint* next)
{
	unreachable("stage 0 stub");
}

<*
 Record the attributes applied to declaration `node`: append `refs` to
 `extra` and map node -> (start, refs.len), replacing any previous entry
 (Zig Wip.addAppliedAttrs).
*>
fn void AttributeMap.set_decl_attrs(&self, NodeIndex node, AttrRef[] refs)
{
	unreachable("stage 0 stub");
}

<*
 Zig `attrs`: the refs recorded for `node` (empty for NODE_NULL or a node
 without attributes). Zig takes `anytype` (Index or OptIndex); pass
 `index.pack()` for a NodeIndex.
*>
fn AttrRef[] AttributeMap.attrs(&self, NodeOptIndex node)
{
	unreachable("stage 0 stub");
}

<* Zig `getAttribute`: the LAST attribute of `node` whose args tag is `tag`, else NO_ATTRIBUTE. *>
fn Attribute? AttributeMap.get_attribute(&self, NodeOptIndex node, AttributeTag tag)
{
	unreachable("stage 0 stub");
}

<*
 Zig `requestedAlignment`: the maximum over `node`'s ALIGNMENT attributes,
 a null alignment counting as `comp.target.default_alignment()`;
 NO_ATTRIBUTE when there is none.
*>
fn uint? AttributeMap.requested_alignment(&self, NodeOptIndex node, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Zig `hasAttribute`: any attribute of `node` has args tag `tag`. *>
fn bool AttributeMap.has_attribute(&self, NodeOptIndex node, AttributeTag tag)
{
	unreachable("stage 0 stub");
}

<*
 TypeStore.zig `QualType.getAttribute`: attributes on the declarations of
 struct, union, enum and typedef types. Invalid -> NO_ATTRIBUTE; record /
 enum -> `get_attribute(decl_node)`; typeof -> its base; typedef -> its
 decl_node, then its base; anything else NO_ATTRIBUTE.
*>
fn Attribute? QualType.get_attribute(self, Tree* tree, AttributeTag tag)
{
	unreachable("stage 0 stub");
}

<* TypeStore.zig `QualType.hasAttribute`. *>
fn bool QualType.has_attribute(self, Tree* tree, AttributeTag tag)
{
	unreachable("stage 0 stub");
}
