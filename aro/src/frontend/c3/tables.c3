// Port of the pointer-keyed tables of c3c: `STable`, `HTable` and `PathTable`
// (the second half of src/compiler/symtab.c) and `DeclTable`
// (src/compiler/decltable.c).
//
// All keys are interned (symtab) pointers, compared by address exactly like
// c3c: a String key is identified by its `ptr`.
//
// Deviations from c3c:
// - Storage comes from the AST arena (`calloc_arena`), as c3c's CALLOC does;
//   tables are released with `ast_memory_reset`.
// - `goto RESIZE` in `stable_set` is a plain branch.
module aro::frontend::c3::compiler;

const double TABLE_MAX_LOAD = 0.5;
const uint MAX_HASH_SIZE = 512 * 1024 * 1024;

struct SEntry
{
	String key;
	void* value;
}

struct STable
{
	uint count;
	uint capacity;
	uint max_load;
	SEntry* entries;
}

struct PathTableEntry
{
	String short_path;
	String name;
	Decl* value;
	PathTableEntry* next;
}

struct PathTable
{
	uint mask;
	PathTableEntry** entries;
}

<* c3c `next_highest_power_of_2` (utils/lib.h). *>
fn uint next_highest_power_of_2(uint v)
{
	v--;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v++;
	return v;
}

<* c3c `is_power_of_two` (utils/lib.h). *>
fn bool is_power_of_two(ulong x) => x != 0 && (x & (x - 1)) == 0;

fn uint ptr_hash(void* key) @inline
{
	uptr k = (uptr)key;
	return (uint)(k ^ (k >> 8));
}

// ---------------------------------------------------------------------------
// STable

fn void stable_init(STable* table, uint initial_size)
{
	assert(initial_size != 0, "Size must be larger than 0");
	assert(is_power_of_two(initial_size), "Must be a power of two");
	SEntry* entries = calloc_arena(initial_size * SEntry::size);
	table.count = 0;
	table.capacity = initial_size;
	table.max_load = (uint)(initial_size * TABLE_MAX_LOAD);
	table.entries = entries;
}

fn void stable_clear(STable* table)
{
	mem::clear(table.entries, (sz)(table.capacity * SEntry::size));
	table.count = 0;
}

fn SEntry* sentry_find(SEntry* entries, uint capacity, String key) @inline
{
	uptr hash_key = (uptr)key.ptr;
	uint mask = capacity - 1;
	hash_key ^= hash_key >> 16;
	uint index = (uint)hash_key & mask;
	while (true)
	{
		SEntry* entry = &entries[index];
		if (entry.key.ptr == key.ptr || !entry.key.ptr) return entry;
		index = (index + 1) & mask;
	}
}

fn void stable_resize(STable* table)
{
	assert(table.capacity < MAX_HASH_SIZE, "Table size too large, exceeded max hash size");
	uint new_capacity = table.capacity ? (table.capacity << 2u) : 16u;
	SEntry* new_data = calloc_arena(new_capacity * SEntry::size);
	table.count = 0;
	uint len = table.capacity;
	for (uint i = 0; i < len; i++)
	{
		SEntry* entry = &table.entries[i];
		String key = entry.key;
		if (!key.ptr) continue;
		table.count++;
		SEntry* dest = sentry_find(new_data, new_capacity, key);
		dest.key = key;
		dest.value = entry.value;
	}
	table.entries = new_data;
	table.max_load = (uint)(new_capacity * TABLE_MAX_LOAD);
	table.capacity = new_capacity;
}

fn void* stable_set(STable* table, String key, void* value)
{
	assert(value != null, "Cannot insert NULL");
	SEntry* entry = sentry_find(table.entries, table.capacity, key);
	void* old = entry.value;
	if (old == value) return old;
	entry.key = key;
	entry.value = value;
	if (!old)
	{
		table.count++;
		if (table.count >= table.max_load) stable_resize(table);
	}
	return old;
}

