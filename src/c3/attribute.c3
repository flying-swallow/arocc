// Port of src/aro/Attribute.zig: the attribute value (`Attribute`), its
// argument payloads (`Args` / `Tag`), `Syntax` and the vendor-namespaced
// attribute names (`Namespaced`, `fromString`, `fromKeyword`,
// `hasIdentifierArg`, `normalize`) — plan 16 stage 1 agent 16.5
// `attributes`. Attribute/Wip.zig (argument parsing and application) and
// Attribute/Diagnostic.zig are ported with the parser (plan 20).
//
// Representation:
//  - Zig `Args` (union(enum)) is `AttributeArgs`: an `AttributeTag` plus an
//    anonymous union with one member per non-void payload. Tags whose Zig
//    payload is `void` (and `patchable_function_entry`, an empty struct)
//    have no member. The full tag -> member table is docs/c3-tree-tags.md
//    section 4.
//  - Zig `?T` payload fields are `has_<field>` + `<field>`; Zig field
//    defaults are listed on each struct (C3 has no field defaults).
//  - Slices (`String`, `Value[]`, `uint[]`) are borrowed: from the attribute
//    map's `extra` storage (`AttributeMap.get`) or from the caller.
//  - Zig enums carrying `opts.enum_kind` keep that kind in their doc
//    comment ("identifier" or "string" argument); `name` is the Zig spelling.
//  - Zig `Namespaced` (union(enum)) is `Namespaced`: an `AttrNamespace` plus
//    an anonymous union of the per-vendor enums (ARO has no members).
//
// Attribute payload types and name resolution are implemented here. Parser
// argument construction and application remain in the later parser port.
module aro::attribute;
import aro::tokens, aro::tokenizer, aro::value, aro::target, aro::type_store;

<* Zig `null` from `Namespaced.fromString` / an opts string map lookup. *>
excuse UNKNOWN_ATTRIBUTE;

<* Zig `Attribute.Tag` (= std.meta.Tag(Args)), in Zig order; `name` is the Zig tag name. *>
enum AttributeTag : char (String name)
{
	ACCESS { "access" },
	ALIAS { "alias" },
	ALIGNMENT { "alignment" },
	ALLOC_ALIGN { "alloc_align" },
	ALLOC_SIZE { "alloc_size" },
	ALLOCATOR { "allocator" },
	ALWAYS_INLINE { "always_inline" },
	APPDOMAIN { "appdomain" },
	ARTIFICIAL { "artificial" },
	ASSUME_ALIGNED { "assume_aligned" },
	CLEANUP { "cleanup" },
	CODE_SEG { "code_seg" },
	COLD { "cold" },
	COMMON { "common" },
	CONST { "const" },
	CONSTRUCTOR { "constructor" },
	COPY { "copy" },
	DEPRECATED { "deprecated" },
	DESIGNATED_INIT { "designated_init" },
	DESTRUCTOR { "destructor" },
	DLLEXPORT { "dllexport" },
	DLLIMPORT { "dllimport" },
	ERROR { "error" },
	EXTERNALLY_VISIBLE { "externally_visible" },
	FALLTHROUGH { "fallthrough" },
	FLATTEN { "flatten" },
	FORMAT { "format" },
	FORMAT_ARG { "format_arg" },
	GNU_INLINE { "gnu_inline" },
	HOT { "hot" },
	IFUNC { "ifunc" },
	INTERRUPT { "interrupt" },
	INTERRUPT_HANDLER { "interrupt_handler" },
	JITINTRINSIC { "jitintrinsic" },
	LEAF { "leaf" },
	MALLOC { "malloc" },
	MAY_ALIAS { "may_alias" },
	MODE { "mode" },
	NAKED { "naked" },
	NO_ADDRESS_SAFETY_ANALYSIS { "no_address_safety_analysis" },
	NO_ICF { "no_icf" },
	NO_INSTRUMENT_FUNCTION { "no_instrument_function" },
	NO_PROFILE_INSTRUMENT_FUNCTION { "no_profile_instrument_function" },
	NO_REORDER { "no_reorder" },
	NO_SANITIZE { "no_sanitize" },
	NO_SANITIZE_ADDRESS { "no_sanitize_address" },
	NO_SANITIZE_COVERAGE { "no_sanitize_coverage" },
	NO_SANITIZE_THREAD { "no_sanitize_thread" },
	NO_SANITIZE_UNDEFINED { "no_sanitize_undefined" },
	NO_SPLIT_STACK { "no_split_stack" },
	NO_STACK_LIMIT { "no_stack_limit" },
	NO_STACK_PROTECTOR { "no_stack_protector" },
	NOALIAS { "noalias" },
	NOCLONE { "noclone" },
	NOCOMMON { "nocommon" },
	WARN_UNUSED_RESULT { "warn_unused_result" },
	NOINIT { "noinit" },
	NOINLINE { "noinline" },
	NOIPA { "noipa" },
	NONNULL { "nonnull" },
	NONSTRING { "nonstring" },
	NOPLT { "noplt" },
	NORETURN { "noreturn" },
	NOTHROW { "nothrow" },
	OPTIMIZE { "optimize" },
	PACKED { "packed" },
	PATCHABLE_FUNCTION_ENTRY { "patchable_function_entry" },
	PERSISTENT { "persistent" },
	PROCESS { "process" },
	PURE { "pure" },
	REPRODUCIBLE { "reproducible" },
	RETAIN { "retain" },
	RETURNS_NONNULL { "returns_nonnull" },
	RETURNS_TWICE { "returns_twice" },
	SCALAR_STORAGE_ORDER { "scalar_storage_order" },
	SECTION { "section" },
	SELECTANY { "selectany" },
	SENTINEL { "sentinel" },
	SIMD { "simd" },
	SINGLE { "single" },
	SPECTRE { "spectre" },
	STACK_PROTECT { "stack_protect" },
	SYMVER { "symver" },
	TARGET { "target" },
	TARGET_CLONES { "target_clones" },
	TLS_MODEL { "tls_model" },
	TRANSPARENT_UNION { "transparent_union" },
	UNAVAILABLE { "unavailable" },
	UNSAFE_INDEXABLE { "unsafe_indexable" },
	UNSEQUENCED { "unsequenced" },
	UNUSED { "unused" },
	USED { "used" },
	UUID { "uuid" },
	VISIBILITY { "visibility" },
	WARN_IF_NOT_ALIGNED { "warn_if_not_aligned" },
	WARNING { "warning" },
	WEAK { "weak" },
	WEAKREF { "weakref" },
	ZERO_CALL_USED_REGS { "zero_call_used_regs" },
	ASM_LABEL { "asm_label" },
	UNALIGNED { "unaligned" },
	INTERNAL_LINKAGE { "internal_linkage" },
	AVAILABILITY { "availability" },
	OPTNONE { "optnone" },
}

