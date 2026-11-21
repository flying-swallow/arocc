// Text dump, lowering status and object rendering for the index-based C3 IR.
module aro::backend::ir;
import aro::primitive_value;
import std::core::string::ansi, aro::frontend::c::diagnostics, aro::value_interner, aro::backend::object, aro::backend::x86_64, aro::target, std::collections::list, std::core::dstring, std::io;

// Lowering failure fault reported by Renderer.fail (Zig Renderer.Error.LowerFail).
excuse LOWER_FAIL;

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

fn void? IrDumpRole.apply(self, Terminal term) => term.set_color(self.color());

fn void? IrDumpRole.write(self, Terminal term, String text)
{
	self.apply(term)!;
	term.write(text)!;
	term.set_color(ansi::Ansi.RESET)!;
}

fn void? Ir.dump(&self, Terminal term)
{
	foreach (&decl : self.decls)
	{
		switch (decl.kind)
		{
			case FUNCTION: self.dump_decl(decl, decl.name, term)!;
			case GLOBAL: self.dump_global(decl, term)!;
		}
	}
	if (&term.writer.flush) term.writer.flush()!;
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

fn void? Ir.dump_global(&self, Decl* decl, Terminal term)
{
	OutStream w = term.writer;
	if (!decl.is_definition())
	{
		IrDumpRole.INSTRUCTION.write(term, "extern ")!;
		IrDumpRole.REFERENCE.apply(term)!; io::fprintf(w, "@%s", decl.name)!; term.set_color(ansi::Ansi.RESET)!;
		if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(term, " internal")!;
		io::write_all(w, "\n\n")!;
		return;
	}
	IrDumpRole.INSTRUCTION.write(term, "global ")!;
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(w, "@%s", decl.name)!; term.set_color(ansi::Ansi.RESET)!;
	io::fprintf(w, " size %d align %d %s", decl.global.size, decl.global.align, decl.global.section.dump_name())!;
	if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(term, " internal")!;
	if (decl.global.tentative) io::write_all(w, " tentative")!;
	if (decl.global.own_section) io::write_all(w, " own_section")!;
	bool has_data = decl.global.section != DataSection.BSS && decl.global.section != DataSection.COMMON;
	if (has_data)
	{
		io::write_all(w, " {\n    bytes ")!;
		IrDumpRole.LITERAL.apply(term)!; self.write_escaped_bytes(decl.global.bytes, term)!; term.set_color(ansi::Ansi.RESET)!;
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

fn void? Ir.dump_decl(&self, Decl* decl, String name, Terminal term)
{
	uint n = (uint)decl.instructions.len;
	uint[] refs = alloc::new_array(self.allocator, uint, n);
	defer alloc::free(self.allocator, refs);
	uint[] labels = alloc::new_array(self.allocator, uint, n);
	defer alloc::free(self.allocator, labels);
	for (uint i = 0; i < n; i++) { refs[i] = uint::max; labels[i] = uint::max; }
	OutStream w = term.writer;
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
	if (decl.linkage == Linkage.INTERNAL) IrDumpRole.ATTRIBUTE.write(term, "internal ")!;
	self.write_type(return_ty, term)!;
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(w, " @%s", name)!; term.set_color(ansi::Ansi.RESET)!;
	w.write_byte('(')!;
	uint ref_count = 0; uint body_start = 0;
	while (body_start < (uint)decl.body.len)
	{
		Ref ref = decl.body[(sz)body_start];
		if (decl.instructions[(sz)ref].tag != ARG) break;
		if (ref_count != 0) io::write_all(w, ", ")!;
		refs[(sz)ref] = ref_count; ref_count++;
		self.write_ref(decl, refs, ref, term)!; term.set_color(ansi::Ansi.RESET)!;
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
				IrDumpRole.REFERENCE.apply(term)!; io::fprintf(w, "%s.%d:\n", inst.data.label, labels[(sz)ref])!;
			case JMP:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    jmp ")!; self.write_label(decl, labels, inst.data.ref, term)!; w.write_byte('\n')!;
			case BRANCH:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    branch ")!;
				self.write_ref(decl, refs, inst.data.branch.cond, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.then_label, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.else_label, term)!; w.write_byte('\n')!;
			case SELECT:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "select ")!;
				self.write_ref(decl, refs, inst.data.branch.cond, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.then_label, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.else_label, term)!; w.write_byte('\n')!;
			case SWITCH:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    switch ")!; self.write_ref(decl, refs, inst.data.switch_data.target, term)!;
				term.set_color(ansi::Ansi.RESET)!; io::write_all(w, " {")!;
				foreach (i, val : inst.data.switch_data.values)
				{
					io::write_all(w, "\n        ")!; self.write_value(val, term)!; term.set_color(ansi::Ansi.RESET)!;
					io::write_all(w, " => ")!; self.write_label(decl, labels, inst.data.switch_data.labels[(sz)i], term)!; term.set_color(ansi::Ansi.RESET)!;
				}
				IrDumpRole.LITERAL.apply(term)!; io::write_all(w, "\n        default ")!; term.set_color(ansi::Ansi.RESET)!;
				io::write_all(w, "=> ")!; self.write_label(decl, labels, inst.data.switch_data.default_label, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, "\n    }\n")!;
			case STORE:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    store ")!; self.write_ref(decl, refs, inst.data.bin.lhs, term)!; term.set_color(ansi::Ansi.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.bin.rhs, term)!; w.write_byte('\n')!;
			case RET:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    ret ")!;
				if (inst.data.ref != NONE) self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case RET_PAIR:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    ret_pair ")!;
				self.write_ref(decl, refs, inst.data.bin.lhs, term)!; term.set_color(ansi::Ansi.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.bin.rhs, term)!; w.write_byte('\n')!;
			case ALLOC:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++;
				io::write_all(w, "alloc ")!; IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, "size ")!; IrDumpRole.LITERAL.apply(term)!; io::fprintf(w, "%d", inst.data.alloc.size)!;
				IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, " align ")!; IrDumpRole.LITERAL.apply(term)!; io::fprintf(w, "%d", inst.data.alloc.align)!;
				if (inst.data.alloc.is_volatile) { IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, " volatile")!; }
				w.write_byte('\n')!;
			case DYN_ALLOC:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++;
				io::write_all(w, "dyn_alloc ")!; self.write_ref(decl, refs, inst.data.dyn_alloc.size, term)!;
				IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, " align ")!; IrDumpRole.LITERAL.apply(term)!; io::fprintf(w, "%d", inst.data.dyn_alloc.align)!;
				w.write_byte('\n')!;
			case STACK_SAVE:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++;
				io::write_all(w, "stack_save\n")!;
			case STACK_RESTORE:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    stack_restore ")!; self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case VA_START:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    va_start ")!; self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case CALL:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "call ")!;
				self.write_ref(decl, refs, inst.data.call.func, term)!; term.set_color(ansi::Ansi.RESET)!; w.write_byte('(')!;
				foreach (usz i, arg : inst.data.call.args) { if (i) io::write_all(w, ", ")!; self.write_ref(decl, refs, arg, term)!; term.set_color(ansi::Ansi.RESET)!; }
				io::write_all(w, ")\n")!;
			case CALL_HI:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "call_hi ")!;
				self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case PHI:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "phi")!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, " {")!;
				foreach (input : inst.data.phi) { io::write_all(w, "\n        ")!; self.write_label(decl, labels, input.label, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, " => ")!; self.write_ref(decl, refs, input.value, term)!; term.set_color(ansi::Ansi.RESET)!; }
				io::write_all(w, "\n    }\n")!;
			case LOAD:
			case BIT_NOT:
			case NEGATE:
			case FNEG:
			case TRUNC:
			case ZEXT:
			case SEXT:
			case FPTOSI:
			case FPTOUI:
			case SITOFP:
			case UITOFP:
			case FPEXT:
			case FPTRUNC:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::fprintf(w, "%s ", inst.tag.name)!;
				self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
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
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::fprintf(w, "%s ", inst.tag.name)!;
				self.write_ref(decl, refs, inst.data.bin.lhs, term)!; term.set_color(ansi::Ansi.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.bin.rhs, term)!; w.write_byte('\n')!;
			case CONSTANT:
			case ARG:
				case SYMBOL: unreachable();
			case LABEL_ADDR:
			case JMP_VAL: {}
		}
	}
	term.set_color(ansi::Ansi.RESET)!; io::write_all(w, "}\n\n")!;
}

