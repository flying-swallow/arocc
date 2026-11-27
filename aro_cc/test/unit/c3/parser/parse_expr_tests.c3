// Tests for the c3 frontend expression and statement parsers (parse_expr.c3,
// parse_stmt.c3): AST shapes and diagnostics for small sources fed through
// parse_expr / parse_stmt on a ParseContext primed like c3c's
// parse_translation_unit. Expected message text comes from c3c
// (src/compiler/parse_expr.c, parse_stmt.c at 54bab366a).
//
// Lowercase identifiers, types (casts, compound literals, declarations) and
// conditions (if / while / switch (x)) route through parse_global.c3
// (parse_path_prefix, parse_optional_type, parse_decl_or_expr); those cases
// are in the `*_global` tests.
module c3_parse_expr_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

ParseContext g_context;

fn ParseContext* open_context(String source)
{
	compiler::compiler_reset();
	ParseContext* c = &g_context;
	SourceFile* file = compiler::source_file_text_load("test.c3", source);
	*c = { .unit = compiler::unit_create(file) };
	compiler::parse_context_lexer_init(c, file);
	// Prime everything (c3c parse_translation_unit).
	compiler::advance(c);
	compiler::advance(c);
	return c;
}

<* Parse `source` as one expression; it must succeed and consume everything. *>
fn Expr* expr_of(String source)
{
	ParseContext* c = open_context(source);
	Expr* e = compiler::parse_expr(c);
	assert(compiler::expr_ok(e), "parse failed: %s", source);
	test::eq(c.tok, TokenType.EOF);
	check(compiler::compiler.context.errors_found, 0);
	return e;
}

<* Parse `source` as one statement; it must succeed and consume everything. *>
fn Ast* stmt_of(String source)
{
	ParseContext* c = open_context(source);
	Ast* a = compiler::parse_stmt(c);
	assert(compiler::ast_ok(a), "parse failed: %s", source);
	test::eq(c.tok, TokenType.EOF);
	check(compiler::compiler.context.errors_found, 0);
	return a;
}

<* The first error report (later reports are follow-on notes or errors). *>
fn String first_error()
{
	foreach (&r : compiler::global_diagnostics.reports)
	{
		if (r.severity == Severity.ERROR) return r.text;
	}
	return "<no error>";
}

<* Parse `source` as an expression, expecting failure with `message` as the first error. *>
fn void expr_error(String source, String message)
{
	ParseContext* c = open_context(source);
	Expr* e = compiler::parse_expr(c);
	assert(!compiler::expr_ok(e), "parse unexpectedly succeeded: %s", source);
	assert(compiler::compiler.context.errors_found > 0);
	test::eq(first_error(), message);
}

<* Parse `source` as a statement, expecting failure with `message` as the first error. *>
fn void stmt_error(String source, String message)
{
	ParseContext* c = open_context(source);
	Ast* a = compiler::parse_stmt(c);
	assert(!compiler::ast_ok(a), "parse unexpectedly succeeded: %s", source);
	assert(compiler::compiler.context.errors_found > 0);
	test::eq(first_error(), message);
}

fn Expr* left(Expr* e) => compiler::exprptr(e.binary_expr.left);
fn Expr* right(Expr* e) => compiler::exprptr(e.binary_expr.right);

fn void expect_binary(Expr* e, BinaryOp op)
{
	test::eq(e.expr_kind, ExprKind.BINARY);
	test::eq(e.binary_expr.operator, op);
}

fn void expect_int(Expr* e, long value)
{
	test::eq(e.expr_kind, ExprKind.CONST);
	test::eq(e.const_expr.const_kind, ConstKind.INTEGER);
	test::eq((long)(int128)e.const_expr.ixx.i, value);
}

fn void expect_ident(Expr* e, String name)
{
	test::eq(e.expr_kind, ExprKind.UNRESOLVED_IDENTIFIER);
	test::eq(e.unresolved_ident_expr.ident, name);
}

fn Ast* astp(AstId id) => compiler::astptr(id);

module c3_parse_expr_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics;

fn void binary_precedence()
{
	defer compiler::compiler_free();
	// * binds tighter than +.
	Expr* e = expr_of("1 + 2 * 3");
	expect_binary(e, ADD);
	expect_int(left(e), 1);
	expect_binary(right(e), MULT);
	expect_int(left(right(e)), 2);
	expect_int(right(right(e)), 3);
	// Left associative.
	e = expr_of("1 - 2 - 3");
	expect_binary(e, SUB);
	expect_binary(left(e), SUB);
	expect_int(right(e), 3);
	// Assignment is right associative.
	e = expr_of("FOO = BAR += 3");
	expect_binary(e, ASSIGN);
	expect_ident(left(e), "FOO");
	expect_binary(right(e), ADD_ASSIGN);
	// Shift > bit > relational > && > ||.
	e = expr_of("1 << 2 < 3 && 4 | 5 == 6 || 7");
	expect_binary(e, OR);
	expect_binary(left(e), AND);
	expect_binary(left(left(e)), LT);
	expect_binary(left(left(left(e))), SHL);
	expect_binary(right(left(e)), EQ);
	expect_binary(left(right(left(e))), BIT_OR);
	// ?? has its own precedence above +.
	e = expr_of("FOO ?? 1 + 2");
	expect_binary(e, ADD);
	expect_binary(left(e), ELSE);
	// Grouping is kept as a flag.
	e = expr_of("(1 + 2) * 3");
	expect_binary(e, MULT);
	expect_binary(left(e), ADD);
	assert(left(e).binary_expr.grouped);
	assert(!e.binary_expr.grouped);
}

