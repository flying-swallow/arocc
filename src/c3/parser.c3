// Parser context and lifecycle (bounded infrastructure port of Parser.zig).
// The declaration, type-name and body grammars are supplied by an
// IParserHandler; this module owns token/tree context, recovery, diagnostics
// and teardown.
module aro::parser;
import aro::compilation, aro::diagnostics, aro::preprocessor, aro::source, aro::tokens, aro::tokenizer, aro::tree, aro::parser_diagnostics, aro::type_store, aro::value, aro::value_interner, aro::symbol_stack, aro::string_interner, aro::pragma, aro::parser_result, aro::attribute;
import std::collections::list, std::collections::map, std::core::dstring, std::io;

excuse PARSING_FAILED;

<* How constant integer declaration references behave inside constant expressions. *>
enum ConstDeclFoldingMode
{
	FOLD_CONST_DECLS,
	GNU_FOLDING_EXTENSION,
	GNU_VLA_FOLDING_EXTENSION,
	NO_CONST_DECL_FOLDING,
}

<* How strongly an initializer requires a saved compile-time value. *>
enum InitContext
{
	RUNTIME,
	CONSTEXPR,
	STATIC,
}

<* Result of a speculative type-name probe. A non-match is successful and
   must not diagnose or consume input; a diagnosed parse failure is returned
   as a fault, so it remains distinct from ordinary grouping. *>
struct TypeNameProbe
{
	bool matched;
	type_store::QualType qt;
}

<* Returned by a handler method that the implementing type has but this
   instance does not provide. Parser treats it exactly like a missing
   optional method. *>
excuse HOOK_ABSENT;

<*
 Grammar and expression extension hooks supplied by the parser's owner. Every
 method is optional: a missing method (or a HOOK_ABSENT fault) means the
 grammar is unavailable, and Parser reports or skips it as documented on each
 dispatcher. The handler is borrowed and must outlive the Parser.
*>
interface IParserHandler
{
	fn void? handle_declaration(Parser* p) @optional;
	fn void? handle_type_name(Parser* p) @optional;
	fn type_store::QualType? handle_typed_type_name(Parser* p) @optional;
	<* A non-match is successful and must not diagnose or consume input. *>
	fn TypeNameProbe? handle_typed_type_name_probe(Parser* p) @optional;
	fn void? handle_body(Parser* p) @optional;
	fn void? handle_implicit_typedefs(Parser* p) @optional;
	<* Called once after the translation unit's top-level parse loop reaches EOF. *>
	fn void? handle_translation_unit_end(Parser* p) @optional;
	<* Classify grammar faults that the translation-unit loop may recover from. *>
	fn bool? is_recoverable_parse_fault(Parser* p, fault parse_fault) @optional;
	<* Required before SymbolStack can combine a tentative declaration with a definition. *>
	fn void handle_tentative_decl_definition(Parser* p, type_store::NodeIndex declaration, type_store::NodeIndex definition) @optional;
	<* Specialized primary-expression grammar, such as the builtin parser. *>
	fn parser_result::Result? handle_builtin_primary_expression(Parser* p, bool eval) @optional;
	<* Specialized call parsing for builtin calls. *>
	fn parser_result::Result? handle_builtin_call(Parser* p, type_store::NodeIndex callee,
		tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval) @optional;
	<* Typed compound literal; starts at the opening brace, `opening_tok` is the '('. *>
	fn parser_result::Result? handle_compound_literal_primary(Parser* p, tokens::TokenIndex opening_tok,
		type_store::QualType qt, bool eval) @optional;
	<* Compound statement inside a GNU statement expression. *>
	fn type_store::NodeIndex? handle_statement_expression_body(Parser* p, bool eval) @optional;
}

<* GNU &&label unary expressions. Installed by the statement grammar for the
   duration of a function body. *>
interface IAddressOfLabel
{
	fn parser_result::Result? handle_address_of_label(Parser* p);
}

<* Optional token index with an explicit presence bit, so index zero is unambiguous. *>
struct TokenIndexOption
{
	bool has_value;
	tokens::TokenIndex value;
}

struct TreeTokenOption
{
	bool has_value;
	tokens::TreeToken value;
}

struct TokenTextOption
{
	bool has_value;
	String value;
}

<* Function metadata active while parsing a function body. The declaration
   owner supplies this after building the function declaration and type. *>
struct FunctionContext
{
	bool active;
	type_store::NodeOptIndex declaration;
	bool variadic;
	uint named_param_count;
	tokens::TokenIndex function_name_tok;
	type_store::QualType function_qt;
	<* Cached static variable generated for __func__ / __FUNCTION__. *>
	type_store::NodeOptIndex func_ident;
	<* Cached static variable generated for __PRETTY_FUNCTION__. *>
	type_store::NodeOptIndex pretty_ident;
}

<* Auto-type declaration whose initializer is currently being parsed. *>
struct AutoTypeDeclContext
{
	bool active;
	string_interner::StringId name;
	type_store::NodeIndex node;
}

<* Call-site context visible while parsing an argument expression. *>
struct VaArgPackCallContext
{
	bool active;
	bool variadic;
	bool typed;
}

