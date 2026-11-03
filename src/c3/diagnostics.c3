// Port of src/aro/Diagnostics.zig: diagnostic messages, warning options and
// groups, the -W state machine (effective_kind), output to a writer / a
// collected list / nowhere, macro backtrace notes and message rendering.
//
// Zig's comptime formatting and reflection are replaced by:
//  - `Option` carrying its flag spelling as an associated value,
//  - explicit group tables (`option_group`),
//  - `format_args` over a `DiagArg[]` with the same "{s}" / "{d}" templates.
// Phase-specific message tables (Parser, Preprocessor, ...) are ported with
// their callers as `DiagnosticTemplate` constants.
module aro::diagnostics;
import aro::source, aro::compilation, std::io, std::collections::list;

<* Zig `Message.Kind`; the label is the `{t}` spelling used in output. Order matters (max for -Wpedantic). *>
enum MessageKind : char (String label)
{
	OFF { "off" },
	NOTE { "note" },
	WARNING { "warning" },
	ERROR { "error" },
	FATAL_ERROR { "fatal error" },
}

<* Zig `Diagnostics.Option` in declaration order; `flag` is the -W<flag> spelling. *>
enum Option : ushort (String flag)
{
	UNSUPPORTED_PRAGMA { "unsupported-pragma" },
	IMPLICIT_INT { "implicit-int" },
	DUPLICATE_DECL_SPECIFIER { "duplicate-decl-specifier" },
	MISSING_DECLARATION { "missing-declaration" },
	EXTERN_INITIALIZER { "extern-initializer" },
	IMPLICIT_FUNCTION_DECLARATION { "implicit-function-declaration" },
	UNUSED_VALUE { "unused-value" },
	UNREACHABLE_CODE { "unreachable-code" },
	UNKNOWN_WARNING_OPTION { "unknown-warning-option" },
	GNU_EMPTY_STRUCT { "gnu-empty-struct" },
	GNU_ALIGNOF_EXPRESSION { "gnu-alignof-expression" },
	MACRO_REDEFINED { "macro-redefined" },
	GENERIC_QUAL_TYPE { "generic-qual-type" },
	MULTICHAR { "multichar" },
	POINTER_INTEGER_COMPARE { "pointer-integer-compare" },
	COMPARE_DISTINCT_POINTER_TYPES { "compare-distinct-pointer-types" },
	LITERAL_CONVERSION { "literal-conversion" },
	CAST_QUALIFIERS { "cast-qualifiers" },
	ARRAY_BOUNDS { "array-bounds" },
	INT_CONVERSION { "int-conversion" },
	POINTER_TYPE_MISMATCH { "pointer-type-mismatch" },
	INCOMPATIBLE_POINTER_TYPES { "incompatible-pointer-types" },
	EXCESS_INITIALIZERS { "excess-initializers" },
	DIVISION_BY_ZERO { "division-by-zero" },
	INITIALIZER_OVERRIDES { "initializer-overrides" },
	INCOMPATIBLE_POINTER_TYPES_DISCARDS_QUALIFIERS { "incompatible-pointer-types-discards-qualifiers" },
	UNKNOWN_ATTRIBUTES { "unknown-attributes" },
	IGNORED_ATTRIBUTES { "ignored-attributes" },
	BUILTIN_MACRO_REDEFINED { "builtin-macro-redefined" },
	GNU_LABEL_AS_VALUE { "gnu-label-as-value" },
	MALFORMED_WARNING_CHECK { "malformed-warning-check" },
	PRAGMA_MESSAGES { "#pragma-messages" },
	NEWLINE_EOF { "newline-eof" },
	EMPTY_TRANSLATION_UNIT { "empty-translation-unit" },
	IMPLICITLY_UNSIGNED_LITERAL { "implicitly-unsigned-literal" },
	UNICODE_ZERO_WIDTH { "unicode-zero-width" },
	UNICODE_HOMOGLYPH { "unicode-homoglyph" },
	UNICODE { "unicode" },
	RETURN_TYPE { "return-type" },
	DOLLAR_IN_IDENTIFIER_EXTENSION { "dollar-in-identifier-extension" },
	UNKNOWN_PRAGMAS { "unknown-pragmas" },
	PREDEFINED_IDENTIFIER_OUTSIDE_FUNCTION { "predefined-identifier-outside-function" },
	MANY_BRACES_AROUND_SCALAR_INIT { "many-braces-around-scalar-init" },
	UNINITIALIZED { "uninitialized" },
	GNU_STATEMENT_EXPRESSION { "gnu-statement-expression" },
	GNU_IMAGINARY_CONSTANT { "gnu-imaginary-constant" },
	GNU_COMPLEX_INTEGER { "gnu-complex-integer" },
	IGNORED_QUALIFIERS { "ignored-qualifiers" },
	INTEGER_OVERFLOW { "integer-overflow" },
	EXTRA_SEMI { "extra-semi" },
	GNU_BINARY_LITERAL { "gnu-binary-literal" },
	VARIADIC_MACROS { "variadic-macros" },
	VARARGS { "varargs" },
	WARNINGS { "#warnings" },
	DEPRECATED_DECLARATIONS { "deprecated-declarations" },
	BACKSLASH_NEWLINE_ESCAPE { "backslash-newline-escape" },
	POINTER_TO_INT_CAST { "pointer-to-int-cast" },
	GNU_CASE_RANGE { "gnu-case-range" },
	CXX_COMPAT { "c++-compat" },
	VLA { "vla" },
	FLOAT_OVERFLOW_CONVERSION { "float-overflow-conversion" },
	FLOAT_ZERO_CONVERSION { "float-zero-conversion" },
	FLOAT_CONVERSION { "float-conversion" },
	GNU_FOLDING_CONSTANT { "gnu-folding-constant" },
	UNDEF { "undef" },
	IGNORED_PRAGMAS { "ignored-pragmas" },
	GNU_INCLUDE_NEXT { "gnu-include-next" },
	INCLUDE_NEXT_OUTSIDE_HEADER { "include-next-outside-header" },
	INCLUDE_NEXT_ABSOLUTE_PATH { "include-next-absolute-path" },
	ENUM_TOO_LARGE { "enum-too-large" },
	FIXED_ENUM_EXTENSION { "fixed-enum-extension" },
	DESIGNATED_INIT { "designated-init" },
	ATTRIBUTE_WARNING { "attribute-warning" },
	INVALID_NORETURN { "invalid-noreturn" },
	ZERO_LENGTH_ARRAY { "zero-length-array" },
	OLD_STYLE_FLEXIBLE_STRUCT { "old-style-flexible-struct" },
	GNU_ZERO_VARIADIC_MACRO_ARGUMENTS { "gnu-zero-variadic-macro-arguments" },
	MAIN_RETURN_TYPE { "main-return-type" },
	EXPANSION_TO_DEFINED { "expansion-to-defined" },
	BIT_INT_EXTENSION { "bit-int-extension" },
	KEYWORD_MACRO { "keyword-macro" },
	POINTER_ARITH { "pointer-arith" },
	SIZEOF_ARRAY_ARGUMENT { "sizeof-array-argument" },
	POINTER_BOOL_CONVERSION { "pointer-bool-conversion" },
	STRING_CONVERSION { "string-conversion" },
	GNU_AUTO_TYPE { "gnu-auto-type" },
	GNU_POINTER_ARITH { "gnu-pointer-arith" },
	GNU_UNION_CAST { "gnu-union-cast" },
	POINTER_SIGN { "pointer-sign" },
	FUSE_LD_PATH { "fuse-ld-path" },
	LANGUAGE_EXTENSION_TOKEN { "language-extension-token" },
	COMPLEX_COMPONENT_INIT { "complex-component-init" },
	MICROSOFT_INCLUDE { "microsoft-include" },
	MICROSOFT_END_OF_FILE { "microsoft-end-of-file" },
	INVALID_SOURCE_ENCODING { "invalid-source-encoding" },
	FOUR_CHAR_CONSTANTS { "four-char-constants" },
	UNKNOWN_ESCAPE_SEQUENCE { "unknown-escape-sequence" },
	INVALID_PP_TOKEN { "invalid-pp-token" },
	DEPRECATED_NON_PROTOTYPE { "deprecated-non-prototype" },
	DUPLICATE_EMBED_PARAM { "duplicate-embed-param" },
	UNUSED_RESULT { "unused-result" },
	NORMALIZED { "normalized" },
	SHIFT_COUNT_NEGATIVE { "shift-count-negative" },
	SHIFT_COUNT_OVERFLOW { "shift-count-overflow" },
	CONSTANT_CONVERSION { "constant-conversion" },
	SIGN_CONVERSION { "sign-conversion" },
	ADDRESS_OF_PACKED_MEMBER { "address-of-packed-member" },
	NONNULL { "nonnull" },
	ATOMIC_ACCESS { "atomic-access" },
	GNU_DESIGNATOR { "gnu-designator" },
	EMPTY_BODY { "empty-body" },
	NULLABILITY_EXTENSION { "nullability-extension" },
	NULLABILITY { "nullability" },
	MICROSOFT_FLEXIBLE_ARRAY { "microsoft-flexible-array" },
	MICROSOFT_ANON_TAG { "microsoft-anon-tag" },
	OUT_OF_SCOPE_FUNCTION { "out-of-scope-function" },
	DATE_TIME { "date-time" },
	VARIADIC_MACRO_ARGUMENTS_OMITTED { "variadic-macro-arguments-omitted" },
	PRAGMA_ONCE_OUTSIDE_HEADER { "pragma-once-outside-header" },
	UNDERLYING_ATOMIC_QUALIFIER_IGNORED { "underlying-atomic-qualifier-ignored" },
	UNDERLYING_CV_QUALIFIER_IGNORED { "underlying-cv-qualifier-ignored" },
	BOUNDS_ATTRIBUTES_REDUNDANT { "bounds-attributes-redundant" },
	FILE_NAME_EXTENSION { "file-name-extension" },
	BASE_FILE_EXTENSION { "base-file-extension" },
	INCLUDE_LEVEL_EXTENSION { "include-level-extension" },
	BLOCKS_EXTENSION { "blocks-extension" },
	EXTRA_TOKENS { "extra-tokens" },
	UNSUPPORTED_VISIBILITY { "unsupported-visibility" },
	DEPRECATED_ATTRIBUTES { "deprecated-attributes" },
	SECTION { "section" },
	LABEL_ATTRIBUTE { "label-attribute" },
	UNUSED_VARIABLE { "unused-variable" },
	UNUSED_PARAMETER { "unused-parameter" },
	UNUSED_LOCAL_TYPEDEF { "unused-local-typedef" },
	UNUSED_LABEL { "unused-label" },
	UNUSED_COMPARISON { "unused-comparison" },
	DEPRECATED_OCTAL_LITERALS { "deprecated-octal-literals" },
	C99_EXTENSIONS { "c99-extensions" },
	C99_COMPAT { "c99-compat" },
	C11_EXTENSIONS { "c11-extensions" },
	PRE_C11_COMPAT { "pre-c11-compat" },
	C23_EXTENSIONS { "c23-extensions" },
	PRE_C23_COMPAT { "pre-c23-compat" },
	C2Y_EXTENSIONS { "c2y-extensions" },
	PRE_C2Y_COMPAT { "pre-c2y-compat" },
}

