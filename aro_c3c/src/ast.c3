// Port of the AST and type data structures of c3c src/compiler/compiler_internal.h
// (Type, TypeInfo, Decl, Expr, Ast, Module, CompilationUnit and their payloads)
// plus the ARENA_DEF id arenas.
//
// Deviations from c3c:
// - C bit-fields are plain fields (bool / char-sized enums).
// - `T **` vectors are slices (`T*[]`), grown with `@vec_add` (vmem.c3).
// - `const char *` names are `String` (interned by the symtab or copied to
//   the AST arena with `str_copy`; both keep a NUL after the last byte).
// - Renamed to avoid std clashes: File -> SourceFile, Path -> ModulePath,
//   Range -> ExprRange, SourceLoc -> tokens::SourceSpan.
// - Fields named after C3 keywords are renamed: `fault` -> `fault_val`,
//   `module` -> `module_name` (ModulePath) / `mod` (ImportDecl, ModuleAliasDecl,
//   CompilationUnit), `alias` -> `alias_decl`, `defer` -> `defer_id`,
//   `import` -> `import_decl`, `var` -> `var_decl` (Decl), `ct_var`
//   (ExprCtSubscript), `retry_var` (switch codegen), `macro` -> `macro_decl`,
//   `typeid` -> `typeid_type` (ExprConst) / `typeid_expr` (ExprMakeAny).
// - Backend slots (`void *backend_*`, LLVM block pointers) are kept as
//   `void*`. The sema/ABI structs referenced from here (SemaContext,
//   FunctionPrototype, ...) live in sema_structs.c3.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, aro::frontend::c3::lexer;

alias Real = double;
alias ByteSize = long;
alias TypeSize = int;
alias IndexDiff = long;
alias ArrayIndex = long;
alias StructIndex = short;
alias AlignSize = int;
alias BitSize = long;
alias FileId = uint;
alias SourceLoc = SourceSpan;

alias AstId = uint;
alias ExprId = uint;
alias DeclId = uint;
alias TypeInfoId = uint;
alias SourceLocId = uint;

const int CLOBBER_FLAG_ELEMENTS = 4;

struct Int128
{
	ulong high;
	ulong low;
}

<* c3c `Int`: an integer constant and its type kind. *>
struct Int
{
	uint128 i;
	TypeKind type;
}

<* c3c `Float`. *>
struct Float
{
	Real f;
	TypeKind type;
}

struct MethodTable
{
	uint count;
	uint capacity;
	uint max_load;
	DeclId* methods;
}

struct DeclTable
{
	uint count;
	uint capacity;
	uint max_load;
	DeclId* entries;
}

struct ConstInitializer
{
	ConstInitType kind;
	<* Always flattened. *>
	Type* type;
	union
	{
		ConstInitializer*[] init_struct;
		Expr* init_value;
		struct init_union
		{
			ConstInitializer* element;
			ArrayIndex index;
		}
		struct init_array
		{
			ConstInitializer*[] elements;
		}
		ConstInitializer*[] init_array_full;
		struct init_array_value
		{
			ConstInitializer* element;
			ArrayIndex index;
		}
	}
}

struct InliningSpan
{
	SourceLocId loc;
	InliningSpan* prev;
	Decl* instance;
}

struct ExprConstBytes
{
	char* ptr;
	ArrayIndex len;
}

struct ExprConstMember
{
	AlignSize offset;
	AlignSize align;
	Decl* decl;
}

struct ExprConst
{
	ConstKind const_kind;
	bool is_character;
	bool is_hex;
	union
	{
		Float fxx;
		Int ixx;
		ulong ptr;
		bool b;
		ExprConstBytes bytes;
		Expr* expr_ref;
		Decl* global_ref;
		Decl* enum_val;
		Decl* fault_val;
		Type* typeid_type;
		ConstInitializer* initializer;
		ConstInitializer* slice_init;
		Expr*[] untyped_list;
		Expr* reflection;
		ExprConstMember member;
	}
}

<* enums.h `FileKind`. *>
enum FileKind : char
{
	SOURCE,
	STDIN,
	TEXT,
	GENERATED,
}

<*
 c3c `File`. `contents` is cleaned and NUL padded (lexer::clean_source);
 c3c's `content_len` is `contents.len`.
*>
struct SourceFile
{
	FileId file_id;
	FileKind kind;
	String contents;
	String name;
	String dir_path;
	String full_path;
}

<* c3c `Path`: a module path such as `std::io`. *>
struct ModulePath
{
	SourceLocId loc;
	String module_name;
	uint len;
}

struct TypeBuiltin
{
	char bitsize;
	char bytesize;
	char abi_alignment;
	char pref_alignment;
}

struct TypeArray
{
	Type* base;
	ArrayIndex len;
}

struct CalleeAttributes
{
	bool nodiscard;
	bool maydiscard;
	bool is_pure;
	bool noreturn;
	bool always_const;
	bool is_simd;
	char format;
}

