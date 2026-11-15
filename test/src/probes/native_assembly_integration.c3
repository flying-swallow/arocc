// Assemble the integer-scalars probe output and inspect the resulting ELF
// object. Arguments are the probe binary, fixture and assembler; the object's
// section headers, symbol table and .data bytes are read directly (ELF64 LE).
module native_assembly_integration;
import std::io, std::io::file, std::collections::list, aro_harness, native;

const uint SHT_PROGBITS = 1;
const uint SHT_SYMTAB = 2;
const char STT_OBJECT = 1;
const char STB_GLOBAL = 1;
const char STV_DEFAULT = 0;

struct Section
{
	String name;
	uint type;
	ulong offset;
	ulong size;
	uint link;
	ulong entsize;
}

struct Symbol
{
	String name;
	ulong value;
	ulong size;
	char type;
	char bind;
	char visibility;
	ushort shndx;
}

struct ElfObject
{
	char[] bytes;
	Section[] sections;
	Symbol[] symbols;
}

struct ExpectedSymbol
{
	String name;
	ulong value;
	ulong size;
}

faultdef ELF_MALFORMED;

fn ulong le(char[] b, ulong at, ulong n)
{
	ulong v = 0;
	for (ulong i = n; i > 0; i--) v = (v << 8) | b[at + i - 1];
	return v;
}

fn bool in_range(char[] b, ulong at, ulong n) => at <= b.len && n <= b.len - at;

fn String? c_name(char[] table, ulong off)
{
	if (off >= table.len) return ELF_MALFORMED~;
	ulong end = off;
	while (end < table.len && table[end]) end++;
	return (String)table[off:end - off];
}

<* Section headers (with names) and the SYMTAB symbols of a relocatable ELF64 little-endian object. *>
fn ElfObject? parse_elf(Allocator a, char[] b)
{
	if (b.len < 64 || b[0] != 0x7f || b[1] != 'E' || b[2] != 'L' || b[3] != 'F' || b[4] != 2 || b[5] != 1)
	{
		return ELF_MALFORMED~;
	}
	ulong shoff = le(b, 0x28, 8);
	ulong shentsize = le(b, 0x3a, 2);
	ulong shnum = le(b, 0x3c, 2);
	ulong shstrndx = le(b, 0x3e, 2);
	if (shentsize < 64 || !in_range(b, shoff, shnum * shentsize) || shstrndx >= shnum) return ELF_MALFORMED~;
	Section[] sections = alloc::new_array(a, Section, (sz)shnum);
	for (ulong i = 0; i < shnum; i++)
	{
		ulong h = shoff + i * shentsize;
		sections[i] = {
			.type = (uint)le(b, h + 4, 4),
			.offset = le(b, h + 0x18, 8),
			.size = le(b, h + 0x20, 8),
			.link = (uint)le(b, h + 0x28, 4),
			.entsize = le(b, h + 0x38, 8),
		};
	}
	Section* shstr = &sections[shstrndx];
	if (!in_range(b, shstr.offset, shstr.size)) return ELF_MALFORMED~;
	char[] shstrtab = b[shstr.offset:shstr.size];
	for (ulong i = 0; i < shnum; i++)
	{
		ulong h = shoff + i * shentsize;
		sections[i].name = c_name(shstrtab, le(b, h, 4))!;
	}
	List{Symbol} symbols;
	symbols.init(a);
	foreach (&s : sections)
	{
		if (s.type != SHT_SYMTAB) continue;
		if (s.entsize < 24 || !in_range(b, s.offset, s.size) || s.link >= sections.len) return ELF_MALFORMED~;
		Section* str = &sections[s.link];
		if (!in_range(b, str.offset, str.size)) return ELF_MALFORMED~;
		char[] strtab = b[str.offset:str.size];
		for (ulong at = s.offset; at + s.entsize <= s.offset + s.size; at += s.entsize)
		{
			char info = b[at + 4];
			symbols.push({
				.name = c_name(strtab, le(b, at, 4))!,
				.type = info & 0xf,
				.bind = info >> 4,
				.visibility = b[at + 5] & 0x3,
				.shndx = (ushort)le(b, at + 6, 2),
				.value = le(b, at + 8, 8),
				.size = le(b, at + 16, 8),
			});
		}
	}
	return { .bytes = b, .sections = sections, .symbols = symbols.array_view() };
}

fn void dump_sections(ElfObject* elf)
{
	foreach (i, s : elf.sections)
	{
		io::eprintfn("  [%2d] %-20s type=%d offset=0x%x size=0x%x", i, s.name, s.type, s.offset, s.size);
	}
}

fn void dump_symbols(ElfObject* elf)
{
	foreach (i, s : elf.symbols)
	{
		io::eprintfn("  %3d: %016x %5d type=%d bind=%d vis=%d ndx=%d %s", i, s.value, s.size, s.type, s.bind, s.visibility, s.shndx, s.name);
	}
}

