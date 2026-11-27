// Tests for the port of c3c parse_global.c (src/frontend/c3/parse_global.c3):
// top level declarations land in the CompilationUnit with the expected
// shape, and errors use c3c's message text verbatim. Most sources avoid
// expression / statement parsing (initializers, array lengths, bodies) so
// they only depend on parse_global.c3; `bodies_and_expressions` and
// `expression_contracts` also go through parse_expr.c3 / parse_stmt.c3.
module c3_parse_global_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;
import std::io;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

<* Parse `source` as file "src/test.c3" like c3c parse_file; returns the first unit. *>
fn CompilationUnit* parse_source(String source)
{
	SourceFile* file = compiler::source_file_text_load("src/test.c3", source);
	ParseContext pc = { .unit = compiler::unit_create(file) };
	compiler::parse_context_lexer_init(&pc, file);
	compiler::parse_translation_unit(&pc);
	return pc.unit;
}

<* Parse `source` expecting errors; returns the text of the first report. *>
fn String first_error(String source)
{
	parse_source(source);
	assert(compiler::compiler.context.errors_found > 0, "expected an error for: %s", source);
	return compiler::global_diagnostics.reports[0].text;
}

fn TypeInfo* var_type(Decl* decl) => compiler::type_infoptr(decl.var_decl.type_info);

fn void check_no_errors()
{
	if (compiler::compiler.context.errors_found)
	{
		foreach (r : compiler::global_diagnostics.reports) io::eprintfn("unexpected report: %s", r.text);
	}
	check(compiler::compiler.context.errors_found, 0);
}

module c3_parse_global_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;

fn void module_and_imports()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source("module foo::bar;\nimport std::io, std::core @public;\nimport abc @norecurse;\n");
	check_no_errors();
	test::eq(unit.mod.name.module_name, "foo::bar");
	check(unit.mod.name.len, 8);
	check(unit.imports.len, 3);
	test::eq(unit.imports[0].import_decl.path.module_name, "std::io");
	assert(!unit.imports[0].import_decl.import_private_as_public);
	test::eq(unit.imports[1].import_decl.path.module_name, "std::core");
	assert(unit.imports[1].import_decl.import_private_as_public);
	check(unit.public_imports.len, 1);
	assert(unit.imports[2].import_decl.is_non_recurse);
	check(unit.global_decls.len, 0);
	assert(!unit.module_generated);
}

fn void module_from_filename()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source("struct Foo { int a; }");
	check_no_errors();
	test::eq(unit.mod.name.module_name, "test");
	assert(unit.module_generated);
	check(unit.global_decls.len, 1);
}

