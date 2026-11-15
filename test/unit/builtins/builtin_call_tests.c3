// Focused tests for the generated-signature builtin-call path.
// Contract expectations are source-derived from Parser.zig CallExpr's
// paramCountOverride/checkArithOverflowArg/checkVaStartArg/finish and Builtins/eval.zig,
// cross-checked against src/builtin_eval.c3. No Zig executable was run;
// these tests do not claim executable Zig parity.
module builtin_call_tests;
import aro::builtin_call, aro::builtins, aro::compilation, aro::diagnostics, aro::parser, aro::parser_postfix, aro::parser_result;
import aro::preprocessor, aro::source, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::float_value, aro::target;
import std::core::mem::allocators;

struct CallOperands
{
	type_store::QualType int_pointer;
	type_store::QualType const_int_pointer;
	type_store::QualType float_pointer;
	type_store::QualType int_vector;
	type_store::QualType atomic_int_pointer;
	type_store::QualType short_pointer;
	type_store::QualType bool_pointer;
	type_store::QualType enum_pointer;
	type_store::QualType struct_pointer;
	type_store::QualType void_pointer;
	type_store::QualType complex_double;
}

<* The fixtures intentionally recognize only builtin names, integer literals,
   and a few named operand types; call argument parsing and dispatch remain
   the production PostfixParser/builtin-call hook under test. *>
fn parser_result::Result? builtin_primary(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.IDENTIFIER) return parser_postfix::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	builtins::Expanded? maybe_expanded = p.comp.builtins.get_or_create(p.comp, p.tree.tok_slice(tok));
	if (catch maybe_expanded) return parser_postfix::PARSING_FAILED~;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BUILTIN_REF,
		.builtin_ref = { .name_tok = tok, .qt = maybe_expanded.qt } });
	p.advance();
	return { .node = node, .qt = maybe_expanded.qt };
}

fn parser_result::Result? builtin_call_argument(void* context, parser::Parser* p,
	tokens::Precedence min_prec, bool eval)
{
	if (p.at_eof()) return parser_postfix::PARSING_FAILED~;
	CallOperands* operands = (CallOperands*)context;
	tokens::TokenIndex tok = p.tok_i;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	type_store::QualType qt;
	value::Value val = value::NONE;
	if (token.id == tokenizer::TokenId.PP_NUM)
	{
		String spelling = p.tree.tok_slice(tok);
		if (spelling.contains("."))
		{
			qt = type_store::DOUBLE;
		}
		else
		{
			long n = spelling == "0" ? 0 : spelling == "1" ? 1 : spelling == "2" ? 2 : 3;
			qt = type_store::INT;
			if (eval) val = value::int_i64(n, p.comp);
		}
	}
	else if (token.id == tokenizer::TokenId.IDENTIFIER)
	{
		String spelling = p.tree.tok_slice(tok);
		if (spelling == "char_arg")
		{
			type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
				.decl_ref = { .name_tok = tok, .qt = type_store::CHAR, .decl = (type_store::NodeIndex)0 } });
			p.advance();
			return { .node = node, .qt = type_store::CHAR, .val = val };
		}
		if (spelling == "last")
		{
			type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
				.decl_ref = { .name_tok = tok, .qt = type_store::INT, .decl = (type_store::NodeIndex)0 } });
			p.advance();
			return { .node = node, .qt = type_store::INT, .val = val };
		}
		switch
		{
			case spelling == "ap": qt = operands.void_pointer;
			case spelling == "out": qt = operands.int_pointer;
			case spelling == "const_out": qt = operands.const_int_pointer;
			case spelling == "float_out": qt = operands.float_pointer;
			case spelling == "vector_arg": qt = operands.int_vector;
			case spelling == "atomic_int_pointer": qt = operands.atomic_int_pointer;
			case spelling == "short_out": qt = operands.short_pointer;
			case spelling == "bool_out": qt = operands.bool_pointer;
			case spelling == "enum_out": qt = operands.enum_pointer;
			case spelling == "struct_out": qt = operands.struct_pointer;
			case spelling == "void_out": qt = operands.void_pointer;
			case spelling == "complex_arg": qt = operands.complex_double;
			case spelling == "float_arg" || spelling == "unknown_float": qt = type_store::FLOAT;
			default: qt = type_store::INT;
		}
	}
	else
	{
		return parser_postfix::PARSING_FAILED~;
	}

	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = qt } });
	p.advance();
	return { .node = node, .qt = qt, .val = val };
}

