// Focused operator regressions for the expression engine using the same
// finalized preprocessor tokens and seeded scope model as
// parser_expression_tests.c3. The unary callback is intentionally tiny: the
// owning C grammar supplies casts, postfix forms, and full primary parsing.
// Source-derived boundary: this callback supplies primary expressions while
// parser_expression owns grouping and the built-in unary operator productions.
// Pointer/null cases still require seeded pointer values and types.
module parser_operator_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_expression, aro::parser_postfix, aro::parser_result;
import aro::preprocessor, aro::source, aro::string_interner, aro::symbol_stack, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::float_value, aro::value_interner;
import aro::lang_opts;
import std::core::mem::allocators;

excuse PRIMARY_CALLBACK_FAILURE;

fn parser_result::Result? fail_primary(void* context, parser::Parser* p, bool eval)
{
	return PRIMARY_CALLBACK_FAILURE~;
}

struct OperatorContext
{
	symbol_stack::SymbolStack* symbols;
	StringId x_name;
	StringId y_name;
}

fn parser_result::Result? parse_seeded_primary(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser_expression::NO_EXPRESSION~;
	OperatorContext* ctx = (OperatorContext*)context;
	tokens::TokenIndex tok = p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	parser_result::Result result;
	if (id == tokenizer::TokenId.IDENTIFIER)
	{
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		StringId name;
		if (spelling == "y") { name = ctx.y_name; }
		else if (spelling == "x") { name = ctx.x_name; }
		else { unreachable("unexpected identifier in operator fixture"); }
		Symbol symbol = ctx.symbols.lookup(name, symbol_stack::ScopeKind.VARS)!!;
		NodeIndex ref = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .qt = symbol.qt, .decl = symbol.node, .name_tok = tok } });
		result.init(ref, symbol.qt, eval ? symbol.val : value::NONE);
	}
	else
	{
		if (id != tokenizer::TokenId.PP_NUM) unreachable("unexpected token in integer operator fixture");
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		long n;
		if (spelling == "0") { n = 0; }
		else if (spelling == "1") { n = 1; }
		else if (spelling == "2") { n = 2; }
		else if (spelling == "3") { n = 3; }
		else if (spelling == "32") { n = 32; }
		else if (spelling == "250") { n = 250; }
		else { unreachable("unexpected integer token in operator fixture"); }
		NodeIndex literal = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::INT } });
		// Integer literals keep their constant value even when an enclosing
		// conditional or short-circuit expression suppresses evaluation.
		result.init(literal, type_store::INT, value::int_i64(n, p.comp));
	}
	p.advance();
	return result;
}

