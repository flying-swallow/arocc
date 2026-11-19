// Parser-owned postfix tests: calls, subscripts, member access, inc/dec and
// closers, driven through finalized tokens and seeded symbols.
//
// Expectations assert the approved final semantics of src/parser_postfix.c3.
// Labels on each expectation:
//   "Source-derived (Parser.zig <fn>)": read from the named reference function.
//   "C11 <clause>": standard behavior where the reference is silent.
//   "C3-only (<reason>)": behavior the C3 port defines beyond the reference.
//   "Clang bounds-safety (<rule>)": -fexperimental-bounds-safety rules, enabled per fixture.
// Message text is `Message.text` as rendered; types print quoted, e.g. 'int'.
// Note: QualType.eql ignores top-level qualifiers, so qualifier expectations also assert is_const.
module parser_postfix_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_result;
import aro::preprocessor, aro::source, aro::string_interner, aro::symbol_stack, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::lang_opts;
import std::core::mem::allocators;

struct PostfixFixture
{
	TrackingAllocator allocator;
	diagnostics::Diagnostics diagnostics;
	compilation::Compilation comp;
	preprocessor::Preprocessor pp;
	parser::Parser parser;
	bool active;
}

fn void PostfixFixture.init(&self, String input, String path = "postfix.c", bool bounds_safety = false)
{
	self.allocator.init(mem);
	self.diagnostics.init_list(&self.allocator);
	self.comp.init(&self.allocator, null, &self.diagnostics);
	if (bounds_safety) self.comp.langopts.bounds_safety = lang_opts::BoundsSafety.CLANG;
	self.pp.init(&self.comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
	source::Source src = self.comp.add_source_from_buffer(path, input)!!;
	TokenWithExpansionLocs eof = self.pp.preprocess(src)!!;
	self.pp.add_token(eof)!!;
	self.parser.init(&self.pp);
	self.parser.bind_finalized_tokens();
	self.active = true;
}

fn void PostfixFixture.free(&self)
{
	if (!self.active) return;
	self.parser.free();
	self.pp.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.allocator.allocation_count() == 0);
	self.allocator.free();
	self.active = false;
}

fn type_store::NodeIndex PostfixFixture.seed(&self, String name, type_store::QualType qt,
	value::Value val = value::NONE)
{
	type_store::NodeIndex decl = self.parser.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = qt } });
	self.parser.define_symbol({ .name = self.comp.intern_string(name), .kind = symbol_stack::SymbolKind.DEF,
		.qt = qt, .node = decl, .val = val });
	return decl;
}

<* True when any rendered diagnostic, including notes, has exactly `text`. *>
fn bool PostfixFixture.has_message(&self, String text)
{
	foreach (&m : self.diagnostics.messages)
	{
		if (m.text == text) return true;
	}
	return false;
}

fn void expect_postfix_failure(PostfixFixture* f)
{
	parser_result::Result? parsed = f.parser.expr();
	if (catch parse_error = parsed)
	{
		assert(parse_error == parser::PARSING_FAILED);
	}
	else
	{
		unreachable("invalid postfix expression unexpectedly parsed");
	}
}

fn type_store::RecordLayout test_record_layout() => {
	.size_bits = 96,
	.field_alignment_bits = 32,
	.pointer_alignment_bits = 32,
	.required_alignment_bits = 8,
};

fn type_store::QualType make_record(PostfixFixture* f, String name, type_store::RecordField[] fields)
{
	return f.comp.type_store.put(type_store::type_record(f.comp.intern_string(name), fields, test_record_layout()));
}

fn type_store::QualType const_of(type_store::QualType qt)
{
	qt.is_const = true;
	return qt;
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

fn void typed_call_coerces_arguments_in_written_order() @test
{
	PostfixFixture f;
	f.init("callee(1, 2)\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::LONG), type_store::func_param(type_store::DOUBLE) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::SHORT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	// Source-derived (Parser.zig callExpr): result is the declared return type.
	assert(parsed.qt.eql(type_store::SHORT, &f.comp));
	tree::Node call = parsed.node.get(&f.parser.tree);
	assert(call.kind == tree::NodeKind.CALL_EXPR);
	assert(call.call.qt.eql(type_store::SHORT, &f.comp));
	assert(call.call.args.len == 2);
	// Source-derived (Parser.zig callExpr -> Result.coerce): int -> long is an
	// integer cast; int -> double is an int-to-float cast. Written order is kept.
	tree::Node first = call.call.args[0].get(&f.parser.tree);
	assert(first.kind == tree::NodeKind.CAST && first.cast.kind == tree::CastKind.INT_CAST);
	assert(first.cast.qt.eql(type_store::LONG, &f.comp));
	assert(f.parser.tree.tok_slice(first.cast.operand.tok(&f.parser.tree)) == "1");
	tree::Node second = call.call.args[1].get(&f.parser.tree);
	assert(second.kind == tree::NodeKind.CAST && second.cast.kind == tree::CastKind.INT_TO_FLOAT);
	assert(second.cast.qt.eql(type_store::DOUBLE, &f.comp));
	assert(f.parser.tree.tok_slice(second.cast.operand.tok(&f.parser.tree)) == "2");
	assert(f.diagnostics.messages.len() == 0);
}

fn void function_pointer_call_keeps_return_type_and_coerces_argument() @test
{
	PostfixFixture f;
	f.init("callee(7)\n");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::LONG) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::LONG,
		type_store::FuncKind.NORMAL, params[..]));
	type_store::QualType fn_pointer = f.comp.type_store.put(type_store::type_pointer(func_type));
	f.seed("callee", fn_pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	tree::Node call = parsed.node.get(&f.parser.tree);
	// Source-derived (Parser.zig callExpr): a pointer to function is callable and
	// its pointee supplies the parameter list and return type.
	assert(call.kind == tree::NodeKind.CALL_EXPR && call.call.qt.eql(type_store::LONG, &f.comp));
	assert(call.call.args.len == 1);
	tree::Node arg = call.call.args[0].get(&f.parser.tree);
	assert(arg.kind == tree::NodeKind.CAST && arg.cast.kind == tree::CastKind.INT_CAST);
	assert(arg.cast.qt.eql(type_store::LONG, &f.comp));
	assert(f.parser.at_eof());
	assert(f.diagnostics.messages.len() == 0);
}

