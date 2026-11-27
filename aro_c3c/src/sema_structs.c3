// Port of the sema / ABI / statistics structs of c3c
// src/compiler/compiler_internal.h (EndJump .. PanicFunctionDescriptor, plus
// the `FindMember` enum), shared by every sema file.
//
// Deviations from c3c:
// - Bit-fields are plain fields; the anonymous unions / structs are kept as
//   C3 anonymous `union { ... }` / `struct { ... }` members, so field access
//   is spelled like c3c (`context.call_env.current_function`,
//   `info.direct_pair.lo`, `context.block_returns`).
// - `T **` vectors are slices; `BlockExit** block_exit_ref` stays a pointer.
// - `CopyStruct.fixups` (c3c: MAX_FIXUPS inline entries, ~16 MB) is a slice
//   that copying.c3 allocates on first use; `current_fixup` indexes it.
// - `StatsOrigin`'s STATS_ORIGINS count is `StatsOrigin.len`.
module aro::frontend::c3::compiler;

const int MAX_FIXUPS = 0xFFFFF;

struct EndJump
{
	bool active;
	SourceLocId loc;
}

struct DynamicScope
{
	bool allow_dead_code;
	bool is_dead;
	bool is_poisoned;
	EndJump end_jump;
	ScopeFlags flags;
	int label_start;
	int current_local;
	AstId defer_last;
	AstId defer_start;
	Ast* in_defer;
	int depth;
}

struct CallEnv
{
	CallEnvKind kind;
	bool ensures;
	bool pure;
	bool in_no_eval;
	bool is_naked_fn;
	bool ignore_deprecation;
	SourceLocId in_if_resolution;
	Decl*[] opt_returns;
	union
	{
		Decl* attr_declaration;
		Decl* current_function;
	}
}

struct JumpTarget
{
	Ast* target;
	AstId defer_id;
}

struct SemaContext
{
	// Evaluated in this.
	CompilationUnit* unit;
	// Compiled in this unit.
	CompilationUnit* compilation_unit;
	CallEnv call_env;
	Decl* current_macro;
	InliningSpan* inlined_at;
	int macro_call_depth;
	// Jump tracking
	JumpTarget break_jump;
	JumpTarget continue_jump;
	JumpTarget next_jump;
	AstId block_return_defer;
	Ast* next_switch;
	struct
	{
		uint original_inline_line;
		Module* original_module;
		Decl*[] yield_params;
		Ast* yield_body;
		BlockExit** block_exit_ref;
		Type* expected_block_type;
		Ast*[] block_returns;
		Expr*[] macro_varargs;
		bool macro_has_vaargs;
		Decl*[] macro_params;
		bool macro_has_ensures;
		Decl*[] ct_locals;
	}
	Type* rtype;
	SemaContext* yield_context;
	Decl*[] locals;
	DynamicScope active_scope;
	Expr* return_expr;
	bool is_temp;
	Decl* generic_infer;
	Decl* generic_instance;
}

<* compiler_internal.h `AbiSpecType` (odd values tag a special ABI type in an AbiType). *>
alias AbiSpecType = int;
const AbiSpecType ABI_TYPE_INT_24 = 1;
const AbiSpecType ABI_TYPE_INT_40 = 3;
const AbiSpecType ABI_TYPE_INT_48 = 5;
const AbiSpecType ABI_TYPE_INT_56 = 7;
const AbiSpecType ABI_TYPE_INT_VEC_2 = 9;
const AbiSpecType ABI_TYPE_INT_VEC_4 = 11;
const AbiSpecType ABI_TYPE_FLOAT_VEC_2 = 13;
const AbiSpecType ABI_TYPE_FLOAT_VEC_4 = 15;
const AbiSpecType ABI_TYPE_LONG_VEC_2 = 17;
const AbiSpecType ABI_TYPE_FLOAT16_VEC_2 = 19;
const AbiSpecType ABI_TYPE_FLOAT16_VEC_4 = 21;
const AbiSpecType ABI_TYPE_BFLOAT16_VEC_2 = 23;
const AbiSpecType ABI_TYPE_BFLOAT16_VEC_4 = 25;
const AbiSpecType ABI_TYPE_DOUBLE_VEC_2 = 27;
const AbiSpecType ABI_TYPE_DOUBLE_VEC_4 = 29;
const AbiSpecType ABI_TYPE_DOUBLE_VEC_8 = 31;

<*
 compiler_internal.h `AbiType`: a Type* or (odd value) an AbiSpecType.
 Like c3c, `abi_type` overlays the low bits of `type` (little-endian), so
 `abi_type & 1` tells the two apart.
