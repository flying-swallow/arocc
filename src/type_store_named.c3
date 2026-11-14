// Port of TypeStore.initNamedTypes, generateNsConstantStringType and
// generateVaListType from src/aro/TypeStore.zig, driven by the explicit C3
// target data in aro::target.
//
// Zig lays out the builtin records with `record_layout.compute`, which is
// ported later. Every builtin record here consists of plain (non-bitfield,
// unpacked, unattributed) scalar fields, for which both the SysV and the MSVC
// algorithms of record_layout.zig reduce to natural layout: each field at the
// next offset aligned to its type's alignment, record alignment the maximum
// field alignment (at least one byte), size rounded up to it, required
// alignment 8 bits. `natural_record_layout` computes exactly that.
module aro::type_store;
import aro::compilation, aro::lang_opts, aro::target, aro::string_interner;

<*
 Natural layout of plain scalar fields (see the module comment); fills each
 field's `layout`.
 @require fields.len > 0
*>
fn RecordLayout natural_record_layout(Compilation* comp, RecordField[] fields, bool is_union = false)
{
	ulong size_bits = 0;
	uint align_bits = 8;
	foreach (&field : fields)
	{
		assert(field.bit_width == BIT_WIDTH_NULL, "bitfields need record_layout.compute");
		ulong fsize = field.qt.sizeof(comp) * 8;
		uint falign = field.qt.alignof(comp) * 8;
		ulong offset = is_union ? 0 : align_forward(size_bits, falign);
		size_bits = max(size_bits, offset + fsize);
		align_bits = max(align_bits, falign);
		field.layout = { .offset_bits = offset, .size_bits = fsize };
	}
	size_bits = align_forward(size_bits, align_bits);
	return { .size_bits = size_bits, .field_alignment_bits = align_bits, .pointer_alignment_bits = align_bits, .required_alignment_bits = 8 };
}

fn QualType put_builtin_struct(Compilation* comp, String name, RecordField[] fields) @local
{
	RecordLayout layout = natural_record_layout(comp, fields);
	return comp.type_store.put(type_record(comp.intern_string(name), fields, layout));
}

fn RecordField field(Compilation* comp, String name, QualType qt) @local => record_field(comp.intern_string(name), qt);

fn QualType int_kind_qt(CIntKind k)
{
	switch (k)
	{
		case SCHAR: return SCHAR;
		case UCHAR: return UCHAR;
		case SHORT: return SHORT;
		case USHORT: return USHORT;
		case INT: return INT;
		case UINT: return UINT;
		case LONG: return LONG;
		case ULONG: return ULONG;
		case LONG_LONG: return LONG_LONG;
		case ULONG_LONG: return ULONG_LONG;
	}
}

