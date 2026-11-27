// Tests for the c3 frontend parser core: ParseContext token handling
// (parser.c3), the inline diagnostics (diagnostics_inline.c3), symtab globals,
// builtin types, and the ast / expr / number helpers. Expected values and
// message text come from c3c (src/compiler/*.c at 54bab366a). The grammar
// files are stubs, so only lexer-driven paths are exercised.
module c3_parser_core_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;
import aro::frontend::c3::lexer;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn ParseContext* open_context(ParseContext* c, String source)
{
	SourceFile* file = compiler::source_file_text_load("test.c3", source);
	*c = { .unit = compiler::unit_create(file) };
	compiler::parse_context_lexer_init(c, file);
	// Prime everything (c3c parse_translation_unit).
	compiler::advance(c);
	compiler::advance(c);
	return c;
}

fn Report* last_report() => &compiler::global_diagnostics.reports[^1];

module c3_parser_core_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;
import aro::frontend::c3::lexer;

fn void advance_and_expect()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ParseContext pc;
	ParseContext* c = open_context(&pc, "module foo;\nint x = 3;");
	test::eq(c.tok, TokenType.MODULE);
	test::eq(compiler::peek(c), TokenType.IDENT);
	assert(compiler::expect(c, MODULE));
	compiler::advance_and_verify(c, MODULE);
	test::eq(compiler::symstr(c), "foo");
	check(c.prev_span.col, 1);
	check(c.span.col, 8);
	assert(compiler::expect_advance(c, IDENT));
	assert(compiler::consume_eos(c));
	assert(compiler::tok_is(c, INT));
	check(c.span.row, 2);
	assert(!compiler::try_consume(c, IDENT));
	check(compiler::compiler.context.errors_found, 0);
	// `int` is not an identifier: c3c `expect` reports at the current token.
	assert(!compiler::expect(c, IDENT));
	check(compiler::compiler.context.errors_found, 1);
	Report* r = last_report();
	test::eq(r.text, "Expected 'IDENT'.");
	test::eq(r.severity, Severity.ERROR);
	check(r.span.row, 2);
	check(r.span.col, 1);
	check(r.span.length, 3);
	// The interned identifier is shared with the symtab.
	compiler::advance(c);
	TokenType type = INVALID_TOKEN;
	test::eq(compiler::symstr(c).ptr, compiler::symtab_find("x", &type).ptr);
	test::eq(type, TokenType.IDENT);
}

fn void consume_messages()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ParseContext pc;
	ParseContext* c = open_context(&pc, "foo bar");
	compiler::advance(c);
	// CONSUME_EOS_OR_RET: "Expected ';'" just after the previous token.
	assert(!compiler::consume_eos(c));
	Report* r = last_report();
	test::eq(r.text, "Expected ';'");
	check(r.span.col, 4);
	check(r.span.length, 1);
	assert(!compiler::@consume(c, LPAREN, "Expected '(' after %s.", "bar"));
	test::eq(last_report().text, "Expected '(' after bar.");
	check(last_report().span.col, 5);
	assert(compiler::@consume(c, IDENT, "unused"));
	test::eq(c.tok, TokenType.EOF);
	// advance() stops at EOF.
	compiler::advance(c);
	test::eq(c.tok, TokenType.EOF);
	check(compiler::compiler.context.errors_found, 2);
}

fn void expect_ident_messages()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ParseContext pc;
	ParseContext* c = open_context(&pc, "Foo int while");
	assert(!compiler::expect_ident(c, "variable name"));
	test::eq(last_report().text, "A variable name cannot start with a capital letter.");
	compiler::advance(c);
	assert(!compiler::expect_ident(c, "variable name"));
	test::eq(last_report().text, "A type cannot be used as a variable name, you must use a different identifier.");
	compiler::advance(c);
	assert(!compiler::expect_ident(c, "variable name"));
	test::eq(last_report().text, "You cannot use a keyword as variable name, pick something else please.");
	assert(compiler::parse_next_may_be_type_or_ident(c) == false);
	assert(compiler::token_is_keyword(WHILE) && !compiler::token_is_keyword(INT));
	assert(compiler::token_is_keyword_ident(INT));
	assert(compiler::token_is_param_name(HASH_IDENT) && !compiler::token_is_param_name(CONST_IDENT));
	assert(compiler::token_is_some_ident(CONST_IDENT));
}