// Source-derived: arithmetic expectations use Value's wrapping integer
// contract; overflow is reported by Value.add/sub/mul as true. Exact integer
// and IEEE vectors remain in integer_value_tests.c3 and float_vector_tests.c3.
fn void check_int_expr(String text, tree::NodeKind kind, long want, bool want_none = false, bool unsigned_y = false, bool eval = true, bool const_x = false, bool expect_failure = false, bool expect_rhs_cast = false, bool expect_pointer = false, bool expect_size = false, uint expected_warnings = uint::max, type_store::QualType y_type = type_store::INT, long y_number = -1, bool check_shift_rhs_promotion = false, type_store::QualType shift_rhs_qt = type_store::INT, tree::CastKind shift_rhs_cast_kind = tree::CastKind.LVAL_TO_RVAL, String expected_failure_message = "", type_store::QualType x_type = type_store::INT, long x_number = 2147483647, bool volatile_x = false, bool const_y = false, bool volatile_y = false, bool atomic_y = false)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		Source src = comp.add_source_from_buffer("operator.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		StringId y = comp.intern_string("y");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		type_store::QualType x_qt = const_x ? x_type.with_qualifiers({ .is_const = true }) : x_type;
		if (volatile_x) x_qt.is_volatile = true;
		NodeIndex xd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = x_qt } });
		type_store::QualType y_qt = unsigned_y && y_type.eql(type_store::INT, &comp) ? type_store::UINT : y_type;
		if (atomic_y) y_qt = comp.type_store.put(type_store::type_atomic(y_qt));
		if (const_y) y_qt.is_const = true;
		if (volatile_y) y_qt.is_volatile = true;
		value::Value y_val = unsigned_y ? value::int_u64((ulong)(y_number < 0 ? 0xFFFF_FFFF : y_number), &comp) : value::int_i64(y_number < 0 ? 1 : y_number, &comp);
		NodeIndex yd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = y_qt } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = x_qt, .node = xd, .val = value::int_i64(x_number, &comp) });
		symbols.define({ .name = y, .kind = symbol_stack::SymbolKind.DEF, .qt = y_qt, .node = yd, .val = y_val });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		OperatorContext context = { .symbols = &symbols, .x_name = x, .y_name = y };
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_seeded_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result? parsed = expression.parse(tokens::PREC_ANY, eval);
		if (catch parse_error = parsed)
		{
			assert(expect_failure, "unexpected operator parse failure");
			assert(parse_error == parser_expression::PARSING_FAILED);
		}
		else
		{
			assert(!expect_failure, "invalid operator expression unexpectedly parsed");
			parser_result::Result result = parsed;
			assert(p.at_eof(), "operator fixture left trailing tokens");
			assert(result.node.kind(&p.tree) == kind);
			type_store::QualType expected_qt = type_store::INT;
			if (expect_pointer) expected_qt = comp.type_store.put(type_store::type_pointer(type_store::INT));
			if (expect_size) expected_qt = comp.type_store.size;
			assert(result.qt.eql(expected_qt, &comp));
			if (expect_pointer)
			{
				Node address = result.node.get(&p.tree);
				assert(address.unary.qt.eql(expected_qt, &comp));
				assert(address.unary.operand.get(&p.tree).kind == tree::NodeKind.DECL_REF_EXPR);
			}
			if (text == "*&x\n")
			{
				Node dereference = result.node.get(&p.tree);
				assert(dereference.unary.qt.eql(type_store::INT, &comp));
				assert(dereference.unary.operand.get(&p.tree).kind == tree::NodeKind.ADDR_OF_EXPR);
			}
			if (expect_size)
			{
				Node type_info = result.node.get(&p.tree);
				assert(type_info.type_info.qt.eql(comp.type_store.size, &comp));
				assert(type_info.type_info.operand_qt.eql(type_store::INT, &comp));
				assert(type_info.type_info.expr != type_store::NODE_NULL);
				assert(type_info.type_info.expr.unpack()!!.get(&p.tree).kind == tree::NodeKind.DECL_REF_EXPR);
			}
			if (expect_rhs_cast)
			{
				Node node = result.node.get(&p.tree);
				assert(node.binary.rhs.get(&p.tree).kind == tree::NodeKind.CAST);
			}
			if (check_shift_rhs_promotion)
			{
				Node binary = result.node.get(&p.tree);
				Node rhs = binary.binary.rhs.get(&p.tree);
				assert(rhs.kind == tree::NodeKind.CAST);
				assert(rhs.cast.kind == shift_rhs_cast_kind);
				assert(rhs.cast.qt.eql(shift_rhs_qt, &comp));
				Node lhs = binary.binary.lhs.get(&p.tree);
				if (lhs.kind == tree::NodeKind.CAST) { assert(lhs.cast.qt.eql(type_store::INT, &comp)); }
				else { assert(lhs.literal.qt.eql(type_store::INT, &comp)); }
			}
			if (!eval || want_none) { assert(result.val.is_none()); }
			else if (expect_pointer)
			{
				assert(result.val.is(value_interner::InternerKeyTag.POINTER, &comp));
				value_interner::InternerKey key = comp.interner.get(result.val.ref());
				assert(key.pointer.node == (uint)xd);
				assert(value::from_ref(key.pointer.offset).is_zero(&comp));
			}
			else { assert(result.val.to_i64(&comp)!! == want); }
		}
		if (expected_warnings != uint::max) test::eq(d.warnings, expected_warnings);
		if (expect_failure)
		{
			assert(d.messages.len() > 0, "invalid integer operator fixture failed without a diagnostic");
			if (expected_failure_message != "") test::eq(d.messages[0].text, expected_failure_message);
		}
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

struct PointerContext
{
	symbol_stack::SymbolStack* symbols;
	StringId pointer_name;
	StringId second_pointer_name;
}

fn parser_result::Result? parse_pointer_primary(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser_expression::NO_EXPRESSION~;
	PointerContext* ctx = (PointerContext*)context;
	tokens::TokenIndex tok = p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	parser_result::Result result;
	if (id == tokenizer::TokenId.IDENTIFIER)
	{
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		StringId name;
		if (spelling == "q") { name = ctx.second_pointer_name; }
		else if (spelling == "p") { name = ctx.pointer_name; }
		else { unreachable("unexpected identifier in pointer operator fixture"); }
		Symbol symbol = ctx.symbols.lookup(name, symbol_stack::ScopeKind.VARS)!!;
		NodeIndex ref = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .qt = symbol.qt, .decl = symbol.node, .name_tok = tok } });
		result.init(ref, symbol.qt, eval ? symbol.val : value::NONE);
	}
	else
	{
		if (id != tokenizer::TokenId.PP_NUM) unreachable("unexpected token in pointer operator fixture");
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		long number;
		if (spelling == "0") { number = 0; }
		else if (spelling == "1") { number = 1; }
		else if (spelling == "2") { number = 2; }
		else { unreachable("unexpected integer token in pointer operator fixture"); }
		NodeIndex literal = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::INT } });
		result.init(literal, type_store::INT, value::int_i64(number, p.comp));
	}
	p.advance();
	return result;
}

