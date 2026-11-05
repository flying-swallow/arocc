// Directive dispatch and conditional preprocessing from src/aro/Preprocessor.zig.
// OWNER: plan 13.5 `directives`.
//
// `preprocess_extra` is the per-file main loop: it reads raw tokens, handles
// directives at the start of a line and hands every other token to
// expand_macro (13.3). #define goes to `define` (13.3), #error / #warning use
// `stringify` (13.4) and #if / #elif use `expr`, which runs
// expand_macro_exhaustive (13.3) and PpExprParser (13.2).
//
// #include / #include_next / #embed / #pragma dispatch to the plan-15
// implementations in preprocessor.c3. Unsupported provider services still
// propagate explicitly; file lookup and directive faults are not relabeled as
// unsupported directives.
//
// Deviations from Zig (each marked at the point of use):
//  - DIAG_DIRECTIVE_UNSUPPORTED is a C3-only record (plans 14/15 remove its uses).
//  - Reading an IfContext level that was never set (e.g. `#ifdef` without a
//    name followed by `#else`) is a safety-checked panic in Zig (invalid enum
//    value); here it is the same panic via `unreachable`.
//  - `#line N x` with a one-byte non-string filename panics in Zig
//    (`slice[1 .. slice.len - 1]` with start > end); here the alias name is "".
//  - Kept as in Zig: `#elifndef` after `#else` in the main loop reports
//    DIAG_ELIFDEF_AFTER_ELSE, and `skip` reports "#elifdef" as the C23
//    extension for both #elifdef and #elifndef.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;
import std::core::string;

<* C3-only: a directive whose implementation belongs to a later plan returned aro::UNSUPPORTED. *>
const PpDiagnostic DIAG_DIRECTIVE_UNSUPPORTED = { .tmpl = { .fmt = "'{s}' is not supported yet by the C3 port", .kind = ERROR } };

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

<*
 Zig `IfContext.get`: the state of the current level (Zig mem.readPackedInt
 of a u2 at bit level*2, little-endian bit order). An unset level (0b11)
 panics like Zig's safety check.
*>
fn IfNesting IfContext.get(&self)
{
	char bits = (self.kind[self.level / 4] >> ((self.level % 4) * 2)) & 3;
	if (bits == 3) unreachable("#if nesting state read before it was set");
	return IfNesting::values[bits];
}

<* Zig `IfContext.set`. *>
fn void IfContext.set(&self, IfNesting context)
{
	char shift = (self.level % 4) * 2;
	char* b = &self.kind[self.level / 4];
	*b = (char)((*b & ~(3 << shift)) | ((char)context.ordinal << shift));
}

<* Zig `IfContext.increment`: level += 1 (wrapping); true on overflow. *>
fn bool IfContext.increment(&self)
{
	self.level = (char)(self.level + 1);
	return self.level == 0;
}

<* Zig `IfContext.decrement`. *>
fn void IfContext.decrement(&self)
{
	assert(self.level > 0, "#if level underflow");
	self.level--;
}

<*
 Zig `std.fmt.parseInt(u32, s, 10)`: optional '+' / '-' sign, decimal digits
 with '_' separators allowed except first/last, no overflow; "-0" is 0.
 Returns false where Zig fails.
*>
fn bool parse_u32_decimal(String s, uint* out) @local
{
	if (s.len == 0) return false;
	bool neg = false;
	if (s[0] == '+' || s[0] == '-')
	{
		neg = s[0] == '-';
		s = s[1..];
	}
	if (s.len == 0) return false;
	if (s[0] == '_' || s[s.len - 1] == '_') return false;
	ulong acc = 0;
	foreach (c : s)
	{
		if (c == '_') continue;
		if (c < '0' || c > '9') return false;
		acc = acc * 10 + (ulong)(c - '0');
		if (acc > 0xFFFF_FFFF) return false;
	}
	if (neg && acc != 0) return false;
	*out = (uint)acc;
	return true;
}

