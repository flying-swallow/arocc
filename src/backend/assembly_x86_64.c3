// x86-64 GNU assembler data emitter, ported from src/assembly_backend/x86_64.zig.
module aro::backend::assembly_x86_64;
import aro::primitive_value;
import aro::tree, aro::tokens, aro::source, aro::compilation, aro::diagnostics;
import aro::type_store, aro::value, aro::value_interner, aro::text_literal_semantics, aro::code_gen_options;
import std::core::dstring;

enum StorageUnit : char (char bits)
{
	BYTE { 8 },
	SHORT { 16 },
	LONG { 32 },
	QUAD { 64 },
}

excuse NO_STORAGE_UNIT;

fn StorageUnit? storage_unit(ulong bits)
{
	switch (bits)
	{
		case 8: return BYTE;
		case 16: return SHORT;
		case 32: return LONG;
		case 64: return QUAD;
		default: return NO_STORAGE_UNIT~;
	}
}

fn String directive(StorageUnit unit)
{
	switch (unit)
	{
		case BYTE: return "byte";
		case SHORT: return "short";
		case LONG: return "long";
		case QUAD: return "quad";
	}
}

fn ulong truncate(ulong value, StorageUnit unit)
{
	switch (unit)
	{
		case BYTE: return value & 0xFF;
		case SHORT: return value & 0xFFFF;
		case LONG: return value & 0xFFFF_FFFF;
		case QUAD: return value;
	}
}

fn void serialize_int(DString* output, ulong value, StorageUnit unit)
{
	output.appendf("  .%s  0x%x\n", directive(unit), truncate(value, unit));
}

fn void serialize_float(DString* output, primitive_value::PrimitiveValue value)
{
	switch (value.tag)
	{
		case primitive_value::PrimitiveType.F16:
			serialize_int(output, value.f16(), SHORT);
		case primitive_value::PrimitiveType.F32:
			serialize_int(output, value.f32(), LONG);
		case primitive_value::PrimitiveType.F64:
			serialize_int(output, value.f64(), QUAD);
		case primitive_value::PrimitiveType.F80:
			serialize_int(output, value.f80().lo, QUAD);
			serialize_int(output, value.f80().hi, SHORT);
			output.append_string("  .zero 6\n");
		case primitive_value::PrimitiveType.F128:
			serialize_int(output, value.f128().lo, QUAD);
			serialize_int(output, value.f128().hi, QUAD);
		default:
			unreachable("serialize_float of a non-float key");
	}
}

fn void? todo_at(tree::Tree* tree, String message, tokens::TokenIndex tok)
{
	Compilation* comp = tree.comp;
	DString text;
	text.init(comp.gpa);
	defer text.free();
	text.appendf("TODO: %s", message);
	Location loc = tree.tokens[(usz)tok].loc;
	comp.diagnostics.add({
		.kind = diagnostics::MessageKind.ERROR,
		.text = text.str_view(),
		.has_location = true,
		.location = loc.expand(comp),
	})!;
	return compilation::FATAL_ERROR~;
}

fn void? todo_node(tree::Tree* tree, String message, type_store::NodeIndex node)
{
	return todo_at(tree, message, node.tok(tree));
}

fn void? emit_single_value(tree::Tree* tree, type_store::QualType qt, type_store::NodeIndex node, DString* data)
{
	Compilation* comp = tree.comp;
	if (try value = tree.value_of(node))
	{
		ulong bit_size = qt.bit_sizeof(comp);
		type_store::ScalarKind scalar_kind = qt.scalar_kind(comp);
		if (!scalar_kind.is_real) return todo_node(tree, "Codegen _Complex values", node);
		if (scalar_kind.is_int)
		{
			// _Bool has bit_sizeof 1, which maps to no StorageUnit; it is emitted as one byte.
			ulong storage_bits = bit_size;
			if (qt.is(comp, type_store::TypeTag.BOOL)) storage_bits = 8;
			StorageUnit? maybe_unit = storage_unit(storage_bits);
			if (try unit = maybe_unit)
			{
				data.appendf("  .%s ", directive(unit));
				if (qt.is(comp, type_store::TypeTag.BOOL))
				{
					data.append_string(value.is_zero(comp) ? "false" : "true");
				}
				else
				{
					primitive_value::PrimitiveValue key = comp.interner.get(value.ref());
					assert(key.tag.kind == NumberKind.INT, "integer initializer did not have an integer key");
					data.appendf("%s", key);
				}
				data.append_char('\n');
				return;
			}
			return todo_node(tree, "Codegen _BitInt values", node);
		}
		if (scalar_kind.is_float)
		{
			primitive_value::PrimitiveType tag;
			switch (bit_size)
			{
				case 16: tag = primitive_value::PrimitiveType.F16;
				case 32: tag = primitive_value::PrimitiveType.F32;
				case 64: tag = primitive_value::PrimitiveType.F64;
				case 80: tag = primitive_value::PrimitiveType.F80;
				case 128: tag = primitive_value::PrimitiveType.F128;
				default: unreachable("unsupported floating storage width");
			}
			// to_float handles canonical 0.0/1.0 refs, which the interner
			// intentionally exposes as integer keys, and returns raw target bits.
			serialize_float(data, value.to_float(tag, comp));
			return;
		}
		if (scalar_kind.is_pointer) return todo_node(tree, "Codegen pointer", node);
		if (qt.is(comp, type_store::TypeTag.ARRAY))
		{
			primitive_value::PrimitiveValue key = comp.interner.get(value.ref());
			assert(key.tag == primitive_value::PrimitiveType.BYTES, "array initializer did not have a bytes key");
			String directive_name = (ulong)key.bytes.len > bit_size / 8 ? "ascii" : "string";
			data.appendf("  .%s ", directive_name);
			text_literal_semantics::print_string(key.bytes, qt, comp, data, text_literal_semantics::PrintStringStyle.QUOTED)!;
			data.append_char('\n');
			return;
		}
		unreachable("unsupported scalar initializer type");
	}
}