struct TypeFunction
{
	Decl* decl;
	Signature* signature;
	FunctionPrototype* prototype;
}

struct Type
{
	TypeKind type_kind;
	bool is_live;
	ushort backend_type_gen;
	ushort backend_typeid_gen;
	ushort backend_debug_gen;
	Module* traced_module;
	Type* canonical;
	String name;
	<* c3c `Type **type_cache` vector. *>
	Type*[] type_cache;
	Type* func_ptr;
	void* backend_type;
	TypeSize size;
	void* backend_typeid;
	void* backend_debug_type;
	union
	{
		<* Error, Struct, Union, Typedef, Member, Bitstruct. *>
		Decl* decl;
		<* int, float, bool. *>
		TypeBuiltin builtin;
		<* Type[], Type[*], Type[123] or Type[<123>]. *>
		TypeArray array;
		<* fn TypeR Type1(Type2, Type3, ...). *>
		TypeFunction function;
		Type* pointer;
		Type* optional;
	}
}

struct TypeInfoUnresolved
{
	String name;
	ModulePath* path;
}

struct TypeInfoArray
{
	TypeInfo* base;
	Expr* len;
}

struct TypeInfoGeneric
{
	TypeInfo* base;
	Expr*[] params;
}

struct TypeInfo
{
	SourceLocId loc;
	ResolveStatus resolve_status;
	TypeInfoKind kind;
	bool optional;
	bool is_simd;
	TypeInfoCompressedKind subtype;
	Type* type;
	union
	{
		TypeInfoUnresolved unresolved;
		Expr* unresolved_type_expr;
		TypeInfoArray array;
		TypeInfo* pointer;
		TypeInfoGeneric generic;
	}
}

struct Attr
{
	ModulePath* path;
	String name;
	SourceLocId loc;
	AttributeType attr_kind;
	bool is_custom;
	Expr*[] exprs;
}

struct ResolvedAttrData
{
	Attr*[] tags;
	String deprecated;
	String[] links;
	String section;
	String wasm_module;
	SourceLocId overload;
}

struct ImportDecl
{
	ModulePath* path;
	bool import_private_as_public;
	bool is_non_recurse;
	Module* mod;
}

struct IncludeDecl
{
	Expr* filename;
}

struct ExecDecl
{
	Expr* filename;
	Expr*[] args;
	Expr* stdin_string;
}

struct StructDecl
{
	Decl*[] members;
	DeclId parent;
	union
	{
		struct
		{
			TypeSize size;
			DeclId padded_decl_id;
			StructIndex union_rep;
			ushort padding;
			bool is_packed;
			bool is_compact;
		}
		struct
		{
			TypeInfo* container_type;
			bool msb0;
			bool big_endian;
			bool little_endian;
			bool overlap;
			bool consecutive;
		}
	}
}

struct VarDecl
{
	TypeInfoId type_info;
	VarDeclKind kind;
	bool shadow;
	bool vararg;
	bool is_static;
	bool is_read;
	bool not_null;
	bool out_param;
	bool in_param;
	bool own_param;
	bool drop_param;
	bool init_param;
	bool is_written;
	bool is_addr;
	bool self_addr;
	bool is_threadlocal;
	bool no_init;
	bool no_alias;
	bool bit_is_expr;
	bool is_self;
	bool is_temp;
	bool copy_const;
	bool defaulted;
	bool safe_infer;
	union
	{
		Expr* init_expr;
		Decl* alias_decl;
	}
	union
	{
		int index;
		struct
		{
			void* backend_debug_ref;
			union
			{
				void* optional_ref;
				int optional_id;
			}
		}
		union
		{
			struct
			{
				Expr* start;
				Expr* end;
			}
			struct
			{
				int start_bit;
				int end_bit;
			}
		}
	}
}

struct EnumConstantDecl
{
	bool is_raw;
	union
	{
		struct
		{
			Expr*[] associated;
			int inner_ordinal;
		}
		Expr* value;
	}
}

struct EnumDecl
{
	Decl*[] values;
	Decl*[] parameters;
	TypeInfo* type_info;
}

struct Signature
{
	CalleeAttributes attrs;
	bool is_macro;
	bool is_at_macro;
	bool is_safemacro;
	Variadic variadic;
	CallABI abi;
	int vararg_index;
	TypeInfoId rtype;
	Decl*[] params;
}

