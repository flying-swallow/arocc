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
	*self = { .gpa = gpa };
	self.attributes.init(gpa);
	self.extra.init(gpa);
	self.decl_attrs.init(gpa);
}

<* Zig `deinit`; resets to `{}`. *>
fn void AttributeMap.free(&self)
{
	self.attributes.free();
	self.extra.free();
	self.decl_attrs.free();
	*self = {};
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
	AttributeArgs args = attribute.args;
	AttrRepr repr = { .tag = PACKED, .data = attribute.tok, .syntax = attribute.syntax, .name = attribute.name };
	switch (args.tag)
	{
		case PACKED: repr.tag = PACKED;
		case HOT: repr.tag = HOT;
		case COLD: repr.tag = COLD;
		case CONST: repr.tag = CONST;
		case TRANSPARENT_UNION: repr.tag = TRANSPARENT_UNION;
		case DESIGNATED_INIT: repr.tag = DESIGNATED_INIT;
		case FALLTHROUGH: repr.tag = FALLTHROUGH;
		case NORETURN: repr.tag = NORETURN;
		case ALWAYS_INLINE: repr.tag = ALWAYS_INLINE;
		case GNU_INLINE: repr.tag = GNU_INLINE;
		case WEAK: repr.tag = WEAK;
		case SELECTANY: repr.tag = SELECTANY;
		case INTERNAL_LINKAGE: repr.tag = INTERNAL_LINKAGE;
		case UNSEQUENCED: repr.tag = UNSEQUENCED;
		case REPRODUCIBLE: repr.tag = REPRODUCIBLE;
		case UNUSED: repr.tag = UNUSED;
		case ALIGNMENT:
			if (args.alignment.has_alignment) { repr.tag = ALIGNMENT; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.extra.push(args.alignment.alignment); }
			else repr.tag = ALIGNMENT_NULL;
		case DEPRECATED:
			if (args.deprecated.has_replacement) { repr.tag = DEPRECATED_REPLACEMENT; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.deprecated.msg); self.put_string(args.deprecated.replacement); }
			else if (args.deprecated.has_msg) { repr.tag = DEPRECATED_REASON; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.deprecated.msg); }
			else repr.tag = DEPRECATED;
		case UNAVAILABLE:
			if (args.unavailable.has_msg) { repr.tag = UNAVAILABLE_REASON; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.unavailable.msg); }
			else repr.tag = UNAVAILABLE;
		case WARNING: repr.tag = WARNING; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.warning);
		case ERROR: repr.tag = ERROR; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.error_msg);
		case WARN_UNUSED_RESULT:
			if (args.warn_unused_result.has_msg) { repr.tag = WARN_UNUSED_RESULT_MSG; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.warn_unused_result.msg); }
			else repr.tag = WARN_UNUSED_RESULT;
		case NONNULL:
			if (!args.nonnull.len) repr.tag = NONNULL_ZERO;
			else { repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); if (args.nonnull.len == 1) { repr.tag = NONNULL_ONE; self.extra.push(args.nonnull[0]); } else { repr.tag = NONNULL; self.extra.push((uint)args.nonnull.len); foreach (v : args.nonnull) self.extra.push(v); } }
		case VISIBILITY:
			switch (args.visibility) { case DEFAULT: repr.tag = VISIBILITY_DEFAULT; case HIDDEN: repr.tag = VISIBILITY_HIDDEN; case PROTECTED: repr.tag = VISIBILITY_PROTECTED; }
		case CLEANUP: repr.tag = CLEANUP; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.extra.push((uint)args.cleanup.function);
		case SECTION: repr.tag = SECTION; repr.data = (uint)self.extra.len(); self.extra.push(attribute.tok); self.put_string(args.section);
		default: unreachable("unsupported attribute map payload");
	}
	uint index = (uint)self.attributes.len();
	self.attributes.push(repr);
	return (AttrRef)index;
}

