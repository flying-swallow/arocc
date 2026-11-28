module llvm;

typedef IntPredicate @constinit = int;
const IntPredicate INT_EQ = (IntPredicate)32;
const IntPredicate INT_NE = (IntPredicate)33;
const IntPredicate INT_UGT = (IntPredicate)34;
const IntPredicate INT_UGE = (IntPredicate)35;
const IntPredicate INT_ULT = (IntPredicate)36;
const IntPredicate INT_ULE = (IntPredicate)37;
const IntPredicate INT_SGT = (IntPredicate)38;
const IntPredicate INT_SGE = (IntPredicate)39;
const IntPredicate INT_SLT = (IntPredicate)40;
const IntPredicate INT_SLE = (IntPredicate)41;

enum RealPredicate : int
{
	ALWAYS_FALSE,
	OEQ,
	OGT,
	OGE,
	OLT,
	OLE,
	ONE,
	ORD,
	UNO,
	UEQ,
	UGT,
	UGE,
	ULT,
	ULE,
	UNE,
	ALWAYS_TRUE,
}

extern fn BuilderRef create_builder_in_context(ContextRef context) @cname("LLVMCreateBuilderInContext");
extern fn void dispose_builder(BuilderRef builder) @cname("LLVMDisposeBuilder");
extern fn void position_builder_at_end(BuilderRef builder, BasicBlockRef block) @cname("LLVMPositionBuilderAtEnd");

extern fn ValueRef build_ret_void(BuilderRef builder) @cname("LLVMBuildRetVoid");
extern fn ValueRef build_ret(BuilderRef builder, ValueRef value) @cname("LLVMBuildRet");
extern fn ValueRef build_br(BuilderRef builder, BasicBlockRef destination) @cname("LLVMBuildBr");
extern fn ValueRef build_cond_br(BuilderRef builder, ValueRef condition, BasicBlockRef then_block, BasicBlockRef else_block) @cname("LLVMBuildCondBr");
extern fn ValueRef build_switch(BuilderRef builder, ValueRef value, BasicBlockRef default_block, uint case_count) @cname("LLVMBuildSwitch");
extern fn void add_case(ValueRef switch_inst, ValueRef value, BasicBlockRef destination) @cname("LLVMAddCase");
extern fn ValueRef build_unreachable(BuilderRef builder) @cname("LLVMBuildUnreachable");
extern fn ValueRef build_select(BuilderRef builder, ValueRef condition, ValueRef then_value, ValueRef else_value, ZString name) @cname("LLVMBuildSelect");
extern fn ValueRef build_phi(BuilderRef builder, TypeRef type, ZString name) @cname("LLVMBuildPhi");
extern fn void add_incoming(ValueRef phi, ValueRef* values, BasicBlockRef* blocks, uint count) @cname("LLVMAddIncoming");
extern fn ValueRef build_call(BuilderRef builder, TypeRef signature, ValueRef callee, ValueRef* arguments, uint count, ZString name) @cname("LLVMBuildCall2");

extern fn ValueRef build_alloca(BuilderRef builder, TypeRef type, ZString name) @cname("LLVMBuildAlloca");
extern fn ValueRef build_array_alloca(BuilderRef builder, TypeRef element, ValueRef count, ZString name) @cname("LLVMBuildArrayAlloca");
extern fn ValueRef build_load(BuilderRef builder, TypeRef type, ValueRef pointer, ZString name) @cname("LLVMBuildLoad2");
extern fn ValueRef build_store(BuilderRef builder, ValueRef value, ValueRef pointer) @cname("LLVMBuildStore");
extern fn ValueRef build_gep(BuilderRef builder, TypeRef element, ValueRef pointer, ValueRef* indices, uint count, ZString name) @cname("LLVMBuildGEP2");
extern fn void set_volatile(ValueRef memory_inst, Bool is_volatile) @cname("LLVMSetVolatile");

extern fn ValueRef build_add(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildAdd");
extern fn ValueRef build_nsw_add(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildNSWAdd");
extern fn ValueRef build_sub(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildSub");
extern fn ValueRef build_nsw_sub(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildNSWSub");
extern fn ValueRef build_mul(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildMul");
extern fn ValueRef build_nsw_mul(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildNSWMul");
extern fn ValueRef build_sdiv(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildSDiv");
extern fn ValueRef build_udiv(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildUDiv");
extern fn ValueRef build_srem(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildSRem");
extern fn ValueRef build_urem(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildURem");
extern fn ValueRef build_and(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildAnd");
extern fn ValueRef build_or(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildOr");
extern fn ValueRef build_xor(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildXor");
extern fn ValueRef build_shl(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildShl");
extern fn ValueRef build_lshr(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildLShr");
extern fn ValueRef build_ashr(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildAShr");
extern fn ValueRef build_icmp(BuilderRef builder, IntPredicate predicate, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildICmp");
extern fn ValueRef build_fadd(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildFAdd");
extern fn ValueRef build_fsub(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildFSub");
extern fn ValueRef build_fmul(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildFMul");
extern fn ValueRef build_fdiv(BuilderRef builder, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildFDiv");
extern fn ValueRef build_fneg(BuilderRef builder, ValueRef value, ZString name) @cname("LLVMBuildFNeg");
extern fn ValueRef build_fcmp(BuilderRef builder, RealPredicate predicate, ValueRef lhs, ValueRef rhs, ZString name) @cname("LLVMBuildFCmp");

extern fn ValueRef build_trunc(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildTrunc");
extern fn ValueRef build_zext(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildZExt");
extern fn ValueRef build_sext(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildSExt");
extern fn ValueRef build_fp_to_si(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildFPToSI");
extern fn ValueRef build_fp_to_ui(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildFPToUI");
extern fn ValueRef build_si_to_fp(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildSIToFP");
extern fn ValueRef build_ui_to_fp(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildUIToFP");
extern fn ValueRef build_fp_trunc(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildFPTrunc");
extern fn ValueRef build_fp_ext(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildFPExt");
extern fn ValueRef build_ptr_to_int(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildPtrToInt");
extern fn ValueRef build_int_to_ptr(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildIntToPtr");
extern fn ValueRef build_bit_cast(BuilderRef builder, ValueRef value, TypeRef type, ZString name) @cname("LLVMBuildBitCast");

extern fn ValueRef build_extract_value(BuilderRef builder, ValueRef aggregate, uint index, ZString name) @cname("LLVMBuildExtractValue");
extern fn ValueRef build_insert_value(BuilderRef builder, ValueRef aggregate, ValueRef value, uint index, ZString name) @cname("LLVMBuildInsertValue");
extern fn ValueRef build_extract_element(BuilderRef builder, ValueRef vector, ValueRef index, ZString name) @cname("LLVMBuildExtractElement");
extern fn ValueRef build_insert_element(BuilderRef builder, ValueRef vector, ValueRef value, ValueRef index, ZString name) @cname("LLVMBuildInsertElement");
extern fn ValueRef build_shuffle_vector(BuilderRef builder, ValueRef lhs, ValueRef rhs, ValueRef mask, ZString name) @cname("LLVMBuildShuffleVector");
