// Port of the declaration/type/record node families of src/aro/Tree.zig
// (`setNode` and `Node.Index.get` arms) — plan 16 stage 1 agent 16.2
// `decl-nodes`. Part of module aro::tree (see tree.c3).
//
// Families handled here (`NodeKind.family == DECL`): EMPTY_DECL,
// STATIC_ASSERT, FUNCTION, PARAM, VARIABLE, TYPEDEF, GLOBAL_ASM,
// STRUCT/UNION/ENUM_DECL, STRUCT/UNION/ENUM_FORWARD_DECL, ENUM_FIELD,
// RECORD_FIELD, CODEGEN_DIAGNOSTIC, ALIGNAS_TYPE, IDENTIFIER_ARG.
// Storage forms and data layouts: docs/c3-tree-tags.md section 2.
//
// Declaration/type/record node codec (plan 16 stage 1).
module aro::tree;
import aro::tokens, aro::type_store, aro::diagnostics;

<*
 Zig `setNode` for a DECL-family node: build its `NodeRepr` (kind, form,
 data, tok), appending to `self.extra` where the layout needs it:
  - FUNCTION / VARIABLE: `decl` view; form.defined + link = body/initializer
    when set, else link = definition; attr = DeclAttr from flags/storage class.
  - PARAM: `decl` view with attr = DeclAttr{register}.
  - STRUCT/UNION/ENUM_DECL: fields.len > 2 -> `typed_span` over add_extra;
    else form.packed + `typed_list` with pack_elem 0 and 1.
  - *_FORWARD_DECL: only container_qt; `definition` is not stored (Zig TODO).
  - CODEGEN_DIAGNOSTIC: `diagnostic` view (kind must be ERROR or WARNING, opt
    only ATTRIBUTE_WARNING; anything else is unreachable) over the text words.
 @require node.kind.family == DECL
*>
fn NodeRepr Tree.encode_decl(&self, Node node)
{
	NodeRepr repr = { .kind = node.kind };
	switch (node.kind)
	{
		case EMPTY_DECL: repr.tok = node.empty_decl.semicolon;
		case STATIC_ASSERT:
			repr.tok = node.static_assert.assert_tok;
			repr.data.static_assert = { .cond = node.static_assert.cond, .message = node.static_assert.message };
		case FUNCTION:
			NodeFunction f = node.function;
			repr.form.defined = !f.body.is_null();
			repr.tok = f.name_tok;
			repr.data.decl = { .qt = f.qt, .attr = { .is_static = f.is_static, .is_inline = f.is_inline },
			.link = repr.form.defined ? f.body : f.definition };
		case PARAM:
			repr.tok = node.param.name_tok;
			repr.data.decl = { .qt = node.param.qt, .attr = { .register = node.param.storage_class == ParamStorageClass.REGISTER } };
		case VARIABLE:
			NodeVariable v = node.variable;
			repr.form.defined = !v.initializer.is_null();
			repr.tok = v.name_tok;
			repr.data.decl = { .qt = v.qt,
			.attr = { .is_extern = v.storage_class == VariableStorageClass.EXTERN,
			.is_static = v.storage_class == VariableStorageClass.STATIC,
			.thread_local = v.thread_local, .implicit = v.implicit,
			.register = v.storage_class == VariableStorageClass.REGISTER },
			.link = repr.form.defined ? v.initializer : v.definition };
		case TYPEDEF:
			repr.tok = node.type_def.name_tok;
			repr.data.type_def = { .qt = node.type_def.qt, .implicit = node.type_def.implicit ? 1 : 0 };
		case GLOBAL_ASM:
			repr.tok = node.global_asm.asm_tok;
			repr.data.global_asm.asm_str = node.global_asm.asm_str;
		case STRUCT_DECL:
		case UNION_DECL:
		case ENUM_DECL:
			NodeContainerDecl d = node.container_decl;
			repr.tok = d.name_or_kind_tok;
			if (d.fields.len > 2)
			{
				ExtraSpan span = self.add_extra(d.fields);
				repr.data.typed_span = { .qt = d.container_qt, .start = span.index, .len = span.len };
			}
			else
			{
				repr.form.packed = true;
				repr.data.typed_list = { .qt = d.container_qt, .elems = { (NodeIndex)pack_elem(d.fields, 0), (NodeIndex)pack_elem(d.fields, 1) } };
			}
		case STRUCT_FORWARD_DECL:
		case UNION_FORWARD_DECL:
		case ENUM_FORWARD_DECL:
			repr.tok = node.container_forward_decl.name_or_kind_tok;
			repr.data.typed.qt = node.container_forward_decl.container_qt;
		case ENUM_FIELD:
			repr.tok = node.enum_field.name_tok;
			repr.data.field = { .qt = node.enum_field.qt, .opt = node.enum_field.init };
		case RECORD_FIELD:
			repr.tok = node.record_field.name_or_first_tok;
			repr.data.field = { .qt = node.record_field.qt, .opt = node.record_field.bit_width };
		case CODEGEN_DIAGNOSTIC:
			NodeCodegenDiagnostic d = node.codegen_diagnostic;
			repr.tok = d.tok;
			if (d.kind != diagnostics::MessageKind.ERROR && d.kind != diagnostics::MessageKind.WARNING) unreachable();
			if (d.has_opt && d.opt != diagnostics::Option.ATTRIBUTE_WARNING) unreachable();
			ExtraSpan span = self.add_extra(((NodeIndex*)d.text.ptr)[:(usz)d.text.len]);
			repr.data.diagnostic = { .pack = { .is_warning = d.kind == diagnostics::MessageKind.WARNING,
			.attribute_warning = d.has_opt && d.opt == diagnostics::Option.ATTRIBUTE_WARNING },
			.start = span.index, .len = span.len };
		case ALIGNAS_TYPE:
			repr.tok = node.alignas_type.alignas_tok;
			repr.data.typed.qt = node.alignas_type.qt;
		case IDENTIFIER_ARG:
			repr.tok = node.identifier_arg.identifier_tok;
		default: unreachable();
	}
	return repr;
}