<* Operand fixtures for the identifier spellings in builtin_call_argument.
   `atomic_int_pointer` is `_Atomic(int) *`; `short_out` is `short *`; `bool_out`
   is `_Bool *`; `enum_out` is `enum E *` for a complete enum E with int tag;
   `struct_out` is `struct Simple *` for the complete struct above. *>
fn CallOperands make_call_operands(Compilation* comp)
{
	// Complete enum shaped like parser_declaration.c3's finished enum body: has_tag set, not incomplete.
	type_store::QualType enum_e = comp.type_store.put({ .tag = type_store::TypeTag.ENUM, .enum_ty = {
		.has_tag = true, .tag = type_store::INT, .incomplete = false, .name = comp.intern_string("E"),
	} });
	// Complete struct Simple { int value; }: a non-scalar pointee for the ARM exclusive address check.
	type_store::RecordField[1] simple_fields = { type_store::record_field(comp.intern_string("value"), type_store::INT) };
	type_store::RecordLayout simple_layout = { .size_bits = 32, .field_alignment_bits = 32,
		.pointer_alignment_bits = 32, .required_alignment_bits = 8 };
	type_store::QualType simple = comp.type_store.put(type_store::type_record(comp.intern_string("Simple"),
		simple_fields[..], simple_layout));
	return {
		.int_pointer = comp.type_store.put(type_store::type_pointer(type_store::INT)),
		.const_int_pointer = comp.type_store.put(type_store::type_pointer(
			type_store::INT.with_qualifiers({ .is_const = true }))),
		.float_pointer = comp.type_store.put(type_store::type_pointer(type_store::FLOAT)),
		.int_vector = comp.type_store.put(type_store::type_vector(type_store::INT, 4)),
		.atomic_int_pointer = comp.type_store.put(type_store::type_pointer(
			comp.type_store.put(type_store::type_atomic(type_store::INT)))),
		.short_pointer = comp.type_store.put(type_store::type_pointer(type_store::SHORT)),
		.bool_pointer = comp.type_store.put(type_store::type_pointer(type_store::BOOL)),
		.enum_pointer = comp.type_store.put(type_store::type_pointer(enum_e)),
		.struct_pointer = comp.type_store.put(type_store::type_pointer(simple)),
		.void_pointer = comp.type_store.put(type_store::type_pointer(type_store::VOID)),
		.complex_double = type_store::DOUBLE.to_complex(comp),
	};
}

<* Parse one call with the native optional postfix hook and check its source
   location or folded result. `diag_fragment == ""` requests a clean parse.
   `expect_result` requires a diagnosed call to remain a builtin-call result. *>