fn void integer_literals()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("0x1F");
	expect_int(e, 31);
	assert(e.const_expr.is_hex);
	test::eq(e.type, compiler::type_int);
	test::eq(e.resolve_status, ResolveStatus.DONE);
	e = expr_of("1_000");
	expect_int(e, 1000);
	assert(!e.const_expr.is_hex);
	// Decimals never become unsigned without a suffix.
	e = expr_of("3000000000");
	test::eq(e.type, compiler::type_long);
	// Hex does.
	e = expr_of("0xFFFFFFFF");
	test::eq(e.type, compiler::type_uint);
	e = expr_of("0o17");
	expect_int(e, 15);
	e = expr_of("0b101");
	expect_int(e, 5);
	e = expr_of("5u");
	test::eq(e.type, compiler::type_uint);
	e = expr_of("5L");
	test::eq(e.type, compiler::type_long);
	e = expr_of("5ULL");
	test::eq(e.type, compiler::type_u128);
	// '-' directly before an integer folds into the literal.
	e = expr_of("-5");
	expect_int(e, -5);
	test::eq(e.type, compiler::type_int);
	check(compiler::sourcelocptr(e.loc).length, 2);
	e = expr_of("-2147483648");
	test::eq(e.type, compiler::type_int);
	e = expr_of("-2147483649");
	test::eq(e.type, compiler::type_long);
}

fn void integer_literal_errors()
{
	defer compiler::compiler_free();
	expr_error("-1u", "Negating an explicitly unsigned value is not allowed, but you can place the value inside of (), like -(1).");
	expr_error("999999999999999999999999999999999999999999", "Integer size exceeded 128 bits, max 128 bits are supported.");
	// A suffix sets the smallest size; decimals stay signed and c3c prints the value as signed.
	test::eq(expr_of("0x1FFFFFFFFFFFFFFFFL").type, compiler::type_i128);
	expr_error("200000000000000000000000000000000000000L", "'-140282366920938463463374607431768211456' does not fit in a 'i64' literal.");
	expr_error("200000000000000000000000000000000000000", "'200000000000000000000000000000000000000' does not fit in a signed integer literal, but you can try making it unsigned by appending the 'U' suffix.");
}

fn void other_literals()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("'a'");
	expect_int(e, 'a');
	assert(e.const_expr.is_character);
	test::eq(e.type, compiler::type_char);
	test::eq(e.const_expr.ixx.type, TypeKind.U8);
	e = expr_of("\"ab\" \"cd\"");
	test::eq(e.const_expr.const_kind, ConstKind.STRING);
	test::eq((String)e.const_expr.bytes.ptr[:e.const_expr.bytes.len], "abcd");
	test::eq(e.type, compiler::type_string);
	e = expr_of("true");
	test::eq(e.const_expr.const_kind, ConstKind.BOOL);
	assert(e.const_expr.b);
	test::eq(e.type, compiler::type_bool);
	e = expr_of("false");
	assert(!e.const_expr.b);
	e = expr_of("null");
	test::eq(e.const_expr.const_kind, ConstKind.POINTER);
	test::eq(e.type, compiler::type_voidptr);
	e = expr_of("1.5");
	test::eq(e.const_expr.const_kind, ConstKind.FLOAT);
	test::eq(e.type, compiler::type_double);
	test::eq(e.const_expr.fxx.f, 1.5);
	e = expr_of("x\"0aff\" x\"10\"");
	test::eq(e.const_expr.const_kind, ConstKind.BYTES);
	check(e.const_expr.bytes.len, 3);
	check(e.const_expr.bytes.ptr[0], 0x0a);
	check(e.const_expr.bytes.ptr[1], 0xff);
	check(e.const_expr.bytes.ptr[2], 0x10);
	test::eq(e.type, compiler::type_get_array(compiler::type_char, 3));
	e = expr_of("b64\"SGk=\"");
	check(e.const_expr.bytes.len, 2);
	check(e.const_expr.bytes.ptr[0], 'H');
	check(e.const_expr.bytes.ptr[1], 'i');
}

