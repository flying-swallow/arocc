// Owner: plan 12 stage 0 (contract; frozen). Changes go through the integrator.
// Language-neutral record schema shared by the .def parser
// (tools/generate_def_parse.c3, 12.1 def-parser) and the table emitter
// (tools/generate_def.c3, 12.2 table-gen). Grammar and output layout:
// tools/builtins_schema.md.
//
// Invariants:
// - The generator links only std plus src/c3/builtin_properties.c3 (never
//   aro_c3_lib, which depends on the generator's output).
// - A DefFile borrows the input buffer: every String in it (names, param_str,
//   features, DefDiag.detail) is a slice of `input` and is valid only while
//   that buffer lives. Nothing is copied.
// - entries are in file order; the parser has already rejected duplicates,
//   so the emitter only sorts.
module generate_def;
import std::collections::list, aro::builtin_properties;

// Parse errors. DefDiag carries the line and the offending text.
<* Text that matches no supported construct (incl. Zig `const`/`pub const` header lines). *>
excuse SYNTAX_ERROR;
<* A property line before the first builtin name (Zig: "property not attached to a value"). *>
excuse ORPHAN_PROPERTY;
<* The same builtin name twice in one file (Zig: "duplicate value"). *>
excuse DUPLICATE_NAME;
<* The same property, or the same attribute field, twice on one builtin. *>
excuse DUPLICATE_PROPERTY;
<* A property name other than param_str/attributes/header/language/features. *>
excuse UNKNOWN_PROPERTY;
<* An unknown header / language / attribute field / format_kind name, or a value of the wrong kind. *>
excuse UNKNOWN_VALUE;
<* A builtin without `.param_str` (no default in Zig BuiltinBase/BuiltinTarget). *>
excuse MISSING_PARAM_STR;
<* `.features` in a group whose Zig record type is BuiltinBase (BuiltinGroup.has_features == false). *>
excuse FEATURES_NOT_ALLOWED;
<* More than 65535 builtins (tag index is a u16). *>
excuse TOO_MANY_BUILTINS;

<* One parsed builtin: name plus the language-neutral record. *>
struct DefEntry
{
	String name;
	BuiltinRecord record;
	<* 1-based line of the name. *>
	uint line;
}

<* A parsed .def file. *>
struct DefFile
{
	BuiltinGroup group;
	List{DefEntry} entries;
}

fn void DefFile.init(&self, Allocator a, BuiltinGroup group)
{
	*self = { .group = group };
	self.entries.init(a);
}

fn void DefFile.free(&self)
{
	self.entries.free();
	*self = {};
}

<* Where parsing failed. detail is a slice of the input (the offending line or token). *>
struct DefDiag
{
	uint line;
	String detail;
}
