// Standalone consumer of the public aro_distribution C3 source package.
// The integration harness builds this workspace after extracting the package
// under a path containing spaces, with C3C set explicitly and Zig removed from
// PATH.
module library_consumer;

import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::parser_declaration, aro::frontend::c::preprocessor;
import aro::source, aro::frontend::c::tree, aro::frontend::c::type_store;
import std::core::mem::allocators;

excuse CONSUMER_FILE_NOT_FOUND;

struct IncludeFixture
{
	String path;
	String contents;
}

fn bool fixture_exists(void* context, String path)
{
	IncludeFixture* fixture = (IncludeFixture*)context;
	return path == fixture.path;
}

fn char[]? fixture_read(void* context, Allocator allocator, String path, ulong limit)
{
	IncludeFixture* fixture = (IncludeFixture*)context;
	if (path != fixture.path) return CONSUMER_FILE_NOT_FOUND~;
	usz len = fixture.contents.len;
	if (limit != ulong::max && len > (usz)limit) len = (usz)limit;
	char* copy = alloc::malloc(allocator, (sz)len + 1);
	if (len > 0) mem::copy(copy, fixture.contents.ptr, (sz)len);
	copy[len] = 0;
	return copy[:len];
}

fn void inspect_variable(tree::Tree* ast, compilation::Compilation* comp, usz index, String expected_name)
{
	type_store::NodeIndex index_in_tree = ast.root_decls[(sz)index];
	tree::Node declaration = index_in_tree.get(ast);
	assert(declaration.kind == tree::NodeKind.VARIABLE, "AST node is not a variable declaration");
	assert(ast.tok_slice(declaration.variable.name_tok) == expected_name, "AST declaration name did not match");
	assert(type_store::INT.eql(declaration.variable.qt, comp), "AST declaration did not retain int type");
	assert(declaration.variable.qt.tprint(comp) == "int", "type inspection did not print int");
}

fn void preprocess_parse_and_inspect(compilation::Compilation* comp, String path, String contents,
	bool expect_malformed, String[] expected_names)
{
	source::Source src = comp.add_source_from_buffer(path, contents)!!;
	preprocessor::InitOptions options = preprocessor::TESTING;
	options.base_file = src.id;
	preprocessor::Preprocessor pp;
	pp.init(comp, options, comp.file_provider())!!;
	pp.add_token(pp.preprocess(src)!!)!!;

	parser::Parser p;
	p.init(&pp);
	tree::Tree ast = p.parse()!!;
	assert(ast.root_decls.len() == expected_names.len, "parser did not preserve all valid declarations");
	foreach (index, name : expected_names) inspect_variable(&ast, comp, (usz)index, name);
	if (expect_malformed)
	{
		assert(comp.diagnostics.errors == 1, "malformed declaration did not produce one diagnostic");
		assert(comp.diagnostics.messages.len() == 1, "diagnostic list did not contain the malformed declaration");
		assert(comp.diagnostics.messages[0].text == "expected identifier or '('",
			"diagnostic text was not inspectable");
	}
	ast.free();
	p.free();
	pp.free();
}

fn int main(String[] args)
{
	TrackingAllocator allocator;
	allocator.init(mem);
	defer allocator.free();
	{
		diagnostics::Diagnostics diags;
		diags.init_list(&allocator);
		compilation::Compilation comp;
		comp.init(&allocator, null, &diags);
		IncludeFixture fixture = {
			.path = "/consumer/consumer_fixture.h",
			.contents = "int from_include;\n",
		};
		comp.include_files = { .ctx = (void*)&fixture, .exists = &fixture_exists, .read = &fixture_read };

		String[] first_names = { "from_include", "from_main", "after_recovery" };
		preprocess_parse_and_inspect(&comp, "/consumer/main.c",
			"#include \"consumer_fixture.h\"\nint from_main;\nint ;\nint after_recovery;\n",
			true, first_names);

		// A fresh preprocessing/parser lifecycle after recovery must remain
		// usable and retain the earlier diagnostic for caller inspection.
		String[] second_names = { "next_parse" };
		preprocess_parse_and_inspect(&comp, "/consumer/next.c", "int next_parse;\n", false, second_names);
		assert(diags.errors == 1 && diags.messages.len() == 1,
			"a subsequent parse changed diagnostics from the recovered parse");

		comp.free();
		diags.free();
	}
	assert(allocator.allocation_count() == 0, "consumer lifecycle leaked compilation allocations");
	return 0;
}