<* A parser borrows its preprocessor and token storage; it owns its tree and symbol scopes. *>
struct Parser
{
	preprocessor::Preprocessor* pp;
	Compilation* comp;
	diagnostics::Diagnostics* diagnostics;
	Tree tree;
	symbol_stack::SymbolStack symbols;
	IParserHandler handler;
	IAddressOfLabel address_of_label;
	InitializerParser initializer_parser;
	bool has_initializer_parser;
	tokens::TokenIndex tok_i;
	tokens::TokenIndex tok_end;
	bool extension_suppressed;
	ConstDeclFoldingMode const_decl_folding;
	<* Set by static-assert parsing while folding its condition. Comparison folding
	   saves operand values in the value map so the evaluation note can print lhs op rhs. *>
	bool record_static_assert_eval_note;
	InitContext init_context;
	FunctionContext function_context;
	VaArgPackCallContext va_arg_pack_call;
	AutoTypeDeclContext auto_type_decl;
	<* Zig `maybe_unused_decl`: pending local declarations keyed by `(uint)NodeIndex`;
	   value is true once the declaration is used. Owned; released by `Parser.free`. *>
	HashMap{uint, bool} maybe_unused_decl;
	<* Insertion order of `maybe_unused_decl` keys, so reports follow declaration order
	   (Zig's array hash map iterates in insertion order; C3 `HashMap` does not). *>
	List{type_store::NodeIndex} maybe_unused_order;
	<* Diagnostic error count at body start, set by the declaration parser before a function
	   body is parsed. `Parser.diagnose_unused_locals` skips reporting when errors grew since then. *>
	uint local_unused_err_count;
	bool initialized;
	bool symbols_initialized;
}

<* Install or restore the function metadata visible to builtin parsers. Save
   the old value before entering nested function parsing and restore it after. *>
fn void Parser.set_function_context(&self, FunctionContext context)
{
	self.function_context = context;
}

<* Current-function checks shared by __builtin_va_arg_pack and _len. This
   follows Parser.zig's requirement for a variadic function with named args
   and an always_inline or gnu_inline declaration attribute. *>
fn bool? Parser.check_va_pack_function(&self, tokens::TokenIndex builtin_tok, String builtin_name)
{
	FunctionContext context = self.function_context;
	if (!context.active)
	{
		self.emit_va_pack_function_diag(parser_diagnostics::ParserDiag.VA_FUNC_NOT_IN_FUNC,
			builtin_name, builtin_tok)!;
		return false;
	}
	if (!context.variadic || context.named_param_count == 0)
	{
		self.emit_va_pack_function_diag(parser_diagnostics::ParserDiag.VA_FUNC_FIXED_ARGS,
			builtin_name, builtin_tok)!;
		return false;
	}
	if (!self.tree.attr_map.has_attribute(context.declaration, attribute::AttributeTag.ALWAYS_INLINE) &&
	!self.tree.attr_map.has_attribute(context.declaration, attribute::AttributeTag.GNU_INLINE))
	{
		self.emit_va_pack_function_diag(parser_diagnostics::ParserDiag.VA_FUNC_NOT_ALWAYS_INLINE,
			builtin_name, builtin_tok)!;
		return false;
	}
	return true;
}

fn void? Parser.emit_va_pack_function_diag(&self, parser_diagnostics::ParserDiag diag,
	String builtin_name, tokens::TokenIndex builtin_tok)
{
	return self.err_dyn(diag, builtin_tok, builtin_name);
}

<* Current call argument state for a va_arg_pack builtin. *>
fn VaArgPackCallContext Parser.va_arg_pack_call_context(self) => self.va_arg_pack_call;

<* Add or remove a nested lexical scope. Parser.init creates the outer scope. *>
fn void Parser.push_scope(&self)
{
	assert(self.symbols_initialized);
	self.symbols.push_scope();
}

fn void Parser.pop_scope(&self)
{
	assert(self.symbols_initialized && self.symbols.active_len > 1, "cannot pop the parser's outer scope");
	self.symbols.pop_scope();
}

<* Seed a symbol in the current scope; declarator construction remains a grammar callback's job. *>
fn void Parser.define_symbol(&self, symbol_stack::Symbol symbol)
{
	assert(self.symbols_initialized);
	self.symbols.define(symbol);
}

<* Bind the expression productions used by initializer grammar. Declaration
   callbacks and primary-expression callbacks can now share this entry point. *>
fn void Parser.bind_initializer_parser(&self, void* context, AssignmentExpression assignment_expression, IntegerConstantExpression integer_constant_expression)
{
	self.initializer_parser = { .parser = self, .context = context,
	.assignment_expression = assignment_expression,
	.integer_constant_expression = integer_constant_expression };
	self.has_initializer_parser = true;
}

fn parser_result::Result? Parser.parse_initializer(&self, type_store::QualType target, bool eval = true)
{
	if (!self.has_initializer_parser)
	{
		if (catch self.grammar_unavailable()) return PARSING_FAILED~;
		return PARSING_FAILED~;
	}
	tokens::TokenIndex initializer_tok = self.tok_i;
	if (try array = target.get(self.comp, type_store::TypeTag.ARRAY))
	{
		if (array.array.len.kind == type_store::ArrayLenKind.VARIABLE ||
			array.array.len.kind == type_store::ArrayLenKind.UNSPECIFIED_VARIABLE)
		{
			self.err(parser_diagnostics::ParserDiag.VLA_INIT, initializer_tok)!;
		}
	}
	parser_result::Result? maybe_result = self.initializer_parser.parse(target, eval);
	if (catch __fault = maybe_result) return __fault~;
	parser_result::Result result = maybe_result;
	InitContext context = self.init_context;
	if (!target.is_invalid() && context != InitContext.RUNTIME &&
	!(result.require_initializer_value(self, context, initializer_tok)!))
	{
		// Match Parser.zig: one failed value requirement is enough to report the
		// initializer error; later elements should not repeat it.
		self.init_context = InitContext.RUNTIME;
	}
	if (target.is_const || context == InitContext.CONSTEXPR) result.restore_saved_value(self);
	return result;
}

<* Parse one initializer under a declaration's value requirement and restore
   the surrounding context for nested initializers. *>
fn parser_result::Result? Parser.parse_initializer_with_context(&self, type_store::QualType target,
	InitContext context, bool eval = true)
{
	InitContext previous = self.init_context;
	defer self.init_context = previous;
	self.init_context = context;
	return self.parse_initializer(target, eval);
}

fn symbol_stack::Symbol? Parser.find_symbol(&self, string_interner::StringId name)
{
	assert(self.symbols_initialized);
	return self.symbols.find_symbol(name);
}

fn bool? Parser.find_typedef(&self, string_interner::StringId name, tokens::TokenIndex name_tok, bool no_type_yet, symbol_stack::Symbol* out)
{
	assert(self.symbols_initialized);
	symbol_stack::SymbolContext ctx = self.symbol_context();
	return self.symbols.find_typedef(&ctx, name, name_tok, no_type_yet, out);
}

fn bool? Parser.find_tag(&self, string_interner::StringId name, tokenizer::TokenId kind, tokens::TokenIndex name_tok, tokenizer::TokenId next_tok_id, symbol_stack::Symbol* out)
{
	assert(self.symbols_initialized);
	symbol_stack::SymbolContext ctx = self.symbol_context();
	return self.symbols.find_tag(&ctx, name, kind, name_tok, next_tok_id, out);
}

<* Pop all active scopes, then free the retained scope storage. *>
fn void Parser.release_symbols(&self)
{
	if (!self.symbols_initialized) return;
	while (self.symbols.active_len > 0) self.symbols.pop_scope();
	self.symbols.free();
	self.symbols_initialized = false;
}

<* Apply the active constant declaration policy to a declaration reference.
 Only integer values receive the GNU folding diagnostic; enumerators remain
 foldable when ordinary constant declaration folding is disabled. *>
fn value::Value Parser.referenced_integer_constant(&self, value::Value decl_value, bool is_integer_constant,
	bool is_enumeration, tokens::TokenIndex name_tok)
{
	switch (self.const_decl_folding)
	{
		case GNU_FOLDING_EXTENSION:
			if (is_integer_constant) self.err(parser_diagnostics::ParserDiag.CONST_DECL_FOLDED, name_tok)!!;
		case GNU_VLA_FOLDING_EXTENSION:
			if (is_integer_constant) self.err(parser_diagnostics::ParserDiag.CONST_DECL_FOLDED_VLA, name_tok)!!;
		case NO_CONST_DECL_FOLDING:
			if (!is_enumeration) return value::NONE;
		case FOLD_CONST_DECLS: {}
	}
	return decl_value;
}

<*
 Initialize over an already preprocessed token list. The token slice stays
 owned by `pp`, which must outlive both this Parser and its returned Tree.
 `handle_implicit_typedefs`, when provided, initializes the grammar layer's typedef
 scope before parsing. This infrastructure does not invent type aliases.
*>
fn void Parser.init(&self, preprocessor::Preprocessor* pp, IParserHandler handler = null)
{
	*self = {};
	self.pp = pp;
	self.comp = pp.comp;
	self.diagnostics = pp.diagnostics;
	self.handler = handler;
	self.const_decl_folding = ConstDeclFoldingMode.FOLD_CONST_DECLS;
	self.function_context.func_ident = type_store::NODE_NULL;
	self.function_context.pretty_ident = type_store::NODE_NULL;
	self.symbols.init(pp.comp.gpa);
	self.symbols_initialized = true;
	self.symbols.push_scope();
	self.maybe_unused_decl.init(pp.comp.gpa);
	self.maybe_unused_order.init(pp.comp.gpa);
	// The implicit-typedef callback may append generated tokens and grow the
	// preprocessor list. Bind the final slice only after that callback runs.
	self.tree.init(pp.comp, {});
	self.initialized = true;
}

<* Current token index, clamped to the terminal end of the borrowed buffer. *>
fn tokens::TokenIndex Parser.current(self) => self.tok_i;

<* Bind the parser to the current preprocessor token buffer after token growth is complete.
 Call this explicitly when using token helpers without Parser.parse; parse itself binds
 after implicit_typedefs so callbacks retain their existing token-growth behavior. *>
fn void Parser.bind_finalized_tokens(&self)
{
	assert(self.initialized);
	self.tree.tokens = self.pp.tokens.array_view();
	self.tok_end = (tokens::TokenIndex)self.tree.tokens.len;
	if (self.tok_i > self.tok_end) self.tok_i = self.tok_end;
}

<* Return a token index at a bounded lookahead distance, or absence at/beyond EOF. *>
fn TokenIndexOption Parser.peek_index(self, usz lookahead = 0)
{
	if (self.tok_i >= self.tok_end) return {};
	usz remaining = (usz)(self.tok_end - self.tok_i);
	if (lookahead >= remaining) return {};
	return { .has_value = true, .value = (tokens::TokenIndex)((usz)self.tok_i + lookahead) };
}

<* Return an inspected token, or absence at/beyond the bound. Index zero is valid. *>
fn TreeTokenOption Parser.peek(self, usz lookahead = 0)
{
	TokenIndexOption maybe_i = self.peek_index(lookahead);
	if (!maybe_i.has_value) return {};
	return { .has_value = true, .value = self.tree.tokens[(usz)maybe_i.value] };
}

<* Text of an in-range token, using Tree.tok_slice for source-backed lexemes. *>
fn TokenTextOption Parser.peek_text(self, usz lookahead = 0)
{
	TokenIndexOption maybe_i = self.peek_index(lookahead);
	if (!maybe_i.has_value) return {};
	return { .has_value = true, .value = self.tree.tok_slice(maybe_i.value) };
}

<* True when the next in-range token has the requested id. *>
fn bool Parser.is_at(self, tokenizer::TokenId id, usz lookahead = 0)
{
	TreeTokenOption tok = self.peek(lookahead);
	return tok.has_value && tok.value.id == id;
}

<* Consume and return the next token index when it matches; has_value=false means absence/mismatch. *>
fn TokenIndexOption Parser.eat(&self, tokenizer::TokenId id)
{
	if (!self.is_at(id)) return {};
	tokens::TokenIndex result = self.tok_i;
	self.advance();
	return { .has_value = true, .value = result };
}

<* Report the standard expected-token diagnostic at the current token and return PARSING_FAILED. *>
fn void? Parser.expect(&self, tokenizer::TokenId id)
{
	if (self.is_at(id))
	{
		self.advance(); return;
	}
	return self.expected_token_diag(id);
}

<* Expect a closing delimiter and attach the corresponding opening-delimiter note. *>
fn void? Parser.expect_closing(&self, tokenizer::TokenId id, tokens::TokenIndex opener)
{
	if (self.is_at(id))
	{
		self.advance(); return;
	}
	fault f = @catch(self.expected_token_diag(id));
	if ((usz)opener < self.tree.tokens.len)
	{
		parser_diagnostics::ParserDiag note;
		if (id == tokenizer::TokenId.R_PAREN)
		{
			note = parser_diagnostics::ParserDiag.TO_MATCH_PAREN;
		}
		else if (id == tokenizer::TokenId.R_BRACE)
		{
			note = parser_diagnostics::ParserDiag.TO_MATCH_BRACE;
		}
		else if (id == tokenizer::TokenId.R_BRACKET)
		{
			note = parser_diagnostics::ParserDiag.TO_MATCH_BRACKET;
		}
		else if (f)
		{
			return f~;
		}
		if (id == tokenizer::TokenId.R_PAREN || id == tokenizer::TokenId.R_BRACE || id == tokenizer::TokenId.R_BRACKET)
		{
			self.err_dyn(note, opener)!;
		}
	}
	if (f) return f~;
	return PARSING_FAILED~;
}

fn void? Parser.expected_token_diag(&self, tokenizer::TokenId expected)
{
	String expected_text = expected.symbol();
	if (self.at_eof())
	{
		DString buf; buf.init(tmem); buf.appendf("expected '%s' before end of file", expected_text);
		self.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_EOF, buf.str_view(), self.diag_index())!;
		return PARSING_FAILED~;
	}
	tokens::TokenIndex tok_i = self.tok_i;
	tokenizer::TokenId actual = self.tree.tokens[(usz)tok_i].id;
	DString buf; buf.init(tmem);
	if (actual == tokenizer::TokenId.INVALID)
	{
		buf.appendf("expected '%s', found invalid bytes", expected_text);
	}
	else
	{
		buf.appendf("expected '%s', found '%s'", expected_text, actual.symbol());
	}
	self.emit_parser_diag(actual == tokenizer::TokenId.INVALID ? parser_diagnostics::ParserDiag.EXPECTED_INVALID : parser_diagnostics::ParserDiag.EXPECTED_TOKEN, buf.str_view(), tok_i)!;
	return PARSING_FAILED~;
}

