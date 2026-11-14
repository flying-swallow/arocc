// Direct coverage for the in-process x86-64 ELF executable linker. The input
// objects are assembled by hand so these tests isolate linking from IR lowering.
module elf_link_tests;
import aro, aro::backend::object, aro::backend::elf_link, aro::host_process, aro::target;
import std::collections::list;
import std::core::mem, std::core::mem::allocators, std::core::string;
import std::io::file, std::io::path;
import std::os::env, std::os::posix;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const target::Host HOST = { X86_64, LINUX, GNU };
const ulong IMAGE_BASE = 0x400000;
const ulong PAGE_SIZE = 0x1000;
const uint PT_LOAD = 1;
const uint PT_GNU_STACK = 0x6474E551;

fn target::Target elf_target()
{
	target::Target? parsed = target::parse_triple("x86_64-linux-gnu", HOST);
	if (catch err = parsed) unreachable("test target must parse");
	return parsed;
}

fn target::Target big_endian_elf_target()
{
	target::Target? parsed = target::parse_triple("aarch64_be-linux-gnu", HOST);
	if (catch err = parsed) unreachable("big-endian test target must parse");
	return parsed;
}

fn char byte_at(String bytes, ulong at)
{
	assert(at < bytes.len, "ELF read outside file");
	return bytes[(sz)at];
}

fn ushort read_u16(String bytes, ulong at)
{
	return (ushort)byte_at(bytes, at) | ((ushort)byte_at(bytes, at + 1) << 8);
}

fn uint read_u32(String bytes, ulong at)
{
	uint value = 0;
	for (uint i = 0; i < 4; i++) value |= (uint)byte_at(bytes, at + i) << (i * 8);
	return value;
}

fn ulong read_u64(String bytes, ulong at)
{
	ulong value = 0;
	for (uint i = 0; i < 8; i++) value |= (ulong)byte_at(bytes, at + i) << (i * 8);
	return value;
}

struct ProgramHeader
{
	uint type;
	uint flags;
	ulong offset;
	ulong vaddr;
	ulong paddr;
	ulong filesz;
	ulong memsz;
	ulong align;
}

struct LinkedImage
{
	String bytes;
	ulong entry;
	ulong phoff;
	ushort phentsize;
	ushort phnum;
}

fn LinkedImage inspect_image(String bytes, ushort expected_loads)
{
	assert(bytes.len >= 64, "ELF header is complete");
	check(byte_at(bytes, 0), 0x7f);
	check(byte_at(bytes, 1), 'E'); check(byte_at(bytes, 2), 'L'); check(byte_at(bytes, 3), 'F');
	check(byte_at(bytes, 4), 2); // ELFCLASS64
	check(byte_at(bytes, 5), 1); // little endian
	check(byte_at(bytes, 6), 1); // current ELF version
	check(read_u16(bytes, 16), 2); // ET_EXEC
	check(read_u16(bytes, 18), 62); // EM_X86_64
	check(read_u32(bytes, 20), 1);
	check(read_u64(bytes, 32), 64); // program headers immediately follow the ELF header
	check(read_u64(bytes, 40), 0); // no section headers
	check(read_u32(bytes, 48), 0); // e_flags
	check(read_u16(bytes, 52), 64);
	check(read_u16(bytes, 54), 56);
	check(read_u16(bytes, 58), 64);
	check(read_u16(bytes, 60), 0);
	check(read_u16(bytes, 62), 0);
	LinkedImage image = {
		.bytes = bytes,
		.entry = read_u64(bytes, 24),
		.phoff = read_u64(bytes, 32),
		.phentsize = read_u16(bytes, 54),
		.phnum = read_u16(bytes, 56),
	};
	check(image.phoff, 64);
	check(image.phentsize, 56);
	check(image.phnum, expected_loads + 1); // PT_LOAD entries plus non-executable GNU_STACK
	assert(image.phoff + (ulong)image.phentsize * image.phnum <= bytes.len,
		"program headers fit in the executable");

	ushort load_count = 0;
	bool stack_found = false;
	bool entry_in_rx = false;
	for (ushort i = 0; i < image.phnum; i++)
	{
		ProgramHeader ph = program_header(&image, i);
		if (ph.type == PT_GNU_STACK)
		{
			stack_found = true;
			check(ph.flags, 6); // readable + writable, never executable
			check(ph.offset, 0); check(ph.vaddr, 0); check(ph.paddr, 0);
			check(ph.filesz, 0); check(ph.memsz, 0); check(ph.align, 0);
			continue;
		}
		if (ph.type != PT_LOAD) unreachable("only PT_LOAD and PT_GNU_STACK are emitted");
		load_count++;
		check(ph.align, PAGE_SIZE);
		check(ph.paddr, ph.vaddr);
		check(ph.offset % PAGE_SIZE, ph.vaddr % PAGE_SIZE);
		assert(ph.memsz >= ph.filesz, "load segment memory size covers file contents");
		assert(ph.offset + ph.filesz <= bytes.len, "load segment contents fit in the file");
		if (ph.flags == 5 && image.entry >= ph.vaddr && image.entry < ph.vaddr + ph.memsz)
		{
			entry_in_rx = true;
		}
		else if (ph.flags != 4 && ph.flags != 6)
		{
			unreachable("load segment has expected RX, R, or RW permissions");
		}
		for (ushort j = 0; j < i; j++)
		{
			ProgramHeader other = program_header(&image, j);
			if (other.type != PT_LOAD) continue;
			assert(ph.vaddr + ph.memsz <= other.vaddr || other.vaddr + other.memsz <= ph.vaddr,
				"load segment memory ranges do not overlap");
			assert(ph.offset + ph.filesz <= other.offset || other.offset + other.filesz <= ph.offset,
				"load segment file ranges do not overlap");
		}
	}
	check(load_count, expected_loads);
	assert(stack_found, "a non-executable GNU stack header is present");
	assert(entry_in_rx, "entry point lies inside an executable load segment");
	assert(image.entry >= IMAGE_BASE, "entry point follows the mapped image base");
	return image;
}

