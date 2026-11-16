// x86_64 backend: the ported Zig encoding table, register/condition data, and
// IR -> assembly lowering on hand-built IR.
module x86_64_tests;
import aro::primitive_value;
import std, aro::backend::elf, aro::backend::ir, aro::backend::object, aro::backend::x86_64, aro::target, aro::value_interner;
import std::core::mem::allocators;

fn Entry entry_for(Mnemonic m, Operand[] ops) => x86_64::find(m, ops)!!;

fn Encoded assert_encoded(Mnemonic mnemonic, Operand[] ops, char[] expected)
{
	Encoded encoded = x86_64::encode(mnemonic, ops)!!;
	assert((usz)encoded.len == expected.len, "wrong encoded length for %s", mnemonic.name);
	for (usz i = 0; i < expected.len; i++)
	{
		assert(encoded.bytes[i] == expected[i], "wrong byte %d for %s", i, mnemonic.name);
	}
	return encoded;
}

fn void encode_zi_and_immediate_modrm_rows() @test
{
	// add eax, 1000
	assert_encoded(ADD, { x86_64::reg_op(EAX), x86_64::imm_op(1000) }, (char[]){ 0x05, 0xe8, 0x03, 0, 0 });
	// cmp al, 7
	assert_encoded(CMP, { x86_64::reg_op(AL), x86_64::imm_op(7) }, (char[]){ 0x3c, 0x07 });
	// add rax, 5
	assert_encoded(ADD, { x86_64::reg_op(RAX), x86_64::imm_op(5) }, (char[]){ 0x48, 0x83, 0xc0, 0x05 });
	// sub rsp, 32
	assert_encoded(SUB, { x86_64::reg_op(RSP), x86_64::imm_op(32) }, (char[]){ 0x48, 0x83, 0xec, 0x20 });
	// and ecx, 100000
	assert_encoded(AND, { x86_64::reg_op(ECX), x86_64::imm_op(100000) }, (char[]){ 0x81, 0xe1, 0xa0, 0x86, 0x01, 0 });
	// mov rax, -1
	assert_encoded(MOV, { x86_64::reg_op(RAX), x86_64::imm_op(-1) }, (char[]){ 0x48, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff });
}

fn void encode_mr_rm_and_sib_rows() @test
{
	// mov ecx, eax
	assert_encoded(MOV, { x86_64::reg_op(ECX), x86_64::reg_op(EAX) }, (char[]){ 0x89, 0xc1 });
	// mov dword ptr [rbp - 8], edi
	assert_encoded(MOV, { x86_64::mem_op(RBP, -8, 32), x86_64::reg_op(EDI) }, (char[]){ 0x89, 0x7d, 0xf8 });
	// mov qword ptr [rbp - 200], r12
	assert_encoded(MOV, { x86_64::mem_op(RBP, -200, 64), x86_64::reg_op(R12) }, (char[]){ 0x4c, 0x89, 0xa5, 0x38, 0xff, 0xff, 0xff });
	// mov byte ptr [rcx], al
	assert_encoded(MOV, { x86_64::mem_op(RCX, 0, 8), x86_64::reg_op(AL) }, (char[]){ 0x88, 0x01 });
	// mov qword ptr [rsp + 8], rax
	assert_encoded(MOV, { x86_64::mem_op(RSP, 8, 64), x86_64::reg_op(RAX) }, (char[]){ 0x48, 0x89, 0x44, 0x24, 0x08 });
	// mov eax, dword ptr [rbp - 8]
	assert_encoded(MOV, { x86_64::reg_op(EAX), x86_64::mem_op(RBP, -8, 32) }, (char[]){ 0x8b, 0x45, 0xf8 });
	// mov rax, qword ptr [r13]
	assert_encoded(MOV, { x86_64::reg_op(RAX), x86_64::mem_op(R13, 0, 64) }, (char[]){ 0x49, 0x8b, 0x45, 0 });
	// mov sil, byte ptr [rcx]
	assert_encoded(MOV, { x86_64::reg_op(SIL), x86_64::mem_op(RCX, 0, 8) }, (char[]){ 0x40, 0x8a, 0x31 });
	// imul eax, ecx
	assert_encoded(IMUL, { x86_64::reg_op(EAX), x86_64::reg_op(ECX) }, (char[]){ 0x0f, 0xaf, 0xc1 });
	// lea rax, [rbp - 16]
	assert_encoded(LEA, { x86_64::reg_op(RAX), x86_64::mem_op(RBP, -16, 0) }, (char[]){ 0x48, 0x8d, 0x45, 0xf0 });
}

fn void encode_opcode_register_and_zero_operand_rows() @test
{
	// mov eax, 100000
	assert_encoded(MOV, { x86_64::reg_op(EAX), x86_64::imm_op(100000) }, (char[]){ 0xb8, 0xa0, 0x86, 0x01, 0 });
	// mov r9d, 1
	assert_encoded(MOV, { x86_64::reg_op(R9D), x86_64::imm_op(1) }, (char[]){ 0x41, 0xb9, 1, 0, 0, 0 });
	// mov rax, 1099511627776
	assert_encoded(MOV, { x86_64::reg_op(RAX), x86_64::imm_op(1099511627776L) }, (char[]){ 0x48, 0xb8, 0, 0, 0, 0, 0, 1, 0, 0 });
	// push rbp
	assert_encoded(PUSH, { x86_64::reg_op(RBP) }, (char[]){ 0x55 });
	// push r12
	assert_encoded(PUSH, { x86_64::reg_op(R12) }, (char[]){ 0x41, 0x54 });
	// pop r15
	assert_encoded(POP, { x86_64::reg_op(R15) }, (char[]){ 0x41, 0x5f });
	// cqo
	assert_encoded(CQO, {}, (char[]){ 0x48, 0x99 });
	// cdq
	assert_encoded(CDQ, {}, (char[]){ 0x99 });
	// leave
	assert_encoded(LEAVE, {}, (char[]){ 0xc9 });
	// ret
	assert_encoded(RET, {}, (char[]){ 0xc3 });
}