fn void struct_members()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
struct Foo @packed
{
	int a, b;
	char* name;
	union { int x; float y; }
	struct inner { bool flag; }
}
union Bar { int i; double d; }
struct Sub { inline Foo foo; int[] list; Foo*[*] ptrs; }
`);
	check_no_errors();
	check(unit.global_decls.len, 3);
	Decl* foo = unit.global_decls[0];
	check(foo.decl_kind, DeclKind.STRUCT);
	test::eq(foo.name, "Foo");
	check(foo.type.type_kind, TypeKind.STRUCT);
	check(foo.attributes.len, 1);
	check(foo.attributes[0].attr_kind, AttributeType.PACKED);
	check(foo.visibility, Visibility.PUBLIC);
	Decl*[] m = foo.strukt.members;
	check(m.len, 5);
	test::eq(m[0].name, "a");
	check(m[0].var_decl.kind, VarDeclKind.MEMBER);
	TypeInfo* int_type = var_type(m[0]);
	check(int_type.kind, TypeInfoKind.INFO_IDENTIFIER);
	check(int_type.resolve_status, ResolveStatus.DONE);
	assert(int_type.type == compiler::type_int);
	test::eq(m[1].name, "b");
	assert(var_type(m[1]) == int_type);
	TypeInfo* name_type = var_type(m[2]);
	check(name_type.subtype, compiler::TYPE_COMPRESSED_PTR);
	assert(name_type.type == compiler::type_get_ptr(compiler::type_char));
	check(m[3].decl_kind, DeclKind.UNION);
	assert(m[3].name.ptr == null);
	test::eq(m[3].type.name, "Foo.3");
	check(m[3].strukt.members.len, 2);
	test::eq(m[3].strukt.members[1].name, "y");
	check(m[4].decl_kind, DeclKind.STRUCT);
	test::eq(m[4].name, "inner");
	test::eq(m[4].type.name, "Foo.inner");
	check(m[4].strukt.parent, compiler::declid(foo));

	Decl* bar = unit.global_decls[1];
	check(bar.decl_kind, DeclKind.UNION);
	check(bar.strukt.members.len, 2);

	Decl* sub = unit.global_decls[2];
	assert(sub.is_substruct);
	TypeInfo* foo_type = var_type(sub.strukt.members[0]);
	check(foo_type.kind, TypeInfoKind.INFO_IDENTIFIER);
	check(foo_type.resolve_status, ResolveStatus.NOT_DONE);
	test::eq(foo_type.unresolved.name, "Foo");
	TypeInfo* list_type = var_type(sub.strukt.members[1]);
	check(list_type.subtype, compiler::TYPE_COMPRESSED_SUB);
	assert(list_type.type == compiler::type_get_slice(compiler::type_int));
	TypeInfo* ptrs_type = var_type(sub.strukt.members[2]);
	check(ptrs_type.kind, TypeInfoKind.INFO_INFERRED_ARRAY);
	check(ptrs_type.array.base.subtype, compiler::TYPE_COMPRESSED_PTR);
}

fn void enums_faults_constsets()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
enum Color : char { RED, GREEN, BLUE, }
enum Plain { X }
faultdef NOT_FOUND, BAD_INPUT;
constdef Flags : inline int { A, B }
`);
	check_no_errors();
	check(unit.global_decls.len, 5);
	Decl* color = unit.global_decls[0];
	check(color.decl_kind, DeclKind.ENUM);
	check(color.enums.values.len, 3);
	test::eq(color.enums.values[1].name, "GREEN");
	check(color.enums.values[1].decl_kind, DeclKind.ENUM_CONSTANT);
	assert(color.enums.type_info.type == compiler::type_char);
	Decl* plain = unit.global_decls[1];
	assert(plain.enums.type_info.type == compiler::type_int);
	check(plain.enums.values.len, 1);
	check(unit.global_decls[2].decl_kind, DeclKind.FAULT);
	test::eq(unit.global_decls[2].name, "NOT_FOUND");
	test::eq(unit.global_decls[3].name, "BAD_INPUT");
	Decl* flags = unit.global_decls[4];
	check(flags.decl_kind, DeclKind.CONSTSET);
	assert(flags.is_substruct);
	check(flags.enums.values.len, 2);
	assert(flags.enums.values[0].enum_constant.is_raw);
}

