module parse_buffer_example;

import aro::compilation, aro::diagnostics, aro::parser, aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::tree, aro::type_store;
import std::core::mem::allocators;

// A tiny caller-supplied grammar: only `int identifier;` is recognized.
// For the complete C grammar use parser_frontend::FrontendHandler instead.
struct IntDeclarations (parser::IParserHandler)
{
	int unused;
}

fn void? IntDeclarations.handle_declaration(&self, parser::Parser* p) @dynamic
{
	if (p.at_eof() || p.tree.tok_slice(p.current()) != "int") return parser::PARSING_FAILED~;
	p.advance();
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER)) return p.expected_token_diag(tokenizer::TokenId.IDENTIFIER);
	tokens::TokenIndex name_tok = p.current();
	p.advance();
	p.expect(tokenizer::TokenId.SEMICOLON)!;

	type_store::NodeIndex declaration = p.tree.add_node({
		.kind = tree::NodeKind.VARIABLE,
		.variable = {
			.name_tok = name_tok,
			.qt = type_store::INT,
			.initializer = type_store::NODE_NULL,
			.definition = type_store::NODE_NULL,
		},
	});
	p.tree.root_decls.push(declaration);
}

fn void? parse_buffer(Allocator gpa, char[] bytes)
{
	diagnostics::Diagnostics diags;
	diags.init_list(gpa);
	defer diags.free();

	compilation::Compilation comp;
	comp.init(gpa, null, &diags);
	defer comp.free();

	source::Source src = comp.add_source_from_buffer("buffer.c", bytes)!;
	preprocessor::Preprocessor pp;
	pp.init(&comp, preprocessor::TESTING)!;
	defer pp.free();
	pp.add_token(pp.preprocess(src)!)!;

	IntDeclarations grammar;
	parser::Parser parser;
	parser.init(&pp, &grammar);
	defer parser.free();
	tree::Tree syntax_tree = parser.parse()!;
	defer syntax_tree.free();

	assert(syntax_tree.root_decls.len() == 1);
	type_store::NodeIndex declaration = syntax_tree.root_decls[0];
	type_store::Type inspected = declaration.qt(&syntax_tree).get_type(&comp);
	assert(inspected.tag == type_store::TypeTag.INT);
	assert(inspected.int_ty == type_store::TypeInt.INT);

	// The list sink stores an owned copy; it does not borrow this message slice.
	diags.add({ .kind = diagnostics::NOTE, .text = "buffer parsed" })!;
	assert(diags.messages.len() == 1);
	assert(diags.messages[0].text == "buffer parsed");
}

fn int main(String[] args)
{
	(void)args;
	fault f = @catch(parse_buffer(mem, "int answer;\n"));
	if (f) return 1;
	return 0;
}