struct FuncDecl
{
	TypeInfoId type_parent;
	char overload_type;
	bool is_wildcard_overload;
	OperatorOverload operator;
	Signature signature;
	DeclId param_struct;
	AstId body;
	union
	{
		<* Function related. *>
		struct
		{
			bool attr_inline;
			bool attr_noinline;
			bool attr_noredzone;
			bool attr_extname;
			bool attr_naked;
			bool attr_benchmark;
			bool attr_test;
			bool attr_winmain;
			bool attr_optional;
			bool attr_init;
			bool attr_finalizer;
			bool attr_interface_method;
			bool attr_dynamic;
			bool attr_nosanitize_address;
			bool attr_nosanitize_memory;
			bool attr_nosanitize_thread;
			bool is_lambda;
			bool in_macro;
			char stack_probe;
			char stack_protector;
			union
			{
				uint priority;
				DeclId interface_method;
				DeclId default_method;
				Decl*[] generated_lambda;
				Decl*[] lambda_ct_parameters;
			}
		}
		<* Macro related. *>
		struct
		{
			DeclId body_param;
			CompilationUnit* unit;
		}
	}
}

struct FnTypeDecl
{
	Signature signature;
	DeclId param_struct;
}

struct AttrDecl
{
	Decl*[] params;
	Attr*[] attrs;
}

struct GenericDecl
{
	String[] parameters;
	int id;
	Expr*[] requires;
	Decl*[] instances;
	Decl* owner;
	Decl*[] decls;
	Decl*[] conditional_decls;
}

struct GenericInstanceDecl
{
	int id;
	Decl*[] templates;
	Decl*[] params;
	String name_suffix;
	String cname_suffix;
	Decl*[] generated_decls;
	DeclId spawn_root;
	int spawn_count;
}

struct TypeAliasDecl
{
	bool is_func;
	union
	{
		Decl* decl;
		Expr* type_expr;
	}
}

struct DefineDecl
{
	union
	{
		Expr* alias_expr;
		Decl* alias_decl;
	}
}

struct ContractParam
{
	String name;
	SourceLocId loc;
	InOutModifier modifier;
	bool by_ref;
	String description;
}

struct ExprContractParam
{
	union
	{
		String name;
		struct
		{
			int index;
			bool found;
		}
	}
}

struct ExprContract
{
	ExprContractParam param;
	Expr* decl_exprs;
	String comment;
	String expr_string;
}

struct ContractsDecl
{
	Expr*[] requires;
	Expr*[] ensures;
	ContractParam[] params;
	bool pure;
	union
	{
		Expr*[] opt_returns;
		Decl*[] opt_returns_resolved;
	}
	String comment;
	String return_desc;
}

struct ModuleAliasDecl
{
	ModulePath* alias_path;
	Module* mod;
}

struct LabelDecl
{
	AstId defer_id;
	bool next_target;
	void* break_target;
	void* continue_target;
	AstId scope_defer;
	AstId parent;
}

struct Methods
{
	bool has_subscript_overloads;
	DeclId[OVERLOADS_COUNT + 1] overloads;
	DeclTable method_table;
	Decl*[] methods;
}

struct Decl
{
	String name;
	String extname;
	DeclKind decl_kind;
	ResolveStatus resolve_status;
	Visibility visibility;
	ushort backend_gen;
	bool has_tag;
	bool is_extern;
	bool is_substruct;
	bool has_variable_array;
	bool is_value;
	bool is_autoimport;
	bool has_extname;
	bool is_external_visible;
	bool is_weak;
	bool is_weak_link;
	bool is_maybe_unused;
	bool is_must_use;
	bool will_reflect;
	bool obfuscate;
	bool is_dynamic;
	bool is_synthetic;
	bool is_export;
	bool is_live;
	bool no_strip;
	bool is_cond;
	bool is_feat_cond;
	bool is_if;
	bool is_body_checked;
	bool attr_nopadding;
	bool resolved_attributes;
	bool allow_deprecated;
	bool attr_constinit;
	bool attr_mustinit;
	bool is_template;
	bool is_templated;
	bool is_method_checked;
	bool is_used;
	union
	{
		void* backend_ref;
		int backend_id;
		void* backend_value;
		Decl* replacement;
		struct
		{
			bool in_init;
		}
	}
	SourceLocId loc;
	TypeSize offset;
	TypeSize padding;
	AlignSize alignment;
	union
	{
		DeclId generic_id;
		DeclId instance_id;
	}
	DeclId docs;
	CompilationUnit* unit;
	union
	{
		Attr*[] attributes;
		ResolvedAttrData* attrs_resolved;
	}
	Type* type;
	union
	{
		Decl*[] decl_list;
		struct
		{
			TypeInfo*[] interfaces;
			Methods* method_table;
			union
			{
				<* Enums and Fault. *>
				EnumDecl enums;
				struct
				{
					TypeInfo* distinct;
					Expr* distinct_align;
				}
				<* Unions, Struct, Bitstruct. *>
				StructDecl strukt;
				Decl*[] interface_methods;
			}
		}
		AttrDecl attr_decl;
		Decl*[] body_params;
		Ast* ct_assert_decl;
		Ast* ct_echo_decl;
		Decl*[] ct_else_decl;
		Decl*[] decls;
		ContractsDecl contracts_decl;
		DefineDecl define_decl;
		ModuleAliasDecl module_alias_decl;
		EnumConstantDecl enum_constant;
		ExecDecl exec_decl;
		Expr* expand_decl;
		FnTypeDecl fntype_decl;
		FuncDecl func_decl;
		ImportDecl import_decl;
		IncludeDecl include;
		LabelDecl label;
		TypeAliasDecl type_alias_decl;
		VarDecl var_decl;
		GenericDecl generic_decl;
		GenericInstanceDecl instance_decl;
	}
}

