// Converted from Builtins/bpf.def.
// Snapshot retained after the one-off generator was removed; edit this C3 table directly.
module aro::frontend::c::builtin_defs::bpf;
import aro::frontend::c::builtin_properties;

enum Builtin : ushort (String name, BuiltinRecord record)
{
	TAG___BUILTIN_BTF_TYPE_ID { "__builtin_btf_type_id", { "LUi.", ALL_LANGUAGES, NONE, { .custom_typecheck = true }, "" } },
	TAG___BUILTIN_PRESERVE_ENUM_VALUE { "__builtin_preserve_enum_value", { "Li.", ALL_LANGUAGES, NONE, { .custom_typecheck = true }, "" } },
	TAG___BUILTIN_PRESERVE_FIELD_INFO { "__builtin_preserve_field_info", { "Ui.", ALL_LANGUAGES, NONE, { .custom_typecheck = true }, "" } },
	TAG___BUILTIN_PRESERVE_TYPE_INFO { "__builtin_preserve_type_info", { "LUi.", ALL_LANGUAGES, NONE, { .custom_typecheck = true }, "" } },
}

const BuiltinGroup GROUP = BPF;
const ushort COUNT = Builtin::values.len;
String[COUNT] names @private = builtin_properties::@builtin_names(Builtin);
const String[] NAMES = &names;
BuiltinRecord[COUNT] records @private = builtin_properties::@builtin_records(Builtin);
const BuiltinRecord[] RECORDS = &records;
const usz SHORTEST_NAME = builtin_properties::@builtin_name_length(Builtin, false);
const usz LONGEST_NAME = builtin_properties::@builtin_name_length(Builtin, true);


$expand(builtin_properties::@builtin_tags(Builtin));
