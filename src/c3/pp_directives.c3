// Directive dispatch and conditional preprocessing from src/aro/Preprocessor.zig.
// OWNER: plan 13.5 `directives`.
//
// `preprocess_extra` is the per-file main loop: it reads raw tokens, handles
// directives at the start of a line and hands every other token to
// expand_macro (13.3). #include / #include_next / #embed / #pragma call the
// plan-15 placeholders in preprocessor.c3 (aro::UNSUPPORTED).
//
// Stage 0: signatures only; every body is a stub.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;

<* Zig `IfContext.Nesting`. *>
enum IfNesting : char
{
	UNTIL_ELSE,
	UNTIL_ENDIF,
	UNTIL_ENDIF_SEEN_ELSE,
}

<*
 Zig `IfContext`: 256 two-bit nesting states packed in 64 bytes plus the
 current level (u8, overflow on the 256th nesting). Zig initializes `kind`
 to 0xFF so that reading an unset level is detectable; start from
 IF_CONTEXT_DEFAULT.
*>
struct IfContext
{
	char[64] kind;
	char level;
}

const IfContext IF_CONTEXT_DEFAULT = { .kind = { [0..63] = 0xFF }, .level = 0 };

<* Zig `IfContext.get`: the state of the current level. *>
fn IfNesting IfContext.get(&self)
{
	unreachable("stage 0 stub");
}

<* Zig `IfContext.set`. *>
fn void IfContext.set(&self, IfNesting context)
{
	unreachable("stage 0 stub");
}

<* Zig `IfContext.increment`: level += 1 (wrapping); true on overflow. *>
fn bool IfContext.increment(&self)
{
	unreachable("stage 0 stub");
}

<* Zig `IfContext.decrement`. *>
fn void IfContext.decrement(&self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `preprocessExtra`: preprocess one source and return its eof token.
 Increments preprocess_count, reserves buf.len/8 tokens, tracks
 start_of_line and the include guard (find_include_guard; cleared by
 #elif/#elifdef/#elifndef/#else at level 1, by #endif at level 0 or when
 something follows the level-1 #endif, stored in include_guards at eof).
 Directives: #error/#warning (WARNING_EXTENSION before C23; tokens
 stringified, the text without quotes reported as DIAG_ERROR_DIRECTIVE /
 DIAG_WARNING_DIRECTIVE at the directive), #if (fatal "too many #if
 nestings" on overflow; `expr`; skip UNTIL_ELSE), #ifdef/#ifndef
 (expect_macro_name, expect_nl), #elif/#elifdef/#elifndef (C23_EXTENSION
 before C23 for the latter two; *_WITHOUT_IF at level 0; *_AFTER_ELSE),
 #else, #endif, #define (define), #undef (store_macro_tokens, ordered
 remove, verbose log, expect_nl), #include (include FIRST), #include_next
 (DIAG_INCLUDE_NEXT; outside a header DIAG_INCLUDE_NEXT_OUTSIDE_HEADER and
 FIRST), #embed (C23_EXTENSION, embed), #pragma (pragma), #line N "file"
 (LINE_SIMPLE_DIGIT, LINE_INVALID_NUMBER "#line", LINE_INVALID_FILENAME,
 source alias via comp.add_source_alias, LINEMARKER token when linemarkers),
 GNU `# N "file" flags` (flags 1/2/3/4, LINE_INVALID_FLAG), empty `#`,
 `#` at eof (UNTERMINATED_CONDITIONAL_DIRECTIVE if nested), anything else
 INVALID_PREPROCESSING_DIRECTIVE + skip_to_nl. With preserve_whitespace an
 NL token is added after each directive. Non-directive tokens: whitespace /
 nl kept with preserve_whitespace; invalid literals warn and expand;
 unterminated comment errors; poisoned identifiers error; others go to
 expand_macro. At eof: UNTERMINATED_CONDITIONAL_DIRECTIVE when nested,
 DIAG_NEWLINE_EOF if the buffer does not end in '\n'.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn TokenWithExpansionLocs? Preprocessor.preprocess_extra(&self, Source src)
{
	unreachable("stage 0 stub");
}

<*
 Zig `findIncludeGuard`: if the first non-newline tokens are `# ifndef IDENT`
 return IDENT (a slice of the source), else NO_INCLUDE_GUARD. Uses a fresh
 tokenizer with no splice locations.
 @return? NO_INCLUDE_GUARD
*>
fn String? Preprocessor.find_include_guard(&self, Source src)
{
	unreachable("stage 0 stub");
}

<* find_include_guard: the source does not start with `#ifndef NAME`. *>
excuse NO_INCLUDE_GUARD;

<*
 Zig `expr`: collect the rest of the line (leading whitespace and comments
 dropped; invalid literals / unterminated comments / poisoned identifiers
 diagnosed) into top_expansion_buf, set expansion_source_loc to its first
 token, clear the hideset, expand_macro_exhaustive(null, .., EXPR),
 remove_placemarkers, then evaluate with PpExprParser (eof = the nl/eof
 token). EXPR_FAILED -> false. top_expansion_buf's arrays are freed at the end.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn bool? Preprocessor.expr(&self, Tokenizer* tokenizer)
{
	unreachable("stage 0 stub");
}

<*
 Zig `skip`: skip lines until the matching #else / #elif / #elifdef /
 #elifndef / #endif (nested #if* counted), leaving the tokenizer at the
 start of that directive line. UNTIL_ENDIF ignores #elif*; with
 UNTIL_ENDIF_SEEN_ELSE #else / #elif* report *_AFTER_ELSE and continue;
 #elifdef/#elifndef report C23_EXTENSION ("#elifdef" for both, as Zig)
 before C23. With preserve_whitespace an NL token is added per skipped line.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.skip(&self, Tokenizer* tokenizer, IfNesting cont)
{
	unreachable("stage 0 stub");
}

<* Zig `skipToNl`: consume tokens up to and including the next nl / eof. *>
fn void skip_to_nl(Tokenizer* tokenizer)
{
	unreachable("stage 0 stub");
}

<*
 Zig `expectMacroName`: next_no_ws must be a macro identifier (its tok_slice
 is returned); otherwise DIAG_MACRO_NAME_MISSING, skip_to_nl and
 NO_MACRO_NAME (Zig null).
 @return? NO_MACRO_NAME, compilation::FATAL_ERROR
*>
fn String? Preprocessor.expect_macro_name(&self, Tokenizer* tokenizer)
{
	unreachable("stage 0 stub");
}

<* expect_macro_name: Zig returned null (already diagnosed). *>
excuse NO_MACRO_NAME;

<*
 Zig `expectNl`: consume up to nl/eof; the first token that is not
 whitespace or a comment gets DIAG_EXTRA_TOKENS_DIRECTIVE_END (once).
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.expect_nl(&self, Tokenizer* tokenizer)
{
	unreachable("stage 0 stub");
}
