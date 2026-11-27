// Port of c3c src/compiler/parser.c (token advance, parse_file and the
// include / stdin entry points) and the inline helpers of parser_internal.h
// (ParameterParseKind, peek, tok_is, expect, symstr, type_info_new_curr,
// ast_new_curr, token_is_*, expect_ident, parse_const_paren_expr, ...), plus
// `advance_and_verify`, RANGE_EXTEND_PREV, EXPR_NEW_TOKEN and NEW_AST_TOKEN
// from compiler_internal.h.
//
// The grammar itself lives in parse_expr.c3, parse_stmt.c3 and
// parse_global.c3.
//
// c3c's control-flow macros return from the caller, so they are expanded by
// hand (helpers below keep each expansion to one line):
//   CONSUME_OR_RET(tok, res)        -> if (!expect_advance(c, tok)) return res;
//   EXPECT_OR_RET(tok, res)         -> if (!expect(c, tok)) return res;
//   CONSUME_EOS_OR_RET(res)         -> if (!consume_eos(c)) return res;
//   TRY_CONSUME_OR_RET(tok, msg, r) -> if (!@consume(c, tok, msg)) return r;
//   EXPECT_IDENT_FOR_OR(name, res)  -> if (!expect_ident(c, name)) return res;
//   CHECK_EXPR_OR_RET(e)            -> if (!expr_ok(e)) return e;
//   ASSIGN_EXPR_OR_RET(x, e, res)   -> Expr* tmp = e; if (!expr_ok(tmp)) return res; x = tmp;
//     (same shape for ASSIGN_AST / ASTID / EXPRID / TYPE / TYPEID / DECL / DECLID)
//   RANGE_EXTEND_PREV(x)            -> range_extend_prev(c, x.loc);
//   EXPR_NEW_TOKEN(kind)            -> expr_new_token(c, kind)
//   NEW_AST_TOKEN(kind)             -> new_ast_token(c, kind)
//   c->data.lex_start / lex_len     -> c.data.lex.ptr / c.data.lex.len
//   c->data.strlen                  -> c.data.string.len
//
// Deviations from c3c:
// - ParseContext embeds lexer::Lexer, initialised with the AST arena (token
//   strings), `global_symtab` and `global_diagnostics`.
// - A lexing error does not `exit_compiler(1)`: the lexer has already
//   reported it (bumping errors_found) and scanned on to EOF; `advance` sets
//   `compiler.context.exit_requested`, which mutes later reports (as if c3c
//   had exited), so parsing runs into EOF silently and parse_file fails.
// - `consume` (printf-style message) is the format-checked macro `@consume`.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, aro::frontend::c3::lexer, std::io;

<* parser_internal.h `ParameterParseKind`. *>
enum ParameterParseKind : char
{
	MACRO,
	FUNC,
	BODY,
	CALL,
	LAMBDA,
	ATTR,
}

<* compiler_internal.h `ParseContext`. *>
struct ParseContext
{
	TokenData data;
	TokenType tok;
	SourceLoc span;
	SourceLoc prev_span;
	CompilationUnit* unit;
	Lexer lexer;
	ContractDescription contracts;
}

<* c3c `lexer_init` on a ParseContext's embedded lexer (`.file`, `.context` set). *>
fn void parse_context_lexer_init(ParseContext* c, SourceFile* file)
{
	c.lexer.init(ast_allocator(), &global_symtab, &global_diagnostics, file.file_id, file.contents);
}

// --- Parser base methods

<* Advance to the next non-comment token. *>
fn void advance(ParseContext* c)
{
	if (tok_is(c, EOF)) return;

	c.tok = c.lexer.token_type;
	c.data = c.lexer.data;
	c.prev_span = c.span;
	c.span = c.lexer.tok_span;
	// c3c: if (!lexer_next_token(&c->lexer)) exit_compiler(1);
	// The lexer has reported its errors; instead of exiting, mute further
	// reports and let the parser run out at EOF (parse_file then fails).
	if (!c.lexer.next_token()) compiler.context.exit_requested = true;
}

fn bool try_consume(ParseContext* c, TokenType type)
{
	if (tok_is(c, type))
	{
		advance(c);
		return true;
	}
	return false;
}

