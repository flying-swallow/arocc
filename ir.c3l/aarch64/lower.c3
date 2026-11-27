// Native Darwin ARM64 selector. Values live in frame slots; x9-x17 and
// v16-v17 are scratch. x18 is reserved by Darwin. No LLVM dependency.
module aro::backend::aarch64;
import aro::target;
import aro::backend::ir, aro::primitive_value, aro::value_interner;
import std::core::dstring, std::core::string, std::collections::list;

// The text emitter consumes the same typed instruction rows that a future
// integrated ARM64 encoder will consume, matching x86_64::Line.
struct Line
{
	bool is_label;
	bool is_raw;
	String label;
	Mnemonic mnemonic;
	Operand[4] ops;
	char op_count;
}

struct Lowering
{
	ir::Ir* graph;
	ir::Decl* decl;
	ir::ErrorList* errors;
	List{Line} lines;
	DString constants;
	uint function_id;
	uint next_label;
	uint[] slots;
	uint[] areas;
	uint[] phi_slots;
	uint frame;
	ir::Ref block;
}

fn uint aligned(uint size, uint alignment) => (size + alignment - 1) / alignment * alignment;
fn ir::Inst Lowering.inst(&self, ir::Ref ref) => self.decl.instructions[(sz)ref];
fn String Lowering.label(&self, ir::Ref ref) => string::tformat("Laro_%d_%d", self.function_id, ref);

fn void? Lowering.fail(&self, String message)
{
	self.errors.put(self.decl ? self.decl.name : "", message.copy(self.errors.allocator));
	return ir::LOWER_FAIL~;
}

