// Source-derived direct tests for parser_builtin and builtin_eval. These use
// the modules' callback / dispatcher APIs and do not claim full C grammar or
// downstream semantic coverage.
module builtin_expression_tests;
import aro::builtin_eval, aro::builtin_defs::common, aro::builtins;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_builtin, aro::parser_result;
import aro::parser_expression, aro::parser_frontend;
import aro::target, aro::lang_opts;
import aro::attribute, aro::attribute_map;
import aro::preprocessor, aro::source, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::float_value, aro::value_interner;
import aro::string_interner, aro::symbol_stack;
import std::core::mem::allocators;

const Host HOST = { X86_64, LINUX, GNU };

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

struct CallbackContext
{
	uint expression_calls;
	bool[3] expression_eval;
	uint constant_calls;
}

alias TestAssignment = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
alias TestIntegerConstant = fn parser_result::Result?(void* context, parser::Parser* p, parser::ConstDeclFoldingMode mode, bool eval);

<* IExpressionGrammar over the tests' callback functions; a null callback is HOOK_ABSENT. *>
struct CallbackExpressions (parser::IExpressionGrammar)
{
	void* context;
	TestAssignment assign;
	TestIntegerConstant int_const;
}

fn parser_result::Result? CallbackExpressions.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
{
	if (!self.assign) return parser::HOOK_ABSENT~;
	return self.assign(self.context, p, eval);
}

fn parser_result::Result? CallbackExpressions.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval) @dynamic
{
	if (!self.int_const) return parser::HOOK_ABSENT~;
	return self.int_const(self.context, p, mode, eval);
}

struct OffsetTypeContext (parser::IParserHandler) { type_store::QualType qt; }

fn type_store::QualType? OffsetTypeContext.handle_typed_type_name(&self, parser::Parser* p) @dynamic
	=> parse_offset_record_type((void*)self, p);

<* Typed type-name handler accepting only `int`. *>
struct IntTypeHandler (parser::IParserHandler) { int unused; }

fn type_store::QualType? IntTypeHandler.handle_typed_type_name(&self, parser::Parser* p) @dynamic
	=> parse_int_type(null, p);

<* Typed type-name handler mapping `int` to a 4 x int vector. *>
struct VectorTypeHandler (parser::IParserHandler) { int unused; }

fn type_store::QualType? VectorTypeHandler.handle_typed_type_name(&self, parser::Parser* p) @dynamic
	=> parse_vector_type(null, p);

fn type_store::QualType? parse_offset_record_type(void* context, parser::Parser* p)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.IDENTIFIER) return parser_builtin::PARSING_FAILED~;
	p.advance();
	return ((OffsetTypeContext*)context).qt;
}

fn parser_result::Result? parse_choose_operand(void* context, parser::Parser* p, bool eval)
{
	CallbackContext* ctx = (CallbackContext*)context;
	if (p.at_eof()) return parser_builtin::PARSING_FAILED~;
	if (p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.PP_NUM && p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.MINUS) return parser_builtin::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	bool negative = false;
	if (p.tree.tokens[(usz)tok].id == tokenizer::TokenId.MINUS) { negative = true; p.advance(); tok = p.tok_i; }
	if (p.at_eof() || p.tree.tokens[(usz)tok].id != tokenizer::TokenId.PP_NUM) return parser_builtin::PARSING_FAILED~;
	String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
	long n = spelling == "0" ? 0 : spelling == "1" ? 1 : spelling == "2" ? 2 : 3;
	if (negative) n = -n;
	assert(ctx.expression_calls < ctx.expression_eval.len);
	ctx.expression_eval[ctx.expression_calls++] = eval;
	NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	return { .node = node, .qt = type_store::INT,
		.val = eval ? value::int_i64(n, p.comp) : value::NONE };
}

fn parser_result::Result? parse_vector_operand(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.PP_NUM) return parser_builtin::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	type_store::QualType vec = p.comp.type_store.put(type_store::type_vector(type_store::INT, 4));
	return { .node = node, .qt = vec, .val = value::NONE };
}

fn parser_result::Result? parse_choose_constant(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval)
{
	CallbackContext* ctx = (CallbackContext*)context;
	ctx.constant_calls++;
	return parse_choose_operand(context, p, eval);
}

fn parser_result::Result? parse_offset_integer_primary(void* context, parser::Parser* p, bool eval)
{
	(void)context;
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.PP_NUM) return parser_builtin::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
	long n = spelling == "0" ? 0 : spelling == "1" ? 1 : spelling == "2" ? 2 : spelling == "3" ? 3 : 4;
	NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	return { .node = node, .qt = type_store::INT,
		.val = eval ? value::int_i64(n, p.comp) : value::NONE };
}

fn parser_result::Result? parse_offset_integer_constant(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval)
{
	CallbackContext* ctx = (CallbackContext*)context;
	ctx.constant_calls++;
	return p.integer_const_expr_with_primary(null, &parse_offset_integer_primary, eval, mode);
}