const Option[] GNU = {
	GNU_EMPTY_STRUCT, GNU_ALIGNOF_EXPRESSION, GNU_LABEL_AS_VALUE, GNU_STATEMENT_EXPRESSION,
	GNU_IMAGINARY_CONSTANT, GNU_COMPLEX_INTEGER, GNU_BINARY_LITERAL, GNU_CASE_RANGE,
	GNU_FOLDING_CONSTANT, GNU_INCLUDE_NEXT, GNU_ZERO_VARIADIC_MACRO_ARGUMENTS, GNU_AUTO_TYPE,
	GNU_POINTER_ARITH, GNU_UNION_CAST, GNU_DESIGNATOR, ZERO_LENGTH_ARRAY,
};
const Option[] CLANG = { FIXED_ENUM_EXTENSION, BIT_INT_EXTENSION, NULLABILITY_EXTENSION, BLOCKS_EXTENSION };
const Option[] MICROSOFT = { MICROSOFT_END_OF_FILE, MICROSOFT_INCLUDE, MICROSOFT_FLEXIBLE_ARRAY, MICROSOFT_ANON_TAG };
// The duplicate entry is in the Zig source too; it is harmless.
const Option[] EXTRA = {
	INITIALIZER_OVERRIDES, IGNORED_QUALIFIERS, INITIALIZER_OVERRIDES, EXPANSION_TO_DEFINED, FUSE_LD_PATH, BLOCKS_EXTENSION,
};
const Option[] IMPLICIT = { IMPLICIT_INT, IMPLICIT_FUNCTION_DECLARATION };
// unused-parameter is intentionally not part of the group (matches gcc and clang).
const Option[] UNUSED = { UNUSED_VALUE, UNUSED_RESULT, UNUSED_VARIABLE, UNUSED_LOCAL_TYPEDEF, UNUSED_LABEL, UNUSED_COMPARISON };
const Option[] DEPRECATED = { DEPRECATED_DECLARATIONS, DEPRECATED_NON_PROTOTYPE, DEPRECATED_ATTRIBUTES, DEPRECATED_OCTAL_LITERALS };
<* implicit ++ unused ++ [...] *>
const Option[] MOST = {
	IMPLICIT_INT, IMPLICIT_FUNCTION_DECLARATION,
	UNUSED_VALUE, UNUSED_RESULT, UNUSED_VARIABLE, UNUSED_LOCAL_TYPEDEF, UNUSED_LABEL, UNUSED_COMPARISON,
	INITIALIZER_OVERRIDES, IGNORED_QUALIFIERS, INITIALIZER_OVERRIDES, MULTICHAR, RETURN_TYPE,
	SIZEOF_ARRAY_ARGUMENT, UNINITIALIZED, UNKNOWN_PRAGMAS,
};
<* most ++ [...] *>
const Option[] ALL = {
	IMPLICIT_INT, IMPLICIT_FUNCTION_DECLARATION,
	UNUSED_VALUE, UNUSED_RESULT, UNUSED_VARIABLE, UNUSED_LOCAL_TYPEDEF, UNUSED_LABEL, UNUSED_COMPARISON,
	INITIALIZER_OVERRIDES, IGNORED_QUALIFIERS, INITIALIZER_OVERRIDES, MULTICHAR, RETURN_TYPE,
	SIZEOF_ARRAY_ARGUMENT, UNINITIALIZED, UNKNOWN_PRAGMAS,
	NONNULL, UNREACHABLE_CODE, MALFORMED_WARNING_CHECK,
};

