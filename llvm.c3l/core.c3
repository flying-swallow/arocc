module llvm;

// LLVM ABI declarations from llvm-c/Types.h, Core.h, Analysis.h and IRReader.h.
// LLVMBool is a C int. In status results, zero indicates success.
alias Bool = int;
typedef ContextRef @constinit = void*;
typedef ModuleRef @constinit = void*;
typedef TypeRef @constinit = void*;
typedef ValueRef @constinit = void*;
typedef BasicBlockRef @constinit = void*;
typedef BuilderRef @constinit = void*;
typedef MemoryBufferRef @constinit = void*;
typedef AttributeRef @constinit = void*;

enum Linkage : int
{
	EXTERNAL,
	AVAILABLE_EXTERNALLY,
	LINK_ONCE_ANY,
	LINK_ONCE_ODR,
	LINK_ONCE_ODR_AUTO_HIDE, // Obsolete LLVM ABI slot.
	WEAK_ANY,
	WEAK_ODR,
	APPENDING,
	INTERNAL,
	PRIVATE,
	DLL_IMPORT, // Obsolete LLVM ABI slot.
	DLL_EXPORT, // Obsolete LLVM ABI slot.
	EXTERNAL_WEAK,
	GHOST, // Obsolete LLVM ABI slot.
	COMMON,
	LINKER_PRIVATE,
	LINKER_PRIVATE_WEAK,
}

enum Visibility : int
{
	DEFAULT,
	HIDDEN,
	PROTECTED,
}

enum VerifierFailureAction : int
{
	ABORT_PROCESS,
	PRINT_MESSAGE,
	RETURN_STATUS,
}

extern fn void get_version(uint* major, uint* minor, uint* patch) @cname("LLVMGetVersion");
extern fn void dispose_message(ZString message) @cname("LLVMDisposeMessage");

extern fn ContextRef context_create() @cname("LLVMContextCreate");
extern fn void context_dispose(ContextRef context) @cname("LLVMContextDispose");
extern fn ModuleRef module_create_with_name_in_context(ZString name, ContextRef context) @cname("LLVMModuleCreateWithNameInContext");
extern fn void dispose_module(ModuleRef module_ref) @cname("LLVMDisposeModule");
extern fn void set_target(ModuleRef module_ref, ZString triple) @cname("LLVMSetTarget");
// Dispose the returned text with dispose_message.
extern fn ZString print_module_to_string(ModuleRef module_ref) @cname("LLVMPrintModuleToString");
// Dispose any returned diagnostic with dispose_message.
extern fn Bool verify_module(ModuleRef module_ref, VerifierFailureAction action, ZString* message) @cname("LLVMVerifyModule");

extern fn MemoryBufferRef create_memory_buffer_with_memory_range_copy(char* input, usz length, ZString name) @cname("LLVMCreateMemoryBufferWithMemoryRangeCopy");
extern fn char* get_buffer_start(MemoryBufferRef buffer) @cname("LLVMGetBufferStart");
extern fn usz get_buffer_size(MemoryBufferRef buffer) @cname("LLVMGetBufferSize");
extern fn void dispose_memory_buffer(MemoryBufferRef buffer) @cname("LLVMDisposeMemoryBuffer");
// Consumes buffer on success or failure. Dispose any diagnostic with dispose_message.
extern fn Bool parse_ir_in_context(ContextRef context, MemoryBufferRef buffer, ModuleRef* output, ZString* message) @cname("LLVMParseIRInContext");

extern fn TypeRef void_type_in_context(ContextRef context) @cname("LLVMVoidTypeInContext");
extern fn TypeRef int_type_in_context(ContextRef context, uint bits) @cname("LLVMIntTypeInContext");
extern fn TypeRef half_type_in_context(ContextRef context) @cname("LLVMHalfTypeInContext");
extern fn TypeRef float_type_in_context(ContextRef context) @cname("LLVMFloatTypeInContext");
extern fn TypeRef double_type_in_context(ContextRef context) @cname("LLVMDoubleTypeInContext");
extern fn TypeRef x86_fp80_type_in_context(ContextRef context) @cname("LLVMX86FP80TypeInContext");
extern fn TypeRef fp128_type_in_context(ContextRef context) @cname("LLVMFP128TypeInContext");
extern fn TypeRef pointer_type_in_context(ContextRef context, uint address_space) @cname("LLVMPointerTypeInContext");
extern fn TypeRef array_type(TypeRef element, ulong count) @cname("LLVMArrayType2");
extern fn TypeRef vector_type(TypeRef element, uint count) @cname("LLVMVectorType");
extern fn TypeRef struct_type_in_context(ContextRef context, TypeRef* elements, uint count, Bool packed) @cname("LLVMStructTypeInContext");
extern fn TypeRef function_type(TypeRef result, TypeRef* parameters, uint count, Bool variadic) @cname("LLVMFunctionType");
extern fn TypeRef type_of(ValueRef value) @cname("LLVMTypeOf");
extern fn TypeRef global_get_value_type(ValueRef global) @cname("LLVMGlobalGetValueType");

