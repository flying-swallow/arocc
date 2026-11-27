// Diagnostics for the C3 frontend: the single `Diagnostic` enum (all phases,
// grouped by `DiagnosticPhase`) and the report sink.
//
// Message text is copied verbatim from c3c (`sema_error_at`, `add_error_token`,
// ...) so that c3c test-suite `// #error:` expectations match. `fmt` is C3
// printf syntax: emit with `Diagnostic.X.@emit(sink, span, args...)`, which
// checks the arguments against `fmt` at compile time. Never hand-write text.
//
// The parser and sema keep c3c's inline message text instead
// (compiler::@print_error_at ... in diagnostics_inline.c3); those reports go
// through `Diagnostics.add_text` as `INLINE_TEXT`. `error_counter` lets the
// compiler module count lexer ERRORs in c3c's `compiler.context.errors_found`
// (the inline reporters bump it themselves, like c3c's sema_verror_range).
//
// Separate from aro::frontend::c::diagnostics on purpose (frontend isolation).
module aro::frontend::c3::diagnostics;
import aro::compiler::reporting;
import aro::frontend::c3::tokens;
import std::io, std::collections::list, std::core::string::ansi, std::core::mem::alloc;

enum Severity : char (String label)
{
	NOTE { "Note" },
	WARNING { "Warning" },
	ERROR { "Error" },
}

enum DiagnosticPhase : char
{
	LEXER,
	<* Free-form c3c-style text reported through `Diagnostics.add_text` (compiler::diagnostics_inline.c3). *>
	INLINE,
}

