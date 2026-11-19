// Port of the System V parts of the Zig compiler's src/codegen/x86_64/abi.zig
// (`SysV`): scalar argument/return registers and preserved register sets.
module aro::backend::x86_64;
import aro::primitive_value;

enum SysVClass : char { INTEGER, SSE, X87 }

fn SysVClass classify(primitive_value::PrimitiveValue ty)
{
	if (ty.tag == primitive_value::PrimitiveType.FLOAT_TY)
	{
		// SysV returns x87 long double in ST0, but passes it in memory.
		if (ty.ty_bits == 80) return SysVClass.X87;
		return SysVClass.SSE;
	}
	return SysVClass.INTEGER;
}

<* SysV.c_abi_int_param_regs *>
const Register[6] SYSV_INT_PARAM_REGS = { RDI, RSI, RDX, RCX, R8, R9 };
<* SysV.c_abi_sse_param_regs: scalar float/double argument registers. *>
const Register[8] SYSV_SSE_PARAM_REGS = { XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6, XMM7 };
<* SysV.c_abi_sse_return_regs *>
const Register[2] SYSV_SSE_RETURN_REGS = { XMM0, XMM1 };
<* SysV.c_abi_int_return_regs *>
const Register[3] SYSV_INT_RETURN_REGS = { RAX, RDX, RCX };
<* SysV.callee_preserved_regs (general-purpose) *>
const Register[5] SYSV_CALLEE_PRESERVED_REGS = { RBX, R12, R13, R14, R15 };
<* SysV.caller_preserved_regs (general-purpose) *>
const Register[9] SYSV_CALLER_PRESERVED_REGS = { RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11 };
<* Stack alignment at a call instruction. *>
const uint SYSV_STACK_ALIGN = 16;
