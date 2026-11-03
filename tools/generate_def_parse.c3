// Owner: 12.1 def-parser.
// Parses the supported .def grammar (tools/builtins_schema.md, "Input grammar")
// into DefEntry records. Port of the parsing half of build/generate_def.zig,
// extended to parse the Zig-style property expressions explicitly instead of
// pasting them into generated source.
//
// Invariants:
// - Never evaluates or copies arbitrary text: anything outside the grammar is
//   a fault with `diag` filled in.
// - Output strings borrow `input` (see generate_def_schema.c3).
// - Rejects duplicate names, duplicate properties/attribute fields, unknown
//   properties/values, missing param_str, and `.features` in BuiltinBase groups.
module generate_def;
import std::collections::list, aro::builtin_properties;

<*
 Parses `input` (the whole .def file) for `group`. On a fault, `diag` holds
 the 1-based line and the offending text.
 Stage-0 stub: returns an empty file so the Bazel rule already produces
 (empty) tables.
*>
fn DefFile? parse_def(Allocator a, String input, BuiltinGroup group, DefDiag* diag)
{
	DefFile file;
	file.init(a, group);
	return file;
}
