// Emit lowered x86_64 Lines into the public object builder. Instructions are
// encoded by encode.c3; this file places their bytes and resolves fixups.
module aro::backend::x86_64;
import aro::backend::ir, aro::backend::object, std::collections::list, std::core::dstring;

struct LocalLabelOffset { String name; usz offset; }
struct PendingFixup { Fixup fixup; usz field_offset; }
struct PendingRelocation
{
	String name;
	object::Section section;
	ulong offset;
	long addend;
	object::RelocKind kind;
}

fn bool label_offset(List{LocalLabelOffset}* labels, String name, usz* result)
{
	foreach (label : *labels)
	{
		if (label.name == name) { *result = label.offset; return true; }
	}
	return false;
}

fn void patch_rel32(List{char}* bytes, usz field, long displacement)
{
	assert(displacement >= int::min && displacement <= int::max, "x86_64 rel32 displacement is out of range");
	for (uint i = 0; i < 4; i++) bytes.set((sz)(field + i), (char)((ulong)displacement >> (i * 8)));
}

fn object::Linkage object_linkage(ir::Linkage linkage)
{
	return linkage == ir::Linkage.INTERNAL ? object::Linkage.INTERNAL : object::Linkage.STRONG;
}

fn object::Section global_section(ir::DataSection section)
{
	if (section == ir::DataSection.RODATA) return object::SECTION_READ_ONLY_DATA;
	// The object API has no BSS or common section, so zero initialized data is
	// represented in writable data. COMMON therefore behaves like -fno-common;
	// tentative globals from separate translation units cannot be merged here.
	return object::SECTION_DATA;
}

fn bool declared(List{String}* names, String name)
{
	foreach (old : *names) if (old == name) return true;
	return false;
}

fn void declare_external(object::Object* obj, List{String}* names, String name)
{
	if (declared(names, name)) return;
	object::declare_symbol(obj, object::SECTION_UNDEFINED, name, true, object::Linkage.STRONG,
		object::SymbolType.EXTERNAL, 0, 0);
	names.push(name);
}

fn void record_error(ir::ErrorList* errors, String name, String message)
{
	errors.put(name, string::format(errors.allocator, "%s", message));
}

fn void declare_object_symbols(ir::Ir* ir, object::Object* obj, List{String}* names,
	List{PendingRelocation}* relocations, ir::ErrorList* errors)
{
	ulong data_align = 1;
	ulong rodata_align = 1;
	foreach (&decl : ir.decls)
	{
		if (declared(names, decl.name)) continue;
		if (decl.kind == ir::DeclKind.FUNCTION)
		{
			if (decl.is_definition()) continue; // Defined functions are declared after their size is known.
			object::declare_symbol(obj, object::SECTION_UNDEFINED, decl.name, true, object_linkage(decl.linkage),
				object::SymbolType.EXTERNAL, 0, 0);
			names.push(decl.name);
			continue;
		}
		if (!decl.is_definition())
		{
			object::declare_symbol(obj, object::SECTION_UNDEFINED, decl.name, true, object_linkage(decl.linkage),
				object::SymbolType.EXTERNAL, 0, 0);
			names.push(decl.name);
			continue;
		}

		object::Section section = global_section(decl.global.section);
		List{char}* bytes = object::get_section(obj, section);
		ulong alignment = decl.global.align > 0 ? decl.global.align : 1;
		if (section.kind == object::SectionKind.READ_ONLY_DATA && alignment > rodata_align)
		{
			rodata_align = alignment;
			object::set_section_align(obj, section, rodata_align);
		}
		else if (section.kind == object::SectionKind.DATA && alignment > data_align)
		{
			data_align = alignment;
			object::set_section_align(obj, section, data_align);
		}
		ulong offset = (ulong)bytes.len();
		while (offset % alignment != 0) { bytes.push(0); offset++; }
		if (decl.global.section == ir::DataSection.BSS || decl.global.section == ir::DataSection.COMMON)
		{
			for (ulong i = 0; i < decl.global.size; i++) bytes.push(0);
		}
		else
		{
			bytes.push_all(decl.global.bytes);
			for (ulong i = (ulong)decl.global.bytes.len; i < decl.global.size; i++) bytes.push(0);
		}
		object::declare_symbol(obj, section, decl.name, true, object_linkage(decl.linkage),
			object::SymbolType.VARIABLE, offset, decl.global.size);
		names.push(decl.name);

		foreach (relocation : decl.global.relocs)
		{
			if (relocation.offset > decl.global.size || decl.global.size - relocation.offset < 8)
			{
				record_error(errors, decl.name, "global relocation is outside 64-bit data");
				continue;
			}
			for (ulong i = 0; i < 8; i++) bytes.set((sz)(offset + relocation.offset + i), 0);
			relocations.push({ .name = relocation.symbol, .section = section,
				.offset = offset + relocation.offset, .addend = relocation.addend,
				.kind = object::RelocKind.ABS64 });
		}
	}
}

