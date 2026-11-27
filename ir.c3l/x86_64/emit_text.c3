// Emit lowered x86_64 instructions as GNU assembler text in Intel syntax
// (the operand order of the Zig encoding table). Every instruction is checked
// against the XED-generated encoding rows first. emit_object.c3 encodes the
// same lowered rows into object bytes and resolves their fixups.
module aro::backend::x86_64;
import aro::backend::ir, std::collections::list, std::core::dstring, std::io;

fn String size_keyword(ushort bits)
{
	switch (bits)
	{
		case 8: return "byte ptr ";
		case 16: return "word ptr ";
		case 32: return "dword ptr ";
		case 64: return "qword ptr ";
		// GNU Intel syntax accepts TBYTE PTR for x87 80-bit memory operands.
		case 80: return "tbyte ptr ";
		case 128: return "xmmword ptr ";
		default: return "";
	}
}

fn void write_operand(DString* out, Operand op)
{
	switch (op.kind)
	{
		case NONE: break;
		case REG:
			if (op.reg.class == X87)
			{
				out.appendf("st(%d)", op.reg.enc);
			}
			else
			{
				out.append_string(op.reg.name);
			}
		case IMM: out.appendf("%d", op.imm);
		case TARGET:
			write_symbol(out, op.target);
			if (op.external) out.append_string("@PLT");
		case MEM:
			Memory m = op.mem;
			out.append_string(size_keyword(m.bits));
			switch (m.base_kind)
			{
				case REG:
					out.appendf("[%s", m.base.name);
					if (m.has_index)
					{
						out.appendf(" + %s", m.index.name);
						if (m.scale != 1) out.appendf("*%d", m.scale);
					}
					if (m.disp > 0) out.appendf(" + %d", m.disp);
					if (m.disp < 0) out.appendf(" - %d", -(long)m.disp);
					out.append_char(']');
				case SYMBOL:
				case LABEL:
					out.append_string("[rip + ");
					write_symbol(out, m.name);
					if (m.gotpc) out.append_string("@GOTPCREL");
					if (m.disp > 0) out.appendf(" + %d", m.disp);
					if (m.disp < 0) out.appendf(" - %d", -(long)m.disp);
					out.append_char(']');
			}
	}
}

const String[*] INTEL_OPERATOR_WORDS = {
	"and", "eq", "ge", "gt", "le", "lt", "mod", "ne", "not", "or", "shl", "shr", "xor",
	"byte", "word", "dword", "fword", "qword", "mmword", "tbyte", "oword", "xmmword",
	"ymmword", "zmmword", "ptr", "offset", "flat", "short", "near", "far",
	// Registers GNU as knows that the lowering never uses.
	"cs", "ds", "es", "fs", "gs", "ss", "rip", "eip", "ip", "st",
	"mm0", "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7",
	"k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7",
	"cr0", "cr2", "cr3", "cr4", "cr8", "dr0", "dr1", "dr2", "dr3", "dr6", "dr7",
};

<* Whether GNU as in Intel syntax would read `name` as an operator, size keyword or register. *>
fn bool is_intel_reserved(String name)
{
	String lower = name.to_lower_tcopy();
	foreach (word : INTEL_OPERATOR_WORDS) if (word == lower) return true;
	foreach (reg : Register::values) if (reg.name == lower) return true;
	return false;
}

<* `name` as written in assembly: quoted when Intel syntax would misparse it (a C
   symbol called `byte`, `shl` or `rax`). *>
fn String asm_symbol(String name) => is_intel_reserved(name) ? string::tformat("\"%s\"", name) : name;

fn void write_symbol(DString* out, String name) => out.append_string(asm_symbol(name));

fn void write_linkage(DString* out, ir::Linkage linkage, String name, bool is_weak = false)
{
	switch (linkage)
	{
		case EXTERNAL: out.appendf(is_weak ? "\t.weak %s\n" : "\t.globl %s\n", asm_symbol(name));
		case INTERNAL: out.appendf("\t.local %s\n", asm_symbol(name));
	}
}

