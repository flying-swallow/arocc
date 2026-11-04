// Port of the declaration/type/record node families of src/aro/Tree.zig
// (`setNode` and `Node.Index.get` arms) — plan 16 stage 1 agent 16.2
// `decl-nodes`. Part of module aro::tree (see tree.c3).
//
// Families handled here (`NodeKind.family == DECL`): EMPTY_DECL,
// STATIC_ASSERT, FUNCTION, PARAM, VARIABLE, TYPEDEF, GLOBAL_ASM,
// STRUCT/UNION/ENUM_DECL, STRUCT/UNION/ENUM_FORWARD_DECL, ENUM_FIELD,
// RECORD_FIELD, CODEGEN_DIAGNOSTIC, ALIGNAS_TYPE, IDENTIFIER_ARG.
// Storage tags and data layouts: docs/c3-tree-tags.md section 2.
//
// Stage 0 (contract): signatures only.
module aro::tree;
import aro::tokens, aro::type_store, aro::diagnostics;

<*
 Zig `setNode` for a DECL-family node: fill `repr.tag`, `repr.data` and
 `repr.tok`, appending to `self.extra` where the layout needs it:
  - FUNCTION -> FN_DEF (data[2] = body) when body is set, else FN_PROTO
    (data[2] = definition); data[1] = DeclAttr{is_static, is_inline}.
  - VARIABLE -> VARIABLE_DEF (data[2] = initializer) when set, else VARIABLE
    (data[2] = definition); data[1] = DeclAttr{is_extern, is_static,
    thread_local, implicit, register} from storage_class/flags.
  - PARAM: data[1] = DeclAttr{register}.
  - STRUCT/UNION/ENUM_DECL: fields.len > 2 -> *_DECL with add_extra
    (data[1] = start, data[2] = len); else *_DECL_TWO with pack_elem 0 and 1.
  - *_FORWARD_DECL: only container_qt; `definition` is not stored (Zig TODO).
  - CODEGEN_DIAGNOSTIC: data[0] = DiagnosticPack (kind must be ERROR or
    WARNING, opt only ATTRIBUTE_WARNING; anything else is unreachable),
    data[1..2] = add_extra(text words).
 @require node.kind.family == DECL
*>
fn void Tree.encode_decl(&self, Node node, NodeRepr* repr)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Node.Index.get` for a DECL-family storage tag: decode `nodes[index]`.
 FN_PROTO gives body NODE_NULL; FN_DEF gives definition NODE_NULL;
 VARIABLE gives initializer NODE_NULL; VARIABLE_DEF gives definition
 NODE_NULL; storage class precedence is static, extern, register, auto;
 *_DECL_TWO uses unpack_elems over data[1..3] (slice aliases node storage);
 *_FORWARD_DECL always decodes definition = NODE_NULL; TYPEDEF implicit is
 data[1] != 0.
 @require index.tag(self).kind.family == DECL
*>
fn Node Tree.decode_decl(&self, NodeIndex index)
{
	unreachable("stage 0 stub");
}
