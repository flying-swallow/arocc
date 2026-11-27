module parse_buffer_example;

import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::parser_declaration, aro::frontend::c::preprocessor;
import aro::source, aro::frontend::c::tree, aro::frontend::c::type_store;
import std::core::mem::allocators;

fn void? parse_buffer(Allocator gpa, char[] bytes)
{
	diagnostics::Diagnostics diags;
	diags.init_list(gpa);
	defer diags.free();

	compilation::Compilation comp;
	comp.init(gpa, compilation::native_definition(), null, &diags);
	defer comp.free();

	source::Source src = comp.add_source_from_buffer("buffer.c", bytes)!;
	preprocessor::Preprocessor pp;
	pp.init(&comp, preprocessor::TESTING)!;
	defer pp.free();
	pp.add_token(pp.preprocess(src)!)!;

	parser::Parser parser;
	parser.init(&pp);
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
