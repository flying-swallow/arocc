// Port of the System V parts of the Zig compiler's src/codegen/x86_64/abi.zig
// (`SysV`): integer argument/return registers and preserved register sets.
module aro::backend::x86_64;

<* SysV.c_abi_int_param_regs *>
const Register[6] SYSV_INT_PARAM_REGS = { RDI, RSI, RDX, RCX, R8, R9 };
<* SysV.c_abi_int_return_regs *>
const Register[3] SYSV_INT_RETURN_REGS = { RAX, RDX, RCX };
<* SysV.callee_preserved_regs (general-purpose) *>
const Register[5] SYSV_CALLEE_PRESERVED_REGS = { RBX, R12, R13, R14, R15 };
<* SysV.caller_preserved_regs (general-purpose) *>
const Register[9] SYSV_CALLER_PRESERVED_REGS = { RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11 };
<* Stack alignment at a call instruction. *>
const uint SYSV_STACK_ALIGN = 16;
