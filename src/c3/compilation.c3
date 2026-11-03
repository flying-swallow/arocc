// Port of the source-storage part of src/aro/Compilation.zig: init/free,
// get_source, add_source_from_owned_buffer / add_source_from_buffer, source
// aliases and the string interner. Later tickets extend `Compilation` with
// targets, language options, include search, pragmas, etc.
module aro::compilation;
import aro::source, aro::string_interner, std::collections::list;

excuse FILE_TOO_BIG;

<*
 Diagnostics raised while normalizing sources, recorded as structured events
 until diagnostic rendering (plan 05) exists. Mirrors `Compilation.Diagnostic`.
*>
enum PendingDiagnosticTag : char
{
	BACKSLASH_NEWLINE_ESCAPE,
}

enum PendingDiagnosticKind : char
{
	OFF,
	WARNING,
}

fn String PendingDiagnosticTag.fmt(self)
{
	switch (self)
	{
		case BACKSLASH_NEWLINE_ESCAPE: return "backslash and newline separated by space";
	}
}

fn String PendingDiagnosticTag.opt(self)
{
	switch (self)
	{
		case BACKSLASH_NEWLINE_ESCAPE: return "backslash-newline-escape";
	}
}

fn PendingDiagnosticKind PendingDiagnosticTag.kind(self)
{
	switch (self)
	{
		case BACKSLASH_NEWLINE_ESCAPE: return WARNING;
	}
}

struct PendingDiagnostic
{
	PendingDiagnosticTag tag;
	<* `location.path` is owned by the source table, `location.line` is an owned copy. *>
	ExpandedLocation location;
}

struct Compilation
{
	Allocator gpa;
	<* Allocations here live until `free`; may be null until a ticket needs it. Not owned. *>
	Allocator arena;

	<* Indexed by SourceId.index; `source_paths` maps path -> index (keys borrowed from `sources`). *>
	List{Source} sources;
	StringTable source_paths;
	<* Indexed by SourceId.index of alias ids. Each alias owns only its `path`. *>
	List{Source} source_aliases;

	List{char} generated_buf;
	StringInterner string_interner;
	List{PendingDiagnostic} pending_diagnostics;

	<* If not UNUSED_ID, the directory containing this source is searched for includes (MS extension). *>
	SourceId ms_cwd_source_id;
}

<*
 Initialize an empty compilation. All owned memory comes from `gpa`.
 @param [&inout] gpa : "Allocator for everything the compilation owns"
*>
fn void Compilation.init(&self, Allocator gpa, Allocator arena = null)
{
	*self = { .gpa = gpa, .arena = arena, .ms_cwd_source_id = source::UNUSED_ID };
	self.sources.init(gpa);
	self.source_paths.init(gpa);
	self.source_aliases.init(gpa);
	self.generated_buf.init(gpa);
	self.string_interner.init(gpa);
	self.pending_diagnostics.init(gpa);
}

fn void Compilation.free(&self)
{
	Allocator gpa = self.gpa;
	foreach (&src : self.sources)
	{
		if (src.has_umbrella_framework_path()) assert(src.umbrella_framework_path.ptr == src.path.ptr);
		alloc::free(gpa, src.path.ptr);
		alloc::free(gpa, src.buf.ptr);
		if (src.splice_locs.len) alloc::free(gpa, src.splice_locs.ptr);
	}
	foreach (&al : self.source_aliases) alloc::free(gpa, al.path.ptr);
	foreach (&d : self.pending_diagnostics)
	{
		if (d.location.line.len) alloc::free(gpa, d.location.line.ptr);
	}
	self.sources.free();
	self.source_paths.free();
	self.source_aliases.free();
	self.generated_buf.free();
	self.string_interner.free();
	self.pending_diagnostics.free();
	*self = {};
}

fn StringId Compilation.intern_string(&self, String str) => self.string_interner.intern(str);

