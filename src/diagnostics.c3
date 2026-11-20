// Port of src/aro/Diagnostics.zig: diagnostic messages, warning options and
// groups, the -W state machine (effective_kind), output to a writer / a
// collected list / nowhere, macro backtrace notes and message rendering.
//
// Zig's comptime formatting and reflection are replaced by:
//  - `Option` carrying its flag spelling as an associated value,
//  - explicit group tables (`option_group`),
//  - C3 printf formatting, checked at compile time by `@format`.
// Phase-specific message tables (Parser, Preprocessor, ...) are ported with
// their callers as enums with associated values (see `DiagMeta`).
module aro::diagnostics;
import aro::ansi, aro::source, aro::compilation, aro::lang_opts, aro::parser, aro::tokens, std::io, std::collections::list;

<* Zig `Message.Kind`; the label is the `{t}` spelling used in output. Order matters (max for -Wpedantic). *>
enum MessageKind : char(String label)
{
	OFF { "off" },
	NOTE { "note" },
	WARNING { "warning" },
	ERROR { "error" },
	FATAL_ERROR { "fatal error" },
}

<* Zig `Diagnostics.Option` in declaration order; `flag` is the -W<flag> spelling. *>
enum Option : ushort(String flag)
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

<* Build a message from diagnostic enum value `diag` and its formatted `text`, with no location. *>
macro Message @message(diag, String text)
{
	return { .kind = diag.kind, .text = text, .has_opt = diag.meta.has_opt, .opt = diag.meta.opt, .extension = diag.meta.extension };
}

<* Same as `@message`, with a location. *>
macro Message @message_at(diag, String text, ExpandedLocation loc)
{
	Message m = @message(diag, text);
	m.has_location = true;
	m.location = loc;
	return m;
}

<* False when `diag` would be reported as OFF, so callers can skip formatting it. *>
macro bool Diagnostics.@enabled(&self, diag)
{
	Message probe = @message(diag, "");
	return self.effective_kind(&probe) != OFF;
}

// ---------------------------------------------------------------------------
// Terminal output (the no_color / escape_codes subset of std.Io.Terminal)

enum ColorMode : char
{
	NO_COLOR,
	ESCAPE_CODES,
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
	AUTO,  // null: use the terminal's mode
	FORCE_ON,  // true
	FORCE_OFF,  // false
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
	* self = {};
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

	self.add(
		{
			.text = (String)buf[:n],
		.kind = WARNING,
		.has_opt = true,
		.opt = UNKNOWN_WARNING_OPTION,
	}
	)!;
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
			self.add_message(
			{
				.kind = NOTE, .effective_kind = NOTE, .text = text
			}
			)!;
			i = half == 0 ? 0 : half - 1;
			while (i > 0)
			{
				i--;
				self.add_expanded_note(comp, expansion_locs[i])!;
			}
		}

		if (note_msg_loc)
		{
			self.add_message(
				{
					.kind = NOTE,
					.effective_kind = NOTE,
					.text = "expanded from here",
					.has_location = true,
					.location = msg.location,
				}
			)!;
		}
	}
	// Zig checks the declared kind here, not the effective one: an error promoted
	// by -Wfatal-errors is reported but does not stop compilation on this path.
	if (copy.kind == FATAL_ERROR) return compilation::FATAL_ERROR~;
}

