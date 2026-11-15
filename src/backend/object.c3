// Public object API and object-format dispatch, ported from
// src/backend/Object.zig. The implementation handle is owned by the selected
// format backend (currently ELF).
module aro::backend::object;
import aro::target;
import aro::backend::elf;
import std::collections::list, std::io;

excuse UNSUPPORTED_FORMAT;

<* Object sections supported by the ELF writer. `custom` carries the section name. *>
enum SectionKind : char
{
	UNDEFINED,
	DATA,
	BSS,
	READ_ONLY_DATA,
	FUNC,
	STRINGS,
	CUSTOM,
}

struct Section
{
	SectionKind kind;
	String custom_name;
}

const Section SECTION_UNDEFINED = { .kind = UNDEFINED };
const Section SECTION_DATA = { .kind = DATA };
const Section SECTION_BSS = { .kind = BSS };
const Section SECTION_READ_ONLY_DATA = { .kind = READ_ONLY_DATA };
const Section SECTION_FUNC = { .kind = FUNC };
const Section SECTION_STRINGS = { .kind = STRINGS };

<* ELF reserved section index used for common symbols. *>
const ushort SHN_COMMON = 0xFFF2;

enum SymbolType : char
{
	FUNC,
	VARIABLE,
	EXTERNAL,
}

<* x86-64 ELF relocation kinds. AUTO preserves the writer's symbol-based choice. *>
enum RelocKind : char (char value)
{
	AUTO { 0 },
	PC32 { 2 },
	PLT32 { 4 },
	GOTPCREL { 9 },
	GOTPCRELX { 41 },
	REX_GOTPCRELX { 42 },
	ABS64 { 1 },
}

<* Zig `std.builtin.GlobalLinkage`. *>
enum Linkage : char
{
	INTERNAL,
	STRONG,
	WEAK,
	LINK_ONCE,
}

<* Public object handle. `implementation` points to the selected backend state. *>
struct Object
{
	Allocator allocator;
	target::ObjectFormat format;
	target::Target target;
	void* implementation;
}

<*
 Create an object for the target's explicit format. ELF is currently the only
 implemented writer; other formats return UNSUPPORTED_FORMAT.
 @return? UNSUPPORTED_FORMAT
*>
fn Object*? create(Allocator gpa, target::Target target)
{
	switch (target.ofmt)
	{
		case ELF:
			void* implementation = elf::create(gpa, target);
			Object object_value;
			Object* object = alloc::malloc(gpa, @sizeof(object_value));
			*object = { .allocator = gpa, .format = target.ofmt, .target = target, .implementation = implementation };
			return object;
		default: return UNSUPPORTED_FORMAT~;
	}
}

fn void Object.deinit(&self)
{
	switch (self.format)
	{
		case ELF: elf::destroy(self.implementation);
		default: unreachable("unsupported object format in initialized object");
	}
	Allocator allocator = self.allocator;
	alloc::free(allocator, self);
}

<*
 Get or create the named output section's mutable bytes. BSS has no bytes;
 use `reserve_zero` to reserve logical zero-initialized storage.
*>
fn List{char}* get_section(Object* object, Section section)
{
	switch (object.format)
	{
		case ELF: return elf::get_section(object.implementation, section);
		default: unreachable("unsupported object format in initialized object");
	}
}

<*
 Align and reserve `size` zero-initialized bytes in a BSS section. The BSS
 byte list stays empty; the returned offset addresses the reserved range.
 @require section.kind == SectionKind.BSS && alignment > 0 && (alignment & (alignment - 1)) == 0
*>
fn ulong reserve_zero(Object* object, Section section, ulong size, ulong alignment)
{
	switch (object.format)
	{
		case ELF: return elf::reserve_zero(object.implementation, section, size, alignment);
		default: unreachable("unsupported object format in initialized object");
	}
}

<* Set the requested alignment for a section, creating the section if needed. *>
fn void set_section_align(Object* object, Section section, ulong alignment)
{
	switch (object.format)
	{
		case ELF: elf::set_section_align(object.implementation, section, alignment);
		default: unreachable("unsupported object format in initialized object");
	}
}

<* Copy a symbol name into object-owned storage; the returned bytes live until `deinit`. *>
fn String copy_name(Object* object, String name)
{
	switch (object.format)
	{
		case ELF: return elf::copy_name(object.implementation, name);
		default: unreachable("unsupported object format in initialized object");
	}
}

<*
 Declare a symbol and return its stable name (generated when `has_name` is
 false). Generated names are owned by the object and live until `deinit`.
*>
fn String declare_symbol(
	Object* object,
	Section section,
	String name,
	bool has_name,
	Linkage linkage,
	SymbolType symbol_type,
	ulong offset,
	ulong size,
)
{
	switch (object.format)
	{
		case ELF: return elf::declare_symbol(object.implementation, section, name, has_name, linkage, symbol_type, offset, size);
		default: unreachable("unsupported object format in initialized object");
	}
}

<*
 Declare a strong common variable symbol. `alignment` is stored in ELF st_value as
 required for SHN_COMMON symbols; `size` is its allocated size.
 @require alignment > 0 && (alignment & (alignment - 1)) == 0
*>
fn String declare_common(
	Object* object,
	String name,
	ulong size,
	ulong alignment,
)
{
	switch (object.format)
	{
		case ELF: return elf::declare_common_symbol(object.implementation, name, size, alignment);
		default: unreachable("unsupported object format in initialized object");
	}
}

fn void add_relocation(Object* object, String name, Section section, ulong address, long addend, RelocKind kind = RelocKind.AUTO)
{
	switch (object.format)
	{
		case ELF: elf::add_relocation(object.implementation, name, section, address, addend, kind);
		default: unreachable("unsupported object format in initialized object");
	}
}

<* Serialize the completed object to the supplied writer. *>
fn void? finish(Object* object, OutStream writer)
{
	switch (object.format)
	{
		case ELF: elf::finish(object.implementation, writer)!;
		default: unreachable("unsupported object format in initialized object");
	}
}
