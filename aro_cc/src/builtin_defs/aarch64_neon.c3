// Converted from Builtins/aarch64_neon.def.
// Snapshot retained after the one-off generator was removed; edit this C3 table directly.
module aro::frontend::c::builtin_defs::aarch64_neon;
import aro::frontend::c::builtin_properties;

enum Builtin : ushort (String name, BuiltinRecord record)
{
	TAG___BUILTIN_SVE_SVDUP_NEONQ_BF16 { "__builtin_sve_svdup_neonq_bf16", { "q8yV8y", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_F16 { "__builtin_sve_svdup_neonq_f16", { "q8hV8h", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_F32 { "__builtin_sve_svdup_neonq_f32", { "q4fV4f", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_F64 { "__builtin_sve_svdup_neonq_f64", { "q2dV2d", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_S16 { "__builtin_sve_svdup_neonq_s16", { "q8sV8s", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_S32 { "__builtin_sve_svdup_neonq_s32", { "q4iV4i", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_S64 { "__builtin_sve_svdup_neonq_s64", { "q4iV4i", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_S8 { "__builtin_sve_svdup_neonq_s8", { "q16ScV16Sc", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_U16 { "__builtin_sve_svdup_neonq_u16", { "q8UsV8Us", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_U32 { "__builtin_sve_svdup_neonq_u32", { "q4UiV4Ui", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_U64 { "__builtin_sve_svdup_neonq_u64", { "q2UWiV2UWi", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVDUP_NEONQ_U8 { "__builtin_sve_svdup_neonq_u8", { "q16UcV16Uc", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_BF16 { "__builtin_sve_svget_neonq_bf16", { "V8yq8y", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_F16 { "__builtin_sve_svget_neonq_f16", { "V8hq8h", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_F32 { "__builtin_sve_svget_neonq_f32", { "V4fq4f", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_F64 { "__builtin_sve_svget_neonq_f64", { "V2dq2d", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_S16 { "__builtin_sve_svget_neonq_s16", { "V8sq8s", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_S32 { "__builtin_sve_svget_neonq_s32", { "V4iq4i", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_S64 { "__builtin_sve_svget_neonq_s64", { "V2Wiq2Wi", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_S8 { "__builtin_sve_svget_neonq_s8", { "V16Scq16Sc", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_U16 { "__builtin_sve_svget_neonq_u16", { "V16Usq16Us", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_U32 { "__builtin_sve_svget_neonq_u32", { "V4Uiq4Ui", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_U64 { "__builtin_sve_svget_neonq_u64", { "V2UWiq2UWi", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVGET_NEONQ_U8 { "__builtin_sve_svget_neonq_u8", { "V16Ucq16Uc", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_BF16 { "__builtin_sve_svset_neonq_bf16", { "q8yq8yV8y", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_F16 { "__builtin_sve_svset_neonq_f16", { "q8hq8hV8h", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_F32 { "__builtin_sve_svset_neonq_f32", { "q4fq4fV4f", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_F64 { "__builtin_sve_svset_neonq_f64", { "q2dq2dV2d", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_S16 { "__builtin_sve_svset_neonq_s16", { "q8sq8sV8s", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_S32 { "__builtin_sve_svset_neonq_s32", { "q4iq4iV4i", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_S64 { "__builtin_sve_svset_neonq_s64", { "q2Wiq2WiV2Wi", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_S8 { "__builtin_sve_svset_neonq_s8", { "q16Scq16ScV16Sc", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_U16 { "__builtin_sve_svset_neonq_u16", { "q8Usq8UsV8s", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_U32 { "__builtin_sve_svset_neonq_u32", { "q4Uiq4UiV4Ui", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_U64 { "__builtin_sve_svset_neonq_u64", { "q2UWiq2UWiV2UWi", ALL_LANGUAGES, NONE, {  }, "sve" } },
	TAG___BUILTIN_SVE_SVSET_NEONQ_U8 { "__builtin_sve_svset_neonq_u8", { "q16Ucq16UcV16Uc", ALL_LANGUAGES, NONE, {  }, "sve" } },
}

const BuiltinGroup GROUP = AARCH64_NEON;
const ushort COUNT = Builtin::values.len;
String[COUNT] names @private = builtin_properties::@builtin_names(Builtin);
const String[] NAMES = &names;
BuiltinRecord[COUNT] records @private = builtin_properties::@builtin_records(Builtin);
const BuiltinRecord[] RECORDS = &records;
const usz SHORTEST_NAME = builtin_properties::@builtin_name_length(Builtin, false);
const usz LONGEST_NAME = builtin_properties::@builtin_name_length(Builtin, true);


$expand(builtin_properties::@builtin_tags(Builtin));
