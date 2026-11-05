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
	switch (node.kind)
	{
		case EMPTY_DECL: repr.tag = NodeTag.EMPTY_DECL; repr.tok = node.empty_decl.semicolon;
		case STATIC_ASSERT:
			repr.tag = NodeTag.STATIC_ASSERT; repr.tok = node.static_assert.assert_tok;
			repr.data[0] = (uint)node.static_assert.cond;
			repr.data[1] = pack_opt_index(node.static_assert.message);
		case FUNCTION:
			NodeFunction f = node.function;
			repr.tag = f.body.is_null() ? NodeTag.FN_PROTO : NodeTag.FN_DEF;
			repr.tok = f.name_tok; repr.data[0] = (uint)f.qt;
			DeclAttr attr; attr.is_static = f.is_static; attr.is_inline = f.is_inline;
			repr.data[1] = (uint)attr;
			repr.data[2] = f.body.is_null() ? pack_opt_index(f.definition) : pack_opt_index(f.body);
		case PARAM:
			repr.tag = NodeTag.PARAM; repr.tok = node.param.name_tok;
			repr.data[0] = (uint)node.param.qt;
			DeclAttr attr; attr.register = node.param.storage_class == ParamStorageClass.REGISTER;
			repr.data[1] = (uint)attr;
		case VARIABLE:
			NodeVariable v = node.variable;
			repr.tag = v.initializer.is_null() ? NodeTag.VARIABLE : NodeTag.VARIABLE_DEF;
			repr.tok = v.name_tok; repr.data[0] = (uint)v.qt;
			DeclAttr attr; attr.is_extern = v.storage_class == VariableStorageClass.EXTERN;
			attr.is_static = v.storage_class == VariableStorageClass.STATIC;
			attr.thread_local = v.thread_local; attr.implicit = v.implicit;
			attr.register = v.storage_class == VariableStorageClass.REGISTER;
			repr.data[1] = (uint)attr;
			repr.data[2] = v.initializer.is_null() ? pack_opt_index(v.definition) : pack_opt_index(v.initializer);
		case TYPEDEF:
			repr.tag = NodeTag.TYPEDEF; repr.tok = node.type_def.name_tok;
			repr.data[0] = (uint)node.type_def.qt; repr.data[1] = node.type_def.implicit ? 1 : 0;
		case GLOBAL_ASM:
			repr.tag = NodeTag.GLOBAL_ASM; repr.tok = node.global_asm.asm_tok;
			repr.data[0] = (uint)node.global_asm.asm_str;
		case STRUCT_DECL: case UNION_DECL: case ENUM_DECL:
			NodeContainerDecl d = node.container_decl;
			repr.tok = d.name_or_kind_tok; repr.data[0] = (uint)d.container_qt;
			if (d.fields.len > 2) {
				ExtraSpan span = self.add_extra(d.fields); repr.data[1] = span.index; repr.data[2] = span.len;
				repr.tag = node.kind == NodeKind.STRUCT_DECL ? NodeTag.STRUCT_DECL : node.kind == NodeKind.UNION_DECL ? NodeTag.UNION_DECL : NodeTag.ENUM_DECL;
			} else {
				repr.data[1] = pack_elem(d.fields, 0); repr.data[2] = pack_elem(d.fields, 1);
				repr.tag = node.kind == NodeKind.STRUCT_DECL ? NodeTag.STRUCT_DECL_TWO : node.kind == NodeKind.UNION_DECL ? NodeTag.UNION_DECL_TWO : NodeTag.ENUM_DECL_TWO;
			}
		case STRUCT_FORWARD_DECL: case UNION_FORWARD_DECL: case ENUM_FORWARD_DECL:
			NodeContainerForwardDecl d = node.container_forward_decl;
			repr.tok = d.name_or_kind_tok; repr.data[0] = (uint)d.container_qt;
			repr.tag = node.kind == NodeKind.STRUCT_FORWARD_DECL ? NodeTag.STRUCT_FORWARD_DECL : node.kind == NodeKind.UNION_FORWARD_DECL ? NodeTag.UNION_FORWARD_DECL : NodeTag.ENUM_FORWARD_DECL;
		case ENUM_FIELD:
			repr.tag = NodeTag.ENUM_FIELD; repr.tok = node.enum_field.name_tok;
			repr.data[0] = (uint)node.enum_field.qt; repr.data[1] = pack_opt_index(node.enum_field.init);
		case RECORD_FIELD:
			repr.tag = NodeTag.RECORD_FIELD; repr.tok = node.record_field.name_or_first_tok;
			repr.data[0] = (uint)node.record_field.qt; repr.data[1] = pack_opt_index(node.record_field.bit_width);
		case CODEGEN_DIAGNOSTIC:
			NodeCodegenDiagnostic d = node.codegen_diagnostic;
			repr.tag = NodeTag.CODEGEN_DIAGNOSTIC; repr.tok = d.tok;
			DiagnosticPack pack; pack.is_warning = d.kind == diagnostics::MessageKind.WARNING;
			pack.attribute_warning = d.has_opt && d.opt == diagnostics::Option.ATTRIBUTE_WARNING;
			repr.data[0] = (uint)pack;
			ExtraSpan span = self.add_extra(((NodeIndex*)d.text.ptr)[:d.text.len]); repr.data[1] = span.index; repr.data[2] = span.len;
		case ALIGNAS_TYPE:
			repr.tag = NodeTag.ALIGNAS_TYPE; repr.tok = node.alignas_type.alignas_tok; repr.data[0] = (uint)node.alignas_type.qt;
		case IDENTIFIER_ARG:
			repr.tag = NodeTag.IDENTIFIER_ARG; repr.tok = node.identifier_arg.identifier_tok;
		default: unreachable();
	}
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
	NodeRepr repr = self.nodes[index];
	uint[3] data = repr.data;
	switch (repr.tag)
	{
		case EMPTY_DECL: return { .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = repr.tok } };
		case STATIC_ASSERT: return { .kind = NodeKind.STATIC_ASSERT, .static_assert = { .assert_tok = repr.tok, .cond = (NodeIndex)data[0], .message = unpack_opt_index(data[1]) } };
		case FN_PROTO: case FN_DEF:
			DeclAttr attr = (DeclAttr)data[1];
			return { .kind = NodeKind.FUNCTION, .function = { .name_tok = repr.tok, .qt = (QualType)data[0], .is_static = attr.is_static, .is_inline = attr.is_inline, .body = repr.tag == NodeTag.FN_DEF ? unpack_opt_index(data[2]) : type_store::NODE_NULL, .definition = repr.tag == NodeTag.FN_PROTO ? unpack_opt_index(data[2]) : type_store::NODE_NULL } };
		case PARAM:
			DeclAttr attr = (DeclAttr)data[1];
			return { .kind = NodeKind.PARAM, .param = { .name_tok = repr.tok, .qt = (QualType)data[0], .storage_class = attr.register ? ParamStorageClass.REGISTER : ParamStorageClass.AUTO } };
		case VARIABLE: case VARIABLE_DEF:
			DeclAttr attr = (DeclAttr)data[1];
			VariableStorageClass sc = attr.is_static ? VariableStorageClass.STATIC : attr.is_extern ? VariableStorageClass.EXTERN : attr.register ? VariableStorageClass.REGISTER : VariableStorageClass.AUTO;
			return { .kind = NodeKind.VARIABLE, .variable = { .name_tok = repr.tok, .qt = (QualType)data[0], .storage_class = sc, .thread_local = attr.thread_local, .implicit = attr.implicit, .initializer = repr.tag == NodeTag.VARIABLE_DEF ? unpack_opt_index(data[2]) : type_store::NODE_NULL, .definition = repr.tag == NodeTag.VARIABLE ? unpack_opt_index(data[2]) : type_store::NODE_NULL } };
		case TYPEDEF: return { .kind = NodeKind.TYPEDEF, .type_def = { .name_tok = repr.tok, .qt = (QualType)data[0], .implicit = data[1] != 0 } };
		case GLOBAL_ASM: return { .kind = NodeKind.GLOBAL_ASM, .global_asm = { .asm_tok = repr.tok, .asm_str = (NodeIndex)data[0] } };
		case STRUCT_DECL: case UNION_DECL: case ENUM_DECL: case STRUCT_DECL_TWO: case UNION_DECL_TWO: case ENUM_DECL_TWO:
			NodeKind kind = repr.tag.kind;
			NodeIndex[] fields = (repr.tag == NodeTag.STRUCT_DECL || repr.tag == NodeTag.UNION_DECL || repr.tag == NodeTag.ENUM_DECL) ? ((NodeIndex*)self.extra.data)[data[1]..data[1]+data[2]] : unpack_elems(data[1..3]);
			return { .kind = kind, .container_decl = { .name_or_kind_tok = repr.tok, .container_qt = (QualType)data[0], .fields = fields } };
		case STRUCT_FORWARD_DECL: case UNION_FORWARD_DECL: case ENUM_FORWARD_DECL: return { .kind = repr.tag.kind, .container_forward_decl = { .name_or_kind_tok = repr.tok, .container_qt = (QualType)data[0], .definition = type_store::NODE_NULL } };
		case ENUM_FIELD: return { .kind = NodeKind.ENUM_FIELD, .enum_field = { .name_tok = repr.tok, .qt = (QualType)data[0], .init = unpack_opt_index(data[1]) } };
		case RECORD_FIELD: return { .kind = NodeKind.RECORD_FIELD, .record_field = { .name_or_first_tok = repr.tok, .qt = (QualType)data[0], .bit_width = unpack_opt_index(data[1]) } };
		case CODEGEN_DIAGNOSTIC:
			DiagnosticPack pack = (DiagnosticPack)data[0];
			return { .kind = NodeKind.CODEGEN_DIAGNOSTIC, .codegen_diagnostic = { .tok = repr.tok, .kind = pack.is_warning ? diagnostics::MessageKind.WARNING : diagnostics::MessageKind.ERROR, .has_opt = pack.attribute_warning, .opt = diagnostics::Option.ATTRIBUTE_WARNING, .text = ((uint*)self.extra.data.ptr)[data[1]..data[1]+data[2]] } };
		case ALIGNAS_TYPE: return { .kind = NodeKind.ALIGNAS_TYPE, .alignas_type = { .alignas_tok = repr.tok, .qt = (QualType)data[0] } };
		case IDENTIFIER_ARG: return { .kind = NodeKind.IDENTIFIER_ARG, .identifier_arg = { .identifier_tok = repr.tok } };
		default: unreachable();
	}
}
