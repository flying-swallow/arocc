// Stringify (#), token pasting (##) and generated tokens from
// src/aro/Preprocessor.zig. OWNER: plan 13.4 `stringify-paste`.
//
// Generated-buffer offsets: every token synthesized here is written to
// `comp.generated_buf` followed by '\n' and addressed by
// { source::GENERATED_ID, byte_offset = start offset, line = pp.generated_line++ }.
// Offsets stay valid when the buffer grows; slices (expanded_slice of a
// generated token) do not. A temporary NUL is appended after the '\n' to
// tokenize in place and removed from the length again (Zig `defer len -= 1`);
// like Zig, the byte stays in the buffer's spare capacity, which keeps the
// tokenizer's "buf.ptr[buf.len] == 0" precondition true for later
// expanded_slice calls on generated tokens.
//
// Deviations from Zig:
//  - paste_tokens frees the expansion array of a preserved-comment macro-arg
//    lhs that is dropped (Zig leaks it; memory only, no visible change).
//  - Before reading generated slices (and again after growing generated_buf)
//    paste_tokens writes a NUL at generated_buf's length (Zig's tokenizer is bounds-checked;
//    C3's requires the sentinel).
// Zig quirks kept on purpose (source-derived, see test/c3/macro_paste_tests.c3):
//  - stringify does not escape '\' inside u8 character literals
//    (CHAR_LITERAL_UTF_8 is missing from Zig's string/char list).
//  - When the stringified text ends in '\' but re-tokenizes as a terminated
//    string (e.g. `\\` -> "\\"), char_buf keeps the NUL used for tokenizing:
//    the result is `"\\"` NUL '\n'.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::hideset, aro::compilation, aro::diagnostics;
import std::collections::list;

enum StringifyWs : char @private
{
	START,
	NEED,
	NOT_NEEDED,
}

<* Zig stringify's `is_str`: tokens whose '\' are escaped (note: not CHAR_LITERAL_UTF_8, as in Zig). *>
fn bool stringify_escapes_backslash(TokenId id) @private
{
	switch (id)
	{
		case STRING_LITERAL:
		case STRING_LITERAL_UTF_16:
		case STRING_LITERAL_UTF_8:
		case STRING_LITERAL_UTF_32:
		case STRING_LITERAL_WIDE:
		case CHAR_LITERAL:
		case CHAR_LITERAL_UTF_16:
		case CHAR_LITERAL_UTF_32:
		case CHAR_LITERAL_WIDE:
			return true;
		default:
			return false;
	}
}

<*
 Zig `stringify`: append the `#` spelling of `toks` to char_buf: '"', then
 each token's expanded_slice with '"' -> \" everywhere and '\' -> \\ inside
 string/char literals (all STRING_LITERAL* / CHAR_LITERAL* ids except
 CHAR_LITERAL_UTF_8), MACRO_WS collapsed to one space between tokens
 (leading/trailing dropped), then "\"\n". If the content ends with '\':
 append "\"\0", re-tokenize char_buf from index 0; if that gives
 UNTERMINATED_STRING_LITERAL warn DIAG_INVALID_PP_STRINGIFY_ESCAPE at the last
 token and replace the trailing `\"\0` with '"'; then append '\n' (so a
 terminated result keeps the NUL, as in Zig). Callers clear char_buf first.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.stringify(&self, TokenWithExpansionLocs[] toks)
{
	self.char_buf.push('"');
	StringifyWs ws_state = START;
	foreach (tok : toks)
	{
		if (tok.id == MACRO_WS)
		{
			if (ws_state == START) continue;
			ws_state = NEED;
			continue;
		}
		if (ws_state == NEED) self.char_buf.push(' ');
		ws_state = NOT_NEEDED;

		// backslashes not inside strings are not escaped
		bool is_str = stringify_escapes_backslash(tok.id);
		foreach (c : self.expanded_slice(tok))
		{
			if (c == '"')
			{
				self.char_buf.push_all("\\\"");
			}
			else if (c == '\\' && is_str)
			{
				self.char_buf.push_all("\\\\");
			}
			else
			{
				self.char_buf.push(c);
			}
		}
	}
	if (self.char_buf[^1] != '\\')
	{
		self.char_buf.push_all("\"\n");
		return;
	}
	self.char_buf.push('"');
	self.char_buf.push(0);
	String view = (String)self.char_buf.array_view();
	Tokenizer tokenizer;
	tokenizer.init(view[:view.len - 1], source::GENERATED_ID, self.comp.langopts);
	tokenizer.line = 0;
	Token item = tokenizer.next();
	if (item.id == UNTERMINATED_STRING_LITERAL)
	{
		TokenWithExpansionLocs tok = toks[^1];
		self.err(tok, DIAG_INVALID_PP_STRINGIFY_ESCAPE)!;
		self.char_buf.size -= 3; // erase unpaired backslash, appended end quote and NUL
		self.char_buf.push('"');
	}
	self.char_buf.push('\n');
}

