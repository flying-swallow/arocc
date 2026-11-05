// Include and embed file lookup for Compilation. Filesystem access is injected
// so the same ordered search works with host and synthetic file services.
module aro::include_search;
import aro::compilation, aro::preprocessor, aro::source, aro::diagnostics;
import std::collections::list;

<* Add/replace the ordered -iquote/-I/-isystem/-idirafter search list. *>
fn void Compilation.set_include_dirs(&self, IncludeDir[] dirs, bool verbose = false) {
	if (self.include_dirs.ptr) alloc::free(self.gpa, self.include_dirs.ptr);
	List{IncludeDir} ordered;
	ordered.init(self.gpa);
	defer ordered.free();
	usz quote_count = 0;
	for (uint pass = 0; pass < 4; pass++) {
		foreach (dir : dirs) {
			// Zig skips inaccessible paths only for verbose search-list output.
			// Keep the provider optional so callers can configure paths before
			// installing file services.
			if (verbose && self.include_files.exists && !self.include_files.exists(self.include_files.ctx, dir.path)) continue;
			bool selected = false;
			if (pass == 0) selected = dir.kind == QUOTE;
			else if (pass == 1) selected = dir.kind == NORMAL || dir.kind == FRAMEWORK;
			else if (pass == 2) selected = dir.kind == SYSTEM || dir.kind == SYSTEM_FRAMEWORK;
			else selected = dir.kind == AFTER;
			if (!selected) continue;
			if (pass == 0) {
				bool duplicate = false;
				for (usz i = 0; i < ordered.len(); i++) {
					IncludeDir previous = ordered[i];
					if (previous.kind == QUOTE && previous.path == dir.path) { duplicate = true; break; }
				}
				if (!duplicate) ordered.push(dir);
				continue;
			}
			ordered.push(dir);
		}
		if (pass == 0) quote_count = ordered.len();
	}
	List{IncludeDir} final_dirs;
	final_dirs.init(self.gpa);
	defer final_dirs.free();
	for (usz i = 0; i < quote_count; i++) final_dirs.push(ordered[i]);
	for (usz i = quote_count; i < ordered.len(); i++) {
		IncludeDir current = ordered[i];
		bool framework = current.kind == FRAMEWORK || current.kind == SYSTEM_FRAMEWORK;
		sz duplicate_index = -1;
		for (usz j = quote_count; j < final_dirs.len(); j++) {
			IncludeDir previous = final_dirs[j];
			bool previous_framework = previous.kind == FRAMEWORK || previous.kind == SYSTEM_FRAMEWORK;
			if (previous.path == current.path && previous_framework == framework) { duplicate_index = (sz)j; break; }
		}
		if (duplicate_index < 0) {
			final_dirs.push(current);
			continue;
		}
		bool current_system = current.kind == SYSTEM || current.kind == SYSTEM_FRAMEWORK || current.kind == AFTER;
		IncludeDir previous = final_dirs[(usz)duplicate_index];
		bool previous_system = previous.kind == SYSTEM || previous.kind == SYSTEM_FRAMEWORK || previous.kind == AFTER;
		if (current_system && !previous_system) {
			for (usz j = (usz)duplicate_index; j + 1 < final_dirs.len(); j++) final_dirs[j] = final_dirs[j + 1];
			final_dirs.pop()!!;
			final_dirs.push(current);
		}
	}
	self.include_dirs = alloc::clone_slice(self.gpa, final_dirs.array_view());
}

fn usz find_substring(String haystack, String needle) {
	if (needle.len > haystack.len) return usz::max;
	for (usz i = 0; i <= haystack.len - needle.len; i++) {
		bool match = true;
		for (usz j = 0; j < needle.len; j++) if (haystack[i + j] != needle[j]) { match = false; break; }
		if (match) return i;
	}
	return usz::max;
}

<* Join without changing borrowed components; allocated result is owned by caller. *>
fn String join_path(Allocator a, String left, String right) {
	if (left.len == 0) return right.copy(a);
	if (right.len == 0) return left.copy(a);
	bool left_slash = left[left.len - 1] == '/';
	bool right_slash = right[0] == '/';
	uint skip = left_slash && right_slash ? 1 : 0;
	uint extra = left_slash || right_slash ? 0 : 1;
	char* p = alloc::malloc(a, left.len + right.len - skip + extra + 1);
	mem::copy(p, left.ptr, left.len);
	uint at = (uint)left.len;
	if (extra) p[at++] = '/';
	mem::copy(p + at, right.ptr + skip, right.len - skip);
	at += (uint)(right.len - skip);
	p[at] = 0;
	return (String)p[:at];
}