fn void lexer_errors_count()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ParseContext pc;
	ParseContext* c = open_context(&pc, "int x = 0b12;\nint y;");
	while (!compiler::tok_is(c, EOF)) compiler::advance(c);
	check(compiler::compiler.context.errors_found, 1);
	test::eq(compiler::global_diagnostics.reports[0].diag, Diagnostic.LEX_BINARY_DIGITS);
}

fn void inline_macros()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	SourceFile* file = compiler::source_file_text_load("inline.c3", "abc\n\"x\ny\" z");
	SourceSpan span = { .file_id = file.file_id, .row = 1, .col = 2, .offset = 1, .length = 2 };
	SourceLocId loc = compiler::make_loc(span);
	assert(!compiler::@print_error_at(loc, "Bad %s number %d ('%c').", "thing", 3, 'q'));
	Report* r = last_report();
	test::eq(r.text, "Bad thing number 3 ('q').");
	test::eq(r.diag, Diagnostic.INLINE_TEXT);
	check(r.span.col, 2);
	check(r.span.offset, 1);
	check(compiler::compiler.context.errors_found, 1);

	compiler::@sema_warning_at(loc, "Warn %d", 7);
	test::eq(last_report().text, "Warn 7");
	test::eq(last_report().severity, Severity.WARNING);
	compiler::@sema_note_prev_at(loc, "The previous use of '%s' was here.", "abc");
	test::eq(last_report().severity, Severity.NOTE);
	check(compiler::compiler.context.errors_found, 1);

	assert(!compiler::@sema_error_at(null, loc, "'%s' would shadow a previous declaration.", "abc"));
	check(compiler::compiler.context.errors_found, 2);

	// print_error_after on a two-line string token lands on its last row.
	SourceSpan str = { .file_id = file.file_id, .row = 2, .col = 1, .offset = 4, .length = 5 };
	compiler::@print_error_after(&str, "Expected ';'");
	r = last_report();
	check(r.span.row, 3);
	check(r.span.col, 3);
	check(r.span.offset, 9);
	check(r.span.length, 1);

	// An unlocalized error (loc 0).
	compiler::@print_error_at(0, "Nowhere.");
	check(last_report().span.row, 0);
	check(compiler::compiler.context.errors_found, 4);
	check(compiler::global_diagnostics.errors, 4);

	compiler::global_context_clear_errors();
	check(compiler::compiler.context.errors_found, 0);
}

