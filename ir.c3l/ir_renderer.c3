// Text dump, lowering status and object rendering for the index-based C3 IR.
module aro::backend::ir;
import aro::primitive_value;
import aro::backend::aarch64;
import std::core::string::ansi, aro::value_interner, aro::backend::object, aro::backend::x86_64, aro::target, std::collections::list, std::core::dstring, std::io;

enum IrDumpRole : char { TYPE, INSTRUCTION, REFERENCE, LITERAL, ATTRIBUTE }

fn String IrDumpRole.color(self)
{
	switch (self)
	{
		case TYPE: return ansi::Ansi.BRIGHT_MAGENTA;
		case INSTRUCTION: return ansi::Ansi.BRIGHT_CYAN;
		case REFERENCE: return ansi::Ansi.BRIGHT_BLUE;
		case LITERAL: return ansi::Ansi.BRIGHT_GREEN;
		case ATTRIBUTE: return ansi::Ansi.BRIGHT_YELLOW;
	}
}

fn void? IrDumpRole.apply(self, OutStream w, bool use_ansi)
{
	if (use_ansi) io::write_all(w, self.color())!;
}

fn void? IrDumpRole.write(self, OutStream w, bool use_ansi, String text)
{
	self.apply(w, use_ansi)!;
	io::write_all(w, text)!;
	if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
}

fn void? Ir.dump(&self, OutStream w, bool use_ansi)
{
	foreach (&decl : self.decls)
	{
		switch (decl.kind)
		{
			case FUNCTION: self.dump_decl(decl, decl.name, w, use_ansi)!;
			case GLOBAL: self.dump_global(decl, w, use_ansi)!;
		}
	}
	if (&w.flush) w.flush()!;
}

fn String DataSection.dump_name(self)
{
	switch (self)
	{
		case EXTERN: return "extern";
		case DATA: return "data";
		case RODATA: return "rodata";
		case BSS: return "bss";
		case COMMON: return "common";
	}
}

fn void? Ir.dump_global(&self, Decl* decl, OutStream w, bool use_ansi)
{
	if (!decl.is_definition())
	{
		IrDumpRole.INSTRUCTION.write(w, use_ansi, "extern ")!;
		IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, "@%s", decl.name)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
		if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(w, use_ansi, " internal")!;
		if (decl.is_weak) IrDumpRole.ATTRIBUTE.write(w, use_ansi, " weak")!;
		io::write_all(w, "\n\n")!;
		return;
	}
	IrDumpRole.INSTRUCTION.write(w, use_ansi, "global ")!;
	IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, "@%s", decl.name)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
	io::fprintf(w, " size %d align %d %s", decl.global.size, decl.global.align, decl.global.section.dump_name())!;
	if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(w, use_ansi, " internal")!;
	if (decl.is_weak) IrDumpRole.ATTRIBUTE.write(w, use_ansi, " weak")!;
	if (decl.global.tentative) io::write_all(w, " tentative")!;
	if (decl.global.own_section) io::write_all(w, " own_section")!;
	bool has_data = decl.global.section != DataSection.BSS && decl.global.section != DataSection.COMMON;
	if (has_data)
	{
		io::write_all(w, " {\n    bytes ")!;
		IrDumpRole.LITERAL.apply(w, use_ansi)!; self.write_escaped_bytes(decl.global.bytes, w)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
		w.write_byte('\n')!;
		foreach (relocation : decl.global.relocs)
		{
			io::fprintf(w, "    reloc %d @%s", relocation.offset, relocation.symbol)!;
			if (relocation.addend > 0) io::fprintf(w, " + %d", relocation.addend)!;
			if (relocation.addend < 0) io::fprintf(w, " - %d", -relocation.addend)!;
			w.write_byte('\n')!;
		}
		io::write_all(w, "}\n\n")!;
		return;
	}
	io::write_all(w, "\n\n")!;
}