<* c3c `consume`: consume `type` or report `$fmt` at the current token. *>
macro bool @consume(ParseContext* c, TokenType type, String $fmt, ...)
{
	if (try_consume(c, type)) return true;
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "consume arguments do not match the format";
	sema_verror_range(&c.span, $fmt, ...$vaarg);
	return false;
}

// --- Extern functions

<* module? imports top_level_statement* *>
fn void parse_translation_unit(ParseContext* c)
{
	// Prime everything
	advance(c);
	advance(c);
	while (!tok_is(c, EOF))
	{
		Decl* decl = parse_top_level_statement(c, &c);
		if (!decl) continue;
		if (decl_ok(decl))
		{
			Decl* gs = decl.is_template ? declptr(decl.generic_id) : null;
			if (decl.is_cond)
			{
				add_decl_to_list(gs ? &gs.generic_decl.conditional_decls : &c.unit.global_cond_decls, decl);
			}
			else
			{
				add_decl_to_list(gs ? &gs.generic_decl.decls : &c.unit.global_decls, decl);
			}
		}
		else
		{
			recover_top_level(c);
		}
	}
}

<*
 Parse a file, generating a default context for it.
 More contexts may be created on demand during parsing.
 Returns true if parsing succeeds.
*>
fn bool parse_file(SourceFile* file)
{
	CompilationUnit* unit = unit_create(file);
	ParseContext parse_context = { .unit = unit };
	parse_context_lexer_init(&parse_context, file);
	if (compiler.context.errors_found) return false;
	parse_translation_unit(&parse_context);
	return !compiler.context.errors_found;
}

fn Decl*[] parse_include_file(SourceFile* file, CompilationUnit* unit)
{
	ParseContext parse_context = { .tok = INVALID_TOKEN };
	ParseContext* c = &parse_context;
	c.unit = unit;
	parse_context_lexer_init(c, file);
	// Prime everything
	advance(c);
	advance(c);
	Decl*[] list;
	while (!tok_is(c, EOF))
	{
		Decl* inner = parse_top_level_statement(c, null);
		if (!inner) continue;
		if (!decl_ok(inner))
		{
			decl_poison(inner);
			return {};
		}
		add_decl_to_list(&list, inner);
	}
	return list;
}

fn Ast* parse_include_file_stmts(SourceFile* file, CompilationUnit* unit)
{
	ParseContext parse_context = { .tok = INVALID_TOKEN };
	ParseContext* c = &parse_context;
	c.unit = unit;
	parse_context_lexer_init(c, file);
	// Prime everything
	advance(c);
	advance(c);
	Ast* first = null;
	Ast* current = null;
	while (!tok_is(c, EOF))
	{
		Ast* stmt = parse_stmt(c);
		if (!stmt) continue;
		if (!ast_ok(stmt))
		{
			ast_poison(stmt);
			return poisoned_ast;
		}
		if (!first)
		{
			first = current = stmt;
			continue;
		}
		assert(current != null);
		current.next = astid(stmt);
		current = stmt;
	}
	return first;
}

<* Parse stdin. Returns true if parsing succeeds. *>
fn bool parse_stdin()
{
	stdin_file = {
		.name = "stdin",
		.file_id = STDIN_FILE_ID,
		.kind = STDIN,
		.full_path = "<stdin>",
		.dir_path = "",
	};
	char[] data;
	while (true)
	{
		char? c = io::stdin().read_byte();
		if (catch c) break;
		if (c == '\r') continue;
		@vec_add(&data, c);
	}
	String? cleaned = lexer::clean_source(ast_allocator(), data);
	if (catch cleaned) return false;
	stdin_file.contents = cleaned;
	CompilationUnit* unit = unit_create(&stdin_file);
	ParseContext parse_context = { .unit = unit };
	parse_context_lexer_init(&parse_context, &stdin_file);
	if (compiler.context.errors_found) return false;
	parse_translation_unit(&parse_context);
	return !compiler.context.errors_found;
}

// ---------------------------------------------------------------------------
// parser_internal.h

fn void add_decl_to_list(Decl*[]* list, Decl* decl)
{
	if (decl.decl_kind == GROUP)
	{
		foreach (d : decl.decls) @vec_add(list, d);
		return;
	}
	@vec_add(list, decl);
}

fn String symstr(ParseContext* c) => c.data.string;

fn TypeInfo* type_info_new_curr(ParseContext* c, TypeInfoKind type) => type_info_new(type, make_loc(c.span));