fn ProgramHeader program_header(LinkedImage* image, ushort index)
{
	assert(index < image.phnum, "program header index is in range");
	ulong at = image.phoff + (ulong)index * image.phentsize;
	return {
		.type = read_u32(image.bytes, at),
		.flags = read_u32(image.bytes, at + 4),
		.offset = read_u64(image.bytes, at + 8),
		.vaddr = read_u64(image.bytes, at + 16),
		.paddr = read_u64(image.bytes, at + 24),
		.filesz = read_u64(image.bytes, at + 32),
		.memsz = read_u64(image.bytes, at + 40),
		.align = read_u64(image.bytes, at + 48),
	};
}

fn ProgramHeader find_load(LinkedImage* image, uint flags)
{
	for (ushort i = 0; i < image.phnum; i++)
	{
		ProgramHeader ph = program_header(image, i);
		if (ph.type == PT_LOAD && ph.flags == flags) return ph;
	}
	unreachable("expected load segment not found");
}

fn ulong align_up(ulong value, ulong alignment)
{
	return (value + alignment - 1) & ~(alignment - 1);
}

fn void emit_exit(object::Object* obj, char code)
{
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0xBF); text.push(code); text.push(0); text.push(0); text.push(0); // mov edi, imm32
	text.push(0xB8); text.push(0x3C); text.push(0); text.push(0); text.push(0); // mov eax, 60
	text.push(0x0F); text.push(0x05); // syscall
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 12);
}

fn void emit_pc32_load(object::Object* obj, object::Section data_section, String name, char exit_if_loaded)
{
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0x0F); text.push(0xB6); text.push(0x3D); // movzx edi, byte [rip + disp32]
	text.push(0); text.push(0); text.push(0); text.push(0);
	text.push(0xB8); text.push(0x3C); text.push(0); text.push(0); text.push(0);
	text.push(0x0F); text.push(0x05);
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 14);
	List{char}* data = object::get_section(obj, data_section);
	data.push(exit_if_loaded);
	object::declare_symbol(obj, data_section, name, true, object::Linkage.STRONG,
		object::SymbolType.VARIABLE, 0, 1);
	object::add_relocation(obj, name, object::SECTION_FUNC, 3, -4);
}

fn void emit_gotpcrelx_load(object::Object* obj, String name, object::RelocKind kind)
{
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0x48); text.push(0x8B); text.push(0x05); // mov rax, [rip + disp32]
	text.push(0); text.push(0); text.push(0); text.push(0);
	text.push(0xC3); // ret
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 8);
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	data.push(0x2A);
	object::declare_symbol(obj, object::SECTION_DATA, name, true, object::Linkage.STRONG,
		object::SymbolType.VARIABLE, 0, 1);
	object::add_relocation(obj, name, object::SECTION_FUNC, 3, -4, kind);
}