fn void unary_and_postfix()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("-FOO");
	test::eq(e.expr_kind, ExprKind.UNARY);
	test::eq(e.unary_expr.operator, UnaryOp.NEG);
	expect_ident(e.unary_expr.expr, "FOO");
	// Unary binds tighter than binary, looser than postfix.
	e = expr_of("-FOO * 2");
	expect_binary(e, MULT);
	test::eq(left(e).expr_kind, ExprKind.UNARY);
	e = expr_of("&FOO[1]");
	test::eq(e.unary_expr.operator, UnaryOp.ADDR);
	test::eq(e.unary_expr.expr.expr_kind, ExprKind.SUBSCRIPT);
	// !! as a prefix is two nots.
	e = expr_of("!!FOO");
	test::eq(e.unary_expr.operator, UnaryOp.NOT);
	test::eq(e.unary_expr.expr.expr_kind, ExprKind.UNARY);
	test::eq(e.unary_expr.expr.unary_expr.operator, UnaryOp.NOT);
	e = expr_of("FOO++");
	test::eq(e.expr_kind, ExprKind.POST_UNARY);
	test::eq(e.unary_expr.operator, UnaryOp.INC);
	e = expr_of("FOO!!");
	test::eq(e.expr_kind, ExprKind.FORCE_UNWRAP);
	e = expr_of("FOO!");
	test::eq(e.expr_kind, ExprKind.RETHROW);
	e = expr_of("FOO~");
	test::eq(e.expr_kind, ExprKind.OPTIONAL);
	expr_error("&&&FOO", "'&&&' is the compile time '&&' operator. If you want to take a temp address of an address, use () or space to clarify the intent, e.g. '&&(&a)'.");
}

fn void calls_and_access()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("FOO(1, 2 + 3)");
	test::eq(e.expr_kind, ExprKind.CALL);
	expect_ident(compiler::exprptr(e.call_expr.function), "FOO");
	check(e.call_expr.arguments.len, 2);
	expect_int(e.call_expr.arguments[0], 1);
	expect_binary(e.call_expr.arguments[1], ADD);
	check(compiler::sourcelocptr(e.loc).length, 13);
	e = expr_of("FOO()");
	check(e.call_expr.arguments.len, 0);
	// Trailing comma and named arguments.
	e = expr_of("FOO(a: 1, $b: 2,)");
	check(e.call_expr.arguments.len, 2);
	test::eq(e.call_expr.arguments[0].expr_kind, ExprKind.NAMED_ARGUMENT);
	test::eq(e.call_expr.arguments[0].named_argument_expr.name, "a");
	expect_int(e.call_expr.arguments[0].named_argument_expr.value, 1);
	test::eq(e.call_expr.arguments[1].named_argument_expr.name, "$b");
	e = expr_of("@foo(1) @inline");
	assert(e.call_expr.attr_force_inline);
	expect_ident(compiler::exprptr(e.call_expr.function), "@foo");
	e = expr_of("FOO(1)(2)");
	test::eq(compiler::exprptr(e.call_expr.function).expr_kind, ExprKind.CALL);
	e = expr_of("FOO.BAR.BAZ");
	test::eq(e.expr_kind, ExprKind.ACCESS_UNRESOLVED);
	expect_ident(e.access_unresolved_expr.child, "BAZ");
	test::eq(e.access_unresolved_expr.parent.expr_kind, ExprKind.ACCESS_UNRESOLVED);
	e = expr_of("FOO.[1]");
	test::eq(e.expr_kind, ExprKind.SUBSCRIPT);
	test::eq(compiler::exprptr(e.subscript_expr.expr).expr_kind, ExprKind.MAYBE_DEREF);
	expr_error("FOO(1) @pure @pure", "Repeat of the same attribute is not allowed.");
	expr_error("FOO(1) @inline @noinline", "@inline and @noinline cannot be combined");
	expr_error("FOO(1) @align", "Only '@pure', '@inline' and '@noinline' are valid attributes for calls.");
	expr_error("FOO(1", "Expected the ending ')' here.");
}

fn void subscripts_and_slices()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("FOO[1]");
	test::eq(e.expr_kind, ExprKind.SUBSCRIPT);
	expect_int(compiler::exprptr(e.subscript_expr.index.expr), 1);
	assert(!e.subscript_expr.index.start_from_end);
	e = expr_of("FOO[^1]");
	assert(e.subscript_expr.index.start_from_end);
	e = expr_of("FOO[1..2]");
	test::eq(e.expr_kind, ExprKind.SLICE);
	assert(!e.slice_expr.range.is_len);
	expect_int(compiler::exprptr(e.slice_expr.range.start), 1);
	expect_int(compiler::exprptr(e.slice_expr.range.end), 2);
	e = expr_of("FOO[..]");
	test::eq(e.expr_kind, ExprKind.SLICE);
	expect_int(compiler::exprptr(e.slice_expr.range.start), 0);
	check(e.slice_expr.range.end, 0);
	e = expr_of("FOO[2:^1]");
	assert(e.slice_expr.range.is_len);
	assert(e.slice_expr.range.end_from_end);
	expr_error("FOO[1:]", "Length-ranges using ':' may not elide the length.");
}

