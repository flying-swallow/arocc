// Parser context and lifecycle (bounded infrastructure port of Parser.zig).
// The declaration, type-name and body grammars live in the embedded
// `DeclarationParser`; this module owns token/tree context, recovery,
// diagnostics and teardown.
module aro::frontend::c::parser;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::preprocessor, aro::source, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::frontend::c::symbol_stack, aro::string_interner, aro::frontend::c::pragma, aro::frontend::c::parser_result, aro::frontend::c::attribute, aro::frontend::c::attribute_map, aro::frontend::c::parser_declaration;
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
interface IParserTestProbe @feat(TESTING)
{
	fn void? handle_declaration(Parser* p) @optional;
	fn void? handle_type_name(Parser* p) @optional;
	fn type_store::QualType? handle_typed_type_name(Parser* p) @optional;
	<* A non-match is successful and must not diagnose or consume input. *>
	fn TypeNameProbe? handle_typed_type_name_probe(Parser* p) @optional;
	fn type_store::NodeIndex? handle_body(Parser* p) @optional;
	fn void? handle_implicit_typedefs(Parser* p) @optional;
	<* Called once after the translation unit's top-level parse loop reaches EOF. *>
	fn void? handle_translation_unit_end(Parser* p) @optional;
	<* Classify grammar faults that the translation-unit loop may recover from. *>
	fn bool? is_recoverable_parse_fault(Parser* p, fault parse_fault) @optional;
	<* Compound statement inside a GNU statement expression. *>
	fn type_store::NodeIndex? handle_statement_expression_body(Parser* p, bool eval) @optional;
}

<* GNU &&label unary expressions. Installed by the statement grammar for the
   duration of a function body. *>
interface IAddressOfLabel
{
	fn parser_result::Result? handle_address_of_label(Parser* p);
}

<*
 Expression productions a sub-grammar (builtins, initializers, statements)
 borrows from its owner. `expression` is optional; a missing method or a
 HOOK_ABSENT fault means the owner does not provide it.
*>
interface IExpressionGrammar
{
	<* Zig `expr`: a full expression, including the comma operator. *>
	fn parser_result::Result? expression(Parser* p, bool eval) @optional;
	<* Zig `assignExpr`. *>
	fn parser_result::Result? assignment_expression(Parser* p, bool eval);
	<* Zig `integerConstExpr` with the given const-declaration folding mode. *>
	fn parser_result::Result? integer_constant_expression(Parser* p, ConstDeclFoldingMode mode, bool eval);
}

<* `Parser.parse_asm_statement` and friends: the current token is not an asm keyword (Zig `null`). *>
excuse NOT_ASM;

<* No token at the requested lookahead (at/beyond EOF), or `eat` found a different token. *>
excuse NO_TOKEN;

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

<* Call-site context visible while parsing an argument expression. *>
struct VaArgPackCallContext
{
	bool active;
	bool variadic;
	bool typed;
}

<* One file-scope declaration in `Parser.file_scope_decls`; `prev` is the 1-based index
   of the previous entry with the same name, 0 if none. *>
struct FileScopeDeclEntry
{
	type_store::NodeIndex node;
	uint prev;
}