// ---------------------------------------------------------------------------
// Payload enums
// ---------------------------------------------------------------------------

<* `access.access_mode` (enum_kind identifier). *>
enum AccessMode : char (String name)
{
	READ_ONLY { "read_only" },
	READ_WRITE { "read_write" },
	WRITE_ONLY { "write_only" },
	NONE { "none" },
}

<* `format.archetype` (enum_kind identifier). *>
enum FormatArchetype : char (String name)
{
	PRINTF { "printf" },
	SCANF { "scanf" },
	STRFTIME { "strftime" },
	STRFMON { "strfmon" },
}

<* `mode` (enum_kind identifier). *>
enum AttrMode : char (String name)
{
	BYTE { "byte" },
	WORD { "word" },
	POINTER { "pointer" },
	BI { "BI" },
	QI { "QI" },
	HI { "HI" },
	PSI { "PSI" },
	SI { "SI" },
	PDI { "PDI" },
	DI { "DI" },
	TI { "TI" },
	OI { "OI" },
	XI { "XI" },
	QF { "QF" },
	HF { "HF" },
	TQF { "TQF" },
	SF { "SF" },
	DF { "DF" },
	XF { "XF" },
	SD { "SD" },
	DD { "DD" },
	TD { "TD" },
	TF { "TF" },
	QQ { "QQ" },
	HQ { "HQ" },
	SQ { "SQ" },
	DQ { "DQ" },
	TQ { "TQ" },
	UQQ { "UQQ" },
	UHQ { "UHQ" },
	USQ { "USQ" },
	UDQ { "UDQ" },
	UTQ { "UTQ" },
	HA { "HA" },
	SA { "SA" },
	DA { "DA" },
	TA { "TA" },
	UHA { "UHA" },
	USA { "USA" },
	UDA { "UDA" },
	UTA { "UTA" },
	CC { "CC" },
	BLK { "BLK" },
	VOID { "VOID" },
	QC { "QC" },
	HC { "HC" },
	SC { "SC" },
	DC { "DC" },
	XC { "XC" },
	TC { "TC" },
	CQI { "CQI" },
	CHI { "CHI" },
	CSI { "CSI" },
	CDI { "CDI" },
	CTI { "CTI" },
	COI { "COI" },
	CPSI { "CPSI" },
	BND32 { "BND32" },
	BND64 { "BND64" },
}