fn String data_section_name(ir::DataSection section)
{
	switch (section)
	{
		case EXTERN: return "";
		case DATA: return ".data";
		case RODATA: return ".rodata";
		case BSS: return ".bss";
		case COMMON: return "";
	}
}

fn void write_byte_range(DString* out, char[] bytes, usz start, usz end)
{
	if (start >= end) return;
	out.append_string("\t.byte ");
	for (usz i = start; i < end; i++)
	{
		if (i != start) out.append_string(", ");
		out.appendf("%d", (uint)bytes[i]);
	}
	out.append_char('\n');
}

fn void write_global_data(DString* out, ir::GlobalData* global)
{
	usz pos = 0;
	ulong last_offset = 0;
	bool have_last = false;
	foreach (relocation : global.relocs)
	{
		assert(!have_last || relocation.offset >= last_offset, "global relocations are not sorted by offset");
		last_offset = relocation.offset;
		have_last = true;
		usz relocation_pos = (usz)relocation.offset;
		assert(relocation_pos >= pos && relocation_pos + 8 <= global.bytes.len, "global relocation is outside serialized data");
		write_byte_range(out, global.bytes, pos, relocation_pos);
		out.appendf("\t.quad %s", asm_symbol(relocation.symbol));
		if (relocation.addend > 0) out.appendf("+%d", relocation.addend);
		if (relocation.addend < 0) out.appendf("%d", relocation.addend);
		out.append_char('\n');
		pos = relocation_pos + 8;
	}
	write_byte_range(out, global.bytes, pos, global.bytes.len);
	if ((ulong)global.bytes.len < global.size) out.appendf("\t.zero %d\n", global.size - (ulong)global.bytes.len);
}

fn void write_global_section(DString* out, ir::Decl* decl)
{
	ir::GlobalData* global = &decl.global;
	if (!global.own_section)
	{
		out.appendf("\t.section %s\n", data_section_name(global.section));
		return;
	}
	switch (global.section)
	{
		case EXTERN: unreachable("external globals do not have a section");
		case DATA: out.appendf("\t.section .data.%s,\"aw\",@progbits\n", decl.name);
		case RODATA: out.append_string("\t.section .rodata\n");
		case BSS: out.appendf("\t.section .bss.%s,\"aw\",@nobits\n", decl.name);
		case COMMON: unreachable("common globals do not have a section");
	}
}

fn void write_global_text(DString* out, ir::Decl* decl)
{
	ir::GlobalData* global = &decl.global;
	if (!decl.is_definition())
	{
		// An undefined weak reference must be declared so it may resolve to 0.
		if (decl.is_weak) out.appendf("\t.weak %s\n\n", asm_symbol(decl.name));
		return;
	}
	if (global.section == ir::DataSection.COMMON)
	{
		if (decl.linkage == ir::Linkage.INTERNAL) write_linkage(out, decl.linkage, decl.name);
		uint align = global.align > 0 ? global.align : 1;
		out.appendf("\t.comm %s, %d, %d\n\n", asm_symbol(decl.name), global.size, align);
		return;
	}
	write_linkage(out, decl.linkage, decl.name, decl.is_weak);
	write_global_section(out, decl);
	out.appendf("\t.type %s, @object\n\t.size %s, %d\n", asm_symbol(decl.name), asm_symbol(decl.name), global.size);
	uint align = global.align > 0 ? global.align : 1;
	out.appendf("\t.align %d\n", align);
	out.appendf("%s:\n", asm_symbol(decl.name));
	if (global.section == ir::DataSection.BSS) { out.appendf("\t.zero %d\n", global.size); }
	else { write_global_data(out, global); }
	out.append_char('\n');
}