fn void encode_grouped_modrm_rows() @test
{
	// idiv ecx
	assert_encoded(IDIV, { x86_64::reg_op(ECX) }, (char[]){ 0xf7, 0xf9 });
	// div r8
	assert_encoded(DIV, { x86_64::reg_op(R8) }, (char[]){ 0x49, 0xf7, 0xf0 });
	// neg rax
	assert_encoded(NEG, { x86_64::reg_op(RAX) }, (char[]){ 0x48, 0xf7, 0xd8 });
	// not al
	assert_encoded(NOT, { x86_64::reg_op(AL) }, (char[]){ 0xf6, 0xd0 });
	// call r11
	assert_encoded(CALL, { x86_64::reg_op(R11) }, (char[]){ 0x41, 0xff, 0xd3 });
	// sete al
	assert_encoded(SETE, { x86_64::reg_op(AL) }, (char[]){ 0x0f, 0x94, 0xc0 });
	// setl r12b
	assert_encoded(SETL, { x86_64::reg_op(R12B) }, (char[]){ 0x41, 0x0f, 0x9c, 0xc4 });
	// shl eax, cl
	assert_encoded(SHL, { x86_64::reg_op(EAX), x86_64::reg_op(CL) }, (char[]){ 0xd3, 0xe0 });
	// sar rax, cl
	assert_encoded(SAR, { x86_64::reg_op(RAX), x86_64::reg_op(CL) }, (char[]){ 0x48, 0xd3, 0xf8 });
	// shr r10w, cl
	assert_encoded(SHR, { x86_64::reg_op(R10W), x86_64::reg_op(CL) }, (char[]){ 0x66, 0x41, 0xd3, 0xea });
	// imul eax, ecx, 10
	assert_encoded(IMUL, { x86_64::reg_op(EAX), x86_64::reg_op(ECX), x86_64::imm_op(10) }, (char[]){ 0x6b, 0xc1, 0x0a });
	// movzx eax, al
	assert_encoded(MOVZX, { x86_64::reg_op(EAX), x86_64::reg_op(AL) }, (char[]){ 0x0f, 0xb6, 0xc0 });
	// movsx eax, cx
	assert_encoded(MOVSX, { x86_64::reg_op(EAX), x86_64::reg_op(CX) }, (char[]){ 0x0f, 0xbf, 0xc1 });
	// movsxd rax, eax
	assert_encoded(MOVSXD, { x86_64::reg_op(RAX), x86_64::reg_op(EAX) }, (char[]){ 0x48, 0x63, 0xc0 });
}

fn void encode_rip_relative_and_branch_fixups() @test
{
	// lea rax, [rip + sym]
	Encoded lea = assert_encoded(LEA, { x86_64::reg_op(RAX), x86_64::symbol_mem_op("sym") }, (char[]){ 0x48, 0x8d, 0x05, 0, 0, 0, 0 });
	assert(lea.fixup.kind == SYMBOL && lea.fixup.name == "sym" && lea.fixup.reloc == object::RelocKind.PC32);
	assert(lea.fixup.offset == 3 && lea.fixup.addend == -4);
	// mov eax, dword ptr [rip + g + 8]
	Operand g_disp = { .kind = MEM, .mem = { .base_kind = SYMBOL, .base = RIP, .disp = 8, .name = "g", .bits = 32 } };
	Encoded g8 = assert_encoded(MOV, { x86_64::reg_op(EAX), g_disp }, (char[]){ 0x8b, 0x05, 0, 0, 0, 0 });
	assert(g8.fixup.kind == SYMBOL && g8.fixup.name == "g" && g8.fixup.reloc == object::RelocKind.PC32);
	assert(g8.fixup.offset == 2 && g8.fixup.addend == 4);
	// mov rax, qword ptr [rip + abs@GOTPCREL]
	Encoded got = assert_encoded(MOV, { x86_64::reg_op(RAX), x86_64::got_symbol_mem_op("abs") }, (char[]){ 0x48, 0x8b, 0x05, 0, 0, 0, 0 });
	assert(got.fixup.kind == SYMBOL && got.fixup.name == "abs" && got.fixup.reloc == object::RelocKind.REX_GOTPCRELX);
	assert(got.fixup.offset == 3 && got.fixup.addend == -4);
	// mov dword ptr [rip + g], 5
	Encoded imm_after_disp = assert_encoded(MOV, { x86_64::symbol_mem_op("g", 32), x86_64::imm_op(5) }, (char[]){ 0xc7, 0x05, 0, 0, 0, 0, 5, 0, 0, 0 });
	assert(imm_after_disp.fixup.kind == SYMBOL && imm_after_disp.fixup.name == "g");
	assert(imm_after_disp.fixup.reloc == object::RelocKind.PC32 && imm_after_disp.fixup.offset == 2 && imm_after_disp.fixup.addend == -8);
	// call ext@PLT
	Encoded call = assert_encoded(CALL, { x86_64::target_op("ext", true) }, (char[]){ 0xe8, 0, 0, 0, 0 });
	assert(call.fixup.kind == SYMBOL && call.fixup.name == "ext" && call.fixup.reloc == object::RelocKind.PLT32);
	assert(call.fixup.offset == 1 && call.fixup.addend == -4);
	// jne .Lx (the local target is fixed up by the caller after labels are laid out)
	Encoded jne = assert_encoded(JNE, { x86_64::target_op(".Lx") }, (char[]){ 0x0f, 0x85, 0, 0, 0, 0 });
	assert(jne.fixup.kind == LOCAL_REL32 && jne.fixup.name == ".Lx" && jne.fixup.offset == 2 && jne.fixup.addend == -4);
	// jmp .Lx
	Encoded jmp = assert_encoded(JMP, { x86_64::target_op(".Lx") }, (char[]){ 0xe9, 0, 0, 0, 0 });
	assert(jmp.fixup.kind == LOCAL_REL32 && jmp.fixup.name == ".Lx" && jmp.fixup.offset == 1 && jmp.fixup.addend == -4);
}

