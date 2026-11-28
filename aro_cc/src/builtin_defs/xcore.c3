// Converted from Builtins/xcore.def.
// Snapshot retained after the one-off generator was removed; edit this C3 table directly.
module aro::frontend::c::builtin_defs::xcore;
import aro::frontend::c::builtin_properties;

enum Builtin : ushort (String name, BuiltinRecord record)
{
	TAG___BUILTIN_BITREV { "__builtin_bitrev", { "UiUi", ALL_LANGUAGES, NONE, { .is_const = true }, "" } },
	TAG___BUILTIN_GETID { "__builtin_getid", { "Si", ALL_LANGUAGES, NONE, { .is_const = true }, "" } },
	TAG___BUILTIN_GETPS { "__builtin_getps", { "UiUi", ALL_LANGUAGES, NONE, {  }, "" } },
	TAG___BUILTIN_SETPS { "__builtin_setps", { "vUiUi", ALL_LANGUAGES, NONE, {  }, "" } },
}

const BuiltinGroup GROUP = XCORE;
const ushort COUNT = Builtin::values.len;
String[COUNT] names @private = builtin_properties::@builtin_names(Builtin);
const String[] NAMES = &names;
BuiltinRecord[COUNT] records @private = builtin_properties::@builtin_records(Builtin);
const BuiltinRecord[] RECORDS = &records;
const usz SHORTEST_NAME = builtin_properties::@builtin_name_length(Builtin, false);
const usz LONGEST_NAME = builtin_properties::@builtin_name_length(Builtin, true);


$expand(builtin_properties::@builtin_tags(Builtin));
