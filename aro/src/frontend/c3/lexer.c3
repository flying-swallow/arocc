// Port of c3c src/compiler/lexer.c (plus the char helpers it uses from
// utils/lib.h and `file_clean_buffer` from utils/file_utils.c).
//
// The lexer is pulled one token at a time by the parser (`next_token`), as in
// c3c; there is no token array.
//
// Deviations from c3c:
// - Positions are byte indices into `buf` instead of pointers. `buf` is the
//   cleaned source (no BOM, no '\r') followed by NUL padding, so the c3c
//   look-ahead (`peek_next`, `current[2]`) never reads past the allocation.
// - Identifier hashing is left to `Symtab` (no inline FNV-1a).
// - `goto IDENT` / `goto DONE` become flags and early returns.
module aro::frontend::c3::lexer;
import aro::frontend::c3::tokens, aro::frontend::c3::symtab, aro::frontend::c3::diagnostics, std::core::mem::alloc;

excuse NOT_UTF8;

<* c3c MAX_IDENTIFIER_LENGTH. *>
const usz MAX_IDENTIFIER_LENGTH = 127;
<* NUL bytes after the source; covers the largest c3c look-ahead (current[2]). *>
const usz BUFFER_PADDING = 4;

enum LexMode : char
{
	NORMAL,
	CONTRACTS,
}

<* c3c `TokenData`. Which fields are meaningful depends on the token type. *>
struct TokenData
{
	<* Raw spelling of the token in the source. *>
	String lex;
	<* IDENT kinds: interned name; STRING: unescaped contents; DOCS_START: comment text; others: spelling. *>
	String string;
	<* BYTES. *>
	bool is_base64;
	ulong bytes_len;
	<* CHAR_LITERAL: big-endian packed value and byte width (1..16). *>
	uint128 char_value;
	char width;
}

struct Lexer
{
	Allocator allocator;
	Symtab* symtab;
	Diagnostics* diags;
	uint file_id;
	<* Cleaned source followed by BUFFER_PADDING NUL bytes. *>
	char* buf;
	usz len;
	usz lexing_start;
	usz current;
	uint current_row;
	uint start_row;
	usz line_start;
	usz start_row_start;
	TokenData data;
	SourceSpan tok_span;
	TokenType token_type;
	LexMode mode;
}

<*
 c3c `file_clean_buffer`: reject UTF-16, drop a UTF-8 BOM and every '\r'.
 Returns a new buffer of the cleaned text followed by BUFFER_PADDING NUL bytes
 (the String excludes the padding); free it with `alloc::free(a, s.ptr)`.
*>
fn String? clean_source(Allocator a, char[] raw)
{
	if (raw.len >= 2 && ((raw[0] == 0xFF && raw[1] == 0xFE) || (raw[0] == 0xFE && raw[1] == 0xFF))) return NOT_UTF8~;
	usz start = 0;
	if (raw.len >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) start = 3;
	char* out = alloc::malloc(a, (sz)(raw.len - start + BUFFER_PADDING));
	usz n = 0;
	for (usz i = start; i < raw.len; i++)
	{
		if (raw[i] == '\r') continue;
		out[n++] = raw[i];
	}
	for (usz i = 0; i < BUFFER_PADDING; i++) out[n + i] = 0;
	return (String)out[:n];
}

<*
 c3c `lexer_init`. `source` must come from `clean_source` (NUL padded).
 String token contents are allocated with `a`.
*>
fn void Lexer.init(&self, Allocator a, Symtab* st, Diagnostics* d, uint file_id, String source)
{
	*self = { .allocator = a, .symtab = st, .diags = d, .file_id = file_id, .buf = source.ptr, .len = source.len };
	self.current_row = 1;
	self.tok_span.file_id = file_id;
	self.mode = NORMAL;
	self.begin_new_token();
	self.check_bidirectional_markers();
}

<*
 c3c `lexer_next_token`: scan the next token into `token_type`/`data`/`tok_span`.
 On a lexing error the rest of the line is skipped and later tokens are scanned
 (reporting their errors too) until EOF; returns false in that case.
*>
fn bool Lexer.next_token(&self)
{
	if (self.scan_token_inner()) return true;
	if (self.reached_end()) return true;
	bool token_is_ok = false;
	do
	{
		if (!token_is_ok)
		{
			while (!self.reached_end() && self.peek() != '\n') self.next();
		}
		token_is_ok = self.scan_token_inner();
	}
	while (!self.reached_end());
	return false;
}

<* Spelling of the current token. *>
fn String Lexer.token_text(&self) => self.data.lex;

// ---------------------------------------------------------------------------
// Character classes (c3c utils/lib.h)

fn bool char_is_lower(char c) @inline => c >= 'a' && c <= 'z';
fn bool char_is_upper(char c) @inline => c >= 'A' && c <= 'Z';
fn bool char_is_digit(char c) @inline => c >= '0' && c <= '9';
fn bool char_is_letter(char c) @inline => char_is_lower(c) || char_is_upper(c);
fn bool char_is_letter_(char c) @inline => char_is_letter(c) || c == '_';
fn bool char_is_alphanum_(char c) @inline => char_is_letter_(c) || char_is_digit(c);
fn bool char_is_digit_or_(char c) @inline => char_is_digit(c) || c == '_';
fn bool char_is_oct(char c) @inline => c >= '0' && c <= '7';
fn bool char_is_oct_or_(char c) @inline => char_is_oct(c) || c == '_';
fn bool char_is_binary(char c) @inline => c == '0' || c == '1';
fn bool char_is_binary_or_(char c) @inline => char_is_binary(c) || c == '_';
fn bool char_is_hex(char c) @inline => char_hex_to_nibble(c) >= 0;
fn bool char_is_hex_or_(char c) @inline => char_is_hex(c) || c == '_';
fn bool char_is_base64(char c) @inline => char_is_letter(c) || char_is_digit(c) || c == '+' || c == '/';
fn bool char_is_whitespace(char c) @inline => c == ' ' || c == '\t' || c == '\n';