fn bool runnable_host()
{
	target::Host? host_opt = target::host();
	if (catch host_opt) return false;
	target::Host host = host_opt;
	return host.arch == X86_64 && host.os == LINUX;
}

fn void expect_exit(object::Object* obj, String test_name, int expected) @feat(POSIX)
{
	if (!runnable_host()) return;
	char[] image = elf_link::link_executable(mem, obj)!!;
	defer alloc::free(mem, image.ptr);
	String root = env::get_var(tmem, "TEST_TMPDIR") ?? (String)path::temp_directory(tmem)!!;
	String executable = string::tformat("%s/aro-elf-link-%d-%s", root, posix::getpid(), test_name);
	file::save(executable, image)!!;
	defer (void)file::delete(executable);
	assert(chmod(executable.zstr_tcopy(), 0o755) == 0, "linked executable is marked runnable");
	ProcessResult result = host_process::run(null, mem, { executable });
	defer
	{
		if (result.stdout.ptr) alloc::free(mem, result.stdout.ptr);
		if (result.stderr.ptr) alloc::free(mem, result.stderr.ptr);
	}
	assert(result.started, "linked executable starts");
	assert(result.exited, "linked executable exits normally");
	test::eq(result.exit_code, expected);
}

extern fn CInt chmod(ZString path, uint mode) @feat(POSIX);

fn void structural_layout_and_pc32_patch() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_pc32_load(obj, object::SECTION_DATA, "value", 7);
	// An unreferenced read-only section verifies that the linker emits a distinct R segment.
	object::get_section(obj, object::SECTION_READ_ONLY_DATA).push(0x5A);

	char[] bytes = elf_link::link_executable(mem, obj)!!;
	defer alloc::free(mem, bytes.ptr);
	LinkedImage image = inspect_image((String)bytes, 3);
	ProgramHeader rx = find_load(&image, 5);
	ProgramHeader ro = find_load(&image, 4);
	ProgramHeader rw = find_load(&image, 6);
	check(rx.offset, 0); check(rx.vaddr, IMAGE_BASE);
	check(ro.offset % PAGE_SIZE, ro.vaddr % PAGE_SIZE);
	check(rw.offset % PAGE_SIZE, rw.vaddr % PAGE_SIZE);
	ulong text_offset = align_up(64 + (ulong)image.phnum * image.phentsize, 16);
	assert(text_offset + 14 <= rx.filesz, "text instructions are in the RX segment");
	long patched = (long)(int)read_u32(image.bytes, text_offset + 3);
	long expected = (long)(rw.vaddr - (rx.vaddr + text_offset + 3) - 4);
	check(patched, expected);
	check((long)(rx.vaddr + text_offset + 7) + patched, rw.vaddr);
}

fn void structural_abs64_pointer_to_entry() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_exit(obj, 0);
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	for (uint i = 0; i < 8; i++) data.push(0);
	object::declare_symbol(obj, object::SECTION_DATA, "start_pointer", true,
		object::Linkage.STRONG, object::SymbolType.VARIABLE, 0, 8);
	object::add_relocation(obj, "_start", object::SECTION_DATA, 0, 0, object::RelocKind.ABS64);

	char[] bytes = elf_link::link_executable(mem, obj)!!;
	defer alloc::free(mem, bytes.ptr);
	LinkedImage image = inspect_image((String)bytes, 2);
	ProgramHeader rw = find_load(&image, 6);
	check(read_u64(image.bytes, rw.offset), image.entry);
}

fn void expect_gotpcrelx_relaxes_mov_to_lea(object::RelocKind kind)
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_gotpcrelx_load(obj, "got_value", kind);

	char[] bytes = elf_link::link_executable(mem, obj)!!;
	defer alloc::free(mem, bytes.ptr);
	LinkedImage image = inspect_image((String)bytes, 2);
	ProgramHeader rx = find_load(&image, 5);
	ProgramHeader rw = find_load(&image, 6);
	ulong text_offset = align_up(64 + (ulong)image.phnum * image.phentsize, 16);
	check(byte_at(image.bytes, text_offset + 1), (char)0x8D);
	long patched = (long)(int)read_u32(image.bytes, text_offset + 3);
	long expected = (long)(rw.vaddr - (rx.vaddr + text_offset + 3) - 4);
	check(patched, expected);
}

