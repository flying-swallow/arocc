// ARM64 backend, organized like the sibling x86_64 backend.
module aro::backend::aarch64;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::target;
import std::core::dstring, std::core::string, std::collections::list;

fn void? Lowering.edge(&self, ir::Ref target)
{
	bool in_target = false;
	foreach (ref : self.decl.body)
	{
		ir::Inst inst = self.inst(ref);
		if (inst.tag == LABEL) { in_target = ref == target; continue; }
		if (!in_target || inst.tag != PHI) continue;
		foreach (input : inst.data.phi)
		{
			if (input.label != self.block) continue;
			self.load(input.value)!;
			self.save_raw(self.phi_slots[(sz)ref], 9);
			break;
		}
	}
}

fn void? Lowering.jump(&self, ir::Ref target)
{
	self.edge(target)!;
	self.emit(B, target_op(self.label(target)));
}