<* Hex digit value, or -1. *>
fn int char_hex_to_nibble(char c)
{
	switch (c)
	{
		case '0'..'9': return c - '0';
		case 'a'..'f': return c - 'a' + 10;
		case 'A'..'F': return c - 'A' + 10;
		default: return -1;
	}
}

<* c3c `char_is_valid_escape`: the escaped value of `\c` ('x', 'u', 'U' map to themselves), or -1. *>
fn int char_is_valid_escape(char c)
{
	switch (c)
	{
		case 'a': return 0x07;
		case 'b': return 0x08;
		case 'e': return 0x1B;
		case 'f': return 0x0C;
		case 'n': return '\n';
		case 'r': return '\r';
		case 't': return '\t';
		case 'v': return 0x0B;
		case 'x': return 'x';
		case 'u': return 'u';
		case 'U': return 'U';
		case '\'': return '\'';
		case '"': return '"';
		case '\\': return '\\';
		case '0': return 0;
		default: return -1;
	}
}

// ---------------------------------------------------------------------------
// Buffer movement

fn char Lexer.peek(&self) @inline => self.buf[self.current];
fn char Lexer.prev(&self) @inline => self.buf[self.current - 1];
fn char Lexer.peek_next(&self) @inline => self.buf[self.current + 1];
fn bool Lexer.reached_end(&self) @inline => self.buf[self.current] == 0;

fn void Lexer.begin_new_token(&self) @inline
{
	self.lexing_start = self.current;
	self.start_row = self.current_row;
	self.start_row_start = self.line_start;
}

<* Step one character forward and return the new current character. *>
fn char Lexer.next(&self) @inline
{
	if (self.buf[self.current++] == '\n')
	{
		self.line_start = self.current;
		self.current_row++;
	}
	return self.buf[self.current];
}

fn void Lexer.backtrack(&self) @inline
{
	self.current--;
	if (self.buf[self.current] == '\n') self.current_row--;
}

fn void Lexer.skip(&self, int steps) @inline
{
	for (int i = 0; i < steps; i++) self.next();
}

fn bool Lexer.match(&self, char expected) @inline
{
	if (self.buf[self.current] != expected) return false;
	self.next();
	return true;
}

// ---------------------------------------------------------------------------
// Token creation

fn void Lexer.set_generic_token(&self, TokenType type)
{
	self.token_type = type;
	usz length = self.current - self.lexing_start;
	self.data.lex = (String)self.buf[self.lexing_start:length];
	self.tok_span.offset = (uint)self.lexing_start;
	self.tok_span.length = length > (usz)int::max ? (uint)int::max : (uint)length;
	self.tok_span.col = (ushort)(self.lexing_start - self.start_row_start + 1);
	self.tok_span.row = self.start_row;
}

fn bool Lexer.new_token(&self, TokenType type, String string)
{
	self.set_generic_token(type);
	self.data.string = string;
	return true;
}

<* New token whose `string` is its own spelling (numbers, bytes). *>
fn bool Lexer.new_lex_token(&self, TokenType type)
{
	self.set_generic_token(type);
	self.data.string = self.data.lex;
	return true;
}

fn SourceSpan Lexer.span_at_start(&self)
{
	return { .file_id = self.file_id, .col = (ushort)(self.lexing_start - self.start_row_start + 1),
	         .offset = (uint)self.lexing_start, .length = 1, .row = self.start_row };
}

fn SourceSpan Lexer.span_at(&self, usz loc, usz len)
{
	if (len > (usz)int::max) len = (usz)int::max;
	return { .file_id = self.file_id, .row = self.current_row, .length = (uint)len,
	         .offset = (uint)loc, .col = (ushort)(loc - self.line_start + 1) };
}

fn SourceSpan Lexer.span_at_current(&self)
{
	return { .file_id = self.file_id, .row = self.current_row, .length = 1,
	         .offset = (uint)self.current, .col = (ushort)(self.current - self.line_start + 1) };
}

<* c3c `add_error_token`: an invalid token covering the scanned text. *>
macro bool Lexer.@error(&self, $diag, ...)
{
	self.set_generic_token(INVALID_TOKEN);
	$diag.@emit(self.diags, self.tok_span, ...$vaarg);
	return false;
}

<* c3c `add_error_token_at_start`: error on the first character of the token. *>
macro bool Lexer.@error_at_start(&self, $diag, ...)
{
	$diag.@emit(self.diags, self.span_at_start(), ...$vaarg);
	self.set_generic_token(INVALID_TOKEN);
	return false;
}

<* c3c `add_error_token_at`: error at an explicit range on the current line. *>
macro bool Lexer.@error_at(&self, usz loc, usz len, $diag, ...)
{
	$diag.@emit(self.diags, self.span_at(loc, len), ...$vaarg);
	self.set_generic_token(INVALID_TOKEN);
	return false;
}