fn void functions()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
extern fn int? foo(int a, char* b, ...) @weak;
extern fn void Foo.bar(&self, Foo* other);
fn void baz(int x);
extern fn void vargs(int... rest);
extern fn void anyv(args...);
fn void hidden() @private;
`);
	check_no_errors();
	check(unit.global_decls.len, 6);
	Decl* foo = unit.global_decls[0];
	check(foo.decl_kind, DeclKind.FUNC);
	test::eq(foo.name, "foo");
	assert(foo.is_extern);
	assert(foo.is_weak && foo.is_weak_link);
	TypeInfo* rtype = compiler::type_infoptr(foo.func_decl.signature.rtype);
	assert(rtype.optional);
	assert(rtype.type == compiler::type_get_optional(compiler::type_int));
	Signature* sig = &foo.func_decl.signature;
	check(sig.params.len, 3);
	test::eq(sig.params[0].name, "a");
	check(sig.params[0].var_decl.kind, VarDeclKind.PARAM);
	assert(var_type(sig.params[0]).type == compiler::type_int);
	test::eq(sig.params[1].name, "b");
	assert(sig.params[2] == null);
	check(sig.variadic, Variadic.RAW);
	check(sig.vararg_index, 2);
	assert(!sig.is_macro);

	Decl* bar = unit.global_decls[1];
	TypeInfo* parent = compiler::type_infoptr(bar.func_decl.type_parent);
	test::eq(parent.unresolved.name, "Foo");
	Decl* self = bar.func_decl.signature.params[0];
	test::eq(self.name, "self");
	assert(self.var_decl.self_addr);
	assert(self.var_decl.type_info == 0);
	check(var_type(bar.func_decl.signature.params[1]).subtype, compiler::TYPE_COMPRESSED_PTR);
	check(bar.func_decl.signature.vararg_index, 2);
	check(bar.func_decl.signature.variadic, Variadic.NONE);

	Decl* baz = unit.global_decls[2];
	assert(!baz.is_extern);
	assert(baz.is_weak);
	check(baz.func_decl.body, 0);

	Signature* vsig = &unit.global_decls[3].func_decl.signature;
	check(vsig.variadic, Variadic.TYPED);
	check(vsig.vararg_index, 0);
	assert(vsig.params[0].var_decl.vararg);

	Signature* asig = &unit.global_decls[4].func_decl.signature;
	check(asig.variadic, Variadic.ANY);
	assert(var_type(asig.params[0]).type == compiler::type_any);

	check(unit.global_decls[5].visibility, Visibility.PRIVATE);
}

fn void interfaces_aliases_and_globals()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
interface Shape { fn double area(); fn void scale(double f); }
alias Callback = fn void(int a);
typedef Meters = inline double;
bitstruct Bits : char { bool a; bool b; }
alias io = module std::io;
attrdef @Hot = @inline, @noinline;
extern const int MAX;
tlocal int counter;
int g1, g2, g3 @private;
`);
	check_no_errors();
	check(unit.global_decls.len, 10);
	Decl* shape = unit.global_decls[0];
	check(shape.decl_kind, DeclKind.INTERFACE);
	check(shape.interface_methods.len, 2);
	assert(shape.interface_methods[1].func_decl.attr_interface_method);
	test::eq(shape.interface_methods[1].func_decl.signature.params[0].name, "f");

	Decl* callback = unit.global_decls[1];
	check(callback.decl_kind, DeclKind.TYPE_ALIAS);
	assert(callback.type_alias_decl.is_func);
	check(callback.type.type_kind, TypeKind.ALIAS);
	Decl* fntype = callback.type_alias_decl.decl;
	check(fntype.decl_kind, DeclKind.FNTYPE);
	check(fntype.fntype_decl.signature.params.len, 1);
	assert(compiler::type_infoptr(fntype.fntype_decl.signature.rtype).type == compiler::type_void);

	Decl* meters = unit.global_decls[2];
	check(meters.decl_kind, DeclKind.TYPEDEF);
	assert(meters.is_substruct);
	assert(meters.distinct.type == compiler::type_double);

	Decl* bits = unit.global_decls[3];
	check(bits.decl_kind, DeclKind.BITSTRUCT);
	assert(bits.strukt.container_type.type == compiler::type_char);
	assert(bits.strukt.consecutive);
	check(bits.strukt.members.len, 2);
	check(bits.strukt.members[1].var_decl.start_bit, 1);

	check(unit.module_aliases.len, 1);
	Decl* io_alias = unit.module_aliases[0];
	check(io_alias.decl_kind, DeclKind.ALIAS_PATH);
	test::eq(io_alias.name, "io");
	test::eq(io_alias.module_alias_decl.alias_path.module_name, "std::io");

	Decl* hot = unit.global_decls[4];
	check(hot.decl_kind, DeclKind.ATTRIBUTE);
	test::eq(hot.name, "@Hot");
	check(hot.attr_decl.attrs.len, 2);
	check(hot.attr_decl.attrs[1].attr_kind, AttributeType.NOINLINE);

	Decl* max = unit.global_decls[5];
	check(max.var_decl.kind, VarDeclKind.CONST);
	assert(max.is_extern);
	assert(max.var_decl.init_expr == null);

	Decl* counter = unit.global_decls[6];
	check(counter.var_decl.kind, VarDeclKind.GLOBAL);
	assert(counter.var_decl.is_threadlocal);

	// `int g1, g2, g3 @private;` is a DECL_GROUP flattened by add_decl_to_list.
	test::eq(unit.global_decls[7].name, "g1");
	test::eq(unit.global_decls[9].name, "g3");
	check(unit.global_decls[9].visibility, Visibility.PRIVATE);
	check(unit.global_decls[7].attributes.len, 0);
}