fn void encoding_table_picks_zig_rows() @test
{
	// add r32, r32: the first shortest row is `mr` (opcode 0x01), as Zig picks it.
	Entry add = entry_for(ADD, { x86_64::reg_op(EAX), x86_64::reg_op(ECX) });
	assert(add.op_en == MR && add.opc[0] == 0x01 && add.mode == NONE);
	// add rax, 5: the imm8s row (0x83 /0) is shorter than `add rax, imm32s` (0x05).
	Entry add_imm = entry_for(ADD, { x86_64::reg_op(RAX), x86_64::imm_op(5) });
	assert(add_imm.opc[0] == 0x83 && add_imm.modrm_ext == 0 && add_imm.mode == LONG);
	// mov eax, imm32: `oi` (0xb8+r); a 64-bit immediate needs mov r64, imm64.
	assert(entry_for(MOV, { x86_64::reg_op(EAX), x86_64::imm_op(100000) }).opc[0] == 0xb8);
	Entry movabs = entry_for(MOV, { x86_64::reg_op(RAX), x86_64::imm_op(1L << 40) });
	assert(movabs.ops[1] == Op.IMM64 && movabs.mode == LONG);
	// Memory operands carry their size; lea takes an unsized memory operand.
	assert(entry_for(MOV, { x86_64::mem_op(RBP, -8, 32), x86_64::reg_op(EAX) }).opc[0] == 0x89);
	assert(entry_for(LEA, { x86_64::reg_op(RCX), x86_64::mem_op(RBP, -16, 0) }).opc[0] == 0x8d);
	// Condition codes map to their set/jump rows.
	assert(entry_for(SETL, { x86_64::reg_op(AL) }).opc[1] == 0x9c);
	assert(entry_for(JNE, { x86_64::target_op(".L1") }).opc[1] == 0x85);
	// No row: a memory-to-memory move.
	assert(@catch(x86_64::find(MOV, { x86_64::mem_op(RBP, -8, 32), x86_64::mem_op(RBP, -16, 32) })) == x86_64::NO_ENCODING);
}

fn void registers_and_conditions_follow_bits_zig() @test
{
	assert(Register.R9.to_bits(32) == R9D && Register.EAX.to_bits(8) == AL && Register.SIL.to_bits(64) == RSI);
	assert(Register.R12B.is_extended() && !Register.EAX.is_extended() && Register.AH.is_high_byte());
	assert(x86_64::SYSV_INT_PARAM_REGS[0] == RDI && x86_64::SYSV_INT_PARAM_REGS[5] == R9);
	foreach (cc : Condition::values) assert(cc.negated.negated == cc, "%s", cc);
	assert(Condition.L.negated == GE && Condition.B.set == SETB && Condition.A.jump == JA);
}

struct Fixture
{
	TrackingAllocator ta;
	value_interner::Interner interner;
	ir::Builder builder;
}

const target::Host HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

fn target::Target object_target()
{
	target::Target? parsed = target::parse_triple("x86_64-linux-gnu", HOST);
	if (catch err = parsed) unreachable("object test target must parse");
	return parsed;
}

fn void Fixture.init(&self)
{
	self.ta.init(mem);
	self.interner.init(&self.ta);
	self.builder.init(&self.ta, &self.interner);
}

fn String? render(Fixture* f, ir::ErrorList* errors, bool spill_all = false)
{
	ir::Ir graph = f.builder.finish();
	defer graph.free();
	return x86_64::render_asm(&graph, &f.ta, errors, spill_all);
}

fn object::Object* render_object(Fixture* f, ir::ErrorList* errors, ir::Ir* graph, bool spill_all = false)
{
	*graph = f.builder.finish();
	return ir::render_object(graph, &f.ta, object_target(), errors, spill_all)!!;
}

fn elf::SectionData* elf_section(elf::Elf* e, String name)
{
	foreach (section : e.sections) if (section.name == name) return section;
	unreachable("expected ELF section not found");
}

fn elf::Symbol* elf_symbol(elf::Elf* e, String name)
{
	foreach (symbol : e.locals) if (symbol.name == name) return symbol;
	foreach (symbol : e.globals) if (symbol.name == name) return symbol;
	unreachable("expected ELF symbol not found");
}

struct ObjectSink (OutStream)
{
	ByteWriter bytes;
}

fn void ObjectSink.init(&self) { self.bytes.init(mem); }
fn sz? ObjectSink.write(&self, char[] data) @dynamic => self.bytes.write(data);
fn void? ObjectSink.write_byte(&self, char byte) @dynamic => self.bytes.write_byte(byte);
fn void? ObjectSink.flush(&self) @dynamic {}
fn void ObjectSink.free(&self) { (void)self.bytes.destroy(); }