<* c3c `add_error_token_at_current`. *>
macro bool Lexer.@error_at_current(&self, $diag, ...)
{
	$diag.@emit(self.diags, self.span_at_current(), ...$vaarg);
	self.set_generic_token(INVALID_TOKEN);
	return false;
}

// ---------------------------------------------------------------------------
// Comments and whitespace

fn void Lexer.parse_line_comment(&self)
{
	char c;
	while ((c = self.peek()) != 0 && c != '\n') self.next();
	if (c == '\n') self.next();
}

<* Nested block comments. *>
fn void Lexer.parse_multiline_comment(&self)
{
	int nesting = 1;
	while (true)
	{
		switch (self.peek())
		{
			case '*':
				if (self.peek_next() == '/')
				{
					self.skip(2);
					nesting--;
					if (nesting == 0) return;
					continue;
				}
			case '/':
				if (self.peek_next() == '*')
				{
					self.skip(2);
					nesting++;
					continue;
				}
			case 0:
				return;
			default:
				break;
		}
		self.next();
	}
}

fn void Lexer.skip_whitespace(&self)
{
	while (true)
	{
		switch (self.peek())
		{
			case '/':
				if (self.mode == CONTRACTS) return;
				if (self.peek_next() == '/')
				{
					self.skip(2);
					self.parse_line_comment();
					continue;
				}
				if (self.peek_next() == '*')
				{
					self.skip(2);
					self.parse_multiline_comment();
					continue;
				}
				return;
			case '\n':
				if (self.mode == CONTRACTS) return;
				self.next();
			case ' ':
			case '\t':
				self.next();
			case '#':
				if (self.current == 0 && self.peek_next() == '!')
				{
					self.skip(2);
					self.parse_line_comment();
					continue;
				}
				return;
			default:
				return;
		}
	}
}

// ---------------------------------------------------------------------------
// Identifiers

<*
 c3c `scan_ident`: classify as normal (first letter lowercase), const (all
 uppercase) or type (uppercase then lowercase), then intern; keywords come back
 from the symtab with their own type.
*>
fn bool Lexer.scan_ident(&self, TokenType normal, TokenType const_token, TokenType type_token, char prefix)
{
	TokenType type = INVALID_TOKEN;
	while (self.peek() == '_') self.next();
	while (true)
	{
		char c = self.peek();
		switch (c)
		{
			case 'a'..'z':
				if (type == INVALID_TOKEN)
				{
					type = normal;
				}
				else if (type == const_token)
				{
					type = type_token;
				}
			case 'A'..'Z':
				if (type == INVALID_TOKEN) type = const_token;
			case '0'..'9':
				if (type == INVALID_TOKEN) return self.@error(diagnostics::Diagnostic.LEX_DIGIT_BEFORE_LETTER);
			case '_':
				break;
			default:
				return self.finish_ident(type, prefix);
		}
		self.next();
	}
}

fn bool Lexer.finish_ident(&self, TokenType type, char prefix)
{
	usz len = self.current - self.lexing_start;
	if (type == INVALID_TOKEN)
	{
		if (prefix == 0 && len == 1) return self.new_token(UNDERSCORE, "_");
		if (prefix != 0 && len == 1) return self.@error(diagnostics::Diagnostic.LEX_IDENT_EXPECTED_AFTER_PREFIX, prefix);
		return self.@error(diagnostics::Diagnostic.LEX_IDENT_ONLY_UNDERSCORE);
	}
	if (len > MAX_IDENTIFIER_LENGTH)
	{
		return self.@error(diagnostics::Diagnostic.LEX_IDENT_TOO_LONG, (int)MAX_IDENTIFIER_LENGTH, (long)len);
	}
	String interned = self.symtab.add((String)self.buf[self.lexing_start:len], &type);
	if (type == RETURN && self.mode == CONTRACTS) type = IDENT;
	assert(type != INVALID_TOKEN);
	return self.new_token(type, interned);
}

// ---------------------------------------------------------------------------
// Numbers

<* c3c `scan_number_suffix`: Ll uU (+ll) Ff Dd. *>
fn bool Lexer.scan_number_suffix(&self, bool* is_float)
{
	if (self.prev() == '_')
	{
		self.backtrack();
		return self.@error_at_current(diagnostics::Diagnostic.LEX_NUMBER_TRAILING_UNDERSCORE);
	}
	char c = self.peek();
	if (!char_is_alphanum_(c)) return true;
	switch (c | 32)
	{
		case 'l':
			c = self.next();
			if ((c | 32) == 'l') c = self.next();
			if (*is_float) return self.@error_at_current(diagnostics::Diagnostic.LEX_INT_SUFFIX_ON_FLOAT, c);
		case 'u':
			if (*is_float) return self.@error_at_current(diagnostics::Diagnostic.LEX_INT_SUFFIX_ON_FLOAT, c);
			c = self.next();
			if ((c | 32) == 'l')
			{
				c = self.next();
				if ((c | 32) == 'l') c = self.next();
			}
		case 'd':
		case 'f':
			c = self.next();
			*is_float = true;
		default:
			break;
	}
	if (char_is_alphanum_(c))
	{
		self.next();
		return self.@error(diagnostics::Diagnostic.LEX_INVALID_LITERAL);
	}
	return true;
}

