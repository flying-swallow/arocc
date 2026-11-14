// Text dump, lowering status and object rendering for the index-based C3 IR.
module aro::backend::ir;
import aro::diagnostics, aro::value_interner, aro::float_value, aro::backend::object, aro::target, std::collections::list, std::core::dstring, std::io;

// Lowering failure fault reported by Renderer.fail (Zig Renderer.Error.LowerFail).
excuse LOWER_FAIL;

enum IrDumpRole : char { TYPE, INSTRUCTION, REFERENCE, LITERAL, ATTRIBUTE }

fn Color IrDumpRole.color(self)
{
	switch (self)
	{
		case TYPE: return diagnostics::Color.BRIGHT_MAGENTA;
		case INSTRUCTION: return diagnostics::Color.BRIGHT_CYAN;
		case REFERENCE: return diagnostics::Color.BRIGHT_BLUE;
		case LITERAL: return diagnostics::Color.BRIGHT_GREEN;
		case ATTRIBUTE: return diagnostics::Color.BRIGHT_YELLOW;
	}
}

fn void? IrDumpRole.apply(self, Terminal term) => term.set_color(self.color());

fn void? IrDumpRole.write(self, Terminal term, String text)
{
	self.apply(term)!;
	term.write(text)!;
	term.set_color(diagnostics::Color.RESET)!;
}

fn void? Ir.dump(&self, Terminal term)
{
	foreach (&decl : self.decls) self.dump_decl(decl, decl.name, term)!;
	if (&term.writer.flush) term.writer.flush()!;
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
	Ref last = decl.body[decl.body.len - 1];
	Ref ret_value = decl.instructions[(sz)last].data.ref;
	self.write_type(decl.instructions[(sz)ret_value].ty, term)!;
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(w, " @%s", name)!; term.set_color(diagnostics::Color.RESET)!;
	w.write_byte('(')!;
	uint ref_count = 0; uint body_start = 0;
	while (body_start < (uint)decl.body.len)
	{
		Ref ref = decl.body[(sz)body_start];
		if (decl.instructions[(sz)ref].tag != ARG) break;
		if (ref_count != 0) io::write_all(w, ", ")!;
		refs[(sz)ref] = ref_count; ref_count++;
		self.write_ref(decl, refs, ref, term)!; term.set_color(diagnostics::Color.RESET)!;
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
				self.write_ref(decl, refs, inst.data.branch.cond, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.then_label, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, ", ")!;
				self.write_label(decl, labels, inst.data.branch.else_label, term)!; w.write_byte('\n')!;
			case SELECT:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "select ")!;
				self.write_ref(decl, refs, inst.data.branch.cond, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.then_label, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.branch.else_label, term)!; w.write_byte('\n')!;
			case SWITCH:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    switch ")!; self.write_ref(decl, refs, inst.data.switch_data.target, term)!;
				term.set_color(diagnostics::Color.RESET)!; io::write_all(w, " {")!;
				foreach (i, val : inst.data.switch_data.values)
				{
					io::write_all(w, "\n        ")!; self.write_value(val, term)!; term.set_color(diagnostics::Color.RESET)!;
					io::write_all(w, " => ")!; self.write_label(decl, labels, inst.data.switch_data.labels[(sz)i], term)!; term.set_color(diagnostics::Color.RESET)!;
				}
				IrDumpRole.LITERAL.apply(term)!; io::write_all(w, "\n        default ")!; term.set_color(diagnostics::Color.RESET)!;
				io::write_all(w, "=> ")!; self.write_label(decl, labels, inst.data.switch_data.default_label, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, "\n    }\n")!;
			case STORE:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    store ")!; self.write_ref(decl, refs, inst.data.bin.lhs, term)!; term.set_color(diagnostics::Color.RESET)!;
				io::write_all(w, ", ")!; self.write_ref(decl, refs, inst.data.bin.rhs, term)!; w.write_byte('\n')!;
			case RET:
				IrDumpRole.INSTRUCTION.apply(term)!; io::write_all(w, "    ret ")!;
				if (inst.data.ref != NONE) self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case ALLOC:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++;
				io::write_all(w, "alloc ")!; IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, "size ")!; IrDumpRole.LITERAL.apply(term)!; io::fprintf(w, "%d", inst.data.alloc.size)!;
				IrDumpRole.ATTRIBUTE.apply(term)!; io::write_all(w, " align ")!; IrDumpRole.LITERAL.apply(term)!; io::fprintf(w, "%d\n", inst.data.alloc.align)!;
			case CALL:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "call ")!;
				self.write_ref(decl, refs, inst.data.call.func, term)!; term.set_color(diagnostics::Color.RESET)!; w.write_byte('(')!;
				foreach (usz i, arg : inst.data.call.args) { if (i) io::write_all(w, ", ")!; self.write_ref(decl, refs, arg, term)!; term.set_color(diagnostics::Color.RESET)!; }
				io::write_all(w, ")\n")!;
			case PHI:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::write_all(w, "phi")!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, " {")!;
				foreach (input : inst.data.phi) { io::write_all(w, "\n        ")!; self.write_label(decl, labels, input.label, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, " => ")!; self.write_ref(decl, refs, input.value, term)!; term.set_color(diagnostics::Color.RESET)!; }
				io::write_all(w, "\n    }\n")!;
			case LOAD:
			case BIT_NOT:
			case NEGATE:
			case TRUNC:
			case ZEXT:
			case SEXT:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::fprintf(w, "%s ", tag_name(inst.tag))!;
				self.write_ref(decl, refs, inst.data.ref, term)!; w.write_byte('\n')!;
			case BIT_OR:
			case BIT_XOR:
			case BIT_AND:
			case BIT_SHL:
			case BIT_SHR:
			case CMP_EQ:
			case CMP_NE:
			case CMP_LT:
			case CMP_LTE:
			case CMP_GT:
			case CMP_GTE:
			case ADD:
			case SUB:
			case MUL:
			case DIV:
			case MOD:
				self.write_new_ref(decl, refs, ref_count, ref, term)!; ref_count++; io::fprintf(w, "%s ", tag_name(inst.tag))!;
				self.write_ref(decl, refs, inst.data.bin.lhs, term)!; term.set_color(diagnostics::Color.RESET)!; io::write_all(w, ", ")!;
				self.write_ref(decl, refs, inst.data.bin.rhs, term)!; w.write_byte('\n')!;
			case CONSTANT:
			case ARG:
				case SYMBOL: unreachable();
			case LABEL_ADDR:
			case JMP_VAL: {}
		}
	}
	term.set_color(diagnostics::Color.RESET)!; io::write_all(w, "}\n\n")!;
}