<* TypeStore.initNamedTypes: wchar_t, wint_t, ptrdiff_t, size_t, pid_t, intmax_t, ..., va_list. *>
fn void init_named_types(Compilation* comp)
{
	TypeStore* ts = &comp.type_store;
	Target* t = &comp.target;
	OsTag os = t.os.tag;
	Arch arch = t.cpu.arch;

	switch (os)
	{
		case OPENBSD:
		case NETBSD: ts.wchar = INT;
		case PS4:
		case PS5:
		case UEFI:
		case WINDOWS: ts.wchar = USHORT;
		case DRIVERKIT:
		case IOS:
		case MACCATALYST:
		case MACOS:
		case TVOS:
		case VISIONOS:
		case WATCHOS: ts.wchar = INT;
		default:
			switch (arch)
			{
				case AARCH64:
				case AARCH64_BE:
				case ARM:
				case ARMEB:
				case THUMB:
				case THUMBEB:
				case VE:
				case MSP430: ts.wchar = UINT;
				case X86_64:
				case X86: ts.wchar = INT;
				case XCORE: ts.wchar = UCHAR;
				default: ts.wchar = INT;
			}
	}

	switch (os)
	{
		case FUCHSIA:
		case LINUX: ts.wint = UINT;
		case OPENBSD: ts.wint = INT;
		case UEFI:
		case WINDOWS: ts.wint = USHORT;
		case SERENITY: ts.wint = UINT;
		default:
			switch (arch)
			{
				case AVR: ts.wint = INT;
				case CSKY:
				case LOONGARCH32:
				case LOONGARCH64:
				case RISCV32:
				case RISCV32BE:
				case RISCV64:
				case RISCV64BE:
				case VE:
				case XCORE:
				case XTENSA:
				case XTENSAEB: ts.wint = UINT;
				default: ts.wint = INT;
			}
	}

	bool darwin_macho_bsd = os.is_darwin() || t.ofmt == MACHO || os == OPENBSD || os == NETBSD;
	ushort ptr_width = t.ptr_bit_width();

	// ptrdiff_t and size_t follow the same per-arch table; size_t is the unsigned form.
	QualType ptrdiff;
	if (os == HAIKU)
	{
		ptrdiff = LONG;
	}
	else
	{
		switch (arch)
		{
			case AARCH64:
			case AARCH64_BE: ptrdiff = os == WINDOWS ? LONG_LONG : LONG;
			case AMDGCN: ptrdiff = LONG;
			case ARC: ptrdiff = INT;
			case ARM:
			case ARMEB:
			case THUMB:
			case THUMBEB: ptrdiff = darwin_macho_bsd ? LONG : INT;
			case AVR: ptrdiff = INT;
			case BPFEB:
			case BPFEL: ptrdiff = LONG;
			case CSKY:
			case HEXAGON:
			case LOONGARCH32: ptrdiff = INT;
			case LOONGARCH64: ptrdiff = LONG;
			case M68K: ptrdiff = INT;
			case MIPS:
			case MIPSEL:
			case MIPS64:
			case MIPS64EL: ptrdiff = t.mips_abi() == N64 ? LONG : INT;
			case MSP430:
			case NVPTX: ptrdiff = INT;
			case NVPTX64: ptrdiff = LONG;
			case POWERPC:
			case POWERPCLE:
			case RISCV32: ptrdiff = INT;
			case SPARC: ptrdiff = os == NETBSD || os == OPENBSD ? LONG : INT;
			case SPIRV32: ptrdiff = INT;
			case SPIRV64:
			case VE:
			case WASM32:
			case WASM64: ptrdiff = LONG;
			case X86:
				ptrdiff = os == OPENBSD || os.is_darwin() || os == RTEMS ? LONG : INT;
			case X86_64:
				if (os == UEFI || os == WINDOWS)
				{
					ptrdiff = LONG_LONG;
				}
				else
				{
					ptrdiff = ptr_width == 32 ? INT : LONG;
				}
			case XCORE:
			case XTENSA:
			case XTENSAEB: ptrdiff = INT;
			default:
				switch (ptr_width)
				{
					case 16:
					case 32: ptrdiff = INT;
					case 64: ptrdiff = LONG;
					default: unreachable("unexpected pointer width");
				}
		}
	}
	ts.ptrdiff = ptrdiff;
	ts.size = ptrdiff.make_int_unsigned(comp);

	ts.pid_t = os == HAIKU ? LONG : INT;

	ts.intmax = int_kind_qt(t.int_max_type());
	ts.intptr = int_kind_qt(t.int_ptr_type());
	ts.int16 = int_kind_qt(t.int16_type());
	ts.int64 = int_kind_qt(t.int64_type());
	ts.uint_least16_t = int_least_n(comp, 16, UNSIGNED);
	ts.uint_least32_t = int_least_n(comp, 32, UNSIGNED);

	ts.ns_constant_string = generate_ns_constant_string_type(comp);
	ts.va_list = generate_va_list_type(comp);
}

fn QualType generate_ns_constant_string_type(Compilation* comp)
{
	QualType const_int_ptr = { .is_const = true, .index = IDX_INT_POINTER };
	QualType const_char_ptr = { .is_const = true, .index = IDX_CHAR_POINTER };
	RecordField[4] fields = {
		field(comp, "isa", const_int_ptr),
		field(comp, "flags", INT),
		field(comp, "str", const_char_ptr),
		field(comp, "length", LONG),
	};
	return put_builtin_struct(comp, "__NSConstantString_tag", &fields);
}

enum VaListKind : char @local
{
	AARCH64_VA_LIST,
	ARM_VA_LIST,
	HEXAGON_VA_LIST,
	POWERPC_VA_LIST,
	S390X_VA_LIST,
	X86_64_VA_LIST,
	XTENSA_VA_LIST,
}