<* Append the function's lines; NO_ENCODING if an instruction has no table row. *>
fn void? Lowering.write_text(&self, DString* out)
{
	ir::Decl* decl = self.decl;
	out.append_string("\t.text\n");
	write_linkage(out, decl.linkage, decl.name, decl.is_weak);
	out.appendf("\t.p2align %d\n\t.type %s, @function\n%s:\n", log2_alignment(function_alignment(decl)),
		asm_symbol(decl.name), asm_symbol(decl.name));
	foreach (&line : self.lines)
	{
		if (line.is_raw)
		{
			out.appendf("%s\n", line.label);
			continue;
		}
		if (line.is_label)
		{
			out.appendf("%s:\n", line.label);
			continue;
		}
		if (catch find(line.mnemonic, line.ops[:line.op_count]))
		{
			DString shown;
			shown.init(tmem);
			foreach (i, op : line.ops[:line.op_count]) { if (i) shown.append_string(", "); write_operand(&shown, op); }
			self.fail("x86_64 encoding table has no form of '%s %s'", line.mnemonic.name, shown.str_view())!;
		}
		out.appendf("\t%s", line.mnemonic.name);
		foreach (i, op : line.ops[:line.op_count])
		{
			out.append_string(i == 0 ? " " : ", ");
			write_operand(out, op);
		}
		out.append_char('\n');
	}
	out.appendf("\t.size %s, .-%s\n\n", asm_symbol(decl.name), asm_symbol(decl.name));
}

<*
 Lower every declaration of `ir` to GNU assembler text (Intel syntax),
 recording per-function failures in `errors` and continuing past them like
 the Zig Renderer. Returns the text (allocated with `allocator`) or LOWER_FAIL.
 @return? ir::LOWER_FAIL
*>
fn String? render_asm(ir::Ir* ir, Allocator allocator, ir::ErrorList* errors, bool spill_all = false)
{
	DString out;
	out.init(allocator);
	@pool()
	{
		Lowering lowering = { .ir = ir, .errors = errors, .spill_all = spill_all };
		lowering.strings.init(tmem);
		lowering.lines.init(mem);
		defer lowering.lines.free();
		lowering.scratch.init(mem, 64 * 1024);
		defer lowering.scratch.free();
		if (ir.global_asm.len() != 0)
		{
			out.append_string("\t.att_syntax prefix\n");
			foreach (text : ir.global_asm) out.appendf("%s\n", text);
		}
		out.append_string("\t.intel_syntax noprefix\n");
		foreach (&decl : ir.decls)
		{
			if (decl.kind == ir::DeclKind.GLOBAL) continue;
			if (!decl.is_definition()) continue;
			if (catch f = lowering.lower_decl(decl))
			{
				if (f != ir::LOWER_FAIL) { out.free(); return f~; }
				continue;
			}
			if (catch f = lowering.write_text(&out))
			{
				if (f != ir::LOWER_FAIL) { out.free(); return f~; }
			}
		}
		foreach (&decl : ir.decls)
		{
			if (decl.kind == ir::DeclKind.GLOBAL) write_global_text(&out, decl);
		}
		if (lowering.strings.len() != 0)
		{
			out.append_string("\t.section .rodata\n");
			foreach (s : lowering.strings)
			{
				if (s.align > 1)
				{
					uint align_power = 0;
					while ((1u << align_power) < s.align) align_power++;
					out.appendf("\t.p2align %d\n", align_power);
				}
				out.appendf("%s:\n\t.byte ", s.label);
				foreach (i, b : s.bytes) { if (i) out.append_string(", "); out.appendf("%d", b); }
				out.append_char('\n');
			}
		}
	};
	foreach (&decl : ir.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0 || decl.static_init == ir::StaticInit.NONE) continue;
		out.appendf("\t.section .%s,\"aw\"\n\t.p2align 3\n\t.quad %s\n", decl.static_init_section(tmem), asm_symbol(decl.name));
	}
	out.append_string("\t.section .note.GNU-stack,\"\",@progbits\n");
	defer out.free();
	if (errors.len() != 0) return ir::LOWER_FAIL~;
	return out.copy_str(allocator);
}

<* Byte alignment of a function's code: 16, or more when `aligned` asks. *>
fn ulong function_alignment(ir::Decl* decl) => decl.code_align > 16 ? (ulong)decl.code_align : 16;

<* log2 of a power-of-two alignment. *>
fn int log2_alignment(ulong align)
{
	int shift = 0;
	while (((ulong)1 << shift) < align) shift++;
	return shift;
}