fn void ternary_and_elvis()
{
	defer compiler::compiler_free();
	// Right associative.
	Expr* e = expr_of("FOO ? 1 : BAR ? 2 : 3");
	test::eq(e.expr_kind, ExprKind.TERNARY);
	expect_ident(compiler::exprptr(e.ternary_expr.cond), "FOO");
	expect_int(compiler::exprptr(e.ternary_expr.then_expr), 1);
	Expr* else_expr = compiler::exprptr(e.ternary_expr.else_expr);
	test::eq(else_expr.expr_kind, ExprKind.TERNARY);
	expect_ident(compiler::exprptr(else_expr.ternary_expr.cond), "BAR");
	// The condition takes the whole || chain.
	e = expr_of("FOO || BAR ? 1 : 2");
	expect_binary(compiler::exprptr(e.ternary_expr.cond), OR);
	e = expr_of("FOO ?: 1");
	test::eq(e.expr_kind, ExprKind.TERNARY);
	check(e.ternary_expr.then_expr, 0);
	e = expr_of("FOO ??? 1 : 2");
	assert(e.ternary_expr.is_const);
	e = expr_of("(FOO ? 1 : 2)");
	assert(e.ternary_expr.grouped);
	expr_error("FOO ? 1", "Expected ':'.");
}

fn void initializer_lists()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("{ 1, 2, 3, }");
	test::eq(e.expr_kind, ExprKind.INITIALIZER_LIST);
	check(e.initializer_list.len, 3);
	e = expr_of("{}");
	test::eq(e.expr_kind, ExprKind.INITIALIZER_LIST);
	check(e.initializer_list.len, 0);
	e = expr_of("{ [0] = 1, [2..3] = 2 }");
	test::eq(e.expr_kind, ExprKind.DESIGNATED_INITIALIZER_LIST);
	check(e.designated_init.list.len, 2);
	Expr* d = e.designated_init.list[1];
	test::eq(d.expr_kind, ExprKind.DESIGNATOR);
	test::eq(d.designator_expr.path[0].kind, DesignatorType.RANGE);
	expect_int(d.designator_expr.path[0].index_end_expr, 3);
	expect_int(d.designator_expr.value, 2);
	// Splat in front of a designated list.
	e = expr_of("{ ...FOO, [0] = 1 }");
	test::eq(e.expr_kind, ExprKind.DESIGNATED_INITIALIZER_LIST);
	check(e.designated_init.list.len, 1);
	expect_ident(e.designated_init.splat, "FOO");
	expr_error("{ 1, [1] = 2 }", "You’re using both named and unnamed values in the same initializer. Try using either all '[1] = value' or all regular values — but not both together.");
	expr_error("{ [0] = 1, [0] = 2 }", "This element is assigned twice in the same initializer.");
	expr_error("{ 1 2 }", "A comma or '}' was expected here.");
}

fn void compile_time_expressions()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("$foo");
	test::eq(e.expr_kind, ExprKind.CT_IDENT);
	test::eq(e.ct_ident_expr.identifier, "$foo");
	e = expr_of("#foo");
	test::eq(e.expr_kind, ExprKind.HASH_IDENT);
	e = expr_of("$vaarg[^1]");
	test::eq(e.expr_kind, ExprKind.VAARG);
	assert(e.vaarg_index.start_from_end);
	e = expr_of("$vaarg.len");
	test::eq(e.expr_kind, ExprKind.VACOUNT);
	e = expr_of("$eval(\"a\")");
	test::eq(e.expr_kind, ExprKind.CT_EVAL);
	e = expr_of("$stringify(1 + 2)");
	test::eq(e.const_expr.const_kind, ConstKind.STRING);
	test::eq((String)e.const_expr.bytes.ptr[:e.const_expr.bytes.len], "1 + 2");
	e = expr_of("$stringify(#x)");
	test::eq(e.expr_kind, ExprKind.STRINGIFY);
	e = expr_of("$embed(\"f\", 3)");
	test::eq(e.expr_kind, ExprKind.EMBED);
	expect_int(e.embed_expr.len, 3);
	e = expr_of("lengthof(FOO)");
	test::eq(e.expr_kind, ExprKind.LENGTHOF);
	e = expr_of("$$LINE");
	test::eq(e.expr_kind, ExprKind.COMPILER_CONST);
	test::eq(e.builtin_expr.ident, "LINE");
	e = expr_of("$$foo(1)");
	test::eq(e.expr_kind, ExprKind.CALL);
	test::eq(compiler::exprptr(e.call_expr.function).expr_kind, ExprKind.BUILTIN);
	e = expr_of("$reflect(FOO)");
	test::eq(e.expr_kind, ExprKind.CT_REFLECT);
	e = expr_of("1 +++ 2");
	expect_binary(e, CT_CONCAT);
	e = expr_of("FOO &&& BAR ||| BAZ");
	expect_binary(e, CT_OR);
	expect_binary(left(e), CT_AND);
	expr_error("$vaarg.foo", "Expected '.len' after '$vaarg'");
	expr_error("$FOO", "Compile time identifiers may not be constants.");
}

fn void expression_errors()
{
	defer compiler::compiler_free();
	expr_error("1 +", "An expression was expected.");
	expr_error("while", "'while' is a keyword and not an expression, it can't be used here.");
	expr_error("try FOO", "'try' can only be used in if/while conditionals or defer, it cannot be used standalone.");
	// '{' after an expression is the generic-parameter infix rule.
	expr_error("FOO {", "An expression was expected.");
	expr_error("FOO{1 2}", "Expected '}'.");
	// A token without an infix rule ends the expression.
	ParseContext* c = open_context("FOO $vaarg");
	Expr* e = compiler::parse_expr(c);
	expect_ident(e, "FOO");
	test::eq(c.tok, TokenType.CT_VAARG);
}

