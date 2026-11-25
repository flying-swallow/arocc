// Tests for the target.c port (src/frontend/c3/target.c3): `--target` name
// parsing and the PlatformTarget values target_setup computes, plus a few
// builtin-type classifications of the non-x64 C ABIs it selects.
// Expectations follow c3c 54bab366a built without LLVM (the values were
// cross-checked against it through $$OS_TYPE / $$C_LONG_SIZE / $feat(...)).
module c3_target_tests;
import aro::frontend::c3::compiler;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn void setup(String name)
{
	ArchOsTarget t = compiler::arch_os_target_from_string(name);
	assert(t != compiler::ARCH_OS_TARGET_DEFAULT, "unknown target %s", name);
	compiler::compiler_reset(t);
}

module c3_target_tests @test;
import aro::frontend::c3::compiler;

fn void target_names_round_trip()
{
	for (int i = 0; i <= compiler::ARCH_OS_TARGET_LAST.ordinal; i++)
	{
		String name = compiler::arch_os_target[i];
		check(compiler::arch_os_target_from_string(name).ordinal, i);
	}
	check(compiler::arch_os_target_from_string("macos-x64"), ArchOsTarget.MACOS_X64);
	check(compiler::arch_os_target_from_string("emscripten"), ArchOsTarget.EMSCRIPTEN_WASM32);
	check(compiler::arch_os_target_from_string("linux-x86_64"), compiler::ARCH_OS_TARGET_DEFAULT);
	check(compiler::arch_os_target_from_string(""), compiler::ARCH_OS_TARGET_DEFAULT);
}

fn void default_is_linux_x64()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(compiler::compiler.build.arch_os_target, ArchOsTarget.LINUX_X64);
	check(p.target_triple, "x86_64-pc-linux-gnu");
	check(p.arch, ArchType.X86_64);
	check(p.os, OsType.LINUX);
	check(p.vendor, VendorType.PC);
	check(p.environment_type, EnvironmentType.GNU);
	check(p.object_format, ObjectFormatType.ELF);
	check(p.abi, Abi.X64);
	check(p.width_pointer, 64);
	check(p.width_c_long, 64);
	assert(p.signed_c_char);
	assert(p.tls_supported);
	assert(!p.big_endian);
	// x86_64 has no native int128 / f16 / f128 support in c3c's tables.
	assert(!p.int128_supported && !p.float16_supported && !p.float128_supported);
	// Native host target without LLVM: baseline cpu (SSE only).
	check(p.cpu, "x86-64");
	check(p.x64.native_vector_size_avx, 16);
	assert(p.x64.pass_int128_vector_in_mem);
	check(p.reloc_model, compiler::RELOC_BIG_PIE);
	check(compiler::type_usz.canonical, compiler::type_ulong);
	check(compiler::libc_from_arch_os(ArchOsTarget.LINUX_X64), compiler::LINK_LIBC_ON);
}

fn void macos_x64()
{
	setup("macos-x64");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.os, OsType.MACOSX);
	check(p.vendor, VendorType.APPLE);
	check(p.object_format, ObjectFormatType.MACHO);
	check(p.abi, Abi.X64);
	// Cross target: AVX1 cpu set (x86-64-v2), 32-byte native vectors.
	check(p.cpu, "x86-64-v2");
	check(p.x64.native_vector_size_avx, 32);
	assert(!p.x64.pass_int128_vector_in_mem);
	// The feature string is the diff against the cpu set's own defaults.
	check(p.features, "+avx,+pclmul,+xsave");
	check(compiler::jump_buffer_size(), 19);
}

fn void windows_x64()
{
	setup("windows-x64");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.os, OsType.WIN32);
	check(p.environment_type, EnvironmentType.MSVC);
	check(p.object_format, ObjectFormatType.COFF);
	check(p.abi, Abi.WIN64);
	assert(p.x64.is_win64);
	check(p.width_c_long, 32);
	check(p.dylib_suffix, ".dll");
	assert(p.pic_required);
	// win64: i128 arguments go indirect, bool is extended.
	Regs regs = { 4, 4 };
	assert(compiler::win64_classify(&regs, { .type = compiler::type_i128 }, false, false).kind == ARG_INDIRECT);
	assert(compiler::win64_classify(&regs, { .type = compiler::type_bool }, false, false).kind == ARG_DIRECT);
}