fn String StringId.lookup(self, Compilation* comp) => self.lookup_extra(&comp.string_interner);

<* Number of pending warnings (Zig tests read `diagnostics.warnings`). *>
fn uint Compilation.warning_count(&self)
{
	uint n;
	foreach (&d : self.pending_diagnostics) if (d.tag.kind() == WARNING) n++;
	return n;
}

<*
 Return the source for `id`. The returned value's slices stay valid until
 `free`, even when more sources are added (except the generated source, whose
 `buf` is invalidated whenever `generated_buf` grows).
 @require !id.is_unused() : "The unused source id has no source"
*>
fn Source Compilation.get_source(&self, SourceId id)
{
	if (id.is_alias) return self.source_aliases[id.index];
	if (id.index == source::GENERATED_INDEX)
	{
		return {
			.path = "<scratch space>",
			.buf = (String)self.generated_buf.array_view(),
			.id = source::GENERATED_ID,
			.kind = USER,
		};
	}
	return self.sources[id.index];
}

<* Look up a non-alias source by path. *>
fn Source? Compilation.find_source(&self, String path)
{
	uint idx = self.source_paths.find(path)!;
	return self.sources[idx];
}

fn ExpandedLocation Location.expand(self, Compilation* comp)
{
	Source src = comp.get_source(self.id);
	return src.line_col(self);
}

enum NormalizeState : char @private
{
	BEGINNING_OF_FILE,
	BOM1,
	BOM2,
	START,
	BACK_SLASH,
	CR,
	BACK_SLASH_CR,
	TRAILING_WS,
}

<*
 Creates a Source from `buf` and adds it to the compilation, performing
 newline splicing and line-ending normalization to '\n'. Ownership of `buf`
 moves to the compilation: it must have been allocated from `self.gpa` with
 room for one extra byte at `buf.ptr[buf.len]`; it is modified in place and
 may be reallocated. The caller retains ownership of `path` (it is copied).
 To add a buffer the caller keeps, use `add_source_from_buffer`.

 @require buf.len <= uint::max : "Source too big"
 @require !@ok(self.source_paths.find(path)) : "A source with this path already exists"
*>
fn Source Compilation.add_source_from_owned_buffer(&self, String path, char[] buf, SourceKind kind)
{
	Allocator gpa = self.gpa;
	char[] contents = buf;
	String duped_path = path.copy(gpa);

	List{uint} splice_list;
	splice_list.init(gpa);
	defer splice_list.free();

	SourceId source_id = { .index = (uint)self.sources.len() };

	uint i = 0;
	uint backslash_loc;
	NormalizeState state = BEGINNING_OF_FILE;
	uint line = 1;

	for SCAN: (usz j = 0; j < contents.len; j++)
	{
		char byte = contents[j];
		contents[i] = byte;

		switch (byte)
		{
			case '\r':
				switch (state)
				{
					case START:
					case CR:
					case BEGINNING_OF_FILE:
						line++;
						state = CR;
						contents[i] = '\n';
						i++;
					case BACK_SLASH:
					case TRAILING_WS:
					case BACK_SLASH_CR:
						i = backslash_loc;
						splice_list.push(i);
						if (state == TRAILING_WS)
						{
							self.add_newline_escape_error(duped_path, contents, splice_list.array_view(), i, line, kind);
						}
						state = state == BACK_SLASH_CR ? CR : BACK_SLASH_CR;
						line++;
					case BOM1:
					case BOM2:
						break SCAN; // invalid utf-8
				}
			case '\n':
				switch (state)
				{
					case START:
					case BEGINNING_OF_FILE:
						line++;
						i++;
					case CR:
					case BACK_SLASH_CR:
						break;
					case BACK_SLASH:
					case TRAILING_WS:
						i = backslash_loc;
						splice_list.push(i);
						if (state == TRAILING_WS)
						{
							self.add_newline_escape_error(duped_path, contents, splice_list.array_view(), i, line, kind);
						}
						line++;
					case BOM1:
					case BOM2:
						break SCAN;
				}
				state = START;
			case '\\':
				backslash_loc = i;
				state = BACK_SLASH;
				i++;
			case '\t':
			case 0x0B:
			case 0x0C:
			case ' ':
				switch (state)
				{
					case START:
					case TRAILING_WS:
						break;
					case BEGINNING_OF_FILE:
					case CR:
					case BACK_SLASH_CR:
						state = START;
					case BACK_SLASH:
						state = TRAILING_WS;
					case BOM1:
					case BOM2:
						break SCAN;
				}
				i++;
			case 0xEF:
				i++;
				state = state == BEGINNING_OF_FILE ? BOM1 : START;
			case 0xBB:
				i++;
				state = state == BOM1 ? BOM2 : START;
			case 0xBF:
				if (state == BOM2)
				{
					i = 0; // rewind and overwrite the BOM
				}
				else
				{
					i++;
				}
				state = START;
			default:
				i++;
				state = START;
		}
	}

	uint[] splice_locs;
	if (splice_list.len()) splice_locs = alloc::clone_slice(gpa, splice_list.array_view());

	if (i != contents.len)
	{
		char* p = alloc::realloc(gpa, contents.ptr, (usz)i + 1);
		contents = p[:i];
	}
	contents.ptr[contents.len] = 0;

	Source src = {
		.id = source_id,
		.path = duped_path,
		.buf = (String)contents,
		.splice_locs = splice_locs,
		.kind = kind,
	};
	self.sources.push(src);
	uint idx = self.source_paths.get_or_put(duped_path);
	assert(idx == source_id.index);
	return src;
}