<*
 Report DIAG_DIRECTIVE_UNSUPPORTED for `what` at `loc` when `f` is
 aro::UNSUPPORTED, then return `f`. Always fails.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn void? Preprocessor.surface_unsupported(&self, Location loc, String what, fault f)
{
	if (f == aro::UNSUPPORTED) self.err_loc(loc, DIAG_DIRECTIVE_UNSUPPORTED, { diagnostics::arg_str(what) })!;
	return f~;
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
 #include / #include_next / #embed / #pragma: file lookup, include markers,
 embed byte tokens, and pragma handling are implemented by plan 15.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn TokenWithExpansionLocs? Preprocessor.preprocess_extra(&self, Source src)
{
	Allocator gpa = self.comp.gpa;
	String guard_name;
	bool has_guard = false;
	if (try g = self.find_include_guard(src))
	{
		guard_name = g;
		has_guard = true;
	}

	self.preprocess_count++;
	Tokenizer tokenizer;
	tokenizer.init(src.buf, src.id, self.comp.langopts, src.splice_locs);

	// Estimate how many new tokens this source will contain.
	self.ensure_total_token_capacity(self.tokens.len() + src.buf.len / 8);

	IfContext if_context = IF_CONTEXT_DEFAULT;

	bool start_of_line = true;
	while (true)
	{
		RawToken tok = tokenizer.next();
		switch (tok.id)
		{
			case HASH:
				if (!start_of_line)
				{
					self.add_token(tokens::from_raw(tok))!;
					break;
				}
				RawToken directive = tokenizer.next_no_ws();
				Location directive_loc = { .id = tok.source, .byte_offset = directive.start, .line = directive.line };
				switch (directive.id)
				{
					case KEYWORD_ERROR:
					case KEYWORD_WARNING:
						if (directive.id == KEYWORD_WARNING && !self.comp.langopts.standard.at_least(C23))
						{
							self.err_loc(directive_loc, DIAG_WARNING_EXTENSION)!;
						}
						// #error tokens..
						self.top_expansion_buf.clear();
						sz char_top = self.char_buf.len();
						defer self.char_buf.size = char_top;

						while (true)
						{
							tok = tokenizer.next();
							if (tok.id == NL || tok.id == EOF) break;
							if (tok.id == WHITESPACE) tok.id = MACRO_WS;
							self.top_expansion_buf.push(tokens::from_raw(tok));
						}
						self.stringify(self.top_expansion_buf.array_view())!;
						// Zig items[char_top + 1 .. len - 2]: drop the quotes and the trailing '\n'.
						String slice = (String)self.char_buf.array_view()[char_top + 1 : self.char_buf.len() - 2 - (char_top + 1)];
						self.err_loc(directive_loc, directive.id == KEYWORD_ERROR ? DIAG_ERROR_DIRECTIVE : DIAG_WARNING_DIRECTIVE, { diagnostics::arg_str(slice) })!;
					case KEYWORD_IF:
						if (if_context.increment())
						{
							fault f = @catch(self.fatal(directive, "too many #if nestings"));
							return f~;
						}
						if (self.expr(&tokenizer)!)
						{
							if_context.set(UNTIL_ENDIF);
							if (self.verbose) self.verbose_log(directive, "entering then branch of #if");
						}
						else
						{
							if_context.set(UNTIL_ELSE);
							self.skip(&tokenizer, UNTIL_ELSE)!;
							if (self.verbose) self.verbose_log(directive, "entering else branch of #if");
						}
					case KEYWORD_IFDEF:
						if (if_context.increment())
						{
							fault f = @catch(self.fatal(directive, "too many #if nestings"));
							return f~;
						}
						String? macro_name = self.expect_macro_name(&tokenizer);
						if (catch f = macro_name)
						{
							if (f != NO_MACRO_NAME) return f~;
							continue;
						}
						self.expect_nl(&tokenizer)!;
						if (self.defines.get(macro_name) != null)
						{
							if_context.set(UNTIL_ENDIF);
							if (self.verbose) self.verbose_log(directive, "entering then branch of #ifdef");
						}
						else
						{
							if_context.set(UNTIL_ELSE);
							self.skip(&tokenizer, UNTIL_ELSE)!;
							if (self.verbose) self.verbose_log(directive, "entering else branch of #ifdef");
						}
					case KEYWORD_IFNDEF:
						if (if_context.increment())
						{
							fault f = @catch(self.fatal(directive, "too many #if nestings"));
							return f~;
						}
						String? macro_name = self.expect_macro_name(&tokenizer);
						if (catch f = macro_name)
						{
							if (f != NO_MACRO_NAME) return f~;
							continue;
						}
						self.expect_nl(&tokenizer)!;
						if (self.defines.get(macro_name) == null)
						{
							if_context.set(UNTIL_ENDIF);
						}
						else
						{
							if_context.set(UNTIL_ELSE);
							self.skip(&tokenizer, UNTIL_ELSE)!;
						}
					case KEYWORD_ELIF:
						if (if_context.level == 0)
						{
							self.err_raw(directive, DIAG_ELIF_WITHOUT_IF)!;
							if_context.increment();
							if_context.set(UNTIL_ELSE);
						}
						else if (if_context.level == 1)
						{
							has_guard = false;
						}
						switch (if_context.get())
						{
							case UNTIL_ELSE:
								if (self.expr(&tokenizer)!)
								{
									if_context.set(UNTIL_ENDIF);
									if (self.verbose) self.verbose_log(directive, "entering then branch of #elif");
								}
								else
								{
									self.skip(&tokenizer, UNTIL_ELSE)!;
									if (self.verbose) self.verbose_log(directive, "entering else branch of #elif");
								}
							case UNTIL_ENDIF:
								self.skip(&tokenizer, UNTIL_ENDIF)!;
							case UNTIL_ENDIF_SEEN_ELSE:
								self.err_raw(directive, DIAG_ELIF_AFTER_ELSE)!;
								skip_to_nl(&tokenizer);
						}
					case KEYWORD_ELIFDEF:
					case KEYWORD_ELIFNDEF:
						bool is_def = directive.id == KEYWORD_ELIFDEF;
						if (!self.comp.langopts.standard.at_least(C23))
						{
							self.err_loc(directive_loc, DIAG_C23_EXTENSION, { diagnostics::arg_str(is_def ? "#elifdef" : "#elifndef") })!;
						}
						if (if_context.level == 0)
						{
							self.err_raw(directive, is_def ? DIAG_ELIFDEF_WITHOUT_IF : DIAG_ELIFNDEF_WITHOUT_IF)!;
							if_context.increment();
							if_context.set(UNTIL_ELSE);
						}
						else if (if_context.level == 1)
						{
							has_guard = false;
						}
						switch (if_context.get())
						{
							case UNTIL_ELSE:
								String? macro_name = self.expect_macro_name(&tokenizer);
								if (catch f = macro_name)
								{
									if (f != NO_MACRO_NAME) return f~;
									if_context.set(UNTIL_ELSE);
									self.skip(&tokenizer, UNTIL_ELSE)!;
									if (self.verbose) self.verbose_log(directive, is_def ? "entering else branch of #elifdef" : "entering else branch of #elifndef");
									break;
								}
								self.expect_nl(&tokenizer)!;
								bool defined = self.defines.get(macro_name) != null;
								if (defined == is_def)
								{
									if_context.set(UNTIL_ENDIF);
									if (self.verbose) self.verbose_log(directive, is_def ? "entering then branch of #elifdef" : "entering then branch of #elifndef");
								}
								else
								{
									if_context.set(UNTIL_ELSE);
									self.skip(&tokenizer, UNTIL_ELSE)!;
									if (self.verbose) self.verbose_log(directive, is_def ? "entering else branch of #elifdef" : "entering else branch of #elifndef");
								}
							case UNTIL_ENDIF:
								self.skip(&tokenizer, UNTIL_ENDIF)!;
							case UNTIL_ENDIF_SEEN_ELSE:
								// Zig reports elifdef_after_else for #elifndef too.
								self.err_raw(directive, DIAG_ELIFDEF_AFTER_ELSE)!;
								skip_to_nl(&tokenizer);
						}
					case KEYWORD_ELSE:
						self.expect_nl(&tokenizer)!;
						if (if_context.level == 0)
						{
							self.err_raw(directive, DIAG_ELSE_WITHOUT_IF)!;
							continue;
						}
						else if (if_context.level == 1)
						{
							has_guard = false;
						}
						switch (if_context.get())
						{
							case UNTIL_ELSE:
								if_context.set(UNTIL_ENDIF_SEEN_ELSE);
								if (self.verbose) self.verbose_log(directive, "#else branch here");
							case UNTIL_ENDIF:
								self.skip(&tokenizer, UNTIL_ENDIF_SEEN_ELSE)!;
							case UNTIL_ENDIF_SEEN_ELSE:
								self.err_raw(directive, DIAG_ELSE_AFTER_ELSE)!;
								skip_to_nl(&tokenizer);
						}
					case KEYWORD_ENDIF:
						self.expect_nl(&tokenizer)!;
						if (if_context.level == 0)
						{
							has_guard = false;
							self.err_raw(directive, DIAG_ENDIF_WITHOUT_IF)!;
							continue;
						}
						else if (if_context.level == 1)
						{
							Tokenizer saved_tokenizer = tokenizer;
							RawToken next = tokenizer.next_no_ws();
							while (next.id == NL) next = tokenizer.next_no_ws();
							if (next.id != EOF) has_guard = false;
							tokenizer = saved_tokenizer;
						}
						if_context.decrement();
					case KEYWORD_DEFINE:
						self.define(&tokenizer, directive)!;
					case KEYWORD_UNDEF:
						String? macro_name = self.expect_macro_name(&tokenizer);
						if (catch f = macro_name)
						{
							if (f != NO_MACRO_NAME) return f~;
							continue;
						}
						if (self.store_macro_tokens) self.add_token(tokens::from_raw(directive))!;
						self.defines.ordered_remove(macro_name);
						if (self.verbose) self.verbose_log(directive, string::tformat("macro %s undefined", macro_name));
						self.expect_nl(&tokenizer)!;
					case KEYWORD_INCLUDE:
						if (catch f = self.include(&tokenizer, FIRST)) self.surface_unsupported(directive_loc, "#include", f)!;
						continue;
					case KEYWORD_INCLUDE_NEXT:
						self.err_loc(directive_loc, DIAG_INCLUDE_NEXT)!;
						WhichInclude which = NEXT;
						if (self.include_depth == 0)
						{
							self.err_loc(directive_loc, DIAG_INCLUDE_NEXT_OUTSIDE_HEADER)!;
							which = FIRST;
						}
						if (catch f = self.include(&tokenizer, which)) self.surface_unsupported(directive_loc, "#include_next", f)!;
					case KEYWORD_EMBED:
						if (!self.comp.langopts.standard.at_least(C23))
						{
							self.err_loc(directive_loc, DIAG_C23_EXTENSION, { diagnostics::arg_str("#embed") })!;
						}
						if (catch f = self.embed(&tokenizer)) self.surface_unsupported(directive_loc, "#embed", f)!;
					case KEYWORD_PRAGMA:
						ExpandBuf expand_buf;
						expand_buf.init(gpa);
						TokenWithExpansionLocs expanded_tok = tokens::from_raw(directive);
						expanded_tok.flags.pragma_directive = true;
						if (catch f = self.pragma(&tokenizer, expanded_tok, &expand_buf))
						{
							free_expand_buf(gpa, &expand_buf);
							self.surface_unsupported(directive_loc, "#pragma", f)!;
						}
						defer expand_buf.free(); // the tokens' arrays move to the output
						self.add_tokens_from_expand_buf(expand_buf.array_view(), {
							.id = NL,
							.loc = { .id = tokenizer.source, .line = tokenizer.line },
						})!;
						continue;
					case KEYWORD_LINE:
						// #line number "file"
						RawToken digits = tokenizer.next_no_ws();
						if (digits.id != PP_NUM) self.err_raw(digits, DIAG_LINE_SIMPLE_DIGIT)!;
						uint new_line;
						bool has_new_line = parse_u32_decimal(self.tok_slice(digits), &new_line);
						if (!has_new_line) self.err_raw(digits, DIAG_LINE_INVALID_NUMBER, { diagnostics::arg_str("#line") })!;

						if (digits.id == EOF || digits.id == NL) continue;
						RawToken name = tokenizer.next_no_ws();
						if (name.id == EOF || name.id == NL) continue;
						if (name.id != STRING_LITERAL) self.err_raw(name, DIAG_LINE_INVALID_FILENAME)!;
						self.expect_nl(&tokenizer)!;

						if (has_new_line) tokenizer.line = new_line;
						tokenizer.source = self.comp.add_source_alias(tokenizer.source, strip_quotes(self.tok_slice(name)), USER);

						if (self.linemarkers != NONE)
						{
							self.add_token({ .id = LINEMARKER, .loc = { .id = tokenizer.source, .byte_offset = tok.start, .line = tokenizer.line } })!;
						}
					case PP_NUM:
						// # number "file" flags
						uint new_line;
						bool has_new_line = parse_u32_decimal(self.tok_slice(directive), &new_line);
						if (!has_new_line) self.err_raw(directive, DIAG_LINE_INVALID_NUMBER, { diagnostics::arg_str("line marker") })!;

						RawToken name = tokenizer.next_no_ws();
						if (name.id == EOF || name.id == NL) continue;
						if (name.id != STRING_LITERAL) self.err_raw(name, DIAG_LINE_INVALID_FILENAME)!;

						TokenId marker_id = LINEMARKER;
						SourceKind source_kind = USER;
						for FLAGS: (int i = 0; i < 4; i++)
						{
							RawToken flag = tokenizer.next_no_ws();
							if (flag.id == EOF || flag.id == NL) break FLAGS;
							String flag_str = self.tok_slice(flag);
							if (flag_str.len == 1)
							{
								switch (flag_str[0])
								{
									case '1':
										if (i == 0)
										{
											marker_id = INCLUDE_START;
											continue FLAGS;
										}
									case '2':
										if (i == 0)
										{
											marker_id = INCLUDE_RESUME;
											continue FLAGS;
										}
									case '3':
										if (source_kind == USER)
										{
											source_kind = SYSTEM;
											continue FLAGS;
										}
									case '4':
										if (source_kind == SYSTEM)
										{
											source_kind = EXTERN_C_SYSTEM;
											continue FLAGS;
										}
									default:
										break;
								}
							}
							self.err_raw(flag, DIAG_LINE_INVALID_FLAG, { diagnostics::arg_str(flag_str) })!;
							skip_to_nl(&tokenizer);
							break FLAGS;
						}

						if (has_new_line) tokenizer.line = new_line;
						tokenizer.source = self.comp.add_source_alias(tokenizer.source, strip_quotes(self.tok_slice(name)), source_kind);

						if (self.linemarkers != NONE)
						{
							self.add_token({ .id = marker_id, .loc = { .id = tokenizer.source, .byte_offset = tok.start, .line = tokenizer.line } })!;
						}
					case NL:
						break;
					case EOF:
						if (if_context.level != 0) self.err_raw(tok, DIAG_UNTERMINATED_CONDITIONAL_DIRECTIVE)!;
						return tokens::from_raw(directive);
					default:
						self.err_raw(tok, DIAG_INVALID_PREPROCESSING_DIRECTIVE)!;
						skip_to_nl(&tokenizer);
				}
				if (self.preserve_whitespace)
				{
					tok.id = NL;
					self.add_token(tokens::from_raw(tok))!;
				}
			case WHITESPACE:
				if (self.preserve_whitespace) self.add_token(tokens::from_raw(tok))!;
			case NL:
				start_of_line = true;
				if (self.preserve_whitespace) self.add_token(tokens::from_raw(tok))!;
			case EOF:
				if (if_context.level != 0) self.err_raw(tok, DIAG_UNTERMINATED_CONDITIONAL_DIRECTIVE)!;
				// The following check needs to occur here and not at the top of the function
				// because a pragma may change the level during preprocessing
				if (src.buf.len > 0 && src.buf[src.buf.len - 1] != '\n')
				{
					self.err_raw(tok, DIAG_NEWLINE_EOF)!;
				}
				if (has_guard)
				{
					uint key = (uint)src.id;
					if (try prev = self.include_guards.get(key)) assert(prev == guard_name);
					self.include_guards.set(key, guard_name);
				}
				return tokens::from_raw(tok);
			case UNTERMINATED_STRING_LITERAL:
			case UNTERMINATED_CHAR_LITERAL:
			case EMPTY_CHAR_LITERAL:
				start_of_line = false;
				self.err_raw(tok, invalid_token_diagnostic(tok.id))!;
				self.expand_macro(&tokenizer, tok)!;
			case UNTERMINATED_COMMENT:
				self.err_raw(tok, DIAG_UNTERMINATED_COMMENT)!;
			default:
				if (tok.id.is_macro_identifier() && @ok(self.poisoned_identifiers.find(self.tok_slice(tok))))
				{
					self.err_raw(tok, DIAG_POISONED_IDENTIFIER)!;
				}
				// Add the token to the buffer doing any necessary expansions.
				start_of_line = false;
				self.expand_macro(&tokenizer, tok)!;
		}
	}
}

<*
 Zig `slice[1 .. slice.len - 1]` on a #line / line-marker filename token.
 Deviation: Zig panics (start > end) for a one-byte token; here that is "".
*>
fn String strip_quotes(String s) @local
{
	if (s.len < 2) return "";
	return s[1 : s.len - 2];
}

<*
 Zig `findIncludeGuard`: if the first non-newline tokens are `# ifndef IDENT`
 return IDENT (a slice of the source), else NO_INCLUDE_GUARD. Uses a fresh
 tokenizer with no splice locations.
 @return? NO_INCLUDE_GUARD
*>
fn String? Preprocessor.find_include_guard(&self, Source src)
{
	Tokenizer tokenizer;
	tokenizer.init(src.buf, src.id, self.comp.langopts);
	RawToken hash = tokenizer.next_no_ws();
	while (hash.id == NL) hash = tokenizer.next_no_ws();
	if (hash.id != HASH) return NO_INCLUDE_GUARD~;
	RawToken ifndef = tokenizer.next_no_ws();
	if (ifndef.id != KEYWORD_IFNDEF) return NO_INCLUDE_GUARD~;
	RawToken guard = tokenizer.next_no_ws();
	if (guard.id != IDENTIFIER) return NO_INCLUDE_GUARD~;
	return self.tok_slice(guard);
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
	Allocator gpa = self.comp.gpa;
	defer free_buf_tokens(gpa, self.top_expansion_buf.array_view());

	self.top_expansion_buf.clear();
	RawToken eof;
	while (true)
	{
		RawToken tok = tokenizer.next();
		switch (tok.id)
		{
			case NL:
			case EOF:
				eof = tok;
				break;
			case WHITESPACE:
				if (self.top_expansion_buf.len() == 0) continue;
			case COMMENT:
				continue;
			case UNTERMINATED_STRING_LITERAL:
			case UNTERMINATED_CHAR_LITERAL:
			case EMPTY_CHAR_LITERAL:
				self.err_raw(tok, invalid_token_diagnostic(tok.id))!;
			case UNTERMINATED_COMMENT:
				self.err_raw(tok, DIAG_UNTERMINATED_COMMENT)!;
				continue;
			default:
				if (tok.id.is_macro_identifier() && @ok(self.poisoned_identifiers.find(self.tok_slice(tok))))
				{
					self.err_raw(tok, DIAG_POISONED_IDENTIFIER)!;
				}
		}
		if (tok.id == NL || tok.id == EOF) break;
		self.top_expansion_buf.push(tokens::from_raw(tok));
	}
	if (self.top_expansion_buf.len() != 0)
	{
		self.expansion_source_loc = self.top_expansion_buf[0].loc;
		self.hideset.clear_retaining_capacity();
		self.expand_macro_exhaustive(null, &self.top_expansion_buf, 0, self.top_expansion_buf.len(), EXPR)!;
		remove_placemarkers(gpa, &self.top_expansion_buf);
	}

	PpExprParser parser = {
		.pp = self,
		.tokens = self.top_expansion_buf.array_view(),
		.eof = tokens::from_raw(eof),
	};
	PpValue? val = parser.parse();
	if (catch f = val)
	{
		if (f == EXPR_FAILED) return false;
		return f~;
	}
	return val.to_bool();
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
	uint ifs_seen = 0;
	bool line_start = true;
	while (tokenizer.index < tokenizer.buf.len)
	{
		if (line_start)
		{
			Tokenizer saved_tokenizer = *tokenizer;
			RawToken hash = tokenizer.next_no_ws();
			if (hash.id == NL) continue;
			line_start = false;
			if (hash.id != HASH) continue;
			RawToken directive = tokenizer.next_no_ws();
			switch (directive.id)
			{
				case KEYWORD_ELSE:
					if (ifs_seen != 0) continue;
					if (cont == UNTIL_ENDIF_SEEN_ELSE)
					{
						self.err_raw(directive, DIAG_ELSE_AFTER_ELSE)!;
						continue;
					}
					*tokenizer = saved_tokenizer;
					return;
				case KEYWORD_ELIF:
					if (ifs_seen != 0 || cont == UNTIL_ENDIF) continue;
					if (cont == UNTIL_ENDIF_SEEN_ELSE)
					{
						self.err_raw(directive, DIAG_ELIF_AFTER_ELSE)!;
						continue;
					}
					*tokenizer = saved_tokenizer;
					return;
				case KEYWORD_ELIFDEF:
				case KEYWORD_ELIFNDEF:
					if (!self.comp.langopts.standard.at_least(C23))
					{
						// Zig says "#elifdef" for #elifndef as well.
						self.err_raw(directive, DIAG_C23_EXTENSION, { diagnostics::arg_str("#elifdef") })!;
					}
					if (ifs_seen != 0 || cont == UNTIL_ENDIF) continue;
					if (cont == UNTIL_ENDIF_SEEN_ELSE)
					{
						self.err_raw(directive, directive.id == KEYWORD_ELIFDEF ? DIAG_ELIFDEF_AFTER_ELSE : DIAG_ELIFNDEF_AFTER_ELSE)!;
						continue;
					}
					*tokenizer = saved_tokenizer;
					return;
				case KEYWORD_ENDIF:
					if (ifs_seen == 0)
					{
						*tokenizer = saved_tokenizer;
						return;
					}
					ifs_seen--;
				case KEYWORD_IF:
				case KEYWORD_IFDEF:
				case KEYWORD_IFNDEF:
					ifs_seen++;
				case NL:
					line_start = true;
				default:
					break;
			}
		}
		else if (tokenizer.buf[tokenizer.index] == '\n')
		{
			line_start = true;
			tokenizer.index++;
			tokenizer.line++;
			if (self.preserve_whitespace)
			{
				self.add_token({ .id = NL, .loc = { .id = tokenizer.source, .line = tokenizer.line } })!;
			}
		}
		else
		{
			line_start = false;
			tokenizer.index++;
		}
	}
}

<* Zig `skipToNl`: consume tokens up to and including the next nl / eof. *>
fn void skip_to_nl(Tokenizer* tokenizer)
{
	while (true)
	{
		RawToken tok = tokenizer.next();
		if (tok.id == NL || tok.id == EOF) return;
	}
}

<*
 Zig `expectMacroName`: next_no_ws must be a macro identifier (its tok_slice
 is returned); otherwise DIAG_MACRO_NAME_MISSING, skip_to_nl and
 NO_MACRO_NAME (Zig null).
 @return? NO_MACRO_NAME, compilation::FATAL_ERROR
*>
fn String? Preprocessor.expect_macro_name(&self, Tokenizer* tokenizer)
{
	RawToken macro_name = tokenizer.next_no_ws();
	if (!macro_name.id.is_macro_identifier())
	{
		self.err_raw(macro_name, DIAG_MACRO_NAME_MISSING)!;
		skip_to_nl(tokenizer);
		return NO_MACRO_NAME~;
	}
	return self.tok_slice(macro_name);
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
	bool sent_err = false;
	while (true)
	{
		RawToken tok = tokenizer.next();
		if (tok.id == NL || tok.id == EOF) return;
		if (tok.id == WHITESPACE || tok.id == COMMENT) continue;
		if (!sent_err)
		{
			sent_err = true;
			self.err_raw(tok, DIAG_EXTRA_TOKENS_DIRECTIVE_END)!;
		}
	}
}
