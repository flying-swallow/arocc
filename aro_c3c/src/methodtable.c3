// Port of c3c src/compiler/methodtable.c (revision 54bab366a): the open
// addressing method table keyed on (name, canonical parent type).
//
// Deviations from c3c: none (CALLOC is calloc_arena).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// methodtable.c:3 (static)
fn DeclId* methodentry_find(DeclId* entries, uint capacity, String name, Type* type) @inline
{
	uptr hash_key = (uptr)name.ptr ^ (uptr)type;
	uint mask = capacity - 1;
	hash_key ^= hash_key >> 16;
	uint index = (uint)hash_key & mask;
	while (true)
	{
		DeclId* entry = &entries[index];
		DeclId decl_id = *entry;
		if (!decl_id) return entry;
		Decl* decl = declptr(*entry);
		if (decl.name.ptr == name.ptr && decl_find_method_target(decl).type.canonical == type) return entry;
		index = (index + 1) & mask;
	}
}

// methodtable.c:20 (static)
fn void methodtable_resize(MethodTable* table) @inline
{
	assert(table.capacity < MAX_HASH_SIZE, "Table size too large, exceeded max hash size");
	uint new_capacity = table.capacity ? (table.capacity << 2u) : 16u;
	DeclId* new_data = calloc_arena(new_capacity * DeclId::size);
	table.count = 0;
	uint len = table.capacity;
	for (uint i = 0; i < len; i++)
	{
		DeclId* entry = &table.methods[i];
		DeclId id = *entry;
		if (!id) continue;
		Decl* decl = declptr(id);
		table.count++;
		DeclId* dest = methodentry_find(new_data, new_capacity, decl.name, decl_find_method_target(decl).type.canonical);
		*dest = id;
	}
	table.methods = new_data;
	table.max_load = (uint)(new_capacity * TABLE_MAX_LOAD);
	table.capacity = new_capacity;
}

// methodtable.c:42
fn DeclId methodtable_set(MethodTable* table, Decl* decl)
{
	assert(decl != null, "Cannot insert NULL");
	assert(decl.func_decl.type_parent);
	DeclId* entry = methodentry_find(table.methods, table.capacity, decl.name, decl_find_method_target(decl).type.canonical);
	DeclId decl_id = declid(decl);
	DeclId old_id = *entry;
	if (old_id) return old_id;
	*entry = decl_id;
	table.count++;
	if (table.count >= table.max_load) methodtable_resize(table);
	return 0;
}

// methodtable.c:57
fn DeclId methodtable_get(MethodTable* table, Type* type, String name)
{
	if (!table.methods) return 0;
	DeclId* entry = methodentry_find(table.methods, table.capacity, name, type);
	return *entry;
}

// methodtable.c:64
fn void methodtable_init(MethodTable* table, uint initial_size)
{
	assert(initial_size != 0, "Size must be larger than 0");
	assert(is_power_of_two(initial_size), "Must be a power of two");

	DeclId* entries = calloc_arena(initial_size * DeclId::size);
	table.count = 0;
	table.capacity = initial_size;
	table.max_load = (uint)(initial_size * TABLE_MAX_LOAD);
	table.methods = entries;
}