<*
 Zig `Node.Index.get` for a DECL-family node: decode `nodes[index]`.
 FUNCTION/VARIABLE without form.defined give body/initializer NODE_NULL,
 with it definition NODE_NULL; storage class precedence is static, extern,
 register, auto; packed *_DECL uses typed_list.elems (slice aliases node
 storage); *_FORWARD_DECL always decodes definition = NODE_NULL.
 @require index.kind(self).family == DECL
*>
fn Node Tree.decode_decl(&self, NodeIndex index)
{
	NodeRepr* repr = self.nodes.get_ref((sz)index);
	NodeData data = repr.data;
	switch (repr.kind)
	{
		case EMPTY_DECL: return
		{
			.kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = repr.tok }
		};
		case STATIC_ASSERT: return
		{
			.kind = NodeKind.STATIC_ASSERT, .static_assert = { .assert_tok = repr.tok, .cond = data.static_assert.cond, .message = data.static_assert.message }
		};
		case FUNCTION:
			DeclAttr attr = data.decl.attr;
			bool defined = repr.form.defined;
			return { .kind = NodeKind.FUNCTION, .function = { .name_tok = repr.tok, .qt = data.decl.qt, .is_static = attr.is_static, .is_inline = attr.is_inline,
			.body = defined ? data.decl.link : type_store::NODE_NULL, .definition = defined ? type_store::NODE_NULL : data.decl.link } };
		case PARAM:
			return
			{
				.kind = NodeKind.PARAM, .param = { .name_tok = repr.tok, .qt = data.decl.qt, .storage_class = data.decl.attr.register ? ParamStorageClass.REGISTER : ParamStorageClass.AUTO }
			};
		case VARIABLE:
			DeclAttr attr = data.decl.attr;
			bool defined = repr.form.defined;
			VariableStorageClass sc = attr.is_static ? VariableStorageClass.STATIC : attr.is_extern ? VariableStorageClass.EXTERN : attr.register ? VariableStorageClass.REGISTER : VariableStorageClass.AUTO;
			return { .kind = NodeKind.VARIABLE, .variable = { .name_tok = repr.tok, .qt = data.decl.qt, .storage_class = sc, .thread_local = attr.thread_local, .implicit = attr.implicit,
			.initializer = defined ? data.decl.link : type_store::NODE_NULL, .definition = defined ? type_store::NODE_NULL : data.decl.link } };
		case TYPEDEF: return
		{
			.kind = NodeKind.TYPEDEF, .type_def = { .name_tok = repr.tok, .qt = data.type_def.qt, .implicit = data.type_def.implicit != 0 }
		};
		case GLOBAL_ASM: return
		{
			.kind = NodeKind.GLOBAL_ASM, .global_asm = { .asm_tok = repr.tok, .asm_str = data.global_asm.asm_str }
		};
		case STRUCT_DECL:
		case UNION_DECL:
		case ENUM_DECL:
			NodeIndex[] fields = repr.form.packed ? unpack_node_elems(repr, 1, 2) : self.extra_nodes(data.typed_span.start, data.typed_span.len);
			return { .kind = repr.kind, .container_decl = { .name_or_kind_tok = repr.tok, .container_qt = data.typed_span.qt, .fields = fields } };
		case STRUCT_FORWARD_DECL:
		case UNION_FORWARD_DECL:
		case ENUM_FORWARD_DECL: return
		{
			.kind = repr.kind, .container_forward_decl = { .name_or_kind_tok = repr.tok, .container_qt = data.typed.qt, .definition = type_store::NODE_NULL }
		};
		case ENUM_FIELD: return
		{
			.kind = NodeKind.ENUM_FIELD, .enum_field = { .name_tok = repr.tok, .qt = data.field.qt, .init = data.field.opt }
		};
		case RECORD_FIELD: return
		{
			.kind = NodeKind.RECORD_FIELD, .record_field = { .name_or_first_tok = repr.tok, .qt = data.field.qt, .bit_width = data.field.opt }
		};
		case CODEGEN_DIAGNOSTIC:
			DiagnosticPack pack = data.diagnostic.pack;
			return { .kind = NodeKind.CODEGEN_DIAGNOSTIC, .codegen_diagnostic = { .tok = repr.tok, .kind = pack.is_warning ? diagnostics::MessageKind.WARNING : diagnostics::MessageKind.ERROR, .has_opt = pack.attribute_warning, .opt = diagnostics::Option.ATTRIBUTE_WARNING, .text = self.extra.array_view()[(usz)data.diagnostic.start :(usz)data.diagnostic.len] } };
		case ALIGNAS_TYPE: return
		{
			.kind = NodeKind.ALIGNAS_TYPE, .alignas_type = { .alignas_tok = repr.tok, .qt = data.typed.qt }
		};
		case IDENTIFIER_ARG: return
		{
			.kind = NodeKind.IDENTIFIER_ARG, .identifier_arg = { .identifier_tok = repr.tok }
		};
		default: unreachable();
	}
}