enum Diagnostic : ushort (String fmt, Severity severity, DiagnosticPhase phase)
{
	// ---- Lexer (c3c lexer.c) ----
	LEX_DIGIT_BEFORE_LETTER { "A letter must precede any digit", ERROR, LEXER },
	LEX_IDENT_EXPECTED_AFTER_PREFIX { "An identifier was expected after the '%c'.", ERROR, LEXER },
	LEX_IDENT_ONLY_UNDERSCORE { "An identifier may not consist of only '_' characters.", ERROR, LEXER },
	LEX_IDENT_TOO_LONG { "An identifier cannot be longer than %d characters, but this one was %d characters long.", ERROR, LEXER },
	LEX_NUMBER_TRAILING_UNDERSCORE { "The number ended with '_', which isn't allowed, please remove it.", ERROR, LEXER },
	LEX_INT_SUFFIX_ON_FLOAT { "Integer suffix '%c' is not valid for a floating point literal.", ERROR, LEXER },
	LEX_INVALID_LITERAL { "This doesn't seem to be a valid literal.", ERROR, LEXER },
	LEX_MULTIPLE_UNDERSCORE { "Multiple consecutive '_' are not allowed.", ERROR, LEXER },
	LEX_OCTAL_DIGITS { "An expression starting with '0o' should be followed by octal numbers (0-7).", ERROR, LEXER },
	LEX_OCTAL_FLOAT_SUFFIX { "Octal literals cannot have a floating point suffix.", ERROR, LEXER },
	LEX_BINARY_DIGITS { "An expression starting with '0b' should be followed by binary digits (0-1).", ERROR, LEXER },
	LEX_BINARY_FLOAT_SUFFIX { "Binary literals cannot have a floating point suffix.", ERROR, LEXER },
	LEX_EXPONENT_EOF { "End of file was reached while parsing the exponent.", ERROR, LEXER },
	LEX_EXPONENT_EOL { "End of line was reached while parsing the exponent.", ERROR, LEXER },
	LEX_EXPONENT_UNEXPECTED { "An unexpected character was found while parsing the exponent.", ERROR, LEXER },
	LEX_EXPONENT_NOT_NUMBER { "Parsing the floating point exponent failed, because '%c' is not a number.", ERROR, LEXER },
	LEX_HEX_DIGITS { "'0x' starts a hexadecimal number, so the next character should be 0-9, a-f or A-F.", ERROR, LEXER },
	LEX_UNDERSCORE_AFTER_DOT { "'_' is not allowed directly after decimal point, try removing it.", ERROR, LEXER },
	LEX_INVALID_UTF8 { "Invalid UTF-8 sequence.", ERROR, LEXER },
	LEX_CHAR_EMPTY { "The character literal was empty.", ERROR, LEXER },
	LEX_CHAR_UNTERMINATED { "The character literal did not terminate.", ERROR, LEXER },
	LEX_CHAR_TOO_LONG { "The character literal exceeds 16 characters.", ERROR, LEXER },
	LEX_CHAR_UNICODE_MULTI_CHAR { "Unicode character literals may only contain one character, please remove the additional ones or use all ASCII.", ERROR, LEXER },
	LEX_CHAR_LINE_BREAK { "A line break is not allowed in a character literal.", ERROR, LEXER },
	LEX_INVALID_ESCAPE { "Invalid escape sequence '\\%c'.", ERROR, LEXER },
	LEX_ESCAPE_EXPECTED { "An escape sequence was expected after '\\'.", ERROR, LEXER },
	LEX_ESCAPE_HEX2 { "Expected a two character hex value after \\x.", ERROR, LEXER },
	LEX_ESCAPE_UNICODE_HEX { "Expected %s character hex value after \\%c.", ERROR, LEXER },
	LEX_CHAR_UNICODE_ESCAPE_MULTI { "Character literals with '\\%c' can only contain one character, please remove this one.", ERROR, LEXER },
	LEX_CHAR_UNICODE_IN_MULTI { "A multi-character literal may not contain unicode characters.", ERROR, LEXER },
	LEX_STRING_EOF { "The end of the file was reached while parsing the string. Did you forget (or accidentally add) a '\"' somewhere?", ERROR, LEXER },
	LEX_STRING_EOL { "The end of the line was reached while parsing the string. Did you forget (or accidentally add) a '\"' somewhere?", ERROR, LEXER },
	LEX_STRING_INVALID_ESCAPE { "Invalid escape in string.", ERROR, LEXER },
	LEX_RAW_STRING_EOF { "Reached the end of the file looking for the end of the raw string that starts here. Did you forget a '`' somewhere?", ERROR, LEXER },
	LEX_HEX_ARRAY_UNTERMINATED { "The hex string seems to be missing a terminating '%c'", ERROR, LEXER },
	LEX_HEX_ARRAY_INVALID_CHAR { "'%c' isn't a valid hexadecimal digit, all digits should be a-z, A-Z and 0-9.", ERROR, LEXER },
	LEX_HEX_ARRAY_INVALID { "This isn't a valid hexadecimal digit, all digits should be a-z, A-Z and 0-9.", ERROR, LEXER },
	LEX_HEX_ARRAY_ODD { "The hexadecimal string is not an even length, did you miss a digit somewhere?", ERROR, LEXER },
	LEX_BASE64_UNTERMINATED { "The base64 string seems to be missing a terminating '%c'", ERROR, LEXER },
	LEX_BASE64_AFTER_PAD { "'%c' can't be placed after an ending '='", ERROR, LEXER },
	LEX_BASE64_TOO_MUCH_PAD { "There cannot be more than 2 '=' at the end of a base64 string.", ERROR, LEXER },
	LEX_BASE64_INVALID { "A valid base64 character was expected here.", ERROR, LEXER },
	LEX_BASE64_INVALID_CHAR { "'%c' is not a valid base64 character.", ERROR, LEXER },
	LEX_BASE64_PADDING { "Base64 strings must either be padded to multiple of 4, or if unpadded - only need 1 or 2 bytes of extra padding.", ERROR, LEXER },
	LEX_BUILTIN_EXPECTED_LETTER { "Expected a letter after $$.", ERROR, LEXER },
	LEX_STRAY_BYTE { "The 0x%x character may not be placed outside of a string or comment, did you forget a \" somewhere?", ERROR, LEXER },
	LEX_STRAY_CHAR { "'%c' may not be placed outside of a string or comment, did you perhaps forget a \" somewhere?", ERROR, LEXER },
	LEX_BIDI_UNBALANCED { "Invalid encoding - Unbalanced bidirectional markers.", ERROR, LEXER },

	// ---- Inline text (parser / sema). The message is formatted at the c3c
	// call site (compiler::@print_error_at ...); `severity` is per report.
	INLINE_TEXT { "%s", ERROR, INLINE },
}

<* One reported diagnostic. `text` is owned by the sink's allocator. *>
struct Report
{
	Diagnostic diag;
	Severity severity;
	SourceSpan span;
	String text;
}

enum OutputKind : char
{
	TO_LIST,
	TO_WRITER,
}

<* Report sink. TO_LIST keeps every report (tests, -verify style runs); TO_WRITER prints immediately and keeps only counts. *>
struct Diagnostics
{
	Allocator allocator;
	OutputKind output;
	OutStream writer;
	bool use_ansi;
	<* Path of each file id, for rendering locations. *>
	List{String} file_paths;
	List{Report} reports;
	uint errors;
	uint warnings;
	<* When set, bumped for every ERROR reported through `add` (c3c lexer errors bump `compiler.context.errors_found`). *>
	int* error_counter;
}