*>
union AbiType
{
	Type* type;
	AbiSpecType abi_type;
}

struct AbiArgAttributes
{
	bool by_reg;
	bool zeroext;
	bool signext;
	bool realign;
	bool by_val;
	char stack_align;
}

struct ABIArgInfo
{
	ArrayIndex param_index_start;
	ArrayIndex param_index_end;
	ABIKind kind;
	AbiArgAttributes attributes;
	union
	{
		struct direct_pair
		{
			AbiType lo;
			AbiType hi;
		}
		struct coerce_expand
		{
			char offset_hi;
			bool packed;
			Type* lo;
			Type* hi;
		}
		AbiType direct_coerce_type;
		char direct_struct_expand;
		struct indirect
		{
			// We may request a certain alignment of the parameters.
			AlignSize alignment;
			Type* type;
		}
	}
	Type* original_type;
	ParamRewrite rewrite;
}

struct ParamInfo
{
	Type* type;
	ParamRewrite rewrite;
}

struct FunctionPrototype
{
	CallABI call_abi;
	bool raw_variadic;
	bool use_win64;
	bool is_resolved;
	ushort vararg_index;
	RetValType ret_rewrite;
	ParamRewrite return_rewrite;
	ParamInfo return_info;
	Type* return_result;
	int param_count;
	ushort param_vacount;
	ABIArgInfo* ret_abi_info;
	ABIArgInfo*[] abi_args;
	ABIArgInfo*[] abi_varargs;
	Type* raw_type;
}

struct NameResolve
{
	Decl* ambiguous_other_decl;
	Decl* private_decl;
	Decl* maybe_decl;
	Decl* found;
	ModulePath* path;
	SourceLocId loc;
	String symbol;
	Module* path_found;
	bool suppress_error;
	bool is_parameterized;
	bool is_generic_parent;
}

struct CopyFixup
{
	void* original;
	void* new_ptr;
}

struct CopyStruct
{
	<* c3c: `CopyFixup fixups[MAX_FIXUPS]`; allocated on first use (MAX_FIXUPS entries). *>
	CopyFixup[] fixups;
	CopyFixup* current_fixup;
	bool single_static;
	bool copy_in_use;
	bool is_template;
	DeclId instance_id;
}

struct FunctionAnalysisTime
{
	Decl* decl;
	double time;
}

enum StatsOrigin : char
{
	USER,
	STDLIB,
	RUNTIME,
	GENERATED,
	NONE,
}

<* c3c STATS_ORIGINS (== STATS_ORIGIN_NONE). *>
const int STATS_ORIGINS = StatsOrigin.NONE.ordinal;

// A row in one of the statistics lists, the fields used depend on the list.
struct StatsEntry
{
	String name;
	int id;
	StatsOrigin origin;
	int instances;
	long instructions;
	long lines;
	double analysis_time;
	double ir_gen_time;
	double codegen_time;
}

// The top entries of a list, the rest are summed up in "other".
struct StatsList
{
	StatsEntry[] top;
	StatsEntry other;
	int other_count;
	StatsEntry total;
}

struct StatsOriginTotals
{
	int files;
	long lines;
	int functions;
	long ir_instructions;
	double codegen_time;
}

struct CompilerStats
{
	double init_time;
	double parsing_time;
	double sema_time;
	double ir_gen_time;
	double codegen_time;
	double link_time;
	double generic_time;
	double static_analysis_time;
	int generic_depth;
	double nested_analysis_time;
	double codegen_thread_time;
	int codegen_tasks;
	int codegen_threads;
	String linker;
	int source_files;
	long source_lines;
	int functions;
	int types;
	int generic_instances;
	long ir_instructions;
	long object_size;
	StatsOriginTotals[STATS_ORIGINS] origins;
	long ast_memory;
	long decl_memory;
	long expr_memory;
	long type_info_memory;
	long sourceloc_memory;
	FunctionAnalysisTime[] function_analysis_times;
	StatsList generic_list;
	StatsList generic_function_list;
	StatsList function_list;
	StatsList module_size_list;
	StatsList module_time_list;
	bool printed;
}

struct PanicVariant
{
	PanicFunction id;
	Type*[PANIC_FN_MAX_VALUES] types;
}

struct PanicFunctionDescriptor
{
	String name;
	String format;
	String summary;
	int text_count;
	int value_count;
}

const String PANIC_MODULE_NAME = "std::core::runtime::panics";

<* compiler_internal.h `FindMember`. *>
enum FindMember : char
{
	METHODS_AND_FIELDS,
	METHODS_INTERFACES_AND_FIELDS,
	FIELDS_ONLY,
}
