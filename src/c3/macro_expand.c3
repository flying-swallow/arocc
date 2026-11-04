// Macro definition and expansion from src/aro/Preprocessor.zig.
// OWNER: plan 13.3 `expansion`.
//
// Ownership: every TokenWithExpansionLocs in an ExpandBuf / MacroArguments
// owns its expansion array (see tokens.c3). Tokens taken out of `buf` must be
// freed or moved; tokens copied in must be `dupe`d. Use the helpers in
// preprocessor.c3 (free_buf_tokens, remove_placemarkers, buf_copy_tokens,
// deinit_macro_arguments, get_paste_args).
//
// Ported: Macro.eql, defineMacro, define, defineFn, expandObjMacro (builtin
// object macros go to BuiltinProvider.expand_obj), expandFuncMacro (builtin
// function macros go to BuiltinProvider.expand_func), expandVaOpt,
// nextBufToken, collectMacroFuncArguments, removeExpandedTokens,
// TokenIterator, expandMacroExhaustive, expandMacro, addTokensFromExpandBuf.
//
// Deviations from Zig (ownership only; the token stream is unchanged):
//  - On a fault, expansion arrays that Zig leaks (Zig's errdefer only
//    deinit()s the lists) are freed: the partial result of
//    expand_obj_macro / expand_func_macro, an expansion result not yet
//    moved into `buf`, and top_expansion_buf when expand_macro fails.
//  - Zig's `ArrayList.replaceRange` is `replace_range` below; moved tokens
//    keep their arrays (no copy).
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::hideset, aro::compilation, aro::diagnostics;
import std::collections::list, std::core::string;

<*
 Zig `Macro.eql`: same token count, equal builtin kinds, pairwise equal
 tok_slice of the body tokens, and for two function macros equal var_args
 and parameter names.
*>
fn bool Macro.eql(&self, Macro* b, Preprocessor* pp)
{
	if (self.tokens.len != b.tokens.len) return false;
	// std.meta.eql on two ?Builtin: both null, or both set and equal.
	if (self.has_builtin_kind != b.has_builtin_kind) return false;
	if (self.has_builtin_kind && !self.builtin_kind.eql(b.builtin_kind)) return false;
	foreach (i, a_tok : self.tokens)
	{
		if (pp.tok_slice(a_tok) != pp.tok_slice(b.tokens[i])) return false;
	}
	if (self.is_func && b.is_func)
	{
		if (self.var_args != b.var_args) return false;
		if (self.params.len != b.params.len) return false;
		foreach (i, p : self.params)
		{
			if (p != b.params[i]) return false;
		}
	}
	return true;
}

<*
 Zig `defineMacro`: insert or replace `name_tok`'s macro. If a different
 definition exists: builtin -> DIAG_BUILTIN_MACRO_REDEFINED at name_tok.loc,
 else DIAG_MACRO_REDEFINED (name); then, for a non-builtin and only if that
 diagnostic was actually emitted (diagnostics.total changed), note
 DIAG_PREVIOUS_DEFINITION at the old macro's loc. verbose: "macro <name>
 defined". store_macro_tokens: add the `define_tok` (KEYWORD_DEFINE) token.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.define_macro(&self, RawToken define_tok, TokenWithExpansionLocs name_tok, Macro m)
{
	String name_str = self.expanded_slice(name_tok);
	bool found_existing;
	Macro* gop = self.defines.get_or_put(name_str, &found_existing);
	if (found_existing && !gop.eql(&m, self))
	{
		Location loc = name_tok.loc;
		uint prev_total = self.diagnostics.total;
		bool was_builtin = gop.is_builtin();
		Location old_loc = gop.loc;
		if (was_builtin)
		{
			self.err_loc(loc, DIAG_BUILTIN_MACRO_REDEFINED)!;
		}
		else
		{
			self.err_loc(loc, DIAG_MACRO_REDEFINED, { diagnostics::arg_str(name_str) })!;
		}
		if (!was_builtin && self.diagnostics.total != prev_total)
		{
			self.err_loc(old_loc, DIAG_PREVIOUS_DEFINITION)!;
		}
	}
	if (self.verbose)
	{
		RawToken raw = { .id = name_tok.id, .source = name_tok.loc.id, .start = name_tok.loc.byte_offset, .line = name_tok.loc.line };
		self.verbose_log(raw, string::tformat("macro %s defined", name_str));
	}
	if (self.store_macro_tokens)
	{
		self.add_token(tokens::from_raw(define_tok))!;
	}
	// add_token does not touch `defines`, so `gop` is still valid.
	*gop = m;
}

<* Copy `items` into the preprocessor arena (Zig `arena.dupe`). *>
fn RawToken[] Preprocessor.arena_dupe_tokens(&self, RawToken[] items)
{
	if (!items.len) return {};
	RawToken[] copy = alloc::new_array(&self.arena, RawToken, items.len);
	copy[..] = items[..];
	return copy;
}

<* Copy `items` into the preprocessor arena (Zig `arena.dupe`). *>
fn String[] Preprocessor.arena_dupe_strings(&self, String[] items)
{
	if (!items.len) return {};
	String[] copy = alloc::new_array(&self.arena, String, items.len);
	copy[..] = items[..];
	return copy;
}

<* True when `raw` is a macro identifier listed by #pragma GCC poison. *>
fn bool Preprocessor.is_poisoned(&self, RawToken raw)
{
	return raw.id.is_macro_identifier() && @ok(self.poisoned_identifiers.find(self.tok_slice(raw)));
}

const RawToken GENERATED_MACRO_WS @private = { .id = MACRO_WS, .source = source::GENERATED_ID };