fn void noncallable_operand_reports_at_open_paren() @test
{
	PostfixFixture f;
	f.init("object(1)\n");
	defer f.free();
	f.seed("object", type_store::INT);
	// Source-derived (Parser.zig callExpr): reported before arguments are parsed.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "cannot call non function type 'int'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 7);
}

fn void wrong_arity_too_few_reports_expected_count_and_invalid_result() @test
{
	PostfixFixture f;
	f.init("callee(1)\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::INT), type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig callExpr, .normal): too few arguments are reported
	// at the closing parenthesis and the call result becomes invalid.
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expected 2 argument(s) got 1");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 9);
}

fn void wrong_arity_too_many_reports_at_first_extra_argument() @test
{
	PostfixFixture f;
	f.init("callee(1, 2, 3)\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::INT), type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig callExpr, .normal): too many arguments are reported
	// at the first extra argument.
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expected 2 argument(s) got 3");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 14);
}

fn void record_argument_for_scalar_parameter_reports_incompatible_type() @test
{
	PostfixFixture f;
	f.init("callee(object)\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("value"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	type_store::FuncParam[1] params = { type_store::func_param(type_store::LONG) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig Result.coerce, .arg): reported at the argument
	// token; the call itself is still built.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.CALL_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "passing 'struct PostfixRecord' to parameter of incompatible type 'long'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void variadic_extra_arguments_get_default_promotions() @test
{
	PostfixFixture f;
	f.init("vararg(1, ch, fl)\n");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.VARIADIC, params[..]));
	f.seed("vararg", func_type);
	f.seed("ch", type_store::CHAR);
	f.seed("fl", type_store::FLOAT);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node call = parsed.node.get(&f.parser.tree);
	assert(call.kind == tree::NodeKind.CALL_EXPR && call.call.args.len == 3);
	// Source-derived shape with C11 6.5.2.2p6 default argument promotions:
	// char -> int and float -> double for arguments past the typed parameters.
	tree::Node promoted_char = call.call.args[1].get(&f.parser.tree);
	assert(promoted_char.kind == tree::NodeKind.CAST && promoted_char.cast.qt.eql(type_store::INT, &f.comp));
	tree::Node promoted_float = call.call.args[2].get(&f.parser.tree);
	assert(promoted_float.kind == tree::NodeKind.CAST && promoted_float.cast.qt.eql(type_store::DOUBLE, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void variadic_under_arity_warns_at_least_expected_count() @test
{
	PostfixFixture f;
	f.init("vfn()\n");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.VARIADIC, params[..]));
	f.seed("vfn", func_type);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig callExpr, .variadic): warning at the closing parenthesis.
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expected at least 1 argument(s) got 0");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.WARNING);
	assert(f.diagnostics.messages[0].location.col == 5);
}

fn void old_style_extra_arguments_warn_and_promote() @test
{
	PostfixFixture f;
	f.init("oldfn(1, ch)\n");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.OLD_STYLE, params[..]));
	f.seed("oldfn", func_type);
	f.seed("ch", type_store::CHAR);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node call = parsed.node.get(&f.parser.tree);
	assert(call.kind == tree::NodeKind.CALL_EXPR && call.call.args.len == 2);
	// Source-derived (Parser.zig callExpr, .old_style): count mismatch is a warning
	// at the first extra argument. C11 6.5.2.2p6: the extra char is promoted to int.
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expected 1 argument(s) got 2");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.WARNING);
	assert(f.diagnostics.messages[0].location.col == 10);
	tree::Node promoted = call.call.args[1].get(&f.parser.tree);
	assert(promoted.kind == tree::NodeKind.CAST && promoted.cast.qt.eql(type_store::INT, &f.comp));
}

fn void old_style_call_without_prototype_warns_and_promotes() @test
{
	PostfixFixture f;
	f.init("oldfn0(ch)\n");
	defer f.free();
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.OLD_STYLE, {}));
	f.seed("oldfn0", func_type);
	f.seed("ch", type_store::CHAR);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node call = parsed.node.get(&f.parser.tree);
	// Source-derived (Parser.zig callExpr, .old_style with no parameters): arg_index and
	// typed_params_len are both 0, so first_after is reassigned to the first argument token ('ch').
	assert(call.kind == tree::NodeKind.CALL_EXPR && call.call.args.len == 1);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "passing arguments to a function without a prototype is deprecated in all versions of C and is not supported in C23");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.WARNING);
	assert(f.diagnostics.messages[0].location.col == 8);
	tree::Node promoted = call.call.args[0].get(&f.parser.tree);
	assert(promoted.kind == tree::NodeKind.CAST && promoted.cast.qt.eql(type_store::INT, &f.comp));
}