fn parser_result::Result? parse_offset_assignment_expression(void* context, parser::Parser* p, bool eval)
	=> p.assign_expr_with_primary(null, &parse_offset_integer_primary, eval);

fn parser_result::Result? parse_nonconstant_offset_index(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval)
{
	(void)context; (void)mode; (void)eval;
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.IDENTIFIER) return parser_builtin::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	return { .node = node, .qt = type_store::INT, .val = value::NONE };
}

fn parser_result::Result? parse_nonconstant_offset_expression(void* context, parser::Parser* p, bool eval)
	=> parse_nonconstant_offset_index(context, p, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION, eval);

fn type_store::QualType? parse_int_type(void* context, parser::Parser* p)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.KEYWORD_INT) return parser_builtin::PARSING_FAILED~;
	p.advance();
	return type_store::INT;
}

fn type_store::QualType? parse_vector_type(void* context, parser::Parser* p)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.KEYWORD_INT) return parser_builtin::PARSING_FAILED~;
	p.advance();
	return p.comp.type_store.put(type_store::type_vector(type_store::INT, 4));
}

fn void choose_expression_suppresses_unselected_evaluation() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("choose-expr.c", "(1, 2, 0)\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_choose_operand, .int_const = &parse_choose_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.choose_expr()!!;
		assert(p.at_eof());
		assert(result.node.kind(&p.tree) == tree::NodeKind.BUILTIN_CHOOSE_EXPR);
		assert(result.val.to_i64(&comp)!! == 2);
		assert(context.constant_calls == 1 && context.expression_calls == 3);
		assert(context.expression_eval[0] && context.expression_eval[1] && !context.expression_eval[2]);
		assert(result.qt.eql(type_store::INT, &comp));
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void types_compatible_expression_returns_constant_boolean() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("types-compatible.c", "(int, int)\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		IntTypeHandler int_types;
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d, .handler = &int_types };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		parser_builtin::BuiltinParser builtin = { .parser = &p };
		parser_result::Result result = builtin.types_compatible(0)!!;
		assert(p.at_eof());
		assert(result.node.kind(&p.tree) == tree::NodeKind.BUILTIN_TYPES_COMPATIBLE_P);
		assert(result.qt.eql(type_store::INT, &comp));
		assert(result.val.to_i64(&comp)!! == 1);
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_eval_infinity_and_isinf_finite_cases() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		// Parser holds Tree by value: nodes and values must go through p.tree.
		// A separate Tree copied into p.tree would miss later add_node/set_value.
		parser::Parser p = { .comp = &comp };
		Tree* tree = &p.tree;
		tree.init(&comp, {});
		builtins::Expanded inf_builtin = { .tag = common::TAG___BUILTIN_INF,
			.attributes = { .const_evaluable = true } };
		value::Value inf = builtin_eval::eval(inf_builtin, &p, {});
		assert(!inf.is_none() && float_value::is_inf(inf, &comp));
		builtins::Expanded inff_builtin = { .tag = common::TAG___BUILTIN_INFF,
			.attributes = { .const_evaluable = true } };
		builtins::Expanded infl_builtin = { .tag = common::TAG___BUILTIN_INFL,
			.attributes = { .const_evaluable = true } };
		value_interner::KeyFloat f_inf = comp.interner.get(builtin_eval::eval(inff_builtin, &p, {}).ref()).float_val;
		value_interner::KeyFloat ld_inf = comp.interner.get(builtin_eval::eval(infl_builtin, &p, {}).ref()).float_val;
		assert(f_inf.is_inf() && f_inf.tag == float_value::tag_for_bits(type_store::FLOAT.bit_sizeof(&comp)));
		assert(ld_inf.is_inf() && ld_inf.tag == float_value::tag_for_bits(type_store::LONG_DOUBLE.bit_sizeof(&comp)));
		NodeIndex finite_arg = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		tree.set_value(finite_arg, value::int_i64(7, &comp));
		NodeIndex[] args = { finite_arg };
		builtins::Expanded isinf_builtin = { .tag = common::TAG___BUILTIN_ISINF,
			.attributes = { .const_evaluable = true } };
		value::Value finite_result = builtin_eval::eval(isinf_builtin, &p, args);
		assert(!finite_result.is_none() && finite_result.to_i64(&comp)!! == 0);
		NodeIndex unknown_arg = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		NodeIndex[] unknown_args = { unknown_arg };
		assert(builtin_eval::eval(isinf_builtin, &p, unknown_args).is_none());
		value::Value missing = builtin_eval::eval(isinf_builtin, &p, {});
		assert(missing.is_none());
		builtins::Expanded unsupported = { .tag = common::TAG___BUILTIN_ISINF };
		assert(builtin_eval::eval(unsupported, &p, args).is_none());
		tree.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_eval_bswap16_32_64_and_missing_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		parser::Parser p = { .comp = &comp };
		Tree* tree = &p.tree;
		tree.init(&comp, {});

		NodeIndex arg16 = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		tree.set_value(arg16, value::int_u64(0x1234, &comp));
		NodeIndex[] args16 = { arg16 };
		builtins::Expanded bswap16_builtin = { .tag = common::TAG___BUILTIN_BSWAP16,
			.attributes = { .const_evaluable = true } };
		value::Value result16 = builtin_eval::eval(bswap16_builtin, &p, args16);
		assert(!result16.is_none() && result16.to_u64(&comp)!! == 0x3412);

		NodeIndex arg32 = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		tree.set_value(arg32, value::int_u64(1, &comp));
		NodeIndex[] args32 = { arg32 };
		builtins::Expanded bswap32_builtin = { .tag = common::TAG___BUILTIN_BSWAP32,
			.attributes = { .const_evaluable = true } };
		value::Value result32 = builtin_eval::eval(bswap32_builtin, &p, args32);
		assert(!result32.is_none() && result32.to_u64(&comp)!! == 0x01000000);

		NodeIndex arg64 = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		tree.set_value(arg64, value::int_u64(0x0102030405060708, &comp));
		NodeIndex[] args64 = { arg64 };
		builtins::Expanded bswap64_builtin = { .tag = common::TAG___BUILTIN_BSWAP64,
			.attributes = { .const_evaluable = true } };
		value::Value result64 = builtin_eval::eval(bswap64_builtin, &p, args64);
		assert(!result64.is_none() && result64.to_u64(&comp)!! == 0x0807060504030201);

		NodeIndex unknown_arg = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .qt = type_store::INT } });
		NodeIndex[] unknown_args = { unknown_arg };
		assert(builtin_eval::eval(bswap16_builtin, &p, unknown_args).is_none());

		tree.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