<* Lexically collapse . and .. without consulting the host filesystem. *>
fn String normalize_path(Allocator a, String path) {
	List{String} parts;
	parts.init(a);
	defer parts.free();
	bool absolute = path.len > 0 && path[0] == '/';
	usz i = 0;
	while (i < path.len) {
		while (i < path.len && path[i] == '/') i++;
		usz start = i;
		while (i < path.len && path[i] != '/') i++;
		if (start == i) continue;
		String part = path[start..i];
		if (part == ".") continue;
		if (part == ".." && parts.len() > 0 && parts[parts.len() - 1] != "..") { parts.pop()!!; continue; }
		if (part == ".." && absolute) continue;
		parts.push(part);
	}
	usz len = absolute ? 1 : 0;
	foreach (part : parts) len += part.len + 1;
	if (len > (absolute ? 1 : 0)) len--;
	if (!absolute && len == 0) len = 1;
	char* out = alloc::malloc(a, (sz)len + 1);
	usz at = 0;
	if (absolute) out[at++] = '/';
	foreach (part : parts) {
		if (at > 0 && out[at - 1] != '/') out[at++] = '/';
		mem::copy(out + at, part.ptr, part.len);
		at += part.len;
	}
	if (at == 0) out[at++] = '.';
	out[at] = 0;
	return (String)out[:at];
}

<* Replace the ordered embed search directories; path strings remain borrowed. *>
fn void Compilation.set_embed_dirs(&self, String[] dirs) {
	if (self.embed_dirs.ptr) alloc::free(self.gpa, self.embed_dirs.ptr);
	self.embed_dirs = alloc::clone_slice(self.gpa, dirs);
}

fn String include_path(Compilation* comp, String base, String name) {
	String joined = join_path(comp.gpa, base, name);
	String normalized = normalize_path(comp.gpa, joined);
	alloc::free(comp.gpa, joined.ptr);
	return normalized;
}

fn String framework_path_name(Allocator a, String name) {
	String suffix = ".framework";
	char* p = alloc::malloc(a, (sz)(name.len + suffix.len) + 1);
	mem::copy(p, name.ptr, name.len);
	mem::copy(p + name.len, suffix.ptr, suffix.len);
	p[name.len + suffix.len] = 0;
	return (String)p[:name.len + suffix.len];
}

fn bool has_nul(String s) { foreach (c : s) if (c == 0) return true; return false; }

fn Source? try_path(Compilation* comp, String path, SourceKind kind) {
	if (!comp.include_files.exists || !comp.include_files.read) return preprocessor::FILE_NOT_FOUND~;
	if (!comp.include_files.exists(comp.include_files.ctx, path)) return preprocessor::FILE_NOT_FOUND~;
	if (try src = comp.find_source(path)) return src;
	char[]? loaded = comp.include_files.read(comp.include_files.ctx, comp.gpa, path, (ulong)uint::max + 1);
	if (catch f = loaded) {
		if (f == preprocessor::FILE_NOT_FOUND) return preprocessor::FILE_NOT_FOUND~;
		return f~;
	}
	char[] raw = loaded;
	if (raw.len > uint::max) { if (raw.ptr) alloc::free(comp.gpa, raw.ptr); return compilation::FILE_TOO_BIG~; }
	char* owned = alloc::malloc(comp.gpa, raw.len + 1);
	defer catch alloc::free(comp.gpa, owned);
	if (raw.len) mem::copy(owned, raw.ptr, raw.len);
	owned[raw.len] = 0;
	if (raw.ptr) alloc::free(comp.gpa, raw.ptr);
	char[] data = owned[:raw.len];
	return comp.add_source_from_owned_buffer(path, data, kind);
}

fn Source? search_candidate(Compilation* comp, String base, String filename, SourceKind kind) {
	String path = include_path(comp, base, filename);
	defer alloc::free(comp.gpa, path.ptr);
	return try_path(comp, path, kind);
}