fn void statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("return 1 + 2;");
	test::eq(a.ast_kind, AstKind.RETURN_STMT);
	expect_binary(a.return_stmt.expr, ADD);
	a = stmt_of("return;");
	assert(!a.return_stmt.expr);
	a = stmt_of("{ 1; FOO(2); ; }");
	test::eq(a.ast_kind, AstKind.COMPOUND_STMT);
	Ast* s = astp(a.compound_stmt.first_stmt);
	test::eq(s.ast_kind, AstKind.EXPR_STMT);
	expect_int(s.expr_stmt, 1);
	s = astp(s.next);
	test::eq(s.ast_kind, AstKind.EXPR_STMT);
	test::eq(s.expr_stmt.expr_kind, ExprKind.CALL);
	s = astp(s.next);
	test::eq(s.ast_kind, AstKind.NOP_STMT);
	check(s.next, 0);
	a = stmt_of("break;");
	test::eq(a.ast_kind, AstKind.BREAK_STMT);
	assert(!a.contbreak_stmt.is_label);
	a = stmt_of("continue FOO;");
	test::eq(a.ast_kind, AstKind.CONTINUE_STMT);
	assert(a.contbreak_stmt.is_label);
	test::eq(a.contbreak_stmt.label.name, "FOO");
	a = stmt_of("nextcase 3;");
	test::eq(a.ast_kind, AstKind.NEXTCASE_STMT);
	expect_int(compiler::exprptr(a.nextcase_stmt.expr), 3);
	a = stmt_of("nextcase FOO: default;");
	assert(a.nextcase_stmt.is_default);
	test::eq(a.nextcase_stmt.label.name, "FOO");
	a = stmt_of("assert(FOO, \"bad %s\", 1);");
	test::eq(a.ast_kind, AstKind.ASSERT_STMT);
	check(a.assert_stmt.args.len, 1);
}

fn void loop_statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("for (;;) {}");
	test::eq(a.ast_kind, AstKind.FOR_STMT);
	check(a.for_stmt.init, 0);
	check(a.for_stmt.cond, 0);
	check(a.for_stmt.incr, 0);
	test::eq(astp(a.for_stmt.body).ast_kind, AstKind.COMPOUND_STMT);
	a = stmt_of("for FOO: (;;) 1;");
	assert(a.for_stmt.flow.label);
	test::eq(compiler::declptr(a.for_stmt.flow.label).name, "FOO");
	test::eq(compiler::declptr(a.for_stmt.flow.label).decl_kind, DeclKind.LABEL);
	// do is a for with skip_first and a constant false condition.
	a = stmt_of("do { 1; };");
	test::eq(a.ast_kind, AstKind.FOR_STMT);
	assert(a.flow.skip_first);
	Expr* cond = compiler::exprptr(a.for_stmt.cond);
	test::eq(cond.const_expr.const_kind, ConstKind.BOOL);
	assert(!cond.const_expr.b);
	a = stmt_of("do { } while (FOO < 3);");
	expect_binary(compiler::exprptr(a.for_stmt.cond), LT);
	stmt_error("for (;;)\n1;", "A single statement after 'for' must be placed on the same line, or be enclosed in {}.");
	stmt_error("for (;;)", "Reached the end of the file when expecting a statement.");
	stmt_error("{ for (;;) }", "The body of a for statement was expected here.");
	stmt_error("for FOO (;;) {}", "The name must be followed by a ':', did you forget it?");
}

fn void switch_statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("switch { case FOO > 1: 2; case 3..4: case 5: break; default: 6; }");
	test::eq(a.ast_kind, AstKind.SWITCH_STMT);
	check(a.switch_stmt.cond, 0);
	check(a.switch_stmt.cases.len, 4);
	Ast* first = a.switch_stmt.cases[0];
	test::eq(first.ast_kind, AstKind.CASE_STMT);
	expect_binary(compiler::exprptr(first.case_stmt.expr), GT);
	test::eq(first.case_stmt.body.ast_kind, AstKind.COMPOUND_STMT);
	Ast* range = a.switch_stmt.cases[1];
	expect_int(compiler::exprptr(range.case_stmt.to_expr), 4);
	// Empty case falls through: no body.
	assert(!range.case_stmt.body);
	check(a.switch_stmt.cases[2].case_stmt.index, 2);
	test::eq(a.switch_stmt.cases[3].ast_kind, AstKind.DEFAULT_STMT);
	a = stmt_of("switch @jump { default: }");
	assert(a.switch_stmt.flow.jump);
	stmt_error("switch { 1; }", "A 'case' or 'default' would be needed here.");
	stmt_error("switch { case 1 2; }", "Missing ':' after case");
	stmt_error("switch { case 1:\n\ncase 2: break; }", "Fallthrough cases with empty rows or comments have unclear meaning, an explicit 'break' or 'nextcase' is needed (or remove the spacing!).");
	stmt_error("switch @foo { }", "Only '@jump' is allowed after a switch.");
	stmt_error("case 1:", "'case' was found outside of 'switch', did you mismatch a '{ }' pair?");
}