fn ulong read_elf_le(char[] bytes, usz offset, uint width)
{
	assert(offset + width <= bytes.len, "ELF field fits in object bytes");
	ulong value = 0;
	for (uint i = 0; i < width; i++) value |= ((ulong)(uint)bytes[(sz)(offset + i)] & 0xff) << (i * 8);
	return value;
}

fn ulong elf_section_index(char[] bytes, String wanted)
{
	ulong headers = read_elf_le(bytes, 40, 8);
	ulong header_size = read_elf_le(bytes, 58, 2);
	ulong header_count = read_elf_le(bytes, 60, 2);
	ulong names_index = read_elf_le(bytes, 62, 2);
	ulong names_header = headers + names_index * header_size;
	ulong names_offset = read_elf_le(bytes, (usz)(names_header + 24), 8);
	for (ulong index = 1; index < header_count; index++)
	{
		ulong header = headers + index * header_size;
		ulong name_offset = read_elf_le(bytes, (usz)header, 4);
		bool matches = true;
		for (usz i = 0; i < wanted.len; i++)
		{
			if (names_offset + name_offset + i >= (ulong)bytes.len ||
				bytes[(sz)(names_offset + name_offset + i)] != wanted[i])
			{
				matches = false;
				break;
			}
		}
		if (matches && names_offset + name_offset + wanted.len < (ulong)bytes.len &&
			bytes[(sz)(names_offset + name_offset + wanted.len)] == 0) return index;
	}
	unreachable("expected ELF section not found");
}

fn ulong elf_symbol_entry(char[] bytes, String wanted)
{
	ulong symbol_header = elf_section_index(bytes, ".symtab");
	ulong headers = read_elf_le(bytes, 40, 8);
	ulong header_size = read_elf_le(bytes, 58, 2);
	ulong symbol_section = headers + symbol_header * header_size;
	ulong symbols_offset = read_elf_le(bytes, (usz)(symbol_section + 24), 8);
	ulong symbols_size = read_elf_le(bytes, (usz)(symbol_section + 32), 8);
	ulong strings_index = read_elf_le(bytes, (usz)(symbol_section + 40), 4);
	ulong strings_header = headers + strings_index * header_size;
	ulong strings_offset = read_elf_le(bytes, (usz)(strings_header + 24), 8);
	ulong strings_size = read_elf_le(bytes, (usz)(strings_header + 32), 8);
	ulong entry_size = read_elf_le(bytes, (usz)(symbol_section + 56), 8);
	for (ulong offset = entry_size; offset < symbols_size; offset += entry_size)
	{
		ulong entry = symbols_offset + offset;
		ulong name_offset = read_elf_le(bytes, (usz)entry, 4);
		if (name_offset >= strings_size) continue;
		bool matches = true;
		for (usz i = 0; i < wanted.len; i++)
		{
			if (name_offset + i >= strings_size ||
				bytes[(sz)(strings_offset + name_offset + i)] != wanted[i])
			{
				matches = false;
				break;
			}
		}
		if (matches && name_offset + wanted.len < strings_size &&
			bytes[(sz)(strings_offset + name_offset + wanted.len)] == 0) return entry;
	}
	unreachable("expected ELF symbol not found");
}

fn long read_rel32(char[] bytes, usz offset)
{
	assert(offset + 4 <= bytes.len, "rel32 field fits in section bytes");
	uint raw = (uint)bytes[(sz)offset] |
		((uint)bytes[(sz)offset + 1] << 8) |
		((uint)bytes[(sz)offset + 2] << 16) |
		((uint)bytes[(sz)offset + 3] << 24);
	if ((raw & 0x8000_0000) != 0) return (long)raw - 0x1_0000_0000L;
	return (long)raw;
}

fn void build_signed_division_fixture(Fixture* f)
{
	f.builder.start_fn();
	ir::Ref a = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref b = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref q = f.builder.add_inst(SDIV, { .bin = { .lhs = a, .rhs = b } }, value_interner::REF_I32);
	f.builder.add_inst(RET, { .ref = q }, value_interner::REF_NORETURN);
	f.builder.finish_fn("quot");
}

fn void lowers_signed_division_and_return() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	build_signed_division_fixture(&f);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors, true)!!;
	defer alloc::free(&f.ta, text.ptr);
	test::eq(text,
		"\t.intel_syntax noprefix\n"
		"\t.text\n"
		"\t.globl quot\n"
		"\t.p2align 4\n"
		"\t.type quot, @function\n"
		"quot:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		"\tsub rsp, 32\n"
		"\tmov dword ptr [rbp - 8], edi\n"
		"\tmov dword ptr [rbp - 16], esi\n"
		".Lquot.entry.0:\n"
		"\tmov eax, dword ptr [rbp - 8]\n"
		"\tmov ecx, dword ptr [rbp - 16]\n"
		"\tcdq\n"
		"\tidiv ecx\n"
		"\tmov dword ptr [rbp - 24], eax\n"
		"\tmov eax, dword ptr [rbp - 24]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size quot, .-quot\n\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
}

