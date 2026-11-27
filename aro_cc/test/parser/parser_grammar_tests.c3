// Integration coverage for the declaration grammar and its composed expressions.
module parser_grammar_tests;
import aro::frontend::c::parser, aro::frontend::c::preprocessor, aro::source, aro::frontend::c::tree;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::type_store, aro::string_interner, aro::frontend::c::symbol_stack, aro::frontend::c::value;
import aro::bigint, aro::value_interner;
import std::core::mem::allocators;

struct GrammarTypedefSeed (parser::IParserTestProbe)
{
	string_interner::StringId name;
	type_store::QualType qt;
}

fn void? GrammarTypedefSeed.handle_implicit_typedefs(&seed, parser::Parser* p) @dynamic
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
		pp.init(&comp, preprocessor::TESTING)!!;
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
		parser::Parser p;
		p.init(&pp); p.test_probe = &seed;
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