<* Group names in Zig declaration order (`@typeInfo(Option).decl_names`). *>
const String[] GROUP_NAMES = { "gnu", "clang", "microsoft", "extra", "implicit", "unused", "deprecated", "most", "all" };

excuse NOT_FOUND;

<* The options of the warning group `name`, or NOT_FOUND. *>
fn Option[]? option_group(String name)
{
	switch (name)
	{
		case "gnu": return GNU;
		case "clang": return CLANG;
		case "microsoft": return MICROSOFT;
		case "extra": return EXTRA;
		case "implicit": return IMPLICIT;
		case "unused": return UNUSED;
		case "deprecated": return DEPRECATED;
		case "most": return MOST;
		case "all": return ALL;
		default: return NOT_FOUND~;
	}
}

<* Zig `std.meta.stringToEnum(Option, name)`. *>
fn Option? option_from_flag(String name)
{
	foreach (o : Option::values) if (o.flag == name) return o;
	return NOT_FOUND~;
}

<* Used by the __has_warning builtin macro. *>
fn bool warning_exists(String name)
{
	if (name == "pedantic") return true;
	if (@ok(option_group(name))) return true;
	return @ok(option_from_flag(name));
}

<* Zig `std.EnumMap(Option, Message.Kind)`: a plain value so `State` can be saved and restored. *>
struct OptionKindMap
{
	bool[Option::len] present;
	MessageKind[Option::len] kinds;
}

