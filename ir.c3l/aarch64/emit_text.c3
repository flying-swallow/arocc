// ARM64 backend, organized like the sibling x86_64 backend.
module aro::backend::aarch64;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::target;
import std::core::dstring, std::core::string, std::collections::list;

fn String symbol(String name)
{
	if (name.len && name[0] == 1) return string::tformat("\"%s\"", name[1:name.len - 1]);
	return string::tformat("\"_%s\"", name);
}

fn void write_bytes(DString* out, char[] bytes)
{
	foreach (byte : bytes) out.appendf("\t.byte %d\n", (uint)byte);
}

fn void write_global(DString* out, ir::Decl* decl)
{
	ir::GlobalData data = decl.global;
	if (data.section == EXTERN)
	{
		if (decl.is_weak) out.appendf("\t.weak_reference %s\n", symbol(decl.name));
		return;
	}
	if (decl.is_hidden && decl.linkage == EXTERNAL) out.appendf("\t.private_extern %s\n", symbol(decl.name));
	if (decl.retain) out.appendf("\t.no_dead_strip %s\n", symbol(decl.name));
	uint power = 0;
	while (((ulong)1 << power) < data.align) power++;
	if (data.section == COMMON && decl.linkage == EXTERNAL)
	{
		out.appendf("\t.comm %s,%d,%d\n", symbol(decl.name), data.size, power);
		return;
	}
	if (data.section == BSS || data.section == COMMON)
	{
		if (decl.linkage == EXTERNAL) out.appendf("\t.globl %s\n", symbol(decl.name));
		if (decl.is_weak) out.appendf("\t.weak_definition %s\n", symbol(decl.name));
		out.appendf("\t.zerofill __DATA,__bss,%s,%d,%d\n", symbol(decl.name), data.size, power);
		return;
	}
	out.append_string(data.section == RODATA && data.relocs.len == 0 ? "\t.section __TEXT,__const\n" : "\t.data\n");
	if (decl.linkage == EXTERNAL) out.appendf("\t.globl %s\n", symbol(decl.name));
	if (decl.is_weak) out.appendf("\t.weak_definition %s\n", symbol(decl.name));
	out.appendf("\t.p2align %d\n%s:\n", power, symbol(decl.name));
	usz offset = 0;
	foreach (reloc : data.relocs)
	{
		write_bytes(out, data.bytes[offset:(usz)reloc.offset - offset]);
		out.appendf("\t.quad %s%+d\n", symbol(reloc.symbol), reloc.addend);
		offset = (usz)reloc.offset + 8;
	}
	write_bytes(out, data.bytes[offset:data.bytes.len - offset]);
	if (data.size > (ulong)data.bytes.len) out.appendf("\t.space %d\n", data.size - (ulong)data.bytes.len);
}

fn String? render_asm(ir::Ir* graph, Allocator allocator, ir::ErrorList* errors, target::Target target)
{
	Lowering lowering = { .graph = graph, .errors = errors };
	DString out;
	out.init(allocator);
	lowering.lines.init(mem);
	defer lowering.lines.free();
	lowering.constants.init(allocator);
	out.appendf("\t.build_version macos, %d, %d\n", target.os.min.major < 11 ? 11 : target.os.min.major, target.os.min.major < 11 ? 0 : target.os.min.minor);
	defer out.free();
	defer lowering.constants.free();
	@pool()
	{
		if (graph.global_asm.len()) lowering.fail("ARM64: global inline assembly is unsupported")!;
		foreach (&decl : graph.decls)
		{
			if (decl.kind == ir::DeclKind.GLOBAL) { write_global(&out, decl); continue; }
			if (!decl.body.len) continue;
			lowering.function_id++;
			@pool()
			{
				lowering.function(decl)!;
				write_lines(&out, lowering.lines.array_view());
				lowering.lines.clear();
			};
		}
		out.append_string("\t.section __TEXT,__const\n");
		out.append_string(lowering.constants.str_view());
		foreach (&decl : graph.decls)
		{
			if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len || decl.static_init == NONE) continue;
			out.appendf("\t.section __DATA,%s\n\t.p2align 3\n\t.quad %s\n", decl.static_init == CONSTRUCTOR ? "__mod_init_func,mod_init_funcs" : "__mod_term_func,mod_term_funcs", symbol(decl.name));
		}
	};
	return out.copy_str(allocator);
}

fn void write_operand(DString* out, Operand operand)
{
	switch (operand.kind)
	{
		case NONE: break;
		case REG: out.append_string(operand.reg.name);
		case IMM: out.appendf("#%d", operand.immediate);
		case TARGET: out.append_string(operand.target);
		case RELOC: out.appendf("%s%s", operand.target, operand.relocation.name);
		case SHIFT: out.appendf("lsl #%d", operand.immediate);
		case CONDITION: out.append_string(operand.condition.name);
		case MEM:
			Memory memory = operand.memory;
			out.appendf("[%s", memory.base.name);
			if (memory.symbol.len) out.appendf(", %s%s", memory.symbol, memory.relocation.name);
			if (memory.displacement) out.appendf(", #%d", memory.displacement);
			out.append_string(memory.mode == PRE_INDEX ? "]!" : "]");
	}
}

fn void write_lines(DString* out, Line[] lines)
{
	foreach (line : lines)
	{
		if (line.is_raw) { out.append_string(line.label); continue; }
		if (line.is_label) { out.appendf("%s:\n", line.label); continue; }
		out.appendf("\t%s", line.mnemonic.name);
		for (uint i = 0; i < line.op_count; i++)
		{
			out.append_string(i ? ", " : " ");
			write_operand(out, line.ops[i]);
		}
		out.append_char('\n');
	}
}