<*
 Zig `destringify`: invert stringify into char_buf:
 "\\\\" -> '\', "\\\"" -> '"', a lone '\' before anything else is kept
 (a trailing lone '\' is dropped, as in Zig).
*>
fn void Preprocessor.destringify(&self, String str)
{
	bool backslash_seen = false;
	foreach (c : str)
	{
		if (c == '\\')
		{
			if (backslash_seen) self.char_buf.push(c);
			backslash_seen = !backslash_seen;
			continue;
		}
		if (backslash_seen && c != '"') self.char_buf.push('\\');
		self.char_buf.push(c);
		backslash_seen = false;
	}
}

<* True for the tokens pasteTokens skips (whitespace, and comments unless -CC keeps them). *>
fn bool Preprocessor.paste_skips(&self, TokenId id)
{
	if (self.comp.langopts.preserve_comments_in_macros && id == COMMENT) return false;
	return id == MACRO_WS || id == COMMENT;
}

<*
 Zig `pasteTokens`: pop trailing MACRO_WS (and comments unless -CC) from
 `lhs_toks` (freeing them); nothing left -> buf_copy_tokens(rhs_toks). A
 preserved-comment macro-arg lhs inhibits pasting (it is dropped; insert a
 MACRO_WS if neither the new last lhs token nor rhs_toks[0] is whitespace or
 a comment, then copy rhs). Find the first non-whitespace/comment rhs (none
 -> push lhs back). Write lhs ++ rhs + "\n" to generated_buf, tokenize with
 next_no_ws_comments twice; the id is PLACEMARKER if both sides are, else the
 first token's; hideset = intersection(hideset(lhs), hideset(rhs)); push
 make_generated_token_extra(start, id, lhs, hs, either is_macro_arg). A second
 token that is not nl/eof -> DIAG_PASTING_FORMED_INVALID (the pasted text) at
 lhs and push that token (tokens::from_raw) too. Then copy the rest of
 rhs_toks after the used token. lhs's array is freed. rhs_toks is borrowed.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.paste_tokens(&self, ExpandBuf* lhs_toks, TokenWithExpansionLocs[] rhs_toks)
{
	Allocator gpa = self.comp.gpa;
	TokenWithExpansionLocs lhs;
	bool have_lhs = false;
	while (lhs_toks.len() > 0)
	{
		lhs = lhs_toks.get(lhs_toks.len() - 1);
		lhs_toks.size -= 1;
		if (!self.paste_skips(lhs.id))
		{
			have_lhs = true;
			break;
		}
		tokens::free_expansion_locs(gpa, lhs.expansion_locs);
	}
	if (!have_lhs)
	{
		buf_copy_tokens(gpa, lhs_toks, rhs_toks, {});
		return;
	}

	// preserved comments (via -CC) inhibit pasting
	if (lhs.id == COMMENT && lhs.flags.is_macro_arg)
	{
		if (lhs_toks.len() != 0 && rhs_toks.len != 0)
		{
			TokenId last = lhs_toks.get(lhs_toks.len() - 1).id;
			TokenId first = rhs_toks[0].id;
			if (last != MACRO_WS && last != COMMENT && first != MACRO_WS && first != COMMENT)
			{
				lhs_toks.push({ .id = MACRO_WS, .loc = lhs.loc });
			}
		}
		tokens::free_expansion_locs(gpa, lhs.expansion_locs); // Zig leaks this array
		buf_copy_tokens(gpa, lhs_toks, rhs_toks, {});
		return;
	}

	sz rhs_rest = 1;
	TokenWithExpansionLocs rhs;
	bool have_rhs = false;
	foreach (r : rhs_toks)
	{
		if (!self.paste_skips(r.id))
		{
			rhs = r;
			have_rhs = true;
			break;
		}
		rhs_rest++;
	}
	if (!have_rhs)
	{
		lhs_toks.push(lhs);
		return;
	}
	defer tokens::free_expansion_locs(gpa, lhs.expansion_locs);

	List{char}* gen = &self.comp.generated_buf;
	sz start = gen.len();
	gen.reserve(1);
	gen.entries[start] = 0; // expanded_slice of a generated token needs the sentinel
	sz end = start + self.expanded_slice(lhs).len + self.expanded_slice(rhs).len;
	gen.reserve(end + 2 - start); // +2 for a newline and null terminator
	gen.entries[start] = 0; // growing may have dropped the sentinel the tokenizer needs
	// We cannot use the earlier slices since they might be invalidated by `reserve`
	gen.push_all((char[])self.expanded_slice(lhs));
	gen.push_all((char[])self.expanded_slice(rhs));
	gen.push('\n');
	gen.push(0);
	gen.size -= 1; // remove redundant null terminator (it stays in the spare capacity)

	// Try to tokenize the result.
	Tokenizer tmp_tokenizer;
	tmp_tokenizer.init((String)gen.array_view(), source::GENERATED_ID, self.comp.langopts);
	tmp_tokenizer.index = (uint)start;
	Token pasted_token = tmp_tokenizer.next_no_ws_comments();
	Token next = tmp_tokenizer.next_no_ws_comments();
	TokenId pasted_id = pasted_token.id;
	if (lhs.id == PLACEMARKER && rhs.id == PLACEMARKER) pasted_id = PLACEMARKER;

	HidesetIndex hs = self.hideset.intersection(self.hideset.get(lhs.loc), self.hideset.get(rhs.loc));
	TokenWithExpansionLocs generated_token = self.make_generated_token_extra(start, pasted_id, lhs, hs, lhs.flags.is_macro_arg || rhs.flags.is_macro_arg);
	lhs_toks.push(generated_token);

	if (next.id != NL && next.id != EOF)
	{
		String pasted = (String)self.comp.generated_buf.array_view()[start:end - start];
		self.err(lhs, DIAG_PASTING_FORMED_INVALID, { diagnostics::arg_str(pasted) })!;
		lhs_toks.push(tokens::from_raw(next));
	}

	buf_copy_tokens(gpa, lhs_toks, rhs_toks[rhs_rest..], {});
}

<*
 Zig `makeGeneratedTokenExtra`: a token { id, GENERATED_ID, byte_offset =
 start, line = generated_line++ } with flags.is_macro_arg, expansion
 locations source.loc then source's chain (generated locations are never
 recorded), and hideset(loc) = hs. The caller owns the returned array.
*>
fn TokenWithExpansionLocs Preprocessor.make_generated_token_extra(&self, sz start, TokenId id, TokenWithExpansionLocs src, HidesetIndex hs, bool is_macro_arg)
{
	Allocator gpa = self.comp.gpa;
	TokenFlags flags;
	flags.is_macro_arg = is_macro_arg;
	TokenWithExpansionLocs pasted_token = {
		.id = id,
		.flags = flags,
		.loc = { .id = source::GENERATED_ID, .byte_offset = (uint)start, .line = self.generated_line },
	};
	self.generated_line++;
	pasted_token.add_expansion_location(gpa, { src.loc });
	pasted_token.add_expansion_location(gpa, src.expansion_slice());
	self.hideset.put(pasted_token.loc, hs);
	return pasted_token;
}

<* Zig `makeGeneratedToken`: make_generated_token_extra(start, id, src, hideset(src.loc), false). *>
fn TokenWithExpansionLocs Preprocessor.make_generated_token(&self, sz start, TokenId id, TokenWithExpansionLocs src)
{
	return self.make_generated_token_extra(start, id, src, self.hideset.get(src.loc), false);
}
