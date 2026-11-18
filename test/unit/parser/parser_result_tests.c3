// Focused direct-AST tests for Result's type conversions.
module parser_result_tests;
import aro::primitive_value;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_declaration, aro::parser_postfix, aro::parser_result, aro::tree, aro::type_store, aro::value, aro::value_interner;
import aro::preprocessor, aro::source, aro::symbol_stack, aro::tokens;
import std::core::mem::allocators;

fn parser_result::Result? parse_initializer_context_assignment(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	String spelling = p.tree.tok_slice(tok);
	p.advance();
	if (spelling == "x")
	{
		type_store::NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .name_tok = tok, .qt = type_store::INT } });
		type_store::NodeIndex reference = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .qt = type_store::INT, .decl = declaration, .name_tok = tok } });
		return { .node = reference, .qt = type_store::INT, .val = value::NONE };
	}
	type_store::NodeIndex literal = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	return { .node = literal, .qt = type_store::INT, .val = eval ? value::int_i64(7, p.comp) : value::NONE };
}

fn parser_result::Result? parse_initializer_context_ice(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode folding)
{
	return parse_initializer_context_assignment(context, p, true);
}

fn void assert_declaration_pointer_offset(value::Value result, compilation::Compilation* comp,
	type_store::NodeIndex decl, long expected_offset)
{
	assert(result.is(primitive_value::PrimitiveType.POINTER, comp));
	primitive_value::PrimitiveValue key = comp.interner.get(result.ref());
	assert(key.pointer.node == (uint)decl);
	assert(value::from_ref(key.pointer.offset).to_i64(comp)!! == expected_offset);
}