fn void check_builtin_call(String text, bool eval, String diag_fragment = "", uint diag_col = 0,
	bool check_value = false, long expected_int = 0, bool expected_infinity = false, bool expect_result = false,
	bool in_variadic_function = false, bool in_fixed_function = false)
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
		CallOperands operands = make_call_operands(&comp);
		Source src = comp.add_source_from_buffer("builtin-call.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		if (in_variadic_function || in_fixed_function)
		{
			type_store::FuncParam[2] params = {
				type_store::func_param(type_store::INT, comp.intern_string("first")),
				type_store::func_param(type_store::INT, comp.intern_string("last")),
			};
			usz param_count = in_variadic_function ? 2 : 1;
			type_store::FuncKind kind = in_variadic_function ? type_store::FuncKind.VARIADIC : type_store::FuncKind.NORMAL;
			type_store::QualType function_qt = comp.type_store.put(type_store::type_func(type_store::VOID,
				kind, params[:param_count]));
			p.function_context = { .active = true, .variadic = in_variadic_function,
				.named_param_count = (uint)param_count, .function_qt = function_qt };
		}
		builtin_call::Dispatcher dispatcher;
		parser_postfix::CallbackParts postfix_parts = { .context = &operands, .primary = &builtin_primary, .nested = &builtin_call_argument };
		parser_postfix::PostfixParser postfix = { .parser = &p, .builtin_call = &dispatcher, .parts = &postfix_parts };
		parser_result::Result? maybe_result = postfix.parse(eval);
		if (diag_fragment.len != 0)
		{
			assert(d.messages.len() == 1, "expected one builtin-call diagnostic, got %d", d.messages.len());
			assert(d.messages[0].text.contains(diag_fragment), "unexpected diagnostic: %s", d.messages[0].text);
			assert(d.messages[0].has_location);
			assert(d.messages[0].location.line_no == 1);
			assert(d.messages[0].location.col == diag_col, "diagnostic column mismatch: %d", d.messages[0].location.col);
			if (expect_result)
			{
				parser_result::Result result = maybe_result!!;
				assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR,
					"overflow diagnostics should preserve the builtin-call node");
				assert(result.qt.eql(type_store::BOOL, &comp),
					"overflow diagnostics should preserve the builtin's bool result type");
			}
		}
		else
		{
			assert(d.messages.len() == 0, "unexpected builtin-call diagnostic");
			parser_result::Result result = maybe_result!!;
			assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR,
				"recognized builtin calls should retain the builtin-call AST node");
			if (check_value)
			{
				assert(!result.val.is_none(), "expected a folded builtin-call value");
				if (expected_infinity)
				{
					assert(float_value::is_inf(result.val, &comp));
				}
				else
				{
					assert(result.val.to_i64(&comp)!! == expected_int);
				}
			}
			else
			{
				assert(result.val.is_none(), "expected an unavailable builtin-call value");
			}
		}
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_va_start_checks_current_function_and_arguments() @test
{
	check_builtin_call("__builtin_va_start(ap, last)\n", true,
		"va_start' cannot be used outside a function", 1);
	check_builtin_call("__builtin_va_start(ap, last)\n", true,
		"va_start' used in a function with fixed args", 1, false, 0, false, false, false, true);
	check_builtin_call("__builtin_va_start(ap, 1)\n", true,
		"second argument to 'va_start' is not the last named parameter", 24, false, 0, false, false, true);
	check_builtin_call("__builtin_va_start(ap, last)\n", true, "", 0,
		false, 0, false, false, true);
	check_builtin_call("va_start(ap, last)\n", true, "", 0,
		false, 0, false, false, true);
	check_builtin_call("__builtin_va_start(ap, last, 2)\n", true,
		"expected closing ')'", 24, false, 0, false, false, true);
}

fn void builtin_overflow_call_checks_arity_and_operand_types() @test
{
	// __builtin_abs has a generated one-parameter signature. These exercise
	// generated arity and scalar-coercion diagnostics in the same dispatcher.
	check_builtin_call("__builtin_abs(1, 2)\n", true,
		"expected 1 argument(s) got 2", 18);
	check_builtin_call("__builtin_abs(vector_arg)\n", true,
		"incompatible type", 15);

	// Parser.zig's custom count is 3 for add_overflow. Missing-argument errors
	// point at ')'; excess arguments point at the first argument beyond 3.
	check_builtin_call("__builtin_add_overflow(1, 2)\n", true,
		"expected 3 argument(s) got 2", 28);
	check_builtin_call("__builtin_add_overflow(1, 2, out, 3)\n", true,
		"expected 3 argument(s) got 4", 35);
	// checkArithOverflowArg reports an invalid arithmetic operand at that
	// operand's first token, then validates the result pointer's pointee.
	check_builtin_call("__builtin_add_overflow(1, float_arg, out)\n", true,
		"operand argument to overflow builtin must be an integer", 27);
	check_builtin_call("__builtin_add_overflow(1, 2, 0)\n", true,
		"result argument to overflow builtin must be a pointer to a non-const integer", 30);
	check_builtin_call("__builtin_add_overflow(1, 2, const_out)\n", true,
		"result argument to overflow builtin must be a pointer to a non-const integer", 30);
	check_builtin_call("__builtin_add_overflow(1, 2, float_out)\n", true,
		"result argument to overflow builtin must be a pointer to a non-const integer", 30);
	// The generated custom signature accepts the valid int* result slot. eval.zig
	// has no overflow-builtin evaluator case, so the call value remains NONE.
	check_builtin_call("__builtin_add_overflow(1, 2, out)\n", true);
}