fn void OptionKindMap.put(&self, Option o, MessageKind kind)
{
	self.present[o.ordinal] = true;
	self.kinds[o.ordinal] = kind;
}

fn MessageKind? OptionKindMap.get(&self, Option o)
{
	if (!self.present[o.ordinal]) return NOT_FOUND~;
	return self.kinds[o.ordinal];
}

<*
 Zig `Diagnostics.State`. Start from `DEFAULT_STATE` (suppress_system_headers
 defaults to true). Pragmas save and restore it by value.
*>
struct State
{
	<* Treat all errors as fatal, set by -Wfatal-errors *>
	bool fatal_errors;
	<* Treat all warnings as errors, set by -Werror *>
	bool error_warnings;
	<* Enable all warnings, set by -Weverything *>
	bool enable_all_warnings;
	<* Ignore all warnings, set by -w *>
	bool ignore_warnings;
	<* How to treat extension diagnostics, set by -Wpedantic *>
	MessageKind extensions;
	<* How to treat individual options, set by -W<name> *>
	OptionKindMap options;
	<* Should warnings be suppressed in system headers, set by -Wsystem-headers *>
	bool suppress_system_headers;
}

const State DEFAULT_STATE = { .extensions = OFF, .suppress_system_headers = true };

<*
 Zig `Diagnostics.Message`. Optional Zig fields are modelled with `has_*` flags.
 `add` borrows every slice for the duration of the call; the to-list output
 stores owned copies.