extern fn ValueRef const_null(TypeRef type) @cname("LLVMConstNull");
extern fn ValueRef get_undef(TypeRef type) @cname("LLVMGetUndef");
extern fn ValueRef const_int(TypeRef type, ulong value, Bool sign_extend) @cname("LLVMConstInt");
extern fn ValueRef const_int_of_arbitrary_precision(TypeRef type, uint word_count, ulong* words) @cname("LLVMConstIntOfArbitraryPrecision");
extern fn ValueRef const_real(TypeRef type, double value) @cname("LLVMConstReal");
extern fn ValueRef const_bit_cast(ValueRef value, TypeRef type) @cname("LLVMConstBitCast");
extern fn ValueRef const_array(TypeRef element, ValueRef* values, ulong count) @cname("LLVMConstArray2");
extern fn ValueRef const_struct_in_context(ContextRef context, ValueRef* values, uint count, Bool packed) @cname("LLVMConstStructInContext");
extern fn ValueRef const_string_in_context(ContextRef context, char* bytes, uint length, Bool omit_terminator) @cname("LLVMConstStringInContext");
extern fn ValueRef const_gep(TypeRef element, ValueRef pointer, ValueRef* indices, uint count) @cname("LLVMConstGEP2");

extern fn ValueRef add_function(ModuleRef module_ref, ZString name, TypeRef signature) @cname("LLVMAddFunction");
extern fn ValueRef get_named_function(ModuleRef module_ref, ZString name) @cname("LLVMGetNamedFunction");
extern fn ValueRef get_param(ValueRef function, uint index) @cname("LLVMGetParam");
extern fn ValueRef add_global(ModuleRef module_ref, TypeRef type, ZString name) @cname("LLVMAddGlobal");
extern fn ValueRef get_named_global(ModuleRef module_ref, ZString name) @cname("LLVMGetNamedGlobal");
extern fn void set_initializer(ValueRef global, ValueRef initializer) @cname("LLVMSetInitializer");
extern fn void set_global_constant(ValueRef global, Bool constant) @cname("LLVMSetGlobalConstant");
extern fn void set_linkage(ValueRef global, Linkage linkage) @cname("LLVMSetLinkage");
extern fn void set_visibility(ValueRef global, Visibility visibility) @cname("LLVMSetVisibility");
extern fn void set_section(ValueRef global, ZString section) @cname("LLVMSetSection");
extern fn void set_alignment(ValueRef value, uint bytes) @cname("LLVMSetAlignment");

extern fn BasicBlockRef append_basic_block_in_context(ContextRef context, ValueRef function, ZString name) @cname("LLVMAppendBasicBlockInContext");
extern fn ValueRef get_basic_block_terminator(BasicBlockRef block) @cname("LLVMGetBasicBlockTerminator");

const uint ATTRIBUTE_RETURN_INDEX = 0;
const uint ATTRIBUTE_FUNCTION_INDEX = uint::max;
extern fn uint get_enum_attribute_kind_for_name(char* name, usz length) @cname("LLVMGetEnumAttributeKindForName");
extern fn AttributeRef create_enum_attribute(ContextRef context, uint kind, ulong value) @cname("LLVMCreateEnumAttribute");
extern fn AttributeRef create_type_attribute(ContextRef context, uint kind, TypeRef type) @cname("LLVMCreateTypeAttribute");
extern fn void add_attribute_at_index(ValueRef function, uint index, AttributeRef attribute) @cname("LLVMAddAttributeAtIndex");
extern fn void add_call_site_attribute(ValueRef call, uint index, AttributeRef attribute) @cname("LLVMAddCallSiteAttribute");
