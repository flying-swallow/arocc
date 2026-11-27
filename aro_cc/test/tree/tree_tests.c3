// Storage and handle checks for aro::frontend::c::tree. Expected tag and node values are
// source-derived from src/aro/Tree.zig; no Zig executable was run.
module tree_tests;
import aro::frontend::c::compilation, aro::frontend::c::tree, aro::frontend::c::type_store, aro::source, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::value;
import std::core::mem::allocators;

macro check(left, right)
{
	$if $Typeof(left) == String:
		test::eq(left, right);
	$else
		test::eq((long)left, (long)right);
	$endif
}

fn void empty_decl_round_trip_and_growth() @test
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
			NodeIndex first = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 0 } });
			check(first, 0);
			check(first.kind(&tree), NodeKind.EMPTY_DECL);
			Node got = first.get(&tree);
			check(got.kind, NodeKind.EMPTY_DECL);
			check(got.empty_decl.semicolon, 0);
			NodeIndex[2] compact_fields = { first, first };
			NodeIndex compact = tree.add_node({ .kind = NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 0, .container_qt = type_store::VOID, .fields = compact_fields[..] } });
			check(compact.kind(&tree), NodeKind.STRUCT_DECL); assert(compact.form(&tree).packed);
			check(compact.get(&tree).container_decl.fields.len, 2);
			NodeIndex[3] long_fields = { first, first, first };
			NodeIndex extended = tree.add_node({ .kind = NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 0, .container_qt = type_store::VOID, .fields = long_fields[..] } });
			check(extended.kind(&tree), NodeKind.STRUCT_DECL); assert(!extended.form(&tree).packed);
			uint first_added_index = (uint)tree.nodes.len();
			for (uint i = 0; i < 256; i++)
			{
				NodeIndex added = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = i } });
				check(added, first_added_index + i);
			}
			check(first.get(&tree).kind, NodeKind.EMPTY_DECL);
			check(first.get(&tree).empty_decl.semicolon, 0);
			Node decoded = extended.get(&tree);
			check(decoded.container_decl.fields.len, 3);
			check(decoded.container_decl.fields[2], first);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void declaration_expression_and_statement_round_trips() @test
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
			NodeIndex decl = tree.add_node({ .kind = NodeKind.VARIABLE, .variable = { .name_tok = 11, .qt = type_store::INT, .storage_class = VariableStorageClass.STATIC, .thread_local = true, .implicit = true, .initializer = type_store::NODE_NULL, .definition = (NodeOptIndex)(uint)7 } });
			check(decl.kind(&tree), NodeKind.VARIABLE); assert(!decl.form(&tree).defined);
			Node decoded_decl = decl.get(&tree);
			check(decoded_decl.variable.name_tok, 11);
			assert(decoded_decl.variable.qt == type_store::INT);
			check(decoded_decl.variable.storage_class, VariableStorageClass.STATIC);
			assert(decoded_decl.variable.thread_local && decoded_decl.variable.implicit);
			assert(decoded_decl.variable.initializer.is_null());
			check(decoded_decl.variable.definition.unwrap(), 7);
			assert(decoded_decl.is_implicit());

			NodeIndex lhs = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 21, .qt = type_store::INT } });
			NodeIndex rhs = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 22, .qt = type_store::INT } });
			NodeIndex sum = tree.add_node({ .kind = NodeKind.ADD_EXPR, .binary = { .qt = type_store::INT, .lhs = lhs, .op_tok = 23, .rhs = rhs } });
			check(sum.kind(&tree), NodeKind.ADD_EXPR);
			Node decoded_sum = sum.get(&tree);
			check(decoded_sum.binary.lhs, lhs);
			check(decoded_sum.binary.rhs, rhs);
			check(decoded_sum.binary.op_tok, 23);
			assert(sum.qt(&tree) == type_store::INT);
			assert(@ok(sum.qt_or_null(&tree)));
			assert(!tree.is_lval(sum));

			NodeIndex call = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 24, .qt = type_store::INT, .callee = sum, .args = { lhs, rhs } } });
			check(call.kind(&tree), NodeKind.CALL_EXPR); assert(!call.form(&tree).packed);
			Node decoded_call = call.get(&tree);
			check(decoded_call.call.callee, sum);
			check(decoded_call.call.args.len, 2);
			check(decoded_call.call.args[0], lhs);
			check(decoded_call.call.args[1], rhs);

			NodeIndex stmt = tree.add_node({ .kind = NodeKind.RETURN_STMT, .return_stmt = { .return_tok = 25, .return_qt = type_store::INT, .operand = ReturnOperandKind.EXPR, .expr = sum } });
			check(stmt.kind(&tree), NodeKind.RETURN_STMT);
			Node decoded_stmt = stmt.get(&tree);
			check(decoded_stmt.return_stmt.expr, sum);
			check(decoded_stmt.return_stmt.operand, ReturnOperandKind.EXPR);
			check(stmt.tok(&tree), 25);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void compact_expression_boundaries_and_borrowed_slices() @test
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
			NodeIndex callee = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			NodeIndex a = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::INT } });
			NodeIndex b = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 3, .qt = type_store::INT } });
			NodeIndex c = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 4, .qt = type_store::INT } });
			NodeIndex[] no_args = {};
			NodeIndex zero = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 4, .qt = type_store::INT, .callee = callee, .args = no_args } });
			check(zero.kind(&tree), NodeKind.CALL_EXPR); assert(zero.form(&tree).packed);
			check(zero.get(&tree).call.args.len, 0);
			NodeIndex[1] one_arg = { a };
			NodeIndex one = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 5, .qt = type_store::INT, .callee = callee, .args = one_arg[..] } });
			check(one.kind(&tree), NodeKind.CALL_EXPR); assert(one.form(&tree).packed);
			check(one.get(&tree).call.args[0], a);
			NodeIndex[2] two_args = { a, b };
			NodeIndex two = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 6, .qt = type_store::INT, .callee = callee, .args = two_args[..] } });
			check(two.kind(&tree), NodeKind.CALL_EXPR); assert(!two.form(&tree).packed);
			NodeIndex[3] three_args = { a, b, c };
			NodeIndex three = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 7, .qt = type_store::INT, .callee = callee, .args = three_args[..] } });
			check(three.kind(&tree), NodeKind.CALL_EXPR); assert(!three.form(&tree).packed);
			Node before_growth = three.get(&tree);
			check(before_growth.call.args.len, 3);
			for (uint i = 0; i < 256; i++) tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = i } });
			// Decoded slices borrow storage and are reacquired after mutation/growth.
			Node after_growth = three.get(&tree);
			check(after_growth.call.args.len, 3);
			check(after_growth.call.args[0], a);
			check(after_growth.call.args[2], c);
			check(one.get(&tree).call.args[0], a);
			check(two.get(&tree).call.args[1], b);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void compact_decoded_slices_alias_node_storage() @test
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
			NodeIndex a = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 1 } });
			NodeIndex b = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 2 } });
			NodeIndex c = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 3 } });

			NodeIndex[2] fields = { a, b };
			NodeIndex decl = tree.add_node({ .kind = NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 4, .container_qt = type_store::INT, .fields = fields[..] } });
			Node decoded_decl = decl.get(&tree);
			NodeRepr* decl_repr = tree.nodes.get_ref((sz)decl);
			assert(decoded_decl.container_decl.fields.ptr == &decl_repr.data.typed_list.elems[0]);
			check(decoded_decl.container_decl.fields.len, 2);
			check(decoded_decl.container_decl.fields[1], b);

			NodeIndex[2] body = { a, b };
			NodeIndex compound = tree.add_node({ .kind = NodeKind.COMPOUND_STMT, .compound_stmt = { .l_brace_tok = 5, .body = body[..] } });
			Node decoded_compound = compound.get(&tree);
			NodeRepr* compound_repr = tree.nodes.get_ref((sz)compound);
			assert(decoded_compound.compound_stmt.body.ptr == &compound_repr.data.elems[0]);
			check(decoded_compound.compound_stmt.body.len, 2);
			check(decoded_compound.compound_stmt.body[0], a);

			NodeIndex[2] decls = { a, c };
			NodeIndex decl_stmt = tree.add_node({ .kind = NodeKind.DECL_STMT, .decl_stmt = { .first_tok = 6, .decls = decls[..] } });
			Node decoded_stmt = decl_stmt.get(&tree);
			NodeRepr* stmt_repr = tree.nodes.get_ref((sz)decl_stmt);
			assert(decoded_stmt.decl_stmt.decls.ptr == &stmt_repr.data.elems[0]);
			check(decoded_stmt.decl_stmt.decls.len, 2);
			check(decoded_stmt.decl_stmt.decls[1], c);

			NodeIndex callee = tree.add_node({ .kind = NodeKind.BUILTIN_REF, .builtin_ref = { .name_tok = 7, .qt = type_store::INT } });
			NodeIndex[1] call_arg = { b };
			NodeIndex call = tree.add_node({ .kind = NodeKind.CALL_EXPR, .call = { .l_paren_tok = 8, .qt = type_store::INT, .callee = callee, .args = call_arg[..] } });
			Node decoded_call = call.get(&tree);
			NodeRepr* call_repr = tree.nodes.get_ref((sz)call);
			assert(decoded_call.call.args.ptr == (NodeIndex*)&call_repr.data.call_one.arg);
			check(decoded_call.call.args.len, 1);
			check(decoded_call.call.args[0], b);

			NodeIndex[2] builtin_args = { a, c };
			NodeIndex builtin_call = tree.add_node({ .kind = NodeKind.BUILTIN_CALL_EXPR, .builtin_call = { .builtin_tok = 9, .qt = type_store::INT, .args = builtin_args[..] } });
			Node decoded_builtin = builtin_call.get(&tree);
			NodeRepr* builtin_repr = tree.nodes.get_ref((sz)builtin_call);
			assert(decoded_builtin.builtin_call.args.ptr == &builtin_repr.data.typed_list.elems[0]);
			check(decoded_builtin.builtin_call.args.len, 2);
			check(decoded_builtin.builtin_call.args[1], c);

			NodeIndex[2] items = { b, c };
			NodeIndex init = tree.add_node({ .kind = NodeKind.ARRAY_INIT_EXPR, .container_init = { .l_brace_tok = 10, .container_qt = type_store::INT, .items = items[..] } });
			Node decoded_init = init.get(&tree);
			NodeRepr* init_repr = tree.nodes.get_ref((sz)init);
			assert(decoded_init.container_init.items.ptr == &init_repr.data.typed_list.elems[0]);
			check(decoded_init.container_init.items.len, 2);
			check(decoded_init.container_init.items[0], b);

			// Compact views borrow node storage and can be reacquired after growth.
			for (uint i = 0; i < 256; i++) tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = i } });
			check(decl.get(&tree).container_decl.fields[1], b);
			check(compound.get(&tree).compound_stmt.body[0], a);
			check(decl_stmt.get(&tree).decl_stmt.decls[1], c);
			check(call.get(&tree).call.args[0], b);
			check(builtin_call.get(&tree).builtin_call.args[1], c);
			check(init.get(&tree).container_init.items[0], b);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void sentinels_casts_classification_and_associations() @test
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
			NodeIndex base = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 8, .qt = type_store::INT } });
			NodeIndex decl_ref = tree.add_node({ .kind = NodeKind.DECL_REF_EXPR, .decl_ref = { .name_tok = 9, .qt = type_store::INT, .decl = base } });
			assert(tree.is_lval(decl_ref));
			assert(!tree.is_lval(base));
			RecordField[1] fields = { type_store::record_field(comp.intern_string("bits"), type_store::INT) };
			fields[0].bit_width = 3;
			QualType record_qt = comp.type_store.put(type_store::type_record(comp.intern_string("Bits"), fields[..], type_store::compute(fields[..], type_store::NODE_NULL, false, &comp, &tree.attr_map, 0)!!));
			NodeIndex record_base = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 13, .qt = record_qt } });
			NodeIndex bit_member = tree.add_node({ .kind = NodeKind.MEMBER_ACCESS_EXPR, .member_access = { .qt = type_store::INT, .base = record_base, .access_tok = 14, .member_index = 0 } });
			assert(tree.is_bitfield(bit_member));
			assert(!tree.is_bitfield(base));
			NodeIndex explicit_cast = tree.add_node({ .kind = NodeKind.CAST, .cast = { .qt = type_store::INT, .l_paren = 10, .kind = CastKind.INT_CAST, .operand = base, .implicit = false } });
			NodeIndex implicit_cast = tree.add_node({ .kind = NodeKind.CAST, .cast = { .qt = type_store::INT, .l_paren = 11, .kind = CastKind.LVAL_TO_RVAL, .operand = decl_ref, .implicit = true } });
			check(explicit_cast.kind(&tree), NodeKind.CAST); assert(!explicit_cast.form(&tree).implicit);
			check(implicit_cast.kind(&tree), NodeKind.CAST); assert(implicit_cast.form(&tree).implicit);
			check(explicit_cast.get(&tree).cast.kind, CastKind.INT_CAST);
			check(implicit_cast.get(&tree).cast.kind, CastKind.LVAL_TO_RVAL);
			assert(!explicit_cast.get(&tree).is_implicit());
			assert(implicit_cast.get(&tree).is_implicit());
			NodeIndex variable = tree.add_node({ .kind = NodeKind.VARIABLE, .variable = { .name_tok = 12, .qt = type_store::INT, .initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
			Node decoded = variable.get(&tree);
			assert(decoded.variable.initializer.is_null());
			assert(decoded.variable.definition.is_null());
			assert(!decoded.is_implicit());
			assert(!@ok(tree.bitfield_width(base, false)));
			tree.set_value(base, value::ONE);
			if (try stored = tree.value_of(base))
			{
				assert(stored.opt_ref == value::ONE.opt_ref);
			}
			else
			{
				assert(false);
			}
			NodeIndex stable = base;
			for (uint i = 0; i < 512; i++) tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = i, .qt = type_store::INT } });
			check(stable, base);
			check(stable.get(&tree).literal.literal_tok, 8);
			if (try stored_after_growth = tree.value_of(stable))
			{
				assert(stored_after_growth.opt_ref == value::ONE.opt_ref);
			}
			else
			{
				assert(false);
			}
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void if_and_for_optional_sentinels_round_trip() @test
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
			NodeIndex init = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 1 } });
			NodeIndex cond = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::INT } });
			NodeIndex incr = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 3, .qt = type_store::INT } });
			NodeIndex body = tree.add_node({ .kind = NodeKind.NULL_STMT, .null_stmt = { .semicolon_or_r_brace_tok = 4 } });

			NodeIndex if_plain = tree.add_node({ .kind = NodeKind.IF_STMT, .if_stmt = { .if_tok = 5, .init = type_store::NODE_NULL, .cond = cond, .then_body = body, .else_body = type_store::NODE_NULL } });
			Node plain_if = if_plain.get(&tree);
			assert(plain_if.if_stmt.init.is_null() && plain_if.if_stmt.else_body.is_null());
			NodeIndex if_init = tree.add_node({ .kind = NodeKind.IF_STMT, .if_stmt = { .if_tok = 6, .init = init.pack(), .cond = cond, .then_body = body, .else_body = type_store::NODE_NULL } });
			Node init_if = if_init.get(&tree);
			check(init_if.if_stmt.init.unwrap(), init);
			assert(init_if.if_stmt.else_body.is_null());
			NodeIndex if_full = tree.add_node({ .kind = NodeKind.IF_STMT, .if_stmt = { .if_tok = 7, .init = init.pack(), .cond = cond, .then_body = body, .else_body = body.pack() } });
			Node full_if = if_full.get(&tree);
			check(full_if.if_stmt.init.unwrap(), init);
			check(full_if.if_stmt.else_body.unwrap(), body);

			NodeIndex for_full = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 8, .init = init.pack(), .cond = cond.pack(), .incr = incr.pack(), .body = body } });
			Node full_for = for_full.get(&tree);
			check(full_for.for_stmt.init.unwrap(), init);
			check(full_for.for_stmt.cond.unwrap(), cond);
			check(full_for.for_stmt.incr.unwrap(), incr);
			NodeIndex for_init_cond = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 9, .init = init.pack(), .cond = cond.pack(), .incr = type_store::NODE_NULL, .body = body } });
			Node init_cond_for = for_init_cond.get(&tree);
			check(init_cond_for.for_stmt.init.unwrap(), init);
			check(init_cond_for.for_stmt.cond.unwrap(), cond);
			assert(init_cond_for.for_stmt.incr.is_null());
			NodeIndex for_init_incr = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 10, .init = init.pack(), .cond = type_store::NODE_NULL, .incr = incr.pack(), .body = body } });
			Node init_incr_for = for_init_incr.get(&tree);
			check(init_incr_for.for_stmt.init.unwrap(), init);
			assert(init_incr_for.for_stmt.cond.is_null());
			check(init_incr_for.for_stmt.incr.unwrap(), incr);
			NodeIndex for_cond_incr = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 11, .init = type_store::NODE_NULL, .cond = cond.pack(), .incr = incr.pack(), .body = body } });
			Node cond_incr_for = for_cond_incr.get(&tree);
			assert(cond_incr_for.for_stmt.init.is_null());
			check(cond_incr_for.for_stmt.cond.unwrap(), cond);
			check(cond_incr_for.for_stmt.incr.unwrap(), incr);
			NodeIndex for_init = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 12, .init = init.pack(), .cond = type_store::NODE_NULL, .incr = type_store::NODE_NULL, .body = body } });
			Node init_for = for_init.get(&tree);
			check(init_for.for_stmt.init.unwrap(), init);
			assert(init_for.for_stmt.cond.is_null() && init_for.for_stmt.incr.is_null());
			NodeIndex for_cond = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 13, .init = type_store::NODE_NULL, .cond = cond.pack(), .incr = type_store::NODE_NULL, .body = body } });
			Node cond_for = for_cond.get(&tree);
			assert(cond_for.for_stmt.init.is_null() && cond_for.for_stmt.incr.is_null());
			check(cond_for.for_stmt.cond.unwrap(), cond);
			NodeIndex for_incr = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 14, .init = type_store::NODE_NULL, .cond = type_store::NODE_NULL, .incr = incr.pack(), .body = body } });
			Node incr_for = for_incr.get(&tree);
			assert(incr_for.for_stmt.init.is_null() && incr_for.for_stmt.cond.is_null());
			check(incr_for.for_stmt.incr.unwrap(), incr);
			NodeIndex for_ever = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 15, .init = type_store::NODE_NULL, .cond = type_store::NODE_NULL, .incr = type_store::NODE_NULL, .body = body } });
			Node ever_for = for_ever.get(&tree);
			assert(ever_for.for_stmt.init.is_null() && ever_for.for_stmt.cond.is_null() && ever_for.for_stmt.incr.is_null());
			tree.free();
		}
		comp.free();
	}
}