fn Source? Compilation.search_include(&self, String filename, SourceId includer, IncludeType type, WhichInclude which, RawToken* include_tok) {
	if (has_nul(filename)) return preprocessor::FILE_NOT_FOUND~;
	Source current = self.get_source(includer);
	if (filename.len > 0 && filename[0] == '/') {
		if (which == NEXT) return preprocessor::FILE_NOT_FOUND~;
		String normalized = normalize_path(self.gpa, filename);
		defer alloc::free(self.gpa, normalized.ptr);
		return try_path(self, normalized, USER);
	}
	if (which == FIRST && type == CLI) {
		if (try src = search_candidate(self, self.cwd, filename, USER)) return src;
	}
	if (which == FIRST && type == QUOTES) {
		uint slash = filename.len;
		for (usz i = current.path.len; i > 0; i--) if (current.path[i - 1] == '/') { slash = (uint)i - 1; break; }
		String dir = slash == filename.len ? "." : current.path[:slash];
		if (try src = search_candidate(self, dir, filename, USER)) return src;
	}
	bool wait = false;
	String wait_dir = "";
	if (which == NEXT) {
		for (usz i = current.path.len; i > 0; i--) if (current.path[i - 1] == '/') { wait_dir = current.path[:i - 1]; break; }
		// If the includer did not come from an include directory, include_next
		// starts at the beginning of the configured search path.
		foreach (dir : self.include_dirs) {
			if (dir.path == wait_dir) { wait = true; break; }
		}
	}
	foreach (dir : self.include_dirs) {
		if (dir.kind == QUOTE && type == ANGLE_BRACKETS) continue;
		if (wait) { if (dir.path == wait_dir) wait = false; continue; }
		SourceKind kind = (dir.kind == SYSTEM || dir.kind == SYSTEM_FRAMEWORK || dir.kind == AFTER) ? SYSTEM : USER;
		if (dir.kind == FRAMEWORK || dir.kind == SYSTEM_FRAMEWORK) {
			uint slash = filename.len;
			for (usz i = 0; i < filename.len; i++) if (filename[i] == '/') { slash = (uint)i; break; }
			if (slash == filename.len) continue;
			String fw = framework_path_name(self.gpa, filename[:slash]);
			defer alloc::free(self.gpa, fw.ptr);
			String root = join_path(self.gpa, dir.path, fw);
			defer alloc::free(self.gpa, root.ptr);
			String headers = join_path(self.gpa, root, "Headers");
			defer alloc::free(self.gpa, headers.ptr);
			if (try src = search_candidate(self, headers, filename[slash + 1..], kind)) {
				// Prefix slice is stable because the source path is compilation-owned.
				usz pos = find_substring(src.path, fw);
				if (pos != usz::max) {
					String umbrella = src.path[:pos + fw.len];
					self.sources[src.id.index].umbrella_framework_path = umbrella;
					src.umbrella_framework_path = umbrella;
				}
				return src;
			}
		} else if (try src = search_candidate(self, dir.path, filename, kind)) { return src; }
	}
	if (self.ms_cwd_source_id != source::UNUSED_ID) {
		Source ms = self.get_source(self.ms_cwd_source_id);
		uint slash = ms.path.len;
		for (usz i = ms.path.len; i > 0; i--) if (ms.path[i - 1] == '/') { slash = (uint)i - 1; break; }
		String dir = slash == ms.path.len ? "." : ms.path[:slash];
		if (try src = search_candidate(self, dir, filename, USER)) {
			if (include_tok) {
				RawToken tok = *include_tok;
				ExpandedLocation loc = self.get_source(tok.source).line_col({ .id = tok.source, .byte_offset = tok.start, .line = tok.line });
				DString warning;
				warning.init(self.gpa);
				defer warning.free();
				if (catch diagnostics::format_args(&warning, DIAG_MS_SEARCH_RULE.fmt, { diagnostics::arg_str(filename) })) unreachable("formatting into a DString failed");
				self.diagnostics.add(DIAG_MS_SEARCH_RULE.message_at(warning.str_view(), loc))!;
			}
			return src;
		}
	}
	if (current.has_umbrella_framework_path()) {
		uint slash = filename.len;
		for (usz i = 0; i < filename.len; i++) if (filename[i] == '/') { slash = (uint)i; break; }
		if (slash != filename.len) {
			String fw = framework_path_name(self.gpa, filename[:slash]);
			defer alloc::free(self.gpa, fw.ptr);
			String frameworks = join_path(self.gpa, current.umbrella_framework_path, "Frameworks");
			defer alloc::free(self.gpa, frameworks.ptr);
			String root = join_path(self.gpa, frameworks, fw);
			defer alloc::free(self.gpa, root.ptr);
			String headers = join_path(self.gpa, root, "Headers");
			defer alloc::free(self.gpa, headers.ptr);
			if (try src = search_candidate(self, headers, filename[slash + 1..], current.kind)) {
				self.sources[src.id.index].umbrella_framework_path = current.umbrella_framework_path;
				src.umbrella_framework_path = current.umbrella_framework_path;
				return src;
			}
		}
	}
	return preprocessor::FILE_NOT_FOUND~;
}