enum RangeType : char
{
	DYNAMIC,
	CONST_END,
	CONST_LEN,
	CONST_RANGE,
	SINGLE_ELEMENT,
}

<* c3c `Range`. *>
struct ExprRange
{
	ResolveStatus status;
	RangeType range_type;
	bool start_from_end;
	bool end_from_end;
	bool is_len;
	bool is_optional;
	union
	{
		struct
		{
			ExprId start;
			union
			{
				ExprId end;
				ArrayIndex const_end;
			}
		}
		struct
		{
			ArrayIndex start_index;
			ArrayIndex len_index;
		}
	}
}

struct ExprTernary
{
	ExprId cond;
	<* Null for elvis. *>
	ExprId then_expr;
	ExprId else_expr;
	bool grouped;
	bool is_const;
}

struct ExprBinary
{
	ExprId left;
	ExprId right;
	BinaryOp operator;
	bool grouped;
}

struct ExprUnary
{
	Expr* expr;
	UnaryOp operator;
	bool no_wrap;
	bool no_read;
}

struct ExprCall
{
	union
	{
		ExprId function;
		DeclId func_ref;
	}
	union
	{
		ExprId macro_body;
		AstId function_contracts;
	}
	bool is_type_method;
	bool is_pointer_call;
	bool attr_force_inline;
	bool attr_force_noinline;
	bool is_builtin;
	bool is_func_ref;
	bool attr_pure;
	bool no_return;
	bool is_dynamic_dispatch;
	bool has_optional_arg;
	bool must_use;
	bool is_optional_return;
	bool va_is_splat;
	bool is_outer_call;
	Expr*[] arguments;
	union
	{
		Expr*[] varargs;
		Expr* vasplat;
	}
}

struct ExprMacroBody
{
	Ast* body;
	Decl*[] body_arguments;
}

struct SubscriptIndex
{
	bool start_from_end;
	ExprId expr;
}

struct ExprSubscript
{
	ExprId expr;
	SubscriptIndex index;
	bool no_check;
	bool ref;
	bool prefer_ref;
}

struct ExprCtSubscript
{
	Decl* ct_var;
	ArrayIndex index;
}

struct ExprSlice
{
	ExprId expr;
	ExprRange range;
}

struct ExprSubscriptAssign
{
	ExprId expr;
	DeclId method;
	ExprId index;
}

struct ExprSliceAssign
{
	ExprId left;
	ExprId right;
}

struct ExprPointerOffset
{
	ExprId ptr;
	ExprId offset;
}

struct ExprBuiltinAccess
{
	BuiltinAccessKind kind;
	ExprId inner;
}

struct ExprEmbedExpr
{
	Expr* filename;
	Expr* len;
}

struct ExprGenericIdent
{
	ExprId parent;
	Expr*[] parameters;
}

struct ExprResolvedAccess
{
	Expr* parent;
	Decl* ref;
}

struct ExprTypeProperty
{
	Expr* type;
	SourceLocId token_span;
	String property;
}

struct ExprUnresolvedAccess
{
	Expr* parent;
	Expr* child;
	bool is_lvalue;
	bool is_ref;
}

struct DesignatorElement
{
	DesignatorType kind;
	union
	{
		Expr* field_expr;
		struct
		{
			Expr* index_expr;
			Expr* index_end_expr;
		}
	}
	ArrayIndex index;
	ArrayIndex index_end;
}

struct ExprDesignator
{
	DesignatorElement*[] path;
	Expr* value;
}

struct ExprNamedArgument
{
	String name;
	SourceLocId name_span;
	Expr* value;
}

struct ExprEvalNamedArgument
{
	Expr* name;
	Expr* value;
}

struct ExprTypeCall
{
	Decl* type;
	TypeProperty property;
}

struct ExprUnresolvedIdentifier
{
	ModulePath* path;
	String ident;
	bool is_const;
}

struct ExprDefaultArg
{
	SourceLocId loc;
	Expr* inner;
}

struct ExprIdentifierRaw
{
	String identifier;
	bool is_ref;
	bool is_rvalue;
}

struct ExprCtCall
{
	TokenType token_type;
	union
	{
		struct
		{
			Expr* main_var;
			DesignatorElement*[] flat_path;
		}
		struct
		{
			TypeInfoId type_from;
			TypeInfoId type_to;
		}
	}
}

struct Clobbers
{
	ulong[CLOBBER_FLAG_ELEMENTS] mask;
}

