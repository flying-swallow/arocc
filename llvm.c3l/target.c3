module llvm;

typedef TargetRef @constinit = void*;
typedef TargetMachineRef @constinit = void*;
typedef TargetDataRef @constinit = void*;

enum CodeGenOptLevel : int
{
	NONE,
	LESS,
	DEFAULT,
	AGGRESSIVE,
}

enum RelocMode : int
{
	DEFAULT,
	STATIC,
	PIC,
	DYNAMIC_NO_PIC,
	ROPI,
	RWPI,
	ROPI_RWPI,
}

enum CodeModel : int
{
	DEFAULT,
	JIT_DEFAULT,
	TINY,
	SMALL,
	KERNEL,
	MEDIUM,
	LARGE,
}

enum CodeGenFileType : int
{
	ASSEMBLY,
	OBJECT,
}

// Register the chosen target's info, target, MC and assembly printer in
// that order before looking it up. The LLVM build must include that target.
extern fn void initialize_x86_target_info() @cname("LLVMInitializeX86TargetInfo");
extern fn void initialize_x86_target() @cname("LLVMInitializeX86Target");
extern fn void initialize_x86_target_mc() @cname("LLVMInitializeX86TargetMC");
extern fn void initialize_x86_asm_printer() @cname("LLVMInitializeX86AsmPrinter");
extern fn void initialize_x86_asm_parser() @cname("LLVMInitializeX86AsmParser");

extern fn void initialize_aarch64_target_info() @cname("LLVMInitializeAArch64TargetInfo");
extern fn void initialize_aarch64_target() @cname("LLVMInitializeAArch64Target");
extern fn void initialize_aarch64_target_mc() @cname("LLVMInitializeAArch64TargetMC");
extern fn void initialize_aarch64_asm_printer() @cname("LLVMInitializeAArch64AsmPrinter");
extern fn void initialize_aarch64_asm_parser() @cname("LLVMInitializeAArch64AsmParser");

// Dispose the returned strings with dispose_message.
extern fn ZString get_default_target_triple() @cname("LLVMGetDefaultTargetTriple");
extern fn ZString normalize_target_triple(ZString triple) @cname("LLVMNormalizeTargetTriple");
extern fn ZString get_host_cpu_name() @cname("LLVMGetHostCPUName");
extern fn ZString get_host_cpu_features() @cname("LLVMGetHostCPUFeatures");

// The target is borrowed from LLVM's registry. Dispose any diagnostic with dispose_message.
extern fn Bool get_target_from_triple(ZString triple, TargetRef* target, ZString* message) @cname("LLVMGetTargetFromTriple");
extern fn TargetMachineRef create_target_machine(TargetRef target, ZString triple, ZString cpu, ZString features,
	CodeGenOptLevel level, RelocMode reloc, CodeModel model) @cname("LLVMCreateTargetMachine");
extern fn void dispose_target_machine(TargetMachineRef machine) @cname("LLVMDisposeTargetMachine");
extern fn TargetDataRef create_target_data_layout(TargetMachineRef machine) @cname("LLVMCreateTargetDataLayout");
extern fn void dispose_target_data(TargetDataRef layout) @cname("LLVMDisposeTargetData");
extern fn void set_module_data_layout(ModuleRef module_ref, TargetDataRef layout) @cname("LLVMSetModuleDataLayout");
extern fn ulong abi_size_of_type(TargetDataRef layout, TypeRef type) @cname("LLVMABISizeOfType");
extern fn uint abi_alignment_of_type(TargetDataRef layout, TypeRef type) @cname("LLVMABIAlignmentOfType");
extern fn ulong offset_of_element(TargetDataRef layout, TypeRef type, uint index) @cname("LLVMOffsetOfElement");

// On success the caller owns output. Dispose any diagnostic with dispose_message.
extern fn Bool target_machine_emit_to_memory_buffer(TargetMachineRef machine, ModuleRef module_ref,
	CodeGenFileType file_type, ZString* message, MemoryBufferRef* output) @cname("LLVMTargetMachineEmitToMemoryBuffer");