fn void? emit_value(tree::Tree* tree, type_store::QualType qt, type_store::NodeIndex node, DString* data)
{
	switch (node.get(tree).kind)
	{
		case tree::NodeKind.ARRAY_INIT_EXPR:
		case tree::NodeKind.STRUCT_INIT_EXPR:
		case tree::NodeKind.UNION_INIT_EXPR:
			return todo_node(tree, "Codegen multiple inits", node);
		default:
			return emit_single_value(tree, qt, node, data);
	}
}

fn void? gen_function(tree::Tree* tree, tree::NodeFunction function)
{
	return todo_at(tree, "Codegen functions", function.name_tok);
}

fn void? gen_variable(tree::Tree* tree, tree::NodeVariable variable, DString* data)
{
	Compilation* comp = tree.comp;
	type_store::QualType qt = variable.qt;
	bool is_tentative = variable.initializer.is_null();
	ulong size;
	if (try resolved_size = qt.sizeof_or_null(comp))
	{
		size = resolved_size;
	}
	else
	{
		assert(is_tentative && qt.is(comp, type_store::TypeTag.ARRAY), "only tentative arrays may have incomplete size");
		size = qt.child_type(comp).sizeof(comp);
	}
	String name = tree.tok_slice(variable.name_tok);
	uint natural_alignment = qt.alignof(comp);
	uint alignment = natural_alignment;
	if (qt.is(comp, type_store::TypeTag.ARRAY) && size >= 16 && alignment < 16) alignment = 16;

	if (variable.storage_class == tree::VariableStorageClass.STATIC) { data.appendf("  .local \"%s\"\n", name); }
	else { data.appendf("  .globl \"%s\"\n", name); }

	if (is_tentative && comp.code_gen_options.common && !variable.thread_local) // TLS is never common
	{
		data.appendf("  .comm \"%s\", %d, %d\n", name, size, alignment);
		return;
	}
	if (!variable.initializer.is_null())
	{
		if (variable.thread_local && comp.code_gen_options.data_sections)
		{
			data.appendf("  .section .tdata.\"%s\",\"awT\",@progbits\n", name);
		}
		else if (variable.thread_local) { data.append_string("  .section .tdata,\"awT\",@progbits\n"); }
		else if (comp.code_gen_options.data_sections)
		{
			data.appendf("  .section .data.\"%s\",\"aw\",@progbits\n", name);
		}
		else { data.append_string("  .data\n"); }

		data.appendf("  .type \"%s\", @object\n", name);
		data.appendf("  .size \"%s\", %d\n", name, size);
		data.appendf("  .align %d\n", alignment);
		data.appendf("\"%s\":\n", name);
		return emit_value(tree, qt, variable.initializer.unwrap(), data);
	}
	if (variable.thread_local && comp.code_gen_options.data_sections)
	{
		data.appendf("  .section .tbss.\"%s\",\"awT\",@nobits\n", name);
	}
	else if (variable.thread_local) { data.append_string("  .section .tbss,\"awT\",@nobits\n"); }
	else if (comp.code_gen_options.data_sections)
	{
		data.appendf("  .section .bss.\"%s\",\"aw\",@nobits\n", name);
	}
	else { data.append_string("  .bss\n"); }
	data.appendf("  .align %d\n", alignment);
	data.appendf("\"%s\":\n", name);
	data.appendf("  .zero %d\n", size);
}

<*
 Emit x86-64 GNU assembler data and the source-text trailer.
 @return? compilation::FATAL_ERROR
*>
fn void? gen_asm(tree::Tree* tree, DString* data, DString* text)
{
	Compilation* comp = tree.comp;
	if (comp.code_gen_options.debug.kind != code_gen_options::DebugKind.STRIP)
	{
		foreach (src : comp.sources)
		{
			data.appendf("  .file %d \"%s\"\n", src.id.index + 1, src.path);
		}
	}

	foreach (decl : tree.root_decls)
	{
		tree::Node node = decl.get(tree);
		switch (node.kind)
		{
			case tree::NodeKind.STATIC_ASSERT:
			case tree::NodeKind.TYPEDEF:
			case tree::NodeKind.STRUCT_DECL:
			case tree::NodeKind.UNION_DECL:
			case tree::NodeKind.ENUM_DECL:
			case tree::NodeKind.STRUCT_FORWARD_DECL:
			case tree::NodeKind.UNION_FORWARD_DECL:
			case tree::NodeKind.ENUM_FORWARD_DECL:
			case tree::NodeKind.EMPTY_DECL:
				break;
			case tree::NodeKind.FUNCTION:
				if (!node.function.body.is_null()) gen_function(tree, node.function)!;
			case tree::NodeKind.VARIABLE:
				// `extern T x;` only declares x; emitting storage would define it.
				if (node.variable.storage_class == tree::VariableStorageClass.EXTERN && node.variable.initializer.is_null()) break;
				gen_variable(tree, node.variable, data)!;
			case tree::NodeKind.GLOBAL_ASM:
				return todo_at(tree, "Codegen global asm", node.global_asm.asm_tok);
			default:
				// Zig has `unreachable` here; report instead of crashing on new top-level kinds.
				return todo_at(tree, "Codegen top-level declaration", decl.tok(tree));
		}
	}
	text.append_string("  .section  .note.GNU-stack,\"\",@progbits\n");
}