<*
 Lower functions into object code, place globals and string constants, then
 apply local rel32 fixups and symbol relocations after declaring all symbols.
 @return? ir::LOWER_FAIL
*>
fn void? render_object(ir::Ir* ir, object::Object* obj, ir::ErrorList* errors, bool spill_all = false)
{
	@pool()
	{
		Lowering lowering = { .ir = ir, .errors = errors, .spill_all = spill_all };
		lowering.strings.init(tmem);
		lowering.lines.init(tmem);
		List{String} names; names.init(tmem);
		List{PendingRelocation} relocations; relocations.init(tmem);
		List{char} encoded; encoded.init(tmem);
		List{PendingFixup} fixups; fixups.init(tmem);
		List{LocalLabelOffset} labels; labels.init(tmem);
		List{char}* text = object::get_section(obj, object::SECTION_FUNC);
		object::set_section_align(obj, object::SECTION_FUNC, 16);
		object::get_section(obj, object::SECTION_DATA);
		object::get_section(obj, object::SECTION_READ_ONLY_DATA);

		// Definitions and IR-declared externals exist before references are queued.
		declare_object_symbols(ir, obj, &names, &relocations, errors);

		foreach (&decl : ir.decls)
		{
			if (decl.kind != ir::DeclKind.FUNCTION || !decl.is_definition()) continue;
			if (catch lowering.lower_decl(decl)) continue;
			encoded.clear(); fixups.clear(); labels.clear();
			foreach (line : lowering.lines)
			{
				if (line.is_label)
				{
					labels.push({ .name = line.label, .offset = (usz)encoded.len() });
					continue;
				}
				Encoded? maybe_instruction = encode(line.mnemonic, line.ops[:line.op_count]);
				if (catch maybe_instruction)
				{
					DString shown;
					shown.init(tmem);
					foreach (i, op : line.ops[:line.op_count])
					{
						if (i) shown.append_string(", ");
						write_operand(&shown, op);
					}
					errors.put(decl.name, string::format(errors.allocator,
						"x86_64 encoding table has no form of '%s %s'", line.mnemonic.name, shown.str_view()));
					continue;
				}
				Encoded instruction = maybe_instruction;
				usz instruction_offset = (usz)encoded.len();
				encoded.push_all(instruction.bytes[:(usz)instruction.len]);
				if (instruction.fixup.kind != FixupKind.NONE)
				{
					fixups.push({ .fixup = instruction.fixup,
						.field_offset = instruction_offset + (usz)instruction.fixup.offset });
				}
			}

			foreach (pending : fixups)
			{
				if (pending.fixup.kind != FixupKind.LOCAL_REL32) continue;
				usz target_offset;
				if (!label_offset(&labels, pending.fixup.name, &target_offset))
				{
					errors.put(decl.name, string::format(errors.allocator,
						"unresolved local x86_64 label '%s'", pending.fixup.name));
					continue;
				}
				long displacement = (long)target_offset + pending.fixup.addend - (long)pending.field_offset;
				patch_rel32(&encoded, pending.field_offset, displacement);
			}

			ulong start = (ulong)text.len();
			while (start % 16 != 0) { text.push(0); start++; }
			start = (ulong)text.len();
			text.push_all(encoded.array_view());
			object::declare_symbol(obj, object::SECTION_FUNC, decl.name, true, object_linkage(decl.linkage),
				object::SymbolType.FUNC, start, (ulong)encoded.len());
			if (!declared(&names, decl.name)) names.push(decl.name);

			foreach (pending : fixups)
			{
				if (pending.fixup.kind != FixupKind.SYMBOL) continue;
				relocations.push({ .name = pending.fixup.name, .section = object::SECTION_FUNC,
					.offset = start + (ulong)pending.field_offset, .addend = pending.fixup.addend,
					.kind = pending.fixup.reloc });
			}
		}

		// String constants are referenced through RIP-relative symbol relocations.
		List{char}* strings = object::get_section(obj, object::SECTION_READ_ONLY_DATA);
		foreach (string : lowering.strings)
		{
			ulong offset = (ulong)strings.len();
			strings.push_all(string.bytes);
			String label = object::copy_name(obj, string.label);
			object::declare_symbol(obj, object::SECTION_READ_ONLY_DATA, label, true, object::Linkage.INTERNAL,
				object::SymbolType.VARIABLE, offset, (ulong)string.bytes.len);
			names.push(label);
		}

		// The Object API requires both section and symbol declarations before relocation.
		foreach (relocation : relocations) declare_external(obj, &names, relocation.name);
		foreach (relocation : relocations)
		{
			object::add_relocation(obj, relocation.name, relocation.section, relocation.offset,
				relocation.addend, relocation.kind);
		}
		if (errors.len() != 0) return ir::LOWER_FAIL~;
	};
	return;
}