*>
struct Message
{
	MessageKind kind;
	String text;
	bool has_opt;
	Option opt;
	bool extension;
	bool has_location;
	ExpandedLocation location;
	MessageKind effective_kind;
}

<*
 A static message description (Zig's per-module `Diagnostic` constants: fmt,
 kind, opt, extension). Phase-specific tables are declared next to their callers.
*>
struct DiagnosticTemplate
{
	String fmt;
	MessageKind kind;
	bool has_opt;
	Option opt;
	bool extension;
}

<* Build a message from a template with already formatted `text` and no location. *>
fn Message DiagnosticTemplate.message(self, String text)
{
	return { .kind = self.kind, .text = text, .has_opt = self.has_opt, .opt = self.opt, .extension = self.extension };
}

<* Same as `message`, with a location. *>
fn Message DiagnosticTemplate.message_at(self, String text, ExpandedLocation loc)
{
	Message m = self.message(text);
	m.has_location = true;
	m.location = loc;
	return m;
}

// ---------------------------------------------------------------------------
// Terminal output (the no_color / escape_codes subset of std.Io.Terminal)

enum ColorMode : char
{
	NO_COLOR,
	ESCAPE_CODES,
}

<* Escape sequences copied from std/Io/Terminal.zig `setColor`. *>
enum Color : char (String code)
{
	WHITE { "\e[37m" },
	BRIGHT_RED { "\e[91m" },
	BRIGHT_GREEN { "\e[92m" },
	BRIGHT_MAGENTA { "\e[95m" },
	BRIGHT_CYAN { "\e[96m" },
	BOLD { "\e[1m" },
	RESET { "\e[0m" },
}

struct Terminal
{
	OutStream writer;
	ColorMode mode;
}

fn void? Terminal.set_color(self, Color color)
{
	if (self.mode == NO_COLOR) return;
	io::write_all(self.writer, color.code)!;
}

fn void? Terminal.write(self, String s)
{
	if (s.len) io::write_all(self.writer, s)!;
}

<* Render the message (its effective_kind must not be OFF). Zig `Message.write`. *>
fn void? Message.write(&self, Terminal term, bool details)
{
	OutStream w = term.writer;
	term.set_color(BOLD)!;
	if (self.has_location)
	{
		io::fprintf(w, "%s:%d:%d: ", self.location.path, self.location.line_no, self.location.col)!;
	}
	switch (self.effective_kind)
	{
		case FATAL_ERROR:
		case ERROR: term.set_color(BRIGHT_RED)!;
		case NOTE: term.set_color(BRIGHT_CYAN)!;
		case WARNING: term.set_color(BRIGHT_MAGENTA)!;
		case OFF: unreachable("off messages are never written");
	}
	term.write(self.effective_kind.label)!;
	term.write(": ")!;

	term.set_color(WHITE)!;
	term.write(self.text)!;
	if (self.has_opt)
	{
		if (self.effective_kind == ERROR && self.kind != ERROR)
		{
			io::fprintf(w, " [-Werror,-W%s]", self.opt.flag)!;
		}
		else if (self.effective_kind != NOTE)
		{
			io::fprintf(w, " [-W%s]", self.opt.flag)!;
		}
	}
	else if (self.extension)
	{
		if (self.effective_kind == ERROR)
		{
			term.write(" [-Werror,-Wpedantic]")!;
		}
		else if (self.effective_kind != self.kind)
		{
			term.write(" [-Wpedantic]")!;
		}
	}

	if (!details || !self.has_location)
	{
		term.write("\n")!;
		term.set_color(RESET)!;
	}
	else
	{
		ExpandedLocation loc = self.location;
		term.set_color(RESET)!;
		term.write("\n")!;
		term.write(loc.line)!;
		if (loc.end_with_splice) term.write("\\ ")!;
		term.write("\n")!;
		for (uint k = 0; k < loc.width; k++) w.write_byte(' ')!;
		term.set_color(BOLD)!;
		term.set_color(BRIGHT_GREEN)!;
		term.write("^\n")!;
		term.set_color(RESET)!;
	}
	if (&w.flush) w.flush()!;
}