<* Source-derived target long-double formats for __builtin_infl. *>
fn void check_infl_target_format(Compilation* comp, parser::Parser* p, String triple,
	ulong width, value_interner::KeyFloatTag tag, uint128 raw)
{
	comp.target = target::parse_triple(triple, HOST)!!;
	comp.langopts.set_target_options(&comp.target);
	type_store::init_named_types(comp);
	assert(type_store::LONG_DOUBLE.bit_sizeof(comp) == width);
	builtins::Expanded infl_builtin = { .tag = common::TAG___BUILTIN_INFL,
		.attributes = { .const_evaluable = true } };
	value::Value result = builtin_eval::eval(infl_builtin, p, {});
	assert(!result.is_none());
	value_interner::KeyFloat inf = comp.interner.get(result.ref()).float_val;
	assert(inf.tag == tag && inf.raw() == raw);
}

fn void builtin_eval_infl_target_long_double_formats() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		Tree tree;
		tree.init(&comp, {});
		parser::Parser p = { .comp = &comp };
		p.tree = tree;

		check_infl_target_format(&comp, &p, "avr-freestanding-none", 32,
			value_interner::KeyFloatTag.F32, 0x7F80_0000);
		check_infl_target_format(&comp, &p, "msp430-other-none", 64,
			value_interner::KeyFloatTag.F64, 0x7FF0_0000_0000_0000);
		// KeyFloat.raw() zero-extends the 80-bit x87 payload into uint128.
		check_infl_target_format(&comp, &p, "x86_64-linux-gnu", 80,
			value_interner::KeyFloatTag.F80, ((uint128)0x7FFF << 64) | (uint128)0x8000_0000_0000_0000);

		tree.free();
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