fn void lowers_signed_division_in_register_mode() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	build_signed_division_fixture(&f);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors)!!;
	defer alloc::free(&f.ta, text.ptr);
	test::eq(text,
		"\t.intel_syntax noprefix\n"
		"\t.text\n"
		"\t.globl quot\n"
		"\t.p2align 4\n"
		"\t.type quot, @function\n"
		"quot:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		"\tsub rsp, 64\n"
		"\tmov qword ptr [rbp - 40], rbx\n"
		"\tmov qword ptr [rbp - 48], r12\n"
		"\tmov qword ptr [rbp - 56], r13\n"
		"\tmov ebx, edi\n"
		"\tmov r12d, esi\n"
		".Lquot.entry.0:\n"
		"\tmov eax, ebx\n"
		"\tmov ecx, r12d\n"
		"\tcdq\n"
		"\tidiv ecx\n"
		"\tmov r13d, eax\n"
		"\tmov eax, r13d\n"
		"\tmov rbx, qword ptr [rbp - 40]\n"
		"\tmov r12, qword ptr [rbp - 48]\n"
		"\tmov r13, qword ptr [rbp - 56]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size quot, .-quot\n\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
}

fn void lowers_seven_live_builder_values_in_register_mode() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref arg_a = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref arg_b = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref arg_c = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref arg_d = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref arg_e = f.builder.add_arg(value_interner::REF_I32);
	ir::Ref arg_f = f.builder.add_arg(value_interner::REF_I32);
	// Keep the six arguments live after defining a seventh independent value.
	ir::Ref extra = f.builder.add_inst(ADD, { .bin = { .lhs = arg_a, .rhs = arg_b } }, value_interner::REF_I32);
	ir::Ref sum = f.builder.add_inst(ADD, { .bin = { .lhs = arg_a, .rhs = arg_b } }, value_interner::REF_I32);
	sum = f.builder.add_inst(ADD, { .bin = { .lhs = sum, .rhs = arg_c } }, value_interner::REF_I32);
	sum = f.builder.add_inst(ADD, { .bin = { .lhs = sum, .rhs = arg_d } }, value_interner::REF_I32);
	sum = f.builder.add_inst(ADD, { .bin = { .lhs = sum, .rhs = arg_e } }, value_interner::REF_I32);
	sum = f.builder.add_inst(ADD, { .bin = { .lhs = sum, .rhs = arg_f } }, value_interner::REF_I32);
	sum = f.builder.add_inst(ADD, { .bin = { .lhs = sum, .rhs = extra } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("sum_seven_live");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors)!!;
	defer alloc::free(&f.ta, text.ptr);
	assert(text.contains("sum_seven_live:"), "seven simultaneously live Builder values lower successfully");
	assert(text.contains("\tmov dword ptr [rbp - 56], eax"),
		"a non-ARG value spills to its existing frame slot under register pressure");
}

fn void lowers_loop_invariant_phi_with_backedge_in_register_mode() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref condition = f.builder.add_arg(value_interner::REF_I1);
	ir::Ref entry = f.builder.current_label;
	ir::Ref invariant = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I32);
	ir::Ref header = f.builder.make_label("header");
	ir::Ref body = f.builder.make_label("body");
	ir::Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	ir::PhiInput[2] incoming = {
		{ .label = entry, .value = invariant },
		{ .label = body, .value = invariant },
	};
	ir::Ref loop_value = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	f.builder.add_inst(ADD, { .bin = { .lhs = loop_value, .rhs = invariant } }, value_interner::REF_I32);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(loop_value);
	f.builder.finish_fn("loop_invariant_phi");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors)!!;
	defer alloc::free(&f.ta, text.ptr);
	assert(text.contains("loop_invariant_phi:"), "loop invariant PHI with a backedge lowers successfully");
	assert(text.contains("jmp .Lloop_invariant_phi.header."), "loop backedge targets the PHI header");
}

fn void object_emits_quot_text_and_global_function_symbol() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	build_signed_division_fixture(&f);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::SectionData* text = elf_section(e, "text");
	char[8] prologue = { 0x55, 0x48, 0x89, 0xe5, 0x48, 0x83, 0xec, 0x40 };
	assert(text.bytes.len() >= prologue.len, "quot text contains the expected prologue");
	for (usz i = 0; i < prologue.len; i++)
	{
		assert(text.bytes[(sz)i] == prologue[i], "wrong quot text byte %d", i);
	}
	assert(e.globals.len() == 1, "quot is the only global symbol");
	elf::Symbol* quot = elf_symbol(e, "quot");
	assert(quot.defined && quot.section == text, "quot is defined in .text");
	assert(quot.info == 0x12, "quot is a global FUNC symbol");
	assert(quot.offset == 0, "quot starts at .text offset zero");
	assert(quot.size == (ulong)text.bytes.len(), "quot size matches .text bytes");
}

fn void object_rendering_honors_spill_all() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	build_signed_division_fixture(&f);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* register_obj = render_object(&f, &errors, &graph);
	defer { register_obj.deinit(); graph.free(); }
	object::Object* spill_obj = ir::render_object(&graph, &f.ta, object_target(), &errors, true)!!;
	defer spill_obj.deinit();
	elf::Elf* register_elf = (elf::Elf*)register_obj.implementation;
	elf::Elf* spill_elf = (elf::Elf*)spill_obj.implementation;
	elf::SectionData* register_text = elf_section(register_elf, "text");
	elf::SectionData* spill_text = elf_section(spill_elf, "text");
	assert(register_text.bytes.len() != spill_text.bytes.len(),
		"spill-all object lowering changes code for live values");
}