<* `scalar_storage_order` (enum_kind string). *>
enum ScalarStorageOrder : char (String name)
{
	LITTLE_ENDIAN { "little-endian" },
	BIG_ENDIAN { "big-endian" },
}

<* `simd.mask` (enum_kind string). *>
enum SimdMask : char (String name)
{
	NOTINBRANCH { "notinbranch" },
	INBRANCH { "inbranch" },
}

<* `spectre` (enum_kind identifier). *>
enum Spectre : char (String name)
{
	NOMITIGATION { "nomitigation" },
}

<* `tls_model.model` (enum_kind string). *>
enum TlsModel : char (String name)
{
	GLOBAL_DYNAMIC { "global-dynamic" },
	LOCAL_DYNAMIC { "local-dynamic" },
	INITIAL_EXEC { "initial-exec" },
	LOCAL_EXEC { "local-exec" },
}

<* `zero_call_used_regs.choice` (enum_kind string). *>
enum ZeroCallUsedRegs : char (String name)
{
	SKIP { "skip" },
	USED { "used" },
	USED_GPR { "used-gpr" },
	USED_ARG { "used-arg" },
	USED_GPR_ARG { "used-gpr-arg" },
	ALL { "all" },
	ALL_GPR { "all-gpr" },
	ALL_ARG { "all-arg" },
	ALL_GPR_ARG { "all-gpr-arg" },
}

<* `availability.platform` (enum_kind identifier). *>
enum AvailabilityPlatform : char (String name)
{
	ANDROID { "android" },
	FUCHSIA { "fuchsia" },
	IOS { "ios" },
	MACOS { "macos" },
	TVOS { "tvos" },
	WATCHOS { "watchos" },
	DRIVERKIT { "driverkit" },
	IOS_APP_EXTENSION { "ios_app_extension" },
	MACOS_APP_EXTENSION { "macos_app_extension" },
	TVOS_APP_EXTENSION { "tvos_app_extension" },
	WATCHOS_APP_EXTENSION { "watchos_app_extension" },
	MACCATALYST { "maccatalyst" },
	MACCATALYST_APP_EXTENSION { "maccatalyst_app_extension" },
	XROS { "xros" },
	XROS_APP_EXTENSION { "xros_app_extension" },
	SWIFT { "swift" },
	SHADERMODEL { "shadermodel" },
	OHOS { "ohos" },
}

<*
 Zig `Args.Visibility` (enum_kind string). The Zig opts map also accepts
 "internal" as HIDDEN (`visibility_from_string`).
*>
enum Visibility : char (String name)
{
	DEFAULT { "default" },
	HIDDEN { "hidden" },
	PROTECTED { "protected" },
}

<* `optimize` union(enum) tag. *>
enum OptimizeKind : char
{
	INDEX,
	FEATURES,
}

// ---------------------------------------------------------------------------
// Payload structs (Zig field order)
// ---------------------------------------------------------------------------

<* ACCESS. Zig default: size_index = null. *>
struct ArgsAccess
{
	AccessMode access_mode;
	uint ref_index;
	bool has_size_index;
	uint size_index;
}

<* ALIAS (Zig field `alias`, a C3 keyword). *>
struct ArgsAlias
{
	Value alias_value;
}

<* ALIGNMENT (Zig `?u32`) and WARN_IF_NOT_ALIGNED (`struct { alignment: ?u32 }`). *>
struct ArgsAlignment
{
	bool has_alignment;
	uint alignment;
}

<* ALLOC_ALIGN *>
struct ArgsAllocAlign
{
	uint position;
}

<* ALLOC_SIZE. Zig default: position_2 = null. *>
struct ArgsAllocSize
{
	uint position_1;
	bool has_position_2;
	uint position_2;
}

<* ASSUME_ALIGNED. Zig default: offset = null. *>
struct ArgsAssumeAligned
{
	bool has_alignment;
	uint alignment;
	bool has_offset;
	uint offset;
}

<* CLEANUP and COPY. *>
struct ArgsFunction
{
	NodeIndex function;
}

<* CODE_SEG *>
struct ArgsCodeSeg
{
	Value segname;
}

<* CONSTRUCTOR and DESTRUCTOR. Zig default: priority = 65535 (`DEFAULT_PRIORITY`). *>
struct ArgsPriority
{
	ushort priority;
}

const ushort DEFAULT_PRIORITY = 65535;