<* asm_target.h `AsmRegister`. *>
struct AsmRegister
{
	String name;
	AsmRegisterType type;
	AsmArgBits bits;
	int clobber_index;
}

struct ExprAsmArgIdent
{
	union
	{
		String name;
		Decl* ident_decl;
	}
	bool copy_output;
	bool early_clobber;
	bool is_input;
}

struct ExprAsmArg
{
	AsmArgKind kind;
	ushort index;
	AsmOffsetType offset_type;
	bool neg_offset;
	bool resolved;
	union
	{
		ExprAsmArgIdent ident;
		ExprId expr_id;
		struct
		{
			ExprId base;
			ExprId idx;
			long offset;
		}
		struct
		{
			ulong value;
			int bits;
			bool is_neg;
		}
		union reg
		{
			String name;
			AsmRegister* ref;
		}
	}
}

struct ExprCtArg
{
	TokenType type;
	ExprId arg;
}

struct ExprCtAndOr
{
	bool is_and;
	Expr*[] args;
}

struct ExprCast
{
	ExprId expr;
	TypeInfoId type_info;
}

struct ExprTwo
{
	Expr* first;
	Expr* last;
}

struct ExprBodyExpansion
{
	Expr*[] values;
	Decl*[] declarations;
	AstId first_stmt;
}

struct BlockExit
{
	void* block_return_exit;
	void* block_optional_exit;
	void* block_error_var;
	void* block_return_out;
}

struct ExprMacroBlock
{
	AstId first_stmt;
	bool is_noreturn;
	bool is_must_use;
	bool is_optional_return;
	bool had_optional_arg;
	Decl*[] arguments;
	Decl* macro_decl;
	BlockExit** block_exit;
}

struct ExprCompoundLiteral
{
	Expr* initializer;
	TypeInfo* type_info;
}

struct Label
{
	String name;
	SourceLocId loc;
}

struct ExprGuard
{
	Expr* inner;
	AstId cleanup;
	BlockExit** in_block;
}

struct ExprCatch
{
	Decl* decl;
	Expr*[] exprs;
}

struct ExprUnresolvedCatch
{
	Expr* variable;
	TypeInfo* type;
	Expr*[] exprs;
}

struct ExprUnresolvedTry
{
	Expr* variable;
	TypeInfo* type;
	Expr* init;
}

struct ExprTry
{
	bool assign_existing;
	Expr* optional;
	union
	{
		Decl* decl;
		Expr* lhs;
	}
}

struct ExprBuiltin
{
	String ident;
	BuiltinFunction builtin;
}

struct ExprTypeidInfo
{
	ExprId parent;
	TypeIdInfoKind kind;
}

struct ExprSwizzle
{
	ExprId parent;
	bool is_overlapping;
	String swizzle;
}

struct ExprCastable
{
	ExprId expr;
	ExprId type;
}

struct ExprOtherContext
{
	Expr* inner;
	SemaContext* context;
	SourceLocId inline_at;
	bool is_ref;
}

struct ExprDesignatedInit
{
	Expr*[] list;
	Expr* splat;
}

struct ExprExtTrunc
{
	Expr* inner;
	bool is_signed;
}

struct ExprIntToBool
{
	Expr* inner;
	bool negate;
}

struct ExprMakeAny
{
	Expr* inner;
	Expr* typeid_expr;
}

struct ExprMakeSlice
{
	Expr* ptr;
	ArrayIndex len;
}