fn void? Lowering.lower(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	switch (inst.tag)
	{
		case CONSTANT: case SYMBOL: case LABEL_ADDR: break;
		case LABEL:
			self.edge(ref)!; // A block may be reached by fallthrough.
			self.block = ref;
			self.emit_label(self.label(ref));
		case PHI:
			self.address(15, self.phi_slots[(sz)ref]);
			self.emit(LDR, reg_op(X9), mem_op(X15));
			self.save(ref)!;
		case ALLOC: self.address(9, self.areas[(sz)ref]); self.save(ref)!;
		case ARG:
			ir::ArgData arg = inst.data.arg;
			uint width = self.bits(inst.ty)!;
			switch (arg.location_kind)
			{
				case GP_REGISTER: self.emit(MOV, reg_op(X9), reg_op(gp(arg.location)));
				case SSE_REGISTER:
					self.emit(FMOV, reg_op(gp(9, width)), reg_op(fp(arg.location, width)));
				case STACK:
					self.immediate(9, (ulong)(16 + arg.location));
					self.emit(ADD, reg_op(X9), reg_op(X29), reg_op(X9));
					if (!arg.stack_address) self.emit(load_op(width), reg_op(gp(9, width)), mem_op(X9));
				default: self.fail("ARM64: unsupported incoming argument")!;
			}
			self.save(ref)!;
		case LOAD:
			uint width = self.bits(inst.ty)!;
			self.load(inst.data.ref)!;
			self.emit(load_op(width), reg_op(gp(9, width)), mem_op(X9));
			self.save(ref)!;
		case STORE:
			uint width = self.bits(self.inst(rhs).ty)!;
			self.load(lhs, 10)!; self.load(rhs)!;
			self.emit(store_op(width), reg_op(gp(9, width)), mem_op(X10));
		case ADD: case SUB: case MUL: case BIT_AND: case BIT_OR: case BIT_XOR:
		case BIT_SHL: case BIT_LSHR: case BIT_ASHR: case SDIV: case UDIV: case SREM: case UREM:
			bool signed = inst.tag == SDIV || inst.tag == SREM || inst.tag == BIT_ASHR;
			self.load(lhs, 9, signed)!; self.load(rhs, 10, signed)!;
			Mnemonic op;
			switch (inst.tag)
			{
				case ADD: op = ADD; case SUB: op = SUB; case MUL: op = MUL;
				case BIT_AND: op = AND; case BIT_OR: op = ORR; case BIT_XOR: op = EOR;
				case BIT_SHL: op = LSL; case BIT_LSHR: op = LSR; case BIT_ASHR: op = ASR;
				case SDIV: case SREM: op = SDIV;
				default: op = UDIV;
			}
			if (inst.tag == SREM || inst.tag == UREM)
			{
				self.emit(op, reg_op(X11), reg_op(X9), reg_op(X10));
				self.emit(MSUB, reg_op(X9), reg_op(X11), reg_op(X10), reg_op(X9));
			}
			else
			{
				self.emit(op, reg_op(X9), reg_op(X9), reg_op(X10));
			}
			self.save(ref)!;
		case NEGATE: case BIT_NOT:
			self.load(inst.data.ref)!;
			self.emit(inst.tag == NEGATE ? NEG : MVN, reg_op(X9), reg_op(X9));
			self.save(ref)!;
		case TRUNC: case ZEXT: case SEXT:
			self.load(inst.data.ref, 9, inst.tag == SEXT)!; self.save(ref)!;
		case CMP_EQ: case CMP_NE: case CMP_SLT: case CMP_SLTE: case CMP_SGT: case CMP_SGTE:
		case CMP_ULT: case CMP_ULTE: case CMP_UGT: case CMP_UGTE:
			bool signed = inst.tag == CMP_SLT || inst.tag == CMP_SLTE || inst.tag == CMP_SGT || inst.tag == CMP_SGTE;
			self.load(lhs, 9, signed)!; self.load(rhs, 10, signed)!;
			self.emit(CMP, reg_op(X9), reg_op(X10));
			self.emit(CSET, reg_op(X9), cond_op(condition(inst.tag)));
			self.save(ref)!;
		case FADD: case FSUB: case FMUL: case FDIV:
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			self.load_fp(lhs, 16)!; self.load_fp(rhs, 17)!;
			uint width = self.bits(self.inst(lhs).ty)!;
			bool compare = inst.tag == FCMP_OEQ || inst.tag == FCMP_UNE || inst.tag == FCMP_OLT || inst.tag == FCMP_OLE || inst.tag == FCMP_OGT || inst.tag == FCMP_OGE;
			if (compare)
			{
				self.emit(FCMP, reg_op(fp(16, width)), reg_op(fp(17, width)));
				self.emit(CSET, reg_op(X9), cond_op(condition(inst.tag)));
				self.save(ref)!;
			}
			else
			{
				Mnemonic op = inst.tag == FADD ? FADD : inst.tag == FSUB ? FSUB : inst.tag == FMUL ? FMUL : FDIV;
				self.emit(op, reg_op(fp(16, width)), reg_op(fp(16, width)), reg_op(fp(17, width)));
				self.save_fp(ref, 16)!;
			}
		case FNEG: case FABS: case FPEXT: case FPTRUNC:
			self.load_fp(inst.data.ref, 16)!;
			uint source = self.bits(self.inst(inst.data.ref).ty)!;
			uint width = self.bits(inst.ty)!;
			Mnemonic op = inst.tag == FNEG ? FNEG : inst.tag == FABS ? FABS : FCVT;
			self.emit(op, reg_op(fp(16, width)), reg_op(fp(16, source)));
			self.save_fp(ref, 16)!;
		case SITOFP: case UITOFP:
			self.load(inst.data.ref, 9, inst.tag == SITOFP)!;
			self.emit(inst.tag == SITOFP ? SCVTF : UCVTF, reg_op(fp(16, self.bits(inst.ty)!)), reg_op(X9));
			self.save_fp(ref, 16)!;
		case FPTOSI: case FPTOUI:
			self.load_fp(inst.data.ref, 16)!;
			self.emit(inst.tag == FPTOSI ? FCVTZS : FCVTZU, reg_op(X9), reg_op(fp(16, self.bits(self.inst(inst.data.ref).ty)!)));
			self.save(ref)!;
		case CLZ: case CTZ:
			self.load(inst.data.ref)!;
			uint width = self.bits(self.inst(inst.data.ref).ty)!;
			if (inst.tag == CTZ) self.emit(RBIT, reg_op(X9), reg_op(X9));
			self.emit(CLZ, reg_op(X9), reg_op(X9));
			if (inst.tag == CLZ && width < 64) self.emit(SUB, reg_op(X9), reg_op(X9), imm_op((long)(64 - width)));
			self.save(ref)!;
		case SELECT:
			self.load(inst.data.branch.cond, 11)!;
			self.load(inst.data.branch.then_label, 9)!;
			self.load(inst.data.branch.else_label, 10)!;
			self.emit(CMP, reg_op(X11), imm_op(0));
			self.emit(CSEL, reg_op(X9), reg_op(X9), reg_op(X10), cond_op(NE));
			self.save(ref)!;
		case CALL: self.call(ref)!;
		case RET:
			if (self.decl.darwin_result.size)
			{
				if (!self.decl.darwin_result.indirect())
				{
					self.load(inst.data.ref, 14)!;
					self.aggregate_result(self.decl.darwin_result, true)!;
				}
			}
			else if (inst.data.ref != ir::NONE)
			{
				if (self.is_float(self.inst(inst.data.ref).ty)) { self.load_fp(inst.data.ref, 0)!; }
				else { self.load(inst.data.ref, 0, self.decl.darwin_return_signed)!; }
			}
			self.emit(MOV, reg_op(SP), reg_op(X29));
			self.emit(LDP, reg_op(X29), reg_op(X30), mem_op(SP), imm_op(16));
			self.emit(RET);
		case JMP: self.jump(inst.data.ref)!;
		case BRANCH: self.branch(inst)!;
		case SWITCH: self.switch_inst(inst)!;
		case JMP_VAL:
			foreach (candidate : self.decl.instructions) if (candidate.tag == LABEL_ADDR) self.edge(candidate.data.ref)!;
			self.load(inst.data.ref)!; self.emit(BR, reg_op(X9));
		case STACK_SAVE: self.emit(MOV, reg_op(X9), reg_op(SP)); self.save(ref)!;
		case STACK_RESTORE: self.load(inst.data.ref)!; self.emit(MOV, reg_op(SP), reg_op(X9));
		case DYN_ALLOC:
			if (inst.data.dyn_alloc.align > 16) self.fail("ARM64: over-aligned variable-length allocation is unsupported")!;
			self.load(inst.data.dyn_alloc.size)!;
			self.emit(ADD, reg_op(X9), reg_op(X9), imm_op(15));
			self.emit(AND, reg_op(X9), reg_op(X9), imm_op(-16));
			self.emit(SUB, reg_op(SP), reg_op(SP), reg_op(X9));
			self.emit(MOV, reg_op(X9), reg_op(SP));
			self.save(ref)!;
		case VA_START:
			self.load(inst.data.ref, 10)!;
			self.immediate(9, (ulong)(16 + self.decl.darwin_va_offset));
			self.emit(ADD, reg_op(X9), reg_op(X29), reg_op(X9));
			self.emit(STR, reg_op(X9), mem_op(X10));
		default:
			self.fail(string::tformat("ARM64: unsupported IR instruction '%s'", inst.tag.name))!;
	}
}

