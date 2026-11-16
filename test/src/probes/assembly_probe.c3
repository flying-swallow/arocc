// A data-only selector for direct AST-to-assembly migration fixtures. The
// input files select a hand-built Tree scenario; they are not parsed as C.
module assembly_probe;
import aro::primitive_value;
import aro::backend::assembly, aro::compilation, aro::diagnostics;
import aro::source, aro::target, aro::tokens, aro::tokenizer, aro::tree, aro::type_store;
import aro::value, aro::value_interner, std::io;

const Host HOST = { X86_64, LINUX, GNU };
const String[17] NAMES = {
	"byte_value", "short_value", "int_value", "long_value", "half_value",
	"float_value", "double_value", "extended_value", "quad_value", "local_zero",
	"common_zero", "tls_value", "sectioned_value", "tls_zero", "string_value",
	"false_value", "true_value",
};

struct ProbeFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[17] tokens;
	Tree tree;
}

fn void ProbeFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	self.comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
	self.comp.langopts.set_target_options(&self.comp.target);
	type_store::init_named_types(&self.comp);

	DString text;
	text.init(&self.ta);
	sz[17] offsets;
	foreach (i, name : NAMES)
	{
		offsets[i] = text.len();
		text.append_string(name);
		text.append_char(' ');
	}
	Source src = self.comp.add_source_from_buffer("assembly_probe.c", text.str_view())!!;
	for (sz i = 0; i < 17; i++)
	{
		self.tokens[i] = { .id = tokenizer::TokenId.IDENTIFIER,
			.loc = { .id = src.id, .byte_offset = (uint)offsets[i], .line = 1 } };
	}
	text.free();
	self.tree.init(&self.comp, self.tokens[..]);
}

fn void ProbeFixture.free(&self)
{
	self.tree.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.ta.allocation_count() == 0, "assembly probe leaked allocations");
	self.ta.free();
}

fn NodeIndex ProbeFixture.int_literal(&self, tokens::TokenIndex tok, type_store::QualType qt, long number)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = qt } });
	self.tree.set_value(node, value::int_i64(number, &self.comp));
	return node;
}

fn NodeIndex ProbeFixture.float_literal(&self, tokens::TokenIndex tok, type_store::QualType qt,
	primitive_value::PrimitiveType tag, uint128 bits)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
		.literal = { .literal_tok = tok, .qt = qt } });
	self.tree.set_value(node, value::intern(&self.comp,
		primitive_value::float_key(tag, bits)));
	return node;
}

fn NodeIndex ProbeFixture.string_literal(&self, tokens::TokenIndex tok, type_store::QualType qt, char[] bytes)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .literal_tok = tok, .qt = qt, .kind = tree::CharLiteralKind.ASCII } });
	self.tree.set_value(node, value::intern(&self.comp, { .tag = BYTES, .bytes = bytes }));
	return node;
}

fn void ProbeFixture.global(&self, tokens::TokenIndex name_tok, type_store::QualType qt)
{
	self.insert_global(name_tok, qt, type_store::NODE_NULL, tree::VariableStorageClass.AUTO, false);
}

fn void ProbeFixture.global_options(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	tree::VariableStorageClass storage, bool thread_local)
{
	self.insert_global(name_tok, qt, type_store::NODE_NULL, storage, thread_local);
}

fn void ProbeFixture.global_value(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	NodeIndex initializer, tree::VariableStorageClass storage, bool thread_local)
{
	self.insert_global(name_tok, qt, initializer.pack(), storage, thread_local);
}

fn void ProbeFixture.insert_global(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	NodeOptIndex init, tree::VariableStorageClass storage, bool thread_local)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = name_tok, .qt = qt, .storage_class = storage,
			.thread_local = thread_local, .initializer = init,
			.definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(node);
}

fn void build_integer_scalars(ProbeFixture* f)
{
	f.global_value(0, type_store::UCHAR, f.int_literal(0, type_store::UCHAR, 255), tree::VariableStorageClass.AUTO, false);
	f.global_value(1, type_store::SHORT, f.int_literal(1, type_store::SHORT, -123), tree::VariableStorageClass.AUTO, false);
	f.global_value(2, type_store::INT, f.int_literal(2, type_store::INT, 305419896), tree::VariableStorageClass.AUTO, false);
	f.global_value(3, type_store::ULONG_LONG, f.int_literal(3, type_store::ULONG_LONG, 123456789), tree::VariableStorageClass.AUTO, false);
}

fn void build_bool_scalars(ProbeFixture* f)
{
	f.global_value(15, type_store::BOOL, f.int_literal(15, type_store::BOOL, 0), tree::VariableStorageClass.AUTO, false);
	f.global_value(16, type_store::BOOL, f.int_literal(16, type_store::BOOL, 1), tree::VariableStorageClass.AUTO, false);
}