fn void object_emits_plt32_for_defined_and_undefined_calls() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref callee = f.builder.add_symbol("callee", value_interner::REF_FUNC);
	f.builder.add_call(callee, {}, value_interner::REF_I32);
	ir::Ref puts = f.builder.add_symbol("puts", value_interner::REF_FUNC);
	ir::Ref puts_call = f.builder.add_call(puts, {}, value_interner::REF_I32);
	f.builder.add_return(puts_call);
	f.builder.finish_fn("caller");
	f.builder.start_fn();
	ir::Ref one = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I32);
	f.builder.add_return(one);
	f.builder.finish_fn("callee");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::SectionData* text = elf_section(e, "text");
	assert(text.relocs.len() == 2, "caller has one relocation for each call site");
	bool saw_callee = false;
	bool saw_puts = false;
	foreach (relocation : text.relocs)
	{
		assert(relocation.kind == object::RelocKind.PLT32.value, "call relocation uses PLT32");
		assert(relocation.addend == -4, "call relocation addend is -4");
		assert(relocation.offset > 0 && relocation.offset <= (ulong)text.bytes.len(), "call relocation is within .text");
		assert(text.bytes[(sz)(relocation.offset - 1)] == 0xe8, "relocation points at a call displacement");
		if (relocation.symbol.name == "callee") saw_callee = true;
		if (relocation.symbol.name == "puts") saw_puts = true;
	}
	assert(saw_callee && saw_puts, "both call targets have PLT32 relocations");
	elf::Symbol* callee_symbol = elf_symbol(e, "callee");
	assert(callee_symbol.defined, "callee is defined");
	elf::Symbol* puts_symbol = elf_symbol(e, "puts");
	assert(!puts_symbol.defined && puts_symbol.section == null, "puts remains undefined");
}

fn void object_patches_loop_branches_inside_function() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref condition = f.builder.add_arg(value_interner::REF_I1);
	ir::Ref header = f.builder.make_label("header");
	ir::Ref body = f.builder.make_label("body");
	ir::Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(condition);
	f.builder.finish_fn("loop");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	foreach (section : e.sections) assert(section.relocs.len() == 0, "loop object has no relocations");
	elf::SectionData* text = elf_section(e, "text");
	elf::Symbol* loop = elf_symbol(e, "loop");
	assert(loop.defined && loop.section == text, "loop function symbol is defined in .text");
	char[] bytes = text.bytes.array_view();
	long function_start = (long)loop.offset;
	long function_end = function_start + (long)loop.size;
	uint branches = 0;
	for (usz i = 0; i < bytes.len;)
	{
		usz field;
		if (i + 6 <= bytes.len && bytes[(sz)i] == 0x0f &&
			(bytes[(sz)i + 1] == 0x84 || bytes[(sz)i + 1] == 0x85))
		{
			field = i + 2;
			i += 6;
		}
		else if (i + 5 <= bytes.len && bytes[(sz)i] == 0xe9)
		{
			field = i + 1;
			i += 5;
		}
		else
		{
			i++;
			continue;
		}
		long destination = (long)field + 4 + read_rel32(bytes, field);
		assert(destination >= function_start && destination < function_end,
			"local rel32 destination %d is within loop", destination);
		branches++;
	}
	assert(branches >= 3, "loop emits its local conditional and backward branches");
}

fn void object_emits_bytes_constant_and_pc32_relocation() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref callee = f.builder.add_symbol("consume_string", value_interner::REF_FUNC);
	value_interner::InternerRef value = f.interner.put({ .tag = primitive_value::PrimitiveType.BYTES,
		.bytes = "object" });
	ir::Ref bytes_ref = f.builder.add_constant(value, value_interner::REF_PTR);
	ir::Ref[1] args = { bytes_ref };
	ir::Ref call = f.builder.add_call(callee, args[..], value_interner::REF_I32);
	f.builder.add_return(call);
	f.builder.finish_fn("return_string");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::SectionData* rodata = elf_section(e, "rodata");
	assert(e.locals.len() == 1, "string constant creates one local symbol");
	elf::Symbol* string_symbol = elf_symbol(e, ".L.str.0");
	assert(string_symbol.defined && string_symbol.section == rodata && string_symbol.info == 1,
		"string constant is a local object in read-only data");
	assert(string_symbol.offset == 0 && string_symbol.size == 6, "string symbol covers the constant bytes");
	char[6] expected = { 'o', 'b', 'j', 'e', 'c', 't' };
	assert(rodata.bytes.len() == expected.len, "read-only string section contains six bytes");
	for (usz i = 0; i < expected.len; i++)
	{
		assert(rodata.bytes[(sz)i] == expected[i], "wrong string byte %d", i);
	}
	elf::SectionData* text = elf_section(e, "text");
	bool found_string_relocation = false;
	foreach (relocation : text.relocs)
	{
		if (relocation.symbol != string_symbol) continue;
		assert(relocation.kind == object::RelocKind.PC32.value && relocation.addend == -4,
			"string address uses a PC32 relocation with addend -4");
		found_string_relocation = true;
	}
	assert(found_string_relocation, "text has a PC32 relocation to the string constant");
	assert(string_symbol.name == ".L.str.0", "string constant uses its generated local label");
}