fn void? Ir.write_type(&self, value_interner::InternerRef ty_ref, Terminal term)
{
	PrimitiveValue ty = self.interner.get(ty_ref); IrDumpRole.TYPE.apply(term)!;
	switch (ty.tag)
	{
		case PTR_TY: io::write_all(term.writer, "ptr_ty")!;
		case NORETURN_TY: io::write_all(term.writer, "noreturn_ty")!;
		case VOID_TY: io::write_all(term.writer, "void_ty")!;
		case FUNC_TY: io::write_all(term.writer, "func_ty")!;
		case INT_TY: io::fprintf(term.writer, "i%d", ty.ty_bits)!;
		case FLOAT_TY: io::fprintf(term.writer, "f%d", ty.ty_bits)!;
		case ARRAY_TY: io::fprintf(term.writer, "[%d * ", ty.array_ty.len)!; self.write_type(ty.array_ty.child, plain_term(term))!; term.writer.write_byte(']')!;
		case VECTOR_TY: io::fprintf(term.writer, "<%d * ", ty.vector_ty.len)!; self.write_type(ty.vector_ty.child, plain_term(term))!; term.writer.write_byte('>')!;
		case RECORD_TY:
			io::write_all(term.writer, "{ ")!; foreach (i, elem : ty.record_ty) { if (i) io::write_all(term.writer, ", ")!; self.write_type(elem, plain_term(term))!; } io::write_all(term.writer, " }")!;
		default: unreachable();
	}
}

