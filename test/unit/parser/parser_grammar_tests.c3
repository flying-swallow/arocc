// Integration coverage for the declaration grammar and its composed expressions.
module parser_grammar_tests;
import aro::parser, aro::parser_declaration, aro::preprocessor, aro::source, aro::tree;
import aro::compilation, aro::diagnostics, aro::type_store, aro::string_interner, aro::symbol_stack, aro::value;
import aro::bigint, aro::value_interner;
import std::core::mem::allocators;

struct GrammarTypedefSeed (parser_declaration::IDeclarationTestProbe)
{
	string_interner::StringId name;
	type_store::QualType qt;
}

fn void? GrammarTypedefSeed.implicit_typedefs(&seed, parser::Parser* p) @dynamic
{
	seed.qt = p.comp.type_store.put(type_store::type_typedef(type_store::INT, seed.name,
		(type_store::NodeIndex)0));
	p.define_symbol({ .kind = symbol_stack::SymbolKind.TYPEDEF, .name = seed.name,
		.tok = 0, .qt = seed.qt, .node = (type_store::NodeIndex)0, .val = value::NONE });
}

fn void integrated_declarations_seed_typedefs_and_compose_function_grammar() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("grammar.c",
			"Seeded seed = 1; typedef int Word; Word source = 1; " +++
			"struct Pair { int key; unsigned ready : 1; }; " +++
			"enum State { STATE_ZERO, STATE_READY = 4, }; " +++
			"struct Pair *pair; enum State *state; " +++
			"Word compute(Word lhs, Word rhs) { " +++
			"typedef Word LocalWord; LocalWord total = lhs + rhs * 2; " +++
			"if (total > 10 && (lhs != 0 || rhs == 0)) { total += (Word)3; } " +++
			"return total ? total : source + seed; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		GrammarTypedefSeed seed = { .name = comp.intern_string("Seeded") };
		parser_declaration::DeclarationParser declarations = {
			.test_probe = &seed,
		};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 8, "all declarations should be retained in source order");
		tree::Node seeded_var = result.root_decls[0].get(&result);
		tree::Node word_typedef = result.root_decls[1].get(&result);
		tree::Node later_var = result.root_decls[2].get(&result);
		assert(seeded_var.kind == tree::NodeKind.VARIABLE);
		assert(seeded_var.variable.qt.eql(seed.qt, &comp), "the seeded typedef should resolve in a declaration specifier");
		assert(word_typedef.kind == tree::NodeKind.TYPEDEF);
		assert(later_var.kind == tree::NodeKind.VARIABLE);
		assert(later_var.variable.qt.eql(word_typedef.type_def.qt, &comp),
			"a parsed typedef should be available to following declarations");

		// Record fields, bit fields, enumerators, and later tag references share
		// the declarations' type identities.
		tree::Node struct_decl = result.root_decls[3].get(&result);
		tree::Node enum_decl = result.root_decls[4].get(&result);
		tree::Node pair_var = result.root_decls[5].get(&result);
		tree::Node state_var = result.root_decls[6].get(&result);
		assert(struct_decl.kind == tree::NodeKind.STRUCT_DECL);
		assert(struct_decl.container_decl.fields.len == 2);
		type_store::Type pair_type = struct_decl.container_decl.container_qt.get(&comp, type_store::TypeTag.STRUCT)!!;
		assert(pair_type.record.fields.len == 2);
		assert(pair_type.record.fields[0].qt.eql(type_store::INT, &comp));
		assert(pair_type.record.fields[1].bit_width == 1, "the record grammar should preserve bit-field width");
		assert(enum_decl.kind == tree::NodeKind.ENUM_DECL);
		assert(enum_decl.container_decl.fields.len == 2);
		tree::Node enum_value = enum_decl.container_decl.fields[1].get(&result);
		assert(enum_value.kind == tree::NodeKind.ENUM_FIELD);
		assert(!enum_value.enum_field.init.is_null(), "explicit enumerator values should keep their expression node");
		type_store::Type pair_pointer = pair_var.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
		type_store::Type state_pointer = state_var.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
		assert(pair_pointer.pointer.child.is(&comp, type_store::TypeTag.STRUCT));
		assert(state_pointer.pointer.child.is(&comp, type_store::TypeTag.ENUM));

		tree::Node function = result.root_decls[7].get(&result);
		assert(function.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 2);
		assert(function_type.params[0].qt.eql(word_typedef.type_def.qt, &comp));
		assert(!function.function.body.is_null());
		tree::Node body = function.function.body.unwrap().get(&result);
		assert(body.kind == tree::NodeKind.COMPOUND_STMT);
		assert(body.compound_stmt.body.len == 4, "body should contain a typedef, declaration, if, and return");

		tree::Node local_typedef_stmt = body.compound_stmt.body[0].get(&result);
		assert(local_typedef_stmt.kind == tree::NodeKind.DECL_STMT);
		tree::Node local_typedef = local_typedef_stmt.decl_stmt.decls[0].get(&result);
		assert(local_typedef.kind == tree::NodeKind.TYPEDEF);
		tree::Node local_decl_stmt = body.compound_stmt.body[1].get(&result);
		tree::Node local = local_decl_stmt.decl_stmt.decls[0].get(&result);
		assert(local_decl_stmt.kind == tree::NodeKind.DECL_STMT && local.kind == tree::NodeKind.VARIABLE);
		assert(local.variable.qt.eql(local_typedef.type_def.qt, &comp),
			"a block typedef should seed subsequent local declarations");
		tree::Node sum = local.variable.initializer.unwrap().get(&result);
		assert(sum.kind == tree::NodeKind.ADD_EXPR, "addition should be the initializer's outer operation");
		tree::Node product = sum.binary.rhs.get(&result);
		assert(product.kind == tree::NodeKind.MUL_EXPR, "multiplication should bind more tightly than addition");

		tree::Node if_stmt = body.compound_stmt.body[2].get(&result);
		assert(if_stmt.kind == tree::NodeKind.IF_STMT);
		tree::Node condition = if_stmt.if_stmt.cond.get(&result);
		assert(condition.kind == tree::NodeKind.BOOL_AND_EXPR);
		tree::Node grouped_or = condition.binary.rhs.get(&result);
		assert(grouped_or.kind == tree::NodeKind.PAREN_EXPR);
		assert(grouped_or.unary.operand.get(&result).kind == tree::NodeKind.BOOL_OR_EXPR);
		tree::Node then_body = if_stmt.if_stmt.then_body.get(&result);
		tree::Node assignment = then_body.compound_stmt.body[0].get(&result);
		assert(assignment.kind == tree::NodeKind.ADD_ASSIGN_EXPR);
		tree::Node calculation = assignment.binary.rhs.get(&result);
		assert(calculation.kind == tree::NodeKind.ADD_EXPR,
			"compound assignment should retain its synthesized addition calculation");
		tree::Node cast = calculation.binary.rhs.get(&result);
		assert(cast.kind == tree::NodeKind.CAST, "the explicit typedef cast should be retained");
		tree::Node return_stmt = body.compound_stmt.body[3].get(&result);
		assert(return_stmt.kind == tree::NodeKind.RETURN_STMT);
		assert(return_stmt.return_stmt.operand == tree::ReturnOperandKind.EXPR);
		assert(return_stmt.return_stmt.expr.get(&result).kind == tree::NodeKind.COND_EXPR,
			"the return should preserve its conditional expression");
		assert(d.messages.len() == 0, "the integrated grammar should parse this valid source without diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
fn void malformed_function_recovers_to_following_declaration() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("recovery.c",
			"int broken(void) { if (1) } int valid;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations;
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.errors > 0, "the malformed function body should produce a parser diagnostic");
		// Zig's compoundStmt closes the body at the stray '}' (Parser.zig ~6187-6230)
		// without propagating the error, so the malformed function is still appended.
		assert(result.root_decls.len() == 2,
			"recovery should keep the malformed function and the valid external declaration after it");
		tree::Node broken = result.root_decls[0].get(&result);
		assert(broken.kind == tree::NodeKind.FUNCTION);
		assert(result.tok_slice(broken.function.name_tok) == "broken");
		tree::Node recovered = result.root_decls[1].get(&result);
		assert(recovered.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(recovered.variable.name_tok) == "valid");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void auto_type_expression_failures_recover_at_declaration_and_statement_boundaries() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("auto-type-recovery.c",
			"int bad_cast = (__auto_type)5; int after_cast = 1; " +++
			"void f(void) { __auto_type self = self; int after_self = 2; } int tail = 3;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations;
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2, "both invalid auto-type expressions should retain their diagnostics");
		test::eq(d.messages[0].text, "expected expression");
		// The stored message is the fully formatted template, with the name filled in.
		test::eq(d.messages[1].text, "variable 'self' declared with deduced type '__auto_type' cannot appear in its own initializer");
		assert(result.root_decls.len() == 3,
			"translation-unit recovery should retain declarations after the invalid cast");
		assert(result.tok_slice(result.root_decls[0].get(&result).variable.name_tok) == "after_cast");
		tree::Node function = result.root_decls[1].get(&result);
		assert(function.kind == tree::NodeKind.FUNCTION);
		tree::Node body = function.function.body.unwrap().get(&result);
		assert(body.compound_stmt.body.len == 2,
			"statement recovery should retain the valid declaration and synthesized function return");
		tree::Node local_decl = body.compound_stmt.body[0].get(&result);
		assert(local_decl.kind == tree::NodeKind.DECL_STMT);
		assert(result.tok_slice(local_decl.decl_stmt.decls[0].get(&result).variable.name_tok) == "after_self");
		tree::Node implicit_return = body.compound_stmt.body[1].get(&result);
		assert(implicit_return.kind == tree::NodeKind.RETURN_STMT);
		assert(implicit_return.return_stmt.operand == tree::ReturnOperandKind.IMPLICIT);
		assert(result.tok_slice(result.root_decls[2].get(&result).variable.name_tok) == "tail");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void nonfixed_enum_overflow_diagnostics_keep_unbounded_messages_and_wrapped_values() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("enum-overflow.c",
			"enum E { A = 2147483647, B, C = 4294967295UL, D, " +++
			"F = 9223372036854775807LL, G, " +++
			"H = 18446744073709551615ULL, I };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations;
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 3, "signed-width growth and largest-type overflow should each be diagnosed");
		test::eq(d.messages[0].text, "overflow in enumeration value");
		test::eq(d.messages[1].text,
			"incremented enumerator value 9223372036854775808 is not representable in the largest integer type");
		test::eq(d.messages[2].text,
			"incremented enumerator value 18446744073709551616 is not representable in the largest integer type");

		tree::Node enum_decl = result.root_decls[0].get(&result);
		value::Value g_value = result.value_of(enum_decl.container_decl.fields[5])!!;
		value::Value i_value = result.value_of(enum_decl.container_decl.fields[7])!!;
		bigint::BigIntConst g_big = g_value.to_big_int(&comp);
		bigint::Limb[2] g_expected_limbs;
		bigint::BigIntMutable g_expected = { .limbs = g_expected_limbs[..], .len = 1, .positive = true };
		g_expected.set_string(10, "9223372036854775808", {})!!;
		assert(g_big.eql(g_expected.to_const()), "G must retain the full value past signed long long");
		bigint::BigIntConst i_big = i_value.to_big_int(&comp);
		bigint::Limb[2] i_expected_limbs;
		bigint::BigIntMutable i_expected = { .limbs = i_expected_limbs[..], .len = 1, .positive = true };
		i_expected.set_string(10, "0", {})!!;
		assert(i_big.eql(i_expected.to_const()), "I must wrap to zero past unsigned long long");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void function_void_parameter_lists_follow_c_conventions() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("void-parameters.c",
			"int f(void); int qualified(const void); int bad(void, int value); " +++
			"int bad_qualified(const void, int value); int later(int value, void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations;
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		// Rejected parameter lists recover past the rest of their declaration
		// (Parser.recover_from closes the open `(`), so unlike Zig the `int value`
		// inside `bad(void, int value)` is not re-parsed as a stray file-scope
		// declaration: only the two valid prototypes remain.
		assert(result.root_decls.len() == 2,
			"sole void prototypes should be retained and rejected lists should not leave stray declarations");
		tree::Node function = result.root_decls[0].get(&result);
		tree::Node qualified_function = result.root_decls[1].get(&result);
		assert(function.kind == tree::NodeKind.FUNCTION && qualified_function.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function.function.qt.get_func(&comp)!!;
		type_store::Func qualified_function_type = qualified_function.function.qt.get_func(&comp)!!;
		assert(function_type.kind == type_store::FuncKind.NORMAL && qualified_function_type.kind == type_store::FuncKind.NORMAL);
		assert(function_type.params.len == 0 && qualified_function_type.params.len == 0,
			"a sole void parameter should produce a normal function type with no parameters");
		assert(d.messages.len() == 4, "invalid void positions and qualifiers should be diagnosed without recovery cascades");
		test::eq(d.messages[0].text, "'void' must be the only parameter if specified");
		test::eq(d.messages[1].text, "'void' must be the only parameter if specified");
		test::eq(d.messages[2].text, "'void' parameter cannot be qualified");
		test::eq(d.messages[3].text, "'void' must be the first parameter if specified");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
