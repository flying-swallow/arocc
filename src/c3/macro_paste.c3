// Stringify (#), token pasting (##) and generated tokens from
// src/aro/Preprocessor.zig. OWNER: plan 13.4 `stringify-paste`.
//
// Generated-buffer offsets: every token synthesized here is written to
// `comp.generated_buf` followed by '\n' and addressed by
// { source::GENERATED_ID, byte_offset = start offset, line = pp.generated_line++ }.
// Offsets stay valid when the buffer grows; slices (expanded_slice of a
// generated token) do not. A temporary NUL may be appended after the '\n' to
// tokenize in place and must be removed again (Zig `defer len -= 1`).
//
// Stage 0: signatures only; every body is a stub.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::hideset, aro::compilation, aro::diagnostics;

<*
 Zig `stringify`: append the `#` spelling of `toks` to char_buf: '"', then
 each token's expanded_slice with '"' -> \" everywhere and '\' -> \\ inside
 string/char literals (all STRING_LITERAL* / CHAR_LITERAL* ids), MACRO_WS
 collapsed to one space between tokens (leading/trailing dropped), then
 "\"\n". If the content ends with an unpaired '\' (re-tokenizing the result
 from char_buf start gives UNTERMINATED_STRING_LITERAL): warn
 DIAG_INVALID_PP_STRINGIFY_ESCAPE at the last token, drop the backslash and
 close the string. Always ends with '\n' (callers strip it as needed).
 Note Zig re-tokenizes char_buf from index 0, so callers clear char_buf first
 (or accept Zig's behavior).
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.stringify(&self, TokenWithExpansionLocs[] toks)
{
	unreachable("stage 0 stub");
}

<*
 Zig `destringify`: invert stringify into char_buf (capacity assumed):
 "\\\\" -> '\', "\\\"" -> '"', a lone '\' before anything else is kept.
*>
fn void Preprocessor.destringify(&self, String str)
{
	unreachable("stage 0 stub");
}

<*
 Zig `pasteTokens`: pop trailing MACRO_WS (and comments unless -CC) from
 `lhs_toks` (freeing them); nothing left -> buf_copy_tokens(rhs_toks). A
 preserved-comment macro-arg lhs inhibits pasting (insert a MACRO_WS if
 needed, then copy rhs). Find the first non-whitespace/comment rhs (none ->
 push lhs back). Write lhs ++ rhs + "\n" to generated_buf, tokenize with
 next_no_ws_comments twice; the id is PLACEMARKER if both sides are, else
 the first token's; hideset = intersection(hideset(lhs), hideset(rhs));
 push make_generated_token_extra(start, id, lhs, hs, either is_macro_arg).
 A second token that is not nl/eof -> DIAG_PASTING_FORMED_INVALID (the
 pasted text) at lhs and push that token (tokens::from_raw) too. Then copy
 the rest of rhs_toks after the used token. lhs's array is freed.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.paste_tokens(&self, ExpandBuf* lhs_toks, TokenWithExpansionLocs[] rhs_toks)
{
	unreachable("stage 0 stub");
}

<*
 Zig `makeGeneratedTokenExtra`: a token { id, GENERATED_ID, byte_offset =
 start, line = generated_line++ } with flags.is_macro_arg, expansion
 locations source.loc then source's chain, and hideset(loc) = hs.
*>
fn TokenWithExpansionLocs Preprocessor.make_generated_token_extra(&self, sz start, TokenId id, TokenWithExpansionLocs src, HidesetIndex hs, bool is_macro_arg)
{
	unreachable("stage 0 stub");
}

<* Zig `makeGeneratedToken`: make_generated_token_extra(start, id, src, hideset(src.loc), false). *>
fn TokenWithExpansionLocs Preprocessor.make_generated_token(&self, sz start, TokenId id, TokenWithExpansionLocs src)
{
	unreachable("stage 0 stub");
}