fn void malformed_call_closer_at_eof_reports_expected_paren() @test
{
	PostfixFixture f;
	f.init("callee(1, 2\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::INT), type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig callExpr -> expectClosing): EOF error plus the opener note.
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].text == "expected ')' before end of file");
	assert(f.has_message("to match this '('"));
}

fn void malformed_call_closer_from_macro_reports_at_macro_use() @test
{
	PostfixFixture f;
	f.init("#define CLOSE_BRACKET ]\ncallee(1 CLOSE_BRACKET\n", "postfix_macro.c");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig expectClosing): a macro-expanded wrong closer is
	// reported at the macro use site (line 2), followed by the expansion note.
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].text == "expected ')', found ']'");
	assert(f.diagnostics.messages[0].has_location);
	assert(f.diagnostics.messages[0].location.path == "postfix_macro.c");
	assert(f.diagnostics.messages[0].location.line_no == 2);
	assert(f.has_message("to match this '('"));
}

fn void unevaluated_postfix_call_still_checks_nested_expression_shape() @test
{
	PostfixFixture f;
	f.init("callee(1 / 0)\n");
	defer f.free();
	type_store::FuncParam[1] params = { type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr(false)!!;
	tree::Node call = parsed.node.get(&f.parser.tree);
	assert(call.kind == tree::NodeKind.CALL_EXPR);
	assert(call.call.args.len == 1);
	assert(call.call.args[0].get(&f.parser.tree).kind == tree::NodeKind.DIV_EXPR);
	assert(parsed.val.is_none());
	assert(f.diagnostics.messages.len() == 0,
		"eval=false must suppress the nested integer division-by-zero diagnostic");
}

fn void unevaluated_call_still_checks_arity() @test
{
	PostfixFixture f;
	f.init("callee(1)\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::INT), type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	parser_result::Result parsed = f.parser.expr(false)!!;
	// Source-derived (Parser.zig callExpr): the argument-count check has no eval gate.
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expected 2 argument(s) got 1");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
}

fn void fatal_argument_fault_releases_scratch_argument_list() @test
{
	PostfixFixture f;
	f.init("callee(1, object)\n");
	defer f.free();
	type_store::FuncParam[2] params = { type_store::func_param(type_store::INT), type_store::func_param(type_store::INT) };
	type_store::QualType func_type = f.comp.type_store.put(type_store::type_func(type_store::INT,
		type_store::FuncKind.NORMAL, params[..]));
	f.seed("callee", func_type);
	type_store::QualType incomplete = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("Incomplete")));
	f.seed("object", incomplete);
	// Source-derived (Parser.zig callExpr): an argument with incomplete size is a
	// fatal fault; no diagnostic is emitted here. The fixture's free() asserts the
	// TrackingAllocator is empty, so the partial argument list must be released.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 0);
}

// ---------------------------------------------------------------------------
// Subscripts
// ---------------------------------------------------------------------------

fn void array_and_pointer_indexes_build_access_nodes() @test
{
	PostfixFixture f;
	f.init("array[1 + 1]\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	parser_result::Result parsed = f.parser.expr()!!;
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.eql(type_store::INT, &f.comp));
	assert(access.array_access.index.get(&f.parser.tree).kind == tree::NodeKind.ADD_EXPR);
	// Source-derived (Parser.zig suffixExpr .l_bracket): array decays to pointer.
	assert(access.array_access.base.get(&f.parser.tree).kind == tree::NodeKind.CAST);
	assert(access.array_access.base.get(&f.parser.tree).cast.kind == tree::CastKind.ARRAY_TO_POINTER);
	assert(f.parser.at_eof());
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("pointer[3]\n");
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::LONG));
	f.seed("pointer", pointer);
	parsed = f.parser.expr()!!;
	access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.eql(type_store::LONG, &f.comp));
	// Source-derived: pointer bases have no static bounds, so no diagnostic.
	assert(access.array_access.base.get(&f.parser.tree).kind == tree::NodeKind.CAST);
	assert(access.array_access.base.get(&f.parser.tree).cast.kind == tree::CastKind.LVAL_TO_RVAL);
	assert(f.diagnostics.messages.len() == 0);
}

fn void reversed_subscript_normalizes_to_pointer_base() @test
{
	PostfixFixture f;
	f.init("0[pointer]\n");
	defer f.free();
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node access = parsed.node.get(&f.parser.tree);
	// Source-derived (Parser.zig suffixExpr .l_bracket): an integer on the left and a
	// pointer on the right swap roles, so the pointer becomes the base.
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.eql(type_store::INT, &f.comp));
	assert(access.array_access.base.get(&f.parser.tree).kind == tree::NodeKind.CAST);
	assert(access.array_access.base.get(&f.parser.tree).cast.kind == tree::CastKind.LVAL_TO_RVAL);
	assert(access.array_access.index.get(&f.parser.tree).kind == tree::NodeKind.INT_LITERAL);
	assert(f.diagnostics.messages.len() == 0);
}