<*
 Record a backslash-newline-escape warning. `buf` is the partially normalized
 buffer; the reported line text is copied because `buf` keeps changing.
*>
fn void Compilation.add_newline_escape_error(&self, String path, char[] buf, uint[] splice_locs, uint byte_offset, uint line, SourceKind kind)
{
	// Temporary source for getting the location for errors.
	Source tmp_source = {
		.path = path,
		.buf = (String)buf,
		.id = source::UNUSED_ID,
		.kind = kind,
		.splice_locs = splice_locs,
	};
	ExpandedLocation loc = tmp_source.line_col({ .id = source::UNUSED_ID, .byte_offset = byte_offset, .line = line });
	if (loc.line.len) loc.line = loc.line[:loc.line.len - 1];
	loc.width += 1;
	loc.col += 1;
	loc.line = loc.line.len ? loc.line.copy(self.gpa) : "";
	self.pending_diagnostics.push({ .tag = BACKSLASH_NEWLINE_ESCAPE, .location = loc });
}

<*
 Add a source from a buffer the caller keeps (it is copied). If a source with
 the same path already exists it is returned unchanged.
 @return? FILE_TOO_BIG
*>
fn Source? Compilation.add_source_from_buffer(&self, String path, char[] buf)
{
	if (try existing = self.find_source(path)) return existing;
	if (buf.len > uint::max) return FILE_TOO_BIG~;
	char* contents = alloc::malloc(self.gpa, buf.len + 1);
	if (buf.len) mem::copy(contents, buf.ptr, buf.len);
	contents[buf.len] = 0;
	return self.add_source_from_owned_buffer(path, contents[:buf.len], USER);
}

<*
 Register `new_path` / `new_kind` as another name for `id`. The alias shares
 the original's buffer and splice locations; `new_path` is copied (the Zig
 original borrowed it).
*>
fn SourceId Compilation.add_source_alias(&self, SourceId id, String new_path, SourceKind new_kind)
{
	Source aliased = self.get_source(id);
	aliased.path = new_path.copy(self.gpa);
	aliased.id = { .index = (uint)self.source_aliases.len(), .is_alias = true };
	aliased.kind = new_kind;
	self.source_aliases.push(aliased);
	return aliased.id;
}
