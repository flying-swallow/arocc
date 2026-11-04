// Port of the source-storage part of src/aro/Compilation.zig: init/free,
// get_source, add_source_from_owned_buffer / add_source_from_buffer, source
// aliases and the string interner. Later tickets extend `Compilation` with
// targets, language options, include search, pragmas, etc.
module aro::compilation;
import aro::source, aro::string_interner, aro::diagnostics, aro::lang_opts, aro::target, aro::type_store, std::collections::list;
import aro::value_interner;
import aro::builtins;
import aro::code_gen_options, std::time;

excuse FILE_TOO_BIG;

<* Zig `error.FatalError` (Compilation.Error): a fatal error has occurred and compilation has stopped. *>
excuse FATAL_ERROR;

// Zig `Compilation.Diagnostic` constants.
const DiagnosticTemplate DIAG_BACKSLASH_NEWLINE_ESCAPE = {
	.fmt = "backslash and newline separated by space",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.BACKSLASH_NEWLINE_ESCAPE,
};

const DiagnosticTemplate DIAG_MS_SEARCH_RULE = {
	.fmt = "#include resolved using non-portable Microsoft search rules as: {s}",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.MICROSOFT_INCLUDE,
	.extension = true,
};

const DiagnosticTemplate DIAG_CTRL_Z_EOF = {
	.fmt = "treating Ctrl-Z as end-of-file is a Microsoft extension",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.MICROSOFT_END_OF_FILE,
	.extension = true,
};

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
	<* Where diagnostics go. Borrowed unless `owns_diagnostics` (an IGNORE sink allocated in `init`). *>
	Diagnostics* diagnostics;
	bool owns_diagnostics;

	<* If not UNUSED_ID, the directory containing this source is searched for includes (MS extension). *>
	SourceId ms_cwd_source_id;

	<* Language options; starts as `lang_opts::DEFAULT` (Zig `langopts: LangOpts = .{}`). *>
	LangOpts langopts;
	<* The C program's target; starts as the native target (Zig `target: Target = .default`). *>
	Target target;
	bool has_darwin_target_variant;
	Target darwin_target_variant;
	<* Interned types (Zig `type_store`); named types are filled by `type_store::init_named_types`. *>
	TypeStore type_store;
	<* Interned constant values (Zig `interner`, backend Interner); see aro::value. *>
	Interner interner;
	<* Created builtin function types, keyed by name (Zig `builtins`). *>
	Builtins builtins;

	<* Zig `environment` (values borrowed; empty by default, Zig `.{}`). *>
	Environment environment;
	<*
	 Wall clock for SourceEpoch.system (Zig `Io.Clock.real.now(io)`); SYSTEM_CLOCK
	 by default. Tests and the probe pass fixed_clock() for determinism.
	*>
	WallClock clock;
	<* Zig `code_gen_options` (starts as code_gen_options::DEFAULT). *>
	CodeGenOptions code_gen_options;
	<* Zig `cmodel` (std.builtin.CodeModel, starts as DEFAULT). *>
	CodeModel cmodel;
}

// ---------------------------------------------------------------------------
// Environment and clock (plan 14 stage 0)

<*
 Zig `Compilation.Environment`: the environment variables aro reads. Only
 the fields some port reads are present; `has_*` false is Zig `null`.
 Values are borrowed (Zig: "Does not copy values").
*>
struct Environment
{
	<*
	 SOURCE_DATE_EPOCH: UNIX timestamp to be used instead of the current date
	 and time in the __DATE__ and __TIME__ macros, and instead of the file
	 modification time in the __TIMESTAMP__ macro. Parsed by
	 Compilation.source_epoch (pp_builtin_macros.c3).
	*>
	bool has_source_date_epoch;
	String source_date_epoch;
}

<* Zig `Environment.sourceEpoch` max_timestamp: Dec 31 9999 23:59:59. *>
const ulong MAX_SOURCE_EPOCH_TIMESTAMP = 253402300799;

<*
 Seconds since the UNIX epoch (Zig `Io.Clock.real.now(io).toSeconds()`, an
 i64 truncated toward zero). A fault is treated like Zig's failed u64 cast
 (InvalidEpoch).
*>
alias ClockNowFn = fn long? (void* ctx);

<* Clock source; `ctx` is passed to `now`. *>
struct WallClock
{
	void* ctx;
	ClockNowFn now;
}

<* The host's real-time clock (std::time::now is microseconds since the epoch). *>
fn long? system_clock_now(void* ctx) => (long)time::now() / 1_000_000;

const WallClock SYSTEM_CLOCK = { null, &system_clock_now };

<* Reads *(long*)ctx. *>
fn long? fixed_clock_now(void* ctx) => *(long*)ctx;