fn tokens::TokenIndex Parser.diag_index(self)
{
	if (self.tok_i < self.tok_end) return self.tok_i;
	if (self.tok_end > 0) return self.tok_end - 1;
	return 0;
}

<*
 Report `diag` with already formatted `text` at `tok_i`. Prefer `Parser.err`,
 which formats `diag.fmt` with compile-time checked arguments.
 @require text.len > 0 : "empty diagnostic text: route templates and arguments through Parser.err"
*>
fn void? Parser.emit_parser_diag(&self, parser_diagnostics::ParserDiag diag, String text, tokens::TokenIndex tok_i)
{
	// Release-build safety net: empty text falls back to the static template when
	// that template has no placeholder. Debug builds reject empty text via @require.
	String final_text = text;
	if (text == "" && !diag.fmt.contains("%")) final_text = diag.fmt;
	if ((usz)tok_i >= self.tree.tokens.len)
	{
		if (!diag.should_emit(&self.comp.langopts, self.extension_suppressed)) return;
		return self.diagnostics.add(diagnostics::@message(diag, final_text));
	}
	tokens::TreeToken tok = self.tree.tokens[(usz)tok_i];
	return diag.emit(self.comp, &self.comp.langopts, self.extension_suppressed, final_text, tok.loc.expand(self.comp), self.pp.expansion_slice(tok_i));
}

