// Linker input filesystem with deterministic in-memory overlays and read cache.
module aro::backend::link;
import aro::frontend::c::diagnostics;
import std::collections::list;
import std::io::file;

<*
 An owned name-to-bytes entry. Both slices point to their own allocations,
 never into a List backing buffer, so they stay stable as entries are added.
*>
struct LinkFsEntry
{
	String name;
	char[] bytes;
}

struct LinkFs
{
	Allocator allocator;
	<* Explicit inputs override host files and cached reads. *>
	List{LinkFsEntry} overlay;
	<* Successful host reads are retained until free; failures are not cached. *>
	List{LinkFsEntry} loaded;
	<* Replaced overlay contents stay alive because callers may still hold their slices. *>
	List{char[]} retired_overlay_bytes;
}

fn void LinkFs.init(&self, Allocator a)
{
	*self = { .allocator = a };
	self.overlay.init(a);
	self.loaded.init(a);
	self.retired_overlay_bytes.init(a);
}

fn void free_entry(Allocator a, LinkFsEntry* entry)
{
	if (entry.name.ptr) alloc::free(a, entry.name.ptr);
	if (entry.bytes.ptr) alloc::free(a, entry.bytes.ptr);
	*entry = {};
}

fn void LinkFs.free(&self)
{
	foreach (&entry : self.overlay) free_entry(self.allocator, entry);
	foreach (&entry : self.loaded) free_entry(self.allocator, entry);
	foreach (bytes : self.retired_overlay_bytes) if (bytes.ptr) alloc::free(self.allocator, bytes.ptr);
	self.overlay.free();
	self.loaded.free();
	self.retired_overlay_bytes.free();
	*self = {};
}

fn LinkFsEntry* find_entry(List{LinkFsEntry}* entries, String name)
{
	for (sz i = 0; i < entries.len(); i++)
	{
		LinkFsEntry* entry = &entries.entries[i];
		if (entry.name == name) return entry;
	}
	return null;
}

<*
 Add or replace an in-memory file. The name and contents are copied, and an
 overlay always wins over both the host filesystem and a previously loaded
 host read for the same exact name.
*>
fn void LinkFs.add_overlay(&self, String name, char[] bytes)
{
	char[] owned_bytes = alloc::clone_slice(self.allocator, bytes);
	if (LinkFsEntry* existing = find_entry(&self.overlay, name))
	{
		if (existing.bytes.ptr) self.retired_overlay_bytes.push(existing.bytes);
		existing.bytes = owned_bytes;
		return;
	}
	String owned_name = name.copy(self.allocator);
	self.overlay.push({ .name = owned_name, .bytes = owned_bytes });
}

<*
 Return whether a path names an overlay, a successfully loaded file, or a host
 file. Paths are compared byte-for-byte and are not normalized.
*>
fn bool LinkFs.exists(&self, String path)
{
	if (find_entry(&self.overlay, path)) return true;
	return file::is_file(path);
}

<*
 Return input bytes owned by this LinkFs. Overlay bytes take priority; otherwise
 a successful host read is cached. The returned slice remains valid until
 free(), even if more files are added. Paths are compared byte-for-byte and
 are not normalized. Host read failures are reported as CANNOT_OPEN and are
 not cached.

 @return? link::FILE_NOT_FOUND
*>
fn char[]? LinkFs.read(&self, Diagnostics* d, String path)
{
	if (LinkFsEntry* overlay = find_entry(&self.overlay, path)) return overlay.bytes;
	if (LinkFsEntry* cached = find_entry(&self.loaded, path)) return cached.bytes;

	char[]? loaded_opt = file::load(self.allocator, path);
	if (catch loaded_opt)
	{
		@link_err(d, Diagnostic.CANNOT_OPEN, path)!;
		return FILE_NOT_FOUND~;
	}

	char[] loaded_bytes = loaded_opt;
	String owned_name = path.copy(self.allocator);
	self.loaded.push({ .name = owned_name, .bytes = loaded_bytes });
	return self.loaded.entries[self.loaded.len() - 1].bytes;
}