fn void vector_subscript_yields_element_type() @test
{
	PostfixFixture f;
	f.init("vec[1]\n");
	defer f.free();
	type_store::QualType vector_type = f.comp.type_store.put(type_store::type_vector(type_store::INT, 4));
	f.seed("vec", vector_type);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node access = parsed.node.get(&f.parser.tree);
	// Source-derived (Parser.zig suffixExpr .l_bracket): vector element type, integer index.
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.eql(type_store::INT, &f.comp));
	assert(access.array_access.index.get(&f.parser.tree).kind == tree::NodeKind.INT_LITERAL);
	assert(f.diagnostics.messages.len() == 0);
}

fn void vector_subscript_rejects_non_integer_index() @test
{
	PostfixFixture f;
	f.init("vec[1.5]\n");
	defer f.free();
	type_store::QualType vector_type = f.comp.type_store.put(type_store::type_vector(type_store::INT, 4));
	f.seed("vec", vector_type);
	// Source-derived (Parser.zig suffixExpr .l_bracket): invalid index is a
	// non-fatal diagnostic at '['; the access node is still built.
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "array subscript is not an integer");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 4);
}

fn void pointer_subscript_rejects_non_integer_index() @test
{
	PostfixFixture f;
	f.init("pointer[1.5]\n");
	defer f.free();
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "array subscript is not an integer");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void integer_subscript_reports_invalid_subscript() @test
{
	PostfixFixture f;
	f.init("integer[0]\n");
	defer f.free();
	f.seed("integer", type_store::INT);
	// Source-derived (Parser.zig suffixExpr .l_bracket): neither operand is
	// pointer, array or vector; diagnostic at '[', parsing continues.
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "subscripted value is not an array, pointer or vector");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void array_index_past_end_warns_at_bracket() @test
{
	PostfixFixture f;
	f.init("array[4]\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	// Source-derived (Parser.zig checkArrayBounds): warning at '[' for a constant index >= length.
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.WARNING);
	assert(f.diagnostics.messages[0].text.contains("is past the end of the array"));
	assert(f.diagnostics.messages[0].location.col == 6);
}

fn void array_last_element_index_is_silent() @test
{
	PostfixFixture f;
	f.init("array[3]\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 0);
}

fn void array_negative_constant_index_warns_before_beginning() @test
{
	PostfixFixture f;
	f.init("array[-1]\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	// Source-derived (Parser.zig checkArrayBounds): depends on constant folding of unary minus.
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.WARNING);
	assert(f.diagnostics.messages[0].text.contains("is before the beginning of the array"));
}

fn void malformed_subscript_closer_at_eof_reports_expected_bracket() @test
{
	PostfixFixture f;
	f.init("array[0\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 2));
	f.seed("array", array_type);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig suffixExpr -> expectClosing): EOF error plus opener note.
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].text == "expected ']' before end of file");
	assert(f.has_message("to match this '['"));
}

fn void malformed_closer_reports_expected_bracket_and_macro_use_location() @test
{
	PostfixFixture f;
	f.init("#define CLOSE )\narray[0 CLOSE\n", "postfix_macro.c");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 2));
	f.seed("array", array_type);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig expectClosing): a macro-expanded wrong closer is
	// reported at the macro use site (line 2), followed by the expansion note.
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].text == "expected ']', found ')'");
	assert(f.diagnostics.messages[0].has_location);
	assert(f.diagnostics.messages[0].location.path == "postfix_macro.c");
	assert(f.diagnostics.messages[0].location.line_no == 2);
	assert(f.has_message("to match this '['"));
}

// Incomplete pointee on a subscript: array_subscript reports PTR_ARITHMETIC_INCOMPLETE at '[' and is not fatal.
// The ARRAY_ACCESS_EXPR is still built, with an invalid type for the element and the result.
fn void incomplete_record_pointer_subscript_reports_arithmetic_and_yields_invalid() @test
{
	PostfixFixture f;
	f.init("pointer[0]\n");
	defer f.free();
	type_store::QualType incomplete = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("Incomplete")));
	f.seed("pointer", f.comp.type_store.put(type_store::type_pointer(incomplete)));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	// Source-derived (Parser.zig suffixExpr .l_bracket): an element type with incomplete size is
	// rejected at '['; parsing continues, so the access node exists with an invalid type.
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.is_invalid());
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "arithmetic on a pointer to an incomplete type 'struct Incomplete'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

// Reversed operands, `0[pointer]`: the integer/pointer swap makes the pointer the base before the
// incomplete-size check, so the same diagnostic is reported at '[' (col 2) and the result is invalid.
fn void reversed_incomplete_record_pointer_subscript_reports_at_bracket() @test
{
	PostfixFixture f;
	f.init("0[pointer]\n");
	defer f.free();
	type_store::QualType incomplete = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("Incomplete")));
	f.seed("pointer", f.comp.type_store.put(type_store::type_pointer(incomplete)));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	// Source-derived (Parser.zig suffixExpr .l_bracket): same non-fatal rule as the forward form.
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(access.array_access.qt.is_invalid());
	assert(parsed.qt.is_invalid());
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "arithmetic on a pointer to an incomplete type 'struct Incomplete'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 2);
}