fn void object_zero_extends_initialized_global_before_relocation() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	char[8] initial = { 1, 2, 3, 4, 5, 6, 7, 8 };
	DataReloc[1] relocs = { { .offset = 8, .symbol = "external_target", .addend = 0 } };
	GlobalData global = {
		.size = 8,
		.align = 8,
		.bytes = initial[..],
		.relocs = relocs[..],
		.section = DataSection.DATA,
	};
	f.builder.add_global("padded_global", ir::Linkage.EXTERNAL, global);
	ir::Ir graph = f.builder.finish();
	defer graph.free();
	// Model an IR producer that supplies a partial initializer; the object
	// emitter must extend it before validating and applying its relocation.
	graph.decls[0].global.size = 16;

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	object::Object* obj = ir::render_object(&graph, &f.ta, object_target(), &errors)!!;
	defer { obj.deinit(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::SectionData* data = elf_section(e, "data");
	assert(data.bytes.len() == 16, "initialized global extends to its declared size");
	for (usz i = 0; i < initial.len; i++) assert(data.bytes[(sz)i] == initial[i], "initial global byte %d is preserved", i);
	for (usz i = initial.len; i < 16; i++) assert(data.bytes[(sz)i] == 0, "extended global byte %d is zero", i);
	assert(data.relocs.len() == 1 && data.relocs[0].offset == 8,
		"relocation in the zero-extended region is applied");
}

fn void object_emits_bss_as_aligned_nobits() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	GlobalData first = { .size = 5, .align = 4, .section = DataSection.BSS };
	GlobalData second = { .size = 9, .align = 16, .section = DataSection.BSS };
	f.builder.add_global("first_zero", ir::Linkage.EXTERNAL, first);
	f.builder.add_global("second_zero", ir::Linkage.EXTERNAL, second);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::SectionData* bss = elf_section(e, "bss");
	assert(bss.sh_type == elf::SHT_NOBITS && bss.nobits_size == 25 && bss.bytes.len() == 0,
		"BSS is a NOBITS section with logical size and no file payload");
	elf::Symbol* first_symbol = elf_symbol(e, "first_zero");
	elf::Symbol* second_symbol = elf_symbol(e, "second_zero");
	assert(first_symbol.defined && first_symbol.section == bss && first_symbol.offset == 0 && first_symbol.size == 5,
		"first BSS symbol has its reserved range");
	assert(second_symbol.defined && second_symbol.section == bss && second_symbol.offset == 16 && second_symbol.size == 9,
		"second BSS symbol respects its alignment");
	ObjectSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	char[] emitted = out.bytes.str_view();
	ulong text_index = elf_section_index(emitted, ".text");
	ulong data_index = elf_section_index(emitted, ".data");
	ulong rodata_index = elf_section_index(emitted, ".rodata");
	ulong bss_index = elf_section_index(emitted, ".bss");
	assert(text_index < data_index && data_index < rodata_index && rodata_index < bss_index,
		"BSS follows text, data, and read-only data");
	ulong headers = read_elf_le(emitted, 40, 8);
	ulong header_size = read_elf_le(emitted, 58, 2);
	ulong bss_header = headers + bss_index * header_size;
	assert(read_elf_le(emitted, (usz)(bss_header + 4), 4) == 8, "BSS section type is SHT_NOBITS");
	assert(read_elf_le(emitted, (usz)(bss_header + 32), 8) == 25, "BSS section size includes alignment padding");
	assert(read_elf_le(emitted, (usz)(bss_header + 48), 8) == 16, "BSS section preserves its maximum alignment");
}

fn void object_emits_common_as_shn_common() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	GlobalData common = { .size = 37, .align = 32, .section = DataSection.COMMON };
	f.builder.add_global("tentative_global", ir::Linkage.EXTERNAL, common);
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	ir::Ir graph = {};
	object::Object* obj = render_object(&f, &errors, &graph);
	defer { obj.deinit(); graph.free(); }
	elf::Elf* e = (elf::Elf*)obj.implementation;
	elf::Symbol* common_symbol = elf_symbol(e, "tentative_global");
	assert(common_symbol.common && common_symbol.offset == 32 && common_symbol.size == 37,
		"COMMON symbol records its alignment and size");
	ObjectSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	char[] emitted = out.bytes.str_view();
	ulong symbol = elf_symbol_entry(emitted, "tentative_global");
	assert(read_elf_le(emitted, (usz)(symbol + 6), 2) == 0xfff2, "COMMON symbol uses SHN_COMMON");
	assert(read_elf_le(emitted, (usz)(symbol + 8), 8) == 32, "COMMON symbol value stores its alignment");
	assert(read_elf_le(emitted, (usz)(symbol + 16), 8) == 37, "COMMON symbol preserves its size");
}

fn void floating_point_reports_lowering_todo() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref x = f.builder.add_arg(value_interner::REF_F64);
	f.builder.add_inst(RET, { .ref = x }, value_interner::REF_NORETURN);
	f.builder.finish_fn("half");
	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	// ErrorList borrows decl names (as in Zig), so inspect it before freeing the Ir.
	ir::Ir graph = f.builder.finish();
	defer graph.free();
	assert(@catch(x86_64::render_asm(&graph, &f.ta, &errors)) == ir::LOWER_FAIL);
	test::eq(errors.name_at(0), "half");
	test::eq(errors.message_at(0), "TODO: floating point lowering");
}

fn void external_and_defined_symbol_calls_use_correct_relocations() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }

	f.builder.start_fn();
	ir::Ref external = f.builder.add_symbol("external_fn", value_interner::REF_FUNC);
	ir::Ref external_call = f.builder.add_call(external, {}, value_interner::REF_I32);
	f.builder.add_return(external_call);
	f.builder.finish_fn("calls_external");

	f.builder.start_fn();
	ir::Ref defined = f.builder.add_symbol("defined_fn", value_interner::REF_FUNC);
	ir::Ref defined_call = f.builder.add_call(defined, {}, value_interner::REF_I32);
	f.builder.add_return(defined_call);
	f.builder.finish_fn("calls_defined");

	f.builder.start_fn();
	ir::Ref answer = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I32);
	f.builder.add_return(answer);
	f.builder.finish_fn("defined_fn");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors)!!;
	defer alloc::free(&f.ta, text.ptr);
	assert(text.contains("call external_fn@PLT"), "an unresolved SYMBOL call should use the PLT");
	assert(text.contains("call defined_fn\n"), "a defined SYMBOL call should be direct");
	assert(!text.contains("call defined_fn@PLT"), "a defined SYMBOL must not use the PLT");
}

