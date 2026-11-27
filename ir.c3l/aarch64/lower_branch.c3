// ARM64 backend, organized like the sibling x86_64 backend.
module aro::backend::aarch64;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::target;
import std::core::dstring, std::core::string, std::collections::list;

fn Condition condition(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_EQ: case FCMP_OEQ: return EQ;
		case CMP_NE: case FCMP_UNE: return NE;
		case CMP_SLT: return LT;
		case CMP_SLTE: return LE;
		case CMP_SGT: case FCMP_OGT: return GT;
		case CMP_SGTE: case FCMP_OGE: return GE;
		case CMP_ULT: case FCMP_OLT: return LO;
		case CMP_ULTE: case FCMP_OLE: return LS;
		case CMP_UGT: return HI;
		case CMP_UGTE: return HS;
		default: unreachable();
	}
}


fn void? Lowering.branch(&self, ir::Inst inst)
{
	uint edge = self.next_label++;
	self.load(inst.data.branch.cond)!;
	self.emit(CBZ, reg_op(X9), target_op(string::tformat("Laro_else_%d_%d", self.function_id, edge)));
	self.jump(inst.data.branch.then_label)!;
	self.emit_label(string::tformat("Laro_else_%d_%d", self.function_id, edge));
	self.jump(inst.data.branch.else_label)!;
}

fn void? Lowering.switch_inst(&self, ir::Inst inst)
{
	foreach (i, target : inst.data.switch_data.labels)
	{
		uint edge = self.next_label++;
		self.load(inst.data.switch_data.target)!;
		self.immediate(10, self.graph.interner.get(inst.data.switch_data.values[i]).int_low_u64());
		self.normalize(10, self.bits(self.inst(inst.data.switch_data.target).ty)!)!;
		self.emit(CMP, reg_op(X9), reg_op(X10));
		self.emit(B_NE, target_op(string::tformat("Laro_case_%d_%d", self.function_id, edge)));
		self.jump(target)!;
		self.emit_label(string::tformat("Laro_case_%d_%d", self.function_id, edge));
	}
	self.jump(inst.data.switch_data.default_label)!;
}