// Small integer index: C11 6.5.2.1p2 requires an integer index and C11 6.3.1.1p2 integer-promotes it.
// Expectation is the promotion cast node in the access AST, not the operand's own type.
fn void char_and_short_indexes_get_integer_promotion_cast() @test
{
	PostfixFixture f;
	f.init("array[ch]\n");
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	f.seed("ch", type_store::CHAR);
	// C11 6.3.1.1p2: char index promoted to int; the cast wraps the lvalue-to-rvalue read.
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	tree::Node char_index = access.array_access.index.get(&f.parser.tree);
	assert(char_index.kind == tree::NodeKind.CAST && char_index.cast.kind == tree::CastKind.INT_CAST);
	assert(char_index.cast.qt.eql(type_store::INT, &f.comp));
	assert(char_index.cast.operand.get(&f.parser.tree).kind == tree::NodeKind.CAST);
	assert(char_index.cast.operand.get(&f.parser.tree).cast.kind == tree::CastKind.LVAL_TO_RVAL);
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("pointer[sh]\n");
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.seed("pointer", pointer);
	f.seed("sh", type_store::SHORT);
	// C11 6.3.1.1p2: short index promoted to int on the pointer-base path as well.
	parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	tree::Node short_index = access.array_access.index.get(&f.parser.tree);
	assert(short_index.kind == tree::NodeKind.CAST && short_index.cast.kind == tree::CastKind.INT_CAST);
	assert(short_index.cast.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

// Make a clang `__single` pointer to `child`: subscripts are in bounds only at a constant 0.
fn type_store::QualType make_single_pointer(PostfixFixture* f, type_store::QualType child)
{
	type_store::Type ty = type_store::type_pointer(child);
	ty.pointer.bounds = type_store::PointerBounds.SINGLE;
	return f.comp.type_store.put(ty);
}

// Clang bounds-safety (parser_postfix.c3 check_single_subscript): constant 0 is in bounds on __single.
fn void single_pointer_zero_index_is_in_bounds() @test
{
	PostfixFixture f;
	f.init("pointer[0]\n", "postfix.c", true);
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("0[pointer]\n", "postfix.c", true);
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	// Reversed operands: the pointer is still the base, so the constant 0 is in bounds.
	parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 0);
}

// Clang bounds-safety: a non-zero constant index on __single is an error at '[', not fatal.
fn void single_pointer_nonzero_constant_index_reports_at_bracket() @test
{
	PostfixFixture f;
	f.init("pointer[1]\n", "postfix.c", true);
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "array subscript on single pointer must use a constant index of 0 to be in bounds");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

// Clang bounds-safety: a non-constant index on __single is also an error ("constant or not").
fn void single_pointer_variable_index_reports_at_bracket() @test
{
	PostfixFixture f;
	f.init("pointer[idx]\n", "postfix.c", true);
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	f.seed("idx", type_store::INT);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "array subscript on single pointer must use a constant index of 0 to be in bounds");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

// Clang bounds-safety: reversed operands, `1[pointer]`, check the pointer side as base; '[' is col 2.
fn void single_pointer_reversed_nonzero_index_reports_at_bracket() @test
{
	PostfixFixture f;
	f.init("1[pointer]\n", "postfix.c", true);
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "array subscript on single pointer must use a constant index of 0 to be in bounds");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 2);
}

// Clang bounds-safety gate: the same __single subscript is silent when bounds-safety is off.
fn void single_pointer_index_is_silent_without_clang_bounds_safety() @test
{
	PostfixFixture f;
	f.init("pointer[1]\n");
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 0);
}

// Clang bounds-safety: only __single is restricted. A fixed array (which only decays) and a plain
// pointer both accept a non-zero index with bounds-safety on.
fn void fixed_array_and_plain_pointer_are_not_single_under_clang_bounds_safety() @test
{
	PostfixFixture f;
	f.init("array[1]\n", "postfix.c", true);
	defer f.free();
	type_store::QualType array_type = f.comp.type_store.put(type_store::type_array(type_store::INT,
		type_store::ArrayLenKind.FIXED, 4));
	f.seed("array", array_type);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("pointer[1]\n", "postfix.c", true);
	f.seed("pointer", f.comp.type_store.put(type_store::type_pointer(type_store::INT)));
	parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.ARRAY_ACCESS_EXPR);
	assert(f.diagnostics.messages.len() == 0);
}

// ---------------------------------------------------------------------------
// Member access
// ---------------------------------------------------------------------------