struct Expr
{
	Type* type;
	SourceLocId loc;
	ExprKind expr_kind;
	ResolveStatus resolve_status;
	union
	{
		ExprResolvedAccess access_resolved_expr;
		ExprUnresolvedAccess access_unresolved_expr;
		ExprBinary binary_expr;
		ExprBinary veccomp_expr;
		ExprBodyExpansion body_expansion_expr;
		ExprBuiltinAccess builtin_access_expr;
		ExprBuiltin builtin_expr;
		ExprCall call_expr;
		ExprCast cast_expr;
		ExprContract contract_expr;
		ExprUnresolvedCatch unresolved_catch_expr;
		ExprCatch catch_expr;
		Expr*[] cond_expr;
		ExprConst const_expr;
		Expr*[] ct_concat;
		ExprOtherContext expr_other_context;
		ExprIdentifierRaw ct_ident_expr;
		Decl* decl_expr;
		Decl* iota_decl_expr;
		ExprDesignatedInit designated_init;
		ExprDesignator designator_expr;
		ExprNamedArgument named_argument_expr;
		ExprEvalNamedArgument eval_named_argument_expr;
		ExprEmbedExpr embed_expr;
		Expr*[] exec_expr;
		ExprAsmArg expr_asm_arg;
		ExprCompoundLiteral expr_compound_literal;
		Expr*[] expression_list;
		ExprIntToBool int_to_bool_expr;
		ExprExtTrunc ext_trunc_expr;
		ExprGenericIdent generic_ident_expr;
		ExprDefaultArg default_arg_expr;
		ExprIdentifierRaw hash_ident_expr;
		ExprUnresolvedIdentifier unresolved_ident_expr;
		Decl* ident_expr;
		Expr*[] initializer_list;
		Expr* inner_expr;
		ExprMakeAny make_any_expr;
		ExprMakeSlice make_slice_expr;
		SubscriptIndex vaarg_index;
		ExprTypeProperty type_property_expr;
		Decl* lambda_expr;
		ExprMacroBlock macro_block;
		ExprMacroBody macro_body_expr;
		Decl* member_get_expr;
		OperatorOverload overload_expr;
		ExprPointerOffset pointer_offset_expr;
		ExprGuard rethrow_expr;
		ExprSliceAssign slice_assign_expr;
		ExprSubscriptAssign subscript_assign_expr;
		ExprSubscript subscript_expr;
		ExprCtSubscript ct_subscript_expr;
		ExprSlice slice_expr;
		ExprSwizzle swizzle_expr;
		ExprTernary ternary_expr;
		ExprTwo two_expr;
		BuiltinDefine benchmark_hook_expr;
		ExprTypeCall type_call_expr;
		BuiltinDefine test_hook_expr;
		Expr*[] try_unwrap_chain_expr;
		ExprTry try_expr;
		ExprUnresolvedTry unresolved_try_expr;
		TypeInfo* type_expr;
		TypeInfo* typeid_expr;
		ExprTypeidInfo typeid_info_expr;
		ExprUnary unary_expr;
		ExprRange vasplat_expr;
		ExprCtCall ct_call_expr;
		ExprCtArg ct_arg_expr;
		ExprCtAndOr ct_and_or_expr;
		ExprCastable castable_expr;
	}
}

struct AstCompoundStmt
{
	AstId first_stmt;
	AstId parent_defer;
	SourceLocId end_loc;
	bool is_loop_body;
}

struct AstReturnStmt
{
	<* May be null. *>
	Expr* expr;
	AstId cleanup;
	AstId cleanup_fail;
	bool cleanup_catch;
	<* For block exits. *>
	BlockExit** block_exit_ref;
}

struct FlowCommon
{
	DeclId label;
	bool has_break;
	bool no_exit;
	bool skip_first;
	bool if_chain;
	bool jump;
}

struct AstIfStmt
{
	FlowCommon flow;
	union
	{
		struct
		{
			ExprId cond;
			AstId then_body;
			AstId else_body;
		}
		struct codegen
		{
			void* break_block;
		}
	}
}

struct AstCaseStmt
{
	ExprId expr;
	ExprId to_expr;
	int index;
	bool was_constant;
	Ast* body;
	void* backend_block;
}

struct AstSwitchStmt
{
	FlowCommon flow;
	Ast*[] cases;
	union
	{
		struct
		{
			ExprId cond;
			AstId defer_id;
			Ast* scope_defer;
		}
		struct codegen
		{
			void* exit_block;
			union
			{
				struct retry
				{
					void* block;
					void* retry_var;
				}
				struct jump
				{
					ushort count;
					short min_index;
					short default_index;
					void* jmptable;
				}
			}
		}
	}
}

struct AstForStmt
{
	FlowCommon flow;
	union
	{
		struct
		{
			ExprId cond;
			ExprId incr;
			ExprId init;
			AstId body;
		}
		struct codegen
		{
			void* continue_block;
			void* exit_block;
		}
	}
}

struct AstForeachStmt
{
	FlowCommon flow;
	bool index_by_ref;
	bool value_by_ref;
	bool iterator;
	bool is_reverse;
	ExprId enumeration;
	AstId body;
	DeclId index;
	DeclId variable;
}

struct AstDeferStmt
{
	AstId prev_defer;
	<* Compound statement. *>
	AstId body;
	void* scope;
	bool is_try;
	bool is_catch;
}

struct AstCtIfStmt
{
	Expr* expr;
	AstId elif;
	AstId then;
}

struct AstCtSwitchStmt
{
	ExprId cond;
	Ast*[] body;
}

struct AstCtTypeAssignStmt
{
	String var_name;
	Expr* type_expr;
}

struct AstCtForeachStmt
{
	DeclId index;
	DeclId value;
	AstId body;
	ExprId expr;
}

struct AstContinueBreakStmt
{
	bool is_label;
	bool is_resolved;
	AstId defers;
	union
	{
		Label label;
		AstId ast;
	}
}

struct AstNextcaseStmt
{
	AstId defer_id;
	bool is_resolved;
	bool is_default;
	bool is_expr;
	union
	{
		struct
		{
			Label label;
			ExprId expr;
		}
		struct
		{
			AstId switch_stmt;
			union
			{
				int case_number;
				Expr* nextcase_value;
			}
		}
	}
}

