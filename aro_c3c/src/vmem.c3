// Port of c3c src/utils/vmem.c plus the ARENA_DEF id arenas of utils/malloc.h
// and the stretchy vectors (`vec_add`, `vec_size`) of utils/lib.h.
//
// A Vmem reserves a large PROT_NONE range and commits it in 4 MiB steps, so
// node addresses never move and a node's id is its index from the arena base
// (index 0 is reserved: id 0 means "none"), exactly like c3c.
//
// Deviations from c3c:
// - c3c vectors (`Decl **` with a hidden header) are C3 slices; `@vec_add`
//   grows them in place in the AST allocator (capacity = next power of two
//   >= len, implied by len), so no header is needed and `foreach` works.
// - Allocation failure panics instead of error_exit (same effect).
module aro::frontend::c3::compiler;
import std::core::mem::vm, std::core::mem::alloc, std::core::mem::allocators;

const usz MB_SIZE = 1024 * 1024;
const usz COMMIT_PAGE_SIZE = 4 * MB_SIZE;

struct Vmem
{
	char* ptr;
	usz size;
	usz allocated;
	usz committed;
}

<* c3c `vmem_init`: reserve `size_in_mb` (halving on failure down to 1/512). *>
fn void Vmem.init(&self, usz size_in_mb)
{
	usz size = size_in_mb * MB_SIZE;
	if (size < COMMIT_PAGE_SIZE) size = COMMIT_PAGE_SIZE;
	usz min_size = size / 512;
	if (min_size < COMMIT_PAGE_SIZE) min_size = COMMIT_PAGE_SIZE;
	while (size >= min_size)
	{
		void*? ptr = vm::alloc((sz)size, PROTECTED);
		if (try ptr)
		{
			*self = { .ptr = ptr, .size = size };
			return;
		}
		size /= 2;
	}
	abort("Failed to map a virtual memory block.");
}

<*
 c3c `vmem_alloc`: zeroed bump allocation of exactly `to_allocate` bytes.
 An id arena holds one type, so elements stay aligned and id = offset / size.
*>
fn void* Vmem.alloc(&self, usz to_allocate)
{
	usz allocated_after = to_allocate + self.allocated;
	if (allocated_after > self.size)
	{
		abort("The compiler ran out of memory: more than %d MB was allocated from a single memory arena.", self.size / MB_SIZE);
	}
	usz end_block = (allocated_after + COMMIT_PAGE_SIZE - 1) / COMMIT_PAGE_SIZE;
	usz blocks_committed = self.committed / COMMIT_PAGE_SIZE;
	if (end_block > blocks_committed)
	{
		usz to_commit = (end_block - blocks_committed) * COMMIT_PAGE_SIZE;
		if (catch vm::commit(self.ptr + self.committed, (sz)to_commit, READWRITE))
		{
			abort("The compiler ran out of memory committing %d bytes.", to_commit);
		}
		self.committed += to_commit;
	}
	void* p = self.ptr + self.allocated;
	self.allocated = allocated_after;
	return p;
}

<* c3c `vmem_free`. *>
fn void Vmem.free(&self)
{
	if (!self.ptr) return;
	(void)vm::release(self.ptr, (sz)self.size);
	*self = {};
}

<* General AST storage (strings, vectors, side structs); freed only by `ast_memory_reset`. *>
DynamicArenaAllocator ast_arena;
bool ast_arena_ready;

fn Allocator ast_allocator()
{
	if (!ast_arena_ready)
	{
		ast_arena.init(mem, 1024 * 1024);
		ast_arena_ready = true;
	}
	return &ast_arena;
}

<* c3c `malloc_arena` / `calloc_arena` (always zeroed). *>
fn void* calloc_arena(usz size) => alloc::calloc(ast_allocator(), (sz)size);

<* c3c `str_copy`: copy into the AST arena, NUL terminated. *>
fn String str_copy(String s)
{
	char* p = calloc_arena(s.len + 1);
	p[:s.len] = s[..];
	return (String)p[:s.len];
}

<* Capacity implied by a vector length: 0, then powers of two from 4. *>
fn usz vec_capacity(usz len) @inline
{
	if (len == 0) return 0;
	usz cap = 4;
	while (cap < len) cap <<= 1;
	return cap;
}

<* c3c `vec_add`: append `value` to the slice at `vec_ref`, growing it in the AST arena. *>
macro void @vec_add(vec_ref, value)
{
	usz len = (*vec_ref).len;
	if (len == vec_capacity(len))
	{
		usz new_cap = len == 0 ? 4 : len * 2;
		$Typeof((*vec_ref).ptr) data = calloc_arena(new_cap * $Typeof((*vec_ref).ptr[0])::size);
		if (len) mem::copy(data, (*vec_ref).ptr, (sz)(len * $Typeof((*vec_ref).ptr[0])::size));
		*vec_ref = data[:len];
	}
	(*vec_ref).ptr[len] = value;
	*vec_ref = (*vec_ref).ptr[:len + 1];
}

<* c3c `vec_pop`. *>
macro @vec_pop(vec_ref)
{
	$Typeof((*vec_ref).ptr[0]) last = (*vec_ref)[^1];
	*vec_ref = (*vec_ref)[:(*vec_ref).len - 1];
	return last;
}

<* c3c `vec_erase_front`: drop the first `count` elements, keeping the same storage. *>
macro void @vec_erase_front(vec_ref, usz count)
{
	usz len = (*vec_ref).len;
	mem::move((*vec_ref).ptr, (*vec_ref).ptr + count, (sz)((len - count) * $Typeof((*vec_ref).ptr[0])::size));
	*vec_ref = (*vec_ref).ptr[:len - count];
}

<* c3c `vec_erase_at`. *>
macro void @vec_erase_at(vec_ref, usz index)
{
	usz len = (*vec_ref).len;
	mem::move((*vec_ref).ptr + index, (*vec_ref).ptr + index + 1, (sz)((len - index - 1) * $Typeof((*vec_ref).ptr[0])::size));
	*vec_ref = (*vec_ref).ptr[:len - 1];
}

<* c3c `vec_resize` (shrink only; the storage is kept). *>
macro void @vec_resize(vec_ref, usz new_size)
{
	assert(new_size <= (*vec_ref).len);
	*vec_ref = (*vec_ref).ptr[:new_size];
}

<* c3c `vec_insert_at`. *>
macro void @vec_insert_at(vec_ref, usz at, value)
{
	@vec_add(vec_ref, value);
	usz len = (*vec_ref).len;
	for (usz i = len - 1; i > at; i--) (*vec_ref)[i] = (*vec_ref)[i - 1];
	(*vec_ref)[at] = value;
}

<* c3c `vec_insert_first`. *>
macro void @vec_insert_first(vec_ref, value) => @vec_insert_at(vec_ref, 0, value);

<* c3c `VECLAST`: the last element, or null when empty (pointer vectors). *>
macro @veclast(vec) => vec.len ? vec[^1] : null;