fn void defer_statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("defer { 1; }");
	test::eq(a.ast_kind, AstKind.DEFER_STMT);
	assert(!a.defer_stmt.is_try && !a.defer_stmt.is_catch);
	test::eq(astp(a.defer_stmt.body).ast_kind, AstKind.COMPOUND_STMT);
	a = stmt_of("defer try 1;");
	assert(a.defer_stmt.is_try);
	a = stmt_of("defer catch 1;");
	assert(a.defer_stmt.is_catch);
	// defer (catch err) declares err = the last fault.
	a = stmt_of("defer (catch err) 1;");
	assert(a.defer_stmt.is_catch);
	Ast* body = astp(a.defer_stmt.body);
	test::eq(body.ast_kind, AstKind.COMPOUND_STMT);
	Ast* decl = astp(body.compound_stmt.first_stmt);
	test::eq(decl.ast_kind, AstKind.DECLARE_STMT);
	test::eq(decl.declare_stmt.name, "err");
	test::eq(decl.declare_stmt.var_decl.init_expr.expr_kind, ExprKind.LAST_FAULT);
	test::eq(astp(decl.next).ast_kind, AstKind.EXPR_STMT);
	stmt_error("{ defer }", "The body of a defer statement was expected here.");
}

fn void compile_time_statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("$if 1: 2; $else 3; 4; $endif");
	test::eq(a.ast_kind, AstKind.CT_IF_STMT);
	expect_int(a.ct_if_stmt.expr, 1);
	test::eq(astp(a.ct_if_stmt.then).ast_kind, AstKind.EXPR_STMT);
	Ast* else_ast = astp(a.ct_if_stmt.elif);
	test::eq(else_ast.ast_kind, AstKind.CT_ELSE_STMT);
	assert(astp(else_ast.ct_else_stmt).next);
	a = stmt_of("$assert 1 : \"msg %s\", 2;");
	test::eq(a.ast_kind, AstKind.CT_ASSERT);
	check(a.assert_stmt.args.len, 1);
	a = stmt_of("$error \"x\";");
	test::eq(a.ast_kind, AstKind.CT_ASSERT);
	check(a.assert_stmt.expr, 0);
	a = stmt_of("$echo 1;");
	test::eq(a.ast_kind, AstKind.CT_ECHO_STMT);
	a = stmt_of("$switch: $case 1: 2; $default: 3; $endswitch");
	test::eq(a.ast_kind, AstKind.CT_SWITCH_STMT);
	check(a.ct_switch_stmt.body.len, 2);
	a = stmt_of("$foreach $i, $v : FOO: 1; $endforeach");
	test::eq(a.ast_kind, AstKind.CT_FOREACH_STMT);
	test::eq(compiler::declptr(a.ct_foreach_stmt.index).name, "$i");
	test::eq(compiler::declptr(a.ct_foreach_stmt.value).name, "$v");
	a = stmt_of("$expand(\"1\");");
	test::eq(a.ast_kind, AstKind.CT_EXPAND_STMT);
	stmt_error("$if 1: 2;", "Expected '$endif' for '$if'");
	stmt_error("$switch $case 1: $endswitch", "Expected ':' after '$switch'.");
	stmt_error("$assert 1", "Expected a ';' here.");
}

fn void asm_statements()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("asm { mov $eax, [&foo]; L1: add.q $rax, 3; }");
	test::eq(a.ast_kind, AstKind.ASM_BLOCK_STMT);
	assert(a.asm_block_stmt.is_volatile);
	Ast* s = astp(a.asm_block_stmt.block.asm_stmt);
	test::eq(s.asm_stmt.instruction, "mov");
	check(s.asm_stmt.args.len, 2);
	test::eq(s.asm_stmt.args[0].expr_asm_arg.kind, AsmArgKind.ARG_REG);
	test::eq(s.asm_stmt.args[1].expr_asm_arg.kind, AsmArgKind.ARG_MEMVAR);
	s = astp(s.next);
	test::eq(s.ast_kind, AstKind.ASM_LABEL);
	s = astp(s.next);
	test::eq(s.asm_stmt.variant, "q");
	test::eq(s.asm_stmt.args[1].expr_asm_arg.kind, AsmArgKind.ARG_VALUE);
	a = stmt_of("asm @pure { }");
	assert(!a.asm_block_stmt.is_volatile);
	a = stmt_of("asm(\"nop\");");
	assert(a.asm_block_stmt.is_string);
	stmt_error("asm @pure @pure { }", "'@pure' should only appear once.");
	stmt_error("asm { mov [$rax * 3]; }", "Expected + or - here.");
}

fn void statement_errors()
{
	defer compiler::compiler_free();
	stmt_error("return 1", "Expected ';'");
	stmt_error(")", "Mismatched ')' found.");
	stmt_error("try", "'try' can only be used when unwrapping an optional, did you mean 'try?'?");
	stmt_error("default:", "'default' was found outside of 'switch', did you mismatch a '{ }' pair?");
	stmt_error("module", "Unexpected 'module' found when expecting a statement.");
	stmt_error("assert 1;", "'assert' needs a '(' here, did you forget it?");
	stmt_error("assert(1)", "Expected a ';' here.");
	stmt_error("{ 1; ", "Reached the end of the file when expecting a statement.");
}

