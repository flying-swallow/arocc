// -E output from src/aro/Preprocessor.zig (prettyPrintTokens and helpers).
// OWNER: plan 13.6 `probe` (together with test/migration/pp_probe.c3 and the
// macro_regression fixture list).
//
// Output goes to an OutStream (Zig *std.Io.Writer); write faults propagate.
// Zig flushes the writer at the end of prettyPrintTokens /
// prettyPrintMacrosOnly; here the stream's optional `flush` is called there
// too (a stream without one is left alone).
//
// Deviations from Zig:
//  - KEYWORD_PRAGMA: Zig asks `comp.getPragma(name).shouldPreserveTokens`
//    and drops the pragma line when the handler says so. Pragma handlers are
//    plan 15 and there is no registry yet, so every pragma is printed (what
//    Zig does for a pragma without a handler).
//  - A pragma line that reaches EOF without NL (impossible in Zig's token
//    stream: preprocessing always emits the NL) stops at the EOF instead of
//    reading past the end.
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

<* Zig `w.flush()`: flush when the stream supports it. *>
fn void? flush_stream(OutStream w) @local
{
	if (&w.flush) w.flush()!;
}

<*
 Zig `fmtEscapes` / `FmtEscapes.format`: write `bytes` as C string contents:
 \n \r \t \\ \" escaped, printable ASCII (' ', '!', '#'..'&', '('..'[',
 ']'..'~') as is, every other byte as \xHH (two lowercase hex digits).
*>
fn void? write_escaped(OutStream w, String bytes)
{
	foreach (c : bytes)
	{
		switch (c)
		{
			case '\n': io::fprint(w, "\\n")!;
			case '\r': io::fprint(w, "\\r")!;
			case '\t': io::fprint(w, "\\t")!;
			case '\\': io::fprint(w, "\\\\")!;
			case '"': io::fprint(w, "\\\"")!;
			case ' ':
			case '!':
			case '#'..'&':
			case '('..'[':
			case ']'..'~':
				w.write_byte(c)!;
			default:
				io::fprintf(w, "\\x%02x", c)!;
		}
	}
}

<*
 Zig `printLinemarker`: '#', "line" for LINE_DIRECTIVES, ` <line_no> "<escaped
 path>"`, and for NUMERIC_DIRECTIVES the flag (" 1" start, " 2" resume) and
 " 3" (SYSTEM) / " 3 4" (EXTERN_C_SYSTEM). No newline.
*>
fn void? Preprocessor.print_linemarker(&self, OutStream w, uint line_no, Source src, LinemarkerFlag start_resume)
{
	w.write_byte('#')!;
	if (self.linemarkers == LINE_DIRECTIVES) io::fprint(w, "line")!;
	io::fprintf(w, " %d \"", line_no)!;
	write_escaped(w, src.path)!;
	w.write_byte('"')!;
	if (self.linemarkers == NUMERIC_DIRECTIVES)
	{
		switch (start_resume)
		{
			case NONE: break;
			case START: io::fprint(w, " 1")!;
			case RESUME: io::fprint(w, " 2")!;
		}
		switch (src.kind)
		{
			case USER: break;
			case SYSTEM: io::fprint(w, " 3")!;
			case EXTERN_C_SYSTEM: io::fprint(w, " 3 4")!;
		}
	}
}