fn void* stable_get(STable* table, String key)
{
	if (!table.entries) return null;
	SEntry* entry = sentry_find(table.entries, table.capacity, key);
	return entry.key.ptr == null ? null : entry.value;
}

// ---------------------------------------------------------------------------
// HTable

fn void htable_init(HTable* table, uint initial_size)
{
	assert(initial_size != 0, "Size must be larger than 0");
	usz size = next_highest_power_of_2(initial_size);
	usz mem_size = size * usz::size;
	table.entries = calloc_arena(mem_size);
	table.mask = (uint)size - 1;
}

fn void* htable_set(HTable* table, void* key, void* value)
{
	assert(value != null, "Cannot insert NULL");
	uint idx = ptr_hash(key) & table.mask;
	HTEntry** entry_ref = &table.entries[idx];
	HTEntry* entry = *entry_ref;
	if (!entry)
	{
		entry = calloc_arena(HTEntry::size);
		entry.key = key;
		entry.value = value;
		*entry_ref = entry;
		return null;
	}
	HTEntry* first_entry = entry;
	do
	{
		if (entry.key == key)
		{
			void* val = entry.value;
			entry.value = value;
			return val;
		}
		entry = entry.next;
	}
	while (entry);

	entry = calloc_arena(HTEntry::size);
	entry.key = key;
	entry.value = value;
	entry.next = first_entry;
	*entry_ref = entry;
	return null;
}

fn void* htable_get(HTable* table, void* key)
{
	uint idx = ptr_hash(key) & table.mask;
	HTEntry* entry = table.entries[idx];
	if (!entry) return null;
	do
	{
		if (entry.key == key) return entry.value;
		entry = entry.next;
	}
	while (entry);
	return null;
}

// ---------------------------------------------------------------------------
// PathTable

fn void pathtable_init(PathTable* table, uint initial_size)
{
	assert(initial_size != 0, "Size must be larger than 0");
	usz size = next_highest_power_of_2(initial_size);
	usz mem_size = size * usz::size;
	table.entries = calloc_arena(mem_size);
	table.mask = (uint)size - 1;
}

fn uint pathtable_index(PathTable* table, String short_path, String name) @inline
{
	return (ptr_hash(short_path.ptr) ^ ptr_hash(name.ptr)) & table.mask;
}

fn void pathtable_set(PathTable* table, Decl* value)
{
	assert(value != null, "Cannot insert NULL");
	assert(value.name.ptr != null);
	String short_path = value.unit.mod.short_path;
	String name = value.name;
	uint idx = pathtable_index(table, short_path, name);
	PathTableEntry** entry_ref = &table.entries[idx];
	PathTableEntry* entry = *entry_ref;
	if (!entry)
	{
		entry = calloc_arena(PathTableEntry::size);
		entry.short_path = short_path;
		entry.name = name;
		entry.value = value;
		*entry_ref = entry;
		return;
	}
	PathTableEntry* first_entry = entry;
	do
	{
		if (entry.short_path.ptr == short_path.ptr && entry.name.ptr == name.ptr)
		{
			entry.value = poisoned_decl;
			return;
		}
		entry = entry.next;
	}
	while (entry);

	entry = calloc_arena(PathTableEntry::size);
	entry.short_path = short_path;
	entry.name = name;
	entry.value = value;
	entry.next = first_entry;
	*entry_ref = entry;
}

fn void pathtable_replace(PathTable* table, Decl* original, Decl* value)
{
	assert(value != null, "Cannot insert NULL");
	assert(value.name.ptr != null);
	String short_path = value.unit.mod.short_path;
	String name = value.name;
	uint idx = pathtable_index(table, short_path, name);
	PathTableEntry** entry_ref = &table.entries[idx];
	PathTableEntry* entry = *entry_ref;
	do
	{
		if (entry.value == original)
		{
			entry.value = value;
			return;
		}
		entry = entry.next;
	}
	while (entry);
}