fn void? Ir.write_type(&self, value_interner::InternerRef ty_ref, Terminal term)
{
	InternerKey ty = self.interner.get(ty_ref); IrDumpRole.TYPE.apply(term)!;
	switch (ty.tag)
	{
		case PTR_TY: io::write_all(term.writer, "ptr_ty")!;
		case NORETURN_TY: io::write_all(term.writer, "noreturn_ty")!;
		case VOID_TY: io::write_all(term.writer, "void_ty")!;
		case FUNC_TY: io::write_all(term.writer, "func_ty")!;
		case INT_TY: io::fprintf(term.writer, "i%d", ty.bits)!;
		case FLOAT_TY: io::fprintf(term.writer, "f%d", ty.bits)!;
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
	IrDumpRole.LITERAL.apply(term)!; InternerKey key = self.interner.get(val);
	switch (key.tag)
	{
		case NULL: io::write_all(term.writer, "nullptr_t")!;
		case INT:
			switch (key.int_val.tag)
			{
				case U64: io::fprintf(term.writer, "%d", key.int_val.u64)!;
				case I64: io::fprintf(term.writer, "%d", key.int_val.i64)!;
				case BIG_INT:
					String number = key.int_val.big_int.to_string_alloc(self.allocator, 10, false);
					defer alloc::free(self.allocator, number.ptr); io::write_all(term.writer, number)!;
			}
		case FLOAT:
			DString number; number.init(self.allocator); defer number.free();
			float_value::print_float(key.float_val, &number); io::write_all(term.writer, number.str_view())!;
		case BYTES:
			term.writer.write_byte('"')!;
			foreach (b : key.bytes)
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
		default: unreachable();
	}
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
	term.set_color(diagnostics::Color.RESET)!; io::write_all(term.writer, " = ")!; IrDumpRole.INSTRUCTION.apply(term)!;
}

fn void? Ir.write_label(&self, Decl* decl, uint[] labels, Ref ref, Terminal term)
{
	IrDumpRole.REFERENCE.apply(term)!; io::fprintf(term.writer, "%s.%d", decl.instructions[(sz)ref].data.label, labels[(sz)ref])!;
}

fn String tag_name(InstTag tag)
{
	switch (tag)
	{
		case BIT_OR: return "bit_or";
		case BIT_XOR: return "bit_xor";
		case BIT_AND: return "bit_and";
		case BIT_SHL: return "bit_shl";
		case BIT_SHR: return "bit_shr";
		case CMP_EQ: return "cmp_eq";
		case CMP_NE: return "cmp_ne";
		case CMP_LT: return "cmp_lt";
		case CMP_LTE: return "cmp_lte";
		case CMP_GT: return "cmp_gt";
		case CMP_GTE: return "cmp_gte";
		case ADD: return "add";
		case SUB: return "sub";
		case MUL: return "mul";
		case DIV: return "div";
		case MOD: return "mod";
		case LOAD: return "load";
		case BIT_NOT: return "bit_not";
		case NEGATE: return "negate";
		case TRUNC: return "trunc";
		case ZEXT: return "zext";
		case SEXT: return "sext";
		default: unreachable();
	}
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
fn void? Renderer.fail(&self, String name, String format, args...)
{
	DString text;
	text.init(self.gpa);
	defer text.free();
	text.appendf(format, ...args)!!;
	self.errors.put(name, text.copy_str(self.gpa));
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
		fault f = @catch(self.fail(decl.name, "TODO implement lowering functions"));
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