fn void? Lowering.function(&self, ir::Decl* decl)
{
	self.decl = decl;
	self.block = ir::NONE;
	self.frame = 0;
	self.slots = mem::temp_array(uint, decl.instructions.len);
	self.areas = mem::temp_array(uint, decl.instructions.len);
	self.phi_slots = mem::temp_array(uint, decl.instructions.len);
	for (usz i = 0; i < decl.instructions.len; i++)
	{
		self.frame += 8;
		self.slots[i] = self.frame;
		self.areas[i] = 0;
		self.phi_slots[i] = 0;
	}
	foreach (ref : decl.body)
	{
		ir::Inst inst = self.inst(ref);
		if (inst.tag == ALLOC)
		{
			if (inst.data.alloc.align > 16) self.fail("ARM64: stack alignment greater than 16 is unsupported")!;
			self.frame = aligned(self.frame + inst.data.alloc.size, inst.data.alloc.align ? inst.data.alloc.align : 1);
			self.areas[(sz)ref] = self.frame;
		}
		if (inst.tag == PHI) { self.frame += 8; self.phi_slots[(sz)ref] = self.frame; }
	}
	self.frame = aligned(self.frame, 16);
	self.directive("\t.section __TEXT,__text,regular,pure_instructions\n");
	uint power = 2;
	while (((ulong)1 << power) < decl.code_align) power++;
	self.directive(string::tformat("\t.p2align %d\n", power));
	if (decl.linkage == EXTERNAL) self.directive(string::tformat("\t.globl %s\n", symbol(decl.name)));
	if (decl.is_hidden && decl.linkage == EXTERNAL) self.directive(string::tformat("\t.private_extern %s\n", symbol(decl.name)));
	if (decl.retain) self.directive(string::tformat("\t.no_dead_strip %s\n", symbol(decl.name)));
	if (decl.is_weak) self.directive(string::tformat("\t.weak_definition %s\n", symbol(decl.name)));
	self.emit_label(symbol(decl.name));
	self.emit(STP, reg_op(X29), reg_op(X30), mem_op(SP, -16, PRE_INDEX));
	self.emit(MOV, reg_op(X29), reg_op(SP));
	// Touch each page while growing a large frame so Darwin's stack guard is
	// traversed rather than jumped over. x9 is not an argument register.
	uint remaining = self.frame;
	while (remaining > 4096)
	{
		self.emit(SUB, reg_op(SP), reg_op(SP), imm_op(1), shift_op(12));
		self.emit(STR, reg_op(XZR), mem_op(SP));
		remaining -= 4096;
	}
	self.adjust_sp(remaining, true);
	foreach (ref : decl.body) self.lower(ref)!;
}


fn void Lowering.emit(&self, Mnemonic mnemonic, Operand a = {}, Operand b = {}, Operand c = {}, Operand d = {})
{
	Line line = { .mnemonic = mnemonic, .ops = { a, b, c, d } };
	foreach (op : line.ops) if (op.kind != NONE) line.op_count++;
	self.lines.push(line);
}
fn void Lowering.emit_label(&self, String label) => self.lines.push({ .is_label = true, .label = label });
fn void Lowering.directive(&self, String text) => self.lines.push({ .is_raw = true, .label = text });