<*
 Zig `define`: handle `#define` after the directive token. Name: `defined`
 -> DIAG_DEFINED_AS_MACRO_NAME + skip_to_nl; not a macro identifier ->
 DIAG_MACRO_NAME_MUST_BE_IDENTIFIER + skip_to_nl; unescape_ucn the name (its
 expansion array is freed at the end); a keyword (after simplify) outside
 "<builtin>" -> DIAG_KEYWORD_MACRO. First body token: nl/eof -> empty object
 macro; '(' directly -> define_fn; whitespace -> skip; anything else ->
 DIAG_WHITESPACE_AFTER_MACRO_NAME. Leading '##' -> DIAG_HASH_HASH_AT_START.
 Body: simplify macro keywords; '##' takes next_no_ws_comments and errors
 DIAG_HASH_HASH_AT_END on nl/eof/'##' (returns without defining); comments kept
 only with preserve_comments_in_macros; whitespace runs become one generated
 MACRO_WS before the next kept token; invalid literal tokens warn
 (invalid_token_diagnostic) and are kept; unterminated comment errors;
 poisoned identifiers and INCOMPLETE_UCN diagnose. Tokens are copied from
 token_buf into the arena.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.define(&self, Tokenizer* tokenizer, RawToken define_tok)
{
	// Get macro name and validate it.
	RawToken escaped_macro_name = tokenizer.next_no_ws();
	if (escaped_macro_name.id == KEYWORD_DEFINED)
	{
		self.err_raw(escaped_macro_name, DIAG_DEFINED_AS_MACRO_NAME)!;
		skip_to_nl(tokenizer);
		return;
	}
	if (!escaped_macro_name.id.is_macro_identifier())
	{
		self.err_raw(escaped_macro_name, DIAG_MACRO_NAME_MUST_BE_IDENTIFIER)!;
		skip_to_nl(tokenizer);
		return;
	}
	Allocator gpa = self.comp.gpa;
	TokenWithExpansionLocs macro_name = self.unescape_ucn(tokens::from_raw(escaped_macro_name))!;
	defer tokens::free_expansion_locs(gpa, macro_name.expansion_locs);

	TokenId macro_name_token_id = macro_name.id;
	macro_name_token_id.simplify_macro_keyword();
	switch (macro_name_token_id)
	{
		case IDENTIFIER:
		case EXTENDED_IDENTIFIER:
			break;
		default:
			// TODO (Zig) allow #define <keyword> <keyword> and #define extern|inline|static|const
			if (macro_name_token_id.is_macro_identifier() && self.comp.get_source(tokenizer.source).path != "<builtin>")
			{
				self.err(macro_name, DIAG_KEYWORD_MACRO)!;
			}
	}

	// Check for function macros and empty defines.
	RawToken first = tokenizer.next();
	switch (first.id)
	{
		case NL:
		case EOF:
			return self.define_macro(define_tok, macro_name, {
				.params = {},
				.tokens = {},
				.var_args = false,
				.loc = macro_name.loc,
				.is_func = false,
			});
		case WHITESPACE:
			first = tokenizer.next();
		case L_PAREN:
			return self.define_fn(tokenizer, define_tok, macro_name, first);
		default:
			self.err_raw(first, DIAG_WHITESPACE_AFTER_MACRO_NAME)!;
	}
	if (first.id == HASH_HASH)
	{
		self.err_raw(first, DIAG_HASH_HASH_AT_START)!;
		skip_to_nl(tokenizer);
		return;
	}
	first.id.simplify_macro_keyword();

	self.token_buf.clear(); // Safe to use since we can only be in one directive at a time.

	bool need_ws = false;
	// Collect the token body and validate any ## found.
	RawToken tok = first;
	while BODY: (true)
	{
		tok.id.simplify_macro_keyword();
		switch (tok.id)
		{
			case HASH_HASH:
				RawToken next = tokenizer.next_no_ws_comments();
				switch (next.id)
				{
					case NL:
					case EOF:
						self.err_raw(tok, DIAG_HASH_HASH_AT_END)!;
						return;
					case HASH_HASH:
						self.err_raw(next, DIAG_HASH_HASH_AT_END)!;
						return;
					default:
						break;
				}
				self.token_buf.push(tok);
				self.token_buf.push(next);
			case NL:
			case EOF:
				break BODY;
			case COMMENT:
				if (self.comp.langopts.preserve_comments_in_macros)
				{
					if (need_ws)
					{
						need_ws = false;
						self.token_buf.push(GENERATED_MACRO_WS);
					}
					self.token_buf.push(tok);
				}
			case WHITESPACE:
				need_ws = true;
			case UNTERMINATED_STRING_LITERAL:
			case UNTERMINATED_CHAR_LITERAL:
			case EMPTY_CHAR_LITERAL:
				self.err_raw(tok, invalid_token_diagnostic(tok.id))!;
				self.token_buf.push(tok);
			case UNTERMINATED_COMMENT:
				self.err_raw(tok, DIAG_UNTERMINATED_COMMENT)!;
			default:
				if (self.is_poisoned(tok)) self.err_raw(tok, DIAG_POISONED_IDENTIFIER)!;
				if (tok.id == INCOMPLETE_UCN) self.err_raw(tok, DIAG_INCOMPLETE_UCN)!;
				if (tok.id != WHITESPACE && need_ws)
				{
					need_ws = false;
					self.token_buf.push(GENERATED_MACRO_WS);
				}
				self.token_buf.push(tok);
		}
		tok = tokenizer.next();
	}

	RawToken[] list = self.arena_dupe_tokens(self.token_buf.array_view());
	self.define_macro(define_tok, macro_name, {
		.loc = macro_name.loc,
		.tokens = list,
		.params = {},
		.is_func = false,
		.var_args = false,
	})!;
}

