// AST dump smoke checks. Format expectations are source-derived from
// src/aro/Tree.zig; no Zig executable was run.
module tree_dump_tests;
import aro::frontend::c::compilation, aro::frontend::c::tree, aro::frontend::c::diagnostics;
import aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::source, aro::frontend::c::type_store, aro::frontend::c::attribute, aro::frontend::c::attribute_map;
import std::core::mem::allocators, std::core::dstring, std::io;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

excuse DUMP_WRITE_FAILED;

struct RejectWriter (OutStream)
{
	bool fail_write;
	bool fail_byte;
	bool fail_flush;
}

fn sz? RejectWriter.write(&self, char[] bytes) @dynamic
{
	if (self.fail_write) return DUMP_WRITE_FAILED~;
	return bytes.len;
}

fn void? RejectWriter.write_byte(&self, char byte) @dynamic
{
	if (self.fail_byte) return DUMP_WRITE_FAILED~;
}

fn void? RejectWriter.flush(&self) @dynamic
{
	if (self.fail_flush) return DUMP_WRITE_FAILED~;
}

fn void empty_tree_dump_is_empty() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		{
			Tree tree;
			tree.init(&comp, {});
			DString output;
			output.init(&ta);
			tree.dump(&output, false)!!;
			assert(output.str_view().len == 0);
			output.free();
			tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

// Source-derived from Tree.zig dumpNode and write: the source buffer supplies
// each token slice, while the manually built nodes exercise the dump APIs.
fn void source_locations_and_expression_write() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		Source src = comp.add_source_from_buffer("expr.c", "x + 1\n")!!;
		tokens::TreeToken[3] toks = {
			{ .id = tokenizer::TokenId.IDENTIFIER, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } },
			{ .id = tokenizer::TokenId.PLUS, .loc = { .id = src.id, .byte_offset = 2, .line = 1 } },
			{ .id = tokenizer::TokenId.PP_NUM, .loc = { .id = src.id, .byte_offset = 4, .line = 1 } },
		};
		Tree tree;
		tree.init(&comp, toks[..]);
		NodeIndex lhs = tree.add_node({ .kind = DECL_REF_EXPR, .decl_ref = { .name_tok = 0, .qt = type_store::INT } });
		NodeIndex rhs = tree.add_node({ .kind = INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::INT } });
		NodeIndex add = tree.add_node({ .kind = ADD_EXPR, .binary = { .lhs = lhs, .op_tok = 1, .rhs = rhs, .qt = type_store::INT } });
		tree.root_decls.push(add);
		DString rendered;
		rendered.init(&ta);
		tree.write(add, &rendered);
		check(rendered.str_view(), "x + 1");
		DString output;
		output.init(&ta);
		tree.dump(&output, false)!!;
		check(output.str_view(),
			"add_expr: 'int'\n"
			" lhs:\n"
			"  decl_ref_expr: 'int' lvalue\n"
			"   name: x\n"
			" rhs:\n"
			"  int_literal: 'int'\n"
			"\n"); // Zig Tree.dump writes a newline after every root declaration.
		output.free();
		rendered.free();
		tree.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void attribute_order_and_no_color_format() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		Tree tree;
		tree.init(&comp, {});
		NodeIndex literal = tree.add_node({ .kind = INT_LITERAL, .literal = { .literal_tok = 0, .qt = type_store::INT } });
		Attribute packed = { .args = { .tag = PACKED }, .syntax = GNU, .name = { .ns = GNU, .gnu = PACKED } };
		Attribute unused = { .args = { .tag = UNUSED }, .syntax = GNU, .name = { .ns = GNU, .gnu = UNUSED } };
		AttrRef[2] refs = { tree.attr_map.put(packed), tree.attr_map.put(unused) };
		tree.attr_map.set_decl_attrs(literal, refs[..]);
		tree.root_decls.push(literal);
		DString output;
		output.init(&ta);
		tree.dump(&output, false)!!;
		check(output.str_view(), "int_literal: 'int'\n packed\n unused\n\n");
		output.free();
		tree.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void writer_errors_propagate() @test
{
	Compilation comp;
	comp.init(mem, compilation::native_definition());
	Tree tree;
	tree.init(&comp, {});
	NodeIndex literal = tree.add_node({ .kind = INT_LITERAL, .literal = { .literal_tok = 0, .qt = type_store::INT } });
	tree.root_decls.push(literal);
	RejectWriter write_failure = { .fail_write = true };
	assert(@catch(tree.dump(&write_failure, false)) == DUMP_WRITE_FAILED);
	RejectWriter byte_failure = { .fail_byte = true };
	assert(@catch(tree.dump(&byte_failure, false)) == DUMP_WRITE_FAILED);
	RejectWriter flush_failure = { .fail_flush = true };
	assert(@catch(tree.dump(&flush_failure, false)) == DUMP_WRITE_FAILED);
	tree.free();
	comp.free();
}