fn void compute_offset_uses_declaration_and_constant_lvalue_offsets() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		type_store::init_named_types(&comp);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});

			NodeIndex scalar_decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 1, .qt = type_store::INT } });
			NodeIndex scalar_ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR,
				.decl_ref = { .qt = type_store::INT, .decl = scalar_decl, .name_tok = 1 } });
			parser_result::Result scalar_result;
			scalar_result.init(scalar_ref, type_store::INT, value::int_i64(2147483647, &comp));
			assert_declaration_pointer_offset(parser_result::compute_offset(&p, scalar_result), &comp, scalar_decl, 0);

			type_store::QualType array_qt = comp.type_store.put(type_store::type_array(
				type_store::INT, type_store::ArrayLenKind.FIXED, 4));
			NodeIndex array_decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 2, .qt = array_qt } });
			NodeIndex array_ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR,
				.decl_ref = { .qt = array_qt, .decl = array_decl, .name_tok = 2 } });
			NodeIndex index = p.tree.add_node({ .kind = NodeKind.INT_LITERAL,
				.literal = { .literal_tok = 3, .qt = type_store::INT } });
			p.tree.set_value(index, value::int_i64(2, &comp));
			NodeIndex element = p.tree.add_node({ .kind = NodeKind.ARRAY_ACCESS_EXPR,
				.array_access = { .qt = type_store::INT, .base = array_ref, .index = index } });
			parser_result::Result element_result;
			element_result.init(element, type_store::INT);
			assert_declaration_pointer_offset(parser_result::compute_offset(&p, element_result), &comp, array_decl, 8);

			// A pointer-based lvalue folds only when its saved value names a symbolic base.
			type_store::QualType int_pointer = comp.type_store.put(type_store::type_pointer(type_store::INT));
			NodeIndex pointer_decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 5, .qt = int_pointer } });
			NodeIndex pointer_ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR,
				.decl_ref = { .qt = int_pointer, .decl = pointer_decl, .name_tok = 5 } });
			NodeIndex pointer_read = p.tree.add_node({ .kind = NodeKind.CAST,
				.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = pointer_ref,
					.qt = int_pointer, .implicit = true } });
			NodeIndex pointee_decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 6, .qt = type_store::INT } });
			p.tree.set_value(pointer_read, value::pointer({ .node = (uint)pointee_decl,
				.offset = value::int_i64(12, &comp).ref() }, &comp));
			NodeIndex pointer_index = p.tree.add_node({ .kind = NodeKind.INT_LITERAL,
				.literal = { .literal_tok = 7, .qt = type_store::INT } });
			p.tree.set_value(pointer_index, value::int_i64(2, &comp));
			NodeIndex pointer_element = p.tree.add_node({ .kind = NodeKind.ARRAY_ACCESS_EXPR,
				.array_access = { .qt = type_store::INT, .base = pointer_read, .index = pointer_index } });
			parser_result::Result pointer_element_result;
			pointer_element_result.init(pointer_element, type_store::INT);
			assert_declaration_pointer_offset(parser_result::compute_offset(&p, pointer_element_result),
				&comp, pointee_decl, 20);

			// Offset scaling is rejected when it overflows ptrdiff_t.
			NodeIndex overflow_index = p.tree.add_node({ .kind = NodeKind.INT_LITERAL,
				.literal = { .literal_tok = 8, .qt = type_store::LONG } });
			p.tree.set_value(overflow_index, value::int_i64(long::max, &comp));
			NodeIndex overflow_element = p.tree.add_node({ .kind = NodeKind.ARRAY_ACCESS_EXPR,
				.array_access = { .qt = type_store::INT, .base = array_ref, .index = overflow_index } });
			parser_result::Result overflow_result;
			overflow_result.init(overflow_element, type_store::INT);
			assert(parser_result::compute_offset(&p, overflow_result).is_none());

			type_store::RecordField[2] fields = {
				type_store::record_field(comp.intern_string("first"), type_store::CHAR),
				type_store::record_field(comp.intern_string("second"), type_store::INT),
			};
			fields[0].layout = { .offset_bits = 0, .size_bits = 8 };
			fields[1].layout = { .offset_bits = 64, .size_bits = 32 };
			type_store::RecordLayout record_layout = { .size_bits = 96, .field_alignment_bits = 32,
				.pointer_alignment_bits = 32, .required_alignment_bits = 8 };
			type_store::QualType record_qt = comp.type_store.put(type_store::type_record(
				comp.intern_string("OffsetRecord"), fields[..], record_layout));
			NodeIndex record_decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 4, .qt = record_qt } });
			NodeIndex record_ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR,
				.decl_ref = { .qt = record_qt, .decl = record_decl, .name_tok = 4 } });
			NodeIndex member = p.tree.add_node({ .kind = NodeKind.MEMBER_ACCESS_EXPR,
				.member_access = { .qt = type_store::INT, .base = record_ref, .member_index = 1 } });
			parser_result::Result member_result;
			member_result.init(member, type_store::INT);
			assert_declaration_pointer_offset(parser_result::compute_offset(&p, member_result), &comp, record_decl, 8);

			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_promotion_and_usual_conversions() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	// Usual conversions can reach the sign-conversion path, which needs a diagnostics sink.
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			NodeIndex a = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::SHORT } });
			NodeIndex b = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::USHORT } });
			parser_result::Result lhs;
			lhs.init(a, type_store::SHORT, value::int_i64(3, &comp));
			parser_result::Result rhs;
			rhs.init(b, type_store::USHORT, value::int_i64(4, &comp));
			lhs.usual_arithmetic_conversion(&rhs, &p)!!;
			assert(lhs.qt.eql(type_store::INT, &comp));
			assert(rhs.qt.eql(type_store::INT, &comp));
			assert(lhs.node.kind(&p.tree) == tree::NodeKind.CAST && lhs.node.form(&p.tree).implicit);
			assert(rhs.node.kind(&p.tree) == tree::NodeKind.CAST && rhs.node.form(&p.tree).implicit);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void lvalue_conversion_preserves_type_and_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			NodeIndex decl = p.tree.add_node({ .kind = NodeKind.VARIABLE, .variable = { .name_tok = 1, .qt = type_store::INT } });
			NodeIndex ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR, .decl_ref = { .qt = type_store::INT, .decl = decl, .name_tok = 1 } });
			parser_result::Result res;
			res.init(ref, type_store::INT, value::int_i64(7, &comp));
			res.value_conversion(&p);
			assert(res.qt.eql(type_store::INT, &comp));
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && res.node.form(&p.tree).implicit);
			assert(res.node.get(&p.tree).cast.kind == CastKind.LVAL_TO_RVAL);
			assert(res.val.is_int(&comp));
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void array_decay_carries_declaration_pointer_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			type_store::QualType array_qt = comp.type_store.put(type_store::type_array(
				type_store::INT, type_store::ArrayLenKind.FIXED, 4));
			NodeIndex decl = p.tree.add_node({ .kind = NodeKind.VARIABLE,
				.variable = { .name_tok = 1, .qt = array_qt } });
			NodeIndex ref = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR,
				.decl_ref = { .qt = array_qt, .decl = decl, .name_tok = 1 } });
			parser_result::Result res;
			res.init(ref, array_qt);
			res.lval_conversion(&p);
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && res.node.form(&p.tree).implicit);
			assert(res.node.get(&p.tree).cast.kind == CastKind.ARRAY_TO_POINTER);
			assert(res.val.is(primitive_value::PrimitiveType.POINTER, &comp));
			primitive_value::PrimitiveValue key = comp.interner.get(res.val.ref());
			assert(key.pointer.node == (uint)decl);
			assert(value::from_ref(key.pointer.offset).is_zero(&comp));
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void string_literal_array_decay_preserves_bytes_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			type_store::QualType char_qt = type_store::CHAR;
			char_qt.is_const = true;
			type_store::QualType array_qt = comp.type_store.put(type_store::type_array(
				char_qt, type_store::ArrayLenKind.FIXED, 4));
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.STRING_LITERAL_EXPR,
				.char_literal = { .literal_tok = 1, .qt = array_qt, .kind = tree::CharLiteralKind.ASCII } });
			value::Value bytes = value::intern(&comp, { .tag = primitive_value::PrimitiveType.BYTES,
				.bytes = "abc" });
			p.tree.set_value(literal, bytes);
			parser_result::Result res;
			res.init(literal, array_qt);
			res.lval_conversion(&p);
			assert(res.node.get(&p.tree).cast.kind == CastKind.ARRAY_TO_POINTER);
			assert(res.val.is(primitive_value::PrimitiveType.BYTES, &comp));
			assert(res.val.opt_ref == bytes.opt_ref);
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void pointer_to_integer_conversion_keeps_value_unavailable() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	// The implicit pointer-to-integer conversion reports through the diagnostics sink.
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			type_store::QualType ptr_ty = comp.type_store.put(type_store::type_pointer(type_store::INT));
			NodeIndex value_node = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = ptr_ty } });
			parser_result::Result res;
			res.init(value_node, ptr_ty, value::NONE);
			res.cast_to_int(&p, type_store::INT)!!;
			assert(res.qt.eql(type_store::INT, &comp));
			assert(res.val.is_none());
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && res.node.form(&p.tree).implicit);
			assert(res.node.get(&p.tree).cast.kind == CastKind.POINTER_TO_INT);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void explicit_integer_cast_builds_explicit_ast_node() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			parser_result::Result res;
			res.init(literal, type_store::INT, value::int_i64(9, &comp));
			assert(res.explicit_cast(&p, type_store::SHORT, 2)!!);
			assert(res.qt.eql(type_store::SHORT, &comp));
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && !res.node.form(&p.tree).implicit);
			assert(!res.node.get(&p.tree).cast.implicit);
			assert(res.val.is_int(&comp));
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void implicit_integer_cast_reports_truncation() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			parser_result::Result res;
			res.init(literal, type_store::INT, value::int_i64(300, &comp));
			// tok is the diagnostic location token, supplied by the parser caller.
			res.cast_to_int(&p, type_store::UCHAR, 1)!!;
			assert(res.qt.eql(type_store::UCHAR, &comp));
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && res.node.form(&p.tree).implicit);
			assert(res.node.get(&p.tree).cast.kind == CastKind.INT_CAST);
			assert(diags.messages.len() == 1);
			assert(diags.messages[0].has_opt && diags.messages[0].opt == diagnostics::Option.CONSTANT_CONVERSION);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void implicit_integer_cast_reports_signedness_change() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	diags.set("sign-conversion", diagnostics::MessageKind.WARNING)!!;
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			parser_result::Result res;
			// Zig Value.intCast reports sign_changed only when the source sign differs from the
			// destination signedness (src/aro/Value.zig:259-276). A positive 1 -> unsigned is .none,
			// so the sign-change case needs a negative source value.
			res.init(literal, type_store::INT, value::int_i64(-1, &comp));
			res.cast_to_int(&p, type_store::UINT, 1)!!;
			assert(res.qt.eql(type_store::UINT, &comp));
			assert(res.node.kind(&p.tree) == tree::NodeKind.CAST && res.node.form(&p.tree).implicit);
			assert(res.node.get(&p.tree).cast.kind == CastKind.INT_CAST);
			assert(diags.messages.len() == 1);
			assert(diags.messages[0].has_opt && diags.messages[0].opt == diagnostics::Option.SIGN_CONVERSION);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void implicit_float_to_integer_reports_value_change() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	diags.set("float-conversion", diagnostics::MessageKind.WARNING)!!;
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.FLOAT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::DOUBLE } });
			value::Value floating = value::intern(&comp, primitive_value::f64_value(0x3FF8_0000_0000_0000));
			parser_result::Result res;
			res.init(literal, type_store::DOUBLE, floating);
			res.cast_to_int(&p, type_store::INT, 1)!!;
			assert(res.qt.eql(type_store::INT, &comp));
			assert(diags.messages.len() == 1);
			assert(diags.messages[0].has_opt && diags.messages[0].opt == diagnostics::Option.FLOAT_CONVERSION);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void implicit_pointer_to_integer_reports_conversion() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	diags.set("int-conversion", diagnostics::MessageKind.WARNING)!!;
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = &diags };
			p.tree.init(&comp, {});
			type_store::QualType ptr_ty = comp.type_store.put(type_store::type_pointer(type_store::INT));
			NodeIndex decl = p.tree.add_node({ .kind = NodeKind.VARIABLE, .variable = { .name_tok = 1, .qt = ptr_ty } });
			NodeIndex operand = p.tree.add_node({ .kind = NodeKind.DECL_REF_EXPR, .decl_ref = { .qt = ptr_ty, .decl = decl, .name_tok = 1 } });
			parser_result::Result res;
			res.init(operand, ptr_ty, value::NONE);
			res.cast_to_int(&p, type_store::INT, 1)!!;
			assert(res.val.is_none());
			assert(diags.messages.len() == 1);
			assert(diags.messages[0].has_opt && diags.messages[0].opt == diagnostics::Option.INT_CONVERSION);
			p.tree.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void complex_float_to_bool_checks_both_components() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			type_store::QualType complex_ty = comp.type_store.put(type_store::type_complex(type_store::DOUBLE));
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.FLOAT_LITERAL, .literal = { .literal_tok = 1, .qt = complex_ty } });
			value::Value imaginary_one = value::intern(&comp, primitive_value::complex_key(primitive_value::zero(F64), primitive_value::one(F64)));
			parser_result::Result res;
			res.init(literal, complex_ty, imaginary_one);
			res.cast_to_bool(&p, 1)!!;
			assert(res.qt.eql(type_store::BOOL, &comp));
			assert(!res.val.is_zero(&comp));
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void bool_coercion_does_not_append_cast() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL,
				.literal = { .literal_tok = 1, .qt = type_store::BOOL } });
			parser_result::Result res;
			res.init(literal, type_store::BOOL, value::int_i64(1, &comp));
			assert(res.coerce_scalar(&p, type_store::BOOL)!!);
			assert(res.node == literal);
			assert(res.node.kind(&p.tree) == tree::NodeKind.INT_LITERAL);
			assert(res.qt.eql(type_store::BOOL, &comp));
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void implicit_integer_conversion_diagnostic_uses_expanded_token_location() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		{
			Source src = comp.add_source_from_buffer("conversion.c", "300;\nmacro_value;\n")!!;
			Preprocessor pp;
			pp.init(&comp, preprocessor::TESTING)!!;
			// The result points at an expanded token. The diagnostic belongs at
			// the outer call site and includes the inner expansion as a note.
			TokenWithExpansionLocs expanded = {
				.id = IDENTIFIER,
				.loc = { .id = src.id, .byte_offset = 0, .line = 1 },
			};
			expanded.add_expansion_location(comp.gpa, {
				{ .id = src.id, .byte_offset = 2, .line = 1 },
				{ .id = src.id, .byte_offset = 5, .line = 2 },
			});
			pp.add_token(expanded)!!;

			parser::Parser p = { .comp = &comp, .diagnostics = &diags, .pp = &pp };
			p.tree.init(&comp, {});
			p.tree.tokens = pp.tokens.array_view();
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 0, .qt = type_store::INT } });
			parser_result::Result res;
			res.init(literal, type_store::INT, value::int_i64(300, &comp));
			res.cast_to_int(&p, type_store::UCHAR, 0)!!;

			// Zig addWithLocation (src/aro/Diagnostics.zig:478-523) emits the primary at the outer
			// expansion site, one "expanded from here" note per inner expansion, and a final note at
			// the token's own location because Diagnostic.emit_at passes note_msg_loc = true.
			assert(diags.messages.len() == 3);
			assert(diags.messages[0].has_location);
			test::eq(diags.messages[0].location.path, "conversion.c");
			assert(diags.messages[0].location.line_no == 2 && diags.messages[0].location.col == 1);
			test::eq(diags.messages[1].text, "expanded from here");
			assert(diags.messages[1].location.line_no == 1 && diags.messages[1].location.col == 3);
			test::eq(diags.messages[2].text, "expanded from here");
			assert(diags.messages[2].location.line_no == 1 && diags.messages[2].location.col == 1);
			p.tree.free();
			pp.free();
		}
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void invalid_type_keeps_explicit_sentinel_and_known_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			parser::Parser p = { .comp = &comp, .diagnostics = comp.diagnostics };
			p.tree.init(&comp, {});
			NodeIndex literal = p.tree.add_node({ .kind = NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INVALID } });
			value::Value known = value::int_i64(23, &comp);
			parser_result::Result res;
			res.init(literal, type_store::INVALID, known);
			res.usual_unary_conversion(&p)!!;
			assert(res.qt.is_invalid());
			assert(res.val.is_int(&comp));
			assert(res.node == literal);
			p.tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void initializer_value_requirements_follow_context_and_compound_storage() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		Source src = comp.add_source_from_buffer("initializer-context.c", "7 7 x { 7, x } x x x")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.set_initializer_test_probe(&grammar_parse_initializer_context_assignment);
		type_store::NodeIndex x_declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = type_store::INT } });
		p.define_symbol({ .name = comp.intern_string("x"), .kind = symbol_stack::SymbolKind.DEF,
			.qt = type_store::INT, .node = x_declaration, .val = value::NONE });
		parser_declaration::DeclarationParser declaration = {};

		parser_result::Result constant = declaration.parse_variable_initializer(&p, type_store::INT, false, true)!!;
		assert(constant.node.kind(&p.tree) == tree::NodeKind.INT_LITERAL);
		assert(diags.messages.len() == 0, "a saved scalar value satisfies static initialization");

		parser_result::Result constexpr_constant = declaration.parse_variable_initializer(&p, type_store::INT, true, false)!!;
		assert(!constexpr_constant.val.is_none(), "constexpr parsing restores the saved scalar value for declaration processing");
		assert(diags.messages.len() == 0);

		parser_result::Result constexpr_nonconstant = declaration.parse_variable_initializer(&p, type_store::INT, true, false)!!;
		assert(constexpr_nonconstant.node.kind(&p.tree) == tree::NodeKind.CAST && constexpr_nonconstant.node.form(&p.tree).implicit);
		assert(diags.messages.len() == 1);
		test::eq(diags.messages[0].text, "constexpr variable must be initialized by a constant expression");
		assert(diags.messages[0].has_location && diags.messages[0].location.col == 5,
			"a scalar requirement is reported at its initializer expression");

		type_store::QualType two_ints = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 2));
		parser_result::Result aggregate = declaration.parse_variable_initializer(&p, two_ints, false, true)!!;
		// The storage tag is split by child count (ARRAY_INIT_EXPR_TWO, tree.c3:388); compare the kind.
		assert(aggregate.node.get(&p.tree).kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(diags.messages.len() == 2, "a mixed aggregate emits one static-value error");
		test::eq(diags.messages[1].text, "initializer element is not a compile-time constant");
		assert(diags.messages[1].has_location && diags.messages[1].location.col == 12,
			"an aggregate requirement points at its first initializer child without a saved value");

		// A file-scope compound literal has static duration and uses the same
		// value requirement even when its storage-class argument is AUTO.
		parser_postfix::PostfixParser postfix = { .parser = &p };
		parser_result::Result compound = postfix.parse_compound_literal(0, type_store::INT)!!;
		assert(compound.node.kind(&p.tree) == tree::NodeKind.COMPOUND_LITERAL_EXPR);
		assert(diags.messages.len() == 3);
		test::eq(diags.messages[2].text, "initializer element is not a compile-time constant");

		// A thread-local compound literal also has static duration inside a
		// function, so it cannot inherit the runtime initializer context.
		p.set_function_context({ .active = true });
		postfix.parse_compound_literal(0, type_store::INT, tree::CompoundLiteralStorageClass.AUTO, true, false)!!;
		assert(diags.messages.len() == 4);
		test::eq(diags.messages[3].text, "initializer element is not a compile-time constant");

		// Explicit runtime context still accepts an expression with no saved value.
		declaration.parse_variable_initializer(&p, type_store::INT, false, false)!!;
		assert(diags.messages.len() == 4);
		assert(p.init_context == parser::InitContext.RUNTIME);

		// Null pointer constants use Value.NULL, which is intentionally not
		// stored in Tree.value_map. The typed null conversion remains constant.
		type_store::QualType int_ptr = comp.type_store.put(type_store::type_pointer(type_store::INT));
		type_store::NodeIndex null_literal = p.tree.add_node({ .kind = tree::NodeKind.NULLPTR_LITERAL,
			.literal = { .literal_tok = p.tok_i, .qt = type_store::NULLPTR_T } });
		type_store::NodeIndex null_cast = p.tree.add_node({ .kind = tree::NodeKind.CAST,
			.cast = { .l_paren = p.tok_i, .kind = tree::CastKind.NULL_TO_POINTER, .operand = null_literal,
				.qt = int_ptr, .implicit = true } });
		parser_result::Result null_pointer;
		null_pointer.init(null_cast, int_ptr);
		assert(null_pointer.require_initializer_value(&p, parser::InitContext.STATIC, p.tok_i)!!,
			"a null pointer conversion remains a static initializer constant without a saved Value");
		assert(diags.messages.len() == 4);

		p.free();
		pp.free();
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

fn void variable_length_array_initializers_are_diagnosed_and_defaulted() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics diags;
	diags.init_list(&ta);
	{
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		Source src = comp.add_source_from_buffer("vla-initializer.c", "{ 7 } { 7 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.set_initializer_test_probe(&grammar_parse_initializer_context_assignment);

		type_store::NodeIndex bound = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = 0, .qt = type_store::INT } });
		type_store::QualType vla = comp.type_store.put(type_store::type_vla(type_store::INT, bound));
		type_store::QualType unspecified_vla = comp.type_store.put(type_store::type_array(type_store::INT,
			type_store::ArrayLenKind.UNSPECIFIED_VARIABLE));
		parser_result::Result first = p.parse_initializer(vla)!!;
		parser_result::Result second = p.parse_initializer(unspecified_vla)!!;
		assert(first.node.kind(&p.tree) == tree::NodeKind.DEFAULT_INIT_EXPR);
		assert(second.node.kind(&p.tree) == tree::NodeKind.DEFAULT_INIT_EXPR);
		assert(diags.messages.len() == 2, "both runtime and unspecified VLA initializer forms are rejected");
		test::eq(diags.messages[0].text, "variable-sized object may not be initialized");
		test::eq(diags.messages[1].text, "variable-sized object may not be initialized");

		p.free();
		pp.free();
		comp.free();
	}
	diags.free();
	assert(ta.allocation_count() == 0);
}

alias InitAssignFn = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
alias InitIceFn = fn parser_result::Result?(void* context, parser::Parser* p, parser::ConstDeclFoldingMode folding);

<* IExpressionGrammar over this file's initializer test productions. *>
struct InitGrammar (parser::IExpressionGrammar)
{
	void* context;
	InitAssignFn assign;
	InitIceFn ice;
}

fn parser_result::Result? InitGrammar.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
	=> self.assign(self.context, p, eval);
fn parser_result::Result? InitGrammar.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode folding, bool eval) @dynamic
	=> self.ice(self.context, p, folding);

InitGrammar grammar_parse_initializer_context_assignment = { null, &parse_initializer_context_assignment, &parse_initializer_context_ice };
