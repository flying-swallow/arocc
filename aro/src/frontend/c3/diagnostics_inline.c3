// Port of c3c src/compiler/diagnostics.c (plus sema_error_at / sema_warn_at
// from semantic_analyser.c, sema_shadow_error from sema_errors.c and the
// PRINT_ERROR_* / SEMA_* macros of compiler_internal.h / sema_internal.h):
// c3c-style error reporting with the message text inline at the call site.
//
// Every entry point that takes a printf format is a macro whose format is a
// compile-time String: `$assert $defined(string::tformat($fmt, ...$vaarg))`
// runs tformat's `@format` check against the arguments at each call site, then
// an out-of-line `*_args` function formats and reports. C `%s` takes a
// String, `%d` any integer, `%c` a char; c3c's `%.*s` becomes `%s` on a slice.
//
// Mapping of the c3c macros (porters expand the RETURN_ forms by hand, since a
// macro cannot return from its caller):
//   PRINT_ERROR_AT(node, ...)            -> @print_error_at(node.loc, ...)
//   RETURN_PRINT_ERROR_AT(v, node, ...)  -> { @print_error_at(node.loc, ...); return v; }
//   PRINT_ERROR_HERE(...)                -> @print_error_here(c, ...)
//   RETURN_PRINT_ERROR_HERE(...)         -> return @print_error_here(c, ...);
//   PRINT_ERROR_LAST(...)                -> @print_error_last(c, ...)
//   RETURN_PRINT_ERROR_LAST(...)         -> return @print_error_last(c, ...);
//   SEMA_ERROR(node, ...)                -> @sema_error_at(context, node.loc, ...)
//   RETURN_SEMA_ERROR(node, ...)         -> return @sema_error_at(context, node.loc, ...);
//   RETURN_SEMA_ERROR_AT(loc, ...)       -> return @sema_error_at(context, loc, ...);
//   SEMA_NOTE(node, ...)                 -> @sema_note_prev_at(node.loc, ...)
//   SEMA_DEPRECATED(node, ...)           -> @sema_deprecated(node.loc, ...)
//   PRINT_DEPRECATED_AT(loc, ...)        -> @print_deprecated_at(loc, ...)
//   PRINT_DEPRECATED_AT_LOC(loc*, ...)   -> @print_deprecated_at_loc(loc*, ...)
// The error macros return `false` (c3c's are void) so RETURN_* forms are one
// statement; the value may be ignored.
//
// Deviations from c3c:
// - Reports go to `global_diagnostics` (compiler.c3) instead of stderr; the
//   sink renders them (source-line excerpt rendering is not ported).
//   `test_output` dropping notes and `lsp_output` are the sink's business.
// - An unlocalized report (c3c `location == NULL`, SourceLocId 0) gets a
//   zeroed span.
// - `sema_error_at` / `sema_warn_at` are macros taking the SemaContext* as
//   an untyped `context` argument and do not print the inlining notes
//   (`sema_print_inline`, semantic_analyser.c3) yet.
// - The MAX_ERROR_LEN truncation of notes is kept (overlong notes are dropped).
module aro::frontend::c3::compiler;
import aro::frontend::c3::diagnostics, aro::frontend::c3::tokens;
import std::core::mem::alloc, std::io;

const int MAX_ERROR_LEN = 4096;

enum PrintType : char
{
	ERROR,
	NOTE,
	WARN,
}

fn Severity print_type_severity(PrintType type) @inline
{
	switch (type)
	{
		case ERROR: return ERROR;
		case NOTE: return NOTE;
		case WARN: return WARNING;
	}
}