struct AstAsmStmt
{
	String instruction;
	String variant;
	Expr*[] args;
}

struct AsmInlineBlock
{
	Clobbers clobbers;
	AstId asm_stmt;
	Ast*[] labels;
	ExprAsmArg*[] output_vars;
	ExprAsmArg*[] input;
}

struct AstAsmBlock
{
	bool is_volatile;
	bool is_inline;
	bool is_goto;
	bool is_string;
	bool is_aligned;
	union
	{
		AsmInlineBlock* block;
		ExprId asm_string;
	}
}

struct AstAssertStmt
{
	bool is_ensure;
	PanicFunction panic_function;
	ExprId message;
	ExprId expr;
	Expr*[] args;
	String[PANIC_FN_MAX_TEXTS] panic_text;
}

struct Ast
{
	SourceLocId loc;
	AstId next;
	AstKind ast_kind;
	union
	{
		<* Shared by the flow statements. *>
		FlowCommon flow;
		AstAsmBlock asm_block_stmt;
		AstAsmStmt asm_stmt;
		String asm_label;
		AstAssertStmt assert_stmt;
		AstCaseStmt case_stmt;
		AstCompoundStmt compound_stmt;
		AstId ct_compound_stmt;
		AstContinueBreakStmt contbreak_stmt;
		AstId ct_else_stmt;
		AstCtTypeAssignStmt ct_type_assign_stmt;
		AstCtForeachStmt ct_foreach_stmt;
		AstCtIfStmt ct_if_stmt;
		AstCtSwitchStmt ct_switch_stmt;
		Decl* declare_stmt;
		Decl*[] decls_stmt;
		AstDeferStmt defer_stmt;
		Expr* expr_stmt;
		Expr* expand_stmt;
		AstForStmt for_stmt;
		AstForeachStmt foreach_stmt;
		AstIfStmt if_stmt;
		AstNextcaseStmt nextcase_stmt;
		AstReturnStmt return_stmt;
		AstSwitchStmt switch_stmt;
		Decl* var_stmt;
	}
}

<* c3c `HTable` (pointer-keyed hash chains; sema port). *>
struct HTEntry
{
	void* key;
	void* value;
	HTEntry* next;
}

struct HTable
{
	uint mask;
	HTEntry** entries;
}

struct Module
{
	ModulePath* name;
	String short_path;
	<* Extname in case a module is renamed externally. *>
	String extname;
	Decl*[] generic_sections;
	bool is_external;
	bool is_compiler_rt;
	bool is_c_library;
	bool is_exported;
	bool no_extprefix;
	AnalysisStage stage;
	HTable symbols;
	CompilationUnit*[] units;
	Module* parent_module;
	Module* top_module;
	Decl*[] benchmarks;
	Decl*[] tests;
	Decl*[] lambdas_to_evaluate;
	int lambda_count;
	InliningSpan inlined_at;
}

struct CompilationUnit
{
	Module* mod;
	SourceFile* file;
	Decl*[] imports;
	Decl*[] module_aliases;
	Decl*[] public_imports;
	Decl*[] types;
	Decl*[] functions;
	Decl*[] lambdas;
	Decl*[] enums;
	Decl*[] attributes;
	Decl*[] faults;
	String[] links;
	Visibility default_visibility;
	bool default_is_weak;
	Attr* if_attr;
	Attr*[] feat_attributes;
	Decl* default_generic_section;
	Decl*[] generic_decls;
	Decl*[] weak_symbols_skipped;
	bool export_by_default;
	bool is_interface_file;
	bool benchmark_by_default;
	bool test_by_default;
	bool module_generated;
	DeclId module_doc;
	Attr*[] attr_links;
	Decl*[] aliases;
	Decl*[] ct_asserts;
	Decl*[] ct_echos;
	Decl*[] ct_includes;
	Decl*[] vars;
	Decl*[] generated_globals;
	Decl*[] macros;
	Decl*[] methods_to_register;
	Decl*[] methods;
	Decl*[] macro_methods;
	Decl*[] global_decls;
	Decl*[] global_cond_decls;
	Decl* main_function;
	Decl* error_import;
	HTable local_symbols;
	TypeInfo*[] check_type_variable_array;
}

struct ContractDescription
{
	String comment;
	SourceLocId comment_span;
	int comment_len;
	Expr*[] requires;
	Expr*[] ensures;
	ContractParam[] params;
	bool pure;
	bool has_contracts;
	SourceLocId first;
	SourceLocId first_variable_require;
	SourceLocId first_non_require;
	SourceLocId first_contract;
	Expr*[] opt_returns;
	String return_desc;
	Attr* deprecated;
}

// ---------------------------------------------------------------------------
// Id arenas (c3c ARENA_DEF). Index 0 of every arena is reserved, so id 0 is
// "none"; `xptr(0)` asserts, `xptrzero(0)` is null.