<*
 Zig `defineFn`: parameter list (`...` -> var_args; `name...` -> GNU named
 variadic with DIAG_GNU_VA_MACRO; DIAG_UNTERMINATED_MACRO_PARAM_LIST at eof;
 DIAG_MISSING_PAREN_PARAM_LIST + note DIAG_TO_MATCH_PAREN at `l_paren`;
 DIAG_INVALID_TOKEN_PARAM_LIST; DIAG_EXPECTED_COMMA_PARAM_LIST) and body:
 '#' must be followed by a parameter / __VA_ARGS__ / the GNU variadic name
 (STRINGIFY_PARAM with end = index, STRINGIFY_VA_ARGS) else
 DIAG_HASH_NOT_FOLLOWED_PARAM; '##' at start/end errors, a MACRO_PARAM right
 before '##' becomes MACRO_PARAM_NO_EXPAND; __VA_OPT__ needs '(' (else
 DIAG_VA_OPT_LPAREN) and its token's start..end span the contents up to the
 matching ')' (nl/eof -> DIAG_VA_OPT_RPAREN + note TO_MATCH_PAREN);
 parameter names become MACRO_PARAM (end = index), the GNU variadic name
 KEYWORD_VA_ARGS. Whitespace handling as in `define` (need_ws only after the
 first body token). Params and tokens are copied into the arena.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.define_fn(&self, Tokenizer* tokenizer, RawToken define_tok, TokenWithExpansionLocs macro_name, RawToken l_paren)
{
	assert(macro_name.id.is_macro_identifier());
	Allocator gpa = self.comp.gpa;
	List{String} params;
	params.init(gpa);
	defer params.free();

	// Parse the parameter list.
	String gnu_var_args = "";
	bool var_args = false;
	while (true)
	{
		RawToken tok = tokenizer.next_no_ws();
		if (tok.id == R_PAREN) break;
		if (tok.id == EOF) return self.err_raw(tok, DIAG_UNTERMINATED_MACRO_PARAM_LIST);
		if (tok.id == ELLIPSIS)
		{
			var_args = true;
			RawToken r_paren = tokenizer.next_no_ws();
			if (r_paren.id != R_PAREN)
			{
				self.err_raw(r_paren, DIAG_MISSING_PAREN_PARAM_LIST)!;
				self.err_raw(l_paren, DIAG_TO_MATCH_PAREN)!;
				skip_to_nl(tokenizer);
				return;
			}
			break;
		}
		if (!tok.id.is_macro_identifier())
		{
			self.err_raw(tok, DIAG_INVALID_TOKEN_PARAM_LIST)!;
			skip_to_nl(tokenizer);
			return;
		}

		params.push(self.tok_slice(tok));

		tok = tokenizer.next_no_ws();
		if (tok.id == ELLIPSIS)
		{
			self.err_raw(tok, DIAG_GNU_VA_MACRO)!;
			gnu_var_args = params.pop()!!;
			RawToken r_paren = tokenizer.next_no_ws();
			if (r_paren.id != R_PAREN)
			{
				self.err_raw(r_paren, DIAG_MISSING_PAREN_PARAM_LIST)!;
				self.err_raw(l_paren, DIAG_TO_MATCH_PAREN)!;
				skip_to_nl(tokenizer);
				return;
			}
			break;
		}
		else if (tok.id == R_PAREN)
		{
			break;
		}
		else if (tok.id != COMMA)
		{
			self.err_raw(tok, DIAG_EXPECTED_COMMA_PARAM_LIST)!;
			skip_to_nl(tokenizer);
			return;
		}
	}

	bool need_ws = false;
	// Collect the body tokens and validate # and ##'s found.
	self.token_buf.clear(); // Safe to use since we can only be in one directive at a time.
	while TOK_LOOP: (true)
	{
		RawToken tok = tokenizer.next();
		switch (tok.id)
		{
			case NL:
			case EOF:
				break TOK_LOOP;
			case WHITESPACE:
				need_ws = self.token_buf.len() != 0;
			case COMMENT:
				if (!self.comp.langopts.preserve_comments_in_macros) continue TOK_LOOP;
				if (need_ws)
				{
					need_ws = false;
					self.token_buf.push(GENERATED_MACRO_WS);
				}
				self.token_buf.push(tok);
			case HASH:
				if (tok.id != WHITESPACE && need_ws)
				{
					need_ws = false;
					self.token_buf.push(GENERATED_MACRO_WS);
				}
				RawToken param = tokenizer.next_no_ws();
				if (var_args && param.id == KEYWORD_VA_ARGS)
				{
					tok.id = STRINGIFY_VA_ARGS;
					self.token_buf.push(tok);
					continue TOK_LOOP;
				}
				if (param.id.is_macro_identifier())
				{
					String s = self.tok_slice(param);
					if (s == gnu_var_args)
					{
						tok.id = STRINGIFY_VA_ARGS;
						self.token_buf.push(tok);
						continue TOK_LOOP;
					}
					foreach (i, p : params)
					{
						if (p == s)
						{
							tok.id = STRINGIFY_PARAM;
							tok.end = (uint)i;
							self.token_buf.push(tok);
							continue TOK_LOOP;
						}
					}
				}
				self.err_raw(param, DIAG_HASH_NOT_FOLLOWED_PARAM)!;
				skip_to_nl(tokenizer);
				return;
			case HASH_HASH:
				need_ws = false;
				// if ## appears at the beginning, the token buf is still empty
				// in this case, error out
				if (self.token_buf.len() == 0)
				{
					self.err_raw(tok, DIAG_HASH_HASH_AT_START)!;
					skip_to_nl(tokenizer);
					return;
				}
				Tokenizer saved_tokenizer = *tokenizer;
				RawToken next = tokenizer.next_no_ws_comments();
				if (next.id == NL || next.id == EOF)
				{
					self.err_raw(tok, DIAG_HASH_HASH_AT_END)!;
					return;
				}
				*tokenizer = saved_tokenizer;
				// convert the previous token to MACRO_PARAM_NO_EXPAND if it was MACRO_PARAM
				sz last = self.token_buf.len() - 1;
				if (self.token_buf.entries[last].id == MACRO_PARAM) self.token_buf.entries[last].id = MACRO_PARAM_NO_EXPAND;
				self.token_buf.push(tok);
			case UNTERMINATED_STRING_LITERAL:
			case UNTERMINATED_CHAR_LITERAL:
			case EMPTY_CHAR_LITERAL:
				self.err_raw(tok, invalid_token_diagnostic(tok.id))!;
				self.token_buf.push(tok);
			case UNTERMINATED_COMMENT:
				self.err_raw(tok, DIAG_UNTERMINATED_COMMENT)!;
			default:
				if (self.is_poisoned(tok)) self.err_raw(tok, DIAG_POISONED_IDENTIFIER)!;
				if (tok.id != WHITESPACE && need_ws)
				{
					need_ws = false;
					self.token_buf.push(GENERATED_MACRO_WS);
				}
				if (var_args && tok.id == KEYWORD_VA_ARGS)
				{
					// do nothing
				}
				else if (var_args && tok.id == KEYWORD_VA_OPT)
				{
					RawToken opt_l_paren = tokenizer.next();
					if (opt_l_paren.id != L_PAREN)
					{
						self.err_raw(opt_l_paren, DIAG_VA_OPT_LPAREN)!;
						skip_to_nl(tokenizer);
						return;
					}
					tok.start = opt_l_paren.end;

					uint parens = 0;
					while VA_OPT: (true)
					{
						RawToken opt_tok = tokenizer.next();
						switch (opt_tok.id)
						{
							case L_PAREN:
								parens++;
							case R_PAREN:
								if (parens == 0) break VA_OPT;
								parens--;
							case NL:
							case EOF:
								self.err_raw(opt_tok, DIAG_VA_OPT_RPAREN)!;
								self.err_raw(opt_l_paren, DIAG_TO_MATCH_PAREN)!;
								skip_to_nl(tokenizer);
								return;
							case WHITESPACE:
								break;
							default:
								tok.end = opt_tok.end;
						}
					}
				}
				else if (tok.id.is_macro_identifier())
				{
					tok.id.simplify_macro_keyword();
					String s = self.tok_slice(tok);
					if (gnu_var_args == s)
					{
						tok.id = KEYWORD_VA_ARGS;
					}
					else
					{
						foreach (i, p : params)
						{
							if (p == s)
							{
								// NOTE (Zig): it doesn't matter to assign MACRO_PARAM_NO_EXPAND
								// here in case a ## was the previous token, because
								// ## processing will eat this token with the same semantics
								tok.id = MACRO_PARAM;
								tok.end = (uint)i;
								break;
							}
						}
					}
				}
				self.token_buf.push(tok);
		}
	}

	String[] param_list = self.arena_dupe_strings(params.array_view());
	RawToken[] token_list = self.arena_dupe_tokens(self.token_buf.array_view());
	self.define_macro(define_tok, macro_name, {
		.is_func = true,
		.params = param_list,
		.var_args = var_args || gnu_var_args.len != 0,
		.tokens = token_list,
		.loc = macro_name.loc,
	})!;
}