fn void? Ir.dump_decl(&self, Decl* decl, String name, OutStream w, bool use_ansi)
{
	uint n = (uint)decl.instructions.len;
	uint[] refs = alloc::new_array(self.allocator, uint, n);
	defer alloc::free(self.allocator, refs);
	uint[] labels = alloc::new_array(self.allocator, uint, n);
	defer alloc::free(self.allocator, labels);
	for (uint i = 0; i < n; i++) { refs[i] = uint::max; labels[i] = uint::max; }
	if (!decl.body.len) return;
	value_interner::InternerRef return_ty = value_interner::REF_VOID;
	foreach (ref : decl.body)
	{
		Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == RET && inst.data.ref != NONE)
		{
			return_ty = decl.instructions[(sz)inst.data.ref].ty;
			break;
		}
		if (inst.tag == RET_PAIR)
		{
			return_ty = decl.instructions[(sz)inst.data.bin.lhs].ty;
			break;
		}
	}
	if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(w, use_ansi, "internal ")!;
	if (decl.is_weak) IrDumpRole.ATTRIBUTE.write(w, use_ansi, "weak ")!;
	self.write_type(return_ty, w, use_ansi)!;
	IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, " @%s", name)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
	w.write_byte('(')!;
	uint ref_count = 0; uint body_start = 0;
	while (body_start < (uint)decl.body.len)
	{
		Ref ref = decl.body[(sz)body_start];
		if (decl.instructions[(sz)ref].tag != ARG) break;
		if (ref_count != 0) io::write_all(w, ", ")!;
		refs[(sz)ref] = ref_count; ref_count++;
		self.write_ref(decl, refs, ref, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
		body_start++;
	}
	w.write_byte(')')!; io::write_all(w, " {\n")!;
	uint label_count = 0;
	foreach (ref : decl.body[body_start..])
	{
		if (decl.instructions[(sz)ref].tag == LABEL) { labels[(sz)ref] = label_count; label_count++; }
	}
	foreach (ref : decl.body[body_start..])
	{
		Inst inst = decl.instructions[(sz)ref];
		switch (inst.tag)
		{
			case LABEL:
				IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, "%s.%d:\n", inst.data.label, labels[(sz)ref])!;
			case JMP:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    jmp ")!; self.write_label(decl, labels, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case BRANCH:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    branch ")!;
				self.write_ref(decl, refs, inst.data.branch.cond, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.then_label, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.else_label, w, use_ansi)!; w.write_byte('\n')!;
			case SELECT:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "select ")!;
				self.write_ref(decl, refs, inst.data.branch.cond, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.then_label, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.else_label, w, use_ansi)!; w.write_byte('\n')!;
			case SWITCH:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    switch ")!; self.write_ref(decl, refs, inst.data.switch_data.target, w, use_ansi)!;
				if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, " {")!;
				foreach (i, val : inst.data.switch_data.values)
				{
					io::write_all(w, "\n        ")!; self.write_value(val, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
					io::write_all(w, " => ")!; self.write_label(decl, labels, inst.data.switch_data.labels[(sz)i], w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				}
				IrDumpRole.LITERAL.apply(w, use_ansi)!; io::write_all(w, "\n        default ")!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				io::write_all(w, "=> ")!; self.write_label(decl, labels, inst.data.switch_data.default_label, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, "\n    }\n")!;
			case STORE:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, inst.is_volatile ? "    store volatile " : "    store ")!; self.write_ref(decl, refs, inst.data.bin.lhs, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.bin.rhs, w, use_ansi)!; w.write_byte('\n')!;
			case RET:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    ret ")!;
				if (inst.data.ref != NONE) self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case RET_PAIR:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    ret_pair ")!;
				self.write_ref(decl, refs, inst.data.bin.lhs, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.bin.rhs, w, use_ansi)!; w.write_byte('\n')!;
			case ALLOC:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++;
				io::write_all(w, "alloc ")!; IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::write_all(w, "size ")!; IrDumpRole.LITERAL.apply(w, use_ansi)!; io::fprintf(w, "%d", inst.data.alloc.size)!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::write_all(w, " align ")!; IrDumpRole.LITERAL.apply(w, use_ansi)!; io::fprintf(w, "%d", inst.data.alloc.align)!;
				if (inst.data.alloc.is_volatile) { IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::write_all(w, " volatile")!; }
				w.write_byte('\n')!;
			case DYN_ALLOC:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++;
				io::write_all(w, "dyn_alloc ")!; self.write_ref(decl, refs, inst.data.dyn_alloc.size, w, use_ansi)!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::write_all(w, " align ")!; IrDumpRole.LITERAL.apply(w, use_ansi)!; io::fprintf(w, "%d", inst.data.dyn_alloc.align)!;
				w.write_byte('\n')!;
			case STACK_SAVE:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++;
				io::write_all(w, "stack_save\n")!;
			case STACK_RESTORE:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    stack_restore ")!; self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case VA_START:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    va_start ")!; self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case CALL:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "call ")!;
				self.write_ref(decl, refs, inst.data.call.func, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; w.write_byte('(')!;
				foreach (usz i, arg : inst.data.call.args) { if (i) io::write_all(w, ", ")!; self.write_ref(decl, refs, arg, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; }
				io::write_all(w, ")")!;
				if (inst.data.call.darwin)
				{
					io::fprintf(w, " darwin(result=%d,hfa=%dx%d;", inst.data.call.result.size, inst.data.call.result.hfa_count, inst.data.call.result.hfa_bits)!;
					foreach (location : inst.data.call.locations) io::fprintf(w, " %s:%d/%d", location.location_kind, location.location, location.stack_size)!;
					w.write_byte(')')!;
				}
				w.write_byte('\n')!;
			case CALL_HI:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "call_hi ")!;
				self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case PHI:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "phi")!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, " {")!;
				foreach (input : inst.data.phi) { io::write_all(w, "\n        ")!; self.write_label(decl, labels, input.label, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, " => ")!; self.write_ref(decl, refs, input.value, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; }
				io::write_all(w, "\n    }\n")!;
			case ATOMIC_LOAD:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "atomic_load ")!;
				self.write_ref(decl, refs, inst.data.atomic.ptr, w, use_ansi)!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::fprintf(w, " %s", inst.data.atomic.order.name)!; w.write_byte('\n')!;
			case ATOMIC_STORE:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    atomic_store ")!; self.write_ref(decl, refs, inst.data.atomic.ptr, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.atomic.val, w, use_ansi)!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::fprintf(w, " %s", inst.data.atomic.order.name)!; w.write_byte('\n')!;
			case FENCE:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    fence")!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::fprintf(w, " %s", inst.data.atomic.order.name)!; w.write_byte('\n')!;
			case CLZ:
			case CTZ:
			case VSPLAT:
			case VREDUCE_ADD:
			case LOAD:
			case BIT_NOT:
			case NEGATE:
			case FNEG:
			case FABS:
			case TRUNC:
			case ZEXT:
			case SEXT:
			case FPTOSI:
			case FPTOUI:
			case SITOFP:
			case UITOFP:
			case FPEXT:
			case FPTRUNC:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::fprintf(w, "%s ", inst.tag.name)!;
				if (inst.is_volatile_access()) io::write_all(w, "volatile ")!;
				self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case BIT_OR:
			case BIT_XOR:
			case BIT_AND:
			case BIT_SHL:
			case BIT_ASHR:
			case BIT_LSHR:
			case CMP_EQ:
			case CMP_NE:
			case CMP_SLT:
			case CMP_SLTE:
			case CMP_SGT:
			case CMP_SGTE:
			case CMP_ULT:
			case CMP_ULTE:
			case CMP_UGT:
			case CMP_UGTE:
			case ADD:
			case SUB:
			case MUL:
			case SDIV:
			case UDIV:
			case SREM:
			case UREM:
			case FADD:
			case FSUB:
			case FMUL:
			case FDIV:
			case FCMP_OEQ:
			case FCMP_UNE:
			case FCMP_OLT:
			case FCMP_OLE:
			case FCMP_OGT:
			case FCMP_OGE:
			case VEXTRACT:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::fprintf(w, "%s ", inst.tag.name)!;
				if (inst.nsw) io::write_all(w, "nsw ")!;
				self.write_ref(decl, refs, inst.data.bin.lhs, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.bin.rhs, w, use_ansi)!; w.write_byte('\n')!;
			case CONSTANT:
			case ARG:
				case SYMBOL: unreachable();
			case LABEL_ADDR:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "label_addr ")!;
				self.write_label(decl, labels, inst.data.ref, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; w.write_byte('\n')!;
			case JMP_VAL:
				IrDumpRole.INSTRUCTION.apply(w, use_ansi)!; io::write_all(w, "    jmp_val ")!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				self.write_ref(decl, refs, inst.data.ref, w, use_ansi)!; w.write_byte('\n')!;
			case VSHUFFLE:
				self.write_new_ref(decl, refs, ref_count, ref, w, use_ansi)!; ref_count++; io::write_all(w, "vshuffle ")!;
				self.write_ref(decl, refs, inst.data.shuffle.lhs, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.shuffle.rhs, w, use_ansi)!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!;
				IrDumpRole.ATTRIBUTE.apply(w, use_ansi)!; io::write_all(w, " [")!;
				uint lanes = self.interner.get(inst.ty).vector_ty.len;
				for (uint i = 0; i < lanes && i < 16; i++)
				{
					if (i) io::write_all(w, " ")!;
					if (inst.data.shuffle.mask[i] == ir::SHUFFLE_UNDEF) { io::write_all(w, "u")!; } else { io::fprintf(w, "%d", inst.data.shuffle.mask[i])!; }
				}
				io::write_all(w, "]")!; if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; w.write_byte('\n')!;
		}
	}
	if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, "}\n\n")!;
}