fn void structural_gotpcrelx_relaxes_mov_to_lea() @test
{
	// Exercise both GOTPCRELX encodings, including the emitter's REX variant.
	expect_gotpcrelx_relaxes_mov_to_lea(object::RelocKind.GOTPCRELX);
	expect_gotpcrelx_relaxes_mov_to_lea(object::RelocKind.REX_GOTPCRELX);
}

fn void missing_entry_is_reported() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	object::get_section(obj, object::SECTION_FUNC).push(0xC3);
	object::declare_symbol(obj, object::SECTION_FUNC, "not_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 1);
	char[]? linked = elf_link::link_executable(mem, obj);
	assert(@catch(linked) == elf_link::MISSING_ENTRY);
}

fn void undefined_strong_symbol_reports_name() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0xE8); text.push(0); text.push(0); text.push(0); text.push(0);
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 5);
	object::declare_symbol(obj, object::SECTION_UNDEFINED, "missing_external", true,
		object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	object::add_relocation(obj, "missing_external", object::SECTION_FUNC, 1, -4);
	String failed_name = "";
	char[]? linked = elf_link::link_executable(mem, obj, { .failed_name = &failed_name });
	assert(@catch(linked) == elf_link::UNDEFINED_SYMBOL);
	test::eq(failed_name, "missing_external");
}

fn void undefined_gotpcrelx_symbol_reports_name() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0x48); text.push(0x8B); text.push(0x05);
	text.push(0); text.push(0); text.push(0); text.push(0);
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 7);
	object::declare_symbol(obj, object::SECTION_UNDEFINED, "missing_data", true,
		object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	object::add_relocation(obj, "missing_data", object::SECTION_FUNC, 3, -4,
		object::RelocKind.REX_GOTPCRELX);
	String failed_name = "";
	char[]? linked = elf_link::link_executable(mem, obj, { .failed_name = &failed_name });
	assert(@catch(linked) == elf_link::UNDEFINED_SYMBOL);
	test::eq(failed_name, "missing_data");
}

fn void big_endian_target_is_rejected() @test
{
	object::Object* obj = object::create(mem, big_endian_elf_target())!!;
	defer obj.deinit();
	char[]? linked = elf_link::link_executable(mem, obj);
	assert(@catch(linked) == elf_link::UNSUPPORTED_TARGET);
}

fn void run_exit_42() @test @feat(POSIX)
{
	if (!runnable_host()) return;
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_exit(obj, 42);
	expect_exit(obj, "exit42", 42);
}

fn void run_pc32_data_load() @test @feat(POSIX)
{
	if (!runnable_host()) return;
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_pc32_load(obj, object::SECTION_DATA, "value", 7);
	expect_exit(obj, "pc32-data", 7);
}

fn void run_plt32_helper_redeclaration() @test @feat(POSIX)
{
	if (!runnable_host()) return;
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0xE8); text.push(0); text.push(0); text.push(0); text.push(0); // call helper (PLT32)
	object::declare_symbol(obj, object::SECTION_FUNC, "_start", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, 0, 5);
	object::declare_symbol(obj, object::SECTION_UNDEFINED, "helper", true,
		object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	object::add_relocation(obj, "helper", object::SECTION_FUNC, 1, -4);
	ulong helper_offset = (ulong)text.len();
	text.push(0xBF); text.push(9); text.push(0); text.push(0); text.push(0); // mov edi, 9
	text.push(0xB8); text.push(0x3C); text.push(0); text.push(0); text.push(0); // mov eax, 60
	text.push(0x0F); text.push(0x05); // syscall
	object::declare_symbol(obj, object::SECTION_FUNC, "helper", true,
		object::Linkage.STRONG, object::SymbolType.FUNC, helper_offset, 12);
	expect_exit(obj, "plt32-helper", 9);
}

fn void run_rodata_load() @test @feat(POSIX)
{
	if (!runnable_host()) return;
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	emit_pc32_load(obj, object::SECTION_READ_ONLY_DATA, "ro_value", 13);
	expect_exit(obj, "rodata", 13);
}