<*
 Zig `expandObjMacro`: a new ExpandBuf for an object-like macro. Empty body
 -> one generated PLACEMARKER. '##' pastes the next non-whitespace (and,
 without preserve_comments_in_macros, non-comment) token onto the buffer
 with paste_tokens; WHITESPACE is kept only with preserve_whitespace;
 MACRO_BUILTIN_OBJ goes to builtins.expand_obj; everything else is
 tokens::from_raw. The caller owns the result.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn ExpandBuf? Preprocessor.expand_obj_macro(&self, Macro* simple_macro)
{
	Allocator gpa = self.comp.gpa;
	ExpandBuf buf;
	buf.init(gpa);
	defer catch free_expand_buf(gpa, &buf);
	if (simple_macro.tokens.len == 0)
	{
		buf.push({ .id = PLACEMARKER, .loc = { .id = source::GENERATED_ID } });
		return buf;
	}
	buf.reserve(simple_macro.tokens.len);

	// Add all of the simple_macros tokens to the new buffer handling any concats.
	for (sz i = 0; i < simple_macro.tokens.len; i++)
	{
		RawToken raw = simple_macro.tokens[i];
		TokenWithExpansionLocs tok = tokens::from_raw(raw);
		switch (raw.id)
		{
			case HASH_HASH:
				TokenWithExpansionLocs rhs = tokens::from_raw(simple_macro.tokens[i + 1]);
				i++;
				while (true)
				{
					if (rhs.id == WHITESPACE)
					{
						rhs = tokens::from_raw(simple_macro.tokens[i + 1]);
						i++;
					}
					else if (rhs.id == COMMENT && !self.comp.langopts.preserve_comments_in_macros)
					{
						rhs = tokens::from_raw(simple_macro.tokens[i + 1]);
						i++;
					}
					else
					{
						break;
					}
				}
				TokenWithExpansionLocs[1] one = { rhs };
				self.paste_tokens(&buf, one[..])!;
			case WHITESPACE:
				if (self.preserve_whitespace) buf.push(tok);
			case MACRO_BUILTIN_OBJ:
				buf.reserve(1);
				self.builtins.expand_obj(self.builtins.ctx, self, simple_macro.builtin_kind.obj, tok, &buf)!;
			default:
				buf.push(tok);
		}
	}
	return buf;
}