<* DEPRECATED. Zig defaults: msg = null, replacement = null. *>
struct ArgsDeprecated
{
	bool has_msg;
	String msg;
	bool has_replacement;
	String replacement;
}

<* FORMAT *>
struct ArgsFormat
{
	FormatArchetype archetype;
	uint string_index;
	uint first_to_check;
}

<* IFUNC *>
struct ArgsIfunc
{
	Value resolver;
}

<* WARN_UNUSED_RESULT and UNAVAILABLE (Zig `?[]const u8`). *>
struct ArgsOptMsg
{
	bool has_msg;
	String msg;
}

<* OPTIMIZE (Zig `union(enum) { index: u32, features: []const u8 }`). *>
struct ArgsOptimize
{
	OptimizeKind kind;
	uint index;
	String features;
}

<* SENTINEL. Zig default: position = 0. *>
struct ArgsSentinel
{
	uint position;
}

<* SIMD. Zig default: mask = null. *>
struct ArgsSimd
{
	bool has_mask;
	SimdMask mask;
}

<* SYMVER *>
struct ArgsSymver
{
	Value version;
}

<* TARGET and TARGET_CLONES. *>
struct ArgsOptions
{
	Value[] options;
}

<* TLS_MODEL *>
struct ArgsTlsModel
{
	TlsModel model;
}

<* UUID *>
struct ArgsUuid
{
	Value uuid;
}

<* WEAKREF. Zig default: target = null. *>
struct ArgsWeakref
{
	bool has_target;
	Value target;
}

<* ZERO_CALL_USED_REGS *>
struct ArgsZeroCallUsedRegs
{
	ZeroCallUsedRegs choice;
}

<* ASM_LABEL *>
struct ArgsAsmLabel
{
	Value name;
}

<*
 AVAILABILITY. Zig `?std.SemanticVersion` is has_x + `target::SemVer`.
 Zig defaults: versions/message/replacement null, unavailable = strict =
 false, priority = 0.
*>
struct ArgsAvailability
{
	AvailabilityPlatform platform;
	bool has_introduced;
	SemVer introduced;
	bool has_deprecated;
	SemVer deprecated;
	bool has_obsoleted;
	SemVer obsoleted;
	bool unavailable;
	bool strict;
	bool has_message;
	Value message;
	bool has_replacement;
	Value replacement;
	uint priority;
}

<*
 Zig `Attribute.Args`. Read the member that `tag` selects; tags without a
 member (void payloads) carry no data.
*>
struct AttributeArgs
{
	AttributeTag tag;
	union
	{
		ArgsAccess access;
		ArgsAlias alias_args;
		ArgsAlignment alignment;
		ArgsAllocAlign alloc_align;
		ArgsAllocSize alloc_size;
		ArgsAssumeAligned assume_aligned;
		ArgsFunction cleanup;
		ArgsCodeSeg code_seg;
		ArgsPriority constructor;
		ArgsFunction copy;
		ArgsDeprecated deprecated;
		ArgsPriority destructor;
		<* ERROR: the message. *>
		String error_msg;
		ArgsFormat format;
		uint format_arg;
		ArgsIfunc ifunc;
		AttrMode mode;
		Value[] no_sanitize;
		ArgsOptMsg warn_unused_result;
		uint[] nonnull;
		ArgsOptimize optimize;
		ScalarStorageOrder scalar_storage_order;
		String section;
		ArgsSentinel sentinel;
		ArgsSimd simd;
		Spectre spectre;
		ArgsSymver symver;
		ArgsOptions target;
		ArgsOptions target_clones;
		ArgsTlsModel tls_model;
		ArgsOptMsg unavailable;
		ArgsUuid uuid;
		Visibility visibility;
		ArgsAlignment warn_if_not_aligned;
		String warning;
		ArgsWeakref weakref;
		ArgsZeroCallUsedRegs zero_call_used_regs;
		ArgsAsmLabel asm_label;
		ArgsAvailability availability;
	}
}

// ---------------------------------------------------------------------------
// Syntax and namespaced names
// ---------------------------------------------------------------------------

<* Zig `Attribute.Syntax`. *>
enum AttributeSyntax : char (String name)
{
	STANDARD { "standard" },
	GNU { "gnu" },
	DECLSPEC { "declspec" },
	KEYWORD { "keyword" },
}

<* Zig `Namespaced` union tag; `name` is printed by dump for STANDARD syntax. *>
enum AttrNamespace : char (String name)
{
	STANDARD { "standard" },
	GNU { "gnu" },
	CLANG { "clang" },
	ARO { "aro" },
	DECLSPEC { "declspec" },
	MSVC { "msvc" },
	RISCV { "riscv" },
	KEYWORD { "keyword" },
}