<* Zig `formatQualType`: the quoted type plus its vector/aka suffix (auto types end after the name). *>
fn void Parser.write_qual_type(&self, DString* w, type_store::QualType qt)
{
	w.append_char('\'');
	qt.print(self.comp, w);
	w.append_char('\'');

	if (qt.is_auto()) return;
	if (try vec = qt.get(self.comp, type_store::TypeTag.VECTOR))
	{
		w.appendf(" (vector of %d '", vec.vector.len);
		vec.vector.elem.print_desugared(self.comp, w);
		w.append_string("' values)");
	}
	else if (qt.should_desugar(self.comp))
	{
		w.append_string(" (aka '");
		qt.print_desugared(self.comp, w);
		w.append_string("')");
	}
}

<*
 Zig `formatResult`: `(none)`, `nullptr_t`, or the printed value. A pointer
 value prints as `&base` plus its offset, with base taken from the declaration
 token of the node it refers to.
*>
fn void Parser.write_value(&self, DString* w, value::Value val, type_store::QualType qt)
{
	if (val.is_none())
	{
		w.append_string("(none)");
	}
	else if (val.opt_ref == value_interner::OPT_NULL)
	{
		w.append_string("nullptr_t");
	}
	else
	{
		value::NestedPrint nested;
		if (val.print(qt, self.comp, w, &nested))
		{
			type_store::NodeIndex pointer_node = (type_store::NodeIndex)nested.node;
			value::print_pointer(nested.offset, self.tree.tok_slice(pointer_node.tok(&self.tree)), self.comp, w);
		}
	}
}