fn void builtin_overflow_result_pointer_rejects_bool_and_enum_pointees() @test
{
	// Result pointees of type _Bool and complete enum E are expected to fail with
	// OVERFLOW_RESULT_REQUIRES_PTR at the result argument's first token (column 30).
	// The diagnostic must not prevent a builtin-call node with the normal bool result.
	check_builtin_call("__builtin_add_overflow(1, 2, bool_out)\n", true,
		"result argument to overflow builtin must be a pointer to a non-const integer", 30, false, 0, false, true);
	check_builtin_call("__builtin_add_overflow(1, 2, enum_out)\n", true,
		"result argument to overflow builtin must be a pointer to a non-const integer", 30, false, 0, false, true);
}

fn void builtin_overflow_call_preserves_original_argument_nodes_and_types() @test
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
		CallOperands operands = make_call_operands(&comp);
		Source src = comp.add_source_from_buffer("builtin-call.c", "__builtin_add_overflow(char_arg, char_arg, out)\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		builtin_call::Dispatcher dispatcher;
		parser_postfix::CallbackParts postfix_parts = { .context = &operands, .primary = &builtin_primary, .nested = &builtin_call_argument };
		parser_postfix::PostfixParser postfix = { .parser = &p, .builtin_call = &dispatcher, .parts = &postfix_parts };
		parser_result::Result? maybe_result = postfix.parse(true);
		assert(d.messages.len() == 0, "unexpected overflow builtin-call diagnostic");
		parser_result::Result result = maybe_result!!;
		assert(result.qt.eql(type_store::BOOL, &comp), "overflow builtin result must stay bool");
		tree::Node call = result.node.get(&p.tree);
		assert(call.kind == tree::NodeKind.BUILTIN_CALL_EXPR);
		assert(call.builtin_call.args.len == 3);
		for (usz i = 0; i < 2; i++)
		{
			type_store::NodeIndex arg = call.builtin_call.args[i];
			assert(arg.qt(&p.tree).eql(type_store::CHAR, &comp),
				"overflow operand %d should retain char instead of a promoted type", i);
			tree::Node arg_node = arg.get(&p.tree);
			assert(arg_node.kind == tree::NodeKind.CAST && arg_node.cast.implicit &&
				arg_node.cast.kind == tree::CastKind.LVAL_TO_RVAL,
				"overflow operand %d should have the expected implicit lvalue conversion", i);
			arg = arg_node.cast.operand;
			assert(arg.get(&p.tree).kind == tree::NodeKind.DECL_REF_EXPR,
				"overflow operand %d should preserve its original decl-ref AST", i);
			assert(arg.qt(&p.tree).eql(type_store::CHAR, &comp));
		}
		assert(call.builtin_call.args[2].qt(&p.tree).eql(operands.int_pointer, &comp),
			"overflow result argument should retain its original pointer type");
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_call_evaluation_and_unavailable_values() @test
{
	// These expected values follow the explicit cases in Builtins/eval.zig and
	// builtin_eval.c3: constant_p of a literal is true, while inf is positive
	// infinity. No-value inputs and eval=false remain unavailable.
	check_builtin_call("__builtin_constant_p(1)\n", true, "", 0, true, 1);
	check_builtin_call("__builtin_constant_p(unknown)\n", true, "", 0, true, 0);
	check_builtin_call("__builtin_inf()\n", true, "", 0, true, 0, true);
	check_builtin_call("__builtin_isinf(unknown_float)\n", true);
	check_builtin_call("__builtin_constant_p(1)\n", false);
}

<* Parse one call with eval set and check every builtin-call diagnostic: the count,
   the fragment, and the 1-based column on line 1. `first_col` checks message 0 and
   `second_col` checks message 1 when `expected_count` is 2. The parse must still
   yield a builtin-call node. *>
fn void check_builtin_call_diagnostics(String text, String fragment, uint expected_count, uint first_col,
	uint second_col)
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
		CallOperands operands = make_call_operands(&comp);
		Source src = comp.add_source_from_buffer("builtin-call.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		builtin_call::Dispatcher dispatcher;
		parser_postfix::CallbackParts postfix_parts = { .context = &operands, .primary = &builtin_primary, .nested = &builtin_call_argument };
		parser_postfix::PostfixParser postfix = { .parser = &p, .builtin_call = &dispatcher, .parts = &postfix_parts };
		parser_result::Result? maybe_result = postfix.parse(true);
		assert(d.messages.len() == (sz)expected_count, "expected %d builtin-call diagnostic(s), got %d",
			expected_count, d.messages.len());
		for (sz i = 0; i < d.messages.len(); i++)
		{
			uint expected_col = i == 0 ? first_col : second_col;
			assert(d.messages[i].text.contains(fragment), "unexpected diagnostic %d: %s", i, d.messages[i].text);
			assert(d.messages[i].has_location);
			assert(d.messages[i].location.line_no == 1);
			assert(d.messages[i].location.col == expected_col, "diagnostic %d column mismatch: %d", i,
				d.messages[i].location.col);
		}
		parser_result::Result result = maybe_result!!;
		assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR,
			"builtin-call diagnostics should preserve the builtin-call AST node");
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

<* Parse one call with eval set and check the call's result type, spelled by
   QualType.tprint. `triple == ""` keeps the host default target; otherwise the
   target and its language options are set before named types are created. *>
fn void check_builtin_call_type(String text, String expected, String triple = "")
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		if (triple.len != 0)
		{
			comp.target = target::from_triple(triple)!!;
			comp.langopts.set_target_options(&comp.target);
		}
		type_store::init_named_types(&comp);
		CallOperands operands = make_call_operands(&comp);
		Source src = comp.add_source_from_buffer("builtin-call.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		builtin_call::Dispatcher dispatcher;
		parser_postfix::CallbackParts postfix_parts = { .context = &operands, .primary = &builtin_primary, .nested = &builtin_call_argument };
		parser_postfix::PostfixParser postfix = { .parser = &p, .builtin_call = &dispatcher, .parts = &postfix_parts };
		parser_result::Result? maybe_result = postfix.parse(true);
		assert(d.messages.len() == 0, "unexpected builtin-call diagnostic");
		parser_result::Result result = maybe_result!!;
		assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR,
			"recognized builtin calls should retain the builtin-call AST node");
		String got = result.qt.tprint(&comp);
		assert(got == expected, "expected builtin-call result type '%s', got '%s'", expected, got);
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_elementwise_clzg_result_is_int() @test
{
	check_builtin_call_type("__builtin_elementwise_clzg(1)\n", "int");
	check_builtin_call_type("__builtin_elementwise_clzg(1, 2)\n", "int");
}

fn void builtin_elementwise_ctzg_result_is_int() @test
{
	check_builtin_call_type("__builtin_elementwise_ctzg(1)\n", "int");
}

// __builtin_complex(real, imag): paramCountOverride is 2 (Parser.zig:6691).
// checkComplexArg (Parser.zig:10111) requires both operands to share one real
// float type; returnType is toComplex of the last argument (Parser.zig:6854-6857).
fn void builtin_complex_result_is_complex_of_operand_type() @test
{
	check_builtin_call_type("__builtin_complex(1.0, 2.0)\n", "_Complex double");
}

// __c11_atomic_load(object, order): paramCountOverride is 2 (Parser.zig:6692).
// Arg 0 must point to an _Atomic type; returnType yields the unqualified
// atomic child (Parser.zig:6826-6829).
fn void c11_atomic_load_result_is_unqualified_atomic_child() @test
{
	check_builtin_call_type("__c11_atomic_load(atomic_int_pointer, 0)\n", "int");
}

// __atomic_fetch_add(object, operand, order): paramCountOverride is 3
// (Parser.zig:6718). returnType takes the pointee of arg 0 with _Atomic removed
// and qualifiers dropped (Parser.zig:6792 group label, body at 6819-6823).
fn void atomic_fetch_add_result_is_pointee_type() @test
{
	check_builtin_call_type("__atomic_fetch_add(short_out, 1, 0)\n", "short");
}

// __c11_atomic_compare_exchange_strong(object, expected, desired, succ, fail):
// paramCountOverride is 5 (Parser.zig:6742). No checkVarArg case exists for it,
// and returnType is .bool (Parser.zig:6861-6865).
fn void c11_atomic_compare_exchange_strong_result_is_bool() @test
{
	check_builtin_call_type("__c11_atomic_compare_exchange_strong(atomic_int_pointer, out, 1, 0, 0)\n",
		"_Bool");
}

// aarch64 __builtin_arm_ldrex(pointer): paramCountOverride is 1 (Parser.zig:6757).
// returnType takes childType of arg 0 (Parser.zig:6937-6942). checkARMExclusive
// coerces arg 0 to a `const volatile` child (Parser.zig:10170ff), so the result
// type includes those qualifiers.
fn void arm_ldrex_result_is_pointee_type() @test
{
	check_builtin_call_type("__builtin_arm_ldrex(out)\n", "const volatile int", "aarch64-linux-gnu");
}

// aarch64 __builtin_arm_strex(value, pointer): paramCountOverride is 2 with the
// value first (Parser.zig:6761). checkARMExclusive only checks arg 1, and
// returnType is .int (Parser.zig:6944-6946).
fn void arm_strex_result_is_int() @test
{
	check_builtin_call_type("__builtin_arm_strex(1, out)\n", "int", "aarch64-linux-gnu");
}

<* Parse one ARM exclusive builtin call under armv7a-linux-gnueabi with eval set.
   `diag_fragments` and `diag_cols` list the expected diagnostics in emission order:
   each message must contain its fragment and report that 1-based column on line 1.
   An empty list requests a clean parse that keeps the builtin-call AST node. Setup
   mirrors check_builtin_call_type's target and operand fixtures. *>
fn void check_arm_exclusive_call(String text, String[] diag_fragments, uint[] diag_cols)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::from_triple("armv7a-linux-gnueabi")!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		CallOperands operands = make_call_operands(&comp);
		Source src = comp.add_source_from_buffer("builtin-call.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		builtin_call::Dispatcher dispatcher;
		parser_postfix::CallbackParts postfix_parts = { .context = &operands, .primary = &builtin_primary, .nested = &builtin_call_argument };
		parser_postfix::PostfixParser postfix = { .parser = &p, .builtin_call = &dispatcher, .parts = &postfix_parts };
		parser_result::Result? maybe_result = postfix.parse(true);
		assert(d.messages.len() == diag_fragments.len, "expected %d ARM exclusive diagnostic(s), got %d",
			diag_fragments.len, d.messages.len());
		for (sz i = 0; i < (sz)diag_fragments.len; i++)
		{
			assert(d.messages[i].text.contains(diag_fragments[(usz)i]), "unexpected diagnostic %d: %s", i, d.messages[i].text);
			assert(d.messages[i].has_location);
			assert(d.messages[i].location.line_no == 1);
			assert(d.messages[i].location.col == diag_cols[(usz)i], "diagnostic %d column mismatch: %d", i,
				d.messages[i].location.col);
		}
		if (diag_fragments.len == 0)
		{
			parser_result::Result result = maybe_result!!;
			assert(result.node.get(&p.tree).kind == tree::NodeKind.BUILTIN_CALL_EXPR,
				"recognized ARM exclusive calls should retain the builtin-call AST node");
		}
		else
		{
			// The parse outcome of a diagnosed call is not pinned here; only its diagnostics are.
			if (catch maybe_result) {}
		}
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// aarch64 pins above only cover result types. The armv7a cases below pin the ARM
// exclusive address checks that Parser.zig's checkARMExclusive (Parser.zig:10125-10262,
// reached from the custom-typecheck dispatch at 6625 and 6635) performs per argument.
// Columns are those of the checked argument token in each call text.

// Non-scalar pointee: `struct Simple *` is neither int, float, nor pointer, so the
// address argument is rejected at `struct_out` (column 21). Zig fixture:
// test/cases/builtins-arm-exclusive.c:22:30.
fn void arm_ldrex_rejects_struct_pointee() @test
{
	check_arm_exclusive_call("__builtin_arm_ldrex(struct_out)\n",
		{ "address argument to __builtin_arm_ldrex must be a pointer to integer, floating-point, or pointer" },
		{ 21 });
}

// ldrexd on armv7a keeps only the 8-byte mask bit (ARM_LDREX_ALL & d_int), so the
// 4-byte `int *` pointee at `out` (column 22) is an unsupported size. The size
// list printed in the message is "8".
fn void arm_ldrexd_rejects_unsupported_pointee_size() @test
{
	check_arm_exclusive_call("__builtin_arm_ldrexd(out)\n",
		{ "address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type" },
		{ 22 });
}

// strex(value, pointer) checks argument 1 as it is parsed, so the pointer-type
// diagnostic on `2` (column 24) is emitted before the arity error. The arity error
// points at the first excess argument `3` (column 27).
fn void arm_strex_pointer_diagnostic_precedes_arity_error() @test
{
	check_arm_exclusive_call("__builtin_arm_strex(1, 2, 3)\n",
		{
			"address argument to __builtin_arm_strex must be a pointer to integer, floating-point, or pointer",
			"expected 2 argument(s) got 3" },
		{ 24, 27 });
}

// Valid int pointee: `out` is `int *`, so no diagnostics and the builtin-call node is kept.
// The aarch64 type test above pins the `const volatile` result after coercion.
fn void arm_ldrex_accepts_int_pointee() @test
{
	String[] no_fragments = {};
	uint[] no_cols = {};
	check_arm_exclusive_call("__builtin_arm_ldrex(out)\n", no_fragments, no_cols);
}

// __builtin_complex(real, imag): each operand at index 0 or 1 must be a real float
// type. Both `void *` operands are rejected, each at its own first token (columns
// 19 and 29). Diagnostics do not fail the parse, so the builtin-call node remains.
fn void builtin_complex_rejects_non_float_operands() @test
{
	check_builtin_call_diagnostics("__builtin_complex(void_out, void_out)\n",
		"is not a real floating point type", 2, 19, 29);
}

// Complex operands are not real floats, so both are rejected (columns 19 and 32).
fn void builtin_complex_rejects_complex_operands() @test
{
	check_builtin_call_diagnostics("__builtin_complex(complex_arg, complex_arg)\n",
		"is not a real floating point type", 2, 19, 32);
}

// float_arg passes the real-float check and 2.0 is double, so the only diagnostic
// is the mismatch on operand 1 at column 30.
fn void builtin_complex_rejects_mismatched_float_operands() @test
{
	check_builtin_call_diagnostics("__builtin_complex(float_arg, 2.0)\n",
		"arguments are of different types", 1, 30, 0);
}

// __c11_atomic_load arg 0 must be a pointer. The integer literal at column 19 is
// rejected as the address argument.
fn void c11_atomic_load_rejects_non_pointer_address() @test
{
	check_builtin_call_diagnostics("__c11_atomic_load(1, 0)\n",
		"address argument to atomic builtin must be a pointer (", 1, 19, 0);
}

// __c11_atomic_load arg 0 is `int *`, a pointer whose pointee is not _Atomic.
fn void c11_atomic_load_rejects_non_atomic_pointee() @test
{
	check_builtin_call_diagnostics("__c11_atomic_load(out, 0)\n",
		"must be a pointer to _Atomic type", 1, 19, 0);
}