<*
 Zig `expandFuncMacro`: substitute `args` / `expanded_args` into the body.
 Variadic part: args from params.len on joined by generated commas (raw and
 expanded copies). '##' loops over following tokens (skipping MACRO_WS, '##',
 comments without -CC) pasting get_paste_args(arg) for parameters, the raw
 variadic tokens (or a PLACEMARKER plus DIAG_NO_ARGUMENT_VARIADIC_MACRO when
 empty) for __VA_ARGS__, expand_va_opt output for __VA_OPT__ (stop if empty).
 MACRO_PARAM_NO_EXPAND copies get_paste_args(raw arg), MACRO_PARAM the
 expanded arg, KEYWORD_VA_ARGS the expanded variadic part (buf_copy_tokens
 with the body token's location); KEYWORD_VA_OPT -> expand_va_opt;
 STRINGIFY_* -> stringify into char_buf, copy to generated_buf, one
 make_generated_token STRING_LITERAL; MACRO_PARAM_BUILTIN_FUNC ->
 builtins.expand_func; ', ## __VA_ARGS__' implements GNU comma deletion with
 DIAG_COMMA_DELETION_VA_ARGS exactly as Zig (incl. the GNU-standard
 ambiguity rule). Then remove_placemarkers and, for each result token, add
 macro_tok.loc and macro_tok's expansion locations, and for tokens with
 should_track_hideset(FUNC) set hideset(tok.loc) = union(hideset(tok.loc), hs).
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn ExpandBuf? Preprocessor.expand_func_macro(&self, TokenWithExpansionLocs macro_tok, Macro* func_macro, MacroArguments* args, MacroArguments* expanded_args, HidesetIndex hs, EvalContext eval_ctx)
{
	Allocator gpa = self.comp.gpa;
	ExpandBuf buf;
	buf.init(gpa);
	defer catch free_expand_buf(gpa, &buf);
	buf.reserve(func_macro.tokens.len);

	// Shallow copies: these lists borrow the arguments' tokens.
	ExpandBuf expanded_variable_arguments;
	expanded_variable_arguments.init(gpa);
	defer expanded_variable_arguments.free();
	ExpandBuf variable_arguments;
	variable_arguments.init(gpa);
	defer variable_arguments.free();

	if (func_macro.var_args)
	{
		sz n = expanded_args.len();
		for (sz i = func_macro.params.len; i < n; i++)
		{
			variable_arguments.push_all(args.entries[i]);
			expanded_variable_arguments.push_all(expanded_args.entries[i]);
			if (i != n - 1)
			{
				TokenWithExpansionLocs comma = { .id = COMMA, .loc = { .id = source::GENERATED_ID } };
				variable_arguments.push(comma);
				expanded_variable_arguments.push(comma);
			}
		}
	}

	// token concatenation and expansion phase
	sz body_len = func_macro.tokens.len;
	for BODY: (sz tok_i = 0; tok_i < body_len; tok_i++)
	{
		RawToken raw = func_macro.tokens[tok_i];
		Location raw_loc = tokens::raw_location(raw);
		switch (raw.id)
		{
			case HASH_HASH:
				while PASTE: (tok_i + 1 < body_len)
				{
					RawToken raw_next = func_macro.tokens[tok_i + 1];
					tok_i++;

					ExpandBuf va_opt_buf;
					va_opt_buf.init(gpa);
					defer va_opt_buf.free(); // tokens from expand_va_opt own no arrays

					TokenWithExpansionLocs[1] one;
					TokenWithExpansionLocs[] next;
					switch (raw_next.id)
					{
						case MACRO_WS:
						case HASH_HASH:
							continue PASTE;
						case COMMENT:
							if (!self.comp.langopts.preserve_comments_in_macros) continue PASTE;
							one[0] = tokens::from_raw(raw_next);
							next = one[..];
						case MACRO_PARAM:
						case MACRO_PARAM_NO_EXPAND:
							next = get_paste_args(args.entries[raw_next.end]);
						case KEYWORD_VA_ARGS:
							if (variable_arguments.len() == 0)
							{
								self.err_raw(raw_next, DIAG_NO_ARGUMENT_VARIADIC_MACRO)!;
								one[0] = { .id = PLACEMARKER, .loc = { .id = source::GENERATED_ID } };
								next = one[..];
							}
							else
							{
								next = variable_arguments.array_view();
							}
						case KEYWORD_VA_OPT:
							self.expand_va_opt(&va_opt_buf, raw_next, variable_arguments.len() != 0);
							if (va_opt_buf.len() == 0) break PASTE;
							next = va_opt_buf.array_view();
						default:
							one[0] = tokens::from_raw(raw_next);
							next = one[..];
					}
					self.paste_tokens(&buf, next)!;
					if (next.len != 0) break PASTE;
				}
			case MACRO_PARAM_NO_EXPAND:
				TokenWithExpansionLocs[] slice = get_paste_args(args.entries[raw.end]);
				buf_copy_tokens(gpa, &buf, slice, { raw_loc });
			case MACRO_PARAM:
				buf_copy_tokens(gpa, &buf, expanded_args.entries[raw.end], { raw_loc });
			case KEYWORD_VA_ARGS:
				buf_copy_tokens(gpa, &buf, expanded_variable_arguments.array_view(), { raw_loc });
			case KEYWORD_VA_OPT:
				self.expand_va_opt(&buf, raw, variable_arguments.len() != 0);
			case STRINGIFY_PARAM:
			case STRINGIFY_VA_ARGS:
				TokenWithExpansionLocs[] arg = raw.id == STRINGIFY_VA_ARGS ? variable_arguments.array_view() : args.entries[raw.end];
				self.char_buf.clear();
				self.stringify(arg)!;
				sz start = self.comp.generated_buf.len();
				self.comp.generated_buf.push_all(self.char_buf.array_view());
				buf.push(self.make_generated_token(start, STRING_LITERAL, tokens::from_raw(raw)));
			case MACRO_PARAM_BUILTIN_FUNC:
				self.builtins.expand_func(self.builtins.ctx, self, func_macro.builtin_kind.func, macro_tok, raw, expanded_args, eval_ctx, &buf)!;
			case COMMA:
				if (tok_i + 2 < body_len && func_macro.tokens[tok_i + 1].id == HASH_HASH)
				{
					RawToken hash_hash = func_macro.tokens[tok_i + 1];
					RawToken maybe_va_args = func_macro.tokens[tok_i + 2];
					sz consumed = 2;
					if (maybe_va_args.id == MACRO_WS && tok_i + 3 < body_len)
					{
						consumed = 3;
						maybe_va_args = func_macro.tokens[tok_i + 3];
					}
					if (maybe_va_args.id == KEYWORD_VA_ARGS)
					{
						// GNU extension: `, ##__VA_ARGS__` deletes the comma if __VA_ARGS__ is empty
						tok_i += consumed;
						if (func_macro.params.len == expanded_args.len())
						{
							// Empty __VA_ARGS__, drop the comma
							self.err_raw(hash_hash, DIAG_COMMA_DELETION_VA_ARGS)!;
						}
						else if (func_macro.params.len == 0 && expanded_args.len() == 1 && expanded_args.entries[0].len == 0)
						{
							// Ambiguous whether this is "empty __VA_ARGS__" or "__VA_ARGS__ omitted"
							if (self.comp.langopts.standard.is_gnu())
							{
								// GNU standard, drop the comma
								self.err_raw(hash_hash, DIAG_COMMA_DELETION_VA_ARGS)!;
							}
							else
							{
								// C standard, retain the comma
								buf.push(tokens::from_raw(raw));
							}
						}
						else
						{
							buf.push(tokens::from_raw(raw));
							if (expanded_variable_arguments.len() > 0 || variable_arguments.len() == func_macro.params.len)
							{
								self.err_raw(hash_hash, DIAG_COMMA_DELETION_VA_ARGS)!;
							}
							buf_copy_tokens(gpa, &buf, expanded_variable_arguments.array_view(), { tokens::raw_location(maybe_va_args) });
						}
						continue BODY;
					}
				}
				// Regular comma, no token pasting with __VA_ARGS__
				buf.push(tokens::from_raw(raw));
			default:
				buf.push(tokens::from_raw(raw));
		}
	}
	remove_placemarkers(gpa, &buf);

	Location[] macro_expansion_locs = macro_tok.expansion_slice();
	foreach (&tok : buf)
	{
		tok.add_expansion_location(gpa, { macro_tok.loc });
		tok.add_expansion_location(gpa, macro_expansion_locs);
		if (tok.id.should_track_hideset(FUNC))
		{
			HidesetIndex new_hideset = self.hideset.union_of(self.hideset.get(tok.loc), hs);
			self.hideset.put(tok.loc, new_hideset);
		}
	}
	return buf;
}

<*
 Zig `expandVaOpt`: if `should_expand`, re-tokenize raw.start..raw.end of
 raw's source (line raw.line, with the source's splice locations) and append
 every token (tokens::from_raw) to `buf`.
*>
fn void Preprocessor.expand_va_opt(&self, ExpandBuf* buf, RawToken raw, bool should_expand)
{
	if (!should_expand) return;

	Source src = self.comp.get_source(raw.source);
	Tokenizer tokenizer = {
		.buf = src.buf,
		.index = raw.start,
		.source = raw.source,
		.langopts = self.comp.langopts,
		.line = raw.line,
		.splice_locs = src.splice_locs,
	};
	while (tokenizer.index < raw.end)
	{
		RawToken tok = tokenizer.next();
		buf.push(tokens::from_raw(tok));
	}
}

<*
 Zig `nextBufToken`: advance *start_idx; at the end of `buf` with
 *start_idx >= *end_idx, pull a raw token from `tokenizer` if non-null (nl ->
 add_expansion_nl++; invalid literal / unterminated comment / poisoned
 identifier diagnostics), append it to `buf` and bump *end_idx, else return a
 generated EOF. Otherwise return buf[*start_idx] (a borrowed copy).
 @return? compilation::FATAL_ERROR
*>
fn TokenWithExpansionLocs? Preprocessor.next_buf_token(&self, Tokenizer* tokenizer, ExpandBuf* buf, sz* start_idx, sz* end_idx)
{
	*start_idx += 1;
	if (*start_idx == buf.len() && *start_idx >= *end_idx)
	{
		if (!tokenizer) return { .id = EOF, .loc = { .id = source::GENERATED_ID } };
		RawToken raw_tok = tokenizer.next();
		// FIXME (Zig) these tokens may be retokenized and the diagnostics duplicated
		switch (raw_tok.id)
		{
			case NL:
				self.add_expansion_nl++;
			case UNTERMINATED_STRING_LITERAL:
			case UNTERMINATED_CHAR_LITERAL:
			case EMPTY_CHAR_LITERAL:
				self.err_raw(raw_tok, invalid_token_diagnostic(raw_tok.id))!;
			case UNTERMINATED_COMMENT:
				self.err_raw(raw_tok, DIAG_UNTERMINATED_COMMENT)!;
			default:
				if (self.is_poisoned(raw_tok)) self.err_raw(raw_tok, DIAG_POISONED_IDENTIFIER)!;
		}
		TokenWithExpansionLocs new_tok = tokens::from_raw(raw_tok);
		*end_idx += 1;
		buf.push(new_tok);
		return new_tok;
	}
	return buf.entries[*start_idx];
}