<*
 `%s` argument printing a type like Zig `{qt}`: quoted, plus the vector or
 `(aka '...')` suffix. Build with `Parser.fmt_qt`.
*>
struct QtArg
{
	Parser* p;
	type_store::QualType qt;
}

fn sz? QtArg.to_format(&self, Formatter* f) @dynamic
{
	DString w;
	w.init(tmem);
	self.p.write_qual_type(&w, self.qt);
	return f.print(w.str_view());
}

<* `%s` argument printing a value like Zig `{value}`. Build with `Parser.fmt_value`. *>
struct ValueArg
{
	Parser* p;
	value::Value val;
	type_store::QualType qt;
}

fn sz? ValueArg.to_format(&self, Formatter* f) @dynamic
{
	DString w;
	w.init(tmem);
	self.p.write_value(&w, self.val, self.qt);
	return f.print(w.str_view());
}

fn QtArg Parser.fmt_qt(&self, type_store::QualType qt) => { .p = self, .qt = qt };
fn ValueArg Parser.fmt_value(&self, value::Value val, type_store::QualType qt) => { .p = self, .val = val, .qt = qt };
fn ValueArg Parser.fmt_result(&self, parser_result::Result res) => { .p = self, .val = res.val, .qt = res.qt };

<* True when `diag` passes the extension/version gates and is not OFF. *>
fn bool Parser.diag_enabled(&self, parser_diagnostics::ParserDiag diag)
{
	if (!diag.should_emit(&self.comp.langopts, self.extension_suppressed)) return false;
	return self.diagnostics.@enabled(diag);
}

<*
 Zig `Parser.err`: format `$diag` with the varargs and report it at `tok`.
 `$diag.fmt` is a constant here, so `string::tformat`'s `@format` makes c3c
 check the argument count and types at every call site. Disabled diagnostics
 return before any formatting.
*>
macro void? Parser.err(&self, parser_diagnostics::ParserDiag $diag, tokens::TokenIndex tok, ...)
{
	if (!self.diag_enabled($diag)) return;
	return self.emit_parser_diag($diag, string::tformat($diag.fmt, ...$vaarg), tok);
}

<*
 `Parser.err` for a diagnostic chosen at runtime. The format string is not
 constant, so arguments are not checked at compile time; prefer `err`.
*>
fn void? Parser.err_dyn(&self, parser_diagnostics::ParserDiag diag, tokens::TokenIndex tok, args...)
{
	if (!self.diag_enabled(diag)) return;
	return self.emit_parser_diag(diag, string::tformat(diag.fmt, ...args), tok);
}

<* Advance one token without reading beyond the preprocessor's token buffer. *>
fn void Parser.advance(&self)
{
	if (self.tok_i < self.tok_end) self.tok_i++;
}