<* A clock that always reads `*seconds` (borrowed; must outlive the compilation's use of it). *>
fn WallClock fixed_clock(long* seconds) => { seconds, &fixed_clock_now };

<* Read `clock` (Zig `Io.Clock.real.now(io).toSeconds()`). *>
fn long? Compilation.now_seconds(&self) => self.clock.now(self.clock.ctx);

<*
 Initialize an empty compilation. All owned memory comes from `gpa`.
 `diagnostics` is borrowed (Zig `InitOptions.diagnostics`); when null the
 compilation owns a sink with IGNORE output that still counts messages.
 @param [&inout] gpa : "Allocator for everything the compilation owns"
*>
fn void Compilation.init(&self, Allocator gpa, Allocator arena = null, Diagnostics* diagnostics = null)
{
	*self = { .gpa = gpa, .arena = arena, .ms_cwd_source_id = source::UNUSED_ID, .diagnostics = diagnostics };
	self.langopts = lang_opts::DEFAULT;
	self.clock = SYSTEM_CLOCK;
	self.code_gen_options = code_gen_options::DEFAULT;
	self.cmodel = DEFAULT;
	// Zig's `Target.default` is the host (builtin); an undescribable host is a build configuration error.
	self.target = target::native()!!;
	if (!diagnostics)
	{
		self.diagnostics = alloc::new(gpa, Diagnostics);
		self.diagnostics.init_ignore();
		self.owns_diagnostics = true;
	}
	self.sources.init(gpa);
	self.source_paths.init(gpa);
	self.source_aliases.init(gpa);
	self.generated_buf.init(gpa);
	self.string_interner.init(gpa);
	self.type_store.init(gpa);
	self.interner.init(gpa);
	self.builtins.init(gpa);
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
	self.sources.free();
	self.source_paths.free();
	self.source_aliases.free();
	self.generated_buf.free();
	self.string_interner.free();
	self.type_store.free();
	self.interner.free();
	self.builtins.free();
	if (self.owns_diagnostics)
	{
		self.diagnostics.free();
		alloc::free(gpa, self.diagnostics);
	}
	*self = {};
}

fn StringId Compilation.intern_string(&self, String str) => self.string_interner.intern(str);

fn String StringId.lookup(self, Compilation* comp) => self.lookup_extra(&comp.string_interner);

<* Warnings sent to the diagnostics output (Zig tests read `diagnostics.warnings`). *>
fn uint Compilation.warning_count(&self) => self.diagnostics.warnings;

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
 If a diagnostic fails (FATAL_ERROR) nothing is added, the copied path is freed
 and `buf` stays with the caller (Zig's `errdefer` behavior).

 @require buf.len <= uint::max : "Source too big"
 @require !@ok(self.source_paths.find(path)) : "A source with this path already exists"

 @return? FATAL_ERROR
*>
fn Source? Compilation.add_source_from_owned_buffer(&self, String path, char[] buf, SourceKind kind)
{
	Allocator gpa = self.gpa;
	char[] contents = buf;
	String duped_path = path.copy(gpa);
	defer catch alloc::free(gpa, duped_path.ptr);

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
							self.add_newline_escape_error(duped_path, contents, splice_list.array_view(), i, line, kind)!;
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
							self.add_newline_escape_error(duped_path, contents, splice_list.array_view(), i, line, kind)!;
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
 Report a backslash-newline-escape warning. `buf` is the partially normalized
 buffer; it is only borrowed for the duration of the `Diagnostics.add` call.
 @return? FATAL_ERROR
*>
fn void? Compilation.add_newline_escape_error(&self, String path, char[] buf, uint[] splice_locs, uint byte_offset, uint line, SourceKind kind)
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
	self.diagnostics.add(DIAG_BACKSLASH_NEWLINE_ESCAPE.message_at(DIAG_BACKSLASH_NEWLINE_ESCAPE.fmt, loc))!;
}

<*
 Add a source from a buffer the caller keeps (it is copied). If a source with
 the same path already exists it is returned unchanged.
 @return? FILE_TOO_BIG, FATAL_ERROR
*>
fn Source? Compilation.add_source_from_buffer(&self, String path, char[] buf)
{
	if (try existing = self.find_source(path)) return existing;
	if (buf.len > uint::max) return FILE_TOO_BIG~;
	char* contents = alloc::malloc(self.gpa, buf.len + 1);
	if (buf.len) mem::copy(contents, buf.ptr, buf.len);
	contents[buf.len] = 0;
	defer catch alloc::free(self.gpa, contents);
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

// ---------------------------------------------------------------------------
// Literal helpers (Zig Compilation.CharUnitSize / wcharMax / float80Type),
// used by number_literal, number_value and text_literal (plan 11).

<* Zig `Compilation.float80Type` returned null: no __float80 for this target/emulation. *>
excuse NO_FLOAT80;

<* Zig `Compilation.CharUnitSize`: the byte width of one string-literal code unit. *>
enum CharUnitSize : char (uint size)
{
	ONE { 1 },
	TWO { 2 },
	FOUR { 4 },
}

<*
 Zig `Compilation.wcharMax`: the largest value of the target's wchar_t
 (maxInt of u8/i8, u16/i16 or u32/i32 by its bit size and signedness).
*>
fn uint Compilation.wchar_max(&self)
{
	QualType wchar = self.type_store.wchar;
	bool is_unsigned = wchar.signedness(self) == UNSIGNED;
	switch (wchar.bit_sizeof(self))
	{
		case 8: return is_unsigned ? 0xFF : 0x7F;
		case 16: return is_unsigned ? 0xFFFF : 0x7FFF;
		case 32: return is_unsigned ? 0xFFFF_FFFF : 0x7FFF_FFFF;
		default: unreachable("unexpected wchar_t size");
	}
}

<*
 Zig `Compilation.float80Type`: emulate NO/GCC -> Target.float80Type
 (LONG_DOUBLE on x86/x86_64, else none); MSVC/CLANG -> none.
 @return? NO_FLOAT80
*>
fn QualType? Compilation.float80_type(&self)
{
	switch (self.langopts.emulate)
	{
		case NO:
		case GCC:
			if (self.target.has_float80_type()) return type_store::LONG_DOUBLE;
			return NO_FLOAT80~;
		case MSVC:
		case CLANG:
			return NO_FLOAT80~;
	}
}