fn Decl* pathtable_get(PathTable* table, String short_path, String name)
{
	uint idx = pathtable_index(table, short_path, name);
	PathTableEntry* entry = table.entries[idx];
	if (!entry) return null;
	do
	{
		if (entry.short_path.ptr == short_path.ptr && entry.name.ptr == name.ptr) return entry.value;
		entry = entry.next;
	}
	while (entry);
	return null;
}

// ---------------------------------------------------------------------------
// DeclTable (decltable.c)

fn DeclId* declentry_find(DeclId* entries, uint capacity, String name) @inline
{
	uptr hash_key = (uptr)name.ptr;
	uint mask = capacity - 1;
	hash_key ^= hash_key >> 16;
	uint index = (uint)hash_key & mask;
	while (true)
	{
		DeclId* entry = &entries[index];
		DeclId decl_id = *entry;
		if (!decl_id) return entry;
		Decl* decl = declptr(*entry);
		if (decl.name.ptr == name.ptr) return entry;
		index = (index + 1) & mask;
	}
}

fn void decltable_resize(DeclTable* table)
{
	assert(table.capacity < MAX_HASH_SIZE, "Table size too large, exceeded max hash size");
	uint new_capacity = table.capacity ? (table.capacity << 2u) : 16u;
	DeclId* new_data = calloc_arena(new_capacity * DeclId::size);
	table.count = 0;
	uint len = table.capacity;
	for (uint i = 0; i < len; i++)
	{
		DeclId* entry = &table.entries[i];
		DeclId id = *entry;
		if (!id) continue;
		Decl* decl = declptr(id);
		table.count++;
		DeclId* dest = declentry_find(new_data, new_capacity, decl.name);
		*dest = id;
	}
	table.entries = new_data;
	table.max_load = (uint)(new_capacity * TABLE_MAX_LOAD);
	table.capacity = new_capacity;
}

fn void decltable_set(DeclTable* table, Decl* decl)
{
	assert(decl != null, "Cannot insert NULL");
	DeclId* entry = declentry_find(table.entries, table.capacity, decl.name);
	DeclId decl_id = declid(decl);
	DeclId old_id = *entry;
	assert(old_id != decl_id);
	// Simple case, a new decl
	if (!old_id)
	{
		*entry = decl_id;
		table.count++;
		if (table.count >= table.max_load) decltable_resize(table);
		return;
	}
	Decl* old = declptr(old_id);
	if (old.decl_kind == DECLARRAY)
	{
		@vec_add(&old.decl_list, decl);
		return;
	}
	Decl* list = decl_calloc();
	list.decl_kind = DECLARRAY;
	list.name = decl.name;
	@vec_add(&list.decl_list, old);
	@vec_add(&list.decl_list, decl);
	*entry = declid(list);
}

fn void decltable_replace(DeclTable* table, Decl* old, Decl* new_decl)
{
	DeclId* entry = declentry_find(table.entries, table.capacity, old.name);
	DeclId decl_id = declid(old);
	if (*entry == decl_id)
	{
		*entry = declid(new_decl);
		return;
	}
	Decl* entry_decl = declptr(*entry);
	assert(entry_decl.decl_kind == DECLARRAY);
	foreach (i, d : entry_decl.decl_list)
	{
		if (d == old)
		{
			entry_decl.decl_list[i] = new_decl;
			return;
		}
	}
	unreachable();
}

fn DeclId decltable_get(DeclTable* table, String name)
{
	if (!table.entries) return 0;
	DeclId* entry = declentry_find(table.entries, table.capacity, name);
	return *entry;
}

fn void decltable_init(DeclTable* table, uint initial_size)
{
	assert(initial_size != 0, "Size must be larger than 0");
	assert(is_power_of_two(initial_size), "Must be a power of two");
	DeclId* entries = calloc_arena(initial_size * DeclId::size);
	table.count = 0;
	table.capacity = initial_size;
	table.max_load = (uint)(initial_size * TABLE_MAX_LOAD);
	table.entries = entries;
}
