module llvm;

typedef PassBuilderOptionsRef @constinit = void*;
typedef ErrorRef @constinit = void*;

extern fn PassBuilderOptionsRef create_pass_builder_options() @cname("LLVMCreatePassBuilderOptions");
extern fn void dispose_pass_builder_options(PassBuilderOptionsRef options) @cname("LLVMDisposePassBuilderOptions");
extern fn void pass_builder_options_set_verify_each(PassBuilderOptionsRef options, Bool enabled) @cname("LLVMPassBuilderOptionsSetVerifyEach");
extern fn void pass_builder_options_set_loop_vectorization(PassBuilderOptionsRef options, Bool enabled) @cname("LLVMPassBuilderOptionsSetLoopVectorization");
extern fn void pass_builder_options_set_slp_vectorization(PassBuilderOptionsRef options, Bool enabled) @cname("LLVMPassBuilderOptionsSetSLPVectorization");

// A null result means success. Consume a non-null result with get_error_message or consume_error.
extern fn ErrorRef run_passes(ModuleRef module_ref, ZString pipeline, TargetMachineRef machine, PassBuilderOptionsRef options) @cname("LLVMRunPasses");
extern fn void consume_error(ErrorRef error) @cname("LLVMConsumeError");
// Consumes error. Dispose the returned string with dispose_error_message.
extern fn ZString get_error_message(ErrorRef error) @cname("LLVMGetErrorMessage");
extern fn void dispose_error_message(ZString message) @cname("LLVMDisposeErrorMessage");