// Direct assertions for the behavior in src/aro/Builtins/eval.zig; these do
// not claim that the C3 evaluator is an executable Zig parity test.
fn void builtin_eval_nan_sign_predicates_and_constant_p_cases() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d; d.init_list(&ta);
		Compilation comp; comp.init(&ta, null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		// Parser holds Tree by value: nodes and values must go through p.tree.
		// A separate Tree copied into p.tree would miss later add_node/set_value.
		parser::Parser p = { .comp = &comp };
		Tree* tree = &p.tree; tree.init(&comp, {});
		assert(type_store::DOUBLE.bit_sizeof(&comp) == 64);
		builtins::Expanded nan_builtin = { .tag = common::TAG___BUILTIN_NAN, .attributes = { .const_evaluable = true } };
		NodeIndex string_node = tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .qt = type_store::CHAR } });
		tree.set_value(string_node, value::intern(&comp, { .tag = BYTES, .bytes = "0x123" }));
		NodeIndex[] string_arg = { string_node };
		value::Value nan = builtin_eval::eval(nan_builtin, &p, string_arg);
		value_interner::KeyFloat nan_float = comp.interner.get(nan.ref()).float_val;
		assert(nan_float.is_nan());
		assert(nan_float.raw() == (float_value::std_nan(value_interner::KeyFloatTag.F64).raw() | 0x123));
		NodeIndex octal_string = tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .qt = type_store::CHAR } });
		tree.set_value(octal_string, value::intern(&comp, { .tag = BYTES, .bytes = "010" }));
		NodeIndex[] octal_arg = { octal_string };
		value_interner::KeyFloat octal_nan = comp.interner.get(builtin_eval::eval(nan_builtin, &p, octal_arg).ref()).float_val;
		assert(octal_nan.raw() == (float_value::std_nan(value_interner::KeyFloatTag.F64).raw() | 8));
		NodeIndex binary_string = tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .qt = type_store::CHAR } });
		tree.set_value(binary_string, value::intern(&comp, { .tag = BYTES, .bytes = "0b101101" }));
		NodeIndex[] binary_arg = { binary_string };
		value_interner::KeyFloat binary_nan = comp.interner.get(builtin_eval::eval(nan_builtin, &p, binary_arg).ref()).float_val;
		assert(binary_nan.raw() == 0x7FF8_0000_0000_002D);
		NodeIndex wide_payload_string = tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .qt = type_store::CHAR } });
		tree.set_value(wide_payload_string, value::intern(&comp, { .tag = BYTES, .bytes = "0xABC123456789ABCD" }));
		NodeIndex[] wide_payload_arg = { wide_payload_string };
		value_interner::KeyFloat truncated_nan = comp.interner.get(builtin_eval::eval(nan_builtin, &p, wide_payload_arg).ref()).float_val;
		assert(truncated_nan.raw() == 0x7FF9_2345_6789_ABCD);
		assert(builtin_eval::eval(nan_builtin, &p, {}).is_none());
		NodeIndex unavailable_nan_string = tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .qt = type_store::CHAR } });
		NodeIndex[] unavailable_nan_arg = { unavailable_nan_string };
		assert(builtin_eval::eval(nan_builtin, &p, unavailable_nan_arg).is_none());

		NodeIndex nan_node = tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
			.literal = { .qt = type_store::DOUBLE } });
		tree.set_value(nan_node, nan);
		NodeIndex[] nan_arg = { nan_node };
		builtins::Expanded isnan_builtin = { .tag = common::TAG___BUILTIN_ISNAN, .attributes = { .const_evaluable = true } };
		assert(builtin_eval::eval(isnan_builtin, &p, nan_arg).to_i64(&comp)!! == 1);

		value::Value pos_inf = float_value::intern_float(float_value::inf(value_interner::KeyFloatTag.F64), &comp);
		value::Value neg_inf = float_value::intern_float(float_value::from_raw(value_interner::KeyFloatTag.F64, 0xFFF0_0000_0000_0000), &comp);
		NodeIndex pos_node = tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL, .literal = { .qt = type_store::DOUBLE } });
		NodeIndex neg_node = tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL, .literal = { .qt = type_store::DOUBLE } });
		tree.set_value(pos_node, pos_inf); tree.set_value(neg_node, neg_inf);
		NodeIndex[] pos_arg = { pos_node }; NodeIndex[] neg_arg = { neg_node };
		builtins::Expanded sign_builtin = { .tag = common::TAG___BUILTIN_ISINF_SIGN, .attributes = { .const_evaluable = true } };
		assert(builtin_eval::eval(sign_builtin, &p, pos_arg).to_i64(&comp)!! == 1);
		assert(builtin_eval::eval(sign_builtin, &p, neg_arg).to_i64(&comp)!! == -1);
		// eval.zig: isInfSign .finite => Value.zero. Value.zig isInfSign classifies NaN as
		// .finite (std.math.isInf is false for NaN), so sign(NaN) folds to 0, not none.
		assert(builtin_eval::eval(sign_builtin, &p, nan_arg).to_i64(&comp)!! == 0);

		builtins::Expanded constant_builtin = { .tag = common::TAG___BUILTIN_CONSTANT_P, .attributes = { .const_evaluable = true } };
		NodeIndex scalar = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::INT } });
		tree.set_value(scalar, value::int_i64(8, &comp));
		NodeIndex[] scalar_arg = { scalar };
		// eval.zig: non-float key -> isInfSign .unknown -> break -> none.
		assert(builtin_eval::eval(sign_builtin, &p, scalar_arg).is_none());
		assert(builtin_eval::eval(isnan_builtin, &p, scalar_arg).to_i64(&comp)!! == 0);
		NodeIndex unavailable = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::INT } });
		NodeIndex pointer = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::VOID_POINTER } });
		tree.set_value(pointer, value::pointer({ .node = 9, .offset = (value_interner::InternerRef)0 }, &comp));
		NodeIndex addr_string = tree.add_node({ .kind = tree::NodeKind.ADDR_OF_EXPR,
			.unary = { .qt = type_store::VOID_POINTER, .operand = string_node } });
		NodeIndex[] unavailable_arg = { unavailable };
		NodeIndex[] pointer_arg = { pointer }; NodeIndex[] addr_string_arg = { addr_string };
		assert(builtin_eval::eval(constant_builtin, &p, scalar_arg).to_i64(&comp)!! == 1);
		assert(builtin_eval::eval(constant_builtin, &p, pointer_arg).to_i64(&comp)!! == 0);
		assert(builtin_eval::eval(constant_builtin, &p, unavailable_arg).to_i64(&comp)!! == 0);
		assert(builtin_eval::eval(constant_builtin, &p, addr_string_arg).to_i64(&comp)!! == 1);
		tree.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