<* A GLOBAL DEFAULT OBJECT symbol `name` in section `data_index` with this value and size. *>
fn bool has_symbol(ElfObject* elf, ulong data_index, String name, ulong value, ulong size)
{
	foreach (s : elf.symbols)
	{
		if (s.type == STT_OBJECT && s.bind == STB_GLOBAL && s.visibility == STV_DEFAULT
			&& s.shndx == data_index && s.name == name && s.value == value && s.size == size) return true;
	}
	return false;
}

fn int main(String[] args)
{
	if (args.len != 4)
	{
		io::eprintfn("usage: %s <assembly_probe> <integer_scalars_fixture> <as>", args[0]);
		return 2;
	}
	String probe_arg = args[1];
	String fixture = args[2];
	String as_arg = args[3];

	if (!native::NATIVE_HOST)
	{
		io::printn("SKIP: native assembly integration requires Linux x86-64");
		return 0;
	}

	foreach (executable : (String[]){ probe_arg, as_arg })
	{
		if (!aro_harness::is_executable(native::resolve_arg(tmem, executable)))
		{
			io::eprintfn("native assembly integration: not executable: %s", executable);
			return 1;
		}
	}
	if (!native::is_readable(fixture))
	{
		io::eprintfn("native assembly integration: fixture is not readable: %s", fixture);
		return 1;
	}
	String probe = native::resolve_arg(mem, probe_arg);
	String assembler = native::resolve_arg(mem, as_arg);

	String? tmpdir = aro_harness::make_temp_dir(mem, "aro-native-assembly.");
	if (catch tmpdir)
	{
		io::eprintn("native assembly integration: cannot create a temporary directory");
		return 1;
	}
	defer aro_harness::remove_tree(tmpdir);
	String assembly = string::format(mem, "%s/integer_scalars.s", tmpdir);
	String object = string::format(mem, "%s/integer_scalars.o", tmpdir);

	// "$probe" "$fixture" > "$assembly"
	RunResult probe_run = aro_harness::run(mem, { probe, fixture });
	io::eprint(probe_run.stderr);
	int status = native::shell_status(&probe_run);
	if (status) return status;
	if (catch file::save(assembly, probe_run.stdout))
	{
		io::eprintfn("native assembly integration: cannot write %s", assembly);
		return 1;
	}
	native::flush_stdout();
	RunResult as_run = aro_harness::run(mem, { assembler, "--64", "-o", object, assembly }, { .inherit_stdio = true });
	status = native::shell_status(&as_run);
	if (status) return status;

	char[]? bytes = file::load(mem, object);
	if (catch bytes)
	{
		io::eprintfn("native assembly integration: cannot read %s", object);
		return 1;
	}
	ElfObject? parsed = parse_elf(mem, bytes);
	if (catch parsed)
	{
		io::eprintfn("native assembly integration: %s is not a valid ELF64 little-endian object", object);
		return 1;
	}
	ElfObject elf = parsed;

	ulong data_index = 0;
	bool found_data = false;
	foreach (i, s : elf.sections)
	{
		if (s.name == ".data" && s.type == SHT_PROGBITS)
		{
			data_index = (ulong)i;
			found_data = true;
			break;
		}
	}
	if (!found_data)
	{
		io::eprintn("native assembly integration: object has no PROGBITS .data section");
		dump_sections(&elf);
		return 1;
	}

	// The emitter aligns each scalar: byte_value at 0, short_value at 2,
	// int_value at 4, and long_value at 8. Confirm the type, binding, section,
	// offset, and byte size recorded by the assembler.
	ExpectedSymbol[*] expected_symbols = {
		{ "byte_value", 0, 1 },
		{ "short_value", 2, 2 },
		{ "int_value", 4, 4 },
		{ "long_value", 8, 8 },
	};
	foreach (e : expected_symbols)
	{
		if (!has_symbol(&elf, data_index, e.name, e.value, e.size))
		{
			io::eprintfn("native assembly integration: missing or incorrect ELF symbol %s", e.name);
			dump_symbols(&elf);
			return 1;
		}
	}

	Section data = elf.sections[data_index];
	if (!in_range(bytes, data.offset, data.size))
	{
		io::eprintn("native assembly integration: .data section lies outside the object");
		return 1;
	}
	DString actual;
	actual.init(mem);
	foreach (c : bytes[data.offset:data.size]) actual.appendf("%02x", c);
	const String EXPECTED = "ff0085ff7856341215cd5b0700000000";
	if (actual.str_view() != EXPECTED)
	{
		io::eprintn("native assembly integration: unexpected .data bytes");
		io::eprintfn("expected: %s", EXPECTED);
		io::eprintfn("actual:   %s", actual.str_view());
		return 1;
	}

	io::printn("native assembly integration passed: four symbols and 16 .data bytes verified");
	return 0;
}
