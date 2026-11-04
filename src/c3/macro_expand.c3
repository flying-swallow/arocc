// Macro definition and expansion from src/aro/Preprocessor.zig.
// OWNER: plan 13.3 `expansion`.
//
// Ownership: every TokenWithExpansionLocs in an ExpandBuf / MacroArguments
// owns its expansion array (see tokens.c3). Tokens taken out of `buf` must be
// freed or moved; tokens copied in must be `dupe`d. Use the helpers in
// preprocessor.c3 (free_buf_tokens, remove_placemarkers, buf_copy_tokens,
// deinit_macro_arguments, get_paste_args).
//
// Stage 0: signatures only; every body is a stub.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::hideset, aro::compilation, aro::diagnostics;

<*
 Zig `Macro.eql`: same token count, equal builtin kinds, pairwise equal
 tok_slice of the body tokens, and for two function macros equal var_args
 and parameter names.
*>
fn bool Macro.eql(&self, Macro* b, Preprocessor* pp)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

<*
 Zig `expandVaOpt`: if `should_expand`, re-tokenize raw.start..raw.end of
 raw's source (line raw.line, with the source's splice locations) and append
 every token (tokens::from_raw) to `buf`.
*>
fn void Preprocessor.expand_va_opt(&self, ExpandBuf* buf, RawToken raw, bool should_expand)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

<* Zig `removeExpandedTokens`: free and remove buf[start : len]; *moving_end_idx saturating -= len. *>
fn void Preprocessor.remove_expanded_tokens(&self, ExpandBuf* buf, sz start, sz len, sz* moving_end_idx)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}
