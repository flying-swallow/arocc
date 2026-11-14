// Port of src/aro/InitList.zig: sparse initializer children indexed by
// designator. Keeping only present indexes avoids allocations proportional to
// a potentially very large array designator.
module aro::init_list;
import aro::tokens, aro::type_store;
import std::collections::list;

<* One populated child and its designator index (Zig `Item`). *>
struct InitListItem
{
	InitList child;
	ulong index;
}

<* A sparse initializer tree node (Zig `InitList`). *>
struct InitList
{
	List{InitListItem} items;
	type_store::NodeOptIndex node;
	tokens::TokenIndex tok;
}

<* Initialize an empty list node with the allocator used by all descendants. *>
fn void InitList.init(&self, Allocator gpa)
{
	*self = { .node = type_store::NODE_NULL };
	self.items.init(gpa, 0);
}

<* Recursively release every descendant and reset this node to its empty state. *>
fn void InitList.free(&self)
{
	for (sz i = 0; i < self.items.len(); i++) self.items[i].child.free();
	self.items.free();
	*self = {};
}

<*
 Find the child at `index`, inserting an empty child in sorted order if absent.
 The returned pointer aliases this node's item storage and may be invalidated
 if a later insertion grows or shifts this node's list.
*>
fn InitList* InitList.find(&self, ulong index)
{
	sz left = 0;
	sz right = self.items.len();
	while (left < right)
	{
		sz mid = left + (right - left) / 2;
		ulong found = self.items[mid].index;
		if (found == index) return &self.items[mid].child;
		if (found < index) { left = mid + 1; }
		else { right = mid; }
	}

	InitList child;
	child.init(self.items.allocator);
	self.items.insert_at(left, { .child = child, .index = index });
	return &self.items[left].child;
}
