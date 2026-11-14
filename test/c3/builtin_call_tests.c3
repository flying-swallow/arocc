// Focused tests for the generated-signature builtin-call path.
// Contract expectations are source-derived from Parser.zig CallExpr's
// paramCountOverride/checkArithOverflowArg/finish and Builtins/eval.zig,
// cross-checked against src/c3/builtin_eval.c3. No Zig executable was run;
// these tests do not claim executable Zig parity.
module builtin_call_tests;
import aro::builtin_call, aro::builtins, aro::compilation, aro::diagnostics, aro::parser, aro::parser_postfix, aro::parser_result;
import aro::preprocessor, aro::source, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::float_value;
import std::core::mem::allocators;

struct CallOperands
{
	type_store::QualType int_pointer;
	type_store::QualType const_int_pointer;
	type_store::QualType float_pointer;
	type_store::QualType int_vector;
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
		long n = spelling == "0" ? 0 : spelling == "1" ? 1 : spelling == "2" ? 2 : 3;
		qt = type_store::INT;
		if (eval) val = value::int_i64(n, p.comp);
	}
	else if (token.id == tokenizer::TokenId.IDENTIFIER)
	{
		String spelling = p.tree.tok_slice(tok);
		switch
		{
			case spelling == "out": qt = operands.int_pointer;
			case spelling == "const_out": qt = operands.const_int_pointer;
			case spelling == "float_out": qt = operands.float_pointer;
			case spelling == "vector_arg": qt = operands.int_vector;
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

<* Parse one call with the native optional postfix hook and check its source
   location or folded result. `diag_fragment == ""` requests a clean parse. *>
fn void check_builtin_call(String text, bool eval, String diag_fragment = "", uint diag_col = 0,
	bool check_value = false, long expected_int = 0, bool expected_infinity = false)
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
		CallOperands operands = {
			.int_pointer = comp.type_store.put(type_store::type_pointer(type_store::INT)),
			.const_int_pointer = comp.type_store.put(type_store::type_pointer(
				type_store::INT.with_qualifiers({ .is_const = true }))),
			.float_pointer = comp.type_store.put(type_store::type_pointer(type_store::FLOAT)),
			.int_vector = comp.type_store.put(type_store::type_vector(type_store::INT, 4)),
		};
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
		parser_postfix::PostfixParser postfix = {
			.parser = &p,
			.context = &operands,
			.primary = &builtin_primary,
			.expression = &builtin_call_argument,
			.has_builtin_call = true,
			.builtin_call_context = null,
			.builtin_call = &builtin_call::dispatch,
		};
		parser_result::Result? maybe_result = postfix.parse(eval);
		if (diag_fragment.len != 0)
		{
			assert(d.messages.len() == 1, "expected one builtin-call diagnostic, got %d", d.messages.len());
			assert(d.messages[0].text.contains(diag_fragment), "unexpected diagnostic: %s", d.messages[0].text);
			assert(d.messages[0].has_location);
			assert(d.messages[0].location.line_no == 1);
			assert(d.messages[0].location.col == diag_col, "diagnostic column mismatch: %d", d.messages[0].location.col);
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
		tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void builtin_overflow_call_checks_arity_and_operand_types() @test
{
	// __builtin_abs has a generated one-parameter signature. These exercise
	// generated arity and scalar-coercion diagnostics in the same dispatcher.
	check_builtin_call("__builtin_abs(1, 2)\n", true,
		"expected 1 argument(s) got 2", 18);
	check_builtin_call("__builtin_abs(vector_arg)\n", true,
		"argument type", 15);

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