fn Terminal plain_term(Terminal term) { term.mode = diagnostics::ColorMode.NO_COLOR; return term; }

fn void? Ir.write_value(&self, value_interner::InternerRef val, Terminal term)
{
	IrDumpRole.LITERAL.apply(term)!; PrimitiveValue key = self.interner.get(val);
	switch (key.tag)
	{
		case NULL: io::write_all(term.writer, "nullptr_t")!;
		case INT_POSITIVE:
		case INT_NEGATIVE: io::fprintf(term.writer, "%s", key)!;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			primitive_value::print_float(key, term.writer)!;
		case BYTES: self.write_escaped_bytes(key.bytes, term)!;
		default: unreachable();
	}
}

fn void? Ir.write_escaped_bytes(&self, char[] bytes, Terminal term)
{
	term.writer.write_byte('"')!;
	foreach (b : bytes)
	{
		switch (b)
		{
			case '\n': io::write_all(term.writer, "\\n")!;
			case '\r': io::write_all(term.writer, "\\r")!;
			case '\t': io::write_all(term.writer, "\\t")!;
			case '\\': io::write_all(term.writer, "\\\\")!;
			case '"': io::write_all(term.writer, "\\\"")!;
			default:
				if (b >= 0x20 && b <= 0x7E) { term.writer.write_byte(b)!; }
				else { io::fprintf(term.writer, "\\x%02x", b)!; }
		}
	}
	term.writer.write_byte('"')!;
}

fn void? Ir.write_ref(&self, Decl* decl, uint[] refs, Ref ref, Terminal term)
{
	if (ref == NONE) return;
	Inst inst = decl.instructions[(sz)ref]; self.write_type(inst.ty, term)!;
	if (inst.tag == CONSTANT) { term.writer.write_byte(' ')!; self.write_value(inst.data.constant, term)!; return; }
	if (inst.tag == SYMBOL) { IrDumpRole.REFERENCE.apply(term)!; io::fprintf(term.writer, " @%s", inst.data.label)!; return; }
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(term.writer, " %%%d", refs[(sz)ref])!;
}

fn void? Ir.write_new_ref(&self, Decl* decl, uint[] refs, uint index, Ref ref, Terminal term)
{
	refs[(sz)ref] = index; io::write_all(term.writer, "    ")!; self.write_ref(decl, refs, ref, term)!;
	term.set_color(ansi::Ansi.RESET)!; io::write_all(term.writer, " = ")!; IrDumpRole.INSTRUCTION.apply(term)!;
}

fn void? Ir.write_label(&self, Decl* decl, uint[] labels, Ref ref, Terminal term)
{
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(term.writer, "%s.%d", decl.instructions[(sz)ref].data.label, labels[(sz)ref])!;
}

<* One failure record: `name` borrows the decl name from the Ir, `message` is owned by the list. *>
struct ErrorEntry
{
	String name;
	String message;
}

<* Ordered name -> message map (Zig `Renderer.ErrorList`). A repeated name replaces its message in place. *>
struct ErrorList
{
	Allocator allocator;
	List{ErrorEntry} entries;
}

fn void ErrorList.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.entries.init(allocator);
}

<* Free every owned message, then the entry storage. Resets to `{}`. *>
fn void ErrorList.free(&self)
{
	foreach (entry : self.entries) alloc::free(self.allocator, entry.message.ptr);
	self.entries.free();
	*self = {};
}

<* Insert `message` for `name`. A repeated name frees the old message and keeps the entry's position. *>
fn void ErrorList.put(&self, String name, String message)
{
	foreach (&entry : self.entries)
	{
		if (entry.name == name)
		{
			alloc::free(self.allocator, entry.message.ptr);
			entry.message = message;
			return;
		}
	}
	self.entries.push({ .name = name, .message = message });
}

fn usz ErrorList.len(&self) => (usz)self.entries.len();
fn String ErrorList.name_at(&self, usz i) => self.entries.array_view()[i].name;
fn String ErrorList.message_at(&self, usz i) => self.entries.array_view()[i].message;

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
 C3 addition: lower `ir` to GNU assembler text for `target` (x86_64 only),
 recording per-function failures in the initialized `errors`, which are kept
 on both success and failure. The text is allocated with `gpa`.
 @return? LOWER_FAIL
*>
fn String? render_asm(Ir* ir, Allocator gpa, target::Target target, ErrorList* errors, bool spill_all = false)
{
	switch (target.cpu.arch)
	{
		case X86_64: return x86_64::render_asm(ir, gpa, errors, spill_all);
		default:
			errors.put("", string::format(errors.allocator, "TODO: lowering Ir for %s", target.cpu.arch.name));
			return LOWER_FAIL~;
	}
}