fn void builtin_types()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Type* ti = compiler::type_int;
	check(ti.size, 4);
	check(ti.builtin.bitsize, 32);
	check(ti.builtin.abi_alignment, 4);
	check(compiler::type_char.size, 1);
	check(compiler::type_bool.builtin.bitsize, 8);
	check(compiler::type_long.size, 8);
	check(compiler::type_i128.size, 16);
	check(compiler::type_i128.builtin.abi_alignment, 16);
	check(compiler::type_float16.size, 2);
	check(compiler::type_double.builtin.abi_alignment, 8);
	check(compiler::type_voidptr.size, 8);
	check(compiler::type_typeid.size, 8);
	check(compiler::type_any.size, 16);
	check(compiler::type_size(compiler::type_usz), 8);
	assert(compiler::type_usz.canonical == compiler::type_ulong);
	assert(compiler::type_sz.canonical == compiler::type_long);
	test::eq(compiler::type_usz.type_kind, TypeKind.ALIAS);
	check(compiler::type_size(compiler::type_chars), 16);
	test::eq(compiler::type_chars.name, "char[]");
	test::eq(compiler::type_string.name, "String");
	test::eq(compiler::type_string.type_kind, TypeKind.TYPEDEF);
	assert(compiler::type_from_token(INT) == ti);
	assert(compiler::type_from_token(USZ) == compiler::type_usz);
	assert(compiler::type_is_void(compiler::type_void));
	assert(compiler::type_is_user_defined(compiler::type_string));
	assert(!compiler::type_is_valid_for_array(compiler::type_void));
	assert(compiler::type_is_valid_for_array(ti));

	Type* ptr = compiler::type_get_ptr(ti);
	test::eq(ptr.name, "int*");
	assert(compiler::type_get_ptr(ti) == ptr);
	assert(compiler::type_get_ptr(compiler::type_void) == compiler::type_voidptr);
	Type* arr = compiler::type_get_array(ti, 4);
	test::eq(arr.name, "int[4]");
	check(compiler::type_size(arr), 16);
	assert(compiler::type_get_array(ti, 4) == arr);
	assert(compiler::type_get_array(ti, 5) != arr);
	test::eq(compiler::type_get_optional(ti).name, "int?");
	test::eq(compiler::type_get_slice(ptr).name, "int*[]");
	// An alias keeps its own name and points its canonical at the target.
	Type* usz_ptr = compiler::type_get_ptr(compiler::type_usz);
	test::eq(usz_ptr.name, "usz*");
	assert(usz_ptr.canonical == compiler::type_get_ptr(compiler::type_ulong));
	test::eq(compiler::type_quoted_error_string(compiler::type_usz), "'usz' (ulong)");
	test::eq(compiler::type_quoted_error_string(arr), "'int[4]'");
	check(compiler::type_alloca_alignment(arr), 16);
	check(compiler::type_abi_alignment(arr), 4);
	assert(compiler::type_cint == null);
	compiler::type_init_cint();
	assert(compiler::type_cint == ti);
	check(compiler::compiler.platform.width_c_int, 32);
	// type_setup registered String in the core unit / module.
	Module* core = compiler::compiler.context.core_module;
	test::eq(core.name.module_name, "std::core");
	test::eq(core.short_path, "core");
	assert(compiler::module_find_symbol(core, compiler::type_string.name) == compiler::type_string.decl);
}

fn void operator_tables()
{
	test::eq(compiler::binaryop_from_token(PLUS), BinaryOp.ADD);
	test::eq(compiler::binaryop_from_token(EQ), BinaryOp.ASSIGN);
	test::eq(compiler::binaryop_from_token(QUESTQUEST), BinaryOp.ELSE);
	test::eq(compiler::binaryop_from_token(SHL_ASSIGN), BinaryOp.SHL_ASSIGN);
	test::eq(compiler::binaryop_from_token(LPAREN), BinaryOp.ERROR);
	test::eq(compiler::binaryop_to_token(BinaryOp.SUB), TokenType.MINUS);
	test::eq(compiler::binaryop_to_token(BinaryOp.VEC_EQ), TokenType.INVALID_TOKEN);
	test::eq(compiler::binaryop_assign_base_op(BinaryOp.MULT_ASSIGN), BinaryOp.MULT);
	test::eq(compiler::binaryop_assign_base_op(BinaryOp.ADD), BinaryOp.ERROR);
	test::eq(compiler::unaryop_from_token(BANGBANG), UnaryOp.NOT);
	test::eq(compiler::unaryop_from_token(AND), UnaryOp.TADDR);
	test::eq(compiler::unaryop_from_token(EQ), UnaryOp.ERROR);
}

fn void symtab_globals()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	TokenType type = IDENT;
	test::eq(compiler::kw_return.ptr, compiler::symtab_add("return", &type).ptr);
	test::eq(type, TokenType.RETURN);
	test::eq(compiler::kw_main, "main");
	test::eq(compiler::kw_len, "len");
	test::eq(compiler::kw_std__core, "std::core");
	test::eq(compiler::kw_at_param, "@param");
	type = IDENT;
	compiler::symtab_add("@param", &type);
	test::eq(type, TokenType.AT_IDENT);
	type = IDENT;
	compiler::symtab_add("DATE", &type);
	test::eq(type, TokenType.CONST_IDENT);
	test::eq(compiler::builtin_defines[BuiltinDefine.DEF_FILE.ordinal], "FILE");
	test::eq(compiler::builtin_list[BuiltinFunction.MEMCOPY.ordinal], "memcpy");
	test::eq(compiler::builtin_list[BuiltinFunction.MAX.ordinal].ptr, compiler::type_property_list[TypeProperty.PROPERTY_MAX.ordinal].ptr);
	test::eq(compiler::type_property_list[TypeProperty.PROPERTY_LEN.ordinal].ptr, compiler::kw_len.ptr);
	TokenType found;
	assert(compiler::symtab_find("never_interned_name", &found).ptr == null);

	test::eq(compiler::attribute_by_name(compiler::kw_at_pure), AttributeType.PURE);
	type = AT_IDENT;
	test::eq(compiler::attribute_by_name(compiler::symtab_add("@inline", &type)), AttributeType.INLINE);
	test::eq(compiler::attribute_by_name(compiler::attribute_list[AttributeType.WINMAIN.ordinal]), AttributeType.WINMAIN);
	// Lookup is by interned pointer, like c3c.
	String copy = "@inline".tcopy();
	test::eq(compiler::attribute_by_name(copy), AttributeType.NONE);
}