fn void check_pointer_expr(String text, tree::NodeKind kind, type_store::QualType expected_qt, bool expected_boolean = false, bool expect_pointer = false, ulong pointer_offset = 0, bool expect_ptrdiff = false, type_store::QualType pointer_qt = type_store::INT_POINTER, type_store::QualType second_pointer_qt = type_store::INT_POINTER, bool bounds_safety = false, bool expect_failure = false, bool expect_none = false, uint expected_warnings = uint::max, bool make_single_pointer = false, bool zero_size_pointee = false, bool seed_overflowing_offset = false, bool incomplete_pointee = false, bool expect_rhs_pointer_cast = false, bool distinct_pointees = false)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.state.extensions = diagnostics::MessageKind.WARNING;
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		if (distinct_pointees) second_pointer_qt = comp.type_store.put(type_store::type_pointer(type_store::FLOAT));
		if (bounds_safety) comp.langopts.bounds_safety = lang_opts::BoundsSafety.CLANG;
		if (make_single_pointer)
		{
			type_store::Type single_pointer = type_store::type_pointer(type_store::INT);
			single_pointer.pointer.bounds = type_store::PointerBounds.SINGLE;
			pointer_qt = comp.type_store.put(single_pointer);
			second_pointer_qt = pointer_qt;
		}
		if (zero_size_pointee)
		{
			type_store::RecordField[] fields = {};
			type_store::RecordLayout layout = { .size_bits = 0, .field_alignment_bits = 8, .pointer_alignment_bits = 8, .required_alignment_bits = 8 };
			type_store::QualType empty_qt = comp.type_store.put(type_store::type_record(comp.intern_string("Empty"), fields[..], layout));
			pointer_qt = comp.type_store.put(type_store::type_pointer(empty_qt));
			second_pointer_qt = pointer_qt;
		}
		if (incomplete_pointee)
		{
			type_store::QualType incomplete_qt = comp.type_store.put(type_store::type_record_incomplete(comp.intern_string("Incomplete")));
			pointer_qt = comp.type_store.put(type_store::type_pointer(incomplete_qt));
			second_pointer_qt = pointer_qt;
		}
		Source src = comp.add_source_from_buffer("pointer-operator.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId pointer_name = comp.intern_string("p");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = pointer_qt } });
		uint pointer_node = (uint)declaration;
		ulong initial_pointer_offset = 0;
		if (seed_overflowing_offset)
		{
			usz ptrdiff_bits = comp.type_store.ptrdiff.bit_sizeof(&comp);
			initial_pointer_offset = ((ulong)1 << (ptrdiff_bits - 1)) - 4;
			// Adding two int elements advances by eight bytes, wrapping across
			// the signed ptrdiff_t boundary.
			pointer_offset = ((ulong)1 << (ptrdiff_bits - 1)) + 4;
		}
		Value pointer_value = value::pointer({ .node = pointer_node, .offset = value::int_u64(initial_pointer_offset, &comp).ref() }, &comp);
		symbols.define({ .name = pointer_name, .kind = symbol_stack::SymbolKind.DEF, .qt = pointer_qt, .node = declaration, .val = pointer_value });
		StringId second_pointer_name = comp.intern_string("q");
		NodeIndex second_declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = second_pointer_qt } });
		symbols.define({ .name = second_pointer_name, .kind = symbol_stack::SymbolKind.DEF, .qt = second_pointer_qt, .node = second_declaration, .val = pointer_value });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		PointerContext context = { .symbols = &symbols, .pointer_name = pointer_name, .second_pointer_name = second_pointer_name };
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_pointer_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result? maybe_result = expression.parse();
		if (catch parse_error = maybe_result)
		{
			assert(expect_failure, "unexpected pointer operator parse failure");
			assert(parse_error == parser_expression::PARSING_FAILED);
		}
		else
		{
			assert(!expect_failure, "invalid pointer operator expression unexpectedly parsed");
			parser_result::Result result = maybe_result;
			assert(p.at_eof(), "pointer operator fixture left trailing tokens");
			assert(result.node.kind(&p.tree) == kind);
			type_store::QualType actual_expected_qt = expect_ptrdiff ? comp.type_store.ptrdiff : expected_qt;
			assert(result.qt.eql(actual_expected_qt, &comp));
			value::Value expected_value = value::from_bool(expected_boolean);
			if (expect_pointer && !seed_overflowing_offset) expected_value = value::pointer({ .node = pointer_node, .offset = value::int_u64(pointer_offset, &comp).ref() }, &comp);
			if (expect_none) { assert(result.val.is_none()); }
			else if (seed_overflowing_offset)
			{
				value_interner::InternerKey result_key = comp.interner.get(result.val.ref());
				assert(result_key.tag == value_interner::InternerKeyTag.POINTER);
				value::Value result_offset = value::from_ref(result_key.pointer.offset);
				usz ptrdiff_bits = comp.type_store.ptrdiff.bit_sizeof(&comp);
				long expected_offset = ptrdiff_bits == 64 ? (long)pointer_offset : (long)(pointer_offset - ((ulong)1 << ptrdiff_bits));
				assert(result_offset.to_i64(&comp)!! == expected_offset);
			}
			else { assert(result.val.opt_ref == expected_value.opt_ref); }
			if (expect_rhs_pointer_cast)
			{
				Node binary = result.node.get(&p.tree);
				Node rhs = binary.binary.rhs.get(&p.tree);
				assert(rhs.kind == tree::NodeKind.CAST);
				assert(rhs.cast.qt.eql(pointer_qt, &comp));
				assert(d.messages.len() == 1);
				assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
				DString expected_message;
				expected_message.init(tmem);
				expected_message.appendf("comparison of distinct pointer types ('%s' and '%s')", pointer_qt.tprint(&comp), second_pointer_qt.tprint(&comp));
				test::eq(d.messages[0].text, expected_message.str_view());
			}
		}
		if (expected_warnings != uint::max) test::eq(d.warnings, expected_warnings);
		if (expect_failure) assert(d.messages.len() > 0, "invalid pointer operator fixture failed without a diagnostic");
		if (seed_overflowing_offset)
		{
			assert(d.messages.len() == 1);
			assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
			DString expected_message;
			expected_message.init(tmem);
			expected_message.append_string("the pointer incremented by ");
			usz ptrdiff_bits = comp.type_store.ptrdiff.bit_sizeof(&comp);
			long signed_pointer_offset = ptrdiff_bits == 64 ? (long)pointer_offset : (long)(pointer_offset - ((ulong)1 << ptrdiff_bits));
			String pointer_base = p.tree.tok_slice(declaration.tok(&p.tree));
			value::print_pointer(value::int_i64(signed_pointer_offset, &comp), pointer_base, &comp, &expected_message);
			ulong element_size = pointer_qt.child_type(&comp).sizeof_or_null(&comp) ?? 1;
			ulong max_bits = comp.target.ptr_bit_width();
			if (max_bits > 61) max_bits = 61;
			ulong max_elements = (((ulong)1 << max_bits) - 1) / element_size;
			expected_message.appendf(" refers past the last possible element in %d-bit address space containing %d-bit (%d-byte) elements (max possible %d elements)", comp.type_store.intptr.bit_sizeof(&comp), element_size * 8, element_size, max_elements);
			test::eq(d.messages[0].text, expected_message.str_view());
		}
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_value_contract_and_signed_overflow() @test
{
	// x is INT_MAX and y is 1. Both cases distinguish overflow=true from
	// successful Value arithmetic: ordinary addition must still fold, while
	// signed overflow must retain the wrapped INT_MIN value.
	check_int_expr("2 + 2\n", tree::NodeKind.ADD_EXPR, 4);
	check_int_expr("x + y\n", tree::NodeKind.ADD_EXPR, -2147483648, false, false, true, false, false, false, false, false, 1);
	check_int_expr("x - y\n", tree::NodeKind.SUB_EXPR, 2147483646);
	// The low 32 bits of INT_MAX * INT_MAX are 1; folding keeps the
	// wrapped result while Value reports signed overflow internally.
	check_int_expr("x * x\n", tree::NodeKind.MUL_EXPR, 1, false, false, true, false, false, false, false, false, 1);
}