<* Zig `toOwnedSlice` on an argument list: an exact gpa allocation ({} when empty); the list is emptied. *>
fn TokenWithExpansionLocs[] to_owned_tokens(Allocator gpa, ExpandBuf* list) @private
{
	sz n = list.len();
	if (n == 0) return {};
	TokenWithExpansionLocs[] owned = alloc::new_array(gpa, TokenWithExpansionLocs, n);
	owned[..] = list.array_view()[..];
	list.clear();
	return owned;
}

<*
 Zig `collectMacroFuncArguments`: skip nl/whitespace/MACRO_WS after the name
 at buf[*start_idx]; anything but '(' -> (DIAG_MISSING_LPAREN_AFTER_BUILTIN
 for builtins), restore the tokenizer and *end_idx, MISSING_L_PAREN. Then
 collect comma-separated arguments respecting nested parens; every token
 gets flags.is_macro_arg and is dupe'd; nl/whitespace become MACRO_WS at its
 loc; ')' at depth 0 ends (stored in *r_paren); eof -> push the partial
 argument, restore the tokenizer, DIAG_UNTERMINATED_MACRO_ARG_LIST at the
 name, UNTERMINATED (the partial arguments are freed). The result is owned
 by the caller (deinit_macro_arguments). g() yields one empty argument.
 @return? MISSING_L_PAREN, UNTERMINATED, compilation::FATAL_ERROR
*>
fn MacroArguments? Preprocessor.collect_macro_func_arguments(&self, Tokenizer* tokenizer, ExpandBuf* buf, sz* start_idx, sz* end_idx, bool is_builtin, TokenWithExpansionLocs* r_paren)
{
	Allocator gpa = self.comp.gpa;
	TokenWithExpansionLocs name_tok = buf.entries[*start_idx];
	Tokenizer saved_tokenizer;
	if (tokenizer) saved_tokenizer = *tokenizer;
	sz old_end = *end_idx;

	while LPAREN: (true)
	{
		TokenWithExpansionLocs tok = self.next_buf_token(tokenizer, buf, start_idx, end_idx)!;
		switch (tok.id)
		{
			case NL:
			case WHITESPACE:
			case MACRO_WS:
				break;
			case L_PAREN:
				break LPAREN;
			default:
				if (is_builtin)
				{
					self.err(name_tok, DIAG_MISSING_LPAREN_AFTER_BUILTIN, { diagnostics::arg_str(self.expanded_slice(name_tok)) })!;
				}
				// Not a macro function call, go over normal identifier, rewind
				if (tokenizer) *tokenizer = saved_tokenizer;
				*end_idx = old_end;
				return MISSING_L_PAREN~;
		}
	}

	// collect the arguments.
	uint parens = 0;
	MacroArguments args;
	args.init(gpa);
	defer catch deinit_macro_arguments(gpa, &args);
	ExpandBuf cur_argument;
	cur_argument.init(gpa);
	defer
	{
		free_buf_tokens(gpa, cur_argument.array_view()); // non-empty only on a fault
		cur_argument.free();
	}
	while (true)
	{
		TokenWithExpansionLocs tok = self.next_buf_token(tokenizer, buf, start_idx, end_idx)!;
		tok.flags.is_macro_arg = true;
		switch (tok.id)
		{
			case COMMA:
				if (parens == 0)
				{
					args.push(to_owned_tokens(gpa, &cur_argument));
				}
				else
				{
					cur_argument.push(tok.dupe(gpa));
				}
			case L_PAREN:
				cur_argument.push(tok.dupe(gpa));
				parens++;
			case R_PAREN:
				if (parens == 0)
				{
					args.push(to_owned_tokens(gpa, &cur_argument));
					*r_paren = tok;
					assert(cur_argument.len() == 0);
					return args;
				}
				cur_argument.push(tok.dupe(gpa));
				parens--;
			case EOF:
				args.push(to_owned_tokens(gpa, &cur_argument));
				if (tokenizer) *tokenizer = saved_tokenizer;
				self.err(name_tok, DIAG_UNTERMINATED_MACRO_ARG_LIST)!;
				return UNTERMINATED~;
			case NL:
			case WHITESPACE:
				cur_argument.push({ .id = MACRO_WS, .loc = tok.loc });
			default:
				cur_argument.push(tok.dupe(gpa));
		}
	}
}

<* Zig `ArrayList.replaceRange`: replace buf[start : len] with `items` (moved in, not copied). *>
fn void replace_range(ExpandBuf* buf, sz start, sz len, TokenWithExpansionLocs[] items) @private
{
	sz old_len = buf.len();
	assert(start + len <= old_len);
	if (items.len > len) buf.reserve(items.len - len);
	sz tail = old_len - start - len;
	if (tail && items.len != len)
	{
		mem::move(&buf.entries[start + items.len], &buf.entries[start + len], tail * TokenWithExpansionLocs::size);
	}
	if (items.len) mem::copy(&buf.entries[start], items.ptr, items.len * TokenWithExpansionLocs::size);
	buf.size = old_len - len + items.len;
}

<* Zig `removeExpandedTokens`: free and remove buf[start : len]; *moving_end_idx saturating -= len. *>
fn void Preprocessor.remove_expanded_tokens(&self, ExpandBuf* buf, sz start, sz len, sz* moving_end_idx)
{
	free_buf_tokens(self.comp.gpa, buf.array_view()[start:len]);
	replace_range(buf, start, len, {});
	*moving_end_idx = *moving_end_idx > len ? *moving_end_idx - len : 0;
}

<*
 Zig `TokenIterator`: iterate `toks` skipping WHITESPACE / MACRO_WS.
*>
struct TokenIterator
{
	TokenWithExpansionLocs[] toks;
	sz i;
}

<* Zig `TokenIterator.nextNoWS`: the next non-whitespace token (advancing past it), false at the end. *>
fn bool TokenIterator.next_no_ws(&self, TokenWithExpansionLocs* out)
{
	while (self.i < self.toks.len)
	{
		TokenWithExpansionLocs tok = self.toks[self.i];
		if (tok.id == WHITESPACE || tok.id == MACRO_WS)
		{
			self.i++;
			continue;
		}
		self.i++;
		if (out) *out = tok;
		return true;
	}
	return false;
}