<* Zig `get`: decode the attribute stored at `ref` (inverse of `put`). *>
fn Attribute AttributeMap.get(&self, AttrRef ref)
{
	AttrRepr r = self.attributes[(uint)ref];
	Attribute result = { .name = r.name, .syntax = r.syntax, .tok = (TokenIndex)r.data, .args = { .tag = PACKED } };
	uint next;
	switch (r.tag)
	{
		case PACKED: result.args.tag = PACKED;
		case HOT: result.args.tag = HOT;
		case COLD: result.args.tag = COLD;
		case CONST: result.args.tag = CONST;
		case TRANSPARENT_UNION: result.args.tag = TRANSPARENT_UNION;
		case DESIGNATED_INIT: result.args.tag = DESIGNATED_INIT;
		case FALLTHROUGH: result.args.tag = FALLTHROUGH;
		case NORETURN: result.args.tag = NORETURN;
		case ALWAYS_INLINE: result.args.tag = ALWAYS_INLINE;
		case GNU_INLINE: result.args.tag = GNU_INLINE;
		case WEAK: result.args.tag = WEAK;
		case SELECTANY: result.args.tag = SELECTANY;
		case INTERNAL_LINKAGE: result.args.tag = INTERNAL_LINKAGE;
		case UNSEQUENCED: result.args.tag = UNSEQUENCED;
		case REPRODUCIBLE: result.args.tag = REPRODUCIBLE;
		case UNUSED: result.args.tag = UNUSED;
		case ALIGNMENT_NULL: result.args.tag = ALIGNMENT; result.args.alignment = { .has_alignment = false };
		case ALIGNMENT: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = ALIGNMENT; result.args.alignment = { .has_alignment = true, .alignment = self.extra[r.data + 1] };
		case DEPRECATED: result.args.tag = DEPRECATED;
		case DEPRECATED_REASON: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = DEPRECATED; result.args.deprecated = { .has_msg = true, .msg = self.get_string(r.data + 1, &next) };
		case DEPRECATED_REPLACEMENT: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = DEPRECATED; result.args.deprecated = { .has_msg = true, .msg = self.get_string(r.data + 1, &next), .has_replacement = true, .replacement = self.get_string(next, &next) };
		case UNAVAILABLE: result.args.tag = UNAVAILABLE; result.args.unavailable = { .has_msg = false };
		case UNAVAILABLE_REASON: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = UNAVAILABLE; result.args.unavailable = { .has_msg = true, .msg = self.get_string(r.data + 1, &next) };
		case WARNING: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = WARNING; result.args.warning = self.get_string(r.data + 1, &next);
		case ERROR: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = ERROR; result.args.error_msg = self.get_string(r.data + 1, &next);
		case WARN_UNUSED_RESULT: result.args.tag = WARN_UNUSED_RESULT; result.args.warn_unused_result = { .has_msg = false };
		case WARN_UNUSED_RESULT_MSG: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = WARN_UNUSED_RESULT; result.args.warn_unused_result = { .has_msg = true, .msg = self.get_string(r.data + 1, &next) };
		case NONNULL_ZERO: result.args.tag = NONNULL; result.args.nonnull = self.extra.slice()[0 .. 0];
		case NONNULL_ONE: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = NONNULL; result.args.nonnull = self.extra.slice()[r.data + 1 .. r.data + 2];
		case NONNULL: result.tok = (TokenIndex)self.extra[r.data]; uint n = self.extra[r.data + 1]; result.args.tag = NONNULL; result.args.nonnull = self.extra.slice()[r.data + 2 .. r.data + 2 + n];
		case VISIBILITY_DEFAULT: result.args.tag = VISIBILITY; result.args.visibility = DEFAULT;
		case VISIBILITY_HIDDEN: result.args.tag = VISIBILITY; result.args.visibility = HIDDEN;
		case VISIBILITY_PROTECTED: result.args.tag = VISIBILITY; result.args.visibility = PROTECTED;
		case CLEANUP: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = CLEANUP; result.args.cleanup = { .function = (NodeIndex)self.extra[r.data + 1] };
		case SECTION: result.tok = (TokenIndex)self.extra[r.data]; result.args.tag = SECTION; result.args.section = self.get_string(r.data + 1, &next);
	}
	return result;
}

<* Zig `putString`: append [len, bytes padded to whole words] to `extra`. *>
fn void AttributeMap.put_string(&self, String str)
{
	uint len = (uint)str.len;
	self.extra.push(len);
	uint words = (len + 3) / 4;
	uint start = (uint)self.extra.len();
	for (uint i = 0; i < words; i++) self.extra.push(0);
	char* bytes = (char*)&self.extra[start];
	for (uint i = 0; i < len; i++) bytes[i] = str[i];
}

<*
 Zig `getString`: the string stored at extra[index] (aliases `extra`); sets
 `*next` to the index just after it.