fn void? Diagnostics.add_expanded_note(&self, Compilation* comp, Location loc)
{
	self.add_message(
		{
			.kind = NOTE,
			.effective_kind = NOTE,
			.text = "expanded from here",
			.has_location = true,
			.location = loc.expand(comp),
	}
	)!;
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
// Diagnostic table
// ---------------------------------------------------------------------------

// The single diagnostic table. Every entry is
// `(String fmt, MessageKind kind, DiagMeta meta, DiagnosticType type)`; `type`
// names the group (and the Zig table) the entry comes from. Entries are grouped
// by type, each group in Zig declaration order. A diagnostic shared by several
// Zig tables (identical text and options) appears once, in the first group.
// `fmt` is C3 printf syntax; emit macros (Diagnostic.@emit, Preprocessor.err,
// Wip.emit, ...) take a `Diagnostic $diag` and format with `string::tformat`,
// whose `@format` checks call-site arguments at compile time.

<*
 Optional metadata of a diagnostic enum entry. Zero means: no -W option, not an
 extension, hidden in system headers when those are suppressed.

 The `meta` of every `Diagnostic` (below). `@message`
 reads `fmt`/`kind`/`meta`, so it works for compile-time or runtime values.
 Emit macros format with `string::tformat($diag.fmt, ...)`, whose `@format`
 checks call-site arguments.
*>
struct DiagMeta
{
	bool has_opt;
	Option opt;
	bool extension;
	<* Zig Preprocessor.Diagnostic `show_in_system_headers`. *>
	bool show_in_system_headers;
	<* Zig Parser.Diagnostic `suppress_version`: silent from this standard on. *>
	bool has_suppress_version;
	lang_opts::Standard suppress_version;
	<* Zig Parser.Diagnostic `suppress_unless_version`: silent before this standard. *>
	bool has_suppress_unless_version;
	lang_opts::Standard suppress_unless_version;
}

<* Zig Parser.err's extension and language-version suppression, checked before formatting. *>
fn bool Diagnostic.should_emit(self, LangOpts* opts, bool extension_suppressed)
{
	DiagMeta m = self.meta;
	if (extension_suppressed && m.extension && self.kind == OFF) return false;
	if (m.has_suppress_version && opts.standard.at_least(m.suppress_version)) return false;
	if (m.has_suppress_unless_version && !opts.standard.at_least(m.suppress_unless_version)) return false;
	return true;
}

<* True when `self` passes the extension/version gates of `q` and is not OFF. *>
fn bool Diagnostic.enabled(self, parser::IQueryable q)
{
	Compilation* comp = q.query_comp();
	return self.should_emit(&comp.langopts, q.query_extension_suppressed()) && comp.diagnostics.@enabled(self);
}

<*
 Zig `Parser.err`: format `$self.fmt` with the varargs and report it at token
 `tok` of `q`. `$self.fmt` is a constant, so the `$assert` runs
 `string::tformat`'s `@format` check on the argument count and types at every
 call site without generating code. Formatting happens out of line in
 `emit_args`: an inlined `tformat` per call site made every diagnostic branch
 add stack slots to its caller, and at -O0 those add up in the recursive
 parser/codegen functions (deep nesting overflowed the stack).
*>
macro void? Diagnostic.@emit($self, parser::IQueryable q, tokens::TokenIndex tok, ...)
{
	$assert $defined(string::tformat($self.fmt, ...$vaarg)) : "diagnostic arguments do not match its format";
	return $self.emit_args(q, tok, ...$vaarg);
}

<* `@emit` at an explicit location (e.g. just past a token) with `expansion_locs` as macro notes. *>
macro void? Diagnostic.@emit_at($self, parser::IQueryable q, ExpandedLocation loc, Location[] expansion_locs, ...)
{
	$assert $defined(string::tformat($self.fmt, ...$vaarg)) : "diagnostic arguments do not match its format";
	return $self.emit_at_args(q, loc, expansion_locs, ...$vaarg);
}

<* Out-of-line body of `@emit`; disabled diagnostics return before any formatting. *>
fn void? Diagnostic.emit_args(self, parser::IQueryable q, tokens::TokenIndex tok, args...) @noinline
{
	if (!self.enabled(q)) return;
	return self.report(q, string::tformat(self.fmt, ...args), tok);
}

<* Out-of-line body of `@emit_at`. *>
fn void? Diagnostic.emit_at_args(self, parser::IQueryable q, ExpandedLocation loc, Location[] expansion_locs, args...) @noinline
{
	if (!self.enabled(q)) return;
	return self.report_at(q, string::tformat(self.fmt, ...args), loc, expansion_locs);
}

<* Internal sink under `@emit`: send formatted `text` at token `tok` of `q`, with its expanded location and macro notes. *>
fn void? Diagnostic.report(self, parser::IQueryable q, String text, tokens::TokenIndex tok)
{
	ExpandedLocation loc;
	Location[] expansion_locs;
	if (!q.query_token_location(tok, &loc, &expansion_locs)) return q.query_comp().diagnostics.add(@message(self, text));
	return self.report_at(q, text, loc, expansion_locs);
}

<* Internal sink under `@emit_at`: send formatted `text` at `loc` with `expansion_locs` as macro notes. *>
fn void? Diagnostic.report_at(self, parser::IQueryable q, String text, ExpandedLocation loc, Location[] expansion_locs)
{
	Compilation* comp = q.query_comp();
	return comp.diagnostics.add_with_location(comp, @message_at(self, text, loc), expansion_locs, true);
}

<* Which group (Zig diagnostic table / emitter) a Diagnostic belongs to. *>
enum DiagnosticType : char
{
	COMPILATION,
	PREPROCESSOR,
	PRAGMA,
	ATTRIBUTE,
	TEXT_LITERAL,
	NUMBER_LITERAL,
	PARSER,
	LINK,
}

enum Diagnostic : ushort (String fmt, MessageKind kind, DiagMeta meta, DiagnosticType type)
{
	// ---- Compilation (src/compilation.c3, include_search.c3, tokens.c3) ----
	// Zig `Compilation.Diagnostic`. `fmt` is C3 printf syntax.
	BACKSLASH_NEWLINE_ESCAPE { "backslash and newline separated by space", WARNING, { .has_opt = true, .opt = Option.BACKSLASH_NEWLINE_ESCAPE }, COMPILATION },
	MS_SEARCH_RULE { "#include resolved using non-portable Microsoft search rules as: %s", WARNING, { .has_opt = true, .opt = Option.MICROSOFT_INCLUDE, .extension = true }, COMPILATION },
	CTRL_Z_EOF { "treating Ctrl-Z as end-of-file is a Microsoft extension", OFF, { .has_opt = true, .opt = Option.MICROSOFT_END_OF_FILE, .extension = true }, COMPILATION },

	// ---- Preprocessor (Preprocessor.err / err_raw / err_loc) ----
	// Zig `Preprocessor.Diagnostic`, in Zig declaration order. `fmt` is C3 printf syntax; emit with `Preprocessor.err`/`err_raw`/`err_loc`.
	ELIF_WITHOUT_IF { "#elif without #if", ERROR, {}, PREPROCESSOR },
	ELIF_AFTER_ELSE { "#elif after #else", ERROR, {}, PREPROCESSOR },
	ELIFDEF_WITHOUT_IF { "#elifdef without #if", ERROR, {}, PREPROCESSOR },
	ELIFDEF_AFTER_ELSE { "#elifdef after #else", ERROR, {}, PREPROCESSOR },
	ELIFNDEF_WITHOUT_IF { "#elifndef without #if", ERROR, {}, PREPROCESSOR },
	ELIFNDEF_AFTER_ELSE { "#elifndef after #else", ERROR, {}, PREPROCESSOR },
	ELSE_WITHOUT_IF { "#else without #if", ERROR, {}, PREPROCESSOR },
	ELSE_AFTER_ELSE { "#else after #else", ERROR, {}, PREPROCESSOR },
	ENDIF_WITHOUT_IF { "#endif without #if", ERROR, {}, PREPROCESSOR },
	UNKNOWN_PRAGMA { "unknown pragma ignored", OFF, { .has_opt = true, .opt = Option.UNKNOWN_PRAGMAS }, PREPROCESSOR },
	LINE_SIMPLE_DIGIT { "#line directive requires a simple digit sequence", ERROR, {}, PREPROCESSOR },
	LINE_INVALID_FILENAME { "invalid filename for #line directive", ERROR, {}, PREPROCESSOR },
	LINE_INVALID_NUMBER { "%s directive requires a positive integer argument", ERROR, {}, PREPROCESSOR },
	LINE_INVALID_FLAG { "invalid flag '%s' in line marker directive", ERROR, {}, PREPROCESSOR },
	UNTERMINATED_CONDITIONAL_DIRECTIVE { "unterminated conditional directive", ERROR, {}, PREPROCESSOR },
	INVALID_PREPROCESSING_DIRECTIVE { "invalid preprocessing directive", ERROR, {}, PREPROCESSOR },
	ERROR_DIRECTIVE { "%s", ERROR, {}, PREPROCESSOR },
	WARNING_DIRECTIVE { "%s", WARNING, { .has_opt = true, .opt = Option.WARNINGS, .show_in_system_headers = true }, PREPROCESSOR },
	MACRO_NAME_MISSING { "macro name missing", ERROR, {}, PREPROCESSOR },
	EXTRA_TOKENS_DIRECTIVE_END { "extra tokens at end of macro directive", WARNING, { .has_opt = true, .opt = Option.EXTRA_TOKENS }, PREPROCESSOR },
	DEFINED_AS_MACRO_NAME { "'defined' cannot be used as a macro name", ERROR, {}, PREPROCESSOR },
	MACRO_NAME_MUST_BE_IDENTIFIER { "macro name must be an identifier", ERROR, {}, PREPROCESSOR },
	WHITESPACE_AFTER_MACRO_NAME { "ISO C99 requires whitespace after the macro name", WARNING, { .has_opt = true, .opt = Option.C99_EXTENSIONS, .extension = true }, PREPROCESSOR },
	HASH_HASH_AT_START { "'##' cannot appear at the start of a macro expansion", ERROR, {}, PREPROCESSOR },
	HASH_HASH_AT_END { "'##' cannot appear at the end of a macro expansion", ERROR, {}, PREPROCESSOR },
	PASTING_FORMED_INVALID { "pasting formed '%s', an invalid preprocessing token", ERROR, {}, PREPROCESSOR },
	MISSING_PAREN_PARAM_LIST { "missing ')' in macro parameter list", ERROR, {}, PREPROCESSOR },
	UNTERMINATED_MACRO_PARAM_LIST { "unterminated macro param list", ERROR, {}, PREPROCESSOR },
	INVALID_TOKEN_PARAM_LIST { "invalid token in macro parameter list", ERROR, {}, PREPROCESSOR },
	EXPECTED_COMMA_PARAM_LIST { "expected comma in macro parameter list", ERROR, {}, PREPROCESSOR },
	HASH_NOT_FOLLOWED_PARAM { "'#' is not followed by a macro parameter", ERROR, {}, PREPROCESSOR },
	EXPECTED_FILENAME { "expected \"FILENAME\" or <FILENAME>", ERROR, {}, PREPROCESSOR },
	EMPTY_FILENAME { "empty filename", ERROR, {}, PREPROCESSOR },
	HEADER_STR_CLOSING { "expected closing '>'", ERROR, {}, PREPROCESSOR },
	HEADER_STR_MATCH { "to match this '<'", NOTE, {}, PREPROCESSOR },
	EMPTY_CHAR_LITERAL_WARNING { "empty character constant", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true }, PREPROCESSOR },
	UNTERMINATED_CHAR_LITERAL_WARNING { "missing terminating ' character", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true }, PREPROCESSOR },
	UNTERMINATED_STRING_LITERAL_WARNING { "missing terminating '\"' character", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true }, PREPROCESSOR },
	UNTERMINATED_COMMENT { "unterminated comment", ERROR, {}, PREPROCESSOR },
	WARNING_EXTENSION { "#warning is a C23 extension", OFF, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, PREPROCESSOR },
	C23_EXTENSION { "%s is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, PREPROCESSOR },
	EMBED_PARAM_IDENTIFIER { "expected identifier", ERROR, {}, PREPROCESSOR },
	EMBED_PARAM_ARGS { "expected '('", ERROR, {}, PREPROCESSOR },
	INVALID_EMBED_LIMIT { "the limit parameter expects a non-negative integer as a parameter", ERROR, {}, PREPROCESSOR },
	DUPLICATE_EMBED_PARAM { "duplicate embed parameter '%s'", WARNING, { .has_opt = true, .opt = Option.DUPLICATE_EMBED_PARAM }, PREPROCESSOR },
	UNKNOWN_EMBED_PARAM { "unknown embed parameter '%s'", ERROR, {}, PREPROCESSOR },
	VA_OPT_LPAREN { "missing '(' following __VA_OPT__", ERROR, {}, PREPROCESSOR },
	VA_OPT_RPAREN { "unterminated __VA_OPT__ argument list", ERROR, {}, PREPROCESSOR },
	KEYWORD_MACRO { "keyword is hidden by macro definition", OFF, { .has_opt = true, .opt = Option.KEYWORD_MACRO, .extension = true }, PREPROCESSOR },
	UNDEFINED_MACRO { "'%s' is not defined, evaluates to 0", OFF, { .has_opt = true, .opt = Option.UNDEF }, PREPROCESSOR },
	FN_MACRO_UNDEFINED { "function-like macro '%s' is not defined", ERROR, {}, PREPROCESSOR },
	PREPROCESSING_DIRECTIVE_ONLY { "'__%s' must be used within a preprocessing directive", ERROR, {}, PREPROCESSOR },
	MISSING_LPAREN_AFTER_BUILTIN { "missing '(' after built-in macro '%s'", ERROR, {}, PREPROCESSOR },
	TOO_MANY_INCLUDES { "#include nested too deeply", ERROR, {}, PREPROCESSOR },
	INCLUDE_NEXT { "#include_next is a language extension", OFF, { .has_opt = true, .opt = Option.GNU_INCLUDE_NEXT, .extension = true }, PREPROCESSOR },
	INCLUDE_NEXT_OUTSIDE_HEADER { "#include_next in primary source file; will search from start of include path", WARNING, { .has_opt = true, .opt = Option.INCLUDE_NEXT_OUTSIDE_HEADER }, PREPROCESSOR },
	COMMA_DELETION_VA_ARGS { "token pasting of ',' and __VA_ARGS__ is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_ZERO_VARIADIC_MACRO_ARGUMENTS, .extension = true }, PREPROCESSOR },
	EXPANSION_TO_DEFINED_OBJ { "macro expansion producing 'defined' has undefined behavior", OFF, { .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED }, PREPROCESSOR },
	EXPANSION_TO_DEFINED_FUNC { "macro expansion producing 'defined' has undefined behavior", OFF, { .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED, .extension = true }, PREPROCESSOR },
	INVALID_PP_STRINGIFY_ESCAPE { "invalid string literal, ignoring final '\\'", WARNING, {}, PREPROCESSOR },
	GNU_VA_MACRO { "named variadic macros are a GNU extension", OFF, { .has_opt = true, .opt = Option.VARIADIC_MACROS, .extension = true }, PREPROCESSOR },
	PRAGMA_OPERATOR_STRING_LITERAL { "_Pragma requires exactly one string literal token", ERROR, {}, PREPROCESSOR },
	INVALID_PREPROC_EXPR_START { "invalid token at start of a preprocessor expression", ERROR, {}, PREPROCESSOR },
	EXPECTED_VALUE_IN_EXPR { "expected value in expression", ERROR, {}, PREPROCESSOR },
	INVALID_PREPROC_OPERATOR { "token is not a valid binary operator in a preprocessor subexpression", ERROR, {}, PREPROCESSOR },
	CONVERT_TO_POSITIVE { "%s side of operator converted from negative value to unsigned: %d to %d", WARNING, {}, PREPROCESSOR },
	PP_DIVISION_BY_ZERO { "%s by zero in preprocessor expression", ERROR, {}, PREPROCESSOR },
	COMMA_OPERATOR { "comma operator in operand of #if", WARNING, { .extension = true }, PREPROCESSOR },
	PP_OVERFLOW { "integer overflow in preprocessor expression", WARNING, {}, PREPROCESSOR },
	EXPECTED_COLON { "expected ':'", ERROR, {}, PREPROCESSOR },
	TO_MATCH_QUESTION { "to match this '?'", NOTE, {}, PREPROCESSOR },
	FLOAT_LITERAL_IN_EXPR { "floating point literal in preprocessor expression", ERROR, {}, PREPROCESSOR },
	INT_LITERAL_TOO_BIG { "integer literal is too large to be represented in any integer type", ERROR, {}, PREPROCESSOR },
	DATA_DEFINITION_NO_TYPE { "data definition has no type or storage class", WARNING, { .extension = true }, PARSER },
	C90_UNSIGNED_DECIMAL { "this decimal constant is unsigned only in ISO C90", WARNING, {}, PREPROCESSOR },
	IMPLICITLY_UNSIGNED_LITERAL { "integer literal is too large to be represented in a signed integer type, interpreting as unsigned", WARNING, { .has_opt = true, .opt = Option.IMPLICITLY_UNSIGNED_LITERAL, .extension = true }, PREPROCESSOR },
	NEWLINE_EOF { "no newline at end of file", OFF, { .has_opt = true, .opt = Option.NEWLINE_EOF, .extension = true }, PREPROCESSOR },
	MALFORMED_WARNING_CHECK { "%s expected option name (e.g. \"-Wundef\")", WARNING, { .has_opt = true, .opt = Option.MALFORMED_WARNING_CHECK, .extension = true }, PREPROCESSOR },
	FEATURE_CHECK_REQUIRES_IDENTIFIER { "builtin feature check macro requires a parenthesized identifier", ERROR, {}, PREPROCESSOR },
	BUILTIN_MACRO_REDEFINED { "redefining builtin macro", WARNING, { .has_opt = true, .opt = Option.BUILTIN_MACRO_REDEFINED, .extension = true }, PREPROCESSOR },
	MACRO_REDEFINED { "'%s' macro redefined", WARNING, { .has_opt = true, .opt = Option.MACRO_REDEFINED, .extension = true }, PREPROCESSOR },
	PREVIOUS_DEFINITION { "previous definition is here", NOTE, {}, PREPROCESSOR },
	UNTERMINATED_MACRO_ARG_LIST { "unterminated function macro argument list", ERROR, {}, PREPROCESSOR },
	TO_MATCH_PAREN { "to match this '('", NOTE, {}, PREPROCESSOR },
	CLOSING_PAREN { "expected closing ')'", ERROR, {}, PREPROCESSOR },
	POISONED_IDENTIFIER { "attempt to use a poisoned identifier", ERROR, {}, PREPROCESSOR },
	EXPECTED_ARGUMENTS { "expected %d argument(s) got %d", ERROR, {}, PREPROCESSOR },
	EXPECTED_AT_LEAST_ARGUMENTS { "expected at least %d argument(s) got %d", WARNING, {}, PREPROCESSOR },
	EXPECTED_STR_LITERAL_IN { "expected string literal in '%s'", ERROR, {}, PREPROCESSOR },
	BUILTIN_MISSING_R_PAREN { "missing ')', after %s", ERROR, {}, PREPROCESSOR },
	CANNOT_CONVERT_TO_IDENTIFIER { "cannot convert %s to an identifier", ERROR, {}, PREPROCESSOR },
	PP_EXPECTED_IDENTIFIER { "expected identifier argument", ERROR, {}, PREPROCESSOR },
	INCOMPLETE_UCN { "incomplete universal character name; treating as '\\' followed by identifier", WARNING, { .has_opt = true, .opt = Option.UNICODE }, PREPROCESSOR },
	INVALID_SOURCE_EPOCH { "environment variable SOURCE_DATE_EPOCH must expand to a non-negative integer less than or equal to 253402300799", ERROR, {}, PREPROCESSOR },
	DATE_TIME { "expansion of date or time macro is not reproducible", OFF, { .has_opt = true, .opt = Option.DATE_TIME, .show_in_system_headers = true }, PREPROCESSOR },
	NO_ARGUMENT_VARIADIC_MACRO { "passing no argument for the '...' parameter of a variadic macro is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.VARIADIC_MACRO_ARGUMENTS_OMITTED, .extension = true }, PREPROCESSOR },
	PRAGMA_ONCE_IN_MAIN_FILE { "#pragma once in main file", WARNING, { .has_opt = true, .opt = Option.PRAGMA_ONCE_OUTSIDE_HEADER }, PREPROCESSOR },
	FILE_NAME_IS_CLANG_EXTENSION { "__FILE_NAME__ is a clang extension", OFF, { .has_opt = true, .opt = Option.FILE_NAME_EXTENSION, .extension = true }, PREPROCESSOR },
	BASE_FILE_IS_CLANG_EXTENSION { "__BASE_FILE__ is a clang extension", OFF, { .has_opt = true, .opt = Option.BASE_FILE_EXTENSION, .extension = true }, PREPROCESSOR },
	INCLUDE_LEVEL_IS_CLANG_EXTENSION { "__INCLUDE_LEVEL__ is a clang extension", OFF, { .has_opt = true, .opt = Option.INCLUDE_LEVEL_EXTENSION, .extension = true }, PREPROCESSOR },
	PRE_C2Y_COUNTER { "'__COUNTER__' is incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, PREPROCESSOR },
	C2Y_COUNTER { "'__COUNTER__' is a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, PREPROCESSOR },
	COUNTER_OVERFLOW { "'__COUNTER__' value cannot exceed 2'147'483'647", ERROR, {}, PREPROCESSOR },
	// C3-only: a directive whose implementation belongs to a later plan returned aro::UNSUPPORTED.
	DIRECTIVE_UNSUPPORTED { "'%s' is not supported yet by the C3 port", ERROR, {}, PREPROCESSOR },

	// ---- #pragma message (src/pragmas/message.c3) ----
	// Zig Pragma/message.zig diagnostics, emitted through the duck-typed `Preprocessor.err`.
	PRAGMA_MESSAGE { "#pragma message: %s", NOTE, {}, PRAGMA },
	PRAGMA_REQUIRES_STRING_LITERAL { "pragma %s requires string literal", ERROR, {}, PRAGMA },

	// ---- Attributes (Wip.emit / emit_at; `{at}` is replaced by the attribute name) ----
	// Zig `Attribute.Diagnostic`. `fmt` is C3 printf syntax, except `{at}`, which `Wip.emit` replaces with the quoted name of the attribute being reported before formatting.
	UNIMPLEMENTED { "TODO: implement {at} attribute", WARNING, {}, ATTRIBUTE },
	ARG_COUNT_ZERO { "{at} attribute takes no arguments", ERROR, {}, ATTRIBUTE },
	ARG_COUNT_ONE { "{at} attribute takes one argument", ERROR, {}, ATTRIBUTE },
	ARG_COUNT { "{at} attribute takes %d arguments", ERROR, {}, ATTRIBUTE },
	NOT_ENOUGH_ARGS { "{at} attribute takes at least %d argument(s)", ERROR, {}, ATTRIBUTE },
	TOO_MANY_ARGS { "{at} attribute takes at most %d argument(s)", ERROR, {}, ATTRIBUTE },
	ARG_TYPE { "expected %s as argmuent of {at} attribute but got %s", ERROR, {}, ATTRIBUTE },
	ARG_INT_OUT_OF_RANGE { "attribute {at} argument value '%s' out of range", ERROR, {}, ATTRIBUTE },
	ARG_REQUIRES_STRING { "expected string literal as argmuent of {at} attribute", ERROR, {}, ATTRIBUTE },
	UNKNOWN_ENUM { "unknown {at} argument. Possible values are: %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	INVALID_TARGET { "{at} attribute only applies to %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	INCOMPATIBLE_ATTR { "{at} and %s attributes are not compatible", ERROR, {}, ATTRIBUTE },
	INVALID_STMT_ATTR { "{at} attribute cannot be applied to a statement", ERROR, {}, ATTRIBUTE },
	STMT_ATTR_ON_DECL { "{at} attribute cannot be applied to a declaration", ERROR, {}, ATTRIBUTE },
	PREVIOUS_ATTRIBUTE { "previous attribute is here", NOTE, {}, ATTRIBUTE },
	IGNORED_ATTRIBUTE { "{at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	CONFLICTING_ATTRIBUTE { "conflicting attribute is here", NOTE, {}, ATTRIBUTE },
	INVALID_VEC_ELEM_TY { "invalid vector element type %s", ERROR, {}, ATTRIBUTE },
	BIT_INT_VEC_TOO_SMALL { "'_BitInt' vector element width must be at least as wide as 'CHAR_BIT'", ERROR, {}, ATTRIBUTE },
	BIT_INT_VEC_NOT_POW2 { "'_BitInt' vector element width must be a power of 2", ERROR, {}, ATTRIBUTE },
	VEC_SIZE_NOT_MULTIPLE { "vector size not an integral multiple of component size", ERROR, {}, ATTRIBUTE },
	ALIGNAS_ON_FUNC { "{at} attribute only applies to variables and fields", ERROR, {}, ATTRIBUTE },
	ALIGNAS_ON_PARAM { "{at} attribute cannot be applied to a function parameter", ERROR, {}, ATTRIBUTE },
	ALIGNAS_ON_REGISTER { "{at} attribute cannot be applied to a variable with 'register' storage class", ERROR, {}, ATTRIBUTE },
	ALIGNAS_BITFIELD { "{at} attribute cannot be applied to a bit-field", ERROR, {}, ATTRIBUTE },
	MINIMUM_ALIGNMENT { "requested alignment is less than minimum alignment of %d", ERROR, {}, ATTRIBUTE },
	NON_POW2_ALIGN { "requested alignment is not a power of 2", ERROR, {}, ATTRIBUTE },
	MSVC_ENUM_ALIGN_IGNORED { "alignment specifier is ignored on enum", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	WARN_UNUSED_RESULT_VOID { "attribute {at} cannot be applied to functions without return value", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	NONNULL_PARAM_ARGS { "{at} attribute when used on parameters takes no arguments", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	PARAM_OUT_OF_BOUNDS { "{at} attribute parameter %d is out of bounds", ERROR, {}, ATTRIBUTE },
	NONNULL_POINTER_ONLY { "{at} attribute only applies to pointer arguments", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	INVALID_NEON_VEC_SIZE { "Neon vector size must be 64 or 128 bits", ERROR, {}, ATTRIBUTE },
	TRANSPARENT_UNION_FORWARD_DECL { "{at} attribute can only be applied to a union definition; attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	TRANSPARENT_UNION_WRONG_TYPE { "{at} attribute only applies to unions", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	TRANSPARENT_UNION_ONE_FIELD { "transparent union definition must contain at least one field; {at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	TRANSPARENT_UNION_SIZE { "size of field '%s' (%d bits) does not match the size of the first field in transparent union; {at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	TRANSPARENT_UNION_SIZE_NOTE { "size of first field is %d", NOTE, {}, ATTRIBUTE },
	DESIGNATED_INIT_INVALID { "{at} attribute is only valid on 'struct' type'", ERROR, {}, ATTRIBUTE },
	FALLTHROUGH_NON_EMPTY { "{at} attribute is only allowed on empty statements", ERROR, {}, ATTRIBUTE },
	FALLTHROUGH_OUTSIDE_SWITCH { "{at} attribute outside a switch statement", ERROR, {}, ATTRIBUTE },
	FALLTHROUGH_NOT_BEFORE_CASE { "{at} attribute not preceding a switch label", ERROR, {}, ATTRIBUTE },
	CALLCONV_NON_FUNC { "{at} only applies to function types; type here is %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	CALLCONV_NOT_SUPPORTED { "{at} calling convention is not supported for this target", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	CALLCONV_INCOMPATIBLE { "%s and %s attributes are not compatible", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	VISIBILITY_PROTECTED_INVALID { "target does not support 'protected' visibility; using 'default'", WARNING, { .has_opt = true, .opt = Option.UNSUPPORTED_VISIBILITY }, ATTRIBUTE },
	INCOMPATIBLE_VISIBILITY { "visibility does not match previous declaration", ERROR, {}, ATTRIBUTE },
	CONFLICTING_NULLABILITY { "nullability specifier '%s' conflicts with existing specifier '%s'", ERROR, {}, ATTRIBUTE },
	INVALID_NULLABILITY { "nullability specifier cannot be applied to non-pointer type %s", ERROR, {}, ATTRIBUTE },
	DEPRECATED_NORETURN { "the '[[_Noreturn]]' attribute spelling is deprecated in C23; use '[[noreturn]]' instead", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_ATTRIBUTES }, ATTRIBUTE },
	CLEANUP_NON_FUNCTION { "{at} argument '%s' is not a function", ERROR, {}, ATTRIBUTE },
	CLEANUP_ONE_ARG { "{at} function '%s' must take 1 parameter", ERROR, {}, ATTRIBUTE },
	CLEANUP_ARG_TY { "{at} function '%s' parameter %s is incompatible with %s", ERROR, {}, ATTRIBUTE },
	GNU_INLINE_NON_INLINE { "{at} attribute requires function to be marked 'inline', attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, ATTRIBUTE },
	CONFLICTING_SECTION_NAME { "{at} does not match previous declaration", WARNING, { .has_opt = true, .opt = Option.SECTION }, ATTRIBUTE },
	INVALID_WEAK { "{at} cannot be applied to declarations with internal linkage", ERROR, {}, ATTRIBUTE },
	INVALID_SELECTANY { "{at} can only be applied to data items with external linkage", ERROR, {}, ATTRIBUTE },

	// ---- Text literals (TextLiteralParser.err) ----
	// Zig `text_literal.Parser.Diagnostic` (exact Zig text). `fmt` is C3 printf syntax; `{c}` arguments are `Ascii` values.
	ILLEGAL_CHAR_ENCODING_ERROR { "illegal character encoding in character literal", ERROR, {}, TEXT_LITERAL },
	ILLEGAL_CHAR_ENCODING_WARNING { "illegal character encoding in character literal", WARNING, { .has_opt = true, .opt = Option.INVALID_SOURCE_ENCODING }, TEXT_LITERAL },
	MISSING_HEX_ESCAPE { "\\%s used with no following hex digits", ERROR, {}, TEXT_LITERAL },
	ESCAPE_SEQUENCE_OVERFLOW { "escape sequence out of range", ERROR, {}, TEXT_LITERAL },
	INCOMPLETE_UNIVERSAL_CHARACTER { "incomplete universal character name", ERROR, {}, TEXT_LITERAL },
	INVALID_UNIVERSAL_CHARACTER { "invalid universal character", ERROR, {}, TEXT_LITERAL },
	CHAR_TOO_LARGE { "character too large for enclosing character literal type", ERROR, {}, TEXT_LITERAL },
	UCN_BASIC_CHAR_ERROR { "character '%s' cannot be specified by a universal character name", ERROR, {}, TEXT_LITERAL },
	UCN_BASIC_CHAR_WARNING { "specifying character '%s' with a universal character name is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, TEXT_LITERAL },
	UCN_CONTROL_CHAR_ERROR { "universal character name refers to a control character", ERROR, {}, TEXT_LITERAL },
	UCN_CONTROL_CHAR_WARNING { "universal character name referring to a control character is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, TEXT_LITERAL },
	C89_UCN_IN_LITERAL { "universal character names are only valid in C99 or later", WARNING, { .has_opt = true, .opt = Option.UNICODE }, TEXT_LITERAL },
	NON_STANDARD_ESCAPE_CHAR { "use of non-standard escape character '\\%s'", OFF, { .extension = true }, TEXT_LITERAL },
	UNKNOWN_ESCAPE_SEQUENCE { "unknown escape sequence '\\%s'", WARNING, { .has_opt = true, .opt = Option.UNKNOWN_ESCAPE_SEQUENCE }, TEXT_LITERAL },
	FOUR_CHAR_CHAR_LITERAL { "multi-character character constant", OFF, { .has_opt = true, .opt = Option.FOUR_CHAR_CONSTANTS }, TEXT_LITERAL },
	MULTICHAR_LITERAL_WARNING { "multi-character character constant", WARNING, { .has_opt = true, .opt = Option.MULTICHAR }, TEXT_LITERAL },
	INVALID_MULTICHAR_LITERAL { "%s character literals may not contain multiple characters", ERROR, {}, TEXT_LITERAL },
	CHAR_LIT_TOO_WIDE { "character constant too long for its type", WARNING, {}, TEXT_LITERAL },
	U8_CHAR_LIT { "UTF-8 character literal is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, TEXT_LITERAL },

	// ---- Number literals (LiteralSite.err) ----
	// Zig `number_literal.Parser.Diagnostic` (exact Zig text). `fmt` is C3 printf syntax; `{c}` arguments are `text_literal::Ascii` values.
	INVALID_BINARY_DIGIT { "invalid digit '%s' in binary constant", ERROR, {}, NUMBER_LITERAL },
	INVALID_OCTAL_DIGIT { "invalid digit '%s' in octal constant", ERROR, {}, NUMBER_LITERAL },
	INVALID_INT_SUFFIX { "invalid suffix '%s' on integer constant", ERROR, {}, NUMBER_LITERAL },
	INVALID_FLOAT_SUFFIX { "invalid suffix '%s' on floating constant", ERROR, {}, NUMBER_LITERAL },
	HEX_FLOATING_CONSTANT_REQUIRES_EXPONENT { "hexadecimal floating constant requires an exponent", ERROR, {}, NUMBER_LITERAL },
	EXPONENT_HAS_NO_DIGITS { "exponent has no digits", ERROR, {}, NUMBER_LITERAL },
	C23_BINARY { "binary integer literals are a C23 extension", OFF, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, NUMBER_LITERAL },
	// Zig text says "octal" although this is the binary-literal compat warning; kept verbatim.
	PRE_C23_BINARY { "octal integer literals are incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, NUMBER_LITERAL },
	BITINT_SUFFIX { "'_BitInt' suffix for literals is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, NUMBER_LITERAL },
	PRE_C23_BITINT { "'_BitInt' suffix for literals is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, NUMBER_LITERAL },
	C2Y_OCTAL { "octal integer literals are a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, NUMBER_LITERAL },
	PRE_C2Y_OCTAL { "octal integer literals are incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, NUMBER_LITERAL },
	C2Y_DEPRECATED_OCTAL { "octal literals without a '0o' prefix are deprecated", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_OCTAL_LITERALS }, NUMBER_LITERAL },

	// ---- Parser (Diagnostic.@emit) ----
	// Parser diagnostics (declaration order follows Zig Parser/Diagnostic.zig).
	// `fmt` uses C3 printf syntax; `Diagnostic.@emit` forwards it to an `@format`
	// function so c3c checks each call site's arguments at compile time.
	// Zig `{qt}`, `{tok_id}`, `{value}`, `{at}`, `{codepoint}` and `{normalized}`
	// placeholders are all `%s`; pass `Parser.qt`/`Parser.value` wrappers for them.
	TODO { "TODO: %s", ERROR, {}, PARSER },
	TO_MATCH_BRACE { "to match this '{'", NOTE, {}, PARSER },
	TO_MATCH_BRACKET { "to match this '['", NOTE, {}, PARSER },
	EXPECTED_INVALID { "expected '%s', found invalid bytes", ERROR, {}, PARSER },
	EXPECTED_EOF { "expected '%s' before end of file", ERROR, {}, PARSER },
	EXPECTED_TOKEN { "expected '%s', found '%s'", ERROR, {}, PARSER },
	EXPECTED_EXPR { "expected expression", ERROR, {}, PARSER },
	UNEXPECTED_TYPE_NAME { "unexpected type name '%s': expected expression", ERROR, {}, PARSER },
	EXPECTED_INTEGER_CONSTANT_EXPR { "expression is not an integer constant expression", ERROR, {}, PARSER },
	MISSING_TYPE_SPECIFIER { "type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int", ERROR, { .has_opt = true, .opt = Option.IMPLICIT_INT, .has_suppress_unless_version = true, .suppress_unless_version = C99 }, PARSER },
	MISSING_TYPE_SPECIFIER_C23 { "a type specifier is required for all declarations", ERROR, {}, PARSER },
	PARAM_NOT_DECLARED { "parameter '%s' was not declared, defaults to 'int'; ISO C99 and later do not support implicit int", ERROR, { .has_opt = true, .opt = Option.IMPLICIT_INT, .extension = true, .has_suppress_unless_version = true, .suppress_unless_version = C99 }, PARSER },
	MULTIPLE_STORAGE_CLASS { "cannot combine with previous '%s' declaration specifier", ERROR, {}, PARSER },
	STATIC_ASSERT_FAILURE_MESSAGE { "static assertion failed%s", ERROR, {}, PARSER },
	STATIC_ASSERT_EXPRESSION_EVALUATES_TO { "expression evaluates to '%s'", NOTE, {}, PARSER },
	EXPECTED_TYPE { "expected a type", ERROR, {}, PARSER },
	CANNOT_COMBINE_SPEC { "cannot combine with previous '%s' specifier", ERROR, {}, PARSER },
	CANNOT_COMBINE_SPEC_QT { "cannot combine with previous %s specifier", ERROR, {}, PARSER },
	CANNOT_COMBINE_WITH_TYPEOF { "'%s typeof' is invalid", ERROR, {}, PARSER },
	DUPLICATE_DECL_SPEC { "duplicate '%s' declaration specifier", WARNING, { .has_opt = true, .opt = Option.DUPLICATE_DECL_SPECIFIER }, PARSER },
	RESTRICT_NON_POINTER { "restrict requires a pointer or reference (%s is invalid)", ERROR, {}, PARSER },
	EXPECTED_EXTERNAL_DECL { "expected external declaration", ERROR, {}, PARSER },
	EXPECTED_RECORD_DECL { "expected record declaration", ERROR, {}, PARSER },
	EXPECTED_IDENT_OR_L_PAREN { "expected identifier or '('", ERROR, {}, PARSER },
	MISSING_DECLARATION { "declaration does not declare anything", WARNING, { .has_opt = true, .opt = Option.MISSING_DECLARATION, .extension = true }, PARSER },
	FUNC_NOT_IN_ROOT { "function definition is not allowed here", ERROR, {}, PARSER },
	ILLEGAL_INITIALIZER { "illegal initializer (only variables can be initialized)", ERROR, {}, PARSER },
	EXTERN_INITIALIZER { "extern variable has initializer", WARNING, { .has_opt = true, .opt = Option.EXTERN_INITIALIZER }, PARSER },
	PARAM_BEFORE_VAR_ARGS { "ISO C requires a named parameter before '...'", ERROR, { .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	VOID_ONLY_PARAM { "'void' must be the only parameter if specified", ERROR, {}, PARSER },
	VOID_PARAM_QUALIFIED { "'void' parameter cannot be qualified", ERROR, {}, PARSER },
	VOID_MUST_BE_FIRST_PARAM { "'void' must be the first parameter if specified", ERROR, {}, PARSER },
	INVALID_STORAGE_ON_PARAM { "invalid storage class on function parameter", ERROR, {}, PARSER },
	THREADLOCAL_NON_VAR { "_Thread_local only allowed on variables", ERROR, {}, PARSER },
	THREAD_BEFORE_STORAGE { "'__thread' before '%s'", OFF, { .extension = true }, PARSER },
	FUNC_SPEC_NON_FUNC { "'%s' can only appear on functions", ERROR, {}, PARSER },
	ILLEGAL_STORAGE_ON_FUNC { "illegal storage class on function", ERROR, {}, PARSER },
	AUTO_ON_GLOBAL { "'auto' specified on global variable", ERROR, {}, PARSER },
	REGISTER_ON_GLOBAL { "register name not specified for global variable", ERROR, {}, PARSER },
	EXPECTED_STMT { "expected statement", ERROR, {}, PARSER },
	FUNC_CANNOT_RETURN_FUNC { "function cannot return a function", ERROR, {}, PARSER },
	FUNC_CANNOT_RETURN_ARRAY { "function cannot return an array", ERROR, {}, PARSER },
	UNDECLARED_IDENTIFIER { "use of undeclared identifier '%s'", ERROR, {}, PARSER },
	NOT_CALLABLE { "cannot call non function type %s", ERROR, {}, PARSER },
	UNSUPPORTED_STR_CAT { "unsupported string literal concatenation", ERROR, {}, PARSER },
	STATIC_FUNC_NOT_GLOBAL { "static functions must be global", ERROR, {}, PARSER },
	IMPLICIT_FUNC_DECL { "call to undeclared function '%s'; ISO C99 and later do not support implicit function declarations", ERROR, { .has_opt = true, .opt = Option.IMPLICIT_FUNCTION_DECLARATION, .has_suppress_unless_version = true, .suppress_unless_version = C99 }, PARSER },
	UNKNOWN_BUILTIN { "use of unknown builtin '%s'", ERROR, { .has_opt = true, .opt = Option.IMPLICIT_FUNCTION_DECLARATION }, PARSER },
	IMPLICIT_BUILTIN { "implicitly declaring library function '%s'", ERROR, { .has_opt = true, .opt = Option.IMPLICIT_FUNCTION_DECLARATION }, PARSER },
	IMPLICIT_BUILTIN_HEADER_NOTE { "include the header <%s.h> or explicitly provide a declaration for '%s'", NOTE, { .has_opt = true, .opt = Option.IMPLICIT_FUNCTION_DECLARATION }, PARSER },
	EXPECTED_PARAM_DECL { "expected parameter declaration", ERROR, {}, PARSER },
	INVALID_OLD_STYLE_PARAMS { "identifier parameter lists are only allowed in function definitions", ERROR, {}, PARSER },
	EXPECTED_FN_BODY { "expected function body after function declaration", ERROR, {}, PARSER },
	INVALID_VOID_PARAM { "parameter cannot have void type", ERROR, {}, PARSER },
	CONTINUE_NOT_IN_LOOP { "'continue' statement not in a loop", ERROR, {}, PARSER },
	BREAK_NOT_IN_LOOP_OR_SWITCH { "'break' statement not in a loop or a switch", ERROR, {}, PARSER },
	UNREACHABLE_CODE { "unreachable code", WARNING, { .has_opt = true, .opt = Option.UNREACHABLE_CODE }, PARSER },
	DUPLICATE_LABEL { "duplicate label '%s'", ERROR, {}, PARSER },
	PREVIOUS_LABEL { "previous definition of label '%s' was here", NOTE, {}, PARSER },
	UNDECLARED_LABEL { "use of undeclared label '%s'", ERROR, {}, PARSER },
	CASE_NOT_IN_SWITCH { "'%s' statement not in a switch statement", ERROR, {}, PARSER },
	DUPLICATE_SWITCH_CASE { "duplicate case value '%s'", ERROR, {}, PARSER },
	MULTIPLE_DEFAULT { "multiple default cases in the same switch", ERROR, {}, PARSER },
	PREVIOUS_CASE { "previous case defined here", NOTE, {}, PARSER },
	EXPECTED_ARGUMENTS_OLD { "expected %d argument(s) got %d", WARNING, {}, PARSER },
	CALLEE_WITH_STATIC_ARRAY { "callee declares array parameter as static here", NOTE, {}, PARSER },
	ARRAY_ARGUMENT_TOO_SMALL { "array argument is too small; contains %d elements, callee requires at least %d", WARNING, { .has_opt = true, .opt = Option.ARRAY_BOUNDS }, PARSER },
	NON_NULL_ARGUMENT { "null passed to a callee that requires a non-null argument", WARNING, {}, PARSER },
	INVALID_STATIC_STAR { "'static' may not be used with an unspecified variable length array size", ERROR, {}, PARSER },
	STATIC_NON_PARAM { "'static' used outside of function parameters", ERROR, {}, PARSER },
	ARRAY_QUALIFIERS { "type qualifier in non parameter array type", ERROR, {}, PARSER },
	STAR_NON_PARAM { "star modifier used outside of function parameters", ERROR, {}, PARSER },
	VARIABLE_LEN_ARRAY_FILE_SCOPE { "variable length arrays not allowed at file scope", ERROR, {}, PARSER },
	USELESS_STATIC { "'static' useless without a constant size", WARNING, {}, PARSER },
	NEGATIVE_ARRAY_SIZE { "array size must be 0 or greater", ERROR, {}, PARSER },
	ARRAY_INCOMPLETE_ELEM { "array has incomplete element type %s", ERROR, {}, PARSER },
	ARRAY_ELEM_SIZE_NOT_MULTIPLE { "size of array element of type %s (%d bytes) isn't a multiple of its alignment (%d bytes)", ERROR, {}, PARSER },
	ARRAY_FUNC_ELEM { "arrays cannot have functions as their element type", ERROR, {}, PARSER },
	STATIC_NON_OUTERMOST_ARRAY { "'static' used in non-outermost array type", ERROR, {}, PARSER },
	QUALIFIER_NON_OUTERMOST_ARRAY { "type qualifier used in non-outermost array type", ERROR, {}, PARSER },
	ARRAY_OVERFLOW { "the pointer incremented by %s refers past the last possible element in %d-bit address space containing %d-bit (%d-byte) elements (max possible %d elements)", WARNING, { .has_opt = true, .opt = Option.ARRAY_BOUNDS }, PARSER },
	OVERFLOW { "overflow in expression; result is '%s'", WARNING, { .has_opt = true, .opt = Option.INTEGER_OVERFLOW }, PARSER },
	INDIRECTION_PTR { "indirection requires pointer operand", ERROR, {}, PARSER },
	ADDR_OF_RVALUE { "cannot take the address of an rvalue", ERROR, {}, PARSER },
	ADDR_OF_BITFIELD { "address of bit-field requested", ERROR, {}, PARSER },
	NOT_ASSIGNABLE { "expression is not assignable", ERROR, {}, PARSER },
	CAST_NOT_ASSIGNABLE { "assignment to cast is not allowed", ERROR, {}, PARSER },
	IDENT_OR_L_BRACE { "expected identifier or '{'", ERROR, {}, PARSER },
	EMPTY_ENUM { "empty enum is invalid", ERROR, {}, PARSER },
	REDEFINITION { "redefinition of '%s'", ERROR, {}, PARSER },
	PREVIOUS_DECLARATION { "previous declaration is here", NOTE, {}, PARSER },
	OUT_OF_SCOPE_USE { "use of out-of-scope declaration of '%s'", WARNING, { .has_opt = true, .opt = Option.OUT_OF_SCOPE_FUNCTION }, PARSER },
	EXPECTED_IDENTIFIER { "expected identifier", ERROR, {}, PARSER },
	EXPECTED_STR_LITERAL { "expected string literal for diagnostic message in static_assert", ERROR, {}, PARSER },
	PARAMETER_MISSING { "parameter named '%s' is missing", ERROR, {}, PARSER },
	EMPTY_RECORD { "empty %s is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_EMPTY_STRUCT, .extension = true }, PARSER },
	EMPTY_RECORD_SIZE { "empty %s has size 0 in C, size 1 in C++", OFF, { .has_opt = true, .opt = Option.CXX_COMPAT }, PARSER },
	WRONG_TAG { "use of '%s' with tag type that does not match previous definition", ERROR, {}, PARSER },
	EXPECTED_PARENS_AROUND_TYPENAME { "expected parentheses around type name", ERROR, {}, PARSER },
	GNU_ALIGNOF_EXPR { "'%s' applied to an expression is a GNU extension", WARNING, { .has_opt = true, .opt = Option.GNU_ALIGNOF_EXPRESSION, .extension = true }, PARSER },
	INVALID_ALIGNOF { "invalid application of 'alignof' to an incomplete type %s", ERROR, {}, PARSER },
	INVALID_SIZEOF { "invalid application of 'sizeof' to an incomplete type %s", ERROR, {}, PARSER },
	GENERIC_QUAL_TYPE { "generic association with qualifiers cannot be matched with", WARNING, { .has_opt = true, .opt = Option.GENERIC_QUAL_TYPE }, PARSER },
	GENERIC_ARRAY_TYPE { "generic association array type cannot be matched with", WARNING, { .has_opt = true, .opt = Option.GENERIC_QUAL_TYPE }, PARSER },
	GENERIC_FUNC_TYPE { "generic association function type cannot be matched with", WARNING, { .has_opt = true, .opt = Option.GENERIC_QUAL_TYPE }, PARSER },
	GENERIC_DUPLICATE { "type %s in generic association compatible with previously specified type", ERROR, {}, PARSER },
	GENERIC_DUPLICATE_HERE { "compatible type %s specified here", NOTE, {}, PARSER },
	GENERIC_DUPLICATE_DEFAULT { "duplicate default generic association", ERROR, {}, PARSER },
	GENERIC_NO_MATCH { "controlling expression type %s not compatible with any generic association type", ERROR, {}, PARSER },
	MUST_USE_STRUCT { "must use 'struct' tag to refer to type '%s'", ERROR, {}, PARSER },
	MUST_USE_UNION { "must use 'union' tag to refer to type '%s'", ERROR, {}, PARSER },
	MUST_USE_ENUM { "must use 'enum' tag to refer to type '%s'", ERROR, {}, PARSER },
	REDEFINITION_DIFFERENT_SYM { "redefinition of '%s' as different kind of symbol", ERROR, {}, PARSER },
	REDEFINITION_INCOMPATIBLE { "redefinition of '%s' with a different type", ERROR, {}, PARSER },
	REDEFINITION_OF_PARAMETER { "redefinition of parameter '%s'", ERROR, {}, PARSER },
	INVALID_BIN_TYPES { "invalid operands to binary expression (%s and %s)", ERROR, {}, PARSER },
	INCOMPATIBLE_VEC_TYPES { "cannot convert between vector type %s and vector type %s as implicit conversion would cause truncation", ERROR, {}, PARSER },
	COMPARISON_PTR_INT { "comparison between pointer and integer (%s and %s)", WARNING, { .has_opt = true, .opt = Option.POINTER_INTEGER_COMPARE, .extension = true }, PARSER },
	COMPARISON_DISTINCT_PTR { "comparison of distinct pointer types (%s and %s)", WARNING, { .has_opt = true, .opt = Option.COMPARE_DISTINCT_POINTER_TYPES, .extension = true }, PARSER },
	INCOMPATIBLE_POINTERS { "incompatible pointer types (%s and %s)", ERROR, {}, PARSER },
	INVALID_ARGUMENT_UN { "invalid argument type %s to unary expression", ERROR, {}, PARSER },
	INCOMPATIBLE_ASSIGN { "assignment to %s from incompatible type %s", ERROR, {}, PARSER },
	IMPLICIT_PTR_TO_INT { "implicit pointer to integer conversion from %s to %s", WARNING, { .has_opt = true, .opt = Option.INT_CONVERSION }, PARSER },
	INVALID_CAST_TO_FLOAT { "pointer cannot be cast to type %s", ERROR, {}, PARSER },
	INVALID_CAST_TO_POINTER { "operand of type %s cannot be cast to a pointer type", ERROR, {}, PARSER },
	INVALID_CAST_TYPE { "cannot cast to non arithmetic or pointer type %s", ERROR, {}, PARSER },
	CAST_TO_SAME_TYPE { "C99 forbids casting nonscalar type %s to the same type", OFF, { .extension = true }, PARSER },
	INVALID_CAST_OPERAND_TYPE { "operand of type %s where arithmetic or pointer type is required", ERROR, {}, PARSER },
	QUAL_CAST { "cast to type %s will not preserve qualifiers", WARNING, { .has_opt = true, .opt = Option.CAST_QUALIFIERS }, PARSER },
	INVALID_VEC_CONVERSION { "invalid conversion between vector type %s and %s of different size", ERROR, {}, PARSER },
	INVALID_VEC_CONVERSION_SCALAR { "invalid conversion between vector type %s and scalar type %s", ERROR, {}, PARSER },
	INVALID_VEC_CONVERSION_INT { "invalid conversion between vector type %s and integer type %s of different size", ERROR, {}, PARSER },
	INVALID_INDEX { "array subscript is not an integer", ERROR, {}, PARSER },
	INVALID_SUBSCRIPT { "subscripted value is not an array, pointer or vector", ERROR, {}, PARSER },
	ARRAY_AFTER { "array index %s is past the end of the array", WARNING, { .has_opt = true, .opt = Option.ARRAY_BOUNDS }, PARSER },
	ARRAY_BEFORE { "array index %s is before the beginning of the array", WARNING, { .has_opt = true, .opt = Option.ARRAY_BOUNDS }, PARSER },
	NON_INT_COND { "statement requires expression with integer type (%s invalid)", ERROR, {}, PARSER },
	NON_SCALAR_COND { "statement requires expression with scalar type (%s invalid)", ERROR, {}, PARSER },
	MULTIPLE_COND_DECL { "declaration in condition can only declare a single object", ERROR, {}, PARSER },
	NON_SCALAR_COND_DECL { "declaration in condition must have a scalar type (%s invalid)", ERROR, {}, PARSER },
	NON_INT_COND_DECL { "declaration in condition must have an integer type (%s invalid)", ERROR, {}, PARSER },
	COND_DECL_VARIABLE { "declaration in condition must be a variable", ERROR, {}, PARSER },
	COND_DECL_INITIALIZER { "variable declaration in condition must have an initializer", ERROR, {}, PARSER },
	C2Y_SELECTION_HEADER { "declarations in %s conditions are a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, PARSER },
	PRE_C2Y_SELECTION_HEADER { "declarations in %s conditions are incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, PARSER },
	FUNC_SHOULD_RETURN { "non-void function '%s' should return a value", ERROR, { .has_opt = true, .opt = Option.RETURN_TYPE }, PARSER },
	INCOMPATIBLE_RETURN { "returning %s from a function with incompatible result type %s", ERROR, {}, PARSER },
	INCOMPATIBLE_RETURN_SIGN { "returning %s from a function with incompatible result type %s converts between pointers to integer types with different sign", WARNING, { .has_opt = true, .opt = Option.POINTER_SIGN }, PARSER },
	IMPLICIT_INT_TO_PTR { "implicit integer to pointer conversion from %s to %s", WARNING, { .has_opt = true, .opt = Option.INT_CONVERSION }, PARSER },
	FUNC_DOES_NOT_RETURN { "non-void function '%s' does not return a value", WARNING, { .has_opt = true, .opt = Option.RETURN_TYPE }, PARSER },
	VOID_FUNC_RETURNS_VALUE { "void function '%s' should not return a value", ERROR, { .has_opt = true, .opt = Option.RETURN_TYPE }, PARSER },
	INCOMPATIBLE_ARG { "passing %s to parameter of incompatible type %s", ERROR, {}, PARSER },
	INCOMPATIBLE_PTR_ARG { "passing %s to parameter of incompatible type %s", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES }, PARSER },
	INCOMPATIBLE_PTR_ARG_SIGN { "passing %s to parameter of incompatible type %s converts between pointers to integer types with different sign", WARNING, { .has_opt = true, .opt = Option.POINTER_SIGN }, PARSER },
	PARAMETER_HERE { "passing argument to parameter here", NOTE, {}, PARSER },
	ATOMIC_ARRAY { "_Atomic cannot be applied to array type %s", ERROR, {}, PARSER },
	ATOMIC_FUNC { "_Atomic cannot be applied to function type %s", ERROR, {}, PARSER },
	ATOMIC_INCOMPLETE { "_Atomic cannot be applied to incomplete type %s", ERROR, {}, PARSER },
	ATOMIC_ATOMIC { "_Atomic cannot be applied to atomic type %s", ERROR, {}, PARSER },
	ATOMIC_COMPLEX { "_Atomic cannot be applied to complex type %s", ERROR, {}, PARSER },
	ATOMIC_QUALIFIED { "_Atomic cannot be applied to qualified type %s", ERROR, {}, PARSER },
	ATOMIC_AUTO { "_Atomic cannot be applied to type 'auto' in C23", ERROR, {}, PARSER },
	ATOMIC_BIT_INT { "_Atomic cannot be applied to integer type %s", ERROR, {}, PARSER },
	ATOMIC_ACCESS { "address of register variable requested", ERROR, { .has_opt = true, .opt = Option.ATOMIC_ACCESS }, PARSER },
	VARIABLE_INCOMPLETE_TY { "variable has incomplete type %s", ERROR, {}, PARSER },
	PARAMETER_INCOMPLETE_TY { "parameter has incomplete type %s", ERROR, {}, PARSER },
	TENTATIVE_ARRAY { "tentative array definition assumed to have one element", WARNING, {}, PARSER },
	DEREF_INCOMPLETE_TY_PTR { "dereferencing pointer to incomplete type %s", ERROR, {}, PARSER },
	POINTER_MISMATCH { "pointer type mismatch (%s and %s)", WARNING, { .has_opt = true, .opt = Option.POINTER_TYPE_MISMATCH, .extension = true }, PARSER },
	STATIC_ASSERT_NOT_CONSTANT { "static assertion expression is not an integral constant expression", ERROR, {}, PARSER },
	STATIC_ASSERT_MISSING_MESSAGE { "'_Static_assert' with no message is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true }, PARSER },
	STATIC_ASSERT_MISSING_MESSAGE_COMPAT { "'_Static_assert' with no message is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, PARSER },
	PRE_C23_COMPAT { "'%s' is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.PRE_C23_COMPAT }, PARSER },
	UNBOUND_VLA { "variable length array must be bound in function definition", ERROR, {}, PARSER },
	ARRAY_TOO_LARGE { "array is too large", ERROR, {}, PARSER },
	RECORD_TOO_LARGE { "type %s is too large", ERROR, {}, PARSER },
	INCOMPATIBLE_PTR_INIT { "incompatible pointer types initializing %s from incompatible type %s", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES }, PARSER },
	INCOMPATIBLE_PTR_INIT_SIGN { "incompatible pointer types initializing %s from incompatible type %s converts between pointers to integer types with different sign", WARNING, { .has_opt = true, .opt = Option.POINTER_SIGN }, PARSER },
	INCOMPATIBLE_PTR_ASSIGN { "incompatible pointer types assigning to %s from incompatible type %s", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES }, PARSER },
	INCOMPATIBLE_PTR_ASSIGN_SIGN { "incompatible pointer types assigning to %s from incompatible type %s converts between pointers to integer types with different sign", WARNING, { .has_opt = true, .opt = Option.POINTER_SIGN }, PARSER },
	VLA_INIT { "variable-sized object may not be initialized", ERROR, {}, PARSER },
	FUNC_INIT { "illegal initializer type", ERROR, {}, PARSER },
	INCOMPATIBLE_INIT { "initializing %s from incompatible type %s", ERROR, {}, PARSER },
	EXCESS_SCALAR_INIT { "excess elements in scalar initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	EXCESS_STR_INIT { "excess elements in string initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	EXCESS_STRUCT_INIT { "excess elements in struct initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	EXCESS_UNION_INIT { "excess elements in union initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	EXCESS_ARRAY_INIT { "excess elements in array initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	EXCESS_VECTOR_INIT { "excess elements in vector initializer", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS }, PARSER },
	STR_INIT_TOO_LONG { "initializer-string for char array is too long", WARNING, { .has_opt = true, .opt = Option.EXCESS_INITIALIZERS, .extension = true }, PARSER },
	ARR_INIT_TOO_LONG { "cannot initialize type %s with array of type %s", ERROR, {}, PARSER },
	EMPTY_INITIALIZER { "use of an empty initializer is a C23 extension", OFF, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	DIVISION_BY_ZERO { "%s by zero is undefined", WARNING, { .has_opt = true, .opt = Option.DIVISION_BY_ZERO }, PARSER },
	BUILTIN_CHOOSE_COND { "'__builtin_choose_expr' requires a constant expression", ERROR, {}, PARSER },
	CONVERTVECTOR_ARG { "%s argument to __builtin_convertvector must be a vector type", ERROR, {}, PARSER },
	CONVERTVECTOR_SIZE { "first two arguments to __builtin_convertvector must have the same number of elements", ERROR, {}, PARSER },
	SHUFFLEVECTOR_ARG { "%s argument to __builtin_shufflevector must be a vector type", ERROR, {}, PARSER },
	SHUFFLEVECTOR_SAME_TYPE { "first two arguments to '__builtin_shufflevector' must have the same type", ERROR, {}, PARSER },
	SHUFFLEVECTOR_NEGATIVE_INDEX { "index for __builtin_shufflevector must be positive or -1", ERROR, {}, PARSER },
	SHUFFLEVECTOR_INDEX_TOO_BIG { "index for __builtin_shufflevector must be less than the total number of vector elements", ERROR, {}, PARSER },
	CASE_VAL_UNAVAILABLE { "case value must be an integer constant expression", ERROR, {}, PARSER },
	ENUM_VAL_UNAVAILABLE { "enum value must be an integer constant expression", ERROR, {}, PARSER },
	INCOMPATIBLE_ARRAY_INIT { "cannot initialize array of type %s with array of type %s", ERROR, {}, PARSER },
	ARRAY_INIT_STR { "array initializer must be an initializer list or wide string literal", ERROR, {}, PARSER },
	INITIALIZER_OVERRIDES { "initializer overrides previous initialization", WARNING, { .has_opt = true, .opt = Option.INITIALIZER_OVERRIDES }, PARSER },
	PREVIOUS_INITIALIZER { "previous initialization", NOTE, {}, PARSER },
	INVALID_ARRAY_DESIGNATOR { "array designator used for non-array type %s", ERROR, {}, PARSER },
	NEGATIVE_ARRAY_DESIGNATOR { "array designator value %s is negative", ERROR, {}, PARSER },
	OOB_ARRAY_DESIGNATOR { "array designator index %s exceeds array bounds", ERROR, {}, PARSER },
	// C3-only: GNU range designator whose end index is below its start.
	ARRAY_DESIGNATOR_RANGE_REVERSED { "array designator range end precedes its start", ERROR, {}, PARSER },
	INVALID_FIELD_DESIGNATOR { "field designator used for non-record type %s", ERROR, {}, PARSER },
	NO_SUCH_FIELD_DESIGNATOR { "record type has no field named '%s'", ERROR, {}, PARSER },
	EMPTY_AGGREGATE_INIT_BRACES { "initializer for aggregate with no elements requires explicit braces", ERROR, {}, PARSER },
	PTR_INIT_DISCARDS_QUALS { "initializing %s from incompatible type %s discards qualifiers", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES_DISCARDS_QUALIFIERS }, PARSER },
	PTR_ASSIGN_DISCARDS_QUALS { "assigning to %s from incompatible type %s discards qualifiers", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES_DISCARDS_QUALIFIERS }, PARSER },
	PTR_RET_DISCARDS_QUALS { "returning %s from a function with incompatible result type %s discards qualifiers", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES_DISCARDS_QUALIFIERS }, PARSER },
	PTR_ARG_DISCARDS_QUALS { "passing %s to parameter of incompatible type %s discards qualifiers", WARNING, { .has_opt = true, .opt = Option.INCOMPATIBLE_POINTER_TYPES_DISCARDS_QUALIFIERS }, PARSER },
	UNKNOWN_ATTRIBUTE { "unknown attribute '%s' ignored", WARNING, { .has_opt = true, .opt = Option.UNKNOWN_ATTRIBUTES }, PARSER },
	UNKNOWN_NAMESPACED_ATTRIBUTE { "unknown attribute '%s::%s' ignored", WARNING, { .has_opt = true, .opt = Option.UNKNOWN_ATTRIBUTES }, PARSER },
	IGNORED_ON_TYPES { "%s attribute ignored when parsing type", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, PARSER },
	INVALID_ON_TYPES { "%s attribute cannot be applied to types", ERROR, {}, PARSER },
	DECLSPEC_EMPTY_ARGS { "parentheses must be omitted if '%s' attribute's argument list is empty", ERROR, {}, PARSER },
	GNU_LABEL_AS_VALUE { "use of GNU address-of-label extension", OFF, { .has_opt = true, .opt = Option.GNU_LABEL_AS_VALUE, .extension = true }, PARSER },
	EXPECTED_RECORD_TY { "member reference base type %s is not a structure or union", ERROR, {}, PARSER },
	MEMBER_EXPR_NOT_PTR { "member reference type %s is not a pointer; did you mean to use '.'?", ERROR, {}, PARSER },
	MEMBER_EXPR_PTR { "member reference type %s is a pointer; did you mean to use '->'?", ERROR, {}, PARSER },
	MEMBER_EXPR_ATOMIC { "accessing a member of atomic type %s is undefined behavior", ERROR, {}, PARSER },
	NO_SUCH_MEMBER { "no member named '%s' in %s", ERROR, {}, PARSER },
	INVALID_COMPUTED_GOTO { "computed goto in function with no address-of-label expressions", ERROR, {}, PARSER },
	EMPTY_TRANSLATION_UNIT { "ISO C requires a translation unit to contain at least one declaration", OFF, { .has_opt = true, .opt = Option.EMPTY_TRANSLATION_UNIT, .extension = true }, PARSER },
	OMITTING_PARAMETER_NAME { "omitting the parameter name in a function definition is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	NON_INT_BITFIELD { "bit-field has non-integer type %s", ERROR, {}, PARSER },
	NEGATIVE_BITWIDTH { "bit-field has negative width (%s)", ERROR, {}, PARSER },
	ZERO_WIDTH_NAMED_FIELD { "named bit-field has zero width", ERROR, {}, PARSER },
	BITFIELD_TOO_BIG { "width of bit-field exceeds width of its type", ERROR, {}, PARSER },
	INVALID_UTF8 { "source file is not valid UTF-8", ERROR, {}, PARSER },
	C99_COMPAT { "using this character in an identifier is incompatible with C99", OFF, { .has_opt = true, .opt = Option.C99_COMPAT }, PARSER },
	UNEXPECTED_CHARACTER { "unexpected character <U+%s>", ERROR, {}, PARSER },
	INVALID_IDENTIFIER_START_CHAR { "character <U+%s> not allowed at the start of an identifier", ERROR, {}, PARSER },
	UNICODE_ZERO_WIDTH { "identifier contains Unicode character <U+%s> that is invisible in some environments", WARNING, { .has_opt = true, .opt = Option.UNICODE_HOMOGLYPH }, PARSER },
	UNICODE_HOMOGLYPH { "treating Unicode character <U+%s> as identifier character rather than as '%s' symbol", WARNING, { .has_opt = true, .opt = Option.UNICODE_HOMOGLYPH }, PARSER },
	MEANINGLESS_ASM_QUAL { "meaningless '%s' on assembly outside function", ERROR, {}, PARSER },
	DUPLICATE_ASM_QUAL { "duplicate asm qualifier '%s'", ERROR, {}, PARSER },
	INVALID_ASM_STR { "cannot use %s string literal in assembly", ERROR, {}, PARSER },
	INVALID_ASM_OUTPUT { "invalid lvalue in asm output", ERROR, {}, PARSER },
	DOLLAR_IN_IDENTIFIER_EXTENSION { "'$' in identifier", OFF, { .has_opt = true, .opt = Option.DOLLAR_IN_IDENTIFIER_EXTENSION, .extension = true }, PARSER },
	DOLLARS_IN_IDENTIFIERS { "illegal character '$' in identifier", ERROR, {}, PARSER },
	PREDEFINED_TOP_LEVEL { "predefined identifier is only valid inside function", WARNING, { .has_opt = true, .opt = Option.PREDEFINED_IDENTIFIER_OUTSIDE_FUNCTION }, PARSER },
	INCOMPATIBLE_VA_ARG { "first argument to va_arg, is of type %s and not 'va_list'", ERROR, {}, PARSER },
	TOO_MANY_SCALAR_INIT_BRACES { "too many braces around scalar initializer", WARNING, { .has_opt = true, .opt = Option.MANY_BRACES_AROUND_SCALAR_INIT, .extension = true }, PARSER },
	GNU_STATEMENT_EXPRESSION { "use of GNU statement expression extension", OFF, { .has_opt = true, .opt = Option.GNU_STATEMENT_EXPRESSION, .extension = true }, PARSER },
	STMT_EXPR_NOT_ALLOWED_FILE_SCOPE { "statement expression not allowed at file scope", ERROR, {}, PARSER },
	GNU_IMAGINARY_CONSTANT { "imaginary constants are a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_IMAGINARY_CONSTANT, .extension = true }, PARSER },
	PLAIN_COMPLEX { "plain '_Complex' requires a type specifier; assuming '_Complex double'", WARNING, { .extension = true }, PARSER },
	COMPLEX_INT { "complex integer types are a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_COMPLEX_INTEGER, .extension = true }, PARSER },
	QUAL_ON_RET_TYPE { "'%s' type qualifier on return type has no effect", OFF, { .has_opt = true, .opt = Option.IGNORED_QUALIFIERS }, PARSER },
	EXTRA_SEMI { "extra ';' outside of a function", OFF, { .has_opt = true, .opt = Option.EXTRA_SEMI }, PARSER },
	FUNC_FIELD { "field declared as a function", ERROR, {}, PARSER },
	EXPECTED_MEMBER_NAME { "expected member name after declarator", ERROR, {}, PARSER },
	VLA_FIELD { "variable length array fields extension is not supported", ERROR, {}, PARSER },
	FIELD_INCOMPLETE_TY { "field has incomplete type %s", ERROR, {}, PARSER },
	FLEXIBLE_IN_UNION { "flexible array member in union is not allowed", ERROR, {}, PARSER },
	FLEXIBLE_IN_UNION_MSVC { "flexible array member in union is a Microsoft extension", OFF, { .has_opt = true, .opt = Option.MICROSOFT_FLEXIBLE_ARRAY, .extension = true }, PARSER },
	FLEXIBLE_NON_FINAL { "flexible array member is not at the end of struct", ERROR, {}, PARSER },
	FLEXIBLE_IN_EMPTY { "flexible array member in otherwise empty struct", ERROR, {}, PARSER },
	FLEXIBLE_IN_EMPTY_MSVC { "flexible array member in otherwise empty struct is a Microsoft extension", OFF, { .has_opt = true, .opt = Option.MICROSOFT_FLEXIBLE_ARRAY, .extension = true }, PARSER },
	ANONYMOUS_STRUCT { "anonymous structs are a Microsoft extension", WARNING, { .has_opt = true, .opt = Option.MICROSOFT_ANON_TAG, .extension = true }, PARSER },
	DUPLICATE_MEMBER { "duplicate member '%s'", ERROR, {}, PARSER },
	BUILTIN_MUST_BE_CALLED { "builtin function must be directly called", ERROR, {}, PARSER },
	VA_FUNC_NOT_IN_FUNC { "'%s' cannot be used outside a function", ERROR, {}, PARSER },
	VA_FUNC_FIXED_ARGS { "'%s' used in a function with fixed args", ERROR, {}, PARSER },
	VA_FUNC_NOT_ALWAYS_INLINE { "'%s' used in a function that is not always inlined", ERROR, {}, PARSER },
	VA_PACK_NON_CALL { "'__va_arg_pack' used outside a call", ERROR, {}, PARSER },
	VA_PACK_NON_VARIADIC_CALL { "'__va_arg_pack' passed to non-variadic function", ERROR, {}, PARSER },
	VA_PACK_NON_VARIADIC_ARG { "'__va_arg_pack' passed as non-variadic argument", ERROR, {}, PARSER },
	VA_PACK_NON_FINAL_ARG { "'__va_arg_pack' is not the final argument", ERROR, {}, PARSER },
	VA_START_NOT_LAST_PARAM { "second argument to 'va_start' is not the last named parameter", WARNING, {}, PARSER },
	DECLSPEC_NOT_ENABLED { "'__declspec' attributes are not enabled; use '-fdeclspec' or '-fms-extensions' to enable support for __declspec attributes", ERROR, {}, PARSER },
	DECLSPEC_ATTR_NOT_SUPPORTED { "__declspec attribute '%s' is not supported", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, PARSER },
	DEPRECATED_DECLARATIONS { "'%s' is deprecated%s%s", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_DECLARATIONS }, PARSER },
	DEPRECATED_ALTERNATIVE { "use '%s' instead", NOTE, {}, PARSER },
	DEPRECATED_NOTE { "'%s' has been explicitly marked deprecated here", NOTE, {}, PARSER },
	UNAVAILABLE { "'%s' is unavailable%s%s", ERROR, {}, PARSER },
	UNAVAILABLE_NOTE { "'%s' has been explicitly marked unavailable here", NOTE, {}, PARSER },
	WARNING_ATTRIBUTE { "call to '%s' declared with attribute warning: %s", WARNING, { .has_opt = true, .opt = Option.ATTRIBUTE_WARNING }, PARSER },
	ERROR_ATTRIBUTE { "call to '%s' declared with attribute error: %s", ERROR, {}, PARSER },
	IGNORED_RECORD_ATTR { "attribute %s is ignored, place it after \"%s\" to apply attribute to type declaration", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES }, PARSER },
	ARRAY_SIZE_NON_INT { "size of array has non-integer type %s", ERROR, {}, PARSER },
	CAST_TO_SMALLER_INT { "cast to smaller integer type %s from %s", WARNING, { .has_opt = true, .opt = Option.POINTER_TO_INT_CAST }, PARSER },
	C2Y_SWITCH_RANGE { "case ranges are a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, PARSER },
	PRE_C2Y_SWITCH_RANGE { "case ranges are incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, PARSER },
	EMPTY_CASE_RANGE { "empty case range specified", WARNING, {}, PARSER },
	VLA { "variable length array used", OFF, {}, PARSER },
	INT_VALUE_CHANGED { "implicit conversion from %s to %s changes %svalue from %s to %s", WARNING, { .has_opt = true, .opt = Option.CONSTANT_CONVERSION }, PARSER },
	SIGN_CONVERSION { "implicit conversion changes signedness: %s to %s", OFF, { .has_opt = true, .opt = Option.SIGN_CONVERSION }, PARSER },
	FLOAT_OVERFLOW_CONVERSION { "implicit conversion of non-finite value from %s to %s is undefined", OFF, { .has_opt = true, .opt = Option.FLOAT_OVERFLOW_CONVERSION }, PARSER },
	FLOAT_OUT_OF_RANGE { "implicit conversion of out of range value from %s to %s is undefined", WARNING, { .has_opt = true, .opt = Option.LITERAL_CONVERSION }, PARSER },
	FLOAT_ZERO_CONVERSION { "implicit conversion from %s to %s changes %svalue from %s to %s", OFF, { .has_opt = true, .opt = Option.FLOAT_ZERO_CONVERSION }, PARSER },
	FLOAT_VALUE_CHANGED { "implicit conversion from %s to %s changes %svalue from %s to %s", WARNING, { .has_opt = true, .opt = Option.FLOAT_CONVERSION }, PARSER },
	FLOAT_TO_INT { "implicit conversion turns floating-point number into integer: %s to %s", OFF, { .has_opt = true, .opt = Option.LITERAL_CONVERSION }, PARSER },
	CONST_DECL_FOLDED { "expression is not an integer constant expression; folding it to a constant is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_FOLDING_CONSTANT, .extension = true }, PARSER },
	CONST_DECL_FOLDED_VLA { "variable length array folded to constant array as an extension", OFF, { .has_opt = true, .opt = Option.GNU_FOLDING_CONSTANT, .extension = true }, PARSER },
	REDEFINITION_OF_TYPEDEF { "typedef redefinition with different types (%s vs %s)", ERROR, {}, PARSER },
	OFFSETOF_TY { "offsetof requires struct or union type, %s invalid", ERROR, {}, PARSER },
	OFFSETOF_INCOMPLETE { "offsetof of incomplete type %s", ERROR, {}, PARSER },
	OFFSETOF_ARRAY { "offsetof requires array type, %s invalid", ERROR, {}, PARSER },
	COND_EXPR_TYPE { "used type %s where arithmetic or pointer type is required", ERROR, {}, PARSER },
	ENUMERATOR_TOO_SMALL { "ISO C restricts enumerator values to range of 'int' (%s is too small)", OFF, { .extension = true }, PARSER },
	ENUMERATOR_TOO_LARGE { "ISO C restricts enumerator values to range of 'int' (%s is too large)", OFF, { .extension = true }, PARSER },
	ENUMERATOR_OVERFLOW { "overflow in enumeration value", WARNING, {}, PARSER },
	ENUM_NOT_REPRESENTABLE { "incremented enumerator value %s is not representable in the largest integer type", WARNING, { .has_opt = true, .opt = Option.ENUM_TOO_LARGE, .extension = true }, PARSER },
	ENUM_TOO_LARGE { "enumeration values exceed range of largest integer", WARNING, { .has_opt = true, .opt = Option.ENUM_TOO_LARGE, .extension = true }, PARSER },
	ENUM_FIXED { "enumeration types with a fixed underlying type are a Clang extension", OFF, { .has_opt = true, .opt = Option.FIXED_ENUM_EXTENSION, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	ENUM_PREV_NONFIXED { "enumeration previously declared with nonfixed underlying type", ERROR, {}, PARSER },
	ENUM_PREV_FIXED { "enumeration previously declared with fixed underlying type", ERROR, {}, PARSER },
	ENUM_DIFFERENT_EXPLICIT_TY { "enumeration redeclared with different underlying type %s (was %s)", ERROR, {}, PARSER },
	ENUM_NOT_REPRESENTABLE_FIXED { "enumerator value is not representable in the underlying type %s", ERROR, {}, PARSER },
	ENUM_FORWARD_DECLARATION { "ISO C forbids forward references to 'enum' types", OFF, { .extension = true }, PARSER },
	ENUM_ATOMIC_IGNORED { "'_Atomic' qualifier ignored; operations involving the enumeration type will be non-atomic", ERROR, { .has_opt = true, .opt = Option.UNDERLYING_ATOMIC_QUALIFIER_IGNORED }, PARSER },
	ENUM_QUALIFIERS_IGNORED { "qualifiers in enumeration underlying type ignored", WARNING, { .has_opt = true, .opt = Option.UNDERLYING_CV_QUALIFIER_IGNORED }, PARSER },
	ENUM_INVALID_UNDERLYING_TYPE { "non-integral type %s is an invalid underlying type", ERROR, {}, PARSER },
	DESIGNATED_INIT_NEEDED { "positional initialization of field in 'struct' declared with 'designated_init' attribute", WARNING, { .has_opt = true, .opt = Option.DESIGNATED_INIT }, PARSER },
	INVALID_NORETURN { "function '%s' declared 'noreturn' should not return", WARNING, { .has_opt = true, .opt = Option.INVALID_NORETURN }, PARSER },
	WARN_UNUSED_RESULT { "ignoring return value of '%s', declared with %s attribute%s%s", WARNING, { .has_opt = true, .opt = Option.UNUSED_RESULT }, PARSER },
	BUILTIN_UNUSED { "ignoring return value of function declared with %s attribute", WARNING, { .has_opt = true, .opt = Option.UNUSED_VALUE }, PARSER },
	UNUSED_VALUE { "expression result unused", WARNING, { .has_opt = true, .opt = Option.UNUSED_VALUE }, PARSER },
	UNUSED_VARIABLE { "unused variable '%s'", WARNING, { .has_opt = true, .opt = Option.UNUSED_VARIABLE }, PARSER },
	UNUSED_PARAM { "unused parameter '%s'", WARNING, { .has_opt = true, .opt = Option.UNUSED_PARAMETER }, PARSER },
	UNUSED_TYPEDEF { "unused typedef '%s'", WARNING, { .has_opt = true, .opt = Option.UNUSED_LOCAL_TYPEDEF }, PARSER },
	UNUSED_LABEL { "unused label '%s'", WARNING, { .has_opt = true, .opt = Option.UNUSED_LABEL }, PARSER },
	UNUSED_COMPARISON { "%s comparison result unused", WARNING, { .has_opt = true, .opt = Option.UNUSED_COMPARISON }, PARSER },
	INVALID_IMAG { "invalid type %s to __imag operator", ERROR, {}, PARSER },
	INVALID_REAL { "invalid type %s to __real operator", ERROR, {}, PARSER },
	ZERO_LENGTH_ARRAY { "zero size arrays are an extension", OFF, { .has_opt = true, .opt = Option.ZERO_LENGTH_ARRAY, .extension = true }, PARSER },
	OLD_STYLE_FLEXIBLE_STRUCT { "array index %s is past the end of the array", OFF, { .has_opt = true, .opt = Option.OLD_STYLE_FLEXIBLE_STRUCT }, PARSER },
	MAIN_RETURN_TYPE { "return type of 'main' is not 'int'", WARNING, { .has_opt = true, .opt = Option.MAIN_RETURN_TYPE, .extension = true }, PARSER },
	SIZEOF_RETURNS_ZERO { "sizeof returns 0", WARNING, {}, PARSER },
	DECLSPEC_NOT_ALLOWED_AFTER_DECLARATOR { "'declspec' attribute not allowed after declarator", ERROR, {}, PARSER },
	DECLARATOR_NAME_TOK { "this declarator", NOTE, {}, PARSER },
	IMAGINARY_UNSUPPORTED { "imaginary types are not supported", ERROR, {}, PARSER },
	TYPE_NOT_SUPPORTED_ON_TARGET { "%s is not supported on this target", ERROR, {}, PARSER },
	BIT_INT { "'_BitInt' in C17 and earlier is a Clang extension", OFF, { .has_opt = true, .opt = Option.BIT_INT_EXTENSION, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	UNSIGNED_BIT_INT_TOO_SMALL { "unsigned _BitInt must have a bit size of at least 1", ERROR, {}, PARSER },
	SIGNED_BIT_INT_TOO_SMALL { "signed _BitInt must have a bit size of at least 2", ERROR, {}, PARSER },
	UNSIGNED_BIT_INT_TOO_BIG { "%sunsigned _BitInt of bit sizes greater than 65535 not supported", ERROR, {}, PARSER },
	SIGNED_BIT_INT_TOO_BIG { "signed _BitInt of bit sizes greater than 65535 not supported", ERROR, {}, PARSER },
	COMPLEX_BIT_INT { "'_Complex _BitInt' is invalid", ERROR, {}, PARSER },
	PTR_ARITHMETIC_INCOMPLETE { "arithmetic on a pointer to an incomplete type %s", ERROR, {}, PARSER },
	POINTER_ARITH_VOID { "invalid application of '%s' to a void type", OFF, { .has_opt = true, .opt = Option.POINTER_ARITH, .extension = true }, PARSER },
	SIZEOF_ARRAY_ARG { "sizeof on array function parameter will return size of %s instead of %s", WARNING, { .has_opt = true, .opt = Option.SIZEOF_ARRAY_ARGUMENT }, PARSER },
	ARRAY_ADDRESS_TO_BOOL { "address of array '%s' will always evaluate to 'true'", WARNING, { .has_opt = true, .opt = Option.POINTER_BOOL_CONVERSION }, PARSER },
	STRING_LITERAL_TO_BOOL { "implicit conversion turns string literal into bool: %s to %s", OFF, { .has_opt = true, .opt = Option.STRING_CONVERSION }, PARSER },
	CONSTANT_EXPRESSION_CONVERSION_NOT_ALLOWED { "cannot cast an object of type %s to %s", ERROR, {}, PARSER },
	SUGGEST_POINTER_FOR_INVALID_FP16 { "%s cannot have __fp16 type; did you forget * ?", ERROR, {}, PARSER },
	AUTO_TYPE_EXTENSION { "'__auto_type' is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_AUTO_TYPE, .extension = true }, PARSER },
	GNU_POINTER_ARITH { "arithmetic on pointers to void is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_POINTER_ARITH, .extension = true }, PARSER },
	AUTO_TYPE_NOT_ALLOWED { "'__auto_type' not allowed in %s", ERROR, {}, PARSER },
	AUTO_TYPE_REQUIRES_INITIALIZER { "declaration of variable '%s' with deduced type requires an initializer", ERROR, {}, PARSER },
	AUTO_TYPE_REQUIRES_SINGLE_DECLARATOR { "'__auto_type' may only be used with a single declarator", ERROR, {}, PARSER },
	AUTO_TYPE_REQUIRES_PLAIN_DECLARATOR { "'__auto_type' requires a plain identifier as declarator", ERROR, {}, PARSER },
	AUTO_TYPE_FROM_BITFIELD { "cannot use bit-field as '__auto_type' initializer", ERROR, {}, PARSER },
	AUTO_TYPE_ARRAY { "'%s' declared as array of '__auto_type'", ERROR, {}, PARSER },
	AUTO_TYPE_WITH_INIT_LIST { "cannot use '__auto_type' with initializer list", ERROR, {}, PARSER },
	MISSING_SEMICOLON { "expected ';' at end of declaration list", WARNING, { .extension = true }, PARSER },
	TENTATIVE_DEFINITION_INCOMPLETE { "tentative definition has type %s that is never completed", ERROR, {}, PARSER },
	FORWARD_DECLARATION_HERE { "forward declaration of %s", NOTE, {}, PARSER },
	GNU_UNION_CAST { "cast to union type is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_UNION_CAST, .extension = true }, PARSER },
	INVALID_UNION_CAST { "cast to union type from type %s not present in union", ERROR, {}, PARSER },
	CAST_TO_INCOMPLETE_TYPE { "cast to incomplete type %s", ERROR, {}, PARSER },
	GNU_ASM_DISABLED { "GNU-style inline assembly is disabled", ERROR, {}, PARSER },
	EXTENSION_TOKEN_USED { "extension used", OFF, { .has_opt = true, .opt = Option.LANGUAGE_EXTENSION_TOKEN, .extension = true }, PARSER },
	COMPLEX_COMPONENT_INIT { "complex initialization specifying real and imaginary components is an extension", OFF, { .has_opt = true, .opt = Option.COMPLEX_COMPONENT_INIT, .extension = true }, PARSER },
	COMPLEX_PREFIX_POSTFIX_OP { "ISO C does not support '++'/'--' on complex type %s", OFF, { .extension = true }, PARSER },
	NOT_FLOATING_TYPE { "argument type %s is not a real floating point type", ERROR, {}, PARSER },
	ELEMENTWISE_TYPE { "argument must be a vector%s (was '%s')", ERROR, {}, PARSER },
	NONTEMPORAL_ADDRESS_POINTER { "address argument to nontemporal builtin must be a pointer ('%s' invalid)", ERROR, {}, PARSER },
	NONTEMPORAL_ADDRESS_TYPE { "address argument to nontemporal builtin must be a pointer to integer, float, pointer, or a vector of such types ('%s' invalid)", ERROR, {}, PARSER },
	ATOMIC_ADDRESS_POINTER { "address argument to atomic builtin must be a pointer (%s invalid)", ERROR, {}, PARSER },
	C11_ATOMIC_ADDRESS_TYPE { "address argument to atomic operation must be a pointer to _Atomic type (%s invalid)", ERROR, {}, PARSER },
	ATOMIC_ADDRESS_TYPE { "address argument to atomic builtin must be a pointer to an integer or a pointer types ('%s' invalid)", ERROR, {}, PARSER },
	ARGUMENT_TYPES_DIFFER { "arguments are of different types (%s vs %s)", ERROR, {}, PARSER },
	EMPTY_CHAR_LITERAL_ERROR { "empty character constant", ERROR, {}, PARSER },
	UNTERMINATED_CHAR_LITERAL_ERROR { "missing terminating ' character", ERROR, {}, PARSER },
	DEF_NO_PROTO_DEPRECATED { "a function definition without a prototype is deprecated in all versions of C and is not supported in C23", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_NON_PROTOTYPE }, PARSER },
	PASSING_ARGS_TO_KR { "passing arguments to a function without a prototype is deprecated in all versions of C and is not supported in C23", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_NON_PROTOTYPE }, PARSER },
	UNKNOWN_TYPE_NAME { "unknown type name '%s'", ERROR, {}, PARSER },
	LABEL_COMPOUND_END { "label at end of compound statement is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	LABEL_DECL { "label followed by a declaration is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	GNU_LABEL_ATTR { "GNU-style attribute between label and declaration applies to the label", WARNING, { .has_opt = true, .opt = Option.LABEL_ATTRIBUTE, .extension = true }, PARSER },
	INVALID_COMPOUND_LITERAL_STORAGE_CLASS { "compound literal cannot have %s storage class", ERROR, {}, PARSER },
	REGISTER_ON_GLOBAL_COMPOUND_LITERAL { "file scope compound literal specifies 'register'", ERROR, {}, PARSER },
	IDENTIFIER_NOT_NORMALIZED { "'%s' is not in NFC", WARNING, {}, PARSER },
	C23_AUTO_SINGLE_DECLARATOR { "'auto' can only be used with a single declarator", ERROR, {}, PARSER },
	C23_AUTO_REQUIRES_INITIALIZER { "'auto' requires an initializer", ERROR, {}, PARSER },
	C23_AUTO_NOT_ALLOWED { "'auto' not allowed in %s", ERROR, {}, PARSER },
	C23_AUTO_WITH_INIT_LIST { "cannot use 'auto' with array", ERROR, {}, PARSER },
	C23_AUTO_ARRAY { "'%s' declared as array of 'auto'", ERROR, {}, PARSER },
	NEGATIVE_SHIFT_COUNT { "shift count is negative", WARNING, { .has_opt = true, .opt = Option.SHIFT_COUNT_NEGATIVE }, PARSER },
	TOO_BIG_SHIFT_COUNT { "shift count >= width of type", WARNING, { .has_opt = true, .opt = Option.SHIFT_COUNT_OVERFLOW }, PARSER },
	COMPLEX_CONJ { "ISO C does not support '~' for complex conjugation of %s", OFF, { .extension = true }, PARSER },
	OVERFLOW_BUILTIN_REQUIRES_INT { "operand argument to overflow builtin must be an integer (%s invalid)", ERROR, {}, PARSER },
	OVERFLOW_RESULT_REQUIRES_PTR { "result argument to overflow builtin must be a pointer to a non-const integer (%s invalid)", ERROR, {}, PARSER },
	AUTO_TYPE_SELF_INITIALIZED { "variable '%s' declared with deduced type '__auto_type' cannot appear in its own initializer", ERROR, {}, PARSER },
	NON_CONSTANT_INITIALIZER { "constexpr variable must be initialized by a constant expression", ERROR, {}, PARSER },
	STATIC_NON_CONSTANT_INITIALIZER { "initializer element is not a compile-time constant", ERROR, {}, PARSER },
	SUBTRACT_POINTERS_ZERO_ELEM_SIZE { "subtraction of pointers to type %s of zero size has undefined behavior", WARNING, { .has_opt = true, .opt = Option.POINTER_ARITH }, PARSER },
	PACKED_MEMBER_ADDRESS { "taking address of packed member '%s' of class or structure '%s' may result in an unaligned pointer value", WARNING, { .has_opt = true, .opt = Option.ADDRESS_OF_PACKED_MEMBER }, PARSER },
	GNU_MISSING_EQ_DESIGNATOR { "use of GNU 'missing =' extension in designator", WARNING, { .has_opt = true, .opt = Option.GNU_DESIGNATOR, .extension = true }, PARSER },
	EMPTY_IF_BODY { "if statement has empty body", WARNING, { .has_opt = true, .opt = Option.EMPTY_BODY }, PARSER },
	EMPTY_IF_BODY_NOTE { "put the semicolon on a separate line to silence this warning", NOTE, { .has_opt = true, .opt = Option.EMPTY_BODY }, PARSER },
	NULLABILITY_EXTENSION { "type nullability specifier '%s' is a Clang extension", OFF, { .has_opt = true, .opt = Option.NULLABILITY_EXTENSION, .extension = true }, PARSER },
	DUPLICATE_NULLABILITY { "duplicate nullability specifier '%s'", WARNING, {}, PARSER },
	ARRAY_NOT_ASSIGNABLE { "array type %s is not assignable", ERROR, {}, PARSER },
	NON_OBJECT_NOT_ASSIGNABLE { "non-object type %s is not assignable", ERROR, {}, PARSER },
	INCOMPLETE_TYPE_NOT_ASSIGNABLE { "incomplete type %s is not assignable", ERROR, {}, PARSER },
	CONST_VAR_ASSIGNMENT { "cannot assign to variable '%s' with const-qualified type %s", ERROR, {}, PARSER },
	DECLARED_CONST_HERE { "variable '%s' declared const here", NOTE, {}, PARSER },
	POINTER_BOUNDS_DECLARED_HERE { "pointer '%s' declared %s here", NOTE, {}, PARSER },
	MIXING_DECIMAL_FLOATS { "cannot mix operands of decimal floating and other floating types", ERROR, {}, PARSER },
	INVALID_ATTRIBUTE_LOCATION { "%s cannot appear here", ERROR, {}, PARSER },
	SINGLE_REQUIRES_ZERO_INDEX { "array subscript on single pointer must use a constant index of 0 to be in bounds", ERROR, {}, PARSER },
	POINTER_ARITH_SINGLE { "pointer arithmetic on single pointer is out of bounds; consider adding '__counted_by'", ERROR, {}, PARSER },
	BLOCKS_NOT_ENABLED { "blocks are not enabled", ERROR, {}, PARSER },
	BLOCKS_ARE_CLANG_EXTENSION { "blocks are a Clang extension", OFF, { .has_opt = true, .opt = Option.BLOCKS_EXTENSION, .extension = true }, PARSER },
	BLOCK_TO_NON_FUNCTION { "block pointer to non-function type is invalid", ERROR, {}, PARSER },
	C23_ATTRIBUTE { "[[]] attributes are a C23 extension", OFF, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true, .has_suppress_version = true, .suppress_version = C23 }, PARSER },
	BUILTIN_ARM_LDREX_STREX_INVALID_PTR_TYPE { "address argument to %s must be a pointer to integer, floating-point, or pointer (%s invalid)", ERROR, {}, PARSER },
	BUILTIN_ARM_LDREX_STREX_UNSUPPORTED { "%s is not supported on this architecture", ERROR, {}, PARSER },
	BUILTIN_ARM_LDREX_STREX_UNSUPPORTED_SIZE { "address argument to %s must be a pointer to %s byte type (%s invalid)", ERROR, {}, PARSER },
	TYPENAME_INVALID_SPECIFIER { "type name does not allow %s specifier to be specified", ERROR, {}, PARSER },
	C99_EXTENSION { "'%s' is a C99 extension", OFF, { .has_opt = true, .opt = Option.C99_EXTENSIONS, .extension = true }, PARSER },
	PRE_C11_COMPAT { "'%s' is incompatible with C standards before C11", OFF, { .has_opt = true, .opt = Option.PRE_C11_COMPAT }, PARSER },
	C11_EXTENSION { "'%s' is a C11 extension", OFF, { .has_opt = true, .opt = Option.C11_EXTENSIONS, .extension = true }, PARSER },
	C2Y_COUNTOF { "'_Countof' is a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, PARSER },
	PRE_C2Y_COUNTOF { "'_Countof' is incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, PARSER },
	INVALID_COUNTOF { "'_Countof' requires an argument of array type; %s is invalid", ERROR, {}, PARSER },
	PRE_C2Y_NAMED_BREAK { "named '%s' is incompatible with C standards before C2y", ERROR, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT }, PARSER },
	C2Y_NAMED_BREAK { "named '%s' is a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true }, PARSER },
	NAMED_BREAK_NOT_ENCLOSING { "'%s' label does not name an enclosing loop or switch", ERROR, {}, PARSER },
	NAMED_CONTINUE_SWITCH { "'continue' label refers to a switch statement", ERROR, {}, PARSER },
	// C3-only: number_value rejects a hex float without significand digits (`0x.p1`). Same text as clang.
	HEX_FLOAT_NO_SIGNIFICAND { "hexadecimal floating constant requires a significand", ERROR, {}, PARSER },
	// C3-only: a primary-expression production the port has not implemented.
	PRIMARY_UNAVAILABLE { "%s", ERROR, {}, PARSER },
	// C3-only: Parser.parse_translation_unit without a grammar handler.
	GRAMMAR_UNAVAILABLE { "parser grammar callback is unavailable", ERROR, {}, PARSER },
	// C3-only: promoted anonymous-record member name found in more than one anonymous member at the same level.
	AMBIGUOUS_MEMBER { "member '%s' is ambiguous; found in multiple anonymous struct or union members", ERROR, {}, PARSER },

	// ---- In-process linker (@link_err) ----
	// Linker diagnostic text. File-oriented entries take a path; parser errors also
	// take a reason so callers can report the failure without retaining
	// parser-specific state.
	CANNOT_OPEN { "cannot open %s", ERROR, {}, LINK },
	MALFORMED_ELF { "%s: malformed ELF file: %s", ERROR, {}, LINK },
	UNSUPPORTED_ELF { "%s: unsupported ELF file: %s", ERROR, {}, LINK },
	MALFORMED_ARCHIVE { "malformed archive %s: %s", ERROR, {}, LINK },
	UNSUPPORTED_ARCHIVE { "unsupported archive %s: %s", ERROR, {}, LINK },
	MALFORMED_SCRIPT { "%s:%d: %s", ERROR, {}, LINK },
	UNSUPPORTED_SCRIPT { "unsupported linker script %s: %s", ERROR, {}, LINK },
	MALFORMED_LD_ARGS { "in-process linker: %s", NOTE, {}, LINK },
	UNSUPPORTED_LD_ARG { "in-process linker does not support '%s'; using the system linker", NOTE, {}, LINK },
	LIBRARY_NOT_FOUND { "cannot find -l%s", ERROR, {}, LINK },
}