fn void dot_access_on_bitfield_keeps_bit_width_identity() @test
{
	PostfixFixture f;
	f.init("object.bits\n");
	defer f.free();
	type_store::QualType const_int = type_store::INT;
	const_int.is_const = true;
	type_store::RecordField[3] fields = {
		type_store::record_field(f.comp.intern_string("plain"), type_store::INT),
		{ .qt = type_store::UINT, .name = f.comp.intern_string("bits"), .bit_width = 3 },
		type_store::record_field(f.comp.intern_string("qualified"), const_int),
	};
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(access.member_access.member_index == 1);
	assert(access.member_access.is_bit_field_width(&f.parser.tree)!! == 3);
	// Source-derived (tree bitfieldWidth): the access node itself reports the bitfield.
	assert(f.parser.tree.is_bitfield(parsed.node));
	assert(parsed.qt.eql(type_store::UINT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void dot_access_on_plain_field_is_not_bitfield() @test
{
	PostfixFixture f;
	f.init("object.plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(!f.parser.tree.is_bitfield(parsed.node));
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void arrow_access_on_pointer_to_record_builds_ptr_member_access() @test
{
	PostfixFixture f;
	f.init("pointer->plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(record));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR);
	assert(access.member_access.member_index == 0);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void dot_on_pointer_reports_and_still_builds_member_access() @test
{
	PostfixFixture f;
	f.init("pointer.plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(record));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig fieldAccess, MEMBER_EXPR_PTR): error at the member
	// name; lookup continues on the unwrapped record.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text.contains("is a pointer; did you mean to use '->'?"));
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 9);
}

fn void arrow_on_record_reports_and_still_builds_ptr_member_access() @test
{
	PostfixFixture f;
	f.init("object->plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig fieldAccess, MEMBER_EXPR_NOT_PTR): error at the member name.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "member reference type 'struct PostfixRecord' is not a pointer; did you mean to use '.'?");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 9);
}

fn void const_record_member_inherits_const_qualifier() @test
{
	PostfixFixture f;
	f.init("object.plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = const_of(make_record(&f, "PostfixRecord", fields[..]));
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	// Approved semantics (C11 6.5.2.3p3): a member of a const-qualified record is const-qualified.
	assert(parsed.qt.eql(const_of(type_store::INT), &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void const_pointee_member_inherits_const_qualifier_through_arrow() @test
{
	PostfixFixture f;
	f.init("pointer->plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = const_of(make_record(&f, "PostfixRecord", fields[..]));
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(record));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	// Approved semantics (C11 6.5.2.3p3): arrow through pointer-to-const keeps const.
	assert(parsed.qt.eql(const_of(type_store::INT), &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void member_qualifier_of_field_is_kept_on_mutable_record() @test
{
	PostfixFixture f;
	f.init("object.qualified\n");
	defer f.free();
	type_store::QualType const_int = const_of(type_store::INT);
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("qualified"), const_int) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.qt.eql(const_int, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void atomic_record_member_access_reports_undefined_behavior() @test
{
	PostfixFixture f;
	f.init("object.plain\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	type_store::QualType atomic_record = f.comp.type_store.put(type_store::type_atomic(record));
	f.seed("object", atomic_record);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig fieldAccess, MEMBER_EXPR_ATOMIC): error at the member
	// name; lookup continues on the non-atomic record.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "accessing a member of atomic type '_Atomic(struct PostfixRecord)' is undefined behavior");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void expected_record_for_member_access_on_scalar() @test
{
	PostfixFixture f;
	f.init("value.x\n");
	defer f.free();
	f.seed("value", type_store::INT);
	// Source-derived (Parser.zig fieldAccess, expected_record_ty): fatal, reported at the member name.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "member reference base type 'int' is not a structure or union");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 7);
}

fn void missing_member_reports_once_at_member_token() @test
{
	PostfixFixture f;
	f.init("object.missing\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	// Source-derived (Parser.zig fieldAccessExtra, no_such_member): fatal, one
	// diagnostic at the member token, not repeated on recovery.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "no member named 'missing' in 'struct PostfixRecord'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void anonymous_member_promotion_builds_nested_access_nodes() @test
{
	PostfixFixture f;
	f.init("object.inner\n");
	defer f.free();
	type_store::RecordField[1] inner_fields = {
		type_store::record_field(f.comp.intern_string("inner"), type_store::INT),
	};
	type_store::QualType inner = make_record(&f, "AnonymousInner", inner_fields[..]);
	type_store::RecordField[1] outer_fields = {
		{ .qt = inner, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType outer = make_record(&f, "AnonymousOuter", outer_fields[..]);
	f.seed("object", outer);
	parser_result::Result parsed = f.parser.expr()!!;
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(access.member_access.member_index == 0);
	tree::Node promoted_base = access.member_access.base.get(&f.parser.tree);
	assert(promoted_base.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(promoted_base.member_access.member_index == 0);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	// Source-derived (Parser.zig fieldAccessExtra): one member access per aggregate level.
	assert(f.diagnostics.messages.len() == 0);
}

fn void anonymous_member_promotion_recurses_through_nested_levels() @test
{
	PostfixFixture f;
	f.init("object.deep\n");
	defer f.free();
	type_store::RecordField[1] deep_fields = { type_store::record_field(f.comp.intern_string("deep"), type_store::INT) };
	type_store::QualType deep = make_record(&f, "AnonymousDeep", deep_fields[..]);
	type_store::RecordField[1] middle_fields = {
		{ .qt = deep, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType middle = make_record(&f, "AnonymousMiddle", middle_fields[..]);
	type_store::RecordField[1] outer_fields = {
		{ .qt = middle, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType outer = make_record(&f, "AnonymousOuter", outer_fields[..]);
	f.seed("object", outer);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig fieldAccessExtra): descends two anonymous levels;
	// each level is its own member access, so the chain is three nodes deep.
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR && access.member_access.member_index == 0);
	tree::Node level_one = access.member_access.base.get(&f.parser.tree);
	assert(level_one.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(level_one.member_access.qt.eql(deep, &f.comp));
	tree::Node level_two = level_one.member_access.base.get(&f.parser.tree);
	assert(level_two.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(level_two.member_access.qt.eql(middle, &f.comp));
	assert(level_two.member_access.base.get(&f.parser.tree).kind != tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void ambiguous_anonymous_members_are_fatal_at_member_token() @test
{
	PostfixFixture f;
	f.init("object.x\n");
	defer f.free();
	type_store::RecordField[1] first_fields = { type_store::record_field(f.comp.intern_string("x"), type_store::INT) };
	type_store::QualType first = make_record(&f, "AnonymousFirst", first_fields[..]);
	type_store::RecordField[1] second_fields = { type_store::record_field(f.comp.intern_string("x"), type_store::FLOAT) };
	type_store::QualType second = make_record(&f, "AnonymousSecond", second_fields[..]);
	type_store::RecordField[2] outer_fields = {
		{ .qt = first, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
		{ .qt = second, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType outer = make_record(&f, "AnonymousOuter", outer_fields[..]);
	f.seed("object", outer);
	// C3-only (parser_postfix.c3 member_match_count, AMBIGUOUS_MEMBER): 'x' is reachable through two
	// anonymous members at the same level. Reported once at the member token and the parse is fatal;
	// no member is picked by declaration order.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "member 'x' is ambiguous; found in multiple anonymous struct or union members");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void const_outer_record_qualifies_member_through_anonymous_level() @test
{
	PostfixFixture f;
	f.init("object.plain\n");
	defer f.free();
	type_store::RecordField[1] inner_fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType inner = make_record(&f, "AnonymousInner", inner_fields[..]);
	type_store::RecordField[1] outer_fields = {
		{ .qt = inner, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType record = const_of(make_record(&f, "AnonymousOuter", outer_fields[..]));
	f.seed("object", record);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	// C11 6.5.2.3p3, applied at each anonymous level: the const outer record makes the anonymous
	// member const, and that const level makes the promoted field const.
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR && access.member_access.member_index == 0);
	tree::Node anonymous = access.member_access.base.get(&f.parser.tree);
	assert(anonymous.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(anonymous.member_access.qt.eql(const_of(inner), &f.comp));
	assert(anonymous.member_access.qt.is_const);
	assert(parsed.qt.eql(const_of(type_store::INT), &f.comp));
	assert(parsed.qt.is_const);
	assert(f.diagnostics.messages.len() == 0);
}

fn void const_anonymous_member_qualifies_field_two_levels_down() @test
{
	PostfixFixture f;
	f.init("object.deep\n");
	defer f.free();
	type_store::RecordField[1] deep_fields = { type_store::record_field(f.comp.intern_string("deep"), type_store::INT) };
	type_store::QualType deep = make_record(&f, "AnonymousDeep", deep_fields[..]);
	type_store::RecordField[1] middle_fields = {
		{ .qt = deep, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType middle = make_record(&f, "AnonymousMiddle", middle_fields[..]);
	type_store::RecordField[1] outer_fields = {
		{ .qt = const_of(middle), .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType outer = make_record(&f, "AnonymousOuter", outer_fields[..]);
	f.seed("object", outer);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(f.parser.at_eof());
	// C11 6.5.2.3p3, applied at each anonymous level: the outer record is mutable, but its const
	// anonymous member is const, so the field two levels down is const. The outer record adds nothing.
	tree::Node access = parsed.node.get(&f.parser.tree);
	assert(access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR && access.member_access.member_index == 0);
	tree::Node deep_access = access.member_access.base.get(&f.parser.tree);
	assert(deep_access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(deep_access.member_access.qt.eql(const_of(deep), &f.comp));
	assert(deep_access.member_access.qt.is_const);
	tree::Node middle_access = deep_access.member_access.base.get(&f.parser.tree);
	assert(middle_access.kind == tree::NodeKind.MEMBER_ACCESS_EXPR);
	assert(middle_access.member_access.qt.eql(const_of(middle), &f.comp));
	assert(middle_access.member_access.qt.is_const);
	assert(parsed.qt.eql(const_of(type_store::INT), &f.comp));
	assert(parsed.qt.is_const);
	assert(f.diagnostics.messages.len() == 0);
}

fn void missing_member_through_anonymous_members_names_outer_record() @test
{
	PostfixFixture f;
	f.init("object.zzz\n");
	defer f.free();
	type_store::RecordField[1] inner_fields = { type_store::record_field(f.comp.intern_string("inner"), type_store::INT) };
	type_store::QualType inner = make_record(&f, "AnonymousInner", inner_fields[..]);
	type_store::RecordField[1] outer_fields = {
		{ .qt = inner, .name = string_interner::EMPTY, .bit_width = type_store::BIT_WIDTH_NULL },
	};
	type_store::QualType outer = make_record(&f, "AnonymousOuter", outer_fields[..]);
	f.seed("object", outer);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig fieldAccessExtra): the diagnostic names the record
	// the lookup started from, not the anonymous member it descended through.
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "no member named 'zzz' in 'struct AnonymousOuter'");
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void incomplete_record_pointer_member_access_reports_dereference() @test
{
	PostfixFixture f;
	f.init("pointer->x\n");
	defer f.free();
	type_store::QualType incomplete = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("Incomplete")));
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(incomplete));
	f.seed("pointer", pointer);
	expect_postfix_failure(&f);
	// Source-derived (Parser.zig fieldAccess, deref_incomplete_ty_ptr): reported at the
	// pointer operand (name token minus two).
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "dereferencing pointer to incomplete type 'struct Incomplete'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 1);
}

fn void incomplete_record_dot_member_access_fails_silently() @test
{
	PostfixFixture f;
	f.init("object.x\n");
	defer f.free();
	type_store::QualType incomplete = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("Incomplete")));
	f.seed("object", incomplete);
	// Source-derived (Parser.zig fieldAccess): the invalid use is reported where the
	// type was named, so no diagnostic here.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 0);
}

// ---------------------------------------------------------------------------
// Increment and decrement
// ---------------------------------------------------------------------------

fn void postfix_inc_dec_accepts_modifiable_arithmetic_lvalues() @test
{
	PostfixFixture f;
	f.init("value++\n");
	defer f.free();
	f.seed("value", type_store::INT);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_INC_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.parser.at_eof());
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("value--\n");
	f.seed("value", type_store::INT);
	parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_DEC_EXPR);
	assert(parsed.qt.eql(type_store::INT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void postfix_inc_on_float_lvalue_is_valid() @test
{
	PostfixFixture f;
	f.init("value++\n");
	defer f.free();
	f.seed("value", type_store::FLOAT);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_INC_EXPR);
	assert(parsed.qt.eql(type_store::FLOAT, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void postfix_inc_on_rvalue_reports_not_assignable() @test
{
	PostfixFixture f;
	f.init("1++\n");
	defer f.free();
	// Source-derived (Parser.zig suffixExpr .plus_plus): reported at the operator token; fatal.
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expression is not assignable");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 2);
}

fn void postfix_inc_on_const_lvalue_reports_not_assignable() @test
{
	PostfixFixture f;
	f.init("value++\n");
	defer f.free();
	f.seed("value", const_of(type_store::INT));
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expression is not assignable");
	assert(f.diagnostics.messages[0].location.col == 6);
}

fn void pointer_inc_dec_accepts_object_pointers_including_pointer_to_const() @test
{
	PostfixFixture f;
	f.init("pointer++\n");
	defer f.free();
	type_store::QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.seed("pointer", pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_INC_EXPR);
	assert(parsed.qt.eql(pointer, &f.comp));
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("pointer--\n");
	type_store::QualType const_pointee = f.comp.type_store.put(type_store::type_pointer(const_of(type_store::INT)));
	f.seed("pointer", const_pointee);
	parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig suffixExpr, checkPtrArithmeticAllowed): the pointer
	// itself is modifiable; pointer-bound checks apply only under bounds-safety, which is off here.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_DEC_EXPR);
	assert(parsed.qt.eql(const_pointee, &f.comp));
	assert(f.diagnostics.messages.len() == 0);
}

fn void const_pointer_inc_reports_not_assignable() @test
{
	PostfixFixture f;
	f.init("pointer++\n");
	defer f.free();
	type_store::QualType pointer = const_of(f.comp.type_store.put(type_store::type_pointer(type_store::INT)));
	f.seed("pointer", pointer);
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "expression is not assignable");
	assert(f.diagnostics.messages[0].location.col == 8);
}

// Clang bounds-safety (parser_postfix.c3 check_postfix_update_operand, POINTER_ARITH_SINGLE): postfix
// ++ and -- on a __single pointer are rejected at the operator. The check returns false, so the postfix
// parse fails fatally instead of building a recovered update node.
fn void single_pointer_postfix_update_reports_pointer_bound_and_is_fatal() @test
{
	PostfixFixture f;
	f.init("pointer++\n", "postfix.c", true);
	defer f.free();
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "pointer arithmetic on single pointer is out of bounds; consider adding '__counted_by'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);

	f.free();
	f.init("pointer--\n", "postfix.c", true);
	f.seed("pointer", make_single_pointer(&f, type_store::INT));
	expect_postfix_failure(&f);
	assert(f.diagnostics.messages.len() == 1);
	assert(f.diagnostics.messages[0].text == "pointer arithmetic on single pointer is out of bounds; consider adding '__counted_by'");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 8);
}

fn void void_pointer_inc_has_no_default_diagnostic() @test
{
	PostfixFixture f;
	f.init("vp++\n");
	defer f.free();
	type_store::QualType void_pointer = f.comp.type_store.put(type_store::type_pointer(type_store::VOID));
	f.seed("vp", void_pointer);
	parser_result::Result parsed = f.parser.expr()!!;
	// Source-derived (Parser.zig suffixExpr): void-pointer arithmetic is a GNU extension
	// whose diagnostic is off by default.
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_INC_EXPR);
	assert(f.diagnostics.messages.len() == 0);
}

fn void record_inc_reports_invalid_argument_type() @test
{
	PostfixFixture f;
	f.init("object++\n");
	defer f.free();
	type_store::RecordField[1] fields = { type_store::record_field(f.comp.intern_string("plain"), type_store::INT) };
	type_store::QualType record = make_record(&f, "PostfixRecord", fields[..]);
	f.seed("object", record);
	// Source-derived (Parser.zig suffixExpr, invalid_argument_un): error at the operator;
	// the reference continues building the node.
	parser_result::Result parsed = f.parser.expr()!!;
	assert(parsed.node.get(&f.parser.tree).kind == tree::NodeKind.POST_INC_EXPR);
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].text == "invalid argument type 'struct PostfixRecord' to unary expression");
	assert(f.diagnostics.messages[0].kind == diagnostics::MessageKind.ERROR);
	assert(f.diagnostics.messages[0].location.col == 7);
}