Vmem ast_vmem;
Vmem expr_vmem;
Vmem decl_vmem;
Vmem type_info_vmem;
Vmem sourceloc_vmem;

macro @arena_def($Type, #vmem)
{
	if (!#vmem.ptr)
	{
		#vmem.init(4096);
		#vmem.alloc($Type::size);
	}
	return ($Type*)#vmem.alloc($Type::size);
}

fn Ast* ast_calloc() => @arena_def(Ast, ast_vmem);
fn Expr* expr_calloc() => @arena_def(Expr, expr_vmem);
fn Decl* decl_calloc() => @arena_def(Decl, decl_vmem);
fn TypeInfo* type_info_calloc() => @arena_def(TypeInfo, type_info_vmem);
fn SourceLoc* sourceloc_calloc() => @arena_def(SourceLoc, sourceloc_vmem);

fn Ast* astptr(AstId id) @inline { assert(id != 0); return (Ast*)ast_vmem.ptr + id; }
fn Ast* astptrzero(AstId id) @inline => id ? (Ast*)ast_vmem.ptr + id : null;
fn AstId astid(Ast* ptr) @inline => (AstId)(ptr - (Ast*)ast_vmem.ptr);
fn Expr* exprptr(ExprId id) @inline { assert(id != 0); return (Expr*)expr_vmem.ptr + id; }
fn Expr* exprptrzero(ExprId id) @inline => id ? (Expr*)expr_vmem.ptr + id : null;
fn ExprId exprid(Expr* ptr) @inline => (ExprId)(ptr - (Expr*)expr_vmem.ptr);
fn ExprId expridzero(Expr* ptr) @inline => ptr ? exprid(ptr) : 0;
fn Decl* declptr(DeclId id) @inline { assert(id != 0); return (Decl*)decl_vmem.ptr + id; }
fn Decl* declptrzero(DeclId id) @inline => id ? (Decl*)decl_vmem.ptr + id : null;
fn DeclId declid(Decl* ptr) @inline => (DeclId)(ptr - (Decl*)decl_vmem.ptr);
fn DeclId declidzero(Decl* ptr) @inline => ptr ? declid(ptr) : 0;
fn TypeInfo* type_infoptr(TypeInfoId id) @inline { assert(id != 0); return (TypeInfo*)type_info_vmem.ptr + id; }
fn TypeInfo* type_infoptrzero(TypeInfoId id) @inline => id ? (TypeInfo*)type_info_vmem.ptr + id : null;
fn TypeInfoId type_infoid(TypeInfo* ptr) @inline => (TypeInfoId)(ptr - (TypeInfo*)type_info_vmem.ptr);
fn TypeInfoId type_infoidzero(TypeInfo* ptr) @inline => ptr ? type_infoid(ptr) : 0;
fn SourceLoc* sourcelocptr(SourceLocId id) @inline => (SourceLoc*)sourceloc_vmem.ptr + id;
fn SourceLocId sourcelocid(SourceLoc* ptr) @inline => (SourceLocId)(ptr - (SourceLoc*)sourceloc_vmem.ptr);

fn Ast* ast_copy(Ast* ptr) { Ast* x = ast_calloc(); *x = *ptr; return x; }
fn Expr* expr_copy_node(Expr* ptr) { Expr* x = expr_calloc(); *x = *ptr; return x; }
fn Decl* decl_copy_node(Decl* ptr) { Decl* x = decl_calloc(); *x = *ptr; return x; }
fn TypeInfo* type_info_copy_node(TypeInfo* ptr) { TypeInfo* x = type_info_calloc(); *x = *ptr; return x; }

<* c3c INVALID_LOC: id 0 (the reserved, zeroed entry). *>
const SourceLocId INVALID_LOC = 0;

<* c3c `make_loc`. *>
fn SourceLocId make_loc(SourceLoc loc)
{
	SourceLoc* copy = sourceloc_calloc();
	*copy = loc;
	return sourcelocid(copy);
}

<* c3c `copy_loc`. *>
fn SourceLocId copy_loc(SourceLocId loc)
{
	SourceLoc* copy = sourceloc_calloc();
	*copy = *sourcelocptr(loc);
	return sourcelocid(copy);
}

<* c3c `extend_loc_with_token`: `loc` lengthened to end where `after` ends. *>
fn SourceLoc extend_loc_with_token(SourceLoc* loc, SourceLoc* after)
{
	SourceLoc new_loc = *loc;
	new_loc.length = after.offset + after.length - loc.offset;
	return new_loc;
}

<* Release every AST arena (tests; c3c `free_arenas`). *>
fn void ast_memory_reset()
{
	ast_vmem.free();
	expr_vmem.free();
	decl_vmem.free();
	type_info_vmem.free();
	sourceloc_vmem.free();
	if (ast_arena_ready)
	{
		ast_arena.free();
		ast_arena_ready = false;
	}
}