fn void build_float_scalars(ProbeFixture* f)
{
	f.global_value(4, type_store::FLOAT16, f.float_literal(4, type_store::FLOAT16, F16, 0x3e00), tree::VariableStorageClass.AUTO, false);
	f.global_value(5, type_store::FLOAT, f.float_literal(5, type_store::FLOAT, F32, 0x3fc00000), tree::VariableStorageClass.AUTO, false);
	f.global_value(6, type_store::DOUBLE, f.float_literal(6, type_store::DOUBLE, F64, 0x3ff8000000000000), tree::VariableStorageClass.AUTO, false);
	f.global_value(7, type_store::LONG_DOUBLE, f.float_literal(7, type_store::LONG_DOUBLE,
		F80, (uint128)0x3fff << 64 | (uint128)0x8000000000000000), tree::VariableStorageClass.AUTO, false);
	f.global_value(8, type_store::FLOAT128, f.float_literal(8, type_store::FLOAT128,
		F128, (uint128)0x3fff000000000000 << 64), tree::VariableStorageClass.AUTO, false);
}

fn void build_storage_defaults(ProbeFixture* f)
{
	f.global(9, type_store::INT);
	f.global_value(11, type_store::INT, f.int_literal(11, type_store::INT, 7), tree::VariableStorageClass.AUTO, true);
	f.global_value(12, type_store::INT, f.int_literal(12, type_store::INT, 9), tree::VariableStorageClass.STATIC, false);
	f.global_options(13, type_store::INT, tree::VariableStorageClass.AUTO, true);
}

fn void build_storage_options(ProbeFixture* f)
{
	f.comp.code_gen_options.common = true;
	f.comp.code_gen_options.data_sections = true;
	f.global(10, type_store::INT);
	f.global_value(12, type_store::INT, f.int_literal(12, type_store::INT, 9), tree::VariableStorageClass.STATIC, false);
	f.global_value(11, type_store::INT, f.int_literal(11, type_store::INT, 7), tree::VariableStorageClass.AUTO, true);
	f.global_options(13, type_store::INT, tree::VariableStorageClass.AUTO, true);
}

fn void build_string_array(ProbeFixture* f)
{
	char[3] bytes = { 'h', 'i', 0 };
	type_store::QualType qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	f.global_value(14, qt, f.string_literal(14, qt, bytes[..]), tree::VariableStorageClass.AUTO, false);
}

fn void build_ascii_array(ProbeFixture* f)
{
	char[3] bytes = { 'h', 'i', 0 };
	type_store::QualType qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 2));
	f.global_value(14, qt, f.string_literal(14, qt, bytes[..]), tree::VariableStorageClass.AUTO, false);
}

fn void build_unsupported_array_init(ProbeFixture* f)
{
	NodeIndex init = f.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR,
		.container_init = { .l_brace_tok = 0, .container_qt = type_store::INT } });
	f.global_value(0, type_store::INT, init, tree::VariableStorageClass.AUTO, false);
}

fn void build_unsupported_bitint(ProbeFixture* f)
{
	type_store::QualType qt = f.comp.type_store.put(type_store::type_bit_int(7, SIGNED));
	f.global_value(0, qt, f.int_literal(0, qt, 1), tree::VariableStorageClass.AUTO, false);
}

fn void build_unsupported_pointer(ProbeFixture* f)
{
	type_store::QualType qt = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.global_value(0, qt, f.int_literal(0, qt, 1), tree::VariableStorageClass.AUTO, false);
}

fn int main(String[] args)
{
	String input;
	for (sz i = 1; i < args.len; i++)
	{
		if (!args[i].starts_with("-"))
		{
			input = args[i];
			break;
		}
	}
	if (input.len == 0)
	{
		io::eprintfn("assembly_probe: expected a fixture file");
		return 2;
	}
	char[] contents = file::load_temp(input)!!;
	String selector = (String)contents;
	// Fixtures carry a runner manifest block; the selector is the trailing data after it.
	if (selector.starts_with("/** manifest:"))
	{
		if (try end = selector.rindex_of("*/")) selector = selector[end + 2..];
	}
	selector = selector.trim();

	ProbeFixture f;
	f.init();
	bool expect_error = false;
	switch (selector)
	{
		case "integer-scalars": build_integer_scalars(&f);
		case "bool-scalars": build_bool_scalars(&f);
		case "float-scalars": build_float_scalars(&f);
		case "storage-defaults": build_storage_defaults(&f);
		case "storage-options": build_storage_options(&f);
		case "string-array": build_string_array(&f);
		case "ascii-array": build_ascii_array(&f);
		case "unsupported-array-init":
			build_unsupported_array_init(&f);
			expect_error = true;
		case "unsupported-bitint":
			build_unsupported_bitint(&f);
			expect_error = true;
		case "unsupported-pointer":
			build_unsupported_pointer(&f);
			expect_error = true;
		default:
			io::eprintfn("assembly_probe: unknown selector '%s'", selector);
			f.free();
			return 2;
	}
	if (expect_error)
	{
		fault failure = @catch(assembly::gen_asm(&f.tree));
		assert(failure == compilation::FATAL_ERROR,
			"unsupported assembly fixture should return FATAL_ERROR");
		assert(f.diagnostics.messages.len() == 1,
			"unsupported assembly fixture should report one diagnostic");
		io::eprintfn("assembly_probe: error: %s", f.diagnostics.messages[0].text);
		f.free();
		return 1;
	}
	assembly::Assembly output = assembly::gen_asm(&f.tree)!!;
	int status = 0;
	if (catch io::write_all(io::stdout(), output.data.str_view())) status = 1;
	if (status == 0)
	{
		if (catch io::write_all(io::stdout(), output.text.str_view())) status = 1;
	}
	output.free();
	f.free();
	return status;
}
