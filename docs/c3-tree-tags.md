# Zig -> C3 AST node and attribute tag mapping (plan 16)

This table records how every tag of `src/aro/Tree.zig`, `src/aro/Attribute.zig`
and `src/aro/Attribute/Map.zig` is represented in the C3 port, so parser work
(plans 18-22) cannot silently drop a tag. Tags are listed in Zig declaration
order; the C3 enums keep that order (ordinals match Zig's tag values).

The rows were generated from the Zig sources at plan 16 stage 0 and checked by
`//test/c3:tree_contract_tests` (tag counts and the storage-tag -> node-kind
mapping). When a Zig tag is added, add it to the C3 enum and to this table.

C3 files (all `module aro::tree` unless noted):

| File | Contents | Plan 16 stage-1 owner |
|---|---|---|
| `src/c3/tree.c3` | handles, `NodeKind`, `NodeTag`, `CastKind`, payload structs, `Node`, `NodeRepr`, `Tree`, storage | 16.1 tree-storage |
| `src/c3/tree_decl.c3` | encode/decode of the DECL family | 16.2 decl-nodes |
| `src/c3/tree_expr.c3` | encode/decode of the STMT and EXPR families, lvalue/bitfield queries | 16.3 expr-stmt-nodes |
| `src/c3/tree_dump.c3` | `write`, `dump`, `dump_attribute`, `dump_node` | 16.4 dump |
| `src/c3/attribute.c3` (`aro::attribute`) | `Attribute`, `AttributeArgs`, `AttributeTag`, `Namespaced` | 16.5 attributes |
| `src/c3/attribute_map.c3` (`aro::attribute_map`) | `AttributeMap`, `AttrReprTag`, `QualType.get_attribute` | 16.5 attributes |
| `src/c3/symbol_stack.c3` (`aro::symbol_stack`) | `SymbolStack`, `Symbol`, `SymbolContext` | 16.6 symbols |

## Conventions

- Handles: Zig `Node.Index` / `Node.OptIndex` are `type_store::NodeIndex` /
  `type_store::NodeOptIndex` (declared by plan 08); Zig `.null` is
  `type_store::NODE_NULL` (0xFFFF_FFFF). Every Zig `?Node.Index` field is a
  `NodeOptIndex`. `aro::tree` adds `NodeOptIndex.unpack/is_null/unwrap` and
  `NodeIndex.pack/get/tok/loc/qt/qt_or_null/tag`.
- Tokens: Zig `TokenIndex` is `aro::tokens::TokenIndex` (written
  `tokens::TokenIndex`, because `aro::type_store` also declares a
  `TokenIndex`). Zig `?TokenIndex` is `has_label` + `label`.
- Zig `Node` (union(enum)) is `Node`: `kind` (`NodeKind`) plus one union
  member per Zig payload *type*; variants sharing a payload type share the
  member (all `Binary` variants use `.binary`).
- Payload field renames: `static` -> `is_static`, `inline` -> `is_inline`;
  `Typedef` member is `.type_def`; `ReturnStmt.operand` (union) is
  `operand` (`ReturnOperandKind`) + `expr` + `implicit_value`;
  `CodegenDiagnostic.opt: ?Option` is `has_opt` + `opt`.
- Small enums: `Param.storage_class` -> `ParamStorageClass`,
  `Variable.storage_class` -> `VariableStorageClass`,
  `CompoundLiteral.storage_class` -> `CompoundLiteralStorageClass`,
  `CharLiteral.kind` -> `CharLiteralKind`, `GNUAssemblyQualifiers` ->
  `GnuAsmQualifiers` (bitstruct, bits volatile/inline/goto),
  `Repr.DeclAttr` -> `DeclAttr` (bits extern/static/inline/thread_local/
  implicit/register), `Repr.DiagnosticPack` -> `DiagnosticPack` (bit 0
  warning, bit 1 attribute-warning).
- Attribute payload fields keep Zig names except `alias` -> `alias_value`
  (member `.alias_args`) and `error` (member `.error_msg`); Zig `?T` fields
  are `has_<field>` + `<field>`; `?std.SemanticVersion` uses `target::SemVer`.
- C3 hash maps cannot hash a `typedef`'d key, so `Tree.value_map`,
  `AttributeMap.decl_attrs` and the symbol scopes are keyed by the
  underlying `uint`.

## 1. `Tree.Node` variants (`union(enum)` tag) -> `tree::NodeKind`

| # | Zig `Node` variant | C3 `NodeKind` | Zig payload | C3 payload struct | `Node` union field | Family / owner |
|---|---|---|---|---|---|---|
| 0 | `empty_decl` | `EMPTY_DECL` | `EmptyDecl` | `NodeEmptyDecl` | `.empty_decl` | DECL / tree_decl.c3 |
| 1 | `static_assert` | `STATIC_ASSERT` | `StaticAssert` | `NodeStaticAssert` | `.static_assert` | DECL / tree_decl.c3 |
| 2 | `function` | `FUNCTION` | `Function` | `NodeFunction` | `.function` | DECL / tree_decl.c3 |
| 3 | `param` | `PARAM` | `Param` | `NodeParam` | `.param` | DECL / tree_decl.c3 |
| 4 | `variable` | `VARIABLE` | `Variable` | `NodeVariable` | `.variable` | DECL / tree_decl.c3 |
| 5 | `typedef` | `TYPEDEF` | `Typedef` | `NodeTypedef` | `.type_def` | DECL / tree_decl.c3 |
| 6 | `global_asm` | `GLOBAL_ASM` | `GlobalAsm` | `NodeGlobalAsm` | `.global_asm` | DECL / tree_decl.c3 |
| 7 | `struct_decl` | `STRUCT_DECL` | `ContainerDecl` | `NodeContainerDecl` | `.container_decl` | DECL / tree_decl.c3 |
| 8 | `union_decl` | `UNION_DECL` | `ContainerDecl` | `NodeContainerDecl` | `.container_decl` | DECL / tree_decl.c3 |
| 9 | `enum_decl` | `ENUM_DECL` | `ContainerDecl` | `NodeContainerDecl` | `.container_decl` | DECL / tree_decl.c3 |
| 10 | `struct_forward_decl` | `STRUCT_FORWARD_DECL` | `ContainerForwardDecl` | `NodeContainerForwardDecl` | `.container_forward_decl` | DECL / tree_decl.c3 |
| 11 | `union_forward_decl` | `UNION_FORWARD_DECL` | `ContainerForwardDecl` | `NodeContainerForwardDecl` | `.container_forward_decl` | DECL / tree_decl.c3 |
| 12 | `enum_forward_decl` | `ENUM_FORWARD_DECL` | `ContainerForwardDecl` | `NodeContainerForwardDecl` | `.container_forward_decl` | DECL / tree_decl.c3 |
| 13 | `enum_field` | `ENUM_FIELD` | `EnumField` | `NodeEnumField` | `.enum_field` | DECL / tree_decl.c3 |
| 14 | `record_field` | `RECORD_FIELD` | `RecordField` | `NodeRecordField` | `.record_field` | DECL / tree_decl.c3 |
| 15 | `labeled_stmt` | `LABELED_STMT` | `LabeledStmt` | `NodeLabeledStmt` | `.labeled_stmt` | STMT / tree_expr.c3 |
| 16 | `compound_stmt` | `COMPOUND_STMT` | `CompoundStmt` | `NodeCompoundStmt` | `.compound_stmt` | STMT / tree_expr.c3 |
| 17 | `if_stmt` | `IF_STMT` | `IfStmt` | `NodeIfStmt` | `.if_stmt` | STMT / tree_expr.c3 |
| 18 | `switch_stmt` | `SWITCH_STMT` | `SwitchStmt` | `NodeSwitchStmt` | `.switch_stmt` | STMT / tree_expr.c3 |
| 19 | `case_stmt` | `CASE_STMT` | `CaseStmt` | `NodeCaseStmt` | `.case_stmt` | STMT / tree_expr.c3 |
| 20 | `default_stmt` | `DEFAULT_STMT` | `DefaultStmt` | `NodeDefaultStmt` | `.default_stmt` | STMT / tree_expr.c3 |
| 21 | `while_stmt` | `WHILE_STMT` | `WhileStmt` | `NodeWhileStmt` | `.while_stmt` | STMT / tree_expr.c3 |
| 22 | `do_while_stmt` | `DO_WHILE_STMT` | `DoWhileStmt` | `NodeDoWhileStmt` | `.do_while_stmt` | STMT / tree_expr.c3 |
| 23 | `for_stmt` | `FOR_STMT` | `ForStmt` | `NodeForStmt` | `.for_stmt` | STMT / tree_expr.c3 |
| 24 | `goto_stmt` | `GOTO_STMT` | `GotoStmt` | `NodeGotoStmt` | `.goto_stmt` | STMT / tree_expr.c3 |
| 25 | `computed_goto_stmt` | `COMPUTED_GOTO_STMT` | `ComputedGotoStmt` | `NodeComputedGotoStmt` | `.computed_goto_stmt` | STMT / tree_expr.c3 |
| 26 | `continue_stmt` | `CONTINUE_STMT` | `ContinueStmt` | `NodeContinueStmt` | `.continue_stmt` | STMT / tree_expr.c3 |
| 27 | `break_stmt` | `BREAK_STMT` | `BreakStmt` | `NodeBreakStmt` | `.break_stmt` | STMT / tree_expr.c3 |
| 28 | `null_stmt` | `NULL_STMT` | `NullStmt` | `NodeNullStmt` | `.null_stmt` | STMT / tree_expr.c3 |
| 29 | `return_stmt` | `RETURN_STMT` | `ReturnStmt` | `NodeReturnStmt` | `.return_stmt` | STMT / tree_expr.c3 |
| 30 | `asm_stmt` | `ASM_STMT` | `AsmStmt` | `NodeAsmStmt` | `.asm_stmt` | STMT / tree_expr.c3 |
| 31 | `decl_stmt` | `DECL_STMT` | `DeclStmt` | `NodeDeclStmt` | `.decl_stmt` | STMT / tree_expr.c3 |
| 32 | `assign_expr` | `ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 33 | `mul_assign_expr` | `MUL_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 34 | `div_assign_expr` | `DIV_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 35 | `mod_assign_expr` | `MOD_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 36 | `add_assign_expr` | `ADD_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 37 | `sub_assign_expr` | `SUB_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 38 | `shl_assign_expr` | `SHL_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 39 | `shr_assign_expr` | `SHR_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 40 | `bit_and_assign_expr` | `BIT_AND_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 41 | `bit_xor_assign_expr` | `BIT_XOR_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 42 | `bit_or_assign_expr` | `BIT_OR_ASSIGN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 43 | `compound_assign_dummy_expr` | `COMPOUND_ASSIGN_DUMMY_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 44 | `comma_expr` | `COMMA_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 45 | `bool_or_expr` | `BOOL_OR_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 46 | `bool_and_expr` | `BOOL_AND_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 47 | `bit_or_expr` | `BIT_OR_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 48 | `bit_xor_expr` | `BIT_XOR_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 49 | `bit_and_expr` | `BIT_AND_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 50 | `equal_expr` | `EQUAL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 51 | `not_equal_expr` | `NOT_EQUAL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 52 | `less_than_expr` | `LESS_THAN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 53 | `less_than_equal_expr` | `LESS_THAN_EQUAL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 54 | `greater_than_expr` | `GREATER_THAN_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 55 | `greater_than_equal_expr` | `GREATER_THAN_EQUAL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 56 | `shl_expr` | `SHL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 57 | `shr_expr` | `SHR_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 58 | `add_expr` | `ADD_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 59 | `sub_expr` | `SUB_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 60 | `mul_expr` | `MUL_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 61 | `div_expr` | `DIV_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 62 | `mod_expr` | `MOD_EXPR` | `Binary` | `NodeBinary` | `.binary` | EXPR / tree_expr.c3 |
| 63 | `cast` | `CAST` | `Cast` | `NodeCast` | `.cast` | EXPR / tree_expr.c3 |
| 64 | `addr_of_expr` | `ADDR_OF_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 65 | `deref_expr` | `DEREF_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 66 | `plus_expr` | `PLUS_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 67 | `negate_expr` | `NEGATE_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 68 | `bit_not_expr` | `BIT_NOT_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 69 | `bool_not_expr` | `BOOL_NOT_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 70 | `pre_inc_expr` | `PRE_INC_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 71 | `pre_dec_expr` | `PRE_DEC_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 72 | `imag_expr` | `IMAG_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 73 | `real_expr` | `REAL_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 74 | `post_inc_expr` | `POST_INC_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 75 | `post_dec_expr` | `POST_DEC_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 76 | `paren_expr` | `PAREN_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 77 | `stmt_expr` | `STMT_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 78 | `addr_of_label` | `ADDR_OF_LABEL` | `AddrOfLabel` | `NodeAddrOfLabel` | `.addr_of_label` | EXPR / tree_expr.c3 |
| 79 | `array_access_expr` | `ARRAY_ACCESS_EXPR` | `ArrayAccess` | `NodeArrayAccess` | `.array_access` | EXPR / tree_expr.c3 |
| 80 | `member_access_expr` | `MEMBER_ACCESS_EXPR` | `MemberAccess` | `NodeMemberAccess` | `.member_access` | EXPR / tree_expr.c3 |
| 81 | `member_access_ptr_expr` | `MEMBER_ACCESS_PTR_EXPR` | `MemberAccess` | `NodeMemberAccess` | `.member_access` | EXPR / tree_expr.c3 |
| 82 | `call_expr` | `CALL_EXPR` | `Call` | `NodeCall` | `.call` | EXPR / tree_expr.c3 |
| 83 | `decl_ref_expr` | `DECL_REF_EXPR` | `DeclRef` | `NodeDeclRef` | `.decl_ref` | EXPR / tree_expr.c3 |
| 84 | `enumeration_ref` | `ENUMERATION_REF` | `DeclRef` | `NodeDeclRef` | `.decl_ref` | EXPR / tree_expr.c3 |
| 85 | `builtin_call_expr` | `BUILTIN_CALL_EXPR` | `BuiltinCall` | `NodeBuiltinCall` | `.builtin_call` | EXPR / tree_expr.c3 |
| 86 | `builtin_ref` | `BUILTIN_REF` | `BuiltinRef` | `NodeBuiltinRef` | `.builtin_ref` | EXPR / tree_expr.c3 |
| 87 | `builtin_types_compatible_p` | `BUILTIN_TYPES_COMPATIBLE_P` | `TypesCompatible` | `NodeTypesCompatible` | `.types_compatible` | EXPR / tree_expr.c3 |
| 88 | `builtin_choose_expr` | `BUILTIN_CHOOSE_EXPR` | `Conditional` | `NodeConditional` | `.conditional` | EXPR / tree_expr.c3 |
| 89 | `builtin_convertvector` | `BUILTIN_CONVERTVECTOR` | `Convertvector` | `NodeConvertvector` | `.convertvector` | EXPR / tree_expr.c3 |
| 90 | `builtin_shufflevector` | `BUILTIN_SHUFFLEVECTOR` | `Shufflevector` | `NodeShufflevector` | `.shufflevector` | EXPR / tree_expr.c3 |
| 91 | `builtin_va_arg_pack` | `BUILTIN_VA_ARG_PACK` | `VaArgPack` | `NodeVaArgPack` | `.va_arg_pack` | EXPR / tree_expr.c3 |
| 92 | `builtin_va_arg_pack_len` | `BUILTIN_VA_ARG_PACK_LEN` | `VaArgPack` | `NodeVaArgPack` | `.va_arg_pack` | EXPR / tree_expr.c3 |
| 93 | `bool_literal` | `BOOL_LITERAL` | `Literal` | `NodeLiteral` | `.literal` | EXPR / tree_expr.c3 |
| 94 | `nullptr_literal` | `NULLPTR_LITERAL` | `Literal` | `NodeLiteral` | `.literal` | EXPR / tree_expr.c3 |
| 95 | `int_literal` | `INT_LITERAL` | `Literal` | `NodeLiteral` | `.literal` | EXPR / tree_expr.c3 |
| 96 | `char_literal` | `CHAR_LITERAL` | `CharLiteral` | `NodeCharLiteral` | `.char_literal` | EXPR / tree_expr.c3 |
| 97 | `float_literal` | `FLOAT_LITERAL` | `Literal` | `NodeLiteral` | `.literal` | EXPR / tree_expr.c3 |
| 98 | `string_literal_expr` | `STRING_LITERAL_EXPR` | `CharLiteral` | `NodeCharLiteral` | `.char_literal` | EXPR / tree_expr.c3 |
| 99 | `imaginary_literal` | `IMAGINARY_LITERAL` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 100 | `compound_literal_expr` | `COMPOUND_LITERAL_EXPR` | `CompoundLiteral` | `NodeCompoundLiteral` | `.compound_literal` | EXPR / tree_expr.c3 |
| 101 | `sizeof_expr` | `SIZEOF_EXPR` | `TypeInfo` | `NodeTypeInfo` | `.type_info` | EXPR / tree_expr.c3 |
| 102 | `alignof_expr` | `ALIGNOF_EXPR` | `TypeInfo` | `NodeTypeInfo` | `.type_info` | EXPR / tree_expr.c3 |
| 103 | `countof_expr` | `COUNTOF_EXPR` | `TypeInfo` | `NodeTypeInfo` | `.type_info` | EXPR / tree_expr.c3 |
| 104 | `generic_expr` | `GENERIC_EXPR` | `Generic` | `NodeGeneric` | `.generic` | EXPR / tree_expr.c3 |
| 105 | `generic_association_expr` | `GENERIC_ASSOCIATION_EXPR` | `Generic.Association` | `NodeGenericAssociation` | `.generic_association` | EXPR / tree_expr.c3 |
| 106 | `generic_default_expr` | `GENERIC_DEFAULT_EXPR` | `Generic.Default` | `NodeGenericDefault` | `.generic_default` | EXPR / tree_expr.c3 |
| 107 | `binary_cond_expr` | `BINARY_COND_EXPR` | `Conditional` | `NodeConditional` | `.conditional` | EXPR / tree_expr.c3 |
| 108 | `cond_dummy_expr` | `COND_DUMMY_EXPR` | `Unary` | `NodeUnary` | `.unary` | EXPR / tree_expr.c3 |
| 109 | `cond_expr` | `COND_EXPR` | `Conditional` | `NodeConditional` | `.conditional` | EXPR / tree_expr.c3 |
| 110 | `array_init_expr` | `ARRAY_INIT_EXPR` | `ContainerInit` | `NodeContainerInit` | `.container_init` | EXPR / tree_expr.c3 |
| 111 | `struct_init_expr` | `STRUCT_INIT_EXPR` | `ContainerInit` | `NodeContainerInit` | `.container_init` | EXPR / tree_expr.c3 |
| 112 | `union_init_expr` | `UNION_INIT_EXPR` | `UnionInit` | `NodeUnionInit` | `.union_init` | EXPR / tree_expr.c3 |
| 113 | `array_filler_expr` | `ARRAY_FILLER_EXPR` | `ArrayFiller` | `NodeArrayFiller` | `.array_filler` | EXPR / tree_expr.c3 |
| 114 | `default_init_expr` | `DEFAULT_INIT_EXPR` | `DefaultInit` | `NodeDefaultInit` | `.default_init` | EXPR / tree_expr.c3 |
| 115 | `codegen_diagnostic` | `CODEGEN_DIAGNOSTIC` | `CodegenDiagnostic` | `NodeCodegenDiagnostic` | `.codegen_diagnostic` | DECL / tree_decl.c3 |
| 116 | `alignas_type` | `ALIGNAS_TYPE` | `AlignasType` | `NodeAlignasType` | `.alignas_type` | DECL / tree_decl.c3 |
| 117 | `identifier_arg` | `IDENTIFIER_ARG` | `IdentifierArg` | `NodeIdentifierArg` | `.identifier_arg` | DECL / tree_decl.c3 |

## 2. `Tree.Node.Repr.Tag` (storage tag) -> `tree::NodeTag`

`dN` is `NodeRepr.data[N]`; `opt(x)` is a `NodeOptIndex` (`NODE_NULL` = Zig `null`); "packed" slots hold node indices up to the first `NODE_NULL`; "extra start" indexes `Tree.extra`.

| # | Zig `Repr.Tag` | C3 `NodeTag` | Decodes to `NodeKind` | Layout |
|---|---|---|---|---|
| 0 | `empty_decl` | `EMPTY_DECL` | `EMPTY_DECL` | tok=semicolon |
| 1 | `static_assert` | `STATIC_ASSERT` | `STATIC_ASSERT` | tok=assert_tok; d0=cond; d1=opt(message) |
| 2 | `fn_proto` | `FN_PROTO` | `FUNCTION` | tok=name_tok; d0=qt; d1=DeclAttr{static,inline}; d2=opt(definition); body=null |
| 3 | `fn_def` | `FN_DEF` | `FUNCTION` | tok=name_tok; d0=qt; d1=DeclAttr{static,inline}; d2=body; definition=null |
| 4 | `param` | `PARAM` | `PARAM` | tok=name_tok; d0=qt; d1=DeclAttr{register} |
| 5 | `variable` | `VARIABLE` | `VARIABLE` | tok=name_tok; d0=qt; d1=DeclAttr{extern,static,thread_local,implicit,register}; d2=opt(definition); initializer=null |
| 6 | `variable_def` | `VARIABLE_DEF` | `VARIABLE` | tok=name_tok; d0=qt; d1=DeclAttr{extern,static,thread_local,implicit,register}; d2=initializer; definition=null |
| 7 | `typedef` | `TYPEDEF` | `TYPEDEF` | tok=name_tok; d0=qt; d1=implicit (0/1) |
| 8 | `global_asm` | `GLOBAL_ASM` | `GLOBAL_ASM` | tok=asm_tok; d0=asm_str |
| 9 | `struct_decl` | `STRUCT_DECL` | `STRUCT_DECL` | tok=name_or_kind_tok; d0=container_qt; d1=extra start; d2=fields.len (used when fields.len > 2) |
| 10 | `union_decl` | `UNION_DECL` | `UNION_DECL` | tok=name_or_kind_tok; d0=container_qt; d1=extra start; d2=fields.len (used when fields.len > 2) |
| 11 | `enum_decl` | `ENUM_DECL` | `ENUM_DECL` | tok=name_or_kind_tok; d0=container_qt; d1=extra start; d2=fields.len (used when fields.len > 2) |
| 12 | `struct_decl_two` | `STRUCT_DECL_TWO` | `STRUCT_DECL` | tok=name_or_kind_tok; d0=container_qt; d1,d2=fields[0..2] packed (NODE_NULL ends) |
| 13 | `union_decl_two` | `UNION_DECL_TWO` | `UNION_DECL` | tok=name_or_kind_tok; d0=container_qt; d1,d2=fields[0..2] packed (NODE_NULL ends) |
| 14 | `enum_decl_two` | `ENUM_DECL_TWO` | `ENUM_DECL` | tok=name_or_kind_tok; d0=container_qt; d1,d2=fields[0..2] packed (NODE_NULL ends) |
| 15 | `struct_forward_decl` | `STRUCT_FORWARD_DECL` | `STRUCT_FORWARD_DECL` | tok=name_or_kind_tok; d0=container_qt; definition not stored (decodes null, Zig TODO) |
| 16 | `union_forward_decl` | `UNION_FORWARD_DECL` | `UNION_FORWARD_DECL` | tok=name_or_kind_tok; d0=container_qt; definition not stored (decodes null, Zig TODO) |
| 17 | `enum_forward_decl` | `ENUM_FORWARD_DECL` | `ENUM_FORWARD_DECL` | tok=name_or_kind_tok; d0=container_qt; definition not stored (decodes null, Zig TODO) |
| 18 | `enum_field` | `ENUM_FIELD` | `ENUM_FIELD` | tok=name_tok; d0=qt; d1=opt(init) |
| 19 | `record_field` | `RECORD_FIELD` | `RECORD_FIELD` | tok=name_or_first_tok; d0=qt; d1=opt(bit_width) |
| 20 | `labeled_stmt` | `LABELED_STMT` | `LABELED_STMT` | tok=label_tok; d0=body |
| 21 | `compound_stmt` | `COMPOUND_STMT` | `COMPOUND_STMT` | tok=l_brace_tok; d0=extra start; d1=body.len (used when body.len > 3) |
| 22 | `compound_stmt_three` | `COMPOUND_STMT_THREE` | `COMPOUND_STMT` | tok=l_brace_tok; d0..d2=body[0..3] packed (NODE_NULL ends) |
| 23 | `if_stmt` | `IF_STMT` | `IF_STMT` | tok=if_tok; d0=cond; d1=then_body; d2=opt(else_body); init=null |
| 24 | `if_init` | `IF_INIT` | `IF_STMT` | tok=if_tok; d0=cond; d1=init; d2=then_body; else_body=null |
| 25 | `if_full` | `IF_FULL` | `IF_STMT` | tok=if_tok; d0=cond; d1=init; d2=extra start: [then_body, else_body] |
| 26 | `switch_stmt` | `SWITCH_STMT` | `SWITCH_STMT` | tok=switch_tok; d0=cond; d1=opt(init); d2=body |
| 27 | `case_stmt` | `CASE_STMT` | `CASE_STMT` | tok=case_tok; d0=start; d1=opt(end); d2=body |
| 28 | `default_stmt` | `DEFAULT_STMT` | `DEFAULT_STMT` | tok=default_tok; d0=body |
| 29 | `while_stmt` | `WHILE_STMT` | `WHILE_STMT` | tok=while_tok; d0=cond; d1=body |
| 30 | `do_while_stmt` | `DO_WHILE_STMT` | `DO_WHILE_STMT` | tok=do_tok; d0=cond; d1=body |
| 31 | `for_full` | `FOR_FULL` | `FOR_STMT` | tok=for_tok; d0=init; d1=extra start: [cond, incr]; d2=body |
| 32 | `for_init_cond` | `FOR_INIT_COND` | `FOR_STMT` | tok=for_tok; d0=init; d1=cond; d2=body |
| 33 | `for_init_incr` | `FOR_INIT_INCR` | `FOR_STMT` | tok=for_tok; d0=init; d1=incr; d2=body |
| 34 | `for_cond_incr` | `FOR_COND_INCR` | `FOR_STMT` | tok=for_tok; d0=cond; d1=incr; d2=body |
| 35 | `for_init` | `FOR_INIT` | `FOR_STMT` | tok=for_tok; d0=init; d2=body |
| 36 | `for_cond` | `FOR_COND` | `FOR_STMT` | tok=for_tok; d0=cond; d2=body |
| 37 | `for_incr` | `FOR_INCR` | `FOR_STMT` | tok=for_tok; d0=incr; d2=body |
| 38 | `for_ever` | `FOR_EVER` | `FOR_STMT` | tok=for_tok; d2=body |
| 39 | `goto_stmt` | `GOTO_STMT` | `GOTO_STMT` | tok=label_tok |
| 40 | `computed_goto_stmt` | `COMPUTED_GOTO_STMT` | `COMPUTED_GOTO_STMT` | tok=goto_tok; d0=expr |
| 41 | `continue_stmt` | `CONTINUE_STMT` | `CONTINUE_STMT` | tok=continue_tok; d0=has label (0/1); d1=label token |
| 42 | `break_stmt` | `BREAK_STMT` | `BREAK_STMT` | tok=break_tok; d0=has label (0/1); d1=label token |
| 43 | `null_stmt` | `NULL_STMT` | `NULL_STMT` | tok=semicolon_or_r_brace_tok |
| 44 | `return_stmt` | `RETURN_STMT` | `RETURN_STMT` | tok=return_tok; d0=return_qt; d1=expr (operand .expr) |
| 45 | `return_none_stmt` | `RETURN_NONE_STMT` | `RETURN_STMT` | tok=return_tok; d0=return_qt (operand .none) |
| 46 | `implicit_return` | `IMPLICIT_RETURN` | `RETURN_STMT` | tok=return_tok; d0=return_qt; d1=implicit zero (0/1) (operand .implicit) |
| 47 | `asm_stmt` | `ASM_STMT` | `ASM_STMT` | tok=asm_tok; d0=asm_str; d1=labels.len; d2=extra start: [outputs.len, inputs.len, clobbers.len, outputs (3 words each: name tok, constraint, expr), inputs (3 words each), clobbers, labels]; quals from tag, goto = labels.len > 0 |
| 48 | `asm_stmt_inline` | `ASM_STMT_INLINE` | `ASM_STMT` | tok=asm_tok; d0=asm_str; d1=labels.len; d2=extra start: [outputs.len, inputs.len, clobbers.len, outputs (3 words each: name tok, constraint, expr), inputs (3 words each), clobbers, labels]; quals from tag, goto = labels.len > 0 |
| 49 | `asm_stmt_volatile` | `ASM_STMT_VOLATILE` | `ASM_STMT` | tok=asm_tok; d0=asm_str; d1=labels.len; d2=extra start: [outputs.len, inputs.len, clobbers.len, outputs (3 words each: name tok, constraint, expr), inputs (3 words each), clobbers, labels]; quals from tag, goto = labels.len > 0 |
| 50 | `asm_stmt_inline_volatile` | `ASM_STMT_INLINE_VOLATILE` | `ASM_STMT` | tok=asm_tok; d0=asm_str; d1=labels.len; d2=extra start: [outputs.len, inputs.len, clobbers.len, outputs (3 words each: name tok, constraint, expr), inputs (3 words each), clobbers, labels]; quals from tag, goto = labels.len > 0 |
| 51 | `asm_stmt_simple` | `ASM_STMT_SIMPLE` | `ASM_STMT` | tok=asm_tok; d0=asm_str; d1=GnuAsmQualifiers bits; no operands |
| 52 | `decl_stmt_three` | `DECL_STMT_THREE` | `DECL_STMT` | tok=first_tok; d0..d2=decls[0..3] packed (NODE_NULL ends) |
| 53 | `decl_stmt` | `DECL_STMT` | `DECL_STMT` | tok=first_tok; d0=extra start; d1=decls.len (used when decls.len > 3) |
| 54 | `comma_expr` | `COMMA_EXPR` | `COMMA_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 55 | `assign_expr` | `ASSIGN_EXPR` | `ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 56 | `mul_assign_expr` | `MUL_ASSIGN_EXPR` | `MUL_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 57 | `div_assign_expr` | `DIV_ASSIGN_EXPR` | `DIV_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 58 | `mod_assign_expr` | `MOD_ASSIGN_EXPR` | `MOD_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 59 | `add_assign_expr` | `ADD_ASSIGN_EXPR` | `ADD_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 60 | `sub_assign_expr` | `SUB_ASSIGN_EXPR` | `SUB_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 61 | `shl_assign_expr` | `SHL_ASSIGN_EXPR` | `SHL_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 62 | `shr_assign_expr` | `SHR_ASSIGN_EXPR` | `SHR_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 63 | `bit_and_assign_expr` | `BIT_AND_ASSIGN_EXPR` | `BIT_AND_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 64 | `bit_xor_assign_expr` | `BIT_XOR_ASSIGN_EXPR` | `BIT_XOR_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 65 | `bit_or_assign_expr` | `BIT_OR_ASSIGN_EXPR` | `BIT_OR_ASSIGN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 66 | `compound_assign_dummy_expr` | `COMPOUND_ASSIGN_DUMMY_EXPR` | `COMPOUND_ASSIGN_DUMMY_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 67 | `bool_or_expr` | `BOOL_OR_EXPR` | `BOOL_OR_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 68 | `bool_and_expr` | `BOOL_AND_EXPR` | `BOOL_AND_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 69 | `bit_or_expr` | `BIT_OR_EXPR` | `BIT_OR_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 70 | `bit_xor_expr` | `BIT_XOR_EXPR` | `BIT_XOR_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 71 | `bit_and_expr` | `BIT_AND_EXPR` | `BIT_AND_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 72 | `equal_expr` | `EQUAL_EXPR` | `EQUAL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 73 | `not_equal_expr` | `NOT_EQUAL_EXPR` | `NOT_EQUAL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 74 | `less_than_expr` | `LESS_THAN_EXPR` | `LESS_THAN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 75 | `less_than_equal_expr` | `LESS_THAN_EQUAL_EXPR` | `LESS_THAN_EQUAL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 76 | `greater_than_expr` | `GREATER_THAN_EXPR` | `GREATER_THAN_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 77 | `greater_than_equal_expr` | `GREATER_THAN_EQUAL_EXPR` | `GREATER_THAN_EQUAL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 78 | `shl_expr` | `SHL_EXPR` | `SHL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 79 | `shr_expr` | `SHR_EXPR` | `SHR_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 80 | `add_expr` | `ADD_EXPR` | `ADD_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 81 | `sub_expr` | `SUB_EXPR` | `SUB_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 82 | `mul_expr` | `MUL_EXPR` | `MUL_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 83 | `div_expr` | `DIV_EXPR` | `DIV_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 84 | `mod_expr` | `MOD_EXPR` | `MOD_EXPR` | tok=op_tok; d0=qt; d1=lhs; d2=rhs |
| 85 | `explicit_cast` | `EXPLICIT_CAST` | `CAST` | tok=l_paren; d0=qt; d1=CastKind ordinal; d2=operand |
| 86 | `implicit_cast` | `IMPLICIT_CAST` | `CAST` | tok=l_paren; d0=qt; d1=CastKind ordinal; d2=operand |
| 87 | `addr_of_expr` | `ADDR_OF_EXPR` | `ADDR_OF_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 88 | `deref_expr` | `DEREF_EXPR` | `DEREF_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 89 | `plus_expr` | `PLUS_EXPR` | `PLUS_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 90 | `negate_expr` | `NEGATE_EXPR` | `NEGATE_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 91 | `bit_not_expr` | `BIT_NOT_EXPR` | `BIT_NOT_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 92 | `bool_not_expr` | `BOOL_NOT_EXPR` | `BOOL_NOT_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 93 | `pre_inc_expr` | `PRE_INC_EXPR` | `PRE_INC_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 94 | `pre_dec_expr` | `PRE_DEC_EXPR` | `PRE_DEC_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 95 | `imag_expr` | `IMAG_EXPR` | `IMAG_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 96 | `real_expr` | `REAL_EXPR` | `REAL_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 97 | `post_inc_expr` | `POST_INC_EXPR` | `POST_INC_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 98 | `post_dec_expr` | `POST_DEC_EXPR` | `POST_DEC_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 99 | `paren_expr` | `PAREN_EXPR` | `PAREN_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 100 | `stmt_expr` | `STMT_EXPR` | `STMT_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 101 | `addr_of_label` | `ADDR_OF_LABEL` | `ADDR_OF_LABEL` | tok=label_tok; d0=qt |
| 102 | `array_access_expr` | `ARRAY_ACCESS_EXPR` | `ARRAY_ACCESS_EXPR` | tok=l_bracket_tok; d0=qt; d1=base; d2=index |
| 103 | `call_expr_one` | `CALL_EXPR_ONE` | `CALL_EXPR` | tok=l_paren_tok; d0=qt; d1=callee; d2=args[0] packed (NODE_NULL if none) |
| 104 | `call_expr` | `CALL_EXPR` | `CALL_EXPR` | tok=l_paren_tok; d0=qt; d1=extra start: [callee, args...]; d2=args.len + 1 (used when args.len > 1) |
| 105 | `builtin_call_expr` | `BUILTIN_CALL_EXPR` | `BUILTIN_CALL_EXPR` | tok=builtin_tok; d0=qt; d1=extra start; d2=args.len (used when args.len > 2) |
| 106 | `builtin_call_expr_two` | `BUILTIN_CALL_EXPR_TWO` | `BUILTIN_CALL_EXPR` | tok=builtin_tok; d0=qt; d1,d2=args[0..2] packed (NODE_NULL ends) |
| 107 | `member_access_expr` | `MEMBER_ACCESS_EXPR` | `MEMBER_ACCESS_EXPR` | tok=access_tok; d0=qt; d1=base; d2=member_index |
| 108 | `member_access_ptr_expr` | `MEMBER_ACCESS_PTR_EXPR` | `MEMBER_ACCESS_PTR_EXPR` | tok=access_tok; d0=qt; d1=base; d2=member_index |
| 109 | `decl_ref_expr` | `DECL_REF_EXPR` | `DECL_REF_EXPR` | tok=name_tok; d0=qt; d1=decl |
| 110 | `enumeration_ref` | `ENUMERATION_REF` | `ENUMERATION_REF` | tok=name_tok; d0=qt; d1=decl |
| 111 | `builtin_ref` | `BUILTIN_REF` | `BUILTIN_REF` | tok=name_tok; d0=qt |
| 112 | `bool_literal` | `BOOL_LITERAL` | `BOOL_LITERAL` | tok=literal_tok; d0=qt |
| 113 | `nullptr_literal` | `NULLPTR_LITERAL` | `NULLPTR_LITERAL` | tok=literal_tok; d0=qt |
| 114 | `int_literal` | `INT_LITERAL` | `INT_LITERAL` | tok=literal_tok; d0=qt |
| 115 | `char_literal` | `CHAR_LITERAL` | `CHAR_LITERAL` | tok=literal_tok; d0=qt; d1=CharLiteralKind ordinal |
| 116 | `float_literal` | `FLOAT_LITERAL` | `FLOAT_LITERAL` | tok=literal_tok; d0=qt |
| 117 | `string_literal_expr` | `STRING_LITERAL_EXPR` | `STRING_LITERAL_EXPR` | tok=literal_tok; d0=qt; d1=CharLiteralKind ordinal |
| 118 | `imaginary_literal` | `IMAGINARY_LITERAL` | `IMAGINARY_LITERAL` | tok=op_tok; d0=qt; d1=operand |
| 119 | `sizeof_expr` | `SIZEOF_EXPR` | `SIZEOF_EXPR` | tok=op_tok; d0=qt; d1=opt(expr); d2=operand_qt |
| 120 | `alignof_expr` | `ALIGNOF_EXPR` | `ALIGNOF_EXPR` | tok=op_tok; d0=qt; d1=opt(expr); d2=operand_qt |
| 121 | `countof_expr` | `COUNTOF_EXPR` | `COUNTOF_EXPR` | tok=op_tok; d0=qt; d1=opt(expr); d2=operand_qt |
| 122 | `generic_expr` | `GENERIC_EXPR` | `GENERIC_EXPR` | tok=generic_tok; d0=qt; d1=extra start: [controlling, chosen, rest...]; d2=rest.len + 2 (used when rest.len > 0) |
| 123 | `generic_expr_zero` | `GENERIC_EXPR_ZERO` | `GENERIC_EXPR` | tok=generic_tok; d0=qt; d1=controlling; d2=chosen; rest empty |
| 124 | `generic_association_expr` | `GENERIC_ASSOCIATION_EXPR` | `GENERIC_ASSOCIATION_EXPR` | tok=colon_tok; d0=association_qt; d1=expr (qtOrNull: null) |
| 125 | `generic_default_expr` | `GENERIC_DEFAULT_EXPR` | `GENERIC_DEFAULT_EXPR` | tok=default_tok; d0=expr |
| 126 | `binary_cond_expr` | `BINARY_COND_EXPR` | `BINARY_COND_EXPR` | tok=cond_tok; d0=qt; d1=cond; d2=extra start: [then_expr, else_expr] |
| 127 | `cond_dummy_expr` | `COND_DUMMY_EXPR` | `COND_DUMMY_EXPR` | tok=op_tok; d0=qt; d1=operand |
| 128 | `cond_expr` | `COND_EXPR` | `COND_EXPR` | tok=cond_tok; d0=qt; d1=cond; d2=extra start: [then_expr, else_expr] |
| 129 | `builtin_choose_expr` | `BUILTIN_CHOOSE_EXPR` | `BUILTIN_CHOOSE_EXPR` | tok=cond_tok; d0=qt; d1=cond; d2=extra start: [then_expr, else_expr] |
| 130 | `builtin_types_compatible_p` | `BUILTIN_TYPES_COMPATIBLE_P` | `BUILTIN_TYPES_COMPATIBLE_P` | tok=builtin_tok; d0=lhs qt; d1=rhs qt (qtOrNull: int) |
| 131 | `builtin_convertvector` | `BUILTIN_CONVERTVECTOR` | `BUILTIN_CONVERTVECTOR` | tok=builtin_tok; d0=dest_qt; d1=operand |
| 132 | `builtin_shufflevector` | `BUILTIN_SHUFFLEVECTOR` | `BUILTIN_SHUFFLEVECTOR` | tok=builtin_tok; d0=qt; d1=extra start: [lhs, rhs, indexes...]; d2=indexes.len |
| 133 | `builtin_va_arg_pack` | `BUILTIN_VA_ARG_PACK` | `BUILTIN_VA_ARG_PACK` | tok=builtin_tok (qtOrNull: null) |
| 134 | `builtin_va_arg_pack_len` | `BUILTIN_VA_ARG_PACK_LEN` | `BUILTIN_VA_ARG_PACK_LEN` | tok=builtin_tok (qtOrNull: int) |
| 135 | `array_init_expr` | `ARRAY_INIT_EXPR` | `ARRAY_INIT_EXPR` | tok=l_brace_tok; d0=container_qt; d1=extra start; d2=items.len (used when items.len > 2) |
| 136 | `array_init_expr_two` | `ARRAY_INIT_EXPR_TWO` | `ARRAY_INIT_EXPR` | tok=l_brace_tok; d0=container_qt; d1,d2=items[0..2] packed (NODE_NULL ends) |
| 137 | `struct_init_expr` | `STRUCT_INIT_EXPR` | `STRUCT_INIT_EXPR` | tok=l_brace_tok; d0=container_qt; d1=extra start; d2=items.len (used when items.len > 2) |
| 138 | `struct_init_expr_two` | `STRUCT_INIT_EXPR_TWO` | `STRUCT_INIT_EXPR` | tok=l_brace_tok; d0=container_qt; d1,d2=items[0..2] packed (NODE_NULL ends) |
| 139 | `union_init_expr` | `UNION_INIT_EXPR` | `UNION_INIT_EXPR` | tok=l_brace_tok; d0=union_qt; d1=field_index; d2=opt(initializer) |
| 140 | `array_filler_expr` | `ARRAY_FILLER_EXPR` | `ARRAY_FILLER_EXPR` | tok=last_tok; d0=qt; d1=count low 32 bits; d2=count high 32 bits |
| 141 | `default_init_expr` | `DEFAULT_INIT_EXPR` | `DEFAULT_INIT_EXPR` | tok=last_tok; d0=qt |
| 142 | `compound_literal_expr` | `COMPOUND_LITERAL_EXPR` | `COMPOUND_LITERAL_EXPR` | tok=l_paren_tok; d0=qt; d1=DeclAttr{static,register,thread_local}; d2=initializer |
| 143 | `codegen_diagnostic` | `CODEGEN_DIAGNOSTIC` | `CODEGEN_DIAGNOSTIC` | tok=tok; d0=DiagnosticPack; d1=extra start; d2=text word count (bytes NUL-padded to a multiple of 4, at least one NUL) |
| 144 | `alignas_type` | `ALIGNAS_TYPE` | `ALIGNAS_TYPE` | tok=alignas_tok; d0=qt |
| 145 | `identifier_arg` | `IDENTIFIER_ARG` | `IDENTIFIER_ARG` | tok=identifier_tok (data unused) |

## 3. `Tree.Node.Cast.Kind` -> `tree::CastKind`

| # | Zig | C3 |
|---|---|---|
| 0 | `no_op` | `NO_OP` |
| 1 | `bitcast` | `BITCAST` |
| 2 | `array_to_pointer` | `ARRAY_TO_POINTER` |
| 3 | `lval_to_rval` | `LVAL_TO_RVAL` |
| 4 | `function_to_pointer` | `FUNCTION_TO_POINTER` |
| 5 | `pointer_to_bool` | `POINTER_TO_BOOL` |
| 6 | `pointer_to_int` | `POINTER_TO_INT` |
| 7 | `bool_to_int` | `BOOL_TO_INT` |
| 8 | `bool_to_float` | `BOOL_TO_FLOAT` |
| 9 | `bool_to_pointer` | `BOOL_TO_POINTER` |
| 10 | `int_to_bool` | `INT_TO_BOOL` |
| 11 | `int_to_float` | `INT_TO_FLOAT` |
| 12 | `complex_int_to_complex_float` | `COMPLEX_INT_TO_COMPLEX_FLOAT` |
| 13 | `int_to_pointer` | `INT_TO_POINTER` |
| 14 | `float_to_bool` | `FLOAT_TO_BOOL` |
| 15 | `float_to_int` | `FLOAT_TO_INT` |
| 16 | `complex_float_to_complex_int` | `COMPLEX_FLOAT_TO_COMPLEX_INT` |
| 17 | `int_cast` | `INT_CAST` |
| 18 | `complex_int_cast` | `COMPLEX_INT_CAST` |
| 19 | `complex_int_to_real` | `COMPLEX_INT_TO_REAL` |
| 20 | `real_to_complex_int` | `REAL_TO_COMPLEX_INT` |
| 21 | `float_cast` | `FLOAT_CAST` |
| 22 | `complex_float_cast` | `COMPLEX_FLOAT_CAST` |
| 23 | `complex_float_to_real` | `COMPLEX_FLOAT_TO_REAL` |
| 24 | `real_to_complex_float` | `REAL_TO_COMPLEX_FLOAT` |
| 25 | `to_void` | `TO_VOID` |
| 26 | `null_to_pointer` | `NULL_TO_POINTER` |
| 27 | `union_cast` | `UNION_CAST` |
| 28 | `vector_splat` | `VECTOR_SPLAT` |
| 29 | `atomic_to_non_atomic` | `ATOMIC_TO_NON_ATOMIC` |
| 30 | `non_atomic_to_atomic` | `NON_ATOMIC_TO_ATOMIC` |

## 4. `Attribute.Tag` (= `std.meta.Tag(Attribute.Args)`) -> `attribute::AttributeTag`

| # | Zig tag | C3 `AttributeTag` | Zig payload | C3 `AttributeArgs` union member |
|---|---|---|---|---|
| 0 | `access` | `ACCESS` | `struct {...}` | `ArgsAccess access` |
| 1 | `alias` | `ALIAS` | `struct {...}` | `ArgsAlias alias_args` |
| 2 | `alignment` | `ALIGNMENT` | `?u32` | `ArgsAlignment alignment` |
| 3 | `alloc_align` | `ALLOC_ALIGN` | `struct {...}` | `ArgsAllocAlign alloc_align` |
| 4 | `alloc_size` | `ALLOC_SIZE` | `struct {...}` | `ArgsAllocSize alloc_size` |
| 5 | `allocator` | `ALLOCATOR` | `void` | (none) |
| 6 | `always_inline` | `ALWAYS_INLINE` | `void` | (none) |
| 7 | `appdomain` | `APPDOMAIN` | `void` | (none) |
| 8 | `artificial` | `ARTIFICIAL` | `void` | (none) |
| 9 | `assume_aligned` | `ASSUME_ALIGNED` | `struct {...}` | `ArgsAssumeAligned assume_aligned` |
| 10 | `cleanup` | `CLEANUP` | `struct {...}` | `ArgsFunction cleanup` |
| 11 | `code_seg` | `CODE_SEG` | `struct {...}` | `ArgsCodeSeg code_seg` |
| 12 | `cold` | `COLD` | `void` | (none) |
| 13 | `common` | `COMMON` | `void` | (none) |
| 14 | `const` | `CONST` | `void` | (none) |
| 15 | `constructor` | `CONSTRUCTOR` | `struct {...}` | `ArgsPriority constructor` |
| 16 | `copy` | `COPY` | `struct {...}` | `ArgsFunction copy` |
| 17 | `deprecated` | `DEPRECATED` | `struct {...}` | `ArgsDeprecated deprecated` |
| 18 | `designated_init` | `DESIGNATED_INIT` | `void` | (none) |
| 19 | `destructor` | `DESTRUCTOR` | `struct {...}` | `ArgsPriority destructor` |
| 20 | `dllexport` | `DLLEXPORT` | `void` | (none) |
| 21 | `dllimport` | `DLLIMPORT` | `void` | (none) |
| 22 | `error` | `ERROR` | `[]const u8` | `String error_msg` |
| 23 | `externally_visible` | `EXTERNALLY_VISIBLE` | `void` | (none) |
| 24 | `fallthrough` | `FALLTHROUGH` | `void` | (none) |
| 25 | `flatten` | `FLATTEN` | `void` | (none) |
| 26 | `format` | `FORMAT` | `struct {...}` | `ArgsFormat format` |
| 27 | `format_arg` | `FORMAT_ARG` | `u32` | `uint format_arg` |
| 28 | `gnu_inline` | `GNU_INLINE` | `void` | (none) |
| 29 | `hot` | `HOT` | `void` | (none) |
| 30 | `ifunc` | `IFUNC` | `struct {...}` | `ArgsIfunc ifunc` |
| 31 | `interrupt` | `INTERRUPT` | `void` | (none) |
| 32 | `interrupt_handler` | `INTERRUPT_HANDLER` | `void` | (none) |
| 33 | `jitintrinsic` | `JITINTRINSIC` | `void` | (none) |
| 34 | `leaf` | `LEAF` | `void` | (none) |
| 35 | `malloc` | `MALLOC` | `void` | (none) |
| 36 | `may_alias` | `MAY_ALIAS` | `void` | (none) |
| 37 | `mode` | `MODE` | `enum {...}` | `AttrMode mode` |
| 38 | `naked` | `NAKED` | `void` | (none) |
| 39 | `no_address_safety_analysis` | `NO_ADDRESS_SAFETY_ANALYSIS` | `void` | (none) |
| 40 | `no_icf` | `NO_ICF` | `void` | (none) |
| 41 | `no_instrument_function` | `NO_INSTRUMENT_FUNCTION` | `void` | (none) |
| 42 | `no_profile_instrument_function` | `NO_PROFILE_INSTRUMENT_FUNCTION` | `void` | (none) |
| 43 | `no_reorder` | `NO_REORDER` | `void` | (none) |
| 44 | `no_sanitize` | `NO_SANITIZE` | `[]const Value` | `Value[] no_sanitize` |
| 45 | `no_sanitize_address` | `NO_SANITIZE_ADDRESS` | `void` | (none) |
| 46 | `no_sanitize_coverage` | `NO_SANITIZE_COVERAGE` | `void` | (none) |
| 47 | `no_sanitize_thread` | `NO_SANITIZE_THREAD` | `void` | (none) |
| 48 | `no_sanitize_undefined` | `NO_SANITIZE_UNDEFINED` | `void` | (none) |
| 49 | `no_split_stack` | `NO_SPLIT_STACK` | `void` | (none) |
| 50 | `no_stack_limit` | `NO_STACK_LIMIT` | `void` | (none) |
| 51 | `no_stack_protector` | `NO_STACK_PROTECTOR` | `void` | (none) |
| 52 | `noalias` | `NOALIAS` | `void` | (none) |
| 53 | `noclone` | `NOCLONE` | `void` | (none) |
| 54 | `nocommon` | `NOCOMMON` | `void` | (none) |
| 55 | `warn_unused_result` | `WARN_UNUSED_RESULT` | `?[]const u8` | `ArgsOptMsg warn_unused_result` |
| 56 | `noinit` | `NOINIT` | `void` | (none) |
| 57 | `noinline` | `NOINLINE` | `void` | (none) |
| 58 | `noipa` | `NOIPA` | `void` | (none) |
| 59 | `nonnull` | `NONNULL` | `[]const u32` | `uint[] nonnull` |
| 60 | `nonstring` | `NONSTRING` | `void` | (none) |
| 61 | `noplt` | `NOPLT` | `void` | (none) |
| 62 | `noreturn` | `NORETURN` | `void` | (none) |
| 63 | `nothrow` | `NOTHROW` | `void` | (none) |
| 64 | `optimize` | `OPTIMIZE` | `union(enum) {...}` | `ArgsOptimize optimize` |
| 65 | `packed` | `PACKED` | `void` | (none) |
| 66 | `patchable_function_entry` | `PATCHABLE_FUNCTION_ENTRY` | `struct {}` | (none: Zig `struct {}`) |
| 67 | `persistent` | `PERSISTENT` | `void` | (none) |
| 68 | `process` | `PROCESS` | `void` | (none) |
| 69 | `pure` | `PURE` | `void` | (none) |
| 70 | `reproducible` | `REPRODUCIBLE` | `void` | (none) |
| 71 | `retain` | `RETAIN` | `void` | (none) |
| 72 | `returns_nonnull` | `RETURNS_NONNULL` | `void` | (none) |
| 73 | `returns_twice` | `RETURNS_TWICE` | `void` | (none) |
| 74 | `scalar_storage_order` | `SCALAR_STORAGE_ORDER` | `enum {...}` | `ScalarStorageOrder scalar_storage_order` |
| 75 | `section` | `SECTION` | `[]const u8` | `String section` |
| 76 | `selectany` | `SELECTANY` | `void` | (none) |
| 77 | `sentinel` | `SENTINEL` | `struct {...}` | `ArgsSentinel sentinel` |
| 78 | `simd` | `SIMD` | `struct {...}` | `ArgsSimd simd` |
| 79 | `single` | `SINGLE` | `void` | (none) |
| 80 | `spectre` | `SPECTRE` | `enum {...}` | `Spectre spectre` |
| 81 | `stack_protect` | `STACK_PROTECT` | `void` | (none) |
| 82 | `symver` | `SYMVER` | `struct {...}` | `ArgsSymver symver` |
| 83 | `target` | `TARGET` | `struct {...}` | `ArgsOptions target` |
| 84 | `target_clones` | `TARGET_CLONES` | `struct {...}` | `ArgsOptions target_clones` |
| 85 | `tls_model` | `TLS_MODEL` | `struct {...}` | `ArgsTlsModel tls_model` |
| 86 | `transparent_union` | `TRANSPARENT_UNION` | `void` | (none) |
| 87 | `unavailable` | `UNAVAILABLE` | `?[]const u8` | `ArgsOptMsg unavailable` |
| 88 | `unsafe_indexable` | `UNSAFE_INDEXABLE` | `void` | (none) |
| 89 | `unsequenced` | `UNSEQUENCED` | `void` | (none) |
| 90 | `unused` | `UNUSED` | `void` | (none) |
| 91 | `used` | `USED` | `void` | (none) |
| 92 | `uuid` | `UUID` | `struct {...}` | `ArgsUuid uuid` |
| 93 | `visibility` | `VISIBILITY` | `Visibility` | `Visibility visibility` |
| 94 | `warn_if_not_aligned` | `WARN_IF_NOT_ALIGNED` | `struct {...}` | `ArgsAlignment warn_if_not_aligned` |
| 95 | `warning` | `WARNING` | `[]const u8` | `String warning` |
| 96 | `weak` | `WEAK` | `void` | (none) |
| 97 | `weakref` | `WEAKREF` | `struct {...}` | `ArgsWeakref weakref` |
| 98 | `zero_call_used_regs` | `ZERO_CALL_USED_REGS` | `struct {...}` | `ArgsZeroCallUsedRegs zero_call_used_regs` |
| 99 | `asm_label` | `ASM_LABEL` | `struct {...}` | `ArgsAsmLabel asm_label` |
| 100 | `unaligned` | `UNALIGNED` | `void` | (none) |
| 101 | `internal_linkage` | `INTERNAL_LINKAGE` | `void` | (none) |
| 102 | `availability` | `AVAILABILITY` | `struct {...}` | `ArgsAvailability availability` |
| 103 | `optnone` | `OPTNONE` | `void` | (none) |

## 5. `Attribute/Map.zig` `Repr.Tag` -> `attribute_map::AttrReprTag`

`data` is the token unless noted; `str(s)` is `[s.len, ceil(s.len/4) words of bytes]`.

| # | Zig | C3 | Args | Layout |
|---|---|---|---|---|
| 0 | `packed` | `PACKED` | `packed` (void) | data = tok |
| 1 | `hot` | `HOT` | `hot` (void) | data = tok |
| 2 | `cold` | `COLD` | `cold` (void) | data = tok |
| 3 | `const` | `CONST` | `const` (void) | data = tok |
| 4 | `alignment` | `ALIGNMENT` | `alignment` non-null | data = extra start: [tok, alignment] |
| 5 | `alignment_null` | `ALIGNMENT_NULL` | `alignment` null | data = tok |
| 6 | `deprecated_replacement` | `DEPRECATED_REPLACEMENT` | `deprecated` with replacement | data = extra start: [tok, str(msg), str(replacement)] |
| 7 | `deprecated_reason` | `DEPRECATED_REASON` | `deprecated` with msg only | data = extra start: [tok, str(msg)] |
| 8 | `deprecated` | `DEPRECATED` | `deprecated` without msg | data = tok |
| 9 | `unavailable_reason` | `UNAVAILABLE_REASON` | `unavailable` with msg | data = extra start: [tok, str(msg)] |
| 10 | `unavailable` | `UNAVAILABLE` | `unavailable` null | data = tok |
| 11 | `warning` | `WARNING` | `warning` | data = extra start: [tok, str(msg)] |
| 12 | `error` | `ERROR` | `error` | data = extra start: [tok, str(msg)] |
| 13 | `warn_unused_result_msg` | `WARN_UNUSED_RESULT_MSG` | `warn_unused_result` with msg | data = extra start: [tok, str(msg)] |
| 14 | `warn_unused_result` | `WARN_UNUSED_RESULT` | `warn_unused_result` null | data = tok |
| 15 | `nonnull_zero` | `NONNULL_ZERO` | `nonnull` with 0 positions | data = tok |
| 16 | `nonnull_one` | `NONNULL_ONE` | `nonnull` with 1 position | data = extra start: [tok, position] |
| 17 | `nonnull` | `NONNULL` | `nonnull` with 2+ positions | data = extra start: [tok, len, positions...] |
| 18 | `transparent_union` | `TRANSPARENT_UNION` | `transparent_union` (void) | data = tok |
| 19 | `designated_init` | `DESIGNATED_INIT` | `designated_init` (void) | data = tok |
| 20 | `fallthrough` | `FALLTHROUGH` | `fallthrough` (void) | data = tok |
| 21 | `visibility_default` | `VISIBILITY_DEFAULT` | `visibility` default | data = tok |
| 22 | `visibility_hidden` | `VISIBILITY_HIDDEN` | `visibility` hidden | data = tok |
| 23 | `visibility_protected` | `VISIBILITY_PROTECTED` | `visibility` protected | data = tok |
| 24 | `noreturn` | `NORETURN` | `noreturn` (void) | data = tok |
| 25 | `cleanup` | `CLEANUP` | `cleanup` | data = extra start: [tok, function node] |
| 26 | `always_inline` | `ALWAYS_INLINE` | `always_inline` (void) | data = tok |
| 27 | `gnu_inline` | `GNU_INLINE` | `gnu_inline` (void) | data = tok |
| 28 | `section` | `SECTION` | `section` | data = extra start: [tok, str(name)] |
| 29 | `weak` | `WEAK` | `weak` (void) | data = tok |
| 30 | `selectany` | `SELECTANY` | `selectany` (void) | data = tok |
| 31 | `internal_linkage` | `INTERNAL_LINKAGE` | `internal_linkage` (void) | data = tok |
| 32 | `unsequenced` | `UNSEQUENCED` | `unsequenced` (void) | data = tok |
| 33 | `reproducible` | `REPRODUCIBLE` | `reproducible` (void) | data = tok |
| 34 | `unused` | `UNUSED` | `unused` (void) | data = tok |

Every other `AttributeTag` reaching `put` is Zig `@panic("TODO")` (unreachable in C3).

## 6. `Attribute.Namespaced` -> `attribute::Namespaced`

| Zig union tag | C3 `AttrNamespace` | Zig enum | C3 enum |
|---|---|---|---|
| `standard` | `STANDARD` | `Namespaced.Standard` | `AttrStandard` |
| `gnu` | `GNU` | `Namespaced.Gnu` | `AttrGnu` |
| `clang` | `CLANG` | `Namespaced.Clang` | `AttrClang` |
| `aro` | `ARO` | `Namespaced.Aro` (empty) | none (no union member) |
| `declspec` | `DECLSPEC` | `Namespaced.Declspec` | `AttrDeclspec` |
| `msvc` | `MSVC` | `Namespaced.Msvc` | `AttrMsvc` |
| `riscv` | `RISCV` | `Namespaced.Riscv` | `AttrRiscv` |
| `keyword` | `KEYWORD` | `Namespaced.Keyword` | `AttrKeyword` |

### `Namespaced.Standard` -> `AttrStandard`

| # | Zig | C3 |
|---|---|---|
| 0 | `deprecated` | `DEPRECATED` |
| 1 | `fallthrough` | `FALLTHROUGH` |
| 2 | `maybe_unused` | `MAYBE_UNUSED` |
| 3 | `nodiscard` | `NODISCARD` |
| 4 | `noreturn` | `NORETURN` |
| 5 | `_Noreturn` | `_NORETURN` |
| 6 | `reproducible` | `REPRODUCIBLE` |
| 7 | `unsequenced` | `UNSEQUENCED` |

### `Namespaced.Gnu` -> `AttrGnu`

| # | Zig | C3 |
|---|---|---|
| 0 | `access` | `ACCESS` |
| 1 | `alias` | `ALIAS` |
| 2 | `aligned` | `ALIGNED` |
| 3 | `alloc_align` | `ALLOC_ALIGN` |
| 4 | `alloc_size` | `ALLOC_SIZE` |
| 5 | `always_inline` | `ALWAYS_INLINE` |
| 6 | `artificial` | `ARTIFICIAL` |
| 7 | `assume_aligned` | `ASSUME_ALIGNED` |
| 8 | `cdecl` | `CDECL` |
| 9 | `cleanup` | `CLEANUP` |
| 10 | `cold` | `COLD` |
| 11 | `common` | `COMMON` |
| 12 | `__const` | `__CONST` |
| 13 | `const` | `CONST` |
| 14 | `constructor` | `CONSTRUCTOR` |
| 15 | `copy` | `COPY` |
| 16 | `deprecated` | `DEPRECATED` |
| 17 | `designated_init` | `DESIGNATED_INIT` |
| 18 | `destructor` | `DESTRUCTOR` |
| 19 | `dllexport` | `DLLEXPORT` |
| 20 | `dllimport` | `DLLIMPORT` |
| 21 | `error` | `ERROR` |
| 22 | `externally_visible` | `EXTERNALLY_VISIBLE` |
| 23 | `fallthrough` | `FALLTHROUGH` |
| 24 | `fastcall` | `FASTCALL` |
| 25 | `flatten` | `FLATTEN` |
| 26 | `format_arg` | `FORMAT_ARG` |
| 27 | `format` | `FORMAT` |
| 28 | `gnu_inline` | `GNU_INLINE` |
| 29 | `hot` | `HOT` |
| 30 | `ifunc` | `IFUNC` |
| 31 | `interrupt_handler` | `INTERRUPT_HANDLER` |
| 32 | `interrupt` | `INTERRUPT` |
| 33 | `leaf` | `LEAF` |
| 34 | `malloc` | `MALLOC` |
| 35 | `may_alias` | `MAY_ALIAS` |
| 36 | `mode` | `MODE` |
| 37 | `ms_abi` | `MS_ABI` |
| 38 | `no_address_safety_analysis` | `NO_ADDRESS_SAFETY_ANALYSIS` |
| 39 | `no_icf` | `NO_ICF` |
| 40 | `no_instrument_function` | `NO_INSTRUMENT_FUNCTION` |
| 41 | `no_profile_instrument_function` | `NO_PROFILE_INSTRUMENT_FUNCTION` |
| 42 | `no_reorder` | `NO_REORDER` |
| 43 | `no_sanitize_address` | `NO_SANITIZE_ADDRESS` |
| 44 | `no_sanitize_coverage` | `NO_SANITIZE_COVERAGE` |
| 45 | `no_sanitize_thread` | `NO_SANITIZE_THREAD` |
| 46 | `no_sanitize_undefined` | `NO_SANITIZE_UNDEFINED` |
| 47 | `no_sanitize` | `NO_SANITIZE` |
| 48 | `no_split_stack` | `NO_SPLIT_STACK` |
| 49 | `no_stack_limit` | `NO_STACK_LIMIT` |
| 50 | `no_stack_protector` | `NO_STACK_PROTECTOR` |
| 51 | `noclone` | `NOCLONE` |
| 52 | `nocommon` | `NOCOMMON` |
| 53 | `noinit` | `NOINIT` |
| 54 | `noinline` | `NOINLINE` |
| 55 | `noipa` | `NOIPA` |
| 56 | `nonnull` | `NONNULL` |
| 57 | `nonstring` | `NONSTRING` |
| 58 | `noplt` | `NOPLT` |
| 59 | `noreturn` | `NORETURN` |
| 60 | `nothrow` | `NOTHROW` |
| 61 | `optimize` | `OPTIMIZE` |
| 62 | `packed` | `PACKED` |
| 63 | `patchable_function_entry` | `PATCHABLE_FUNCTION_ENTRY` |
| 64 | `pcs` | `PCS` |
| 65 | `persistent` | `PERSISTENT` |
| 66 | `pure` | `PURE` |
| 67 | `regcall` | `REGCALL` |
| 68 | `regparm` | `REGPARM` |
| 69 | `retain` | `RETAIN` |
| 70 | `returns_nonnull` | `RETURNS_NONNULL` |
| 71 | `returns_twice` | `RETURNS_TWICE` |
| 72 | `riscv_rvv_vector_bits` | `RISCV_RVV_VECTOR_BITS` |
| 73 | `scalar_storage_order` | `SCALAR_STORAGE_ORDER` |
| 74 | `section` | `SECTION` |
| 75 | `selectany` | `SELECTANY` |
| 76 | `sentinel` | `SENTINEL` |
| 77 | `simd` | `SIMD` |
| 78 | `stack_protect` | `STACK_PROTECT` |
| 79 | `stdcall` | `STDCALL` |
| 80 | `symver` | `SYMVER` |
| 81 | `sysv_abi` | `SYSV_ABI` |
| 82 | `target_clones` | `TARGET_CLONES` |
| 83 | `target` | `TARGET` |
| 84 | `thiscall` | `THISCALL` |
| 85 | `tls_model` | `TLS_MODEL` |
| 86 | `transparent_union` | `TRANSPARENT_UNION` |
| 87 | `unused` | `UNUSED` |
| 88 | `used` | `USED` |
| 89 | `vector_size` | `VECTOR_SIZE` |
| 90 | `visibility` | `VISIBILITY` |
| 91 | `warn_if_not_aligned` | `WARN_IF_NOT_ALIGNED` |
| 92 | `warn_unused_result` | `WARN_UNUSED_RESULT` |
| 93 | `warn_unused` | `WARN_UNUSED` |
| 94 | `warning` | `WARNING` |
| 95 | `weak` | `WEAK` |
| 96 | `weakref` | `WEAKREF` |
| 97 | `zero_call_used_regs` | `ZERO_CALL_USED_REGS` |

### `Namespaced.Clang` -> `AttrClang`

| # | Zig | C3 |
|---|---|---|
| 0 | `aarch64_sve_pcs` | `AARCH64_SVE_PCS` |
| 1 | `aarch64_vector_pcs` | `AARCH64_VECTOR_PCS` |
| 2 | `address_space` | `ADDRESS_SPACE` |
| 3 | `always_inline` | `ALWAYS_INLINE` |
| 4 | `arm_sve_vector_bits` | `ARM_SVE_VECTOR_BITS` |
| 5 | `availability` | `AVAILABILITY` |
| 6 | `ext_vector_type` | `EXT_VECTOR_TYPE` |
| 7 | `internal_linkage` | `INTERNAL_LINKAGE` |
| 8 | `matrix_type` | `MATRIX_TYPE` |
| 9 | `neon_polyvector_type` | `NEON_POLYVECTOR_TYPE` |
| 10 | `neon_vector_type` | `NEON_VECTOR_TYPE` |
| 11 | `no_sanitize_address` | `NO_SANITIZE_ADDRESS` |
| 12 | `no_sanitize_memory` | `NO_SANITIZE_MEMORY` |
| 13 | `no_sanitize` | `NO_SANITIZE` |
| 14 | `no_stack_protector` | `NO_STACK_PROTECTOR` |
| 15 | `noderef` | `NODEREF` |
| 16 | `noinline` | `NOINLINE` |
| 17 | `optnone` | `OPTNONE` |
| 18 | `riscv_vector_cc` | `RISCV_VECTOR_CC` |
| 19 | `riscv_vls_cc` | `RISCV_VLS_CC` |
| 20 | `single` | `SINGLE` |
| 21 | `unavailable` | `UNAVAILABLE` |
| 22 | `unsafe_indexable` | `UNSAFE_INDEXABLE` |
| 23 | `vectorcall` | `VECTORCALL` |
| 24 | `warn_unused_result` | `WARN_UNUSED_RESULT` |

### `Namespaced.Aro`

Empty in Zig; `AttrNamespace.ARO` carries no payload.

### `Namespaced.Declspec` -> `AttrDeclspec`

| # | Zig | C3 |
|---|---|---|
| 0 | `align` | `ALIGN` |
| 1 | `allocate` | `ALLOCATE` |
| 2 | `allocator` | `ALLOCATOR` |
| 3 | `appdomain` | `APPDOMAIN` |
| 4 | `code_seg` | `CODE_SEG` |
| 5 | `deprecated` | `DEPRECATED` |
| 6 | `dllexport` | `DLLEXPORT` |
| 7 | `dllimport` | `DLLIMPORT` |
| 8 | `jitintrinsic` | `JITINTRINSIC` |
| 9 | `naked` | `NAKED` |
| 10 | `noalias` | `NOALIAS` |
| 11 | `noinline` | `NOINLINE` |
| 12 | `noreturn` | `NORETURN` |
| 13 | `process` | `PROCESS` |
| 14 | `restrict` | `RESTRICT` |
| 15 | `safebuffers` | `SAFEBUFFERS` |
| 16 | `selectany` | `SELECTANY` |
| 17 | `spectre` | `SPECTRE` |
| 18 | `thread` | `THREAD` |
| 19 | `uuid` | `UUID` |

### `Namespaced.Msvc` -> `AttrMsvc`

| # | Zig | C3 |
|---|---|---|
| 0 | `forceinline_calls` | `FORCEINLINE_CALLS` |
| 1 | `forceinline` | `FORCEINLINE` |
| 2 | `noinline` | `NOINLINE` |

### `Namespaced.Riscv` -> `AttrRiscv`

| # | Zig | C3 |
|---|---|---|
| 0 | `vector_cc` | `VECTOR_CC` |
| 1 | `vls_cc` | `VLS_CC` |

### `Namespaced.Keyword` -> `AttrKeyword`

| # | Zig | C3 |
|---|---|---|
| 0 | `_Alignas` | `_ALIGNAS` |
| 1 | `alignas` | `ALIGNAS` |
| 2 | `noreturn` | `NORETURN` |
| 3 | `asm_label` | `ASM_LABEL` |
| 4 | `nonnull` | `NONNULL` |
| 5 | `null_unspecified` | `NULL_UNSPECIFIED` |
| 6 | `nullable_result` | `NULLABLE_RESULT` |
| 7 | `nullable` | `NULLABLE` |
| 8 | `__forceinline` | `__FORCEINLINE` |
| 9 | `_forceinline` | `_FORCEINLINE` |
| 10 | `__stdcall` | `__STDCALL` |
| 11 | `_stdcall` | `_STDCALL` |
| 12 | `__thiscall` | `__THISCALL` |
| 13 | `_thiscall` | `_THISCALL` |
| 14 | `__vectorcall` | `__VECTORCALL` |
| 15 | `_vectorcall` | `_VECTORCALL` |
| 16 | `__fastcall` | `__FASTCALL` |
| 17 | `_fastcall` | `_FASTCALL` |
| 18 | `_regcall` | `_REGCALL` |
| 19 | `__cdecl` | `__CDECL` |
| 20 | `_cdecl` | `_CDECL` |
| 21 | `ptr64` | `PTR64` |
| 22 | `ptr32` | `PTR32` |
| 23 | `sptr` | `SPTR` |
| 24 | `uptr` | `UPTR` |

### `Namespaced.Standard.Vendors` -> `StandardVendor`

| # | Zig | C3 |
|---|---|---|
| 0 | `aro` | `ARO` |
| 1 | `clang` | `CLANG` |
| 2 | `gnu` | `GNU` |
| 3 | `msvc` | `MSVC` |
| 4 | `riscv` | `RISCV` |

## 7. Attribute payload enums -> `aro::attribute`

Values are the Zig names upper-cased with `-` -> `_`; each C3 enum's `name`
associated value is the Zig spelling. `enum_kind` is the Zig `opts.enum_kind`
(how Attribute/Wip.zig parses the argument).

| Zig | C3 | enum_kind |
|---|---|---|
| `Args.access.access_mode` | `AccessMode` | identifier |
| `Args.format.archetype` | `FormatArchetype` | identifier |
| `Args.mode` (59 machine modes) | `AttrMode` | identifier |
| `Args.scalar_storage_order` | `ScalarStorageOrder` | string |
| `Args.simd.mask` | `SimdMask` | string |
| `Args.spectre` | `Spectre` | identifier |
| `Args.tls_model.model` | `TlsModel` | string |
| `Args.zero_call_used_regs.choice` | `ZeroCallUsedRegs` | string |
| `Args.availability.platform` | `AvailabilityPlatform` | identifier |
| `Args.Visibility` (opts map adds `internal` -> `hidden`) | `Visibility` | string |
| `Args.optimize` union tag | `OptimizeKind` | - |
| `Attribute.Syntax` | `AttributeSyntax` | - |