<*
 Zig `expandMacroExhaustive`: expand buf[start_idx..end_idx) until no more
 expansion happens (rescan loop with `advance_index`). In EXPR context
 `defined X` / `defined ( X )` are skipped. A macro identifier is expanded
 unless flags.expansion_disabled, undefined, or its name is in its own
 hideset. Function macros: collect arguments (MISSING_L_PAREN -> mark
 expansion_disabled unless is_macro_arg; UNTERMINATED -> GCC emulation skips
 the name, remove the consumed tokens), hs = (is_macro_arg ? NONE :
 intersection(hideset(name), hideset(r_paren))) with the name prepended;
 g() with zero params counts as zero arguments when whitespace only;
 DIAG_EXPECTED_AT_LEAST_ARGUMENTS / DIAG_EXPECTED_ARGUMENTS remove the call;
 arguments are dupe'd and expanded (with `tokenizer` = null) when
 should_expand_args; expand_func_macro replaces the call. Object macros:
 expand_obj_macro, hs = prepend(name, hideset(name)), each result token gets
 is_macro_arg from the name, the name's location chain, union'd hideset for
 should_track_hideset(OBJ); `defined` produced in EXPR context warns
 DIAG_EXPANSION_TO_DEFINED_FUNC/OBJ; the index only advances past result
 tokens before the first `defined` or defined macro name. Finally free and
 drop everything past the moving end index.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn void? Preprocessor.expand_macro_exhaustive(&self, Tokenizer* tokenizer, ExpandBuf* buf, sz start_idx, sz end_idx, EvalContext eval_ctx)
{
	Allocator gpa = self.comp.gpa;
	sz moving_end_idx = end_idx;
	sz advance_index = 0;
	// rescan loop
	bool do_rescan = true;
	while (do_rescan)
	{
		do_rescan = false;
		// expansion loop
		sz idx = start_idx + advance_index;
		while EXPANSION: (idx < moving_end_idx)
		{
			TokenWithExpansionLocs macro_tok = buf.entries[idx];
			if (macro_tok.id == KEYWORD_DEFINED && eval_ctx == EXPR)
			{
				idx++;
				TokenIterator it = { .toks = buf.array_view()[idx:moving_end_idx - idx] };
				TokenWithExpansionLocs tok;
				if (it.next_no_ws(&tok))
				{
					if (tok.id == L_PAREN)
					{
						it.next_no_ws(null); // eat (what should be) identifier
						it.next_no_ws(null); // eat (what should be) r paren
					}
				}
				idx += it.i;
				continue EXPANSION;
			}
			if (!macro_tok.id.is_macro_identifier() || macro_tok.flags.expansion_disabled)
			{
				idx++;
				continue EXPANSION;
			}
			String expanded = self.expanded_slice(macro_tok);
			Macro* m = self.defines.get(expanded);
			if (!m)
			{
				idx++;
				continue EXPANSION;
			}
			HidesetIndex macro_hidelist = self.hideset.get(macro_tok.loc);
			if (self.hideset.contains(macro_hidelist, expanded))
			{
				idx++;
				continue EXPANSION;
			}
			uint name_len = (uint)expanded.len;

			if (m.is_func)
			{
				TokenWithExpansionLocs r_paren;
				sz macro_scan_idx = idx;
				// to be saved in case this doesn't turn out to be a call
				MacroArguments? args_opt = self.collect_macro_func_arguments(tokenizer, buf, &macro_scan_idx, &moving_end_idx, m.is_builtin(), &r_paren);
				if (catch f = args_opt)
				{
					switch (f)
					{
						case MISSING_L_PAREN:
							if (!buf.entries[idx].flags.is_macro_arg) buf.entries[idx].flags.expansion_disabled = true;
							idx++;
						case UNTERMINATED:
							if (self.comp.langopts.emulate == GCC) idx++;
							self.remove_expanded_tokens(buf, idx, macro_scan_idx - idx, &moving_end_idx);
						default:
							return f~;
					}
				}
				else
				{
					MacroArguments args = args_opt;
					assert(r_paren.id == R_PAREN);
					defer deinit_macro_arguments(gpa, &args);

					HidesetIndex r_paren_hidelist = self.hideset.get(r_paren.loc);
					HidesetIndex hs = hideset::NONE;
					if (!macro_tok.flags.is_macro_arg) hs = self.hideset.intersection(macro_hidelist, r_paren_hidelist);
					hs = self.hideset.prepend(macro_tok.loc, name_len, hs);

					uint args_count = (uint)args.len();
					// if the macro has zero arguments g() args_count is still 1
					// an empty token list g() and a whitespace-only token list g(    )
					// counts as zero arguments for the purposes of argument-count validation
					if (args_count == 1 && m.params.len == 0)
					{
						bool only_ws = true;
						foreach (tok : args.entries[0])
						{
							if (tok.id != MACRO_WS)
							{
								only_ws = false;
								break;
							}
						}
						if (only_ws) args_count = 0;
					}

					// Validate argument count.
					if (m.var_args && args_count < m.params.len)
					{
						self.err(buf.entries[idx], DIAG_EXPECTED_AT_LEAST_ARGUMENTS, { diagnostics::arg_uint(m.params.len), diagnostics::arg_uint(args_count) })!;
						idx++;
						self.remove_expanded_tokens(buf, idx, macro_scan_idx - idx + 1, &moving_end_idx);
						continue EXPANSION;
					}
					if (!m.var_args && args_count != m.params.len)
					{
						self.err(buf.entries[idx], DIAG_EXPECTED_ARGUMENTS, { diagnostics::arg_uint(m.params.len), diagnostics::arg_uint(args_count) })!;
						idx++;
						self.remove_expanded_tokens(buf, idx, macro_scan_idx - idx + 1, &moving_end_idx);
						continue EXPANSION;
					}
					MacroArguments expanded_args;
					expanded_args.init(gpa);
					defer deinit_macro_arguments(gpa, &expanded_args);
					expanded_args.reserve(args.len());
					bool should_expand_args = m.should_expand_args();
					foreach (arg : args)
					{
						ExpandBuf expand_buf;
						expand_buf.init(gpa);
						expand_buf.reserve(arg.len);
						foreach (tok : arg) expand_buf.push(tok.dupe(gpa));

						if (should_expand_args)
						{
							if (catch f2 = self.expand_macro_exhaustive(null, &expand_buf, 0, expand_buf.len(), eval_ctx))
							{
								free_expand_buf(gpa, &expand_buf);
								return f2~;
							}
						}
						// Even if not expanding the arguments, still append to expanded_args so expansion locations will
						// get cleaned up.
						expanded_args.push(to_owned_tokens(gpa, &expand_buf));
						expand_buf.free();
					}

					ExpandBuf res = self.expand_func_macro(macro_tok, m, &args, &expanded_args, hs, eval_ctx)!;
					defer res.free(); // the tokens move into `buf`
					sz tokens_added = res.len();
					sz tokens_removed = macro_scan_idx - idx + 1;
					free_buf_tokens(gpa, buf.array_view()[idx:tokens_removed]);
					replace_range(buf, idx, tokens_removed, res.array_view());

					moving_end_idx += tokens_added;
					// Overflow here means that we encountered an unterminated argument list
					// while expanding the body of this macro.
					moving_end_idx = moving_end_idx > tokens_removed ? moving_end_idx - tokens_removed : 0;
					idx += tokens_added;
					do_rescan = true;
				}
			}
			else
			{
				bool is_func = m.is_func;
				ExpandBuf res = self.expand_obj_macro(m)!;
				defer res.free(); // the tokens move into `buf` (or are freed on a fault)
				defer catch free_buf_tokens(gpa, res.array_view());

				HidesetIndex hs = self.hideset.prepend(macro_tok.loc, name_len, macro_hidelist);

				Location[] macro_expansion_locs = macro_tok.expansion_slice();
				sz increment_idx_by = res.len();
				foreach (i, &tok : res)
				{
					tok.flags.is_macro_arg = macro_tok.flags.is_macro_arg;
					tok.add_expansion_location(gpa, { macro_tok.loc });
					tok.add_expansion_location(gpa, macro_expansion_locs);

					if (tok.id.should_track_hideset(OBJ))
					{
						HidesetIndex new_hideset = self.hideset.union_of(self.hideset.get(tok.loc), hs);
						self.hideset.put(tok.loc, new_hideset);
					}

					if (tok.id == KEYWORD_DEFINED && eval_ctx == EXPR)
					{
						if (is_func)
						{
							self.err(*tok, DIAG_EXPANSION_TO_DEFINED_FUNC)!;
						}
						else
						{
							self.err(*tok, DIAG_EXPANSION_TO_DEFINED_OBJ)!;
						}
					}

					if (i < increment_idx_by && (tok.id == KEYWORD_DEFINED || self.defines.contains(self.expanded_slice(*tok))))
					{
						increment_idx_by = i;
					}
				}

				tokens::free_expansion_locs(gpa, buf.entries[idx].expansion_locs);
				replace_range(buf, idx, 1, res.array_view());
				idx += increment_idx_by;
				moving_end_idx = moving_end_idx + res.len() - 1;
				do_rescan = true;
			}
			if (idx - start_idx == advance_index + 1 && !do_rescan)
			{
				advance_index++;
			}
		} // end of replacement phase
	}
	// end of scanning phase

	// trim excess buffer
	free_buf_tokens(gpa, buf.array_view()[moving_end_idx:buf.len() - moving_end_idx]);
	buf.size = moving_end_idx;
}