*>
fn String AttributeMap.get_string(&self, uint index, uint* next)
{
	uint len = self.extra[index];
	uint words = (len + 3) / 4;
	*next = index + 1 + words;
	return ((char*)&self.extra[index + 1])[0 .. len];
}

<*
 Record the attributes applied to declaration `node`: append `refs` to
 `extra` and map node -> (start, refs.len), replacing any previous entry
 (Zig Wip.addAppliedAttrs).
*>
fn void AttributeMap.set_decl_attrs(&self, NodeIndex node, AttrRef[] refs)
{
	uint start = (uint)self.extra.len();
	foreach (r : refs) self.extra.push((uint)r);
	self.decl_attrs.set((uint)node, { .index = start, .len = (uint)refs.len });
}

<*
 Zig `attrs`: the refs recorded for `node` (empty for NODE_NULL or a node
 without attributes). Zig takes `anytype` (Index or OptIndex); pass
 `index.pack()` for a NodeIndex.
*>
fn AttrRef[] AttributeMap.attrs(&self, NodeOptIndex node)
{
	NodeIndex? idx = node.unpack();
	if (!idx) return self.extra.slice()[0 .. 0];
	AttrSpan? maybe_span = self.decl_attrs.get((uint)idx!);
	if (!maybe_span) return self.extra.slice()[0 .. 0];
	AttrSpan span = maybe_span!;
	return ((AttrRef*)self.extra.slice().ptr)[span.index .. span.index + span.len];
}

<* Zig `getAttribute`: the LAST attribute of `node` whose args tag is `tag`, else NO_ATTRIBUTE. *>
fn Attribute? AttributeMap.get_attribute(&self, NodeOptIndex node, AttributeTag tag)
{
	AttrRef[] list = self.attrs(node);
	for (usz i = list.len; i > 0; i--) { Attribute a = self.get(list[i - 1]); if (a.args.tag == tag) return a; }
	return NO_ATTRIBUTE~;
}

<*
 Zig `requestedAlignment`: the maximum over `node`'s ALIGNMENT attributes,
 a null alignment counting as `comp.target.default_alignment()`;
 NO_ATTRIBUTE when there is none.
*>
fn uint? AttributeMap.requested_alignment(&self, NodeOptIndex node, Compilation* comp)
{
	uint? max_value;
	foreach (ref : self.attrs(node)) { Attribute a = self.get(ref); if (a.args.tag != ALIGNMENT) continue; uint v = a.args.alignment.has_alignment ? a.args.alignment.alignment : comp.target.default_alignment(); if (!max_value || max_value! < v) max_value = v; }
	return max_value;
}

<* Zig `hasAttribute`: any attribute of `node` has args tag `tag`. *>
fn bool AttributeMap.has_attribute(&self, NodeOptIndex node, AttributeTag tag)
{
	foreach (ref : self.attrs(node)) if (self.get(ref).args.tag == tag) return true;
	return false;
}

<*
 TypeStore.zig `QualType.getAttribute`: attributes on the declarations of
 struct, union, enum and typedef types. Invalid -> NO_ATTRIBUTE; record /
 enum -> `get_attribute(decl_node)`; typeof -> its base; typedef -> its
 decl_node, then its base; anything else NO_ATTRIBUTE.
*>
fn Attribute? QualType.get_attribute(self, Tree* tree, AttributeTag tag)
{
	if (self.is_invalid()) return NO_ATTRIBUTE~;
	Type t = self.get_type(tree.comp);
	switch (t.tag)
	{
		case STRUCT: return tree.attr_map.get_attribute(t.record.decl_node, tag);
		case UNION: return tree.attr_map.get_attribute(t.record.decl_node, tag);
		case ENUM: return tree.attr_map.get_attribute((NodeOptIndex)t.enum_ty.decl_node, tag);
		case TYPEOF: return t.type_of.base.get_attribute(tree, tag);
		case TYPEDEF: return tree.attr_map.get_attribute((NodeOptIndex)t.type_def.decl_node, tag) ?? t.type_def.base.get_attribute(tree, tag);
		default: return NO_ATTRIBUTE~;
	}
}

<* TypeStore.zig `QualType.hasAttribute`. *>
fn bool QualType.has_attribute(self, Tree* tree, AttributeTag tag)
{
	return @ok(self.get_attribute(tree, tag));
}