<* Match Zig `pragma` by replaying consecutive preserved pragma lines in one call. *>
fn bool? Parser.replay_pragma(&self)
{
	bool found = false;
	while (self.is_at(tokenizer::TokenId.KEYWORD_PRAGMA))
	{
		tokens::TokenIndex pragma_tok = self.tok_i;
		tokens::TokenIndex name_tok = pragma_tok + 1;
		if ((usz)name_tok < self.tree.tokens.len)
		{
			String name = self.tree.tok_slice(name_tok);
			if (try handler = self.comp.pragmas.get(name))
			{
				if (handler.parser)
				{
					switch (handler.parser(handler.ctx, self, name_tok))
					{
						case pragma::PragmaResult.FATAL: return PARSING_FAILED~;
						case pragma::PragmaResult.STOP_PREPROCESSING: return PARSING_FAILED~;
						default: break;
					}
				}
			}
		}
		while (!self.at_eof() && !self.is_at(tokenizer::TokenId.NL)) self.advance();
		if (self.is_at(tokenizer::TokenId.NL)) self.advance();
		found = true;
	}
	return found;
}

<* True when the current token is the preprocessor's EOF token (or buffer end). *>
fn bool Parser.at_eof(self)
{
	if (self.tok_i >= self.tok_end) return true;
	return self.tree.tokens[(usz)self.tok_i].id == EOF;
}

<* Tokens that can begin a declaration. Leave these at depth zero so the
 following translation-unit item gets a fresh parse attempt. *>
fn bool recovery_declaration_start(tokenizer::TokenId id)
{
	switch (id)
	{
		case KEYWORD_ATTRIBUTE1: case KEYWORD_ATTRIBUTE2: case KEYWORD_DECLSPEC:
		case KEYWORD_TYPEDEF: case KEYWORD_EXTERN: case KEYWORD_STATIC: case KEYWORD_AUTO:
		case KEYWORD_REGISTER: case KEYWORD_THREAD_LOCAL: case KEYWORD_C23_THREAD_LOCAL:
		case KEYWORD_THREAD: case KEYWORD_INLINE: case KEYWORD_INLINE1: case KEYWORD_INLINE2:
		case KEYWORD_NORETURN: case KEYWORD_VOID: case KEYWORD_BOOL: case KEYWORD_C23_BOOL:
		case KEYWORD_CHAR: case KEYWORD_SHORT: case KEYWORD_INT: case KEYWORD_LONG:
		case KEYWORD_SIGNED: case KEYWORD_SIGNED1: case KEYWORD_SIGNED2: case KEYWORD_UNSIGNED:
		case KEYWORD_FLOAT: case KEYWORD_DOUBLE: case KEYWORD_COMPLEX: case KEYWORD_ATOMIC:
		case KEYWORD_ENUM: case KEYWORD_STRUCT: case KEYWORD_UNION: case KEYWORD_ALIGNAS:
		case KEYWORD_C23_ALIGNAS: case IDENTIFIER: case EXTENDED_IDENTIFIER: case KEYWORD_TYPEOF:
		case KEYWORD_TYPEOF1: case KEYWORD_TYPEOF2: case KEYWORD_TYPEOF_UNQUAL:
		case KEYWORD_EXTENSION: case KEYWORD_BIT_INT:
			return true;
		default: return false;
	}
}

<* Skip a malformed top-level construct through its semicolon or balanced
 close. A following declaration start and `[[` attribute introducer remain
 untouched for the next parse attempt. *>
fn void Parser.recover(&self)
{
	uint parens = 0;
	uint braces = 0;
	uint brackets = 0;
	while (!self.at_eof())
	{
		tokenizer::TokenId id = self.tree.tokens[(usz)self.tok_i].id;
		bool at_depth_zero = parens == 0 && braces == 0 && brackets == 0;
		if (at_depth_zero)
		{
			if (id == tokenizer::TokenId.L_BRACKET && self.is_at(tokenizer::TokenId.L_BRACKET, 1)) return;
			if (recovery_declaration_start(id)) return;
			if (id == tokenizer::TokenId.SEMICOLON || id == tokenizer::TokenId.R_BRACE)
			{
				self.advance();
				return;
			}
		}
		if (id == tokenizer::TokenId.KEYWORD_PRAGMA)
		{
			// The parse loop replays preserved pragmas before each root item.
			return;
		}

		self.advance();
		switch (id)
		{
			case tokenizer::TokenId.L_PAREN: parens++;
			case tokenizer::TokenId.R_PAREN: if (parens > 0) parens--;
			case tokenizer::TokenId.L_BRACE: braces++;
			case tokenizer::TokenId.R_BRACE:
				if (braces > 0) braces--;
				if (parens == 0 && braces == 0 && brackets == 0) return;
			case tokenizer::TokenId.L_BRACKET: brackets++;
			case tokenizer::TokenId.R_BRACKET: if (brackets > 0) brackets--;
			case tokenizer::TokenId.SEMICOLON:
				if (parens == 0 && braces == 0 && brackets == 0) return;
			default: {}
		}
	}
}

<* The parser fault is always recoverable; other grammar faults need the
 handler's explicit classification. *>
fn bool? Parser.is_recoverable_parse_fault(&self, fault parse_fault)
{
	if (parse_fault == PARSING_FAILED) return true;
	if (!self.handler || !&self.handler.is_recoverable_parse_fault) return false;
	bool? result = self.handler.is_recoverable_parse_fault(self, parse_fault);
	if (catch handler_fault = result)
	{
		if (handler_fault == HOOK_ABSENT) return false;
		return handler_fault~;
	}
	return result;
}