<* A parser borrows its preprocessor and token storage; it owns its tree and symbol scopes. *>
struct Parser (IQueryable)
{
	preprocessor::Preprocessor* pp;
	Compilation* comp;
	diagnostics::Diagnostics* diagnostics;
	Tree tree;
	symbol_stack::SymbolStack symbols;
	<* Declaration, type-name and statement grammar state; set up by `Parser.init`. *>
	parser_declaration::DeclarationParser declarations;
	IParserTestProbe test_probe @feat(TESTING);
	IAddressOfLabel address_of_label;
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
	<* Zig `maybe_unused_decl`: pending local declarations keyed by `(uint)NodeIndex`;
	   value is true once the declaration is used. Owned; released by `Parser.free`. *>
	HashMap{uint, bool} maybe_unused_decl;
	<* Enumerator ENUM_FIELD node -> its enum declaration node (both `(uint)NodeIndex`), for
	   reporting uses of enumerators of a deprecated enum. Owned; released by `Parser.free`. *>
	HashMap{uint, uint} enumerator_enum;
	<* Insertion order of `maybe_unused_decl` keys, so reports follow declaration order
	   (Zig's array hash map iterates in insertion order; C3 `HashMap` does not). *>
	List{type_store::NodeIndex} maybe_unused_order;
	<* Deprecated-declaration uses seen inside a declaration whose declarators are not
	   yet known to be deprecated themselves (clang delays them the same way); see
	   `begin_deprecation_deferral`. Owned; released with `maybe_unused_order`. *>
	List{DeferredDeprecation} deferred_deprecations;
	<* Nesting depth of declarations deferring deprecation warnings. *>
	uint deprecation_defer_depth;
	<* Non-zero inside a deprecated declarator, its initializer or its function body:
	   uses of deprecated declarations are not reported there. *>
	uint deprecated_context;
	<* Name index over file-scope FUNCTION/VARIABLE entries of `tree.root_decls`, filled
	   lazily by `DeclarationParser.index_file_scope_decls`. Entries with the same name form
	   a chain through `FileScopeDeclEntry.prev`; `file_scope_decl_head` maps a StringId to
	   the newest entry (both 1-based, 0 = none). Owned; released at the end of `Parser.parse`. *>
	List{FileScopeDeclEntry} file_scope_decls;
	HashMap{uint, uint} file_scope_decl_head;
	<* Number of `tree.root_decls` already scanned into `file_scope_decls`. *>
	usz file_scope_decls_indexed;
	<* Diagnostic error count at body start, set by the declaration parser before a function
	   body is parsed. `Parser.diagnose_unused_locals` skips reporting when errors grew since then. *>
	uint local_unused_err_count;
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
		Diagnostic.VA_FUNC_NOT_IN_FUNC.@emit(self, builtin_tok, builtin_name)!;
		return false;
	}
	if (!context.variadic || context.named_param_count == 0)
	{
		Diagnostic.VA_FUNC_FIXED_ARGS.@emit(self, builtin_tok, builtin_name)!;
		return false;
	}
	if (!self.tree.attr_map.has_attribute(context.declaration, attribute::AttributeTag.ALWAYS_INLINE) &&
	!self.tree.attr_map.has_attribute(context.declaration, attribute::AttributeTag.GNU_INLINE))
	{
		Diagnostic.VA_FUNC_NOT_ALWAYS_INLINE.@emit(self, builtin_tok, builtin_name)!;
		return false;
	}
	return true;
}


<* Current call argument state for a va_arg_pack builtin. *>
fn VaArgPackCallContext Parser.va_arg_pack_call_context(&self) => self.va_arg_pack_call;

<* Add or remove a nested lexical scope. Parser.init creates the outer scope. *>
fn void Parser.push_scope(&self)
{
	self.symbols.push_scope();
}

fn void Parser.pop_scope(&self)
{
	assert(self.symbols.active_len > 1, "cannot pop the parser's outer scope");
	self.symbols.pop_scope();
}

<* Seed a symbol in the current scope; declarator construction remains a grammar callback's job. *>
fn void Parser.define_symbol(&self, symbol_stack::Symbol symbol)
{
	self.symbols.define(symbol);
}