fn void macos_aarch64()
{
	setup("macos-aarch64");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.arch, ArchType.AARCH64);
	check(p.abi, Abi.AARCH64);
	assert(p.aarch64.is_darwin_pcs && !p.aarch64.is_aapcs);
	assert(p.signed_c_char);
	assert(p.int128_supported && p.float16_supported && !p.float128_supported);
	assert(p.vec64i && p.vec128f);
	check(p.align_max_vector, 16);
	check(p.integers[BitSizes.BITS8.ordinal].align, 8);
	check(p.integers[BitSizes.BITS8.ordinal].pref_align, 32);
	check(p.features, "+crc,+lse,+rdm,+fp-armv8,+neon");
	assert(compiler::aarch64_classify_argument_type({ .type = compiler::type_long }).kind == ARG_DIRECT);
	assert(compiler::aarch64_classify_argument_type({ .type = compiler::type_void }).kind == ARG_IGNORE);
}

fn void linux_aarch64_unsigned_char()
{
	setup("linux-aarch64");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	assert(!p.signed_c_char);
	assert(p.aarch64.is_aapcs && !p.aarch64.is_darwin_pcs);
	check(compiler::jump_buffer_size(), 39);
}

fn void riscv()
{
	setup("linux-riscv32");
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.abi, Abi.RISCV);
	check(p.width_pointer, 32);
	check(p.width_c_long, 32);
	check(p.riscv.xlen, 4);
	// rv32 defaults to RVI with the integer-only ABI.
	check(p.riscv.flen, 0);
	assert(!p.signed_c_char);
	assert(p.float128_supported && !p.int128_supported);
	check(compiler::type_usz.canonical, compiler::type_uint);
	compiler::compiler_free();

	setup("linux-riscv64");
	defer compiler::compiler_free();
	p = &compiler::compiler.platform;
	check(p.riscv.xlen, 8);
	// rv64 defaults to RVGC with the double ABI.
	check(p.riscv.flen, 8);
	assert(p.int128_supported);
	check(p.features, "+64bit,+a,+c,+d,+f,+i,+m,+zba,+zbb,+zbs,+zicsr,+zifencei");
}

fn void wasm32()
{
	setup("wasm32");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.os, OsType.UNKNOWN);
	check(p.object_format, ObjectFormatType.WASM);
	check(p.abi, Abi.WASM);
	check(p.width_pointer, 32);
	assert(p.int128_supported);
	check(compiler::libc_from_arch_os(ArchOsTarget.WASM32), compiler::LINK_LIBC_OFF);
	compiler::build_target_setup_defaults();
	check(compiler::compiler.build.link_libc, compiler::LINK_LIBC_OFF);
	assert(compiler::wasm_classify_argument_type({ .type = compiler::type_int }).kind == ARG_DIRECT);
}

fn void linux_x86()
{
	setup("linux-x86");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.arch, ArchType.X86);
	check(p.abi, Abi.X86);
	check(p.width_pointer, 32);
	assert(!p.x86.return_small_struct_in_reg_abi);
	// i386 SysV: 64-bit ints are 4-byte aligned (8 preferred), doubles too.
	check(p.integers[BitSizes.BITS64.ordinal].align, 32);
	check(p.integers[BitSizes.BITS64.ordinal].pref_align, 64);
	check(p.floats[BitSizes.BITS64.ordinal].align, 32);
	check(compiler::type_abi_alignment(compiler::type_long), 4);
}

fn void elf_x64_freestanding()
{
	setup("elf-x64");
	defer compiler::compiler_free();
	PlatformTarget* p = &compiler::compiler.platform;
	check(p.os, OsType.NONE);
	assert(p.noredzone);
	check(p.reloc_model, compiler::RELOC_NONE);
	check(compiler::libc_from_arch_os(ArchOsTarget.ELF_X64), compiler::LINK_LIBC_OFF);
}