<* Dispatch the declaration grammar's legacy type-name callback, or report its absence. *>
fn void? Parser.parse_type_name(&self)
{
	if (self.handler && &self.handler.handle_type_name)
	{
		fault f = @catch(self.handler.handle_type_name(self));
		if (f != HOOK_ABSENT)
		{
			if (f) return f~;
			return;
		}
	}
	return self.grammar_unavailable();
}

<* Dispatch the typed type-name callback, or report its absence. *>
fn type_store::QualType? Parser.parse_typed_type_name(&self)
{
	if (self.handler && &self.handler.handle_typed_type_name)
	{
		type_store::QualType? qt = self.handler.handle_typed_type_name(self);
		if (catch f = qt)
		{
			if (f != HOOK_ABSENT) return f~;
		}
		else
		{
			return qt;
		}
	}
	self.grammar_unavailable()!;
	return PARSING_FAILED~;
}

<* Probe for a type-name in an ambiguous expression production. Missing
   grammar and a grammar-reported non-match both leave the cursor untouched;
   diagnosed parse failures and fatal faults propagate unchanged. The legacy
   typed callback remains a committed parse entry and is not reinterpreted as
   this speculative contract. *>
fn TypeNameProbe? Parser.probe_typed_type_name(&self)
{
	if (!self.handler || !&self.handler.handle_typed_type_name_probe) return { .matched = false };
	tokens::TokenIndex start = self.tok_i;
	TypeNameProbe? maybe_probe = self.handler.handle_typed_type_name_probe(self);
	if (catch f = maybe_probe)
	{
		if (f == HOOK_ABSENT) return { .matched = false };
		return f~;
	}
	TypeNameProbe probe = maybe_probe;
	if (!probe.matched) self.tok_i = start;
	return probe;
}

<* Dispatch the mutually recursive statement/body grammar, or report its absence. *>
fn void? Parser.parse_body(&self)
{
	if (self.handler && &self.handler.handle_body)
	{
		fault f = @catch(self.handler.handle_body(self));
		if (f != HOOK_ABSENT)
		{
			if (f) return f~;
			return;
		}
	}
	return self.grammar_unavailable();
}

fn void? Parser.grammar_unavailable(&self)
{
	if (self.tok_end == 0)
	{
		return self.diagnostics.add(diagnostics::@message(parser_diagnostics::ParserDiag.GRAMMAR_UNAVAILABLE, parser_diagnostics::ParserDiag.GRAMMAR_UNAVAILABLE.fmt));
	}
	tokens::TokenIndex diag_tok = self.tok_i < self.tok_end ? self.tok_i : self.tok_end - 1;
	ExpandedLocation expanded = self.tree.tokens[(usz)diag_tok].loc.expand(self.comp);
	Message m = diagnostics::@message_at(parser_diagnostics::ParserDiag.GRAMMAR_UNAVAILABLE, parser_diagnostics::ParserDiag.GRAMMAR_UNAVAILABLE.fmt, expanded);
	return self.diagnostics.add_with_location(self.comp, m, self.pp.expansion_slice(diag_tok), true);
}

<*
 Parse top-level declarations using the registered callback. Missing grammar
 produces a recoverable diagnostic and consumes one construct at a time.
 Fatal diagnostics propagate after the partially-built Tree is freed.
 On success the caller owns the returned Tree; tokens remain borrowed from pp.
*>
fn Tree? Parser.parse(&self)
{
	assert(self.initialized);
	self.comp.pragmas.before_parse(self.comp);
	if (self.handler && &self.handler.handle_implicit_typedefs)
	{
		fault f = @catch(self.handler.handle_implicit_typedefs(self));
		if (f && f != HOOK_ABSENT)
		{
			self.tree.free();
			self.release_symbols();
			self.initialized = false;
			self.comp.pragmas.after_parse(self.comp);
			return f~;
		}
	}
	self.bind_finalized_tokens();
	while (!self.at_eof())
	{
		bool? replay_result = self.replay_pragma();
		fault pragma_fault = @catch(replay_result);
		if (pragma_fault)
		{
			self.tree.free();
			self.release_symbols();
			self.initialized = false;
			self.comp.pragmas.after_parse(self.comp);
			return pragma_fault~;
		}
		if (try handled = replay_result)
		{
			if (handled) continue;
		}
		tokens::TokenIndex before = self.tok_i;
		fault declaration_fault = HOOK_ABSENT;
		if (self.handler && &self.handler.handle_declaration) declaration_fault = @catch(self.handler.handle_declaration(self));
		if (declaration_fault != HOOK_ABSENT)
		{
			fault f = declaration_fault;
			if (f)
			{
				bool? maybe_recoverable = self.is_recoverable_parse_fault(f);
				if (catch classification_fault = maybe_recoverable)
				{
					self.tree.free();
					self.release_symbols();
					self.initialized = false;
					self.comp.pragmas.after_parse(self.comp);
					return classification_fault~;
				}
				if (maybe_recoverable)
				{
					if (before == self.tok_i)
					{
						self.advance();
					}
					else
					{
						self.recover();
					}
					continue;
				}
				self.tree.free();
				self.release_symbols();
				self.initialized = false;
				self.comp.pragmas.after_parse(self.comp);
				return f~;
			}
		}
		else
		{
			fault f = @catch(self.grammar_unavailable());
			if (f)
			{
				self.tree.free();
				self.release_symbols();
				self.initialized = false;
				self.comp.pragmas.after_parse(self.comp);
				return f~;
			}
			self.recover();
		}
		if (before == self.tok_i && !self.at_eof()) self.advance();
	}
	if (self.handler && &self.handler.handle_translation_unit_end)
	{
		fault finalization_fault = @catch(self.handler.handle_translation_unit_end(self));
		if (finalization_fault && finalization_fault != HOOK_ABSENT)
		{
			self.tree.free();
			self.release_symbols();
			self.initialized = false;
			self.comp.pragmas.after_parse(self.comp);
			return finalization_fault~;
		}
	}
	Tree result = self.tree;
	self.tree = {};
	self.release_symbols();
	self.initialized = false;
	self.comp.pragmas.after_parse(self.comp);
	return result;
}