fn void lambda_short_body()
{
	defer compiler::compiler_free();
	// parse_short_body is driven by a Decl; build the bare minimum c3c needs.
	ParseContext* c = open_context("=> FOO(1);");
	Decl* func = compiler::decl_calloc();
	Ast* body = compiler::parse_short_body(c, func, false);
	assert(compiler::ast_ok(body));
	test::eq(body.ast_kind, AstKind.COMPOUND_STMT);
	Ast* ret = astp(body.compound_stmt.first_stmt);
	test::eq(ret.ast_kind, AstKind.RETURN_STMT);
	test::eq(ret.return_stmt.expr.expr_kind, ExprKind.CALL);
	test::eq(c.tok, TokenType.EOF);
	// A trailing macro body keeps the call as an expression statement and the ';' stays.
	c = open_context("=> @pool() { 1; };");
	body = compiler::parse_short_body(c, func, false);
	ret = astp(body.compound_stmt.first_stmt);
	test::eq(ret.ast_kind, AstKind.EXPR_STMT);
	assert(ret.expr_stmt.call_expr.macro_body);
	assert(ret.expr_stmt.call_expr.is_outer_call);
	test::eq(c.tok, TokenType.EOS);
}

// --- Cases that go through parse_global.c3 (identifiers with path
// prefixes, types, conditions, declarations).

fn void identifiers_and_types_global()
{
	defer compiler::compiler_free();
	Expr* e = expr_of("foo + 1");
	expect_binary(e, ADD);
	expect_ident(left(e), "foo");
	assert(!left(e).unresolved_ident_expr.is_const);
	e = expr_of("std::io::foo");
	expect_ident(e, "foo");
	test::eq(e.unresolved_ident_expr.path.module_name, "std::io");
	check(compiler::sourcelocptr(e.loc).length, 12);
	e = expr_of("(int)foo");
	test::eq(e.expr_kind, ExprKind.CAST);
	expect_ident(compiler::exprptr(e.cast_expr.expr), "foo");
	test::eq(compiler::type_infoptr(e.cast_expr.type_info).type, compiler::type_int);
	// A cast binds tighter than binary operators, but takes postfix.
	e = expr_of("(int)foo[1] + 2");
	expect_binary(e, ADD);
	test::eq(left(e).expr_kind, ExprKind.CAST);
	test::eq(compiler::exprptr(left(e).cast_expr.expr).expr_kind, ExprKind.SUBSCRIPT);
	// `Type {` is a generic type (c3c parse_optional_type allows generics here).
	e = expr_of("Foo { 1, 2 }");
	test::eq(e.expr_kind, ExprKind.TYPEINFO);
	test::eq(e.type_expr.kind, TypeInfoKind.INFO_GENERIC);
	e = expr_of("(Foo){ 1, 2 }");
	test::eq(e.expr_kind, ExprKind.COMPOUND_LITERAL);
	test::eq(e.expr_compound_literal.type_info.unresolved.name, "Foo");
	check(e.expr_compound_literal.initializer.initializer_list.len, 2);
	e = expr_of("(int[2]){ 1, 2 }");
	test::eq(e.expr_kind, ExprKind.COMPOUND_LITERAL);
	check(compiler::sourcelocptr(e.loc).length, 16);
	e = expr_of("int");
	test::eq(e.expr_kind, ExprKind.TYPEINFO);
	e = expr_of("int::typeid");
	test::eq(e.expr_kind, ExprKind.CONST);
	test::eq(e.const_expr.const_kind, ConstKind.TYPEID);
	test::eq(e.const_expr.typeid_type, compiler::type_int);
	e = expr_of("Foo::size");
	test::eq(e.expr_kind, ExprKind.TYPE_PROPERTY);
	test::eq(e.type_property_expr.property, "size");
	e = expr_of("{ .a = 1, .b.c = 2 }");
	test::eq(e.expr_kind, ExprKind.DESIGNATED_INITIALIZER_LIST);
	test::eq(e.designated_init.list[1].designator_expr.path[0].kind, DesignatorType.FIELD);
	check(e.designated_init.list[1].designator_expr.path.len, 2);
	expr_error("{ .a = 1, .a = 2 }", "This element is assigned twice in the same initializer.");
	expr_error("{ .a = 1, 2 }", "You’re using both named and unnamed values in the same initializer. Try using either all '.field = value' or all regular values — but not both together.");
	e = expr_of("$defined(1, foo)");
	test::eq(e.expr_kind, ExprKind.CT_DEFINED);
	check(e.expression_list.len, 2);
	e = expr_of("fn int(int x) => x + 1");
	test::eq(e.expr_kind, ExprKind.LAMBDA);
	Decl* func = e.lambda_expr;
	check(func.func_decl.signature.params.len, 1);
	assert(func.func_decl.body);
	expr_error("Foo::", "A type property, like 'name' or 'size' was expected after '::'");
	expr_error("std::", "Expected a type, function or constant.");
}

