// Port of src/aro/DepFile.zig. Dependency paths retain insertion order and
// are borrowed by add_dependency or copied into the supplied arena by
// add_dependency_dupe.
module aro::dep_file;
import std::collections::list;

enum Format : char { MAKE, NMAKE }

struct DepFile
{
	String target;
	List{String} deps;
	<* Copies made by add_dependency_copy; borrowed/arena-owned paths are not freed here. *>
	List{String} owned_deps;
	Format format;
	Allocator allocator;
}

fn void DepFile.init(&self, Allocator a, String target, Format format)
{
	*self = { .target = target, .format = format, .allocator = a };
	self.deps.init(a);
	self.owned_deps.init(a);
}

fn void DepFile.free(&self)
{
	foreach (path : self.owned_deps) alloc::free(self.allocator, path.ptr);
	self.owned_deps.free();
	self.deps.free();
	*self = {};
}

fn void DepFile.add_dependency(&self, String path)
{
	foreach (dep : self.deps) if (dep == path) return;
	self.deps.push(path);
}

fn void DepFile.add_dependency_dupe(&self, Allocator arena, String path)
{
	foreach (dep : self.deps) if (dep == path) return;
	self.deps.push(path.copy(arena));
}

<* Copy a transient path and release the copy from `free`, independent of a Compilation arena. *>
fn void DepFile.add_dependency_copy(&self, String path)
{
	foreach (dep : self.deps) if (dep == path) return;
	String copy = path.copy(self.allocator);
	self.owned_deps.push(copy);
	self.deps.push(copy);
}

<* Write a Make or NMake dependency rule to `w`. *>
fn void DepFile.write(&self, DString* w)
{
	const sz MAX_COLUMNS = 75;
	sz columns = 0;
	write_target(self.target, w);
	columns += self.target.len;
	put(w, ":");
	columns++;
	foreach (path : self.deps)
	{
		if (path == "<stdin>") continue;
		if (columns + path.len + 3 > MAX_COLUMNS)
		{
			put(w, " \\\n ");
			columns = 1;
		}
		put(w, " ");
		write_path(self.format, path, w);
		columns += path.len + 1;
	}
	put(w, "\n");
}

fn void put(DString* w, String s) => w.append_string(s);

fn void put_char(DString* w, char c) => w.append_char(c);

fn void write_target(String path, DString* w)
{
	foreach (i, c : path)
	{
		switch (c)
		{
			case ' ':
			case '\t':
				put_char(w, '\\');
				for (sz j = i; j > 0;)
				{
					j--;
					if (path[j] != '\\') break;
					put_char(w, '\\');
				}
			case '$': put_char(w, '$');
			case '#': put_char(w, '\\');
			default:
		}
		put_char(w, c);
	}
}

fn void write_path(Format format, String path, DString* w)
{
	if (format == NMAKE)
	{
		bool quote = false;
		foreach (c : path) if (c == ' ' || c == '#' || c == '$' || c == '{' || c == '}' || c == '^' || c == '!') quote = true;
		if (quote) put(w, "\"");
		put(w, path);
		if (quote) put(w, "\"");
		return;
	}
	foreach (i, c : path)
	{
		switch (c)
		{
			case ' ':
				put_char(w, '\\');
				for (sz j = i; j > 0;)
				{
					j--;
					if (path[j] != '\\') break;
					put_char(w, '\\');
				}
			case '$': put_char(w, '$');
			case '#': put_char(w, '\\');
			default:
		}
		put_char(w, c);
	}
}