fn void generics()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module foo <Type, SIZE>;
struct List { Type* items; }
module foo::bar;
struct Pair <Ta, Tb> { Ta a; Tb b; }
struct Other <Ta, Tb> { Ta x; }
struct Single <Ta> { Ta x; }
struct Plain { int x; }
`);
	check_no_errors();
	Decl* section = unit.default_generic_section;
	assert(section != null);
	check(section.decl_kind, DeclKind.GENERIC);
	check(section.generic_decl.parameters.len, 2);
	test::eq(section.generic_decl.parameters[1], "SIZE");
	check(unit.generic_decls.len, 1);
	// Templates go to their generic section, not the unit.
	check(unit.global_decls.len, 0);
	check(section.generic_decl.decls.len, 1);
	Decl* list = section.generic_decl.decls[0];
	test::eq(list.name, "List");
	assert(list.is_template);
	check(list.generic_id, compiler::declid(section));

	TokenType type = INVALID_TOKEN;
	Module* bar = compiler::global_context_find_module(compiler::symtab_find("foo::bar", &type));
	assert(bar != null);
	check(bar.units.len, 1);
	CompilationUnit* unit2 = bar.units[0];
	check(unit2.generic_decls.len, 3);
	check(bar.generic_sections.len, 3);
	Decl* pair_section = unit2.generic_decls[0];
	Decl* other_section = unit2.generic_decls[1];
	Decl* single_section = unit2.generic_decls[2];
	// Same parameter names unify to the same generic id.
	check(pair_section.generic_decl.id, other_section.generic_decl.id);
	assert(pair_section.generic_decl.id != single_section.generic_decl.id);
	assert(pair_section.generic_decl.id != section.generic_decl.id);
	check(pair_section.generic_decl.decls.len, 1);
	test::eq(pair_section.generic_decl.decls[0].name, "Pair");
	check(unit2.global_decls.len, 1);
	test::eq(unit2.global_decls[0].name, "Plain");
}

fn void contracts()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
<* @pure *>
extern fn void foo();
<* @deprecated *>
extern fn void bar();
<*
 Some description.
*>
extern fn void baz();
`);
	check_no_errors();
	check(unit.global_decls.len, 3);
	Decl* foo = unit.global_decls[0];
	assert(foo.docs != 0);
	Decl* foo_docs = compiler::declptr(foo.docs);
	check(foo_docs.decl_kind, DeclKind.CONTRACT);
	assert(foo_docs.contracts_decl.pure);
	Decl* bar = unit.global_decls[1];
	check(bar.attributes.len, 1);
	check(bar.attributes[0].attr_kind, AttributeType.DEPRECATED);
	Decl* baz = unit.global_decls[2];
	assert(baz.docs != 0);
	assert(compiler::declptr(baz.docs).contracts_decl.comment.contains("Some description."));
	assert(!compiler::declptr(baz.docs).contracts_decl.pure);
}

fn void error_messages()
{
	String[2][*] cases = {
		{ "struct foo { int a; }", "Names of structs must start with an uppercase letter." },
		{ "enum FOO { A }", "Names of enums cannot be all uppercase." },
		{ "enum Foo { }", "An enum must have at least one value." },
		{ "enum Foo { A, A }", "This enum constant is declared twice." },
		{ "extern fn void foo() @public @private;", "Only a single visibility attribute may be added." },
		{ "struct Foo @packed @packed { int a; }", "Repeat of attribute '@packed' here." },
		{ "module \"foo\";", "'module' should be followed by a plain identifier, not a string. Did you accidentally put the module name between \"\"?" },
		{ "import ;", "Import statement should be followed by the name of the module to import." },
		{ "struct Foo <> { int a; }", "The generic parameter list cannot be empty, it needs at least one element." },
		{ "extern fn void foo(int ABC);", "Parameter names may not be all uppercase." },
		{ "extern fn void foo() {}", "An 'extern' function may not have a body." },
		{ "int FOO;", "This looks like a constant variable, did you forget 'const'?" },
		{ ";", "';' wasn't expected here, try removing it." },
		{ "<* @param x *> struct Foo { int a; }", "Contracts can only be used with generic declarations and modules." },
		{ "<* @pure *> import std::io;", "Contracts are only used for modules, functions and macros." },
		{ "fn void @foo();", "Expected a function name here, e.g. 'someName'." },
		{ "struct Foo { int a, int b; }", "Did you accidentally use ',' rather than ';' between your declarations?" },
		{ "struct Foo { inline int a, b; }", "'inline' can only be applied to a single member, so please define it on its own line." },
		{ "fn void foo(int a, int a...);", "For typed vaargs '...', needs to appear after the type." },
		{ "fn void foo(int... a, int... b);", "Only a single variadic parameter is allowed." },
		{ "fn void foo(int x @public);", "'@public' cannot be used here." },
		{ "alias foo = fn void();", "This looks like you're declaring a function type alias, and such an alias must have a valid type name, like 'Callback'." },
		{ "import std::io @local;", "Only '@public' and '@norecurse' are valid attributes here." },
	};
	foreach (pair : cases)
	{
		compiler::compiler_reset();
		test::eq(first_error(pair[0]), pair[1]);
		compiler::compiler_free();
	}
}