<* TypeStore.generateVaListType: the target's `__builtin_va_list`. *>
fn QualType generate_va_list_type(Compilation* comp)
{
	Target* t = &comp.target;
	VaListKind kind;
	switch (t.cpu.arch)
	{
		case AMDGCN:
		case MSP430:
		case NVPTX:
		case NVPTX64:
		case POWERPC64:
		case POWERPC64LE:
		case X86:
			return CHAR_POINTER;
		case ARC:
		case AVR:
		case BPFEL:
		case BPFEB:
		case CSKY:
		case LANAI:
		case LOONGARCH32:
		case LOONGARCH64:
		case M68K:
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL:
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE:
		case SPARC:
		case SPARC64:
		case SPIRV32:
		case SPIRV64:
		case VE:
		case WASM32:
		case WASM64:
		case XCORE:
			return VOID_POINTER;
		case AARCH64:
		case AARCH64_BE:
			switch (t.os.tag)
			{
				case DRIVERKIT:
				case IOS:
				case MACCATALYST:
				case MACOS:
				case TVOS:
				case VISIONOS:
				case WATCHOS:
				case WINDOWS: return CHAR_POINTER;
				default: kind = AARCH64_VA_LIST;
			}
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: kind = ARM_VA_LIST;
		case HEXAGON:
			if (!t.abi.is_musl()) return CHAR_POINTER;
			kind = HEXAGON_VA_LIST;
		case POWERPC:
		case POWERPCLE: kind = POWERPC_VA_LIST;
		case S390X: kind = S390X_VA_LIST;
		case X86_64:
			if (t.os.tag == UEFI || t.os.tag == WINDOWS) return CHAR_POINTER;
			kind = X86_64_VA_LIST;
		case XTENSA: kind = XTENSA_VA_LIST;
		default: return VOID; // unknown
	}

	QualType struct_qt;
	switch (kind)
	{
		case AARCH64_VA_LIST:
			RecordField[5] fields = {
				field(comp, "__stack", VOID_POINTER),
				field(comp, "__gr_top", VOID_POINTER),
				field(comp, "__vr_top", VOID_POINTER),
				field(comp, "__gr_offs", INT),
				field(comp, "__vr_offs", INT),
			};
			return put_builtin_struct(comp, "__va_list", &fields);
		case ARM_VA_LIST:
			RecordField[1] fields = { field(comp, "__ap", VOID_POINTER) };
			return put_builtin_struct(comp, "__va_list", &fields);
		case S390X_VA_LIST:
			RecordField[4] fields = {
				field(comp, "__gpr", LONG),
				field(comp, "__fpr", LONG),
				field(comp, "__overflow_arg_area", VOID_POINTER),
				field(comp, "__reg_save_area", VOID_POINTER),
			};
			struct_qt = put_builtin_struct(comp, "__va_list_tag", &fields);
		case POWERPC_VA_LIST:
			RecordField[5] fields = {
				field(comp, "gpr", UCHAR),
				field(comp, "fpr", UCHAR),
				field(comp, "reserved", USHORT),
				field(comp, "overflow_arg_area", VOID_POINTER),
				field(comp, "reg_save_area", VOID_POINTER),
			};
			struct_qt = put_builtin_struct(comp, "__va_list_tag", &fields);
		case HEXAGON_VA_LIST:
			RecordField[3] fields = {
				field(comp, "__current_saved_reg_area_pointer", VOID_POINTER),
				field(comp, "__saved_reg_area_end_pointer", VOID_POINTER),
				field(comp, "__overflow_area_pointer", VOID_POINTER),
			};
			struct_qt = put_builtin_struct(comp, "__va_list_tag", &fields);
		case X86_64_VA_LIST:
			RecordField[4] fields = {
				field(comp, "gp_offset", UINT),
				field(comp, "fp_offset", UINT),
				field(comp, "overflow_arg_area", VOID_POINTER),
				field(comp, "reg_save_area", VOID_POINTER),
			};
			struct_qt = put_builtin_struct(comp, "__va_list_tag", &fields);
		case XTENSA_VA_LIST:
			RecordField[3] fields = {
				field(comp, "__va_stk", INT_POINTER),
				field(comp, "__va_reg", INT_POINTER),
				field(comp, "__va_ndx", INT),
			};
			return put_builtin_struct(comp, "__va_list_tag", &fields);
	}
	return comp.type_store.put(type_array(struct_qt, FIXED, 1));
}