<*
 Zig `expandMacro`: top-level expansion of `raw` read from `tokenizer`.
 Non-macro-identifiers: simplify_macro_keyword and add_token. Otherwise put
 it in top_expansion_buf, set expansion_source_loc, clear the hideset
 (retaining capacity), expand_macro_exhaustive(tokenizer, .., 0, 1,
 NON_EXPR) and add_tokens_from_expand_buf with a NL token at the
 tokenizer's source/line.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn void? Preprocessor.expand_macro(&self, Tokenizer* tokenizer, RawToken raw)
{
	TokenWithExpansionLocs source_tok = tokens::from_raw(raw);
	if (!raw.id.is_macro_identifier())
	{
		source_tok.id.simplify_macro_keyword();
		return self.add_token(source_tok);
	}
	self.top_expansion_buf.clear();
	self.top_expansion_buf.push(source_tok);
	self.expansion_source_loc = source_tok.loc;

	self.hideset.clear_retaining_capacity();
	if (catch f = self.expand_macro_exhaustive(tokenizer, &self.top_expansion_buf, 0, 1, NON_EXPR))
	{
		// Deviation: Zig leaks these arrays on a fault.
		free_buf_tokens(self.comp.gpa, self.top_expansion_buf.array_view());
		self.top_expansion_buf.clear();
		return f~;
	}
	self.add_tokens_from_expand_buf(self.top_expansion_buf.array_view(), {
		.id = NL,
		.loc = { .id = tokenizer.source, .line = tokenizer.line },
	})!;
}

<* Zig `PragmaLoc`. *>
struct PragmaLoc @private
{
	TokenWithExpansionLocs name_tok;
	TokenIndex start;
}

<*
 Zig `addTokensFromExpandBuf`: move `toks` into the output. MACRO_WS (unless
 preserve_whitespace), comments (unless preserve_comments_in_macros) and
 PLACEMARKERs are freed and dropped; tokens flagged pragma_directive are
 added and remembered with the following name token for eval_pragma (plan
 15); others get simplify_macro_keyword_extra(true) and unescape_ucn. With
 preserve_whitespace, add `tokenizer_nl` add_expansion_nl times (resetting
 it). Ownership of every token's array moves to the output or is freed.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn void? Preprocessor.add_tokens_from_expand_buf(&self, TokenWithExpansionLocs[] toks, TokenWithExpansionLocs tokenizer_nl)
{
	Allocator gpa = self.comp.gpa;
	List{PragmaLoc} pragma_locs;
	pragma_locs.init(gpa);
	defer pragma_locs.free();

	self.ensure_unused_token_capacity(toks.len);
	foreach (i, const_tok : toks)
	{
		TokenWithExpansionLocs tok = const_tok;
		if (tok.id == MACRO_WS && !self.preserve_whitespace)
		{
			tokens::free_expansion_locs(gpa, tok.expansion_locs);
			continue;
		}
		if (tok.id == COMMENT && !self.comp.langopts.preserve_comments_in_macros)
		{
			tokens::free_expansion_locs(gpa, tok.expansion_locs);
			continue;
		}
		if (tok.id == PLACEMARKER)
		{
			tokens::free_expansion_locs(gpa, tok.expansion_locs);
			continue;
		}
		if (tok.flags.pragma_directive)
		{
			TokenIndex pragma_start = (TokenIndex)self.tokens.len();
			self.add_token_assume_capacity(tok);
			pragma_locs.push({ .name_tok = toks[i + 1], .start = pragma_start });
			continue;
		}
		tok.id.simplify_macro_keyword_extra(true);
		self.add_token_assume_capacity(self.unescape_ucn(tok)!);
	}
	if (self.preserve_whitespace)
	{
		self.ensure_unused_token_capacity(self.add_expansion_nl);
		while (self.add_expansion_nl > 0)
		{
			self.add_token_assume_capacity(tokenizer_nl);
			self.add_expansion_nl--;
		}
	}
	foreach (p : pragma_locs)
	{
		self.eval_pragma(p.name_tok, p.start)!;
	}
}
