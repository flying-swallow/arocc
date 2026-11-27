// Diagnostics shared by IR verification, optimization, and lowering.
module aro::backend::ir;
import std::collections::list;

// Shared failure used by legalization and machine lowering.
excuse LOWER_FAIL;

<* One failure record: name borrows the declaration name; message is owned. *>
struct ErrorEntry
{
	String name;
	String message;
}

<* Ordered name -> message map (Zig `Renderer.ErrorList`). A repeated name replaces its message in place. *>
struct ErrorList
{
	Allocator allocator;
	List{ErrorEntry} entries;
}

fn void ErrorList.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.entries.init(allocator);
}

<* Free every owned message, then the entry storage. Resets to `{}`. *>
fn void ErrorList.free(&self)
{
	foreach (entry : self.entries) alloc::free(self.allocator, entry.message.ptr);
	self.entries.free();
	*self = {};
}

<* Insert `message` for `name`. A repeated name frees the old message and keeps the entry's position. *>
fn void ErrorList.put(&self, String name, String message)
{
	foreach (&entry : self.entries)
	{
		if (entry.name == name)
		{
			alloc::free(self.allocator, entry.message.ptr);
			entry.message = message;
			return;
		}
	}
	self.entries.push({ .name = name, .message = message });
}

fn usz ErrorList.len(&self) => (usz)self.entries.len();
fn String ErrorList.name_at(&self, usz i) => self.entries.array_view()[i].name;
fn String ErrorList.message_at(&self, usz i) => self.entries.array_view()[i].message;