fn void conditions_global()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("if (foo) { 1; } else 2;");
	test::eq(a.ast_kind, AstKind.IF_STMT);
	Expr* cond = compiler::exprptr(a.if_stmt.cond);
	test::eq(cond.expr_kind, ExprKind.COND);
	check(cond.cond_expr.len, 1);
	expect_ident(cond.cond_expr[0], "foo");
	test::eq(astp(a.if_stmt.then_body).ast_kind, AstKind.COMPOUND_STMT);
	test::eq(astp(a.if_stmt.else_body).ast_kind, AstKind.EXPR_STMT);
	// A non-compound body on another line is poisoned for sema to report.
	a = stmt_of("if (foo)\n1;");
	test::eq(astp(a.if_stmt.then_body).ast_kind, AstKind.POISONED);
	a = stmt_of("if (try x = foo() && y) {}");
	cond = compiler::exprptr(a.if_stmt.cond);
	Expr* chain = cond.cond_expr[0];
	test::eq(chain.expr_kind, ExprKind.TRY_UNWRAP_CHAIN);
	check(chain.try_unwrap_chain_expr.len, 2);
	Expr* unwrap = chain.try_unwrap_chain_expr[0];
	test::eq(unwrap.expr_kind, ExprKind.TRY_UNRESOLVED);
	expect_ident(unwrap.unresolved_try_expr.variable, "x");
	test::eq(unwrap.unresolved_try_expr.init.expr_kind, ExprKind.CALL);
	a = stmt_of("if (catch err = foo, bar) {}");
	Expr* catch_ = compiler::exprptr(a.if_stmt.cond).cond_expr[0];
	test::eq(catch_.expr_kind, ExprKind.CATCH_UNRESOLVED);
	expect_ident(catch_.unresolved_catch_expr.variable, "err");
	check(catch_.unresolved_catch_expr.exprs.len, 2);
	a = stmt_of("while (foo < 3) foo++;");
	test::eq(a.ast_kind, AstKind.FOR_STMT);
	test::eq(compiler::exprptr(a.for_stmt.cond).expr_kind, ExprKind.COND);
	a = stmt_of("for (i = 0; i < 3; i++, j++) {}");
	Expr* init = compiler::exprptr(a.for_stmt.init);
	test::eq(init.expr_kind, ExprKind.EXPRESSION_LIST);
	check(compiler::exprptr(a.for_stmt.incr).expression_list.len, 2);
	a = stmt_of("switch (foo) { case int: 1; case Foo: 2; }");
	Expr* first = compiler::exprptr(a.switch_stmt.cases[0].case_stmt.expr);
	test::eq(first.expr_kind, ExprKind.CONST);
	test::eq(first.const_expr.typeid_type, compiler::type_int);
	test::eq(compiler::exprptr(a.switch_stmt.cases[1].case_stmt.expr).expr_kind, ExprKind.TYPEID);
	a = stmt_of("foreach (i, &x : foo) {}");
	test::eq(a.ast_kind, AstKind.FOREACH_STMT);
	test::eq(compiler::declptr(a.foreach_stmt.index).name, "i");
	test::eq(compiler::declptr(a.foreach_stmt.variable).name, "x");
	assert(a.foreach_stmt.value_by_ref);
	a = stmt_of("foreach_r (int x : foo) {}");
	assert(a.foreach_stmt.is_reverse);
	test::eq(compiler::declptr(a.foreach_stmt.variable).var_decl.type_info != 0, true);
	stmt_error("if (try x = foo, 1) {}", "The 'try' must be placed last, can you change it?");
	stmt_error("if (foo == 1 bar) {}", "Finding an identifier here was surprising - did you forget '||' or '&&' or the ending ')' character?");
	stmt_error("while (foo)\n1;", "A single statement after 'while' must be placed on the same line, or be enclosed in {}.");
	stmt_error("if (foo)", "Reached the end of the file when expecting a statement.");
	stmt_error("{ if (foo) }", "The body of an if statement was expected here.");
}

fn void declarations_global()
{
	defer compiler::compiler_free();
	Ast* a = stmt_of("int x = 1;");
	test::eq(a.ast_kind, AstKind.DECLARE_STMT);
	test::eq(a.declare_stmt.name, "x");
	expect_int(a.declare_stmt.var_decl.init_expr, 1);
	a = stmt_of("int x, y;");
	test::eq(a.ast_kind, AstKind.DECLS_STMT);
	check(a.decls_stmt.len, 2);
	test::eq(a.decls_stmt[1].name, "y");
	a = stmt_of("static int x;");
	assert(a.declare_stmt.var_decl.is_static);
	a = stmt_of("$Type = int;");
	test::eq(a.ast_kind, AstKind.CT_TYPE_ASSIGN_STMT);
	stmt_error("int x[4];", "This looks like the beginning of a declaration with the format 'int x[4]' which is a c-style array declaration. In C3, you need to use something like 'int[4] x' instead.");
	stmt_error("int x = 1, y;", "Multiple variable declarations cannot use initialization.");
	stmt_error("foo bar;", "Expected a type here.");
}