<* Zig `Namespaced.Standard`. *>
enum AttrStandard : char (String name)
{
	DEPRECATED { "deprecated" },
	FALLTHROUGH { "fallthrough" },
	MAYBE_UNUSED { "maybe_unused" },
	NODISCARD { "nodiscard" },
	NORETURN { "noreturn" },
	_NORETURN { "_Noreturn" },
	REPRODUCIBLE { "reproducible" },
	UNSEQUENCED { "unsequenced" },
}

<* Zig `Namespaced.Standard.Vendors`. *>
enum StandardVendor : char (String name)
{
	ARO { "aro" },
	CLANG { "clang" },
	GNU { "gnu" },
	MSVC { "msvc" },
	RISCV { "riscv" },
}

<* Zig `Namespaced.Gnu` ("Not supported by Clang" comments are in Attribute.zig). *>
enum AttrGnu : char (String name)
{
	ACCESS { "access" },
	ALIAS { "alias" },
	ALIGNED { "aligned" },
	ALLOC_ALIGN { "alloc_align" },
	ALLOC_SIZE { "alloc_size" },
	ALWAYS_INLINE { "always_inline" },
	ARTIFICIAL { "artificial" },
	ASSUME_ALIGNED { "assume_aligned" },
	CDECL { "cdecl" },
	CLEANUP { "cleanup" },
	COLD { "cold" },
	COMMON { "common" },
	__CONST { "__const" },
	CONST { "const" },
	CONSTRUCTOR { "constructor" },
	COPY { "copy" },
	DEPRECATED { "deprecated" },
	DESIGNATED_INIT { "designated_init" },
	DESTRUCTOR { "destructor" },
	DLLEXPORT { "dllexport" },
	DLLIMPORT { "dllimport" },
	ERROR { "error" },
	EXTERNALLY_VISIBLE { "externally_visible" },
	FALLTHROUGH { "fallthrough" },
	FASTCALL { "fastcall" },
	FLATTEN { "flatten" },
	FORMAT_ARG { "format_arg" },
	FORMAT { "format" },
	GNU_INLINE { "gnu_inline" },
	HOT { "hot" },
	IFUNC { "ifunc" },
	INTERRUPT_HANDLER { "interrupt_handler" },
	INTERRUPT { "interrupt" },
	LEAF { "leaf" },
	MALLOC { "malloc" },
	MAY_ALIAS { "may_alias" },
	MODE { "mode" },
	MS_ABI { "ms_abi" },
	NO_ADDRESS_SAFETY_ANALYSIS { "no_address_safety_analysis" },
	NO_ICF { "no_icf" },
	NO_INSTRUMENT_FUNCTION { "no_instrument_function" },
	NO_PROFILE_INSTRUMENT_FUNCTION { "no_profile_instrument_function" },
	NO_REORDER { "no_reorder" },
	NO_SANITIZE_ADDRESS { "no_sanitize_address" },
	NO_SANITIZE_COVERAGE { "no_sanitize_coverage" },
	NO_SANITIZE_THREAD { "no_sanitize_thread" },
	NO_SANITIZE_UNDEFINED { "no_sanitize_undefined" },
	NO_SANITIZE { "no_sanitize" },
	NO_SPLIT_STACK { "no_split_stack" },
	NO_STACK_LIMIT { "no_stack_limit" },
	NO_STACK_PROTECTOR { "no_stack_protector" },
	NOCLONE { "noclone" },
	NOCOMMON { "nocommon" },
	NOINIT { "noinit" },
	NOINLINE { "noinline" },
	NOIPA { "noipa" },
	NONNULL { "nonnull" },
	NONSTRING { "nonstring" },
	NOPLT { "noplt" },
	NORETURN { "noreturn" },
	NOTHROW { "nothrow" },
	OPTIMIZE { "optimize" },
	PACKED { "packed" },
	PATCHABLE_FUNCTION_ENTRY { "patchable_function_entry" },
	PCS { "pcs" },
	PERSISTENT { "persistent" },
	PURE { "pure" },
	REGCALL { "regcall" },
	REGPARM { "regparm" },
	RETAIN { "retain" },
	RETURNS_NONNULL { "returns_nonnull" },
	RETURNS_TWICE { "returns_twice" },
	RISCV_RVV_VECTOR_BITS { "riscv_rvv_vector_bits" },
	SCALAR_STORAGE_ORDER { "scalar_storage_order" },
	SECTION { "section" },
	SELECTANY { "selectany" },
	SENTINEL { "sentinel" },
	SIMD { "simd" },
	STACK_PROTECT { "stack_protect" },
	STDCALL { "stdcall" },
	SYMVER { "symver" },
	SYSV_ABI { "sysv_abi" },
	TARGET_CLONES { "target_clones" },
	TARGET { "target" },
	THISCALL { "thiscall" },
	TLS_MODEL { "tls_model" },
	TRANSPARENT_UNION { "transparent_union" },
	UNUSED { "unused" },
	USED { "used" },
	VECTOR_SIZE { "vector_size" },
	VISIBILITY { "visibility" },
	WARN_IF_NOT_ALIGNED { "warn_if_not_aligned" },
	WARN_UNUSED_RESULT { "warn_unused_result" },
	WARN_UNUSED { "warn_unused" },
	WARNING { "warning" },
	WEAK { "weak" },
	WEAKREF { "weakref" },
	ZERO_CALL_USED_REGS { "zero_call_used_regs" },
}