fn void decl_and_ast_helpers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Decl* d = compiler::decl_new_var("x", 0, null, LOCAL);
	test::eq(compiler::decl_to_a_name(d), "a variable");
	test::eq(compiler::decl_to_name(d), "variable");
	d.var_decl.kind = UNWRAPPED;
	test::eq(compiler::decl_to_name(d), "unwrapped variable");
	assert(compiler::decl_ok(d));
	assert(!compiler::decl_poison(d));
	assert(!compiler::decl_ok(d));
	assert(compiler::decl_ok(null));
	assert(!compiler::decl_ok(compiler::poisoned_decl));
	assert(!compiler::expr_ok(compiler::poisoned_expr));
	assert(!compiler::ast_ok(compiler::poisoned_ast));
	assert(!compiler::type_info_ok(compiler::poisoned_type_info));

	Decl* s = compiler::decl_new_with_type("Foo", null, STRUCT);
	test::eq(s.type.type_kind, TypeKind.STRUCT);
	assert(s.type.decl == s && s.type.canonical == s.type);
	test::eq(compiler::decl_to_a_name(s), "a struct");

	AstId first;
	AstId* next = &first;
	Ast* a = compiler::new_ast(EXPR_STMT, 0);
	Ast* b = compiler::new_ast(NOP_STMT, 0);
	compiler::ast_append(&next, a);
	compiler::ast_append(&next, b);
	assert(compiler::astptr(first) == a && compiler::astptr(a.next) == b);
	assert(compiler::ast_last(a) == b);

	TypeInfo* ti = compiler::type_info_new_base(compiler::type_int, 0);
	test::eq(ti.resolve_status, ResolveStatus.DONE);
	test::eq(compiler::type_info_new(INFO_POINTER, 0).resolve_status, ResolveStatus.NOT_DONE);
}

fn void expr_constants()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Expr* e = compiler::expr_new_const_int(0, compiler::type_int, (ulong)-5);
	assert(compiler::expr_is_const_int(e));
	assert(e.const_expr.ixx.i == (uint128)(int128)-5);
	test::eq(compiler::int_to_str(e.const_expr.ixx, 10, false), "-5");
	Expr* u = compiler::expr_new_const_int(0, compiler::type_ulong, ulong::max);
	assert(u.const_expr.ixx.i == (uint128)ulong::max);
	test::eq(compiler::int_to_str(u.const_expr.ixx, 16, true), "0xFFFFFFFFFFFFFFFF");
	test::eq(compiler::i128_to_string(5, 2, false, true), "0b101");
	assert(compiler::int_fits(e.const_expr.ixx, I8));
	assert(!compiler::int_fits(e.const_expr.ixx, U8));
	assert(!compiler::int_fits(u.const_expr.ixx, I64));
	assert(compiler::int_comp(e.const_expr.ixx, u.const_expr.ixx, LT));

	Expr* s = compiler::expr_new_const_string(0, "hello");
	assert(compiler::expr_is_const_string(s));
	check(s.const_expr.bytes.len, 5);
	assert(s.type == compiler::type_string);
	Expr* bin = compiler::expr_new_binary(0, e, u, ADD);
	assert(compiler::exprptr(bin.binary_expr.left) == e);
	Expr* id = compiler::expr_new(UNRESOLVED_IDENTIFIER, 0);
	assert(compiler::expr_is_plain_identifier(id));
	assert(compiler::expr_new_const_bool(0, compiler::type_bool, true).const_expr.b);
	test::eq(compiler::expr_new_expr(CALL, e).loc, e.loc);
}