fn void signed_unsigned_and_comparison_operators() @test
{
	check_int_expr("2 * 2\n", tree::NodeKind.MUL_EXPR, 4);
	check_int_expr("2 < 1\n", tree::NodeKind.LESS_THAN_EXPR, 0);
	check_int_expr("2 == 2\n", tree::NodeKind.EQUAL_EXPR, 1);
	check_int_expr("2 | 1\n", tree::NodeKind.BIT_OR_EXPR, 3);
	check_int_expr("2 << 1\n", tree::NodeKind.SHL_EXPR, 4);
	// Shift operands promote independently. The wide unsigned RHS stays wide,
	// while the result and the integer left operand stay int.
	check_int_expr("2 << y\n", tree::NodeKind.SHL_EXPR, 8, false, true, true, false, false, false, false, false, uint::max, type_store::ULONG_LONG, 2, true, type_store::ULONG_LONG);
	// Source-derived usual arithmetic conversion: UINT_MAX is greater than 2.
	check_int_expr("2 < y\n", tree::NodeKind.LESS_THAN_EXPR, 1, false, true);
	// Source-derived conversions: unsigned char promotes to int, while a wide
	// unsigned operand converts the signed int operand to unsigned long long.
	check_int_expr("x < y\n", tree::NodeKind.LESS_THAN_EXPR, 0, false, false, true, false, false, false, false, false, uint::max, type_store::SHORT, 1);
	check_int_expr("x < y\n", tree::NodeKind.LESS_THAN_EXPR, 0, false, false, true, false, false, false, false, false, uint::max, type_store::UCHAR, 1);
	check_int_expr("x < y\n", tree::NodeKind.LESS_THAN_EXPR, 1, false, false, true, false, false, false, false, false, uint::max, type_store::LONG_LONG, 0x8000_0000);
	check_int_expr("x < y\n", tree::NodeKind.LESS_THAN_EXPR, 1, false, true, true, false, false, false, false, false, uint::max, type_store::ULONG_LONG, 0xFFFF_FFFF);
	check_int_expr("2 / 0\n", tree::NodeKind.DIV_EXPR, 0, true, false, true, false, false, false, false, false, 1);
	check_int_expr("2 % 0\n", tree::NodeKind.MOD_EXPR, 0, true, false, true, false, false, false, false, false, 1);
	check_int_expr("2 / 2\n", tree::NodeKind.DIV_EXPR, 1);
	check_int_expr("2 % 2\n", tree::NodeKind.MOD_EXPR, 0);
	// Invalid integer-only operators report source operand types even after
	// integer promotion and usual arithmetic conversion change the working types.
	check_int_expr("x & y\n", tree::NodeKind.BIT_AND_EXPR, 0, false, false, false, false, true, false, false, false, uint::max, type_store::FLOAT, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('unsigned char' and 'float')", type_store::UCHAR, 1);
	check_int_expr("x % y\n", tree::NodeKind.MOD_EXPR, 0, false, false, false, false, true, false, false, false, uint::max, type_store::FLOAT, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('unsigned char' and 'float')", type_store::UCHAR, 1);
	check_int_expr("x &= y\n", tree::NodeKind.BIT_AND_ASSIGN_EXPR, 0, false, false, false, false, true, false, false, false, uint::max, type_store::FLOAT, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('unsigned char' and 'float')", type_store::UCHAR, 1);
	check_int_expr("x %= y\n", tree::NodeKind.MOD_ASSIGN_EXPR, 0, false, false, false, false, true, false, false, false, uint::max, type_store::FLOAT, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('unsigned char' and 'float')", type_store::UCHAR, 1);
	check_int_expr("x << y\n", tree::NodeKind.SHL_EXPR, 0, false, false, false, false, true, false, false, false, uint::max, type_store::LONG, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('float' and '_Atomic(long)')", type_store::FLOAT, 1, false, false, false, true);
	check_int_expr("x << y\n", tree::NodeKind.SHL_EXPR, 0, false, false, true, true, true, false, false, false, uint::max, type_store::LONG, 1, false, type_store::INT, tree::CastKind.LVAL_TO_RVAL, "invalid operands to binary expression ('const volatile float' and 'const volatile _Atomic(long)')", type_store::FLOAT, 1, true, true, true, true);
	check_int_expr("2 << 0\n", tree::NodeKind.SHL_EXPR, 2);
	check_int_expr("2 >> 1\n", tree::NodeKind.SHR_EXPR, 1);
	// Source-derived: Parser.zig diagnoses invalid counts, then retains the
	// Value helper's target-width result instead of rejecting the expression.
	check_int_expr("2 >> -2\n", tree::NodeKind.SHR_EXPR, 0, false, false, true, false, false, false, false, false, 1);
	check_int_expr("2 >> 250\n", tree::NodeKind.SHR_EXPR, 0, false, false, true, false, false, false, false, false, 1);
	check_int_expr("2 << 32\n", tree::NodeKind.SHL_EXPR, 0, false, false, true, false, false, false, false, false, 2);
}

fn void assignment_and_compound_assignment_shapes() @test
{
	// Variable declaration references are lvalues in Tree.is_lval_extra; the
	// expression callback supplies no assignment result value, as expected.
	check_int_expr("-2\n", tree::NodeKind.NEGATE_EXPR, -2);
	check_int_expr("++x\n", tree::NodeKind.PRE_INC_EXPR, -2147483648, false, false, true, false, false, false, false, false, 1);
	check_int_expr("--x\n", tree::NodeKind.PRE_DEC_EXPR, 2147483646);
	check_int_expr("x = 2\n", tree::NodeKind.ASSIGN_EXPR, 0, true);
	check_int_expr("x += 2\n", tree::NodeKind.ADD_ASSIGN_EXPR, 0, true);
	check_int_expr("x += y\n", tree::NodeKind.ADD_ASSIGN_EXPR, 0, true, true, true, false, false, true);
	check_int_expr("x = y\n", tree::NodeKind.ASSIGN_EXPR, 0, true, true, true, false, false, true);
	check_int_expr("x <<= 1\n", tree::NodeKind.SHL_ASSIGN_EXPR, 0, true);
	// Compound shifts use the same promoted left width and shift-count warnings
	// as their non-assignment forms, while still suppressing the assignment value.
	check_int_expr("x <<= 32\n", tree::NodeKind.SHL_ASSIGN_EXPR, 0, true, false, true, false, false, false, false, false, 1);
	check_int_expr("x >>= -2\n", tree::NodeKind.SHR_ASSIGN_EXPR, 0, true, false, true, false, false, false, false, false, 1);
	check_int_expr("x = 2\n", tree::NodeKind.ASSIGN_EXPR, 0, true, false, true, true, true);
	check_int_expr("2 = 2\n", tree::NodeKind.ASSIGN_EXPR, 0, true, false, true, false, true);
	// Prefix increment requires a modifiable lvalue; integer literals are not.
	check_int_expr("++2\n", tree::NodeKind.PRE_INC_EXPR, 0, true, false, true, false, true);
	// Source-derived modifiable-lvalue rule also rejects const operands for
	// prefix increment and compound assignment.
	check_int_expr("++x\n", tree::NodeKind.PRE_INC_EXPR, 0, true, false, true, true, true);
	check_int_expr("x += 2\n", tree::NodeKind.ADD_ASSIGN_EXPR, 0, true, false, true, true, true);
	// Validate the converted operand's type before assigning !'s int result type.
	check_int_expr("!y\n", tree::NodeKind.BOOL_NOT_EXPR, 0, true, false, true, false, true, false, false, false, uint::max, type_store::VOID);
}

fn void address_dereference_sizeof_and_alignment() @test
{
	// x is seeded with scalar value 2147483647; its address remains the declaration at offset zero.
	check_int_expr("&x\n", tree::NodeKind.ADDR_OF_EXPR, 0, false, false, true, false, false, false, true);
	check_int_expr("*&x\n", tree::NodeKind.DEREF_EXPR, 0, true);
	check_int_expr("sizeof x\n", tree::NodeKind.SIZEOF_EXPR, 4, false, false, true, false, false, false, false, true);
	check_int_expr("__alignof x\n", tree::NodeKind.ALIGNOF_EXPR, 4, false, false, true, false, false, false, false, true, 1);
}

fn void pointer_arithmetic_subtraction_and_null_comparison() @test
{
	check_pointer_expr("p + 1\n", tree::NodeKind.ADD_EXPR, type_store::INT_POINTER, false, true, 4);
	check_pointer_expr("p + 2\n", tree::NodeKind.ADD_EXPR, type_store::INT_POINTER, false, true, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, false, false, false, 1, false, false, true);
	check_pointer_expr("p - p\n", tree::NodeKind.SUB_EXPR, type_store::INT, false, false, 0, true);
	check_pointer_expr("p == 0\n", tree::NodeKind.EQUAL_EXPR, type_store::INT, false);
	check_pointer_expr("0 != p\n", tree::NodeKind.NOT_EQUAL_EXPR, type_store::INT, true);
	check_pointer_expr("0 ? 0 : p\n", tree::NodeKind.COND_EXPR, type_store::INT_POINTER, false, true, 0);
	check_pointer_expr("1 ? p : 0\n", tree::NodeKind.COND_EXPR, type_store::INT_POINTER, false, true, 0);
	check_pointer_expr("p < q\n", tree::NodeKind.LESS_THAN_EXPR, type_store::INT, false, false, 0, false, type_store::VOID_POINTER, type_store::INT_POINTER, false, false, false, 0);
	// Distinct non-void pointer comparisons warn and convert only the RHS to
	// the LHS pointer type for both relational and equality operators.
	check_pointer_expr("p < q\n", tree::NodeKind.LESS_THAN_EXPR, type_store::INT, false, false, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, false, false, false, 1, false, false, false, false, true, true);
	check_pointer_expr("p == q\n", tree::NodeKind.EQUAL_EXPR, type_store::INT, true, false, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, false, false, false, 1, false, false, false, false, true, true);
	// Source-derived GNU extension: void pointer arithmetic is accepted with a
	// diagnostic, using the implementation's one-byte fallback stride.
	check_pointer_expr("p + 1\n", tree::NodeKind.ADD_EXPR, type_store::VOID_POINTER, false, true, 1, false, type_store::VOID_POINTER, type_store::VOID_POINTER, false, false, false, 1);
	// `__extension__` suppresses the warning while preserving parsing and folding.
	check_pointer_expr("__extension__ (p + 1)\n", tree::NodeKind.PAREN_EXPR, type_store::VOID_POINTER, false, true, 1, false, type_store::VOID_POINTER, type_store::VOID_POINTER, false, false, false, 0);
	check_pointer_expr("p - q\n", tree::NodeKind.SUB_EXPR, type_store::INT, false, false, 0, true, type_store::INT_POINTER, type_store::INT_POINTER, false, false, true, 1, false, true);
	check_pointer_expr("p + 0\n", tree::NodeKind.ADD_EXPR, type_store::INT_POINTER, false, false, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, true, true, false, uint::max, true);
	// Source-derived pointer arithmetic requires a complete object pointee.
	check_pointer_expr("p + 1\n", tree::NodeKind.ADD_EXPR, type_store::INT_POINTER, false, false, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, false, true, false, uint::max, false, false, false, true);
	check_pointer_expr("__imag p\n", tree::NodeKind.IMAG_EXPR, type_store::INT, false, false, 0, false, type_store::INT_POINTER, type_store::INT_POINTER, false, true);
}

fn void macro_expansion_and_eval_suppression() @test
{
	check_int_expr("#define TWO 2\nTWO + 2\n", tree::NodeKind.ADD_EXPR, 4);
	check_int_expr("2 + 2\n", tree::NodeKind.ADD_EXPR, 0, true, false, false);
	check_int_expr("0 ? 2 : 1\n", tree::NodeKind.COND_EXPR, 0, true, false, false);
}

fn void const_expression_entry_accepts_integer_expression() @test
{
	// The public integer_const_expr entry point is the parser's integer-only
	// constant-expression production; this fixture's primary callback emits int.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("const-expr.c", "2 + 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = {};
		parser_result::Result result = p.integer_const_expr_with_primary(&context, &parse_seeded_primary)!!;
		assert(p.at_eof(), "integer constant expression fixture left trailing tokens");
		assert(result.node.kind(&p.tree) == tree::NodeKind.ADD_EXPR);
		assert(result.qt.eql(type_store::INT, &comp));
		assert(result.val.to_i64(&comp)!! == 4);
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_const_expr_rejects_noninteger_result() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("noninteger-const-expr.c", "x\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		Value one = value::intern(&comp, float_value::f64_value(0x3FF0_0000_0000_0000));
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::DOUBLE } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = declaration, .val = one });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = { .symbols = &symbols, .x_name = x };
		parser_result::Result? result = p.integer_const_expr_with_primary(&context, &parse_seeded_primary);
		if (catch parse_error = result) { assert(parse_error == parser_expression::PARSING_FAILED); }
		else { assert(false, "noninteger expression accepted as an integer constant expression"); }
		assert(d.messages.len() == 1, "noninteger integer-constant expression should diagnose once");
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void primary_callback_fault_is_propagated() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("callback-fault.c", "x\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		parser_postfix::CallbackParts expression_parts = { .operand = &fail_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		fault failure = @catch(expression.parse(tokens::PREC_ANY));
		assert(failure == PRIMARY_CALLBACK_FAILURE, "primary callback fault was changed by the operator parser");
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void comma_and_conditional_preserve_operator_shape() @test
{
	check_int_expr("1, 2\n", tree::NodeKind.COMMA_EXPR, 2);
	check_int_expr("1 ? 2 : 0\n", tree::NodeKind.COND_EXPR, 2);
	check_int_expr("0 ? 2 : 1\n", tree::NodeKind.COND_EXPR, 1);
	// Source-derived GNU binary conditional: the condition is also the true arm.
	check_int_expr("2 ?: 1\n", tree::NodeKind.BINARY_COND_EXPR, 2);
	check_int_expr("0 ?: 2\n", tree::NodeKind.BINARY_COND_EXPR, 2);
	check_int_expr("1 ? 2 : 3\n", tree::NodeKind.COND_EXPR, 0, true, false, false);
}

fn void conditional_uses_common_type_of_both_arms() @test
{
	// Source-derived C conditional typing: even though the false arm is chosen,
	// an int/double pair has double common type and converts the int arm.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("conditional.c", "0 ? y : x\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		StringId y = comp.intern_string("y");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex xd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::INT } });
		NodeIndex yd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::DOUBLE } });
		Value one = value::int_i64(1, &comp);
		Value double_one = value::intern(&comp, float_value::f64_value(0x3FF0_0000_0000_0000));
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::INT, .node = xd, .val = one });
		symbols.define({ .name = y, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = yd, .val = double_one });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = { .symbols = &symbols, .x_name = x, .y_name = y };
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_seeded_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result result = expression.parse()!!;
		assert(p.at_eof(), "conditional expression fixture left trailing tokens");
		assert(result.node.kind(&p.tree) == tree::NodeKind.COND_EXPR);
		assert(result.qt.eql(type_store::DOUBLE, &comp));
		assert(result.val.opt_ref == double_one.opt_ref);
		Node conditional = result.node.get(&p.tree);
		Node converted_else = conditional.conditional.else_expr.get(&p.tree);
		assert(converted_else.kind == tree::NodeKind.CAST);
		assert(converted_else.cast.kind == tree::CastKind.INT_TO_FLOAT);
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void short_circuit_and_invalid_forms() @test
{
	check_int_expr("0 && x\n", tree::NodeKind.BOOL_AND_EXPR, 0);
	check_int_expr("1 || x\n", tree::NodeKind.BOOL_OR_EXPR, 1);
	// The RHS is parsed for type checking but eval=false must suppress the
	// constant divide-by-zero rejection and leave its value unavailable.
	// Source-derived: the suppressed RHS/arm still parses, but its divide by
	// zero must not be evaluated or emit the normal arithmetic warning.
	check_int_expr("0 && (1 / 0)\n", tree::NodeKind.BOOL_AND_EXPR, 0, false, false, true, false, false, false, false, false, 0);
	check_int_expr("1 || (1 / 0)\n", tree::NodeKind.BOOL_OR_EXPR, 1, false, false, true, false, false, false, false, false, 0);
	check_int_expr("0 && (x <<= 32)\n", tree::NodeKind.BOOL_AND_EXPR, 0, false, false, true, false, false, false, false, false, 0);
	check_int_expr("0 ? (1 / 0) : 2\n", tree::NodeKind.COND_EXPR, 2, false, false, true, false, false, false, false, false, 0);
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("bad.c", "1 +\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = {};
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_seeded_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result? bad = expression.parse();
		if (catch parse_error = bad) { assert(parse_error == parser_expression::PARSING_FAILED); }
		else { assert(false, "incomplete binary expression parsed"); }
		assert(d.messages.len() > 0, "malformed binary expression failed without a diagnostic");
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void float_operands_keep_arithmetic_ast_type() @test
{
	// Source-derived: Value arithmetic also folds floating operands; float_value_tests.c3
	// separately covers the underlying IEEE operations.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("float-op.c", "x + y\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		StringId y = comp.intern_string("y");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex xd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::DOUBLE } });
		NodeIndex yd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::DOUBLE } });
		Value one = value::intern(&comp, float_value::f64_value(0x3FF0_0000_0000_0000));
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = xd, .val = one });
		symbols.define({ .name = y, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = yd, .val = one });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = { .symbols = &symbols, .x_name = x, .y_name = y };
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_seeded_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result result = expression.parse()!!;
		assert(p.at_eof(), "floating operator fixture left trailing tokens");
		assert(result.node.kind(&p.tree) == tree::NodeKind.ADD_EXPR);
		assert(result.qt.eql(type_store::DOUBLE, &comp));
		assert(result.val.to_float(value_interner::InternerKeyTag.F64, &comp).raw() == 0x4000_0000_0000_0000);
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void complex_arithmetic_and_unary_conjugation_fold() @test
{
	// Source-derived from the complex operator rules: complex operands retain
	// their complex AST type during addition, and '~' computes conjugation.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::QualType complex_double = comp.type_store.put(type_store::type_complex(type_store::DOUBLE));
		Value x_value = value::intern(&comp, float_value::make_complex(
			float_value::f64_value(0x3FF0_0000_0000_0000), float_value::f64_value(0x4000_0000_0000_0000)));
		Value y_value = value::intern(&comp, float_value::make_complex(
			float_value::f64_value(0x4008_0000_0000_0000), float_value::f64_value(0x4010_0000_0000_0000)));
		Value sum_value = value::intern(&comp, float_value::make_complex(
			float_value::f64_value(0x4010_0000_0000_0000), float_value::f64_value(0x4018_0000_0000_0000)));
		Value conjugate_value = value::intern(&comp, float_value::make_complex(
			float_value::f64_value(0x3FF0_0000_0000_0000), float_value::f64_value(0xC000_0000_0000_0000)));
		Source src = comp.add_source_from_buffer("complex-operator.c", "x + y; ~x; __imag x; __real x; __imag__ y; __real__ y; __imag 2; __real 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		StringId y = comp.intern_string("y");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex xd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = complex_double } });
		NodeIndex yd = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = complex_double } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = complex_double, .node = xd, .val = x_value });
		symbols.define({ .name = y, .kind = symbol_stack::SymbolKind.DEF, .qt = complex_double, .node = yd, .val = y_value });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		OperatorContext context = { .symbols = &symbols, .x_name = x, .y_name = y };
		parser_postfix::CallbackParts expression_parts = { .context = &context, .operand = &parse_seeded_primary };
		parser_expression::ExpressionParser expression = { .parser = &p, .parts = &expression_parts };
		parser_result::Result addition = expression.parse()!!;
		assert(!p.at_eof(), "complex operator fixture lost the separator");
		assert(addition.node.kind(&p.tree) == tree::NodeKind.ADD_EXPR);
		assert(addition.qt.eql(complex_double, &comp));
		assert(addition.val.opt_ref == sum_value.opt_ref);
		p.advance();
		parser_result::Result conjugation = expression.parse()!!;
		assert(!p.at_eof(), "complex operator fixture lost the separator after conjugation");
		assert(conjugation.node.kind(&p.tree) == tree::NodeKind.BIT_NOT_EXPR);
		assert(conjugation.qt.eql(complex_double, &comp));
		assert(conjugation.val.opt_ref == conjugate_value.opt_ref);
		p.advance();
		parser_result::Result imaginary_x = expression.parse()!!;
		assert(imaginary_x.node.kind(&p.tree) == tree::NodeKind.IMAG_EXPR);
		assert(imaginary_x.qt.eql(type_store::DOUBLE, &comp));
		// Source-derived vector: x has real=1.0 and imaginary=2.0.
		assert(imaginary_x.val.to_float(value_interner::InternerKeyTag.F64, &comp).raw() == 0x4000_0000_0000_0000);
		p.advance();
		parser_result::Result real_x = expression.parse()!!;
		assert(real_x.node.kind(&p.tree) == tree::NodeKind.REAL_EXPR);
		assert(real_x.qt.eql(type_store::DOUBLE, &comp));
		assert(real_x.val.to_float(value_interner::InternerKeyTag.F64, &comp).raw() == 0x3FF0_0000_0000_0000);
		p.advance();
		parser_result::Result imaginary_y = expression.parse()!!;
		assert(imaginary_y.node.kind(&p.tree) == tree::NodeKind.IMAG_EXPR);
		assert(imaginary_y.val.to_float(value_interner::InternerKeyTag.F64, &comp).raw() == 0x4010_0000_0000_0000);
		p.advance();
		parser_result::Result real_y = expression.parse()!!;
		assert(real_y.node.kind(&p.tree) == tree::NodeKind.REAL_EXPR);
		assert(real_y.val.to_float(value_interner::InternerKeyTag.F64, &comp).raw() == 0x4008_0000_0000_0000);
		p.advance();
		parser_result::Result imaginary_int = expression.parse()!!;
		assert(imaginary_int.node.kind(&p.tree) == tree::NodeKind.IMAG_EXPR);
		assert(imaginary_int.qt.eql(type_store::INT, &comp));
		assert(imaginary_int.val.to_i64(&comp)!! == 0);
		p.advance();
		parser_result::Result real_int = expression.parse()!!;
		assert(real_int.node.kind(&p.tree) == tree::NodeKind.REAL_EXPR);
		assert(real_int.qt.eql(type_store::INT, &comp));
		assert(real_int.val.to_i64(&comp)!! == 2);
		assert(p.at_eof(), "GNU real/imag fixture left trailing tokens");
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