// ---------------------------------------------------------------------------
// Diagnostics

enum OutputKind : char
{
	IGNORE,
	TO_WRITER,
	TO_LIST,
}

<* Zig `color: ?bool`. *>
enum ColorOverride : char
{
	AUTO,      // null: use the terminal's mode
	FORCE_ON,  // true
	FORCE_OFF, // false
}

struct Diagnostics
{
	OutputKind output;
	<* TO_WRITER: destination and its detected mode. The stream is borrowed. *>
	Terminal terminal;
	<* TO_LIST: owns `messages` and every message's text / location.path / location.line copy. *>
	Allocator list_allocator;
	List{Message} messages;

	<* Force usage of color in output. *>
	ColorOverride color;
	<* Include line of code in output. *>
	bool details;

	State state;
	<* Amount of error or fatal error messages that have been sent to `output`. *>
	uint errors;
	<* Amount of warnings that have been sent to `output`. *>
	uint warnings;
	<* Total amount of diagnostics messages sent to `output`. *>
	uint total;
	uint macro_backtrace_limit;
	<*
	 If `effective_kind` causes us to skip a diagnostic, this is temporarily set to
	 `true` to signal that associated notes should also be skipped.
	*>
	bool hide_notes;
}

<* `.{ .output = .ignore }` with Zig's field defaults. *>
fn void Diagnostics.init_ignore(&self)
{
	*self = { .output = IGNORE, .details = true, .state = DEFAULT_STATE, .macro_backtrace_limit = 6 };
}

<* `.{ .output = .{ .to_writer = term } }`. The stream is borrowed. *>
fn void Diagnostics.init_writer(&self, OutStream writer, ColorMode mode)
{
	self.init_ignore();
	self.output = TO_WRITER;
	self.terminal = { .writer = writer, .mode = mode };
}

<* `.{ .output = .{ .to_list = ... } }`. Messages and their strings are allocated from `a`. *>
fn void Diagnostics.init_list(&self, Allocator a)
{
	self.init_ignore();
	self.output = TO_LIST;
	self.list_allocator = a;
	self.messages.init(a);
}

fn void Diagnostics.free(&self)
{
	if (self.output == TO_LIST)
	{
		foreach (&m : self.messages) free_message_copy(self.list_allocator, m);
		self.messages.free();
	}
	*self = {};
}

fn void free_message_copy(Allocator a, Message* m) @private
{
	if (m.text.len) alloc::free(a, m.text.ptr);
	if (m.has_location)
	{
		if (m.location.path.len) alloc::free(a, m.location.path.ptr);
		if (m.location.line.len) alloc::free(a, m.location.line.ptr);
	}
}

fn String copy_or_empty(Allocator a, String s) @private => s.len ? s.copy(a) : "";

<*
 Set the kind of option or group `name` (or "pedantic"). Unknown names produce
 an `unknown warning '<name>'` warning [-Wunknown-warning-option].
 @return? compilation::FATAL_ERROR
*>
fn void? Diagnostics.set(&self, String name, MessageKind to)
{
	if (name == "pedantic")
	{
		self.state.extensions = to;
		return;
	}
	if (try option = option_from_flag(name))
	{
		self.state.options.put(option, to);
		return;
	}
	if (try group = option_group(name))
	{
		foreach (option : group) self.state.options.put(option, to);
		return;
	}

	// Zig formats into a 256-byte stack buffer; longer texts are cut at 256 bytes.
	char[256] buf;
	String prefix = "unknown warning '";
	usz n = 0;
	foreach (c : prefix) buf[n++] = c;
	foreach (c : name)
	{
		if (n == buf.len) break;
		buf[n++] = c;
	}
	if (n < buf.len) buf[n++] = '\'';

	self.add({
		.text = (String)buf[:n],
		.kind = WARNING,
		.has_opt = true,
		.opt = UNKNOWN_WARNING_OPTION,
	})!;
}