fn void symbol_values_use_got_for_externals_and_lea_for_definitions() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }

	f.builder.start_fn();
	ir::Ref external = f.builder.add_symbol("abs", value_interner::REF_PTR);
	f.builder.add_return(external);
	f.builder.finish_fn("returns_abs");

	f.builder.start_fn();
	ir::Ref local = f.builder.add_symbol("local_name", value_interner::REF_PTR);
	f.builder.add_return(local);
	f.builder.finish_fn("returns_local_name");

	f.builder.start_fn();
	f.builder.add_return(ir::NONE);
	f.builder.finish_fn("local_name", ir::Linkage.INTERNAL);

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors)!!;
	defer alloc::free(&f.ta, text.ptr);
	test::eq(text,
		"\t.intel_syntax noprefix\n"
		"\t.text\n"
		"\t.globl returns_abs\n"
		"\t.p2align 4\n"
		"\t.type returns_abs, @function\n"
		"returns_abs:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		".Lreturns_abs.entry.0:\n"
		"\tmov rax, qword ptr [rip + abs@GOTPCREL]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size returns_abs, .-returns_abs\n\n"
		"\t.text\n"
		"\t.globl returns_local_name\n"
		"\t.p2align 4\n"
		"\t.type returns_local_name, @function\n"
		"returns_local_name:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		".Lreturns_local_name.entry.0:\n"
		"\tlea rax, [rip + local_name]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size returns_local_name, .-returns_local_name\n\n"
		"\t.text\n"
		"\t.local local_name\n"
		"\t.p2align 4\n"
		"\t.type local_name, @function\n"
		"local_name:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		".Llocal_name.entry.0:\n"
		"\tleave\n"
		"\tret\n"
		"\t.size local_name, .-local_name\n\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
}

fn void identical_string_constants_share_one_assembly_label() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref callee = f.builder.add_symbol("consume_strings", value_interner::REF_FUNC);
	value_interner::InternerRef bytes = f.interner.put({ .tag = primitive_value::PrimitiveType.BYTES,
		.bytes = "shared" });
	ir::Ref first = f.builder.add_constant(bytes, value_interner::REF_PTR);
	ir::Ref second = f.builder.add_constant(bytes, value_interner::REF_PTR);
	ir::Ref[2] args = { first, second };
	ir::Ref call = f.builder.add_call(callee, args[..], value_interner::REF_I32);
	f.builder.add_return(call);
	f.builder.finish_fn("pass_strings");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors, true)!!;
	defer alloc::free(&f.ta, text.ptr);
	test::eq(text,
		"\t.intel_syntax noprefix\n"
		"\t.text\n"
		"\t.globl pass_strings\n"
		"\t.p2align 4\n"
		"\t.type pass_strings, @function\n"
		"pass_strings:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		"\tsub rsp, 16\n"
		".Lpass_strings.entry.0:\n"
		"\tlea rdi, [rip + .L.str.0]\n"
		"\tlea rsi, [rip + .L.str.0]\n"
		"\txor eax, eax\n"
		"\tcall consume_strings@PLT\n"
		"\tmov dword ptr [rbp - 8], eax\n"
		"\tmov eax, dword ptr [rbp - 8]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size pass_strings, .-pass_strings\n\n"
		"\t.section .rodata\n"
		".L.str.0:\n"
		"\t.byte 115, 104, 97, 114, 101, 100\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
}

fn void select_lowers_to_conditional_assembly() @test
{
	Fixture f;
	f.init();
	defer { f.builder.free(); f.interner.free(); f.ta.free(); }
	f.builder.start_fn();
	ir::Ref cond = f.builder.add_arg(value_interner::REF_I1);
	ir::Ref yes = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I32);
	value_interner::InternerRef no_value = f.interner.put(primitive_value::int_key(29));
	ir::Ref no = f.builder.add_constant(no_value, value_interner::REF_I32);
	ir::Ref selected = f.builder.add_select(cond, yes, no, value_interner::REF_I32);
	f.builder.add_return(selected);
	f.builder.finish_fn("choose_with_select");

	ir::ErrorList errors;
	errors.init(&f.ta);
	defer errors.free();
	String text = render(&f, &errors, true)!!;
	defer alloc::free(&f.ta, text.ptr);
	test::eq(text,
		"\t.intel_syntax noprefix\n"
		"\t.text\n"
		"\t.globl choose_with_select\n"
		"\t.p2align 4\n"
		"\t.type choose_with_select, @function\n"
		"choose_with_select:\n"
		"\tpush rbp\n"
		"\tmov rbp, rsp\n"
		"\tsub rsp, 16\n"
		"\tmov byte ptr [rbp - 8], dil\n"
		".Lchoose_with_select.entry.0:\n"
		"\tmov al, byte ptr [rbp - 8]\n"
		"\ttest al, al\n"
		"\tje .Lchoose_with_select.edge.0\n"
		"\tmov eax, 1\n"
		"\tmov dword ptr [rbp - 16], eax\n"
		"\tjmp .Lchoose_with_select.edge.1\n"
		".Lchoose_with_select.edge.0:\n"
		"\tmov eax, 29\n"
		"\tmov dword ptr [rbp - 16], eax\n"
		".Lchoose_with_select.edge.1:\n"
		"\tmov eax, dword ptr [rbp - 16]\n"
		"\tleave\n"
		"\tret\n"
		"\t.size choose_with_select, .-choose_with_select\n\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
}