fn void floats()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	String err;
	Float f = compiler::float_from_string("1_5.25e2", &err);
	test::eq(f.type, TypeKind.F64);
	assert(f.f == 1525.0);
	f = compiler::float_from_string("2.5f", &err);
	test::eq(f.type, TypeKind.F32);
	assert(f.f == 2.5);
	f = compiler::float_from_hex("0x1.8p1", &err);
	assert(f.f == 3.0);
	f = compiler::float_from_hex("0x1.8", &err);
	test::eq(f.type, TypeKind.POISONED);
	test::eq(err, "Hex floating points must end with 'p' or 'P' and a valid exponent, e.g. 0x1.0p10 or 0x1.0P10.");
	f = compiler::float_from_string("1e999", &err);
	test::eq(f.type, TypeKind.POISONED);
	test::eq(err, "The float value is out of range.");
	assert(compiler::float_round_to_type(1.0 / 3.0, F16) == 0.333251953125);
}

fn void modules_and_paths()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	ParseContext pc;
	ParseContext* c = open_context(&pc, "module x;");
	ModulePath* path = compiler::path_create_from_string("foo::bar_baz", 12, 0);
	assert(compiler::context_set_module(c, path));
	test::eq(c.unit.mod.short_path, "bar_baz");
	assert(compiler::global_context_find_module(path.module_name) == c.unit.mod);
	ModulePath* bad = compiler::path_create_from_string("Foo", 3, 0);
	assert(!compiler::check_module_name(bad));
	test::eq(last_report().text, "A module name may not have any uppercase characters, trailing, leading or double '_'");
	assert(compiler::path_create_from_string("while", 5, 0) == null);
	test::eq(last_report().text, "A module name was expected here.");
	assert(compiler::unit_add_import(c.unit, path, false, false));
	check(c.unit.imports.len, 1);

	ParseContext pc2;
	SourceFile* file = compiler::source_file_text_load("dir/My-File.c3", "");
	pc2 = { .unit = compiler::unit_create(file) };
	assert(compiler::context_set_module_from_filename(&pc2));
	test::eq(pc2.unit.mod.name.module_name, "my_file");
}

fn void scratch_and_strings()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	compiler::scratch_buffer_clear();
	compiler::scratch_buffer_append("ab");
	compiler::scratch_buffer_append_char('c');
	compiler::@scratch_buffer_printf("%d-%s", 12, "x");
	test::eq(compiler::scratch_buffer_str(), "abc12-x");
	compiler::scratch_buffer_push();
	compiler::scratch_buffer_append("inner");
	test::eq(compiler::scratch_buffer_copy(), "inner");
	compiler::scratch_buffer_pop();
	check(compiler::scratch_buffer_len(), 7);
	TokenType type = INVALID_TOKEN;
	String interned = compiler::scratch_buffer_interned_as(&type);
	test::eq(interned, "abc12-x");
	compiler::scratch_buffer_clear();
	compiler::scratch_buffer_append_remove_space("a  b\n\tc ", 8);
	test::eq(compiler::scratch_buffer_str(), "a b c");
	assert(compiler::str_is_valid_module_name("std::io"));
	assert(!compiler::str_is_valid_module_name("std::_io"));
	assert(!compiler::str_is_valid_module_name("a__b"));
	assert(!compiler::str_is_valid_module_name("ab_"));
	assert(compiler::str_is_valid_lowercase_name("abc_1"));
	assert(compiler::str_is_type("_Foo1") && !compiler::str_is_type("FOO"));
	assert(compiler::str_is_valid_constant("FOO_1"));
	test::eq(compiler::@str_printf("%s/%d", "a", 3), "a/3");
	test::eq(compiler::str_cat("ab", "cd"), "abcd");
	assert(compiler::str_has_suffix("x.c3i", ".c3i"));
}