<* c3c NEXT_AND_CHECK_NO_MULTIPLE_: step, false after reporting on "__". *>
fn bool Lexer.next_no_double_underscore(&self)
{
	if (self.next() == '_' && self.prev() == '_')
	{
		return self.@error_at_current(diagnostics::Diagnostic.LEX_MULTIPLE_UNDERSCORE);
	}
	return true;
}

<* 0o prefixed octal (no C-style leading zero octals). *>
fn bool Lexer.scan_oct(&self)
{
	if (!char_is_oct(self.peek())) return self.@error_at_current(diagnostics::Diagnostic.LEX_OCTAL_DIGITS);
	self.next();
	while (char_is_oct_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	if (char_is_digit(self.peek())) return self.@error_at_current(diagnostics::Diagnostic.LEX_OCTAL_DIGITS);
	bool is_float = false;
	if (!self.scan_number_suffix(&is_float)) return false;
	if (is_float) return self.@error(diagnostics::Diagnostic.LEX_OCTAL_FLOAT_SUFFIX);
	return self.new_lex_token(INTEGER);
}

fn bool Lexer.scan_binary(&self)
{
	if (!char_is_binary(self.peek())) return self.@error_at_current(diagnostics::Diagnostic.LEX_BINARY_DIGITS);
	self.next();
	while (char_is_binary_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	if (char_is_digit(self.peek())) return self.@error_at_current(diagnostics::Diagnostic.LEX_BINARY_DIGITS);
	bool is_float = false;
	if (!self.scan_number_suffix(&is_float)) return false;
	if (is_float) return self.@error(diagnostics::Diagnostic.LEX_BINARY_FLOAT_SUFFIX);
	return self.new_lex_token(INTEGER);
}

<* Exponent digits after e/E/p/P, with optional sign. *>
fn bool Lexer.scan_exponent(&self)
{
	self.next();
	char c = self.peek();
	self.next();
	if (c == '+' || c == '-')
	{
		c = self.peek();
		self.next();
	}
	if (!char_is_digit(c))
	{
		if (c == 0)
		{
			self.backtrack();
			return self.@error_at_current(diagnostics::Diagnostic.LEX_EXPONENT_EOF);
		}
		if (c == '\n') return self.@error(diagnostics::Diagnostic.LEX_EXPONENT_EOL);
		if (c < 31 || c > 127) self.@error(diagnostics::Diagnostic.LEX_EXPONENT_UNEXPECTED);
		return self.@error(diagnostics::Diagnostic.LEX_EXPONENT_NOT_NUMBER, c);
	}
	while (char_is_digit(self.peek())) self.next();
	return true;
}

<* Hex integers and hex floats (0x1.8p3). *>
fn bool Lexer.scan_hex(&self)
{
	if (!char_is_hex(self.peek())) return self.@error_at_current(diagnostics::Diagnostic.LEX_HEX_DIGITS);
	self.next();
	while (char_is_hex_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	bool is_float = false;
	if (self.peek() == '.' && self.peek_next() != '.')
	{
		is_float = true;
		self.next();
		char c = self.peek();
		if (c == '_') return self.@error_at_current(diagnostics::Diagnostic.LEX_UNDERSCORE_AFTER_DOT);
		if (char_is_hex(c)) self.next();
		while (char_is_hex_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	}
	char c = self.peek();
	if (c == 'p' || c == 'P')
	{
		is_float = true;
		if (!self.scan_exponent()) return false;
	}
	if (!self.scan_number_suffix(&is_float)) return false;
	return self.new_lex_token(is_float ? REAL : INTEGER);
}

fn bool Lexer.scan_dec(&self)
{
	assert(char_is_digit(self.peek()));
	while (char_is_digit_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	bool is_float = false;
	// A single '.' makes a float ("123." included); ".." is a range.
	if (self.peek() == '.' && self.peek_next() != '.')
	{
		is_float = true;
		self.next();
		if (self.peek() == '_') return self.@error_at_current(diagnostics::Diagnostic.LEX_UNDERSCORE_AFTER_DOT);
		while (char_is_digit_or_(self.peek())) if (!self.next_no_double_underscore()) return false;
	}
	char c = self.peek();
	if (c == 'e' || c == 'E')
	{
		is_float = true;
		if (!self.scan_exponent()) return false;
	}
	if (!self.scan_number_suffix(&is_float)) return false;
	return self.new_lex_token(is_float ? REAL : INTEGER);
}

fn bool Lexer.scan_digit(&self)
{
	if (self.peek() == '0')
	{
		switch (self.peek_next())
		{
			case 'x':
			case 'X':
				self.skip(2);
				return self.scan_hex();
			case 'o':
			case 'O':
				self.skip(2);
				return self.scan_oct();
			case 'b':
			case 'B':
				self.skip(2);
				return self.scan_binary();
			default:
				break;
		}
	}
	return self.scan_dec();
}

// ---------------------------------------------------------------------------
// Characters and strings

<* `positions` hex digits, or -1. *>
fn long Lexer.scan_hex_literal(&self, int positions)
{
	long hex = 0;
	for (int j = 0; j < positions; j++)
	{
		hex <<= 4;
		int i = char_hex_to_nibble(self.peek());
		if (i < 0) return -1;
		self.next();
		hex += i;
	}
	return hex;
}

<* Decode the rest of a UTF-8 sequence whose lead byte `c` was consumed; -1 on error (reported). *>
fn long Lexer.scan_utf8(&self, char c)
{
	int utf8_bytes;
	ulong result;
	switch
	{
		case c < 0xc0:
			self.@error(diagnostics::Diagnostic.LEX_INVALID_UTF8);
			return -1;
		case c <= 0xdf:
			result = (ulong)(0x1f & c);
			utf8_bytes = 2;
		case c <= 0xef:
			result = (ulong)(0xf & c);
			utf8_bytes = 3;
		case c <= 0xf7:
			result = (ulong)(0x7 & c);
			utf8_bytes = 4;
		case c <= 0xfb:
			result = (ulong)(0x3 & c);
			utf8_bytes = 5;
		case c <= 0xfd:
			result = (ulong)(0x1 & c);
			utf8_bytes = 6;
		default:
			self.@error(diagnostics::Diagnostic.LEX_INVALID_UTF8);
			return -1;
	}
	for (int i = 1; i < utf8_bytes; i++)
	{
		result <<= 6;
		c = self.peek();
		if (c == 0) return 0xFFFD;
		self.next();
		if ((c & 0xc0) != 0x80)
		{
			self.@error(diagnostics::Diagnostic.LEX_INVALID_UTF8);
			return -1;
		}
		result += (ulong)(c & 0x3f);
	}
	return (long)result;
}

<*
 c3c `scan_char`:
 1. ASCII or \xAB: up to 16 bytes, packed big-endian.
 2. One UTF-8 character: width 2, or 4 above U+FFFF.
 3. ꯍ: width 2. 4. \U01234567: width 4.
*>
fn bool Lexer.scan_char(&self)
{
	if (self.match('\'')) return self.@error(diagnostics::Diagnostic.LEX_CHAR_EMPTY);
	int width = 0;
	uint128 b = 0;
	while (!self.match('\''))
	{
		char c = self.peek();
		self.next();
		if (c == 0) return self.@error_at_start(diagnostics::Diagnostic.LEX_CHAR_UNTERMINATED);
		if (width > 15) return self.@error_at_start(diagnostics::Diagnostic.LEX_CHAR_TOO_LONG);
		if (c >= 0x80)
		{
			if (width != 0) return self.@error(diagnostics::Diagnostic.LEX_CHAR_UNICODE_IN_MULTI);
			long utf8 = self.scan_utf8(c);
			if (utf8 < 0) return false;
			if (!self.match('\''))
			{
				if (self.peek() == 0) continue;
				self.backtrack();
				return self.@error_at_current(diagnostics::Diagnostic.LEX_CHAR_UNICODE_MULTI_CHAR);
			}
			return self.finish_char((uint128)utf8, utf8 > 0xffff ? 4 : 2);
		}
		int escape = ' ';
		if (c == '\n') return self.@error_at_current(diagnostics::Diagnostic.LEX_CHAR_LINE_BREAK);
		if (c == '\\')
		{
			c = self.peek();
			escape = char_is_valid_escape(c);
			if (escape == -1)
			{
				self.lexing_start += 1;
				if (c > ' ' && c <= 127)
				{
					self.next();
					return self.@error(diagnostics::Diagnostic.LEX_INVALID_ESCAPE, c);
				}
				return self.@error_at_current(diagnostics::Diagnostic.LEX_ESCAPE_EXPECTED);
			}
			self.next();
		}
		usz escape_begin = self.current - 2;
		switch (escape)
		{
			case 'x':
				long hex = self.scan_hex_literal(2);
				if (hex < 0)
				{
					return self.@error_at(escape_begin, self.current - escape_begin, diagnostics::Diagnostic.LEX_ESCAPE_HEX2);
				}
				c = (char)hex;
			case 'u':
			case 'U':
				if (width != 0) return self.@error(diagnostics::Diagnostic.LEX_CHAR_UNICODE_IN_MULTI);
				int bytes = escape == 'U' ? 4 : 2;
				long hex = self.scan_hex_literal(bytes * 2);
				if (hex < 0)
				{
					self.begin_new_token();
					return self.@error_at(escape_begin, self.current - escape_begin, diagnostics::Diagnostic.LEX_ESCAPE_UNICODE_HEX,
					                      escape == 'u' ? "a four" : "an eight", (char)escape);
				}
				if (!self.match('\''))
				{
					if (self.peek() == 0) continue;
					return self.@error_at_current(diagnostics::Diagnostic.LEX_CHAR_UNICODE_ESCAPE_MULTI, (char)escape);
				}
				return self.finish_char((uint128)hex, (char)bytes);
			case ' ':
				break;
			default:
				c = (char)escape;
		}
		width++;
		b = (b << 8) + c;
	}
	assert(width > 0 && width <= 16);
	return self.finish_char(b, (char)width);
}

fn bool Lexer.finish_char(&self, uint128 value, char width)
{
	self.set_generic_token(CHAR_LITERAL);
	self.data.char_value = value;
	self.data.width = width;
	return true;
}

<* Append the UTF-8 encoding of `cp` at `dest[*pos]`. *>
fn void append_utf8(char* dest, usz* pos, ulong cp)
{
	switch
	{
		case cp < 0x80:
			dest[(*pos)++] = (char)cp;
		case cp < 0x800:
			dest[(*pos)++] = (char)(0xC0 | (cp >> 6));
			dest[(*pos)++] = (char)(0x80 | (cp & 0x3F));
		case cp < 0x10000:
			dest[(*pos)++] = (char)(0xE0 | (cp >> 12));
			dest[(*pos)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
			dest[(*pos)++] = (char)(0x80 | (cp & 0x3F));
		default:
			dest[(*pos)++] = (char)(0xF0 | (cp >> 18));
			dest[(*pos)++] = (char)(0x80 | ((cp >> 12) & 0x3F));
			dest[(*pos)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
			dest[(*pos)++] = (char)(0x80 | (cp & 0x3F));
	}
}

<* c3c `append_esc_string_token`: decode the escape at `buf[src]` (after '\'); bytes consumed, or -1. *>
fn int Lexer.append_escape(&self, char* dest, usz src, usz* pos)
{
	char* s = self.buf + src;
	int scanned_char = char_is_valid_escape(s[0]);
	if (scanned_char < 0) return -1;
	int digits;
	switch (scanned_char)
	{
		case 'x':
			int h = char_hex_to_nibble(s[1]);
			if (h < 0) return -1;
			int l = char_hex_to_nibble(s[2]);
			if (l < 0) return -1;
			dest[(*pos)++] = (char)((h << 4) + l);
			return 3;
		case 'u':
			digits = 4;
		case 'U':
			digits = 8;
		default:
			dest[(*pos)++] = (char)scanned_char;
			return 1;
	}
	ulong cp = 0;
	for (int i = 1; i <= digits; i++)
	{
		int x = char_hex_to_nibble(s[i]);
		if (x < 0) return -1;
		cp = (cp << 4) + (ulong)x;
	}
	append_utf8(dest, pos, cp);
	return digits + 1;
}

fn void Lexer.consume_to_end_quote(&self)
{
	char c = self.peek();
	while (c != 0 && c != '"') c = self.next();
}

fn bool Lexer.scan_string(&self)
{
	// Find the end first to size the buffer.
	usz cur = self.current;
	while (true)
	{
		char c = self.buf[cur++];
		if (c == '"') break;
		if (c == '\n' || c == 0)
		{
			cur++;
			break;
		}
		if (c == '\\')
		{
			c = self.buf[cur];
			if (c != '\n' && c != 0) cur++;
		}
	}
	usz end = cur - 1;
	char* dest = alloc::malloc(self.allocator, (sz)(end - self.current + 1));
	usz len = 0;
	while (self.current < end)
	{
		char c = self.peek();
		self.next();
		if (c == 0 || (c == '\\' && self.peek() == 0))
		{
			if (c == 0) self.backtrack();
			alloc::free(self.allocator, dest);
			self.@error_at_start(diagnostics::Diagnostic.LEX_STRING_EOF);
			self.consume_to_end_quote();
			return false;
		}
		if (c == '\n' || (c == '\\' && self.peek() == '\n'))
		{
			self.backtrack();
			alloc::free(self.allocator, dest);
			self.@error_at_start(diagnostics::Diagnostic.LEX_STRING_EOL);
			self.consume_to_end_quote();
			return false;
		}
		if (c == '\\')
		{
			int scanned = self.append_escape(dest, self.current, &len);
			if (scanned < 0)
			{
				alloc::free(self.allocator, dest);
				self.@error_at_current(diagnostics::Diagnostic.LEX_STRING_INVALID_ESCAPE);
				self.consume_to_end_quote();
				return false;
			}
			self.skip(scanned);
			continue;
		}
		dest[len++] = c;
	}
	self.next();
	dest[len] = 0;
	return self.new_token(STRING, (String)dest[:len]);
}

<* `raw` string; a doubled backtick is a literal backtick. *>
fn bool Lexer.scan_raw_string(&self)
{
	while (true)
	{
		char c = self.peek();
		self.next();
		if (c == '`' && self.peek() != '`') break;
		if (c == 0) return self.@error_at_start(diagnostics::Diagnostic.LEX_RAW_STRING_EOF);
		if (c == '`') self.next();
	}
	usz cur = self.lexing_start + 1;
	usz end = self.current - 1;
	char* dest = alloc::malloc(self.allocator, (sz)(end - cur + 1));
	usz len = 0;
	while (cur < end)
	{
		char c = self.buf[cur++];
		if (c == '`' && self.buf[cur] == '`') cur++;
		dest[len++] = c;
	}
	dest[len] = 0;
	return self.new_token(STRING, (String)dest[:len]);
}

<* x"..." / x'...' / x`...` hex byte strings. *>
fn bool Lexer.scan_hex_array(&self)
{
	char start_char = self.peek();
	self.next();
	ulong len = 0;
	while (true)
	{
		char c = self.peek();
		if (c == 0) return self.@error_at_current(diagnostics::Diagnostic.LEX_HEX_ARRAY_UNTERMINATED, start_char);
		if (c == start_char) break;
		if (char_is_hex(c))
		{
			self.next();
			len++;
			continue;
		}
		if (char_is_whitespace(c))
		{
			self.next();
			continue;
		}
		if (c > ' ' && c < 127) return self.@error_at_current(diagnostics::Diagnostic.LEX_HEX_ARRAY_INVALID_CHAR, c);
		return self.@error_at_current(diagnostics::Diagnostic.LEX_HEX_ARRAY_INVALID);
	}
	self.next();
	if (len % 2 != 0) return self.@error(diagnostics::Diagnostic.LEX_HEX_ARRAY_ODD);
	self.new_lex_token(BYTES);
	self.data.is_base64 = false;
	self.data.bytes_len = len / 2;
	return true;
}

<* b64"..." / b64'...' / b64`...`. *>
fn bool Lexer.scan_base64(&self)
{
	self.next();
	self.next();
	char start_char = self.peek();
	self.next();
	uint end_len = 0;
	ulong len = 0;
	while (true)
	{
		char c = self.peek();
		if (c == 0) return self.@error_at_start(diagnostics::Diagnostic.LEX_BASE64_UNTERMINATED, start_char);
		self.next();
		if (c == start_char) break;
		if (char_is_base64(c))
		{
			if (end_len != 0) return self.@error_at_current(diagnostics::Diagnostic.LEX_BASE64_AFTER_PAD, c);
			len++;
			continue;
		}
		if (c == '=')
		{
			if (end_len > 1) return self.@error_at_current(diagnostics::Diagnostic.LEX_BASE64_TOO_MUCH_PAD);
			end_len++;
			continue;
		}
		if (!char_is_whitespace(c))
		{
			if (c < ' ' || c > 127) return self.@error_at_current(diagnostics::Diagnostic.LEX_BASE64_INVALID);
			return self.@error_at_current(diagnostics::Diagnostic.LEX_BASE64_INVALID_CHAR, c);
		}
	}
	if (end_len == 0 && len % 4 != 0)
	{
		switch (len % 4)
		{
			case 2: end_len = 2;
			case 3: end_len = 1;
			default: break;
		}
	}
	if ((len + end_len) % 4 != 0) return self.@error_at_start(diagnostics::Diagnostic.LEX_BASE64_PADDING);
	self.new_lex_token(BYTES);
	self.data.is_base64 = true;
	self.data.bytes_len = (3 * len - end_len) / 4;
	return true;
}

// ---------------------------------------------------------------------------
// Doc comments

<*
 c3c `parse_doc_start`: after the doc opener, collect the free text up to the
 first contract line ("@foo") or the doc closer, then switch to contract lexing.
 DOCS_START's `string` is that text with trailing whitespace trimmed.
*>
fn bool Lexer.parse_doc_start(&self)
{
	usz comment_start = 0;
	bool has_comment = false;
	bool may_have_contract = true;
	while (!self.reached_end())
	{
		char c = self.peek();
		switch (c)
		{
			case '\n':
				may_have_contract = true;
				self.next();
				continue;
			case ' ':
			case '\t':
				self.next();
				continue;
			case '*':
				if (self.peek_next() == '>') break;
				may_have_contract = false;
				self.next();
				continue;
			case '@':
				if (may_have_contract && char_is_lower(self.peek_next())) break;
				nextcase default;
			default:
				may_have_contract = false;
				if (!has_comment)
				{
					comment_start = self.current;
					has_comment = true;
				}
				self.next();
				continue;
		}
		break;
	}
	self.mode = CONTRACTS;
	if (!has_comment) return self.new_token(DOCS_START, "");
	usz last = self.current - 1;
	while (last > comment_start && char_is_whitespace(self.buf[last])) last--;
	return self.new_token(DOCS_START, (String)self.buf[comment_start:last - comment_start + 1]);
}

fn bool Lexer.next_is_ident(&self)
{
	usz i = self.current;
	while (self.buf[i] == '_') i++;
	return char_is_lower(self.buf[i]);
}

// ---------------------------------------------------------------------------
// Main scanner

fn bool Lexer.scan_token_inner(&self)
{
	self.skip_whitespace();
	self.begin_new_token();
	if (self.reached_end())
	{
		self.new_token(EOF, "\n");
		return false;
	}
	char c = self.peek();
	self.next();
	switch (c)
	{
		case '\n':
			assert(self.mode == CONTRACTS);
			return self.new_token(DOCS_EOL, "<eol>");
		case '@':
			if (char_is_letter_(self.peek())) return self.scan_ident(AT_IDENT, AT_CONST_IDENT, AT_TYPE_IDENT, '@');
			return self.new_token(AT, "@");
		case '\'':
			return self.scan_char();
		case '`':
			return self.scan_raw_string();
		case '"':
			return self.scan_string();
		case '#':
			if (!self.next_is_ident()) return self.new_token(HASH, "#");
			return self.scan_ident(HASH_IDENT, INVALID_TOKEN, INVALID_TOKEN, '#');
		case '$':
			if (self.match('$'))
			{
				if (char_is_letter(self.peek())) return self.new_token(BUILTIN, "$$");
				return self.@error_at_current(diagnostics::Diagnostic.LEX_BUILTIN_EXPECTED_LETTER);
			}
			return self.scan_ident(CT_IDENT, CT_CONST_IDENT, CT_TYPE_IDENT, '$');
		case ',': return self.new_token(COMMA, ",");
		case ';': return self.new_token(EOS, ";");
		case '{': return self.new_token(LBRACE, "{");
		case '}': return self.new_token(RBRACE, "}");
		case '(': return self.new_token(LPAREN, "(");
		case ')': return self.new_token(RPAREN, ")");
		case '[':
			if (self.match('<')) return self.new_token(LVEC, "[<");
			return self.new_token(LBRACKET, "[");
		case ']': return self.new_token(RBRACKET, "]");
		case '.':
			if (self.match('.'))
			{
				if (self.match('.')) return self.new_token(ELLIPSIS, "...");
				return self.new_token(DOTDOT, "..");
			}
			return self.new_token(DOT, ".");
		case '~': return self.new_token(BIT_NOT, "~");
		case ':':
			return self.match(':') ? self.new_token(SCOPE, "::") : self.new_token(COLON, ":");
		case '!':
			if (self.match('!')) return self.new_token(BANGBANG, "!!");
			return self.match('=') ? self.new_token(NOT_EQUAL, "!=") : self.new_token(BANG, "!");
		case '/':
			return self.match('=') ? self.new_token(DIV_ASSIGN, "/=") : self.new_token(DIV, "/");
		case '*':
			if (self.mode == CONTRACTS && self.match('>'))
			{
				self.mode = NORMAL;
				return self.new_token(DOCS_END, "*>");
			}
			return self.match('=') ? self.new_token(MULT_ASSIGN, "*=") : self.new_token(STAR, "*");
		case '=':
			if (self.match('>')) return self.new_token(IMPLIES, "=>");
			return self.match('=') ? self.new_token(EQEQ, "==") : self.new_token(EQ, "=");
		case '^':
			return self.match('=') ? self.new_token(BIT_XOR_ASSIGN, "^=") : self.new_token(BIT_XOR, "^");
		case '?':
			if (self.match('?')) return self.match('?') ? self.new_token(CT_TERNARY, "???") : self.new_token(QUESTQUEST, "??");
			return self.match(':') ? self.new_token(ELVIS, "?:") : self.new_token(QUESTION, "?");
		case '<':
			if (self.match('<'))
			{
				if (self.match('=')) return self.new_token(SHL_ASSIGN, "<<=");
				return self.new_token(SHL, "<<");
			}
			if (self.mode == NORMAL && self.match('*')) return self.parse_doc_start();
			return self.match('=') ? self.new_token(LESS_EQ, "<=") : self.new_token(LESS, "<");
		case '>':
			if (self.match('>'))
			{
				if (self.match('=')) return self.new_token(SHR_ASSIGN, ">>=");
				return self.new_token(SHR, ">>");
			}
			if (self.match(']')) return self.new_token(RVEC, ">]");
			return self.match('=') ? self.new_token(GREATER_EQ, ">=") : self.new_token(GREATER, ">");
		case '%':
			return self.match('=') ? self.new_token(MOD_ASSIGN, "%=") : self.new_token(MOD, "%");
		case '&':
			if (self.match('&')) return self.match('&') ? self.new_token(CT_AND, "&&&") : self.new_token(AND, "&&");
			return self.match('=') ? self.new_token(BIT_AND_ASSIGN, "&=") : self.new_token(AMP, "&");
		case '|':
			if (self.match('|')) return self.match('|') ? self.new_token(CT_OR, "|||") : self.new_token(OR, "||");
			return self.match('=') ? self.new_token(BIT_OR_ASSIGN, "|=") : self.new_token(BIT_OR, "|");
		case '+':
			if (self.match('+'))
			{
				if (self.match('+')) return self.match('=') ? self.new_token(CT_CONCAT_ASSIGN, "+++=") : self.new_token(CT_CONCAT, "+++");
				return self.new_token(PLUSPLUS, "++");
			}
			if (self.match('=')) return self.new_token(PLUS_ASSIGN, "+=");
			return self.new_token(PLUS, "+");
		case '-':
			if (self.match('>')) return self.new_token(ARROW, "->");
			if (self.match('-')) return self.new_token(MINUSMINUS, "--");
			if (self.match('=')) return self.new_token(MINUS_ASSIGN, "-=");
			return self.new_token(MINUS, "-");
		case 'x':
			char q = self.peek();
			if (q == '"' || q == '\'' || q == '`') return self.scan_hex_array();
			self.backtrack();
			return self.scan_ident(IDENT, CONST_IDENT, TYPE_IDENT, 0);
		case 'b':
			char q = self.buf[self.current + 2];
			if (self.peek() == '6' && self.peek_next() == '4' && (q == '\'' || q == '"' || q == '`')) return self.scan_base64();
			self.backtrack();
			return self.scan_ident(IDENT, CONST_IDENT, TYPE_IDENT, 0);
		case '_':
		case 'a':
		case 'c'..'w':
		case 'y':
		case 'z':
		case 'A'..'Z':
			self.backtrack();
			return self.scan_ident(IDENT, CONST_IDENT, TYPE_IDENT, 0);
		case '0'..'9':
			self.backtrack();
			return self.scan_digit();
		default:
			if (c >= 0x80) return self.@error(diagnostics::Diagnostic.LEX_STRAY_BYTE, c);
			return self.@error(diagnostics::Diagnostic.LEX_STRAY_CHAR, c);
	}
}

<* c3c `check_bidirectional_markers`: reject unbalanced U+202A..U+202E / U+2066..U+2069. *>
fn void Lexer.check_bidirectional_markers(&self)
{
	int balance = 0;
	for (usz i = self.current; i + 2 < self.len + 2; i++)
	{
		if (self.buf[i] != 0xE2) continue;
		char next = self.buf[i + 1];
		if (next == 0) break;
		char type = self.buf[i + 2];
		switch (next)
		{
			case 0x80:
				if (type == 0xAC)
				{
					balance--;
					if (balance < 0) break;
				}
				if (type >= 0xAA && type <= 0xAE) balance++;
				continue;
			case 0x81:
				if (type >= 0xA6 && type <= 0xA8)
				{
					balance++;
				}
				else if (type == 0xA9)
				{
					balance--;
					if (balance < 0) break;
				}
				continue;
			default:
				continue;
		}
		break;
	}
	if (balance != 0) self.@error_at_start(diagnostics::Diagnostic.LEX_BIDI_UNBALANCED);
}