fn parser_result::Result? Parser.parse_initializer(&self, type_store::QualType target, bool eval = true)
{
	tokens::TokenIndex initializer_tok = self.tok_i;
	// Snapshot before the VLA check so an earlier error in this initializer,
	// including VLA_INIT, suppresses the static value check below.
	uint errors_before = self.diagnostics.errors;
	if (try array = target.get(self.comp, type_store::TypeTag.ARRAY))
	{
		if (array.array.len.kind == type_store::ArrayLenKind.VARIABLE ||
			array.array.len.kind == type_store::ArrayLenKind.UNSPECIFIED_VARIABLE)
		{
			Diagnostic.VLA_INIT.@emit(self, initializer_tok)!;
		}
	}
	parser_result::Result result = self.parse_initializer_value(target, eval)!;
	InitContext context = self.init_context;
	// A static initializer that already reported an error is not re-checked for
	// compile-time constness, so the static diagnostic does not repeat an earlier
	// one (option B recovery).
	bool static_after_error = context == InitContext.STATIC && self.diagnostics.errors > errors_before;
	if (!target.is_invalid() && context != InitContext.RUNTIME && !static_after_error &&
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
	return self.symbols.find_symbol(name);
}

fn bool? Parser.find_typedef(&self, string_interner::StringId name, tokens::TokenIndex name_tok, bool no_type_yet, symbol_stack::Symbol* out)
{
	return self.symbols.find_typedef(self, name, name_tok, no_type_yet, out);
}

fn bool? Parser.find_tag(&self, string_interner::StringId name, tokenizer::TokenId kind, tokens::TokenIndex name_tok, tokenizer::TokenId next_tok_id, symbol_stack::Symbol* out)
{
	return self.symbols.find_tag(self, name, kind, name_tok, next_tok_id, out);
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
			if (is_integer_constant) Diagnostic.CONST_DECL_FOLDED.@emit(self, name_tok)!!;
		case GNU_VLA_FOLDING_EXTENSION:
			if (is_integer_constant) Diagnostic.CONST_DECL_FOLDED_VLA.@emit(self, name_tok)!!;
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
fn void Parser.init(&self, preprocessor::Preprocessor* pp)
{
	*self = {};
	self.pp = pp;
	self.comp = pp.comp;
	self.diagnostics = pp.diagnostics;
	self.const_decl_folding = ConstDeclFoldingMode.FOLD_CONST_DECLS;
	self.function_context.func_ident = type_store::NODE_NULL;
	self.function_context.pretty_ident = type_store::NODE_NULL;
	// Parser is not moved after init, so the grammar may point at itself.
	self.declarations.statements.expressions = &self.declarations;
	self.symbols.init(pp.comp.gpa);
	self.symbols.push_scope();
	self.maybe_unused_decl.init(pp.comp.gpa);
	self.enumerator_enum.init(pp.comp.gpa);
	self.maybe_unused_order.init(pp.comp.gpa);
	self.deferred_deprecations.init(pp.comp.gpa);
	self.file_scope_decls.init(pp.comp.gpa);
	self.file_scope_decl_head.init(pp.comp.gpa);
	// The implicit-typedef callback may append generated tokens and grow the
	// preprocessor list. Bind the final slice only after that callback runs.
	self.tree.init(pp.comp, {});
}

<* Current token index, clamped to the terminal end of the borrowed buffer. *>
fn tokens::TokenIndex Parser.current(&self) => self.tok_i;

<* Bind the parser to the current preprocessor token buffer after token growth is complete.
 Call this explicitly when using token helpers without Parser.parse; parse itself binds
 after implicit_typedefs so callbacks retain their existing token-growth behavior. *>
fn void Parser.bind_finalized_tokens(&self)
{
	self.tree.tokens = self.pp.tokens.array_view();
	self.tok_end = (tokens::TokenIndex)self.tree.tokens.len;
	if (self.tok_i > self.tok_end) self.tok_i = self.tok_end;
}

<* Return a token index at a bounded lookahead distance, or NO_TOKEN at/beyond EOF. Index zero is valid. *>
fn tokens::TokenIndex? Parser.peek_index(&self, usz lookahead = 0)
{
	if (self.tok_i >= self.tok_end) return NO_TOKEN~;
	usz remaining = (usz)(self.tok_end - self.tok_i);
	if (lookahead >= remaining) return NO_TOKEN~;
	return (tokens::TokenIndex)((usz)self.tok_i + lookahead);
}

<* Return an inspected token, or NO_TOKEN at/beyond the bound. *>
fn tokens::TreeToken? Parser.peek(&self, usz lookahead = 0)
{
	return self.tree.tokens[(usz)self.peek_index(lookahead)!];
}

<* Text of an in-range token, using Tree.tok_slice for source-backed lexemes. *>
fn String? Parser.peek_text(&self, usz lookahead = 0)
{
	return self.tree.tok_slice(self.peek_index(lookahead)!);
}

<* True when the next in-range token has the requested id. *>
fn bool Parser.is_at(&self, tokenizer::TokenId id, usz lookahead = 0)
{
	if (try tok = self.peek(lookahead)) return tok.id == id;
	return false;
}

<* Consume and return the next token index when it matches; NO_TOKEN on absence/mismatch. *>
fn tokens::TokenIndex? Parser.eat(&self, tokenizer::TokenId id)
{
	if (!self.is_at(id)) return NO_TOKEN~;
	tokens::TokenIndex result = self.tok_i;
	self.advance();
	return result;
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
		if (id == tokenizer::TokenId.R_PAREN)
		{
			Diagnostic.TO_MATCH_PAREN.@emit(self, opener)!;
		}
		else if (id == tokenizer::TokenId.R_BRACE)
		{
			Diagnostic.TO_MATCH_BRACE.@emit(self, opener)!;
		}
		else if (id == tokenizer::TokenId.R_BRACKET)
		{
			Diagnostic.TO_MATCH_BRACKET.@emit(self, opener)!;
		}
		else if (f)
		{
			return f~;
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
		Diagnostic.EXPECTED_EOF.@emit(self, self.diag_index(), expected_text)!;
		return PARSING_FAILED~;
	}
	tokens::TokenIndex tok_i = self.tok_i;
	tokenizer::TokenId actual = self.tree.tokens[(usz)tok_i].id;
	if (actual == tokenizer::TokenId.INVALID)
	{
		Diagnostic.EXPECTED_INVALID.@emit(self, tok_i, expected_text)!;
	}
	else
	{
		Diagnostic.EXPECTED_TOKEN.@emit(self, tok_i, expected_text, actual.symbol())!;
	}
	return PARSING_FAILED~;
}

fn tokens::TokenIndex Parser.diag_index(&self)
{
	if (self.tok_i < self.tok_end) return self.tok_i;
	if (self.tok_end > 0) return self.tok_end - 1;
	return 0;
}

<* What a token-based diagnostic producer (the Parser) exposes to `Diagnostic.emit`. *>
interface IQueryable
{
	fn Compilation* query_comp();
	<* Zig `extension_suppressed`: an `__extension__` is in effect. *>
	fn bool query_extension_suppressed();
	<* Expanded location and macro expansion locs of `tok`; false when `tok` is past the token list. *>
	fn bool query_token_location(tokens::TokenIndex tok, ExpandedLocation* loc, Location[]* expansion_locs);
}

fn Compilation* Parser.query_comp(&self) @dynamic => self.comp;
fn bool Parser.query_extension_suppressed(&self) @dynamic => self.extension_suppressed;

fn bool Parser.query_token_location(&self, tokens::TokenIndex tok, ExpandedLocation* loc, Location[]* expansion_locs) @dynamic
{
	if ((usz)tok >= self.tree.tokens.len) return false;
	*loc = self.tree.tokens[(usz)tok].loc.expand(self.comp);
	*expansion_locs = self.pp.expansion_slice(tok);
	return true;
}

<* Zig `formatQualType`: the quoted type plus its vector/aka suffix (auto types end after the name). *>
fn void Parser.write_qual_type(&self, DString* w, type_store::QualType qt)
{
	w.append_char('\'');
	qt.print(self.comp, w)!!;
	w.append_char('\'');

	if (qt.is_auto()) return;
	if (try vec = qt.get(self.comp, type_store::TypeTag.VECTOR))
	{
		w.appendf(" (vector of %d '", vec.vector.len);
		vec.vector.elem.print_desugared(self.comp, w)!!;
		w.append_string("' values)");
	}
	else if (qt.should_desugar(self.comp))
	{
		w.append_string(" (aka '");
		qt.print_desugared(self.comp, w)!!;
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
		if (val.print(qt, self.comp, w, &nested)!!)
		{
			type_store::NodeIndex pointer_node = (type_store::NodeIndex)nested.node;
			value::print_pointer(nested.offset, self.tree.tok_slice(pointer_node.tok(&self.tree)), self.comp, w)!!;
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
				if (&handler.parser_handler)
				{
					switch (handler.parser_handler(self, name_tok))
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
fn bool Parser.at_eof(&self)
{
	if (self.tok_i >= self.tok_end) return true;
	return self.tree.tokens[(usz)self.tok_i].id == EOF;
}

<* Recover after a root item failed partway: first close the parens, brackets
 and braces the item opened in [start, tok_i) (a failure inside `__typeof (f)`
 must not resume at `f` and parse it as a new declaration), then `recover`. *>
fn void Parser.recover_from(&self, tokens::TokenIndex start)
{
	uint open = 0;
	uint braces = 0;
	for (tokens::TokenIndex i = start; i < self.tok_i; i++)
	{
		switch (self.tree.tokens[(usz)i].id)
		{
			case tokenizer::TokenId.L_BRACE: braces++; open++;
			case tokenizer::TokenId.L_PAREN:
			case tokenizer::TokenId.L_BRACKET:
				open++;
			case tokenizer::TokenId.R_BRACE: if (braces > 0) braces--; nextcase tokenizer::TokenId.R_PAREN;
			case tokenizer::TokenId.R_PAREN:
			case tokenizer::TokenId.R_BRACKET:
				if (open > 0) open--;
			default: break;
		}
	}
	bool was_open = open > 0;
	while (open > 0 && !self.at_eof())
	{
		tokenizer::TokenId id = self.tree.tokens[(usz)self.tok_i].id;
		if (id == tokenizer::TokenId.KEYWORD_PRAGMA) return;
		// Outside braces a `;` cannot be inside the declaration's parentheses:
		// an unclosed `_BitInt(8 x;` ends there.
		if (id == tokenizer::TokenId.SEMICOLON && braces == 0) break;
		self.advance();
		switch (id)
		{
			case tokenizer::TokenId.L_BRACE: braces++; open++;
			case tokenizer::TokenId.L_PAREN:
			case tokenizer::TokenId.L_BRACKET:
				open++;
			case tokenizer::TokenId.R_BRACE: if (braces > 0) braces--; nextcase tokenizer::TokenId.R_PAREN;
			case tokenizer::TokenId.R_PAREN:
			case tokenizer::TokenId.R_BRACKET:
				open--;
			default: break;
		}
	}
	// Still inside the failed declaration (`__typeof (f) g;`): its remaining
	// declarators are not new items. Stop at its `;`, a brace, or a keyword
	// that starts a declaration; `recover` handles the rest.
	while (was_open && !self.at_eof())
	{
		tokenizer::TokenId id = self.tree.tokens[(usz)self.tok_i].id;
		if (id == tokenizer::TokenId.SEMICOLON)
		{
			self.advance();
			return;
		}
		if (id == tokenizer::TokenId.L_BRACE || id == tokenizer::TokenId.R_BRACE || id == tokenizer::TokenId.KEYWORD_PRAGMA) break;
		if (id.starts_declaration() && !id.is_identifier()) break;
		if (id == tokenizer::TokenId.L_PAREN || id == tokenizer::TokenId.L_BRACKET) break;
		self.advance();
	}
	self.recover();
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
			if (id.starts_declaration()) return;
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
	bool? result;
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.is_recoverable_parse_fault)
		{
			result = self.test_probe.is_recoverable_parse_fault(self, parse_fault);
		}
		else
		{
			result = self.declarations.is_recoverable_parse_fault(self, parse_fault);
		}
	$else
		result = self.declarations.is_recoverable_parse_fault(self, parse_fault);
	$endif
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
	$if env::TESTING:
	if (self.test_probe && &self.test_probe.handle_type_name)
	{
		fault f = @catch(self.test_probe.handle_type_name(self));
		if (f != HOOK_ABSENT)
		{
			if (f) return f~;
			return;
		}
	}
	$endif
	fault f = @catch(self.declarations.handle_type_name(self));
	if (f != HOOK_ABSENT)
	{
		if (f) return f~;
		return;
	}
	return self.grammar_unavailable();
}

<* Dispatch the typed type-name callback, or report its absence. *>
fn type_store::QualType? Parser.parse_typed_type_name(&self)
{
	$if env::TESTING:
	if (self.test_probe && &self.test_probe.handle_typed_type_name)
	{
		type_store::QualType? qt = self.test_probe.handle_typed_type_name(self);
		if (catch f = qt)
		{
			if (f != HOOK_ABSENT) return f~;
		}
		else
		{
			return qt;
		}
	}
	$endif
	type_store::QualType? qt = self.declarations.handle_typed_type_name(self);
	if (catch f = qt)
	{
		if (f != HOOK_ABSENT) return f~;
	}
	else { return qt; }
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
	tokens::TokenIndex start = self.tok_i;
	TypeNameProbe? maybe_probe = HOOK_ABSENT~;
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.handle_typed_type_name_probe)
		{
			maybe_probe = self.test_probe.handle_typed_type_name_probe(self);
		}
	$endif
	if (catch f = maybe_probe)
	{
		if (f != HOOK_ABSENT) return f~;
		maybe_probe = self.declarations.handle_typed_type_name_probe(self);
	}
	if (catch f = maybe_probe)
	{
		if (f == HOOK_ABSENT) return { .matched = false };
		return f~;
	}
	TypeNameProbe probe = maybe_probe;
	if (!probe.matched) self.tok_i = start;
	return probe;
}

<* Dispatch the mutually recursive statement/body grammar and return the body
 node, or report its absence and fail with PARSING_FAILED. *>
fn type_store::NodeIndex? Parser.parse_body(&self)
{
	$if env::TESTING:
	if (self.test_probe && &self.test_probe.handle_body)
	{
		type_store::NodeIndex? body = self.test_probe.handle_body(self);
		if (catch f = body)
		{
			if (f != HOOK_ABSENT) return f~;
		}
		else
		{
			return body;
		}
	}
	$endif
	type_store::NodeIndex? body = self.declarations.handle_body(self);
	if (catch f = body)
	{
		if (f != HOOK_ABSENT) return f~;
	}
	else { return body; }
	self.grammar_unavailable()!;
	return PARSING_FAILED~;
}

fn void? Parser.grammar_unavailable(&self)
{
	if (self.tok_end == 0)
	{
		return self.diagnostics.add(diagnostics::@message(Diagnostic.GRAMMAR_UNAVAILABLE, Diagnostic.GRAMMAR_UNAVAILABLE.fmt));
	}
	tokens::TokenIndex diag_tok = self.tok_i < self.tok_end ? self.tok_i : self.tok_end - 1;
	ExpandedLocation expanded = self.tree.tokens[(usz)diag_tok].loc.expand(self.comp);
	Message m = diagnostics::@message_at(Diagnostic.GRAMMAR_UNAVAILABLE, Diagnostic.GRAMMAR_UNAVAILABLE.fmt, expanded);
	return self.diagnostics.add_with_location(self.comp, m, self.pp.expansion_slice(diag_tok), true);
}

<*
 Parse top-level declarations using the registered callback. Missing grammar
 produces a recoverable diagnostic and consumes one construct at a time.
 Fatal diagnostics propagate with the partially-built Tree still owned by the
 Parser. Symbol scopes always stay with the Parser; `Parser.free` releases them.
 On success the caller owns the returned Tree; tokens remain borrowed from pp.
*>
fn Tree? Parser.parse(&self)
{
	// Like Zig Parser.parse's deferred parser-state cleanup, release per-parse
	// unused-local tracking on every success and error return. The returned
	// Tree has independent ownership and remains with the caller.
	defer self.maybe_unused_decl.free();
	defer self.enumerator_enum.free();
	defer self.maybe_unused_order.free();
	defer self.deferred_deprecations.free();
	defer self.file_scope_decls.free();
	defer self.file_scope_decl_head.free();
	self.comp.pragmas.before_parse(self.comp);
	defer self.comp.pragmas.after_parse(self.comp);
	bool prelude_handled = false;
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.handle_implicit_typedefs)
		{
			fault f = @catch(self.test_probe.handle_implicit_typedefs(self));
			if (f && f != HOOK_ABSENT) return f~;
			prelude_handled = !f;
		}
	$endif
	if (!prelude_handled)
	{
		fault f = @catch(self.declarations.handle_implicit_typedefs(self));
		if (f && f != HOOK_ABSENT) return f~;
	}
	self.bind_finalized_tokens();
	while (!self.at_eof())
	{
		bool? replay_result = self.replay_pragma();
		if (catch pragma_fault = replay_result) return pragma_fault~;
		if (replay_result) continue;
		tokens::TokenIndex before = self.tok_i;
		uint errors_before = self.diagnostics.errors;
		fault declaration_fault = @catch(self.handle_declaration());
		if (declaration_fault != HOOK_ABSENT)
		{
			fault f = declaration_fault;
			if (f)
			{
				if (!self.is_recoverable_parse_fault(f)!) return f~;
				// A failed item must not pass silently once recovery skips it.
				if (self.diagnostics.errors == errors_before)
				{
					// Mid-item silent failures so far are operands (unterminated
					// string in an initializer, `(static int){1}`).
					if (self.tok_i > before)
					{
						Diagnostic.EXPECTED_EXPR.@emit(self, self.tok_i - 1)!;
					}
					else
					{
						Diagnostic.EXPECTED_EXTERNAL_DECL.@emit(self, self.tok_i)!;
					}
				}
				if (before == self.tok_i)
				{
					self.advance();
				}
				else
				{
					self.recover_from(before);
				}
				continue;
			}
		}
		else
		{
			self.grammar_unavailable()!;
			self.recover();
		}
		if (before == self.tok_i && !self.at_eof()) self.advance();
	}
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.handle_translation_unit_end)
		{
			fault f = @catch(self.test_probe.handle_translation_unit_end(self));
			if (f && f != HOOK_ABSENT) return f~;
		}
	$endif
	self.declarations.handle_translation_unit_end(self)!;
	Tree result = self.tree;
	self.tree = {};
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

<*
 Zig `checkDeprecatedUnavailable`: report a use at `usage_tok` of a declaration
 marked `unavailable` (error, then PARSING_FAILED) or `deprecated` (warning,
 optional replacement note), each followed by a note at the attribute.
*>
fn void? Parser.check_deprecated_unavailable(&self, type_store::NodeOptIndex node, tokens::TokenIndex usage_tok,
	bool name_from_usage = false)
{
	if (!@ok(node.unpack())) return;
	attribute_map::AttributeMap* am = &self.tree.attr_map;
	if (try attr = am.get_attribute(node, attribute::AttributeTag.UNAVAILABLE))
	{
		attribute::ArgsOptMsg u = attr.args.unavailable;
		self.err_deprecated(usage_tok, self.used_name(node, usage_tok, name_from_usage), true, u.has_msg, u.msg)!;
		Diagnostic.UNAVAILABLE_NOTE.@emit(self, attr.tok, self.decl_name(node))!;
		return PARSING_FAILED~;
	}
	if (!am.has_attribute(node, attribute::AttributeTag.DEPRECATED)) return;
	if (self.deprecated_context > 0) return;
	if (self.deprecation_defer_depth > 0)
	{
		self.deferred_deprecations.push({ node, usage_tok, name_from_usage, false });
		return;
	}
	return self.report_deprecated(node, usage_tok, name_from_usage);
}

<* An enumerator without its own deprecated/unavailable attribute reports its enum's, under the enumerator's name. *>
fn void? Parser.check_enumerator_parent_deprecated(&self, symbol_stack::Symbol symbol, tokens::TokenIndex usage_tok)
{
	type_store::NodeOptIndex own = (type_store::NodeOptIndex)symbol.node;
	if (self.tree.attr_map.has_attribute(own, attribute::AttributeTag.DEPRECATED) ||
		self.tree.attr_map.has_attribute(own, attribute::AttributeTag.UNAVAILABLE)) return;
	uint? parent = self.enumerator_enum.get((uint)symbol.node);
	if (catch parent) return;
	return self.check_deprecated_unavailable((type_store::NodeOptIndex)parent, usage_tok, name_from_usage: true);
}

fn String Parser.decl_name(&self, type_store::NodeOptIndex node)
{
	return self.tree.tok_slice(node.unwrap().tok(&self.tree));
}

fn String Parser.used_name(&self, type_store::NodeOptIndex node, tokens::TokenIndex usage_tok, bool name_from_usage)
{
	return name_from_usage ? self.tree.tok_slice(usage_tok) : self.decl_name(node);
}

fn void? Parser.report_deprecated(&self, type_store::NodeOptIndex node, tokens::TokenIndex usage_tok, bool name_from_usage)
{
	attribute::Attribute attr = self.tree.attr_map.get_attribute(node, attribute::AttributeTag.DEPRECATED)!!;
	attribute::ArgsDeprecated d = attr.args.deprecated;
	self.err_deprecated(usage_tok, self.used_name(node, usage_tok, name_from_usage), false, d.has_msg, d.msg)!;
	if (d.has_replacement) Diagnostic.DEPRECATED_ALTERNATIVE.@emit(self, usage_tok, d.replacement)!;
	Diagnostic.DEPRECATED_NOTE.@emit(self, attr.tok, self.decl_name(node))!;
}

<*
 Start deferring deprecation warnings for one declaration (clang's delayed
 diagnostics): uses in its specifiers and declarators are held until each
 declarator shows whether it is itself deprecated. Returns the mark that
 `flush_deprecations` / `drop_deprecations` take.
*>
fn usz Parser.begin_deprecation_deferral(&self)
{
	self.deprecation_defer_depth++;
	return (usz)self.deferred_deprecations.len();
}

<* End the deferral begun at `mark`; held uses are reported when `flush`, else dropped. *>
fn void? Parser.end_deprecation_deferral(&self, usz mark, bool flush)
{
	self.deprecation_defer_depth--;
	if (flush) return self.flush_deprecations(mark);
	// Every declarator was deprecated: forget the specifiers' uses, but keep the
	// ones nested declarations (members) already settled for the enclosing one.
	usz keep = mark;
	for (usz i = mark; i < (usz)self.deferred_deprecations.len(); i++)
	{
		DeferredDeprecation d = self.deferred_deprecations[(sz)i];
		if (d.committed) self.deferred_deprecations[(sz)keep++] = d;
	}
	self.drop_deprecations(keep);
}

<* Report the uses held since `mark`. An enclosing declaration keeps holding them. *>
fn void? Parser.flush_deprecations(&self, usz mark)
{
	if (self.deprecation_defer_depth > 1)
	{
		// Settled here; the enclosing declaration reports or drops them.
		for (usz i = mark; i < (usz)self.deferred_deprecations.len(); i++) self.deferred_deprecations[(sz)i].committed = true;
		return;
	}
	defer self.drop_deprecations(mark);
	for (usz i = mark; i < (usz)self.deferred_deprecations.len(); i++)
	{
		DeferredDeprecation d = self.deferred_deprecations[(sz)i];
		self.report_deprecated(d.node, d.usage_tok, d.name_from_usage)!;
	}
}

<* Forget the uses held since `mark` (a deprecated declarator). *>
fn void Parser.drop_deprecations(&self, usz mark)
{
	while ((usz)self.deferred_deprecations.len() > mark) self.deferred_deprecations.pop()!!;
}

struct DeferredDeprecation
{
	type_store::NodeOptIndex node;
	tokens::TokenIndex usage_tok;
	bool name_from_usage;
	<* Settled by a nested declaration; survives its enclosing declaration's specifier drop. *>
	bool committed;
}

<* Zig `errDeprecated`: "'name' is deprecated[: msg]" / "'name' is unavailable[: msg]". *>
fn void? Parser.err_deprecated(&self, tokens::TokenIndex tok, String name, bool unavailable, bool has_msg, String msg)
{
	@pool()
	{
		DString escaped = dstring::temp();
		if (has_msg) parser_result::append_escaped(&escaped, msg)!;
		String colon = has_msg ? ": " : "";
		if (unavailable)
		{
			Diagnostic.UNAVAILABLE.@emit(self, tok, name, colon, escaped.str_view())!;
		}
		else
		{
			Diagnostic.DEPRECATED_DECLARATIONS.@emit(self, tok, name, colon, escaped.str_view())!;
		}
	};
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
			case VARIABLE: Diagnostic.UNUSED_VARIABLE.@emit(self, name_tok, name)!;
			case PARAM: Diagnostic.UNUSED_PARAM.@emit(self, name_tok, name)!;
			case TYPEDEF: Diagnostic.UNUSED_TYPEDEF.@emit(self, name_tok, name)!;
			case LABELED_STMT: Diagnostic.UNUSED_LABEL.@emit(self, name_tok, name)!;
			default: unreachable("tracked unused local has no diagnostic");
		}
	}
}

<* Release all parser-owned state. Safe after success, failure, or init-only. *>
fn void Parser.free(&self)
{
	self.tree.free();
	self.maybe_unused_decl.free();
	self.enumerator_enum.free();
	self.maybe_unused_order.free();
	self.deferred_deprecations.free();
	self.file_scope_decls.free();
	self.file_scope_decl_head.free();
	// Drop every active scope (including the outer one from init) before freeing storage.
	self.symbols.active_len = 0;
	self.symbols.free();
	*self = {};
}