<* Zig `Namespaced.Clang`. *>
enum AttrClang : char (String name)
{
	AARCH64_SVE_PCS { "aarch64_sve_pcs" },
	AARCH64_VECTOR_PCS { "aarch64_vector_pcs" },
	ADDRESS_SPACE { "address_space" },
	ALWAYS_INLINE { "always_inline" },
	ARM_SVE_VECTOR_BITS { "arm_sve_vector_bits" },
	AVAILABILITY { "availability" },
	EXT_VECTOR_TYPE { "ext_vector_type" },
	INTERNAL_LINKAGE { "internal_linkage" },
	MATRIX_TYPE { "matrix_type" },
	NEON_POLYVECTOR_TYPE { "neon_polyvector_type" },
	NEON_VECTOR_TYPE { "neon_vector_type" },
	NO_SANITIZE_ADDRESS { "no_sanitize_address" },
	NO_SANITIZE_MEMORY { "no_sanitize_memory" },
	NO_SANITIZE { "no_sanitize" },
	NO_STACK_PROTECTOR { "no_stack_protector" },
	NODEREF { "noderef" },
	NOINLINE { "noinline" },
	OPTNONE { "optnone" },
	RISCV_VECTOR_CC { "riscv_vector_cc" },
	RISCV_VLS_CC { "riscv_vls_cc" },
	SINGLE { "single" },
	UNAVAILABLE { "unavailable" },
	UNSAFE_INDEXABLE { "unsafe_indexable" },
	VECTORCALL { "vectorcall" },
	WARN_UNUSED_RESULT { "warn_unused_result" },
}

<* Zig `Namespaced.Declspec`. *>
enum AttrDeclspec : char (String name)
{
	ALIGN { "align" },
	ALLOCATE { "allocate" },
	ALLOCATOR { "allocator" },
	APPDOMAIN { "appdomain" },
	CODE_SEG { "code_seg" },
	DEPRECATED { "deprecated" },
	DLLEXPORT { "dllexport" },
	DLLIMPORT { "dllimport" },
	JITINTRINSIC { "jitintrinsic" },
	NAKED { "naked" },
	NOALIAS { "noalias" },
	NOINLINE { "noinline" },
	NORETURN { "noreturn" },
	PROCESS { "process" },
	RESTRICT { "restrict" },
	SAFEBUFFERS { "safebuffers" },
	SELECTANY { "selectany" },
	SPECTRE { "spectre" },
	THREAD { "thread" },
	UUID { "uuid" },
}

<* Zig `Namespaced.Msvc`. *>
enum AttrMsvc : char (String name)
{
	FORCEINLINE_CALLS { "forceinline_calls" },
	FORCEINLINE { "forceinline" },
	NOINLINE { "noinline" },
}

<* Zig `Namespaced.Riscv`. *>
enum AttrRiscv : char (String name)
{
	VECTOR_CC { "vector_cc" },
	VLS_CC { "vls_cc" },
}

<* Zig `Namespaced.Keyword`. *>
enum AttrKeyword : char (String name)
{
	_ALIGNAS { "_Alignas" },
	ALIGNAS { "alignas" },
	NORETURN { "noreturn" },
	ASM_LABEL { "asm_label" },
	NONNULL { "nonnull" },
	NULL_UNSPECIFIED { "null_unspecified" },
	NULLABLE_RESULT { "nullable_result" },
	NULLABLE { "nullable" },
	__FORCEINLINE { "__forceinline" },
	_FORCEINLINE { "_forceinline" },
	__STDCALL { "__stdcall" },
	_STDCALL { "_stdcall" },
	__THISCALL { "__thiscall" },
	_THISCALL { "_thiscall" },
	__VECTORCALL { "__vectorcall" },
	_VECTORCALL { "_vectorcall" },
	__FASTCALL { "__fastcall" },
	_FASTCALL { "_fastcall" },
	_REGCALL { "_regcall" },
	__CDECL { "__cdecl" },
	_CDECL { "_cdecl" },
	PTR64 { "ptr64" },
	PTR32 { "ptr32" },
	SPTR { "sptr" },
	UPTR { "uptr" },
}