fn void? Ir.write_type(&self, value_interner::InternerRef ty_ref, OutStream w, bool use_ansi)
{
	PrimitiveValue ty = self.interner.get(ty_ref); IrDumpRole.TYPE.apply(w, use_ansi)!;
	switch (ty.tag)
	{
		case PTR_TY: io::write_all(w, "ptr_ty")!;
		case NORETURN_TY: io::write_all(w, "noreturn_ty")!;
		case VOID_TY: io::write_all(w, "void_ty")!;
		case FUNC_TY: io::write_all(w, "func_ty")!;
		case INT_TY: io::fprintf(w, "i%d", ty.ty_bits)!;
		case FLOAT_TY: io::fprintf(w, "f%d", ty.ty_bits)!;
		case ARRAY_TY: io::fprintf(w, "[%d * ", ty.array_ty.len)!; self.write_type(ty.array_ty.child, w, false)!; w.write_byte(']')!;
		case VECTOR_TY: io::fprintf(w, "<%d * ", ty.vector_ty.len)!; self.write_type(ty.vector_ty.child, w, false)!; w.write_byte('>')!;
		case RECORD_TY:
			io::write_all(w, "{ ")!; foreach (i, elem : ty.record_ty) { if (i) io::write_all(w, ", ")!; self.write_type(elem, w, false)!; } io::write_all(w, " }")!;
		default: unreachable();
	}
}