<* c3c `print_error_type_at`; takes ownership of `message` (allocated on the sink's allocator). *>
fn void print_error_type_at(SourceLoc* location, String message, PrintType print_type)
{
	if (compiler.context.exit_requested)
	{
		alloc::free(global_diagnostics.allocator, message.ptr);
		return;
	}
	SourceLoc span = location ? *location : {};
	global_diagnostics.add_text(print_type_severity(print_type), span, message);
}

fn String diag_vformat(String message, any[] args) @inline
{
	return string::format(global_diagnostics.allocator, message, ...args);
}

fn void vprint_msg(SourceLoc* location, String message, any[] args, PrintType type)
{
	print_error_type_at(location, diag_vformat(message, args), type);
}

<* c3c `sema_verror_range`. *>
fn void sema_verror_range(SourceLoc* location, String message, args...)
{
	vprint_msg(location, message, args, ERROR);
	compiler.context.errors_found++;
}

<* c3c `sema_vwarn_range`. *>
fn void sema_vwarn_range(SourceLocId location, String message, args...)
{
	vprint_msg(sourcelocptrzero(location), message, args, WARN);
}

<* c3c `sourcelocptrzero` (compiler_internal.h ARENA_DEF): null for id 0. *>
fn SourceLoc* sourcelocptrzero(SourceLocId id) @inline => id ? sourcelocptr(id) : null;

<* Formats into a MAX_ERROR_LEN buffer like c3c's vsnprintf path; overlong text is dropped (null String). *>
fn String diag_vformat_bounded(String message, any[] args)
{
	String text = diag_vformat(message, args);
	if (text.len > MAX_ERROR_LEN - 2)
	{
		alloc::free(global_diagnostics.allocator, text.ptr);
		return {};
	}
	return text;
}

// ---------------------------------------------------------------------------
// Entry points (format-checked macros + out-of-line bodies)

<* c3c `print_error_at_loc`. *>
macro bool @print_error_at_loc(SourceLoc* loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_error_at_loc arguments do not match the format";
	sema_verror_range(loc, $fmt, ...$vaarg);
	return false;
}

<* c3c `print_error_at`. *>
macro bool @print_error_at(SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_error_at arguments do not match the format";
	sema_verror_range(sourcelocptrzero(loc), $fmt, ...$vaarg);
	return false;
}

<* c3c PRINT_ERROR_HERE: error at the current token of ParseContext `c`. *>
macro bool @print_error_here(c, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "PRINT_ERROR_HERE arguments do not match the format";
	sema_verror_range(&c.span, $fmt, ...$vaarg);
	return false;
}

<* c3c PRINT_ERROR_LAST: error at the previous token of ParseContext `c`. *>
macro bool @print_error_last(c, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "PRINT_ERROR_LAST arguments do not match the format";
	sema_verror_range(&c.prev_span, $fmt, ...$vaarg);
	return false;
}

<* c3c `print_error_after`: error just after `curr` (on the last row of a multiline span). *>
macro bool @print_error_after(SourceLoc* curr, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_error_after arguments do not match the format";
	print_error_after_args(curr, $fmt, ...$vaarg);
	return false;
}

fn void print_error_after_args(SourceLoc* curr, String message, args...) @noinline
{
	SourceLoc loc = *curr;
	// Spans cover every line of a multiline token, so the position after
	// it is on its last row, not at the start column plus the full length.
	String contents = source_file_by_id(loc.file_id).contents;
	usz start = loc.offset;
	usz end = start + loc.length;
	bool has_last_row_start = false;
	usz last_row_start = 0;
	for (usz p = start; p < end; p++)
	{
		if (contents.ptr[p] != '\n') continue;
		loc.row++;
		last_row_start = p + 1;
		has_last_row_start = true;
	}
	if (has_last_row_start)
	{
		loc.col = (ushort)(end - last_row_start + 1);
		loc.offset += loc.length;
	}
	else
	{
		loc.col += (ushort)loc.length;
	}
	loc.length = 1;
	sema_verror_range(&loc, message, ...args);
}

<* c3c `sema_warning_at`. *>
macro void @sema_warning_at(SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "sema_warning_at arguments do not match the format";
	sema_vwarn_range(loc, $fmt, ...$vaarg);
}

<* c3c `sema_note_prev_at` (c3c SEMA_NOTE(node, ...) is `@sema_note_prev_at(node.loc, ...)`). *>
macro void @sema_note_prev_at(SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "sema_note_prev_at arguments do not match the format";
	sema_note_prev_at_args(loc, $fmt, ...$vaarg);
}

fn void sema_note_prev_at_args(SourceLocId loc, String message, args...) @noinline
{
	String text = diag_vformat_bounded(message, args);
	// Ignore errors
	if (text.ptr) print_error_type_at(sourcelocptrzero(loc), text, NOTE);
}

<* c3c `sema_warn_prev_at`. *>
macro void @sema_warn_prev_at(SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "sema_warn_prev_at arguments do not match the format";
	sema_warn_prev_at_args(loc, $fmt, ...$vaarg);
}

fn void sema_warn_prev_at_args(SourceLocId loc, String message, args...) @noinline
{
	String text = diag_vformat_bounded(message, args);
	// Ignore errors
	if (text.ptr) print_error_type_at(sourcelocptrzero(loc), text, WARN);
}

bool deprecation_hint_at;
bool deprecation_hint_at_loc;

<* c3c `print_deprecation_at`. *>
macro void @print_deprecation_at(SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_deprecation_at arguments do not match the format";
	print_deprecation_args(sourcelocptrzero(loc), &deprecation_hint_at, $fmt, ...$vaarg);
}

<* c3c `print_deprecation_at_loc`. *>
macro void @print_deprecation_at_loc(SourceLoc* loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_deprecation_at_loc arguments do not match the format";
	print_deprecation_args(loc, &deprecation_hint_at_loc, $fmt, ...$vaarg);
}

<*
 Body of print_deprecation_at(_loc). c3c prints the --warn-deprecation hint
 once to stderr; here it is a NOTE report without a location.
*>
fn void print_deprecation_args(SourceLoc* loc, bool* deprecation_hint, String message, args...) @noinline
{
	String text = diag_vformat_bounded(message, args);
	// Ignore errors
	if (text.ptr)
	{
		print_error_type_at(loc, text, compiler.build.warnings.deprecation == WARN ? PrintType.NOTE : PrintType.ERROR);
	}
	if (!compiler.build.lsp_output && !*deprecation_hint)
	{
		*deprecation_hint = true;
		print_error_type_at(null, "HINT: You may use --warn-deprecation=no to silence deprecation warnings.".copy(global_diagnostics.allocator), NOTE);
	}
}

<* c3c SEMA_DEPRECATED(node, ...) with `node.loc`. *>
macro void @sema_deprecated(SourceLocId loc, String $fmt, ...)
{
	if (compiler.build.test_output && compiler.build.warnings.deprecation > SILENT) @print_error_at(loc, $fmt, ...$vaarg);
	if (compiler.build.warnings.deprecation > SILENT) @print_deprecation_at(loc, $fmt, ...$vaarg);
}

<* c3c PRINT_DEPRECATED_AT. *>
macro void @print_deprecated_at(SourceLocId loc, String $fmt, ...)
{
	if (compiler.build.test_output && compiler.build.warnings.deprecation > SILENT) @print_error_at(loc, $fmt, ...$vaarg);
	if (compiler.build.warnings.deprecation > SILENT) @print_deprecation_at(loc, $fmt, ...$vaarg);
}

<* c3c PRINT_DEPRECATED_AT_LOC. *>
macro void @print_deprecated_at_loc(SourceLoc* loc, String $fmt, ...)
{
	if (compiler.build.test_output && compiler.build.warnings.deprecation > SILENT) @print_error_at_loc(loc, $fmt, ...$vaarg);
	if (compiler.build.warnings.deprecation > SILENT) @print_deprecation_at_loc(loc, $fmt, ...$vaarg);
}

<* c3c `print_error`: an error located only by file name. *>
macro void @print_error(ParseContext* context, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "print_error arguments do not match the format";
	print_error_args(context, $fmt, ...$vaarg);
}

fn void print_error_args(ParseContext* context, String message, args...) @noinline
{
	compiler.context.errors_found++;
	SourceFile* file = context.unit.file;
	String text = diag_vformat(message, args);
	SourceLoc span = { .file_id = file.file_id };
	global_diagnostics.add_text(ERROR, span, text);
}

<* semantic_analyser.c `sema_error_at` (SEMA_ERROR / RETURN_SEMA_ERROR). `context` is the SemaContext*. *>
macro bool @sema_error_at(context, SourceLocId loc, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "sema_error_at arguments do not match the format";
	sema_verror_range(sourcelocptrzero(loc), $fmt, ...$vaarg);
	// c3c: sema_print_inline(context, loc) -- not ported yet.
	return false;
}

<* semantic_analyser.c `sema_warn_at` (SEMA_WARN): reports at `level`; false when it became an error. *>
macro bool @sema_warn_at(context, SourceLocId loc, WarningLevel level, String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "sema_warn_at arguments do not match the format";
	if (level == SILENT) return true;
	bool is_warn = level != ERROR;
	if (is_warn)
	{
		sema_vwarn_range(loc, $fmt, ...$vaarg);
	}
	else
	{
		sema_verror_range(sourcelocptrzero(loc), $fmt, ...$vaarg);
	}
	// c3c: sema_print_inline(context, loc) -- not ported yet.
	return is_warn;
}

<* sema_errors.c `sema_shadow_error`. *>
fn void sema_shadow_error(SemaContext* context, Decl* decl, Decl* old)
{
	@sema_error_at(context, decl.loc, "'%s' would shadow a previous declaration.", decl.name);
	@sema_note_prev_at(old.loc, "The previous use of '%s' was here.", decl.name);
}

// ---------------------------------------------------------------------------
// Location helpers

<* This function is fairly slow, which is a reflection on how often it is supposed to be used. *>
fn void loc_to_scratch(SourceLocId loc)
{
	if (!loc)
	{
		scratch_buffer_append("<unknown code>");
		return;
	}
	SourceLoc* location = sourcelocptr(loc);
	SourceFile* file = source_file_by_id(location.file_id);
	char* current = file.contents.ptr + location.offset;
	bool last_was_whitespace = false;
	for (uint i = 0; i < location.length; i++)
	{
		char c = current[i];
		// This does not properly handle strings
		if (c <= ' ')
		{
			if (last_was_whitespace) continue;
			last_was_whitespace = true;
			scratch_buffer_append_char(' ');
			continue;
		}
		last_was_whitespace = false;
		scratch_buffer_append_char(c);
	}
}

<* This function is fairly slow, which is a reflection on how often it is supposed to be used. *>
fn String span_to_string(SourceLocId span)
{
	SourceLoc* location = sourcelocptr(span);
	SourceFile* file = source_file_by_id(location.file_id);
	return str_copy(file.contents[location.offset:location.length]);
}

fn void assert_print_line(SourceLocId loc)
{
	if (loc == 0)
	{
		io::eprintf("Assert analysing code at unknown location:\n");
		return;
	}
	SourceLoc* location = sourcelocptr(loc);
	SourceFile* file = source_file_by_id(location.file_id);
	io::eprintfn("Assert analysing '%s' at row %d, col %d.", file.name, location.row, location.col);
}