<* Zig `Namespaced`. Zig `Namespaced.Aro` is an empty enum: ARO has no member. *>
struct Namespaced
{
	AttrNamespace ns;
	union
	{
		AttrStandard standard;
		AttrGnu gnu;
		AttrClang clang;
		AttrDeclspec declspec;
		AttrMsvc msvc;
		AttrRiscv riscv;
		AttrKeyword keyword;
	}
}

<* Zig `==` on `Namespaced`: same namespace and same member value. *>
fn bool Namespaced.eq(self, Namespaced other)
{
	if (self.ns != other.ns) return false;
	switch (self.ns)
	{
		case STANDARD: return self.standard == other.standard;
		case GNU: return self.gnu == other.gnu;
		case CLANG: return self.clang == other.clang;
		case DECLSPEC: return self.declspec == other.declspec;
		case MSVC: return self.msvc == other.msvc;
		case RISCV: return self.riscv == other.riscv;
		case KEYWORD: return self.keyword == other.keyword;
		case ARO: return true;
	}
}

<* Zig `@tagName` of the active member (the attribute's spelling); "" for ARO. *>
fn String Namespaced.name(self)
{
	switch (self.ns)
	{
		case STANDARD: return self.standard.name;
		case GNU: return self.gnu.name;
		case CLANG: return self.clang.name;
		case DECLSPEC: return self.declspec.name;
		case MSVC: return self.msvc.name;
		case RISCV: return self.riscv.name;
		case KEYWORD: return self.keyword.name;
		case ARO: return "";
	}
}

<*
 Zig `Namespaced.fromString` (`name_raw` and `vendor` are normalized first):
  - STANDARD without vendor: an AttrStandard name.
  - STANDARD with vendor: a StandardVendor name; ARO -> UNKNOWN_ATTRIBUTE;
    else a name of that vendor's enum.
  - GNU (no vendor allowed): an AttrGnu name, else an AttrClang name.
  - DECLSPEC (no vendor allowed): an AttrDeclspec name.
  - KEYWORD: unreachable.
 UNKNOWN_ATTRIBUTE when nothing matches.
*>
fn Namespaced? namespaced_from_string(AttributeSyntax syntax, bool has_vendor, String vendor, String name_raw)
{
	String name = normalize(name_raw);
	if (syntax == KEYWORD) unreachable("keyword syntax uses namespaced_from_keyword");
	if (syntax == STANDARD)
	{
		if (!has_vendor)
		{
			foreach (v : AttrStandard::values) if (v.name == name) return { .ns = STANDARD, .standard = v };
			return UNKNOWN_ATTRIBUTE~;
		}
		String ven = normalize(vendor);
		StandardVendor? sv = null;
		foreach (v : StandardVendor::values) if (v.name == ven) { sv = v; break; }
		if (sv == null || sv!! == ARO) return UNKNOWN_ATTRIBUTE~;
		switch (sv!!)
		{
			case GNU:
				foreach (v : AttrGnu::values) if (v.name == name) return { .ns = GNU, .gnu = v };
				break;
			case CLANG:
				foreach (v : AttrClang::values) if (v.name == name) return { .ns = CLANG, .clang = v };
				break;
			case MSVC:
				foreach (v : AttrMsvc::values) if (v.name == name) return { .ns = MSVC, .msvc = v };
				break;
			case RISCV:
				foreach (v : AttrRiscv::values) if (v.name == name) return { .ns = RISCV, .riscv = v };
				break;
			case ARO: return UNKNOWN_ATTRIBUTE~;
		}
		return UNKNOWN_ATTRIBUTE~;
	}
	if (syntax == GNU)
	{
		assert(!has_vendor);
		foreach (v : AttrGnu::values) if (v.name == name) return { .ns = GNU, .gnu = v };
		foreach (v : AttrClang::values) if (v.name == name) return { .ns = CLANG, .clang = v };
		return UNKNOWN_ATTRIBUTE~;
	}
	assert(syntax == DECLSPEC && !has_vendor);
	foreach (v : AttrDeclspec::values) if (v.name == name) return { .ns = DECLSPEC, .declspec = v };
	return UNKNOWN_ATTRIBUTE~;
}

<*
 Zig `Namespaced.fromKeyword`: KEYWORD_ALIGNAS -> _ALIGNAS,
 KEYWORD_C23_ALIGNAS -> ALIGNAS, KEYWORD_NORETURN -> NORETURN,
 KEYWORD_ASM/ASM1/ASM2 -> ASM_LABEL, KEYWORD_NONNULL, KEYWORD_NULL_UNSPECIFIED,
 KEYWORD_NULLABLE_RESULT, KEYWORD_NULLABLE, KEYWORD_FORCEINLINE(2),
 KEYWORD_STDCALL(2), KEYWORD_THISCALL(2), KEYWORD_VECTORCALL(2),
 KEYWORD_FASTCALL(2), KEYWORD_REGCALL, KEYWORD_CDECL(2), KEYWORD_PTR64,
 KEYWORD_PTR32, KEYWORD_SPTR, KEYWORD_UPTR to the AttrKeyword of the same
 spelling; any other id is unreachable.
*>
fn Namespaced namespaced_from_keyword(TokenId id)
{
	AttrKeyword keyword;
	switch (id)
	{
		case KEYWORD_ALIGNAS: keyword = _ALIGNAS;
		case KEYWORD_C23_ALIGNAS: keyword = ALIGNAS;
		case KEYWORD_NORETURN: keyword = NORETURN;
		case KEYWORD_ASM:
		case KEYWORD_ASM1:
		case KEYWORD_ASM2: keyword = ASM_LABEL;
		case KEYWORD_NONNULL: keyword = NONNULL;
		case KEYWORD_NULL_UNSPECIFIED: keyword = NULL_UNSPECIFIED;
		case KEYWORD_NULLABLE_RESULT: keyword = NULLABLE_RESULT;
		case KEYWORD_NULLABLE: keyword = NULLABLE;
		case KEYWORD_FORCEINLINE: keyword = __FORCEINLINE;
		case KEYWORD_FORCEINLINE2: keyword = _FORCEINLINE;
		case KEYWORD_STDCALL: keyword = __STDCALL;
		case KEYWORD_STDCALL2: keyword = _STDCALL;
		case KEYWORD_THISCALL: keyword = __THISCALL;
		case KEYWORD_THISCALL2: keyword = _THISCALL;
		case KEYWORD_VECTORCALL: keyword = __VECTORCALL;
		case KEYWORD_VECTORCALL2: keyword = _VECTORCALL;
		case KEYWORD_FASTCALL: keyword = __FASTCALL;
		case KEYWORD_FASTCALL2: keyword = _FASTCALL;
		case KEYWORD_REGCALL: keyword = _REGCALL;
		case KEYWORD_CDECL: keyword = __CDECL;
		case KEYWORD_CDECL2: keyword = _CDECL;
		case KEYWORD_PTR64: keyword = PTR64;
		case KEYWORD_PTR32: keyword = PTR32;
		case KEYWORD_SPTR: keyword = SPTR;
		case KEYWORD_UPTR: keyword = UPTR;
		default: unreachable("not an attribute keyword");
	}
	return { .ns = KEYWORD, .keyword = keyword };
}

<* Zig `hasIdentifierArg`: GNU access/mode/format and DECLSPEC spectre. *>
fn bool Namespaced.has_identifier_arg(self)
{
	switch (self.ns)
	{
		case GNU: return self.gnu == ACCESS || self.gnu == MODE || self.gnu == FORMAT;
		case DECLSPEC: return self.declspec == SPECTRE;
		default: return false;
	}
}

<* Zig `normalize`: strip a leading and trailing "__" when name.len >= 4. *>
fn String normalize(String name)
{
	if (name.len >= 4 && name.starts_with("__") && name.ends_with("__")) return name[2 : name.len - 4];
	return name;
}

<* Zig `Visibility.opts.map`: default, hidden, internal (-> HIDDEN), protected. *>
fn Visibility? visibility_from_string(String s)
{
	if (s == "default") return DEFAULT;
	if (s == "hidden" || s == "internal") return HIDDEN;
	if (s == "protected") return PROTECTED;
	return null;
}

// ---------------------------------------------------------------------------
// Attribute
// ---------------------------------------------------------------------------

<* Zig `Attribute`. *>
struct Attribute
{
	AttributeArgs args;
	AttributeSyntax syntax;
	Namespaced name;
	tokens::TokenIndex tok;
}
