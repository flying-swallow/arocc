// -E output from src/aro/Preprocessor.zig (prettyPrintTokens and helpers).
// OWNER: plan 13.6 `probe` (together with test/migration/pp_probe.c3 and the
// macro_regression fixture list).
//
// Output goes to an OutStream (Zig *std.Io.Writer); write faults propagate.
//
// Stage 0: signatures only; every body is a stub.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, std::io;

<* Zig `DumpMode`. *>
enum DumpMode : char
{
	<* Standard preprocessor output; no macros *>
	RESULT_ONLY,
	<*
	 Output only #define directives for all the macros defined during the
	 execution of the preprocessor (only those still defined at the end, most
	 recent definition, in definition order).
	*>
	MACROS_ONLY,
	<* Standard output plus #define's and #undef's as they are encountered *>
	MACROS_AND_RESULT,
	<* Same as MACROS_AND_RESULT, except only the macro name is printed for #define's *>
	MACRO_NAMES_AND_RESULT,
}

<* Zig `printLinemarker`'s start_resume. *>
enum LinemarkerFlag : char
{
	START,
	RESUME,
	NONE,
}

<* Zig `collapse_newlines`: after how many empty lines they are replaced with a linemarker. *>
const uint COLLAPSE_NEWLINES = 8;

<* Zig `prettyPrintMacro` parts. *>
enum MacroParts : char
{
	NAME_ONLY,
	NAME_AND_BODY,
}

<*
 Zig `fmtEscapes` / `FmtEscapes.format`: write `bytes` as C string contents:
 \n \r \t \\ \" escaped, printable ASCII (' ', '!', '#'..'&', '('..'[',
 ']'..'~') as is, every other byte as \xHH (two lowercase hex digits).
*>
fn void? write_escaped(OutStream w, String bytes)
{
	unreachable("stage 0 stub");
}

<*
 Zig `printLinemarker`: '#', "line" for LINE_DIRECTIVES, ` <line_no> "<escaped
 path>"`, and for NUMERIC_DIRECTIVES the flag (" 1" start, " 2" resume) and
 " 3" (SYSTEM) / " 3 4" (EXTERN_C_SYSTEM). No newline.
*>
fn void? Preprocessor.print_linemarker(&self, OutStream w, uint line_no, Source src, LinemarkerFlag start_resume)
{
	unreachable("stage 0 stub");
}

<*
 Zig `prettyPrintMacro`: re-tokenize the #define / #undef at `loc` and print
 it: whitespace runs as one space, comments only after the name (they reset
 the whitespace state), other tokens via tok_slice, stopping at nl/eof or
 right after the name for NAME_ONLY.
*>
fn void? Preprocessor.pretty_print_macro(&self, OutStream w, Location loc, MacroParts parts)
{
	unreachable("stage 0 stub");
}

<* Zig `prettyPrintMacrosOnly`: "#define " + pretty_print_macro(NAME_AND_BODY) + "\n" for each non-builtin macro in definition order. *>
fn void? Preprocessor.pretty_print_macros_only(&self, OutStream w)
{
	unreachable("stage 0 stub");
}

<*
 Zig `prettyPrintTokens`: print `tokens` (which must end with EOF) trying to
 preserve whitespace. NL runs: with linemarkers NONE, 2+ newlines before the
 next token collapse to one blank line; with linemarkers, 8+ (COLLAPSE_NEWLINES)
 become a linemarker. KEYWORD_PRAGMA prints "#pragma" and the space-separated
 rest of the line (pragma preservation queries belong to plan 15).
 WHITESPACE prints spaces (newlines inside only with linemarkers).
 INCLUDE_START / INCLUDE_RESUME / LINEMARKER print line markers.
 KEYWORD_DEFINE / KEYWORD_UNDEF print the macro for the two dump modes. Other
 tokens print their expanded slice. Ends with a newline if the last output
 was not one.
*>
fn void? Preprocessor.pretty_print_tokens(&self, OutStream w, DumpMode macro_dump_mode)
{
	unreachable("stage 0 stub");
}
