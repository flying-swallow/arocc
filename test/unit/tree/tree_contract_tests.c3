// Tests for the plan 16 stage-0 contract code that is implemented (not
// stubbed): the optional-index and packed-element helpers, the tag enums'
// counts/order/mapping (which the docs/c3-tree-tags.md table mirrors) and
// the bit layouts of DeclAttr / GnuAsmQualifiers / DiagnosticPack.
// Expected values are source-derived from Tree.zig, Attribute.zig and
// Attribute/Map.zig; no Zig executable was run.
module tree_contract_tests;
import aro::tree, aro::type_store, aro::attribute, aro::attribute_map, aro::symbol_stack;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void opt_index_helpers() @test
{
	NodeOptIndex n = type_store::NODE_NULL;
	assert(n.is_null());
	assert(!@ok(n.unpack()));
	NodeIndex i = (NodeIndex)7;
	NodeOptIndex p = i.pack();
	assert(!p.is_null());
	check(p.unwrap(), 7);
	check(p.unpack()!!, 7);
	check(tree::pack_opt_index(type_store::NODE_NULL), 0xFFFF_FFFF);
	check(tree::unpack_opt_index(5), 5);
}

fn void packed_elems() @test
{
	NodeIndex[2] two = { (NodeIndex)3, (NodeIndex)9 };
	check(tree::pack_elem(two[..], 0), 3);
	check(tree::pack_elem(two[..], 1), 9);
	check(tree::pack_elem(two[..], 2), 0xFFFF_FFFF);
	uint[3] data = { 4, 0xFFFF_FFFF, 0xFFFF_FFFF };
	NodeIndex[] elems = tree::unpack_elems(data[..]);
	check(elems.len, 1);
	check(elems[0], 4);
	uint[3] full = { 1, 2, 3 };
	check(tree::unpack_elems(full[..]).len, 3);
	uint[3] none = { 0xFFFF_FFFF, 0, 0 };
	check(tree::unpack_elems(none[..]).len, 0);
}

fn void tag_counts() @test
{
	// Tree.zig: 118 Node variants, 31 Cast kinds. (Zig's 146 Repr tags are
	// NodeKind + NodeForm bits here.)
	check(NodeKind::len, 118);
	check(CastKind::len, 31);
	// Attribute.zig: 104 Args tags; Map.zig: 35 Repr tags.
	check(AttributeTag::len, 104);
	check(AttrReprTag::len, 35);
	check(AttrGnu::len, 98);
	check(AttrClang::len, 25);
	check(AttrKeyword::len, 25);
	check(AttrDeclspec::len, 20);
	check(AttrStandard::len, 8);
}

fn void tag_mapping() @test
{
	assert(NodeKind.TYPEDEF.name == "typedef");
	assert(NodeKind.CAST.family == EXPR);
	assert(NodeKind.DECL_STMT.family == STMT);
	assert(NodeKind.CODEGEN_DIAGNOSTIC.family == DECL);
	assert(CastKind.LVAL_TO_RVAL.name == "lval_to_rval");
	assert(AttributeTag.WARN_UNUSED_RESULT.name == "warn_unused_result");
	assert(AttrGnu.__CONST.name == "__const");
	assert(AttrStandard._NORETURN.name == "_Noreturn");
	assert(AttrKeyword._ALIGNAS.name == "_Alignas");
	assert(AttrMode.BND64.name == "BND64");
	assert(AttrMode::len == 59);
}

fn void bit_layouts() @test
{
	// NodeData views overlay the same three words (Zig Repr.data: [3]u32).
	check(NodeData::size, 12);
	check(NodeRepr::size, 20);
	NodeData data;
	data.binary = { .lhs = (NodeIndex)7, .rhs = (NodeIndex)9 };
	check(data.words[1], 7);
	check(data.for_stmt.body, 9);
	DeclAttr a = { .is_static = true, .register = true };
	check((uint)a, 0b100010);
	GnuAsmQualifiers q = { .is_inline = true, .is_goto = true };
	check((uint)q, 0b110);
	DiagnosticPack d = { .is_warning = true, .attribute_warning = true };
	check((uint)d, 0b11);
}

fn void node_construction() @test
{
	Node n = { .kind = BOOL_LITERAL, .literal = { .literal_tok = 3, .qt = type_store::BOOL } };
	check(n.literal.literal_tok, 3);
	assert(n.literal.qt == type_store::BOOL);
	Attribute attr = { .args = { .tag = SECTION, .section = "text" }, .syntax = GNU, .name = { .ns = GNU, .gnu = SECTION }, .tok = 4 };
	assert(attr.args.section == "text");
	Symbol s = { .kind = TYPEDEF, .node = (NodeIndex)1 };
	check(s.node, 1);
}