fn Source? provider_find_include(void* ctx, Preprocessor* pp, String filename, RawToken include_tok, IncludeType type, WhichInclude which) {
	return pp.comp.search_include(filename, include_tok.source, type, which, &include_tok);
}

fn bool? provider_has_include(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType type, WhichInclude which) {
	Source? found = pp.comp.search_include(filename, includer, type, which, null);
	if (catch f = found) {
		if (f == preprocessor::FILE_NOT_FOUND) return false;
		return f~;
	}
	if (pp.dependencies) pp.dependencies.add_dependency(found.path);
	return true;
}

fn char[]? read_embed_candidate(Compilation* comp, Preprocessor* pp, String path, String dependency_path, ulong limit) {
	// Keep provider read failures distinct from a candidate that does not exist.
	// The FileProvider contract passes `limit` through to the file service.
	char[]? loaded = comp.include_files.read(comp.include_files.ctx, comp.gpa, path, limit);
	if (catch f = loaded) return f~;
	char[] bytes = loaded;
	// Zig records the spelling used in the directive. That text may be backed
	// by a temporary expansion buffer, so the dependency sink owns a copy.
	if (pp.dependencies) pp.dependencies.add_dependency_copy(dependency_path);
	return bytes;
}

fn char[]? provider_find_embed(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType type, ulong limit) {
	Compilation* comp = pp.comp;
	if (!comp.include_files.read || !comp.include_files.exists || has_nul(filename)) return preprocessor::FILE_NOT_FOUND~;
	if (filename.len != 0 && filename[0] == '/') {
		if (!comp.include_files.exists(comp.include_files.ctx, filename)) return preprocessor::FILE_NOT_FOUND~;
		return read_embed_candidate(comp, pp, filename, filename, limit);
	}
	if (type == QUOTES || type == CLI) {
		Source src = comp.get_source(includer);
		uint slash = src.path.len;
		for (usz i = src.path.len; i > 0; i--) if (src.path[i - 1] == '/') { slash = (uint)i - 1; break; }
		String dir = slash == src.path.len ? "." : src.path[:slash];
		String candidate = include_path(comp, dir, filename);
		defer alloc::free(comp.gpa, candidate.ptr);
		if (comp.include_files.exists(comp.include_files.ctx, candidate)) return read_embed_candidate(comp, pp, candidate, filename, limit);
	}
	foreach (dir : comp.embed_dirs) {
		String candidate = include_path(comp, dir, filename);
		defer alloc::free(comp.gpa, candidate.ptr);
		if (comp.include_files.exists(comp.include_files.ctx, candidate)) return read_embed_candidate(comp, pp, candidate, filename, limit);
	}
	return preprocessor::FILE_NOT_FOUND~;
}

fn ulong? provider_source_mtime(void* ctx, Preprocessor* pp, SourceId id) {
	if (!pp.comp.include_files.mtime) return 0;
	Source src = pp.comp.get_source(id);
	return pp.comp.include_files.mtime(pp.comp.include_files.ctx, src.path) ?? 0;
}

fn FileProvider Compilation.file_provider(&self) => { .ctx = self, .find_include = &provider_find_include, .has_include = &provider_has_include, .find_embed = &provider_find_embed, .source_mtime = &provider_source_mtime };