fn void? Ir.write_value(&self, value_interner::InternerRef val, OutStream w, bool use_ansi)
{
	IrDumpRole.LITERAL.apply(w, use_ansi)!; PrimitiveValue key = self.interner.get(val);
	switch (key.tag)
	{
		case NULL: io::write_all(w, "nullptr_t")!;
		case INT_POSITIVE:
		case INT_NEGATIVE: io::fprintf(w, "%s", key)!;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			primitive_value::print_float(key, w)!;
		case BYTES: self.write_escaped_bytes(key.bytes, w)!;
		default: unreachable();
	}
}

fn void? Ir.write_escaped_bytes(&self, char[] bytes, OutStream w)
{
	w.write_byte('"')!;
	foreach (b : bytes)
	{
		switch (b)
		{
			case '\n': io::write_all(w, "\\n")!;
			case '\r': io::write_all(w, "\\r")!;
			case '\t': io::write_all(w, "\\t")!;
			case '\\': io::write_all(w, "\\\\")!;
			case '"': io::write_all(w, "\\\"")!;
			default:
				if (b >= 0x20 && b <= 0x7E) { w.write_byte(b)!; }
				else { io::fprintf(w, "\\x%02x", b)!; }
		}
	}
	w.write_byte('"')!;
}

fn void? Ir.write_ref(&self, Decl* decl, uint[] refs, Ref ref, OutStream w, bool use_ansi)
{
	if (ref == NONE) return;
	Inst inst = decl.instructions[(sz)ref]; self.write_type(inst.ty, w, use_ansi)!;
	if (inst.tag == CONSTANT) { w.write_byte(' ')!; self.write_value(inst.data.constant, w, use_ansi)!; return; }
	if (inst.tag == SYMBOL) { IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, " @%s", inst.data.label)!; return; }
	IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, " %%%d", refs[(sz)ref])!;
}

fn void? Ir.write_new_ref(&self, Decl* decl, uint[] refs, uint index, Ref ref, OutStream w, bool use_ansi)
{
	refs[(sz)ref] = index; io::write_all(w, "    ")!; self.write_ref(decl, refs, ref, w, use_ansi)!;
	if (use_ansi) io::write_all(w, ansi::Ansi.RESET)!; io::write_all(w, " = ")!; IrDumpRole.INSTRUCTION.apply(w, use_ansi)!;
}

fn void? Ir.write_label(&self, Decl* decl, uint[] labels, Ref ref, OutStream w, bool use_ansi)
{
	IrDumpRole.REFERENCE.apply(w, use_ansi)!; io::fprintf(w, "%s.%d", decl.instructions[(sz)ref].data.label, labels[(sz)ref])!;
}

<* Port of `Ir.Renderer`: the object being filled, the Ir being lowered and the ordered failures. *>
struct Renderer
{
	Allocator gpa;
	object::Object* obj;
	Ir* ir;
	ErrorList errors;
}