fn MessageKind Diagnostics.severity(&self, Option option)
{
	if (try k = self.state.options.get(option)) return k;
	return OFF;
}

<*
 This mutates the `Diagnostics`, so may only be called when `message` is being added.
 If OFF is returned, `message` will not be included, so the caller should give up.
 Callers without a location (Zig passes a `Diagnostic` with no `location` field)
 leave `has_location` false.
*>
fn MessageKind Diagnostics.effective_kind(&self, Message* message)
{
	if (self.hide_notes && message.kind == NOTE) return OFF;

	// -w disregards explicit kind set with -W<name>
	if (self.state.ignore_warnings && message.kind == WARNING)
	{
		self.hide_notes = true;
		return OFF;
	}

	if (message.has_location)
	{
		if (message.location.kind != USER && self.state.suppress_system_headers &&
			(message.kind == WARNING || message.kind == OFF))
		{
			return OFF;
		}
	}

	MessageKind kind = message.kind;

	// Get explicit kind set by -W<name>=
	bool set_explicit = false;
	if (message.has_opt)
	{
		if (try explicit = self.state.options.get(message.opt))
		{
			kind = explicit;
			set_explicit = true;
		}
	}

	// Use extension diagnostic behavior if not set explicitly.
	if (message.extension && !set_explicit)
	{
		if (self.state.extensions.ordinal > kind.ordinal) kind = self.state.extensions;
	}

	// Make diagnostic a warning if -Weverything is set.
	if (kind == OFF && self.state.enable_all_warnings) kind = WARNING;

	// Upgrade warnings to errors if -Werror is set
	if (kind == WARNING && self.state.error_warnings) kind = ERROR;

	// Upgrade errors to fatal errors if -Wfatal-errors is set
	if (kind == ERROR && self.state.fatal_errors) kind = FATAL_ERROR;

	if (kind == OFF) self.hide_notes = true;
	return kind;
}

<*
 Add `msg`. Its slices are only borrowed for the duration of the call.
 @return? compilation::FATAL_ERROR : "the message became a fatal error, or writing it failed"
*>
fn void? Diagnostics.add(&self, Message msg)
{
	Message copy = msg;
	copy.effective_kind = self.effective_kind(&msg);
	if (copy.effective_kind == OFF) return;
	self.add_message(copy)!;
	if (copy.effective_kind == FATAL_ERROR) return compilation::FATAL_ERROR~;
}

<*
 Add `msg` at the outermost expansion location followed by "expanded from here"
 notes (most recent first), omitting the middle of the backtrace when it is
 longer than `macro_backtrace_limit`.
 @require !note_msg_loc || expansion_locs.len == 0 || msg.has_location : "note_msg_loc needs a location"
 @return? compilation::FATAL_ERROR
*>
fn void? Diagnostics.add_with_location(&self, Compilation* comp, Message msg, Location[] expansion_locs, bool note_msg_loc)
{
	Message copy = msg;
	if (expansion_locs.len != 0)
	{
		copy.location = expansion_locs[^1].expand(comp);
		copy.has_location = true;
	}
	copy.effective_kind = self.effective_kind(&copy);
	if (copy.effective_kind == OFF) return;
	self.add_message(copy)!;

	if (expansion_locs.len != 0)
	{
		// Add macro backtrace notes in reverse order omitting from the middle if needed.
		ulong i = (ulong)expansion_locs.len - 1;
		ulong backtrace_limit = self.macro_backtrace_limit;
		ulong half = backtrace_limit / 2;
		ulong limit = i < backtrace_limit ? 0 : i - half;
		while (i > limit)
		{
			i--;
			self.add_expanded_note(comp, expansion_locs[i])!;
		}
		if (limit != 0)
		{
			char[128] buf;
			String text = (String)io::bprintf(&buf,
				"(skipping %d expansions in backtrace; use -fmacro-backtrace-limit=0 to see all)",
				(ulong)expansion_locs.len - backtrace_limit)!!;
			self.add_message({ .kind = NOTE, .effective_kind = NOTE, .text = text })!;
			i = half == 0 ? 0 : half - 1;
			while (i > 0)
			{
				i--;
				self.add_expanded_note(comp, expansion_locs[i])!;
			}
		}

		if (note_msg_loc)
		{
			self.add_message({
				.kind = NOTE,
				.effective_kind = NOTE,
				.text = "expanded from here",
				.has_location = true,
				.location = msg.location,
			})!;
		}
	}
	// Zig checks the declared kind here, not the effective one: an error promoted
	// by -Wfatal-errors is reported but does not stop compilation on this path.
	if (copy.kind == FATAL_ERROR) return compilation::FATAL_ERROR~;
}

