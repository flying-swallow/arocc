// Ported from https://github.com/ziglang/zig/blob/c9006d9479c619d9ed555164831e11a04d88d382/src/tracy.zig
// Zig's source is distributed under the MIT license; see the repository LICENSE.

module aro::tracy;
import std::core::mem::allocators;

// Enable features with `-D TRACY`, `-D TRACY_ALLOCATION`, and
// `-D TRACY_CALLSTACK`. Each flag defaults to off when it is not supplied.
const bool ENABLE = $feat(TRACY);
const bool ENABLE_ALLOCATION = $feat(TRACY_ALLOCATION);
const bool ENABLE_CALLSTACK = $feat(TRACY_CALLSTACK);
const int CALLSTACK_DEPTH = 10;
const uint RED = 0xFF0000;

const bool ENABLE_ALL = ENABLE && ENABLE_ALLOCATION;

struct Ctx
{
	uint id;
	CInt active;
}

struct SourceLocation
{
	ZString name;
	ZString function;
	ZString file;
	uint line;
	uint color;
}

<* End a zone and release its profiling context. *>
fn void Ctx.end(self)
{
	$if ENABLE: ___tracy_emit_zone_end(self); $endif
}

<* Attach arbitrary bytes to a zone. *>
fn void Ctx.add_text(self, String text)
{
	$if ENABLE: ___tracy_emit_zone_text(self, text.ptr, (usz)text.len); $endif
}

fn void Ctx.set_name(self, String name)
{
	$if ENABLE: ___tracy_emit_zone_name(self, name.ptr, (usz)name.len); $endif
}

fn void Ctx.set_color(self, uint color)
{
	$if ENABLE: ___tracy_emit_zone_color(self, color); $endif
}

fn void Ctx.set_value(self, ulong value)
{
	$if ENABLE: ___tracy_emit_zone_value(self, value); $endif
}

<*
 Begin a profiling zone. `function` and `file` must point to null-terminated
 strings whose storage remains valid for the call. This takes an explicit
 location because C3 does not expose Zig's compile-time SourceLocation value.
*>
fn Ctx trace(ZString function, ZString file, uint line)
{
	$if ENABLE:
		SourceLocation src = { .name = null, .function = function, .file = file, .line = line, .color = 0 };
		$if ENABLE_CALLSTACK:
			return ___tracy_emit_zone_begin_callstack(&src, CALLSTACK_DEPTH, 1);
		$else
			return ___tracy_emit_zone_begin(&src, 1);
		$endif
	$else
		return {};
	$endif
}

fn Ctx trace_named(ZString function, ZString file, uint line, ZString name)
{
	$if ENABLE:
		SourceLocation src = { .name = name, .function = function, .file = file, .line = line, .color = 0 };
		$if ENABLE_CALLSTACK:
			return ___tracy_emit_zone_begin_callstack(&src, CALLSTACK_DEPTH, 1);
		$else
			return ___tracy_emit_zone_begin(&src, 1);
		$endif
	$else
		return {};
	$endif
}

struct TracyAllocator
{
	Allocator parent;
	ZString name;
	bool has_name;
}

fn TracyAllocator tracy_allocator(Allocator parent)
{
	return { .parent = parent, .name = null, .has_name = false };
}

fn TracyAllocator tracy_allocator_named(Allocator parent, ZString name)
{
	return { .parent = parent, .name = name, .has_name = true };
}

<* Convert a long-lived wrapper to the allocator interface without copying it. *>
macro Allocator tracy_allocator_interface(TracyAllocator* wrapper) => (Allocator)wrapper;

fn void*? TracyAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	if (!size) return null;
	void*? result = self.parent.acquire(size, init_type, alignment);
	if (catch err = result)
	{
		message_color("allocation failed", RED);
		return err~;
	}
	$if ENABLE_ALL:
	{
		if (self.has_name) { alloc_named(result, (usz)size, self.name); }
		else { alloc(result, (usz)size); }
	}
	$endif
	return result;
}

fn void*? TracyAllocator.resize(&self, void* old_pointer, sz new_size, sz alignment) @dynamic
{
	if (!new_size)
	{
		self.release(old_pointer, false);
		return null;
	}
	void*? result = self.parent.resize(old_pointer, new_size, alignment);
	if (catch err = result) return err~;
	$if ENABLE_ALL:
	{
		if (self.has_name)
		{
			free_named(old_pointer, self.name);
			alloc_named(result, (usz)new_size, self.name);
		}
		else
		{
			free(old_pointer);
			alloc(result, (usz)new_size);
		}
	}
	$endif
	return result;
}

fn void TracyAllocator.release(&self, void* ptr, bool aligned) @dynamic
{
	if (!ptr) return;
	self.parent.release(ptr, aligned);
	$if ENABLE_ALL:
	{
		if (self.has_name) { free_named(ptr, self.name); }
		else { free(ptr); }
	}
	$endif
}

<* The null-terminated message storage must remain valid for Tracy's lifetime. *>
fn void message(ZString msg)
{
	$if ENABLE: ___tracy_emit_messageL(msg, ENABLE_CALLSTACK ? CALLSTACK_DEPTH : 0); $endif
}