fn void Diagnostics.init_list(&self, Allocator a)
{
	*self = { .allocator = a, .output = TO_LIST };
	self.file_paths.init(a);
	self.reports.init(a);
}

fn void Diagnostics.init_writer(&self, Allocator a, OutStream writer, bool use_ansi)
{
	self.init_list(a);
	self.output = TO_WRITER;
	self.writer = writer;
	self.use_ansi = use_ansi;
}

fn void Diagnostics.free(&self)
{
	foreach (r : self.reports) alloc::free(self.allocator, r.text.ptr);
	self.reports.free();
	self.file_paths.free();
	*self = {};
}

<* Register the path printed for `file_id` (ids are dense, in registration order). *>
fn uint Diagnostics.add_file(&self, String path)
{
	self.file_paths.push(path);
	return (uint)self.file_paths.len() - 1;
}

<*
 Report `$self` at `span`. `$self.fmt` is a constant, so the `$assert` runs
 `string::tformat`'s `@format` check at every call site without generating code;
 formatting happens out of line in `emit_args`.
*>
macro void Diagnostic.@emit($self, Diagnostics* d, SourceSpan span, ...)
{
	$assert $defined(string::tformat($self.fmt, ...$vaarg)) : "diagnostic arguments do not match its format";
	$self.emit_args(d, span, ...$vaarg);
}

<* Out-of-line body of `@emit`. *>
fn void Diagnostic.emit_args(self, Diagnostics* d, SourceSpan span, args...) @noinline
{
	d.add(self, span, string::format(d.allocator, self.fmt, ...args));
}

<* Internal sink under `@emit`; takes ownership of `text`. *>
fn void Diagnostics.add(&self, Diagnostic diag, SourceSpan span, String text)
{
	if (diag.severity == ERROR && self.error_counter) (*self.error_counter)++;
	self.add_report({ .diag = diag, .severity = diag.severity, .span = span, .text = text });
}

<*
 Text sink for the c3c-style inline reporters (`compiler::sema_verror_range`
 and friends); takes ownership of `text`, which must come from `self.allocator`.
*>
fn void Diagnostics.add_text(&self, Severity severity, SourceSpan span, String text)
{
	self.add_report({ .diag = INLINE_TEXT, .severity = severity, .span = span, .text = text });
}

fn void Diagnostics.add_report(&self, Report r)
{
	String text = r.text;
	switch (r.severity)
	{
		case ERROR: self.errors++;
		case WARNING: self.warnings++;
		case NOTE: break;
	}
	if (self.output == TO_WRITER)
	{
		(void)self.write_report(&r);
		alloc::free(self.allocator, text.ptr);
		return;
	}
	self.reports.push(r);
}

<* c3c-style one-line rendering: `(path:row:col) Error: text`. *>
fn void? Diagnostics.write_report(&self, Report* r)
{
	OutStream w = self.writer;
	bool use_ansi = self.use_ansi;
	String path = r.span.file_id < self.file_paths.len() ? self.file_paths[r.span.file_id] : "<unknown>";
	if (use_ansi) io::write_all(w, ansi::Ansi.BOLD)!;
	io::fprintf(w, "(%s:%d:%d) ", path, r.span.row, r.span.col)!;
	switch (r.severity)
	{
		case ERROR: if (use_ansi) io::write_all(w, ansi::Ansi.BRIGHT_RED)!;
		case WARNING: if (use_ansi) io::write_all(w, ansi::Ansi.BRIGHT_MAGENTA)!;
		case NOTE: if (use_ansi) io::write_all(w, ansi::Ansi.BRIGHT_CYAN)!;
	}
	io::write_all(w, r.severity.label)!;
	io::write_all(w, ": ")!;
	if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
	io::write_all(w, r.text)!;
	io::write_all(w, "\n")!;
}

// Tooling reports have no language source span or warning option policy.
fn void? report_tooling(void* context, reporting::Severity severity, String text, String option)
{
	Diagnostics* diagnostics = (Diagnostics*)context;
	Severity kind;
	switch (severity)
	{
		case OFF: return;
		case NOTE: kind = NOTE;
		case WARNING: kind = WARNING;
		case ERROR: case FATAL_ERROR: kind = ERROR;
	}
	if (kind == ERROR && diagnostics.error_counter) (*diagnostics.error_counter)++;
	diagnostics.add_text(kind, { .file_id = uint::max }, text.copy(diagnostics.allocator));
}

fn reporting::Sink Diagnostics.tooling_sink(&self) => { .context = self, .report = &report_tooling };