<*
 Zig `prettyPrintMacro`: re-tokenize the #define / #undef at `loc` and print
 it: whitespace runs as one space, comments only after the name (they reset
 the whitespace state), other tokens via tok_slice, stopping at nl/eof or
 right after the name for NAME_ONLY.
 (Re-tokenized because the macro may have been #undef'ed and redefined.)
*>
fn void? Preprocessor.pretty_print_macro(&self, OutStream w, Location loc, MacroParts parts)
{
	Source src = self.comp.get_source(loc.id);
	Tokenizer tz;
	tz.init(src.buf, src.id, self.comp.langopts);
	tz.index = loc.byte_offset;
	bool prev_ws = false; // avoid printing multiple whitespace if /* */ comments are within the macro def
	bool saw_name = false; // do not print comments before the name token is seen.
	while (true)
	{
		RawToken tok = tz.next();
		switch (tok.id)
		{
			case COMMENT:
				if (saw_name)
				{
					prev_ws = false;
					io::fprint(w, self.tok_slice(tok))!;
				}
			case NL:
			case EOF:
				return;
			case WHITESPACE:
				if (!prev_ws)
				{
					w.write_byte(' ')!;
					prev_ws = true;
				}
			default:
				prev_ws = false;
				io::fprint(w, self.tok_slice(tok))!;
		}
		if (tok.id == IDENTIFIER || tok.id == EXTENDED_IDENTIFIER)
		{
			if (parts == NAME_ONLY) return;
			saw_name = true;
		}
	}
}

<* Zig `prettyPrintMacrosOnly`: "#define " + pretty_print_macro(NAME_AND_BODY) + "\n" for each non-builtin macro in definition order. *>
fn void? Preprocessor.pretty_print_macros_only(&self, OutStream w)
{
	foreach (&m : self.defines.macros())
	{
		if (m.is_builtin()) continue;
		io::fprint(w, "#define ")!;
		self.pretty_print_macro(w, m.loc, NAME_AND_BODY)!;
		w.write_byte('\n')!;
	}
	flush_stream(w)!;
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
	if (macro_dump_mode == MACROS_ONLY) return self.pretty_print_macros_only(w);

	TreeToken[] toks = self.tokens.array_view();
	sz i = 0;
	bool last_nl = true;
	while OUTER: (true)
	{
		defer i++;
		TreeToken cur = toks[i];
		switch (cur.id)
		{
			case EOF:
				if (!last_nl) w.write_byte('\n')!;
				flush_stream(w)!;
				return;
			case NL:
				uint newlines = 0;
				for (sz j = i; j < toks.len; j++)
				{
					TokenId id = toks[j].id;
					if (id == NL)
					{
						newlines++;
					}
					else if (id == EOF)
					{
						if (!last_nl) w.write_byte('\n')!;
						flush_stream(w)!;
						return;
					}
					else if (id != WHITESPACE)
					{
						if (self.linemarkers == NONE)
						{
							if (newlines < 2) break;
						}
						else if (newlines < COLLAPSE_NEWLINES)
						{
							break;
						}

						i = (j - 1) - (toks[j - 1].id == WHITESPACE ? 1 : 0);
						if (!last_nl) w.write_byte('\n')!;
						if (self.linemarkers != NONE)
						{
							TreeToken next = toks[i];
							Source src = self.comp.get_source(next.loc.id);
							ExpandedLocation line_col = src.line_col(next.loc);
							self.print_linemarker(w, line_col.line_no, src, NONE)!;
							w.write_byte('\n')!;
							last_nl = true;
						}
						continue OUTER;
					}
				}
				last_nl = true;
				w.write_byte('\n')!;
			case KEYWORD_PRAGMA:
				// Zig: comp.getPragma(name).shouldPreserveTokens (plan 15) may drop the line here.
				io::fprint(w, "#pragma")!;
				i++;
				while (true)
				{
					cur = toks[i];
					if (cur.id == NL)
					{
						w.write_byte('\n')!;
						last_nl = true;
						break;
					}
					if (cur.id == EOF)
					{
						i--; // let the outer loop print the final newline
						break;
					}
					w.write_byte(' ')!;
					io::fprint(w, self.tree_token_slice(cur))!;
					i++;
				}
			case WHITESPACE:
				String slice = self.tree_token_slice(cur);
				while (try nl = slice.index_of_char('\n'))
				{
					if (self.linemarkers != NONE) w.write_byte('\n')!;
					slice = slice[nl + 1..];
				}
				for (sz k = 0; k < slice.len; k++) w.write_byte(' ')!;
				last_nl = false;
			case INCLUDE_START:
				Source src = self.comp.get_source(cur.loc.id);
				self.print_linemarker(w, 1, src, START)!;
				w.write_byte('\n')!;
				last_nl = true;
			case INCLUDE_RESUME:
				Source src = self.comp.get_source(cur.loc.id);
				if (!last_nl) w.write_byte('\n')!;
				self.print_linemarker(w, cur.loc.line, src, RESUME)!;
				w.write_byte('\n')!;
				last_nl = true;
			case LINEMARKER:
				Source src = self.comp.get_source(cur.loc.id);
				if (!last_nl) w.write_byte('\n')!;
				self.print_linemarker(w, cur.loc.line, src, NONE)!;
				last_nl = false;
			case KEYWORD_DEFINE:
			case KEYWORD_UNDEF:
				switch (macro_dump_mode)
				{
					case MACROS_AND_RESULT:
					case MACRO_NAMES_AND_RESULT:
						w.write_byte('#')!;
						self.pretty_print_macro(w, cur.loc, macro_dump_mode == MACROS_AND_RESULT ? NAME_AND_BODY : NAME_ONLY)!;
						last_nl = false;
					case RESULT_ONLY:
						unreachable("store_macro_tokens must be false for standard preprocessor output");
					case MACROS_ONLY:
						unreachable("handled by pretty_print_macros_only");
				}
			default:
				io::fprint(w, self.tree_token_slice(cur))!;
				last_nl = false;
		}
	}
}