fn void token_location_round_trip_for_generated_and_source_tokens() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		{
			Source src = comp.add_source_from_buffer("macro-origin.c", "VALUE\n")!!;
			comp.generated_buf.push_all("VALUE");
			comp.generated_buf.push(0); // generated_buf keeps a NUL sentinel in spare capacity for the tokenizer
			comp.generated_buf.size -= 1;
			TreeToken[2] tree_tokens = {
				{ .id = tokenizer::TokenId.IDENTIFIER, .loc = { .id = source::GENERATED_ID, .byte_offset = 0, .line = 1 } },
				{ .id = tokenizer::TokenId.IDENTIFIER, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } },
			};
			Tree tree;
			tree.init(&comp, tree_tokens[..]);
			NodeIndex generated = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 0, .qt = type_store::INT } });
			NodeIndex source_derived = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			check(generated.tok(&tree), 0);
			check(generated.loc(&tree).id.index, source::GENERATED_INDEX);
			check(tree.tok_slice(generated.tok(&tree)), "VALUE");
			check(source_derived.loc(&tree).id.index, src.id.index);
			check(source_derived.loc(&tree).byte_offset, 0);
			check(source_derived.loc(&tree).line, 1);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void storage_form_round_trips() @test
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
			NodeIndex x = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			NodeIndex y = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::INT } });
			NodeIndex z = tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 3, .qt = type_store::INT } });
			NodeIndex body = tree.add_node({ .kind = NodeKind.NULL_STMT, .null_stmt = { .semicolon_or_r_brace_tok = 4 } });

			// FOR_STMT: every init/cond/incr combination (Zig for_full .. for_ever).
			for (uint mask = 0; mask < 8; mask++)
			{
				NodeOptIndex init = mask & 1 ? x.pack() : type_store::NODE_NULL;
				NodeOptIndex cond = mask & 2 ? y.pack() : type_store::NODE_NULL;
				NodeOptIndex incr = mask & 4 ? z.pack() : type_store::NODE_NULL;
				NodeIndex f = tree.add_node({ .kind = NodeKind.FOR_STMT, .for_stmt = { .for_tok = 5, .init = init, .cond = cond, .incr = incr, .body = body } });
				check(f.kind(&tree), NodeKind.FOR_STMT);
				NodeForStmt got = f.get(&tree).for_stmt;
				assert(got.init == init && got.cond == cond && got.incr == incr, "for mask %d", mask);
				check(got.body, body);
				assert(@catch(f.qt_or_null(&tree)) == tree::NO_QT);
			}

			// IF_STMT: plain (with/without else), init only, init + else.
			NodeOptIndex[2] inits = { type_store::NODE_NULL, x.pack() };
			NodeOptIndex[2] elses = { type_store::NODE_NULL, z.pack() };
			foreach (init : inits)
			{
				foreach (else_body : elses)
				{
					NodeIndex i = tree.add_node({ .kind = NodeKind.IF_STMT, .if_stmt = { .if_tok = 6, .cond = y, .init = init, .then_body = body, .else_body = else_body } });
					NodeIfStmt got = i.get(&tree).if_stmt;
					assert(got.init == init && got.cond == y && got.then_body == body && got.else_body == else_body);
				}
			}

			// RETURN_STMT: expr / none / implicit.
			NodeIndex r_expr = tree.add_node({ .kind = NodeKind.RETURN_STMT, .return_stmt = { .return_tok = 7, .return_qt = type_store::INT, .operand = ReturnOperandKind.EXPR, .expr = x } });
			NodeIndex r_none = tree.add_node({ .kind = NodeKind.RETURN_STMT, .return_stmt = { .return_tok = 7, .return_qt = type_store::VOID, .operand = ReturnOperandKind.NONE } });
			NodeIndex r_impl = tree.add_node({ .kind = NodeKind.RETURN_STMT, .return_stmt = { .return_tok = 7, .return_qt = type_store::INT, .operand = ReturnOperandKind.IMPLICIT, .implicit_value = true } });
			check(r_expr.get(&tree).return_stmt.operand, ReturnOperandKind.EXPR);
			check(r_expr.get(&tree).return_stmt.expr, x);
			check(r_none.get(&tree).return_stmt.operand, ReturnOperandKind.NONE);
			check(r_impl.get(&tree).return_stmt.operand, ReturnOperandKind.IMPLICIT);
			assert(r_impl.get(&tree).return_stmt.implicit_value);

			// ASM_STMT: simple (packed) and extended with qualifiers.
			NodeIndex simple = tree.add_node({ .kind = NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = 8, .asm_str = x, .quals = { .is_volatile = true } } });
			assert(simple.form(&tree).packed);
			assert(simple.get(&tree).asm_stmt.quals.is_volatile && !simple.get(&tree).asm_stmt.quals.is_inline);
			NodeIndex[1] clobbers = { y };
			NodeIndex extended = tree.add_node({ .kind = NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = 8, .asm_str = x, .clobbers = clobbers[..], .quals = { .is_inline = true, .is_volatile = true } } });
			assert(!extended.form(&tree).packed);
			NodeAsmStmt got_asm = extended.get(&tree).asm_stmt;
			assert(got_asm.quals.is_inline && got_asm.quals.is_volatile && !got_asm.quals.is_goto);
			check(got_asm.clobbers.len, 1);
			check(got_asm.clobbers[0], y);

			// FUNCTION: prototype vs definition.
			NodeIndex proto = tree.add_node({ .kind = NodeKind.FUNCTION, .function = { .name_tok = 9, .qt = type_store::INT, .body = type_store::NODE_NULL, .definition = z.pack() } });
			NodeIndex def = tree.add_node({ .kind = NodeKind.FUNCTION, .function = { .name_tok = 9, .qt = type_store::INT, .body = body.pack(), .definition = type_store::NODE_NULL } });
			assert(!proto.form(&tree).defined && def.form(&tree).defined);
			check(proto.get(&tree).function.definition.unwrap(), z);
			assert(proto.get(&tree).function.body.is_null());
			check(def.get(&tree).function.body.unwrap(), body);
			assert(def.get(&tree).function.definition.is_null());
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}