<* Unwrap argument conversions around the real parser's subscript node. *>
fn NodeIndex subscript_argument(parser::Parser* p, NodeIndex node)
{
	while (true)
	{
		tree::Node current = node.get(&p.tree);
		switch (current.kind)
		{
			case PAREN_EXPR: node = current.unary.operand;
			case CAST: node = current.cast.operand;
			case ARRAY_ACCESS_EXPR: return node;
			default: unreachable("expected a string subscript argument, got %s", current.kind.name);
		}
	}
}

<* Parse __builtin_constant_p with the production expression and frontend
   hooks. The optional index symbol is an ordinary runtime variable with no
   constant value. *>
fn void check_builtin_constant_p_string_subscript(String text, long expected, bool runtime_index)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		comp.langopts.standard = lang_opts::Standard.C17;
		type_store::init_named_types(&comp);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("constant-p-subscript.c", text)!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		parser_frontend::FrontendHandler frontend;
		p.init(&pp, &frontend);
		frontend.bind(&p);
		p.bind_finalized_tokens();
		if (runtime_index)
		{
			NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
				.variable = { .name_tok = 0, .qt = type_store::INT } });
			p.define_symbol({ .name = comp.intern_string("index"), .qt = type_store::INT,
				.tok = 0, .node = declaration, .kind = symbol_stack::SymbolKind.DEF,
				.val = value::NONE });
		}
		parser_result::Result result = p.expr()!!;
		assert(p.at_eof());
		assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR);
		assert(result.val.to_i64(&comp)!! == expected);
		assert(d.messages.len() == 0, "unexpected parser diagnostic");
		tree::Node call = result.node.get(&p.tree);
		assert(call.builtin_call.args.len == 1);
		NodeIndex access_index = subscript_argument(&p, call.builtin_call.args[0]);
		tree::Node access = access_index.get(&p.tree);
		assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
		bool has_subscript_value = false;
		if (try subscript_value = p.tree.value_of(access_index)) has_subscript_value = !subscript_value.is_none();
		if (runtime_index)
		{
			assert(!has_subscript_value, "a runtime string subscript must stay unavailable");
			assert(access.array_access.index.get(&p.tree).kind == tree::NodeKind.CAST);
		}
		else
		{
			assert(expected == 1);
			assert(access.array_access.index.get(&p.tree).kind == tree::NodeKind.INT_LITERAL);
		}
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_constant_p_folds_string_subscripts_only_when_constant() @test
{
	check_builtin_constant_p_string_subscript("__builtin_constant_p(\"ABC\"[0])\n", 1, false);
	check_builtin_constant_p_string_subscript("__builtin_constant_p(\"ABC\"[index])\n", 0, true);
}

<* Parse a file-scope snippet with the production expression path. The result
   must fold to `expected` and the parse must emit no diagnostics, so a stale
   "initializer overrides previous initialization" warning fails the check. *>
fn void check_constant_expression_no_diagnostics(String text, long expected)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		comp.langopts.standard = lang_opts::Standard.C17;
		type_store::init_named_types(&comp);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("constant-expression.c", text)!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		parser_frontend::FrontendHandler frontend;
		p.init(&pp, &frontend);
		frontend.bind(&p);
		p.bind_finalized_tokens();
		parser_result::Result result = p.expr()!!;
		assert(p.at_eof());
		assert(result.val.to_i64(&comp)!! == expected);
		assert(d.messages.len() == 0, "unexpected parser diagnostic");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_constant_p_folds_scalar_compound_literal() @test
{
	check_constant_expression_no_diagnostics("__builtin_constant_p((int){4}) == 1\n", 1);
}