<*
 Record a failure for `name`, formatting `format` with `args`. Zig `Renderer.fail`.
 @return? LOWER_FAIL
*>
fn void? Renderer.fail(&self, String name, String format, args...) @format(2)
{
	self.errors.put(name, string::format(self.gpa, format, ...args));
	return LOWER_FAIL~;
}

<*
 Dispatch on the target architecture. X86 and X86_64 use the x86 renderer; any
 other architecture is unreachable. Zig `Renderer.render`.
 @return? LOWER_FAIL
*>
fn void? Renderer.render(&self)
{
	switch (self.obj.target.cpu.arch)
	{
		case X86:
		case X86_64:
			return self.render_x86();
		default:
			unreachable("unsupported architecture in initialized object");
	}
}

<*
 Port of backend/Ir/x86/Renderer.zig. Machine lowering is not implemented, so every
 declaration records `TODO implement lowering functions`. Rendering continues past each
 LOWER_FAIL, as the Zig `continue` does, and reports LOWER_FAIL if any failure was recorded.
 @return? LOWER_FAIL
*>
fn void? Renderer.render_x86(&self)
{
	foreach (&decl : self.ir.decls)
	{
		String message = decl.kind == DeclKind.GLOBAL ? "TODO lower global data" : "TODO implement lowering functions";
		fault f = @catch(self.fail(decl.name, message));
		if (f)
		{
			if (f != LOWER_FAIL) return f~;
		}
	}
	if (self.errors.len() != 0) return LOWER_FAIL~;
}

<*
 Port of `Ir.render`: create the object for `target`, lower every declaration and move
 the recorded failures into the initialized `errors` output (when non-null) on both
 success and failure. Existing output contents are freed before replacement. The object
 is destroyed when lowering fails. Zig `ir.render`.
 @return? LOWER_FAIL, object::UNSUPPORTED_FORMAT
*>
fn object::Object*? render(Ir* ir, Allocator gpa, target::Target target, ErrorList* errors)
{
	object::Object* obj = object::create(gpa, target)!;
	Renderer renderer = { .gpa = gpa, .obj = obj, .ir = ir };
	renderer.errors.init(gpa);
	fault f = @catch(renderer.render());
	if (errors != null)
	{
		errors.free();
		*errors = renderer.errors;
	}
	else
	{
		renderer.errors.free();
	}
	renderer.errors = {};
	if (f)
	{
		obj.deinit();
		return f~;
	}
	return obj;
}

<*
 C3 addition: render `ir` into an object for `target`, transferring recorded
 failures into `errors` and destroying the object if rendering fails.
 @return? LOWER_FAIL, object::UNSUPPORTED_FORMAT
*>
fn object::Object*? render_object(Ir* ir, Allocator gpa, target::Target target, ErrorList* errors, bool spill_all = false)
{
	if (target.cpu.arch == AARCH64 && target.os.tag == MACOS)
	{
		errors.put("", "ARM64 macOS does not support -fintegrated-as; use -fno-integrated-as".copy(errors.allocator));
		return LOWER_FAIL~;
	}
	switch (target.cpu.arch)
	{
		case X86_64: break;
		default:
			errors.put("", string::format(errors.allocator, "TODO: lowering Ir for %s", target.cpu.arch.name));
			return LOWER_FAIL~;
	}
	object::Object* obj = object::create(gpa, target)!;
	fault f = @catch(x86_64::render_object(ir, obj, errors, spill_all));
	if (f)
	{
		obj.deinit();
		return f~;
	}
	return obj;
}

<*
 C3 addition: lower `ir` to target assembler text (x86_64 ELF or ARM64 Mach-O),
 recording per-function failures in the initialized `errors`, which are kept
 on both success and failure. The text is allocated with `gpa`.
 @return? LOWER_FAIL
*>
fn String? render_asm(Ir* ir, Allocator gpa, target::Target target, ErrorList* errors, bool spill_all = false)
{
	switch (target.cpu.arch)
	{
		case X86_64: return x86_64::render_asm(ir, gpa, errors, spill_all);
		case AARCH64:
			if (target.os.tag == MACOS) return aarch64::render_asm(ir, gpa, errors, target);
			errors.put("", "ARM64 assembly output currently requires macOS".copy(errors.allocator));
			return LOWER_FAIL~;
		default:
			errors.put("", string::format(errors.allocator, "TODO: lowering Ir for %s", target.cpu.arch.name));
			return LOWER_FAIL~;
	}
}