fn void? Diagnostics.add_expanded_note(&self, Compilation* comp, Location loc)
{
	self.add_message({
		.kind = NOTE,
		.effective_kind = NOTE,
		.text = "expanded from here",
		.has_location = true,
		.location = loc.expand(comp),
	})!;
}

fn void? Diagnostics.add_message(&self, Message msg)
{
	switch (msg.effective_kind)
	{
		case OFF: unreachable("add_message with an OFF message");
		case ERROR:
		case FATAL_ERROR: self.errors++;
		case WARNING: self.warnings++;
		case NOTE: break;
	}
	self.total++;
	self.hide_notes = false;

	switch (self.output)
	{
		case IGNORE:
			break;
		case TO_WRITER:
			Terminal term = self.terminal;
			if (self.color == FORCE_OFF) term.mode = NO_COLOR;
			if (self.color == FORCE_ON && term.mode == NO_COLOR) term.mode = ESCAPE_CODES;
			if (catch msg.write(term, self.details)) return compilation::FATAL_ERROR~;
		case TO_LIST:
			Allocator a = self.list_allocator;
			Message owned = msg;
			owned.text = copy_or_empty(a, msg.text);
			if (msg.has_location)
			{
				owned.location.path = copy_or_empty(a, msg.location.path);
				owned.location.line = copy_or_empty(a, msg.location.line);
			}
			self.messages.push(owned);
	}
}

// ---------------------------------------------------------------------------
// Message templates: Zig `formatArgs` / `templateIndex` / `formatString` / `formatInt`.

enum DiagArgKind : char
{
	STRING,
	SIGNED,
	UNSIGNED,
}

<* One argument of `format_args`. Build with `arg_str`, `arg_int` or `arg_uint`. *>
struct DiagArg
{
	DiagArgKind kind;
	String str;
	long signed;
	ulong unsigned;
}

fn DiagArg arg_str(String s) => { .kind = STRING, .str = s };
fn DiagArg arg_int(long v) => { .kind = SIGNED, .signed = v };
fn DiagArg arg_uint(ulong v) => { .kind = UNSIGNED, .unsigned = v };

<*
 Write `fmt` with each argument substituted for the next "{s}" (strings) or
 "{d}" (integers) template, in order. Callers with phase-specific argument
 types (token ids, types, ...) use `template_index` the same way.
*>
fn void? format_args(OutStream w, String fmt, DiagArg[] args)
{
	sz i = 0;
	foreach (arg : args)
	{
		switch (arg.kind)
		{
			case STRING: i += format_string(w, fmt[i..], arg.str)!;
			case SIGNED: i += format_int(w, fmt[i..], arg.signed)!;
			case UNSIGNED: i += format_uint(w, fmt[i..], arg.unsigned)!;
		}
	}
	if (fmt.len > i) io::write_all(w, fmt[i..])!;
}

<*
 Write `fmt` up to `template` and return the index just past it. A missing
 template writes a bug notice and returns 0 (Zig panics in debug builds instead).
*>
fn sz? template_index(OutStream w, String fmt, String template)
{
	if (try i = fmt.index_of(template))
	{
		if (i) io::write_all(w, fmt[:i])!;
		return i + template.len;
	}
	io::fprintf(w, "template `%s` not found in format string `%s` (this is a bug in arocc)", template, fmt)!;
	return 0;
}

fn sz? format_string(OutStream w, String fmt, String str)
{
	sz i = template_index(w, fmt, "{s}")!;
	if (str.len) io::write_all(w, str)!;
	return i;
}

fn sz? format_int(OutStream w, String fmt, long value)
{
	sz i = template_index(w, fmt, "{d}")!;
	io::fprintf(w, "%d", value)!;
	return i;
}

fn sz? format_uint(OutStream w, String fmt, ulong value)
{
	sz i = template_index(w, fmt, "{d}")!;
	io::fprintf(w, "%d", value)!;
	return i;
}