<*
 Zig `addMaybeUnused`: remember a local declaration so an unused-warning can be
 reported when its function ends. Declarations marked `unused` / `maybe_unused`
 are treated as used. Only locals (inside a function), params, local typedefs,
 labels and empty declarations are tracked, and only while their warning option
 is not OFF. A later `mark_used` on the same node keeps its used state.
*>
fn void? Parser.add_maybe_unused(&self, type_store::NodeIndex decl_node)
{
	// MAYBE_UNUSED is stored as AttributeTag.UNUSED (attribute_wip apply_unused).
	if (self.tree.attr_map.has_attribute(decl_node.pack(), attribute::AttributeTag.UNUSED))
	{
		self.mark_used(decl_node); // Might have added an empty_decl.
		return;
	}

	tree::Node node = decl_node.get(&self.tree);
	switch (node.kind)
	{
		case VARIABLE:
			if (node.variable.storage_class == tree::VariableStorageClass.EXTERN) return;
			if (!self.function_context.active) return;
			if (self.diagnostics.severity(diagnostics::Option.UNUSED_VARIABLE) == diagnostics::MessageKind.OFF) return;
		case PARAM:
			if (self.diagnostics.severity(diagnostics::Option.UNUSED_PARAMETER) == diagnostics::MessageKind.OFF) return;
		case TYPEDEF:
			if (!self.function_context.active) return;
			if (self.diagnostics.severity(diagnostics::Option.UNUSED_LOCAL_TYPEDEF) == diagnostics::MessageKind.OFF) return;
		case LABELED_STMT:
			if (!self.function_context.active) return;
			if (self.diagnostics.severity(diagnostics::Option.UNUSED_LABEL) == diagnostics::MessageKind.OFF) return;
		case EMPTY_DECL:
			if (self.diagnostics.severity(diagnostics::Option.UNUSED_VARIABLE) == diagnostics::MessageKind.OFF) return;
		default:
			return;
	}

	uint key = (uint)decl_node;
	if (self.maybe_unused_decl.has_key(key)) return;
	self.maybe_unused_decl.set(key, false);
	self.maybe_unused_order.push(decl_node);
}

<* Zig `markUsed`: clear the pending report for `decl_node`. Untracked nodes are ignored. *>
fn void Parser.mark_used(&self, type_store::NodeIndex decl_node)
{
	uint key = (uint)decl_node;
	if (self.maybe_unused_decl.has_key(key)) self.maybe_unused_decl.set(key, true);
}

<*
 Zig `diagnoseUnusedLocals`: at function end, report each tracked declaration
 that was never marked used, in declaration order. `local_unused_err_count` is the
 diagnostic error count at body start; reporting is skipped when the body
 raised an error since then. Pending entries are always cleared, including on
 the skipped path.
*>
fn void? Parser.diagnose_unused_locals(&self)
{
	defer self.maybe_unused_decl.clear();
	defer self.maybe_unused_order.clear();
	if (self.diagnostics.errors > self.local_unused_err_count) return;

	foreach (decl_node : self.maybe_unused_order)
	{
		bool used = self.maybe_unused_decl.get((uint)decl_node) ?? true;
		if (used) continue;
		tree::Node node = decl_node.get(&self.tree);
		if (node.kind == tree::NodeKind.EMPTY_DECL) continue;

		tokens::TokenIndex name_tok = decl_node.tok(&self.tree);
		String name = self.tree.tok_slice(name_tok);
		switch (node.kind)
		{
			case VARIABLE: self.err(parser_diagnostics::ParserDiag.UNUSED_VARIABLE, name_tok, name)!;
			case PARAM: self.err(parser_diagnostics::ParserDiag.UNUSED_PARAM, name_tok, name)!;
			case TYPEDEF: self.err(parser_diagnostics::ParserDiag.UNUSED_TYPEDEF, name_tok, name)!;
			case LABELED_STMT: self.err(parser_diagnostics::ParserDiag.UNUSED_LABEL, name_tok, name)!;
			default: unreachable("tracked unused local has no diagnostic");
		}
	}
}

<* Release a context that was initialized but not successfully parsed. *>
fn void Parser.free(&self)
{
	if (self.initialized) self.tree.free();
	self.release_symbols();
	self.maybe_unused_decl.free();
	self.maybe_unused_order.free();
	*self = {};
}