<* The null-terminated message storage must remain valid for Tracy's lifetime. *>
fn void message_color(ZString msg, uint color)
{
	$if ENABLE: ___tracy_emit_messageLC(msg, color, ENABLE_CALLSTACK ? CALLSTACK_DEPTH : 0); $endif
}

fn void message_copy(String msg)
{
	$if ENABLE: ___tracy_emit_message(msg.ptr, (usz)msg.len, ENABLE_CALLSTACK ? CALLSTACK_DEPTH : 0); $endif
}

fn void message_color_copy(String msg, uint color)
{
	$if ENABLE: ___tracy_emit_messageC(msg.ptr, (usz)msg.len, color, ENABLE_CALLSTACK ? CALLSTACK_DEPTH : 0); $endif
}

fn void frame_mark()
{
	$if ENABLE: ___tracy_emit_frame_mark(null); $endif
}

fn void frame_mark_named(ZString name)
{
	$if ENABLE: ___tracy_emit_frame_mark(name); $endif
}

struct Frame
{
	ZString name;
}

fn Frame named_frame(ZString name)
{
	$if ENABLE: ___tracy_emit_frame_mark_start(name); $endif
	return { .name = name };
}

fn void Frame.end(&self)
{
	$if ENABLE: ___tracy_emit_frame_mark_end(self.name); $endif
}

fn void alloc(void* ptr, usz size)
{
	$if ENABLE:
		$if ENABLE_CALLSTACK:
			___tracy_emit_memory_alloc_callstack(ptr, size, CALLSTACK_DEPTH, 0);
		$else
			___tracy_emit_memory_alloc(ptr, size, 0);
		$endif
	$endif
}

fn void alloc_named(void* ptr, usz size, ZString name)
{
	$if ENABLE:
		$if ENABLE_CALLSTACK:
			___tracy_emit_memory_alloc_callstack_named(ptr, size, CALLSTACK_DEPTH, 0, name);
		$else
			___tracy_emit_memory_alloc_named(ptr, size, 0, name);
		$endif
	$endif
}

fn void free(void* ptr)
{
	$if ENABLE:
		$if ENABLE_CALLSTACK:
			___tracy_emit_memory_free_callstack(ptr, CALLSTACK_DEPTH, 0);
		$else
			___tracy_emit_memory_free(ptr, 0);
		$endif
	$endif
}

fn void free_named(void* ptr, ZString name)
{
	$if ENABLE:
		$if ENABLE_CALLSTACK:
			___tracy_emit_memory_free_callstack_named(ptr, CALLSTACK_DEPTH, 0, name);
		$else
			___tracy_emit_memory_free_named(ptr, 0, name);
		$endif
	$endif
}

extern fn void ___tracy_emit_frame_mark_start(ZString name) @feat(TRACY);
extern fn void ___tracy_emit_frame_mark_end(ZString name) @feat(TRACY);
extern fn Ctx ___tracy_emit_zone_begin(SourceLocation* src, CInt active) @feat(TRACY);
extern fn Ctx ___tracy_emit_zone_begin_callstack(SourceLocation* src, CInt depth, CInt active) @feat(TRACY);
extern fn void ___tracy_emit_zone_text(Ctx ctx, char* text, usz size) @feat(TRACY);
extern fn void ___tracy_emit_zone_name(Ctx ctx, char* text, usz size) @feat(TRACY);
extern fn void ___tracy_emit_zone_color(Ctx ctx, uint color) @feat(TRACY);
extern fn void ___tracy_emit_zone_value(Ctx ctx, ulong value) @feat(TRACY);
extern fn void ___tracy_emit_zone_end(Ctx ctx) @feat(TRACY);
extern fn void ___tracy_emit_memory_alloc(void* ptr, usz size, CInt secure) @feat(TRACY);
extern fn void ___tracy_emit_memory_alloc_callstack(void* ptr, usz size, CInt depth, CInt secure) @feat(TRACY);
extern fn void ___tracy_emit_memory_free(void* ptr, CInt secure) @feat(TRACY);
extern fn void ___tracy_emit_memory_free_callstack(void* ptr, CInt depth, CInt secure) @feat(TRACY);
extern fn void ___tracy_emit_memory_alloc_named(void* ptr, usz size, CInt secure, ZString name) @feat(TRACY);
extern fn void ___tracy_emit_memory_alloc_callstack_named(void* ptr, usz size, CInt depth, CInt secure, ZString name) @feat(TRACY);
extern fn void ___tracy_emit_memory_free_named(void* ptr, CInt secure, ZString name) @feat(TRACY);
extern fn void ___tracy_emit_memory_free_callstack_named(void* ptr, CInt depth, CInt secure, ZString name) @feat(TRACY);
extern fn void ___tracy_emit_message(char* text, usz size, CInt callstack) @feat(TRACY);
extern fn void ___tracy_emit_messageL(ZString text, CInt callstack) @feat(TRACY);
extern fn void ___tracy_emit_messageC(char* text, usz size, uint color, CInt callstack) @feat(TRACY);
extern fn void ___tracy_emit_messageLC(ZString text, uint color, CInt callstack) @feat(TRACY);
extern fn void ___tracy_emit_frame_mark(ZString name) @feat(TRACY);