fn TokenType peek(ParseContext* c) => c.lexer.token_type;

fn Ast* ast_new_curr(ParseContext* c, AstKind kind) => new_ast(kind, make_loc(c.span));

fn bool tok_is(ParseContext* c, TokenType type) => c.tok == type;

fn bool expect(ParseContext* c, TokenType token_type)
{
	if (tok_is(c, token_type)) return true;
	@print_error_here(c, "Expected '%s'.", token_type_to_string(token_type));
	return false;
}

fn bool token_is_param_name(TokenType token_type)
{
	switch (token_type)
	{
		case CT_IDENT:
		case IDENT:
		case HASH_IDENT:
		case CT_TYPE_IDENT:
			return true;
		default:
			return false;
	}
}

fn bool token_is_some_ident(TokenType token_type)
{
	switch (token_type)
	{
		case TYPE_IDENT:
		case IDENT:
		case CONST_IDENT:
			return true;
		default:
			return false;
	}
}

fn bool token_is_keyword_ident(TokenType token_type)
{
	return token_type >= tokens::FIRST_KEYWORD && token_type <= tokens::LAST_NON_CT_KEYWORD;
}

fn bool token_is_keyword(TokenType token_type)
{
	return token_type >= tokens::FIRST_NON_TYPE_KEYWORD && token_type <= tokens::LAST_NON_CT_KEYWORD;
}

<* c3c TYPE_TOKENS: the builtin type keywords `void` .. `untypedlist`. *>
fn bool token_is_type_token(TokenType token_type) => token_type >= VOID && token_type <= UNTYPEDLIST;

fn bool expect_ident(ParseContext* c, String name)
{
	switch (c.tok)
	{
		case IDENT:
			return true;
		case TYPE_IDENT:
		case CONST_IDENT:
			@print_error_here(c, "A %s cannot start with a capital letter.", name);
			return false;
		case VOID..UNTYPEDLIST:
			@print_error_here(c, "A type cannot be used as a %s, you must use a different identifier.", name);
			return false;
		default:
			if (token_is_keyword_ident(c.tok))
			{
				@print_error_here(c, "You cannot use a keyword as %s, pick something else please.", name);
				return false;
			}
			@print_error_here(c, "A %s was expected.", name);
			return false;
	}
}

fn Expr* parse_const_paren_expr(ParseContext* c)
{
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	Expr* expr = parse_constant_expr(c);
	if (!expr_ok(expr)) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	return expr;
}

fn bool parse_next_may_be_type_or_ident(ParseContext* c)
{
	switch (c.tok)
	{
		case CONST_IDENT:
		case IDENT:
		case HASH_IDENT:
		case CT_IDENT:
		case CT_CONST_IDENT:
		case VOID..UNTYPEDLIST:
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			return true;
		default:
			return false;
	}
}

<* Useful sanity check function. *>
fn void advance_and_verify(ParseContext* context, TokenType token_type)
{
	assert(context.tok == token_type);
	advance(context);
}

// ---------------------------------------------------------------------------
// Expansion helpers for c3c's returning macros (see header)

<* CONSUME_OR_RET's check: expect `tok`, then advance past it. *>
fn bool expect_advance(ParseContext* c, TokenType tok)
{
	if (!expect(c, tok)) return false;
	advance(c);
	return true;
}

<* CONSUME_EOS_OR_RET's check. *>
fn bool consume_eos(ParseContext* c)
{
	if (!tok_is(c, EOS))
	{
		@print_error_after(&c.prev_span, "Expected ';'");
		return false;
	}
	advance(c);
	return true;
}

<* c3c RANGE_EXTEND_PREV(x): extend the span of `loc` (a node's `loc`) to the end of the previous token. *>
fn void range_extend_prev(ParseContext* c, SourceLocId loc)
{
	*sourcelocptr(loc) = extend_loc_with_token(sourcelocptr(loc), &c.prev_span);
}

<* c3c EXPR_NEW_TOKEN. *>
fn Expr* expr_new_token(ParseContext* c, ExprKind kind) => expr_new(kind, make_loc(c.span));

<* c3c NEW_AST_TOKEN. *>
fn Ast* new_ast_token(ParseContext* c, AstKind kind) => new_ast_loc(kind, c.span);