fn void error_location()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	String text = first_error("module test;\nstruct foo { int a; }");
	test::eq(text, "Names of structs must start with an uppercase letter.");
	Report* r = &compiler::global_diagnostics.reports[0];
	check(r.severity, Severity.ERROR);
	check(r.span.row, 2);
	check(r.span.col, 8);
	check(r.span.length, 3);
	// The note of a duplicate enum constant points at the first one.
	compiler::compiler_free();
	compiler::compiler_reset();
	first_error("enum Foo { A, B, A }");
	check(compiler::global_diagnostics.reports.len(), 2);
	Report* note = &compiler::global_diagnostics.reports[1];
	check(note.severity, Severity.NOTE);
	test::eq(note.text, "The previous declaration was here.");
	check(note.span.col, 12);
}

fn void bodies_and_expressions()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
const int SIZE = 4;
int[SIZE] arr;
fn int add(int a, int b = 2) { return a + b; }
fn int twice(int x) => x * 2;
macro @swap(#a, #b) { var tmp = #a; #a = #b; #b = tmp; }
macro max(x, y; @body(it)) { @body(x); }
alias Num = int;
alias add2 = add;
enum Op : int (String name) { ADD { "add" }, SUB { "sub" } }
bitstruct Flags : uint { bool a : 0; uint b : 1..3; }
struct Vec @align(16) { float x; }
fn Vec Vec.plus(self, Vec o) @operator(+) => self;
$assert(SIZE == 4);
typedef Aligned = int @align(8);
int[<4>] vec;
`);
	check_no_errors();
	check(unit.global_decls.len, 15);
	Decl*[] d = unit.global_decls;
	check(d[0].var_decl.kind, VarDeclKind.CONST);
	assert(d[0].var_decl.init_expr != null);
	TypeInfo* arr_type = var_type(d[1]);
	check(arr_type.kind, TypeInfoKind.INFO_ARRAY);
	assert(arr_type.array.len != null);
	check(d[2].decl_kind, DeclKind.FUNC);
	assert(d[2].func_decl.body != 0);
	assert(d[2].func_decl.signature.params[1].var_decl.init_expr != null);
	assert(d[3].func_decl.body != 0);
	check(d[4].decl_kind, DeclKind.MACRO);
	test::eq(d[4].name, "@swap");
	assert(d[4].func_decl.signature.is_macro && d[4].func_decl.signature.is_at_macro);
	check(d[4].func_decl.signature.params[0].var_decl.kind, VarDeclKind.PARAM_EXPR);
	check(d[4].func_decl.body_param, 0);
	Decl* max = d[5];
	assert(!max.func_decl.signature.is_at_macro);
	check(max.func_decl.signature.params.len, 2);
	assert(max.func_decl.body_param != 0);
	Decl* body_param = compiler::declptr(max.func_decl.body_param);
	test::eq(body_param.name, "@body");
	check(body_param.body_params.len, 1);
	check(d[6].decl_kind, DeclKind.TYPE_ALIAS);
	assert(!d[6].type_alias_decl.is_func);
	assert(d[6].type_alias_decl.type_expr != null);
	check(d[7].decl_kind, DeclKind.ALIAS);
	assert(d[7].define_decl.alias_expr != null);
	Decl* op = d[8];
	check(op.enums.parameters.len, 1);
	test::eq(op.enums.parameters[0].name, "name");
	check(op.enums.values.len, 2);
	check(op.enums.values[1].enum_constant.associated.len, 1);
	Decl* flags = d[9];
	assert(!flags.strukt.consecutive);
	Decl* b = flags.strukt.members[1];
	assert(b.var_decl.bit_is_expr);
	assert(b.var_decl.start != null && b.var_decl.end != null);
	assert(flags.strukt.members[0].var_decl.end == null);
	Decl* vec_decl = d[10];
	check(vec_decl.attributes[0].attr_kind, AttributeType.ALIGN);
	check(vec_decl.attributes[0].exprs.len, 1);
	Decl* plus = d[11];
	test::eq(compiler::type_infoptr(plus.func_decl.type_parent).unresolved.name, "Vec");
	Attr* operator = plus.attributes[0];
	check(operator.attr_kind, AttributeType.OPERATOR);
	check(operator.exprs[0].expr_kind, ExprKind.OPERATOR_CHARS);
	check(operator.exprs[0].overload_expr, compiler::OVERLOAD_PLUS);
	check(d[12].decl_kind, DeclKind.CT_ASSERT);
	assert(d[12].ct_assert_decl != null);
	check(d[13].decl_kind, DeclKind.TYPEDEF);
	assert(d[13].distinct_align != null);
	check(var_type(d[14]).kind, TypeInfoKind.INFO_VECTOR);
}

fn void expression_contracts()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source(`module test;
<*
 Adds.
 @param [in] a : "the a"
 @require a > 0 : "positive"
 @ensure return > 0
*>
fn int f(int a) => a;
`);
	check_no_errors();
	Decl* f = unit.global_decls[0];
	ContractsDecl* docs = &compiler::declptr(f.docs).contracts_decl;
	check(docs.params.len, 1);
	test::eq(docs.params[0].name, "a");
	check(docs.params[0].modifier, InOutModifier.IN);
	test::eq(docs.params[0].description, "the a");
	check(docs.requires.len, 1);
	test::eq(docs.requires[0].contract_expr.expr_string, "a > 0");
	test::eq(docs.requires[0].contract_expr.comment, "positive");
	check(docs.ensures.len, 1);
	test::eq(docs.ensures[0].contract_expr.expr_string, "return > 0");
}

fn void expression_error_messages()
{
	String[2][*] cases = {
		{ "int a, b = 1;", "Initialization is not allowed with multiple declarations." },
		{ "enum Foo : int (int x) { A { x: 1 } }", "This looks like a named param call, but that style of declaration is not supported for declaring enum associated values." },
		{ "bitstruct Foo : int { bool a; bool b : 1; }", "Bitstructs either have bit ranges for all members, or no members have ranges – mixing is not permitted. Either remove this range, or add ranges to all other members." },
		{ "struct Foo { int a; } fn void Foo.x(self) @operator(!=) {}", "For comparisons, use '<' and '==', other comparison operations will be derived from those." },
		{ "fn void f() @if(true) @if(true) {}", "Repeat of attribute '@if' here." },
		{ "<* @require true \"positive\" *> fn void f() {}", "Expected a ':' before the description." },
		{ "<* @param x *> module foo <Type>;", "Invalid constraint - only '@require' is valid for generic declarations and modules." },
	};
	foreach (pair : cases)
	{
		compiler::compiler_reset();
		test::eq(first_error(pair[0]), pair[1]);
		compiler::compiler_free();
	}
}

fn void generic_module_requires()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	CompilationUnit* unit = parse_source("<* @require $defined(Type) *>\nmodule foo <Type>;\nstruct Box { Type value; }\n");
	check_no_errors();
	Decl* section = unit.default_generic_section;
	check(section.generic_decl.requires.len, 1);
	check(section.generic_decl.requires[0].expr_kind, ExprKind.CONTRACT);
	check(section.generic_decl.decls.len, 1);
}
