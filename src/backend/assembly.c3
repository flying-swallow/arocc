// Public assembly result and architecture dispatcher.
module aro::backend::assembly;
import aro::tree, aro::target, aro::compilation, aro::backend::assembly_x86_64;
import std::core::dstring;

excuse UNSUPPORTED_ARCHITECTURE;

<* The generated assembly data and its human-readable text representation. *>
struct Assembly
{
	DString data;
	DString text;
}

fn void Assembly.free(&self)
{
	self.data.free();
	self.text.free();
	*self = {};
}

<*
 Generate assembly for the target architecture. Currently only X86_64 is
 supported; other architectures return UNSUPPORTED_ARCHITECTURE.
 @return? UNSUPPORTED_ARCHITECTURE, compilation::FATAL_ERROR
*>
fn Assembly? gen_asm(tree::Tree* tree)
{
	Assembly result;
	result.data.init(tree.comp.gpa);
	result.text.init(tree.comp.gpa);
	switch (tree.comp.target.cpu.arch)
	{
		case X86_64:
			fault f = @catch(assembly_x86_64::gen_asm(tree, &result.data, &result.text));
			if (f)
			{
				result.free();
				return f~;
			}
			return result;
		default:
			result.free();
			return UNSUPPORTED_ARCHITECTURE~;
	}
}