fn void shufflevector_diagnoses_index_below_negative_one_and_keeps_ast() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("shuffle.c", "(1, 2, -2)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_vector_operand, .int_const = &parse_choose_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.shufflevector(0)!!;
		assert(p.at_eof() && result.node.kind(&p.tree) == tree::NodeKind.BUILTIN_SHUFFLEVECTOR);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "index for __builtin_shufflevector must be positive or -1");
		check(d.messages[0].location.col, 8);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void shufflevector_builds_result_type_and_index_nodes() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("shuffle-valid.c", "(1, 2, 1, -1)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_vector_operand, .int_const = &parse_choose_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.shufflevector(0)!!;
		assert(p.at_eof() && result.node.kind(&p.tree) == tree::NodeKind.BUILTIN_SHUFFLEVECTOR);
		tree::Node node = p.tree.decode_expr_stmt(result.node);
		assert(node.shufflevector.indexes.len == 2);
		assert(node.shufflevector.qt.get(&comp, type_store::TypeTag.VECTOR)!!.vector.len == 2);
		assert(p.tree.value_of(node.shufflevector.indexes[0])!!.to_i64(&comp)!! == 1);
		assert(p.tree.value_of(node.shufflevector.indexes[1])!!.to_i64(&comp)!! == -1);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void convertvector_builds_destination_typed_node() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("convertvector.c", "(1, int)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		VectorTypeHandler vector_types;
		parser::Parser p; p.init(&pp, &vector_types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_vector_operand };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.convertvector(0)!!;
		assert(p.at_eof() && result.node.kind(&p.tree) == tree::NodeKind.BUILTIN_CONVERTVECTOR);
		tree::Node node = p.tree.decode_expr_stmt(result.node);
		assert(node.convertvector.dest_qt.eql(result.qt, &comp));
		assert(result.qt.get(&comp, type_store::TypeTag.VECTOR)!!.vector.len == 4);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void va_arg_and_offsetof_report_specialized_type_errors() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("builtin-errors.c", "(1, int)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		IntTypeHandler int_types;
		parser::Parser p; p.init(&pp, &int_types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_choose_operand };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		assert(@catch(builtin.va_arg(0)) == parser_builtin::PARSING_FAILED);
		assert(d.messages.len() == 1);
		// Parser/Diagnostic.zig::incompatible_va_arg uses {qt}; Parser.zig::formatQualType quotes it.
		test::eq(d.messages[0].text, "first argument to va_arg, is of type 'int' and not 'va_list'");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
	{
		TrackingAllocator ta2; ta2.init(mem); defer ta2.free();
		Diagnostics d; d.init_list(&ta2); Compilation comp; comp.init(&ta2, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("offsetof-error.c", "(int, field) (int, field)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		IntTypeHandler int_types;
		parser::Parser p; p.init(&pp, &int_types);
		p.bind_finalized_tokens();
		parser_builtin::BuiltinParser builtin = { .parser = &p };
		assert(@catch(builtin.offsetof(0)) == parser_builtin::PARSING_FAILED);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "offsetof requires struct or union type, 'int' invalid");
		while (!p.is_at(tokenizer::TokenId.L_PAREN)) p.advance();
		assert(@catch(builtin.offsetof(0, true)) == parser_builtin::PARSING_FAILED);
		assert(d.messages.len() == 2);
		test::eq(d.messages[1].text, "offsetof requires struct or union type, 'int' invalid");
		p.free(); pp.free(); comp.free(); d.free();
	}
}

// Source-derived from Parser.zig::offsetofMemberDesignator: array access
// decays the field to a pointer and adds each element's bit size to the offset.
fn void offsetof_array_designators_accumulate_nested_record_offsets() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("offsetof-array.c", "(Root, items[1 + 1].value)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		type_store::RecordField[1] leaf_fields = { type_store::record_field(comp.intern_string("value"), type_store::INT) };
		leaf_fields[0].layout = { .offset_bits = 0, .size_bits = 32 };
		type_store::RecordLayout layout = { .size_bits = 32, .field_alignment_bits = 32,
			.pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType leaf = comp.type_store.put(type_store::type_record(comp.intern_string("Leaf"), leaf_fields[..], layout));
		type_store::QualType leaves = comp.type_store.put(type_store::type_array(leaf, type_store::ArrayLenKind.FIXED, 4));
		type_store::RecordField[1] root_fields = { type_store::record_field(comp.intern_string("items"), leaves) };
		root_fields[0].layout = { .offset_bits = 0, .size_bits = 128 };
		type_store::QualType root = comp.type_store.put(type_store::type_record(comp.intern_string("Root"), root_fields[..], layout));
		OffsetTypeContext types = { .qt = root };
		parser::Parser p; p.init(&pp, &types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .int_const = &parse_offset_integer_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.offsetof(0, true)!!;
		assert(p.at_eof() && result.val.to_i64(&comp)!! == 64);
		tree::Node call = result.node.get(&p.tree);
		tree::Node member = call.builtin_call.args[0].get(&p.tree);
		assert(member.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
		tree::Node array = member.member_access.base.get(&p.tree);
		assert(array.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
		assert(array.array_access.qt.eql(leaf, &comp));
		tree::Node array_decay = array.array_access.base.get(&p.tree);
		assert(array_decay.kind == tree::NodeKind.CAST);
		assert(array_decay.cast.kind == tree::CastKind.ARRAY_TO_POINTER);
		tree::Node first_member = array_decay.cast.operand.get(&p.tree);
		tree::Node base = first_member.member_access.base.get(&p.tree);
		assert(p.tree.tokens[(usz)base.default_init.last_tok].id == tokenizer::TokenId.L_BRACKET);
		assert(context.constant_calls == 1);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Source-derived from Parser.zig::fieldAccessExtra: anonymous record fields
// promote their members and contribute each nested layout offset.
fn void offsetof_resolves_promoted_anonymous_record_fields() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("offsetof-anonymous.c", "(Root, value)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		type_store::RecordField[1] inner_fields = {
			type_store::record_field(comp.intern_string("value"), type_store::INT) };
		inner_fields[0].layout = { .offset_bits = 8, .size_bits = 32 };
		type_store::RecordLayout inner_layout = { .size_bits = 40, .field_alignment_bits = 8,
			.pointer_alignment_bits = 8, .required_alignment_bits = 8 };
		type_store::QualType inner = comp.type_store.put(type_store::type_record(
			comp.intern_string("Inner"), inner_fields[..], inner_layout));
		type_store::RecordField[1] fields = {
			type_store::record_field(string_interner::EMPTY, inner) };
		fields[0].layout = { .offset_bits = 16, .size_bits = 40 };
		type_store::RecordLayout layout = { .size_bits = 56, .field_alignment_bits = 8,
			.pointer_alignment_bits = 8, .required_alignment_bits = 8 };
		type_store::QualType root = comp.type_store.put(type_store::type_record(
			comp.intern_string("Root"), fields[..], layout));
		OffsetTypeContext types = { .qt = root };
		parser::Parser p; p.init(&pp, &types);
		p.bind_finalized_tokens();
		CallbackExpressions exprs = { .int_const = &parse_offset_integer_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.offsetof(0, true)!!;
		assert(result.val.to_i64(&comp)!! == 24);
		tree::Node access = result.node.get(&p.tree).builtin_call.args[0].get(&p.tree);
		assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
		assert(access.member_access.member_index == 0);
		tree::Node anonymous = access.member_access.base.get(&p.tree);
		assert(anonymous.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
		assert(anonymous.member_access.member_index == 0);
		assert(anonymous.member_access.qt.eql(inner, &comp));
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Source-derived from Parser.zig::offsetofMemberDesignator and checkArrayBounds:
// signed indices contribute signed bit offsets and bounds diagnostics point at '['.
fn void offsetof_uses_signed_offsets_checks_array_bounds_and_preserves_ast() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("offsetof-byte-bit.c",
			"(Root, items[2]) (Root, items[3]) (Root, items[-1]) (Root, items[2])\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		type_store::QualType items = comp.type_store.put(type_store::type_array(type_store::INT,
			type_store::ArrayLenKind.FIXED, 3));
		type_store::RecordField[1] fields = { type_store::record_field(comp.intern_string("items"), items) };
		fields[0].layout = { .offset_bits = 8, .size_bits = 96 };
		type_store::RecordLayout layout = { .size_bits = 104, .field_alignment_bits = 8,
			.pointer_alignment_bits = 8, .required_alignment_bits = 8 };
		type_store::QualType root = comp.type_store.put(type_store::type_record(comp.intern_string("Root"), fields[..], layout));
		OffsetTypeContext types = { .qt = root };
		parser::Parser p; p.init(&pp, &types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .int_const = &parse_offset_integer_constant };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result byte_offset = builtin.offsetof(0)!!;
		assert(byte_offset.val.to_i64(&comp)!! == 9);
		tree::Node call = byte_offset.node.get(&p.tree);
		tree::Node access = call.builtin_call.args[0].get(&p.tree);
		assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
		assert(access.array_access.qt.eql(type_store::INT, &comp));

		parser_result::Result past_end = builtin.offsetof(0)!!;
		assert(past_end.val.to_i64(&comp)!! == 13);
		parser_result::Result before_start = builtin.offsetof(0)!!;
		assert(before_start.val.to_i64(&comp)!! == -3);
		parser_result::Result bit_offset = builtin.offsetof(0, true)!!;
		assert(bit_offset.val.to_i64(&comp)!! == 72);
		assert(p.at_eof());
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "array index 3 is past the end of the array");
		test::eq(d.messages[1].text, "array index -1 is before the beginning of the array");
		check(d.messages[0].location.col, 30);
		check(d.messages[1].location.col, 47);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Source-derived from Parser.zig::offsetofMemberDesignator: a runtime index
// keeps an unavailable offset and array-access AST, while malformed
// designators recover to the next builtin call.
fn void offsetof_keeps_runtime_array_index_and_recovers_from_malformed_designator() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("offsetof-nonconstant.c",
			"(Root, [0]) (Root, items[index]) (Root, items[1])\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		type_store::QualType items = comp.type_store.put(type_store::type_array(type_store::INT,
			type_store::ArrayLenKind.FIXED, 2));
		type_store::RecordField[1] fields = { type_store::record_field(comp.intern_string("items"), items) };
		fields[0].layout = { .offset_bits = 0, .size_bits = 64 };
		type_store::RecordLayout layout = { .size_bits = 64, .field_alignment_bits = 8,
			.pointer_alignment_bits = 8, .required_alignment_bits = 8 };
		type_store::QualType root = comp.type_store.put(type_store::type_record(comp.intern_string("Root"), fields[..], layout));
		OffsetTypeContext types = { .qt = root };
		parser::Parser p; p.init(&pp, &types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_nonconstant_offset_expression };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		assert(@catch(builtin.offsetof(0)) == parser_builtin::PARSING_FAILED);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "expected identifier");
		assert(p.is_at(tokenizer::TokenId.L_PAREN));
		parser_result::Result runtime = builtin.offsetof(0)!!;
		assert(runtime.val.is_none());
		tree::Node runtime_access = runtime.node.get(&p.tree).builtin_call.args[0].get(&p.tree);
		assert(runtime_access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
		assert(runtime_access.array_access.qt.eql(type_store::INT, &comp));
		assert(d.messages.len() == 1);
		assert(p.is_at(tokenizer::TokenId.L_PAREN));
		exprs.assign = &parse_offset_assignment_expression;
		parser_result::Result recovered = builtin.offsetof(0)!!;
		assert(recovered.val.to_i64(&comp)!! == 4);
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void bit_cast_accepts_equal_sized_callback_operand_and_type() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("bit-cast.c", "(int, 1)\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		IntTypeHandler int_types;
		parser::Parser p; p.init(&pp, &int_types);
		p.bind_finalized_tokens();
		CallbackContext context = {};
		CallbackExpressions exprs = { .context = &context, .assign = &parse_choose_operand };
		parser_builtin::BuiltinParser builtin = { .parser = &p, .expressions = &exprs };
		parser_result::Result result = builtin.bit_cast(0)!!;
		assert(p.at_eof());
		assert(result.node.kind(&p.tree) == tree::NodeKind.CAST);
		assert(result.qt.eql(type_store::INT, &comp));
		assert(context.expression_calls == 1 && context.expression_eval[0]);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Source-derived direct coverage for Parser.check_va_pack_function and
// BuiltinParser.va_arg_pack / va_arg_pack_len. Each invocation starts at the
// `(` token after the source builtin identifier, as primary dispatch does.
fn void va_arg_pack_obeys_call_and_function_contexts() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		Diagnostics d; d.init_list(&ta); Compilation comp; comp.init(&ta, null, &d);
		Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("va-pack.c", "__builtin_va_arg_pack() __builtin_va_arg_pack_len()\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		parser_builtin::BuiltinParser builtin = { .parser = &p };
		// Give the function check a real declaration key and source-built
		// ALWAYS_INLINE metadata, as the declaration parser does.
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .qt = type_store::INVALID, .body = type_store::NODE_NULL,
				.definition = type_store::NODE_NULL } });
		attribute::Attribute always_inline = { .args = { .tag = attribute::AttributeTag.ALWAYS_INLINE },
			.syntax = attribute::AttributeSyntax.GNU,
			.name = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALWAYS_INLINE } };
		attribute_map::AttrRef attr_ref = p.tree.attr_map.put(always_inline);
		attribute_map::AttrRef[1] refs = { attr_ref };
		p.tree.attr_map.set_decl_attrs(decl, refs[..]);
		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = true, .named_param_count = 1 });

		// A valid variadic declaration outside a call is still rejected with
		// INVALID result type. The message text and branch order mirror the
		// implementation; the call-state diagnostic outranks type acceptance.
		p.tok_i = 1;
		parser_result::Result outside = builtin.va_arg_pack(0)!!;
		assert(outside.node.kind(&p.tree) == tree::NodeKind.BUILTIN_VA_ARG_PACK);
		assert(outside.qt.is_invalid());
		assert(d.messages.len() == 1 && d.messages[0].text == "'__va_arg_pack' used outside a call");

		p.va_arg_pack_call = { .active = true, .variadic = true, .typed = false };
		p.tok_i = 1;
		parser_result::Result accepted = builtin.va_arg_pack(0)!!;
		assert(accepted.qt.eql(type_store::VOID, &comp));
		assert(d.messages.len() == 1);

		p.va_arg_pack_call = { .active = true, .variadic = true, .typed = true };
		p.tok_i = 1;
		parser_result::Result typed = builtin.va_arg_pack(0)!!;
		assert(typed.qt.is_invalid());
		assert(d.messages.len() == 2 && d.messages[1].text == "'__va_arg_pack' passed as non-variadic argument");

		p.va_arg_pack_call = { .active = true, .variadic = false, .typed = false };
		p.tok_i = 1;
		parser_result::Result nonvariadic = builtin.va_arg_pack(0)!!;
		assert(nonvariadic.qt.is_invalid());
		assert(d.messages.len() == 3 && d.messages[2].text == "'__va_arg_pack' passed to non-variadic function");

		// va_arg_pack_len is int on all paths, with function validity carried
		// by diagnostics. Check the missing-attribute and inactive-function paths.
		p.tree.attr_map.set_decl_attrs(decl, {});
		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = true, .named_param_count = 1 });
		p.tok_i = 4;
		parser_result::Result no_inline = builtin.va_arg_pack_len(3)!!;
		assert(no_inline.qt.eql(type_store::INT, &comp));
		assert(d.messages.len() == 4 && d.messages[3].text == "'__builtin_va_arg_pack_len' used in a function that is not always inlined");

		p.set_function_context({});
		p.tok_i = 4;
		parser_result::Result outside_function = builtin.va_arg_pack_len(3)!!;
		assert(outside_function.qt.eql(type_store::INT, &comp));
		assert(d.messages.len() == 5 && d.messages[4].text == "'__builtin_va_arg_pack_len' cannot be used outside a function");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}
